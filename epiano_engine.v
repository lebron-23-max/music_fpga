`timescale 1ns / 1ps
//=============================================================================
// epiano_engine.v —— 电钢琴独立引擎封装
//=============================================================================
// 独立维护 50 个电钢琴声部的 TDM 算术；状态由顶层双端口 RAM 的 port0 保存，
// 波表 ROM 与弦乐引擎共享。
//=============================================================================
module epiano_engine #(
    parameter integer VOICE_COUNT = 50,
    parameter integer KEY_COUNT = 12
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               engine_active,
    input  wire [KEY_COUNT-1:0] key_gate,
    input  wire               test_mode,
    input  wire [16:0]        pitch_ratio,
    input  wire [16:0]        pitch_ratio_glide,
    input  wire               glide_active,
    input  wire [4:0]         glide_key,
    input  wire [7:0]         adsr_a,
    input  wire [7:0]         adsr_d,
    input  wire [7:0]         adsr_s,
    input  wire [7:0]         adsr_r,
    input  wire [74:0]        key_octave_bus,
    input  wire [199:0]       key_tune_bus,
    input  wire signed [15:0] wave_data,
    input  wire               wave_valid,
    output wire [14:0]        wave_addr,
    output wire               wave_req,
    output wire [6:0]         state_addr,
    output wire               state_we,
    output wire [76:0]        state_wdata,
    input  wire [76:0]        state_rdata,
    output wire signed [15:0] audio_sample,
    output wire [VOICE_COUNT-1:0] voices_busy,
    output wire               voices_any,
    output wire [7:0]         voices_sounding
);
    wavetable_engine #(.VOICE_COUNT(VOICE_COUNT), .KEY_COUNT(KEY_COUNT),
                      .COMPACT_KEYMAP(1), .COMPACT_SOUND_COUNT(1)) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick),
        .engine_active(engine_active),
        .timbre_kind(1'b0),
        .chord_mode(1'b0),
        .key_gate(key_gate),
        .test_mode(test_mode),
        .pitch_ratio(pitch_ratio),
        .pitch_ratio_glide(pitch_ratio_glide),
        .glide_active(glide_active),
        .glide_key(glide_key),
        .adsr_a(adsr_a),
        .adsr_d(adsr_d),
        .adsr_s(adsr_s),
        .adsr_r(adsr_r),
        .key_octave_bus(key_octave_bus),
        .key_tune_bus(key_tune_bus),
        .wave_data(wave_data),
        .wave_valid(wave_valid),
        .wave_addr(wave_addr),
        .wave_req(wave_req),
        .state_addr(state_addr),
        .state_we(state_we),
        .state_wdata(state_wdata),
        .state_rdata(state_rdata),
        .audio_sample(audio_sample),
        .voices_busy(voices_busy),
        .voices_any(voices_any),
        .voices_sounding(voices_sounding)
    );
endmodule