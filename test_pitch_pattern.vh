    // Consonant 25-note C-major stress pattern used by full-voice tests.
    function [6:0] test_midi_for_voice;
        input [6:0] voice;
        reg [6:0] r;
        begin
            r = voice;
            if (r >= 7'd100) r = r - 7'd100;
            if (r >= 7'd75)  r = r - 7'd75;
            if (r >= 7'd50)  r = r - 7'd50;
            if (r >= 7'd25)  r = r - 7'd25;
            case (r)
                5'd0: test_midi_for_voice = 7'd72;
                5'd1: test_midi_for_voice = 7'd74;
                5'd2: test_midi_for_voice = 7'd76;
                5'd3: test_midi_for_voice = 7'd77;
                5'd4: test_midi_for_voice = 7'd79;
                5'd5: test_midi_for_voice = 7'd81;
                5'd6: test_midi_for_voice = 7'd83;
                5'd7: test_midi_for_voice = 7'd84;
                5'd8: test_midi_for_voice = 7'd86;
                5'd9: test_midi_for_voice = 7'd88;
                5'd10: test_midi_for_voice = 7'd89;
                5'd11: test_midi_for_voice = 7'd91;
                5'd12: test_midi_for_voice = 7'd93;
                5'd13: test_midi_for_voice = 7'd95;
                5'd14: test_midi_for_voice = 7'd96;
                5'd15: test_midi_for_voice = 7'd98;
                5'd16: test_midi_for_voice = 7'd100;
                5'd17: test_midi_for_voice = 7'd101;
                5'd18: test_midi_for_voice = 7'd103;
                5'd19: test_midi_for_voice = 7'd105;
                5'd20: test_midi_for_voice = 7'd107;
                5'd21: test_midi_for_voice = 7'd108;
                5'd22: test_midi_for_voice = 7'd110;
                5'd23: test_midi_for_voice = 7'd112;
                5'd24: test_midi_for_voice = 7'd115;
                default: test_midi_for_voice = 7'd72;
            endcase
        end
    endfunction
