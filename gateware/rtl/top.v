// SPDX-License-Identifier: GPL-3.0-or-later
// s6la8 top level.  Pin names match the nets in hardware/s6la8.zen.
//
// Not implemented yet: the SDRAM deep buffer (the SDRAM is held deselected),
// 200 MS/s double-edge sampling, external clock, and deskew of IFCLK.
module top #(
    parameter FLUSH = 20'd480000      // idle IFCLK cycles before a short packet is sent
) (
    input  wire        CLK50,
    input  wire        IFCLK,
    input  wire [7:0]  CH,
    input  wire        EXT_CLK,
    input  wire        TRIG,

    inout  wire [7:0]  FD,
    output wire        SLWR,
    output wire        SLRD,
    output wire        SLOE,
    output wire        PKTEND,
    output wire        FIFOADR0,
    output wire        FIFOADR1,
    input  wire        FLAGA,
    input  wire        FLAGB,
    input  wire        FLAGC,

    input  wire        CCLK,          // REG_SCK after configuration
    input  wire        REG_MOSI,
    output wire        REG_MISO,
    input  wire        REG_CS_N,
    output wire        FPGA_IRQ_N,
    input  wire        FB_OE_N,

    output wire        LED1_K,
    output wire        LED2_K,

    output wire        SD_CLK,
    output wire        SD_CKE,
    output wire        SD_CS_N,
    output wire        SD_RAS_N,
    output wire        SD_CAS_N,
    output wire        SD_WE_N,
    output wire        SD_DQML,
    output wire        SD_DQMH,
    output wire        SD_BA0,
    output wire        SD_BA1,
    output wire [12:0] SD_A,
    inout  wire [15:0] SD_DQ
);
    localparam [7:0] VERSION = 8'h01;
    localparam ABITS = 15;

    wire clk, locked;
    clkgen u_clk (.clk50(CLK50), .clk(clk), .locked(locked));

    // ------------------------------------------------------------ authentication
    // Production bitstreams only capture on boards whose EEPROM holds the tag
    // for this FPGA's Device DNA (rtl/dna_auth.v, tools/provision.py).
`ifdef S6LA8_PRODUCTION
    `include "auth_key.vh"
`else
    `include "auth_key_dev.vh"
`endif
    reg [63:0]  auth_tag = 0;         // 0x30..0x37, from the EEPROM via the FX2
    reg         auth_check = 1'b0;
    wire [56:0] dna;
    wire        dna_valid, auth_ok, auth_busy;
    wire [63:0] dna64 = {7'b0, dna};
    wire        enabled = !AUTH_REQUIRED || auth_ok;
    dna_auth #(.KEY(AUTH_KEY)) u_auth (.clk(clk), .tag(auth_tag), .check(auth_check),
        .dna(dna), .dna_valid(dna_valid), .ok(auth_ok), .busy(auth_busy));

    // ------------------------------------------------------------ registers
    wire [6:0] addr;
    wire [7:0] wdata;
    wire       wstrobe;
    reg  [7:0] rdata;
    spi_regs u_spi (.clk(clk), .sck(CCLK), .mosi(REG_MOSI), .cs_n(REG_CS_N), .miso(REG_MISO),
                    .addr(addr), .wdata(wdata), .wstrobe(wstrobe), .rdata(rdata));

    reg [7:0]   ctrl = 0, leds = 0, nstages = 0;
    reg [31:0]  divider = 0, pre = 0, post = 0;
    reg [127:0] stages = 0;           // four 32-bit trigger stages at 0x18..0x27
    reg         arm = 1'b0, soft_rst = 1'b0, force_trig = 1'b0;
    wire        armed, triggered, done, overflow;
    wire [31:0] trigpos;
    wire [3:0]  stage_off = addr[3:0] - 4'h8;        // 0x18..0x27 -> 0..15

    always @(posedge clk) begin
        arm <= 1'b0; soft_rst <= 1'b0; force_trig <= 1'b0; auth_check <= 1'b0;
        if (wstrobe) begin
            case (addr)
                7'h04: begin
                    ctrl       <= wdata & {7'h02, enabled};   // run_stream, testgen
                    arm        <= wdata[1] & enabled;
                    soft_rst   <= wdata[3];
                    force_trig <= wdata[4];
                end
                7'h08: divider[7:0]   <= wdata;
                7'h09: divider[15:8]  <= wdata;
                7'h0a: divider[23:16] <= wdata;
                7'h0b: divider[31:24] <= wdata;
                7'h0c: post[7:0]      <= wdata;
                7'h0d: post[15:8]     <= wdata;
                7'h0e: post[23:16]    <= wdata;
                7'h0f: post[31:24]    <= wdata;
                7'h10: pre[7:0]       <= wdata;
                7'h11: pre[15:8]      <= wdata;
                7'h12: pre[23:16]     <= wdata;
                7'h13: pre[31:24]     <= wdata;
                7'h28: nstages        <= wdata;
                7'h2c: leds           <= wdata;
                7'h06: auth_check     <= wdata[0];
                default: ;
            endcase
            if (addr >= 7'h18 && addr < 7'h28)
                stages[8*stage_off +: 8] <= wdata;
            if (addr >= 7'h30 && addr < 7'h38)
                auth_tag[8*addr[2:0] +: 8] <= wdata;
        end
    end

    always @(*) begin
        case (addr)
            7'h00: rdata = 8'h53;                     // 'S'
            7'h01: rdata = 8'h36;                     // '6'
            7'h02: rdata = VERSION;
            7'h03: rdata = ABITS;                     // log2 of buffer depth
            7'h04: rdata = ctrl;
            7'h05: rdata = {3'b0, overflow, done, triggered, armed, ctrl[0]};
            7'h14: rdata = trigpos[7:0];
            7'h15: rdata = trigpos[15:8];
            7'h16: rdata = trigpos[23:16];
            7'h17: rdata = trigpos[31:24];
            7'h06: rdata = {4'b0, AUTH_REQUIRED[0], auth_busy, auth_ok, dna_valid};
            7'h2c: rdata = leds;
            7'h38, 7'h39, 7'h3a, 7'h3b, 7'h3c, 7'h3d, 7'h3e, 7'h3f:
                   rdata = dna64[8*addr[2:0] +: 8];
            default: rdata = 8'h00;
        endcase
    end

    // ------------------------------------------------------------ sampling
    reg [7:0] ch_s1 = 0, ch_s2 = 0, testcnt = 0;
    always @(posedge clk) begin
        ch_s1 <= CH;
        ch_s2 <= ch_s1;
    end

    wire [7:0] cap_out;
    wire       cap_wr, fifo_full;
    // Hold reset long enough for the 48 MHz domain to see it.
    reg        rst = 1'b1;
    reg [4:0]  rst_cnt = 5'h1f;
    always @(posedge clk) begin
        if (!locked || soft_rst) rst_cnt <= 5'h1f;
        else if (rst_cnt != 0)   rst_cnt <= rst_cnt - 1'b1;
        rst <= (rst_cnt != 0);
    end

    // The test pattern counts once per sample, so the host can check it.
    reg [31:0] tdiv = 0;
    always @(posedge clk) begin
        if (rst || !ctrl[2]) begin
            tdiv <= 0; testcnt <= 0;
        end else if (tdiv == 0) begin
            tdiv <= divider; testcnt <= testcnt + 1'b1;
        end else begin
            tdiv <= tdiv - 1'b1;
        end
    end
    wire [7:0] probe = ctrl[2] ? testcnt : ch_s2;

    capture #(.ABITS(ABITS)) u_cap (
        .clk(clk), .rst(rst), .probe(probe),
        .run_stream(ctrl[0]), .arm(arm), .force_trig(force_trig),
        .divider(divider), .pre(pre), .post(post), .nstages(nstages[1:0]),
        .stage0(stages[31:0]), .stage1(stages[63:32]), .stage2(stages[95:64]), .stage3(stages[127:96]),
        .armed(armed), .triggered(triggered), .done(done), .overflow(overflow), .trigpos(trigpos),
        .out(cap_out), .out_wr(cap_wr), .out_full(fifo_full));

    // ------------------------------------------------------------ FX2 side
    wire       ifclk = IFCLK;
    wire [7:0] fifo_q, fd_out;
    wire       fifo_valid, fifo_rd, fd_oe, slwr_n, pktend_n;
    reg  [1:0] rst_if = 2'b11, fb_s = 2'b00;
    always @(posedge ifclk) begin
        rst_if <= {rst_if[0], rst};
        fb_s   <= {fb_s[0], FB_OE_N};
    end

    afifo #(.WIDTH(8), .ABITS(12)) u_fifo (
        .wclk(clk), .wrst(rst), .wr(cap_wr), .wdata(cap_out), .wfull(fifo_full),
        .rclk(ifclk), .rrst(rst_if[1]), .rd(fifo_rd), .rdata(fifo_q), .rvalid(fifo_valid));

    // The FPGA may drive FD only while the FX2 holds the fallback buffer off.
    fx2_sfifo #(.FLUSH(FLUSH)) u_sfifo (
        .ifclk(ifclk), .rst(rst_if[1]), .enable(fb_s[1]), .flag_full_n(FLAGB),
        .slwr_n(slwr_n), .pktend_n(pktend_n), .fd(fd_out), .fd_oe(fd_oe),
        .din(fifo_q), .din_valid(fifo_valid), .din_rd(fifo_rd));

    assign FD       = (fd_oe && FB_OE_N) ? fd_out : 8'hzz;
    assign SLWR     = fb_s[1] ? slwr_n : 1'bz;
    assign PKTEND   = fb_s[1] ? pktend_n : 1'bz;
    assign SLRD     = 1'bz;                       // pulled up on the board
    assign SLOE     = 1'bz;
    assign FIFOADR0 = 1'bz;                       // pulled down: EP2
    assign FIFOADR1 = 1'bz;
    assign FPGA_IRQ_N = !done;

    assign LED1_K = !(armed || ctrl[0] || leds[0]);
    assign LED2_K = !(overflow || leds[1]);

    // SDRAM parked: deselected, clock stopped.
    assign SD_CLK   = 1'b0;
    assign SD_CKE   = 1'b0;
    assign SD_CS_N  = 1'b1;
    assign SD_RAS_N = 1'b1;
    assign SD_CAS_N = 1'b1;
    assign SD_WE_N  = 1'b1;
    assign SD_DQML  = 1'b1;
    assign SD_DQMH  = 1'b1;
    assign SD_BA0   = 1'b0;
    assign SD_BA1   = 1'b0;
    assign SD_A     = 13'd0;
    assign SD_DQ    = 16'hzzzz;
endmodule
