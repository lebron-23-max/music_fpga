`timescale 1ns / 1ps
//=============================================================================
// music_box_vstate.v —— 单个声部的状态寄存器（被打包进一条状态总线）
//=============================================================================
// 只保存状态，不做任何运算：
//   pos  (24) 相位（Q12）
//   env  (24) 包络累加器（电平 = env[23:8]）
//   st   ( 3) ADSR 状态
//   inc  (24) 基准相位增量
//   bank ( 1) 波表 bank
//   key  ( 5) 触发它的按键（5'h1F = 测试/无）
// 共 81 位。50 个实例各自独立，engine 用“扫描地址 + 多路选择”读写，
// 这样综合器不会把它当成存储器（移位寄存器曾被误映射成 BSRAM，
// 导致上板行为和仿真不一致）。
//=============================================================================
module music_box_vstate (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,        // 1 = 写入 state_i
    input  wire [80:0] state_i,
    output wire [80:0] state_o
);
    reg [23:0] pos;
    reg [23:0] env;
    reg [2:0]  st;
    reg [23:0] inc;
    reg        bank;
    reg [4:0]  key;

    assign state_o = {key, bank, inc, st, env, pos};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            {key, bank, inc, st, env, pos} <= {5'h1F, 1'b0, 24'd0, 3'd0, 24'd0, 24'd0};
        else if (load)
            {key, bank, inc, st, env, pos} <= state_i;
    end
endmodule