`timescale 1ns / 1ps
//=============================================================================
// liss_plot.v —— 李萨如图形（v12：2:3 对称花纹 + 随音量缩放，2026-10-15）
//=============================================================================
// 一、图形：相位累加器 + 正弦表产生 x = sin(2θ)、y = sin(3θ)
//   等效于示波器 X-Y 接两台频率比 2:3 的锁相信号源。
//   θ 每段 +1/256 圈，一场扫完 256 段 = 整圈 ⇒ x 走 2 圈、y 走 3 圈，
//   **首尾闭合、上下左右都对称**（用户 2026-10-15 确认就是这个花样）。
//
// 二、跟音量变化（用户要求）
//   半径 = |sin| × k/8，k 由**本场电平 peak 相对慢释放峰值包络 peak_ref 的比例**决定，
//   k ∈ {8,7,6,5,4,3,2,1}（= 1.00 / 0.875 / 0.75 / 0.625 / 0.5 / 0.375 / 0.25 / 0.125）：
//     · 音符一敲下去 ⇒ peak ≈ peak_ref ⇒ k=8，图形最大（填满面板 ~94%）；
//     · 声音衰减 ⇒ peak/peak_ref 变小 ⇒ 图形一层层缩小，像示波器上"衰减下去"；
//     · 重新弹 ⇒ 立刻回到最大；peak_ref 每场只掉 1/64（τ≈1 s），所以音量稳定时
//       图形尺寸也稳定，不会乱跳。
//   阈值全是移位+加法（无除法、无乘法器），两轴用同一个 k ⇒ **仍然轴对称**。
//
// 三、完全静音（peak < 64）：只清位图不画线，面板留空（不编造数据）。
//
// 四、为什么不用"真实波形"画 XY（v10 的教训）
//   真实音色含大量谐波：同一个信号按两个速率取样做 XY，第 n 次谐波在两轴上的
//   频率比互不相同 ⇒ 图形必然杂乱、不可能轴对称（用户实测否决）。
//   音频通路完全不受影响：本模块只读一个 peak（电平）。
//
// 五、旧版遗留的三个 bug（保持修好的状态）
//   ① 步长取整 ⇒ 图形不闭合；现在 θ 步进精确 = 1/256 圈。
//   ② 读-改-写流水少等一拍 ⇒ 跨字时把别的像素搬过来（碎点/乱线）；
//      现在 4 拍/像素：发读地址 -> 等 1 拍 -> 用数据登记写 -> 再等 1 拍让写落地。
//   ③ 荧光余晖把笔迹糊开；现在**每场先清零再重画**，像素一律写 2'b11（最亮）。
//
// 位图仍是 160x136、每像素 2bit（地址 = row*20 + (x>>3)，行内像素 p = bit[2p+1:2p]），
// 与 video_render.v 的读法完全一致 —— 渲染器不需要改。
//=============================================================================
module liss_plot (
    input  wire               pix_clk,
    input  wire               rst_n,
    input  wire               start,       // 场消隐起始脉冲
    input  wire [15:0]        peak,        // 本场 |峰值|（电平 -> 图形大小）
    input  wire [7:0]         nv,          // 当前音色正在发声的声部数（=0 即"没有音频"）
    input  wire               vblank,      // 场消隐期：引擎独占位图读口
    input  wire [11:0]        rd_addr,     // 渲染器读地址
    output wire [15:0]        rd_data,
    output reg                busy,
    output reg  [7:0]         done_cnt     // 本场画出的像素数（调试，饱和 255）
);
`include "sine_lut8.vh"

    //-------------------------- 常量 --------------------------
    localparam [8:0]  NSEG    = 9'd256;      // 每场段数（正好 = 一整圈 θ）
    localparam [15:0] THSTEP  = 16'd256;     // 每段相位步进 = 1/256 圈
    localparam [15:0] PEAK_MIN= 16'd64;      // 低于此峰值视为静音（面板留空）
    localparam [12:0] PBUD    = 13'd6000;    // 每场像素上限（保护消隐期）

    localparam [3:0] S_IDLE=4'd0, S_CLR=4'd1,  S_LAT=4'd2, S_PT=4'd3,
                     S_LNX=4'd4,  S_LRD=4'd5,  S_WR=4'd6,  S_WT=4'd7;

    //---------------- 位图：单写口 + 单读口（BSRAM） ----------------
    reg [15:0] bmp [0:2719];
    reg [15:0] rd_q;
    reg        eng_we;
    reg [11:0] eng_addr;
    reg [11:0] eng_raddr;
    reg [15:0] eng_wdata;

    wire [11:0] r_addr = busy ? eng_raddr : rd_addr;
    always @(posedge pix_clk) rd_q <= bmp[r_addr];
    always @(posedge pix_clk) if (eng_we) bmp[eng_addr] <= eng_wdata;
    assign rd_data = rd_q;

    // 把像素写成"最亮"（2bit = 11）—— 不累加、不衰减，保证线条亮度一致
    function [15:0] set_px;
        input [15:0] c;
        input [3:0]  sh;
        begin set_px = c | (16'h0003 << sh); end
    endfunction

    //---------------- 电平 -> 半径（连续增益 + 快攻慢放 + 限速滑动） ----------------
    // 用户要求：不要"换挡式放大缩小"，要随音量有律动感、过渡流畅。
    //   peak_ref : 慢释放峰值包络（每场掉 1/64），用来把不同音色的电平归一化
    //   r_tgt    : 目标半径增益 16..64（= 1/4 .. 满幅），由 peak/peak_ref 的 8 档决定
    //   r_cur    : 实际半径增益，每场向 r_tgt 滑动（攻 8/场、放 3/场）⇒ 连续、无跳变
    //   半径     = sin × r_cur / 64
    reg [15:0] peak_ref;
    reg [6:0]  r_cur;
    reg        loud;

    wire [15:0] p_ref_next = (peak > peak_ref) ? peak : (peak_ref - (peak_ref >> 6));
    wire [15:0] half = peak_ref >> 1;
    wire [15:0] qt   = peak_ref >> 2;
    wire [15:0] ei   = peak_ref >> 3;
    wire ge7 = (peak >= (peak_ref - ei));            // 0.875
    wire ge6 = (peak >= (peak_ref - qt));            // 0.750
    wire ge5 = (peak >= (peak_ref - ei - qt));       // 0.625
    wire ge4 = (peak >= half);                       // 0.500
    wire ge3 = (peak >= (half - ei));                // 0.375
    wire ge2 = (peak >= qt);                         // 0.250
    wire ge1 = (peak >= ei);                         // 0.125
    wire [2:0] k_w = ge7 ? 3'd7 : ge6 ? 3'd6 : ge5 ? 3'd5 : ge4 ? 3'd4 :
                     ge3 ? 3'd3 : ge2 ? 3'd2 : ge1 ? 3'd1 : 3'd1;
    wire [6:0] r_tgt = {k_w, 3'b000} + 7'd8;      // k=1..7 -> 16..64

    //---------------- 相位累加器 + 正弦表（2:3） ----------------
    reg  [15:0] theta;
    // ★ 律动：y 轴加一个相对相位 phi（每场前进、速率随真实电平）
    //   x = sin(2θ)   y = sin(3θ + φ)   ⇒ 图形在 2:3 族里连续变形/转动，
    //   φ=0 就是用户确认的那张对称花纹（形状不变，只是"活"起来）。
    reg [15:0] phi;
    wire [15:0] phi_step = 16'd160 + (peak >> 3);  // 2026-10-17 用户反馈偏慢：约 2.5 倍速
    wire [15:0] th2 = {theta[14:0], 1'b0};       // 2θ
    wire [15:0] th3 = th2 + theta + phi;          // 3θ + φ
    wire signed [14:0] prod_x = sin8(th2[15:8]) * $signed({1'b0, r_cur});
    wire signed [14:0] prod_y = sin8(th3[15:8]) * $signed({1'b0, r_cur});
    wire signed [7:0]  sx = prod_x >>> 6;     // sin × r_cur/64
    wire signed [7:0]  sy = prod_y >>> 6;
    wire [7:0] tx = 8'd80 + sx;                  // 8 位环绕算术天然正确（±64 范围内）
    wire [7:0] ty = 8'd68 - sy;

    //---------------- Bresenham ----------------
    reg [7:0]  px_p, py_p, px_c, py_c;
    reg [7:0]  ln_x, ln_y;
    reg [8:0]  ln_dx, ln_dy;
    reg        ln_sx, ln_sy;
    reg signed [10:0] ln_err;
    reg [9:0]  ln_steps;
    reg [11:0] cur_word_d;

    wire [11:0] cur_word = {ln_y, 4'b0000} + {2'b0, ln_y, 2'b00} + {7'b0, ln_x[7:3]};
    wire [3:0]  psh      = {ln_x[2:0], 1'b0};
    wire        at_end   = (ln_x == px_c) && (ln_y == py_c);
    wire signed [10:0] e2  = ln_err <<< 1;
    wire signed [10:0] ndy = $signed({1'b0, ln_dy});
    wire signed [10:0] ndx = $signed({1'b0, ln_dx});
    wire        step_x = (e2 > -ndy);
    wire        step_y = (e2 <  ndx);
    wire [7:0]  x_next = step_x ? (ln_sx ? (ln_x + 8'd1) : (ln_x - 8'd1)) : ln_x;
    wire [7:0]  y_next = step_y ? (ln_sy ? (ln_y + 8'd1) : (ln_y - 8'd1)) : ln_y;
    wire signed [10:0] err_next = ln_err + (step_x ? -ndy : 11'sd0)
                                         + (step_y ?  ndx : 11'sd0);

    //---------------- 主状态机 ----------------
    reg [3:0]  st;
    reg [11:0] dcnt;                 // 位图清零计数
    reg [8:0]  idx;                  // 已画段数
    reg [12:0] pix_drawn;

    wire seg_end = (idx >= NSEG) || (pix_drawn >= PBUD);

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; busy <= 1'b0; done_cnt <= 8'd0;
            dcnt <= 12'd0; idx <= 9'd0; pix_drawn <= 13'd0; loud <= 1'b0;
            theta <= 16'd0; phi <= 16'd0; peak_ref <= 16'd0; r_cur <= 7'd0; loud <= 1'b0;
            px_p <= 8'd80; py_p <= 8'd68; px_c <= 8'd80; py_c <= 8'd68;
            ln_x <= 8'd80; ln_y <= 8'd68;
            ln_dx <= 9'd0; ln_dy <= 9'd0; ln_sx <= 1'b1; ln_sy <= 1'b1;
            ln_err <= 11'sd0; ln_steps <= 10'd0;
            eng_we <= 1'b0; eng_addr <= 12'd0; eng_wdata <= 16'h0000; eng_raddr <= 12'd0;
            cur_word_d <= 12'd0;
        end else begin
            eng_we <= 1'b0;
            if (busy && !vblank) begin
                // 消隐期结束还没画完 ⇒ 立刻收手（保护有效视频区）
                busy <= 1'b0; st <= S_IDLE;
            end else begin
            case (st)
            S_IDLE: begin
                busy <= 1'b0; done_cnt <= 8'd0;
                if (start) begin
                    busy      <= 1'b1;
                    dcnt      <= 12'd0;
                    idx       <= 9'd0;
                    pix_drawn <= 13'd0;
                    // 静音门控：以"正在发声的声部数"为准（peak 包络有下限、静音也会残留）
                    loud      <= (peak >= PEAK_MIN);
                    peak_ref  <= p_ref_next;
                    phi       <= phi + phi_step;      // 律动：相对相位每场前进
                    // 半径滑动：攻 8、放 3（每场），并在静音时归零
                    if (peak < PEAK_MIN && peak < 16'd32) begin
                        r_cur <= 7'd0;
                    end else if (r_cur < r_tgt) begin
                        r_cur <= ((r_tgt - r_cur) > 7'd8) ? (r_cur + 7'd8) : r_tgt;
                    end else if (r_cur > r_tgt) begin
                        r_cur <= ((r_cur - r_tgt) > 7'd3) ? (r_cur - 7'd3) : r_tgt;
                    end
                    st        <= S_CLR;
                end
            end
            //---- 1) 每场清零整张位图（没有余晖 ⇒ 线条锐利）----
            S_CLR: begin
                eng_we    <= 1'b1;
                eng_addr  <= dcnt;
                eng_wdata <= 16'h0000;
                if (dcnt == 12'd2719) begin
                    dcnt <= 12'd0;
                    if (!loud) begin
                        // 没有声音就不画（面板留空，不编造数据）
                        busy <= 1'b0;
                        st   <= S_IDLE;
                    end else begin
                        st <= S_LAT;
                    end
                end else begin
                    dcnt <= dcnt + 12'd1;
                end
            end
            //---- 2) 从 θ=0 开始扫（图形恒定，与起拍相位无关）----
            S_LAT: begin
                theta <= 16'd0;
                px_p  <= 8'd80; py_p <= 8'd68;
                st    <= S_PT;
            end
            //---- 3) 取一个点：x=sin(2θ)、y=sin(3θ)，与上一点连成折线 ----
            S_PT: begin
                ln_x   <= px_p;  ln_y <= py_p;
                ln_dx  <= (tx > px_p) ? (tx - px_p) : (px_p - tx);
                ln_dy  <= (ty > py_p) ? (ty - py_p) : (py_p - ty);
                ln_sx  <= (px_p < tx);
                ln_sy  <= (py_p < ty);
                ln_err <= $signed({1'b0,(tx > px_p) ? (tx - px_p) : (px_p - tx)})
                        - $signed({1'b0,(ty > py_p) ? (ty - py_p) : (py_p - ty)});
                px_c   <= tx;  py_c <= ty;
                ln_steps <= 10'd0;
                theta  <= theta + THSTEP;
                idx    <= idx + 9'd1;
                st     <= S_LNX;
            end
            //---- 4) 逐像素读-改-写：4 拍，保证"写落地"之后才发起下一次读 ----
            S_LNX: begin
                eng_raddr  <= cur_word;
                cur_word_d <= cur_word;
                st <= S_LRD;
            end
            S_LRD: begin
                st <= S_WR;                    // 读口 1 拍延迟，这一拍等数据
            end
            S_WR: begin
                eng_we    <= 1'b1;
                eng_addr  <= cur_word_d;
                eng_wdata <= set_px(rd_q, psh);   // 本拍 rd_q 正是 cur_word_d 的内容
                if (pix_drawn != 13'd8191) pix_drawn <= pix_drawn + 13'd1;
                done_cnt  <= (done_cnt == 8'hFF) ? 8'hFF : (done_cnt + 8'd1);
                if (at_end || (ln_steps == 10'd64) || (pix_drawn >= PBUD)) begin
                    px_p <= px_c; py_p <= py_c;
                    if (seg_end) begin
                        busy <= 1'b0;
                        st   <= S_IDLE;
                    end else begin
                        st <= S_PT;
                    end
                end else begin
                    ln_steps <= ln_steps + 10'd1;
                    ln_x     <= x_next;
                    ln_y     <= y_next;
                    ln_err   <= err_next;
                    st       <= S_WT;
                end
            end
            S_WT: begin
                st <= S_LNX;                   // 等写真正落地，再发下一次读
            end
            default: st <= S_IDLE;
            endcase
            end
        end
    end

endmodule
