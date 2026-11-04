`timescale 1ns / 1ps
//=============================================================================
// music_top.v
// 板级顶层：控制面、四音色引擎、全局效果链和 HDMI 显示连接。
//   piano_engine / music_box_engine
//   四音色各自 50 声部；EP/弦乐各自执行 TDM 运算并共用波表 ROM。
//=============================================================================
module music_top #(
    parameter integer USE_NEW_PANEL = 0,
    parameter integer TEST_DEBOUNCE_CYCLES = 250_000,
    parameter integer MATRIX_SCAN_CYCLES = 10_000
) (
    input  wire        clk,

    // New interaction-board panel interface (used when USE_NEW_PANEL=1).
    output wire [4:0]  key_row_n,
    input  wire [4:0]  key_col_n,
    input  wire [5:0]  func_btn_n,
    input  wire [3:0]  panel_enc_a,
    input  wire [3:0]  panel_enc_b,
    input  wire        panel_enc_shift_n,
    output wire        ws2812_din,

    // Legacy 12-key bench interface (kept for existing regression benches).
    input  wire [11:0] key_n,      // 12 路低有效外部按键，建议上拉
    input  wire        timbre_sel,  // 音色切换按键：SDRAM0_A6 / D14，低有效，按一次翻转
    input  wire [4:0]  enc_a,       // [0..3]=ADSR EC11 A，[4]=主音量 A11 / D17
    input  wire [4:0]  enc_b,       // [0..3]=ADSR EC11 B，[4]=主音量 A8 / A18
    input  wire        reverb_sw,   // 混响切换按键：SDRAM0_A4 / E16，低有效，按一次翻转
    input  wire        delay_sw,    // 延迟切换按键：SDRAM0_BA0 / F15，低有效，按一次翻转
    input  wire        chorus_btn_n,// 合唱切换键：SDRAM0_A10 / D20，低有效，按一次翻转
    input  wire        seq_btn_n,   // KEY0 / AA13，低有效：切换曲目
    input  wire        key1_n,      // KEY1 / AB13，低有效：播放/停止
    input  wire        vibrato_btn_n, // 颤音切换：D19，低有效
    input  wire        pitch_up_n,   // 升调键：SDRAM0_A1 / E19，低有效，每按一次 +50
    input  wire        pitch_down_n, // 降调键：SDRAM0_A3 / C18，低有效，每按一次 -50
    input  wire        uart_rx,      // HC-05 TXD / PMOD1_IO1 / J8.2：Y22
    output wire        uart_tx,      // HC-05 RXD / PMOD1_IO0 / J8.1：Y21
    input  wire        test_piano_n, // 钢琴50声部齐奏锁存键，PMOD1_IO2 / AB21 (J8.9)
    input  wire        test_mb_n,    // 八音盒50声部齐奏锁存键，PMOD1_IO3 / AB22 (J8.10)
    input  wire        test_ep_n,    // 电钢琴50声部齐奏锁存键，PMOD1_IO4 / AA20 (J8.7)
    input  wire        test_str_n,   // 弦乐50声部齐奏锁存键，PMOD1_IO5 / AA21 (J8.8)
    output wire        sd_cs_n,
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire I2S_BCLK,
    output wire I2S_LRCK,
    output wire I2S_DIN,
    output wire PA_EN,
    // HDMI/DVI TMDS 输出（正端；负端由 IO 差分缓冲驱动，见 tmds_serializer.v）
    output wire [2:0]  tmds_data_p,
    output wire        tmds_clk_p
);
    localparam [15:0] POR_CYCLES = 16'd49_999;
    reg [15:0] por_cnt;
    reg        rst_n_int;

    initial begin
        por_cnt   = 16'd0;
        rst_n_int = 1'b0;
    end

    always @(posedge clk) begin
        if (por_cnt < POR_CYCLES) begin
            por_cnt   <= por_cnt + 16'd1;
            rst_n_int <= 1'b0;
        end else begin
            rst_n_int <= 1'b1;
        end
    end

    //=================================================================
    // HC-05 UART bring-up：115200 8N1。
    // 手机发送 ASCII "PING"（无需换行），FPGA 回复 "PONG\r\n"。
    // 接收端为异步输入，uart_rx 内部做两级同步后按 434 clk/bit 采样。
    //=================================================================
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;
    wire       uart_rx_framing_error;
    wire       uart_tx_start_ping;
    wire [7:0] uart_tx_data_ping;
    wire       uart_tx_busy;
    wire       dl_octave_commit;
    wire       dl_tx_start;
    wire [7:0] dl_tx_data;
    wire       rec_tx_req;
    wire [7:0] rec_tx_data;
    wire       rec_tx_grant;
    wire       record_stream_enable;
    wire       record_tx_hold;
    wire [2:0] octave_shift_piano, octave_shift_musicbox;
    wire [2:0] octave_shift_epiano, octave_shift_strings;
    wire [199:0] key_tune_piano, key_tune_musicbox, key_tune_epiano, key_tune_strings;
    wire [199:0] bt_score_key_map;
    wire [74:0] key_octave_bus_piano = {25{octave_shift_piano}};
    wire [74:0] key_octave_bus_musicbox = {25{octave_shift_musicbox}};
    wire [74:0] key_octave_bus_epiano = {25{octave_shift_epiano}};
    wire [74:0] key_octave_bus_strings = {25{octave_shift_strings}};
    assign rec_tx_grant = rec_tx_req && !uart_tx_busy && !record_tx_hold &&
                          !uart_tx_start_ping && !dl_tx_start;
    wire       uart_tx_start = uart_tx_start_ping | dl_tx_start | rec_tx_grant;
    wire [7:0] uart_tx_data = uart_tx_start_ping ? uart_tx_data_ping :
                              (dl_tx_start ? dl_tx_data : rec_tx_data);

    uart_rx #(.CLKS_PER_BIT(434)) u_uart_rx (
        .clk(clk),
        .rst_n(rst_n_int),
        .serial_in(uart_rx),
        .data_out(uart_rx_data),
        .valid(uart_rx_valid),
        .framing_error(uart_rx_framing_error)
    );

    uart_ping_responder u_uart_ping (
        .clk(clk),
        .rst_n(rst_n_int),
        .rx_valid(uart_rx_valid),
        .rx_data(uart_rx_data),
        .tx_busy(uart_tx_busy),
        .tx_start(uart_tx_start_ping),
        .tx_data(uart_tx_data_ping)
    );

    uart_tx #(.CLKS_PER_BIT(434)) u_uart_tx (
        .clk(clk),
        .rst_n(rst_n_int),
        .start(uart_tx_start),
        .data_in(uart_tx_data),
        .serial_out(uart_tx),
        .busy(uart_tx_busy)
    );

    // ---------------------------------------------------------------------
    // Control surface: new interaction panel or the legacy bench controls.
    // ---------------------------------------------------------------------
    wire reverb_en, delay_en, chorus_en, vibrato_en;
    wire glide_active;
    wire [1:0] timbre_code;
    wire test_piano_en, test_mb_en, test_ep_en, test_str_en;
    wire test_any;
    wire guide_en, led_note_en;
    wire guide_score_done;
    wire [24:0] guide_note_mask;
    wire sample_tick;

    // New board panel
    wire [24:0] panel_key_pressed;
    wire [1:0]  panel_timbre_code;
    wire        panel_reverb_en, panel_delay_en, panel_chorus_en, panel_vibrato_en;
    wire        panel_test_piano_en, panel_test_mb_en, panel_test_ep_en, panel_test_str_en;
    wire        panel_guide_en, panel_led_note_en;
    wire        panel_func_shift;
    wire [1:0]  panel_func_layer;
    wire        panel_song_next_pulse, panel_song_play_pulse;
    wire        panel_seq_page_toggle;
    wire [3:0]  panel_seq_confirm_pulse;
    wire [3:0]  panel_seq_enc_up, panel_seq_enc_down;
    wire [1:0]  panel_enc_layer;
    wire [7:0]  panel_adsr_a, panel_adsr_d, panel_adsr_s, panel_adsr_r;
    wire [7:0]  panel_master_volume;
    wire signed [5:0] panel_pitch_step;
    wire [7:0]  panel_reverb_size, panel_reverb_mix;
    wire [7:0]  panel_delay_time, panel_delay_feedback;
    wire [7:0]  panel_chorus_rate, panel_chorus_depth;

    interaction_panel #(
        .SCAN_CYCLES(MATRIX_SCAN_CYCLES),
        .MATRIX_DEBOUNCE(4),
        .BUTTON_DEBOUNCE_CLKS(TEST_DEBOUNCE_CYCLES)
    ) u_panel (
        .clk(clk), .rst_n(rst_n_int),
        .key_row_n(key_row_n), .key_col_n(key_col_n),
        .key_pressed(panel_key_pressed),
        .func_btn_n(func_btn_n),
        .enc_a(panel_enc_a), .enc_b(panel_enc_b),
        .enc_shift_n(panel_enc_shift_n), .guide_done(guide_score_done),
        .timbre_code(panel_timbre_code),
        .reverb_en(panel_reverb_en), .delay_en(panel_delay_en),
        .chorus_en(panel_chorus_en), .vibrato_en(panel_vibrato_en),
        .test_piano_en(panel_test_piano_en), .test_mb_en(panel_test_mb_en),
        .test_ep_en(panel_test_ep_en), .test_str_en(panel_test_str_en),
        .guide_en(panel_guide_en), .led_note_en(panel_led_note_en),
        .func_shift(panel_func_shift), .func_layer(panel_func_layer),
        .song_next_pulse(panel_song_next_pulse), .song_play_pulse(panel_song_play_pulse),
        .seq_page_toggle(panel_seq_page_toggle), .seq_confirm_pulse(panel_seq_confirm_pulse),
        .seq_enc_up(panel_seq_enc_up), .seq_enc_down(panel_seq_enc_down),
        .enc_layer(panel_enc_layer),
        .adsr_a(panel_adsr_a), .adsr_d(panel_adsr_d),
        .adsr_s(panel_adsr_s), .adsr_r(panel_adsr_r),
        .master_volume(panel_master_volume), .pitch_step(panel_pitch_step),
        .reverb_size(panel_reverb_size), .reverb_mix(panel_reverb_mix),
        .delay_time(panel_delay_time), .delay_feedback(panel_delay_feedback),
        .chorus_rate(panel_chorus_rate), .chorus_depth(panel_chorus_depth),
        .scan_row_dbg()
    );

    builtin_guide_score u_guide_score (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .enable(guide_en), .note_mask(guide_note_mask), .done(guide_score_done)
    );

    // Legacy bench controls
    wire [1:0] timbre_code_old;
    wire reverb_en_old, delay_en_old, chorus_en_old, vibrato_en_old;
    wire test_piano_en_old, test_mb_en_old, test_ep_en_old, test_str_en_old;

    key_cycle #(.INIT(2'd0)) u_timbre_select (
        .clk(clk), .rst_n(rst_n_int),
        .key_n(timbre_sel), .state(timbre_code_old)
    );
    key_toggle #(.INIT(1'b1)) u_reverb_toggle (
        .clk(clk), .rst_n(rst_n_int),
        .key_n(reverb_sw), .state(reverb_en_old)
    );
    key_toggle #(.INIT(1'b0)) u_delay_toggle (
        .clk(clk), .rst_n(rst_n_int),
        .key_n(delay_sw), .state(delay_en_old)
    );
    key_toggle #(.INIT(1'b0)) u_chorus_toggle (
        .clk(clk), .rst_n(rst_n_int),
        .key_n(chorus_btn_n), .state(chorus_en_old)
    );
    key_toggle #(.INIT(1'b0)) u_vibrato_toggle (
        .clk(clk), .rst_n(rst_n_int),
        .key_n(vibrato_btn_n), .state(vibrato_en_old)
    );

    key_toggle #(.INIT(1'b0), .DEBOUNCE_CYCLES(TEST_DEBOUNCE_CYCLES), .ARM_AFTER_RELEASE(1'b1)) u_test_piano (
        .clk(clk), .rst_n(rst_n_int), .key_n(test_piano_n), .state(test_piano_en_old)
    );
    key_toggle #(.INIT(1'b0), .DEBOUNCE_CYCLES(TEST_DEBOUNCE_CYCLES), .ARM_AFTER_RELEASE(1'b1)) u_test_mb (
        .clk(clk), .rst_n(rst_n_int), .key_n(test_mb_n), .state(test_mb_en_old)
    );
    key_toggle #(.INIT(1'b0), .DEBOUNCE_CYCLES(TEST_DEBOUNCE_CYCLES), .ARM_AFTER_RELEASE(1'b1)) u_test_ep (
        .clk(clk), .rst_n(rst_n_int), .key_n(test_ep_n), .state(test_ep_en_old)
    );
    key_toggle #(.INIT(1'b0), .DEBOUNCE_CYCLES(TEST_DEBOUNCE_CYCLES), .ARM_AFTER_RELEASE(1'b1)) u_test_str (
        .clk(clk), .rst_n(rst_n_int), .key_n(test_str_n), .state(test_str_en_old)
    );

    assign timbre_code    = USE_NEW_PANEL ? panel_timbre_code : timbre_code_old;
    assign reverb_en      = USE_NEW_PANEL ? panel_reverb_en : reverb_en_old;
    assign delay_en       = USE_NEW_PANEL ? panel_delay_en : delay_en_old;
    assign chorus_en      = USE_NEW_PANEL ? panel_chorus_en : chorus_en_old;
    assign vibrato_en     = USE_NEW_PANEL ? panel_vibrato_en : vibrato_en_old;
    assign test_piano_en  = USE_NEW_PANEL ? panel_test_piano_en : test_piano_en_old;
    assign test_mb_en     = USE_NEW_PANEL ? panel_test_mb_en : test_mb_en_old;
    assign test_ep_en     = USE_NEW_PANEL ? panel_test_ep_en : test_ep_en_old;
    assign test_str_en    = USE_NEW_PANEL ? panel_test_str_en : test_str_en_old;
    // WS2812 guide and note indication are driven by the mode-2 U59 controls.
    assign guide_en       = USE_NEW_PANEL ? panel_guide_en : 1'b0;
    assign led_note_en    = USE_NEW_PANEL ? panel_led_note_en : 1'b0;
wire [2:0] current_octave_shift =
    (timbre_code == 2'd0) ? octave_shift_piano :
    (timbre_code == 2'd1) ? octave_shift_musicbox :
    (timbre_code == 2'd2) ? octave_shift_epiano : octave_shift_strings;
    assign test_any       = test_piano_en | test_mb_en | test_ep_en | test_str_en;
    wire [1:0] active_enc_layer  = USE_NEW_PANEL ? panel_enc_layer  : 2'd0;
    wire [1:0] active_func_layer = USE_NEW_PANEL ? panel_func_layer : 2'd0;
    // Legacy KEY0/KEY1 plus the new panel's function-layer-2 song controls.
    wire song_next_pulse_old, play_pulse_old;
    key_pulse u_song_key (.clk(clk), .rst_n(rst_n_int), .key_n(seq_btn_n), .pulse(song_next_pulse_old));
    key_pulse u_play_key (.clk(clk), .rst_n(rst_n_int), .key_n(key1_n), .pulse(play_pulse_old));
    wire song_next_pulse = USE_NEW_PANEL ? panel_song_next_pulse : song_next_pulse_old;
    wire play_pulse      = USE_NEW_PANEL ? panel_song_play_pulse : play_pulse_old;
    reg [2:0] song_sel;
    reg       seq_en;
    reg       bt_song_valid;
    wire      dl_commit;
    wire      dl_active;
    wire [7:0] song_count = bt_song_valid ? 8'd5 : 8'd4;
    wire [2:0] song_sel_next = (song_sel == (song_count[2:0] - 3'd1))
                             ? 3'd0 : (song_sel + 3'd1);
    wire       bt_mode = (song_sel == 3'd4);
    wire       seq_mode = (song_sel == 3'd3);
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            song_sel      <= 3'd0;
            seq_en        <= 1'b0;
            bt_song_valid <= 1'b0;
        end else begin
            if (dl_commit) bt_song_valid <= 1'b1;
            if (song_next_pulse) begin
                song_sel <= song_sel_next;
                seq_en   <= 1'b0;
            end else if (dl_commit) begin
                song_sel <= 3'd4;
                seq_en   <= 1'b0;
            end else if (dl_active) begin
                seq_en <= 1'b0;
            end else if (play_pulse) begin
                seq_en <= ~seq_en;
            end
        end
    end
    // Song slot 3 is the volatile Bluetooth score and must not touch SD.
    wire song_reload = song_next_pulse && (song_sel_next < 3'd3);

    wire signed [15:0] piano_audio;
    wire signed [15:0] music_box_audio;
    wire signed [15:0] epiano_audio;
    wire signed [15:0] strings_audio;
    wire signed [15:0] wavetable_audio;
    wire signed [15:0] audio_sample;
    wire [11:0] key_gate_old;
    wire [24:0] key_gate;

    // The new panel is already debounced by key_matrix_5x5. Legacy benches
    // retain the original 12-key debounce path and inactive upper notes.
    key_debounce u_keys (
        .clk(clk),
        .rst_n(rst_n_int),
        .key_n(key_n),
        .key_gate(key_gate_old)
    );

    assign key_gate = USE_NEW_PANEL
                    ? ~panel_key_pressed
                    : {13'h1FFF, key_gate_old};

    //================ SD 卡曲谱与音序器 ================
    wire        sd_ready, sd_is_sdhc, sd_done, sd_error;
    wire [3:0]  sd_error_code, sd_state;
    wire        sd_start;
    wire [31:0] sd_sector;
    wire        sd_rvalid;
    wire [8:0]  sd_raddr;
    wire [7:0]  sd_rdata;
    wire [31:0] score_base_lba;
    wire        score_base_valid;
    wire        score_loader_ready = sd_ready;

    wire        score_ram_we;
    wire [8:0]  score_ram_waddr;
    wire [9:0]  score_ram_raddr_player;
    wire [7:0]  score_ram_wdata, score_ram_rdata;
    wire [7:0]  bt_score_ram_rdata;
    wire        dl_ram_we;
    wire [9:0]  dl_ram_waddr;
    wire [7:0]  dl_ram_wdata;
    wire        dl_error;
    wire [3:0]  dl_state;
    wire        score_load_done, score_load_error;
    wire [3:0]  score_load_err_code;
    wire [7:0]  score_track_count, score_ticks_per_q, score_flags;
    wire [31:0] score_tempo_step, score_body_crc;
    wire [15:0] score_event_count, score_event_bytes;
    wire [1:0]  score_loaded_song;
    wire [7:0]  bt_track_count, bt_ticks_per_q, bt_flags;
    wire [31:0] bt_tempo_step, bt_body_crc;
    wire [15:0] bt_event_count, bt_event_bytes;
    wire [7:0]  player_track_count = bt_mode ? bt_track_count : score_track_count;
    wire [7:0]  player_flags       = bt_mode ? bt_flags       : score_flags;
    wire [31:0] player_tempo_step  = bt_mode ? bt_tempo_step  : score_tempo_step;
    wire [15:0] player_event_count = bt_mode ? bt_event_count : score_event_count;
    wire [7:0]  player_rdata       = bt_mode ? bt_score_ram_rdata : score_ram_rdata;
    wire        player_load_done   = bt_mode ? (bt_song_valid && !dl_active) : score_load_done;

    wire score_map_active = bt_mode && player_flags[2];
    wire [199:0] active_tune_piano   = score_map_active ? bt_score_key_map : key_tune_piano;
    wire [199:0] active_tune_musicbox= score_map_active ? bt_score_key_map : key_tune_musicbox;
    wire [199:0] active_tune_epiano  = score_map_active ? bt_score_key_map : key_tune_epiano;
    wire [199:0] active_tune_strings = score_map_active ? bt_score_key_map : key_tune_strings;
    wire [74:0] active_oct_piano   = score_map_active ? 75'd0 : key_octave_bus_piano;
    wire [74:0] active_oct_musicbox= score_map_active ? 75'd0 : key_octave_bus_musicbox;
    wire [74:0] active_oct_epiano  = score_map_active ? 75'd0 : key_octave_bus_epiano;
    wire [74:0] active_oct_strings = score_map_active ? 75'd0 : key_octave_bus_strings;

    wire        song_player_playing, seq_done;
    wire        seq_playing;
    wire        step_seq_playing, seq_page;
    wire [2:0]  seq_selected_row;
    wire [4:0]  seq_selected_step;
    wire [3:0]  seq_track_ready;
    wire [7:0]  seq_speed, seq_swing, seq_gate;
    wire [127:0] seq_active_mask;
    wire [5:0] seq_selected_entry;
    wire [24:0] step_gate_piano, step_gate_mb, step_gate_ep, step_gate_str;
    wire [24:0] active_seq_gate_piano, active_seq_gate_mb, active_seq_gate_ep, active_seq_gate_str;
    wire [24:0] seq_gate_piano, seq_gate_mb, seq_gate_ep, seq_gate_str;

    sd_spi_sector_reader #(
        .INIT_HALF_DIV(16'd63),
        .FAST_HALF_DIV(16'd4)
    ) u_sd (
        .clk(clk), .rst_n(rst_n_int),
        .sd_cs_n(sd_cs_n), .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .start(sd_start), .sector_no(sd_sector),
        .write_start(1'b0), .write_sector(32'd0),
        .write_valid(1'b0), .write_data(8'd0),
        .write_ready(), .write_done(), .write_error(),
        .ready(sd_ready), .sdhc(sd_is_sdhc), .done(sd_done), .error(sd_error),
        .error_code(sd_error_code), .state_dbg(sd_state), .rvalid(sd_rvalid),
        .raddr(sd_raddr), .rdata(sd_rdata)
    );

    music_score_loader u_score_loader (
        .clk(clk), .rst_n(rst_n_int),
        .sd_ready(score_loader_ready), .sd_done(sd_done), .sd_error(sd_error),
        .sd_rvalid(sd_rvalid), .sd_raddr(sd_raddr), .sd_rdata(sd_rdata),
        .song_index(song_sel[1:0]), .reload(song_reload), .loaded_song(score_loaded_song),
        .base_lba(score_base_lba), .base_valid(score_base_valid),
        .sd_start(sd_start), .sd_sector(sd_sector),
        .ram_we(score_ram_we), .ram_waddr(score_ram_waddr), .ram_wdata(score_ram_wdata),
        .load_done(score_load_done), .load_error(score_load_error),
        .load_err_code(score_load_err_code),
        .track_count(score_track_count), .ticks_per_q(score_ticks_per_q),
        .flags(score_flags), .tempo_step(score_tempo_step),
        .event_count(score_event_count), .event_bytes(score_event_bytes),
        .body_crc(score_body_crc)
    );

    // SD-loaded scores remain in the shared SD score RAM only.
    music_score_ram u_score_ram (
        .clk(clk),
        .wbank(1'b0),
        .we(score_ram_we),
        .waddr(score_ram_waddr),
        .wdata(score_ram_wdata),
        .rbank(1'b0),
        .raddr(score_ram_raddr_player[8:0]),
        .rdata(score_ram_rdata)
    );

    // Bluetooth scores use a dedicated volatile distributed RAM. It has no
    // address, data, status, or enable connection to the SD subsystem.
    bt_score_ram u_bt_score_ram (
        .clk(clk),
        .we(dl_ram_we),
        .waddr(dl_ram_waddr),
        .wdata(dl_ram_wdata),
        .raddr(score_ram_raddr_player),
        .rdata(bt_score_ram_rdata)
    );

    uart_record_stream u_record_stream (
        .clk(clk), .rst_n(rst_n_int),
        .record_enable(record_stream_enable),
        .key_mask(panel_key_pressed),
        .timbre_code(timbre_code),
        .octave_shift(current_octave_shift),
        .tx_busy(uart_tx_busy), .tx_grant(rec_tx_grant),
        .tx_req(rec_tx_req), .tx_data(rec_tx_data),
        .packet_count()
    );
    uart_score_download u_score_download (
        .clk(clk), .rst_n(rst_n_int),
        .rx_valid(uart_rx_valid), .rx_data(uart_rx_data),
        .current_timbre(timbre_code),
        .ram_we(dl_ram_we), .ram_waddr(dl_ram_waddr), .ram_wdata(dl_ram_wdata),
        .download_active(dl_active), .download_commit(dl_commit), .download_error(dl_error),
        .record_enable(record_stream_enable),
        .tx_hold_record(record_tx_hold),
        .octave_commit(dl_octave_commit),
        .octave_shift_piano(octave_shift_piano),
        .octave_shift_musicbox(octave_shift_musicbox),
        .octave_shift_epiano(octave_shift_epiano),
        .octave_shift_strings(octave_shift_strings),
        .key_tune_piano(key_tune_piano),
        .key_tune_musicbox(key_tune_musicbox),
        .key_tune_epiano(key_tune_epiano),
        .key_tune_strings(key_tune_strings),
        .tx_start(dl_tx_start), .tx_data(dl_tx_data), .tx_busy(uart_tx_busy),
        .track_count(bt_track_count), .ticks_per_q(bt_ticks_per_q),
        .flags(bt_flags), .tempo_step(bt_tempo_step),
        .event_count(bt_event_count), .event_bytes(bt_event_bytes),
        .body_crc(bt_body_crc), .score_key_map(bt_score_key_map), .state_dbg(dl_state)
    );

    music_score_player u_score_player (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .start(seq_en && !seq_mode), .stop(~seq_en || song_reload || seq_mode), .load_done(player_load_done),
        .track_count(player_track_count), .tempo_step(player_tempo_step),
        .event_count(player_event_count), .flags(player_flags),
        .ram_rdata(player_rdata), .ram_raddr(score_ram_raddr_player),
        .playing(song_player_playing), .done(seq_done),
        .gate_piano(seq_gate_piano), .gate_musicbox(seq_gate_mb),
        .gate_epiano(seq_gate_ep), .gate_strings(seq_gate_str)
    );


    step_sequencer #(.KEY_COUNT(25)) u_step_seq (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .key_pressed(panel_key_pressed),
        .enc_layer(active_enc_layer), .enc_up(panel_seq_enc_up), .enc_down(panel_seq_enc_down),
        .page_toggle(panel_seq_page_toggle), .confirm_pulse(panel_seq_confirm_pulse),
        .start(seq_en && seq_mode), .stop(!seq_en || !seq_mode || song_reload),
        .playing(step_seq_playing), .page(seq_page),
        .selected_row(seq_selected_row), .selected_step(seq_selected_step),
        .speed(seq_speed), .swing(seq_swing), .gate_sel(seq_gate),
        .track_ready(seq_track_ready), .active_mask(seq_active_mask), .selected_entry(seq_selected_entry),
        .gate_piano(step_gate_piano), .gate_musicbox(step_gate_mb),
        .gate_epiano(step_gate_ep), .gate_strings(step_gate_str)
    );

    assign active_seq_gate_piano = seq_mode ? step_gate_piano : seq_gate_piano;
    assign active_seq_gate_mb    = seq_mode ? step_gate_mb    : seq_gate_mb;
    assign active_seq_gate_ep    = seq_mode ? step_gate_ep    : seq_gate_ep;
    assign active_seq_gate_str   = seq_mode ? step_gate_str   : seq_gate_str;
    assign seq_playing = seq_mode ? step_seq_playing : song_player_playing;

    // Local pipeline registers break the player-gate -> audio-engine -> mixer
    // path. One 50 MHz clock is negligible inside a 48.8 kHz sample period.
    reg [24:0] active_seq_gate_piano_q, active_seq_gate_mb_q;
    reg [24:0] active_seq_gate_ep_q, active_seq_gate_str_q;
    reg        seq_chord_mode_q;
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            active_seq_gate_piano_q <= 25'h1FFFFFF;
            active_seq_gate_mb_q    <= 25'h1FFFFFF;
            active_seq_gate_ep_q    <= 25'h1FFFFFF;
            active_seq_gate_str_q   <= 25'h1FFFFFF;
            seq_chord_mode_q        <= 1'b0;
        end else begin
            active_seq_gate_piano_q <= active_seq_gate_piano;
            active_seq_gate_mb_q    <= active_seq_gate_mb;
            active_seq_gate_ep_q    <= active_seq_gate_ep;
            active_seq_gate_str_q   <= active_seq_gate_str;
            seq_chord_mode_q        <= seq_mode ? 1'b0 : player_flags[1];
        end
    end
    //================ Legacy 5-encoder bench controls =================
    wire [7:0] enc_adsr_a, enc_adsr_d, enc_adsr_s, enc_adsr_r, enc_volume;

    enc_param #(.SIGNED(0), .INIT(8'd0),   .STEP(8'd1)) u_enc_a (
        .clk(clk), .rst_n(rst_n_int), .enc_a(enc_a[0]), .enc_b(enc_b[0]), .value(enc_adsr_a));
    enc_param #(.SIGNED(0), .INIT(8'd42),  .STEP(8'd1)) u_enc_d (
        .clk(clk), .rst_n(rst_n_int), .enc_a(enc_a[1]), .enc_b(enc_b[1]), .value(enc_adsr_d));
    enc_param #(.SIGNED(0), .INIT(8'd0),   .STEP(8'd1)) u_enc_s (
        .clk(clk), .rst_n(rst_n_int), .enc_a(enc_a[2]), .enc_b(enc_b[2]), .value(enc_adsr_s));
    enc_param #(.SIGNED(0), .INIT(8'd63),  .STEP(8'd1)) u_enc_r (
        .clk(clk), .rst_n(rst_n_int), .enc_a(enc_a[3]), .enc_b(enc_b[3]), .value(enc_adsr_r));
    enc_param #(.SIGNED(0), .INIT(8'd50),  .STEP(8'd1)) u_enc_vol (
        .clk(clk), .rst_n(rst_n_int), .enc_a(enc_a[4]), .enc_b(enc_b[4]), .value(enc_volume));

    wire [7:0] global_adsr_a = USE_NEW_PANEL ? panel_adsr_a : enc_adsr_a;
    wire [7:0] global_adsr_d = USE_NEW_PANEL ? panel_adsr_d : enc_adsr_d;
    wire [7:0] global_adsr_s = USE_NEW_PANEL ? panel_adsr_s : enc_adsr_s;
    wire [7:0] global_adsr_r = USE_NEW_PANEL ? panel_adsr_r : enc_adsr_r;
    wire [7:0] master_volume = USE_NEW_PANEL ? panel_master_volume : enc_volume;

    wire [7:0] reverb_size     = USE_NEW_PANEL ? panel_reverb_size     : 8'd192;
    wire [7:0] reverb_mix      = USE_NEW_PANEL ? panel_reverb_mix      : 8'd255;
    wire [7:0] delay_time      = USE_NEW_PANEL ? panel_delay_time      : 8'd255;
    wire [7:0] delay_feedback  = USE_NEW_PANEL ? panel_delay_feedback  : 8'd64;
    wire [7:0] chorus_rate     = USE_NEW_PANEL ? panel_chorus_rate     : 8'd96;
    wire [7:0] chorus_depth    = USE_NEW_PANEL ? panel_chorus_depth    : 8'd255;

    wire [126:0] mb_voices_busy;
    wire [126:0] epiano_voices_busy;
    wire [91:0] strings_voices_busy;
    wire [126:0] wt_voices_busy;

    localparam PIANO_TEST_MODE = 1'b0;
    wire signed [5:0] pitch_step_old;
    wire signed [5:0] pitch_step = USE_NEW_PANEL ? panel_pitch_step : pitch_step_old;

    wire [16:0] pitch_ratio_q15, pitch_ratio_eff, pitch_ratio_glide;
    wire [4:0]  glide_key;

    pitch_bend_ctl u_pitch_bend_ctl (
        .clk(clk),
        .rst_n(rst_n_int),
        .btn_up_n(pitch_up_n),
        .btn_down_n(pitch_down_n),
        .pitch_step(pitch_step_old)
    );
    //降调
    pitch_ratio_lut u_pitch_ratio_lut (
        .step_index(pitch_step),
        .ratio_q15(pitch_ratio_q15)
    );

    performance_mod #(.KEY_COUNT(25)) u_performance (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .key_gate(key_gate), .allow_glide(~seq_playing), .vibrato_en(vibrato_en),
        .pitch_ratio_in(pitch_ratio_q15),
        .pitch_ratio_out(pitch_ratio_eff),
        .pitch_ratio_glide_out(pitch_ratio_glide),
        .glide_ratio_out(),
        .glide_active(glide_active), .glide_key(glide_key)
    );
    // 按键只送给"当前选中"的音色引擎：未选中的引擎不发声，
    // 这样它的实时频谱就是空的（用户实测反馈：按钢琴时八音盒频谱不该有数据）。
    // 只听得到的那一路本来就由 audio_mux 选，所以最终音色不受影响。
    wire [24:0] key_gate_piano = seq_playing ? active_seq_gate_piano_q :
        ((timbre_code == 2'd0) ? key_gate : 25'h1FFFFFF);
    wire [24:0] key_gate_mb = seq_playing ? active_seq_gate_mb_q :
        ((timbre_code == 2'd1) ? key_gate : 25'h1FFFFFF);
    wire [24:0] key_gate_ep = seq_playing ? active_seq_gate_ep_q :
        ((timbre_code == 2'd2) ? key_gate : 25'h1FFFFFF);
    wire [24:0] key_gate_str = seq_playing ? active_seq_gate_str_q :
        ((timbre_code == 2'd3) ? key_gate : 25'h1FFFFFF);
    wire [71:0]       piano_voices_busy;
    wire [7:0]        piano_sounding, mb_sounding;
    wire [7:0]        epiano_sounding, strings_sounding, wt_sounding;
    wire piano_any, mb_any, epiano_any, strings_any;
    piano_engine #(.TEST_MODE(PIANO_TEST_MODE), .VOICE_COUNT(72), .KEY_COUNT(25)) u_piano (
        .clk(clk),
        .rst_n(rst_n_int),
        .sample_tick(sample_tick),
        .key_gate(key_gate_piano),
        .test_mode(test_piano_en),
        .pitch_ratio(pitch_ratio_eff),
        .pitch_ratio_glide(pitch_ratio_glide),
        .glide_active(glide_active),
        .glide_key(glide_key),
        .voices_busy(piano_voices_busy),
        .voices_sounding(piano_sounding),
        .adsr_a(global_adsr_a),
        .adsr_d(global_adsr_d),
        .adsr_s(global_adsr_s),
        .adsr_r(global_adsr_r),
        .key_octave_bus(active_oct_piano),
        .key_tune_bus(active_tune_piano),
        .audio_sample(piano_audio), .voices_any(piano_any)
    );
    music_box_engine #(.VOICE_COUNT(127), .KEY_COUNT(25)) u_music_box (
        .clk(clk),
        .rst_n(rst_n_int),
        .sample_tick(sample_tick),
        .key_gate(key_gate_mb),
        .test_mode(test_mb_en),
        .pitch_ratio(pitch_ratio_eff),
        .pitch_ratio_glide(pitch_ratio_glide),
        .glide_active(glide_active),
        .glide_key(glide_key),
        .audio_sample(music_box_audio),
        .voices_busy(mb_voices_busy), .voices_any(mb_any),
        .voices_sounding(mb_sounding),
        .adsr_a(global_adsr_a),
        .adsr_d(global_adsr_d),
        .adsr_s(global_adsr_s),
        .adsr_r(global_adsr_r),
        .key_octave_bus(active_oct_musicbox),
        .key_tune_bus(active_tune_musicbox)
    );

    // 电钢琴/弦乐独立引擎：各自 50 状态与 TDM 算术，共用波表 ROM 和双端口状态 RAM。
    wire [14:0] epiano_wave_addr, strings_wave_addr, wt_rom_addr;
    wire epiano_wave_req, strings_wave_req;
    wire epiano_wave_valid, strings_wave_valid;
    wire signed [15:0] epiano_wave_data, strings_wave_data, wt_rom_data;
    wire [6:0] epiano_state_addr, strings_state_addr;
    wire epiano_state_we, strings_state_we;
    wire [76:0] epiano_state_wdata, strings_state_wdata;
    wire [76:0] epiano_state_rdata, strings_state_rdata;

    wavetable_rom u_wavetable_rom (
        .clk(clk),
        .address(wt_rom_addr),
        .data(wt_rom_data)
    );

    wavetable_rom_arbiter u_wavetable_arb (
        .clk(clk), .rst_n(rst_n_int),
        .req0(epiano_wave_req), .addr0(epiano_wave_addr),
        .req1(strings_wave_req), .addr1(strings_wave_addr),
        .rom_addr(wt_rom_addr), .rom_data(wt_rom_data),
        .valid0(epiano_wave_valid), .valid1(strings_wave_valid),
        .data0(epiano_wave_data), .data1(strings_wave_data)
    );

    wavetable_state_ram #(.EP_DEPTH(127), .STR_DEPTH(92)) u_wavetable_state (
        .clk(clk),
        .ep_addr(epiano_state_addr),
        .ep_we(epiano_state_we),
        .ep_wdata(epiano_state_wdata),
        .ep_rdata(epiano_state_rdata),
        .str_addr(strings_state_addr),
        .str_we(strings_state_we),
        .str_wdata(strings_state_wdata),
        .str_rdata(strings_state_rdata)
    );

    epiano_engine #(.VOICE_COUNT(127), .KEY_COUNT(25)) u_epiano (
        .clk(clk),
        .rst_n(rst_n_int),
        .sample_tick(sample_tick),
        .engine_active(seq_playing || (timbre_code == 2'd2) || test_ep_en),
        .key_gate(key_gate_ep),
        .test_mode(test_ep_en),
        .pitch_ratio(pitch_ratio_eff),
        .pitch_ratio_glide(pitch_ratio_glide),
        .glide_active(glide_active),
        .glide_key(glide_key),
        .adsr_a(global_adsr_a),
        .adsr_d(global_adsr_d),
        .adsr_s(global_adsr_s),
        .adsr_r(global_adsr_r),
        .key_octave_bus(active_oct_epiano),
        .key_tune_bus(active_tune_epiano),
        .wave_data(epiano_wave_data),
        .wave_valid(epiano_wave_valid),
        .wave_addr(epiano_wave_addr),
        .wave_req(epiano_wave_req),
        .state_addr(epiano_state_addr),
        .state_we(epiano_state_we),
        .state_wdata(epiano_state_wdata),
        .state_rdata(epiano_state_rdata),
        .audio_sample(epiano_audio),
        .voices_busy(epiano_voices_busy),
        .voices_any(epiano_any),
        .voices_sounding(epiano_sounding)
    );

    strings_engine #(.VOICE_COUNT(92), .KEY_COUNT(25)) u_strings (
        .clk(clk),
        .rst_n(rst_n_int),
        .sample_tick(sample_tick),
        .engine_active(seq_playing || (timbre_code == 2'd3) || test_str_en),
        .chord_mode(seq_playing && seq_chord_mode_q),
        .key_gate(key_gate_str),
        .test_mode(test_str_en),
        .pitch_ratio(pitch_ratio_eff),
        .pitch_ratio_glide(pitch_ratio_glide),
        .glide_active(glide_active),
        .glide_key(glide_key),
        .adsr_a(global_adsr_a),
        .adsr_d(global_adsr_d),
        .adsr_s(global_adsr_s),
        .adsr_r(global_adsr_r),
        .key_octave_bus(active_oct_strings),
        .key_tune_bus(active_tune_strings),
        .wave_data(strings_wave_data),
        .wave_valid(strings_wave_valid),
        .wave_addr(strings_wave_addr),
        .wave_req(strings_wave_req),
        .state_addr(strings_state_addr),
        .state_we(strings_state_we),
        .state_wdata(strings_state_wdata),
        .state_rdata(strings_state_rdata),
        .audio_sample(strings_audio),
        .voices_busy(strings_voices_busy),
        .voices_any(strings_any),
        .voices_sounding(strings_sounding)
    );

    assign wavetable_audio = timbre_code[0] ? strings_audio : epiano_audio;
    assign wt_sounding = timbre_code[0] ? strings_sounding : epiano_sounding;
    assign wt_voices_busy = timbre_code[0] ? strings_voices_busy : epiano_voices_busy;

    //---------------- 最终主音量 ----------------
    // 位置：两种音色“二选一”之后、I2S 发送之前。
    // 所以它决定的是最终输出音量，与音色、音高、混音路数都无关。
    // 主音量在新板由编码器层 1 控制；旧板保留第 5 路 EC11。

    function signed [15:0] sat16_from_19;
        input signed [18:0] v;
        begin
            if      (v > 19'sd32767)  sat16_from_19 = 16'sd32767;
            else if (v < -19'sd32768) sat16_from_19 = -16'sd32768;
            else                      sat16_from_19 = v[15:0];
        end
    endfunction

    // Register engine outputs next to gain/mixer logic. Engines update on
    // sample_tick; this adds one sample of latency and cuts long I2S paths.
    reg signed [15:0] piano_audio_q, music_box_audio_q;
    reg signed [15:0] epiano_audio_q, strings_audio_q;
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            piano_audio_q <= 16'sd0;
            music_box_audio_q <= 16'sd0;
            epiano_audio_q <= 16'sd0;
            strings_audio_q <= 16'sd0;
        end else if (sample_tick) begin
            piano_audio_q <= piano_audio;
            music_box_audio_q <= music_box_audio;
            epiano_audio_q <= epiano_audio;
            strings_audio_q <= strings_audio;
        end
    end
    // 实测同一按键/包络下八音盒活动段 RMS 比钢琴低约 17 dB。
    // 4x 饱和补偿将单音峰值从约 5k 提到约 20k，同时保留约 4 dB 瞬时余量。
    wire signed [18:0] mb_gain_raw = {{3{music_box_audio_q[15]}}, music_box_audio_q} <<< 2;
    wire signed [15:0] mb_audio_gain = sat16_from_19(mb_gain_raw);

    // 单音色固定增益：EP 1.5x、弦乐 1x，保持 v22 的响度平衡。
    wire signed [18:0] ep_audio_ext = {{3{epiano_audio_q[15]}}, epiano_audio_q};
    wire signed [18:0] str_audio_ext = {{3{strings_audio_q[15]}}, strings_audio_q};
    wire signed [18:0] ep_gain_raw = ep_audio_ext + (ep_audio_ext >>> 1);
    wire signed [15:0] ep_audio_gain = sat16_from_19(ep_gain_raw);
    wire signed [15:0] str_audio_gain = sat16_from_19(str_audio_ext);

    // Second audio pipeline stage: register gain results before the 4-way mix.
    reg signed [15:0] mb_audio_gain_q, ep_audio_gain_q, str_audio_gain_q;
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            mb_audio_gain_q <= 16'sd0;
            ep_audio_gain_q <= 16'sd0;
            str_audio_gain_q <= 16'sd0;
        end else if (sample_tick) begin
            mb_audio_gain_q <= mb_audio_gain;
            ep_audio_gain_q <= ep_audio_gain;
            str_audio_gain_q <= str_audio_gain;
        end
    end

    // Test-key release gate: blank immediately, then hold until every engine's
    // release tail has actually reached zero. This prevents the previous
    // fixed-duration timeout from leaving MB counts/spectrum visible.
    wire test_blank;
    wire test_release_wait;
    test_mode_gate u_test_gate (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .test_any(test_any),
        .piano_any(piano_any), .mb_any(mb_any),
        .ep_any(epiano_any), .str_any(strings_any),
        .blank(test_blank), .release_wait(test_release_wait)
    );
    wire signed [15:0] free_wt_audio = timbre_code[0] ? str_audio_gain_q : ep_audio_gain_q;
    wire signed [15:0] free_audio =
        (timbre_code == 2'd0) ? piano_audio_q :
        (timbre_code == 2'd1) ? mb_audio_gain_q : free_wt_audio;

    // 四音色同时播放时统一缩混 1/4；实际波形峰值留足余量，不改变自由演奏电平。
    wire signed [18:0] piano_ext = {{3{piano_audio_q[15]}}, piano_audio_q};
    wire signed [18:0] mb_ext = {{3{mb_audio_gain_q[15]}}, mb_audio_gain_q};
    wire signed [18:0] ep_ext = {{3{ep_audio_gain_q[15]}}, ep_audio_gain_q};
    wire signed [18:0] str_ext = {{3{str_audio_gain_q[15]}}, str_audio_gain_q};
    wire signed [18:0] seq_str_ext = str_ext - (str_ext >>> 2);
    wire signed [20:0] seq_sum = {{2{piano_ext[18]}}, piano_ext} +
                                      {{2{mb_ext[18]}}, mb_ext} +
                                      {{2{ep_ext[18]}}, ep_ext} +
                                      {{2{seq_str_ext[18]}}, seq_str_ext};
    wire seq_has_piano = (active_seq_gate_piano_q != 25'h1FFFFFF);
    wire seq_has_mb    = (active_seq_gate_mb_q    != 25'h1FFFFFF);
    wire seq_has_ep    = (active_seq_gate_ep_q    != 25'h1FFFFFF);
    wire seq_has_str   = (active_seq_gate_str_q   != 25'h1FFFFFF);
    wire [2:0] seq_active_count = {2'd0,seq_has_piano} + {2'd0,seq_has_mb} +
                                  {2'd0,seq_has_ep} + {2'd0,seq_has_str};
    reg signed [20:0] seq_scaled_21;
    always @* begin
        case (seq_active_count)
            3'd0: seq_scaled_21 = 21'sd0;
            3'd1: seq_scaled_21 = seq_sum;
            3'd2: seq_scaled_21 = seq_sum >>> 1;
            default: seq_scaled_21 = seq_sum >>> 2;
        endcase
    end
    wire signed [15:0] seq_audio = sat16_from_19(seq_scaled_21[18:0]);

    // 四音色 50 声部齐奏测试混音：只混入已开启的音色，并按实际启用数归一化。
    wire signed [18:0] test_piano_ext = test_piano_en ? piano_ext  : 19'sd0;
    wire signed [18:0] test_mb_ext    = test_mb_en    ? mb_ext     : 19'sd0;
    wire signed [18:0] test_ep_ext    = test_ep_en    ? ep_ext     : 19'sd0;
    wire signed [18:0] test_str_ext   = test_str_en   ? str_ext    : 19'sd0;
    wire signed [20:0] test_sum = {{2{test_piano_ext[18]}}, test_piano_ext} +
                                  {{2{test_mb_ext[18]}}, test_mb_ext} +
                                  {{2{test_ep_ext[18]}}, test_ep_ext} +
                                  {{2{test_str_ext[18]}}, test_str_ext};
    wire [2:0] test_count = {2'b0, test_piano_en} + {2'b0, test_mb_en} +
                            {2'b0, test_ep_en} + {2'b0, test_str_en};
    reg signed [20:0] test_scaled;
    always @* begin
        case (test_count)
            3'd0: test_scaled = 21'sd0;
            3'd1: test_scaled = test_sum;
            3'd2: test_scaled = test_sum >>> 1;
            default: test_scaled = test_sum >>> 2;
        endcase
    end
    wire signed [15:0] test_audio = sat16_from_19(test_scaled[18:0]);

    // Third audio pipeline stage: register the selected free/seq/test mixes.
    reg signed [15:0] free_audio_q, seq_audio_q, test_audio_q;
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            free_audio_q <= 16'sd0;
            seq_audio_q <= 16'sd0;
            test_audio_q <= 16'sd0;
        end else if (sample_tick) begin
            free_audio_q <= free_audio;
            seq_audio_q <= seq_audio;
            test_audio_q <= test_audio;
        end
    end
    wire signed [15:0] free_audio_blanked = test_blank ? 16'sd0 : free_audio_q;
    wire signed [15:0] audio_mux = test_any ? test_audio_q :
                                   seq_playing ? seq_audio_q : free_audio_blanked;

    // 频谱只分析当前选中音色的原始输出；EP/弦乐各自独立引擎。
    wire signed [15:0] selected_timbre_audio =
        (timbre_code == 2'd0) ? piano_audio_q :
        (timbre_code == 2'd1) ? music_box_audio_q :
                                wavetable_audio;
    wire [9:0] seq_sound_sum = {2'b0,piano_sounding} + {2'b0,mb_sounding} +
                               {2'b0,epiano_sounding} + {2'b0,strings_sounding};
    wire [9:0] selected_sounding = (test_any || seq_playing)
        ? seq_sound_sum
        : ((timbre_code == 2'd0) ? piano_sounding :
           (timbre_code == 2'd1) ? mb_sounding : wt_sounding);

    wire signed [15:0] audio_rev, audio_dly, audio_fx;

    // Schroeder 混响（en=0 时组合旁路，音频与旧版逐位一致）
    audio_reverb u_reverb (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .sample_in(audio_mux), .en(reverb_en), .sample_out(audio_rev),
        .size(reverb_size), .mix(reverb_mix)
    );

    // 250 ms 反馈延迟（en=0 组合旁路）
    audio_delay u_delay (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .sample_in(audio_rev), .en(delay_en), .sample_out(audio_dly),
        .delay_time(delay_time), .feedback(delay_feedback)
    );

    // 双声部合唱（en=0 组合旁路）
    audio_chorus u_chorus (
        .clk(clk), .rst_n(rst_n_int), .sample_tick(sample_tick),
        .sample_in(audio_dly), .en(chorus_en), .sample_out(audio_fx),
        .rate(chorus_rate), .depth(chorus_depth)
    );

    wire signed [15:0] audio_vol_out;
    // Sequencer and test modes are intentionally dry. Test release also bypasses
    // the FX chain while test_blank is asserted, so a reverb/delay tail cannot
    // keep sounding after the test button has been switched off. Normal free
    // play still uses the original effects chain unchanged.
    wire signed [15:0] audio_to_volume =
        (seq_playing || test_any || test_blank) ? audio_mux : audio_fx;

    // Register the selected audio in the middle of the sample period. This
    // cuts the long engine/mux -> volume multiplier path without adding an
    // extra output-sample latency: the final sample register still captures
    // the same sample at the next sample_tick.
    reg [9:0] audio_pipe_cnt;
    reg signed [15:0] audio_to_volume_q;
    reg signed [15:0] audio_volume_in_q;
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int) begin
            audio_pipe_cnt <= 10'd0;
            audio_to_volume_q <= 16'sd0;
            audio_volume_in_q  <= 16'sd0;
        end else if (sample_tick) begin
            audio_pipe_cnt     <= 10'd0;
            audio_volume_in_q  <= audio_to_volume_q;
        end else begin
            audio_pipe_cnt <= audio_pipe_cnt + 10'd1;
            if (audio_pipe_cnt == 10'd511)
                audio_to_volume_q <= audio_to_volume;
        end
    end

    audio_volume u_volume (
        .sample_in(audio_volume_in_q),
        .volume(master_volume),
        .sample_out(audio_vol_out)
    );

    // 最终音频再打一拍：切断 volume -> I2S/scope 的长组合路径（增加 1 个采样延迟，20.5 us）
    reg signed [15:0] audio_sample_q;
    always @(posedge clk or negedge rst_n_int) begin
        if (!rst_n_int)       audio_sample_q <= 16'sd0;
        else if (sample_tick) audio_sample_q <= audio_vol_out;
    end
    assign audio_sample = audio_sample_q;

    audio_i2s_tx u_i2s (
        .clk(clk),
        .rst_n(rst_n_int),
        .sample_in(audio_sample),
        .sample_tick(sample_tick),
        .I2S_BCLK(I2S_BCLK),
        .I2S_LRCK(I2S_LRCK),
        .I2S_DIN(I2S_DIN)
    );

    assign PA_EN = 1'b0;

    //──────────────── WS2812 note / guide LEDs ────────────────────
    // White: pressed keys when note indication is enabled.
    // Red: the current target note from the on-chip guide melody.
    wire [24:0] led_key_mask = USE_NEW_PANEL ? panel_key_pressed : 25'd0;
    wire [24:0] led_white_mask = led_note_en ? led_key_mask : 25'd0;
    wire [24:0] led_red_mask = guide_en ? guide_note_mask : 25'd0;

    ws2812_guide_driver #(
        .RED_LEVEL(8'd192),
        .WHITE_LEVEL(8'd255),
        .TEST_BRIGHT(8'd0),
        .STARTUP_BLANK_FRAMES(2'd1)
    ) u_ws2812 (
        .clk(clk), .rst_n(rst_n_int), .enable(1'b1),
        .white_mask(led_white_mask), .red_mask(led_red_mask),
        .dout(ws2812_din)
    );
    //=================================================================
    // HDMI 实时显示子系统（视频时钟/时序/实时数据/渲染/TMDS PHY）
    //   只读音频引擎输出与控制量，不改动任何音频通路。
    //=================================================================
    wire hdmi_lock;

    // Test switches own the four spectrum/voice-count panels while any test
    // is active. Releasing the last test clears its panel immediately.
    wire signed [15:0] disp_piano_audio = test_any ? (test_piano_en ? piano_audio_q : 16'sd0) : (test_blank ? 16'sd0 : piano_audio_q);
    wire signed [15:0] disp_mb_audio    = test_any ? (test_mb_en    ? music_box_audio_q : 16'sd0) : (test_blank ? 16'sd0 : music_box_audio_q);
    wire signed [15:0] disp_ep_audio    = test_any ? (test_ep_en    ? epiano_audio_q : 16'sd0) : (test_blank ? 16'sd0 : epiano_audio_q);
    wire signed [15:0] disp_str_audio   = test_any ? (test_str_en   ? strings_audio_q : 16'sd0) : (test_blank ? 16'sd0 : strings_audio_q);
    wire [7:0] disp_piano_sounding = test_any ? (test_piano_en ? piano_sounding : 8'd0) : (test_blank ? 8'd0 : piano_sounding);
    wire [7:0] disp_mb_sounding    = test_any ? (test_mb_en    ? mb_sounding : 8'd0) : (test_blank ? 8'd0 : mb_sounding);
    wire [7:0] disp_ep_sounding    = test_any ? (test_ep_en    ? epiano_sounding : 8'd0) : (test_blank ? 8'd0 : epiano_sounding);
    wire [7:0] disp_str_sounding   = test_any ? (test_str_en   ? strings_sounding : 8'd0) : (test_blank ? 8'd0 : strings_sounding);
    display_top u_display (
        .clk          (clk),
        .rst_n        (rst_n_int),
        .sample_tick  (sample_tick),
        .piano_audio  (disp_piano_audio),
        .mb_audio     (disp_mb_audio),
        .ep_audio     (disp_ep_audio),
        .strings_audio(disp_str_audio),
        .audio_sample (audio_sample),
        .timbre_sel   (timbre_code),
        .master_volume(master_volume),
        .pitch_step  (pitch_step),
        .adsr_a       (global_adsr_a),
        .adsr_d       (global_adsr_d),
        .adsr_s       (global_adsr_s),
        .adsr_r       (global_adsr_r),
        .reverb       ({7'd0, reverb_en}),
        .delay        ({7'd0, delay_en}),
        .chorus       ({7'd0, chorus_en}),
        .reverb_size  (reverb_size),
        .reverb_mix   (reverb_mix),
        .delay_time   (delay_time),
        .delay_feedback(delay_feedback),
        .chorus_rate  (chorus_rate),
        .chorus_depth (chorus_depth),
        .enc_layer    (active_enc_layer),
        .func_layer   (active_func_layer),
        .glide        ({7'd0, glide_active}),
        .vibrato      ({7'd0, vibrato_en}),
        .song_sel     (song_sel),
        .song_count   (song_count),
        .playing      (seq_playing),
        // 注意：display_top 这两个端口是 32 位，必须显式补零到 32 位。
        // 只写 {2'b0, x}（8 位）接到 32 位端口时，高 24 位没有驱动会变成 z，
        // 里面做 popcount 就得到 X，会把声部数/峰值/频谱柱全带坏（这次踩过）。
        .piano_busy   (disp_piano_sounding),
        .mb_busy      (disp_mb_sounding),
        .ep_busy      (disp_ep_sounding),
        .strings_busy (disp_str_sounding),
        .seq_page(seq_page), .seq_active_mask(seq_active_mask), .seq_selected_entry(seq_selected_entry),
        .seq_selected_row(seq_selected_row), .seq_selected_step(seq_selected_step),
        .seq_track_ready(seq_track_ready), .seq_speed(seq_speed),
        .seq_swing(seq_swing), .seq_gate_sel(seq_gate),
        .tmds_data_p  (tmds_data_p),
        .tmds_clk_p   (tmds_clk_p),
        .pll_lock     (hdmi_lock)
    );
endmodule
