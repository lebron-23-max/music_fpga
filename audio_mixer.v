`timescale 1ns / 1ps
//=============================================================================
// audio_mixer.v —— 可扩展音频混音器
//=============================================================================
//
// 输入是一根打包的 16 位有符号采样总线：
//     samples_in[(NUM_INPUTS*16)-1:0]
// 每个 16 位片段是一路声部（或一个音色引擎）的输出，索引 0 放在最低 16 位。
//
// 工作过程：
//   1) 把 NUM_INPUTS 路有符号采样相加，内部位宽自动加宽，保证不会溢出；
//   2) 可选地右移 OUTPUT_SHIFT 位做增益控制（声部很多时留出余量，避免削波）；
//   3) 结果超过 16 位范围就饱和截断，防止溢出翻转造成爆音。
//
// OUTPUT_SHIFT 说明：
//   0 = 不衰减（和钢琴引擎一致，声部多时靠饱和限幅）
//   1 = 除以 2      2 = 除以 4      3 = 除以 8 ...
//   32 复音的八音盒用 2，给同时发声的声部留出动态余量。
//=============================================================================
module audio_mixer #(
    parameter integer NUM_INPUTS   = 12,
    parameter integer INPUT_WIDTH  = 16,
    parameter integer OUTPUT_WIDTH = 16,
    parameter integer OUTPUT_SHIFT = 0
) (
    input  wire signed [NUM_INPUTS*INPUT_WIDTH-1:0] samples_in,
    output reg  signed [OUTPUT_WIDTH-1:0]            sample_out
);
    // 内部求和位宽：输入位宽 + log2(路数) + 1（多留一位符号位），保证 32 路以内不溢出。
    localparam integer SUM_WIDTH = INPUT_WIDTH + $clog2(NUM_INPUTS) + 1;

    reg signed [SUM_WIDTH-1:0] sum_value;
    reg signed [SUM_WIDTH-1:0] sum_scaled;
    integer i;

    // 逐路有符号累加。
    always @* begin
        sum_value = {SUM_WIDTH{1'b0}};
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            sum_value = sum_value +
                $signed(samples_in[i*INPUT_WIDTH +: INPUT_WIDTH]);
        end
    end

    // 可选的增益衰减（算术右移，保留符号）。
    always @* begin
        if (OUTPUT_SHIFT == 0)
            sum_scaled = sum_value;
        else
            sum_scaled = sum_value >>> OUTPUT_SHIFT;
    end

    // 饱和截断到输出位宽。
    always @* begin
        if (sum_scaled > ((1 <<< (OUTPUT_WIDTH-1)) - 1))
            sample_out = {1'b0, {(OUTPUT_WIDTH-1){1'b1}}};
        else if (sum_scaled < -(1 <<< (OUTPUT_WIDTH-1)))
            sample_out = {1'b1, {(OUTPUT_WIDTH-1){1'b0}}};
        else
            sample_out = sum_scaled[OUTPUT_WIDTH-1:0];
    end
endmodule