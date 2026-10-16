// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioural model of the Spartan-6 DNA_PORT primitive (UG380, chapter 4):
// READ loads the 57-bit DNA, SHIFT shifts it towards DOUT, MSB first.
module DNA_PORT #(
    parameter [56:0] SIM_DNA_VALUE = 57'h123456789abcdef
) (
    input  wire CLK,
    input  wire READ,
    input  wire SHIFT,
    input  wire DIN,
    output wire DOUT
);
    reg [56:0] sr = 57'h0;
    assign DOUT = sr[56];
    always @(posedge CLK)
        if (READ) sr <= SIM_DNA_VALUE;
        else if (SHIFT) sr <= {sr[55:0], DIN};
endmodule
