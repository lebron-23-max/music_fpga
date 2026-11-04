`timescale 1ns / 1ps
//=============================================================================
// key_toggle.v —— 低有效按键 -> 同步、消抖后的翻转开关
//   按住 DEBOUNCE_CYCLES 后确认一次按下，状态翻转；松开后重新武装。
//   输入先经过两级同步，避免异步按键边沿直接驱动状态机。
//=============================================================================
module key_toggle #(
    parameter integer DEBOUNCE_CYCLES = 250_000,  // 5 ms @ 50 MHz
    parameter         INIT            = 1'b0,     // 上电/复位后的初始状态
    parameter         ARM_AFTER_RELEASE = 1'b0   // 1=上电必须先看到高电平才允许首次按下
) (
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,        // 低有效
    output reg  state         // 0=关，1=开
);
    localparam [19:0] DEBOUNCE_LAST = (DEBOUNCE_CYCLES > 0) ?
                                      (DEBOUNCE_CYCLES - 1) : 0;

    reg [19:0] cnt;
    reg        key_sync1;
    reg        key_sync2;
    reg        clean;
    reg        clean_d;
    reg        armed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt      <= 20'd0;
            key_sync1 <= 1'b1;
            key_sync2 <= 1'b1;
            clean    <= 1'b0;
            clean_d  <= 1'b0;
            armed    <= (ARM_AFTER_RELEASE == 0);
            state    <= INIT;
        end else begin
            key_sync1 <= key_n;
            key_sync2 <= key_sync1;

            // A released key arms the switch.  Test keys also use this to
            // ignore a pin that is held low at power-up / is not connected.
            if (key_sync2) begin
                cnt   <= 20'd0;
                clean <= 1'b0;
                if (!armed) armed <= 1'b1;
            end else if (!armed) begin
                cnt   <= 20'd0;
                clean <= 1'b0;
            end else if (cnt < DEBOUNCE_LAST) begin
                cnt   <= cnt + 20'd1;
                clean <= 1'b0;
            end else begin
                // Keep clean high while the key is held; clean_d guarantees
                // exactly one toggle per physical press.
                clean <= 1'b1;
            end

            clean_d <= clean;
            if (clean && !clean_d) state <= ~state;
        end
    end
endmodule