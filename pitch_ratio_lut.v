`timescale 1ns / 1ps
//=============================================================================
// pitch_ratio_lut.v —— ±24 个 50-cent 步进的精确相位增量比（Q15）
//   ratio_q15 = round(2^(cents/1200) * 32768)，0 cents = 32768。
//   step=-24 → -1200 cents；step=+24 → +1200 cents。
//=============================================================================
module pitch_ratio_lut (
    input  wire signed [5:0]  step_index,
    output reg  [16:0]        ratio_q15
);
    always @(*) begin
        case (step_index)
            -6'sd24: ratio_q15 = 17'd16384;
            -6'sd23: ratio_q15 = 17'd16864;
            -6'sd22: ratio_q15 = 17'd17358;
            -6'sd21: ratio_q15 = 17'd17867;
            -6'sd20: ratio_q15 = 17'd18390;
            -6'sd19: ratio_q15 = 17'd18929;
            -6'sd18: ratio_q15 = 17'd19484;
            -6'sd17: ratio_q15 = 17'd20055;
            -6'sd16: ratio_q15 = 17'd20643;
            -6'sd15: ratio_q15 = 17'd21247;
            -6'sd14: ratio_q15 = 17'd21870;
            -6'sd13: ratio_q15 = 17'd22511;
            -6'sd12: ratio_q15 = 17'd23170;
            -6'sd11: ratio_q15 = 17'd23849;
            -6'sd10: ratio_q15 = 17'd24548;
            -6'sd9: ratio_q15 = 17'd25268;
            -6'sd8: ratio_q15 = 17'd26008;
            -6'sd7: ratio_q15 = 17'd26770;
            -6'sd6: ratio_q15 = 17'd27554;
            -6'sd5: ratio_q15 = 17'd28362;
            -6'sd4: ratio_q15 = 17'd29193;
            -6'sd3: ratio_q15 = 17'd30048;
            -6'sd2: ratio_q15 = 17'd30929;
            -6'sd1: ratio_q15 = 17'd31835;
            6'sd0: ratio_q15 = 17'd32768;
            6'sd1: ratio_q15 = 17'd33728;
            6'sd2: ratio_q15 = 17'd34716;
            6'sd3: ratio_q15 = 17'd35734;
            6'sd4: ratio_q15 = 17'd36781;
            6'sd5: ratio_q15 = 17'd37859;
            6'sd6: ratio_q15 = 17'd38968;
            6'sd7: ratio_q15 = 17'd40110;
            6'sd8: ratio_q15 = 17'd41285;
            6'sd9: ratio_q15 = 17'd42495;
            6'sd10: ratio_q15 = 17'd43740;
            6'sd11: ratio_q15 = 17'd45022;
            6'sd12: ratio_q15 = 17'd46341;
            6'sd13: ratio_q15 = 17'd47699;
            6'sd14: ratio_q15 = 17'd49097;
            6'sd15: ratio_q15 = 17'd50535;
            6'sd16: ratio_q15 = 17'd52016;
            6'sd17: ratio_q15 = 17'd53540;
            6'sd18: ratio_q15 = 17'd55109;
            6'sd19: ratio_q15 = 17'd56724;
            6'sd20: ratio_q15 = 17'd58386;
            6'sd21: ratio_q15 = 17'd60097;
            6'sd22: ratio_q15 = 17'd61858;
            6'sd23: ratio_q15 = 17'd63670;
            6'sd24: ratio_q15 = 17'd65536;
            default: ratio_q15 = 17'd32768;
        endcase
    end
endmodule
