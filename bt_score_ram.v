`timescale 1ns / 1ps
// Volatile 1024-byte score RAM for Bluetooth / UART download.
// Force distributed LUTRAM because all block RAMs are already occupied.
module bt_score_ram (
    input  wire        clk,
    input  wire        we,
    input  wire [9:0]  waddr,
    input  wire [7:0]  wdata,
    input  wire [9:0]  raddr,
    output reg  [7:0]  rdata
);
`ifdef GOWIN_SYNTHESIS
    (* syn_ramstyle = "distributed" *) reg [7:0] mem [0:1023];
`else
    (* ram_style = "distributed" *) reg [7:0] mem [0:1023];
`endif
    integer i;
    initial begin
        for (i=0;i<1024;i=i+1) mem[i]=8'd0;
    end
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule