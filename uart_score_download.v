`timescale 1ns / 1ps
//=============================================================================
// uart_score_download.v - HC-05 volatile score + per-key tuning + octave
//=============================================================================
// Score frame: BTSD, cmd=0x01, seq, length=512 LE16, payload CRC32 LE32,
// then 512-byte MSCORE1 payload. It becomes volatile BT1.
//
// Octave frame: BTOK, cmd=0x03, seq, length=1 LE16, payload CRC32 LE32,
// then delta (0x01=up, 0xFF=down, 0x00=reset).
// Record frame: BTRC, cmd=0x04, seq, length=1, payload CRC32, then 0/1.
// Per-key tune frame: BTKM, cmd=0x05, seq, length=26, payload CRC32,
// then timbre[1:0] plus 25 signed semitone offsets. The offset is applied
// first; the existing BTOK global octave is applied afterwards.
// BTSD/BTOK/BTRC/BTKM never access the SD score path.
module uart_score_download (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire [1:0]  current_timbre,
    output reg         ram_we,
    output reg  [9:0]  ram_waddr,
    output reg  [7:0]  ram_wdata,
    output reg         download_active,
    output reg         download_commit,
    output reg         download_error,
    output reg         octave_commit,
    output reg         record_enable,
    output wire        tx_hold_record,
    output reg  [2:0]  octave_shift_piano,
    output reg  [2:0]  octave_shift_musicbox,
    output reg  [2:0]  octave_shift_epiano,
    output reg  [2:0]  octave_shift_strings,
    output reg  [199:0] key_tune_piano,
    output reg  [199:0] key_tune_musicbox,
    output reg  [199:0] key_tune_epiano,
    output reg  [199:0] key_tune_strings,
    output reg         tx_start,
    output reg  [7:0]  tx_data,
    input  wire        tx_busy,
    output reg  [7:0]  track_count,
    output reg  [7:0]  ticks_per_q,
    output reg  [7:0]  flags,
    output reg  [31:0] tempo_step,
    output reg  [15:0] event_count,
    output reg  [15:0] event_bytes,
    output reg  [31:0] body_crc,
    output reg  [199:0] score_key_map,
    output wire [3:0]  state_dbg
);
    localparam [4:0] S_IDLE=5'd0, S_M1=5'd1, S_M2=5'd2,
                     S_M3_SCORE=5'd3, S_M3_OCT=5'd4, S_M3_REC=5'd15, S_M3_KEY=5'd16,
                     S_CMD=5'd5, S_SEQ=5'd6, S_LEN0=5'd7, S_LEN1=5'd8,
                     S_CRC0=5'd9, S_CRC1=5'd10, S_CRC2=5'd11, S_CRC3=5'd12,
                     S_PAYLOAD=5'd13, S_CHECK=5'd14;
    localparam [1:0] KIND_SCORE=2'd0, KIND_OCT=2'd1, KIND_REC=2'd2, KIND_KEY=2'd3;
    localparam [1:0] TX_NONE=2'd0, TX_ACK=2'd1, TX_NAK=2'd2;
    localparam [31:0] CRC32_POLY=32'hEDB88320;

    reg [4:0] state;
    reg [7:0] cmd_q, seq_q, delta_q;
    reg [15:0] payload_len;
    reg [31:0] crc_expected, crc_work;
    reg [9:0] payload_idx;
    reg [63:0] score_magic;
    reg [7:0] score_version;
    reg [1:0] timbre_q;
    reg [199:0] key_map_candidate;
    reg [1:0] key_timbre_q;
    reg [7:0] key_timbre_raw;
    reg [7:0] key_tune_tmp [0:24];
    reg [1:0] frame_kind;      // 0=score, 1=octave, 2=record, 3=key tune
    reg       score_frame;
    reg [1:0] tx_kind;
    reg       tx_pending;
    reg [2:0] tx_idx;
    reg [1:0] tx_phase;
    wire [31:0] crc_next = crc32_byte(crc_work, rx_data);
    wire [9:0] score_event_start = flags[2] ? 10'd64 : 10'd40;
    wire [10:0] score_event_end = {1'b0,score_event_start} + event_bytes;

    function [31:0] crc32_byte;
        input [31:0] c_in;
        input [7:0] d;
        integer j;
        reg [31:0] c;
        begin
            c = c_in;
            for (j=0;j<8;j=j+1)
                c = (c[0]^d[j]) ? ((c>>1)^CRC32_POLY) : (c>>1);
            crc32_byte = c;
        end
    endfunction

    function [7:0] tx_msg_byte;
        input [1:0] kind;
        input [2:0] idx;
        begin
            if (kind == TX_ACK) begin
                case (idx)
                3'd0: tx_msg_byte = 8'h41;
                3'd1: tx_msg_byte = 8'h43;
                3'd2: tx_msg_byte = 8'h4B;
                3'd3: tx_msg_byte = 8'h0D;
                default: tx_msg_byte = 8'h0A;
                endcase
            end else begin
                case (idx)
                3'd0: tx_msg_byte = 8'h4E;
                3'd1: tx_msg_byte = 8'h41;
                3'd2: tx_msg_byte = 8'h4B;
                3'd3: tx_msg_byte = 8'h0D;
                default: tx_msg_byte = 8'h0A;
                endcase
            end
        end
    endfunction

    function note_ok;
        input [7:0] value;
        begin
            note_ok = (value <= 8'd127);
        end
    endfunction

    function [2:0] next_octave;
        input [2:0] current;
        input [7:0] delta;
        begin
            case (delta)
            8'h00: next_octave = 3'b000;
            8'h01: next_octave = (current == 3'b001) ? 3'b001 : current + 3'd1;
            8'hFF: next_octave = (current == 3'b111) ? 3'b111 : current - 3'd1;
            default: next_octave = current;
            endcase
        end
    endfunction

    function octave_map_ok;
        input [199:0] map;
        input [2:0] shift;
        integer j;
        reg [7:0] note;
        begin
            octave_map_ok = 1'b1;
            for (j=0; j<25; j=j+1) begin
                note = map[j*8 +: 8];
                if ((shift == 3'b001) && (note > 8'd115)) octave_map_ok = 1'b0;
                if ((shift == 3'b111) && (note < 8'd12))  octave_map_ok = 1'b0;
            end
        end
    endfunction
    reg [24:0] key_tune_valid_mask;
    reg [199:0] key_tune_candidate;
    integer kv;
    always @* begin
        key_tune_valid_mask = 25'h1FFFFFF;
        key_tune_candidate = 200'd0;
        for (kv = 0; kv < 25; kv = kv + 1) begin
            key_tune_valid_mask[kv] = note_ok(key_tune_tmp[kv]);
            key_tune_candidate[kv*8 +: 8] = key_tune_tmp[kv];
        end
    end

    wire [2:0] selected_octave =
        (timbre_q == 2'd0) ? octave_shift_piano :
        (timbre_q == 2'd1) ? octave_shift_musicbox :
        (timbre_q == 2'd2) ? octave_shift_epiano : octave_shift_strings;
    wire [2:0] candidate_octave = next_octave(selected_octave, delta_q);
    wire octave_map_valid =
        (timbre_q == 2'd0) ? octave_map_ok(key_tune_piano, candidate_octave) :
        (timbre_q == 2'd1) ? octave_map_ok(key_tune_musicbox, candidate_octave) :
        (timbre_q == 2'd2) ? octave_map_ok(key_tune_epiano, candidate_octave) :
                             octave_map_ok(key_tune_strings, candidate_octave);
    // BTKM must be valid together with the target timbre's existing octave layer.
    wire [2:0] key_existing_octave =
        (key_timbre_q == 2'd0) ? octave_shift_piano :
        (key_timbre_q == 2'd1) ? octave_shift_musicbox :
        (key_timbre_q == 2'd2) ? octave_shift_epiano : octave_shift_strings;
    wire key_map_with_octave_valid = octave_map_ok(key_tune_candidate, key_existing_octave);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cmd_q <= 0; seq_q <= 0; delta_q <= 0; payload_len <= 0;
            crc_expected <= 0; crc_work <= 32'hFFFFFFFF; payload_idx <= 0;
            score_magic <= 0; score_version <= 0; timbre_q <= 0;
            frame_kind <= 0; score_frame <= 0;
            track_count <= 0; ticks_per_q <= 0; flags <= 0; tempo_step <= 0;
            event_count <= 0; event_bytes <= 0; body_crc <= 0; score_key_map <= 0; key_map_candidate <= 0;
            ram_we <= 0; ram_waddr <= 0; ram_wdata <= 0;
            download_active <= 0; download_commit <= 0; download_error <= 0; octave_commit <= 0; record_enable <= 0;
            octave_shift_piano <= 3'b000;
            octave_shift_musicbox <= 3'b000;
            octave_shift_epiano <= 3'b000;
            octave_shift_strings <= 3'b000;
            for (kv=0; kv<25; kv=kv+1) begin
                key_tune_piano[kv*8 +: 8] <= 8'd72 + kv[7:0];
                key_tune_musicbox[kv*8 +: 8] <= 8'd72 + kv[7:0];
                key_tune_epiano[kv*8 +: 8] <= 8'd72 + kv[7:0];
                key_tune_strings[kv*8 +: 8] <= 8'd60 + kv[7:0];
            end
            key_timbre_q <= 2'd0;
            key_timbre_raw <= 8'd0;
            tx_start <= 0; tx_data <= 0; tx_kind <= TX_NONE;
            tx_pending <= 0; tx_idx <= 0; tx_phase <= 0;
        end else begin
            ram_we <= 0;
            download_commit <= 0;
            octave_commit <= 0;
            tx_start <= 0;
            download_active <= score_frame && (state != S_IDLE);

            case (tx_phase)
            2'd0: if (tx_pending && !tx_busy) begin
                tx_data <= tx_msg_byte(tx_kind, tx_idx);
                tx_start <= 1;
                tx_phase <= 2'd1;
            end
            2'd1: tx_phase <= 2'd2;
            2'd2: if (tx_busy) tx_phase <= 2'd3;
            2'd3: if (!tx_busy) begin
                if (tx_idx == 3'd4) begin
                    tx_pending <= 0;
                    tx_idx <= 0;
                end else begin
                    tx_idx <= tx_idx + 3'd1;
                end
                tx_phase <= 2'd0;
            end
            default: tx_phase <= 2'd0;
            endcase

            if (rx_valid) begin
                case (state)
                S_IDLE: if (rx_data == 8'h42) begin
                    state <= S_M1;
                    crc_work <= 32'hFFFFFFFF;
                    payload_idx <= 0;
                    score_magic <= 0;
                    frame_kind <= KIND_SCORE;
                    score_frame <= 1'b0;
                    download_error <= 1'b0;
                end
                S_M1: state <= (rx_data == 8'h54) ? S_M2 : S_IDLE;
                S_M2: begin
                    if (rx_data == 8'h53) begin
                        frame_kind <= KIND_SCORE;
                        score_frame <= 1'b1;
                        state <= S_M3_SCORE;
                    end else if (rx_data == 8'h4F) begin
                        frame_kind <= KIND_OCT;
                        score_frame <= 1'b0;
                        state <= S_M3_OCT;
                    end else if (rx_data == 8'h52) begin
                        frame_kind <= KIND_REC;
                        score_frame <= 1'b0;
                        state <= S_M3_REC;
                    end else if (rx_data == 8'h4B) begin
                        frame_kind <= KIND_KEY;
                        score_frame <= 1'b0;
                        state <= S_M3_KEY;
                    end else begin
                        state <= S_IDLE;
                    end
                end
                S_M3_SCORE: state <= (rx_data == 8'h44) ? S_CMD : S_IDLE;
                S_M3_OCT:   state <= (rx_data == 8'h4B) ? S_CMD : S_IDLE;
                S_M3_REC:   state <= (rx_data == 8'h43) ? S_CMD : S_IDLE;
                S_M3_KEY:   state <= (rx_data == 8'h4D) ? S_CMD : S_IDLE;
                S_CMD: begin cmd_q <= rx_data; state <= S_SEQ; end
                S_SEQ: begin seq_q <= rx_data; state <= S_LEN0; end
                S_LEN0: begin payload_len[7:0] <= rx_data; state <= S_LEN1; end
                S_LEN1: begin payload_len[15:8] <= rx_data; state <= S_CRC0; end
                S_CRC0: begin crc_expected[7:0] <= rx_data; state <= S_CRC1; end
                S_CRC1: begin crc_expected[15:8] <= rx_data; state <= S_CRC2; end
                S_CRC2: begin crc_expected[23:16] <= rx_data; state <= S_CRC3; end
                S_CRC3: begin
                    crc_expected[31:24] <= rx_data;
                    crc_work <= 32'hFFFFFFFF;
                    payload_idx <= 0;
                    timbre_q <= current_timbre;
                    if (((frame_kind == KIND_SCORE) && ((payload_len == 16'd512) || (payload_len == 16'd1024))) ||
                        (((frame_kind == KIND_OCT) || (frame_kind == KIND_REC)) &&
                         (payload_len == 16'd1)) ||
                        ((frame_kind == KIND_KEY) && (payload_len == 16'd26))) begin
                        state <= S_PAYLOAD;
                    end else begin
                        tx_pending <= 1;
                        tx_kind <= TX_NAK;
                        tx_idx <= 0;
                        download_error <= 1;
                        state <= S_IDLE;
                    end
                end
                S_PAYLOAD: begin
                    crc_work <= crc_next;
                    if (frame_kind == KIND_SCORE) begin
                        ram_we <= 1;
                        ram_waddr <= payload_idx;
                        ram_wdata <= rx_data;
                        if (payload_idx < 8) score_magic <= {score_magic[55:0],rx_data};
                        if (payload_idx == 8) score_version <= rx_data;
                        if (payload_idx == 9) track_count <= rx_data;
                        if (payload_idx == 10) ticks_per_q <= rx_data;
                        if (payload_idx == 11) flags <= rx_data;
                        if (payload_idx == 12) tempo_step[7:0] <= rx_data;
                        if (payload_idx == 13) tempo_step[15:8] <= rx_data;
                        if (payload_idx == 14) tempo_step[23:16] <= rx_data;
                        if (payload_idx == 15) tempo_step[31:24] <= rx_data;
                        if (payload_idx == 16) event_count[7:0] <= rx_data;
                        if (payload_idx == 17) event_count[15:8] <= rx_data;
                        if (payload_idx == 18) event_bytes[7:0] <= rx_data;
                        if (payload_idx == 19) event_bytes[15:8] <= rx_data;
                        if (payload_idx == 20) body_crc[7:0] <= rx_data;
                        if (payload_idx == 21) body_crc[15:8] <= rx_data;
                        if (payload_idx == 22) body_crc[23:16] <= rx_data;
                        if (payload_idx == 23) body_crc[31:24] <= rx_data;
                        if ((payload_idx >= 10'd24) && (payload_idx < 10'd49))
                            key_map_candidate[(payload_idx-10'd24)*8 +: 8] <= rx_data;
                        if (payload_idx == payload_len - 16'd1) state <= S_CHECK;
                        else payload_idx <= payload_idx + 10'd1;
                    end else if (frame_kind == KIND_KEY) begin
                        if (payload_idx == 0) begin key_timbre_q <= rx_data[1:0]; key_timbre_raw <= rx_data; end
                        else key_tune_tmp[payload_idx[4:0] - 5'd1] <= rx_data;
                        if (payload_idx == 9'd25) state <= S_CHECK;
                        else payload_idx <= payload_idx + 9'd1;
                    end else begin
                        delta_q <= rx_data;
                        state <= S_CHECK;
                    end
                end
                default: state <= S_IDLE;
                endcase
            end

            if (state == S_CHECK) begin
                if (frame_kind == KIND_KEY) begin
                    if ((cmd_q == 8'h06) && (payload_len == 16'd26) &&
                        ((~crc_work) == crc_expected) && (key_timbre_raw <= 8'd3) &&
                        (&key_tune_valid_mask) && key_map_with_octave_valid) begin
                        case (key_timbre_q)
                        2'd0: for (kv = 0; kv < 25; kv = kv + 1) key_tune_piano[kv*8 +: 8] <= key_tune_tmp[kv];
                        2'd1: for (kv = 0; kv < 25; kv = kv + 1) key_tune_musicbox[kv*8 +: 8] <= key_tune_tmp[kv];
                        2'd2: for (kv = 0; kv < 25; kv = kv + 1) key_tune_epiano[kv*8 +: 8] <= key_tune_tmp[kv];
                        default: for (kv = 0; kv < 25; kv = kv + 1) key_tune_strings[kv*8 +: 8] <= key_tune_tmp[kv];
                        endcase
                        tx_pending <= 1;
                        tx_kind <= TX_ACK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end else begin
                        download_error <= 1;
                        tx_pending <= 1;
                        tx_kind <= TX_NAK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end
                end else if (frame_kind == KIND_OCT) begin
                    if ((cmd_q == 8'h03) && (payload_len == 16'd1) &&
                        ((~crc_work) == crc_expected) &&
                        ((delta_q == 8'h01) || (delta_q == 8'hFF) || (delta_q == 8'h00)) && octave_map_valid) begin
                        case (timbre_q)
                        2'd0: octave_shift_piano <= candidate_octave;
                        2'd1: octave_shift_musicbox <= candidate_octave;
                        2'd2: octave_shift_epiano <= candidate_octave;
                        default: octave_shift_strings <= candidate_octave;
                        endcase
                        octave_commit <= 1;
                        tx_pending <= 1;
                        tx_kind <= TX_ACK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end else begin
                        download_error <= 1;
                        tx_pending <= 1;
                        tx_kind <= TX_NAK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end
                end else if (frame_kind == KIND_REC) begin
                    if ((cmd_q == 8'h04) && (payload_len == 16'd1) &&
                        ((~crc_work) == crc_expected) &&
                        ((delta_q == 8'h00) || (delta_q == 8'h01))) begin
                        record_enable <= delta_q[0];
                        tx_pending <= 1;
                        tx_kind <= TX_ACK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end else begin
                        download_error <= 1;
                        tx_pending <= 1;
                        tx_kind <= TX_NAK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end
                end else begin
                    if ((cmd_q == 8'h01) &&
                        ((payload_len == 16'd512) || (payload_len == 16'd1024)) &&
                        ((~crc_work) == crc_expected) &&
                        (score_magic == 64'h4D53434F52453100) &&
                        (score_version == 8'd1) && (track_count != 0) &&
                        (track_count <= 8'd8) &&
                        (event_count != 0) &&
                        (event_count <= (flags[2] ? 16'd240 : 16'd120)) &&
                        (event_bytes == {event_count[13:0],2'b00}) &&
                        (score_event_end <= {1'b0,payload_len})) begin
                        if (flags[2]) score_key_map <= key_map_candidate;
                        download_commit <= 1;
                        tx_pending <= 1;
                        tx_kind <= TX_ACK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end else begin
                        download_error <= 1;
                        tx_pending <= 1;
                        tx_kind <= TX_NAK;
                        tx_idx <= 0;
                        state <= S_IDLE;
                    end
                end
            end
        end
    end

    assign tx_hold_record = tx_pending || (tx_phase != 2'd0) || (state != S_IDLE);
    assign state_dbg = state[3:0];
endmodule
