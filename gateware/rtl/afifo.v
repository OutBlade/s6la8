// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-clock FIFO with Gray-coded pointers and a registered, first-word
// fall-through output.  The memory has a synchronous read so it maps to
// block RAM.
module afifo #(
    parameter WIDTH = 8,
    parameter ABITS = 11
) (
    input  wire             wclk,
    input  wire             wrst,
    input  wire             wr,
    input  wire [WIDTH-1:0] wdata,
    output wire             wfull,

    input  wire             rclk,
    input  wire             rrst,
    input  wire             rd,
    output reg  [WIDTH-1:0] rdata,
    output wire             rvalid
);
    reg [WIDTH-1:0] mem [0:(1<<ABITS)-1];

    reg [ABITS:0] wbin = 0, wgray = 0, rbin = 0, rgray = 0;
    reg [ABITS:0] rgray_w1 = 0, rgray_w2 = 0, wgray_r1 = 0, wgray_r2 = 0;
    reg           valid = 0;

    wire [ABITS:0] wbin_n  = wbin + 1'b1;
    wire [ABITS:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
    assign wfull = (wgray == {~rgray_w2[ABITS:ABITS-1], rgray_w2[ABITS-2:0]});

    always @(posedge wclk) begin
        if (wrst) begin
            wbin <= 0; wgray <= 0; rgray_w1 <= 0; rgray_w2 <= 0;
        end else begin
            {rgray_w2, rgray_w1} <= {rgray_w1, rgray};
            if (wr && !wfull) begin
                mem[wbin[ABITS-1:0]] <= wdata;
                wbin  <= wbin_n;
                wgray <= wgray_n;
            end
        end
    end

    wire           rempty = (rgray == wgray_r2);
    wire           fetch  = !rempty && (!valid || rd);
    wire [ABITS:0] rbin_n = rbin + 1'b1;
    assign rvalid = valid;

    always @(posedge rclk) begin
        if (rrst) begin
            rbin <= 0; rgray <= 0; wgray_r1 <= 0; wgray_r2 <= 0; valid <= 0;
        end else begin
            {wgray_r2, wgray_r1} <= {wgray_r1, wgray};
            if (fetch) begin
                rdata <= mem[rbin[ABITS-1:0]];
                rbin  <= rbin_n;
                rgray <= (rbin_n >> 1) ^ rbin_n;
                valid <= 1'b1;
            end else if (rd) begin
                valid <= 1'b0;
            end
        end
    end
endmodule
