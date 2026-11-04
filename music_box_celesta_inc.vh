    function [31:0] phase_inc_for_note;  // Q16, scaled 32 kHz -> 48828.125 Hz
        input [3:0] note;
        begin
            case (note)
            0:  phase_inc_for_note = 32'd42614;  // MIDI 72
            1:  phase_inc_for_note = 32'd45131;  // MIDI 73
            2:  phase_inc_for_note = 32'd47983;  // MIDI 74
            3:  phase_inc_for_note = 32'd50835;  // MIDI 75
            4:  phase_inc_for_note = 32'd53855;  // MIDI 76
            5:  phase_inc_for_note = 32'd57043;  // MIDI 77
            6:  phase_inc_for_note = 32'd60398;  // MIDI 78
            7:  phase_inc_for_note = 32'd63921;  // MIDI 79
            8:  phase_inc_for_note = 32'd67780;  // MIDI 80
            9:  phase_inc_for_note = 32'd35903;  // MIDI 81
            10:  phase_inc_for_note = 32'd38084;  // MIDI 82
            11:  phase_inc_for_note = 32'd40265;  // MIDI 83
            default: phase_inc_for_note = 32'd42614;
            endcase
        end
    endfunction
