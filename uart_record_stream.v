`timescale 1ns / 1ps
//=============================================================================
// uart_record_stream.v - live performance event snapshots over HC-05 UART
//
// Packet: BTEV (4), sequence (1), timbre (1), octave_shift (1),
//         key_mask[31:0] little-endian (4), XOR checksum (1) = 12 bytes.
//
// This is a state stream, not recorded PCM. The App compares consecutive masks
// to reconstruct note-on and note-off events. Only the newest unsent snapshot is
// retained, so UART backpressure can never stall the audio/keyboard path.
//=============================================================================
module uart_record_stream (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        record_enable,
    input  wire [24:0] key_mask,
    input  wire [1:0]  timbre_code,
    input  wire [2:0]  octave_shift,
    input  wire        tx_busy,
    input  wire        tx_grant,
    output reg         tx_req,
    output reg  [7:0]  tx_data,
    output reg  [7:0]  packet_count
);
    localparam [3:0] LAST_BYTE = 4'd11;

    reg        record_enable_d;
    reg        active;
    reg [3:0]  byte_idx;
    reg        dirty;
    reg [24:0] snap_mask;
    reg [1:0]  snap_timbre;
    reg [2:0]  snap_octave;
    reg [7:0]  snap_seq;

    wire snapshot_changed = (key_mask != snap_mask) ||
                            (timbre_code != snap_timbre) ||
                            (octave_shift != snap_octave);

    function [7:0] event_byte;
        input [3:0]  idx;
        input [7:0]  seq;
        input [1:0]  timbre;
        input [2:0]  octave;
        input [24:0] mask;
        begin
            case (idx)
                4'd0: event_byte = 8'h42; // B
                4'd1: event_byte = 8'h54; // T
                4'd2: event_byte = 8'h45; // E
                4'd3: event_byte = 8'h56; // V
                4'd4: event_byte = seq;
                4'd5: event_byte = {6'd0, timbre};
                4'd6: event_byte = {5'd0, octave};
                4'd7: event_byte = mask[7:0];
                4'd8: event_byte = mask[15:8];
                4'd9: event_byte = mask[23:16];
                4'd10: event_byte = {7'd0, mask[24]};
                default: event_byte = 8'h42 ^ 8'h54 ^ 8'h45 ^ 8'h56 ^
                                      seq ^ {6'd0, timbre} ^ {5'd0, octave} ^
                                      mask[7:0] ^ mask[15:8] ^ mask[23:16] ^
                                      {7'd0, mask[24]};
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            record_enable_d <= 1'b0;
            active <= 1'b0;
            byte_idx <= 4'd0;
            dirty <= 1'b0;
            snap_mask <= 25'd0;
            snap_timbre <= 2'd0;
            snap_octave <= 3'd0;
            snap_seq <= 8'd0;
            tx_req <= 1'b0;
            tx_data <= 8'd0;
            packet_count <= 8'd0;
        end else begin
            tx_req <= 1'b0;
            record_enable_d <= record_enable;

            if (!record_enable) begin
                active <= 1'b0;
                byte_idx <= 4'd0;
                dirty <= 1'b0;
                snap_mask <= key_mask;
                snap_timbre <= timbre_code;
                snap_octave <= octave_shift;
            end else begin
                if (!record_enable_d)
                    dirty <= 1'b1;

                if (!active) begin
                    if (dirty || snapshot_changed) begin
                        active <= 1'b1;
                        byte_idx <= 4'd0;
                        dirty <= 1'b0;
                        snap_mask <= key_mask;
                        snap_timbre <= timbre_code;
                        snap_octave <= octave_shift;
                        snap_seq <= snap_seq + 8'd1;
                        packet_count <= packet_count + 8'd1;
                        tx_req <= 1'b1;
                        tx_data <= event_byte(4'd0, snap_seq + 8'd1, timbre_code,
                                              octave_shift, key_mask);
                    end
                end else begin
                    tx_req <= 1'b1;
                    tx_data <= event_byte(byte_idx, snap_seq, snap_timbre,
                                          snap_octave, snap_mask);
                    if (tx_grant) begin
                        if (byte_idx == LAST_BYTE) begin
                            active <= 1'b0;
                            byte_idx <= 4'd0;
                            dirty <= snapshot_changed;
                        end else begin
                            byte_idx <= byte_idx + 4'd1;
                        end
                    end
                end

                if (active && snapshot_changed)
                    dirty <= 1'b1;
            end
        end
    end
endmodule