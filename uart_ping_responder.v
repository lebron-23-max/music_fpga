`timescale 1ns / 1ps
// Minimal HC-05 bring-up command responder.
// Receives the ASCII byte sequence "PING" (no line ending required) and
// transmits "PONG\r\n". Unknown bytes are ignored.
module uart_ping_responder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx_valid,
    input  wire [7:0] rx_data,
    input  wire       tx_busy,
    output reg        tx_start,
    output reg  [7:0] tx_data
);
    localparam [1:0] WAIT_READY  = 2'd0;
    localparam [1:0] START_PULSE = 2'd1;
    localparam [1:0] WAIT_BUSY   = 2'd2;
    localparam [1:0] WAIT_DONE   = 2'd3;

    reg [1:0] match_index;
    reg [1:0] tx_state;
    reg [2:0] response_index;
    reg       response_pending;

    function [7:0] response_byte;
        input [2:0] index;
        begin
            case (index)
                3'd0: response_byte = 8'h50; // P
                3'd1: response_byte = 8'h4F; // O
                3'd2: response_byte = 8'h4E; // N
                3'd3: response_byte = 8'h47; // G
                3'd4: response_byte = 8'h0D; // CR
                default: response_byte = 8'h0A; // LF
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            match_index      <= 2'd0;
            tx_state         <= WAIT_READY;
            response_index   <= 3'd0;
            response_pending <= 1'b0;
            tx_start         <= 1'b0;
            tx_data          <= 8'd0;
        end else begin
            tx_start <= 1'b0;

            if (rx_valid && !response_pending) begin
                case (match_index)
                    2'd0: match_index <= (rx_data == 8'h50) ? 2'd1 : 2'd0;
                    2'd1: match_index <= (rx_data == 8'h49) ? 2'd2 :
                                         ((rx_data == 8'h50) ? 2'd1 : 2'd0);
                    2'd2: match_index <= (rx_data == 8'h4E) ? 2'd3 :
                                         ((rx_data == 8'h50) ? 2'd1 : 2'd0);
                    2'd3: begin
                        if (rx_data == 8'h47) begin
                            match_index      <= 2'd0;
                            response_pending <= 1'b1;
                            response_index   <= 3'd0;
                            tx_state         <= WAIT_READY;
                        end else begin
                            match_index <= (rx_data == 8'h50) ? 2'd1 : 2'd0;
                        end
                    end
                endcase
            end

            case (tx_state)
                WAIT_READY: begin
                    if (response_pending && !tx_busy) begin
                        tx_data <= response_byte(response_index);
                        tx_start <= 1'b1;
                        tx_state <= START_PULSE;
                    end
                end

                START_PULSE: begin
                    tx_start <= 1'b0;
                    tx_state <= WAIT_BUSY;
                end

                WAIT_BUSY: begin
                    if (tx_busy)
                        tx_state <= WAIT_DONE;
                end

                WAIT_DONE: begin
                    if (!tx_busy) begin
                        if (response_index == 3'd5) begin
                            response_pending <= 1'b0;
                            response_index   <= 3'd0;
                        end else begin
                            response_index <= response_index + 3'd1;
                        end
                        tx_state <= WAIT_READY;
                    end
                end

                default: tx_state <= WAIT_READY;
            endcase
        end
    end
endmodule