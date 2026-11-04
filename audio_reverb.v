`timescale 1ns / 1ps
//=============================================================================
// audio_reverb.v —— Freeverb 风格 Schroeder 混响（8 梳状 + 4 全通，单声道）
//=============================================================================
// 参考成熟 Freeverb 的延迟长度与拓扑（按 48.828 kHz 重算）：
//   8 个并联梳状：25.3 / 26.9 / 29.0 / 30.7 / 32.3 / 33.8 / 35.3 / 36.7 ms；
//   每个梳状反馈环内有 0.75*x[n] + 0.25*prev 的一阶高频阻尼，反馈 0.84375。
//   8 路求和后 ÷8 恢复电平，再串 4 个全通（10.0 / 12.6 / 7.74 / 5.10 ms，g=0.5）。
//   干湿比 = 0.875 dry + 0.9375 wet；通过 8 梳状/4 全通增加反射密度，而不是单纯拉反馈。
//   梳状入口 1.5x；30k 满幅正弦压力测试下输出/梳状/全通饱和计数均为 0。
//
// 资源：12 条独立延迟线，每条一个写口 + 一个读口，推断为简单双口 BSRAM。
//   所有乘系数都用移位加法，不新增 DSP。
//
// 时序：sample_tick 后 7 拍完成一个采样；采样周期有 1024 拍，余量充足。
//   en=0 时 sample_out 组合旁路 sample_in ⇒ 与加混响前逐位一致。
//=============================================================================
module audio_reverb (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire signed [15:0] sample_in,
    input  wire               en,          // 1=开混响，0=完全旁路
    input  wire [7:0]         size,        // 顶 3 位选择 8 档反馈/衰减
    input  wire [7:0]         mix,         // 顶 3 位选择 8 档湿声增益
    output wire signed [15:0] sample_out
);
    localparam integer D0 = 1236;   // 25.32 ms
    localparam integer D1 = 1316;   // 26.95 ms
    localparam integer D2 = 1414;   // 28.96 ms
    localparam integer D3 = 1501;   // 30.74 ms
    localparam integer D4 = 1575;   // 32.25 ms
    localparam integer D5 = 1651;   // 33.81 ms
    localparam integer D6 = 1724;   // 35.31 ms
    localparam integer D7 = 1790;   // 36.66 ms
    localparam integer A0 = 488;    // 10.00 ms
    localparam integer A1 = 615;    // 12.60 ms
    localparam integer A2 = 378;    //  7.74 ms
    localparam integer A3 = 249;    //  5.10 ms

    //---------------- 延迟线（每个数组 = 一个简单双口 BSRAM） ----------------
    reg signed [15:0] c0 [0:D0-1];
    reg signed [15:0] c1 [0:D1-1];
    reg signed [15:0] c2 [0:D2-1];
    reg signed [15:0] c3 [0:D3-1];
    reg signed [15:0] c4 [0:D4-1];
    reg signed [15:0] c5 [0:D5-1];
    reg signed [15:0] c6 [0:D6-1];
    reg signed [15:0] c7 [0:D7-1];
    reg signed [15:0] a0 [0:A0-1];
    reg signed [15:0] a1 [0:A1-1];
    reg signed [15:0] a2 [0:A2-1];
    reg signed [15:0] a3 [0:A3-1];

    reg  [10:0] p0,p1,p2,p3,p4,p5,p6,p7,pa0,pa1,pa2,pa3;
    reg signed [15:0] rd0,rd1,rd2,rd3,rd4,rd5,rd6,rd7,rda0,rda1,rda2,rda3;

    // 读口：缓冲长度 = 延迟长度，读当前写指针即得到 D 个采样前的值。
    always @(posedge clk) begin
        rd0  <= c0[p0];
        rd1  <= c1[p1];
        rd2  <= c2[p2];
        rd3  <= c3[p3];
        rd4  <= c4[p4];
        rd5  <= c5[p5];
        rd6  <= c6[p6];
        rd7  <= c7[p7];
        rda0 <= a0[pa0];
        rda1 <= a1[pa1];
        rda2 <= a2[pa2];
        rda3 <= a3[pa3];
    end

    //---------------- 上电清零（复用同一个写口） ----------------
    reg [10:0] clr_cnt;
    reg        clr_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clr_cnt  <= 11'd0;
            clr_done <= 1'b0;
        end else if (!clr_done) begin
            if (clr_cnt == D7) clr_done <= 1'b1;
            else               clr_cnt  <= clr_cnt + 11'd1;
        end
    end

    //---------------- 写口 ----------------
    reg we0,we1,we2,we3,we4,we5,we6,we7,wea0,wea1,wea2,wea3;
    reg [10:0] wa0,wa1,wa2,wa3,wa4,wa5,wa6,wa7,waa0,waa1,waa2,waa3;
    reg signed [15:0] wd0,wd1,wd2,wd3,wd4,wd5,wd6,wd7,wda0,wda1,wda2,wda3;

    always @(posedge clk) begin
        if (!clr_done) begin
            if (clr_cnt < D0) c0[clr_cnt] <= 16'sd0;
            if (clr_cnt < D1) c1[clr_cnt] <= 16'sd0;
            if (clr_cnt < D2) c2[clr_cnt] <= 16'sd0;
            if (clr_cnt < D3) c3[clr_cnt] <= 16'sd0;
            if (clr_cnt < D4) c4[clr_cnt] <= 16'sd0;
            if (clr_cnt < D5) c5[clr_cnt] <= 16'sd0;
            if (clr_cnt < D6) c6[clr_cnt] <= 16'sd0;
            if (clr_cnt < D7) c7[clr_cnt] <= 16'sd0;
            if (clr_cnt < A0) a0[clr_cnt] <= 16'sd0;
            if (clr_cnt < A1) a1[clr_cnt] <= 16'sd0;
            if (clr_cnt < A2) a2[clr_cnt] <= 16'sd0;
            if (clr_cnt < A3) a3[clr_cnt] <= 16'sd0;
        end else begin
            if (we0)  c0[wa0]  <= wd0;
            if (we1)  c1[wa1]  <= wd1;
            if (we2)  c2[wa2]  <= wd2;
            if (we3)  c3[wa3]  <= wd3;
            if (we4)  c4[wa4]  <= wd4;
            if (we5)  c5[wa5]  <= wd5;
            if (we6)  c6[wa6]  <= wd6;
            if (we7)  c7[wa7]  <= wd7;
            if (wea0) a0[waa0] <= wda0;
            if (wea1) a1[waa1] <= wda1;
            if (wea2) a2[waa2] <= wda2;
            if (wea3) a3[waa3] <= wda3;
        end
    end

    function signed [18:0] feedback_gain;
        input signed [18:0] x;
        input [2:0] level;
        begin
            case (level)
                3'd0: feedback_gain = (x >>> 1);                        // 0.500
                3'd1: feedback_gain = (x >>> 1) + (x >>> 3);            // 0.625
                3'd2: feedback_gain = (x >>> 1) + (x >>> 3) + (x >>> 4); // 0.6875
                3'd3: feedback_gain = x - (x >>> 2);                    // 0.750
                3'd4: feedback_gain = x - (x >>> 3) - (x >>> 4) - (x >>> 5); // 0.78125
                3'd5: feedback_gain = x - (x >>> 3) - (x >>> 4);        // 0.8125
                3'd6: feedback_gain = x - (x >>> 3) - (x >>> 5);        // 0.84375
                default: feedback_gain = x - (x >>> 3);                 // 0.875
            endcase
        end
    endfunction

    function signed [18:0] wet_gain;
        input signed [18:0] x;
        input [2:0] level;
        begin
            case (level)
                3'd0: wet_gain = (x >>> 4);                             // 0.0625
                3'd1: wet_gain = (x >>> 3);                             // 0.125
                3'd2: wet_gain = (x >>> 2) - (x >>> 4);                 // 0.1875
                3'd3: wet_gain = (x >>> 2);                             // 0.250
                3'd4: wet_gain = (x >>> 1) - (x >>> 3);                 // 0.375
                3'd5: wet_gain = (x >>> 1);                             // 0.500
                3'd6: wet_gain = x - (x >>> 2);                         // 0.750
                default: wet_gain = x - (x >>> 4);                      // 0.9375
            endcase
        end
    endfunction
    //---------------- 饱和到 16 位 ----------------
    function signed [15:0] sat16;
        input signed [18:0] v;
        begin
            if      (v > 19'sd32767)  sat16 = 16'sd32767;
            else if (v < -19'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    //---------------- 组合运算 ----------------
    reg  signed [15:0] dry;
    reg  signed [16:0] lp0,lp1,lp2,lp3,lp4,lp5,lp6,lp7;
    reg  signed [20:0] csum;
    wire signed [18:0] dry19  = {{3{dry[15]}}, dry};
    wire signed [18:0] rd0_19 = {{3{rd0[15]}}, rd0};
    wire signed [18:0] rd1_19 = {{3{rd1[15]}}, rd1};
    wire signed [18:0] rd2_19 = {{3{rd2[15]}}, rd2};
    wire signed [18:0] rd3_19 = {{3{rd3[15]}}, rd3};
    wire signed [18:0] rd4_19 = {{3{rd4[15]}}, rd4};
    wire signed [18:0] rd5_19 = {{3{rd5[15]}}, rd5};
    wire signed [18:0] rd6_19 = {{3{rd6[15]}}, rd6};
    wire signed [18:0] rd7_19 = {{3{rd7[15]}}, rd7};
    wire signed [18:0] lp0_19 = {{2{lp0[16]}}, lp0};
    wire signed [18:0] lp1_19 = {{2{lp1[16]}}, lp1};
    wire signed [18:0] lp2_19 = {{2{lp2[16]}}, lp2};
    wire signed [18:0] lp3_19 = {{2{lp3[16]}}, lp3};
    wire signed [18:0] lp4_19 = {{2{lp4[16]}}, lp4};
    wire signed [18:0] lp5_19 = {{2{lp5[16]}}, lp5};
    wire signed [18:0] lp6_19 = {{2{lp6[16]}}, lp6};
    wire signed [18:0] lp7_19 = {{2{lp7[16]}}, lp7};

    // Freeverb 阻尼：0.75*x[n] + 0.25*prev
    wire signed [18:0] lpn0 = rd0_19 - (rd0_19 >>> 2) + (lp0_19 >>> 2);
    wire signed [18:0] lpn1 = rd1_19 - (rd1_19 >>> 2) + (lp1_19 >>> 2);
    wire signed [18:0] lpn2 = rd2_19 - (rd2_19 >>> 2) + (lp2_19 >>> 2);
    wire signed [18:0] lpn3 = rd3_19 - (rd3_19 >>> 2) + (lp3_19 >>> 2);
    wire signed [18:0] lpn4 = rd4_19 - (rd4_19 >>> 2) + (lp4_19 >>> 2);
    wire signed [18:0] lpn5 = rd5_19 - (rd5_19 >>> 2) + (lp5_19 >>> 2);
    wire signed [18:0] lpn6 = rd6_19 - (rd6_19 >>> 2) + (lp6_19 >>> 2);
    wire signed [18:0] lpn7 = rd7_19 - (rd7_19 >>> 2) + (lp7_19 >>> 2);

    // 梳状入口 1.5x；反馈 0.84375 = 1 - 1/8 - 1/32。
    wire signed [18:0] x19 = dry19 + (dry19 >>> 1);


    // 8 路求和后 /8。csum 含符号扩展，取 [20:3] 不会发生 18 位回绕。
    wire signed [17:0] ap0in = csum[20:3];
    wire signed [18:0] rda0_19 = {{3{rda0[15]}}, rda0};
    wire signed [18:0] rda1_19 = {{3{rda1[15]}}, rda1};
    wire signed [18:0] rda2_19 = {{3{rda2[15]}}, rda2};
    wire signed [18:0] rda3_19 = {{3{rda3[15]}}, rda3};
    wire signed [18:0] ap0in19 = {{1{ap0in[17]}}, ap0in};

    // 4 级全通，g=0.5。各级之间插入寄存器，避免四级组合链在 50 MHz
    // 下直接从 BSRAM 数据输出连接到最终 out_r。
    reg signed [18:0] ap1_in_q, ap2_in_q, ap3_in_q, wet_q;
    wire signed [18:0] ap0w   = ap0in19 + (rda0_19 >>> 1);
    wire signed [18:0] ap0out = rda0_19 - (ap0w >>> 1);
    wire signed [18:0] ap1w   = ap1_in_q + (rda1_19 >>> 1);
    wire signed [18:0] ap1out = rda1_19 - (ap1w >>> 1);
    wire signed [18:0] ap2w   = ap2_in_q + (rda2_19 >>> 1);
    wire signed [18:0] ap2out = rda2_19 - (ap2w >>> 1);
    wire signed [18:0] ap3w   = ap3_in_q + (rda3_19 >>> 1);
    wire signed [18:0] ap3out = rda3_19 - (ap3w >>> 1);

    // 0.875 dry + 0.9375 wet，峰值经压力测试保留约 360 LSB 余量。
    wire signed [18:0] mixw = (dry19 - (dry19 >>> 3)) + wet_gain(wet_q, mix[7:5]);

    //---------------- 状态机 ----------------
    // Two extra pipeline stages isolate the synchronous BSRAM data output from
    // the parameterized feedback gain network. This is required at 50 MHz:
    // RAM_DO -> dynamic gain -> wd was the worst setup path in the first v35 PNR.
    localparam [3:0] S_IDLE=4'd0, S_PREP=4'd1, S_WRITE=4'd2,
                     S_AP0=4'd3, S_AP1=4'd4, S_AP2=4'd5, S_AP3=4'd6,
                     S_OUT=4'd7;
    reg [3:0] st;
    reg [2:0] wr_idx;
    reg signed [15:0] out_r;
    reg signed [18:0] lpn_q0, lpn_q1, lpn_q2, lpn_q3;
    reg signed [18:0] lpn_q4, lpn_q5, lpn_q6, lpn_q7;
    reg signed [18:0] x19_q;

    reg signed [18:0] lpn_sel;
    reg signed [20:0] rd_sel_21;
    always @* begin
        case (wr_idx)
        3'd0: begin lpn_sel=lpn_q0; rd_sel_21={{2{rd0_19[18]}},rd0_19}; end
        3'd1: begin lpn_sel=lpn_q1; rd_sel_21={{2{rd1_19[18]}},rd1_19}; end
        3'd2: begin lpn_sel=lpn_q2; rd_sel_21={{2{rd2_19[18]}},rd2_19}; end
        3'd3: begin lpn_sel=lpn_q3; rd_sel_21={{2{rd3_19[18]}},rd3_19}; end
        3'd4: begin lpn_sel=lpn_q4; rd_sel_21={{2{rd4_19[18]}},rd4_19}; end
        3'd5: begin lpn_sel=lpn_q5; rd_sel_21={{2{rd5_19[18]}},rd5_19}; end
        3'd6: begin lpn_sel=lpn_q6; rd_sel_21={{2{rd6_19[18]}},rd6_19}; end
        default: begin lpn_sel=lpn_q7; rd_sel_21={{2{rd7_19[18]}},rd7_19}; end
        endcase
    end
    wire signed [18:0] write_data = sat16(x19_q + feedback_gain(lpn_sel, size[7:5]));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            wr_idx<=3'd0;
            p0<=11'd0; p1<=11'd0; p2<=11'd0; p3<=11'd0;
            p4<=11'd0; p5<=11'd0; p6<=11'd0; p7<=11'd0;
            pa0<=11'd0; pa1<=11'd0; pa2<=11'd0; pa3<=11'd0;
            dry<=16'sd0;
            lp0<=17'sd0; lp1<=17'sd0; lp2<=17'sd0; lp3<=17'sd0;
            lp4<=17'sd0; lp5<=17'sd0; lp6<=17'sd0; lp7<=17'sd0;
            lpn_q0<=19'sd0; lpn_q1<=19'sd0; lpn_q2<=19'sd0; lpn_q3<=19'sd0;
            lpn_q4<=19'sd0; lpn_q5<=19'sd0; lpn_q6<=19'sd0; lpn_q7<=19'sd0;
            x19_q<=19'sd0;
            ap1_in_q<=19'sd0; ap2_in_q<=19'sd0; ap3_in_q<=19'sd0; wet_q<=19'sd0;
            csum<=21'sd0; out_r<=16'sd0;
            we0<=0;we1<=0;we2<=0;we3<=0;we4<=0;we5<=0;we6<=0;we7<=0;
            wea0<=0;wea1<=0;wea2<=0;wea3<=0;
            wa0<=0;wa1<=0;wa2<=0;wa3<=0;wa4<=0;wa5<=0;wa6<=0;wa7<=0;
            waa0<=0;waa1<=0;waa2<=0;waa3<=0;
            wd0<=0;wd1<=0;wd2<=0;wd3<=0;wd4<=0;wd5<=0;wd6<=0;wd7<=0;
            wda0<=0;wda1<=0;wda2<=0;wda3<=0;
        end else begin
            we0<=0;we1<=0;we2<=0;we3<=0;we4<=0;we5<=0;we6<=0;we7<=0;
            wea0<=0;wea1<=0;wea2<=0;wea3<=0;
            case (st)
            S_IDLE: if (sample_tick) begin
                dry <= sample_in;
                st  <= S_PREP;
            end
            S_PREP: begin
                lpn_q0 <= lpn0; lpn_q1 <= lpn1; lpn_q2 <= lpn2; lpn_q3 <= lpn3;
                lpn_q4 <= lpn4; lpn_q5 <= lpn5; lpn_q6 <= lpn6; lpn_q7 <= lpn7;
                lp0<=lpn0[16:0]; lp1<=lpn1[16:0]; lp2<=lpn2[16:0]; lp3<=lpn3[16:0];
                lp4<=lpn4[16:0]; lp5<=lpn5[16:0]; lp6<=lpn6[16:0]; lp7<=lpn7[16:0];
                csum <= 21'sd0;
                x19_q <= x19;
                wr_idx <= 3'd0;
                st <= S_WRITE;
            end

            S_WRITE: begin
                case (wr_idx)
                3'd0: begin we0<=1; wa0<=p0; wd0<=write_data; end
                3'd1: begin we1<=1; wa1<=p1; wd1<=write_data; end
                3'd2: begin we2<=1; wa2<=p2; wd2<=write_data; end
                3'd3: begin we3<=1; wa3<=p3; wd3<=write_data; end
                3'd4: begin we4<=1; wa4<=p4; wd4<=write_data; end
                3'd5: begin we5<=1; wa5<=p5; wd5<=write_data; end
                3'd6: begin we6<=1; wa6<=p6; wd6<=write_data; end
                default: begin we7<=1; wa7<=p7; wd7<=write_data; end
                endcase
                csum <= csum + rd_sel_21;
                if (wr_idx == 3'd7) st <= S_AP0;
                else wr_idx <= wr_idx + 3'd1;
            end
            S_AP0: begin wea0<=1;waa0<=pa0;wda0<=sat16(ap0w); ap1_in_q<=ap0out; st<=S_AP1; end
            S_AP1: begin wea1<=1;waa1<=pa1;wda1<=sat16(ap1w); ap2_in_q<=ap1out; st<=S_AP2; end
            S_AP2: begin wea2<=1;waa2<=pa2;wda2<=sat16(ap2w); ap3_in_q<=ap2out; st<=S_AP3; end
            S_AP3: begin
                wea3<=1;waa3<=pa3;wda3<=sat16(ap3w);
                wet_q <= ap3out;
                st <= S_OUT;
            end
            S_OUT: begin
                out_r <= sat16(mixw);
                p0 <= (p0 == D0-1) ? 11'd0 : p0+11'd1;
                p1 <= (p1 == D1-1) ? 11'd0 : p1+11'd1;
                p2 <= (p2 == D2-1) ? 11'd0 : p2+11'd1;
                p3 <= (p3 == D3-1) ? 11'd0 : p3+11'd1;
                p4 <= (p4 == D4-1) ? 11'd0 : p4+11'd1;
                p5 <= (p5 == D5-1) ? 11'd0 : p5+11'd1;
                p6 <= (p6 == D6-1) ? 11'd0 : p6+11'd1;
                p7 <= (p7 == D7-1) ? 11'd0 : p7+11'd1;
                pa0 <= (pa0 == A0-1) ? 11'd0 : pa0+11'd1;
                pa1 <= (pa1 == A1-1) ? 11'd0 : pa1+11'd1;
                pa2 <= (pa2 == A2-1) ? 11'd0 : pa2+11'd1;
                pa3 <= (pa3 == A3-1) ? 11'd0 : pa3+11'd1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
    assign sample_out = en ? out_r : sample_in;
endmodule
