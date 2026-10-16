// SPDX-License-Identifier: GPL-3.0-or-later
// Sample ring buffer in SDRAM, with the same interface as ring_bram.
//
// Write side: one 8-bit sample per `wr` (at most one per clock).  Pairs of
// samples become 16-bit words (even sample in the low byte), go through a
// 512-word FIFO and are written in bursts.  `stop` writes out what is left.
// Play side: `play` replays `play_len` samples starting at sample
// `play_addr` as a first-word fall-through byte stream.
module ring_sdram #(
    parameter SABITS    = 25,           // ring depth 2**SABITS samples
    parameter INIT_WAIT = 20000
) (
    input  wire              clk,
    input  wire              rst,               // power-up: also re-initialises the SDRAM
    input  wire              soft_rst,          // abandons a capture or replay only
    output wire              ready,             // SDRAM initialised

    input  wire              start,             // pulse: empty the ring
    input  wire              wr,
    input  wire [7:0]        wdata,
    output reg               overflow = 1'b0,   // a sample was lost (sticky until start)
    input  wire              stop,              // pulse: flush to memory
    output wire              drained,           // everything written since stop

    input  wire              play,
    input  wire [SABITS-1:0] play_addr,
    input  wire [SABITS:0]   play_len,
    output wire [7:0]        q,
    output wire              q_valid,
    input  wire              q_rd,
    output wire              play_done,

    output wire              sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output wire [1:0]        sd_ba,
    output wire [12:0]       sd_a,
    output wire [1:0]        sd_dqm,
    output wire [15:0]       sd_dq_out,
    output wire              sd_dq_oe,
    input  wire [15:0]       sd_dq_in
);
    localparam WABITS = SABITS - 1;
    wire [15:0] c_rdata;
    wire        c_rvalid, ctrl_idle;

    // ---------------------------------------------------------------- write
    reg  [7:0]  lo = 0;
    reg         half = 1'b0;                    // a low byte is waiting
    reg         wf_wr = 1'b0;
    reg  [15:0] wf_d = 0;
    reg         flushing = 1'b0, writing = 1'b0;
    reg  [3:0]  settle = 0;
    wire [15:0] wf_q;
    wire        wf_valid, wf_pop, wf_full;
    wire [9:0]  wf_count;

    always @(posedge clk) begin
        wf_wr <= 1'b0;
        if (rst || soft_rst || start) begin
            half <= 1'b0; overflow <= 1'b0; flushing <= 1'b0; writing <= start && !rst && !soft_rst;
        end else if (wr && writing && !flushing) begin
            if (!half) begin
                lo <= wdata; half <= 1'b1;
            end else begin
                wf_d <= {wdata, lo}; wf_wr <= 1'b1; half <= 1'b0;
                if (wf_full) overflow <= 1'b1;
            end
        end else if (stop && writing) begin
            flushing <= 1'b1;
            if (half) begin wf_d <= {8'h00, lo}; wf_wr <= 1'b1; half <= 1'b0; end
        end
        // let the last FIFO write become visible before the final partial burst
        if (!flushing) settle <= 0;
        else if (settle != 4'd15) settle <= settle + 1'b1;
        if (flushing && settle == 4'd15 && wf_count == 0 && ctrl_idle) begin
            writing <= 1'b0;
        end
    end
    assign drained = !writing;

    sync_fifo #(.WIDTH(16), .ABITS(9)) u_wf (
        .clk(clk), .rst(rst || soft_rst || start), .wr(wf_wr), .wdata(wf_d), .rd(wf_pop),
        .q(wf_q), .valid(wf_valid), .count(wf_count), .full(wf_full));

    // ---------------------------------------------------------------- play
    reg              playing = 1'b0, rreq = 1'b0;
    reg  [2:0]       skip_words = 0;
    reg              skip_byte = 1'b0, hi_next = 1'b0;
    reg  [SABITS:0]  remain = 0;
    reg              rf_rst = 1'b0;
    wire [15:0]      rf_q;
    wire             rf_valid, rf_full;
    wire [9:0]       rf_count;
    wire [WABITS-1:0] word0 = play_addr[SABITS-1:1];

    wire out_byte_valid = playing && rf_valid && skip_words == 0 && remain != 0;
    assign q         = hi_next ? rf_q[15:8] : rf_q[7:0];
    assign q_valid   = out_byte_valid && !(skip_byte && !hi_next);
    wire   take      = q_valid && q_rd;
    wire   drop      = playing && rf_valid && (skip_words != 0 || (skip_byte && !hi_next));
    wire   rf_pop    = drop ? (skip_words != 0 || hi_next) : (take && hi_next);
    assign play_done = !playing && !rreq;

    always @(posedge clk) begin
        rf_rst <= 1'b0;
        if (rst || soft_rst || start) begin
            playing <= 1'b0; rreq <= 1'b0; rf_rst <= 1'b1;
        end else if (play) begin
            rreq       <= 1'b1;             // start once the controller is idle
            skip_words <= word0[2:0];
            skip_byte  <= play_addr[0];
            hi_next    <= 1'b0;
            remain     <= play_len;
            rf_rst     <= 1'b1;
        end else if (rreq && ctrl_idle) begin
            rreq <= 1'b0; playing <= (remain != 0);
        end else if (playing) begin
            if (drop) begin
                if (skip_words != 0) skip_words <= skip_words - 1'b1;
                else begin skip_byte <= 1'b0; hi_next <= 1'b1; end
            end else if (take) begin
                hi_next <= !hi_next;
                remain  <= remain - 1'b1;
                if (remain == 1) begin playing <= 1'b0; rf_rst <= 1'b1; end
            end
        end
    end

    sync_fifo #(.WIDTH(16), .ABITS(9)) u_rf (
        .clk(clk), .rst(rst || rf_rst), .wr(c_rvalid && playing), .wdata(c_rdata), .rd(rf_pop),
        .q(rf_q), .valid(rf_valid), .count(rf_count), .full(rf_full));

    reg rstart_p = 1'b0;
    always @(posedge clk) rstart_p <= rreq && ctrl_idle;

    sdram_ctrl #(.WABITS(WABITS), .INIT_WAIT(INIT_WAIT)) u_ctrl (
        .clk(clk), .rst(rst), .ready(ready),
        .wmode(writing), .wflush(flushing && settle == 4'd15), .wcount(wf_count), .wdata(wf_q),
        .wpop(wf_pop), .wreset(start), .waddr(),
        .rmode(playing), .rstart(rreq && ctrl_idle), .rstart_addr({word0[WABITS-1:3], 3'b000}),
        .rspace(10'd512 - rf_count), .rdata(c_rdata), .rvalid(c_rvalid),
        .idle(ctrl_idle),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe),
        .sd_dq_in(sd_dq_in));
endmodule
