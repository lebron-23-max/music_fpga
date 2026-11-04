`timescale 1ns / 1ps
//=============================================================================
// display_top.v —— HDMI 显示子系统顶层（视频时钟 + 时序 + 实时数据 + 渲染 + TMDS PHY）
//=============================================================================
// 时钟域划分：
//   clk     (50 MHz)：音频引擎 + 频谱引擎 + UI 数据写入（原有设计不动）
//   pix_clk (40 MHz)：视频时序 + 全部渲染逻辑 + TMDS 编码
//   ser_clk (200 MHz)：TMDS 10:1 串行化
// 跨域只有两处：scope_capture 的采样握手、ui_data_ram 的双时钟 BSRAM。
//
// 显示内容（全部实时、全部来自真实信号）：
//   1. 最终输出波形（audio_sample 采样缓冲）
//   2. 李萨如图形（同一缓冲的 x-y 相位图）
//   3. 当前 ADSR 参数曲线（四个编码器值实时算出来）
//   4. 四个频谱面板：钢琴/八音盒为真实 Goertzel 频谱 + 频率个数，
//      音色 3/4 未实现 -> 显示 RESERVED，不编造非零数据
//   5. 音量条、变调条、音色框、混响框、ADSR 数值、活跃声部数
//=============================================================================
module display_top (
    input  wire        clk,           // 板载 50 MHz
    input  wire        rst_n,         // 50 MHz 域异步复位，低有效

    // ---- 音频域数据源 ----
    input  wire               sample_tick,
    input  wire signed [15:0] piano_audio,
    input  wire signed [15:0] mb_audio,
    input  wire signed [15:0] ep_audio,
    input  wire signed [15:0] strings_audio,
    input  wire signed [15:0] audio_sample,   // 最终输出（波形/李萨如用）

    // ---- 控制量 ----
    input  wire [1:0]  timbre_sel,   // 4 音色代码 0..3
    input  wire [7:0]  master_volume,
    input  wire signed [5:0]  pitch_step,
    input  wire [7:0]  adsr_a,
    input  wire [7:0]  adsr_d,
    input  wire [7:0]  adsr_s,
    input  wire [7:0]  adsr_r,
    input  wire [7:0]  reverb,
    input  wire [7:0]  delay,
    input  wire [7:0]  chorus,
    input  wire [7:0]  reverb_size,
    input  wire [7:0]  reverb_mix,
    input  wire [7:0]  delay_time,
    input  wire [7:0]  delay_feedback,
    input  wire [7:0]  chorus_rate,
    input  wire [7:0]  chorus_depth,
    input  wire [1:0]  enc_layer,
    input  wire [1:0]  func_layer,
    input  wire [7:0]  glide,
    input  wire [7:0]  vibrato,
    input  wire [2:0]  song_sel,
    input  wire [7:0]  song_count,
    input  wire        playing,
    input  wire [7:0]  piano_busy,
    input  wire [7:0]  mb_busy,
    input  wire [7:0]  ep_busy,
    input  wire [7:0]  strings_busy,
    input  wire        seq_page,
    input  wire [127:0] seq_active_mask,
    input  wire [5:0]  seq_selected_entry,
    input  wire [2:0]  seq_selected_row,
    input  wire [4:0]  seq_selected_step,
    input  wire [3:0]  seq_track_ready,
    input  wire [7:0]  seq_speed, seq_swing, seq_gate_sel,

    // ---- HDMI 输出（差分正端；负端由 IO 差分缓冲驱动，见 tmds_serializer.v）----
    output wire [2:0]  tmds_data_p,
    output wire        tmds_clk_p,
    output wire        pll_lock
);
    //=================================================================
    // 1. 视频时钟
    //=================================================================
    wire pix_clk, ser_clk, pix_rst_n;
    video_clk_gen u_vclk (
        .clk(clk), .rst_n(rst_n),
        .pix_clk(pix_clk), .ser_clk(ser_clk),
        .lock(pll_lock), .pix_rst_n(pix_rst_n)
    );

    //=================================================================
    // 2. 视频时序
    //=================================================================
    wire [9:0] vx, vy;
    wire vde, vhs, vvs, vls, vfs, vblk, vblk_start;

    video_timing u_tim (
        .pix_clk(pix_clk), .rst_n(pix_rst_n),
        .hs(vhs), .vs(vvs), .vde(vde),
        .x(vx), .y(vy),
        .line_start(vls), .frame_start(vfs),
        .vblank(vblk), .vblank_start(vblk_start)
    );

    // Sequencer controls are written in the 50 MHz domain. Register them
    // through two pixel-clock flops before using them in text/render logic.
    reg        seq_page_p0, seq_page_p1;
    reg [2:0]  seq_row_p0, seq_row_p1;
    reg [4:0]  seq_step_p0, seq_step_p1;
    reg [3:0]  seq_ready_p0, seq_ready_p1;
    reg [127:0] seq_mask_p0, seq_mask_p1;
    reg [5:0]  seq_entry_p0, seq_entry_p1;
    reg [7:0]  seq_speed_p0, seq_speed_p1;
    reg [7:0]  seq_swing_p0, seq_swing_p1;
    reg [7:0]  seq_gate_p0, seq_gate_p1;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            seq_page_p0<=0; seq_page_p1<=0;
            seq_row_p0<=0; seq_row_p1<=0; seq_step_p0<=0; seq_step_p1<=0;
            seq_ready_p0<=0; seq_ready_p1<=0; seq_mask_p0<=0; seq_mask_p1<=0;
            seq_entry_p0<=0; seq_entry_p1<=0; seq_speed_p0<=0; seq_speed_p1<=0;
            seq_swing_p0<=0; seq_swing_p1<=0; seq_gate_p0<=0; seq_gate_p1<=0;
        end else begin
            seq_page_p0<=seq_page; seq_page_p1<=seq_page_p0;
            seq_row_p0<=seq_selected_row; seq_row_p1<=seq_row_p0;
            seq_step_p0<=seq_selected_step; seq_step_p1<=seq_step_p0;
            seq_ready_p0<=seq_track_ready; seq_ready_p1<=seq_ready_p0;
            seq_mask_p0<=seq_active_mask; seq_mask_p1<=seq_mask_p0;
            seq_entry_p0<=seq_selected_entry; seq_entry_p1<=seq_entry_p0;
            seq_speed_p0<=seq_speed; seq_speed_p1<=seq_speed_p0;
            seq_swing_p0<=seq_swing; seq_swing_p1<=seq_swing_p0;
            seq_gate_p0<=seq_gate_sel; seq_gate_p1<=seq_gate_p0;
        end
    end
    //=================================================================
    // 3. 采样捕获（最终输出 -> 显示域 512 点缓冲）
    //=================================================================
    wire [8:0]         render_scope_addr;
    wire [8:0]         scope_rd_addr;
    wire signed [15:0] scope_rdata;
    wire [8:0]         cap_ptr;
    wire [15:0]        disp_peak;
    wire [15:0]        liss_period;

    scope_capture u_scope (
        .clk(clk), .sample_tick(sample_tick), .sample_in(audio_sample),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n), .new_frame(vfs),
        .raddr(scope_rd_addr), .rdata(scope_rdata), .cap_ptr(cap_ptr), .peak_lat(disp_peak),
        .period_lat(liss_period)
    );

    //------------------------------------------------------------------
    // 自动量程：找最小右移量，使峰值不超过 30 LSB。
    // 原实现按 MSB 粗略移位后再硬限幅到 ±28，较大信号会出现平顶。
    //------------------------------------------------------------------
    function [3:0] peak_shift;
        input [15:0] peak;
        begin
            if      (peak <= 16'd30)    peak_shift = 4'd0;
            else if (peak <= 16'd60)    peak_shift = 4'd1;
            else if (peak <= 16'd120)   peak_shift = 4'd2;
            else if (peak <= 16'd240)   peak_shift = 4'd3;
            else if (peak <= 16'd480)   peak_shift = 4'd4;
            else if (peak <= 16'd960)   peak_shift = 4'd5;
            else if (peak <= 16'd1920)  peak_shift = 4'd6;
            else if (peak <= 16'd3840)  peak_shift = 4'd7;
            else if (peak <= 16'd7680)  peak_shift = 4'd8;
            else if (peak <= 16'd15360) peak_shift = 4'd9;
            else if (peak <= 16'd30720) peak_shift = 4'd10;
            else                        peak_shift = 4'd11;
        end
    endfunction
    wire [3:0] disp_shift = peak_shift(disp_peak);
    //=================================================================
    // 4. UI 实时数据 RAM（音频域写 / 显示域读）
    //=================================================================
    wire        sp_we;
    wire [7:0]  sp_addr;
    wire [7:0]  sp_data;
    wire        cw_we;
    wire [7:0]  cw_addr;
    wire [7:0]  cw_data;

    wire        ud_we    = sp_we | cw_we;
    wire [7:0]  ud_waddr = sp_we ? sp_addr : cw_addr;
    wire [7:0]  ud_wdata = sp_we ? sp_data : cw_data;

    wire [7:0]  snap_raddr;
    wire        snap_busy;
    wire [7:0]  render_spec_addr;
    wire [7:0]  ud_rdata;

    ui_data_ram u_udram (
        .wclk(clk),  .we(ud_we),  .waddr(ud_waddr), .wdata(ud_wdata),
        .rclk(pix_clk), .raddr(snap_busy ? snap_raddr : render_spec_addr),
        .rdata(ud_rdata)
    );

    wire [31:0] sp_updates;
    spectrum_engine u_spec (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .sig0(piano_audio), .sig1(mb_audio), .sig2(ep_audio), .sig3(strings_audio),
        .ud_we(sp_we), .ud_addr(sp_addr), .ud_data(sp_data),
        .dbg_updates(sp_updates)
    );

    ui_ctrl_writer u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .timbre_sel(timbre_sel),
        .volume(master_volume),
        .pitch_step(pitch_step),
        .adsr_a(adsr_a), .adsr_d(adsr_d), .adsr_s(adsr_s), .adsr_r(adsr_r),
        .reverb(reverb),
        .delay(delay), .chorus(chorus),
        .reverb_size(reverb_size), .reverb_mix(reverb_mix),
        .delay_time(delay_time), .delay_feedback(delay_feedback),
        .chorus_rate(chorus_rate), .chorus_depth(chorus_depth),
        .enc_layer(enc_layer), .func_layer(func_layer),
        .glide(glide), .vibrato(vibrato), .song_sel(song_sel),
        .playing(playing), .song_count(song_count),
        .voice_busy0(piano_busy), .voice_busy1(mb_busy), .voice_busy2(ep_busy), .voice_busy3(strings_busy),
        .we(cw_we), .addr(cw_addr), .data(cw_data)
    );

    //=================================================================
    // 5. 每场快照（消隐期把控制量拷进显示域）
    //=================================================================
    wire [7:0] sn_count0, sn_count1, sn_count2, sn_count3;
    wire [7:0] sn_timbre, sn_volume, sn_pitch_step;
    wire [7:0] sn_a, sn_d, sn_s, sn_r, sn_reverb, sn_delay, sn_chorus;
    wire [7:0] sn_reverb_size, sn_reverb_mix, sn_delay_time, sn_delay_feedback;
    wire [7:0] sn_chorus_rate, sn_chorus_depth;
    wire [7:0] sn_enc_layer, sn_func_layer;
    wire [7:0] sn_glide, sn_vibrato, sn_song, sn_playing, sn_song_count;
    wire [7:0] sn_v0, sn_v1, sn_v2, sn_v3;
    wire       snap_valid;

    ui_snapshot u_snap (
        .clk(pix_clk), .rst_n(pix_rst_n), .start(vblk_start),
        .rd_addr(snap_raddr), .rd_data(ud_rdata),
        .v_count0(sn_count0), .v_count1(sn_count1), .v_count2(sn_count2), .v_count3(sn_count3),
        .v_timbre(sn_timbre), .v_volume(sn_volume), .v_pitch_step(sn_pitch_step),
        .v_a(sn_a), .v_d(sn_d), .v_s(sn_s), .v_r(sn_r),
        .v_reverb(sn_reverb),
        .v_delay(sn_delay), .v_chorus(sn_chorus),
        .v_reverb_size(sn_reverb_size), .v_reverb_mix(sn_reverb_mix),
        .v_delay_time(sn_delay_time), .v_delay_feedback(sn_delay_feedback),
        .v_chorus_rate(sn_chorus_rate), .v_chorus_depth(sn_chorus_depth),
        .v_enc_layer(sn_enc_layer), .v_func_layer(sn_func_layer),
        .v_glide(sn_glide), .v_vibrato(sn_vibrato), .v_song(sn_song),
        .v_playing(sn_playing), .v_song_count(sn_song_count),
        .v_voices0(sn_v0), .v_voices1(sn_v1), .v_voices2(sn_v2), .v_voices3(sn_v3),
        .valid(snap_valid), .busy(snap_busy)
    );

    //=================================================================
    // 6. ADSR 包络曲线表
    //=================================================================
    wire [7:0] render_adsr_addr;
    wire [7:0] adsr_rdata;
    wire [8:0] adsr_segend;

    adsr_curve u_curve (
        .clk(pix_clk), .rst_n(pix_rst_n), .start(snap_valid),
        .a(sn_a), .d(sn_d), .s(sn_s), .r(sn_r),
        .raddr(render_adsr_addr), .rdata(adsr_rdata), .seg_end(adsr_segend)
    );

    //=================================================================
    // 7. 文本层（字符 RAM + 刷新 + 字库）
    //=================================================================
    wire        tw_we;
    wire [11:0] tw_waddr;
    wire [7:0]  tw_wdata;
    wire        tw_busy;
    wire [9:0]  tw_rom_addr;
    wire [8:0]  tw_done;
    wire [11:0] render_text_addr;
    wire [7:0]  text_rdata;
    wire [11:0] render_font_addr;
    wire [15:0] font_rdata;

    ui_text_ram u_tram (
        .clk(pix_clk),
        .we(tw_we), .waddr(tw_waddr), .wdata(tw_wdata),
        .raddr(render_text_addr), .rdata(text_rdata)
    );

    ui_text_writer u_tw (
        .clk(pix_clk), .rst_n(pix_rst_n), .start(snap_valid),
        .rom_addr(tw_rom_addr),
        .we(tw_we), .waddr(tw_waddr), .wdata(tw_wdata),
        .busy(tw_busy), .done_cnt(tw_done),
        .sn_volume(sn_volume), .sn_pitch_step(sn_pitch_step),
        .sn_count0(sn_count0), .sn_count1(sn_count1), .sn_count2(sn_count2), .sn_count3(sn_count3),
        .sn_a(sn_a), .sn_d(sn_d), .sn_s(sn_s), .sn_r(sn_r),
        .sn_timbre(sn_timbre), .sn_reverb(sn_reverb),
        .sn_reverb_size(sn_reverb_size), .sn_reverb_mix(sn_reverb_mix),
        .sn_delay_time(sn_delay_time), .sn_delay_feedback(sn_delay_feedback),
        .sn_chorus_rate(sn_chorus_rate), .sn_chorus_depth(sn_chorus_depth),
        .sn_enc_layer(sn_enc_layer), .sn_func_layer(sn_func_layer),
        .sn_glide(sn_glide), .sn_vibrato(sn_vibrato), .sn_song(sn_song),
        .sn_song_count(sn_song_count),
        .sn_voices0(sn_v0), .sn_voices1(sn_v1), .sn_voices2(sn_v2), .sn_voices3(sn_v3),
        .seq_page(seq_page_p1), .seq_selected_entry(seq_entry_p1),
        .seq_selected_row(seq_row_p1), .seq_selected_step(seq_step_p1),
        .seq_track_ready(seq_ready_p1), .seq_speed(seq_speed_p1),
        .seq_swing(seq_swing_p1), .seq_gate_sel(seq_gate_p1)
    );

    video_font_rom u_font (
        .clk(pix_clk), .addr(render_font_addr), .data(font_rdata)
    );

    //=================================================================
    // 8. 李萨如图形（位图 + 绘制）
    //=================================================================
    wire        liss_busy;
    wire [11:0] render_bmp_addr;
    wire [15:0] bmp_rdata;
    wire [7:0]  liss_done;

    // 李萨如的"有没有音频"判定：用当前音色正在发声的声部数（0 = 静音）
    wire [7:0] liss_nv = (sn_timbre[1:0] == 2'd0) ? sn_v0 :
                        (sn_timbre[1:0] == 2'd1) ? sn_v1 :
                        (sn_timbre[1:0] == 2'd2) ? sn_v2 : sn_v3;
    liss_plot u_liss (
        .pix_clk(pix_clk), .rst_n(pix_rst_n),
        .start(vblk_start), .peak(disp_peak), .nv(liss_nv), .vblank(vblk),
        .rd_addr(render_bmp_addr), .rd_data(bmp_rdata),
        .busy(liss_busy), .done_cnt(liss_done)
    );

    // 示波缓冲读口只给渲染器：李萨如已改成内置 2:3 相位累加器，不再读采样缓冲
    assign scope_rd_addr = render_scope_addr;

    //=================================================================
    // 9. 渲染器
    //=================================================================
    wire [23:0] render_rgb;
    wire        render_de, render_hs, render_vs;
    wire [3:0]  render_zone;

    video_render u_render (
        .clk(pix_clk), .rst_n(pix_rst_n),
        .x(vx), .y(vy), .vde(vde), .hs(vhs), .vs(vvs),
        .cap_ptr(cap_ptr),
        .shift(disp_shift),
        .scope_data(scope_rdata), .bmp_data(bmp_rdata),
        .adsr_data(adsr_rdata), .adsr_segend(adsr_segend), .spec_data(ud_rdata),
        .text_data(text_rdata), .font_data(font_rdata),
        .snap_count0(sn_count0), .snap_count1(sn_count1), .snap_count2(sn_count2), .snap_count3(sn_count3),
        .snap_timbre(sn_timbre), .snap_volume(sn_volume), .snap_pitch(sn_pitch_step),
        .snap_a(sn_a), .snap_d(sn_d), .snap_s(sn_s), .snap_r(sn_r),
        .snap_reverb(sn_reverb), .snap_delay(sn_delay), .snap_chorus(sn_chorus),
        .snap_glide(sn_glide), .snap_vibrato(sn_vibrato), .snap_song(sn_song),
        .snap_playing(sn_playing), .snap_song_count(sn_song_count),
        .snap_voices0(sn_v0), .snap_voices1(sn_v1), .snap_voices2(sn_v2), .snap_voices3(sn_v3),
        .seq_page(seq_page_p1), .seq_selected_row(seq_row_p1),
        .seq_selected_step(seq_step_p1), .seq_track_ready(seq_ready_p1),
        .seq_active_mask(seq_mask_p1),
        .scope_addr(render_scope_addr), .bmp_addr(render_bmp_addr),
        .adsr_addr(render_adsr_addr), .spec_addr(render_spec_addr),
        .text_addr(render_text_addr), .font_addr(render_font_addr),
        .dbg_zone(render_zone),
        .rgb_out(render_rgb), .de_out(render_de),
        .hs_out(render_hs), .vs_out(render_vs)
    );

    //=================================================================
    // 10. TMDS PHY
    //=================================================================
    hdmi_tx_top #(
        .USE_NEG_ODDR(0),
        .USE_OSER10(1) // IOLOGIC 10:1 serializer; removes the FF->ODDR 200 MHz path
    ) u_hdmi (
        .pix_clk(pix_clk),
        .ser_clk(ser_clk),
        .rst_n  (pix_rst_n),
        .vde    (render_de),
        .hs     (render_hs),
        .vs     (render_vs),
        .rgb    (render_rgb),
        .tmds_data_p(tmds_data_p),
        .tmds_data_n(),
        .tmds_clk_p (tmds_clk_p),
        .tmds_clk_n ()
    );

endmodule
