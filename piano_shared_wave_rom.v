`timescale 1ns / 1ps
//=============================================================================
// piano_shared_wave_rom.v
// 多个钢琴声部共享的单口 C4/A4 多帧波表 ROM。
//
// 地址格式：
//   address[13:12] = bank 选择
//       0 = C4 bank0
//       1 = C4 bank1
//       2 = A4 bank0
//       3 = A4 bank1
//   address[11:0] = bank 内地址（4 帧 x 1024 点）
//
// 四个 bank 各只实例化一次。外部扫描器每个时钟提供一个地址，
// 数据在下一次时钟沿返回；bank_sel_q 与 bank 数据同步锁存，
// 保证地址切换时选择的是上一拍真正读出的 bank。
//=============================================================================
module piano_shared_wave_rom (
    input  wire               clk,
    input  wire [13:0]        address,
    output wire signed [15:0] data
);

    wire [11:0] bank_address = address[11:0];
    wire [1:0]  bank_select  = address[13:12];

    reg [1:0] bank_select_q;

    wire signed [15:0] c4_bank0_data;
    wire signed [15:0] c4_bank1_data;
    wire signed [15:0] a4_bank0_data;
    wire signed [15:0] a4_bank1_data;

    piano_wave_C4_bank0 u_c4_bank0 (
        .clk(clk),
        .address(bank_address),
        .data(c4_bank0_data)
    );

    piano_wave_C4_bank1 u_c4_bank1 (
        .clk(clk),
        .address(bank_address),
        .data(c4_bank1_data)
    );

    piano_wave_A4_bank0 u_a4_bank0 (
        .clk(clk),
        .address(bank_address),
        .data(a4_bank0_data)
    );

    piano_wave_A4_bank1 u_a4_bank1 (
        .clk(clk),
        .address(bank_address),
        .data(a4_bank1_data)
    );

    always @(posedge clk) begin
        bank_select_q <= bank_select;
    end

    assign data = (bank_select_q == 2'd0) ? c4_bank0_data :
                  (bank_select_q == 2'd1) ? c4_bank1_data :
                  (bank_select_q == 2'd2) ? a4_bank0_data :
                                            a4_bank1_data;

endmodule

// 钢琴波表 bank ROM：C4/A4 的 8 个时间帧分到偶数帧和奇数帧 bank。
module piano_wave_C4_bank0 (
    input  wire               clk,
    input  wire [11:0]        address,
    output reg  signed [15:0] data
);
    reg signed [15:0] piano_rom [0:4095];
    initial begin
`include "piano_rom_C4_bank0.vh"
    end
    always @(posedge clk) data <= piano_rom[address];
endmodule

module piano_wave_C4_bank1 (
    input  wire               clk,
    input  wire [11:0]        address,
    output reg  signed [15:0] data
);
    reg signed [15:0] piano_rom [0:4095];
    initial begin
`include "piano_rom_C4_bank1.vh"
    end
    always @(posedge clk) data <= piano_rom[address];
endmodule

module piano_wave_A4_bank0 (
    input  wire               clk,
    input  wire [11:0]        address,
    output reg  signed [15:0] data
);
    reg signed [15:0] piano_rom [0:4095];
    initial begin
`include "piano_rom_A4_bank0.vh"
    end
    always @(posedge clk) data <= piano_rom[address];
endmodule

module piano_wave_A4_bank1 (
    input  wire               clk,
    input  wire [11:0]        address,
    output reg  signed [15:0] data
);
    reg signed [15:0] piano_rom [0:4095];
    initial begin
`include "piano_rom_A4_bank1.vh"
    end
    always @(posedge clk) data <= piano_rom[address];
endmodule

