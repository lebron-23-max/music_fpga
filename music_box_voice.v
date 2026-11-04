`timescale 1ns / 1ps
//=============================================================================
// music_box_voice.v —— 八音盒单声部振荡器（可编程频率 + ADSR 包络）
//=============================================================================
//
// 一、这个模块做什么
//   把“一个音符”演奏出来。每个输出采样点做三件事：
//     1) 用 Q16 读指针在波表上滑动，取出此刻的波形值（音高由增量决定）；
//     2) 读指针按 Attack+Loop 结构回绕（Attack 只放一次，Loop 无限循环）；
//     3) 波形乘上 ADSR 包络电平，得到输出。
//
// 二、Q16 读指针 pos
//     pos[31:16] = 波表索引（最大表长 2608 < 4096，12 位够用）
//     pos[15:0]  = 相位小数
//     每采样点 pos <= pos + inc_used。inc_used 越大音越高。
//·
// 三、实时变调
//     inc_used = base_inc + (base_inc >>> 7) * pitch_bend
//     pitch_bend = 0 原音高，+127 ≈ 升八度，8 ≈ 升半音。逐采样点生效。
//
// 四、ADSR 包络（本版新增，取代原来的固定衰减表）
//     4 个 8 位参数（后续接电位器/编码器）：
//       adsr_a : 起音速度，0 = 最快（约 5 ms），255 = 最慢（约 1.3 s）
//       adsr_d : 衰减速度，越大衰减越慢（指数衰减，4 位有效档位）
//       adsr_s : 延音电平，0 = 打击乐式（自然衰减到无声，按键松开不打断）
//                            >0 = 常规 ADSR（按住保持在 s，松开后按 R 释放）
//       adsr_r : 释放速度，越大释放越慢（仅当 adsr_s > 0 时生效）
//
//     电平用 32 位累加器 env_acc 表示，电平 = env_acc[31:16]（16 位）。
//       ATTACK ：env_acc 线性上升，步长 = (256-A)<<16
//       DECAY  ：env_acc -= env_acc >> dec_shift   （指数衰减）
//       SUSTAIN：保持
//       RELEASE：env_acc -= env_acc >> rel_shift
//     默认 A=0、S=0 时表现为“瞬间起音 + 指数自然衰减”，与原来的八音盒
//     听感一致，而且按键松开不会把音掐掉。
//
// 五、分时隙取数据
//     32 个声部共用一块 ROM，每个采样点后有 32 拍扫描：
//       第 k 拍送出声部 k 的波表地址，下一拍声部 k 取回数据并推进指针。
//     voice_busy = 1 表示本声部正在发声，分配器据此寻找空槽。
//=============================================================================
module music_box_voice #(
    parameter [5:0] VOICE_ID = 6'd0          // 声部编号 0..31，决定扫描时隙
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,     // 音频采样脉冲 48.828125 kHz
    input  wire [5:0]         scan_slot_d,     // engine 上一拍的扫描时隙
    input  wire               scan_valid_d,    // 上一拍扫描是否有效
    input  wire signed [15:0] wave_data,       // ROM 返回的波形
    output wire [11:0]        wave_addr,       // 本声部要读的波表地址
    output reg  signed [15:0] voice_out,       // 音频输出
    output reg                voice_busy,      // 1 = 正在发声
    // ---------------- 分配器编程接口 ----------------
    input  wire               note_start,      // 单周期脉冲：开始一个新音
    input  wire               note_hold,       // 1 = 按键仍按住（供 S>0 时的 RELEASE 用）
    input  wire [31:0]        base_inc_in,     // 基准相位增量（Q16）
    input  wire [11:0]        table_base_in,   // bank 起始地址
    input  wire [12:0]        table_len_in,    // 整表长度
    input  wire [12:0]        loop_len_in,     // Loop 段长度
    input  wire [12:0]        attack_len_in,   // Attack 段长度
    input  wire signed [7:0]  pitch_bend,      // 实时变调
    // ---------------- ADSR 参数与控制 ----------------
    input  wire [7:0]         adsr_a,          // 起音速度
    input  wire [7:0]         adsr_s,          // 延音电平
    input  wire               dec_tick,        // 全局衰减节拍（由 adsr_d 决定快慢）
    input  wire               rel_tick         // 全局释放节拍（由 adsr_r 决定快慢）
);
    //-------------------------- 可写频率 --------------------------
    reg  [23:0] base_inc_r;                    // Q12 相位增量（已含实时变调）

    wire signed [23:0] base_s     = $signed(base_inc_r);
    wire signed [31:0] bend_prod  = base_s * $signed(pitch_bend);
    wire signed [23:0] bend_delta = bend_prod >>> 7;   // 变调偏移 = 基准 × bend/128
    wire signed [23:0] inc_signed = base_s + bend_delta;
    wire        [23:0] inc_used   = inc_signed[23] ? 24'd0 : inc_signed[23:0];

    //-------------------------- 读指针 --------------------------
    reg  [23:0] pos;                          // Q12：pos[23:12] 是波表索引
    wire [11:0] wave_index  = pos[23:12];
    wire        attack_done = (wave_index >= attack_len_in);

    wire [23:0] pos_plus    = pos + inc_used;
    wire        wrap        = (pos_plus[23:12] >= table_len_in);  // 表尾低 12 位必为 0，只比高 12 位
    wire [23:0] loop_shift  = {loop_len_in,  12'd0};
    wire [23:0] pos_next    = wrap ? (pos_plus - loop_shift) : pos_plus;

    assign wave_addr = table_base_in + wave_index;

    //========================== ADSR 包络 ==========================
    localparam [2:0] E_IDLE = 3'd0,
                     E_ATK  = 3'd1,
                     E_DEC  = 3'd2,
                     E_SUS  = 3'd3,
                     E_REL  = 3'd4;

    reg  [2:0]  env_state;
    reg  [23:0] env_acc;                      // 电平 = env_acc[23:8]（16 位）
    wire [15:0] env_level = env_acc[23:8];

    // ---- 起音 A：线性上升，A=0 最快（256<<8），A=255 最慢（1<<8）----
    // 纯拼接实现，不含乘法器，也不含可变移位。
    wire [8:0]  att_mag  = 9'd256 - {1'b0, adsr_a};
    wire [16:0] att_step = {att_mag, 8'd0};

    // ---- 衰减 D / 释放 R：指数衰减，但“每次减多少”固定为 1/256 ----
    // 不要写成 (env_acc >> 可变位数)：那会综合出每声部两个可变桶形移位器，
    // 32 声部共 64 个，逻辑会从 38% 涨到 77% 并导致时序失败。
    // 改为“固定移位 + 全局可变节拍”：快慢由 engine 送来的 dec_tick/rel_tick
    // 决定（全局只做一份计数器），每个声部只剩一个减法。
    wire [23:0] dec_sub = env_acc >> 8;
    wire [23:0] rel_sub = env_acc >> 8;

    // 只有 S>0 才进入“延音+释放”模式；S=0 为打击乐模式，松开按键不打断
    wire        adr_mode    = (adsr_s != 8'd0);
    wire        release_req = adr_mode && !note_hold;

    wire [23:0] atk_next = (env_acc + att_step >= 24'hFF0000)
                           ? 24'hFF0000 : (env_acc + att_step);
    wire        dec_hit  = (env_acc[23:8] <= {adsr_s, 8'd0});
    wire        rel_done = (env_acc < 24'h000100);

    //-------------------------- 音量乘法 --------------------------
    // 16 位有符号波形 × 17 位无符号电平 -> 33 位，取高 16 位输出。
    wire signed [32:0] wave_product = wave_data * $signed({1'b0, env_level});

    //-------------------------- 时序逻辑 --------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_inc_r  <= 24'd0;
            pos         <= 24'd0;
            env_state   <= E_IDLE;
            env_acc     <= 24'd0;
            voice_busy  <= 1'b0;
            voice_out   <= 16'sd0;
        end else begin
            //======== 波表时隙：推进读指针并输出 ========
            if (scan_valid_d && (scan_slot_d == VOICE_ID)) begin
                if (voice_busy) begin
                    voice_out <= wave_product[31:16];
                    pos       <= pos_next;
                end else begin
                    voice_out <= 16'sd0;
                end
            end

            //======== 每个采样点更新一次 ADSR ========
            if (sample_tick) begin
                case (env_state)
                E_IDLE: ;
                E_ATK: begin
                    if (release_req) begin
                        env_state <= E_REL;
                    end else if (atk_next >= 24'hFF0000) begin
                        env_acc   <= 24'hFF0000;
                        env_state <= E_DEC;
                    end else begin
                        env_acc <= atk_next;
                    end
                end
                E_DEC: begin
                    if (release_req) begin
                        env_state <= E_REL;
                    end else if (dec_hit) begin
                        if (adr_mode) begin
                            env_acc   <= {adsr_s, 16'd0};
                            env_state <= E_SUS;
                        end else begin
                            env_acc   <= 24'd0;
                            env_state <= E_IDLE;      // 自然衰减到无声，声部释放
                        end
                    end else if (dec_tick) begin
                        env_acc <= env_acc - dec_sub; // 只在全局节拍上减 1/256
                    end
                end
                E_SUS: begin
                    if (release_req) env_state <= E_REL;
                end
                E_REL: begin
                    if (rel_done) begin
                        env_acc   <= 24'd0;
                        env_state <= E_IDLE;
                    end else if (rel_tick) begin
                        env_acc <= env_acc - rel_sub; // 只在全局节拍上减 1/256
                    end
                end
                default: env_state <= E_IDLE;
                endcase

                // 声部忙标志跟随包络状态
                voice_busy <= (env_state != E_IDLE);
            end

            //======== 分配器启动新音（优先级最高） ========
            if (note_start) begin
                base_inc_r <= base_inc_in;
                pos        <= 24'd0;
                env_acc    <= 24'd0;
                env_state  <= E_ATK;
                voice_busy <= 1'b1;
                voice_out  <= 16'sd0;
            end
        end
    end

endmodule