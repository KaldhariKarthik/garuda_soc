`timescale 1ns/1ps
//=============================================================================
// tb_garuda_iport_ahb_master.v -- unit TB for rtl/core/garuda_iport_ahb_master.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 6.4 (I-port AHB-Lite operation),
//        Sec. 6.5 (flush / dropped in-flight data), Sec. 4.1 (fixed I-port
//        pins), Sec. 16 (AHB-Lite master protocol).
// Plan:  C12 (I-port ERROR raises instruction access fault 1), C13 (a
//        speculatively-fetched faulting word that is flushed must not trap),
//        C14 (fetch-ahead and full backpressure), C15 (whole-buffer flush,
//        no stale instruction issued).
//
// The central regression here is ERRATUM I-1, documented in the RTL header:
// the module once completed a transfer in its ADDRESS phase and therefore
// paired every instruction with the PREVIOUS bus cycle's read data while
// keeping its own correct PC tag. A TB that only checked "some data arrived"
// would pass that broken RTL. This one runs a real instruction stream through
// a memory model whose contents are a function of address, and checks the
// (data_pc_o, data_instr_o) PAIR on every delivery -- which is exactly the
// property the old RTL violated and no earlier testbench tested.
//
// Environment (deliberately behavioural, not the real blocks):
//   * pc model    -- fetch_pc advances by 4 on every fetch_issue_o, and
//                    reloads on redirect. Mirrors garuda_pc_gen.
//   * FIFO model  -- occupancy counter: +1 on data_valid_o, -1 on rd_en,
//                    cleared on redirect. Mirrors garuda_prefetch_buffer's
//                    accounting so the master's reservation logic is driven
//                    with realistic backpressure.
//   * AHB slave   -- pipelined: latches the address phase, drives HRDATA in
//                    the following (data) phase. Wait states and ERROR
//                    responses are switchable.
//
// Checked:
//   * Fixed pins (Sec. 4.1): HSIZE = 010, HPROT = 0010, HWRITE = 0,
//     HWDATA = 0 in every cycle; HBURST = INCR only while HTRANS = SEQ,
//     SINGLE otherwise.
//   * Reset/idle (Sec. 4.2/16.3): HTRANS = IDLE out of reset.
//   * The first transfer after reset and after every redirect is NONSEQ;
//     sequential prefetch continues as SEQ (Sec. 6.4).
//   * ERRATUM I-1: instruction/PC pairing over a long stream.
//   * FIFO reservation: with the buffer never drained, deliveries stop at
//     depth 4 -- the master must count BOTH in-flight transfers (address
//     phase and data phase), or a 2-deep pipeline overruns a depth-4 FIFO.
//   * Wait states: HADDR/HTRANS held stable while HREADY is low.
//   * Redirect (Sec. 6.5 / C15): data owed for pre-redirect fetches is
//     dropped even though it lands one or more cycles AFTER redirect_i has
//     fallen -- the drop_pending/drop_cnt obligation. No stale word may be
//     delivered, and the first post-redirect delivery must carry the new
//     target's PC.
//   * HRESP = ERROR surfaces as data_fault_o on the correct entry, and a
//     faulting word that is flushed is never delivered at all (C13).
//=============================================================================

module tb_garuda_iport_ahb_master;

  reg         clk = 0, rst_n;
  reg         redirect;
  reg  [31:0] fetch_pc;
  reg  [2:0]  fifo_occupancy;
  reg         fifo_rd_en;

  wire [31:0] i_haddr, i_hwdata;
  wire [1:0]  i_htrans;
  wire [2:0]  i_hsize, i_hburst;
  wire [3:0]  i_hprot;
  wire        i_hwrite;
  reg  [31:0] i_hrdata;
  reg         i_hready, i_hresp;

  wire        fetch_issue, data_valid, data_fault;
  wire [31:0] data_instr, data_pc;

  integer errors = 0;
  integer i, delivered;
  reg [31:0] redirect_target;
  reg        expect_no_delivery;
  reg [31:0] first_pc_after_redirect;
  reg        saw_first_after_redirect;

  localparam HTRANS_IDLE   = 2'b00;
  localparam HTRANS_NONSEQ = 2'b10;
  localparam HTRANS_SEQ    = 2'b11;
  localparam RESET_VECTOR  = 32'h1000_0000;

  always #5 clk = ~clk;

  garuda_iport_ahb_master #(.FIFO_DEPTH(4)) dut (
    .clk_i(clk), .rst_n_i(rst_n), .redirect_i(redirect),
    .fetch_pc_i(fetch_pc),
    .fifo_occupancy_i(fifo_occupancy), .fifo_rd_en_i(fifo_rd_en),
    .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize),
    .i_hburst_o(i_hburst), .i_hprot_o(i_hprot), .i_hwrite_o(i_hwrite),
    .i_hwdata_o(i_hwdata),
    .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(i_hresp),
    .fetch_issue_o(fetch_issue), .data_valid_o(data_valid),
    .data_instr_o(data_instr), .data_pc_o(data_pc),
    .data_fault_o(data_fault));

  //--------------------------------------------------------------------
  // Memory model: the word at address A is a unique function of A, so a
  // mis-paired instruction/PC delivery is detectable from the pair alone.
  //--------------------------------------------------------------------
  function [31:0] mem_word;
    input [31:0] a;
    begin
      mem_word = {~a[15:0], a[15:0]} ^ 32'h5A5A_0000;
    end
  endfunction

  //--------------------------------------------------------------------
  // AHB-Lite slave model: pipelined address/data phases.
  //--------------------------------------------------------------------
  reg [31:0] slave_addr;
  reg        slave_busy;
  reg        err_arm;               // return ERROR for the next data phase
  reg [31:0] err_addr;

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
  // PC generator and FIFO occupancy models.
  //--------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fetch_pc       <= RESET_VECTOR;
      fifo_occupancy <= 3'd0;
    end else if (redirect) begin
      fetch_pc       <= redirect_target;
      fifo_occupancy <= 3'd0;
    end else begin
      if (fetch_issue) fetch_pc <= fetch_pc + 32'd4;
      case ({data_valid, fifo_rd_en})
        2'b10: fifo_occupancy <= fifo_occupancy + 3'd1;
        2'b01: if (fifo_occupancy != 0) fifo_occupancy <= fifo_occupancy - 3'd1;
        default: ;
      endcase
    end
  end

  //--------------------------------------------------------------------
  // Continuous checks.
  //--------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n) begin
      // Fixed I-port pins (Sec. 4.1)
      if (i_hsize !== 3'b010) begin
        $display("FAIL i_hsize not word: %b", i_hsize);
        errors = errors + 1; end
      if (i_hprot !== 4'b0010) begin
        $display("FAIL i_hprot not opcode-fetch: %b", i_hprot);
        errors = errors + 1; end
      if (i_hwrite !== 1'b0) begin
        $display("FAIL i_hwrite asserted on the I-port");
        errors = errors + 1; end
      if (i_hwdata !== 32'b0) begin
        $display("FAIL i_hwdata not tied 0: %h", i_hwdata);
        errors = errors + 1; end
      // HBURST tracks HTRANS (Sec. 6.4)
      if (i_htrans === HTRANS_SEQ && i_hburst !== 3'b001) begin
        $display("FAIL hburst not INCR while SEQ: %b", i_hburst);
        errors = errors + 1; end
      if (i_htrans !== HTRANS_SEQ && i_hburst !== 3'b000) begin
        $display("FAIL hburst not SINGLE outside SEQ: %b", i_hburst);
        errors = errors + 1; end
      // FIFO must never be overrun (the reservation invariant)
      if (fifo_occupancy > 3'd4) begin
        $display("FAIL fifo overrun: occupancy=%0d", fifo_occupancy);
        errors = errors + 1; end
      // ERRATUM I-1: every delivery must pair the right word with its PC
      if (data_valid) begin
        delivered = delivered + 1;
        if (!data_fault && data_instr !== mem_word(data_pc)) begin
          $display("FAIL pairing: pc=%h instr=%h expected %h (ERRATUM I-1)",
                   data_pc, data_instr, mem_word(data_pc));
          errors = errors + 1;
        end
        if (expect_no_delivery) begin
          $display("FAIL stale delivery after redirect: pc=%h instr=%h",
                   data_pc, data_instr);
          errors = errors + 1;
        end
        if (!saw_first_after_redirect) begin
          first_pc_after_redirect = data_pc;
          saw_first_after_redirect = 1'b1;
        end
      end
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

  initial begin
    delivered = 0; expect_no_delivery = 0;
    saw_first_after_redirect = 1; first_pc_after_redirect = 0;
    rst_n = 0; redirect = 0; redirect_target = RESET_VECTOR;
    fifo_rd_en = 0; i_hready = 1; err_arm = 0; err_addr = 0;

    // ---- reset / idle (Sec. 4.2, 16.3) ---------------------------------
    #3;
      if (i_htrans !== HTRANS_IDLE) begin
        $display("FAIL reset_htrans: got %b exp IDLE", i_htrans);
        errors = errors + 1;
      end
    @(negedge clk); rst_n = 1;

    // ---- first transfer after reset is NONSEQ (Sec. 6.4) ---------------
    fifo_rd_en = 1;                 // IF pops every cycle: steady state
    // HADDR/HTRANS are REGISTERED, so the first transfer appears some cycles
    // after reset rather than at a fixed one. Scan for the first non-IDLE
    // transfer instead of asserting on an exact cycle number.
    begin : first_transfer
      reg found;
      found = 0;
      for (i = 0; i < 10 && !found; i = i + 1) begin
        tick;
        if (i_htrans !== HTRANS_IDLE) begin
          found = 1;
          if (i_htrans !== HTRANS_NONSEQ) begin
            $display("FAIL first_transfer_nonseq: got %b", i_htrans);
            errors = errors + 1;
          end
          c32("first_haddr", i_haddr, RESET_VECTOR);
        end
      end
      c("saw_first_transfer", found, 1'b1);
    end
    // the next transfer is SEQ: sequential prefetch uses INCR (Sec. 6.4)
    begin : second_transfer
      reg found_seq;
      found_seq = 0;
      for (i = 0; i < 10 && !found_seq; i = i + 1) begin
        tick;
        if (i_htrans === HTRANS_SEQ) found_seq = 1;
      end
      c("second_transfer_seq", found_seq, 1'b1);
    end

    // ---- streaming: ERRATUM I-1 pairing checked continuously -----------
    delivered = 0;
    for (i = 0; i < 40; i = i + 1) tick;
    if (delivered < 10) begin
      $display("FAIL stream_throughput: only %0d deliveries in 40 cycles",
               delivered);
      errors = errors + 1;
    end

    // ---- wait states: address/control held stable (Sec. 16.2) ----------
    @(negedge clk); i_hready = 0; #1;
    begin : wait_hold
      reg [31:0] held_addr;
      reg [1:0]  held_trans;
      held_addr  = i_haddr;
      held_trans = i_htrans;
      for (i = 0; i < 4; i = i + 1) begin
        tick;
        if (i_haddr !== held_addr) begin
          $display("FAIL wait_haddr_moved: %h -> %h", held_addr, i_haddr);
          errors = errors + 1;
        end
        if (i_htrans !== held_trans) begin
          $display("FAIL wait_htrans_moved: %b -> %b", held_trans, i_htrans);
          errors = errors + 1;
        end
      end
    end
    @(negedge clk); i_hready = 1;
    for (i = 0; i < 8; i = i + 1) tick;

    // ---- FIFO full backpressure (C14) ----------------------------------
    // Stop popping: occupancy fills and the master must stop issuing before
    // more than FIFO_DEPTH words can ever land.
    @(negedge clk); fifo_rd_en = 0;
    for (i = 0; i < 30; i = i + 1) tick;      // continuous overrun check runs
      if (fifo_occupancy !== 3'd4) begin
        $display("FAIL backpressure: occupancy settled at %0d, expected 4",
                 fifo_occupancy);
        errors = errors + 1;
      end
      c("no_issue_when_full", fetch_issue, 1'b0);
    // resume popping and confirm fetching restarts
    @(negedge clk); fifo_rd_en = 1;
    delivered = 0;
    for (i = 0; i < 20; i = i + 1) tick;
    if (delivered == 0) begin
      $display("FAIL no_restart_after_backpressure");
      errors = errors + 1;
    end

    // ---- redirect: in-flight data must be DROPPED (Sec. 6.5 / C15) -----
    // Two transfers are live at this point (one address phase, one data
    // phase). Neither may be delivered after the redirect, even though one
    // of them completes a cycle or more AFTER redirect_i has fallen -- that
    // is the drop_cnt obligation.
    @(negedge clk);
      redirect = 1; redirect_target = 32'h3000_0000;
      expect_no_delivery = 1;
      saw_first_after_redirect = 0;
    tick;
    @(negedge clk); redirect = 0; #1;
    // the two owed data phases land now; nothing may be written
    tick;
    tick;
    @(negedge clk); expect_no_delivery = 0;
    // the first transfer after a redirect is NONSEQ again
    tick;
    begin : post_redirect_nonseq
      reg found_nonseq;
      found_nonseq = 0;
      for (i = 0; i < 6; i = i + 1) begin
        if (i_htrans === HTRANS_NONSEQ && i_haddr === 32'h3000_0000)
          found_nonseq = 1;
        tick;
      end
      c("post_redirect_nonseq", found_nonseq, 1'b1);
    end
    for (i = 0; i < 10; i = i + 1) tick;
    // the first word delivered after the redirect belongs to the new stream
    c("delivered_after_redirect", saw_first_after_redirect, 1'b1);
    if (saw_first_after_redirect && first_pc_after_redirect !== 32'h3000_0000)
    begin
      $display("FAIL stale_stream: first post-redirect pc=%h expected %h",
               first_pc_after_redirect, 32'h3000_0000);
      errors = errors + 1;
    end

    // ---- HRESP = ERROR surfaces as data_fault on the right entry -------
    // (Sec. 6.4: the fault is TAGGED here and only trapped when the entry
    //  reaches ID, which is what makes C13 possible.)
    err_addr = 32'h3000_0020; err_arm = 1;
    begin : fault_check
      reg saw_fault;
      saw_fault = 0;
      for (i = 0; i < 24; i = i + 1) begin
        tick;
        if (data_valid && data_fault) begin
          saw_fault = 1;
          if (data_pc !== err_addr) begin
            $display("FAIL fault_tagged_wrong_entry: pc=%h expected %h",
                     data_pc, err_addr);
            errors = errors + 1;
          end
        end
        if (data_valid && !data_fault && data_pc === err_addr) begin
          $display("FAIL faulting_entry_delivered_clean: pc=%h", data_pc);
          errors = errors + 1;
        end
      end
      c("saw_tagged_fault", saw_fault, 1'b1);
    end
    err_arm = 0;

    // ---- C13: a faulting word that is FLUSHED must never be delivered --
    err_addr = 32'h7000_0010; err_arm = 1;
    @(negedge clk); redirect = 1; redirect_target = 32'h7000_0000;
    tick; @(negedge clk); redirect = 0;
    // let the faulting fetch get issued, then redirect away before it lands
    tick; tick;
    @(negedge clk); redirect = 1; redirect_target = 32'h8000_0000;
                    expect_no_delivery = 1;
    tick; @(negedge clk); redirect = 0;
    tick; tick;
    @(negedge clk); expect_no_delivery = 0;
    err_arm = 0;
    for (i = 0; i < 10; i = i + 1) tick;

    if (errors == 0) $display("IPORT_AHB_MASTER UNIT: ALL CHECKS PASSED");
    else             $display("IPORT_AHB_MASTER UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
