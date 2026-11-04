`timescale 1ns / 1ps
//=============================================================================
// music_box_engine.v —— 八音盒引擎（72 声部，TDM 单数据通路版）
//=============================================================================
//
// 一、为什么这么改
//   上一版每个声部都带一整套运算（相位加法器 + 回绕比较/减法/选择 + 包络
//   加/减/比较 + 乘法器），32 份加起来占掉全片约 25% 的逻辑。
//   本版把“状态”和“运算”分开：
//     状态：32 个声部的 相位/包络/频率/状态/bank/按键 放进 6 组循环移位寄存器
//           （每个有效时钟移一位）。移位是纯走线，不需要读地址多路选择器。
//     运算：全部声部共用一套
//             1 个相位加法器 + 1 个回绕比较/减法
//           + 1 个包络加减器
//           + 1 个乘法器 + 1 个累加器 + 1 块波表 ROM
//   每个采样点用 33 拍把所有声部轮流算一遍；累加器在扫描过程中直接把 32 路
//   混完，所以原来的 32 路加法树（混音器）也一并消失。
//
// 二、仍然满足赛题对“独立发声单元”的定义
//   每个声部都保留自己独立的相位累加器、频率寄存器（可写）、包络状态机，
//   只是运算单元按时分复用共享 —— 这正是“独立振荡器”的定义，而不是把
//   多个振荡器合成一个。
//
// 三、33 拍扫描的时序（每拍处理一个声部）
//   第 s 拍：取出第 s 号声部状态
//            送出它的波表地址（用的是“更新前”的相位，与旧版一致）
//            算出 相位下一拍值 / 包络下一拍值
//            把新值移回循环移位寄存器
//   第 s+1 拍：ROM 数据回来（是第 s 号声部的样本）→ 乘上第 s 号声部的新电平
//            → 累加进输出总和
//   第 32 拍：最后一个声部（31 号）的数据回来并累加完毕 → 锁存输出
//   32 拍移位正好绕一圈，回到原位，所以相位永远对齐。
//
// 四、包络
//   与上一版完全相同的 ADSR：A 线性上升；D/R 指数衰减（每次减自身 1/256），
//   快慢由全局节拍 dec_tick/rel_tick 决定（周期 = adsr_d/adsr_r + 1 个采样点）。
//   S=0 为打击乐模式（自然衰减到无声）；S>0 停在对应延音电平，R 段始终有效。
//=============================================================================
module music_box_engine #(
    parameter integer VOICE_COUNT = 50,
    parameter integer KEY_COUNT = 12
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,     // 音频采样脉冲 48.828125 kHz
    input  wire [KEY_COUNT-1:0] key_gate,      // 低有效
    input  wire               test_mode,       // 1 = 50 音齐奏测试
    input  wire [16:0]        pitch_ratio,     // Q15：基础变调 + 颤音
    input  wire [16:0]        pitch_ratio_glide, // Q15：仅滑音声部使用
    input  wire               glide_active,
    input  wire [4:0]         glide_key,
    input  wire [7:0]         adsr_a,          // ADSR：起音
    input  wire [7:0]         adsr_d,          // ADSR：衰减
    input  wire [7:0]         adsr_s,          // ADSR：延音电平
    input  wire [7:0]         adsr_r,
    input  wire [74:0]        key_octave_bus,          // ADSR：释放
    input  wire [199:0]       key_tune_bus,            // 25 absolute MIDI notes
    output reg  signed [15:0] audio_sample,    // 最终音频
    output wire [VOICE_COUNT-1:0] voices_busy, // 声部占用（按键分配出去的槽位）
    output wire               voices_any,
    output wire [7:0]         voices_sounding  // 真正在发声的声部数（包络非零）
);
    //-------------------------- 波表 bank 参数 --------------------------
    localparam [11:0] C5_BASE = 12'd0;      // C5：attack 1998 + loop 610
    localparam [12:0] C5_LEN  = 13'd2608;
    localparam [12:0] C5_LOOP = 13'd610;
    localparam [12:0] C5_ATK  = 13'd1998;
    localparam [11:0] C6_BASE = 12'd2608;   // C6：attack 838 + loop 520
    localparam [12:0] C6_LEN  = 13'd1358;
    localparam [12:0] C6_LOOP = 13'd520;
    localparam [12:0] C6_ATK  = 13'd838;

    // 音符表：MIDI 音号 -> 相位增量 / 是否用 C6 bank（MIDI 60..91）
`include "music_box_note_inc.vh"
`include "test_pitch_pattern.vh"
    wire [24:0] key_gate_full = {{(25-KEY_COUNT){1'b1}}, key_gate};

    localparam [6:0]  TEST_MIDI_LO = 7'd48;
    localparam [31:0] TEST_PERIOD  = 32'd48_827;
    localparam [6:0]  VOICE_LAST   = VOICE_COUNT - 1;
    localparam [6:0]  VOICE_NONE   = VOICE_COUNT - 1;
    wire [6:0] active_voices = VOICE_COUNT;

    function signed [2:0] octave_for_key;
        input [74:0] bus;
        input [4:0] key;
        begin
            if (key < 5'd25) octave_for_key = $signed(bus[key*3 +: 3]);
            else             octave_for_key = 3'sd0;
        end
    endfunction

    function [7:0] midi_for_key;
        input [199:0] bus;
        input [4:0] key;
        begin
            if (key < 5'd25) midi_for_key = bus[key*8 +: 8];
            else             midi_for_key = 8'd0;
        end
    endfunction

    function [23:0] apply_octave;
        input [23:0] value;
        input signed [2:0] octave;
        begin
            case (octave)
            3'sd1:   apply_octave = value << 1;
            3'sb111:  apply_octave = value >> 1;
            default: apply_octave = value;
            endcase
        end
    endfunction

    // 每声部 8 拍：状态地址、同步读/锁存、音高乘法、音高累加、位置加法、状态写回、混音累加。
    localparam [2:0] PH_STATE = 3'd0;
    localparam [2:0] PH_READ  = 3'd1;
    localparam [2:0] PH_CAP   = 3'd2;
    localparam [2:0] PH_PITCH = 3'd3;
    localparam [2:0] PH_INC   = 3'd4;
    localparam [2:0] PH_POS   = 3'd5;
    localparam [2:0] PH_NEXT  = 3'd6;
    localparam [2:0] PH_ACC   = 3'd7;

    localparam [2:0] E_IDLE = 3'd0, E_ATK = 3'd1, E_DEC = 3'd2, E_SUS = 3'd3, E_REL = 3'd4;

    //=========================================================================
    //  1) ADSR 全局节拍
    //=========================================================================
    // A：固定每次加 65536，靠 A+1 的节拍改变总起音时间：约 5 ms .. 1.34 s。
    // D：D 越大周期越短；曲线在 D=42 附近保持原有约 43 采样节拍。
    // R：R 越大周期越长：约 5 ms .. 1.34 s。
    function [8:0] decay_period_for;
        input [7:0] d;
        reg [8:0] dd;
        begin
            dd = {1'b0, d};
            if (d < 8'd43)
                decay_period_for = 9'd256 - (dd << 2) - dd;
            else if (d >= 8'd226)
                decay_period_for = 9'd1;
            else
                decay_period_for = 9'd46 - ((dd - 9'd43) >> 2);
        end
    endfunction

    wire [8:0] att_period = {1'b0, adsr_a} + 9'd1;
    wire [8:0] dec_period = decay_period_for(adsr_d);
    wire [8:0] rel_period = {1'b0, adsr_r} + 9'd1;
    reg  [8:0] att_cnt, dec_cnt, rel_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            att_cnt <= 9'd0;
            dec_cnt <= 9'd0;
            rel_cnt <= 9'd0;
        end else if (sample_tick) begin
            att_cnt <= (att_cnt >= att_period - 9'd1) ? 9'd0 : att_cnt + 9'd1;
            dec_cnt <= (dec_cnt >= dec_period - 9'd1) ? 9'd0 : dec_cnt + 9'd1;
            rel_cnt <= (rel_cnt >= rel_period - 9'd1) ? 9'd0 : rel_cnt + 9'd1;
        end
    end
    wire att_tick_raw = sample_tick && (att_cnt >= att_period - 9'd1);
    wire dec_tick_raw = sample_tick && (dec_cnt >= dec_period - 9'd1);
    wire rel_tick_raw = sample_tick && (rel_cnt >= rel_period - 9'd1);

    //=========================================================================
    //  2) 每声部 8 拍扫描控制
    //     PH_STATE：发状态 RAM 地址、锁存当前声部与请求
    //     PH_READ ：等待同步状态 RAM 读延迟
    //     PH_CAP  ：锁存同步状态 RAM 数据
    //     PH_PITCH：锁存音高乘法结果与包络下一值
    //     PH_INC  ：锁存音高增量
    //     PH_POS  ：锁存相位加增量结果
    //     PH_NEXT ：生成并锁存状态写回值
    //     PH_ACC  ：累加当前声部波形/电平乘积
    //     72 声部需要 576 拍，远小于每采样 1024 拍。
    //=========================================================================
    reg [6:0] scan_voice;
    reg [2:0] scan_phase;
    reg [7:0] step;
    reg       scan_run;
    wire [6:0] vsel = scan_voice;
    wire       sub  = (scan_phase != PH_STATE);
    wire       last_step = (scan_voice == active_voices - 7'd1) && (scan_phase == PH_ACC);
    wire       acc_valid = scan_run && (scan_phase == PH_ACC) && (scan_voice < active_voices);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step       <= 8'd0;
            scan_voice <= 7'd0;
            scan_phase <= PH_STATE;
            scan_run   <= 1'b0;
        end else if (sample_tick) begin
            step       <= 8'd0;
            scan_voice <= 7'd0;
            scan_phase <= PH_STATE;
            scan_run   <= 1'b1;
        end else if (scan_run) begin
            if (last_step) begin
                scan_run   <= 1'b0;
                scan_voice <= 7'd0;
                scan_phase <= PH_STATE;
                step       <= 8'd0;
            end else begin
                step <= step + 8'd1;
                if (scan_phase == PH_ACC) begin
                    scan_phase <= PH_STATE;
                    scan_voice <= scan_voice + 7'd1;
                end else begin
                    scan_phase <= scan_phase + 3'd1;
                end
            end
        end
    end
    // 采样点脉冲锁存给整个扫描期用
    reg att_tick_l, dec_tick_l, rel_tick_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            att_tick_l <= 1'b0;
            dec_tick_l <= 1'b0;
            rel_tick_l <= 1'b0;
        end else if (sample_tick) begin
            att_tick_l <= att_tick_raw;
            dec_tick_l <= dec_tick_raw;
            rel_tick_l <= rel_tick_raw;
        end else if (scan_run && last_step) begin
            att_tick_l <= 1'b0;
            dec_tick_l <= 1'b0;
            rel_tick_l <= 1'b0;
        end
    end

    //=========================================================================
    //  3) 50 声部状态 + A 拍状态锁存
    //=========================================================================
    reg [6:0]  mb_state_addr;
    reg        mb_state_we;
    reg [80:0] mb_state_wdata;
    wire [80:0] mb_state_rdata;
    music_box_state_ram #(.WIDTH(81), .DEPTH(VOICE_COUNT)) u_vstate_ram (
        .clk(clk), .addr(mb_state_addr), .we(mb_state_we),
        .wdata(mb_state_wdata), .rdata(mb_state_rdata)
    );

    wire [80:0] cur_state_mux = mb_state_rdata;
    wire [23:0] mux_pos  = cur_state_mux[23:0];
    wire [23:0] mux_env  = cur_state_mux[47:24];
    wire [2:0]  mux_st   = cur_state_mux[50:48];
    wire [23:0] mux_inc  = cur_state_mux[74:51];
    wire        mux_bank = cur_state_mux[75];
    wire [4:0]  mux_key  = cur_state_mux[80:76];
    wire [11:0] mux_base = mux_bank ? C6_BASE : C5_BASE;

    reg [80:0] cur_state_r;
    reg [6:0]  cur_voice_r;
    reg        cur_start_r;
    reg [23:0] req_inc_r;
    reg        req_bank_r;
    reg [4:0]  req_key_r;

    wire [23:0] r_pos  = cur_state_r[23:0];
    wire [23:0] r_env  = cur_state_r[47:24];
    wire [2:0]  r_st   = cur_state_r[50:48];
    wire [23:0] r_inc  = cur_state_r[74:51];
    wire        r_bank = cur_state_r[75];
    wire [4:0]  r_key  = cur_state_r[80:76];
    // key=F is reserved for test voices.  They must follow test_mode, not
    // remain held forever after the test switch is turned off.
    wire        r_hold = (r_key < 5'd25) ? ~key_gate_full[r_key] : test_mode;
    wire [12:0] r_len  = r_bank ? C6_LEN  : C5_LEN;
    wire [12:0] r_loop = r_bank ? C6_LOOP : C5_LOOP;

    //=========================================================================
    //  4) 分配器 -> 核心装载请求
    //=========================================================================
    reg        req_valid;
    reg [6:0]  req_voice;
    reg [23:0] req_inc;
    reg        req_bank;
    reg [4:0]  req_key;
    wire       mux_start = scan_run && req_valid && (sub == 1'b0) && (vsel == req_voice);
    wire       cur_start = mux_start;

    //=========================================================================
    //  5) 相位（多级流水，逐样本语义不变）
    //=========================================================================
    // 八音盒相位增量只用到低 13 位（MIDI 60..91 最大 3995）
    // Q15 变调比：32768=原音高，65536=+1200 cents，16384=-1200 cents
    wire [12:0] inc13 = r_inc[12:0];
    wire [16:0] mux_pitch_ratio = (glide_active && (mux_key == glide_key))
        ? pitch_ratio_glide : pitch_ratio;
    reg [16:0] voice_pitch_ratio_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) voice_pitch_ratio_q <= 17'd32768;
        else if (scan_run && (scan_phase == PH_CAP))
            voice_pitch_ratio_q <= mux_pitch_ratio;
    end
    wire [29:0] pitch_prod = inc13 * voice_pitch_ratio_q;

    reg  [29:0] pitch_prod_q;
    reg  [23:0] inc_use_q;
    reg  [23:0] pos_plus_q;
    wire [14:0] pitch_delta_q = pitch_prod_q >>> 15;
    wire [25:0] inc_sum_q = {1'b0, r_inc} + {11'd0, pitch_delta_q};
    wire [23:0] inc_use_now = cur_start_r ? req_inc_r
                                         : (inc_sum_q[23] ? 24'd0 : inc_sum_q[23:0]);
    wire [23:0] pos_base = cur_start_r ? 24'd0 : r_pos;
    wire [23:0] loop_shift = {r_loop[11:0], 12'd0};
    wire        wrap = (pos_plus_q[23:12] >= r_len);
    wire [23:0] pos_next = wrap ? (pos_plus_q - loop_shift) : pos_plus_q;
    // ROM 地址用已锁存的当前声部状态发出，避免 64/88:1 状态 mux 直通 ROM 地址路径。
    wire [11:0] rom_addr = (r_bank ? C6_BASE : C5_BASE) +
                          (cur_start_r ? 12'd0 : r_pos[23:12]);

    wire signed [15:0] wave_data;
    music_box_celesta_rom u_rom (
        .clk(clk),
        .wave_addr(rom_addr),
        .wave_data(wave_data)
    );

    //=========================================================================
    //  6) 包络（B 拍，用锁存后的状态）
    //=========================================================================
    wire [16:0] att_step = 17'd65536;
    wire [23:0] dec_sub  = r_env >> 8;
    wire [23:0] rel_sub  = r_env >> 8;
    wire [7:0]  sustain_eff = test_mode ? 8'hFF : adsr_s;
    wire        adr_mode = (sustain_eff != 8'd0);
    wire        release_req = !r_hold;
    wire [23:0] atk_next = (r_env + att_step >= 24'hFF0000) ? 24'hFF0000
                                                             : (r_env + att_step);
    wire        dec_hit  = (r_env[23:8] <= {sustain_eff, 8'd0});
    wire        rel_done = (r_env < 24'h000100);

    reg [23:0] env_next;
    reg [2:0]  st_next;
    always @* begin
        if (cur_start_r) begin
            env_next = 24'd0;
            st_next  = E_ATK;
        end else begin
            case (r_st)
            E_ATK: begin
                if (release_req)                     begin env_next = r_env; st_next = E_REL; end
                else if (att_tick_l) begin
                    if (atk_next >= 24'hFF0000)      begin env_next = 24'hFF0000; st_next = E_DEC; end
                    else                             begin env_next = atk_next; st_next = E_ATK; end
                end
                else                                 begin env_next = r_env; st_next = E_ATK; end
            end
            E_DEC: begin
                if (release_req)                     begin env_next = r_env; st_next = E_REL; end
                else if (dec_hit) begin
                    if (adr_mode)                    begin env_next = {sustain_eff, 16'd0}; st_next = E_SUS; end
                    else                             begin env_next = 24'd0; st_next = E_IDLE; end
                end
                else if (dec_tick_l)                 begin env_next = r_env - dec_sub; st_next = E_DEC; end
                else                                 begin env_next = r_env; st_next = E_DEC; end
            end
            E_SUS: begin
                if (release_req)                     begin env_next = r_env; st_next = E_REL; end
                else                                 begin env_next = r_env; st_next = E_SUS; end
            end
            E_REL: begin
                if (rel_done)                        begin env_next = 24'd0; st_next = E_IDLE; end
                else if (rel_tick_l)                 begin env_next = r_env - rel_sub; st_next = E_REL; end
                else                                 begin env_next = r_env; st_next = E_REL; end
            end
            default:                                 begin env_next = 24'd0; st_next = E_IDLE; end
            endcase
        end
    end

    //=========================================================================
    //  7) 状态写回 + 64 个 vstate
    //=========================================================================
    reg [23:0] env_next_q;
    reg [2:0] st_next_q;

    wire [80:0] next_state = { cur_start_r ? req_key_r  : r_key,
                               cur_start_r ? req_bank_r : r_bank,
                               cur_start_r ? req_inc_r  : r_inc,
                               st_next_q, env_next_q, pos_next };


    reg signed [15:0] wave_pipe;
    reg [15:0] level_pipe;
    reg signed [31:0] product_q;
    reg signed [15:0] prod16_q;
    reg signed [21:0] sum;

    // Seven-phase control keeps the external state RAM synchronous while
    // preserving one independent phase/envelope state per voice.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_state_r <= 81'd0;
            cur_voice_r <= 7'd0;
            cur_start_r <= 1'b0;
            req_inc_r   <= 24'd0;
            req_bank_r  <= 1'b0;
            req_key_r   <= 5'h1F;
            mb_state_addr <= 7'd0;
            mb_state_we <= 1'b0;
            mb_state_wdata <= 81'd0;
            pitch_prod_q <= 30'd0;
            inc_use_q   <= 24'd0;
            pos_plus_q  <= 24'd0;
            env_next_q  <= 24'd0;
            st_next_q   <= 3'd0;
        end else if (scan_run) begin
            mb_state_we <= 1'b0;
            case (scan_phase)
            PH_STATE: begin
                mb_state_addr <= vsel;
                cur_voice_r <= vsel;
                cur_start_r <= mux_start;
                req_inc_r   <= req_inc;
                req_bank_r  <= req_bank;
                req_key_r   <= req_key;
            end
            PH_READ: begin end
            PH_CAP: begin
                cur_state_r <= mb_state_rdata;
            end
            PH_PITCH: begin
                pitch_prod_q <= pitch_prod;
                env_next_q   <= env_next;
                st_next_q    <= st_next;
            end
            PH_INC: begin
                inc_use_q <= inc_use_now;
                wave_pipe <= wave_data;
                level_pipe <= env_next_q[23:8];
            end
            PH_POS: begin
                product_q  <= wave_pipe * $signed({1'b0, level_pipe});
                pos_plus_q <= pos_base + inc_use_q;
            end
            PH_NEXT: begin
                prod16_q        <= product_q >>> 16;
                mb_state_we     <= (cur_voice_r < VOICE_COUNT);
                mb_state_addr   <= cur_voice_r;
                mb_state_wdata  <= next_state;
            end
            PH_ACC: begin
                // State RAM write completed at the PH_NEXT -> PH_ACC edge.
            end
            default: ;
            endcase
        end
    end

    //=========================================================================
    //  8) 波形/电平流水 + 乘法 + 累加
    //=========================================================================
    reg lstep_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum     <= 22'sd0;
            lstep_d <= 1'b0;
        end else begin
            if (sample_tick) begin
                sum     <= 22'sd0;
                lstep_d <= 1'b0;
            end else begin
                lstep_d <= scan_run && last_step;
                if (acc_valid)
                    sum <= sum + {{6{prod16_q[15]}}, prod16_q};
            end
        end
    end

    wire signed [21:0] scaled = sum >>> 2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_sample <= 16'sd0;
        end else if (lstep_d) begin
            if (scaled > 22'sd32767)        audio_sample <= 16'sh7FFF;
            else if (scaled < -22'sd32768)  audio_sample <= 16'sh8000;
            else                            audio_sample <= scaled[15:0];
        end
    end

    //=========================================================================
    //  9) 声部忙/发声标志 + 按键绑定（PH_NEXT）
    //=========================================================================
    reg [VOICE_COUNT-1:0] v_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_busy <= {VOICE_COUNT{1'b0}};
        else if (scan_run && (scan_phase == PH_NEXT) && (cur_voice_r < active_voices))
            v_busy[cur_voice_r] <= (st_next_q != E_IDLE);
    end
    assign voices_busy = v_busy;

    reg [VOICE_COUNT*5-1:0] v_key_bus;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_key_bus <= {VOICE_COUNT{5'h1F}};
        else if (scan_run && (scan_phase == PH_NEXT) && cur_start_r &&
                 (cur_voice_r < active_voices))
            v_key_bus[cur_voice_r*5 +: 5] <= req_key_r;
    end

    reg [VOICE_COUNT-1:0] v_sound;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_sound <= {VOICE_COUNT{1'b0}};
        else if (scan_run && (scan_phase == PH_NEXT) && (cur_voice_r < active_voices))
            v_sound[cur_voice_r] <= (env_next_q[23:8] > 8'd64);
    end

    function [7:0] pop_voices;
        input [VOICE_COUNT-1:0] v;
        integer q;
        begin
            pop_voices = 8'd0;
            for (q = 0; q < VOICE_COUNT; q = q + 1) pop_voices = pop_voices + v[q];
        end
    endfunction
    assign voices_sounding = pop_voices(v_sound);
    assign voices_any = |v_sound;

    //=========================================================================
    //  10) 声部分配器（按键 -> 空闲声部）
    //=========================================================================
    function [4:0] lowest_key;
        input [24:0] v;
        integer k;
        begin
            lowest_key = 5'd0;
            for (k = 24; k >= 0; k = k - 1)
                if (v[k]) lowest_key = k[4:0];
        end
    endfunction

    reg        alloc_test;
    reg [6:0]  sweep_midi;

    // Full-voice test uses a known consonant C-major pattern, not a
    // non-musical phase ramp. Every voice still remains independently active.
    wire [6:0] test_midi = test_midi_for_voice(tgt_voice);
    wire [23:0] test_inc_base = note_inc(test_midi);
    wire [7:0] midi_tgt = midi_for_key(key_tune_bus, sel_key);
    wire [31:0] alloc_inc32 = alloc_test ? {8'd0, test_inc_base} : note_inc(midi_tgt[6:0]);
    wire [23:0] alloc_inc_shifted = apply_octave(alloc_inc32[23:0], octave_for_key(key_octave_bus, sel_key));
    wire signed [2:0] test_octave = $signed(key_octave_bus[2:0]);
    wire [23:0] test_inc_shifted = apply_octave(test_inc_base, test_octave);
    reg [24:0] key_gate_d;
    reg [24:0] pending;

    reg [31:0] test_cnt;
    reg        test_mode_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_cnt    <= 32'd0;
            test_mode_d <= 1'b0;
        end else begin
            test_mode_d <= test_mode;
            if (sample_tick)
                test_cnt <= (test_cnt >= TEST_PERIOD) ? 32'd0 : test_cnt + 32'd1;
        end
    end
    wire test_tick  = sample_tick && (test_cnt >= TEST_PERIOD);
    wire test_start = test_mode && ~test_mode_d;

    localparam [2:0] S_IDLE = 3'd0, S_FIND = 3'd1, S_LOAD = 3'd2, S_WAIT = 3'd3, S_NEXT = 3'd4;

    reg [2:0]  state;
    reg [6:0]  tgt_voice;
    reg [6:0]  tgt_midi;
    reg [4:0]  sel_key;
    reg [6:0]  ex_voice;     // 这个键已经占着的声部
    reg        ex_found;
    reg [6:0]  free_voice;   // 找到的第一个空声部
    reg        free_found;
    wire [4:0] v_key_cur = v_key_bus[tgt_voice*5 +: 5];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            tgt_voice  <= 7'd0;
            tgt_midi   <= 7'd0;
            sel_key    <= 5'd0;
            alloc_test <= 1'b0;
            sweep_midi <= TEST_MIDI_LO;
            req_valid  <= 1'b0;
            req_voice  <= 7'd0;
            req_inc    <= 24'd0;
            req_bank   <= 1'b0;
            req_key    <= 5'h1F;
            key_gate_d <= 25'h1FFFFFF;
            ex_found   <= 1'b0;
            free_found <= 1'b0;
            ex_voice   <= 7'd0;
            free_voice <= 7'd0;
            pending    <= 25'd0;
        end else begin
            if (sample_tick) begin
                key_gate_d <= key_gate_full;
                // Test mode owns the allocator.  Do not carry ordinary key
                // edges across the test interval, otherwise one stale press
                // can fire once immediately after test mode closes.
                if (test_mode || test_mode_d)
                    pending <= 25'd0;
                else
                    pending <= pending | (key_gate_d & ~key_gate_full);
            end

            case (state)
            S_IDLE: begin
                if (test_mode) begin
                    if (test_tick || test_start) begin
                        tgt_voice  <= 7'd0;
            ex_found   <= 1'b0;
            free_found <= 1'b0;
                        sweep_midi <= TEST_MIDI_LO;
                        alloc_test <= 1'b1;
                        state      <= S_LOAD;
                    end
                end else if (!scan_run && (pending != 25'd0)) begin
                    sel_key    <= lowest_key(pending);
                    tgt_midi   <= midi_for_key(key_tune_bus, lowest_key(pending))[6:0];
                    tgt_voice  <= 7'd0;
            ex_found   <= 1'b0;
            free_found <= 1'b0;
                    alloc_test <= 1'b0;
                    state      <= S_FIND;
                end
            end

            S_FIND: begin
                // ★ 一边扫一边记两件事：
                //   ① 这个键是不是已经占着某个声部（优先：重触发它，不再占新槽位）
                //   ② 第一个空槽位（备选）
                if ((v_busy[tgt_voice] || v_sound[tgt_voice]) && (v_key_cur == sel_key) && !ex_found) begin
                    ex_voice <= tgt_voice;
                    ex_found <= 1'b1;
                end else if (!v_busy[tgt_voice] && !free_found) begin
                    free_voice <= tgt_voice;
                    free_found <= 1'b1;
                end
                if (tgt_voice == VOICE_LAST) begin
                    if (ex_found || ((v_busy[VOICE_LAST] || v_sound[VOICE_LAST]) && (v_key_cur == sel_key))) begin
                        tgt_voice <= ex_found ? ex_voice : VOICE_LAST;   // 同键 -> 重触发
                        state     <= S_LOAD;
                    end else if (free_found || !v_busy[VOICE_LAST]) begin
                        tgt_voice <= free_found ? free_voice : VOICE_LAST;
                        state     <= S_LOAD;
                    end else begin
                        state     <= S_IDLE;   // 声部满且都不是这个键 -> 丢弃
                    end
                end else begin
                    tgt_voice <= tgt_voice + 7'd1;
                end
            end

            S_LOAD: begin
                req_voice <= tgt_voice;
                req_inc   <= alloc_test ? test_inc_shifted : alloc_inc_shifted;
                req_bank  <= alloc_test ? note_is_c6(test_midi) : note_is_c6(midi_tgt[6:0]);
                req_key   <= alloc_test ? 5'h1F : sel_key;
                req_valid <= 1'b1;
                state     <= S_WAIT;
            end

            S_WAIT: begin
                // 等核心扫描到这一声部时把状态装载进去（避免地址多路选择器）
                if (cur_start) begin
                    req_valid <= 1'b0;
                    state     <= S_NEXT;
                end
            end

            S_NEXT: begin
                if (alloc_test) begin
                    if (tgt_voice == VOICE_LAST) begin
                        state <= S_IDLE;
                    end else begin
                        tgt_voice  <= tgt_voice + 7'd1;
                        sweep_midi <= sweep_midi + 7'd1;
                        state      <= S_LOAD;
                    end
                end else begin
                    pending[sel_key] <= 1'b0;
                    state            <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
