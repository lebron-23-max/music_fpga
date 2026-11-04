`timescale 1ns / 1ps
//=============================================================================
// piano_engine.v
// 72-voice piano engine with one shared TDM voice datapath.
//
// The sample path, frame interpolation, gain scaling and piano effects are
// unchanged. Per-voice frame/phase state now lives in a state RAM and is read
// and written once per sample, eliminating 50 copies of the address/frame
// arithmetic that previously overflowed the device.
//=============================================================================
module piano_engine #(
    parameter integer TEST_MODE = 0,
    parameter integer VOICE_COUNT = 50,
    parameter integer KEY_COUNT = 12
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
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
    output wire signed [15:0] audio_sample,
    output wire [VOICE_COUNT-1:0] voices_busy,
    output wire               voices_any,
    output wire [7:0]         voices_sounding
);
    wire [24:0] key_gate_full = {{(25-KEY_COUNT){1'b1}}, key_gate};
    localparam [2:0] LAST_FRAME = 3'd7;
`include "piano_note_inc.vh"
`include "test_pitch_pattern.vh"
    localparam [6:0] VOICE_LAST = 7'd71;

    function signed [2:0] octave_for_key;
        input [74:0] bus;
        input [4:0] key;
        begin
            if (key < 5'd25) octave_for_key = $signed(bus[key*3 +: 3]);
            else             octave_for_key = 3'sd0;
        end
    endfunction

    function [7:0] midi_for_voice;
        input [199:0] bus;
        input [6:0] voice;
        begin
            if ((voice >= 7'd12) && (voice < 7'd37))
                midi_for_voice = bus[(voice-7'd12)*8 +: 8];
            else if (voice < 7'd12)
                midi_for_voice = 8'd60 + voice;
            else
                midi_for_voice = 8'd60;
        end
    endfunction

    function [31:0] apply_octave;
        input [31:0] value;
        input signed [2:0] octave;
        begin
            case (octave)
            3'sd1:   apply_octave = value << 1;
            3'sb111:  apply_octave = value >> 1;
            default: apply_octave = value;
            endcase
        end
    endfunction

    // State layout. Upper bits are reserved to keep the RAM at 192 bits.
    localparam integer ST_ACTIVE = 0;
    localparam integer ST_GATE_D = 1;
    localparam integer ST_PM     = 2;
    localparam integer ST_PD     = 34;
    localparam integer ST_FM     = 66;
    localparam integer ST_FD     = 69;
    localparam integer ST_SCM    = 72;
    localparam integer ST_SCD    = 89;
    localparam integer ST_BM     = 106;
    localparam integer ST_BD     = 122;
    localparam integer ST_MS     = 138;
    localparam integer ST_DS     = 154;
    localparam integer STATE_W   = 192;

    wire [7:0] piano_adsr_s = (TEST_MODE || test_mode) ? 8'hFF : adsr_s;
    wire [VOICE_COUNT-1:0] voice_gate = (TEST_MODE || test_mode) ? {VOICE_COUNT{1'b0}} :
        {{(VOICE_COUNT-37){1'b1}}, key_gate_full, 12'hFFF};
    wire [5:0] glide_note = (glide_key < 5'd25) ? (6'd12 + {1'b0, glide_key}) : 6'd63;

    // Envelope lane state lives in BSRAM. The TDM scan queries the two gains
    // for the current voice in subphases 0/1, before they are consumed at 11.
    reg [8:0] env_rd_addr;
    reg env_rd_req;
    wire [15:0] env_rd_data;
    wire [VOICE_COUNT-1:0] env_sounding_mask;
    piano_envelope_bank #(.NUM_VOICES(VOICE_COUNT)) u_env_bank (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .voice_gate(voice_gate),
        .adsr_a(adsr_a), .adsr_d(adsr_d), .adsr_s(piano_adsr_s), .adsr_r(adsr_r),
        .env_rd_addr(env_rd_addr), .env_rd_req(env_rd_req), .env_rd_data(env_rd_data),
        .env_sounding_mask(env_sounding_mask)
    );

    reg [13:0] rom_addr;
    wire signed [15:0] rom_data;
    piano_shared_wave_rom u_rom (
        .clk(clk), .address(rom_addr), .data(rom_data)
    );

    reg [6:0] state_addr;
    reg state_we;
    reg [STATE_W-1:0] state_wdata;
    wire [STATE_W-1:0] state_rdata;
    piano_voice_state_ram #(.WIDTH(STATE_W), .DEPTH(72)) u_state (
        .clk(clk), .addr(state_addr), .we(state_we),
        .wdata(state_wdata), .rdata(state_rdata)
    );

    function [13:0] piano_addr;
        input [31:0] phase;
        input [2:0]  frame;
        input [6:0]  voice;
        input        bank1;
        reg [1:0] root_bank;
        reg [1:0] pair;
        reg [1:0] bank_frame;
        begin
            root_bank = (voice >= 6'd6) ? 2'd2 : 2'd0;
            pair = frame[2:1];
            if (bank1)
                bank_frame = pair;
            else if (frame == LAST_FRAME)
                bank_frame = pair;
            else
                bank_frame = frame[0] ? (pair + 2'd1) : pair;
            piano_addr = {root_bank | {1'b0, bank1}, bank_frame, phase[31:22]};
        end
    endfunction
    function [16:0] segment_length;
        input [2:0] frame;
        begin
            case (frame)
            3'd0: segment_length = 17'd733;
            3'd1: segment_length = 17'd1220;
            3'd2: segment_length = 17'd2442;
            3'd3: segment_length = 17'd4883;
            3'd4: segment_length = 17'd9765;
            3'd5: segment_length = 17'd19532;
            3'd6: segment_length = 17'd39062;
            default: segment_length = 17'd1;
            endcase
        end
    endfunction

    function [15:0] segment_step;
        input [2:0] frame;
        begin
            case (frame)
            3'd0: segment_step = 16'd90;
            3'd1: segment_step = 16'd54;
            3'd2: segment_step = 16'd27;
            3'd3: segment_step = 16'd14;
            3'd4: segment_step = 16'd7;
            3'd5: segment_step = 16'd4;
            3'd6: segment_step = 16'd2;
            default: segment_step = 16'd1;
            endcase
        end
    endfunction

    function [31:0] scaled_inc;
        input [48:0] product;
        reg [33:0] shifted;
        begin
            shifted = product >>> 15;
            scaled_inc = (|shifted[33:32]) ? 32'd0 : shifted[31:0];
        end
    endfunction

    reg [6:0]  voice_idx;
    reg [3:0]  start_wait;
    reg [3:0]  subphase;
    reg        scan_active;
    reg [STATE_W-1:0] work_state;
    reg signed [15:0] rom_m0, rom_m1, rom_d0, rom_d1;
    reg [48:0] pitch_main_prod, pitch_det_prod;
    reg [31:0] pitch_base;
    reg [16:0] pitch_mult_b;
    reg [31:0] voice_base_main_q;
    reg [31:0] voice_base_det_q;
    reg [16:0] voice_pitch_q;
    reg [48:0] pitch_mult_p;
    reg signed [17:0] audio_a;
    reg signed [17:0] audio_b;
    reg signed [35:0] audio_p;
    reg signed [16:0] main_interp_q;
    reg signed [16:0] det_interp_q;
    reg signed [24:0] mix_sum;
    reg signed [16:0] voice_sum_q;
    reg [15:0] gain_main_q, gain_det_q;
    reg signed [15:0] strings_mix_q;
    reg signed [15:0] mix_scan_q;
    reg [VOICE_COUNT-1:0] busy_mask;
    reg signed [15:0] mixed_saturated_q;

    wire signed [15:0] main_rom_a = work_state[ST_FM] ? rom_m1 : rom_m0;
    wire signed [15:0] main_rom_b = (work_state[ST_FM +: 3] == LAST_FRAME) ? main_rom_a :
        (work_state[ST_FM] ? rom_m0 : rom_m1);
    wire signed [15:0] det_rom_a = work_state[ST_FD] ? rom_d1 : rom_d0;
    wire signed [15:0] det_rom_b = (work_state[ST_FD +: 3] == LAST_FRAME) ? det_rom_a :
        (work_state[ST_FD] ? rom_d0 : rom_d1);
    wire signed [16:0] main_delta = main_rom_b - main_rom_a;
    wire signed [16:0] det_delta  = det_rom_b - det_rom_a;

    wire [16:0] voice_pitch = (glide_active && (voice_idx == glide_note)) ?
        pitch_ratio_glide : pitch_ratio;
    wire signed [2:0] test_octave = $signed(key_octave_bus[2:0]);
    wire signed [2:0] voice_octave = (TEST_MODE || test_mode) ? test_octave : octave_for_key(key_octave_bus, voice_idx[4:0]);
    // Test mode must produce 72 genuinely independent oscillators. The normal
    // note table only covers the playable range and would repeat its default
    // value for the extra lanes; this monotonic test ramp keeps every lane
    // distinct while the same BTOK octave multiplier remains in effect.
    wire [6:0] piano_test_midi = test_midi_for_voice(voice_idx);
    wire [31:0] piano_test_base = piano_phase_inc(piano_test_midi);
    wire [7:0] piano_midi = midi_for_voice(key_tune_bus, voice_idx);
    wire [31:0] piano_normal_base = (piano_midi <= 8'd127) ? piano_phase_inc(piano_midi[6:0]) : 32'd0;
    wire [31:0] voice_base_main = apply_octave(
        (TEST_MODE || test_mode) ? piano_test_base : piano_normal_base,
        voice_octave);
    wire [31:0] voice_base_det  = voice_base_main + (voice_base_main >> 9) + (voice_base_main >> 11);
    wire [31:0] inc_main_use = scaled_inc(pitch_main_prod);
    wire [31:0] inc_det_use  = scaled_inc(pitch_det_prod);


    wire [31:0] work_pm = work_state[ST_PM +: 32];
    wire [31:0] work_pd = work_state[ST_PD +: 32];
    wire [2:0]  work_fm = work_state[ST_FM +: 3];
    wire [2:0]  work_fd = work_state[ST_FD +: 3];
    wire [16:0] work_scm = work_state[ST_SCM +: 17];
    wire [16:0] work_scd = work_state[ST_SCD +: 17];
    wire [15:0] work_bm = work_state[ST_BM +: 16];
    wire [15:0] work_bd = work_state[ST_BD +: 16];
    wire work_active = work_state[ST_ACTIVE];
    wire work_gate_d = work_state[ST_GATE_D];
    wire gate_now = ~voice_gate[voice_idx];
    wire trigger = gate_now && !work_gate_d;

    reg [31:0] next_pm, next_pd;
    reg [2:0] next_fm, next_fd;
    reg [16:0] next_scm, next_scd;
    reg [15:0] next_bm, next_bd;
    reg signed [15:0] next_ms, next_ds;
    reg next_active, next_gate_d;
    reg [STATE_W-1:0] next_state;

    always @* begin
        next_active = work_active;
        next_gate_d = gate_now;
        next_pm = work_pm;
        next_pd = work_pd;
        next_fm = work_fm;
        next_fd = work_fd;
        next_scm = work_scm;
        next_scd = work_scd;
        next_bm = work_bm;
        next_bd = work_bd;
        next_ms = work_state[ST_MS +: 16];
        next_ds = work_state[ST_DS +: 16];
        if (trigger) begin
            next_active = 1'b1;
            next_pm = 32'd0;
            next_pd = 32'h40000000;
            next_fm = 3'd0;
            next_fd = 3'd0;
            next_scm = 17'd0;
            next_scd = 17'd0;
            next_bm = 16'd0;
            next_bd = 16'd0;
            next_ms = 16'sd0;
            next_ds = 16'sd0;
        end else if (work_active) begin
            next_ms = main_interp_q[15:0];
            next_ds = det_interp_q[15:0];
            next_pm = work_pm + inc_main_use;
            next_pd = work_pd + inc_det_use;
            if (work_fm < LAST_FRAME) begin
                if ((work_scm + 17'd1) >= segment_length(work_fm)) begin
                    next_fm = work_fm + 3'd1;
                    next_scm = 17'd0;
                    next_bm = 16'd0;
                end else begin
                    next_scm = work_scm + 17'd1;
                    next_bm = (work_bm > (16'hFFFF - segment_step(work_fm))) ?
                              16'hFFFF : (work_bm + segment_step(work_fm));
                end
            end
            if (work_fd < LAST_FRAME) begin
                if ((work_scd + 17'd1) >= segment_length(work_fd)) begin
                    next_fd = work_fd + 3'd1;
                    next_scd = 17'd0;
                    next_bd = 16'd0;
                end else begin
                    next_scd = work_scd + 17'd1;
                    next_bd = (work_bd > (16'hFFFF - segment_step(work_fd))) ?
                              16'hFFFF : (work_bd + segment_step(work_fd));
                end
            end
        end
        next_state = {22'b0, next_ds, next_ms, next_bd, next_bm,
                      next_scd, next_scm, next_fd, next_fm,
                      next_pd, next_pm, next_gate_d, next_active};
    end

    wire signed [35:0] main_env_product =
        $signed(main_interp_q[15:0]) * $signed({2'b0, gain_main_q});
    wire signed [35:0] det_env_product =
        $signed(det_interp_q[15:0]) * $signed({2'b0, gain_det_q});
    wire signed [16:0] voice_sum_now =
        ($signed(main_env_product[31:16]) + $signed(det_env_product[31:16])) >>> 1;
    wire signed [24:0] mix_sum_now = mix_sum + voice_sum_q;
    wire signed [15:0] mix_saturated_now =
        (mix_sum_now > 25'sd32767) ? 16'sh7FFF :
        (mix_sum_now < -25'sd32768) ? 16'sh8000 : mix_sum_now[15:0];
    wire signed [15:0] mixed_saturated;
    wire        note_gate = &voice_gate;
    wire signed [15:0] hammer_sample;
    wire signed [15:0] brightness_attack;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_idx <= 6'd0;
            subphase <= 4'd0;
            scan_active <= 1'b0;
            state_addr <= 6'd0;
            env_rd_addr <= 9'd0;
            env_rd_req <= 1'b0;
            state_we <= 1'b0;
            state_wdata <= {STATE_W{1'b0}};
            work_state <= {STATE_W{1'b0}};
            rom_addr <= 14'd0;
            rom_m0 <= 16'sd0; rom_m1 <= 16'sd0;
            rom_d0 <= 16'sd0; rom_d1 <= 16'sd0;
            pitch_main_prod <= 49'd0; pitch_det_prod <= 49'd0;
            pitch_base <= 32'd0; voice_base_main_q <= 32'd0; voice_base_det_q <= 32'd0;
            voice_pitch_q <= 17'd32768; pitch_mult_b <= 17'd0; pitch_mult_p <= 49'd0;
            main_interp_q <= 17'sd0; det_interp_q <= 17'sd0;
            mix_sum <= 25'sd0;
            voice_sum_q <= 17'sd0;
            gain_main_q <= 16'd0; gain_det_q <= 16'd0;
            strings_mix_q <= 16'sd0;
            mix_scan_q <= 16'sd0;
            busy_mask <= {VOICE_COUNT{1'b0}};
            mixed_saturated_q <= 16'sd0;
        end else begin
            state_we <= 1'b0;
            pitch_mult_p <= {17'd0, pitch_base} * pitch_mult_b;
            audio_p <= $signed(audio_a) * $signed(audio_b);

            if (sample_tick) begin
                // Let the BSRAM envelope scan finish lane 0 before the TDM
                // query. Eight clocks leave the complete 72-voice pass within
                // the 1024-clock sample budget (8 + 72*14 = 1016).
                scan_active <= 1'b0;
                start_wait  <= 4'd8;
                voice_idx <= 7'd0;
                subphase <= 4'd0;
                state_addr <= 7'd0;
                env_rd_addr <= 9'd0;
                env_rd_req <= 1'b0;
                mix_sum <= 25'sd0;
                voice_sum_q <= 17'sd0;
            end else if (start_wait != 4'd0) begin
                start_wait <= start_wait - 4'd1;
                if (start_wait == 4'd1) begin
                    scan_active <= 1'b1;
                    voice_idx <= 7'd0;
                    subphase <= 4'd0;
                    state_addr <= 7'd0;
                    env_rd_addr <= 9'd0;
                    env_rd_req <= 1'b0;
                end
            end else if (scan_active) begin
                case (subphase)
                4'd0: begin
                    voice_base_main_q <= voice_base_main;
                    voice_pitch_q <= voice_pitch;
                    state_addr <= voice_idx;
                    env_rd_addr <= {voice_idx, 1'b0};
                    env_rd_req <= 1'b1;
                end
                4'd1: begin
                    voice_base_det_q <= voice_base_main_q + (voice_base_main_q >> 9) + (voice_base_main_q >> 11);
                    env_rd_addr <= {voice_idx, 1'b1};
                    env_rd_req <= 1'b1;
                end
                4'd2: begin
                    gain_main_q <= env_rd_data;
                    env_rd_req <= 1'b0;
                    work_state <= state_rdata;
                    pitch_base <= voice_base_main_q;
                    pitch_mult_b <= voice_pitch_q;
                    rom_addr <= piano_addr(state_rdata[ST_PM +: 32],
                                           state_rdata[ST_FM +: 3], voice_idx, 1'b0);
                end
                4'd3: begin
                    gain_det_q <= env_rd_data;
                    pitch_base <= voice_base_det_q;
                    rom_addr <= piano_addr(work_pm, work_fm, voice_idx, 1'b1);
                end
                4'd4: begin
                    pitch_main_prod <= pitch_mult_p;
                    rom_m0 <= rom_data;
                    rom_addr <= piano_addr(work_pd, work_fd, voice_idx, 1'b0);
                end
                4'd5: begin
                    pitch_det_prod <= pitch_mult_p;
                    rom_m1 <= rom_data;
                    rom_addr <= piano_addr(work_pd, work_fd, voice_idx, 1'b1);
                end
                4'd6: rom_d0 <= rom_data;
                4'd7: begin
                    rom_d1 <= rom_data;
                    audio_a <= {{1{main_delta[16]}}, main_delta};
                    audio_b <= {2'b0, work_bm};
                end
                4'd8: begin
                    audio_a <= {{1{det_delta[16]}}, det_delta};
                    audio_b <= {2'b0, work_bd};
                end
                4'd9: main_interp_q <= main_rom_a + (audio_p >>> 16);
                4'd10: det_interp_q <= det_rom_a + (audio_p >>> 16);
                4'd11: begin
                    state_wdata <= next_state;
                    state_we <= 1'b1;
                    busy_mask[voice_idx] <= next_active;

                end
                4'd12: begin
                    voice_sum_q <= work_active ? voice_sum_now : 17'sd0;
                end
                default: begin
                    state_we <= 1'b0;
                    mix_sum <= mix_sum_now;
                    if (voice_idx == VOICE_LAST) begin
                        scan_active <= 1'b0;
                        mix_scan_q <= mix_saturated_now;
                    end else begin
                        voice_idx <= voice_idx + 7'd1;
                    end
                end
                endcase
                if (subphase != 4'd13)
                    subphase <= subphase + 4'd1;
                else
                    subphase <= 4'd0;
            end

            if (sample_tick) begin
                strings_mix_q <= mix_scan_q;
                mixed_saturated_q <= mixed_saturated;
            end
        end
    end
    function [6:0] first_active_note;
        input [VOICE_COUNT-1:0] gate_vec;
        integer k;
        begin
            first_active_note = 7'd0;
            for (k = VOICE_COUNT-1; k >= 0; k = k - 1)
                if (!gate_vec[k]) first_active_note = k[6:0];
        end
    endfunction


    wire [6:0]  note_index = first_active_note(voice_gate);
    wire        root_is_a4 = (note_index >= 6'd6);


    wire signed [17:0] mix_with_effects;

    wire signed [21:0] volume_scaled;

    piano_effects u_effects (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .note_gate(note_gate), .root_is_a4(root_is_a4),
        .sample_in(strings_mix_q), .bright_out(brightness_attack),
        .hammer_out(hammer_sample)
    );

    assign mix_with_effects = strings_mix_q + hammer_sample + brightness_attack;
    assign mixed_saturated = (mix_with_effects > 18'sd32767) ? 16'sh7FFF :
                             (mix_with_effects < -18'sd32768) ? 16'sh8000 :
                             mix_with_effects[15:0];
    wire signed [21:0] volume_mixed_ext = {{6{mixed_saturated_q[15]}}, mixed_saturated_q};
    assign volume_scaled = (volume_mixed_ext <<< 3) + (volume_mixed_ext <<< 1);
    assign audio_sample = volume_scaled[19:4];
    assign voices_busy = busy_mask;

    function [7:0] pop_voices;
        input [VOICE_COUNT-1:0] v;
        integer q;
        begin
            pop_voices = 8'd0;
            for (q = 0; q < VOICE_COUNT; q = q + 1) pop_voices = pop_voices + v[q];
        end
    endfunction

    assign voices_sounding = pop_voices(env_sounding_mask);
    assign voices_any = |env_sounding_mask;

endmodule
