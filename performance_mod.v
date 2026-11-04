`timescale 1ns / 1ps
//=============================================================================
// performance_mod.v —— 连续音级滑音 + 24 位相位 LFO 颤音
//=============================================================================
// 滑音检测参考 Dexed 的“按音符事件逐步逼近目标音高”结构，不依赖全局
// 弯音。只有连续三个以上、同方向、相邻音级（每步 1~2 个半音）在合理时间内
// 出现时，当前新音才使用滑音比例；普通和弦与跳进不会形成该序列。
//
// 颤音参考 Dexed LFO：24 位相位累加器取高 8 位查正弦表。旧版 8 位相位每
// 样本加 26，实际约 4.96 kHz，并不是 5 Hz，这是此前听不出慢速晃动的主因。
//=============================================================================
module performance_mod #(
    parameter integer KEY_COUNT = 12
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire [KEY_COUNT-1:0] key_gate, // 低有效
    input  wire        allow_glide,    // 音序播放时关闭
    input  wire        vibrato_en,
    input  wire [16:0] pitch_ratio_in, // 全局变调 Q15，32768=原音高
    output reg  [16:0] pitch_ratio_out,
    output reg  [16:0] pitch_ratio_glide_out,
    output reg  [16:0] glide_ratio_out,
    output reg         glide_active,
    output reg  [4:0]  glide_key
);
`include "sine_lut8.vh"
    wire [24:0] key_gate_full = {{(25-KEY_COUNT){1'b1}}, key_gate};

    // 连续音级：35~180 ms/步，同方向，每步 1~2 个半音。
    localparam [15:0] GLIDE_GAP_MIN = 16'd1709; // 35 ms @ 48.828125 kHz
    localparam [15:0] GLIDE_GAP_MAX = 16'd8789; // 180 ms
    localparam [16:0] GLIDE_RATIO_TARGET = 17'd32768;
    localparam [23:0] VIB_PHASE_INC = 24'd1718; // 5 Hz @ 48.828125 kHz

    function integer popcount25;
        input [24:0] v;
        integer i;
        begin
            popcount25 = 0;
            for (i = 0; i < 25; i = i + 1)
                popcount25 = popcount25 + v[i];
        end
    endfunction

    function [4:0] only_key;
        input [24:0] v;
        integer i;
        begin
            only_key = 5'h1F;
            for (i = 0; i < 25; i = i + 1)
                if (v[i]) only_key = i[4:0];
        end
    endfunction

    reg [24:0] key_gate_d;
    reg [4:0]  seq_prev_key;
    reg [1:0]  seq_dir;       // 0=none, 1=up, 2=down
    reg [1:0]  seq_count;     // 0..3，3 表示已确认连续音级
    reg [15:0] seq_gap;

    reg [23:0] vib_phase;
    reg [8:0]  vib_amp;
    reg [2:0]  vib_ramp_div;

    wire [24:0] press_set = key_gate_d & ~key_gate_full;
    wire [4:0]  press_key = only_key(press_set);
    wire        one_press = (popcount25(press_set) == 1);
    wire signed [5:0] key_delta = $signed({1'b0, press_key}) -
                                  $signed({1'b0, seq_prev_key});
    wire [5:0] key_mag = (key_delta < 0) ? -key_delta : key_delta;
    wire [1:0] key_dir = (key_delta > 0) ? 2'd1 : 2'd2;
    wire step_pitch_ok = (key_mag == 6'd1) || (key_mag == 6'd2);
    wire step_time_ok = (seq_gap >= GLIDE_GAP_MIN) &&
                        (seq_gap <= GLIDE_GAP_MAX);
    wire chain_extend = (seq_count != 2'd0) && step_pitch_ok && step_time_ok &&
                        ((seq_count == 2'd1) || (seq_dir == key_dir));
    wire glide_trigger = allow_glide && one_press && (seq_count >= 2'd2) && chain_extend;

    // 起点比例 = 上一个连续音相对当前目标音高的频率比。
    wire signed [5:0] glide_key_delta = ({1'b0, seq_prev_key}) -
                                      ({1'b0, press_key});
    wire signed [6:0] glide_step = glide_key_delta * 7'sd2;
    wire [16:0] glide_start_ratio;
    pitch_ratio_lut u_glide_ratio_lut (
        .step_index(glide_step[5:0]),
        .ratio_q15(glide_start_ratio)
    );

    // 24 位 LFO 相位，高 8 位给既有正弦表；最大约 ±27 cents。
    wire signed [7:0]  vib_sin = sin8(vib_phase[23:16]);
    wire signed [11:0] vib_base = {{4{vib_sin[7]}}, vib_sin} <<< 3;
    wire signed [20:0] vib_prod = vib_base * $signed({1'b0, vib_amp});
    wire signed [11:0] vib_offset = vib_prod >>> 8;
    wire signed [19:0] pitch_sum_vib = $signed({1'b0, pitch_ratio_in}) +
                                       {{8{vib_offset[11]}}, vib_offset};
    wire signed [18:0] glide_offset = $signed({1'b0, glide_ratio_out}) - 19'sd32768;
    wire signed [19:0] pitch_sum_glide = pitch_sum_vib +
                                         {{1{glide_offset[18]}}, glide_offset};

    function [16:0] sat17;
        input signed [19:0] v;
        begin
            if      (v > 20'sd65536) sat17 = 17'h10000;
            else if (v < 20'sd8192)  sat17 = 17'd8192;
            else                     sat17 = v[16:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_gate_d            <= 25'h1FFFFFF;
            seq_prev_key          <= 5'h1F;
            seq_dir               <= 2'd0;
            seq_count             <= 2'd0;
            seq_gap               <= 16'd0;
            vib_phase             <= 24'd0;
            vib_amp               <= 9'd0;
            vib_ramp_div          <= 3'd0;
            pitch_ratio_out       <= 17'd32768;
            pitch_ratio_glide_out <= 17'd32768;
            glide_ratio_out       <= 17'd32768;
            glide_active          <= 1'b0;
            glide_key             <= 5'h1F;
        end else if (sample_tick) begin
            key_gate_d <= key_gate_full;
            if (seq_gap != 16'hFFFF) seq_gap <= seq_gap + 16'd1;

            //---------------- 连续音级手势分类 ----------------
            if (!allow_glide) begin
                seq_prev_key <= 5'h1F;
                seq_dir      <= 2'd0;
                seq_count    <= 2'd0;
                seq_gap      <= 16'd0;
            end else if (popcount25(press_set) > 1) begin
                seq_count <= 2'd0;
                seq_dir   <= 2'd0;
                seq_gap   <= 16'd0;
            end else if (one_press) begin
                seq_gap <= 16'd0;
                if (seq_count == 2'd0) begin
                    seq_prev_key <= press_key;
                    seq_dir      <= 2'd0;
                    seq_count    <= 2'd1;
                end else if (chain_extend) begin
                    seq_prev_key <= press_key;
                    seq_dir      <= key_dir;
                    if (seq_count >= 2'd2) begin
                        seq_count       <= 2'd3;
                        glide_key       <= press_key;
                        glide_ratio_out <= glide_start_ratio;
                        glide_active    <= 1'b1;
                    end else begin
                        seq_count <= 2'd2;
                    end
                end else begin
                    seq_prev_key <= press_key;
                    seq_dir      <= 2'd0;
                    seq_count    <= 2'd1;
                end
            end

            //---------------- 当前滑音声部向目标音高收敛 ----------------
            if (glide_trigger) begin
                glide_ratio_out <= glide_start_ratio;
                glide_active    <= 1'b1;
                glide_key       <= press_key;
            end else if (!glide_active) begin
                glide_ratio_out <= GLIDE_RATIO_TARGET;
                glide_key       <= 5'h1F;
            end else if (glide_ratio_out > GLIDE_RATIO_TARGET) begin
                if ((glide_ratio_out - GLIDE_RATIO_TARGET) <= 17'd3)
                    glide_ratio_out <= GLIDE_RATIO_TARGET;
                else
                    glide_ratio_out <= glide_ratio_out - 17'd3;
            end else if (glide_ratio_out < GLIDE_RATIO_TARGET) begin
                if ((GLIDE_RATIO_TARGET - glide_ratio_out) <= 17'd3)
                    glide_ratio_out <= GLIDE_RATIO_TARGET;
                else
                    glide_ratio_out <= glide_ratio_out + 17'd3;
            end else begin
                glide_active <= 1'b0;
                glide_key    <= 5'h1F;
            end
            if (!allow_glide) begin
                glide_active    <= 1'b0;
                glide_ratio_out <= GLIDE_RATIO_TARGET;
                glide_key       <= 5'h1F;
            end

            //---------------- 5 Hz 颤音 LFO ----------------
            if (vibrato_en) begin
                vib_phase <= vib_phase + VIB_PHASE_INC;
                if (vib_ramp_div == 3'd7) begin
                    vib_ramp_div <= 3'd0;
                    if (vib_amp < 9'd256) vib_amp <= vib_amp + 9'd1;
                end else begin
                    vib_ramp_div <= vib_ramp_div + 3'd1;
                end
            end else begin
                if (vib_ramp_div == 3'd7) begin
                    vib_ramp_div <= 3'd0;
                    if (vib_amp > 9'd1) vib_amp <= vib_amp - 9'd1;
                    else                vib_amp <= 9'd0;
                end else begin
                    vib_ramp_div <= vib_ramp_div + 3'd1;
                end
                if (vib_amp == 9'd0) vib_phase <= 24'd0;
            end

            pitch_ratio_out       <= sat17(pitch_sum_vib);
            pitch_ratio_glide_out <= sat17(pitch_sum_glide);
        end
    end
endmodule