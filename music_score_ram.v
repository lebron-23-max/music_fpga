`timescale 1ns / 1ps
//=============================================================================
// music_score_ram.v —— 512 字节曲谱缓存
//=============================================================================
module music_score_ram (
    input  wire       clk,
    input  wire       wbank,
    input  wire       we,
    input  wire [8:0] waddr,
    input  wire [7:0] wdata,
    input  wire       rbank,
    input  wire [8:0] raddr,
    output reg  [7:0] rdata
);
    reg [7:0] mem [0:1023] /* synthesis syn_ramstyle = "registers" */;
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) mem[i] = 8'd0;
    end
    always @(posedge clk) begin
        if (we) mem[{wbank,waddr}] <= wdata;
        rdata <= mem[{rbank,raddr}];
    end
endmodule