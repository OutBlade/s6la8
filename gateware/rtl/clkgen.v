// SPDX-License-Identifier: GPL-3.0-or-later
// 50 MHz oscillator -> 100 MHz system clock, plus a copy shifted by 225
// degrees (6.25 ns) that samples SDRAM read data in the middle of its valid
// window (see sdram_ctrl.v).  Under SIM the testbench drives the system clock
// directly, so simulation needs no Xilinx libraries.
module clkgen (
    input  wire clk50,
    output wire clk,
    output wire clk_sdrd,
    output wire locked
);
`ifdef SIM
    assign clk = clk50;
    // transport delay: an inertial #6.25 would swallow the 5 ns half-periods
    reg clk_rd_r = 1'b0;
    /* verilator lint_off ASSIGNDLY */
    always @(clk50) clk_rd_r <= #6.25 clk50;
    /* verilator lint_on ASSIGNDLY */
    assign clk_sdrd = clk_rd_r;
    assign locked = 1'b1;
`else
    wire clk_rd_u;
    wire clk50_b, fb, clk_u;
    IBUFG u_in (.I(clk50), .O(clk50_b));
    PLL_BASE #(
        .CLKIN_PERIOD(20.0), .CLKFBOUT_MULT(16), .DIVCLK_DIVIDE(1),   // VCO 800 MHz
        .CLKOUT0_DIVIDE(8), .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(225.0),
        .COMPENSATION("INTERNAL")
    ) u_pll (
        .CLKIN(clk50_b), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(clk_u),
        .CLKOUT1(clk_rd_u), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .LOCKED(locked), .RST(1'b0));
    BUFG u_bufg (.I(clk_u), .O(clk));
    BUFG u_bufg_rd (.I(clk_rd_u), .O(clk_sdrd));
`endif
endmodule
