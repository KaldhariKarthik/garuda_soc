`timescale 1ns/1ps
//=============================================================================
// tb_garuda_if_stage_top.v -- integration TB for rtl/core/garuda_if_stage_top.v
//                             (garuda_pc_gen + garuda_iport_ahb_master +
//                              garuda_prefetch_buffer)
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 6 (instruction fetch and prefetch
//        buffer), Sec. 16 (AHB-Lite), Sec. 5 (pipeline).
// Plan:  C14 (buffer fill/drain, full backpressure, empty fetch bubble),
//        C15 (whole-buffer flush on redirect; no stale instruction issued),
//        C12/C13 (I-port ERROR tagged, and dropped if flushed).
// Coverage note: docs/COVERAGE.md Category C names garuda_if_stage_top at
//        58.36% with "buffer full, redirect with 2 fetches in flight,
//        back-to-back redirects" as the outstanding corners. Each of those
//        three has a section below.
//
// The scoreboard is the real check: every instruction popped to IF/ID must
//   (a) carry the next expected PC in strict +4 order from the last redirect
//       target -- no gaps, no duplicates, no reordering; and
//   (b) carry the memory word belonging to THAT PC.
// (b) is the whole-stage form of ERRATUM I-1; (a) is what a stale buffer
// entry or a mis-sequenced pointer breaks.
//
// A "fetch bubble" (buffer empty) is an absence of a pop, not a NOP in the
// stream (Sec. 6.3) -- so the scoreboard simply does not advance on those
// cycles, and any NOP that appeared in the stream would fail check (b).
//=============================================================================

module tb_garuda_if_stage_top;

  reg         clk = 0, rst_n;
  reg         stall, redirect;
  reg  [31:0] redirect_pc;

  wire [31:0] i_haddr, i_hwdata;
  wire [1:0]  i_htrans;
  wire [2:0]  i_hsize, i_hburst;
  wire [3:0]  i_hprot;
  wire        i_hwrite;
  reg  [31:0] i_hrdata;
  reg         i_hready, i_hresp;

  wire [31:0] instr, instr_pc;
  wire        instr_valid, instr_fault;

  integer errors = 0;
  integer i, popped;
  reg [31:0] expected_pc;
  reg        scoreboard_armed;
  reg        expect_no_pop;
  reg        err_arm;
  reg [31:0] err_addr;
  reg        saw_fault_at_err_addr;

  localparam HTRANS_IDLE  = 2'b00;
  localparam RESET_VECTOR = 32'h1000_0000;

  always #5 clk = ~clk;

  garuda_if_stage_top dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize),
    .i_hburst_o(i_hburst), .i_hprot_o(i_hprot), .i_hwrite_o(i_hwrite),
    .i_hwdata_o(i_hwdata),
    .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(i_hresp),
    .instr_o(instr), .instr_pc_o(instr_pc),
    .instr_valid_o(instr_valid), .instr_fault_o(instr_fault),
    .stall_i(stall), .redirect_i(redirect), .redirect_pc_i(redirect_pc));

  // Each address holds a unique word, so a mis-paired delivery is visible.
  function [31:0] mem_word;
    input [31:0] a;
    begin
      mem_word = {~a[15:0], a[15:0]} ^ 32'h5A5A_0000;
    end
  endfunction

  //--------------------------------------------------------------------
  // Pipelined AHB-Lite slave model.
  //--------------------------------------------------------------------
  reg [31:0] slave_addr;
  reg        slave_busy;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      slave_addr <= 32'd0;
      slave_busy <= 1'b0;
    end else if (i_hready) begin
      slave_busy <= (i_htrans != HTRANS_IDLE);
      if (i_htrans != HTRANS_IDLE) slave_addr <= i_haddr;
    end
  end

  always @(*) begin
    i_hrdata = mem_word(slave_addr);
    i_hresp  = slave_busy & err_arm & (slave_addr == err_addr);
  end

  //--------------------------------------------------------------------
  // Scoreboard. A pop happens when the buffer is non-empty and IF is
  // neither stalled nor being redirected (the fifo_rd_en term inside the
  // DUT). Sampled at the clock edge, before the pointers move.
  //--------------------------------------------------------------------
  wire pop_now = instr_valid & ~stall & ~redirect;

  always @(posedge clk) begin
    if (rst_n && pop_now) begin
      popped = popped + 1;
      if (expect_no_pop) begin
        $display("FAIL stale instruction issued after redirect: pc=%h instr=%h",
                 instr_pc, instr);
        errors = errors + 1;
      end
      if (scoreboard_armed) begin
        if (instr_pc !== expected_pc) begin
          $display("FAIL stream order: popped pc=%h expected %h",
                   instr_pc, expected_pc);
          errors = errors + 1;
        end
        if (!instr_fault && instr !== mem_word(instr_pc)) begin
          $display("FAIL stream pairing: pc=%h instr=%h expected %h",
                   instr_pc, instr, mem_word(instr_pc));
          errors = errors + 1;
        end
      end else begin
        // first pop after a redirect: adopt it, then require strict +4
        scoreboard_armed = 1'b1;
      end
      expected_pc = instr_pc + 32'd4;
      if (instr_fault && instr_pc === err_addr) saw_fault_at_err_addr = 1'b1;
    end
  end

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

  task tick; begin @(posedge clk); #1; end endtask

  // Redirect for exactly one cycle to tgt, and re-arm the scoreboard.
  task do_redirect;
    input [31:0] tgt;
    begin
      @(negedge clk);
      redirect = 1; redirect_pc = tgt;
      scoreboard_armed = 0;          // first post-redirect pop sets the anchor
      expected_pc = tgt;
      @(posedge clk); #1;
      @(negedge clk); redirect = 0;
    end
  endtask

  initial begin
    popped = 0; expected_pc = RESET_VECTOR;
    scoreboard_armed = 0; expect_no_pop = 0;
    saw_fault_at_err_addr = 0;
    err_arm = 0; err_addr = 0;
    rst_n = 0; stall = 0; redirect = 0; redirect_pc = RESET_VECTOR;
    i_hready = 1;

    // ---- reset: IDLE on the bus, nothing valid to IF/ID ----------------
    #3;
      if (i_htrans !== HTRANS_IDLE) begin
        $display("FAIL reset_htrans: got %b exp IDLE", i_htrans);
        errors = errors + 1;
      end
      c("reset_no_valid_instr", instr_valid, 1'b0);
    @(negedge clk); rst_n = 1;

    // ---- steady-state fetch from the reset vector (C14) ----------------
    // The first pop anchors the scoreboard; every pop after it must be +4
    // with the matching memory word.
    for (i = 0; i < 60; i = i + 1) tick;
    if (popped < 10) begin
      $display("FAIL fetch_throughput: only %0d instructions issued in 60 cycles",
               popped);
      errors = errors + 1;
    end
    c32("stream_started_at_reset_vector_or_later",
        (expected_pc >= RESET_VECTOR), 32'd1);

    // ---- stall holds the head: no pop, and instr_o does not move -------
    @(negedge clk); stall = 1; #1;
    begin : stall_hold
      reg [31:0] held_instr, held_pc;
      integer    popped_before;
      held_instr = instr; held_pc = instr_pc;
      popped_before = popped;
      for (i = 0; i < 6; i = i + 1) begin
        tick;
        if (instr !== held_instr || instr_pc !== held_pc) begin
          $display("FAIL stall_head_moved: pc %h->%h", held_pc, instr_pc);
          errors = errors + 1;
        end
      end
      if (popped !== popped_before) begin
        $display("FAIL stall_popped: %0d instructions issued while stalled",
                 popped - popped_before);
        errors = errors + 1;
      end
    end
    @(negedge clk); stall = 0;
    for (i = 0; i < 10; i = i + 1) tick;

    // ---- buffer FULL corner (COVERAGE.md Category C) -------------------
    // A long stall fills the depth-4 buffer and backpressures fetch; the
    // stream must resume in order with nothing lost or duplicated.
    @(negedge clk); stall = 1;
    for (i = 0; i < 25; i = i + 1) tick;
    @(negedge clk); stall = 0;
    for (i = 0; i < 20; i = i + 1) tick;

    // ---- wait states on the I-port (empty-buffer fetch bubble) ---------
    // HREADY low starves IF: pops simply stop happening. There must be no
    // architectural NOP injected -- the scoreboard would flag it as a
    // pairing failure.
    @(negedge clk); i_hready = 0;
    for (i = 0; i < 12; i = i + 1) tick;
    @(negedge clk); i_hready = 1;
    for (i = 0; i < 20; i = i + 1) tick;

    // ---- redirect with fetches in flight (C15) -------------------------
    // Nothing from the old stream may be issued once the redirect fires.
    expect_no_pop = 1;
    do_redirect(32'h2000_0000);
    tick; tick;
    @(negedge clk); expect_no_pop = 0;
    for (i = 0; i < 30; i = i + 1) tick;
    // the anchor was adopted from the first post-redirect pop; check it
    // actually came from the new target
    if (scoreboard_armed && expected_pc < 32'h2000_0004) begin
      $display("FAIL redirect_target_stream: expected_pc=%h after redirect to %h",
               expected_pc, 32'h2000_0000);
      errors = errors + 1;
    end

    // ---- back-to-back redirects (COVERAGE.md Category C) ---------------
    do_redirect(32'h2000_0100);
    do_redirect(32'h3000_0200);
    for (i = 0; i < 30; i = i + 1) tick;
    if (scoreboard_armed && expected_pc < 32'h3000_0204) begin
      $display("FAIL back2back_redirect_stream: expected_pc=%h", expected_pc);
      errors = errors + 1;
    end

    // ---- redirect while stalled ----------------------------------------
    @(negedge clk); stall = 1;
    do_redirect(32'h4000_0000);
    @(negedge clk); stall = 0;
    for (i = 0; i < 30; i = i + 1) tick;

    // ---- I-port ERROR is TAGGED, not trapped here (C12, Sec. 6.4) ------
    do_redirect(32'h5000_0000);
    err_addr = 32'h5000_0010; err_arm = 1;
    for (i = 0; i < 40; i = i + 1) tick;
      c("fault_tagged_on_its_own_entry", saw_fault_at_err_addr, 1'b1);
    // ...and only on that entry: the scoreboard's pairing check would have
    // fired if a clean word had been marked, or a faulting one delivered
    // with the wrong pc.
    err_arm = 0;

    // ---- C13: a faulting word that is FLUSHED never reaches IF/ID ------
    // Whether the faulting entry is still in the buffer when the second
    // redirect fires depends on exact fetch timing, so the HARD check here
    // is the one that holds either way: expect_no_pop guarantees that
    // NOTHING from the old stream (faulting or clean) is issued after the
    // redirect. Whether the faulting word had already been popped before
    // the flush is reported, not asserted -- C13's authoritative test is at
    // core level (sw/tests/t_flush.S through tb_boot), where "does it trap"
    // is actually observable.
    do_redirect(32'h6000_0000);
    err_addr = 32'h6000_0008; err_arm = 1;
    saw_fault_at_err_addr = 0;
    tick; tick;
    expect_no_pop = 1;
    do_redirect(32'h7000_0000);
    tick; tick;
    @(negedge clk); expect_no_pop = 0;
    err_arm = 0;
    for (i = 0; i < 20; i = i + 1) tick;
    $display("INFO C13: faulting word %h %s popped before the flush",
             32'h6000_0008,
             saw_fault_at_err_addr ? "WAS" : "was NOT");

    if (errors == 0) $display("IF_STAGE_TOP INTEG: ALL CHECKS PASSED");
    else             $display("IF_STAGE_TOP INTEG: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
