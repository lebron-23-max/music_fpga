`timescale 1ns / 1ps
//=============================================================================
// piano_envelope_shared.v
// 32 音测试模式的共享包络：所有声部同时触发，因此主弦和副弦各只保留
// 一套包络状态，计算完成后复制到 32 路主弦/副弦包络总线上。
//=============================================================================
module piano_envelope_shared (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          sample_tick,
    input  wire [7:0]    adsr_a,
    input  wire [7:0]    adsr_d,
    input  wire [7:0]    adsr_s,
    input  wire [7:0]    adsr_r,
    output wire [1023:0] env_bus
);
    wire [31:0] pair_bus;

    piano_envelope_bank #(
        .NUM_VOICES(1)
    ) u_shared_lane (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick),
        .voice_gate(1'b0),       // 测试模式全部按键同时有效
        .adsr_a(adsr_a),
        .adsr_d(adsr_d),
        .adsr_s(adsr_s),
        .adsr_r(adsr_r),
        .env_bus(pair_bus)
    );

    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : g_copy
            assign env_bus[(2*g)*16 +: 16]   = pair_bus[15:0];
            assign env_bus[(2*g+1)*16 +: 16] = pair_bus[31:16];
        end
    endgenerate
endmodule