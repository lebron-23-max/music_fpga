`timescale 1ns / 1ps
//=============================================================================
// piano_envelope_bank.v
// 72-voice piano envelope bank (72 main + 72 detune lanes).
//
// v51 resource optimization:
//   - all mutable per-lane state is packed into one 144 x 36-bit BSRAM
//   - a simple-dual-port RAM separates the scan write port from a shared
//     read port used by both the scan and the piano TDM envelope query
//   - the former 144-way full-width output mux and per-lane state registers are
//     removed, while the ADSR transition equations are kept unchanged
//=============================================================================
module piano_envelope_bank #(parameter integer NUM_VOICES = 72) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          sample_tick,
    input  wire [NUM_VOICES-1:0] voice_gate,
    input  wire [7:0]    adsr_a,
    input  wire [7:0]    adsr_d,
    input  wire [7:0]    adsr_s,
    input  wire [7:0]    adsr_r,
    input  wire [8:0]    env_rd_addr,
    input  wire          env_rd_req,
    output wire [15:0]   env_rd_data,
    output reg  [NUM_VOICES-1:0] env_sounding_mask
);
    localparam [2:0] IDLE    = 3'd0;
    localparam [2:0] ATTACK  = 3'd1;
    localparam [2:0] HOLD    = 3'd2;
    localparam [2:0] SUSTAIN = 3'd3;
    localparam [2:0] TAIL    = 3'd4;
    localparam [2:0] RELEASE = 3'd5;
    localparam integer LANES = NUM_VOICES * 2;
    localparam [8:0] LAST_SLOT = LANES - 1;

    // ADSR mapping tables are sampled once per audio sample.
    wire [15:0] lut_a, lut_d, lut_s, lut_r, lut_t;
    piano_adsr_lut u_adsr_lut (
        .clk(clk), .a(adsr_a), .d(adsr_d), .s(adsr_s), .r(adsr_r),
        .va(lut_a), .vd(lut_d), .vs(lut_s), .vr(lut_r), .vt(lut_t)
    );
    wire [15:0] ATTACK_MAIN    = lut_a;
    wire [15:0] ATTACK_DETUNE  = (lut_a == 16'hFFFF) ? 16'hFFFF : (lut_a + 16'd1);
    wire [16:0] TAIL_START_MAIN = {1'b0, lut_t};
    wire [16:0] TAIL_START_DETUNE = TAIL_START_MAIN - 17'd1;
    wire [15:0] TAIL_FLOOR      = lut_s;
    wire [15:0] TAIL_DECAY_MAIN = lut_d;
    wire [15:0] TAIL_DECAY_DETUNE = (lut_d == 16'hFFFF) ? 16'hFFFF : (lut_d + 16'd1);
    wire [15:0] RELEASE_MAIN    = lut_r;
    wire [15:0] RELEASE_DETUNE  = (lut_r > 16'd1) ? (lut_r - 16'd1) : 16'd1;

    // Packed lane: {env_value[15:0], hold_count[16:0], state[2:0], gate_d}
    reg [8:0]  scan_addr;
    reg        scan_we;
    reg [35:0] scan_wdata;
    wire [35:0] ram_rdata;
    wire [8:0] ram_raddr = env_rd_req ? env_rd_addr : scan_addr;
    wire [35:0] scan_rdata = ram_rdata;

    piano_envelope_state_ram #(.DEPTH(LANES), .WIDTH(36)) u_state_ram (
        .clk(clk), .waddr(scan_addr), .we(scan_we), .wdata(scan_wdata),
        .raddr(ram_raddr), .rdata(ram_rdata)
    );
    assign env_rd_data = ram_rdata[35:20];

    reg [1:0] scan_phase;
    reg       scan_active;
    reg       scan_resume_wait;
    reg [8:0] scan_slot;

    reg [2:0]  cur_state;
    reg [15:0] cur_hold;
    reg [15:0] cur_env;
    reg        cur_gate_d;
    reg        cur_gate_now;
    reg        cur_detune;
    reg [8:0]  cur_slot;

    reg [15:0] attack_main_q;
    reg [15:0] attack_detune_q;
    reg [16:0] tail_start_main_q;
    reg [16:0] tail_start_detune_q;
    reg [15:0] tail_floor_q;
    reg [15:0] tail_coeff_main_q;
    reg [15:0] tail_coeff_detune_q;
    reg [15:0] release_main_q;
    reg [15:0] release_detune_q;
    reg [15:0] tail_step_q;
    reg [15:0] release_step_q;

    // Compute the per-lane multiplicative step from the word currently being
    // read. Using cur_env here would register the previous lane's step because
    // cur_env is also updated with a nonblocking assignment.
    wire [15:0] scan_env_now = scan_rdata[35:20];
    wire [31:0] scan_tail_product =
        {16'd0, scan_env_now} * (scan_slot[0] ? tail_coeff_detune_q : tail_coeff_main_q);
    wire [31:0] scan_release_product =
        {16'd0, scan_env_now} * (scan_slot[0] ? release_detune_q : release_main_q);
    wire [15:0] tail_step_now = (scan_tail_product[31:16] == 16'd0) ? 16'd1 : scan_tail_product[31:16];
    wire [15:0] release_step_now = (scan_release_product[31:16] == 16'd0) ? 16'd1 : scan_release_product[31:16];
    wire [15:0] attack_step = cur_detune ? attack_detune_q : attack_main_q;
    wire [16:0] tail_start = cur_detune ? tail_start_detune_q : tail_start_main_q;
    wire [16:0] tail_start_last = (tail_start == 17'd0) ? 17'd0 : (tail_start - 17'd1);

    reg [2:0]  next_state;
    reg [15:0] next_hold;
    reg [15:0] next_env;

    always @* begin
        next_state = cur_state;
        next_hold  = cur_hold;
        next_env   = cur_env;

        if (cur_gate_now && !cur_gate_d) begin
            next_state = ATTACK;
            next_hold  = 16'd0;
            next_env   = attack_step;
        end else if (!cur_gate_now && (cur_state != IDLE) && (cur_state != RELEASE)) begin
            next_state = RELEASE;
            next_hold  = 16'd0;
        end else begin
            case (cur_state)
            ATTACK: begin
                if (cur_env > (16'hFFFF - attack_step)) begin
                    next_env   = 16'hFFFF;
                    next_state = HOLD;
                end else begin
                    next_env = cur_env + attack_step;
                end
            end
            HOLD: begin
                if (cur_hold >= tail_start_last) begin
                    next_state = TAIL;
                    next_hold  = 16'd0;
                end else begin
                    next_hold = cur_hold + 16'd1;
                end
            end
            TAIL: begin
                if (cur_env <= (tail_floor_q + tail_step_q)) begin
                    next_env   = tail_floor_q;
                    next_state = (tail_floor_q == 16'd0) ? IDLE : SUSTAIN;
                end else begin
                    next_env = cur_env - tail_step_q;
                end
            end
            SUSTAIN: begin
                next_env = tail_floor_q;
            end
            RELEASE: begin
                if (cur_env <= release_step_q) begin
                    next_env   = 16'd0;
                    next_state = IDLE;
                end else begin
                    next_env = cur_env - release_step_q;
                end
            end
            default: next_env = 16'd0;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_phase <= 2'd0;
            scan_active <= 1'b0;
            scan_resume_wait <= 1'b0;
            scan_slot <= 9'd0;
            scan_addr <= 9'd0;
            scan_we <= 1'b0;
            scan_wdata <= 36'd0;
            env_sounding_mask <= {NUM_VOICES{1'b0}};
            cur_state <= IDLE;
            cur_hold <= 16'd0;
            cur_env <= 16'd0;
            cur_gate_d <= 1'b0;
            cur_gate_now <= 1'b0;
            cur_detune <= 1'b0;
            cur_slot <= 9'd0;
            tail_step_q <= 16'd1;
            release_step_q <= 16'd1;
            attack_main_q <= 16'd269;
            attack_detune_q <= 16'd270;
            tail_start_main_q <= 17'd48_828;
            tail_start_detune_q <= 17'd48_827;
            tail_floor_q <= 16'd16384;
            tail_coeff_main_q <= 16'd8;
            tail_coeff_detune_q <= 16'd9;
            release_main_q <= 16'd16;
            release_detune_q <= 16'd15;
        end else begin
            scan_we <= 1'b0;

            if (sample_tick) begin
                attack_main_q       <= ATTACK_MAIN;
                attack_detune_q     <= ATTACK_DETUNE;
                tail_start_main_q   <= TAIL_START_MAIN;
                tail_start_detune_q <= TAIL_START_DETUNE;
                tail_floor_q        <= TAIL_FLOOR;
                tail_coeff_main_q   <= TAIL_DECAY_MAIN;
                tail_coeff_detune_q <= TAIL_DECAY_DETUNE;
                release_main_q      <= RELEASE_MAIN;
                release_detune_q    <= RELEASE_DETUNE;
                scan_active <= 1'b1;
                scan_resume_wait <= 1'b0;
                scan_phase  <= 2'd0;
                scan_slot   <= 9'd0;
                scan_addr   <= 9'd0;
            end else if (scan_active) begin
                // Envelope reads from the piano TDM own the shared read port
                // for these cycles; pause the background scan without losing
                // its current phase or asserting a write.
                if (env_rd_req) begin
                    scan_resume_wait <= 1'b1;
                end else if (scan_resume_wait) begin
                    // Reissue the interrupted scan address and let its synchronous
                    // read data become valid before continuing the RMW sequence.
                    scan_resume_wait <= 1'b0;
                end else begin
                case (scan_phase)
                2'd0: begin
                    // The address was issued on the previous cycle.
                    scan_phase <= 2'd1;
                end
                2'd1: begin
                    cur_state    <= scan_rdata[3:1];
                    cur_hold     <= scan_rdata[19:4];
                    cur_env      <= scan_rdata[35:20];
                    cur_gate_d   <= scan_rdata[0];
                    cur_gate_now <= ~voice_gate[scan_slot[8:1]];
                    cur_detune   <= scan_slot[0];
                    cur_slot     <= scan_slot;
                    tail_step_q    <= tail_step_now;
                    release_step_q <= release_step_now;
                    scan_phase <= 2'd2;
                end
                2'd2: begin
                    scan_addr  <= scan_slot;
                    scan_wdata <= {next_env, next_hold, next_state, cur_gate_now};
                    scan_we    <= 1'b1;
                    if (!scan_slot[0])
                        env_sounding_mask[scan_slot[8:1]] <= (next_env > 16'd64);
                    scan_phase <= 2'd3;
                end
                default: begin
                    // Write completes on this edge. Advance to the next lane.
                    if (scan_slot == LAST_SLOT) begin
                        scan_active <= 1'b0;
                        scan_phase  <= 2'd0;
                    end else begin
                        scan_slot <= scan_slot + 9'd1;
                        scan_addr <= scan_slot + 9'd1;
                        scan_phase <= 2'd0;
                    end
                end
                endcase
                end
            end
        end
    end
endmodule