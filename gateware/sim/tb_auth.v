// SPDX-License-Identifier: GPL-3.0-or-later
// dna_auth against the Python reference (tools/provision.py selftest):
// key 00..0f, DNA 0x0123456789abcdef -> tag e9d31dd454ca179c.
`timescale 1ns/1ps
module tb_auth;
    reg clk = 0;
    always #5 clk = ~clk;

    reg  [63:0] tag = 64'h0;
    reg         check = 1'b0;
    wire [56:0] dna;
    wire        dna_valid, ok, busy;

    dna_auth #(.KEY(128'h0f0e0d0c0b0a09080706050403020100)) dut (
        .clk(clk), .tag(tag), .check(check), .dna(dna), .dna_valid(dna_valid), .ok(ok), .busy(busy));

    task try(input [63:0] t, input expect_ok);
        begin
            @(posedge clk) begin tag <= t; check <= 1'b1; end
            @(posedge clk) check <= 1'b0;
            repeat (3) @(posedge clk);
            wait (!busy);
            @(posedge clk);
            if (ok !== expect_ok) begin
                $display("FAIL: tag %h gave ok=%b", t, ok);
                $finish;
            end
        end
    endtask

    initial begin
        wait (dna_valid);
        if (dna !== 57'h0123456789abcdef) begin
            $display("FAIL: read DNA %h", dna);
            $finish;
        end
        try(64'he9d31dd454ca179c, 1'b1);
        try(64'he9d31dd454ca179d, 1'b0);
        try(64'h0, 1'b0);
        try(64'he9d31dd454ca179c, 1'b1);
        $display("PASS auth");
        $finish;
    end
    initial begin #2000000 $display("FAIL: timeout"); $finish; end
endmodule
