// =============================================================================
// tb_dsu_top.sv -- DSU unit testbench: rtl/dsu/dsu_top.v vs DSU_Golden.DSUModel
//
// This is the piece the DSU verification plan's Infrastructure sheet row 4 has
// listed as NOT WRITTEN. Everything it needs already existed:
//   tools/golden/DSU_Golden.py  -- DSUModel, cycle-accurate, validated vs RTL
//   tools/gen/DSU_gen.py        -- emits dsu_stim.mem / dsu_expected.mem
// so this file deliberately adds no golden model of its own. A second model
// would be a second thing to keep in sync, and the two would drift.
//
// FILE FORMAT (fixed-size records, as DSU_gen.py documents)
//   dsu_stim.mem      4 words/test: instr, rs1, rs2, ctrl
//                     ctrl bit 0 = csr_clear_overflow
//                     ctrl bit 8 = dsu_en_n (1 -> drive dsu_en LOW)
//                     Bit 8 was chosen so vectors predating it, which have
//                     ctrl of 0 or 1, still mean exactly what they meant.
//   dsu_expected.mem  8 words/test: rd_data,
//                                   acc_FX[31:0], {16'b0, acc_FX[47:32]},
//                                   acc_FY[31:0], {16'b0, acc_FY[47:32]},
//                                   acc_MAG[31:0],{16'b0, acc_MAG[47:32]},
//                                   flags = {rd_addr[4:0], illegal, rd_valid, overflow}
//
// PER-TEST PROTOCOL -- must match DSU_gen.py exactly, or every record shifts:
//   1. drive the instruction and HOLD it while dsu_busy is asserted. The
//      interlock re-presents the same instruction; it does not skip one.
//   2. sample the outputs on the cycle dsu_busy is low.
//   3. run ONE idle cycle (dsu_en=0) so the MAC's stage 2 commits its pending
//      product. Stage 2 self-drains since ERRATUM DSU-4; before that a trailing
//      "settle" op was needed to force the commit.
//   4. compare the accumulators.
//
// Run:  make test_dsu        (regenerates vectors, then runs this)
// =============================================================================
`timescale 1ns/1ps

module tb_dsu_top;

    // Sized for the --clamp-walk suite, not the everyday one. Reaching the top
    // of the 48-bit accumulator range takes a ~32,768-instruction ramp (the
    // largest single contribution any DSU instruction can make is 2^31), so
    // the vector set that exercises the overflow logic at all is an order of
    // magnitude longer than the functional suite. The end-of-stimulus X marker
    // means a short file still runs in a short time.
    localparam integer MAX_TESTS = 40960;
    localparam integer STIM_W    = 4;
    localparam integer EXP_W     = 8;

    reg [31:0] stim [0:MAX_TESTS*STIM_W-1];
    reg [31:0] exp  [0:MAX_TESTS*EXP_W-1];

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst_n;
    reg         flush;
    reg         dsu_en;
    reg  [31:0] instr, rs1, rs2;
    reg         csr_clear_overflow;

    wire        dsu_busy;
    wire [31:0] dsu_rd_data;
    wire        dsu_rd_valid;
    wire [4:0]  dsu_rd_addr;
    wire        dsu_overflow;
    wire        illegal_instr;
    wire [47:0] dbg_acc_0, dbg_acc_1, dbg_acc_2;

    dsu_top dut (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .dsu_en(dsu_en), .instr(instr), .rs1(rs1), .rs2(rs2),
        .csr_clear_overflow(csr_clear_overflow),
        .dsu_busy(dsu_busy), .dsu_rd_data(dsu_rd_data),
        .dsu_rd_valid(dsu_rd_valid), .dsu_rd_addr(dsu_rd_addr),
        .dsu_overflow(dsu_overflow), .illegal_instr(illegal_instr),
        .dbg_acc_0(dbg_acc_0), .dbg_acc_1(dbg_acc_1), .dbg_acc_2(dbg_acc_2)
    );

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    // Cycle-level trace of the overflow path, for a window of cycles.
    integer tfrom, tto;
    initial begin
        if (!$value$plusargs("TFROM=%d", tfrom)) tfrom = 0;
        if (!$value$plusargs("TTO=%d", tto))     tto   = 0;
    end
    always @(posedge clk) if (tto > 0 && cyc >= tfrom && cyc <= tto)
        $display("[T] c%0d instr=%08x en=%b clr=%0d | pend=%b%b%b macovf=%b satovf=%0d | sticky=%0d acc2=%012x rd=%08x",
                 cyc, instr, dut.u_cluster.en_onehot, csr_clear_overflow,
                 dut.u_cluster.u_mac0.pending, dut.u_cluster.u_mac1.pending,
                 dut.u_cluster.u_mac2.pending,
                 dut.mac_overflow, dut.sat_overflow, dsu_overflow, dbg_acc_2, dsu_rd_data);

    integer ntests, errors, checked, i;
    integer max_report;
    reg [1023:0] stimfile, expfile;

    // Sampled on the completing (non-busy) cycle.
    reg [31:0] s_rd_data;
    reg        s_rd_valid, s_illegal, s_overflow;
    reg [4:0]  s_rd_addr;

    task automatic report_mismatch(input integer idx, input [1023:0] what,
                                   input [47:0] got, input [47:0] want);
        begin
            if (errors <= max_report)
                $display("[FAIL] test %0d  %0s: got %012x expected %012x  (instr=%08x rs1=%08x rs2=%08x)",
                         idx, what, got, want,
                         stim[idx*STIM_W+0], stim[idx*STIM_W+1], stim[idx*STIM_W+2]);
        end
    endtask

    initial begin
        errors = 0; checked = 0;
        if (!$value$plusargs("MAXREPORT=%d", max_report)) max_report = 10;
        if (!$value$plusargs("STIM=%s", stimfile)) stimfile = "sim/dsu/dsu_stim.mem";
        if (!$value$plusargs("EXP=%s",  expfile))  expfile  = "sim/dsu/dsu_expected.mem";

        for (i = 0; i < MAX_TESTS*STIM_W; i = i + 1) stim[i] = 32'hxxxx_xxxx;
        $readmemh(stimfile, stim);
        $readmemh(expfile,  exp);

        // The stimulus file carries one record per test; the first X word marks
        // the end. Counting this way means the testbench never has to be told
        // how many tests the generator produced.
        ntests = 0;
        while (ntests < MAX_TESTS && stim[ntests*STIM_W] !== 32'hxxxx_xxxx)
            ntests = ntests + 1;
        $display("tb_dsu_top: %0d tests from %0s", ntests, stimfile);
        if (ntests == 0) begin
            $display("FATAL: no stimulus - run tools/gen/DSU_gen.py first");
            $finish;
        end

        // ---- reset ----
        rst_n = 1'b0; flush = 1'b0; dsu_en = 1'b0;
        instr = 32'b0; rs1 = 32'b0; rs2 = 32'b0; csr_clear_overflow = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (i = 0; i < ntests; i = i + 1) begin : one_test
            integer guard;
            reg [47:0] e_acc0, e_acc1, e_acc2;
            reg [31:0] flags;

            // ---- 1. drive, holding while the interlock is asserted ----
            instr              = stim[i*STIM_W+0];
            rs1                = stim[i*STIM_W+1];
            rs2                = stim[i*STIM_W+2];
            csr_clear_overflow = stim[i*STIM_W+3][0];
            dsu_en             = ~stim[i*STIM_W+3][8];   // bit 8 = dsu_en_n

            guard = 0;
            #1;                                  // let dsu_busy settle
            while (dsu_busy && guard < 8) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            if (guard >= 8) begin
                $display("[FAIL] test %0d: dsu_busy stuck - interlock is not a one-shot", i);
                errors = errors + 1;
            end

            // ---- 2. sample on the completing cycle ----
            s_rd_data  = dsu_rd_data;
            s_rd_valid = dsu_rd_valid;
            s_rd_addr  = dsu_rd_addr;
            s_illegal  = illegal_instr;
            s_overflow = dsu_overflow;

            @(posedge clk);
            // Drive AWAY from the edge. Assigning at the posedge races the
            // DUT's own flops: the testbench and the DUT can disagree about
            // what was on the wire at the sampling instant. This showed up as
            // a csr_clear_overflow pulse that the model honoured and the RTL
            // appeared to ignore - the clear was simply never seen.
            #1;

            // ---- 3. one idle cycle so stage 2 commits (ERRATUM DSU-4) ----
            dsu_en = 1'b0;
            instr  = 32'b0; rs1 = 32'b0; rs2 = 32'b0; csr_clear_overflow = 1'b0;
            @(posedge clk);
            #1;

            // ---- 4. compare ----
            e_acc0 = {exp[i*EXP_W+2][15:0], exp[i*EXP_W+1]};
            e_acc1 = {exp[i*EXP_W+4][15:0], exp[i*EXP_W+3]};
            e_acc2 = {exp[i*EXP_W+6][15:0], exp[i*EXP_W+5]};
            flags  = exp[i*EXP_W+7];

            checked = checked + 1;
            if ($test$plusargs("DBGOVF") && i >= 18 && i <= 22)
                $display("[DBG] test %0d instr=%08x clr=%0d sampled_ovf=%0d live_ovf=%0d exp_ovf=%0d",
                         i, stim[i*STIM_W+0], stim[i*STIM_W+3][0],
                         s_overflow, dsu_overflow, flags[0]);

            if (dbg_acc_0 !== e_acc0) begin
                errors = errors + 1; report_mismatch(i, "acc_FX",  dbg_acc_0, e_acc0);
            end
            if (dbg_acc_1 !== e_acc1) begin
                errors = errors + 1; report_mismatch(i, "acc_FY",  dbg_acc_1, e_acc1);
            end
            if (dbg_acc_2 !== e_acc2) begin
                errors = errors + 1; report_mismatch(i, "acc_MAG", dbg_acc_2, e_acc2);
            end
            // rd_data only has meaning when the op actually returns one
            if (flags[1] && (s_rd_data !== exp[i*EXP_W+0])) begin
                errors = errors + 1;
                report_mismatch(i, "rd_data", {16'b0, s_rd_data}, {16'b0, exp[i*EXP_W+0]});
            end
            if (s_rd_valid !== flags[1]) begin
                errors = errors + 1; report_mismatch(i, "rd_valid", s_rd_valid, flags[1]);
            end
            if (s_illegal !== flags[2]) begin
                errors = errors + 1; report_mismatch(i, "illegal", s_illegal, flags[2]);
            end
            if (s_overflow !== flags[0]) begin
                errors = errors + 1; report_mismatch(i, "overflow", s_overflow, flags[0]);
            end
            if (s_rd_valid && (s_rd_addr !== flags[7:3])) begin
                errors = errors + 1; report_mismatch(i, "rd_addr", s_rd_addr, flags[7:3]);
            end
        end

        $display("\n============ DSU_TOP vs DSUModel ============");
        $display("  tests compared : %0d", checked);
        $display("  mismatches     : %0d", errors);
        if (errors == 0) $display("  RESULT         : PASSED");
        else             $display("  RESULT         : %0d FAILURES", errors);
        $display("=============================================");
        $finish;
    end

    // Safety net: never let a stuck interlock hang the regression.
    initial begin
        #20_000_000;
        $display("FATAL: tb_dsu_top timeout");
        $finish;
    end

endmodule
