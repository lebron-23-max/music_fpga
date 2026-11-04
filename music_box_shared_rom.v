`timescale 1ns / 1ps
//=============================================================================
// music_box_shared_rom.v
// 八音盒共享单周期波表 ROM。
// 当前第一版使用 F#4 根音；后续可以增加 F#3/F#5 bank。
//=============================================================================
module music_box_shared_rom (
    input  wire        clk,
    input  wire [10:0] address,
    output reg signed [15:0] data
);
    reg signed [15:0] music_box_rom [0:2047];

    initial begin
`include "music_box_Fs4_2048x16.vh"
    end

    always @(posedge clk)
        data <= music_box_rom[address];

endmodule
