`timescale 1ns / 1ps
//=============================================================================
// scope_capture.v —— 最终音频输出的采集（跨时钟 + 512 点示波缓冲）
//=============================================================================
// ★ 资源修复（2026-10-14，见 context-suammary.md 第 17 节）：
//   旧实现里 512x16 的显示缓冲有**两个写入源**（capture 写 + 复位后清零写，
//   分在两个 always 块里），Gowin 无法推断 BSRAM，把它展开成
//   512x16 = 8192 个触发器 + 512:1 的 16 位读多路器
//   ⇒ 实测 13508 LUT + 8873 REG，占满 CLS（87%）导致 PNR 布线失败（261 nets）。
//   修复：清零与采集**共用同一个写口**（mux 选地址/数据/使能），
//   512x16 推断为 1 块 BSRAM（SDPB）。
//
// ★ 跨时钟做法（保持不变，原因见下）：
//   音频域（clk, 50 MHz）把"最新采样"和"采样序号"写进一块**双时钟 BSRAM**
//   （0..15 = 最近 16 个采样的循环缓冲，16 = 采样序号，17 = 基频周期估计）；
//   显示域（pix_clk, 40 MHz）在自己的时钟域里轮询读口：读到序号变了就去读
//   (序号-1) 对应的采样，写进 512 点显示缓冲。
//   为什么不用"保持寄存器 + 2FF 同步"那一版：那会产生真实的跨域组合路径，
//   PNR 报 571 个端点违规、clk_50m Fmax 掉到 48.3 MHz（详见第 9 节）。
//
// ★ 新增：基频周期估计（过零间隔 + 一阶平滑），供李萨如图形选延迟
//   （delay ≈ 周期/4 ⇒ x-y 相位差 ~90°，椭圆最饱满）。
//=============================================================================
module scope_capture (
    input  wire               clk,           // 50 MHz 音频域
    input  wire               sample_tick,   // 48.828 kHz 音频采样脉冲
    input  wire signed [15:0] sample_in,     // 最终输出 audio_sample

    input  wire               pix_clk,       // 40 MHz 显示域
    input  wire               pix_rst_n,
    input  wire               new_frame,     // 帧起始脉冲（pix 域）
    input  wire [8:0]         raddr,         // 显示缓冲读地址（波形/李萨如）
    output reg  signed [15:0] rdata,
    output reg  [8:0]         cap_ptr,       // 本场锁存的捕获指针
    output reg  [15:0]        peak_lat,      // 本场锁存的|峰值|（自动量程用）
    output reg  [15:0]        period_lat     // 本场锁存的基频周期（单位：采样数）
);
    localparam integer DEPTH = 256;

    //=================================================================
    // 0) 基频周期估计已删除（2026-10-18）
    //    李萨如图形早已改为内置 2:3 相位累加器，不再使用 period；
    //    原 per_avg 的 16 位时钟使能路径是 clk_50m 的最差 setup 路径，
    //    这里保留 period_lat 输出但恒为 0，兼容旧调试 TB。
    //=================================================================
    //=================================================================
    // 1) 跨时钟缓冲（双时钟 BSRAM，写口 clk 域 / 读口 pix 域）
    //=================================================================
    reg [15:0] sh_mem [0:31];        // 0..15 采样，16 序号，17 周期
    reg        we;
    reg [5:0]  waddr;
    reg [15:0] wdata;
    reg [3:0]  wptr;
    reg [15:0] seq;
    reg [1:0]  wst;

    // 仿真/上电都要有确定初值：seq 未初始化会让写出的序号一直是 X，
    // 显示域永远等不到"序号变化"，整条采集链静默失效（上板因为 FF 上电为 0 才正常）。
    initial begin
        wptr = 4'd0;
        seq  = 16'd0;
        wst  = 2'd0;
    end

    // 一次采样分三拍写：采样 -> 周期 -> 序号（序号最后写，显示域才可能看到）
    always @(posedge clk) begin
        we <= 1'b0;
        case (wst)
        2'd0: if (sample_tick) begin
                  we    <= 1'b1;
                  waddr <= {2'b00, wptr};
                  wdata <= sample_in;
                  wst   <= 2'd1;
              end
        2'd1: begin
                  we    <= 1'b1;
                  waddr <= 6'd17;
                  wdata <= 16'd0;      // 周期估计已删除
                  wst   <= 2'd2;
              end
        default: begin
                  we    <= 1'b1;
                  waddr <= 6'd16;
                  wdata <= seq + 16'd1;
                  seq   <= seq + 16'd1;
                  wptr  <= wptr + 4'd1;
                  wst   <= 2'd0;
              end
        endcase
    end

    // 写口（clk 域）
    always @(posedge clk) if (we) sh_mem[waddr] <= wdata;

    // 显示域读口
    reg  [5:0]  rd_a;
    reg  [15:0] rd_q;
    always @(posedge pix_clk) rd_q <= sh_mem[rd_a];

    // 轮询 FSM：读序号 -> 有新值就读采样/周期 -> 产生 capture
    reg [2:0]  pst;
    reg [15:0] seen_seq;
    reg        capture;
    reg signed [15:0] smp;
    reg [15:0] per_new;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            pst <= 3'd0; rd_a <= 6'd16; seen_seq <= 16'd0;
            capture <= 1'b0; smp <= 16'sd0; per_new <= 16'd0;
        end else begin
            capture <= 1'b0;
            case (pst)
            3'd0: begin rd_a <= 6'd16;  pst <= 3'd1; end
            3'd1: begin                 pst <= 3'd2; end          // 等序号回来
            3'd2: begin
                      if (rd_q != seen_seq) begin
                          seen_seq <= rd_q;
                          rd_a     <= {2'b00, (rd_q[3:0] - 4'd1)};
                          pst      <= 3'd3;
                      end else begin
                          pst <= 3'd0;
                      end
                  end
            3'd3: begin                 pst <= 3'd4; end          // 等采样回来
            3'd4: begin
                      smp  <= $signed(rd_q);
                      rd_a <= 6'd17;
                      pst  <= 3'd5;
                  end
            3'd5: begin                 pst <= 3'd6; end          // 等周期回来
            default: begin
                      per_new <= rd_q;
                      capture <= 1'b1;
                      pst     <= 3'd0;
                  end
            endcase
        end
    end

    //=================================================================
    // 2) 显示域 512 点缓冲（★ 单写口 + 单读口 ⇒ BSRAM）
    //=================================================================
    // Two 512-sample banks share one 1024x16 BSRAM. Capture writes one bank
    // continuously while video reads the other frozen bank.
    reg signed [15:0] mem [0:2*DEPTH-1];
    reg [7:0]         wptr_d;
    reg               write_bank, display_bank;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            wptr_d <= 8'd0;
        end else if (new_frame) begin
            wptr_d <= 8'd0;
        end else if (capture) begin
            wptr_d <= wptr_d + 8'd1;
        end
    end

    // 复位后先清 0：★ 必须和采集走**同一个写口**（用 mux 选），
    //   否则综合器无法推断 BSRAM（这是 13508 LUT 的根因）。
    reg [10:0] clr_cnt;
    reg        clr_done;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            clr_cnt  <= 11'd0;
            clr_done <= 1'b0;
        end else if (!clr_done) begin
            if (clr_cnt == 2*DEPTH - 1) clr_done <= 1'b1;
            clr_cnt <= clr_cnt + 11'd1;
        end
    end

    reg               mem_we;
    reg [9:0]         mem_waddr;
    reg signed [15:0] mem_wdata;

    always @(posedge pix_clk) begin
        if (!clr_done) begin
            mem_we    <= 1'b1;
            mem_waddr <= clr_cnt[9:0];
            mem_wdata <= 16'sd0;
        end else begin
            mem_we    <= capture;
            mem_waddr <= {1'b0, write_bank, wptr_d};
            mem_wdata <= smp;
        end
    end

    always @(posedge pix_clk) if (mem_we) mem[mem_waddr] <= mem_wdata;

    always @(posedge pix_clk) rdata <= mem[{display_bank, raddr[7:0]}];

    //=================================================================
    // 3) 每场锁存捕获指针 / 周期
    //=================================================================
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            cap_ptr      <= 9'd0;
            display_bank <= 1'b0;
            write_bank   <= 1'b0;
            period_lat   <= 16'd0;
        end else if (new_frame) begin
            cap_ptr      <= {1'b0, wptr_d};
            display_bank <= write_bank;
            write_bank   <= ~write_bank;
            period_lat   <= per_new;
        end
    end

    //=========================================================================
    // 自动量程的峰值检测：跟踪 |采样| 的包络（慢释放），每场锁存一次
    //   不同音色/不同音的输出幅度能差 10 倍以上，固定缩放会让弱音色的波形和
    //   李萨如缩成一个小点。这里相当于真示波器的"自动量程"。
    //=========================================================================
    wire [15:0] smp_abs = smp[15] ? (~smp + 16'd1) : smp;

    reg [15:0] peak_track;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)     peak_track <= 16'd0;
        else if (capture) begin
            if (smp_abs > peak_track)        peak_track <= smp_abs;
            // 释放时间常数约 1024 个采样（21ms）：跟着当前音量走，衰减中的音也保持满画幅
            // 2026-10-17：必须能衰到 0（否则静音时仍残留 ~256，李萨如永远不消失）。
            //   每采样至少减 1，保证 0 可达；信号一来立刻跟随。
            else if (peak_track > 16'd1)     peak_track <= peak_track - ((peak_track >> 10) + 16'd1);
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)     peak_lat <= 16'd0;
        else if (new_frame) peak_lat <= peak_track;
    end

endmodule
