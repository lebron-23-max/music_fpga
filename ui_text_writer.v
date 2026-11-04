`timescale 1ns / 1ps
//=============================================================================
// ui_text_writer.v —— 文本层刷新（每场消隐期重写整张 UI 文本表）
//=============================================================================
// 表项 24 bit：{is_field(1), 单元地址(12), 0(3), 载荷(8)}
//   is_field=0：载荷 = 字库字符码（0..127 ASCII，128..255 中文）
//   is_field=1：载荷 = field*8 + d，由本模块按实时快照值算出来
// 每场全表重写一遍（302 项 x 3 拍 ≈ 0.9k 拍，场消隐有 29.5k 拍）。
// 字符层是 16x16 单元，地址 = {y[9:4], x[9:4]}。
//=============================================================================
module ui_text_writer (
    input  wire        clk,        // pix_clk
    input  wire        rst_n,
    input  wire        start,      // 消隐期 + 快照就绪时给一拍脉冲

    output reg  [9:0]  rom_addr,
    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         busy,
    output reg  [8:0]  done_cnt,

    input  wire [7:0]  sn_volume,
    input  wire [7:0]  sn_pitch_step,
    input  wire [7:0]  sn_count0,
    input  wire [7:0]  sn_count1,
    input  wire [7:0]  sn_count2,
    input  wire [7:0]  sn_count3,
    input  wire [7:0]  sn_a,
    input  wire [7:0]  sn_d,
    input  wire [7:0]  sn_s,
    input  wire [7:0]  sn_r,
    input  wire [7:0]  sn_timbre,
    input  wire [7:0]  sn_reverb,
    input  wire [7:0]  sn_reverb_size,
    input  wire [7:0]  sn_reverb_mix,
    input  wire [7:0]  sn_delay_time,
    input  wire [7:0]  sn_delay_feedback,
    input  wire [7:0]  sn_chorus_rate,
    input  wire [7:0]  sn_chorus_depth,
    input  wire [7:0]  sn_enc_layer,
    input  wire [7:0]  sn_func_layer,
    input  wire [7:0]  sn_glide,
    input  wire [7:0]  sn_vibrato,
    input  wire [7:0]  sn_song,
    input  wire [7:0]  sn_song_count,
    input  wire [7:0]  sn_voices0,
    input  wire [7:0]  sn_voices1,
    input  wire [7:0]  sn_voices2,
    input  wire [7:0]  sn_voices3,
    input  wire        seq_page,
    input  wire [5:0]  seq_selected_entry,
    input  wire [2:0]  seq_selected_row,
    input  wire [4:0]  seq_selected_step,
    input  wire [3:0]  seq_track_ready,
    input  wire [7:0]  seq_speed,
    input  wire [7:0]  seq_swing,
    input  wire [7:0]  seq_gate_sel
);
    localparam integer NENT = 640;

`include "ui_codes.vh"

    reg [23:0] ui_rom [0:NENT-1] /* synthesis syn_romstyle = "logic" */;
    reg [23:0] ent;

    always @(posedge clk) ent <= ui_rom[rom_addr];

    //---------------- 十进制数字 ----------------
    function [7:0] digit3;
        input [9:0] v;
        input [1:0] d;
        reg [9:0] r;
        reg [3:0] h, t, o;
        begin
            if (v >= 10'd900) begin h=4'd9; r=v-10'd900; end
            else if (v >= 10'd800) begin h=4'd8; r=v-10'd800; end
            else if (v >= 10'd700) begin h=4'd7; r=v-10'd700; end
            else if (v >= 10'd600) begin h=4'd6; r=v-10'd600; end
            else if (v >= 10'd500) begin h=4'd5; r=v-10'd500; end
            else if (v >= 10'd400) begin h=4'd4; r=v-10'd400; end
            else if (v >= 10'd300) begin h=4'd3; r=v-10'd300; end
            else if (v >= 10'd200) begin h=4'd2; r=v-10'd200; end
            else if (v >= 10'd100) begin h=4'd1; r=v-10'd100; end
            else begin h=4'd0; r=v; end
            if (r >= 10'd90) begin t=4'd9; r=r-10'd90; end
            else if (r >= 10'd80) begin t=4'd8; r=r-10'd80; end
            else if (r >= 10'd70) begin t=4'd7; r=r-10'd70; end
            else if (r >= 10'd60) begin t=4'd6; r=r-10'd60; end
            else if (r >= 10'd50) begin t=4'd5; r=r-10'd50; end
            else if (r >= 10'd40) begin t=4'd4; r=r-10'd40; end
            else if (r >= 10'd30) begin t=4'd3; r=r-10'd30; end
            else if (r >= 10'd20) begin t=4'd2; r=r-10'd20; end
            else if (r >= 10'd10) begin t=4'd1; r=r-10'd10; end
            else t=4'd0;
            o = r[3:0];
            if (d == 2'd0)      digit3 = 8'h30 + h;
            else if (d == 2'd1) digit3 = 8'h30 + t;
            else                digit3 = 8'h30 + o;
        end
    endfunction

    // 12 位十进制格式化：最大 1200 cents。旧实现把 rem 截成 8 位，
    // 导致 300→44、350→94；这里所有中间量均保持 12 位。
    function [7:0] pitch_digit;
        input [11:0] v;
        input [1:0]  d;
        reg [11:0] r;
        reg [3:0] h, t;
        begin
            r = (v >= 12'd1000) ? (v - 12'd1000) : v;
            if (r >= 12'd900) begin h = 4'd9; r = r - 12'd900; end
            else if (r >= 12'd800) begin h = 4'd8; r = r - 12'd800; end
            else if (r >= 12'd700) begin h = 4'd7; r = r - 12'd700; end
            else if (r >= 12'd600) begin h = 4'd6; r = r - 12'd600; end
            else if (r >= 12'd500) begin h = 4'd5; r = r - 12'd500; end
            else if (r >= 12'd400) begin h = 4'd4; r = r - 12'd400; end
            else if (r >= 12'd300) begin h = 4'd3; r = r - 12'd300; end
            else if (r >= 12'd200) begin h = 4'd2; r = r - 12'd200; end
            else if (r >= 12'd100) begin h = 4'd1; r = r - 12'd100; end
            else                    h = 4'd0;

            if (r >= 12'd90) begin t = 4'd9; r = r - 12'd90; end
            else if (r >= 12'd80) begin t = 4'd8; r = r - 12'd80; end
            else if (r >= 12'd70) begin t = 4'd7; r = r - 12'd70; end
            else if (r >= 12'd60) begin t = 4'd6; r = r - 12'd60; end
            else if (r >= 12'd50) begin t = 4'd5; r = r - 12'd50; end
            else if (r >= 12'd40) begin t = 4'd4; r = r - 12'd40; end
            else if (r >= 12'd30) begin t = 4'd3; r = r - 12'd30; end
            else if (r >= 12'd20) begin t = 4'd2; r = r - 12'd20; end
            else if (r >= 12'd10) begin t = 4'd1; r = r - 12'd10; end
            else                    t = 4'd0;

            case (d)
            2'd0: pitch_digit = (v >= 12'd1000) ? "1" : "0";
            2'd1: pitch_digit = 8'h30 + {4'd0, h};
            2'd2: pitch_digit = 8'h30 + {4'd0, t};
            default: pitch_digit = 8'h30 + {4'd0, r[3:0]};
            endcase
        end
    endfunction

    wire [7:0] pstepmag = sn_pitch_step[7] ? (~sn_pitch_step + 8'd1) : sn_pitch_step;
    // cents = step*50；移位加法避免显示路径新增乘法器/DSP 推断。
    wire [11:0] pcents12 = (pstepmag << 5) + (pstepmag << 4) + (pstepmag << 1);
    wire [11:0] pmag = pcents12;
    wire [9:0] total_voices_sum = sn_voices0 + sn_voices1 + sn_voices2 + sn_voices3;
    wire [9:0] total_voices = total_voices_sum;


    // 动态字段解码：field = 载荷>>3，d = 载荷&7
    function [7:0] field_char;
        input [4:0] fid;
        input [2:0] d;
        begin
            case (fid)
            4'd0: field_char = digit3(sn_volume, d[1:0]);
            4'd1: begin
                      case (d)
                      3'd0: field_char = sn_pitch_step[7] ? "-" : "+";
                      3'd1: field_char = pitch_digit(pmag, 2'd0);
                      3'd2: field_char = pitch_digit(pmag, 2'd1);
                      3'd3: field_char = pitch_digit(pmag, 2'd2);
                      default: field_char = pitch_digit(pmag, 2'd3);
                      endcase
                  end
            4'd2: field_char = (d == 3'd0) ?
                      digit3((sn_voices0 == 8'd0) ? 8'd0 : sn_count0, 2'd1) :
                      digit3((sn_voices0 == 8'd0) ? 8'd0 : sn_count0, 2'd2);
            4'd3: field_char = (d == 3'd0) ?
                      digit3((sn_voices1 == 8'd0) ? 8'd0 : sn_count1, 2'd1) :
                      digit3((sn_voices1 == 8'd0) ? 8'd0 : sn_count1, 2'd2);
            4'd12: field_char = (d == 3'd0) ?
                      digit3((sn_voices2 == 8'd0) ? 8'd0 : sn_count2, 2'd1) :
                      digit3((sn_voices2 == 8'd0) ? 8'd0 : sn_count2, 2'd2);
            4'd13: field_char = (d == 3'd0) ?
                      digit3((sn_voices3 == 8'd0) ? 8'd0 : sn_count3, 2'd1) :
                      digit3((sn_voices3 == 8'd0) ? 8'd0 : sn_count3, 2'd2);
            4'd4: field_char = digit3(sn_a, d[1:0]);
            4'd5: field_char = digit3(sn_d, d[1:0]);
            4'd6: field_char = digit3(sn_s, d[1:0]);
            4'd7: field_char = digit3(sn_r, d[1:0]);
            // 音色名：3 格 —— 钢琴 / 八音盒 / 电钢琴 / 弦乐
            4'd8: begin
                      case (sn_timbre[1:0])
                      2'd0: field_char = (d == 3'd0) ? CJK_GANG : (d == 3'd1) ? CJK_QIN : " ";
                      2'd1: field_char = (d == 3'd0) ? CJK_BA   : (d == 3'd1) ? CJK_YIN :
                                         (d == 3'd2) ? CJK_HE   : " ";
                      2'd2: field_char = (d == 3'd0) ? CJK_DIAN : (d == 3'd1) ? CJK_GANG :
                                         (d == 3'd2) ? CJK_QIN  : " ";
                      default: field_char = (d == 3'd0) ? CJK_XIAN : (d == 3'd1) ? CJK_YUE : " ";
                      endcase
                  end
            // 混响开关：2 格 —— 关 / 开（混响未实现 ⇒ 恒"关"）
            4'd9: field_char = (d == 3'd0) ? (sn_reverb[0] ? CJK_KAI : CJK_GUAN) : " ";
            4'd10: field_char = (d == 3'd0)
                               ? ((total_voices >= 10'd100) ? digit3(total_voices, 2'd0) : " ")
                               : digit3(total_voices, d[1:0]);
            4'd11: field_char = (d == 3'd0) ? digit3(sn_voices1, 2'd1) : digit3(sn_voices1, 2'd2);
            4'd14: begin
                      case (sn_song[2:0])
                      2'd0: field_char = (d == 3'd0) ? CJK_XIAO : (d == 3'd1) ? CJK_XING :
                                         (d == 3'd2) ? CJK_XING : " ";
                      2'd1: field_char = (d == 3'd0) ? CJK_HUAN : (d == 3'd1) ? CJK_LE :
                                         (d == 3'd2) ? CJK_SONG : " ";
                      2'd2: field_char = (d == 3'd0) ? CJK_LIANG : (d == 3'd1) ? CJK_ZHI :
                                            (d == 3'd2) ? CJK_LAO : (d == 3'd3) ? CJK_HU : " ";
                      2'd3: field_char = (d == 3'd0) ? "S" : (d == 3'd1) ? "E" :
                                          (d == 3'd2) ? "Q" : " ";
                      default: field_char = (d == 3'd0) ? "B" : (d == 3'd1) ? "T" :
                                             (d == 3'd2) ? "1" : " ";
                      endcase
                  end
            5'd16: field_char = digit3(sn_reverb_size, d[1:0]);
            5'd17: field_char = digit3(sn_reverb_mix, d[1:0]);
            5'd18: field_char = digit3(sn_delay_time, d[1:0]);
            5'd19: field_char = digit3(sn_delay_feedback, d[1:0]);
            5'd20: field_char = digit3(sn_chorus_rate, d[1:0]);
            5'd21: field_char = digit3(sn_chorus_depth, d[1:0]);
            5'd22: field_char = (d == 3'd0) ? (8'h30 + sn_enc_layer) : " ";
            5'd23: field_char = (d == 3'd0) ? (8'h30 + sn_func_layer) : " ";
            4'd15: field_char = (d == 3'd0) ? (8'h31 + sn_song) :
                                 (d == 3'd1) ? "/" :
                                 (d == 3'd2) ? (8'h30 + sn_song_count) : " ";
            default: field_char = " ";
            endcase
        end
    endfunction

    function [7:0] seq_note_letter;
        input [4:0] n;
        begin
            case (n%12)
            0: seq_note_letter="C"; 1: seq_note_letter="C"; 2: seq_note_letter="D";
            3: seq_note_letter="D"; 4: seq_note_letter="E"; 5: seq_note_letter="F";
            6: seq_note_letter="F"; 7: seq_note_letter="G"; 8: seq_note_letter="G";
            9: seq_note_letter="A"; 10:seq_note_letter="A"; default:seq_note_letter="B";
            endcase
        end
    endfunction
    function [7:0] seq_note_accidental;
        input [4:0] n;
        begin
            case (n%12)
            1,3,6,8,10: seq_note_accidental="#";
            default: seq_note_accidental=" ";
            endcase
        end
    endfunction
    function [7:0] seq_note_octave;
        input [4:0] n;
        begin
            if (n<12) seq_note_octave="4";
            else if (n<24) seq_note_octave="5";
            else seq_note_octave="6";
        end
    endfunction
    // seq_speed carries BPM directly in 24..96 (4 BPM steps).
    // The display field is three digits: hundreds, tens, ones.
    function [7:0] speed_digit;
        input [7:0] v;
        input [1:0] pos;
        begin
            case (pos)
            2'd0: speed_digit="0";
            2'd1: case (v)
                8'd24,8'd28:                         speed_digit="2";
                8'd32,8'd36:                         speed_digit="3";
                8'd40,8'd44,8'd48:                   speed_digit="4";
                8'd52,8'd56:                         speed_digit="5";
                8'd60,8'd64,8'd68:                   speed_digit="6";
                8'd72,8'd76:                         speed_digit="7";
                8'd80,8'd84,8'd88:                   speed_digit="8";
                8'd92,8'd96:                         speed_digit="9";
                default:                             speed_digit="0";
            endcase
            2'd2: case (v)
                8'd24:                               speed_digit="4";
                8'd28,8'd48,8'd68,8'd88:             speed_digit="8";
                8'd32,8'd52,8'd72,8'd92:             speed_digit="2";
                8'd36,8'd56,8'd76,8'd96:             speed_digit="6";
                8'd40,8'd60,8'd80:                   speed_digit="0";
                8'd44,8'd64,8'd84:                   speed_digit="4";
                default:                             speed_digit="0";
            endcase
            default: speed_digit="0";
            endcase
        end
    endfunction    function [7:0] gate_digit;
        input [7:0] sel;
        input [1:0] pos;
        begin
            if (sel==0) gate_digit = (pos==0) ? "0" : (pos==1) ? "5" : " ";
            else if (sel==1) gate_digit = (pos==0) ? "0" : (pos==1) ? "7" : "5";
            else gate_digit = (pos==0) ? "1" : (pos==1) ? "0" : "0";
        end
    endfunction
    reg [9:0]  idx;
    reg [11:0] seq_addr;
    reg [7:0]  seq_char;
    wire [5:0] seq_sel_entry = seq_selected_entry;
    always @* begin
        seq_addr = 12'd0;
        seq_char = 8'h00;
        if (idx < 12) begin
            seq_addr = 12'd1 + {2'b0, idx};
            case (idx)
            0:seq_char="S"; 1:seq_char="E"; 2:seq_char="Q"; 3:seq_char=" ";
            4:seq_char="3"; 5:seq_char="2"; 6:seq_char=" "; 7:seq_char="S";
            8:seq_char="T"; 9:seq_char="E"; 10:seq_char="P"; default:seq_char=" ";
            endcase
        end else if (idx>=20 && idx<26) begin
            seq_addr=26*50+2+(idx-20);
            case(idx-20) 0:seq_char="T";1:seq_char="E";2:seq_char="M";3:seq_char="P";4:seq_char="O";default:seq_char=" ";endcase
        end else if (idx>=27 && idx<30) begin
            seq_addr=26*50+9+(idx-27);
            seq_char=speed_digit(seq_speed,(idx==27)?2'd0:(idx==28)?2'd1:2'd2);
        end else if (idx>=32 && idx<38) begin
            seq_addr=28*50+2+(idx-32);
            case(idx-32) 0:seq_char="S";1:seq_char="W";2:seq_char="I";3:seq_char="N";4:seq_char="G";default:seq_char=" ";endcase
        end else if (idx==39) begin
            seq_addr=28*50+9; seq_char=8'h30+seq_swing[1:0];
        end else if (idx>=44 && idx<50) begin
            seq_addr=30*50+2+(idx-44);
            case(idx-44) 0:seq_char="G";1:seq_char="A";2:seq_char="T";3:seq_char="E";default:seq_char=" ";endcase
        end else if (idx>=51 && idx<54) begin
            seq_addr=30*50+9+(idx-51);
            seq_char=gate_digit(seq_gate_sel, (idx==51)?2'd0:(idx==52)?2'd1:2'd2);
        end else if (idx==54) begin
            seq_addr=30*50+12; seq_char="%";
        end else if (idx>=60 && idx<81) begin
            seq_addr=34*50+2+(idx-60);
            case(idx-60)
            0:seq_char="E";1:seq_char="N";2:seq_char="C";3:seq_char="0";4:seq_char=":";
            5:seq_char="R";6:seq_char="O";7:seq_char="W";8:seq_char=" ";9:seq_char="E";
            10:seq_char="N";11:seq_char="C";12:seq_char="1";13:seq_char=":";14:seq_char="S";
            15:seq_char="T";16:seq_char="E";17:seq_char="P";18:seq_char=" ";19:seq_char=">";
            default:seq_char=" ";
            endcase
        end else if (idx>=500 && idx<526) begin
            seq_addr=35*50+2+(idx-500);
            case(idx-500)
            0:seq_char="U";1:seq_char="5";2:seq_char="7";3:seq_char=":";4:seq_char="P";5:seq_char="A";
            6:seq_char="G";7:seq_char="E";8:seq_char=" ";9:seq_char=" ";10:seq_char="U";11:seq_char="5";
            12:seq_char="5";13:seq_char="/";14:seq_char="6";15:seq_char="1";16:seq_char="/";17:seq_char="6";
            18:seq_char="0";19:seq_char="/";20:seq_char="5";21:seq_char="9";22:seq_char=":";23:seq_char="A";
            24:seq_char="R";default:seq_char="M";
            endcase
        end else if (idx>=300 && idx<304) begin
            seq_addr=(4+(idx-300)*5)*50;
            seq_char=8'h31+idx[1:0];
        end else if (idx>=304 && idx<308) begin
            seq_addr=(4+(idx-304)*5)*50+1;
            seq_char=seq_track_ready[idx[1:0]]?"R":" ";
        end else if (idx>=320 && idx<324) begin
            seq_addr=32*50+2+(idx-320);
            case(idx-320) 0:seq_char="N";1:seq_char="O";2:seq_char="T";default:seq_char="E";endcase
        end else if (idx==325 || idx==326 || idx==327) begin
            seq_addr=32*50+7+(idx-325);
            if (seq_selected_row<3'd4 && seq_sel_entry[5]) begin
                if (idx==325) seq_char=seq_note_letter(seq_sel_entry[4:0]);
                else if (idx==326) seq_char=seq_note_accidental(seq_sel_entry[4:0]);
                else seq_char=seq_note_octave(seq_sel_entry[4:0]);
            end else if (idx==325) seq_char="-";
            else seq_char=" ";
        end
    end
    wire [11:0] e_addr = seq_page ? seq_addr : ent[22:11];
    wire [7:0]  e_pay  = ent[7:0];
    wire [7:0]  e_char = seq_page ? seq_char : (ent[23] ? field_char(e_pay[7:3], e_pay[2:0]) : e_pay);

    localparam [1:0] S_CLR = 2'd0, S_RDA = 2'd1, S_CAP = 2'd2, S_WR = 2'd3;
    reg [1:0]  ph;
    reg [12:0] clr;

    initial begin
`include "ui_text_rom.vh"
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= S_CLR; idx <= 10'd0; clr <= 13'd0; rom_addr <= 10'd0;
            we <= 1'b0; waddr <= 12'd0; wdata <= 8'd0;
            busy <= 1'b0; done_cnt <= 9'd0;
        end else begin
            we <= 1'b0;
            if (!busy) begin
                if (start) begin
                    busy     <= 1'b1;
                    idx      <= 10'd0;
                    clr      <= 13'd0;
                    ph       <= S_CLR;
                    rom_addr <= 10'd0;
                end
            end else begin
                case (ph)
                S_CLR: begin
                            we    <= 1'b1;
                            waddr <= clr[11:0];
                            wdata <= 8'h00;
                            if (clr == 13'd4095) begin clr <= 13'd0; ph <= S_RDA; end
                            else                 clr <= clr + 13'd1;
                        end
                S_RDA: begin rom_addr <= idx; ph <= S_CAP; end
                S_CAP: begin ph <= S_WR; end
                default: begin
                            we    <= 1'b1;
                            waddr <= e_addr;
                            wdata <= e_char;
                            done_cnt <= done_cnt + 9'd1;
                            if (idx == NENT - 1) busy <= 1'b0;
                            else begin idx <= idx + 10'd1; ph <= S_RDA; end
                        end
                endcase
            end
        end
    end

endmodule