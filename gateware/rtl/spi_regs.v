// SPDX-License-Identifier: GPL-3.0-or-later
// SPI slave (mode 0, MSB first), oversampled in the system clock domain.
// Frame: one address byte (bit 7 set = read), then data bytes; the address
// increments after each byte.
module spi_regs (
    input  wire       clk,
    input  wire       sck,
    input  wire       mosi,
    input  wire       cs_n,
    output reg        miso = 1'b0,

    output reg  [6:0] addr = 0,
    output reg  [7:0] wdata = 0,
    output reg        wstrobe = 1'b0,
    input  wire [7:0] rdata
);
    reg [2:0] sck_s = 0;
    reg [1:0] cs_s = 2'b11;
    reg [1:0] mosi_s = 0;
    reg [2:0] bitcnt = 0;
    reg [6:0] shift = 0;
    reg [7:0] tx = 0;
    reg       have_addr = 1'b0, is_read = 1'b0;

    wire sck_rise = (sck_s[2:1] == 2'b01);
    wire sck_fall = (sck_s[2:1] == 2'b10);
    wire active   = !cs_s[1];

    always @(posedge clk) begin
        sck_s  <= {sck_s[1:0], sck};
        cs_s   <= {cs_s[0], cs_n};
        mosi_s <= {mosi_s[0], mosi};
        wstrobe <= 1'b0;
        if (wstrobe) addr <= addr + 1'b1;

        if (!active) begin
            bitcnt <= 0; have_addr <= 1'b0; is_read <= 1'b0;
        end else if (sck_rise) begin
            shift  <= {shift[5:0], mosi_s[1]};
            bitcnt <= bitcnt + 1'b1;
            if (bitcnt == 3'd7) begin
                if (!have_addr) begin
                    have_addr <= 1'b1;
                    is_read   <= shift[6];
                    addr      <= {shift[5:0], mosi_s[1]};
                end else if (!is_read) begin
                    wdata   <= {shift[6:0], mosi_s[1]};
                    wstrobe <= 1'b1;
                end
            end
        end else if (sck_fall && have_addr && is_read) begin
            if (bitcnt == 3'd0) begin
                miso <= rdata[7];
                tx   <= {rdata[6:0], 1'b0};
            end else begin
                miso <= tx[7];
                tx   <= {tx[6:0], 1'b0};
            end
            if (bitcnt == 3'd7) addr <= addr + 1'b1;
        end
    end
endmodule
