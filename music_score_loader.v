`timescale 1ns / 1ps
//=============================================================================
// music_score_loader.v —— 从 SD 自定义曲谱区加载 512 字节曲谱
//=============================================================================
// MBR 第 4 分区项 type=0x7F，起始 LBA 指向曲谱扇区。
// 曲谱扇区格式见 tools/build_twinkle_score.py。
module music_score_loader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sd_ready,
    input  wire        sd_done,
    input  wire        sd_error,
    input  wire        sd_rvalid,
    input  wire [8:0]  sd_raddr,
    input  wire [7:0]  sd_rdata,
    input  wire [1:0]  song_index,
    input  wire        reload,
    output reg  [1:0]  loaded_song,
    output reg  [31:0] base_lba,
    output reg         base_valid,
    output reg         sd_start,
    output reg  [31:0] sd_sector,
    output reg         ram_we,
    output reg  [8:0]  ram_waddr,
    output reg  [7:0]  ram_wdata,
    output reg         load_done,
    output reg         load_error,
    output reg  [3:0]  load_err_code,
    output reg  [7:0]  track_count,
    output reg  [7:0]  ticks_per_q,
    output reg  [7:0]  flags,
    output reg  [31:0] tempo_step,
    output reg  [15:0] event_count,
    output reg  [15:0] event_bytes,
    output reg  [31:0] body_crc
);
    localparam [2:0] L_IDLE=3'd0, L_MBR=3'd1, L_MBR_WAIT=3'd2, L_SONG=3'd3,
                     L_SONG_WAIT=3'd4, L_CRC_WAIT=3'd5, L_GOOD=3'd6, L_BAD=3'd7;
    reg [2:0] state;
    reg [7:0] mbr_tail [0:17];
    reg [63:0] magic;
    reg [7:0] version;
    reg [31:0] score_lba, crc_expected, crc_work;
    reg [1:0] song_latched;
    reg [7:0] crc_data;
    reg [3:0] crc_bit;
    reg crc_busy;
    wire [31:0] crc_shift = (crc_work >> 1) ^ ((crc_work[0] ^ crc_data[0]) ? 32'hEDB88320 : 32'd0);
    wire [9:0] event_end_now = 10'd40 + event_bytes[9:0];
    wire in_event = (sd_raddr >= 9'd40) && ({1'b0, sd_raddr} < event_end_now);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=L_IDLE; sd_start<=0; sd_sector<=0; ram_we<=0; ram_waddr<=0; ram_wdata<=0;
            load_done<=0; load_error<=0; load_err_code<=0; magic<=0; version<=0;
            track_count<=0; ticks_per_q<=0; flags<=0; tempo_step<=0;
            event_count<=0; event_bytes<=0; crc_expected<=0; crc_work<=32'hFFFFFFFF;
            crc_data<=0; crc_bit<=0; crc_busy<=0; score_lba<=0; song_latched<=0; loaded_song<=0; base_lba<=0; base_valid<=0;
        end else begin
            ram_we<=1'b0; sd_start<=1'b0;
            if (sd_rvalid && state==L_MBR_WAIT && sd_raddr>=494)
                mbr_tail[sd_raddr-494] <= sd_rdata;
            if (crc_busy) begin
                crc_work <= crc_shift;
                crc_data <= crc_data >> 1;
                if (crc_bit==7) crc_busy<=1'b0; else crc_bit<=crc_bit+1;
            end else if (sd_rvalid && state==L_SONG_WAIT && in_event) begin
                crc_data<=sd_rdata; crc_bit<=0; crc_busy<=1'b1;
            end
            if (state==L_SONG_WAIT && sd_rvalid) begin
                ram_we<=1'b1; ram_waddr<=sd_raddr; ram_wdata<=sd_rdata;
                if (sd_raddr<8) magic <= {magic[55:0], sd_rdata};
                case (sd_raddr)
                8: version<=sd_rdata;
                9: track_count<=sd_rdata;
                10: ticks_per_q<=sd_rdata;
                11: flags<=sd_rdata;
                12: tempo_step[7:0]<=sd_rdata;
                13: tempo_step[15:8]<=sd_rdata;
                14: tempo_step[23:16]<=sd_rdata;
                15: tempo_step[31:24]<=sd_rdata;
                16: event_count[7:0]<=sd_rdata;
                17: event_count[15:8]<=sd_rdata;
                18: event_bytes[7:0]<=sd_rdata;
                19: event_bytes[15:8]<=sd_rdata;
                20: crc_expected[7:0]<=sd_rdata;
                21: crc_expected[15:8]<=sd_rdata;
                22: crc_expected[23:16]<=sd_rdata;
                23: crc_expected[31:24]<=sd_rdata;
                default: ;
                endcase
            end
            if (reload) begin
                state<=L_IDLE; load_done<=0; load_error<=0; load_err_code<=0;
                crc_work<=32'hFFFFFFFF; crc_busy<=0;
            end else case (state)
            L_IDLE: begin
                load_done<=0; load_error<=0; magic<=0; crc_work<=32'hFFFFFFFF; crc_busy<=0;
                if (sd_ready) begin
                    song_latched<=song_index;
                    loaded_song<=song_index;
                    sd_sector<=0; sd_start<=1; state<=L_MBR;
                end
            end
            L_MBR: begin
                if (sd_error) begin load_error<=1; load_err_code<=1; state<=L_BAD; end
                else state<=L_MBR_WAIT;
            end
            L_MBR_WAIT: begin
                if (sd_error) begin load_error<=1; load_err_code<=1; state<=L_BAD; end
                else if (sd_done) begin
                    score_lba <= {mbr_tail[11],mbr_tail[10],mbr_tail[9],mbr_tail[8]};
                    base_lba <= {mbr_tail[11],mbr_tail[10],mbr_tail[9],mbr_tail[8]};
                    base_valid <= 1'b1;
                    if ((mbr_tail[4]!=8'h7F)||(mbr_tail[16]!=8'h55)||(mbr_tail[17]!=8'hAA)) begin
                        load_error<=1; load_err_code<=2; state<=L_BAD;
                    end else begin
                        sd_sector <= {mbr_tail[11],mbr_tail[10],mbr_tail[9],mbr_tail[8]} + {30'd0, song_latched};
                        sd_start<=1; state<=L_SONG;
                    end
                end
            end
            L_SONG: begin
                if (sd_error) begin load_error<=1; load_err_code<=3; state<=L_BAD; end
                else state<=L_SONG_WAIT;
            end
            L_SONG_WAIT: begin
                if (sd_error) begin load_error<=1; load_err_code<=3; state<=L_BAD; end
                else if (sd_done) state<=L_CRC_WAIT;
            end
            L_CRC_WAIT: begin
                if (!crc_busy) begin
                    if ((magic!=64'h4D53434F52453100)||(version!=1)||(event_count==0)||
                        (track_count==0)||(event_count>120)||(event_bytes!=(event_count<<2))||
                        (event_end_now>10'd512)||((~crc_work)!=crc_expected)) begin
                        load_error<=1; load_err_code<=4; state<=L_BAD;
                    end else begin
                        body_crc<=~crc_work; load_done<=1; state<=L_GOOD;
                    end
                end
            end
            L_GOOD: if (!sd_ready) state<=L_BAD;
            L_BAD: load_done<=0;
            default: state<=L_IDLE;
            endcase
        end
    end
endmodule