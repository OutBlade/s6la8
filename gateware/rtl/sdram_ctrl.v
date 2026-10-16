// SPDX-License-Identifier: GPL-3.0-or-later
// SDR SDRAM controller for one MT48LC16M16A2 (4 banks x 8192 rows x 512
// columns x 16 bit), streaming only: it either writes a word stream to
// consecutive addresses or reads consecutive addresses into a word stream.
//
// Bursts of 8 words, CAS latency 3.  A row stays open while the stream
// stays in it and data keeps coming, so a sequential write sustains about
// 95 % of the clock rate.  Word address = {bank, row, column}; streams wrap
// at 2**WABITS words.
//
// Timing at 100 MHz: tRCD, tRP and tWR 2 clocks, tRFC 8, tMRD 2; one auto
// refresh at least every REFI clocks (750 = 7.5 us; the part needs 8192
// refreshes per 64 ms, i.e. one per 7.8 us).  Rows are closed before each
// refresh, which also bounds tRAS.
//
// The SDRAM clock is the system clock inverted (forwarded by the caller), so
// the SDRAM samples commands half a clock after they change.  Read data for
// the clock after the READ command's edge n is valid from about
// n + CL - 1 + tAC to n + CL + tOH (plus the clock's way out to the SDRAM,
// 2 to 4 ns); the caller registers DQ with a 225-degree clock inside that
// window into `sd_dq_in`, and the word appears in `rdata` CL + 1 clocks
// after the READ command.
module sdram_ctrl #(
    parameter WABITS    = 24,
    parameter INIT_WAIT = 20000,        // >= 100 us after power-up, in clocks
    parameter REFI      = 750
) (
    input  wire              clk,
    input  wire              rst,
    output reg               ready = 1'b0,

    // write stream from a FWFT FIFO
    input  wire              wmode,             // hold during a write session
    input  wire              wflush,            // write a final partial burst too
    input  wire [9:0]        wcount,            // words in the FIFO
    input  wire [15:0]       wdata,             // FIFO head
    output wire              wpop,              // take the FIFO head this clock
    input  wire              wreset,            // waddr <= 0
    output reg  [WABITS-1:0] waddr = 0,         // address of the next word written

    // read stream: consecutive bursts from rstart_addr (a multiple of 8)
    input  wire              rmode,
    input  wire              rstart,
    input  wire [WABITS-1:0] rstart_addr,
    input  wire [9:0]        rspace,            // free entries downstream
    output reg  [15:0]       rdata = 0,
    output reg               rvalid = 1'b0,

    output wire              idle,

    output reg               sd_cke = 1'b0,
    output reg               sd_cs_n = 1'b1,
    output reg               sd_ras_n = 1'b1,
    output reg               sd_cas_n = 1'b1,
    output reg               sd_we_n = 1'b1,
    output reg  [1:0]        sd_ba = 0,
    output reg  [12:0]       sd_a = 0,
    output reg  [1:0]        sd_dqm = 2'b11,
    output reg  [15:0]       sd_dq_out = 0,
    output reg               sd_dq_oe = 1'b0,
    input  wire [15:0]       sd_dq_in
);
    localparam CL = 3, RLAT = CL + 1;

    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

    localparam S_POWER = 0, S_INIT_PRE = 1, S_INIT_REF = 2, S_INIT_MRS = 3, S_IDLE = 4,
               S_WRITE = 5, S_READ = 6, S_CLOSE = 7;
    reg [2:0]  state = S_POWER;
    reg [15:0] wait_cnt = 0;
    reg        init_ref2 = 1'b0;
    reg [10:0] ref_cnt = 0;
    reg        ref_due = 1'b0;
    reg        bursting = 1'b0;
    reg [3:0]  beat = 0;                       // next beat of the write burst
    reg [3:0]  last_n = 0;                     // real words in the current burst
    reg [WABITS-1:0] raddr = 0;
    reg [2:0]  rgap = 0;                       // clocks until the next READ may issue
    reg [RLAT-1:0] riss = 0;                   // READ issued 1..RLAT clocks ago
    reg [3:0]  rbeat = 0;
    reg [6:0]  inflight = 0;                   // words requested, not yet delivered
    reg [2:0]  since_act = 0;                  // clocks since ACTIVE, for tRAS
    reg [1:0]  open_bank = 0;
    reg [12:0] open_row = 0;

    wire [1:0]  w_bank = waddr[WABITS-1 -: 2];
    wire [12:0] w_row  = waddr[WABITS-3:9];
    wire [8:0]  w_col  = waddr[8:0];
    wire [1:0]  r_bank = raddr[WABITS-1 -: 2];
    wire [12:0] r_row  = raddr[WABITS-3:9];
    wire [8:0]  r_col  = raddr[8:0];

    wire go     = (wait_cnt == 0) && !rst;
    wire w_full = (wcount >= 10'd8);
    wire w_have = w_full || (wflush && wcount != 0);

    // decisions for this clock
    wire issue_wr = go && state == S_WRITE && !bursting && wmode && w_have && !ref_due &&
                    w_bank == open_bank && w_row == open_row;
    wire issue_rd = go && state == S_READ && rgap == 0 && rmode && !ref_due &&
                    r_bank == open_bank && r_row == open_row &&
                    ({1'b0, rspace} >= {4'b0, inflight} + 11'd10);
    wire [3:0] n_new = w_full ? 4'd8 : wcount[3:0];

    assign wpop = issue_wr || (bursting && beat < last_n);
    assign idle = (state == S_IDLE) && !bursting && inflight == 0;

    // refresh timer
    always @(posedge clk) begin
        if (rst || !ready) begin
            ref_cnt <= 0; ref_due <= 1'b0;
        end else if (state == S_IDLE && go && ref_due) begin
            ref_cnt <= 0; ref_due <= 1'b0;
        end else begin
            ref_cnt <= ref_cnt + 1'b1;
            if (ref_cnt >= REFI - 40) ref_due <= 1'b1;   // time to close a row first
        end
    end

    // read data return
    always @(posedge clk) begin
        riss   <= {riss[RLAT-2:0], issue_rd};
        rvalid <= 1'b0;
        rdata  <= sd_dq_in;
        if (rst) begin
            rbeat <= 0;
        end else if (riss[RLAT-1]) begin
            rvalid <= 1'b1; rbeat <= 4'd7;
        end else if (rbeat != 0) begin
            rvalid <= 1'b1; rbeat <= rbeat - 1'b1;
        end
        if (rst) inflight <= 0;
        else inflight <= inflight + (issue_rd ? 7'd8 : 7'd0) - ((riss[RLAT-1] || rbeat != 0) ? 7'd1 : 7'd0);
        if (issue_rd) rgap <= 3'd7;
        else if (rgap != 0) rgap <= rgap - 1'b1;
    end

    always @(posedge clk) begin
        {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_NOP;
        sd_dqm   <= 2'b11;
        sd_dq_oe <= 1'b0;
        if (since_act != 3'd7) since_act <= since_act + 1'b1;
        if (wreset) waddr <= 0;
        if (rstart) raddr <= rstart_addr;

        // the rest of a write burst
        if (bursting) begin
            sd_dq_oe  <= 1'b1;
            sd_dq_out <= wdata;
            sd_dqm    <= (beat < last_n) ? 2'b00 : 2'b11;
            beat      <= beat + 1'b1;
            if (beat == 4'd7) bursting <= 1'b0;
        end
        if (state == S_READ || inflight != 0) sd_dqm <= 2'b00;   // DQM masks reads 2 clocks later

        if (rst) begin
            state <= S_POWER; ready <= 1'b0; wait_cnt <= INIT_WAIT; sd_cke <= 1'b1;
            bursting <= 1'b0;
        end else if (wait_cnt != 0) begin
            wait_cnt <= wait_cnt - 1'b1;
        end else case (state)
        S_POWER: state <= S_INIT_PRE;                // CKE high and NOPs for INIT_WAIT
        S_INIT_PRE: begin
            {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_PRE; sd_a[10] <= 1'b1;
            wait_cnt <= 1; state <= S_INIT_REF; init_ref2 <= 1'b0;
        end
        S_INIT_REF: begin
            {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_REF;
            wait_cnt <= 7; init_ref2 <= 1'b1;
            if (init_ref2) state <= S_INIT_MRS;
        end
        S_INIT_MRS: begin
            {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_MRS; sd_ba <= 2'b00;
            sd_a <= {3'b000, 1'b0, 2'b00, 3'd3, 1'b0, 3'b011};   // write burst, CL3, sequential, BL8
            wait_cnt <= 1; state <= S_IDLE; ready <= 1'b1;
        end
        S_IDLE: begin
            if (ref_due) begin
                {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_REF; wait_cnt <= 7;
            end else if (wmode && w_have) begin
                {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_ACT; sd_ba <= w_bank; sd_a <= w_row;
                open_bank <= w_bank; open_row <= w_row; since_act <= 0;
                wait_cnt <= 1; state <= S_WRITE;                 // tRCD
            end else if (rmode && !rstart && {1'b0, rspace} >= {4'b0, inflight} + 11'd10) begin
                {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_ACT; sd_ba <= r_bank; sd_a <= r_row;
                open_bank <= r_bank; open_row <= r_row; since_act <= 0;
                wait_cnt <= 1; state <= S_READ;
            end
        end
        S_WRITE: begin
            if (issue_wr) begin
                {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_WRITE;
                sd_ba <= w_bank; sd_a <= {4'b0000, w_col};       // A10 low: keep the row open
                sd_dq_oe <= 1'b1; sd_dq_out <= wdata; sd_dqm <= 2'b00;
                last_n <= n_new; beat <= 4'd1; bursting <= 1'b1;
                waddr <= waddr + {{(WABITS-4){1'b0}}, 4'd8};
            end else if (!bursting && (!wmode || ref_due || (w_have && (w_bank != open_bank || w_row != open_row)))) begin
                // keep the row open while the FIFO refills; close it for a
                // refresh, a new row or the end of the session
                wait_cnt <= 1; state <= S_CLOSE;                 // tWR after the last word
            end
        end
        S_READ: begin
            if (issue_rd) begin
                {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_READ;
                sd_ba <= r_bank; sd_a <= {4'b0000, r_col};
                raddr <= raddr + {{(WABITS-4){1'b0}}, 4'd8};
            end else if (rgap == 0 && !(rmode && !ref_due && r_bank == open_bank && r_row == open_row &&
                                        {1'b0, rspace} >= {4'b0, inflight} + 11'd10)) begin
                state <= S_CLOSE;                                // last burst is out; PRE may follow
            end
        end
        S_CLOSE: if (since_act >= 3'd4) begin                // tRAS: 5 clocks from ACTIVE
            {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= C_PRE; sd_a[10] <= 1'b1;
            wait_cnt <= 1; state <= S_IDLE;                      // tRP
        end
        default: state <= S_IDLE;
        endcase
    end
endmodule
