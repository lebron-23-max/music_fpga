`timescale 1ns / 1ps
// 115200 8N1 transmitter on a 50 MHz clock.
module uart_tx #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data_in,
    output reg        serial_out,
    output reg        busy
);
    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA  = 2'd2;
    localparam [1:0] STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            clk_count  <= 16'd0;
            bit_index  <= 3'd0;
            shift_reg  <= 8'd0;
            serial_out <= 1'b1;
            busy       <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    serial_out <= 1'b1;
                    clk_count  <= 16'd0;
                    bit_index  <= 3'd0;
                    if (start) begin
                        shift_reg <= data_in;
                        serial_out <= 1'b0;
                        busy       <= 1'b1;
                        state      <= START;
                    end
                end

                START: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count  <= 16'd0;
                        serial_out <= shift_reg[0];
                        bit_index  <= 3'd0;
                        state      <= DATA;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                DATA: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 16'd0;
                        if (bit_index == 3'd7) begin
                            serial_out <= 1'b1;
                            state      <= STOP;
                        end else begin
                            bit_index  <= bit_index + 3'd1;
                            serial_out <= shift_reg[bit_index + 3'd1];
                        end
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                STOP: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 16'd0;
                        busy      <= 1'b0;
                        state     <= IDLE;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule