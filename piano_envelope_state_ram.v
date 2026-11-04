`timescale 1ns / 1ps
//=============================================================================
// piano_envelope_state_ram.v
// 144 x 36-bit simple-dual-port RAM for packed piano envelope states.
// Port A is write-only; port B is read-only and is shared between the
// background state scan and the real-time envelope query in the piano TDM.
//=============================================================================
module piano_envelope_state_ram #(
    parameter integer DEPTH = 144,
    parameter integer WIDTH = 36
) (
    input  wire                 clk,
    input  wire [8:0]           waddr,
    input  wire                 we,
    input  wire [WIDTH-1:0]     wdata,
    input  wire [8:0]           raddr,
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
            mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        rdata <= mem[raddr];
    end
endmodule