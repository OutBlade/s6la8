// SPDX-License-Identifier: GPL-3.0-or-later
// ring_sdram against the SDRAM model: write a counting pattern, replay
// windows with odd and even start addresses, across the ring's wrap point.
`timescale 1ns / 1ps
module tb_ring;
    reg clk = 0;
    always #5 clk = ~clk;
    reg clk_rd = 0;
    always @(clk) clk_rd <= #6.25 clk;

    reg         rst = 1, start = 0, wr = 0, stop = 0, play = 0, q_rd = 1;
    reg  [7:0]  wdata = 0;
    reg  [13:0] play_addr = 0;
    reg  [14:0] play_len = 0;
    wire [7:0]  q;
    wire        ready, overflow, drained, q_valid, play_done;
    wire        cke, cs_n, ras_n, cas_n, we_n, oe;
    wire [1:0]  ba, dqm;
    wire [12:0] a;
    wire [15:0] dq_o, dq;
    reg  [15:0] dq_in = 0;
    always @(posedge clk_rd) dq_in <= dq;
    assign dq = oe ? dq_o : 16'hzzzz;
    wire #3 sdclk = ~clk;

    ring_sdram #(.SABITS(14), .INIT_WAIT(200)) dut (
        .clk(clk), .rst(rst), .soft_rst(1'b0), .ready(ready), .start(start), .wr(wr), .wdata(wdata),
        .overflow(overflow), .stop(stop), .drained(drained),
        .play(play), .play_addr(play_addr), .play_len(play_len), .q(q), .q_valid(q_valid),
        .q_rd(q_rd), .play_done(play_done),
        .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
        .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_out(dq_o), .sd_dq_oe(oe), .sd_dq_in(dq_in));
    sdram_model #(.STORE_ROWS(5)) mem (.clk(sdclk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n),
        .cas_n(cas_n), .we_n(we_n), .ba(ba), .a(a), .dqm(dqm), .dq(dq));

    integer errors = 0, i, got, n;
    reg [7:0] want;

    task replay(input integer from, input integer len, input [7:0] first);
        begin
            @(posedge clk) begin play <= 1; play_addr <= from; play_len <= len; end
            @(posedge clk) play <= 0;
            got = 0; want = first;
            while (got < len) begin
                @(posedge clk);
                if (q_valid && q_rd) begin
                    if (q !== want) begin
                        if (errors < 10) $display("ERROR replay %0d+%0d: byte %0d = %h, expected %h", from, len, got, q, want);
                        errors = errors + 1;
                    end
                    want = want + 1; got = got + 1;
                end
            end
            wait (play_done);
            $display("%t replay from %0d, %0d bytes done", $time, from, len); $fflush;
        end
    endtask

    initial begin
        #100 rst = 0;
        wait (ready); $display("%t ready", $time); $fflush;
        @(posedge clk) start <= 1; @(posedge clk) start <= 0;
        // 20001 samples at full rate, value = index (mod 256): wraps the 16 K ring
        for (i = 0; i < 20001; i = i + 1) begin
            @(posedge clk) begin wr <= 1; wdata <= i; end
        end
        @(posedge clk) wr <= 0;
        @(posedge clk) stop <= 1; @(posedge clk) stop <= 0;
        wait (drained); $display("%t drained, overflow=%b", $time, overflow); $fflush;
        // the newest 16000 samples: indices 4001..20000, ring addresses wrap
        replay((20001 - 16000) % 16384, 16000, 8'((20001 - 16000) & 255));
        replay(20000 % 16384, 1, 8'(20000 & 255));
        replay(12345, 77, 8'((12345 + 16384) & 255));
        // slow consumer
        q_rd = 0; fork begin replay(18000 % 16384, 2001, 8'(18000 & 255)); end
                       begin repeat (40000) begin @(posedge clk) q_rd <= ($random & 3) == 0; end q_rd <= 1; end join
        if (mem.errors) errors = errors + mem.errors;
        if (overflow) begin $display("ERROR overflow"); errors = errors + 1; end
        if (errors == 0) $display("PASS ring"); else $display("FAIL ring: %0d errors", errors);
        $finish;
    end
    initial begin #20000000 $display("FAIL: timeout"); $finish; end
endmodule
