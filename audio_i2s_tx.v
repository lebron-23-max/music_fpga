// PT8211 LSBJ I2S 发送器和音频采样脉冲产生器。
module audio_i2s_tx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] sample_in,
    output wire               sample_tick,
    output wire               I2S_BCLK,
    output wire               I2S_LRCK,
    output reg                I2S_DIN
);

    // div_cnt 每 16 个 50 MHz 时钟完成一个 BCK 周期。
    reg [3:0] div_cnt;
    // phase 每 64 个 BCK 周期完成一个左右声道帧。
    reg [5:0] phase;
    // 当前音频帧的采样值，左右声道使用同一个值。
    reg [15:0] frame_sample;

    wire [5:0] next_phase;
    wire [4:0] data_bit_index;

    assign next_phase = (phase == 6'd63) ? 6'd0 : phase + 6'd1;

    // PT8211 使用 LSBJ（最低有效位对齐）格式：
    // 每个声道有 32 个 BCK，前 16 个 BCK 补零，
    // 后 16 个 BCK 按 bit15 到 bit0 的顺序发送。
    // next_phase 为 16~31 或 48~63 时，data_bit_index 为 0~15。
    assign data_bit_index = next_phase[4:0] - 5'd16;

    // div_cnt[3] 为 0 时 BCK 为低，为 1 时 BCK 为高。
    assign I2S_BCLK = div_cnt[3];
    // phase[5] 为 0 时发送左声道，为 1 时发送右声道。
    assign I2S_LRCK = phase[5];

    // 每 1024 个系统时钟产生一个音频采样脉冲。
    assign sample_tick = (div_cnt == 4'd15) && (phase == 6'd63);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt      <= 4'd15;
            phase        <= 6'd63;
            frame_sample <= 16'sd0;
            I2S_DIN      <= 1'b0;
        end else begin
            if (div_cnt == 4'd15) begin
                // 每个 BCK 的下降沿更新 DIN，接收端在 BCK 上升沿采样。
                div_cnt <= 4'd0;
                phase   <= next_phase;

                if (next_phase == 6'd0) begin
                    // 新一帧开始，锁存本帧左右声道共用的采样值。
                    frame_sample <= sample_in;
                    I2S_DIN      <= 1'b0;
                end else if (next_phase < 6'd16) begin
                    // 左声道前半部分补零。
                    I2S_DIN <= 1'b0;
                end else if (next_phase < 6'd32) begin
                    // 左声道后半部分：bit15 到 bit0。
                    I2S_DIN <= frame_sample[15 - data_bit_index];
                end else if (next_phase < 6'd48) begin
                    // 右声道前半部分补零。
                    I2S_DIN <= 1'b0;
                end else begin
                    // 右声道后半部分：bit15 到 bit0。
                    I2S_DIN <= frame_sample[15 - data_bit_index];
                end
            end else begin
                div_cnt <= div_cnt + 4'd1;
            end
        end
    end

endmodule
