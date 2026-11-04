`timescale 1ns / 1ps
// Bluetooth 25-key octave map downloader.
// Frame: "BTPK", cmd=0x02, seq, len=25 LE16, payload CRC32 LE32,
// then 25 signed bytes. Allowed octave values are -1, 0, +1.
module uart_keymap (
    input  wire clk,
    input  wire rst_n,
    input  wire rx_valid,
    input  wire [7:0] rx_data,
    output reg [74:0] key_octave_bus,
    output reg download_active,
    output reg download_commit,
    output reg download_error,
    output reg tx_start,
    output reg [7:0] tx_data,
    input  wire tx_busy,
    output wire [3:0] state_dbg
);
    localparam [4:0] S_IDLE=0,S_M1=1,S_M2=2,S_M3=3,S_CMD=4,S_SEQ=5,
                     S_LEN0=6,S_LEN1=7,S_CRC0=8,S_CRC1=9,S_CRC2=10,S_CRC3=11,
                     S_PAYLOAD=12,S_CHECK=13;
    localparam [1:0] TX_NONE=0,TX_ACK=1,TX_NAK=2;
    reg [4:0] state;
    reg [7:0] cmd_q,seq_q,payload_idx;
    reg [15:0] payload_len;
    reg [31:0] crc_expected,crc_work;
    reg [63:0] magic;
    reg [74:0] map_work;
    wire [8:0] map_bit = {payload_idx,1'b0} + payload_idx;
    reg map_ok;
    reg [1:0] tx_kind;
    reg tx_pending;
    reg [2:0] tx_idx;
    reg [1:0] tx_phase;
    localparam [31:0] CRC32_POLY=32'hEDB88320;

    function [31:0] crc32_byte; input [31:0] c_in; input [7:0] d; integer j; reg [31:0] c;
    begin c=c_in; for(j=0;j<8;j=j+1) c=(c[0]^d[j])?((c>>1)^CRC32_POLY):(c>>1); crc32_byte=c; end endfunction
    function [7:0] msg_byte; input [1:0] kind; input [2:0] idx; begin
      if(kind==TX_ACK) case(idx) 0:msg_byte=8'h41;1:msg_byte=8'h43;2:msg_byte=8'h4B;3:msg_byte=8'h0D;default:msg_byte=8'h0A;endcase
      else case(idx) 0:msg_byte=8'h4E;1:msg_byte=8'h41;2:msg_byte=8'h4B;3:msg_byte=8'h0D;default:msg_byte=8'h0A;endcase
    end endfunction
    wire [31:0] crc_next=crc32_byte(crc_work,rx_data);

    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        state<=S_IDLE;cmd_q<=0;seq_q<=0;payload_idx<=0;payload_len<=0;
        crc_expected<=0;crc_work<=32'hFFFFFFFF;magic<=0;map_work<=0;map_ok<=1;
        key_octave_bus<=75'd0;download_active<=0;download_commit<=0;download_error<=0;
        tx_start<=0;tx_data<=0;tx_kind<=TX_NONE;tx_pending<=0;tx_idx<=0;tx_phase<=0;
      end else begin
        download_commit<=0;tx_start<=0;download_active<=(state!=S_IDLE);
        case(tx_phase)
        0: if(tx_pending&&!tx_busy) begin tx_data<=msg_byte(tx_kind,tx_idx);tx_start<=1;tx_phase<=1;end
        1: tx_phase<=2;
        2: if(tx_busy) tx_phase<=3;
        3: if(!tx_busy) begin if(tx_idx==4) begin tx_pending<=0;tx_idx<=0;end else tx_idx<=tx_idx+1;tx_phase<=0;end
        default: tx_phase<=0;
        endcase
        if(rx_valid) begin
          case(state)
          S_IDLE: if(rx_data==8'h42) begin state<=S_M1;crc_work<=32'hFFFFFFFF;payload_idx<=0;magic<=0;map_work<=0;map_ok<=1;end
          S_M1: state<=(rx_data==8'h54)?S_M2:S_IDLE;
          S_M2: state<=(rx_data==8'h50)?S_M3:S_IDLE;
          S_M3: if(rx_data==8'h4B) state<=S_CMD; else state<=S_IDLE;
          S_CMD: begin cmd_q<=rx_data;state<=S_SEQ;end
          S_SEQ: begin seq_q<=rx_data;state<=S_LEN0;end
          S_LEN0: begin payload_len[7:0]<=rx_data;state<=S_LEN1;end
          S_LEN1: begin payload_len[15:8]<=rx_data;state<=S_CRC0;end
          S_CRC0: begin crc_expected[7:0]<=rx_data;state<=S_CRC1;end
          S_CRC1: begin crc_expected[15:8]<=rx_data;state<=S_CRC2;end
          S_CRC2: begin crc_expected[23:16]<=rx_data;state<=S_CRC3;end
          S_CRC3: begin crc_expected[31:24]<=rx_data;payload_idx<=0;crc_work<=32'hFFFFFFFF;state<=(payload_len==25)?S_PAYLOAD:S_IDLE;if(payload_len!=25)begin tx_pending<=1;tx_kind<=TX_NAK;tx_idx<=0;end end
          S_PAYLOAD: begin
            crc_work<=crc_next;
            if(!(rx_data==8'hFF || rx_data==8'h00 || rx_data==8'h01)) map_ok<=0;
            map_work[map_bit +: 3] <= (rx_data==8'hFF)?3'b111:(rx_data==8'h01)?3'b001:3'b000;
            if(payload_idx==24) state<=S_CHECK; else payload_idx<=payload_idx+1;
          end
          default: state<=S_IDLE;
          endcase
        end
        if(state==S_CHECK) begin
          if(cmd_q==8'h02 && payload_len==25 && (~crc_work)==crc_expected && map_ok) begin
            key_octave_bus<=map_work;download_commit<=1;tx_pending<=1;tx_kind<=TX_ACK;tx_idx<=0;state<=S_IDLE;
          end else begin download_error<=1;tx_pending<=1;tx_kind<=TX_NAK;tx_idx<=0;state<=S_IDLE;end
        end
      end
    end
    assign state_dbg=state[3:0];
endmodule