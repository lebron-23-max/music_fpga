// ============================================================
// 模块名：tmds_serializer
// 功能：TMDS 10:1 串行化（4 条 lane：3 数据 + 1 时钟），差分 p/n 输出
//
// 时钟域：ser_clk = **240MHz** = 5 × pix_clk（由 rtl/top/clk_gen_video.v 同一颗 PLLA 出）
//  ★★ 线速记账（t17）：本模块每个 ser_clk 周期在 ODDR 的**两个沿**各出 1 bit
//     ⇒ TMDS 每 lane 比特率 = **2 × 240MHz = 480 Mbps**。**不是 510 Mbps** ——
//     510 是旧的 51MHz 像素档（ser_clk = 5 × 51）的账；见到底稿里写 510Mbps 的
//     地方（旧注释 / 外部文档 / 早先的交接材料），一律按历史档处理。
// 依赖：Gowin 原语 **ODDR**（厂商相关的只允许出现在 rtl/io/、rtl/top/）
//
// ---------------------------------------------------------------------------
// ★ 为什么是"5bit 移位 + ODDR 双沿"= 10:1
//   GW5A-25A 的原语库（simlib/gw5a/prim_sim.v 实测）里**没有** OSERDES，
//   只有 ODDR（2:1 硬核 DDR 输出）。所以要做 10:1 只能这样拼：
//       fabric 里用 5bit 移位寄存器跑 ser_clk(=5×pix)，每个 ser_clk 周期挪 1 bit；
//       ODDR 在这 5 个周期的**上升沿/下降沿各出 1 bit** → 每像素 10 bit。
//   这正是厂商例程 ch26_hdmi_color/src/dvi_encoder.v 的 serdes_4b_10to1 做法，
//   本模块按同一思路重写（修掉了厂商那份里 TMDS_2_l/TMDS_2_h 误用 datain_3
//   的位这一处笔误——因为 datain_3 恒为常数，厂商那里"碰巧无害"）。
//
// ---------------------------------------------------------------------------
// ★ 位序（TMDS 规定 **LSB 先发**，这是最容易搞反、也最容易只看波形看不出的地方）
//   每个 10bit 码字 d[9:0]，一个像素周期内串行发出的顺序必须是：
//       d[0] d[1] d[2] ... d[9]
//   本模块把一个码字拆成两组（低位在前）：
//       rise 组 = {d[8], d[6], d[4], d[2], d[0]}  → 送 ODDR 的 **D0**（上升沿出）
//       fall 组 = {d[9], d[7], d[5], d[3], d[1]}  → 送 ODDR 的 **D1**（下降沿出）
//   于是时间顺序 = d0(升) d1(降) d2(升) d3(降) ... d8(升) d9(降) ✔
//   ★ 组内是"右移"：rise[0]/fall[0] 是最先出去的位，每拍右移一位。
//
// ---------------------------------------------------------------------------
// ★ 装载节拍：mod5 计到 4 时**整组重装**（即每 5 个 ser_clk = 恰好 1 个像素）
//   ser_clk 与 pix_clk 由同一 VCO 整数分频而来（510/2 与 510/10），相位固定，
//   所以"每 5 拍重装一次"天然与像素节拍对齐，不需要再做跨域握手。
//   上电瞬间可能差一个像素（第一次装载采到旧值），但相位关系固定，
//   之后永远不再漂移 —— 一帧内容整体平移 1 像素，肉眼不可见，也不会抖动。
//
// ---------------------------------------------------------------------------
// ★ 负端怎么产生：p/n 各用一个 ODDR，n 端输入取反（厂商同做法）。
//   HDMI 差分对在板上的接法是 p/n 分别串阻到连接器，所以这里就是
//   "两路反相 LVCMOS33 + 外部电阻网络"的经典低成本 TMDS 驱动方式，
//   .cst 里 IO_TYPE=LVCMOS33/DRIVE=8/PULL_MODE=NONE 必须与之一致。
//
// ===========================================================================
// ★★★ 2026-10-07（t5，GW5AT-60K bring-up）：负端 ODDR **默认整体禁用**
//
//   为什么：顶层 `tmds_*_n` 这 4 个端口在 .cst 里**没有 IO_LOC**
//   （见 `mega60k/constraints/OX-1-60K.cst`「DVI/HDMI TMDS 输出」整节），
//   于是 PnR 把它们落到了**与 _p 完全无关**的 4 个球位上。
//
//   ★★★ **落点每次 build 都可能变**（这正是"不给 IO_LOC"的代价：抽签）。
//     三次实测（`mega60k/impl/pnr/OX-1-60K.rpt.txt` / BUILD_LOG.md 记录 1)、2)）：
//       · 18:52 与 20:00 两次都是 **M6 / M5 / P2 / N2**
//         —— 那是 **SOM 板载 512MiB DDR3 的控制线**（`ddr_bank[2]` / `ddr_we`
//            / `ddr_bank[1]` 一带），即把 4 根 240MHz 活信号（线速 480Mbps）接到了 DDR3 上；
//       · 更早一次是 **G18 / G20 / L15 / J20**（其中 G20 → JOYA_RXD_3V3，
//         会与 Joy-Con A 的外部 TX 电平对打）。
//     ⇒ **同一个 RTL 两次 build 落点不同**，这就是"必须 tie 成高阻、
//       不能让工具抽签"的直接证据。
//
//   而 _p 那 4 条走的是 **LVCMOS33D（真差分输出缓冲）**：
//       tmds_clk_p → G15/4 [A]，tmds_data_p[0] → J14/4 [A]，
//       tmds_data_p[1] → J15/4 [A]，tmds_data_p[2] → K17/5 [A]
//   差分缓冲已经驱动了连接器的 _p/_n 两腿 ⇒ RTL 里这 4 个独立单端 ODDR
//   **既冗余又落在没人管的球位上**（240MHz 活信号 / 线速 480Mbps 输出到未知网络）。
//
//   ⚠ 取证订正（t5 实测，只记事实）：任务书原写「_p 用 (p)/(n) 两球位、
//     _n 的 ODDR 与它**同一个 IOB**」——20:00 这份 pin.html/rpt 实测是
//     **_p 各占 1 球（A 腿），_n 完全落在别的 IOB**（M6/M5/P2/N2）。
//     所以 _n 不是"与差分补重复"，而是**额外的 4 个单端输出**；
//     结论不变（要 tie 高阻），但依据要以本条实测为准。
//
//   ★ 本项目已有同形先例：`i2s_mclk` 在 60K 上"刻意不给 IO_LOC"，
//     顶层用一个常量把它钉住，**不删端口**（见 fm_synth_top.v 第 6a 节）。
//     本参数走同一条约定。
//
//   ★ 为什么是 **1'bz（高阻）而不是 1'b0**：高阻 = 把球位真正放开，
//     不与板上任何外部驱动源对打（0 是**主动**驱动低电平，会与外部
//     TX/缓冲对打出电流）。本项目先例：`kp_col_o` 未选中列就是 1'bz。
//
//   ★ 参数默认 0 ⇒ **正式位流的 TMDS 正向路径逐位不变**：_p 那 4 个 ODDR
//     与整条移位链一个字都没动（lane3 的移位链仍要跑：它供 tmds_clk_p）。
//     这个参数只决定"_n 是接 ODDR 还是接高阻"。
// ============================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// ★ 仿真时用 `+define+SIM_ODDR` 把原语换成仿真模型 oddr_sim（定义在
//   rtl/io/video/sim/tb_video_io.v 里，端口与参数和真 ODDR 完全一致）。
//   原因：GW5A 的 prim_sim.v 里 ODDR 模型引用了全局 GSR，ModelSim 解析不到；
//   综合/上板走 `else 分支，用的就是真原语 ODDR，不受影响。
// ---------------------------------------------------------------------------
`ifdef SIM_ODDR
  `define TMDS_ODDR(NAME,Q0,Q1,D0,D1,TX,CLK) oddr_sim NAME (Q0, Q1, D0, D1, TX, CLK)
`else
  `define TMDS_ODDR(NAME,Q0,Q1,D0,D1,TX,CLK) ODDR     NAME (Q0, Q1, D0, D1, TX, CLK)
`endif
// ★ 2026-10-09（P1-0 路③）：OSER10 通路（默认**不启用**，见参数 USE_OSER10）
//   仿真模型位置与 GSR 坑见 `work/2026-10-09_p1_128poly/evidence/p1_0_oser10_findings.md`
//   ★★ 宏写法有两个坑，都踩过（实测）：
//     ① **正文里不能出现 `[`** —— `DAT[9]` 会让 ModelSim 报
//        `vlog-13069 near "[" syntax error, unexpected '['`。⇒ 改成 10 个独立位实参。
//     ② **宏参数名不能用 `D`** —— 正文的 `D0..D9` 会被文本替换成 `<实参>0..9`
//        （`D0` → `d_lane00`）。这里参数名用 `B0..B9`，正文只有位置化端口名 `D0..D9`。
//   ★ 位置化端口序：`OSER10 (Q, D0, D1, …, D9, PCLK, FCLK, RESET)`；
//     接法定案为 `D1=d[0], D2=d[1], … D9=d[8], D0=d[9]` ⇒ 位置序 = `Q, d[9], d[0], d[1], …, d[8]`。
`ifdef SIM_OSER
  `define TMDS_OSER(NAME,Q,B0,B1,B2,B3,B4,B5,B6,B7,B8,B9,PCLK,FCLK,RST) oser10_sim NAME (Q, B9, B0, B1, B2, B3, B4, B5, B6, B7, B8, PCLK, FCLK, RST)
`else
  `define TMDS_OSER(NAME,Q,B0,B1,B2,B3,B4,B5,B6,B7,B8,B9,PCLK,FCLK,RST) OSER10     NAME (Q, B9, B0, B1, B2, B3, B4, B5, B6, B7, B8, PCLK, FCLK, RST)
`endif

module tmds_serializer #(
    // ★ 0（默认）= _n 四根 tie 成高阻（GW5AT-60K 板上的正确接法，见文件头）
    //   1         = 恢复"p/n 各一个 ODDR"的老行为（25A 板 / 需要时再打开）
    parameter integer USE_NEG_ODDR = 0,
    // ★★ 2026-10-09（P1-0 路③）：串行化实现二选一
    //   0（默认）= 现行「fabric 5bit 移位 + ODDR 双沿」——**正式位流逐位不变**
    //   1        = 改用 gw5at 的 **OSER10 专用 10:1 串行器**
    //   为什么要有 1：族① 的 `FF→ODDR` 在 ser_clk 240MHz 上 `tCL` 已占 99.4%，
    //   是**器件 tCL 极限、插流水无效**（p3-0 §5 实测）。OSER10 把串行化搬进
    //   IOLOGIC 硬核 ⇒ 该路径从根上消失。
    //   ★ 原注释写"GW5A-25A 原语库没有 OSERDES"——**那句只对 25A 成立**；
    //     gw5at 库（`IDE/data/hardware_core/gw5at/prim_syn.v:196`）**有 OSER10**。
    //   ★ 接法已实测定案（对着厂商行为模型逐位验过，见 findings 文件）：
    //     `D1=d[0], D2=d[1], … D9=d[8], D0=d[9]` ⇒ 输出严格 **LSB-first**。
    //   ★ `OSER10.RESET` 是**高有效**（`lrstn = ~RESET`）⇒ 这里送 `~rst_n`。
    parameter integer USE_OSER10 = 0
) (
    input  wire        ser_clk,      // 240MHz（= 5 × pix_clk；线速 480Mbps）
    input  wire        pix_clk,      // 48MHz（仅 OSER10 通路需要它的 PCLK）
    input  wire        rst_n,        // 低有效（ser_clk 域）

    input  wire [9:0]  d_lane0,      // 蓝
    input  wire [9:0]  d_lane1,      // 绿
    input  wire [9:0]  d_lane2,      // 红
    input  wire [9:0]  d_lane3,      // 时钟 lane 的 10bit 图案（一般接 10'b1111100000）

    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n
);

    // ------------------------------------------------------------------
    // 模 5 计数器：一个像素周期 = 5 个 ser_clk
    // ------------------------------------------------------------------
    generate
    if (USE_OSER10 == 0) begin : g_oddr_path
    // ================= 现行实现（默认）：5bit 移位 + ODDR 双沿 =================
    reg [2:0] mod5;

    always @(posedge ser_clk or negedge rst_n) begin
        if (!rst_n)             mod5 <= 3'd0;
        else if (mod5 == 3'd4)  mod5 <= 3'd0;
        else                    mod5 <= mod5 + 3'd1;
    end

    wire load = (mod5 == 3'd4);      // 装载（= 新的一个像素）

    // ------------------------------------------------------------------
    // 四条 lane 的移位寄存器
    //   命名：sh_rise_* 送 ODDR D0（上升沿），sh_fall_* 送 ODDR D1（下降沿）
    // ------------------------------------------------------------------
    reg [4:0] sh_rise0, sh_fall0;
    reg [4:0] sh_rise1, sh_fall1;
    reg [4:0] sh_rise2, sh_fall2;
    reg [4:0] sh_rise3, sh_fall3;

    always @(posedge ser_clk or negedge rst_n) begin
        if (!rst_n) begin
            sh_rise0 <= 5'd0; sh_fall0 <= 5'd0;
            sh_rise1 <= 5'd0; sh_fall1 <= 5'd0;
            sh_rise2 <= 5'd0; sh_fall2 <= 5'd0;
            sh_rise3 <= 5'd0; sh_fall3 <= 5'd0;
        end
        else if (load) begin
            // 重装：低位（先发的）放到 [0]
            sh_rise0 <= {d_lane0[8], d_lane0[6], d_lane0[4], d_lane0[2], d_lane0[0]};
            sh_fall0 <= {d_lane0[9], d_lane0[7], d_lane0[5], d_lane0[3], d_lane0[1]};
            sh_rise1 <= {d_lane1[8], d_lane1[6], d_lane1[4], d_lane1[2], d_lane1[0]};
            sh_fall1 <= {d_lane1[9], d_lane1[7], d_lane1[5], d_lane1[3], d_lane1[1]};
            sh_rise2 <= {d_lane2[8], d_lane2[6], d_lane2[4], d_lane2[2], d_lane2[0]};
            sh_fall2 <= {d_lane2[9], d_lane2[7], d_lane2[5], d_lane2[3], d_lane2[1]};
            sh_rise3 <= {d_lane3[8], d_lane3[6], d_lane3[4], d_lane3[2], d_lane3[0]};
            sh_fall3 <= {d_lane3[9], d_lane3[7], d_lane3[5], d_lane3[3], d_lane3[1]};
        end
        else begin
            // 右移一位（最高位补 0，移出去的低位就是本拍要发的位）
            sh_rise0 <= {1'b0, sh_rise0[4:1]};
            sh_fall0 <= {1'b0, sh_fall0[4:1]};
            sh_rise1 <= {1'b0, sh_rise1[4:1]};
            sh_fall1 <= {1'b0, sh_fall1[4:1]};
            sh_rise2 <= {1'b0, sh_rise2[4:1]};
            sh_fall2 <= {1'b0, sh_fall2[4:1]};
            sh_rise3 <= {1'b0, sh_rise3[4:1]};
            sh_fall3 <= {1'b0, sh_fall3[4:1]};
        end
    end

    // Q1 输出不使用：用显式未连接线占位（宏参数里不能留空）
    wire tmds_unused0, tmds_unused1, tmds_unused2, tmds_unused3,
         tmds_unused4, tmds_unused5, tmds_unused6, tmds_unused7;

    // ------------------------------------------------------------------
    // ODDR 输出（p 正相 / n 反相）
    //   TX 接 0 = 输出使能（厂商例程同样接 GND；prim_sim 的 ODDR 模型里
    //   TX 只影响 Q1，不影响 Q0，极性以厂商上板验证过的接法为准）。
    //
    // ★★ 2026-10-07（t5）：_p 那 4 个 ODDR **永远就是下面这 4 条，一行没动**；
    //    _n 那 4 个由 USE_NEG_ODDR 决定 —— 0（默认）时**不生成 ODDR**，
    //    顶层直接接 1'bz（见文件头「负端 ODDR 默认整体禁用」）。
    //    ⇒ 正式位流的 TMDS 正向路径逐位不变。
    // ------------------------------------------------------------------
    `TMDS_ODDR(oddr_d0_p, tmds_data_p[0], tmds_unused0, sh_rise0[0], sh_fall0[0], 1'b0, ser_clk);   // 蓝 p
    `TMDS_ODDR(oddr_d1_p, tmds_data_p[1], tmds_unused2, sh_rise1[0], sh_fall1[0], 1'b0, ser_clk);   // 绿 p
    `TMDS_ODDR(oddr_d2_p, tmds_data_p[2], tmds_unused4, sh_rise2[0], sh_fall2[0], 1'b0, ser_clk);   // 红 p
    `TMDS_ODDR(oddr_ck_p, tmds_clk_p,     tmds_unused6, sh_rise3[0], sh_fall3[0], 1'b0, ser_clk);   // 时钟 p

        // ★ 这里**不能**再写 generate/endgenerate（vlog-13060 Cannot nest generate regions）：
        //   外层已有 generate，条件 generate 直接写 if/else + 具名 begin 即可。
        if (USE_NEG_ODDR != 0) begin : g_neg_oddr
            `TMDS_ODDR(oddr_d0_n, tmds_data_n[0], tmds_unused1, ~sh_rise0[0], ~sh_fall0[0], 1'b0, ser_clk); // 蓝 n
            `TMDS_ODDR(oddr_d1_n, tmds_data_n[1], tmds_unused3, ~sh_rise1[0], ~sh_fall1[0], 1'b0, ser_clk); // 绿 n
            `TMDS_ODDR(oddr_d2_n, tmds_data_n[2], tmds_unused5, ~sh_rise2[0], ~sh_fall2[0], 1'b0, ser_clk); // 红 n
            `TMDS_ODDR(oddr_ck_n, tmds_clk_n,     tmds_unused7, ~sh_rise3[0], ~sh_fall3[0], 1'b0, ser_clk); // 时钟 n
        end
        else begin : g_neg_z
            // 高阻：把 4 个球位真正放开（不是钉 0 —— 钉 0 会主动对打）
            assign tmds_data_n  = 3'bzzz;
            assign tmds_clk_n   = 1'bz;
        end
    end
    else begin : g_oser_path
    // ================= OSER10 专用串行器（USE_OSER10=1）=================
    //   好处：串行化进 IOLOGIC 硬核 ⇒ 族① 的 `FF→ODDR` 240MHz 路径消失。
    //   接法（实测定案）：D1=d[0], D2=d[1], … D9=d[8], D0=d[9] ⇒ LSB-first。
    //   `_n` 同默认口径：本板把 4 根负端 tie 成高阻（文件头「负端 ODDR 默认整体禁用」）。
    `TMDS_OSER(oser_d0, tmds_data_p[0],
               d_lane0[0],d_lane0[1],d_lane0[2],d_lane0[3],d_lane0[4],
               d_lane0[5],d_lane0[6],d_lane0[7],d_lane0[8],d_lane0[9],
               pix_clk, ser_clk, ~rst_n);                                   // 蓝
    `TMDS_OSER(oser_d1, tmds_data_p[1],
               d_lane1[0],d_lane1[1],d_lane1[2],d_lane1[3],d_lane1[4],
               d_lane1[5],d_lane1[6],d_lane1[7],d_lane1[8],d_lane1[9],
               pix_clk, ser_clk, ~rst_n);                                   // 绿
    `TMDS_OSER(oser_d2, tmds_data_p[2],
               d_lane2[0],d_lane2[1],d_lane2[2],d_lane2[3],d_lane2[4],
               d_lane2[5],d_lane2[6],d_lane2[7],d_lane2[8],d_lane2[9],
               pix_clk, ser_clk, ~rst_n);                                   // 红
    `TMDS_OSER(oser_ck, tmds_clk_p,
               d_lane3[0],d_lane3[1],d_lane3[2],d_lane3[3],d_lane3[4],
               d_lane3[5],d_lane3[6],d_lane3[7],d_lane3[8],d_lane3[9],
               pix_clk, ser_clk, ~rst_n);                                   // 时钟 lane
    assign tmds_data_n = 3'bzzz;
    assign tmds_clk_n  = 1'bz;
    end
    endgenerate

endmodule
