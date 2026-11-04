`timescale 1ns / 1ps
// 115200 8N1 receiver, 16x-free mid-bit sampling on a 50 MHz clock.
module uart_rx #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       serial_in,
    output reg  [7:0] data_out,
    output reg        valid,
    output reg        framing_error
);
    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA  = 2'd2;
    localparam [1:0] STOP  = 2'd3;

    reg [1:0]  sync_ff;
    reg [1:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  shift_reg;

    wire serial_sync = sync_ff[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sync_ff <= 2'b11;
        else
            sync_ff <= {sync_ff[0], serial_in};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            clk_count     <= 16'd0;
            bit_index     <= 3'd0;
            shift_reg     <= 8'd0;
            data_out      <= 8'd0;
            valid         <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            valid         <= 1'b0;
            framing_error <= 1'b0;

            case (state)
                IDLE: begin
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    if (!serial_sync)
                        state <= START;
                end

                START: begin
                    if (clk_count == (CLKS_PER_BIT / 2 - 1)) begin
                        clk_count <= 16'd0;
                        if (!serial_sync)
                            state <= DATA;
                        else
                            state <= IDLE;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                DATA: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count      <= 16'd0;
                        shift_reg[bit_index] <= serial_sync;
                        if (bit_index == 3'd7)
                            state <= STOP;
                        else
                            bit_index <= bit_index + 3'd1;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                STOP: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count     <= 16'd0;
                        data_out      <= shift_reg;
                        valid         <= 1'b1;
                        framing_error <= (serial_sync != 1'b1);
                        state         <= IDLE;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule