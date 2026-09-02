`timescale 1ns/1ps
//=============================================================================
// tb_garuda_prefetch_buffer.v -- unit TB for rtl/core/garuda_prefetch_buffer.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 6.3 (buffer structure) and Sec. 6.5
//        (whole-buffer flush).
// Plan:  C14 ("prefetch buffer fill/drain, full backpressure, empty fetch
//        bubble") and C15 ("whole-buffer flush on redirect; no stale
//        instruction issued"). C13 (a flushed faulting word must not trap)
//        depends on this block dropping the tagged entry -- the flush checks
//        below are its unit-level half.
//
// Checked:
//   * Reset: empty, occupancy 0, instr_valid low.
//   * FIFO ORDER and TAG INTEGRITY: each entry carries its own instr, pc tag
//     and fault bit (Sec. 6.3). Every pushed word uses a distinct pc that is
//     NOT instr+const, so a crossed instr/pc wiring cannot pass.
//   * Occupancy accounting across all four {wr_en, rd_en} combinations,
//     including the simultaneous read+write case which must leave occupancy
//     unchanged -- the classic off-by-one in a circular FIFO.
//   * full_o at depth 4 (backpressures fetch_pc advance, Sec. 6.3) and
//     empty_o at 0 (starves IF -> fetch bubble, not an architectural NOP).
//   * Pointer WRAPAROUND: fill/drain twice so wr_ptr and rd_ptr both wrap
//     past 3, then verify data still comes out in order.
//   * Whole-buffer flush (Sec. 6.5): a redirect empties the buffer in ONE
//     cycle regardless of occupancy, and the first entry written after the
//     flush is the one that pops -- i.e. no pre-redirect word is ever issued
//     (the C15 property).
//   * Flush WINS over a concurrent write and over a concurrent read.
//   * The fault bit is per-entry: a faulting word among clean ones must come
//     out with fault set on that entry only (feeds the Sec. 6.4 deferred
//     instruction-access-fault).
//
// Not exercised, deliberately: pushing past full. The RTL does not guard the
// write when occupancy == 4; the I-port master owns that invariant via its
// room_for_new_fetch reservation, so overflow is out of this block's
// contract and is covered in tb_garuda_iport_ahb_master.v instead.
//=============================================================================

module tb_garuda_prefetch_buffer;

  reg         clk = 0, rst_n;
  reg         redirect;
  reg         wr_en;
  reg  [31:0] wr_instr, wr_pc;
  reg         wr_fault;
  reg         rd_en;
  wire [31:0] instr, instr_pc;
  wire        instr_fault, instr_valid;
  wire        full, empty;
  wire [2:0]  occupancy;

  integer errors = 0;
  integer i;

  always #5 clk = ~clk;

  garuda_prefetch_buffer dut (
    .clk_i(clk), .rst_n_i(rst_n), .redirect_i(redirect),
    .wr_en_i(wr_en), .wr_instr_i(wr_instr), .wr_pc_i(wr_pc),
    .wr_fault_i(wr_fault),
    .rd_en_i(rd_en),
    .instr_o(instr), .instr_pc_o(instr_pc),
    .instr_fault_o(instr_fault), .instr_valid_o(instr_valid),
    .full_o(full), .empty_o(empty), .occupancy_o(occupancy));

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

  task cocc;
    input [255:0] n;
    input [2:0] e;
    begin
      if (occupancy !== e) begin
        $display("FAIL %0s occupancy: got %0d exp %0d", n, occupancy, e);
        errors = errors + 1;
      end
    end
  endtask

  // One clock edge with the given stimulus.
  task step;
    input        rdir;
    input        we;
    input [31:0] wi, wp;
    input        wf;
    input        re;
    begin
      @(negedge clk);
      redirect = rdir; wr_en = we; wr_instr = wi; wr_pc = wp;
      wr_fault = wf; rd_en = re;
      @(posedge clk);
      #1;
    end
  endtask

  task push;
    input [31:0] wi, wp;
    input        wf;
    begin step(1'b0, 1'b1, wi, wp, wf, 1'b0); end
  endtask

  task pop;
    begin step(1'b0, 1'b0, 32'd0, 32'd0, 1'b0, 1'b1); end
  endtask

  task quiet;
    begin step(1'b0, 1'b0, 32'd0, 32'd0, 1'b0, 1'b0); end
  endtask

  // Check the head of the FIFO without popping it.
  task chk_head;
    input [255:0] n;
    input [31:0]  exp_instr, exp_pc;
    input         exp_fault;
    begin
      if (instr !== exp_instr || instr_pc !== exp_pc || instr_fault !== exp_fault) begin
        $display("FAIL %0s head: instr=%h/%h pc=%h/%h fault=%b/%b (got/exp)",
                 n, instr, exp_instr, instr_pc, exp_pc, instr_fault, exp_fault);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    rst_n = 0; redirect = 0; wr_en = 0; rd_en = 0;
    wr_instr = 0; wr_pc = 0; wr_fault = 0;

    // ---- reset state ----------------------------------------------------
    #3;
      c("rst_empty",       empty,       1'b1);
      c("rst_not_full",    full,        1'b0);
      c("rst_instr_valid", instr_valid, 1'b0);
      cocc("rst", 3'd0);
    @(negedge clk); rst_n = 1;

    // ---- fill to full; pc tags are deliberately NOT instr+const --------
    push(32'h0000_0093, 32'h1000_0000, 1'b0);
      cocc("fill1", 3'd1);
      c("fill1_valid",  instr_valid, 1'b1);
      c("fill1_notfull", full,       1'b0);
      chk_head("fill1", 32'h0000_0093, 32'h1000_0000, 1'b0);
    push(32'hDEAD_0113, 32'h2000_0040, 1'b0);  cocc("fill2", 3'd2);
    push(32'hBEEF_0193, 32'h1000_0008, 1'b0);  cocc("fill3", 3'd3);
    push(32'hCAFE_0213, 32'h3000_0FFC, 1'b0);
      cocc("fill4", 3'd4);
      c("full_at_depth4", full,  1'b1);
      c("not_empty",      empty, 1'b0);
    // head is still entry 0 -- filling does not disturb the read side
      chk_head("head_after_fill", 32'h0000_0093, 32'h1000_0000, 1'b0);

    // ---- drain in order, tags intact (Sec. 6.3) ------------------------
    pop; chk_head("drain2", 32'hDEAD_0113, 32'h2000_0040, 1'b0);
      cocc("drain1", 3'd3);
      c("not_full_after_pop", full, 1'b0);
    pop; chk_head("drain3", 32'hBEEF_0193, 32'h1000_0008, 1'b0);
    pop; chk_head("drain4", 32'hCAFE_0213, 32'h3000_0FFC, 1'b0);
      cocc("drain3", 3'd1);
    pop;
      cocc("drained", 3'd0);
      c("empty_after_drain",     empty,       1'b1);
      c("invalid_after_drain",   instr_valid, 1'b0);

    // ---- simultaneous read + write leaves occupancy unchanged ----------
    push(32'h1111_0001, 32'h1000_0100, 1'b0);
    push(32'h2222_0002, 32'h1000_0104, 1'b0);
      cocc("pre_simul", 3'd2);
    step(1'b0, 1'b1, 32'h3333_0003, 32'h1000_0108, 1'b0, 1'b1);   // wr + rd
      cocc("simul_rw", 3'd2);
      chk_head("simul_head_advanced", 32'h2222_0002, 32'h1000_0104, 1'b0);
    step(1'b0, 1'b1, 32'h4444_0004, 32'h1000_010C, 1'b0, 1'b1);
      cocc("simul_rw2", 3'd2);
      chk_head("simul_head2", 32'h3333_0003, 32'h1000_0108, 1'b0);
    quiet;
      cocc("quiet_holds", 3'd2);
      chk_head("quiet_head", 32'h3333_0003, 32'h1000_0108, 1'b0);

    // ---- pointer wraparound: keep cycling past depth 4 ------------------
    pop; pop;
      cocc("wrap_drained", 3'd0);
    // Two full fill/drain rounds: 8 writes and 8 reads take both pointers
    // past 3 and back to 0, without ever exceeding depth 4.
    for (i = 0; i < 8; i = i + 1) begin
      push(32'hA000_0000 + i, 32'h1000_0200 + (i * 4), 1'b0);
      chk_head("wrap_drain", 32'hA000_0000 + i, 32'h1000_0200 + (i * 4), 1'b0);
      pop;
      cocc("wrap_round", 3'd0);
    end

    // ---- per-entry fault bit (feeds the deferred cause-1 trap) ---------
    step(1'b1, 1'b0, 32'd0, 32'd0, 1'b0, 1'b0);      // clean slate
    push(32'h0000_0013, 32'h1000_0300, 1'b0);        // clean
    push(32'h0000_0000, 32'h1000_0304, 1'b1);        // faulting fetch
    push(32'h0000_0013, 32'h1000_0308, 1'b0);        // clean
      chk_head("fault_entry0_clean", 32'h0000_0013, 32'h1000_0300, 1'b0);
    pop;
      c("fault_entry1_faulting", instr_fault, 1'b1);
      c32("fault_entry1_pc",     instr_pc,    32'h1000_0304);
    pop;
      c("fault_entry2_clean", instr_fault, 1'b0);
      c32("fault_entry2_pc",  instr_pc,    32'h1000_0308);
    pop;

    // ---- whole-buffer flush in ONE cycle (Sec. 6.5, test C15) ----------
    push(32'hAAAA_0001, 32'h1000_0400, 1'b0);
    push(32'hAAAA_0002, 32'h1000_0404, 1'b0);
    push(32'hAAAA_0003, 32'h1000_0408, 1'b0);
      cocc("pre_flush", 3'd3);
    step(1'b1, 1'b0, 32'd0, 32'd0, 1'b0, 1'b0);      // redirect
      cocc("flushed", 3'd0);
      c("flush_empty",   empty,       1'b1);
      c("flush_invalid", instr_valid, 1'b0);
      c("flush_notfull", full,        1'b0);
    // the FIRST word written after the flush must be the one that pops --
    // no pre-redirect instruction may ever be issued (C15)
    push(32'hBBBB_0001, 32'h9000_0000, 1'b0);
      chk_head("post_flush_head", 32'hBBBB_0001, 32'h9000_0000, 1'b0);
      cocc("post_flush", 3'd1);
    pop;

    // flush from FULL, also in one cycle
    push(32'hCCCC_0001, 32'h9000_0100, 1'b0);
    push(32'hCCCC_0002, 32'h9000_0104, 1'b0);
    push(32'hCCCC_0003, 32'h9000_0108, 1'b0);
    push(32'hCCCC_0004, 32'h9000_010C, 1'b0);
      c("full_before_flush", full, 1'b1);
    step(1'b1, 1'b0, 32'd0, 32'd0, 1'b0, 1'b0);
      cocc("flush_from_full", 3'd0);
      c("flush_from_full_empty", empty, 1'b1);

    // ---- flush wins over a concurrent write and a concurrent read ------
    push(32'hDDDD_0001, 32'h9000_0200, 1'b0);
    push(32'hDDDD_0002, 32'h9000_0204, 1'b0);
    step(1'b1, 1'b1, 32'hDDDD_0003, 32'h9000_0208, 1'b0, 1'b0);   // flush + wr
      cocc("flush_beats_write", 3'd0);
      c("flush_beats_write_empty", empty, 1'b1);
    push(32'hEEEE_0001, 32'h9000_0300, 1'b0);
    push(32'hEEEE_0002, 32'h9000_0304, 1'b0);
    step(1'b1, 1'b0, 32'd0, 32'd0, 1'b0, 1'b1);                   // flush + rd
      cocc("flush_beats_read", 3'd0);
    // and the buffer is usable again immediately
    push(32'hFFFF_0001, 32'h9000_0400, 1'b0);
      chk_head("usable_after_flush", 32'hFFFF_0001, 32'h9000_0400, 1'b0);

    if (errors == 0) $display("PREFETCH_BUFFER UNIT: ALL CHECKS PASSED");
    else             $display("PREFETCH_BUFFER UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
