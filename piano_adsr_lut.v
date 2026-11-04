`timescale 1ns / 1ps
//=============================================================================
// piano_adsr_lut.v —— 钢琴 ADSR 参数映射
//=============================================================================
// A/D/R tables are implemented as distributed lookup functions (small values:
// 9/7/6 bits). S/T retain full 16-bit precision in BSRAM. This avoids the
// vendor pROM limitation on a >18-bit packed word while preserving every table
// value bit-for-bit.
//=============================================================================
module piano_adsr_lut (
    input  wire       clk,
    input  wire [7:0] a,
    input  wire [7:0] d,
    input  wire [7:0] s,
    input  wire [7:0] r,
    output reg [15:0] va,
    output reg [15:0] vd,
    output reg [15:0] vs,
    output reg [15:0] vr,
    output reg [15:0] vt
);
`include "piano_adsr_lut_maps.vh"

    reg [15:0] adsr_s_lut [0:255] /* synthesis syn_romstyle = "logic" */;
    reg [15:0] adsr_t_lut [0:255] /* synthesis syn_romstyle = "logic" */;
    initial begin
`include "piano_adsr_lut_st.vh"
    end

    reg [2:0] rd_phase;
    initial begin
        rd_phase = 3'd0;
        va = 16'd0; vd = 16'd0; vs = 16'd0; vr = 16'd0; vt = 16'd0;
    end
    always @(posedge clk) begin
        case (rd_phase)
        3'd0: va <= {7'd0, adsr_a_map(a)};
        3'd1: vd <= {9'd0, adsr_d_map(d)};
        3'd2: vs <= adsr_s_lut[s];
        3'd3: vr <= {10'd0, adsr_r_map(r)};
        default: vt <= adsr_t_lut[d];
        endcase
        rd_phase <= (rd_phase == 3'd4) ? 3'd0 : (rd_phase + 3'd1);
    end
endmodule