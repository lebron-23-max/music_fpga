`timescale 1ns / 1ps
// Debounced active-low button with one-cycle short/long pulses.
// long_pulse fires once while held; short_pulse fires only on release when the
// press never reached the long threshold.
module key_long_press #(
    parameter integer DEBOUNCE_CYCLES = 250_000,
    parameter integer LONG_CYCLES = 20_000_000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,
    output reg  short_pulse,
    output reg  long_pulse
);
    reg [1:0] sync;
    reg stable_n;
    reg [18:0] debounce_cnt;
    reg [25:0] hold_cnt;
    reg long_fired;
    reg stable_d;

    wire stable_changed = stable_n ^ stable_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync <= 2'b11;
        else sync <= {sync[0], key_n};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_n <= 1'b1;
            debounce_cnt <= 19'd0;
        end else if (sync[1] != stable_n) begin
            if (debounce_cnt == DEBOUNCE_CYCLES-1) begin
                stable_n <= sync[1];
                debounce_cnt <= 19'd0;
            end else begin
                debounce_cnt <= debounce_cnt + 19'd1;
            end
        end else begin
            debounce_cnt <= 19'd0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            short_pulse <= 1'b0;
            long_pulse <= 1'b0;
            hold_cnt <= 26'd0;
            long_fired <= 1'b0;
            stable_d <= 1'b1;
        end else begin
            short_pulse <= 1'b0;
            long_pulse <= 1'b0;
            stable_d <= stable_n;

            if (stable_changed) begin
                hold_cnt <= 26'd0;
                if (stable_n) begin
                    if (!long_fired) short_pulse <= 1'b1;
                    long_fired <= 1'b0;
                end else begin
                    long_fired <= 1'b0;
                end
            end

            if (!stable_n && !long_fired) begin
                if (hold_cnt >= LONG_CYCLES-1) begin
                    long_pulse <= 1'b1;
                    long_fired <= 1'b1;
                end else begin
                    hold_cnt <= hold_cnt + 26'd1;
                end
            end
        end
    end
endmodule