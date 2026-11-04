`timescale 1ns / 1ps
//=============================================================================
// key_debounce.v
// 12 路低有效按键同步和消抖。
//
// 外部按键 key_n[11:0] 低有效，建议在 CST 中使用上拉。
// 输出 key_gate[11:0] 也是低有效，直接送入钢琴包络引擎。
//=============================================================================
module key_debounce #(
    parameter integer SCAN_DIV       = 50000, // 50 MHz 下约 1 ms
    parameter integer DEBOUNCE_TICKS = 4      // 约 4 ms 消抖
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] key_n,
    output wire [11:0] key_gate
);
    localparam [15:0] SCAN_DIV_LAST = SCAN_DIV - 1;
    localparam [15:0] DEBOUNCE_LAST = DEBOUNCE_TICKS - 1;

    reg [15:0] scan_cnt;
    reg [11:0] key_sync1;
    reg [11:0] key_sync2;
    reg [11:0] key_state;
    reg [15:0] debounce_cnt [0:11];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt <= 16'd0;
            key_sync1 <= 12'hFFF;
            key_sync2 <= 12'hFFF;
            key_state <= 12'hFFF;
            for (i = 0; i < 12; i = i + 1)
                debounce_cnt[i] <= 16'd0;
        end else begin
            key_sync1 <= key_n;
            key_sync2 <= key_sync1;

            if (scan_cnt == SCAN_DIV_LAST) begin
                scan_cnt <= 16'd0;

                for (i = 0; i < 12; i = i + 1) begin
                    if (key_sync2[i] != key_state[i]) begin
                        if (debounce_cnt[i] == DEBOUNCE_LAST) begin
                            key_state[i] <= key_sync2[i];
                            debounce_cnt[i] <= 16'd0;
                        end else begin
                            debounce_cnt[i] <= debounce_cnt[i] + 16'd1;
                        end
                    end else begin
                        debounce_cnt[i] <= 16'd0;
                    end
                end
            end else begin
                scan_cnt <= scan_cnt + 16'd1;
            end
        end
    end

    assign key_gate = key_state;

endmodule
