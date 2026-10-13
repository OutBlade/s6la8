// SPDX-License-Identifier: GPL-3.0-or-later
// Self-checking testbench for the s6la8 top level.
//
// The FX2 model holds four 512-byte packets, commits one on every 512th
// write or on PKTEND, raises "full" one clock-to-out delay after the commit
// that used the last buffer, and flags any write that arrives while full.
// A "host" drains packets at random intervals.
`timescale 1ns / 1ps

module tb_top;
    reg clk = 0, ifclk = 0;
    always #5 clk = ~clk;                 // 100 MHz
    always #10.416 ifclk = ~ifclk;        // 48 MHz

    reg        sck = 0, mosi = 0, cs_n = 1, fb_oe_n = 0;
    wire       miso, irq_n, slwr_n, pktend_n;
    wire [7:0] fd;
    reg  [7:0] ch = 0;
    reg        flag_full_n = 1;

    top #(.FLUSH(20'd2000)) dut (
        .CLK50(clk), .IFCLK(ifclk), .CH(ch), .EXT_CLK(1'b0), .TRIG(1'b0),
        .FD(fd), .SLWR(slwr_n), .PKTEND(pktend_n), .FLAGA(1'b1), .FLAGB(flag_full_n), .FLAGC(1'b1),
        .CCLK(sck), .REG_MOSI(mosi), .REG_MISO(miso), .REG_CS_N(cs_n),
        .FPGA_IRQ_N(irq_n), .FB_OE_N(fb_oe_n));
    pullup (slwr_n);
    pullup (pktend_n);

    integer errors = 0;

    // ------------------------------------------------------------ FX2 model
    integer committed = 0, fill = 0, rx_count = 0, drain_gap = 400, seed = 1;
    integer short_packets = 0, writes_when_full = 0;
    reg [7:0] rx [0:262143];
    always @(posedge ifclk) begin
        if (!slwr_n) begin
            if (committed == 4) begin
                writes_when_full = writes_when_full + 1;
            end else begin
                rx[rx_count] = fd;
                rx_count = rx_count + 1;
                fill = fill + 1;
                if (fill == 512) begin fill = 0; committed = committed + 1; end
            end
        end
        if (!pktend_n) begin
            if (!slwr_n) begin $display("ERROR: PKTEND together with SLWR"); errors = errors + 1; end
            if (fill != 0) begin fill = 0; committed = committed + 1; short_packets = short_packets + 1; end
        end
        flag_full_n <= #9.5 (committed != 4);
    end
    // host side: take one packet every so often
    integer t = 0;
    always @(posedge ifclk) begin
        t = t + 1;
        if (t >= drain_gap + ($random(seed) & 255)) begin
            t = 0;
            if (committed > 0) committed = committed - 1;
        end
    end

    // ------------------------------------------------------------ SPI master
    task spi_byte(input [7:0] o, output [7:0] i);
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = o[k]; #250 sck = 1; i[k] = miso; #250 sck = 0;
            end
        end
    endtask
    task reg_write(input [6:0] a, input [7:0] d);
        reg [7:0] x;
        begin cs_n = 0; #200 spi_byte({1'b0, a}, x); spi_byte(d, x); #200 cs_n = 1; #400; end
    endtask
    task reg_write32(input [6:0] a, input [31:0] d);
        reg [7:0] x;
        begin
            cs_n = 0; #200 spi_byte({1'b0, a}, x);
            spi_byte(d[7:0], x); spi_byte(d[15:8], x); spi_byte(d[23:16], x); spi_byte(d[31:24], x);
            #200 cs_n = 1; #400;
        end
    endtask
    task reg_read(input [6:0] a, output [7:0] d);
        reg [7:0] x;
        begin cs_n = 0; #200 spi_byte({1'b1, a}, x); spi_byte(8'h00, d); #200 cs_n = 1; #400; end
    endtask
    task reg_read32(input [6:0] a, output [31:0] d);
        reg [7:0] x;
        begin
            cs_n = 0; #200 spi_byte({1'b1, a}, x);
            spi_byte(8'h00, d[7:0]); spi_byte(8'h00, d[15:8]); spi_byte(8'h00, d[23:16]); spi_byte(8'h00, d[31:24]);
            #200 cs_n = 1; #400;
        end
    endtask
    task expect8(input [255:0] what, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("ERROR: %0s = %0d, expected %0d", what, got, want);
            errors = errors + 1;
        end
    endtask

    reg [7:0]  b;
    reg [31:0] w;
    integer i, n, first;

    initial begin
        $timeformat(-6, 1, " us", 10);
        #2000;

        // --- 1. identity ---------------------------------------------------
        reg_read(7'h00, b); expect8("ID0", b, 8'h53);
        reg_read(7'h01, b); expect8("ID1", b, 8'h36);
        reg_read(7'h03, b); expect8("depth log2", b, 15);
        reg_write32(7'h08, 32'h12345678);
        reg_write(7'h2c, 8'h03);
        reg_read(7'h2c, b); expect8("LED readback", b, 3);

        // --- 2. FD must stay released while the fallback buffer is on -------
        reg_write32(7'h08, 32'd3);          // 25 MS/s
        reg_write(7'h04, 8'h05);            // stream + test pattern
        #200000;
        if (fd !== 8'hzz || rx_count != 0) begin
            $display("ERROR: FPGA drove the FIFO bus with FB_OE_N low"); errors = errors + 1;
        end
        reg_write(7'h04, 8'h08);            // reset

        // --- 3. streaming at 25 MS/s with a slow, bursty host ---------------
        fb_oe_n = 1;
        #1000;
        drain_gap = 900;                    // ~27 MB/s average, above 25 MB/s
        reg_write(7'h04, 8'h05);
        #6000000;
        reg_write(7'h04, 8'h04);            // stop, keep the pattern
        #300000;                            // let the flush timer commit the tail
        reg_read(7'h05, b);
        expect8("stream overflow flag", b[4], 0);
        expect8("writes while full", writes_when_full, 0);
        n = 0;
        for (i = 4; i < rx_count; i = i + 1)      // the first samples predate the pattern
            if (rx[i] !== ((rx[i-1] + 8'd1) & 8'hff)) n = n + 1;
        expect8("stream sequence breaks", n, 0);
        if (rx_count < 100000) begin $display("ERROR: only %0d stream bytes", rx_count); errors = errors + 1; end
        if (fill != 0) begin $display("ERROR: %0d bytes left uncommitted", fill); errors = errors + 1; end
        $display("stream: %0d bytes, %0d short packet(s)", rx_count, short_packets);

        // --- 4. overflow is reported when the host stalls --------------------
        reg_write(7'h04, 8'h08);
        rx_count = 0; committed = 0; fill = 0;
        drain_gap = 400000;                 // host effectively stopped
        reg_write32(7'h08, 32'd0);          // 100 MS/s
        reg_write(7'h04, 8'h05);
        #500000;
        reg_read(7'h05, b);
        expect8("overflow flag after stall", b[4], 1);
        expect8("writes while full after stall", writes_when_full, 0);
        reg_write(7'h04, 8'h08);

        // --- 5. buffered capture, edge + level trigger, pre/post -------------
        #2000;
        rx_count = 0; committed = 0; fill = 0; drain_gap = 300;
        reg_write32(7'h08, 32'd0);          // 100 MS/s
        reg_write32(7'h10, 32'd1000);       // pre
        reg_write32(7'h0c, 32'd3000);       // post
        // stage 0: bit 7 rising; stage 1: value == 0x90
        reg_write32(7'h18, {8'h00, 8'h80, 8'h00, 8'h00});
        reg_write32(7'h1c, {8'h00, 8'h00, 8'h90, 8'hff});
        reg_write(7'h28, 8'd1);
        reg_write(7'h04, 8'h06);            // arm + test pattern
        wait (irq_n === 1'b0);
        #400000;
        reg_read(7'h05, b);
        expect8("done", b[3], 1);
        expect8("triggered", b[2], 1);
        reg_read32(7'h14, w);
        if (w < 1000 || w > 32768 - 3000) begin
            $display("ERROR: trigger position %0d out of range", w); errors = errors + 1;
        end
        expect8("buffered byte count", rx_count, w + 3000);
        expect8("sample at trigger", rx[w], 8'h90);
        n = 0;
        for (i = 1; i < rx_count; i = i + 1)
            if (rx[i] !== ((rx[i-1] + 8'd1) & 8'hff)) n = n + 1;
        expect8("buffered sequence breaks", n, 0);
        expect8("writes while full (buffered)", writes_when_full, 0);
        $display("buffered: %0d bytes, trigger at %0d", rx_count, w);

        // --- 6. forced trigger, no pre-trigger requirement -------------------
        reg_write(7'h04, 8'h08);
        #2000; rx_count = 0; committed = 0; fill = 0;
        reg_write32(7'h10, 32'd0);
        reg_write32(7'h0c, 32'd512);
        reg_write32(7'h18, {8'h00, 8'h00, 8'hff, 8'hff});   // never matches a counter soon
        reg_write32(7'h08, 32'd9);          // 10 MS/s
        reg_write(7'h28, 8'd0);
        reg_write(7'h04, 8'h06);
        #50000;
        reg_write(7'h04, 8'h14);            // force trigger, keep the pattern
        wait (irq_n === 1'b0);
        #300000;
        reg_read32(7'h14, w);
        expect8("forced capture byte count", rx_count, w + 512);

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
