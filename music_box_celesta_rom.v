`timescale 1ns / 1ps
//=============================================================================
// music_box_celesta_rom.v —— 八音盒的波形只读存储器
//=============================================================================
//
// 一、这个模块是什么
//   它是一块只读存储器（ROM），只保存 16 位有符号波形采样：
//     celesta_rom[0..3965]
//         地址    0..2607  -> C5 波表（根音 523.629906 Hz，attack 1998 + loop 610）
//         地址 2608..3965  -> C6 波表（根音 1046.832025 Hz，attack  838 + loop 520）
//
//   综合工具会把这个数组映射到芯片内部的 BSRAM 存储块上，
//   本设计只读不写，数据在 initial 块里一次性填入。
//
// 二、为什么写成“寄存器输出”（为什么读数据会晚一拍）
//   这里写的是：
//       always @(posedge clk) wave_data <= celesta_rom[wave_addr];
//   含义是“这一拍给地址，下一拍数据才出现在输出端口”，这叫做同步读。
//   好处是时序稳定、能映射到 BSRAM 自带的输出寄存器，主频容易做高。
//
// 三、两个 bank 是怎么区分的
//   ROM 自己并不认识 bank，它只认 12 位地址。
//   引擎把 bank 起始地址和表内索引相加后送入 wave_addr，于是
//   C5 的音落在 0..2607，C6 的音落在 2608..3965。
//
// 四、数据从哪来
//   由脚本 wavetables/generate_celesta_bank.py 从 nv32 的 C 源文件解析生成，
//   输出为 music_box_celesta_bank.vh。
//   该 .vh 只是数据填充块，不是独立模块，所以不能写进 music_1.gprj，
//   否则 Gowin 会把它当独立源文件解析并报语法错。
//
// 说明：八音盒包络由 music_box_engine.v 实时计算，不使用包络表。
//=============================================================================
module music_box_celesta_rom (
    input  wire               clk,
    input  wire [11:0]        wave_addr,  // 波表地址（有效范围 0..3965）
    output reg  signed [15:0] wave_data   // 波形采样输出（下一拍有效）
);
    reg signed [15:0] celesta_rom [0:3965];

    // 上电时把波形表内容写进去，内容来自脚本生成的 .vh 数据文件。
    initial begin
`include "music_box_celesta_bank.vh"
    end

    // 同步读：地址与数据之间隔一拍。
    always @(posedge clk) begin
        wave_data <= celesta_rom[wave_addr];
    end

endmodule