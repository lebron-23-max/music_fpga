`timescale 1ns / 1ps
//=============================================================================
// builtin_guide_score.v — 晴天 continuous numbered-notation guide melody
// Generated from 晴天_简谱_连续版.pdf. Numbers 1..7 map to C..B in one
// octave; a dot above adds +12; # raises one semitone; bar flags add a gap.
//=============================================================================
module builtin_guide_score (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire        enable,
    output reg  [24:0] note_mask,
    output reg         done
);
    localparam [6:0] EVENT_LAST = 7'd100;
    localparam [17:0] Q = 18'd16384;
    localparam [17:0] H = 18'd32768;
    localparam [17:0] NOTE_GAP = 18'd2048;
    localparam [17:0] BAR_GAP = 18'd4096;

    function [4:0] event_note;
        input [6:0] idx;
        begin
            case (idx)
                7'd0: event_note = 5'd4;
                7'd1: event_note = 5'd2;
                7'd2: event_note = 5'd5;
                7'd3: event_note = 5'd4;
                7'd4: event_note = 5'd0;
                7'd5: event_note = 5'd7;
                7'd6: event_note = 5'd11;
                7'd7: event_note = 5'd12;
                7'd8: event_note = 5'd11;
                7'd9: event_note = 5'd7;
                7'd10: event_note = 5'd0;
                7'd11: event_note = 5'd0;
                7'd12: event_note = 5'd9;
                7'd13: event_note = 5'd9;
                7'd14: event_note = 5'd21;
                7'd15: event_note = 5'd7;
                7'd16: event_note = 5'd7;
                7'd17: event_note = 5'd7;
                7'd18: event_note = 5'd5;
                7'd19: event_note = 5'd4;
                7'd20: event_note = 5'd2;
                7'd21: event_note = 5'd4;
                7'd22: event_note = 5'd5;
                7'd23: event_note = 5'd4;
                7'd24: event_note = 5'd4;
                7'd25: event_note = 5'd6;
                7'd26: event_note = 5'd8;
                7'd27: event_note = 5'd4;
                7'd28: event_note = 5'd6;
                7'd29: event_note = 5'd8;
                7'd30: event_note = 5'd11;
                7'd31: event_note = 5'd14;
                7'd32: event_note = 5'd11;
                7'd33: event_note = 5'd12;
                7'd34: event_note = 5'd12;
                7'd35: event_note = 5'd12;
                7'd36: event_note = 5'd12;
                7'd37: event_note = 5'd7;
                7'd38: event_note = 5'd7;
                7'd39: event_note = 5'd9;
                7'd40: event_note = 5'd7;
                7'd41: event_note = 5'd5;
                7'd42: event_note = 5'd2;
                7'd43: event_note = 5'd4;
                7'd44: event_note = 5'd5;
                7'd45: event_note = 5'd7;
                7'd46: event_note = 5'd9;
                7'd47: event_note = 5'd0;
                7'd48: event_note = 5'd9;
                7'd49: event_note = 5'd11;
                7'd50: event_note = 5'd11;
                7'd51: event_note = 5'd4;
                7'd52: event_note = 5'd2;
                7'd53: event_note = 5'd5;
                7'd54: event_note = 5'd4;
                7'd55: event_note = 5'd0;
                7'd56: event_note = 5'd7;
                7'd57: event_note = 5'd11;
                7'd58: event_note = 5'd12;
                7'd59: event_note = 5'd11;
                7'd60: event_note = 5'd7;
                7'd61: event_note = 5'd0;
                7'd62: event_note = 5'd0;
                7'd63: event_note = 5'd9;
                7'd64: event_note = 5'd9;
                7'd65: event_note = 5'd21;
                7'd66: event_note = 5'd7;
                7'd67: event_note = 5'd7;
                7'd68: event_note = 5'd7;
                7'd69: event_note = 5'd5;
                7'd70: event_note = 5'd4;
                7'd71: event_note = 5'd2;
                7'd72: event_note = 5'd4;
                7'd73: event_note = 5'd5;
                7'd74: event_note = 5'd4;
                7'd75: event_note = 5'd4;
                7'd76: event_note = 5'd6;
                7'd77: event_note = 5'd8;
                7'd78: event_note = 5'd4;
                7'd79: event_note = 5'd6;
                7'd80: event_note = 5'd8;
                7'd81: event_note = 5'd11;
                7'd82: event_note = 5'd14;
                7'd83: event_note = 5'd11;
                7'd84: event_note = 5'd12;
                7'd85: event_note = 5'd12;
                7'd86: event_note = 5'd12;
                7'd87: event_note = 5'd12;
                7'd88: event_note = 5'd7;
                7'd89: event_note = 5'd7;
                7'd90: event_note = 5'd9;
                7'd91: event_note = 5'd7;
                7'd92: event_note = 5'd5;
                7'd93: event_note = 5'd21;
                7'd94: event_note = 5'd23;
                7'd95: event_note = 5'd0;
                7'd96: event_note = 5'd2;
                7'd97: event_note = 5'd4;
                7'd98: event_note = 5'd2;
                7'd99: event_note = 5'd4;
                7'd100: event_note = 5'd0;
                default: event_note = 5'd0;
            endcase
        end
    endfunction

    function [17:0] event_base;
        input [6:0] idx;
        begin
            case (idx)
                7'd10: event_base = H;
                7'd16: event_base = H;
                7'd24: event_base = H;
                7'd35: event_base = H;
                7'd51: event_base = H;
                7'd57: event_base = H;
                7'd64: event_base = H;
                7'd75: event_base = H;
                7'd88: event_base = H;
                7'd99: event_base = H;
                default: event_base = Q;
            endcase
        end
    endfunction

    function [17:0] event_extra;
        input [6:0] idx;
        begin
            case (idx)
                7'd3: event_extra = BAR_GAP;
                7'd10: event_extra = BAR_GAP;
                7'd13: event_extra = BAR_GAP;
                7'd16: event_extra = BAR_GAP;
                7'd19: event_extra = BAR_GAP;
                7'd23: event_extra = BAR_GAP;
                7'd27: event_extra = BAR_GAP;
                7'd34: event_extra = BAR_GAP;
                7'd41: event_extra = BAR_GAP;
                7'd50: event_extra = BAR_GAP;
                7'd54: event_extra = BAR_GAP;
                7'd61: event_extra = BAR_GAP;
                7'd64: event_extra = BAR_GAP;
                7'd67: event_extra = BAR_GAP;
                7'd70: event_extra = BAR_GAP;
                7'd74: event_extra = BAR_GAP;
                7'd78: event_extra = BAR_GAP;
                7'd85: event_extra = BAR_GAP;
                7'd92: event_extra = BAR_GAP;
                7'd98: event_extra = BAR_GAP;
                7'd100: event_extra = BAR_GAP;
                default: event_extra = 18'd0;
            endcase
        end
    endfunction

    function [17:0] event_len;
        input [6:0] idx;
        begin
            event_len = event_base(idx) + event_extra(idx);
        end
    endfunction

    reg [6:0]  event_idx;
    reg [17:0] tick_left;
    reg [17:0] gate_left;
    reg        enable_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_idx <= 7'd0;
            tick_left <= 18'd0;
            gate_left <= 18'd0;
            enable_d  <= 1'b0;
            note_mask <= 25'd0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            enable_d <= enable;
            if (!enable) begin
                event_idx <= 7'd0;
                tick_left <= 18'd0;
                gate_left <= 18'd0;
                note_mask <= 25'd0;
            end else if (!enable_d) begin
                event_idx <= 7'd0;
                tick_left <= event_len(7'd0) - 18'd1;
                gate_left <= (event_len(7'd0) > NOTE_GAP) ? (event_len(7'd0)-NOTE_GAP-18'd1) : (event_len(7'd0)-18'd1);
                note_mask <= 25'd1 << event_note(7'd0);
            end else if (sample_tick) begin
                if (tick_left == 18'd0) begin
                    if (event_idx == EVENT_LAST) begin
                        note_mask <= 25'd0;
                        done <= 1'b1;
                        event_idx <= 7'd0;
                        tick_left <= 18'd0;
                        gate_left <= 18'd0;
                    end else begin
                        event_idx <= event_idx + 7'd1;
                        tick_left <= event_len(event_idx + 7'd1) - 18'd1;
                        gate_left <= (event_len(event_idx + 7'd1) > NOTE_GAP) ? (event_len(event_idx + 7'd1)-NOTE_GAP-18'd1) : (event_len(event_idx + 7'd1)-18'd1);
                        note_mask <= 25'd1 << event_note(event_idx + 7'd1);
                    end
                end else begin
                    tick_left <= tick_left - 18'd1;
                    if (gate_left != 18'd0) gate_left <= gate_left - 18'd1;
                    note_mask <= (gate_left > 18'd1) ? (25'd1 << event_note(event_idx)) : 25'd0;
                end
            end
        end
    end
endmodule
