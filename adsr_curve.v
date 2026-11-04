`timescale 1ns / 1ps
//=============================================================================
// adsr_curve.v —— 当前 ADSR 参数的包络曲线表（显示用，寄存器实现）
//=============================================================================
// 每场消隐期重算 220 列曲线，表项 = 该列包络高度 0..190。
// A：0→峰值；D：峰值→S；固定平台保持 S；R：S→0；释放结束后全为 0。
// 段宽取 2 的幂（8/16/32/64），每列只需累加与移位。
//=============================================================================
module adsr_curve (
    input  wire       clk,        // pix_clk
    input  wire       rst_n,
    input  wire       start,      // 每场一次（消隐期）启动重算
    input  wire [7:0] a, d, s, r,

    input  wire [7:0] raddr,      // 渲染器读地址 0..219
    output reg  [7:0] rdata,
    output reg  [8:0] seg_end     // 曲线实际长度（列数）
);
    localparam integer TBL_LEN = 220;
    localparam [7:0]   PEAK    = 8'd190;
    localparam [8:0]   WS      = 9'd24;

    reg [7:0] mem [0:255] /* synthesis syn_ramstyle = "registers" */;
    always @(posedge clk) rdata <= mem[raddr];

    reg        we;
    reg [7:0]  waddr;
    reg [7:0]  wdata;
    always @(posedge clk) if (we) mem[waddr] <= wdata;

    //---------------- 段参数 ----------------
    reg [1:0] log_a, log_d, log_r;
    reg [7:0] sus;
    reg [8:0] end_a, end_d, end_s, end_r;

    wire [8:0] wa9 = {1'b0, 8'd8} << (a >> 6);
    wire [8:0] wd9 = {1'b0, 8'd8} << ((8'd255 - d) >> 6);
    wire [8:0] wr9 = {1'b0, 8'd8} << (r >> 6);

    //---------------- 状态机 ----------------
    reg        busy;
    reg [8:0]  x;
    reg [7:0]  lvl;
    reg [15:0] frac;

    wire [8:0]  x_n     = x + 9'd1;
    wire        bnd_n   = (x_n == end_a) || (x_n == end_d) ||
                          (x_n == end_s) || (x_n == end_r);
    wire [7:0]  delta_n = (x_n < end_a) ? PEAK :
                          (x_n < end_d) ? (PEAK - sus) :
                          (x_n < end_s) ? 8'd0 : sus;
    wire [2:0]  sh_n    = ((x_n < end_a) ? log_a :
                           (x_n < end_d) ? log_d : log_r) + 2'd3;
    wire [15:0] frac_n  = bnd_n ? 16'd0 : (frac + {8'b0, delta_n});
    // Keep the computed step wider than 8 bits.  In the old code the
    // release/decay step wrapped after 255 and made the graph jump back up
    // (the saw-tooth shown on the R segment).
    wire [15:0] step_n  = frac_n >> sh_n;
    wire [15:0] step_lim = (step_n > {8'd0, PEAK}) ? {8'd0, PEAK} : step_n;
    wire [8:0]  lvl_n9  = (x_n >= end_r) ? 9'd0 :
                          (x_n < end_a) ? step_lim :
                          (x_n < end_d) ? ({1'b0, PEAK} - step_lim) :
                          (x_n < end_s) ? {1'b0, sus} :
                          (({1'b0, sus} >= step_lim) ? ({1'b0, sus} - step_lim) : 9'd0);
    wire [7:0]  lvl_n   = lvl_n9[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; x <= 9'd0; lvl <= 8'd0; frac <= 16'd0;
            we <= 1'b0; waddr <= 8'd0; wdata <= 8'd0;
            log_a <= 2'd0; log_d <= 2'd0; log_r <= 2'd0; sus <= 8'd0;
            end_a <= 9'd8; end_d <= 9'd72; end_s <= 9'd96; end_r <= 9'd160;
            seg_end <= 9'd160;
        end else begin
            we <= 1'b0;
            if (!busy) begin
                if (start) begin
                    busy    <= 1'b1;
                    log_a   <= a >> 6;
                    log_d   <= (8'd255 - d) >> 6;
                    log_r   <= r >> 6;
                    sus     <= (s > PEAK) ? PEAK : s;
                    end_a   <= wa9;
                    end_d   <= wa9 + wd9;
                    end_s   <= wa9 + wd9 + WS;
                    end_r   <= wa9 + wd9 + WS + wr9;
                    seg_end <= wa9 + wd9 + WS + wr9;
                    x       <= 9'd0;
                    lvl     <= 8'd0;
                    frac    <= 16'd0;
                end
            end else begin
                we    <= 1'b1;
                waddr <= x[7:0];
                wdata <= lvl;

                if (x == TBL_LEN - 1) begin
                    busy <= 1'b0;
                end else begin
                    x    <= x_n;
                    frac <= frac_n;
                    lvl  <= lvl_n;
                end
            end
        end
    end
endmodule