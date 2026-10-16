// SPDX-License-Identifier: GPL-3.0-or-later
// Board authentication.
//
// Every Spartan-6 carries a factory-programmed 57-bit Device DNA.  At
// production each board's DNA is read out and SipHash-2-4(KEY, DNA) is stored
// in the FX2's EEPROM; the FX2 writes that tag into the FPGA after
// configuration.  This block reads the DNA, computes the same hash with the
// key built into the bitstream and raises `ok` only if the two agree.  A copied
// board has a different DNA, and a valid tag for it cannot be made without
// the key.
//
// The key comes from auth_key.vh (production, kept out of version control) or
// auth_key_dev.vh (all zero, check disabled).  See tools/provision.py.
module dna_auth #(
    parameter [127:0] KEY = 128'h0
) (
    input  wire        clk,             // system clock, at most 128 MHz
    input  wire [63:0] tag,             // from the EEPROM, via the FX2
    input  wire        check,           // pulse after `tag` was written
    output reg  [56:0] dna = 57'h0,
    output reg         dna_valid = 1'b0,
    output reg         ok = 1'b0,
    output reg         busy = 1'b1
);
    // ---------------------------------------------------------------- DNA
    // DNA_PORT runs at 2 MHz or less: drive it from clk / 64.  Controls
    // change and DOUT is sampled on the falling edge, half a period away
    // from the rising edge that acts on them.
    reg  [5:0] div = 0;
    reg        dclk = 1'b0, dread = 1'b0, dshift = 1'b0;
    reg  [6:0] nbits = 0;
    reg  [1:0] dstate = 0;
    wire       dout;

    DNA_PORT u_dna (.CLK(dclk), .READ(dread), .SHIFT(dshift), .DIN(1'b0), .DOUT(dout));

    always @(posedge clk) begin
        div <= div + 1'b1;
        if (div == 6'd63) dclk <= 1'b1;
        if (div == 6'd31) begin
            dclk <= 1'b0;
            case (dstate)
                2'd0: begin dread <= 1'b1; dstate <= 2'd1; end
                2'd1, 2'd2: begin
                    dread  <= 1'b0;
                    dshift <= 1'b1;
                    dstate <= 2'd2;
                    dna    <= {dna[55:0], dout};         // MSB first
                    nbits  <= nbits + 1'b1;
                    if (nbits == 7'd56) begin
                        dshift <= 1'b0;
                        dstate <= 2'd3;
                        dna_valid <= 1'b1;
                    end
                end
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------- SipHash-2-4
    // One SipRound per clock: 2 rounds for the DNA word, 2 for the length
    // block, 4 for finalisation.
    localparam [63:0] K0 = KEY[63:0], K1 = KEY[127:64];
    reg  [63:0] v0, v1, v2, v3;
    reg  [3:0]  step = 0;
    reg         run = 1'b0;
    wire [63:0] m = {7'b0, dna};
    localparam [63:0] B = 64'h0800000000000000;   // message length 8, no tail bytes

    function [255:0] round(input [63:0] a0, input [63:0] a1, input [63:0] a2, input [63:0] a3);
        reg [63:0] x0, x1, x2, x3;
        begin
            x0 = a0 + a1; x1 = {a1[50:0], a1[63:51]} ^ x0; x0 = {x0[31:0], x0[63:32]};
            x2 = a2 + a3; x3 = {a3[47:0], a3[63:48]} ^ x2;
            x0 = x0 + x3; x3 = {x3[42:0], x3[63:43]} ^ x0;
            x2 = x2 + x1; x1 = {x1[46:0], x1[63:47]} ^ x2; x2 = {x2[31:0], x2[63:32]};
            round = {x0, x1, x2, x3};
        end
    endfunction

    wire [255:0] r = round(v0, v1, v2, v3);
    wire [63:0]  hash = v0 ^ v1 ^ v2 ^ v3;

    always @(posedge clk) begin
        if (check && dna_valid && !run) begin
            v0 <= K0 ^ 64'h736f6d6570736575;
            v1 <= K1 ^ 64'h646f72616e646f6d;
            v2 <= K0 ^ 64'h6c7967656e657261;
            v3 <= K1 ^ 64'h7465646279746573 ^ m;
            step <= 0;
            run  <= 1'b1;
            busy <= 1'b1;
        end else if (run) begin
            step <= step + 1'b1;
            case (step)
                4'd0, 4'd2, 4'd4, 4'd5, 4'd6, 4'd7: {v0, v1, v2, v3} <= r;
                4'd1: {v0, v1, v2, v3} <= {r[255:192] ^ m, r[191:128], r[127:64], r[63:0] ^ B};
                4'd3: {v0, v1, v2, v3} <= {r[255:192] ^ B, r[191:128], r[127:64] ^ 64'hff, r[63:0]};
                default: begin
                    ok   <= (hash == tag);
                    run  <= 1'b0;
                    busy <= 1'b0;
                end
            endcase
        end
    end
endmodule
