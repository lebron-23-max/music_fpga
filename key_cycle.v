`timescale 1ns / 1ps
//=============================================================================
// key_cycle.v —— 低有效按键 -> 4 档循环选择
//=============================================================================
// 按住约 5 ms 后确认一次按下，状态 0→1→2→3→0。用于四种音色切换。
//=============================================================================
module key_cycle #(
    parameter integer DEBOUNCE_CYCLES = 250_000,
    parameter [1:0]   INIT            = 2'd0,
    parameter [1:0]   MAX             = 2'd3
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_n,
    output reg  [1:0] state
);
    reg [19:0] cnt;
    reg        clean;
    reg        clean_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 20'd0;
            clean   <= 1'b0;
            clean_d <= 1'b0;
            state   <= INIT;
        end else begin
            if (!key_n) begin
                if (cnt < DEBOUNCE_CYCLES[19:0]) cnt <= cnt + 20'd1;
            end else begin
                cnt <= 20'd0;
            end

            if (cnt >= DEBOUNCE_CYCLES[19:0] - 20'd1) clean <= 1'b1;
            else if (key_n)                            clean <= 1'b0;

            clean_d <= clean;
            if (clean && !clean_d) state <= (state == MAX) ? 2'd0 : (state + 2'd1);
        end
    end
endmodule