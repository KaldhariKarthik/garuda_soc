`timescale 1ns/1ps
// =============================================================================
// tb_debug_dm.sv -- unit bench of debug_module on the hclk side (Track A plan 6A.5
// step G1). DMI requests are driven straight into the module (no TAP, no crossing),
// and the SBA master is a stub whose completion cycle the bench knows exactly, so a
// DMI write can be placed in the very cycle an SBA transfer completes.
//
//   T1 DBG-4    an SBA bus error completes in the cycle of a debugger write to sbcs
//               that has a W1C bit set: sberror must still read 4 ([N-7.6]; hardware
//               set wins, the rule DMA [N-7.19] states for the same pattern)
//   T2 control  the same with an sbcs write that clears nothing: sberror 4
//   T3 control  a W1C of sberror = 4 clears it when no transfer completes
//   T4 control  dmcontrol.dmactive = 0 in the error's completion cycle: the DM reset
//               wins (sberror 0, spec 6.5)
//   T5 control  a W1C in the completion cycle of a GOOD transfer: sberror stays 0 and
//               the read data still lands in sbdata0
// =============================================================================
module tb_debug_dm;
    reg hclk = 0, rst_n = 0;
    always #2 hclk = ~hclk;

    reg         req = 0;
    reg  [6:0]  addr = 0;
    reg  [31:0] wdata = 0;
    reg  [1:0]  op = 0;
    wire [31:0] rdata;
    wire        done, ndmreset, hartreset, halt_req;
    wire        sba_start, sba_write;
    wire [31:0] sba_addr, sba_wdata;
    reg         sba_done = 0, sba_err = 0, sba_busy = 0;
    reg  [31:0] sba_rdata = 32'h1234_5678;

    debug_module dut (
        .hclk_i(hclk), .dm_rst_n_i(rst_n), .req_i(req), .addr_i(addr), .wdata_i(wdata), .op_i(op),
        .rdata_o(rdata), .done_o(done), .ndmreset_o(ndmreset), .hartreset_o(hartreset),
        .halt_req_o(halt_req), .halt_safe_i(1'b1),
        .dsu_acc0_i(48'd0), .dsu_acc1_i(48'd0), .dsu_acc2_i(48'd0), .dsu_ovf_i(1'b0),
        .sba_start_o(sba_start), .sba_write_o(sba_write), .sba_addr_o(sba_addr),
        .sba_wdata_o(sba_wdata), .sba_done_i(sba_done), .sba_err_i(sba_err),
        .sba_rdata_i(sba_rdata), .sba_busy_i(sba_busy));

    localparam [6:0] A_DMCONTROL = 7'h10, A_SBCS = 7'h38, A_SBADDR0 = 7'h39, A_SBDATA0 = 7'h3C;
    // sbcs fields (Debug 0.13): [22] sbbusyerror W1C, [20] sbreadonaddr, [19:17] sbaccess,
    // [16] sbautoincrement, [15] sbreadondata, [14:12] sberror W1C
    localparam [31:0] SBCS_RDONADDR = 32'h0014_0000;            // sbreadonaddr, sbaccess = 2 (word)
    localparam [31:0] SBCS_W1C_ALL  = 32'h0014_7000;            // the same + write 1 to sberror[14:12]

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    // one DMI access in one hclk cycle (the DM answers the next cycle)
    task automatic dmi(input [6:0] a, input [31:0] d, input [1:0] o);
        @(negedge hclk); req = 1; addr = a; wdata = d; op = o;
        @(negedge hclk); req = 0; op = 0;
    endtask
    task automatic dmi_rd(input [6:0] a, output [31:0] r);
        dmi(a, 0, 2'd1); r = rdata;
    endtask

    // SBA stub: a transfer runs WAIT cycles (sba_busy high), then sba_done (with sba_err if
    // asked) is high for one cycle, one cycle after busy falls (DBG-2 timing of sba_master).
    integer WAIT = 3;
    reg     next_err = 0;
    always @(posedge hclk) begin
        sba_done <= 1'b0; sba_err <= 1'b0;
        if (sba_start) begin
            sba_busy <= 1'b1;
            fork begin
                repeat (WAIT) @(posedge hclk);
                sba_busy <= 1'b0;
                @(posedge hclk);
                sba_done <= 1'b1; sba_err <= next_err;
            end join_none
        end
    end

    // start an SBA read (sbreadonaddr) and put a DMI write in its completion cycle
    task automatic read_with_write_at_done(input bit err, input [6:0] wa, input [31:0] wd);
        next_err = err;
        dmi(A_SBADDR0, 32'h0000_0100, 2'd2);       // starts the read (sba_start next cycle)
        @(negedge hclk);
        while (sba_done !== 1'b1) @(negedge hclk);  // sba_done is high in this cycle: the DM
        req = 1; addr = wa; wdata = wd; op = 2'd2;    // samples it and req on the same edge
        @(negedge hclk); req = 0; op = 0;
        repeat (2) @(negedge hclk);
    endtask

    reg [31:0] r;
    initial begin
        $display("=== tb_debug_dm: debug_module unit bench (DBG-4 and controls) ===");
        repeat (3) @(negedge hclk); rst_n = 1;
        dmi(A_DMCONTROL, 32'h0000_0001, 2'd2);      // dmactive
        dmi(A_SBCS, SBCS_RDONADDR, 2'd2);

        // ---- T1 DBG-4 -------------------------------------------------------------------
        read_with_write_at_done(1'b1, A_SBCS, SBCS_W1C_ALL);
        dmi_rd(A_SBCS, r);
        check(r[14:12] == 3'd4, "T1 DBG-4: SBA bus error in the cycle of an sbcs W1C write reads sberror = 4");

        // ---- T3 control: W1C clears ----------------------------------------------------------
        dmi(A_SBCS, SBCS_W1C_ALL, 2'd2);
        dmi_rd(A_SBCS, r);
        check(r[14:12] == 3'd0, "T3 control: W1C clears sberror when no transfer completes");

        // ---- T2 control: sbcs write that clears nothing ---------------------------------------
        read_with_write_at_done(1'b1, A_SBCS, SBCS_RDONADDR);
        dmi_rd(A_SBCS, r);
        check(r[14:12] == 3'd4, "T2 control: SBA bus error with an sbcs write that clears nothing reads 4");

        // ---- T5 control: W1C in a good transfer's completion cycle ----------------------------
        dmi(A_SBCS, SBCS_W1C_ALL, 2'd2);            // clear T2's error (no transfer can start with it set)
        sba_rdata = 32'hC0DE_0005;
        read_with_write_at_done(1'b0, A_SBCS, SBCS_W1C_ALL);
        dmi_rd(A_SBCS, r);
        check(r[14:12] == 3'd0, "T5 control: W1C in a good transfer's completion cycle leaves sberror 0");
        dmi_rd(A_SBDATA0, r);
        check(r == 32'hC0DE_0005, "T5 control: the read data of that transfer is in sbdata0");

        // ---- T4 control: DM reset in the error's completion cycle wins -----------------------------
        read_with_write_at_done(1'b1, A_DMCONTROL, 32'h0000_0000);
        dmi(A_DMCONTROL, 32'h0000_0001, 2'd2);
        dmi_rd(A_SBCS, r);
        check(r[14:12] == 3'd0, "T4 control: dmactive = 0 in the error's completion cycle resets sberror");

        // ---- T6 DBG-7: a halted hart stays halted when the debugger clears haltreq -------------
        // Debug 0.13: haltreq only requests; once the hart is halted the debugger writes dmcontrol
        // with haltreq = 0 (OpenOCD does this after every halt), and the hart stays halted until
        // resumereq. GARUDA's halt is hartreset ([N-7.8]); that write must not release it.
        dmi(A_DMCONTROL, 32'h8000_0001, 2'd2);              // haltreq
        repeat (4) @(negedge hclk);
        dmi_rd(7'h11, r);
        check(r[9:8] == 2'b11, "T6 haltreq halts the hart (dmstatus allhalted/anyhalted)");
        dmi(A_DMCONTROL, 32'h0000_0001, 2'd2);              // the debugger clears haltreq
        repeat (4) @(negedge hclk);
        dmi_rd(7'h11, r);
        check(r[9:8] == 2'b11, "T6 DBG-7: clearing haltreq keeps the hart halted (only resumereq resumes)");
        dmi(A_DMCONTROL, 32'h4000_0001, 2'd2);              // resumereq
        repeat (4) @(negedge hclk);
        dmi_rd(7'h11, r);
        check(r[11:10] == 2'b11, "T6 resumereq resumes the hart (allrunning/anyrunning)");
        // ---- T7 DBG-8: the resume is acknowledged (Debug 0.13 dmstatus allresumeack/anyresumeack,
        // which a debugger polls after resumereq); a new resumereq clears it (spec table, bit 16/17),
        // and it is set again only when the hart runs
        check(r[17:16] == 2'b11, "T7 DBG-8: after resumereq dmstatus reports allresumeack/anyresumeack");
        dmi(A_DMCONTROL, 32'h8000_0001, 2'd2); repeat (4) @(negedge hclk);   // halt again
        // resumereq with the hartreset field set: the ack is cleared, but the hart stays held,
        // so the clear can be read (an ack that never clears would pass T7 otherwise; 2026-11-01)
        dmi(A_DMCONTROL, 32'h6000_0001, 2'd2); repeat (4) @(negedge hclk);
        dmi_rd(7'h11, r);
        check(r[17:16] == 2'b00 && r[9:8] == 2'b11, "T7 resumereq clears allresumeack/anyresumeack while the hart is still held");
        dmi(A_DMCONTROL, 32'h0000_0001, 2'd2);              // release hartreset: the hart runs
        repeat (4) @(negedge hclk);
        dmi_rd(7'h11, r);
        check(r[17:16] == 2'b11 && r[11:10] == 2'b11, "T7 a second resume is acknowledged too");
        $display("tb_debug_dm: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #200000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
