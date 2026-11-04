`timescale 1ns / 1ps
//=============================================================================
// piano_voice.v
// 单个钢琴音符级声部（主弦 + 失谐副弦状态与共享时隙接口）。
//
// 每个实例固定对应一个音高，内部包含：
//   1. 主弦独立相位累加器、频率增量、帧状态和包络；
//   2. 失谐副弦独立相位累加器、频率增量、帧状态和包络；
//   3. 两个弦共用一个外部共享波表 ROM 的读时隙接口；
//   4. 帧插值和采样值×包络乘法由顶层共享 DSP 时隙完成。
//
// 波表 ROM 由顶层 piano_shared_wave_rom 统一提供。本模块只输出当前
// 时隙需要的 ROM 地址，并在对应时隙锁存 ROM 数据。因此 12 个实例
// 虽然共享存储，但每个音符仍拥有独立的相位/频率/包络状态。
//=============================================================================
module piano_voice #(
    parameter [5:0] NOTE_INDEX = 6'd0,
    parameter [5:0] VOICE_ID   = 6'd0,

    // 与 music_2 原稳定版保持一致的按键包络参数。
    parameter [15:0] ATTACK_STEP        = 16'd269,
    parameter [16:0] LONG_HOLD_SAMPLES  = 17'd12_207,
    parameter [16:0] TAIL_START_SAMPLES = 17'd48_828,
    parameter [15:0] TAIL_FLOOR         = 16'd16384,
    parameter [15:0] TAIL_DECAY_COEFF   = 16'd8,
    parameter [15:0] RELEASE_COEFF      = 16'd16
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               note_gate,       // 低有效，独立音符键门
    input  wire [16:0]        pitch_ratio,     // Q15：基础变调 + 颤音
    input  wire [16:0]        pitch_ratio_glide,
    input  wire               glide_active,
    input  wire [5:0]         glide_note,
    input  wire               shared_frame,     // 1=测试模式，32 声部共享帧状态
    input  wire [2:0]         shared_frame_idx,
    input  wire [16:0]        shared_segment_count,
    input  wire [15:0]        shared_blend,
    input  wire [15:0]        gain_main,        // 共享包络引擎输出的主弦包络
    input  wire [15:0]        gain_detune,      // 共享包络引擎输出的副弦包络

    // 顶层共享 ROM 扫描接口。
    input  wire [7:0]         scan_slot,
    input  wire [7:0]         scan_slot_d,
    input  wire               scan_valid_d,
    input  wire signed [15:0] rom_data,

    // 共享乘法流水线接口。所有 voice 共享硬件乘法器，
    // 但各自仍有独立的 phase_acc、phase_inc、frame 和 envelope 状态。
    input  wire [7:0]         arith_slot,
    input  wire [7:0]         arith_slot_d,
    input  wire               arith_valid_d,
    input  wire signed [35:0] arith_product,
    input  wire signed [35:0] frame_mac_result,
    output wire signed [17:0] arith_a,
    output wire signed [17:0] arith_b,
    output wire signed [17:0] frame_add,

    output wire [13:0]        rom_addr,
    output wire signed [15:0] voice_out,
    output wire               voice_busy
);

    localparam [2:0] LAST_FRAME = 3'd7;

    //-------------------------------------------------------------------------
    // 固定音高和失谐副弦频率
    //-------------------------------------------------------------------------
`include "piano_note_inc.vh"

    localparam [31:0] PHASE_INC_MAIN = piano_phase_inc(NOTE_INDEX);
    localparam [31:0] PHASE_INC_DETUNE =
        PHASE_INC_MAIN + (PHASE_INC_MAIN >> 9) + (PHASE_INC_MAIN >> 11);

    // Q15 变调比：+1200 cents=131072（2x），0 cents=32768（1x），-1200 cents=16384（0.5x）
    // 滑音只选择正在连奏的新键；固定音高旧声部继续使用普通音高比。
    wire [16:0] voice_pitch_ratio =
        (glide_active && (NOTE_INDEX == glide_note))
        ? pitch_ratio_glide : pitch_ratio;
    wire [48:0] bend_prod_main = PHASE_INC_MAIN * voice_pitch_ratio;
    wire [48:0] bend_prod_det  = PHASE_INC_DETUNE * voice_pitch_ratio;
    wire [33:0] inc_main_scaled = bend_prod_main >>> 15;
    wire [33:0] inc_detune_scaled = bend_prod_det >>> 15;
    wire [31:0] inc_main_use   = |inc_main_scaled[33:32] ? 32'd0 : inc_main_scaled[31:0];
    wire [31:0] inc_detune_use = |inc_detune_scaled[33:32] ? 32'd0 : inc_detune_scaled[31:0];

    // 与当前稳定音色一致：C4~F4 使用 C4 根音，F#4~B4 使用 A4 根音。
    localparam ROOT_IS_A4 = (NOTE_INDEX >= 4'd6);
    localparam [1:0] ROOT_BANK = ROOT_IS_A4 ? 2'd2 : 2'd0;

    // 副弦包络使用略有差异的参数，避免综合器把两个包络状态机误合并。
    localparam [15:0] DETUNE_ATTACK_STEP  = ATTACK_STEP + 16'd1;
    localparam [16:0] DETUNE_TAIL_START   = TAIL_START_SAMPLES - 17'd1;
    localparam [15:0] DETUNE_TAIL_COEFF   = TAIL_DECAY_COEFF + 16'd1;
    localparam [15:0] DETUNE_RELEASE_COEFF = RELEASE_COEFF - 16'd1;

    //-------------------------------------------------------------------------
    // 主弦和失谐副弦的独立状态
    //-------------------------------------------------------------------------
    reg [31:0] phase_acc_main;
    reg [31:0] phase_acc_detune;

    reg [2:0]  frame_idx_main;
    reg [2:0]  frame_idx_detune;
    reg [16:0] segment_count_main;
    reg [16:0] segment_count_detune;
    reg [15:0] blend_main;
    reg [15:0] blend_detune;

    reg signed [15:0] bank0_sample_main;
    reg signed [15:0] bank1_sample_main;
    reg signed [15:0] bank0_sample_detune;
    reg signed [15:0] bank1_sample_detune;

    reg signed [15:0] main_sample;
    reg signed [15:0] detune_sample;

    // 在 ROM 扫描阶段锁存 frame 插值所需操作数，
    // 等共享乘法器返回后，再把结果写回 main_sample / detune_sample。
    reg signed [16:0] frame_delta_main_q;
    reg signed [16:0] frame_delta_detune_q;
    reg [15:0]        frame_blend_main_q;
    reg [15:0]        frame_blend_detune_q;
    reg signed [15:0] frame_rom_a_main_q;
    reg signed [15:0] frame_rom_a_detune_q;
    reg               frame_pending_main;
    reg               frame_pending_detune;

    // 共享乘法器的包络乘法结果。
    reg signed [15:0] envelope_main_sample;
    reg signed [15:0] envelope_detune_sample;

    reg        gate_pressed_d;
    reg        note_active;

    wire gate_pressed = ~note_gate;
    wire trigger      = gate_pressed && !gate_pressed_d;

    //-------------------------------------------------------------------------
    // 当前相位对应的 bank 地址
    //-------------------------------------------------------------------------
    wire [9:0] phase_addr_main   = phase_acc_main[31:22];
    wire [9:0] phase_addr_detune = phase_acc_detune[31:22];

    wire [2:0]  frame_idx_main_use   = shared_frame ? shared_frame_idx : frame_idx_main;
    wire [2:0]  frame_idx_detune_use = shared_frame ? shared_frame_idx : frame_idx_detune;
    wire [16:0] segment_count_main_use   = shared_frame ? shared_segment_count : segment_count_main;
    wire [16:0] segment_count_detune_use = shared_frame ? shared_segment_count : segment_count_detune;
    wire [15:0] blend_main_use   = shared_frame ? shared_blend : blend_main;
    wire [15:0] blend_detune_use = shared_frame ? shared_blend : blend_detune;

    wire [2:0] next_frame_main = (frame_idx_main_use == LAST_FRAME) ?
                                  LAST_FRAME : (frame_idx_main_use + 3'd1);
    wire [2:0] next_frame_detune = (frame_idx_detune_use == LAST_FRAME) ?
                                    LAST_FRAME : (frame_idx_detune_use + 3'd1);

    wire [1:0] pair_idx_main = frame_idx_main_use[2:1];
    wire [1:0] pair_idx_detune = frame_idx_detune_use[2:1];

    wire [1:0] bank0_frame_main = (frame_idx_main_use == LAST_FRAME) ? pair_idx_main :
                                  (frame_idx_main_use[0] ? (pair_idx_main + 2'd1) : pair_idx_main);
    wire [1:0] bank1_frame_main = pair_idx_main;

    wire [1:0] bank0_frame_detune = (frame_idx_detune_use == LAST_FRAME) ? pair_idx_detune :
                                    (frame_idx_detune_use[0] ? (pair_idx_detune + 2'd1) : pair_idx_detune);
    wire [1:0] bank1_frame_detune = pair_idx_detune;

    wire [11:0] bank0_addr_main = {bank0_frame_main, phase_addr_main};
    wire [11:0] bank1_addr_main = {bank1_frame_main, phase_addr_main};
    wire [11:0] bank0_addr_detune = {bank0_frame_detune, phase_addr_detune};
    wire [11:0] bank1_addr_detune = {bank1_frame_detune, phase_addr_detune};

    wire [13:0] addr_main_bank0   = {ROOT_BANK,       bank0_addr_main};
    wire [13:0] addr_main_bank1   = {ROOT_BANK | 2'd1, bank1_addr_main};
    wire [13:0] addr_detune_bank0 = {ROOT_BANK,       bank0_addr_detune};
    wire [13:0] addr_detune_bank1 = {ROOT_BANK | 2'd1, bank1_addr_detune};

    // 每个音符占用 4 个连续读时隙：
    //   slot[1:0]=0 主弦 bank0
    //   slot[1:0]=1 主弦 bank1
    //   slot[1:0]=2 副弦 bank0
    //   slot[1:0]=3 副弦 bank1
    reg [13:0] rom_addr_r;
    always @* begin
        if (scan_slot[7:2] == VOICE_ID) begin
            case (scan_slot[1:0])
            2'd0: rom_addr_r = addr_main_bank0;
            2'd1: rom_addr_r = addr_main_bank1;
            2'd2: rom_addr_r = addr_detune_bank0;
            default: rom_addr_r = addr_detune_bank1;
            endcase
        end else begin
            rom_addr_r = 14'd0;
        end
    end
    assign rom_addr = rom_addr_r;

    //-------------------------------------------------------------------------
    // frame 插值常数，与旧版 piano_dds_48k 完全一致。
    //-------------------------------------------------------------------------
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

    // 在当前 bank1 时隙，rom_data 就是刚读出的 B 帧数据。
    // 这里只锁存 A/B 帧差值和混合系数，真正的乘法由顶层共享 DSP 完成。
    wire signed [15:0] main_rom_a_capture = frame_idx_main_use[0] ? rom_data : bank0_sample_main;
    wire signed [15:0] main_rom_b_capture = (frame_idx_main_use == LAST_FRAME) ? main_rom_a_capture :
                                            (frame_idx_main_use[0] ? bank0_sample_main : rom_data);
    wire signed [16:0] main_frame_delta_capture = main_rom_b_capture - main_rom_a_capture;

    wire signed [15:0] detune_rom_a_capture = frame_idx_detune_use[0] ? rom_data : bank0_sample_detune;
    wire signed [15:0] detune_rom_b_capture = (frame_idx_detune_use == LAST_FRAME) ? detune_rom_a_capture :
                                              (frame_idx_detune_use[0] ? bank0_sample_detune : rom_data);
    wire signed [16:0] detune_frame_delta_capture = detune_rom_b_capture - detune_rom_a_capture;


    // 当前时隙对应哪个钢琴声部的哪一次乘法。
    //   slot[1:0]=0: 主弦 frame 插值
    //   slot[1:0]=1: 副弦 frame 插值
    //   slot[1:0]=2: 主弦 sample x envelope
    //   slot[1:0]=3: 副弦 sample x envelope
    reg signed [17:0] arith_a_r;
    reg signed [17:0] arith_b_r;
    reg signed [17:0] frame_add_r;
    always @* begin
        arith_a_r = 18'sd0;
        arith_b_r = 18'sd0;
        frame_add_r = 18'sd0;

        if (arith_slot[7:2] == VOICE_ID) begin
            case (arith_slot[1:0])
            2'd0: begin
                if (frame_pending_main) begin
                    arith_a_r = {{1{frame_delta_main_q[16]}}, frame_delta_main_q};
                    arith_b_r = {2'b00, frame_blend_main_q};
                    frame_add_r = {{2{frame_rom_a_main_q[15]}}, frame_rom_a_main_q};
                end
            end
            2'd1: begin
                if (frame_pending_detune) begin
                    arith_a_r = {{1{frame_delta_detune_q[16]}}, frame_delta_detune_q};
                    arith_b_r = {2'b00, frame_blend_detune_q};
                    frame_add_r = {{2{frame_rom_a_detune_q[15]}}, frame_rom_a_detune_q};
                end
            end
            2'd2: begin
                if (note_active) begin
                    arith_a_r = {{2{main_sample[15]}}, main_sample};
                    arith_b_r = {2'b00, gain_main};
                end
            end
            default: begin
                if (note_active) begin
                    arith_a_r = {{2{detune_sample[15]}}, detune_sample};
                    arith_b_r = {2'b00, gain_detune};
                end
            end
            endcase
        end
    end

    assign arith_a = arith_a_r;
    assign arith_b = arith_b_r;
    assign frame_add = frame_add_r;

    //-------------------------------------------------------------------------
    // 状态更新：按键下降沿复位；扫描到 bank1 时推进相位和帧。
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc_main     <= 32'h0000_0000;
            phase_acc_detune   <= 32'h4000_0000;
            frame_idx_main     <= 3'd0;
            frame_idx_detune   <= 3'd0;
            segment_count_main <= 17'd0;
            segment_count_detune <= 17'd0;
            blend_main         <= 16'd0;
            blend_detune       <= 16'd0;
            bank0_sample_main     <= 16'sd0;
            bank1_sample_main     <= 16'sd0;
            bank0_sample_detune   <= 16'sd0;
            bank1_sample_detune   <= 16'sd0;
            frame_delta_main_q    <= 17'sd0;
            frame_delta_detune_q  <= 17'sd0;
            frame_blend_main_q    <= 16'd0;
            frame_blend_detune_q  <= 16'd0;
            frame_rom_a_main_q    <= 16'sd0;
            frame_rom_a_detune_q  <= 16'sd0;
            frame_pending_main    <= 1'b0;
            frame_pending_detune  <= 1'b0;
            main_sample        <= 16'sd0;
            detune_sample      <= 16'sd0;
            envelope_main_sample   <= 16'sd0;
            envelope_detune_sample <= 16'sd0;
            gate_pressed_d     <= 1'b0;
            note_active        <= 1'b0;
        end else begin
            if (sample_tick) begin
                gate_pressed_d <= gate_pressed;

                if (trigger) begin
                    note_active        <= 1'b1;
                    phase_acc_main     <= 32'h0000_0000;
                    phase_acc_detune   <= 32'h4000_0000;
                    frame_idx_main     <= 3'd0;
                    frame_idx_detune   <= 3'd0;
                    segment_count_main <= 17'd0;
                    segment_count_detune <= 17'd0;
                    blend_main         <= 16'd0;
                    blend_detune       <= 16'd0;
                    bank0_sample_main     <= 16'sd0;
                    bank1_sample_main     <= 16'sd0;
                    bank0_sample_detune   <= 16'sd0;
                    bank1_sample_detune   <= 16'sd0;
                    frame_delta_main_q    <= 17'sd0;
                    frame_delta_detune_q  <= 17'sd0;
                    frame_blend_main_q    <= 16'd0;
                    frame_blend_detune_q  <= 16'd0;
                    frame_rom_a_main_q    <= 16'sd0;
                    frame_rom_a_detune_q  <= 16'sd0;
                    frame_pending_main    <= 1'b0;
                    frame_pending_detune  <= 1'b0;
                    main_sample        <= 16'sd0;
                    detune_sample      <= 16'sd0;
                    envelope_main_sample   <= 16'sd0;
                    envelope_detune_sample <= 16'sd0;
                end
            end

            if (scan_valid_d && (scan_slot_d[7:2] == VOICE_ID)) begin
                case (scan_slot_d[1:0])
                2'd0: begin
                    bank0_sample_main <= rom_data;
                end

                2'd1: begin
                    if (note_active) begin
                        bank1_sample_main   <= rom_data;
                        frame_delta_main_q  <= main_frame_delta_capture;
                        frame_blend_main_q  <= blend_main;
                        frame_rom_a_main_q  <= main_rom_a_capture;
                        frame_pending_main  <= 1'b1;
                    end
                end

                2'd2: begin
                    bank0_sample_detune <= rom_data;
                end

                default: begin
                    if (note_active) begin
                        bank1_sample_detune   <= rom_data;
                        frame_delta_detune_q  <= detune_frame_delta_capture;
                        frame_blend_detune_q  <= blend_detune;
                        frame_rom_a_detune_q  <= detune_rom_a_capture;
                        frame_pending_detune  <= 1'b1;
                    end
                end
                endcase
            end

            // 共享乘法器结果返回后，再更新当前钢琴声部的独立状态。
            if (arith_valid_d && (arith_slot_d[7:2] == VOICE_ID)) begin
                case (arith_slot_d[1:0])
                2'd0: begin
                    if (frame_pending_main) begin
                        main_sample    <= frame_mac_result[31:16];
                        phase_acc_main <= phase_acc_main + inc_main_use;
                        frame_pending_main <= 1'b0;

                        if (!shared_frame && (frame_idx_main_use < LAST_FRAME)) begin
                            if ((segment_count_main_use + 17'd1) >= segment_length(frame_idx_main_use)) begin
                                frame_idx_main     <= next_frame_main;
                                segment_count_main <= 17'd0;
                                blend_main         <= 16'd0;
                            end else begin
                                segment_count_main <= segment_count_main_use + 17'd1;
                                if (blend_main_use > (16'hFFFF - segment_step(frame_idx_main_use)))
                                    blend_main <= 16'hFFFF;
                                else
                                    blend_main <= blend_main_use + segment_step(frame_idx_main_use);
                            end
                        end
                    end
                end

                2'd1: begin
                    if (frame_pending_detune) begin
                        detune_sample  <= frame_mac_result[31:16];
                        phase_acc_detune <= phase_acc_detune + inc_detune_use;
                        frame_pending_detune <= 1'b0;

                        if (!shared_frame && (frame_idx_detune_use < LAST_FRAME)) begin
                            if ((segment_count_detune_use + 17'd1) >= segment_length(frame_idx_detune_use)) begin
                                frame_idx_detune     <= next_frame_detune;
                                segment_count_detune <= 17'd0;
                                blend_detune         <= 16'd0;
                            end else begin
                                segment_count_detune <= segment_count_detune_use + 17'd1;
                                if (blend_detune_use > (16'hFFFF - segment_step(frame_idx_detune_use)))
                                    blend_detune <= 16'hFFFF;
                                else
                                    blend_detune <= blend_detune_use + segment_step(frame_idx_detune_use);
                            end
                        end
                    end
                end

                2'd2: begin
                    envelope_main_sample <= arith_product[31:16];
                end

                default: begin
                    envelope_detune_sample <= arith_product[31:16];
                end
                endcase
            end
        end
    end

    assign voice_busy = note_active;

    // 主/副弦各自乘自己的包络后等幅混合，输出与旧版完全相同的音色层。
    wire signed [16:0] voice_sum = envelope_main_sample + envelope_detune_sample;
    assign voice_out = voice_sum >>> 1;

endmodule
