`timescale 1ns / 1ps
//=============================================================================
// music_board_top.v — physical top level for the new interaction PCB
//
// The original music_top remains parameter-compatible with the legacy bench
// and regression benches. This wrapper selects the new 25-key matrix panel and
// exposes only the pins used by music_pcb.enet plus the existing audio/SD/HDMI
// interfaces.
//=============================================================================
module music_board_top (
    input  wire        clk,

    output wire [4:0]  key_row_n,
    input  wire [4:0]  key_col_n,
    input  wire [5:0]  func_btn_n,
    input  wire [3:0]  enc_a,
    input  wire [3:0]  enc_b,
    input  wire        enc_shift_n,
    output wire        ws2812_din,

    input  wire        uart_rx,
    output wire        uart_tx,

    output wire        sd_cs_n,
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso,

    output wire        I2S_BCLK,
    output wire        I2S_LRCK,
    output wire        I2S_DIN,
    output wire        PA_EN,

    output wire [2:0]  tmds_data_p,
    output wire        tmds_clk_p
);
    music_top #(
        .USE_NEW_PANEL(1),
        .TEST_DEBOUNCE_CYCLES(250_000),
        .MATRIX_SCAN_CYCLES(10_000)
    ) u_music (
        .clk(clk),

        .key_row_n(key_row_n),
        .key_col_n(key_col_n),
        .func_btn_n(func_btn_n),
        .panel_enc_a(enc_a),
        .panel_enc_b(enc_b),
        .panel_enc_shift_n(enc_shift_n),
        .ws2812_din(ws2812_din),

        // Legacy bench pins are unused and held released/high.
        .key_n(12'hFFF),
        .timbre_sel(1'b1),
        .enc_a(5'h1F),
        .enc_b(5'h1F),
        .reverb_sw(1'b1),
        .delay_sw(1'b1),
        .chorus_btn_n(1'b1),
        .seq_btn_n(1'b1),
        .key1_n(1'b1),
        .vibrato_btn_n(1'b1),
        .pitch_up_n(1'b1),
        .pitch_down_n(1'b1),
        .test_piano_n(1'b1),
        .test_mb_n(1'b1),
        .test_ep_n(1'b1),
        .test_str_n(1'b1),

        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .sd_cs_n(sd_cs_n),
        .sd_sclk(sd_sclk),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .I2S_BCLK(I2S_BCLK),
        .I2S_LRCK(I2S_LRCK),
        .I2S_DIN(I2S_DIN),
        .PA_EN(PA_EN),
        .tmds_data_p(tmds_data_p),
        .tmds_clk_p(tmds_clk_p)
    );
endmodule