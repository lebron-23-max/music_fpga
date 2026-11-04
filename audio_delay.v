`timescale 1ns / 1ps
//=============================================================================
// audio_delay.v — variable-time mono feedback delay
//
// time      : 0..255 maps to about 25 ms .. 249 ms
// feedback  : top three bits select 8 feedback levels (0.125 .. 0.875)
// dry/wet   : retained at 0.625 / 0.3125
// en=0      : bit-exact combinational bypass
//=============================================================================
module audio_delay #(
    parameter integer DELAY_SAMPLES = 12207
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire signed [15:0] sample_in,
    input  wire               en,
    input  wire [7:0]         delay_time,
    input  wire [7:0]         feedback,
    output wire signed [15:0] sample_out
);
    localparam integer AW = 14;

    reg signed [15:0] mem [0:DELAY_SAMPLES-1];
    reg  [AW-1:0]     ptr;
    reg  [AW-1:0]     raddr;
    reg signed [15:0] rd;

    always @(posedge clk) rd <= mem[raddr];

    reg [AW-1:0] clr_cnt;
    reg          clr_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clr_cnt  <= {AW{1'b0}};
            clr_done <= 1'b0;
        end else if (!clr_done) begin
            if (clr_cnt == DELAY_SAMPLES - 1) clr_done <= 1'b1;
            else                              clr_cnt  <= clr_cnt + 1'b1;
        end
    end

    reg               we;
    reg  [AW-1:0]     waddr;
    reg signed [15:0] wdata;
    always @(posedge clk) begin
        if (!clr_done) mem[clr_cnt] <= 16'sd0;
        else if (we)   mem[waddr]   <= wdata;
    end

    function signed [15:0] sat16;
        input signed [17:0] v;
        begin
            if      (v > 18'sd32767)  sat16 = 16'sd32767;
            else if (v < -18'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    function signed [17:0] fb_gain;
        input signed [17:0] x;
        input [2:0] level;
        begin
            case (level)
                3'd0: fb_gain = (x >>> 3);                       // 0.125
                3'd1: fb_gain = (x >>> 2);                       // 0.250
                3'd2: fb_gain = (x >>> 2) + (x >>> 3) + (x >>> 4); // 0.4375
                3'd3: fb_gain = (x >>> 1);                       // 0.500
                3'd4: fb_gain = (x >>> 1) + (x >>> 3);           // 0.625
                3'd5: fb_gain = (x >>> 1) + (x >>> 2);           // 0.750
                3'd6: fb_gain = (x >>> 1) + (x >>> 2) + (x >>> 4); // 0.8125
                default: fb_gain = x - (x >>> 3);                // 0.875
            endcase
        end
    endfunction

    // 43 * delay_time + 1220 samples, i.e. roughly 25 ms .. 249 ms.
    wire [14:0] t_x32     = {10'd0, delay_time} << 5;
    wire [14:0] t_x8      = {10'd0, delay_time} << 3;
    wire [14:0] t_x2      = {10'd0, delay_time} << 1;
    wire [14:0] t_x1      = {7'd0, delay_time} >> 1;
    wire [14:0] time_span = t_x32 + t_x8 + t_x2 + t_x1;
    wire [14:0] dlen15    = 15'd1220 + time_span;
    wire [14:0] read_diff = {1'b0, ptr} + 15'd12207 - dlen15;
    wire [14:0] read_wrap = (read_diff >= 15'd12207) ? (read_diff - 15'd12207) : read_diff;

    reg signed [15:0] dry;
    wire signed [17:0] rd18  = {{2{rd[15]}}, rd};
    wire signed [17:0] dry18 = {{2{dry[15]}}, dry};
    wire signed [17:0] wet18 = (rd18 >>> 2) + (rd18 >>> 4);
    wire signed [17:0] dryw  = (dry18 >>> 1) + (dry18 >>> 3);
    wire signed [17:0] mixw  = dryw + wet18;
    wire signed [17:0] fbw   = dry18 + fb_gain(rd18, feedback[7:5]);

    reg [1:0] st;
    reg signed [15:0] out_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 2'd0; ptr <= {AW{1'b0}}; raddr <= {AW{1'b0}}; dry <= 16'sd0;
            we <= 1'b0; waddr <= {AW{1'b0}}; wdata <= 16'sd0; out_r <= 16'sd0;
        end else begin
            we <= 1'b0;
            case (st)
            2'd0: if (sample_tick) begin
                      dry   <= sample_in;
                      raddr <= read_wrap[AW-1:0];
                      st    <= 2'd1;
                  end
            2'd1: begin
                      we    <= 1'b1;
                      waddr <= ptr;
                      wdata <= sat16(fbw);
                      out_r <= sat16(mixw);
                      st    <= 2'd2;
                  end
            default: begin
                      ptr <= (ptr == DELAY_SAMPLES - 1) ? {AW{1'b0}} : ptr + 1'b1;
                      st  <= 2'd0;
                  end
            endcase
        end
    end

    assign sample_out = en ? out_r : sample_in;
endmodule