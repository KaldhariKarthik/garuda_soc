`timescale 1ns/1ps
//=============================================================================
// tb_d_port_ahb_master.v -- unit TB for rtl/core/d_port_ahb_master.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 10.4 (wait states), Sec. 16.1-16.3
//        (AHB-Lite master, two-cycle ERROR response, reset/idle).
// Plan:  C12 ("D-port ERROR raises access fault 5/7 precisely") at the bus
//        level, plus the D-port-wait-state row of the Sec. 11.4 hold table.
//        The cause NUMBERS are mem_stage's to assign and are checked in
//        tb_mem_stage.v; this TB owns the bus protocol underneath them.
//
// The whole point of this TB is ERRATUM D-1, documented at length in the RTL
// header: the module used to complete a transfer in its ADDRESS phase, which
// made every store write zero and every load return the previous bus cycle's
// data. Three checks below are direct regression tests for it:
//
//   store_hwdata_held_after_start_falls
//       start_i and hwdata_i are DROPPED the moment the address phase is
//       accepted (which is what the pipeline actually does, since the hold
//       is released by that same event). d_hwdata_o must still present the
//       captured value throughout the data phase. The old RTL collapsed it
//       to 0 exactly here.
//   ok_done_is_a_data_phase_event
//       ok_done_o must be low during the address phase and high only in the
//       data phase -- this is the cycle load_formatter samples HRDATA.
//   stall_released_only_on_completion
//       mem_stall_o must cover BOTH phases and drop only in the completing
//       cycle. Releasing it a cycle early is what made loads sample early.
//
// Also checked:
//   * Reset/idle (Sec. 16.3): HTRANS = IDLE out of reset, no transfer with
//     start_i low.
//   * A minimum access is TWO cycles (address, then data) -- inherent to
//     AHB-Lite with no write buffer, per the RTL header.
//   * Address-phase wait states: HADDR/HTRANS/HWRITE/HSIZE held stable while
//     HREADY is low (Sec. 16.2 "the master holds address/control stable").
//   * Data-phase wait states: no completion pulse until HREADY rises.
//   * No spurious second transfer: start_i stays asserted through the data
//     phase (MEM is held), and HTRANS must stay IDLE rather than re-issuing
//     NONSEQ to the same address.
//   * Two-cycle AMBA ERROR response: err_pulse_o fires exactly once, in the
//     cycle the error is sampled, and the FSM returns to the address phase.
//   * ok_done_o and err_pulse_o are mutually exclusive and never overlap.
//   * Back-to-back accesses run cleanly with no dead-state lockup.
//=============================================================================

module tb_d_port_ahb_master;

  reg         clk = 0, rst_n;
  reg         start, hwrite_in;
  reg  [31:0] addr, hwdata_in;
  reg  [2:0]  hsize_in;
  reg         hready, hresp;

  wire [31:0] d_haddr, d_hwdata;
  wire [1:0]  d_htrans;
  wire [2:0]  d_hsize;
  wire        d_hwrite;
  wire        mem_stall, ok_done, err_pulse;

  integer errors = 0;
  integer ok_count, err_count;

  localparam HTRANS_IDLE   = 2'b00;
  localparam HTRANS_NONSEQ = 2'b10;

  always #5 clk = ~clk;

  d_port_ahb_master dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .start_i(start), .hwrite_i(hwrite_in), .addr_i(addr),
    .hsize_i(hsize_in), .hwdata_i(hwdata_in),
    .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize),
    .d_hwrite_o(d_hwrite), .d_hwdata_o(d_hwdata),
    .d_hready_i(hready), .d_hresp_i(hresp),
    .mem_stall_o(mem_stall), .ok_done_o(ok_done), .err_pulse_o(err_pulse));

  task c;
    input [255:0] n;
    input g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %b exp %b", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  task c32;
    input [255:0] n;
    input [31:0] g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %h exp %h", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  task c2;
    input [255:0] n;
    input [1:0] g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %b exp %b", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  // Advance one clock and settle in the new cycle.
  task tick;
    begin @(posedge clk); #1; end
  endtask

  // ok_done and err_pulse must never be asserted together, in any cycle.
  always @(posedge clk) begin
    if (rst_n) begin
      if (ok_done && err_pulse) begin
        $display("FAIL exclusivity: ok_done and err_pulse both high");
        errors = errors + 1;
      end
      if (ok_done)   ok_count  = ok_count  + 1;
      if (err_pulse) err_count = err_count + 1;
    end
  end

  initial begin
    ok_count = 0; err_count = 0;
    rst_n = 0; start = 0; hwrite_in = 0; addr = 0; hwdata_in = 0;
    hsize_in = 3'b010; hready = 1; hresp = 0;

    // ---- reset / idle (Sec. 16.3) --------------------------------------
    #3;
      c2("reset_htrans_idle", d_htrans, HTRANS_IDLE);
      c32("reset_hwdata",     d_hwdata, 32'd0);
      c("reset_no_stall",     mem_stall, 1'b0);
      c("reset_no_done",      ok_done,   1'b0);
      c("reset_no_err",       err_pulse, 1'b0);
    @(negedge clk); rst_n = 1; #1;
      c2("idle_htrans", d_htrans, HTRANS_IDLE);
      c("idle_no_stall", mem_stall, 1'b0);

    // =================================================================
    // STORE -- the ERRATUM D-1 regression
    // =================================================================
    @(negedge clk);
      start = 1; hwrite_in = 1; addr = 32'h2000_0010;
      hsize_in = 3'b010; hwdata_in = 32'hCAFE_F00D; hready = 1; hresp = 0;
    #1;
      // address phase: control on the bus, transfer NOT yet complete
      c2("store_addr_htrans",  d_htrans, HTRANS_NONSEQ);
      c32("store_addr_haddr",  d_haddr,  32'h2000_0010);
      c("store_addr_hwrite",   d_hwrite, 1'b1);
      c("store_addr_stall",    mem_stall, 1'b1);
      c("ok_done_is_a_data_phase_event", ok_done, 1'b0);
      c("no_err_in_addr_phase",          err_pulse, 1'b0);
    tick;
      // Data phase. The pipeline hold was released by the accepted address
      // phase, so the MEM operands are already gone -- drop them here to
      // reproduce exactly that.
      start = 0; hwdata_in = 32'd0; addr = 32'd0; hwrite_in = 0;
      #1;
      c32("store_hwdata_held_after_start_falls", d_hwdata, 32'hCAFE_F00D);
      c2("store_data_phase_htrans_idle", d_htrans, HTRANS_IDLE);
      c("store_completes", ok_done, 1'b1);
      c("stall_released_only_on_completion", mem_stall, 1'b0);
    tick;
      c("store_done_is_one_cycle", ok_done, 1'b0);

    // =================================================================
    // LOAD -- completion is a data-phase event
    // =================================================================
    @(negedge clk);
      start = 1; hwrite_in = 0; addr = 32'h2000_0020; hsize_in = 3'b010;
      hready = 1; hresp = 0;
    #1;
      c2("load_addr_htrans", d_htrans, HTRANS_NONSEQ);
      c("load_addr_hwrite",  d_hwrite, 1'b0);
      c("load_addr_stall",   mem_stall, 1'b1);
      c("load_no_early_done", ok_done, 1'b0);
    tick;
      // start_i stays asserted through the data phase (MEM is held) --
      // this must NOT re-issue a second transfer to the same address.
      #1;
      c2("no_spurious_second_transfer", d_htrans, HTRANS_IDLE);
      c("load_completes", ok_done, 1'b1);
      c("load_stall_released", mem_stall, 1'b0);
    @(negedge clk); start = 0; #1;

    // =================================================================
    // ADDRESS-PHASE WAIT STATES -- control held stable (Sec. 16.2)
    // =================================================================
    @(negedge clk);
      start = 1; hwrite_in = 1; addr = 32'h2000_0030; hsize_in = 3'b001;
      hwdata_in = 32'h0000_BEEF; hready = 0; hresp = 0;
    #1;
      c2("await_htrans", d_htrans, HTRANS_NONSEQ);
      c("await_stall",   mem_stall, 1'b1);
    tick; #1;
      c2("await_htrans_held", d_htrans, HTRANS_NONSEQ);
      c32("await_haddr_held", d_haddr,  32'h2000_0030);
      c("await_hsize_held",   d_hsize[0], 1'b1);           // 3'b001
      c("await_hwrite_held",  d_hwrite, 1'b1);
      c("await_still_stalled", mem_stall, 1'b1);
      c("await_no_done", ok_done, 1'b0);
    tick; #1;
      c2("await_htrans_held2", d_htrans, HTRANS_NONSEQ);
      c("await_no_done2", ok_done, 1'b0);
    @(negedge clk); hready = 1; #1;
      c("await_accept_still_stalled", mem_stall, 1'b1);    // still address phase
    tick;
      @(negedge clk); start = 0; hwdata_in = 32'd0; #1;
      c32("await_hwdata_captured", d_hwdata, 32'h0000_BEEF);
      c("await_completes", ok_done, 1'b1);

    // =================================================================
    // DATA-PHASE WAIT STATES (Sec. 10.4)
    // =================================================================
    @(negedge clk);
      start = 1; hwrite_in = 0; addr = 32'h2000_0040; hsize_in = 3'b010;
      hready = 1; hresp = 0;
    tick;                                   // address phase accepted
    @(negedge clk); hready = 0; #1;         // slave inserts wait states
      c("dwait_stalled",  mem_stall, 1'b1);
      c("dwait_no_done",  ok_done,   1'b0);
      c2("dwait_htrans_idle", d_htrans, HTRANS_IDLE);
    tick; #1;
      c("dwait_stalled2", mem_stall, 1'b1);
      c("dwait_no_done2", ok_done,   1'b0);
    tick; #1;
      c("dwait_stalled3", mem_stall, 1'b1);
    @(negedge clk); hready = 1; #1;
      c("dwait_completes",     ok_done,   1'b1);
      c("dwait_stall_released", mem_stall, 1'b0);
    @(negedge clk); start = 0; #1;

    // =================================================================
    // TWO-CYCLE AMBA ERROR RESPONSE (Sec. 16.2), on a LOAD
    // =================================================================
    err_count = 0;
    @(negedge clk);
      start = 1; hwrite_in = 0; addr = 32'h4000_0000; hsize_in = 3'b010;
      hready = 1; hresp = 0;
    tick;                                   // address phase accepted
    @(negedge clk); hready = 0; hresp = 1; #1;   // ERROR cycle 1
      c("err_cycle1_no_pulse", err_pulse, 1'b0);
      c("err_cycle1_stalled",  mem_stall, 1'b1);
    @(negedge clk); hready = 1; hresp = 1; #1;   // ERROR cycle 2
      c("err_cycle2_pulse", err_pulse, 1'b1);
      c("err_not_ok",       ok_done,   1'b0);
      c("err_stall_released", mem_stall, 1'b0);
    @(negedge clk); start = 0; hresp = 0; #1;
      c("err_pulse_is_one_cycle", err_pulse, 1'b0);
    tick;
    if (err_count !== 1) begin
      $display("FAIL err_pulse_count: got %0d expected 1", err_count);
      errors = errors + 1;
    end

    // ERROR on a STORE takes the same path (cause 7 upstream)
    err_count = 0;
    @(negedge clk);
      start = 1; hwrite_in = 1; addr = 32'h4000_0004; hwdata_in = 32'h1234_5678;
      hready = 1; hresp = 0;
    tick;
    @(negedge clk); hready = 0; hresp = 1; #1;
      c("store_err_cycle1_no_pulse", err_pulse, 1'b0);
    @(negedge clk); hready = 1; hresp = 1; #1;
      c("store_err_cycle2_pulse", err_pulse, 1'b1);
      c32("store_err_hwdata_still_driven", d_hwdata, 32'h1234_5678);
    @(negedge clk); start = 0; hresp = 0; hwdata_in = 0;
    tick;
    if (err_count !== 1) begin
      $display("FAIL store_err_count: got %0d expected 1", err_count);
      errors = errors + 1;
    end

    // ---- FSM recovers: a normal access works straight after an error ---
    @(negedge clk);
      start = 1; hwrite_in = 0; addr = 32'h2000_0050; hready = 1; hresp = 0;
    #1;
      c2("post_err_addr_phase", d_htrans, HTRANS_NONSEQ);
    tick; #1;
      c("post_err_completes", ok_done, 1'b1);
    @(negedge clk); start = 0;

    // =================================================================
    // BACK-TO-BACK accesses: three in a row, each two cycles
    // =================================================================
    ok_count = 0;
    @(negedge clk); start = 1; hwrite_in = 0; addr = 32'h2000_0100;
                    hready = 1; hresp = 0;
    tick; @(negedge clk); addr = 32'h2000_0104;   // data phase of #1
    tick; @(negedge clk); addr = 32'h2000_0108;
    tick; @(negedge clk);
    tick; @(negedge clk); start = 0;
    tick;
    if (ok_count < 2) begin
      $display("FAIL back_to_back: only %0d completions observed", ok_count);
      errors = errors + 1;
    end

    if (errors == 0) $display("D_PORT_AHB_MASTER UNIT: ALL CHECKS PASSED");
    else             $display("D_PORT_AHB_MASTER UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
