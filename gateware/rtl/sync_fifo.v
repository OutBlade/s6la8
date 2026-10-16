// SPDX-License-Identifier: GPL-3.0-or-later
// Single-clock FIFO, first-word fall-through, one word per clock in and out.
// The block RAM is read one entry ahead (address = read pointer plus the
// current pop), so `q` always shows the oldest word without a bubble.
module sync_fifo #(
    parameter WIDTH = 16,
    parameter ABITS = 9
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             wr,             // ignored when full
    input  wire [WIDTH-1:0] wdata,
    input  wire             rd,             // pop `q` (ignored when not valid)
    output wire [WIDTH-1:0] q,
    output wire             valid,
    output wire [ABITS:0]   count,          // words stored
    output wire             full
);
    reg [WIDTH-1:0] mem [0:(1<<ABITS)-1];
    reg [WIDTH-1:0] mem_q = 0;
    reg [ABITS:0]   wptr = 0, wptr_d = 0, rptr = 0;

    assign count = wptr - rptr;
    assign full  = (count == (1 << ABITS));
    assign valid = (wptr_d != rptr);        // a word written last cycle is readable now
    assign q     = mem_q;

    wire           we    = wr && !full;
    wire           take  = rd && valid;
    wire [ABITS:0] rnext = rptr + {{ABITS{1'b0}}, take};

    always @(posedge clk) begin
        if (we) mem[wptr[ABITS-1:0]] <= wdata;
        mem_q <= mem[rnext[ABITS-1:0]];
    end

    always @(posedge clk) begin
        if (rst) begin
            wptr <= 0; wptr_d <= 0; rptr <= 0;
        end else begin
            if (we) wptr <= wptr + 1'b1;
            wptr_d <= wptr;
            rptr   <= rnext;
        end
    end
endmodule
