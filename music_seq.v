`timescale 1ns / 1ps
//=============================================================================
// music_seq.v
// 自动音阶演示控制器。它只产生 note_gate 和 note_index 事件，
// 不关心钢琴引擎和 I2S。未来可以替换为触摸、矩阵键盘或传感器控制，
// 而不需要修改音频合成通路。
//=============================================================================
module music_seq (
    input  wire       clk,
    input  wire       rst_n,
    output reg        note_gate,
    output reg [3:0]  note_index
);
    localparam [25:0] NOTE_INTERVAL = 26'd49_999_999; // 1.0 s
    localparam [20:0] PRESS_CYCLES  = 21'd999_999;    // 20 ms

    reg [25:0] interval_cnt;
    reg [20:0] press_cnt;
    reg [2:0]  step;

    function [3:0] note_for_step;
        input [2:0] s;
        begin
            case (s)
            3'd0: note_for_step = 4'd0;
            3'd1: note_for_step = 4'd2;
            3'd2: note_for_step = 4'd4;
            3'd3: note_for_step = 4'd5;
            3'd4: note_for_step = 4'd7;
            3'd5: note_for_step = 4'd9;
            default: note_for_step = 4'd11;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            interval_cnt <= 26'd0;
            press_cnt    <= 21'd0;
            step         <= 3'd0;
            note_index   <= 4'd0;
            note_gate    <= 1'b1;
        end else begin
            interval_cnt <= interval_cnt + 26'd1;

            if (interval_cnt >= NOTE_INTERVAL) begin
                interval_cnt <= 26'd0;
                press_cnt    <= 21'd0;
                if (step == 3'd6) begin
                    step       <= 3'd0;
                    note_index <= note_for_step(3'd0);
                end else begin
                    step       <= step + 3'd1;
                    note_index <= note_for_step(step + 3'd1);
                end
                note_gate <= 1'b0;
            end else if (!note_gate) begin
                if (press_cnt >= PRESS_CYCLES) begin
                    press_cnt <= 21'd0;
                    note_gate <= 1'b1;
                end else begin
                    press_cnt <= press_cnt + 21'd1;
                end
            end
        end
    end
endmodule
