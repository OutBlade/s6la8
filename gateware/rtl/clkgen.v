// SPDX-License-Identifier: GPL-3.0-or-later
// 50 MHz oscillator -> 100 MHz system clock.  Under SIM the testbench drives
// the system clock directly, so simulation needs no Xilinx libraries.
module clkgen (
    input  wire clk50,
    output wire clk,
    output wire locked
);
`ifdef SIM
    assign clk = clk50;
    assign locked = 1'b1;
`else
    wire clk50_b, fb, clk_u;
    IBUFG u_in (.I(clk50), .O(clk50_b));
    PLL_BASE #(
        .CLKIN_PERIOD(20.0), .CLKFBOUT_MULT(16), .DIVCLK_DIVIDE(1),   // VCO 800 MHz
        .CLKOUT0_DIVIDE(8), .COMPENSATION("INTERNAL")
    ) u_pll (
        .CLKIN(clk50_b), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(clk_u),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .LOCKED(locked), .RST(1'b0));
    BUFG u_bufg (.I(clk_u), .O(clk));
`endif
endmodule
