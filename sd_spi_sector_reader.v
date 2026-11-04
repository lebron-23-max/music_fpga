`timescale 1ns / 1ps
//=============================================================================
// sd_spi_sector_reader.v —— SD 卡 SPI 初始化与单扇区读取
//=============================================================================
// 支持 SDv2/SDHC（8 GB microSD 属于 SDHC）。初始化使用低速时钟，完成后
// 切到约 12.5 MHz。CMD17 按 512 字节块读取，数据以 rvalid/raddr/rdata 输出。
module sd_spi_sector_reader #(
    parameter [15:0] INIT_HALF_DIV = 16'd63,
    parameter [15:0] FAST_HALF_DIV = 16'd4
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         sd_cs_n,
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    input  wire        start,
    input  wire [31:0] sector_no,
    output reg         ready,
    output reg         sdhc,
    output reg         done,
    output reg         error,
    output reg  [3:0]  error_code,
    output wire [3:0]  state_dbg,
    output reg         rvalid,
    output reg  [8:0]  raddr,
    // Single-sector write path (CMD24).
    input  wire        write_start,
    input  wire [31:0] write_sector,
    input  wire        write_valid,
    input  wire [7:0]  write_data,
    output reg         write_ready,
    output reg         write_done,
    output reg         write_error,
    output reg  [7:0]  rdata
);
    localparam [4:0] S_POWER = 5'd0, S_POWER_BYTE = 5'd1, S_CMD_SETUP = 5'd2,
                     S_CMD_SEND = 5'd3, S_WAIT_R1 = 5'd4, S_RESP_BYTES = 5'd5,
                     S_CMD_GAP = 5'd6, S_DISPATCH = 5'd7, S_IDLE = 5'd8,
                     S_READ_TOKEN = 5'd9, S_READ_DATA = 5'd10, S_READ_CRC = 5'd11,
                     S_READ_END = 5'd12, S_ERROR = 5'd13,
                     S_WRITE_TOKEN = 5'd14, S_WRITE_DATA = 5'd15,
                     S_WRITE_SEND = 5'd16, S_WRITE_CRC = 5'd17,
                     S_WRITE_RESP = 5'd18, S_WRITE_BUSY = 5'd19,
                     S_WRITE_END = 5'd20, S_WRITE_CRC_CALC = 5'd21;
    localparam [19:0] WRITE_BUSY_LIMIT = 20'd500000;
    localparam [2:0] K_CMD0 = 3'd0, K_CMD8 = 3'd1, K_CMD55 = 3'd2,
                     K_ACMD41 = 3'd3, K_CMD58 = 3'd4, K_CMD16 = 3'd5,
                     K_READ = 3'd6, K_WRITE = 3'd7;
    reg [4:0] state;
    reg [5:0] cmd_idx;
    reg [2:0] cmd_kind;
    reg [31:0] cmd_arg;
    reg [47:0] cmd_word;
    reg [2:0] cmd_pos;
    reg [15:0] power_cnt;
    reg [7:0]  r1;
    reg [7:0] r1_tries, resp_left, init_retry;
    reg [31:0] resp_shift;
    reg [8:0] cmd8_ok, byte_idx;
    reg [15:0] token_tries;
    reg [1:0] crc_left;
    reg [8:0] write_idx;
    reg [1:0] write_crc_left;
    reg [2:0] write_resp_tries;
    reg [15:0] write_crc16;
    reg [19:0] write_busy_tries;
    reg [7:0] write_byte_q;
    reg [3:0] crc_bit_idx;
    reg [15:0] crc_bit_work;
    reg xfer_req;
    reg byte_issued;
    reg [7:0] tx_byte;
    wire byte_start, byte_busy, byte_done, spi_sclk, spi_mosi;
    wire [7:0] rx_byte;
    wire [15:0] half_div = ready ? FAST_HALF_DIV : INIT_HALF_DIV;
    assign byte_start = xfer_req && !byte_busy && !byte_issued;
    assign sd_sclk = spi_sclk;
    assign sd_mosi = spi_mosi;
    assign state_dbg = state[3:0];
    function [6:0] crc7_byte;
        input [6:0] crc_in;
        input [7:0] data;
        integer i;
        reg [6:0] c;
        begin
            c = crc_in;
            for (i = 7; i >= 0; i = i - 1)
                c = {c[5:0], 1'b0} ^ ((c[6] ^ data[i]) ? 7'h09 : 7'h00);
            crc7_byte = c;
        end
    endfunction
    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] data;
        integer i;
        reg [15:0] c;
        begin
            c = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16_byte = c;
        end
    endfunction
    function [47:0] make_cmd;
        input [5:0] idx;
        input [31:0] arg;
        reg [6:0] c;
        reg [7:0] b0;
        begin
            b0 = {2'b01, idx};
            c = 7'd0;
            c = crc7_byte(c, b0);
            c = crc7_byte(c, arg[31:24]);
            c = crc7_byte(c, arg[23:16]);
            c = crc7_byte(c, arg[15:8]);
            c = crc7_byte(c, arg[7:0]);
            make_cmd = {b0, arg, c, 1'b1};
        end
    endfunction
    wire [31:0] resp_shift_next = {resp_shift[23:0], rx_byte};
    spi_byte_master u_spi_byte (
        .clk(clk), .rst_n(rst_n), .start(byte_start), .half_div(half_div),
        .tx_data(tx_byte), .rx_data(rx_byte), .sclk(spi_sclk), .mosi(spi_mosi),
        .miso(sd_miso), .busy(byte_busy), .done(byte_done)
    );    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_POWER; sd_cs_n <= 1'b1; ready <= 1'b0; sdhc <= 1'b0;
            done <= 1'b0; error <= 1'b0; error_code <= 4'd0;
            rvalid <= 1'b0; raddr <= 9'd0; rdata <= 8'd0;
            cmd_idx <= 6'd0; cmd_kind <= K_CMD0; cmd_arg <= 32'd0;
            cmd_word <= 48'd0; cmd_pos <= 3'd0; power_cnt <= 16'd0;
            r1 <= 8'hFF; r1_tries <= 8'd0; resp_left <= 8'd0; resp_shift <= 32'd0;
            cmd8_ok <= 9'd0; init_retry <= 8'd0; token_tries <= 16'd0;
            crc_left <= 2'd0; byte_idx <= 9'd0; write_idx <= 9'd0;
            write_crc_left <= 2'd0; write_resp_tries <= 3'd0;
            write_crc16 <= 16'd0; write_busy_tries <= 20'd0;
            write_byte_q <= 8'd0; crc_bit_idx <= 4'd0; crc_bit_work <= 16'd0;
            xfer_req <= 1'b0; byte_issued <= 1'b0; tx_byte <= 8'hFF;
            write_ready <= 1'b0; write_done <= 1'b0; write_error <= 1'b0;
        end else begin
            done <= 1'b0; error <= 1'b0; rvalid <= 1'b0; write_done <= 1'b0;
            if (byte_done) begin xfer_req <= 1'b0; byte_issued <= 1'b0; end
            else if (byte_start) byte_issued <= 1'b1;
            case (state)
            S_POWER: begin
                sd_cs_n <= 1'b1; power_cnt <= 16'd0; state <= S_POWER_BYTE;
            end
            S_POWER_BYTE: begin
                sd_cs_n <= 1'b1;
                if (byte_done) begin
                    if (power_cnt == 16'd9) begin
                        cmd_idx <= 6'd0; cmd_kind <= K_CMD0; cmd_arg <= 32'd0;
                        state <= S_CMD_SETUP;
                    end else power_cnt <= power_cnt + 16'd1;
                end else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end
            S_CMD_SETUP: begin
                sd_cs_n <= 1'b0; cmd_word <= make_cmd(cmd_idx, cmd_arg);
                cmd_pos <= 3'd0; xfer_req <= 1'b0; state <= S_CMD_SEND;
            end
            S_CMD_SEND: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    if (cmd_pos == 3'd5) begin r1_tries <= 8'd0; state <= S_WAIT_R1; end
                    else cmd_pos <= cmd_pos + 3'd1;
                end else if (!xfer_req) begin
                    tx_byte <= cmd_word >> (8 * (5 - cmd_pos)); xfer_req <= 1'b1;
                end
            end
            S_WAIT_R1: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    if (rx_byte != 8'hFF) begin
                        r1 <= rx_byte;
                        if (cmd_kind == K_READ) begin
                            if (rx_byte == 8'h00) begin token_tries <= 16'd0; state <= S_READ_TOKEN; end
                            else begin error <= 1'b1; error_code <= 4'd4; state <= S_ERROR; end
                        end else if (cmd_kind == K_WRITE) begin
                            if (rx_byte == 8'h00) begin write_idx <= 9'd0; state <= S_WRITE_TOKEN; end
                            else begin error <= 1'b1; write_error <= 1'b1; error_code <= 4'd9; state <= S_ERROR; end
                        end else begin
                            resp_shift <= 32'd0;
                            if ((cmd_kind == K_CMD8) || (cmd_kind == K_CMD58)) begin
                                resp_left <= 8'd4; state <= S_RESP_BYTES;
                            end else state <= S_CMD_GAP;
                        end
                    end else if (r1_tries == 8'd15) begin
                        error <= 1'b1; error_code <= 4'd1; state <= S_ERROR;
                    end else r1_tries <= r1_tries + 8'd1;
                end else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end
            S_RESP_BYTES: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    resp_shift <= resp_shift_next;
                    if (resp_left == 8'd1) begin
                        if (cmd_kind == K_CMD8) cmd8_ok <= (resp_shift_next[11:0] == 12'h1AA);
                        state <= S_CMD_GAP;
                    end else resp_left <= resp_left - 8'd1;
                end else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end
            S_CMD_GAP: begin
                sd_cs_n <= 1'b1;
                if (byte_done) state <= S_DISPATCH;
                else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end            S_DISPATCH: begin
                sd_cs_n <= 1'b1;
                case (cmd_kind)
                K_CMD0: begin
                    if (r1[0]) begin
                        cmd_idx <= 6'd8; cmd_kind <= K_CMD8; cmd_arg <= 32'h0000_01AA;
                        state <= S_CMD_SETUP;
                    end else begin error <= 1'b1; error_code <= 4'd6; state <= S_ERROR; end
                end
                K_CMD8: begin
                    if ((r1 == 8'h01) && cmd8_ok[0]) begin
                        cmd_idx <= 6'd55; cmd_kind <= K_CMD55; cmd_arg <= 32'd0;
                        state <= S_CMD_SETUP;
                    end else begin error <= 1'b1; error_code <= 4'd2; state <= S_ERROR; end
                end
                K_CMD55: begin
                    if (r1[0]) begin
                        cmd_idx <= 6'd41; cmd_kind <= K_ACMD41; cmd_arg <= 32'h4000_0000;
                        state <= S_CMD_SETUP;
                    end else begin error <= 1'b1; error_code <= 4'd7; state <= S_ERROR; end
                end
                K_ACMD41: begin
                    if ((r1 == 8'h00)) begin
                        cmd_idx <= 6'd58; cmd_kind <= K_CMD58; cmd_arg <= 32'd0;
                        state <= S_CMD_SETUP;
                    end else if (init_retry == 8'd199) begin
                        error <= 1'b1; error_code <= 4'd3; state <= S_ERROR;
                    end else begin
                        init_retry <= init_retry + 8'd1;
                        cmd_idx <= 6'd55; cmd_kind <= K_CMD55; cmd_arg <= 32'd0;
                        state <= S_CMD_SETUP;
                    end
                end
                K_CMD58: begin
                    if ((r1 == 8'h00) && resp_shift[30]) begin sdhc <= 1'b1; ready <= 1'b1; state <= S_IDLE; end
                    else begin
                        cmd_idx <= 6'd16; cmd_kind <= K_CMD16; cmd_arg <= 32'h0000_0200;
                        state <= S_CMD_SETUP;
                    end
                end
                K_CMD16: begin
                    if (r1 == 8'h00) begin sdhc <= 1'b0; ready <= 1'b1; state <= S_IDLE; end
                    else begin error <= 1'b1; error_code <= 4'd8; state <= S_ERROR; end
                end
                default: state <= S_IDLE;
                endcase
            end
            S_IDLE: begin
                sd_cs_n <= 1'b1;
                if (write_start && ready) begin
                    ready <= 1'b0;
                    write_ready <= 1'b0;
                    write_error <= 1'b0;
                    write_idx <= 9'd0;
                    cmd_idx <= 6'd24; cmd_kind <= K_WRITE;
                    cmd_arg <= sdhc ? write_sector : (write_sector << 9);
                    state <= S_CMD_SETUP;
                end else if (start && ready) begin
                    cmd_idx <= 6'd17; cmd_kind <= K_READ;
                    cmd_arg <= sdhc ? sector_no : (sector_no << 9);
                    state <= S_CMD_SETUP;
                end
            end
            S_WRITE_TOKEN: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    write_idx <= 9'd0;
                    write_crc16 <= 16'd0;
                    write_busy_tries <= 20'd0;
                    write_ready <= 1'b1;
                    state <= S_WRITE_DATA;
                end else if (!xfer_req) begin
                    tx_byte <= 8'hFE; xfer_req <= 1'b1;
                end
            end
            S_WRITE_DATA: begin
                sd_cs_n <= 1'b0;
                write_ready <= 1'b1;
                if (write_valid) begin
                    tx_byte <= write_data;
                    write_byte_q <= write_data;
                    write_ready <= 1'b0;
                    xfer_req <= 1'b1;
                    state <= S_WRITE_SEND;
                end
            end
            S_WRITE_SEND: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    // Compute the 8-bit data CRC one bit per clock.  This
                    // removes the long combinational CRC path that caused
                    // setup violations at 50 MHz.
                    crc_bit_work <= write_crc16 ^ {write_byte_q, 8'h00};
                    crc_bit_idx <= 4'd0;
                    state <= S_WRITE_CRC_CALC;
                end else if (!xfer_req) begin
                    tx_byte <= 8'hFF; xfer_req <= 1'b1;
                end
            end
            S_WRITE_CRC_CALC: begin
                if (crc_bit_idx == 4'd7) begin
                    write_crc16 <= crc_bit_work[15] ?
                        ((crc_bit_work << 1) ^ 16'h1021) : (crc_bit_work << 1);
                    if (write_idx == 9'd511) begin
                        write_crc_left <= 2'd2;
                        state <= S_WRITE_CRC;
                    end else begin
                        write_idx <= write_idx + 9'd1;
                        state <= S_WRITE_DATA;
                    end
                end else begin
                    crc_bit_work <= crc_bit_work[15] ?
                        ((crc_bit_work << 1) ^ 16'h1021) : (crc_bit_work << 1);
                    crc_bit_idx <= crc_bit_idx + 4'd1;
                end
            end
            S_WRITE_CRC: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    if (write_crc_left == 2'd1) begin
                        write_resp_tries <= 3'd0;
                        state <= S_WRITE_RESP;
                    end else begin
                        write_crc_left <= write_crc_left - 2'd1;
                    end
                end else if (!xfer_req) begin
                    tx_byte <= (write_crc_left == 2'd2) ? write_crc16[15:8] : write_crc16[7:0];
                    xfer_req <= 1'b1;
                end
            end
            S_WRITE_RESP: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    if (rx_byte[4:0] == 5'b00101) begin
                        write_busy_tries <= 20'd0;
                        state <= S_WRITE_BUSY;
                    end else if ((rx_byte == 8'hFF) && (write_resp_tries < 3'd7)) begin
                        write_resp_tries <= write_resp_tries + 3'd1;
                    end else begin
                        error <= 1'b1; write_error <= 1'b1; error_code <= 4'd10;
                        state <= S_ERROR;
                    end
                end else if (!xfer_req) begin
                    tx_byte <= 8'hFF; xfer_req <= 1'b1;
                end
            end
            S_WRITE_BUSY: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    if (rx_byte == 8'hFF) state <= S_WRITE_END;
                    else if (write_busy_tries == WRITE_BUSY_LIMIT) begin
                        error <= 1'b1; write_error <= 1'b1; error_code <= 4'd11;
                        state <= S_ERROR;
                    end else begin
                        write_busy_tries <= write_busy_tries + 20'd1;
                    end
                end else if (!xfer_req) begin
                    tx_byte <= 8'hFF; xfer_req <= 1'b1;
                end
            end
            S_WRITE_END: begin
                sd_cs_n <= 1'b1;
                if (byte_done) begin
                    write_ready <= 1'b0;
                    write_done <= 1'b1;
                    ready <= 1'b1;
                    state <= S_IDLE;
                end else if (!xfer_req) begin
                    tx_byte <= 8'hFF; xfer_req <= 1'b1;
                end
            end
            S_READ_TOKEN: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    if (rx_byte == 8'hFE) begin byte_idx <= 9'd0; state <= S_READ_DATA; end
                    else if (token_tries == 16'd4095) begin
                        error <= 1'b1; error_code <= 4'd5; state <= S_ERROR;
                    end else token_tries <= token_tries + 16'd1;
                end else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end
            S_READ_DATA: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    rvalid <= 1'b1; raddr <= byte_idx; rdata <= rx_byte;
                    if (byte_idx == 9'd511) begin crc_left <= 2'd2; state <= S_READ_CRC; end
                    else byte_idx <= byte_idx + 9'd1;
                end else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end
            S_READ_CRC: begin
                sd_cs_n <= 1'b0;
                if (byte_done) begin
                    if (crc_left == 2'd1) state <= S_READ_END;
                    else crc_left <= crc_left - 2'd1;
                end else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end
            S_READ_END: begin
                sd_cs_n <= 1'b1;
                if (byte_done) begin ready <= 1'b1; done <= 1'b1; state <= S_IDLE; end
                else if (!xfer_req) begin tx_byte <= 8'hFF; xfer_req <= 1'b1; end
            end
            S_ERROR: begin
                sd_cs_n <= 1'b1; ready <= 1'b0; xfer_req <= 1'b0;
                if (start) state <= S_POWER;
            end
            default: state <= S_POWER;
            endcase
        end
    end
endmodule