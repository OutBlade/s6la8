// SPDX-License-Identifier: GPL-3.0-or-later
// Sampling, triggering and capture control.
//
// Stream mode pushes every sample straight to the output FIFO and stops with
// the overflow flag set if the FIFO is full.  Buffer mode records into a
// block-RAM ring, waits for the trigger sequence, records `post` more
// samples and then replays the ring, oldest sample first.
module capture #(
    parameter ABITS = 15              // ring depth = 2**ABITS samples
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  probe,         // already synchronised to clk

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
    input  wire        out_full
);
    localparam [31:0] DEPTH = 32'd1 << ABITS;

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

    // ---------------------------------------------------------- ring buffer
    reg [7:0] ring [0:(1<<ABITS)-1];
    reg [ABITS-1:0] wptr = 0, rptr = 0;
    reg [7:0]       ring_q = 0, ring_d = 0;
    reg             ring_we = 1'b0;
    always @(posedge clk) begin
        if (ring_we) ring[wptr] <= ring_d;
        ring_q <= ring[rptr];
    end

    localparam IDLE = 3'd0, FILL = 3'd1, WAIT = 3'd2, POST = 3'd3,
               PLAY = 3'd4, PLAY2 = 3'd5;
    reg [2:0]  state = IDLE;
    reg [31:0] filled = 0, remain = 0, replay = 0;
    reg        q_valid = 1'b0;

    // Pre-trigger samples that still fit beside `post` in the ring.
    wire [31:0] room_pre = (post >= DEPTH) ? 32'd0 : (DEPTH - post);
    wire [31:0] keep_pre = (filled < room_pre) ? filled : room_pre;
    wire [31:0] total    = (trigpos + post > DEPTH) ? DEPTH : (trigpos + post);

    always @(posedge clk) begin
        out_wr  <= 1'b0;
        ring_we <= 1'b0;
        ring_d  <= s;                      // s may change every cycle at full rate
        if (ring_we) wptr <= wptr + 1'b1;

        if (rst) begin
            state <= IDLE; armed <= 1'b0; triggered <= 1'b0; done <= 1'b0;
            overflow <= 1'b0; stage <= 0; q_valid <= 1'b0;
        end else case (state)
        IDLE: begin
            if (arm) begin
                state <= FILL; armed <= 1'b1; triggered <= 1'b0; done <= 1'b0;
                overflow <= 1'b0; filled <= 0; stage <= 0; wptr <= 0;
            end else if (run_stream && tick && !overflow) begin
                if (out_full) overflow <= 1'b1;
                else begin out <= s; out_wr <= 1'b1; end
            end else if (!run_stream) begin
                overflow <= 1'b0;
            end
        end
        FILL: begin                        // collect the pre-trigger minimum
            if (tick) begin
                ring_we <= 1'b1;
                filled  <= filled + 1'b1;
            end
            if (filled >= pre) state <= WAIT;
        end
        WAIT: begin
            if (force_trig || (tick && match && stage == nstages)) begin
                // A sample that fires the trigger is the first of `post`.
                triggered <= 1'b1;
                trigpos   <= keep_pre;
                if (tick && post != 0) begin
                    ring_we <= 1'b1;
                    remain  <= post - 1'b1;
                end else begin
                    remain  <= post;
                end
                state <= POST;
            end else if (tick) begin
                ring_we <= 1'b1;
                if (filled < DEPTH) filled <= filled + 1'b1;
                if (match) stage <= stage + 1'b1;
            end
        end
        POST: begin
            if (remain == 0) state <= PLAY;
            else if (tick) begin
                ring_we <= 1'b1;
                remain  <= remain - 1'b1;
            end
        end
        PLAY: if (!ring_we) begin          // wptr has settled
            replay  <= total;
            rptr    <= wptr - total[ABITS-1:0];
            q_valid <= 1'b0;
            state   <= PLAY2;
        end
        PLAY2: begin
            if (replay == 0) begin
                done <= 1'b1; armed <= 1'b0; state <= IDLE;
            end else if (!q_valid) begin
                q_valid <= 1'b1;           // ring_q holds ring[rptr] next cycle
            end else if (!out_full && !out_wr) begin
                out <= ring_q; out_wr <= 1'b1;
                rptr <= rptr + 1'b1; replay <= replay - 1'b1; q_valid <= 1'b0;
            end
        end
        default: state <= IDLE;
        endcase
    end
endmodule
