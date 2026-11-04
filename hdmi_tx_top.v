// ============================================================
// 模块名：hdmi_tx_top
// 功能：HDMI/DVI 发送物理层（TMDS 编码 + 10:1 串行化 + 差分输出）
//
// 时钟域：pix_clk（48MHz，编码） + ser_clk（240MHz = 5×pix，串行化）
//   ★ 线速记账（t17）：每 lane 比特率 = 2 × ser_clk = **480 Mbps**（旧 51/255 档是 510）。
// 依赖：tmds_encoder ×3、tmds_serializer（内部例化 ODDR 原语）
//
// ---------------------------------------------------------------------------
// ★ 接口约定（上层只要按像素时钟给这 5 个信号，PHY 全包）
//      vde  = 数据使能；hs/vs = 行/场同步（**低有效**，与 video_timing 一致）
//      rgb  = {R[7:0], G[7:0], B[7:0]}
//   三路 TMDS 通道的映射（与厂商 .cst/例化一致，不要随意换）：
//      lane0 = 蓝，且**同步信号走蓝通道的控制周期**（c0=hs, c1=vs）
//      lane1 = 绿（c0=c1=0）
//      lane2 = 红（c0=c1=0）
//   引脚：tmds_data_p[0]/n[0] = R7/T7（蓝）
//         tmds_data_p[1]/n[1] = T6/V6（绿）
//         tmds_data_p[2]/n[2] = R5/T5（红）
//         tmds_clk_p/n = M10/N9
//
// ---------------------------------------------------------------------------
// ★ 两个时钟域在这里交汇，复位要分域
//   rst_n 由 pix 域给出（异步复位、同步释放）。串行器在 ser_clk 域，
//   直接把 pix 域的"同步释放"拿去当 ser 域复位会踩恢复/移除时间违例，
//   所以本模块内部给 ser 域做一次"异步置位、同步释放"（2FF）。
//   ★ 不要图省事把两个域接同一个 rst_n —— 这正是 PITFALLS §B.3 那类坑。
//
// ★ 编码延迟：三路编码器都是 2 拍，且相位完全一致 → 三色之间零 skew。
//   vde/hs/vs 走的是各自编码器内部的同一级延迟链，所以"像素-同步-使能"
//   三者的相对关系自动保持，不需要在外面另加补偿。
//   （唯一代价：整帧相对 hs/vs 平移 2 个像素，对显示无影响。）
// ============================================================
`timescale 1ns/1ps

module hdmi_tx_top #(
    // ★★ t5（2026-10-07）：0（默认）= `tmds_*_n` 四根 tie 成高阻（本板正确接法）；
    //   1 = 恢复 p/n 各一个 ODDR 的老行为。理由与实测落位见
    //   `tmds_serializer.v` 文件头「负端 ODDR 默认整体禁用」一节。
    //   ★ 这个参数**不改变 `_p` 四条的信号路径**。
    parameter integer USE_NEG_ODDR = 0,
    // ★ 2026-10-09：串行化实现二选一（默认 0 = 现行，位流不变）
    parameter integer USE_OSER10   = 0
)(
    input  wire        pix_clk,      // 48MHz（60K 档；25A 是 51MHz）
    input  wire        ser_clk,      // 240MHz（= 5 × pix_clk；25A 是 5 × 51MHz）
    input  wire        rst_n,        // pix 域复位，低有效

    input  wire        vde,          // 数据使能
    input  wire        hs,           // 行同步（低有效）
    input  wire        vs,           // 场同步（低有效）
    input  wire [23:0] rgb,          // {R,G,B}

    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n
);

    // ------------------------------------------------------------------
    // ser 域复位：异步置位、同步释放
    // ------------------------------------------------------------------
    reg [1:0] ser_rst_sync;

    always @(posedge ser_clk or negedge rst_n) begin
        if (!rst_n) ser_rst_sync <= 2'b00;
        else        ser_rst_sync <= {ser_rst_sync[0], 1'b1};
    end

    wire ser_rst_n = ser_rst_sync[1];

    // ------------------------------------------------------------------
    // 三路 TMDS 编码
    // ------------------------------------------------------------------
    wire [9:0] tmds_b, tmds_g, tmds_r;

    tmds_encoder u_enc_b (
        .clk   (pix_clk),
        .rst_n (rst_n),
        .din   (rgb[7:0]),      // 蓝
        .c0    (hs),            // ★ 同步信号藏在蓝通道
        .c1    (vs),
        .de    (vde),
        .dout  (tmds_b)
    );

    tmds_encoder u_enc_g (
        .clk   (pix_clk),
        .rst_n (rst_n),
        .din   (rgb[15:8]),     // 绿
        .c0    (1'b0),
        .c1    (1'b0),
        .de    (vde),
        .dout  (tmds_g)
    );

    tmds_encoder u_enc_r (
        .clk   (pix_clk),
        .rst_n (rst_n),
        .din   (rgb[23:16]),    // 红
        .c0    (1'b0),
        .c1    (1'b0),
        .de    (vde),
        .dout  (tmds_r)
    );

    // ------------------------------------------------------------------
    // 10:1 串行化 + 差分输出
    //   时钟 lane 的图案固定为 10'b1111100000（5 低 5 高 = 1 个 pix_clk 周期的方波）
    //   ★★ t5（2026-10-07）：`USE_NEG_ODDR` 透传下去，**默认 0** ⇒ 本板的
    //     `tmds_*_n` 由 tmds_serializer 直接接 1'bz（高阻），不再生成 4 个
    //     独立单端 ODDR（它们会被 PnR 落到与 _p 无关的随机球位上）。
    //     测量依据见 tmds_serializer.v 文件头。**不改 _p 四条信号路径**。
    // ------------------------------------------------------------------
    tmds_serializer #(
        .USE_NEG_ODDR (USE_NEG_ODDR),
        // ★ 2026-10-09（P1-0 路③）：默认 0 = 现行 ODDR 通路，正式位流逐位不变。
        //   置 1 改用 gw5at 的 OSER10（消除 240MHz FF→ODDR 路径）；见 tmds_serializer.v 参数注释。
        .USE_OSER10   (USE_OSER10)
    ) u_ser (
        .ser_clk    (ser_clk),
        .pix_clk    (pix_clk),
        .rst_n      (ser_rst_n),
        .d_lane0    (tmds_b),
        .d_lane1    (tmds_g),
        .d_lane2    (tmds_r),
        .d_lane3    (10'b1111100000),
        .tmds_data_p(tmds_data_p),
        .tmds_data_n(tmds_data_n),
        .tmds_clk_p (tmds_clk_p),
        .tmds_clk_n (tmds_clk_n)
    );

endmodule
