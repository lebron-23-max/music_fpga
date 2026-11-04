`timescale 1ns / 1ps
//=============================================================================
// ui_text_ram.v —— 文本字符层（字符单元 RAM）
//=============================================================================
// 64 列 x 64 行 字符单元，每格 1 字节 ASCII；
// 屏幕映射：单元 (cx,cy) 覆盖像素 x = cx*16..cx*16+15, y = cy*16..cy*16+15。
//   cx = x[9:4]（0..49 用得到），cy = y[9:4]（0..37 用得到）
//   地址 = {cy[5:0], cx[5:0]}
// 写口：文本刷新 FSM（只在场消隐写）；读口：像素流水线每拍读一次。
// 同一时钟域、写读各一个端口 ⇒ 综合成半双口 BSRAM，读写互不冲突。
//=============================================================================
module ui_text_ram (
    input  wire        clk,
    input  wire        we,
    input  wire [11:0] waddr,
    input  wire [7:0]  wdata,
    input  wire [11:0] raddr,
    output reg  [7:0]  rdata
);
    reg [7:0] mem [0:4095];

    always @(posedge clk) if (we) mem[waddr] <= wdata;
    always @(posedge clk) rdata <= mem[raddr];
endmodule
