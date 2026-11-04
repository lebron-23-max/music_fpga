`timescale 1ns / 1ps
//=============================================================================
// music_score_player.v —— 4/8-track score event player
//=============================================================================
// Legacy v1 event (flags[2]=0):
//   delta[15:0], {note[3:0],timbre[1:0],track[1:0]}, duration
// Extended v2 event (flags[2]=1):
//   b0      = delta[7:0]
//   b1[3:0] = delta[11:8]
//   b1[5:4] = timbre[1:0]
//   b1[7]   = note[4]
//   b2[3:0] = note[3:0]
//   b2[6:4] = track[2:0]
//   b3      = duration in ticks
// v2 event body starts at byte 64; bytes 24..48 contain the 25-key MIDI map.
module music_score_player (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire        start,
    input  wire        stop,
    input  wire        load_done,
    input  wire [7:0]  track_count,
    input  wire [31:0] tempo_step,
    input  wire [15:0] event_count,
    input  wire [7:0]  flags,
    input  wire [7:0]  ram_rdata,
    output reg  [9:0]  ram_raddr,
    output reg         playing,
    output reg         done,
    output reg  [24:0] gate_piano,
    output reg  [24:0] gate_musicbox,
    output reg  [24:0] gate_epiano,
    output reg  [24:0] gate_strings
);
    localparam [3:0] P_IDLE=4'd0, P_SET0=4'd1, P_WAIT0=4'd2, P_CAP0=4'd3,
                     P_WAIT1=4'd4, P_CAP1=4'd5, P_WAIT2=4'd6, P_CAP2=4'd7,
                     P_WAIT3=4'd8, P_CAP3=4'd9, P_MUSIC_WAIT=4'd10,
                     P_TRIGGER=4'd11, P_DONE=4'd12, P_DRAIN=4'd13;
    localparam [24:0] GATE_OFF = 25'h1FFFFFF;
    localparam [9:0]  EVENT_V1 = 10'd40;
    localparam [9:0]  EVENT_V2 = 10'd64;

    reg [3:0] state;
    reg [9:0] event_ptr;
    reg [7:0] event_index;
    reg [7:0] ev_b0, ev_b1, ev_b2, ev_b3;
    reg [15:0] delta_left;
    reg [23:0] tempo_acc;
    reg [7:0] gate_timer [0:7];
    reg [4:0] gate_note [0:7];
    reg [1:0] gate_timbre [0:7];
    reg       gate_on [0:7];
    integer i, j;

    wire [24:0] tempo_sum = {1'b0, tempo_acc} + tempo_step[24:0];
    wire        seq_tick = playing && sample_tick && tempo_sum[24];
    wire        fmt_v2 = flags[2];
    wire [9:0]  event_start = fmt_v2 ? EVENT_V2 : EVENT_V1;
    wire [15:0] ev_delta = fmt_v2 ? {4'b0, ev_b1[3:0], ev_b0} : {ev_b1, ev_b0};
    wire [2:0]  ev_track = fmt_v2 ? ev_b2[6:4] : {1'b0, ev_b2[1:0]};
    wire [1:0]  ev_timbre = fmt_v2 ? ev_b1[5:4] : ev_b2[3:2];
    wire [4:0]  ev_note = fmt_v2 ? {ev_b1[7], ev_b2[3:0]} : {1'b0, ev_b2[7:4]};
    wire [7:0]  ev_duration = ev_b3;
    wire [7:0]  next_index = event_index + 8'd1;

    always @(*) begin
        gate_piano = GATE_OFF;
        gate_musicbox = GATE_OFF;
        gate_epiano = GATE_OFF;
        gate_strings = GATE_OFF;
        for (j = 0; j < 8; j = j + 1) begin
            if (gate_on[j] && (gate_note[j] < 5'd25)) begin
                case (gate_timbre[j])
                2'd0: gate_piano[gate_note[j]] = 1'b0;
                2'd1: gate_musicbox[gate_note[j]] = 1'b0;
                2'd2: gate_epiano[gate_note[j]] = 1'b0;
                default: gate_strings[gate_note[j]] = 1'b0;
                endcase
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=P_IDLE; event_ptr<=EVENT_V1; event_index<=8'd0;
            ev_b0<=0; ev_b1<=0; ev_b2<=0; ev_b3<=0; delta_left<=0;
            tempo_acc<=0; ram_raddr<=EVENT_V1; playing<=0; done<=0;
            for (i=0;i<8;i=i+1) begin
                gate_timer[i]<=0; gate_note[i]<=0; gate_timbre[i]<=0; gate_on[i]<=0;
            end
        end else begin
            done <= 1'b0;
            if (!playing) tempo_acc <= 24'd0;
            else if (sample_tick) tempo_acc <= tempo_sum[23:0];
            if (stop && playing) begin
                playing<=0; state<=P_IDLE;
                for (i=0;i<8;i=i+1) gate_on[i]<=0;
            end else case (state)
            P_IDLE: begin
                ram_raddr<=event_start;
                if (start && load_done && !playing) begin
                    event_ptr<=event_start; event_index<=8'd0; delta_left<=0;
                    tempo_acc<=0; playing<=1; state<=P_SET0;
                    for (i=0;i<8;i=i+1) gate_on[i]<=0;
                end
            end
            P_SET0: begin ram_raddr<=event_ptr; state<=P_WAIT0; end
            P_WAIT0: begin state<=P_CAP0; end
            P_CAP0: begin ev_b0<=ram_rdata; ram_raddr<=event_ptr+10'd1; state<=P_WAIT1; end
            P_WAIT1: begin state<=P_CAP1; end
            P_CAP1: begin ev_b1<=ram_rdata; ram_raddr<=event_ptr+10'd2; state<=P_WAIT2; end
            P_WAIT2: begin state<=P_CAP2; end
            P_CAP2: begin ev_b2<=ram_rdata; ram_raddr<=event_ptr+10'd3; state<=P_WAIT3; end
            P_WAIT3: begin state<=P_CAP3; end
            P_CAP3: begin ev_b3<=ram_rdata; delta_left<=ev_delta; state<=P_MUSIC_WAIT; end
            P_MUSIC_WAIT: begin
                if (seq_tick) begin
                    for (i=0;i<8;i=i+1) begin
                        if (gate_on[i]) begin
                            if (gate_timer[i]<=8'd1) gate_on[i]<=0;
                            else gate_timer[i]<=gate_timer[i]-8'd1;
                        end
                    end
                    if (delta_left==0) state<=P_TRIGGER;
                    else begin
                        delta_left<=delta_left-16'd1;
                        if (delta_left==16'd1) state<=P_TRIGGER;
                    end
                end
            end
            P_TRIGGER: begin
                if ((ev_track<track_count) && (ev_note<5'd25) && (ev_duration!=0)) begin
                    gate_timer[ev_track]<=ev_duration;
                    gate_note[ev_track]<=ev_note;
                    gate_timbre[ev_track]<=ev_timbre;
                    gate_on[ev_track]<=1'b1;
                end
                event_ptr<=event_ptr+10'd4;
                event_index<=next_index;
                if (next_index >= event_count[7:0]) begin
                    event_ptr<=event_start; event_index<=8'd0;
                    delta_left<=0; state<=P_DRAIN;
                end else state<=P_SET0;
            end
            P_DRAIN: begin
                if (seq_tick) begin
                    for (i=0;i<8;i=i+1) begin
                        if (gate_on[i]) begin
                            if (gate_timer[i]<=8'd1) gate_on[i]<=0;
                            else gate_timer[i]<=gate_timer[i]-8'd1;
                        end
                    end
                    if (!gate_on[0] && !gate_on[1] && !gate_on[2] && !gate_on[3] &&
                        !gate_on[4] && !gate_on[5] && !gate_on[6] && !gate_on[7]) begin
                        if (flags[0]) state<=P_SET0;
                        else begin playing<=0; done<=1'b1; state<=P_DONE; end
                    end
                end
            end
            P_DONE: if (!start) state<=P_IDLE;
            default: state<=P_IDLE;
            endcase
        end
    end
endmodule