`timescale 1ns / 1ps
// 72-slot music-box voice state RAM (phase, envelope, ADSR, increment, bank, key).
module music_box_state_ram #(
    parameter integer WIDTH = 81,
    parameter integer DEPTH = 72
) (
    input  wire               clk,
    input  wire [6:0]         addr,
    input  wire               we,
    input  wire [WIDTH-1:0]   wdata,
    output reg  [WIDTH-1:0]   rdata
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    integer i;
    initial begin
        for (i=0; i<DEPTH; i=i+1) mem[i] = {WIDTH{1'b0}};
    end
    always @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        else    rdata <= mem[addr];
    end
endmodule