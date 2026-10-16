// SPDX-License-Identifier: GPL-3.0-or-later
// s6la8 top level.  Pin names match the nets in hardware/s6la8.zen.
//
// Buffered captures go to block RAM (32 K samples) or, with register 0x07
// bit 0 set, to the SDRAM (32 M samples).
// Not implemented yet: 200 MS/s double-edge sampling, external clock, and
// deskew of IFCLK.
module top #(
    parameter FLUSH = 20'd480000,     // idle IFCLK cycles before a short packet is sent
    parameter SD_SABITS = 25,         // SDRAM ring: 2**25 samples (the whole 256 Mbit part)
    parameter SD_INIT_WAIT = 20000    // 200 us power-up wait at 100 MHz
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

    wire clk, clk_sdrd, locked;
    clkgen u_clk (.clk50(CLK50), .clk(clk), .clk_sdrd(clk_sdrd), .locked(locked));

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
    reg         mem_sel = 1'b0;       // 0x07 bit 0: buffer in SDRAM
    wire        sd_ready;
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
                7'h07: mem_sel        <= wdata[0] & sd_ready;
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
            7'h03: rdata = mem_sel ? SD_SABITS : ABITS;   // log2 of buffer depth
            7'h07: rdata = {sd_ready, 6'b0, mem_sel};
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
    reg        rst = 1'b1, rst_hw = 1'b1;   // rst_hw: PLL lock only; the SDRAM
    reg [4:0]  rst_cnt = 5'h1f;             // keeps refreshing through soft resets
    always @(posedge clk) begin
        if (!locked || soft_rst) rst_cnt <= 5'h1f;
        else if (rst_cnt != 0)   rst_cnt <= rst_cnt - 1'b1;
        rst <= (rst_cnt != 0);
        rst_hw <= !locked;
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

    wire        m_start, m_wr, m_stop, m_play, m_q_rd;
    wire [7:0]  m_wdata;
    wire [31:0] m_play_addr, m_play_len;
    wire [7:0]  b_q, d_q;
    wire        b_q_valid, b_done, d_q_valid, d_done, d_drained, d_overflow;
    wire [31:0] depth = mem_sel ? ((32'd1 << SD_SABITS) - 32'd16) : (32'd1 << ABITS);

    capture u_cap (
        .clk(clk), .rst(rst), .probe(probe), .depth(depth),
        .run_stream(ctrl[0]), .arm(arm), .force_trig(force_trig),
        .divider(divider), .pre(pre), .post(post), .nstages(nstages[1:0]),
        .stage0(stages[31:0]), .stage1(stages[63:32]), .stage2(stages[95:64]), .stage3(stages[127:96]),
        .armed(armed), .triggered(triggered), .done(done), .overflow(overflow), .trigpos(trigpos),
        .out(cap_out), .out_wr(cap_wr), .out_full(fifo_full),
        .mem_start(m_start), .mem_wr(m_wr), .mem_wdata(m_wdata), .mem_stop(m_stop),
        .mem_drained(mem_sel ? d_drained : 1'b1), .mem_overflow(mem_sel & d_overflow),
        .mem_play(m_play), .mem_play_addr(m_play_addr), .mem_play_len(m_play_len),
        .mem_q(mem_sel ? d_q : b_q), .mem_q_valid(mem_sel ? d_q_valid : b_q_valid), .mem_q_rd(m_q_rd),
        .mem_play_done(mem_sel ? d_done : b_done));

    ring_bram #(.ABITS(ABITS)) u_bram (
        .clk(clk), .rst(rst), .start(m_start & !mem_sel), .wr(m_wr & !mem_sel), .wdata(m_wdata),
        .play(m_play & !mem_sel), .play_addr(m_play_addr[ABITS-1:0]), .play_len(m_play_len[ABITS:0]),
        .q(b_q), .q_valid(b_q_valid), .q_rd(m_q_rd & !mem_sel), .play_done(b_done));

    // ------------------------------------------------------------ SDRAM
    wire        sd_cke_i, sd_cs_i, sd_ras_i, sd_cas_i, sd_we_i, sd_oe;
    wire [1:0]  sd_ba_i, sd_dqm_i;
    wire [12:0] sd_a_i;
    wire [15:0] sd_dq_o;
    (* IOB = "TRUE" *) reg [15:0] sd_dq_in = 0;
    always @(posedge clk_sdrd) sd_dq_in <= SD_DQ;   // middle of the read data window

    ring_sdram #(.SABITS(SD_SABITS), .INIT_WAIT(SD_INIT_WAIT)) u_sdram (
        .clk(clk), .rst(rst_hw), .soft_rst(rst), .ready(sd_ready),
        .start(m_start & mem_sel), .wr(m_wr & mem_sel), .wdata(m_wdata), .overflow(d_overflow),
        .stop(m_stop & mem_sel), .drained(d_drained),
        .play(m_play & mem_sel), .play_addr(m_play_addr[SD_SABITS-1:0]), .play_len(m_play_len[SD_SABITS:0]),
        .q(d_q), .q_valid(d_q_valid), .q_rd(m_q_rd & mem_sel), .play_done(d_done),
        .sd_cke(sd_cke_i), .sd_cs_n(sd_cs_i), .sd_ras_n(sd_ras_i), .sd_cas_n(sd_cas_i), .sd_we_n(sd_we_i),
        .sd_ba(sd_ba_i), .sd_a(sd_a_i), .sd_dqm(sd_dqm_i), .sd_dq_out(sd_dq_o), .sd_dq_oe(sd_oe),
        .sd_dq_in(sd_dq_in));

    // The SDRAM clock is the system clock inverted: commands and write data
    // change on the rising edge and the SDRAM samples them half a period later.
    ODDR2 #(.DDR_ALIGNMENT("NONE"), .SRTYPE("SYNC")) u_sdclk (
        .Q(SD_CLK), .C0(clk), .C1(~clk), .CE(1'b1), .D0(1'b0), .D1(1'b1), .R(1'b0), .S(1'b0));
    assign SD_CKE   = sd_cke_i;
    assign SD_CS_N  = sd_cs_i;
    assign SD_RAS_N = sd_ras_i;
    assign SD_CAS_N = sd_cas_i;
    assign SD_WE_N  = sd_we_i;
    assign SD_BA0   = sd_ba_i[0];
    assign SD_BA1   = sd_ba_i[1];
    assign SD_A     = sd_a_i;
    assign SD_DQML  = sd_dqm_i[0];
    assign SD_DQMH  = sd_dqm_i[1];
    assign SD_DQ    = sd_oe ? sd_dq_o : 16'hzzzz;

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

endmodule
