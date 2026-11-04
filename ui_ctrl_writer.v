`timescale 1ns / 1ps
//=============================================================================
// ui_ctrl_writer.v —— 把音频域控制量和四音色声部数写入 ui_data_ram
//=============================================================================
module ui_ctrl_writer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  timbre_sel,
    input  wire [7:0]  volume,
    input  wire signed [5:0] pitch_step,
    input  wire [7:0]  adsr_a,
    input  wire [7:0]  adsr_d,
    input  wire [7:0]  adsr_s,
    input  wire [7:0]  adsr_r,
    input  wire [7:0]  reverb,
    input  wire [7:0]  delay,
    input  wire [7:0]  chorus,
    input  wire [7:0]  reverb_size,
    input  wire [7:0]  reverb_mix,
    input  wire [7:0]  delay_time,
    input  wire [7:0]  delay_feedback,
    input  wire [7:0]  chorus_rate,
    input  wire [7:0]  chorus_depth,
    input  wire [1:0]  enc_layer,
    input  wire [1:0]  func_layer,
    input  wire [7:0]  glide,
    input  wire [7:0]  vibrato,
    input  wire [2:0]  song_sel,
    input  wire        playing,
    input  wire [7:0]  song_count,
    input  wire [7:0]  voice_busy0,
    input  wire [7:0]  voice_busy1,
    input  wire [7:0]  voice_busy2,
    input  wire [7:0]  voice_busy3,

    output reg         we,
    output reg  [7:0]  addr,
    output reg  [7:0]  data
);
    localparam [7:0] BASE = 8'd212;



    reg [11:0] tick;
    reg [4:0]  idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick <= 12'd0; idx <= 5'd0; we <= 1'b0;
            addr <= BASE; data <= 8'd0;
        end else begin
            we <= 1'b0;
            if (tick == 12'd4095) begin
                tick <= 12'd0;
                we   <= 1'b1;
                addr <= BASE + {3'b0, idx};
                case (idx)
                5'd0:  data <= {6'b0, timbre_sel};
                5'd1:  data <= volume;
                5'd2:  data <= {{2{pitch_step[5]}}, pitch_step};
                5'd3:  data <= adsr_a;
                5'd4:  data <= adsr_d;
                5'd5:  data <= adsr_s;
                5'd6:  data <= adsr_r;
                5'd7:  data <= reverb;
                5'd8:  data <= delay;
                5'd9:  data <= chorus;
                5'd10: data <= voice_busy0;
                5'd11: data <= voice_busy1;
                5'd12: data <= voice_busy2;
                5'd13: data <= voice_busy3;
                5'd14: data <= {5'b0, song_sel};
                5'd15: data <= glide;
                5'd16: data <= vibrato;
                5'd17: data <= {7'b0, playing};
                5'd18: data <= song_count;
                5'd19: data <= reverb_size;
                5'd20: data <= reverb_mix;
                5'd21: data <= delay_time;
                5'd22: data <= delay_feedback;
                5'd23: data <= chorus_rate;
                5'd24: data <= chorus_depth;
                5'd25: data <= {6'b0, enc_layer} + 8'd1;
                5'd26: data <= {6'b0, func_layer} + 8'd1;
                default: data <= 8'd0;
                endcase
                idx <= (idx == 5'd26) ? 5'd0 : (idx + 5'd1);
            end else begin
                tick <= tick + 12'd1;
            end
        end
    end
endmodule