`timescale 1ns / 1ps
//=============================================================================
// interaction_panel.v — 5x5 note matrix, six function keys, four EC11 controls
//
// Function-key map from music_pcb.enet:
//   func_btn_n[0] = U56 / F14 : layer shift (toggle)
//   func_btn_n[1] = U57 / E17
//   func_btn_n[2] = U55 / D15
//   func_btn_n[3] = U61 / F16
//   func_btn_n[4] = U60 / F13
//   func_btn_n[5] = U59 / D14
//
// Layer 0: timbre, reverb, delay, chorus, vibrato
// Layer 1: piano/MB/EP/strings 72-voice tests; U59 is reserved
// Layer 2: SD song next / SD play-stop, remaining three keys reserved
// Layer 3: sequencer screen toggle + four track-confirm keys
//
// Encoder shift C15 cycles four layers:
//   0: A/D/S/R
//   1: volume, pitch, reverb size, reverb mix
//   2: delay time, delay feedback, chorus rate, chorus depth
//   3: 16-step sequencer edit controls
//=============================================================================
module interaction_panel #(
    parameter integer SCAN_CYCLES          = 10_000,
    parameter integer MATRIX_DEBOUNCE      = 5,
    parameter integer BUTTON_DEBOUNCE_CLKS = 250_000,
    parameter integer GUIDE_LONG_CYCLES = 20_000_000,
    parameter integer ENC_FAST_HOLD_CYCLES = 1_000_000,
    parameter [7:0]   ENC_FAST_STEP = 8'd8
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [4:0]  key_row_n,
    input  wire [4:0]  key_col_n,
    output wire [24:0] key_pressed,

    input  wire [5:0]  func_btn_n,
    input  wire [3:0]  enc_a,
    input  wire [3:0]  enc_b,
    input  wire        enc_shift_n,
    input  wire        guide_done,

    output reg  [1:0]  timbre_code,
    output reg         reverb_en,
    output reg         delay_en,
    output reg         chorus_en,
    output reg         vibrato_en,
    output reg         test_piano_en,
    output reg         test_mb_en,
    output reg         test_ep_en,
    output reg         test_str_en,
    output reg         guide_en,
    output reg         led_note_en,

    output reg         func_shift,
    output reg  [1:0]  func_layer,
    output reg         song_next_pulse,
    output reg         song_play_pulse,
    output wire [1:0]  enc_layer,
    output reg         seq_page_toggle,
    output reg  [3:0]  seq_confirm_pulse,
    output wire [3:0]  seq_enc_up,
    output wire [3:0]  seq_enc_down,
    output reg  [7:0]  adsr_a,
    output reg  [7:0]  adsr_d,
    output reg  [7:0]  adsr_s,
    output reg  [7:0]  adsr_r,
    output reg  [7:0]  master_volume,
    output reg  signed [5:0] pitch_step,
    output reg  [7:0]  reverb_size,
    output reg  [7:0]  reverb_mix,
    output reg  [7:0]  delay_time,
    output reg  [7:0]  delay_feedback,
    output reg  [7:0]  chorus_rate,
    output reg  [7:0]  chorus_depth,

    output wire [2:0]  scan_row_dbg
);
    //-------------------------------------------------------------------------
    // Note matrix
    //-------------------------------------------------------------------------
    key_matrix_5x5 #(
        .SCAN_CYCLES(SCAN_CYCLES),
        .DEBOUNCE_FRAMES(MATRIX_DEBOUNCE)
    ) u_matrix (
        .clk(clk), .rst_n(rst_n),
        .row_n(key_row_n), .col_n(key_col_n),
        .key_pressed(key_pressed),
        .scan_row_dbg(scan_row_dbg)
    );

    //-------------------------------------------------------------------------
    // Function buttons: debounced single pulses
    //-------------------------------------------------------------------------
    wire [5:0] func_pulse;
    genvar gb;
    generate
        for (gb = 0; gb < 6; gb = gb + 1) begin : g_btn
            key_pulse #(.DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CLKS)) u_pulse (
                .clk(clk), .rst_n(rst_n),
                .key_n(func_btn_n[gb]),
                .pulse(func_pulse[gb])
            );
        end
    endgenerate

    wire guide_key_short;
    wire guide_key_long;
    key_long_press #(
        .DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CLKS),
        .LONG_CYCLES(GUIDE_LONG_CYCLES)
    ) u_guide_key (
        .clk(clk), .rst_n(rst_n), .key_n(func_btn_n[5]),
        .short_pulse(guide_key_short), .long_pulse(guide_key_long)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            func_shift      <= 1'b0;
            func_layer      <= 2'd0;
            song_next_pulse <= 1'b0;
            song_play_pulse <= 1'b0;
            seq_page_toggle <= 1'b0;
            seq_confirm_pulse <= 4'd0;
            timbre_code     <= 2'd0;
            reverb_en       <= 1'b1;
            delay_en        <= 1'b0;
            chorus_en       <= 1'b0;
            vibrato_en      <= 1'b0;
            test_piano_en   <= 1'b0;
            test_mb_en      <= 1'b0;
            test_ep_en      <= 1'b0;
            test_str_en     <= 1'b0;
            guide_en        <= 1'b0;
            led_note_en     <= 1'b1;
        end else begin
            song_next_pulse <= 1'b0;
            song_play_pulse <= 1'b0;
            seq_page_toggle <= 1'b0;
            seq_confirm_pulse <= 4'd0;
            if (guide_done) guide_en <= 1'b0;

            if (func_pulse[0]) begin
                func_layer <= (func_layer == 2'd3) ? 2'd0 : func_layer + 2'd1;
                func_shift <= (func_layer != 2'd3);
            end

            case (func_layer)
            2'd0: begin
                if (func_pulse[1]) timbre_code <= (timbre_code == 2'd3) ? 2'd0 : timbre_code + 2'd1;
                if (func_pulse[2]) reverb_en   <= ~reverb_en;
                if (func_pulse[3]) delay_en    <= ~delay_en;
                if (func_pulse[4]) chorus_en   <= ~chorus_en;
                if (func_pulse[5]) vibrato_en  <= ~vibrato_en;
            end
            2'd1: begin
                if (func_pulse[1]) test_piano_en <= ~test_piano_en;
                if (func_pulse[2]) test_mb_en    <= ~test_mb_en;
                if (func_pulse[3]) test_ep_en    <= ~test_ep_en;
                if (func_pulse[4]) test_str_en   <= ~test_str_en;
                if (guide_key_short) led_note_en <= ~led_note_en;
                if (guide_key_long && !guide_done) guide_en <= ~guide_en;
            end
            2'd2: begin
                if (func_pulse[1]) song_next_pulse <= 1'b1;
                if (func_pulse[2]) song_play_pulse <= 1'b1;
                // U61/U60/U59 intentionally reserved in this layer.
            end
            default: begin
                if (func_pulse[1]) seq_page_toggle <= 1'b1;
                if (func_pulse[2]) seq_confirm_pulse[0] <= 1'b1;
                if (func_pulse[3]) seq_confirm_pulse[1] <= 1'b1;
                if (func_pulse[4]) seq_confirm_pulse[2] <= 1'b1;
                if (func_pulse[5]) seq_confirm_pulse[3] <= 1'b1;
            end
            endcase

            // Guide playback removed; U59 remains reserved for future use.
        end
    end

    //-------------------------------------------------------------------------
    // Encoder shift layer
    //-------------------------------------------------------------------------
    key_cycle #(
        .DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CLKS),
        .INIT(2'd0),
        .MAX(2'd3)
    ) u_enc_layer (
        .clk(clk), .rst_n(rst_n),
        .key_n(enc_shift_n), .state(enc_layer)
    );

    //-------------------------------------------------------------------------
    // Four independent quadrature decoders
    //-------------------------------------------------------------------------
    generate
        for (gb = 0; gb < 4; gb = gb + 1) begin : g_enc
            enc_detent u_dec (
                .clk(clk), .rst_n(rst_n),
                .enc_a(enc_a[gb]), .enc_b(enc_b[gb]),
                .detent_up(seq_enc_up[gb]), .detent_down(seq_enc_down[gb])
            );
        end
    endgenerate

    reg [20:0] enc_activity_cnt;
    wire enc_any = (|seq_enc_up) || (|seq_enc_down);
    wire enc_fast = enc_activity_cnt < ENC_FAST_HOLD_CYCLES;
    wire [7:0] enc_step = enc_fast ? ENC_FAST_STEP : 8'd1;
    wire signed [5:0] pitch_step_inc = enc_fast ? 6'sd4 : 6'sd1;

    function [7:0] step_up8;
        input [7:0] v;
        input [7:0] step;
        begin
            step_up8 = (v > (8'hFF - step)) ? 8'hFF : (v + step);
        end
    endfunction

    function [7:0] step_down8;
        input [7:0] v;
        input [7:0] step;
        begin
            step_down8 = (v < step) ? 8'h00 : (v - step);
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adsr_a          <= 8'd0;
            enc_activity_cnt <= ENC_FAST_HOLD_CYCLES;
            adsr_d          <= 8'd42;
            adsr_s          <= 8'd0;
            adsr_r          <= 8'd63;
            master_volume   <= 8'd50;
            pitch_step      <= 6'sd0;
            reverb_size     <= 8'd192;  // about 0.84375 feedback
            reverb_mix      <= 8'd255;  // closest to the previous wet level
            delay_time      <= 8'd255;  // about 250 ms
            delay_feedback  <= 8'd64;   // about 0.4375 feedback
            chorus_rate     <= 8'd96;   // 0.8 Hz
            chorus_depth    <= 8'd255;  // full +/-4 ms
        end else begin
            if (enc_any) enc_activity_cnt <= 21'd0;
            else if (enc_activity_cnt < ENC_FAST_HOLD_CYCLES) enc_activity_cnt <= enc_activity_cnt + 21'd1;

            // Encoder 0
            if (seq_enc_up[0]) begin
                case (enc_layer)
                    2'd0: adsr_a <= step_up8(adsr_a, enc_step);
                    2'd1: master_volume <= step_up8(master_volume, enc_step);
                    2'd2: delay_time <= step_up8(delay_time, enc_step);
                    2'd3: begin end
                endcase
            end else if (seq_enc_down[0]) begin
                case (enc_layer)
                    2'd0: adsr_a <= step_down8(adsr_a, enc_step);
                    2'd1: master_volume <= step_down8(master_volume, enc_step);
                    2'd2: delay_time <= step_down8(delay_time, enc_step);
                    2'd3: begin end
                endcase
            end

            // Encoder 1
            if (seq_enc_up[1]) begin
                case (enc_layer)
                    2'd0: adsr_d <= step_up8(adsr_d, enc_step);
                    2'd1: pitch_step <= (pitch_step > (6'sd24 - pitch_step_inc)) ? 6'sd24 : (pitch_step + pitch_step_inc);
                    2'd2: delay_feedback <= step_up8(delay_feedback, enc_step);
                    2'd3: begin end
                endcase
            end else if (seq_enc_down[1]) begin
                case (enc_layer)
                    2'd0: adsr_d <= step_down8(adsr_d, enc_step);
                    2'd1: pitch_step <= (pitch_step < (-6'sd24 + pitch_step_inc)) ? -6'sd24 : (pitch_step - pitch_step_inc);
                    2'd2: delay_feedback <= step_down8(delay_feedback, enc_step);
                    2'd3: begin end
                endcase
            end

            // Encoder 2
            if (seq_enc_up[2]) begin
                case (enc_layer)
                    2'd0: adsr_s <= step_up8(adsr_s, enc_step);
                    2'd1: reverb_size <= step_up8(reverb_size, enc_step);
                    2'd2: chorus_rate <= step_up8(chorus_rate, enc_step);
                    2'd3: begin end
                endcase
            end else if (seq_enc_down[2]) begin
                case (enc_layer)
                    2'd0: adsr_s <= step_down8(adsr_s, enc_step);
                    2'd1: reverb_size <= step_down8(reverb_size, enc_step);
                    2'd2: chorus_rate <= step_down8(chorus_rate, enc_step);
                    2'd3: begin end
                endcase
            end

            // Encoder 3
            if (seq_enc_up[3]) begin
                case (enc_layer)
                    2'd0: adsr_r <= step_up8(adsr_r, enc_step);
                    2'd1: reverb_mix <= step_up8(reverb_mix, enc_step);
                    2'd2: chorus_depth <= step_up8(chorus_depth, enc_step);
                    2'd3: begin end
                endcase
            end else if (seq_enc_down[3]) begin
                case (enc_layer)
                    2'd0: adsr_r <= step_down8(adsr_r, enc_step);
                    2'd1: reverb_mix <= step_down8(reverb_mix, enc_step);
                    2'd2: chorus_depth <= step_down8(chorus_depth, enc_step);
                    2'd3: begin end
                endcase
            end
        end
    end
endmodule
