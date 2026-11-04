#!/usr/bin/env python3
"""Generate the FPGA WS2812 guide score for 晴天 from the supplied PDF."""
from pathlib import Path

ROOT = Path(r"D:\gaoyun_project\music_1")
OUT = ROOT / "src" / "builtin_guide_score.v"
DEG = {1:0, 2:2, 3:4, 4:5, 5:7, 6:9, 7:11}
line1 = [(3,0,0,0),(2,0,0,0),(4,0,0,0),(3,0,0,1),(1,0,0,0),(5,0,0,0),(7,0,0,0),(1,0,1,0),(7,0,0,0),(5,0,0,0),(1,0,0,1)]
line2 = [(1,0,0,0),(6,0,0,0),(6,0,0,1),(6,0,1,0),(5,0,0,0),(5,0,0,1)]
line3 = [(5,0,0,0),(4,0,0,0),(3,0,0,1),(2,0,0,0),(3,0,0,0),(4,0,0,0),(3,0,0,1)]
line4 = [(3,0,0,0),(4,1,0,0),(5,1,0,0),(3,0,0,1),(4,1,0,0),(5,1,0,0),(7,0,0,0),(2,0,1,0),(7,0,0,0),(1,0,1,0),(1,0,1,1)]
line5 = [(1,0,1,0),(1,0,1,0),(5,0,0,0),(5,0,0,0),(6,0,0,0),(5,0,0,0),(4,0,0,1),(2,0,0,0),(3,0,0,0),(4,0,0,0),(5,0,0,0),(6,0,0,0),(1,0,0,0),(6,0,0,0),(7,0,0,0),(7,0,0,1)]
line10 = [(1,0,1,0),(1,0,1,0),(5,0,0,0),(5,0,0,0),(6,0,0,0),(5,0,0,0),(4,0,0,1),(6,0,1,0),(7,0,1,0),(1,0,0,0),(2,0,0,0),(3,0,0,0),(2,0,0,1)]
line11 = [(3,0,0,0),(1,0,0,1)]
events = line1 + line2 + line3 + line4 + line5 + line1 + line2 + line3 + line4 + line10 + line11
notes=[]
for d,sharp,up,bar in events:
    n=DEG[d] + (1 if sharp else 0) + (12 if up else 0)
    if not (0 <= n <= 24): raise ValueError(n)
    notes.append((n,bar))

def case_note():
    return '\n'.join(f"                7'd{i}: event_note = 5'd{v};" for i,(v,_) in enumerate(notes))
def case_bar():
    return '\n'.join(f"                7'd{i}: event_extra = BAR_GAP;" for i,(_,v) in enumerate(notes) if v)
def case_half():
    # Phrase endings are held for two units; the PDF does not specify exact
    # rhythmic values beyond spacing, so this mirrors the previous guide speed.
    idx = {10,16,24,35,51,57,64,75,88,99}
    return '\n'.join(f"                7'd{i}: event_base = H;" for i in range(len(notes)) if i in idx)

src=f'''`timescale 1ns / 1ps
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
    localparam [6:0] EVENT_LAST = 7'd{len(notes)-1};
    localparam [17:0] Q = 18'd16384;
    localparam [17:0] H = 18'd32768;
    localparam [17:0] NOTE_GAP = 18'd2048;
    localparam [17:0] BAR_GAP = 18'd4096;

    function [4:0] event_note;
        input [6:0] idx;
        begin
            case (idx)
{case_note()}
                default: event_note = 5'd0;
            endcase
        end
    endfunction

    function [17:0] event_base;
        input [6:0] idx;
        begin
            case (idx)
{case_half()}
                default: event_base = Q;
            endcase
        end
    endfunction

    function [17:0] event_extra;
        input [6:0] idx;
        begin
            case (idx)
{case_bar()}
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
'''
OUT.write_text(src, encoding='utf-8', newline='\n')
print('events',len(notes),'last_note',notes[-1][0],'bars',sum(b for _,b in notes),'out',OUT)