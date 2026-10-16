// SPDX-License-Identifier: GPL-3.0-or-later
// Sampling, triggering and capture control.
//
// Stream mode pushes every sample straight to the output FIFO and stops with
// the overflow flag set if the FIFO is full.  Buffer mode records into a ring
// (block RAM or SDRAM, chosen by the caller through the mem_* ports), waits
// for the trigger sequence, records `post` more samples and then replays the
// ring, oldest sample first.
module capture (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  probe,         // already synchronised to clk
    input  wire [31:0] depth,         // usable ring depth in samples

    input  wire        run_stream,
    input  wire        arm,           // pulse: start a buffered capture
    input  wire        force_trig,
    input  wire [31:0] divider,       // sample every divider+1 clocks
    input  wire [31:0] pre,           // samples required before triggering
    input  wire [31:0] post,          // samples recorded after the trigger
    input  wire [1:0]  nstages,       // trigger stages in use minus one
    input  wire [31:0] stage0, stage1, stage2, stage3,   // {fall, rise, value, mask}

    output reg         armed = 1'b0,
    output reg         triggered = 1'b0,
    output reg         done = 1'b0,
    output reg         overflow = 1'b0,
    output reg  [31:0] trigpos = 0,   // samples before the trigger in the replay

    output reg  [7:0]  out = 0,
    output reg         out_wr = 1'b0,
    input  wire        out_full,

    // ring buffer
    output reg         mem_start = 1'b0,
    output reg         mem_wr = 1'b0,
    output reg  [7:0]  mem_wdata = 0,
    output reg         mem_stop = 1'b0,
    input  wire        mem_drained,
    input  wire        mem_overflow,
    output reg         mem_play = 1'b0,
    output reg  [31:0] mem_play_addr = 0,
    output reg  [31:0] mem_play_len = 0,
    input  wire [7:0]  mem_q,
    input  wire        mem_q_valid,
    output wire        mem_q_rd,
    input  wire        mem_play_done
);
    // ---------------------------------------------------------- sample tick
    reg [31:0] divcnt = 0;
    reg        tick = 1'b0;
    reg [7:0]  s = 0, s_prev = 0;
    always @(posedge clk) begin
        tick <= 1'b0;
        if (rst || divcnt == 0) begin
            divcnt <= divider;
            tick   <= !rst;
            s      <= probe;
            s_prev <= s;
        end else begin
            divcnt <= divcnt - 1'b1;
        end
    end

    // ---------------------------------------------------------- trigger
    reg  [1:0]  stage = 0;
    wire [31:0] cfg = (stage == 2'd0) ? stage0 : (stage == 2'd1) ? stage1 :
                      (stage == 2'd2) ? stage2 : stage3;
    wire [7:0] t_mask = cfg[7:0], t_value = cfg[15:8], t_rise = cfg[23:16], t_fall = cfg[31:24];
    wire match = ((s & t_mask) == (t_value & t_mask)) &&
                 ((~s_prev & s & t_rise) == t_rise) &&
                 ((s_prev & ~s & t_fall) == t_fall);

    // ---------------------------------------------------------- control
    localparam IDLE = 3'd0, FILL = 3'd1, WAIT = 3'd2, POST = 3'd3,
               DRAIN = 3'd4, PLAY = 3'd5, PLAY2 = 3'd6;
    reg [2:0]  state = IDLE;
    reg [31:0] filled = 0, remain = 0, wptr = 0;
    reg        rec = 1'b0;                 // write the current sample
    reg [7:0]  s_rec = 0;

    // Pre-trigger samples that still fit beside `post` in the ring.
    wire [31:0] room_pre = (post >= depth) ? 32'd0 : (depth - post);
    wire [31:0] keep_pre = (filled < room_pre) ? filled : room_pre;
    wire [31:0] total    = (trigpos + post > depth) ? depth : (trigpos + post);

    assign mem_q_rd = (state == PLAY2) && !out_full && !out_wr;

    always @(posedge clk) begin
        out_wr    <= 1'b0;
        mem_start <= 1'b0;
        mem_stop  <= 1'b0;
        mem_play  <= 1'b0;
        mem_wr    <= rec;
        s_rec     <= s;                    // s may change every cycle at full rate
        mem_wdata <= s_rec;                // the sample that set `rec`
        rec       <= 1'b0;
        if (mem_wr) wptr <= wptr + 1'b1;

        if (rst) begin
            state <= IDLE; armed <= 1'b0; triggered <= 1'b0; done <= 1'b0;
            overflow <= 1'b0; stage <= 0;
        end else case (state)
        IDLE: begin
            if (arm) begin
                state <= FILL; armed <= 1'b1; triggered <= 1'b0; done <= 1'b0;
                overflow <= 1'b0; filled <= 0; stage <= 0; wptr <= 0; mem_start <= 1'b1;
            end else if (run_stream && tick && !overflow) begin
                if (out_full) overflow <= 1'b1;
                else begin out <= s; out_wr <= 1'b1; end
            end else if (!run_stream) begin
                overflow <= 1'b0;
            end
        end
        FILL: begin                        // collect the pre-trigger minimum
            if (tick) begin
                rec    <= 1'b1;
                filled <= filled + 1'b1;
            end
            if (filled >= pre) state <= WAIT;
        end
        WAIT: begin
            if (force_trig || (tick && match && stage == nstages)) begin
                // A sample that fires the trigger is the first of `post`.
                triggered <= 1'b1;
                trigpos   <= keep_pre;
                if (tick && post != 0) begin
                    rec    <= 1'b1;
                    remain <= post - 1'b1;
                end else begin
                    remain <= post;
                end
                state <= POST;
            end else if (tick) begin
                rec <= 1'b1;
                if (filled < depth) filled <= filled + 1'b1;
                if (match) stage <= stage + 1'b1;
            end
        end
        POST: begin
            if (remain == 0) begin
                if (!rec && !mem_wr) begin mem_stop <= 1'b1; state <= DRAIN; end
            end else if (tick) begin
                rec    <= 1'b1;
                remain <= remain - 1'b1;
            end
        end
        DRAIN: if (!mem_stop && mem_drained) begin
            if (mem_overflow) overflow <= 1'b1;
            state <= PLAY;
        end
        PLAY: begin
            mem_play      <= 1'b1;
            mem_play_addr <= wptr - total;
            mem_play_len  <= total;
            state         <= PLAY2;
        end
        PLAY2: begin
            if (mem_q_rd && mem_q_valid) begin
                out <= mem_q; out_wr <= 1'b1;
            end else if (!mem_play && mem_play_done) begin
                done <= 1'b1; armed <= 1'b0; state <= IDLE;
            end
        end
        default: state <= IDLE;
        endcase
    end
endmodule
