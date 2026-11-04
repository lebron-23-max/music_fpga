`timescale 1ns / 1ps
//=============================================================================
// key_matrix_5x5.v — 5x5 switch matrix scanner and note remapper
//
// Electrical topology (from music_pcb.enet):
//   row   0 = B16, 1 = B15, 2 = A16, 3 = A15, 4 = D20
//   col   0 = A20, 1 = B20, 2 = A21, 3 = B21, 4 = COL4
// One row is driven low at a time; all other rows are high-Z. Columns are
// pulled-up inputs. This is required for diode-less same-column multi-touch:
// driving inactive rows high would clamp the column and hide the scanned key.
//
// Output key_pressed[24:0] is active high and uses musical pitch order:
//   bit 0=C, 1=C#, 2=D, ... 11=B, 12=C, ... 24=C (two octaves + top C).
//=============================================================================
module key_matrix_5x5 #(
    parameter integer SCAN_CYCLES     = 10_000, // 200 us per row @ 50 MHz
    parameter integer DEBOUNCE_FRAMES = 5       // per-key 5 ms confirmation
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire [4:0]  row_n,
    input  wire [4:0]  col_n,
    output reg  [24:0] key_pressed,
    output wire [2:0]  scan_row_dbg
);
    localparam integer SCAN_LAST = SCAN_CYCLES - 1;
    localparam integer DB_LAST   = DEBOUNCE_FRAMES - 1;

    // Column pins are asynchronous to the system clock.  A scan row is first
    // captured as a registered 5-bit mask, then its five cells are processed
    // one per clock.  This keeps the long pad/scan-row path out of the
    // per-key debounce and pitch-remap cone.
    reg [15:0] scan_cnt;
    reg [2:0]  scan_row;
    reg [4:0]  row_sel;
    reg [4:0]  col_sync1, col_sync2;
    reg [4:0]  row_cols_q;
    reg [2:0]  proc_row, proc_col;
    reg [4:0]  note_idx_q;
    reg        processing;
    reg [7:0]  debounce_cnt [0:24];
    integer    c;

    function [4:0] matrix_note;
        input [2:0] row;
        input [2:0] col;
        begin
            case (row*5 + col)
                6'd0:  matrix_note = 5'd1;   // U26  C#4
                6'd1:  matrix_note = 5'd3;   // U27  D#4
                6'd2:  matrix_note = 5'd6;   // U28  F#4
                6'd3:  matrix_note = 5'd8;   // U29  G#4
                6'd4:  matrix_note = 5'd10;  // U30  A#4

                6'd5:  matrix_note = 5'd13;  // U33  C#5
                6'd6:  matrix_note = 5'd15;  // U34  D#5
                6'd7:  matrix_note = 5'd18;  // U35  F#5
                6'd8:  matrix_note = 5'd20;  // U36  G#5
                6'd9:  matrix_note = 5'd22;  // U37  A#5

                6'd10: matrix_note = 5'd17;  // U39  F5
                6'd11: matrix_note = 5'd19;  // U40  G5
                6'd12: matrix_note = 5'd21;  // U41  A5
                6'd13: matrix_note = 5'd23;  // U42  B5
                6'd14: matrix_note = 5'd24;  // U43  C6

                6'd15: matrix_note = 5'd9;   // U44  A4
                6'd16: matrix_note = 5'd11;  // U45  B4
                6'd17: matrix_note = 5'd12;  // U46  C5
                6'd18: matrix_note = 5'd14;  // U47  D5
                6'd19: matrix_note = 5'd16;  // U48  E5

                6'd20: matrix_note = 5'd0;   // U49  C4
                6'd21: matrix_note = 5'd2;   // U50  D4
                6'd22: matrix_note = 5'd4;   // U51  E4
                6'd23: matrix_note = 5'd5;   // U52  F4
                default: matrix_note = 5'd7; // U53  G4
            endcase
        end
    endfunction

    // Only the selected row is driven low. All other row pins are released so
    // closed switches on other rows cannot force this row's column high.
    // Use Gowin TBUF explicitly: plain 1'bz on a hierarchical output was
    // optimized back to a push-pull inverse in the final netlist.
    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_row_drive
            TBUF u_row_tbuf (
                .O(row_n[gi]),
                .I(1'b0),
                .OEN(~row_sel[gi])
            );
        end
    endgenerate

    assign scan_row_dbg = scan_row;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt    <= 16'd0;
            scan_row    <= 3'd0;
            row_sel     <= 5'b00001;
            col_sync1   <= 5'b11111;
            col_sync2   <= 5'b11111;
            row_cols_q  <= 5'b00000;
            proc_row    <= 3'd0;
            proc_col    <= 3'd0;
            note_idx_q  <= 5'd0;
            processing  <= 1'b0;
            key_pressed <= 25'd0;
            for (c = 0; c < 25; c = c + 1)
                debounce_cnt[c] <= 8'd0;
        end else begin
            col_sync1 <= col_n;
            col_sync2 <= col_sync1;

            if (!processing) begin
                if (scan_cnt == SCAN_LAST) begin
                    scan_cnt   <= 16'd0;
                    row_cols_q <= ~col_sync2;
                    proc_row   <= scan_row;
                    proc_col   <= 3'd0;
                    note_idx_q <= matrix_note(scan_row, 3'd0);
                    processing <= 1'b1;
                end else begin
                    scan_cnt <= scan_cnt + 16'd1;
                end
            end else begin
                // Only the captured row is evaluated.  Other rows retain their
                // previous debounced state.  One cell is updated per clock.
                if (row_cols_q[proc_col] == key_pressed[note_idx_q]) begin
                    debounce_cnt[note_idx_q] <= 8'd0;
                end else if (debounce_cnt[note_idx_q] == DB_LAST) begin
                    key_pressed[note_idx_q] <= row_cols_q[proc_col];
                    debounce_cnt[note_idx_q] <= 8'd0;
                end else begin
                    debounce_cnt[note_idx_q] <= debounce_cnt[note_idx_q] + 8'd1;
                end

                if (proc_col == 3'd4) begin
                    processing <= 1'b0;
                    if (scan_row == 3'd4) begin
                        scan_row <= 3'd0;
                        row_sel  <= 5'b00001;
                    end else begin
                        scan_row <= scan_row + 3'd1;
                        row_sel  <= 5'b00001 << (scan_row + 3'd1);
                    end
                end else begin
                    proc_col   <= proc_col + 3'd1;
                    note_idx_q <= matrix_note(proc_row, proc_col + 3'd1);
                end
            end
        end
    end
endmodule