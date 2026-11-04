`timescale 1ns / 1ps
//=============================================================================
// ui_snapshot.v —— 每场把 ui_data_ram 中的频谱峰值和控制量拷入显示域
//=============================================================================
module ui_snapshot (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    output reg  [7:0] rd_addr,
    input  wire [7:0] rd_data,

    output reg [7:0]  v_count0,
    output reg [7:0]  v_count1,
    output reg [7:0]  v_count2,
    output reg [7:0]  v_count3,
    output reg [7:0]  v_timbre,
    output reg [7:0]  v_volume,
    output reg [7:0]  v_pitch_step,
    output reg [7:0]  v_a,
    output reg [7:0]  v_d,
    output reg [7:0]  v_s,
    output reg [7:0]  v_r,
    output reg [7:0]  v_reverb,
    output reg [7:0]  v_delay,
    output reg [7:0]  v_chorus,
    output reg [7:0]  v_reverb_size,
    output reg [7:0]  v_reverb_mix,
    output reg [7:0]  v_delay_time,
    output reg [7:0]  v_delay_feedback,
    output reg [7:0]  v_chorus_rate,
    output reg [7:0]  v_chorus_depth,
    output reg [7:0]  v_enc_layer,
    output reg [7:0]  v_func_layer,
    output reg [7:0]  v_voices0,
    output reg [7:0]  v_voices1,
    output reg [7:0]  v_voices2,
    output reg [7:0]  v_voices3,
    output reg [7:0]  v_song,
    output reg [7:0]  v_glide,
    output reg [7:0]  v_vibrato,
    output reg [7:0]  v_playing,
    output reg [7:0]  v_song_count,
    output reg        valid,
    output reg        busy
);
    localparam [7:0] BASE = 8'd208;
    localparam integer N = 31;

    reg [4:0] idx;
    reg [1:0] phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx <= 5'd0; phase <= 2'd0; valid <= 1'b0; busy <= 1'b0;
            rd_addr <= BASE;
            v_count0 <= 0; v_count1 <= 0; v_count2 <= 0; v_count3 <= 0;
            v_timbre <= 0; v_volume <= 0; v_pitch_step <= 0;
            v_a <= 0; v_d <= 0; v_s <= 0; v_r <= 0;
            v_reverb <= 0; v_delay <= 0; v_chorus <= 0;
            v_reverb_size <= 0; v_reverb_mix <= 0; v_delay_time <= 0;
            v_delay_feedback <= 0; v_chorus_rate <= 0; v_chorus_depth <= 0;
            v_enc_layer <= 0; v_func_layer <= 0;
            v_voices0 <= 0; v_voices1 <= 0; v_voices2 <= 0; v_voices3 <= 0;
            v_song <= 0; v_glide <= 0; v_vibrato <= 0; v_playing <= 0; v_song_count <= 0;
        end else begin
            valid <= 1'b0;
            if (!busy) begin
                if (start) begin
                    busy <= 1'b1; idx <= 5'd0; phase <= 2'd0; rd_addr <= BASE;
                end
            end else begin
                if (phase == 2'd0) begin
                    rd_addr <= BASE + {3'b0, idx};
                    phase <= 2'd1;
                end else if (phase == 2'd1) begin
                    phase <= 2'd2;
                end else begin
                    case (idx)
                    5'd0:  v_count0 <= rd_data;
                    5'd1:  v_count1 <= rd_data;
                    5'd2:  v_count2 <= rd_data;
                    5'd3:  v_count3 <= rd_data;
                    5'd4:  v_timbre <= rd_data;
                    5'd5:  v_volume <= rd_data;
                    5'd6:  v_pitch_step <= rd_data;
                    5'd7:  v_a <= rd_data;
                    5'd8:  v_d <= rd_data;
                    5'd9:  v_s <= rd_data;
                    5'd10: v_r <= rd_data;
                    5'd11: v_reverb <= rd_data;
                    5'd12: v_delay <= rd_data;
                    5'd13: v_chorus <= rd_data;
                    5'd14: v_voices0 <= rd_data;
                    5'd15: v_voices1 <= rd_data;
                    5'd16: v_voices2 <= rd_data;
                    5'd17: v_voices3 <= rd_data;
                    5'd18: v_song <= rd_data;
                    5'd19: v_glide <= rd_data;
                    5'd20: v_vibrato <= rd_data;
                    5'd21: v_playing <= rd_data;
                    5'd22: v_song_count <= rd_data;
                    5'd23: v_reverb_size <= rd_data;
                    5'd24: v_reverb_mix <= rd_data;
                    5'd25: v_delay_time <= rd_data;
                    5'd26: v_delay_feedback <= rd_data;
                    5'd27: v_chorus_rate <= rd_data;
                    5'd28: v_chorus_depth <= rd_data;
                    5'd29: v_enc_layer <= rd_data;
                    5'd30: v_func_layer <= rd_data;
                    default: ;
                    endcase
                    if (idx == N - 1) begin
                        busy <= 1'b0; valid <= 1'b1;
                    end else begin
                        idx <= idx + 5'd1; phase <= 2'd0;
                    end
                end
            end
        end
    end
endmodule