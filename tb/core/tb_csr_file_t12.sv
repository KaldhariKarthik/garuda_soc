// =============================================================================
// tb_csr_file_t12.sv -- T-12: the interrupt-level stack across nested traps.
//
// Drives csr_file directly, the way trap_ctrl does (trap_enter / mret pulses
// with is_interrupt and the taken CLIC level), and plays the firmware side:
// a handler that can be preempted or can trap SAVES mcause on entry and
// RESTORES it before its mret (the CLIC rule, DN-T12; TRM firmware rule).
// The level stack is then architecturally visible and software-restorable.
//
// Contract (DN-T12, Track A plan W3; rulings R1-R3 pending with Karthik):
//   every trap        mcause[23:16] <- mil (the level being left)
//   CLIC interrupt    mil <- its level (always >= 1: the take needs level > mil)
//   exception, MTI    mil unchanged (R1)
//   mret              mil <- mcause[23:16]
//   mintstatus 0x346  {24'b0, mil}            (R2: no mpil in [15:8])
//   mintstatus 0xFB1  {mil, 24'b0}            (R3: ratified Smclic layout)
//
// Scenarios (each a [FAIL] line on the pre-fix RTL, where mpil was one hidden
// register pushed only by interrupts and popped by every mret):
//   A  nesting 80 -> 200, unwind: level returns to 80, then to 0
//   B  exception inside a level-80 handler: the level stays 80, and after
//      the exception's mret it is still 80; the handler's mret returns to 0
//   C  machine-timer interrupt inside a level-80 handler: the level stays 80
//   D  depth 3 (40 -> 120 -> 200) and the full unwind
//   E  mcause carries the level left; outside handlers mcause is the plain cause
//   F  the two mintstatus layouts
// =============================================================================
`timescale 1ns/1ps
`include "core_ex_defs.vh"

module tb_csr_file_t12;
    logic        clk = 1'b0;
    always #5 clk = ~clk;
    logic        rst_n, csr_en, trap_enter, mret, is_int;
    logic [7:0]  lvl;
    logic [11:0] addr;
    logic [31:0] wdata, tpc, tcause, ttval;
    logic [1:0]  op;
    wire  [31:0] rdata, mtvec, mepc;
    wire  [7:0]  mil, ithr;
    wire         illegal, mie, clr_ovf;

    csr_file dut (
        .clk_i(clk), .rst_n_i(rst_n), .csr_en_i(csr_en), .commit_i(1'b1), .csr_addr_i(addr),
        .csr_wdata_i(wdata), .csr_op_i(op), .csr_rdata_o(rdata), .illegal_csr_o(illegal),
        .instret_i(1'b0), .dsu_overflow_i(1'b0), .csr_clear_overflow_o(clr_ovf),
        .trap_enter_i(trap_enter), .mret_i(mret), .is_interrupt_i(is_int), .clic_level_i(lvl),
        .trap_pc_i(tpc), .trap_cause_i(tcause), .trap_tval_i(ttval), .mtip_i(1'b0),
        .mstatus_mie_o(mie), .mtvec_o(mtvec), .mepc_o(mepc), .mintthresh_o(ithr),
        .mintstatus_mil_o(mil), .mti_pending_o());

    int checks = 0, errors = 0;

    task automatic chk(input string what, input logic [31:0] got, input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("[FAIL] %-48s got %08h expected %08h", what, got, exp);
        end else
            $display("[PASS] %-48s %08h", what, got);
    endtask

    // one trap_ctrl-style pulse, applied between clock edges
    task automatic trap(input logic interrupt, input logic [7:0] level, input logic [31:0] cause);
        @(negedge clk);
        trap_enter = 1'b1; is_int = interrupt; lvl = interrupt ? level : 8'd0;
        tcause = cause; tpc = 32'h1000_0100; ttval = 32'd0;
        @(negedge clk);
        trap_enter = 1'b0; is_int = 1'b0; lvl = 8'd0;
    endtask

    task automatic do_mret();
        @(negedge clk); mret = 1'b1;
        @(negedge clk); mret = 1'b0;
    endtask

    task automatic csr_read(input logic [11:0] a, output logic [31:0] v);
        @(negedge clk); csr_en = 1'b1; addr = a; op = `CSR_RS; wdata = 32'd0;
        #1 v = rdata;
        @(negedge clk); csr_en = 1'b0; op = 2'b00;
    endtask

    task automatic csr_write(input logic [11:0] a, input logic [31:0] v);
        @(negedge clk); csr_en = 1'b1; addr = a; op = `CSR_RW; wdata = v;
        @(negedge clk); csr_en = 1'b0; op = 2'b00;
    endtask

    // every scenario starts from reset, so one failure cannot mask the next
    task automatic do_reset();
        @(negedge clk); rst_n = 1'b0;
        @(negedge clk); rst_n = 1'b1;
    endtask

    localparam logic [11:0] MCAUSE = 12'h342;
    logic [31:0] s_a, s_b, s_c, v;

    initial begin
        {rst_n, csr_en, trap_enter, mret, is_int} = '0;
        lvl = '0; addr = '0; wdata = '0; op = '0; tpc = '0; tcause = '0; ttval = '0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        // ---- A: nesting 80 -> 200 and back ----------------------------------
        chk("A0 level after reset", mil, 0);
        trap(1, 8'd80, 32'h8000_0003);  chk("A1 enter level 80", mil, 80);
        csr_read(MCAUSE, s_a);                                  // handler A saves mcause
        trap(1, 8'd200, 32'h8000_0005); chk("A2 preempted by level 200", mil, 200);
        csr_read(MCAUSE, s_b);                                  // handler B saves mcause
        csr_write(MCAUSE, s_b); do_mret(); chk("A3 B returns: level 80", mil, 80);
        csr_write(MCAUSE, s_a); do_mret(); chk("A4 A returns: level 0", mil, 0);

        do_reset();
        // ---- B: exception inside a level-80 handler --------------------------
        trap(1, 8'd80, 32'h8000_0003);  chk("B1 enter level 80", mil, 80);
        csr_read(MCAUSE, s_a);
        trap(0, 8'd0, 32'h0000_0002);   chk("B2 exception inside: level stays 80", mil, 80);
        csr_read(MCAUSE, s_c);
        csr_write(MCAUSE, s_c); do_mret(); chk("B3 exception returns: still 80", mil, 80);
        csr_write(MCAUSE, s_a); do_mret(); chk("B4 handler returns: level 0", mil, 0);

        do_reset();
        // ---- C: machine-timer interrupt inside a level-80 handler (R1) -------
        trap(1, 8'd80, 32'h8000_0003);  chk("C1 enter level 80", mil, 80);
        csr_read(MCAUSE, s_a);
        trap(1, 8'd0, 32'h8000_0007);   chk("C2 MTI inside: level stays 80", mil, 80);
        csr_read(MCAUSE, s_c);
        csr_write(MCAUSE, s_c); do_mret(); chk("C3 MTI returns: still 80", mil, 80);
        csr_write(MCAUSE, s_a); do_mret(); chk("C4 handler returns: level 0", mil, 0);

        do_reset();
        // ---- D: depth 3 ------------------------------------------------------
        trap(1, 8'd40, 32'h8000_0002);  chk("D1 level 40", mil, 40);   csr_read(MCAUSE, s_a);
        trap(1, 8'd120, 32'h8000_0004); chk("D2 level 120", mil, 120); csr_read(MCAUSE, s_b);
        trap(1, 8'd200, 32'h8000_0006); chk("D3 level 200", mil, 200); csr_read(MCAUSE, s_c);
        csr_write(MCAUSE, s_c); do_mret(); chk("D4 unwind to 120", mil, 120);
        csr_write(MCAUSE, s_b); do_mret(); chk("D5 unwind to 40", mil, 40);
        csr_write(MCAUSE, s_a); do_mret(); chk("D6 unwind to 0", mil, 0);

        do_reset();
        // ---- E: what mcause carries ------------------------------------------
        trap(0, 8'd0, 32'h0000_0005);   csr_read(MCAUSE, v);
        chk("E1 exception at level 0: plain mcause", v, 32'h0000_0005);
        do_mret();
        trap(1, 8'd80, 32'h8000_0003);  csr_read(MCAUSE, v);
        chk("E2 interrupt from level 0: mpil 0", v, 32'h8000_0003);
        trap(1, 8'd200, 32'h8000_0005); csr_read(MCAUSE, v);
        chk("E3 interrupt from level 80: mcause[23:16]=80", v, 32'h8050_0005);

        // ---- F: mintstatus layouts at level 200 ------------------------------
        csr_read(12'h346, v); chk("F1 mintstatus 0x346 = {24'b0, mil}", v, 32'h0000_00C8);
        csr_read(12'hFB1, v); chk("F2 mintstatus 0xFB1 = {mil, 24'b0}", v, 32'hC800_0000);

        // the verdict line is chosen by control flow (Docs/handbook/H4_coding.md)
        if (errors == 0) $display(" RESULT: ALL CHECKS PASSED (%0d checks)", checks);
        else             $display(" RESULT: %0d CHECK(S) FAILED of %0d", errors, checks);
        $finish;
    end
endmodule
