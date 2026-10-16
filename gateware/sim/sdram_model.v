// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioural model of an MT48LC16M16A2-6A (x16, 4 banks, 8192 rows, 512
// columns) for the testbench.  It checks the command sequence and timing the
// controller relies on and prints "SDRAM ERROR" for every violation:
//   init (precharge, two refreshes, mode register) before use, tMRD,
//   tRCD, tRP, tRAS, tRC, tRFC, tWR, refresh interval, commands to closed
//   or open banks, burst length 8 and CAS latency 3 only.
// Output data follows tAC and tOH; DQM masks reads two clocks later and
// writes on the same clock.  Only the low STORE_ROWS row bits are stored, to
// keep simulation memory small; a row beyond that is reported.
`timescale 1ns / 1ps
module sdram_model #(
    parameter STORE_ROWS = 5,
    parameter real T_AC = 5.4, T_OH = 2.7,
    parameter real T_RCD = 18, T_RP = 18, T_RAS = 42, T_RC = 60, T_RFC = 60, T_WR = 12,
    parameter real T_REFI = 7812.5
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n, ras_n, cas_n, we_n,
    input  wire [1:0]  ba,
    input  wire [12:0] a,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);
    integer errors = 0;
    reg [15:0] mem [0:(4 << (STORE_ROWS + 9)) - 1];
    reg        open [0:3];
    reg [12:0] row  [0:3];
    real       t_act [0:3], t_pre [0:3], t_wlast [0:3];
    real       t_ref = -1.0, t_mrs = -1.0e9, t_refcmd = -1.0e9;
    integer    init_refs = 0, i;
    reg        precharged_all = 1'b0, mode_set = 1'b0;
    reg [2:0]  cl = 0;

    // write burst in progress
    integer    wleft = 0;
    reg [1:0]  wbank;
    reg [8:0]  wcol;
    // read data scheduled per clock (index = clock count mod 16)
    reg [15:0] rq_data [0:15];
    reg        rq_valid [0:15];
    reg [1:0]  dqm_d1 = 2'b11, dqm_d2 = 2'b11;
    integer    ck = 0;
    reg [15:0] dq_r = 16'hzzzz;
    assign dq = dq_r;

    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            open[i] = 1'b0; t_act[i] = -1.0e9; t_pre[i] = -1.0e9; t_wlast[i] = -1.0e9;
        end
        for (i = 0; i < 16; i = i + 1) rq_valid[i] = 1'b0;
    end

    task err(input [8*48-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("SDRAM ERROR at %0t: %0s", $time, what);
        end
    endtask

    function [31:0] idx(input [1:0] b, input [12:0] r, input [8:0] c);
        idx = {b, r[STORE_ROWS-1:0], c};
    endfunction

    wire [3:0] c = {cs_n, ras_n, cas_n, we_n};

    always @(posedge clk) begin
        ck = ck + 1;
        // read data for this clock: hold the old word tOH, the new one after tAC
        dq_r <= #(T_OH) 16'hxxxx;
        if (rq_valid[ck % 16] && dqm_d2 != 2'b11)
            dq_r <= #(T_AC) rq_data[ck % 16];
        else
            dq_r <= #(T_AC) 16'hzzzz;
        rq_valid[ck % 16] = 1'b0;
        dqm_d2 = dqm_d1;
        dqm_d1 = dqm;

        // write burst data (the first word arrives with the command, below)
        if (wleft > 0 && c != 4'b0100 && c != 4'b0101) begin
            if (dqm == 2'b00) mem[idx(wbank, row[wbank], wcol)] = dq;
            if (dq === 16'hxxxx || dq === 16'hzzzz) if (dqm != 2'b11) err("write data undriven");
            wcol = wcol + 1;
            wleft = wleft - 1;
            if (dqm != 2'b11) t_wlast[wbank] = $realtime;
        end

        if (cke && !cs_n) case (c)
        4'b0011: begin                                          // ACTIVE
            if (!mode_set) err("ACTIVE before mode register set");
            if (open[ba]) err("ACTIVE to an open bank");
            if ($realtime - t_pre[ba] < T_RP) err("tRP");
            if ($realtime - t_act[ba] < T_RC) err("tRC");
            if ($realtime - t_refcmd < T_RFC) err("tRFC");
            if ($realtime - t_mrs < 19.9) err("tMRD");
            if (a >= (1 << STORE_ROWS)) err("row beyond the modelled range");
            open[ba] = 1'b1; row[ba] = a; t_act[ba] = $realtime;
        end
        4'b0100: begin                                          // WRITE
            if (!open[ba]) err("WRITE to a closed bank");
            if ($realtime - t_act[ba] < T_RCD) err("tRCD (write)");
            if (a[10]) err("auto precharge not expected");
            if (a[2:0] != 0) err("burst not aligned to 8");
            wbank = ba; wcol = a[8:0]; wleft = 7;
            if (dqm == 2'b00) mem[idx(ba, row[ba], a[8:0])] = dq;
            if (dqm != 2'b11) t_wlast[ba] = $realtime;
            wcol = wcol + 1;
        end
        4'b0101: begin                                          // READ
            if (!open[ba]) err("READ to a closed bank");
            if ($realtime - t_act[ba] < T_RCD) err("tRCD (read)");
            if (a[10]) err("auto precharge not expected");
            if (cl != 3) err("CAS latency is not 3");
            wleft = 0;
            for (i = 0; i < 8; i = i + 1) begin
                rq_data[(ck + 2 + i) % 16]  = mem[idx(ba, row[ba], a[8:0] + i)];
                rq_valid[(ck + 2 + i) % 16] = 1'b1;
            end
        end
        4'b0010: begin                                          // PRECHARGE
            for (i = 0; i < 4; i = i + 1)
                if (a[10] || ba == i) begin
                    if (open[i] && $realtime - t_act[i] < T_RAS) err("tRAS");
                    if (open[i] && $realtime - t_wlast[i] < T_WR) err("tWR");
                    open[i] = 1'b0; t_pre[i] = $realtime;
                end
            if (a[10]) precharged_all = 1'b1;
        end
        4'b0001: begin                                          // AUTO REFRESH
            for (i = 0; i < 4; i = i + 1) begin
                if (open[i]) err("REFRESH with a bank open");
                if ($realtime - t_pre[i] < T_RP) err("tRP before REFRESH");
            end
            if ($realtime - t_refcmd < T_RFC) err("tRFC");
            if (t_ref > 0 && mode_set && $realtime - t_ref > T_REFI) err("refresh interval");
            t_ref = $realtime; t_refcmd = $realtime;
            init_refs = init_refs + 1;
        end
        4'b0000: begin                                          // LOAD MODE REGISTER
            if (!precharged_all || init_refs < 2) err("mode register before init sequence");
            if (a[2:0] != 3'b011) err("burst length is not 8");
            if (a[3]) err("interleaved burst");
            if (a[9]) err("single-location write mode");
            cl = a[6:4];
            mode_set = 1'b1; t_mrs = $realtime;
            t_ref = $realtime;
        end
        default: ;
        endcase

        if (mode_set && t_ref > 0 && $realtime - t_ref > T_REFI + 100) begin
            err("refresh overdue");
            t_ref = $realtime;
        end
    end
endmodule
