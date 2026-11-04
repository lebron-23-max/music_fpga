//=============================================================================
// piano_effects.v —— 钢琴起音/锤击/亮度效果集中模块
// 原来的 attack ROM、亮度包络和锤击播放器统一收拢到这里。
//=============================================================================

// 钢琴锤击起音 ROM。
module piano_attack_C4_rom (
    input  wire               clk,
    input  wire [10:0]        address,
    output reg  signed [15:0] data
);
    reg signed [15:0] piano_attack_rom [0:2047];
    initial begin
`include "piano_attack_C4.vh"
    end
    always @(posedge clk) data <= piano_attack_rom[address];
endmodule

module piano_attack_A4_rom (
    input  wire               clk,
    input  wire [10:0]        address,
    output reg  signed [15:0] data
);
    reg signed [15:0] piano_attack_rom [0:2047];
    initial begin
`include "piano_attack_A4.vh"
    end
    always @(posedge clk) data <= piano_attack_rom[address];
endmodule


// 钢琴起音阶段高频增强。
module piano_attack_brightness (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               note_gate,
    input  wire signed [15:0] sample_in,
    output reg  signed [15:0] bright_out
);
    reg signed [15:0] lowpass_state;
    reg [15:0] bright_env;
    reg        gate_pressed_d;

    wire       gate_pressed = ~note_gate;
    wire       trigger = gate_pressed && !gate_pressed_d;
    wire signed [16:0] lowpass_delta = sample_in - lowpass_state;
    wire signed [16:0] lowpass_next = lowpass_state + (lowpass_delta >>> 3);
    wire signed [15:0] lowpass_saturated = (lowpass_next > 17'sd32767) ? 16'sh7FFF :
                                            (lowpass_next < -17'sd32768) ? 16'sh8000 :
                                            lowpass_next[15:0];
    wire signed [15:0] highpass_sample = sample_in - lowpass_state;
    wire [15:0] bright_step = bright_env >> 10;
    wire signed [32:0] bright_product = highpass_sample * $signed({1'b0, bright_env});
    wire signed [19:0] bright_scaled = bright_product >>> 14;
    wire signed [15:0] bright_saturated = (bright_scaled > 18'sd32767) ? 16'sh7FFF :
                                           (bright_scaled < -18'sd32768) ? 16'sh8000 :
                                           bright_scaled[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lowpass_state <= 16'sd0;
            bright_env    <= 16'd0;
            gate_pressed_d <= 1'b0;
            bright_out    <= 16'sd0;
        end else if (sample_tick) begin
            gate_pressed_d <= gate_pressed;

            if (trigger) begin
                lowpass_state <= 16'sd0;
                bright_env    <= 16'hFFFF;
                bright_out    <= 16'sd0;
            end else begin
                lowpass_state <= lowpass_saturated;

                if (bright_env <= bright_step)
                    bright_env <= 16'd0;
                else
                    bright_env <= bright_env - bright_step;

                bright_out <= bright_saturated;
            end
        end
    end
endmodule

// 钢琴锤击瞬态播放器。
module piano_hammer #(
    parameter integer HAMMER_SHIFT = 1  // 右移越大，锤击层越弱
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               note_gate,
    input  wire               root_is_a4,
    output reg signed [15:0]  hammer_out
);

    reg [10:0] attack_addr;
    reg        playing;
    reg        gate_pressed_d;
    wire       gate_pressed = ~note_gate;
    wire       trigger = gate_pressed && !gate_pressed_d;
    wire signed [15:0] c4_attack_data;
    wire signed [15:0] a4_attack_data;

    piano_attack_C4_rom u_attack_c4 (
        .clk(clk),
        .address(attack_addr),
        .data(c4_attack_data)
    );

    piano_attack_A4_rom u_attack_a4 (
        .clk(clk),
        .address(attack_addr),
        .data(a4_attack_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            attack_addr    <= 11'd0;
            playing        <= 1'b0;
            gate_pressed_d <= 1'b0;
            hammer_out     <= 16'sd0;
        end else if (sample_tick) begin
            gate_pressed_d <= gate_pressed;

            if (trigger) begin
                attack_addr <= 11'd0;
                playing     <= 1'b1;
                hammer_out  <= 16'sd0;
            end else if (playing) begin
                // 根据当前根音选择真实 C4/A4 锤击瞬态。
                hammer_out <= (root_is_a4 ? a4_attack_data : c4_attack_data) >>> HAMMER_SHIFT;

                if (attack_addr == 11'd2047)
                    playing <= 1'b0;
                else
                    attack_addr <= attack_addr + 11'd1;
            end else begin
                hammer_out <= 16'sd0;
            end
        end
    end

endmodule
//=============================================================================
// piano_effects.v 对外的统一效果边界
//=============================================================================
module piano_effects (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               note_gate,
    input  wire               root_is_a4,
    input  wire signed [15:0] sample_in,
    output wire signed [15:0] bright_out,
    output wire signed [15:0] hammer_out
);
    piano_attack_brightness u_brightness (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick),
        .note_gate(note_gate),
        .sample_in(sample_in),
        .bright_out(bright_out)
    );

    piano_hammer #(
        .HAMMER_SHIFT(6)
    ) u_hammer (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick),
        .note_gate(note_gate),
        .root_is_a4(root_is_a4),
        .hammer_out(hammer_out)
    );
endmodule