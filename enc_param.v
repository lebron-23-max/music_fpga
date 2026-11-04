`timescale 1ns / 1ps
//=============================================================================
// enc_param.v —— 旋转编码器（EC11）→ 8 位参数，自包含、零耦合、可复用
//=============================================================================
//
// 一、用途
//   把一路 EC11 增量式编码器的 A/B 两相解码成一个 8 位参数值。
//   模块内部自带“输入同步 + 正交解码 + 加减计数 + 限幅”，对外只有
//   clk/rst_n/A/B 和 value 五个端口，和任何音色或引擎都没有耦合，
//   任何需要“旋钮调参数”的模块都可以直接例化，不会互相影响。
//
// 二、EC11 模块接线
//     A 相   -> enc_a
//     B 相   -> enc_b
//     C(公共)-> 板子 GND
//     模块 VCC -> 3.3V（**不要接 5V**：模块的 A/B 带上拉电阻，接 5V 时输出
//                 摆幅是 0~5V，会打坏 GW5AT 的 3.3V IO）
//
// 三、参数
//     SIGNED = 0 : 输出无符号 0..255（ADSR 这类参数用）
//     SIGNED = 1 : 输出有符号 -128..127，中心 0（实时变调用）
//     INIT       : 复位/上电初值
//     STEP       : 每转动一格的变化量（1 = 一格 1 个 LSB）
//                  EC11 通常每格 4 个正交计数，所以 STEP=1 时转一格 ≈ 变 4
//
// 四、抗抖动
//   A/B 先过两级同步器，再做“四状态正交解码”：只有按
//   00→01→11→10→00（或反序）这种正确顺序变化才计数，
//   接触抖动造成的来回跳变会相互抵消，不会乱加。
//=============================================================================
module enc_param #(
    parameter integer SIGNED = 0,          // 0=无符号 0..255, 1=有符号 -128..127
    parameter [7:0]   INIT   = 8'd0,       // 初始值
    parameter [7:0]   STEP   = 8'd1        // 每格步进
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enc_a,               // A 相（异步输入）
    input  wire       enc_b,               // B 相（异步输入）
    output reg  [7:0] value                // 参数值
);
    //---------------- 两级同步 ----------------
    reg a1, a2, b1, b2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a1 <= 1'b1; a2 <= 1'b1;
            b1 <= 1'b1; b2 <= 1'b1;
        end else begin
            a1 <= enc_a;  a2 <= a1;
            b1 <= enc_b;  b2 <= b1;
        end
    end

    wire [1:0] state_now = {a2, b2};

    //---------------- 正交解码：产生加/减单拍脉冲 ----------------
    reg [1:0] prev;
    reg       up, down;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev <= 2'b11;                 // 空闲时 A/B 被上拉为高
            up   <= 1'b0;
            down <= 1'b0;
        end else begin
            up   <= 1'b0;
            down <= 1'b0;
            if (state_now != prev) begin
                // 顺时针 00->01->11->10 ；逆时针 00->10->11->01
                case ({prev, state_now})
                    4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: up   <= 1'b1;
                    4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: down <= 1'b1;
                    default: ;             // 非法跳变（抖动）不计
                endcase
                prev <= state_now;
            end
        end
    end

    //---------------- 加减计数 + 限幅 ----------------
    // 无符号路径（0..255）：用无符号加法，靠第 9 位（进位/借位）判断越界。
    //   注意不能对 0..255 的值做符号扩展，否则 ≥128 时会被当成负数。
    wire [8:0] inc_u = {1'b0, value} + {1'b0, STEP};
    wire [8:0] dec_u = {1'b0, value} - {1'b0, STEP};
    // 有符号路径（-128..127）：符号扩展后做有符号比较。
    wire signed [8:0] v_s    = $signed({value[7], value});
    wire signed [8:0] s_step = $signed({1'b0, STEP});
    wire signed [8:0] inc_s  = v_s + s_step;
    wire signed [8:0] dec_s  = v_s - s_step;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            value <= INIT;
        end else if (up) begin
            if (SIGNED != 0)
                value <= (inc_s > 9'sd127)  ? 8'h7F : inc_s[7:0];   // 上限 +127
            else
                value <= inc_u[8]           ? 8'hFF : inc_u[7:0];   // 上限 255
        end else if (down) begin
            if (SIGNED != 0)
                value <= (dec_s < -9'sd128) ? 8'h80 : dec_s[7:0];   // 下限 -128
            else
                value <= dec_u[8]           ? 8'h00 : dec_u[7:0];   // 下限 0
        end
    end

endmodule