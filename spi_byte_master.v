`timescale 1ns / 1ps
//=============================================================================
// spi_byte_master.v —— 8-bit SPI 字节发送/接收器
//=============================================================================
// 主机在 SCLK 下降沿更新 MOSI，在上升沿采样 MISO。
module spi_byte_master (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [15:0] half_div,
    input  wire [7:0]  tx_data,
    output reg  [7:0]  rx_data,
    output reg         sclk,
    output reg         mosi,
    input  wire        miso,
    output reg         busy,
    output reg         done
);
    reg [15:0] div_cnt;
    reg [15:0] half_div_q;
    reg [2:0]  bit_idx;
    reg        phase;
    reg [7:0]  tx_shift;
    reg        miso_meta, miso_sync;

    always @(posedge clk) begin
        miso_meta <= miso;
        miso_sync <= miso_meta;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= 16'd0;
            half_div_q <= 16'd2;
            bit_idx   <= 3'd0;
            phase     <= 1'b0;
            tx_shift  <= 8'd0;
            rx_data   <= 8'd0;
            sclk      <= 1'b0;
            mosi      <= 1'b1;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                sclk <= 1'b0;
                mosi <= 1'b1;
                if (start) begin
                    half_div_q <= (half_div < 16'd2) ? 16'd2 : half_div;
                    tx_shift   <= tx_data;
                    rx_data    <= 8'd0;
                    bit_idx    <= 3'd7;
                    phase      <= 1'b0;
                    div_cnt    <= 16'd0;
                    mosi       <= tx_data[7];
                    busy       <= 1'b1;
                end
            end else begin
                if (div_cnt + 16'd1 < half_div_q) begin
                    div_cnt <= div_cnt + 16'd1;
                end else begin
                    div_cnt <= 16'd0;
                    if (!phase) begin
                        sclk <= 1'b1;
                        rx_data[bit_idx] <= miso_sync;
                        phase <= 1'b1;
                    end else begin
                        sclk <= 1'b0;
                        if (bit_idx == 3'd0) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                            mosi    <= tx_shift[bit_idx - 3'd1];
                            phase   <= 1'b0;
                        end
                    end
                end
            end
        end
    end
endmodule