`timescale 1ns / 1ps
//=============================================================================
// step_sequencer.v - 4 tracks x 32 editable steps, performance sequencer
//=============================================================================
// Editing (encoder layer 4 on HDMI page 2):
//   enc0: select row 1..4 then TEMPO/SWING/GATE
//   enc1: on a track select 1 of 32 steps; on a parameter change its value
//   Steps 1..16 and 17..32 share one 16-column grid bank selected by the
//   selected step high bit; the completed bank remains visible in active_mask.
//   note key: write note into selected step, press same note again to clear
//   U57: toggle second HDMI page
//   U55/U61/U60/U59: arm/disarm tracks 1..4
//=============================================================================
module step_sequencer #(parameter integer KEY_COUNT = 25) (
    input  wire clk,
    input  wire rst_n,
    input  wire sample_tick,
    input  wire [KEY_COUNT-1:0] key_pressed,
    input  wire [1:0] enc_layer,
    input  wire [3:0] enc_up,
    input  wire [3:0] enc_down,
    input  wire page_toggle,
    input  wire [3:0] confirm_pulse,
    input  wire start,
    input  wire stop,
    output reg playing,
    output reg page,
    output reg [2:0] selected_row,
    output reg [4:0] selected_step,
    output reg [7:0] speed,
    output reg [7:0] swing,
    output reg [7:0] gate_sel,
    output reg [3:0] track_ready,
    output reg [127:0] active_mask,
    output wire [5:0] selected_entry,
    output reg [24:0] gate_piano,
    output reg [24:0] gate_musicbox,
    output reg [24:0] gate_epiano,
    output reg [24:0] gate_strings
);
    localparam [24:0] GATE_OFF = 25'h1FFFFFF;
    // Four-bar default demo: piano melody, sparse music-box sparkle,
    // electric-piano arpeggio and strings root movement.
    localparam [767:0] DEFAULT_PATTERN = 768'h000020000027000025000020000020000027000025000020B27927B27920CEEAEECEEAE7C6CA6CC6CA65B27927B2792003000003300003500003800003500003300003000002C0008249E9B279209E9AEEC2EAE7967A6CBACA65822927A67920;
    localparam [127:0] DEFAULT_MASK = 128'h11111111FFFFFFFF44444444FFFFFFFF;
    reg [24:0] key_d;
    reg        start_d;
    reg [4:0]  play_step;
    reg [15:0] step_cnt;
    reg [15:0] gate_cnt;
    reg        gate_open;
    reg [767:0] pattern_bus;

    function [5:0] pattern_at;
        input [1:0] track;
        input [4:0] step;
        begin
            pattern_at = pattern_bus[(track*32 + step)*6 +: 6];
        end
    endfunction

    function [4:0] lowest_key;
        input [24:0] v;
        integer i;
        begin
            lowest_key = 5'd0;
            for (i=24;i>=0;i=i-1)
                if (v[i]) lowest_key = i[4:0];
        end
    endfunction

    // 19 tempo positions: 24..96 BPM in 4 BPM steps.
    // Values are audio-sample ticks for one 16th-note step at 48.828125 kHz.
    function [15:0] base_period;
        input [7:0] bpm;
        begin
            case (bpm)
            8'd24: base_period=16'd30518;
            8'd28: base_period=16'd26158;
            8'd32: base_period=16'd22888;
            8'd36: base_period=16'd20345;
            8'd40: base_period=16'd18311;
            8'd44: base_period=16'd16646;
            8'd48: base_period=16'd15259;
            8'd52: base_period=16'd14085;
            8'd56: base_period=16'd13079;
            8'd60: base_period=16'd12207;
            8'd64: base_period=16'd11444;
            8'd68: base_period=16'd10771;
            8'd72: base_period=16'd10173;
            8'd76: base_period=16'd9637;
            8'd80: base_period=16'd9155;
            8'd84: base_period=16'd8719;
            8'd88: base_period=16'd8323;
            8'd92: base_period=16'd7961;
            8'd96: base_period=16'd7629;
            default:base_period=16'd12207;
            endcase
        end
    endfunction

    // Pipeline the tempo lookup and step-period calculation. This keeps the
    // long BPM mux/adder chain out of the sample-tick gate-control path.
    reg [15:0] period_base_q;
    reg [15:0] step_period_q;
    wire [15:0] swing_delta = (swing==0) ? 16'd0 :
                              (swing==1) ? (period_base_q >> 4) :
                              (swing==2) ? (period_base_q >> 3) : (period_base_q >> 2);
    wire [15:0] step_period_next = play_step[0] ?
                                   (period_base_q + swing_delta) :
                                   (period_base_q - swing_delta);
    wire [15:0] gate_period = (gate_sel==0) ? (step_period_q >> 1) :
                              (gate_sel==1) ? (step_period_q - (step_period_q >> 2)) :
                                              step_period_q;
    wire [4:0] key_now = lowest_key(key_pressed);
    wire       key_press = |(key_pressed & ~key_d) && (enc_layer==2'd3) && page && (selected_row<3'd4);
    wire [6:0] sel_index = {selected_row[1:0],5'd0} + {2'd0,selected_step};
    wire [5:0] sel_entry = pattern_bus[sel_index*6 +: 6];
    wire [4:0] pb_note0 = pattern_at(2'd0, play_step)[4:0];
    wire [4:0] pb_note1 = pattern_at(2'd1, play_step)[4:0];
    wire [4:0] pb_note2 = pattern_at(2'd2, play_step)[4:0];
    wire [4:0] pb_note3 = pattern_at(2'd3, play_step)[4:0];

    task clear_gates;
        begin
            gate_piano <= GATE_OFF;
            gate_musicbox <= GATE_OFF;
            gate_epiano <= GATE_OFF;
            gate_strings <= GATE_OFF;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page<=0;selected_row<=0;selected_step<=0;
            speed<=8'd96;swing<=0;gate_sel<=1;
            pattern_bus<=DEFAULT_PATTERN;active_mask<=DEFAULT_MASK;track_ready<=4'hF;
            playing<=0;play_step<=0;step_cnt<=0;gate_cnt<=0;gate_open<=0;
            period_base_q<=16'd12207;step_period_q<=16'd12207;
            gate_piano<=GATE_OFF;gate_musicbox<=GATE_OFF;gate_epiano<=GATE_OFF;gate_strings<=GATE_OFF;
            key_d<=0;start_d<=0;
        end else begin
            key_d <= key_pressed;
            start_d <= start;
            period_base_q <= base_period(speed);
            step_period_q <= step_period_next;

            if (page_toggle) page <= ~page;

            if (confirm_pulse[0] && page) track_ready[0] <= ~track_ready[0];
            if (confirm_pulse[1] && page) track_ready[1] <= ~track_ready[1];
            if (confirm_pulse[2] && page) track_ready[2] <= ~track_ready[2];
            if (confirm_pulse[3] && page) track_ready[3] <= ~track_ready[3];

            if ((enc_layer==2'd3) && page) begin
                if (enc_up[0]) selected_row <= (selected_row==3'd6) ? 3'd0 : selected_row+3'd1;
                else if (enc_down[0]) selected_row <= (selected_row==3'd0) ? 3'd6 : selected_row-3'd1;

                if (selected_row<4) begin
                    if (enc_up[1] || enc_up[2]) selected_step <= (selected_step==5'd31) ? 5'd0 : selected_step+5'd1;
                    else if (enc_down[1] || enc_down[2]) selected_step <= (selected_step==0) ? 5'd31 : selected_step-5'd1;
                    if (key_press) begin
                        if (sel_entry[5] && sel_entry[4:0]==key_now) begin
                            pattern_bus[sel_index*6 +: 6] <= 6'd0;
                            active_mask[sel_index] <= 1'b0;
                        end else begin
                            pattern_bus[sel_index*6 +: 6] <= {1'b1,key_now};
                            active_mask[sel_index] <= 1'b1;
                        end
                    end
                end else begin
                    if (enc_up[1]) begin
                        if (selected_row==3'd4 && speed<8'd96) speed<=speed+8'd4;
                        if (selected_row==3'd5 && swing<8'd3) swing<=swing+1;
                        if (selected_row==3'd6 && gate_sel<8'd2) gate_sel<=gate_sel+1;
                    end else if (enc_down[1]) begin
                        if (selected_row==3'd4 && speed>8'd24) speed<=speed-8'd4;
                        if (selected_row==3'd5 && swing>0) swing<=swing-1;
                        if (selected_row==3'd6 && gate_sel>0) gate_sel<=gate_sel-1;
                    end
                end
            end

            if (stop) begin
                playing<=0; step_cnt<=0; gate_cnt<=0; gate_open<=0; clear_gates;
            end else if (!playing) begin
                if (start && !start_d) begin
                    playing<=1; play_step<=0; step_cnt<=0; gate_cnt<=0; gate_open<=1;
                    gate_piano<=GATE_OFF; gate_musicbox<=GATE_OFF; gate_epiano<=GATE_OFF; gate_strings<=GATE_OFF;
                    if (track_ready[0] && pattern_at(2'd0,4'd0)[5]) gate_piano[pb_note0]<=1'b0;
                    if (track_ready[1] && pattern_at(2'd1,4'd0)[5]) gate_musicbox[pb_note1]<=1'b0;
                    if (track_ready[2] && pattern_at(2'd2,4'd0)[5]) gate_epiano[pb_note2]<=1'b0;
                    if (track_ready[3] && pattern_at(2'd3,4'd0)[5]) gate_strings[pb_note3]<=1'b0;
                end
            end else if (sample_tick) begin
                if (gate_open && gate_cnt+1>=gate_period) begin
                    gate_open<=0; clear_gates;
                end else if (gate_open) gate_cnt<=gate_cnt+1;

                if (step_cnt+1>=step_period_q) begin
                    step_cnt<=0; gate_cnt<=0;
                    if (play_step==5'd31) begin
                        playing<=0; gate_open<=0; clear_gates;
                    end else begin
                        play_step<=play_step+5'd1; gate_open<=1;
                        gate_piano<=GATE_OFF; gate_musicbox<=GATE_OFF; gate_epiano<=GATE_OFF; gate_strings<=GATE_OFF;
                        if (track_ready[0] && pattern_at(2'd0,play_step+5'd1)[5]) gate_piano[pattern_at(2'd0,play_step+5'd1)[4:0]]<=1'b0;
                        if (track_ready[1] && pattern_at(2'd1,play_step+5'd1)[5]) gate_musicbox[pattern_at(2'd1,play_step+5'd1)[4:0]]<=1'b0;
                        if (track_ready[2] && pattern_at(2'd2,play_step+5'd1)[5]) gate_epiano[pattern_at(2'd2,play_step+5'd1)[4:0]]<=1'b0;
                        if (track_ready[3] && pattern_at(2'd3,play_step+5'd1)[5]) gate_strings[pattern_at(2'd3,play_step+5'd1)[4:0]]<=1'b0;
                    end
                end else step_cnt<=step_cnt+1;
            end
        end
    end
    assign selected_entry = pattern_bus[sel_index*6 +: 6];
endmodule