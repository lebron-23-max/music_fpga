`timescale 1ns / 1ps
//=============================================================================
// spectrum_engine.v —— 实时频谱（2 通道 x 52 半音 Goertzel）
//=============================================================================
// 数据来源：piano_audio / music_box_audio，真实音频，不做替代或占位。
//
// 算法：
//   每个频点一个二阶 Goertzel 谐振器
//       s[n] = x[n] + a*s[n-1] - s[n-2],  a = 2cos(2*pi*f/Fs)（Q14）
//   分析窗 2048 点（约 23.8 Hz 分辨率），窗内加三角窗（Bartlett，旁瓣 -26 dB）。
//   窗结束用标准 Goertzel 功率公式求幅度：
//       |X|^2 = s1^2 + s2^2 - a*s1*s2
//   注意：不能再用 |s1|+|s2| 近似！无阻尼时 s1/s2 含一个随窗长线性增长的
//   瞬态项，|s1|+|s2| 会随输入相位在 0..满幅之间乱跳（2026-10-17 实测）。
//   功率公式把瞬态项抵消掉，结果与起始相位无关。
//
// 显示：功率 -> 对数刻度（每个 2 倍功率 = 8 个显示单位，约 1.33 单位/dB），
//   只用一个前导 1 检测 + 3 bit 尾数，不需要 sqrt/LUT。
//
// 时分复用：104 个谐振器共用 1 个乘法器 + 1 块 208x23 状态 RAM。
//   吸收 8 拍/频点（832 拍），幅度 9 拍/频点（936 拍）；每个采样周期 1024 拍，
//   幅度阶段会跨过约 1.3 个采样点（0.06%），对 2048 点窗无可见影响。
//
// ★ 门级纪律：本模块含乘法、累加、BSRAM、位宽截断，改完必须做综合后网表
//   + Gowin 原语库的门级仿真并与 RTL 逐样本对比（见交接文档 §0.2）。
//=============================================================================
module spectrum_engine (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire signed [15:0] sig0,        // 钢琴
    input  wire signed [15:0] sig1,        // 八音盒
    input  wire signed [15:0] sig2,        // 电钢琴
    input  wire signed [15:0] sig3,        // 弦乐

    output reg                ud_we,
    output reg  [7:0]         ud_addr,
    output reg  [7:0]         ud_data,
    output reg  [31:0]        dbg_updates
);
    localparam integer NBIN = 52;
    localparam integer NB   = 104;
    localparam integer WINC = 2048;

    reg [2:0]  mode;
    reg        pair_sel;
    reg [6:0]  bin;
    reg [3:0]  ph;
    reg [12:0] scnt;
    reg [7:0]  rst_i;

    //=================================================================
    // 系数表（52 个半音，C5..B8，Q14 = round(2cos(2*pi*f/Fs)*16384)）
    //=================================================================
    function signed [15:0] coef_of;
        input [5:0] k;
        reg signed [15:0] coef;
        begin
            coef = 16'sd0;
            case (k)
`include "spectrum_coef.vh"
            default: coef = 16'sd0;
            endcase
            coef_of = coef;
        end
    endfunction

    // Strings use a C3..B6 table so the sustained song register is visible.
    function signed [15:0] coef_low_of;
        input [5:0] k;
        reg signed [15:0] coef;
        begin
            coef = 16'sd0;
            case (k)
`include "spectrum_coef_low.vh"
            default: coef = 16'sd0;
            endcase
            coef_low_of = coef;
        end
    endfunction

    wire [6:0] coef_idx = (bin >= 7'd52) ? (bin - 7'd52) : bin;
    wire       coef_low_sel = pair_sel && (bin >= 7'd52);

    //=================================================================
    // 状态 RAM：208 x 23 bit（地址 bin=s1，地址 104+bin=s2）
    //=================================================================
    reg signed [22:0] st_mem [0:207];
    reg               st_we;
    reg [7:0]         st_waddr;
    reg signed [22:0] st_wdata;
    reg [7:0]         st_raddr;
    reg signed [22:0] st_rdata;

    always @(posedge clk) if (st_we) st_mem[st_waddr] <= st_wdata;
    always @(posedge clk) st_rdata <= st_mem[st_raddr];

    //=================================================================
    // 输入自动量程 + 直流阻断 + 三角窗
    //=================================================================
    reg signed [7:0] x0, x1;

    reg [15:0] pk_leak0, pk_leak1;
    reg [15:0] pk0, pk1;
    wire signed [15:0] sig0_sel = pair_sel ? sig2 : sig0;
    wire signed [15:0] sig1_sel = pair_sel ? sig3 : sig1;
    wire [15:0] sg_abs0 = sig0_sel[15] ? (~sig0_sel + 16'd1) : sig0_sel;
    wire [15:0] sg_abs1 = sig1_sel[15] ? (~sig1_sel + 16'd1) : sig1_sel;
    wire [7:0] mag_base  = pair_sel ? 8'd104 : 8'd0;
    wire [7:0] peak_base = pair_sel ? 8'd210 : 8'd208;
    // 先寄存绝对值，切断 "piano_audio -> pk_leak CE" 的长组合路径（显示自动量程晚 1 个采样无影响）
    reg [15:0] sg_abs0_r, sg_abs1_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sg_abs0_r <= 16'd0; sg_abs1_r <= 16'd0; end
        else if (sample_tick) begin sg_abs0_r <= sg_abs0; sg_abs1_r <= sg_abs1; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pk_leak0 <= 16'd0; pk_leak1 <= 16'd0; pk0 <= 16'd0; pk1 <= 16'd0;
        end else if (sample_tick) begin
            pk0 <= pk_leak0;  pk1 <= pk_leak1;
            pk_leak0 <= (sg_abs0_r > pk_leak0) ? sg_abs0_r :
                        ((pk_leak0 > 16'd64) ? (pk_leak0 - (pk_leak0 >> 10)) : pk_leak0);
            pk_leak1 <= (sg_abs1_r > pk_leak1) ? sg_abs1_r :
                        ((pk_leak1 > 16'd64) ? (pk_leak1 - (pk_leak1 >> 10)) : pk_leak1);
        end
    end

    // shift = msb - 5：目标 6 bit；高通在高端最多再放大 ~2 倍，留 1 bit 余量。
    function [3:0] sh_of;
        input [15:0] p;
        begin
            if      (p[15]) sh_of = 4'd10;
            else if (p[14]) sh_of = 4'd9;
            else if (p[13]) sh_of = 4'd8;
            else if (p[12]) sh_of = 4'd7;
            else if (p[11]) sh_of = 4'd6;
            else if (p[10]) sh_of = 4'd5;
            else if (p[9])  sh_of = 4'd4;
            else if (p[8])  sh_of = 4'd3;
            else if (p[7])  sh_of = 4'd2;
            else            sh_of = 4'd0;
        end
    endfunction
    wire [3:0] sh0 = sh_of(pk0);
    wire [3:0] sh1 = sh_of(pk1);

    // 一阶高通：y = x - x[n-1] + (1 - 1/256)*y[n-1]
    // 全部用 signed 20 bit，不能混入拼接（拼接是无符号，会让 >>> 变成逻辑移位，
    // 负半周直接发散；2026-10-17 频谱全乱的根因）。
    reg signed [19:0] hp_x0, hp_x1;
    reg signed [19:0] hp_y0, hp_y1;
    wire signed [19:0] hx0 = {{4{sig0_sel[15]}}, sig0_sel};
    wire signed [19:0] hx1 = {{4{sig1_sel[15]}}, sig1_sel};
    wire signed [19:0] hy0 = hp_y0 + (hx0 - hp_x0) - (hp_y0 >>> 8);
    wire signed [19:0] hy1 = hp_y1 + (hx1 - hp_x1) - (hp_y1 >>> 8);
    wire signed [19:0] hy0_r = hy0 + 20'sd1024;
    wire signed [19:0] hy1_r = hy1 + 20'sd1024;

    // 8 bit 饱和（不能回绕：正峰截低 8 位会变成负峰）
    wire signed [19:0] xs0 = hy0_r >>> sh0;
    wire signed [19:0] xs1 = hy1_r >>> sh1;
    wire signed [7:0]  xsat0 = (xs0 > 20'sd127)  ? 8'sd127  :
                               (xs0 < -20'sd128) ? -8'sd128 : xs0[7:0];
    wire signed [7:0]  xsat1 = (xs1 > 20'sd127)  ? 8'sd127  :
                               (xs1 < -20'sd128) ? -8'sd128 : xs1[7:0];

    // 三角窗：w = 1 - |2n/(N-1) - 1|，Q8
    wire [12:0] wtri = (scnt < (WINC/2)) ? scnt : (WINC-1-scnt);
    wire [7:0]  wq   = wtri[12:3];
    wire signed [7:0] x_raw = (bin >= 7'd52) ? x1 : x0;
    wire signed [15:0] xwin = x_raw * $signed({1'b0, wq});
    wire signed [7:0]  x_cur = xwin >>> 8;

    //=================================================================
    // 流式峰值检测历史（每通道保留 7 个邻近幅度）
    //=================================================================
    reg [7:0] mag_hist0 [0:6];
    reg [7:0] mag_hist1 [0:6];
    reg [5:0] peak0_final, peak1_final;
    integer hi;

    //=================================================================
    // Goertzel 定点运算
    //=================================================================
    reg signed [22:0] s1_q, s2_q, snew_q;
    reg signed [15:0] coef_q;
    reg signed [38:0] prod_q;

    wire signed [38:0] rounded = prod_q + 39'sd16384;
    wire signed [26:0] scaled  = rounded >>> 14;
    wire signed [26:0] xext    = {{19{x_cur[7]}}, x_cur};
    wire signed [26:0] s2ext   = {{4{s2_q[22]}}, s2_q};
    wire signed [26:0] ssum    = xext + scaled - s2ext;
    wire signed [22:0] snew_sat = (ssum > 27'sd4194303)  ? 23'sd4194303 :
                                  (ssum < -27'sd4194304) ? -23'sd4194304 : ssum[22:0];

    //=================================================================
    // 幅度：|X|^2 = s1^2 + s2^2 - a*s1*s2（用高 16 位状态）
    //   共用 1 个 18x16 乘法器：p1=s1h^2 -> p2=s2h^2 -> t=a*s2h -> p3=t*s1h
    //=================================================================
    reg signed [15:0] s1h, s2h;
    reg signed [17:0] ma;
    reg signed [15:0] mb;
    reg signed [33:0] mul_p;
    reg signed [32:0] p1, p2;
    reg signed [17:0] tval;

    wire signed [33:0] power_w = {{1{p1[32]}}, p1} + {{1{p2[32]}}, p2} - mul_p;
    wire        [33:0] pabs    = power_w[33] ? 34'd0 : power_w;

    function [5:0] msb_of;
        input [33:0] v;
        integer i;
        begin
            msb_of = 6'd0;
            for (i = 0; i < 34; i = i + 1)
                if (v[i]) msb_of = i[5:0];
        end
    endfunction

    wire [5:0] pmsb  = msb_of(pabs);
    wire [5:0] psh6  = (pmsb > 6'd3) ? (pmsb - 6'd3) : 6'd0;
    wire [5:0] psh   = psh6[5:0];
    wire [33:0] pnorm = pabs >> psh;
    wire [2:0] pfine = pnorm[2:0];
    wire [7:0] mag_new = (pmsb > 6'd31) ? 8'hFF : {pmsb[4:0], pfine};

    //=================================================================
    // 流式峰值计数：只保留 7 个邻近幅度，避免 104x8 阵列和 104:1 多路器
    //=================================================================
    reg [5:0] peak_cnt0, peak_cnt1;
    reg        energy0, energy1;
    reg [7:0] mag_work;
    reg [5:0] ci_work;
    reg [2:0] hit_work;
    wire [5:0] ci = (bin < 7'd52) ? bin[5:0] : (bin - 7'd52);
    wire [7:0] v0 = (bin < 7'd52) ? mag_hist0[1] : mag_hist1[1];
    wire [7:0] v1 = (bin < 7'd52) ? mag_hist0[2] : mag_hist1[2];
    wire [7:0] v2 = (bin < 7'd52) ? mag_hist0[3] : mag_hist1[3];
    wire [7:0] v3 = (bin < 7'd52) ? mag_hist0[4] : mag_hist1[4];
    wire [7:0] v4 = (bin < 7'd52) ? mag_hist0[5] : mag_hist1[5];
    wire [7:0] v5 = (bin < 7'd52) ? mag_hist0[6] : mag_hist1[6];
    wire [7:0] v6 = mag_work;

    function peak_hit;
        input [7:0] mk, ml, mr, ml2, mr2, ml3, mr3;
        input edge_lo, edge_hi;
        reg [8:0] mk2;
        begin
            mk2 = {1'b0, mk} << 1;
            peak_hit = (mk >= 8'd32) &&
                       (edge_lo || (mk >  (ml + (ml >> 1)))) &&
                       (edge_hi || (mk >= (mr + (mr >> 1)))) &&
                       (mk2 >= {1'b0, ml2}) &&
                       (mk2 >= {1'b0, mr2}) &&
                       (mk >= ml3) && (mk >= mr3);
        end
    endfunction

    // 比较器与计数器分成两级，避免 p2 -> 峰值计数成为 50 MHz 长路径。
    wire normal_hit_work = (ci_work >= 6'd3) ?
        peak_hit(v3, v2, v4, v1, v5, v0, v6, (ci_work == 6'd3), 1'b0) : 1'b0;
    wire p49_work = peak_hit(v4, v3, v5, v2, v6, v1, v6, 1'b0, 1'b0);
    wire p50_work = peak_hit(v5, v4, v6, v3, v6, v2, v6, 1'b0, 1'b0);
    wire p51_work = peak_hit(v6, v5, v6, v4, v6, v3, v6, 1'b0, 1'b1);
    wire [2:0] extra_hit_work = (ci_work == 6'd51) ? ({2'b0,p49_work} + {2'b0,p50_work} + {2'b0,p51_work}) : 3'd0;
    wire [2:0] hit_total_work = normal_hit_work + extra_hit_work;
    wire [6:0] cnt0_plus = {1'b0, peak_cnt0} + {4'b0, hit_work};
    wire [6:0] cnt1_plus = {1'b0, peak_cnt1} + {4'b0, hit_work};
    wire [5:0] cnt0_sat = (cnt0_plus > 7'd63) ? 6'd63 : cnt0_plus[5:0];
    wire [5:0] cnt1_sat = (cnt1_plus > 7'd63) ? 6'd63 : cnt1_plus[5:0];

    //=================================================================
    // 主状态机
    //=================================================================
    localparam [2:0] M_ABSORB = 3'd0, M_MAG = 3'd1, M_RST = 3'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= M_RST; pair_sel <= 1'b0; bin <= 7'd0; ph <= 4'd0; scnt <= 13'd0;  // 上电先把 208x23 状态 RAM 和幅度寄存器清零
            st_we <= 1'b0; st_waddr <= 8'd0; st_wdata <= 23'sd0; st_raddr <= 8'd0;
            s1_q <= 23'sd0; s2_q <= 23'sd0; snew_q <= 23'sd0;
            coef_q <= 16'sd0; prod_q <= 39'sd0;
            x0 <= 8'sd0; x1 <= 8'sd0;
            hp_x0 <= 20'sd0; hp_x1 <= 20'sd0; hp_y0 <= 20'sd0; hp_y1 <= 20'sd0;
            ud_we <= 1'b0; ud_addr <= 7'd0; ud_data <= 8'd0;
            rst_i <= 8'd0;
            peak_cnt0 <= 6'd0; peak_cnt1 <= 6'd0; peak0_final <= 6'd0; peak1_final <= 6'd0;
            energy0 <= 1'b0; energy1 <= 1'b0;
            mag_work <= 8'd0; ci_work <= 6'd0; hit_work <= 3'd0;
            dbg_updates <= 32'd0;
            s1h <= 16'sd0; s2h <= 16'sd0; ma <= 18'sd0; mb <= 16'sd0;
            mul_p <= 34'sd0; p1 <= 33'sd0; p2 <= 33'sd0; tval <= 18'sd0;
        end else begin
            st_we <= 1'b0;
            ud_we <= 1'b0;

            case (mode)
            //---------------------------------------------------------
            // 吸收：每个采样点把 104 个谐振器各推进一次
            //---------------------------------------------------------
            M_ABSORB: begin
                case (ph)
                4'd0: if (sample_tick) begin
                          x0  <= xsat0;
                          x1  <= xsat1;
                          hp_x0 <= hx0;
                          hp_x1 <= hx1;
                          hp_y0 <= hy0;
                          hp_y1 <= hy1;
                          bin <= 7'd0;
                          st_raddr <= 8'd0;
                          ph  <= 4'd1;
                      end
                4'd1: begin st_raddr <= {1'b0, bin};             ph <= 4'd2; end
                4'd2: begin st_raddr <= 8'd104 + {1'b0, bin};    ph <= 4'd3; end
                4'd3: begin s1_q <= st_rdata;
                            coef_q <= coef_low_sel ? coef_low_of(coef_idx[5:0]) : coef_of(coef_idx[5:0]); ph <= 4'd4; end
                4'd4: begin s2_q <= st_rdata;
                            prod_q <= coef_q * s1_q;       ph <= 4'd5; end
                4'd5: begin snew_q <= snew_sat;            ph <= 4'd6; end
                4'd6: begin st_we <= 1'b1; st_waddr <= {1'b0, bin}; st_wdata <= snew_q;
                            ph <= 4'd7; end
                default: begin
                            st_we <= 1'b1; st_waddr <= 8'd104 + {1'b0, bin}; st_wdata <= s1_q;
                            if (bin == NB - 1) begin
                                bin <= 7'd0;
                                ph  <= 4'd0;
                                if (scnt == WINC - 1) begin
                                    scnt <= 13'd0;
                                    mode <= M_MAG;
                                end else begin
                                    scnt <= scnt + 13'd1;
                                end
                            end else begin
                                bin <= bin + 7'd1;
                                ph  <= 4'd1;
                            end
                        end
                endcase
            end

            //---------------------------------------------------------
            //---------------------------------------------------------
            // 幅度：11 拍/频点（3 个乘法 + 收尾）
            //---------------------------------------------------------
            M_MAG: begin
                case (ph)
                4'd0: begin st_raddr <= {1'b0, bin};          ph <= 4'd1; end
                4'd1: begin st_raddr <= 8'd104 + {1'b0, bin}; ph <= 4'd2; end
                4'd2: begin s1_q <= st_rdata;
                            coef_q <= coef_low_sel ? coef_low_of(coef_idx[5:0]) : coef_of(coef_idx[5:0]); ph <= 4'd3; end
                4'd3: begin s1h <= s1_q >>> 7;
                            s2_q <= st_rdata;                  ph <= 4'd4; end
                4'd4: begin s2h <= s2_q >>> 7;
                            ma <= s1h; mb <= s1h;              ph <= 4'd5; end
                4'd5: begin mul_p <= ma * mb;          // p1 = s1h^2
                            ma <= s2h; mb <= s2h;              ph <= 4'd6; end
                4'd6: begin p1 <= mul_p;
                            mul_p <= ma * mb;          // p2 = s2h^2
                            ma <= coef_q; mb <= s2h;           ph <= 4'd7; end
                4'd7: begin p2 <= mul_p;
                            mul_p <= ma * mb;          // t_raw = a*s2h
                                                               ph <= 4'd8; end
                4'd8: begin tval <= mul_p >>> 14;
                            ma <= mul_p >>> 14; mb <= s1h;     ph <= 4'd9; end
                4'd9: begin mul_p <= ma * mb;          // p3 = (a*s2h)*s1h
                                                               ph <= 4'd10; end
                4'd10: begin
                            ud_we   <= 1'b1;
                            ud_addr <= mag_base + {1'b0, bin[6:0]};
                            ud_data <= mag_new;
                            mag_work <= mag_new;
                            if (bin < 7'd52) begin if (mag_new > 8'd32) energy0 <= 1'b1; end
                            else begin if (mag_new > 8'd32) energy1 <= 1'b1; end
                            ci_work <= ci;
                            ph <= 4'd11;
                        end
                4'd11: begin hit_work <= hit_total_work; ph <= 4'd12; end
                default: begin
                            if (bin < 7'd52) begin
                                if (ci_work == 6'd0) begin
                                    for (hi=0; hi<7; hi=hi+1) mag_hist0[hi] <= mag_work;
                                end else begin
                                    for (hi=0; hi<6; hi=hi+1) mag_hist0[hi] <= mag_hist0[hi+1];
                                    mag_hist0[6] <= mag_work;
                                end
                                peak_cnt0 <= cnt0_sat;
                                if (bin == 7'd51) peak0_final <= (cnt0_sat == 6'd0 && energy0) ? 6'd1 : cnt0_sat;
                            end else begin
                                if (ci_work == 6'd0) begin
                                    for (hi=0; hi<7; hi=hi+1) mag_hist1[hi] <= mag_work;
                                end else begin
                                    for (hi=0; hi<6; hi=hi+1) mag_hist1[hi] <= mag_hist1[hi+1];
                                    mag_hist1[6] <= mag_work;
                                end
                                peak_cnt1 <= cnt1_sat;
                                if (bin == 7'd103) peak1_final <= (cnt1_sat == 6'd0 && energy1) ? 6'd1 : cnt1_sat;
                            end
                            if (bin == NB - 1) begin
                                dbg_updates <= dbg_updates + 32'd1;
                                bin <= 7'd0;
                                mode <= M_RST;
                                ph <= 4'd0;
                            end else begin
                                bin <= bin + 7'd1;
                                ph  <= 4'd0;
                            end
                        end
                endcase
            end


            //---------------------------------------------------------
            // 清状态 + 写频率个数 + 清幅度寄存器
            //---------------------------------------------------------
            M_RST: begin
                if (rst_i < 8'd208) begin
                    st_we    <= 1'b1;
                    st_waddr <= rst_i[7:0];
                    st_wdata <= 23'sd0;
                    rst_i    <= rst_i + 8'd1;
                end else if (rst_i == 8'd208) begin
                    ud_we   <= 1'b1;
                    ud_addr <= peak_base;
                    ud_data <= {2'b0, peak0_final};
                    rst_i   <= 8'd209;
                end else if (rst_i == 8'd209) begin
                    ud_we   <= 1'b1;
                    ud_addr <= peak_base + 8'd1;
                    ud_data <= {2'b0, peak1_final};
                    peak_cnt0 <= 6'd0;
                    peak_cnt1 <= 6'd0;
                    energy0 <= 1'b0; energy1 <= 1'b0;
                    pair_sel <= ~pair_sel;
                    mode  <= M_ABSORB;
                    bin   <= 7'd0;
                    ph    <= 4'd0;
                    scnt  <= 13'd0;
                    rst_i <= 8'd0;
                end else begin
                    rst_i <= 8'd0;
                end
            end

            default: mode <= M_ABSORB;
            endcase
        end
    end

endmodule
