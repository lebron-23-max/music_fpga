`timescale 1ns / 1ps
//=============================================================================
// audio_chorus.v —— 双声部合唱（短延迟 + LFO 调制 + 线性插值）
//=============================================================================
// 结构：
//   一块 2048 x 16bit 环形 BSRAM（42 ms @ 48.828 kHz）。
//   LFO：三角波（相位累加器高 8 位），0.8 Hz。
//   两个声部共用一条延迟线，延迟时间反相调制：
//       d0 = 15ms + 4ms*tri_0
//       d1 = 15ms + 4ms*tri_90（正交相位，避免两路反相平均抵消）
//   读出地址落在两个采样点之间，用线性插值消除"拉链噪声"。
//   输出 = 0.5 dry + 0.5 * (v0+v1)/2。
//   en=0 时组合旁路；上电用同一个写口清 2048 个单元。
//=============================================================================
module audio_chorus (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire signed [15:0] sample_in,
    input  wire               en,
    input  wire [7:0]         rate,
    input  wire [7:0]         depth,
    output wire signed [15:0] sample_out
);
    localparam integer DEPTH = 2048;
    localparam signed [18:0] BASE_Q8 = 19'sd187392;  // 732.0 samples = 15.0 ms

    function [31:0] lfo_inc_for;
        input [2:0] level;
        begin
            case (level)
                3'd0: lfo_inc_for = 32'd17592;   // 0.20 Hz
                3'd1: lfo_inc_for = 32'd35184;   // 0.40 Hz
                3'd2: lfo_inc_for = 32'd52777;   // 0.60 Hz
                3'd3: lfo_inc_for = 32'd70369;   // 0.80 Hz
                3'd4: lfo_inc_for = 32'd87961;   // 1.00 Hz
                3'd5: lfo_inc_for = 32'd131942;  // 1.50 Hz
                3'd6: lfo_inc_for = 32'd175922;  // 2.00 Hz
                default: lfo_inc_for = 32'd263883; // 3.00 Hz
            endcase
        end
    endfunction

    function signed [18:0] depth_mod;
        input signed [7:0] lfo;
        input [2:0] level;
        reg signed [18:0] base;
        begin
            base = {{11{lfo[7]}}, lfo} * 19'sd195; // +/-195 samples at full depth
            case (level)
                3'd0: depth_mod = 19'sd0;
                3'd1: depth_mod = base >>> 1;
                3'd2: depth_mod = base;
                3'd3: depth_mod = base + (base >>> 1);
                3'd4: depth_mod = base <<< 1;
                3'd5: depth_mod = (base <<< 1) + (base >>> 1);
                3'd6: depth_mod = base + (base <<< 1);
                default: depth_mod = base <<< 2;
            endcase
        end
    endfunction

    wire [31:0] lfo_inc_sel = lfo_inc_for(rate[7:5]);
    reg signed [15:0] mem [0:DEPTH-1];
    reg  [10:0]       ptr;
    reg  [10:0]       raddr;
    reg signed [15:0] rd;

    always @(posedge clk) rd <= mem[raddr];

    // 复位清零（复用同一个写口）
    reg [10:0] clr_cnt;
    reg        clr_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clr_cnt  <= 11'd0;
            clr_done <= 1'b0;
        end else if (!clr_done) begin
            if (clr_cnt == DEPTH - 1) clr_done <= 1'b1;
            else                      clr_cnt  <= clr_cnt + 11'd1;
        end
    end

    reg               we;
    reg  [10:0]       waddr;
    reg signed [15:0] wdata;
    always @(posedge clk) begin
        if (!clr_done) mem[clr_cnt] <= 16'sd0;
        else if (we)   mem[waddr]   <= wdata;
    end

    function signed [15:0] sat16;
        input signed [16:0] v;
        begin
            if      (v > 17'sd32767)  sat16 = 16'sd32767;
            else if (v < -17'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    //---------------- LFO + 延迟地址 ----------------
    reg  [31:0] ph;
    // 三角波 LFO：0° 与 90° 两路正交相位，避免两路反相平均互相抵消。
    wire [31:0] ph90 = ph + 32'h4000_0000;
    wire [6:0]  lfo_tri0 = ph[31]   ? ~ph[30:24]   : ph[30:24];
    wire [6:0]  lfo_tri1 = ph90[31] ? ~ph90[30:24] : ph90[30:24];
    wire signed [7:0] lfo0 = {1'b0, lfo_tri0} - 8'sd64;
    wire signed [7:0] lfo1 = {1'b0, lfo_tri1} - 8'sd64;
    wire signed [18:0] mod0_q8 = depth_mod(lfo0, depth[7:5]);
    wire signed [18:0] mod1_q8 = depth_mod(lfo1, depth[7:5]);
    wire signed [18:0] d0_q8 = BASE_Q8 + mod0_q8;
    wire signed [18:0] d1_q8 = BASE_Q8 + mod1_q8;
    wire [10:0] d0_int = d0_q8[18:8];
    wire [10:0] d1_int = d1_q8[18:8];
    wire [7:0]  frac0  = d0_q8[7:0];
    wire [7:0]  frac1  = d1_q8[7:0];
    reg  [7:0]  frac0_q, frac1_q;

    wire [10:0] addr0a = ptr - d0_int;
    wire [10:0] addr0b = addr0a - 11'd1;
    wire [10:0] addr1a = ptr - d1_int;
    wire [10:0] addr1b = addr1a - 11'd1;

    //---------------- 插值 ----------------
    reg signed [15:0] s0a, s1a, s0b, s1b;
    wire signed [16:0] diff0 = s1a - s0a;
    wire signed [16:0] diff1 = s1b - s0b;
    wire signed [24:0] prod0 = diff0 * $signed({1'b0, frac0_q});
    wire signed [24:0] prod1 = diff1 * $signed({1'b0, frac1_q});
    wire signed [16:0] interp0 = prod0 >>> 8;
    wire signed [16:0] interp1 = prod1 >>> 8;
    wire signed [16:0] y0 = s0a + interp0;
    wire signed [16:0] y1 = s0b + interp1;

    reg signed [15:0] dry;
    wire signed [16:0] wet17 = (y0 + y1) >>> 1;
    wire signed [17:0] dry18 = {{2{dry[15]}}, dry};
    wire signed [17:0] wet18 = {{1{wet17[16]}}, wet17};
    // 双声部平均值略低，补 1.5x 湿增益，保证加厚感可闻且不压过干声太多
    wire signed [17:0] wet_boost = wet18 + (wet18 >>> 1);
    wire signed [17:0] mixw  = (dry18 >>> 1) + (wet_boost >>> 1);

    //---------------- 状态机 ----------------
    reg [2:0] st;
    reg signed [15:0] out_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 3'd0; ptr <= 11'd0; ph <= 32'd0;
            raddr <= 11'd0; frac0_q <= 8'd0; frac1_q <= 8'd0; s0a <= 16'sd0; s1a <= 16'sd0; s0b <= 16'sd0; s1b <= 16'sd0;
            dry <= 16'sd0; out_r <= 16'sd0;
            we <= 1'b0; waddr <= 11'd0; wdata <= 16'sd0;
        end else begin
            we <= 1'b0;
            case (st)
            3'd0: if (sample_tick) begin
                      dry  <= sample_in;
                      ph   <= ph + lfo_inc_sel;
                      frac0_q <= frac0;
                      frac1_q <= frac1;
                      raddr <= addr0a;
                      st    <= 3'd1;
                  end
            3'd1: begin s0a <= rd; raddr <= addr0b; st <= 3'd2; end
            3'd2: begin s1a <= rd; raddr <= addr1a; st <= 3'd3; end
            3'd3: begin s0b <= rd; raddr <= addr1b; st <= 3'd4; end
            3'd4: begin s1b <= rd; st <= 3'd5; end
            3'd5: begin
                      out_r <= sat16(mixw);
                      we    <= 1'b1;
                      waddr <= ptr;
                      wdata <= sample_in;
                      st    <= 3'd6;
                  end
            default: begin
                      ptr <= (ptr == DEPTH - 1) ? 11'd0 : ptr + 11'd1;
                      st  <= 3'd0;
                  end
            endcase
        end
    end

    assign sample_out = en ? out_r : sample_in;

endmodule