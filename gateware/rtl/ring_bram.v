// SPDX-License-Identifier: GPL-3.0-or-later
// Sample ring buffer in block RAM, with the same interface as ring_sdram.
module ring_bram #(
    parameter ABITS = 15
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             start,
    input  wire             wr,
    input  wire [7:0]       wdata,
    input  wire             play,
    input  wire [ABITS-1:0] play_addr,
    input  wire [ABITS:0]   play_len,
    output wire [7:0]       q,
    output wire             q_valid,
    input  wire             q_rd,
    output wire             play_done
);
    reg [7:0]       mem [0:(1<<ABITS)-1];
    reg [7:0]       mem_q = 0;
    reg [ABITS-1:0] wptr = 0, rptr = 0;
    reg [ABITS:0]   remain = 0;
    reg [1:0]       pstate = 0;                 // 0 idle, 1 loading, 2 streaming

    assign q         = mem_q;
    assign q_valid   = (pstate == 2'd2) && remain != 0;
    wire   take      = q_valid && q_rd;
    wire [ABITS-1:0] rnext = rptr + {{(ABITS-1){1'b0}}, take};
    assign play_done = (pstate == 2'd0) && !play;

    always @(posedge clk) begin
        if (wr) mem[wptr] <= wdata;
        mem_q <= mem[rnext];
    end

    always @(posedge clk) begin
        if (rst || start) wptr <= 0;
        else if (wr) wptr <= wptr + 1'b1;

        rptr <= rnext;
        if (rst) begin
            pstate <= 0;
        end else if (play) begin
            rptr <= play_addr; remain <= play_len; pstate <= 2'd1;
        end else if (pstate == 2'd1) begin
            pstate <= 2'd2;                     // mem_q now holds mem[play_addr]
        end else if (pstate == 2'd2) begin
            if (take) remain <= remain - 1'b1;
            if (remain == 0 || (take && remain == 1)) pstate <= 2'd0;
        end
    end
endmodule
