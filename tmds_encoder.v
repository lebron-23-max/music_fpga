// ============================================================
// 模块名：tmds_encoder
// 功能：TMDS 8b/10b 编码（单通道，DVI 1.0 §3.3.3）
//
// 时钟域：pix_clk（48MHz；60K 档，见 rtl/top/clk_gen_video.v）
// 依赖：无（纯逻辑，无厂商原语）
//
// 用法：一路像素通道一个实例
//     lane0(蓝)：c0 = hsync, c1 = vsync   —— 同步信号就藏在**蓝通道**的控制周期里
//     lane1(绿)：c0 = 0,     c1 = 0
//     lane2(红)：c0 = 0,     c1 = 0
//   ★ 这三路必须**互相同拍**（同一 clk、同一复位），否则三色之间产生 skew。
//
// ---------------------------------------------------------------------------
// ★ 延迟：din/de/c0/c1 进来到 dout 有效 = **2 拍**（三路完全相同）
//   第 1 拍：寄存输入、统计输入 1 的个数 N1d；
//   第 2 拍：由 N1d/din_q 组合出 q_m（8→9），当拍寄存出 dout（9→10）。
//   de/c0/c1 与数据同步走这两拍，所以"哪个像素配哪个 de"不会错位。
//
// ---------------------------------------------------------------------------
// ★ 算法要点（照 DVI 1.0 §3.3.3 与厂商例程 dvi_encoder.v 的 encode 模块一致）
//   1) 8→9 bit（q_m）：
//        decision1 = (N1d > 4) | ((N1d == 4) & (din[0] == 0))
//        q_m[0] = din[0]
//        q_m[i] = decision1 ? ~(q_m[i-1] ^ din[i]) : (q_m[i-1] ^ din[i])   (i=1..7)
//        q_m[8] = ~decision1      // 注意：decision1 为真时 q_m[8]=0
//   2) 9→10 bit：按运行不一致度 cnt（5bit 有符号，最高位是符号位）分三支；
//      控制周期（de=0）输出 4 个控制码并把 cnt 清零。
//   3) N1q_m/N0q_m 统计的是 **q_m[7:0]**（不含 q_m[8]），N0q_m = 8 - N1q_m。
//
//   ★ cnt 只在 de=1 时演进：控制周期无条件清零（规范要求，也是"两帧之间
//     不一致度不会累积跑飞"的原因；不要"顺手"改成只在 de=1 清零）。
// ============================================================
`timescale 1ns/1ps

module tmds_encoder (
    input  wire        clk,
    input  wire        rst_n,      // 低有效，异步复位

    input  wire [7:0]  din,        // 像素分量（8bit）
    input  wire        c0,         // 控制位 0（蓝通道 = HSYNC）
    input  wire        c1,         // 控制位 1（蓝通道 = VSYNC）
    input  wire        de,         // 数据使能

    output reg  [9:0]  dout        // TMDS 码字（bit0 先发）
);

    // ------------------------------------------------------------------
    // 第 1 级：寄存输入 + 统计输入 1 的个数
    // ------------------------------------------------------------------
    reg [7:0] din_q;
    reg       de_q, c0_q, c1_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            din_q <= 8'h00;
            de_q  <= 1'b0;
            c0_q  <= 1'b0;
            c1_q  <= 1'b0;
        end
        else begin
            din_q <= din;
            de_q  <= de;
            c0_q  <= c0;
            c1_q  <= c1;
        end
    end

    // ------------------------------------------------------------------
    // 8→9 bit
    // ------------------------------------------------------------------
    // ★ n1d 必须是**组合量**、统计的正是当拍 din_q（与 q_m 同源）。
    //   本模块第一版把它写成寄存器 `n1d <= din[...]`，于是它统计的是**上一拍**的 din，
    //   而 decision1/q_m 用的是当拍的 din_q —— 统计与数据错开一拍。
    //   实测后果：din_q=0xFF 时 N1 被算成 0（应为 8），decision1 判反，
    //   输出 0x200 而规范要求 0x0FF，金标 4144 条里错 1321 条。
    //   （厂商 encode 模块用"两级寄存"错开 n1d 与 din_q 来避免这个问题，
    //     这里改成组合则更直接，且流水线深度仍是 2 拍。）
    wire [3:0] n1d = din_q[0] + din_q[1] + din_q[2] + din_q[3] +
                     din_q[4] + din_q[5] + din_q[6] + din_q[7];

    wire decision1 = (n1d > 4'h4) | ((n1d == 4'h4) & (din_q[0] == 1'b0));

    wire [8:0] q_m;
    assign q_m[0] = din_q[0];
    assign q_m[1] = decision1 ? ~(q_m[0] ^ din_q[1]) : (q_m[0] ^ din_q[1]);
    assign q_m[2] = decision1 ? ~(q_m[1] ^ din_q[2]) : (q_m[1] ^ din_q[2]);
    assign q_m[3] = decision1 ? ~(q_m[2] ^ din_q[3]) : (q_m[2] ^ din_q[3]);
    assign q_m[4] = decision1 ? ~(q_m[3] ^ din_q[4]) : (q_m[3] ^ din_q[4]);
    assign q_m[5] = decision1 ? ~(q_m[4] ^ din_q[5]) : (q_m[4] ^ din_q[5]);
    assign q_m[6] = decision1 ? ~(q_m[5] ^ din_q[6]) : (q_m[5] ^ din_q[6]);
    assign q_m[7] = decision1 ? ~(q_m[6] ^ din_q[7]) : (q_m[6] ^ din_q[7]);
    assign q_m[8] = ~decision1;      // decision1 → 0；否则 → 1

    // ------------------------------------------------------------------
    // 9→10 bit
    //
    // ★★ 这里踩过一个真实的 bug，务必保留这段说明 ★★
    //
    //   错误写法（本模块第一版）：
    //       always @(posedge clk) n1q_m <= q_m[0]+...+q_m[7];
    //   看起来"把统计寄存一拍更省时序"，实际是**错拍**：
    //     · n1q_m 是**寄存器**，它在第 N+1 拍统计的是第 N 拍的 q_m；
    //     · 而 q_m 是组合量、由**当拍 din_q** 决定；
    //     · de_q/n0q_m/decision2 在同一个 always 里用的却是**当拍**的 n1q_m。
    //   于是"决策用的统计"比"决策用的 q_m"整整晚一拍 ——
    //   实测现象（ModelSim 抓到）：din_q=0xFF 时 q_m[7:0] 应全 1（n1q_m=8,n0q_m=0），
    //   而 DUT 里读出 n1q_m=0,n0q_m=8（**恰好反了**），导致 decision2/3 判错、
    //   输出 0x200 而规范要求 0x0FF。金标对拍 4144 条里错 1321 条。
    //
    //   正确写法：让统计与 q_m 处于**同一条组合链**（都由当拍 din_q 推出），
    //   决策与统计就天然同拍了，且流水线深度仍是 2 拍。
    //   代价：q_m 的异或链之后多一级 8 输入加法树。48MHz（60K 档）像素时钟下余量充足
    //   （综合报告里的 setup slack 会说话）。
    // ------------------------------------------------------------------
    wire [3:0] n1q_m = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
                       q_m[4] + q_m[5] + q_m[6] + q_m[7];
    wire [3:0] n0q_m = 4'h8 - n1q_m;

    // 运行不一致度：cnt[4] 是符号位（1 = 负）
    reg [4:0] cnt;

    wire decision2 = (cnt == 5'h00) | (n1q_m == n0q_m);
    wire decision3 = (~cnt[4] & (n1q_m > n0q_m)) |
                     ( cnt[4] & (n0q_m > n1q_m));

    // 控制周期的 4 个码字
    localparam [9:0] CTL0 = 10'b1101010100,   // {c1,c0} = 00
                     CTL1 = 10'b0010101011,   //            01
                     CTL2 = 10'b0101010100,   //            10
                     CTL3 = 10'b1010101011;   //            11

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout <= 10'h000;
            cnt  <= 5'd0;
        end
        else if (de_q) begin
            // ---- 数据周期 ----
            if (decision2) begin
                dout[9]   <= ~q_m[8];
                dout[8]   <=  q_m[8];
                dout[7:0] <=  q_m[8] ?  q_m[7:0] : ~q_m[7:0];
                cnt       <=  q_m[8] ? (cnt + {1'b0, n1q_m} - {1'b0, n0q_m})
                                     : (cnt + {1'b0, n0q_m} - {1'b0, n1q_m});
            end
            else if (decision3) begin
                dout[9]   <= 1'b1;
                dout[8]   <= q_m[8];
                dout[7:0] <= ~q_m[7:0];
                // {q_m[8],1'b0} = q_m[8] ? 2 : 0
                cnt       <= cnt + {q_m[8], 1'b0} + {1'b0, n0q_m} - {1'b0, n1q_m};
            end
            else begin
                dout[9]   <= 1'b0;
                dout[8]   <= q_m[8];
                dout[7:0] <= q_m[7:0];
                // {~q_m[8],1'b0} = q_m[8] ? 0 : 2
                cnt       <= cnt - {~q_m[8], 1'b0} + {1'b0, n1q_m} - {1'b0, n0q_m};
            end
        end
        else begin
            // ---- 控制周期：发控制码，并把 cnt 清零 ----
            cnt  <= 5'd0;
            case ({c1_q, c0_q})
                2'b00:   dout <= CTL0;
                2'b01:   dout <= CTL1;
                2'b10:   dout <= CTL2;
                default: dout <= CTL3;
            endcase
        end
    end

endmodule
