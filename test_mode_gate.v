`timescale 1ns / 1ps
//=============================================================================
// test_mode_gate.v — immediate test-mode blanking with real-tail hold
//=============================================================================
module test_mode_gate (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sample_tick,
    input  wire       test_any,
    input  wire       piano_any,
    input  wire       mb_any,
    input  wire       ep_any,
    input  wire       str_any,
    output wire       blank,
    output reg        release_wait
);
    reg test_any_q;
    reg all_silent_q;
    reg any_sounding_q;
    wire any_sounding = piano_any | mb_any | ep_any | str_any;

    // test_any_q remains asserted for at least one clock after the panel
    // releases its last test mode. Including it here removes the otherwise
    // visible one-cycle gap that showed the old MB tail (for example 14 voices).
    assign blank = test_any | test_any_q | release_wait;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_any_q    <= 1'b0;
            all_silent_q  <= 1'b1;
            any_sounding_q<= 1'b0;
            release_wait  <= 1'b0;
        end else begin
            // Capture the deassertion edge every clock, not only on an audio
            // sample tick; sample_tick is 1024 clocks apart.
            test_any_q <= test_any;
            if (sample_tick) begin
                any_sounding_q <= any_sounding;
                all_silent_q <= ~any_sounding_q;
            end

            if (test_any) begin
                release_wait <= 1'b0;
            end else if (test_any_q) begin
                release_wait <= 1'b1;
            end else if (release_wait && all_silent_q) begin
                release_wait <= 1'b0;
            end
        end
    end
endmodule