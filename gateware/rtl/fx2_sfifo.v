// SPDX-License-Identifier: GPL-3.0-or-later
// FX2LP synchronous slave-FIFO writer for one bulk IN endpoint with AUTOIN.
//
// The FX2 can only run out of room when a 512-byte packet is committed, so
// bytes are written in bursts that end on a packet boundary, and the full
// flag is looked at only there, after PAUSE idle cycles.  That makes the
// flag's output delay plus this module's input and output registers harmless.
// A partial packet left waiting for FLUSH cycles is committed with PKTEND.
module fx2_sfifo #(
    parameter PAUSE = 3,
    parameter FLUSH = 20'd480000      // 10 ms at 48 MHz
) (
    input  wire       ifclk,
    input  wire       rst,
    input  wire       enable,         // FPGA owns the FD bus
    input  wire       flag_full_n,    // FLAGB, low = EP2 full
    output reg        slwr_n = 1'b1,
    output reg        pktend_n = 1'b1,
    output reg  [7:0] fd = 8'h00,
    output reg        fd_oe = 1'b0,

    input  wire [7:0] din,
    input  wire       din_valid,
    output wire       din_rd
);
    reg        full_n = 1'b0;
    reg  [8:0] count = 0;             // bytes in the open packet
    reg  [2:0] pause = 0;
    reg [19:0] idle = 0;
    reg        was_write = 1'b0;

    wire can_write = enable && din_valid && (pause == 0) && (count != 0 || full_n);
    assign din_rd = can_write;

    always @(posedge ifclk) begin
        full_n   <= flag_full_n;
        fd_oe    <= enable;
        slwr_n   <= 1'b1;
        pktend_n <= 1'b1;
        was_write <= 1'b0;
        if (rst || !enable) begin
            count <= 0; pause <= PAUSE; idle <= 0;
        end else begin
            if (pause != 0) pause <= pause - 1'b1;
            if (can_write) begin
                fd     <= din;
                slwr_n <= 1'b0;
                count  <= count + 1'b1;      // wraps to 0 after 512
                idle   <= 0;
                was_write <= 1'b1;
                if (count == 9'd511) pause <= PAUSE;
            end else if (count != 0) begin
                if (idle == FLUSH && !was_write) begin
                    pktend_n <= 1'b0;        // commit the short packet
                    count <= 0; idle <= 0; pause <= PAUSE;
                end else begin
                    idle <= idle + 1'b1;
                end
            end
        end
    end
endmodule
