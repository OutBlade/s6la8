// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioural model of the Spartan-6 ODDR2 primitive as used here (C1 = ~C0,
// no alignment, no set/reset): D0 after the rising edge of C0, D1 after
// that of C1.
/* verilator lint_off UNUSEDPARAM */
module ODDR2 #(
    parameter DDR_ALIGNMENT = "NONE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output wire Q,
    input  wire C0, C1, CE, D0, D1, R, S
);
    reg q0 = 1'b0, q1 = 1'b0;
    always @(posedge C0) if (CE) q0 <= D0;
    always @(posedge C1) if (CE) q1 <= D1;
    assign Q = C0 ? q0 : q1;
endmodule
/* verilator lint_on UNUSEDPARAM */
