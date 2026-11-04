`timescale 1ns / 1ps
//=============================================================================
// key_pulse.v —— 低有效按键消抖后输出一个 clk 周期脉冲
//=============================================================================
module key_pulse #(
    parameter integer DEBOUNCE_CYCLES = 250_000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,
    output reg  pulse
);
    reg [19:0] cnt;
    reg clean;
    reg clean_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 20'd0;
            clean <= 1'b0;
            clean_d <= 1'b0;
            pulse <= 1'b0;
        end else begin
            pulse <= 1'b0;
            if (!key_n) begin
                if (cnt < DEBOUNCE_CYCLES[19:0]) cnt <= cnt + 20'd1;
            end else begin
                cnt <= 20'd0;
            end
            if (cnt >= DEBOUNCE_CYCLES[19:0] - 20'd1) clean <= 1'b1;
            else if (key_n) clean <= 1'b0;
            clean_d <= clean;
            if (clean && !clean_d) pulse <= 1'b1;
        end
    end
endmodule