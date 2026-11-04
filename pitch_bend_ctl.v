`timescale 1ns / 1ps
//=============================================================================
// pitch_bend_ctl.v —— 两个低有效按键的实时升降调控制面
//   每按一次步进 1，步进值对应 50 cents；-24..+24 即 -1200..+1200 cents。
//   两个按键同时按下（消抖后）立即回到 0，确保能准确恢复原调。
//=============================================================================
module pitch_bend_ctl #(
    parameter integer DEBOUNCE_CYCLES = 250_000
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              btn_up_n,
    input  wire              btn_down_n,
    output reg signed [5:0]  pitch_step
);
    localparam signed [5:0] STEP_MIN = -6'sd24;
    localparam signed [5:0] STEP_MAX =  6'sd24;
    reg [19:0] cnt_up, cnt_down;
    reg        up_clean, down_clean;
    reg        up_d, down_d;
    wire up_raw   = ~btn_up_n;
    wire down_raw = ~btn_down_n;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_up <= 20'd0; cnt_down <= 20'd0;
            up_clean <= 1'b0; down_clean <= 1'b0;
            up_d <= 1'b0; down_d <= 1'b0; pitch_step <= 6'sd0;
        end else begin
            if (up_raw) begin
                if (cnt_up < DEBOUNCE_CYCLES[19:0]) cnt_up <= cnt_up + 20'd1;
            end else begin
                cnt_up <= 20'd0; up_clean <= 1'b0;
            end
            if (down_raw) begin
                if (cnt_down < DEBOUNCE_CYCLES[19:0]) cnt_down <= cnt_down + 20'd1;
            end else begin
                cnt_down <= 20'd0; down_clean <= 1'b0;
            end
            if (cnt_up >= DEBOUNCE_CYCLES[19:0]) up_clean <= 1'b1;
            if (cnt_down >= DEBOUNCE_CYCLES[19:0]) down_clean <= 1'b1;
            up_d <= up_clean; down_d <= down_clean;
            if (up_clean && down_clean) begin
                pitch_step <= 6'sd0;
            end else if (up_clean && !up_d) begin
                if (pitch_step < STEP_MAX) pitch_step <= pitch_step + 6'sd1;
            end else if (down_clean && !down_d) begin
                if (pitch_step > STEP_MIN) pitch_step <= pitch_step - 6'sd1;
            end
        end
    end
endmodule
