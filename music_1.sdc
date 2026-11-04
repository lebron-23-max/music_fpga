create_clock -name clk_50m -period 20 -waveform {0 10} [get_ports {clk}]
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk_50m}] -to [get_clocks {clk_50m}]
# clk_50m 与 pix/ser 之间的数据只通过 double-clock BSRAM + 序号握手传递，
# 属于异步时钟组；显式约束可避免把 CDC RAM 路径当作同源同步路径分析。
# 接收域寄存器的 CDC 伪路径：双时钟 BSRAM + 序号握手。
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/u_scope/*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/u_snap/*}]
# 复位异步进入各时钟域后先经过两级同步，复位同步链是 CDC，不是数据路径。
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/u_vclk/rst_sync_*}]
set_false_path -from [get_regs {u_music/u_display/u_vclk/rst_sync_*}] -to [get_regs {u_music/u_display/u_hdmi/ser_rst_sync_*}]
# OSER10 RESET is an asynchronous clear input. Its release is already generated
# by the two-flop ser-domain synchronizer; it is not a 200 MHz data path.
set_false_path -from [get_regs {u_music/u_display/u_hdmi/ser_rst_sync_*}] -to [get_pins {u_music/u_display/u_hdmi/u_ser/g_oser_path.oser_*/RESET}]
# 音序器编辑状态进入显示域时先经过两级触发器同步。第一级是本域采样，
# 不从 50 MHz 时钟做同步 setup/hold 检查；第二级及其后仍按 pix_clk 正常分析。
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_page_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_row_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_step_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_ready_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_mask_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_entry_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_speed_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_swing_p0*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/seq_gate_p0*}]
# Slow user-control selectors: song/test/timbre changes are debounced UI events.
# A one-sample transition glitch is acceptable; audio data inputs remain timed.
set_false_path -from [get_regs {u_music/song_sel_*}]
set_false_path -from [get_regs {u_music/u_panel/test_*_en_*}]
set_false_path -from [get_regs {u_music/u_panel/timbre_code_*}]
set_false_path -from [get_regs {u_music/u_score_player/playing_*}]
set_false_path -from [get_regs {u_music/u_step_seq/playing_*}]
set_false_path -from [get_regs {u_music/u_test_gate/*}]
# Spectrum and control panels are display-only; they do not feed the audio path.
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/u_spec/*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/u_ctrl/*}]
set_false_path -from [get_clocks {clk_50m}] -to [get_regs {u_music/u_display/u_liss/*}]
