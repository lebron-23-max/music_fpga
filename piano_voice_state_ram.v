`timescale 1ns / 1ps
// 50-voice piano TDM state bank. One read/write port is enough because the
// engine scans one voice at a time and writes it back before advancing.
module piano_voice_state_ram #(
    parameter integer WIDTH = 192,
    parameter integer DEPTH = 64
) (
    input  wire                 clk,
    input  wire [6:0]           addr,
    input  wire                 we,
    input  wire [WIDTH-1:0]     wdata,
    output reg  [WIDTH-1:0]     rdata
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {WIDTH{1'b0}};
    end
    always @(posedge clk) begin
        if (we)
            mem[addr] <= wdata;
        else
            rdata <= mem[addr];
    end
endmodule