`timescale 1ns / 1ps
//=============================================================================
// enc_detent.v — EC11 quadrature decoder with one pulse per mechanical detent
//
// EC11 normally produces four legal quadrature transitions per detent. This
// module validates only legal Gray-code transitions and emits a single-clock
// up/down pulse after each complete detent, independent of the control layer.
//=============================================================================
module enc_detent (
    input  wire clk,
    input  wire rst_n,
    input  wire enc_a,
    input  wire enc_b,
    output reg  detent_up,
    output reg  detent_down
);
    reg a1, a2, b1, b2;
    reg [1:0] prev;
    reg [1:0] phase;

    wire [1:0] state_now = {a2, b2};
    wire [3:0] trans = {prev, state_now};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a1 <= 1'b1; a2 <= 1'b1; b1 <= 1'b1; b2 <= 1'b1;
            prev <= 2'b11; phase <= 2'd0;
            detent_up <= 1'b0; detent_down <= 1'b0;
        end else begin
            a1 <= enc_a; a2 <= a1;
            b1 <= enc_b; b2 <= b1;
            detent_up   <= 1'b0;
            detent_down <= 1'b0;

            if (state_now != prev) begin
                case (trans)
                    4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: begin
                        if (phase == 2'd3) begin
                            phase <= 2'd0;
                            detent_up <= 1'b1;
                        end else begin
                            phase <= phase + 2'd1;
                        end
                    end
                    4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: begin
                        if (phase == 2'd0) begin
                            phase <= 2'd3;
                            detent_down <= 1'b1;
                        end else begin
                            phase <= phase - 2'd1;
                        end
                    end
                    default: ;
                endcase
                prev <= state_now;
            end
        end
    end
endmodule