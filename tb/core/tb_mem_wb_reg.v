`timescale 1ns/1ps
//=============================================================================
// tb_mem_wb_reg.v -- unit TB for rtl/core/mem_wb_reg.v (+ wb_stage.v)
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 5.2 (pipeline registers), Sec. 10.3
//        (mux-in-MEM contract), Sec. 11.4 (flush composition), Sec. 13.2
//        (minstret retirement pulse).
// Plan:  supports C28 (reset leaves the pipeline in the bubble state) and the
//        D-port-wait-state row of the Sec. 11.4 table ("bubble enters WB").
//
// wb_stage.v is instantiated downstream of the register in the same TB: it is
// a pure pass-through with no state, so a separate TB for three assigns would
// only re-check the same wires. The checks below read through it, which also
// proves the MEM/WB -> WB -> regfile-write-port wiring order.
//
// Checked:
//   * Reset (Sec. 5.2 "all four registers reset to the bubble state"):
//     reg_write_o and retire_o LOW, wb_data/rd zeroed. Asynchronous assert is
//     checked mid-cycle, not just at a clock edge.
//   * Normal clocked update: wb_data/rd/reg_write/retire all captured on the
//     rising edge and held for the whole next cycle.
//   * flush_i inserts a bubble: reg_write_o AND retire_o both go low. Both
//     matter -- a flush that killed the write but not the retire pulse would
//     silently inflate minstret, which is exactly what Sec. 13.2 uses for the
//     IPC/trace check.
//   * Flush WINS over a valid input presented in the same cycle (Sec. 11.4:
//     "the flush wins and the held op is squashed").
//   * There is deliberately NO hold input (see the RTL header): a multi-cycle
//     wait state is modelled here as flush held high for N cycles, and the
//     TB confirms the previous writeback is NOT replayed on each of those
//     cycles -- the failure mode the header calls out.
//   * retire_o is independent of reg_write_i: a store retires (retire=1,
//     reg_write=0) and must still pulse minstret exactly once.
//=============================================================================

module tb_mem_wb_reg;

  reg         clk = 0, rst_n;
  reg         flush;
  reg  [31:0] wb_data_i;
  reg  [4:0]  rd_i;
  reg         reg_write_i, retire_i;
  wire [31:0] wb_data_o;
  wire [4:0]  rd_o;
  wire        reg_write_o, retire_o;

  // wb_stage outputs (register-file write port)
  wire        rf_we;
  wire [4:0]  rf_rd;
  wire [31:0] rf_wdata;

  integer errors = 0;
  integer i, retire_count;

  always #5 clk = ~clk;

  mem_wb_reg dut (
    .clk_i(clk), .rst_n_i(rst_n), .flush_i(flush),
    .wb_data_i(wb_data_i), .rd_i(rd_i),
    .reg_write_i(reg_write_i), .retire_i(retire_i),
    .wb_data_o(wb_data_o), .rd_o(rd_o),
    .reg_write_o(reg_write_o), .retire_o(retire_o));

  // Sec. 5 structural boundary: WB drives the regfile write port.
  wb_stage u_wb (
    .wb_data_i(wb_data_o), .rd_i(rd_o), .reg_write_i(reg_write_o),
    .rf_we_o(rf_we), .rf_rd_o(rf_rd), .rf_wdata_o(rf_wdata));

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

  // Present one MEM-stage payload for a single clock edge.
  task drive;
    input [31:0] d;
    input [4:0]  rd;
    input        rw, ret, fl;
    begin
      @(negedge clk);
      wb_data_i = d; rd_i = rd; reg_write_i = rw; retire_i = ret; flush = fl;
      @(posedge clk);
      #1;
    end
  endtask

  // Count retire pulses so a replayed retirement is caught, not just sampled.
  always @(posedge clk)
    if (rst_n && retire_o) retire_count = retire_count + 1;

  initial begin
    retire_count = 0;
    rst_n = 0; flush = 0;
    wb_data_i = 32'hDEAD_BEEF; rd_i = 5'd7; reg_write_i = 1; retire_i = 1;

    // ---- reset is asynchronous and forces the bubble state -------------
    #3;
      c32("rst_wb_data",   wb_data_o,   32'd0);
      c32("rst_rd",        rd_o,        32'd0);
      c("rst_reg_write",   reg_write_o, 1'b0);
      c("rst_retire",      retire_o,    1'b0);
      c("rst_rf_we",       rf_we,       1'b0);
    @(negedge clk); rst_n = 1;

    // ---- normal capture -------------------------------------------------
    drive(32'h1234_5678, 5'd9, 1'b1, 1'b1, 1'b0);
      c32("cap_wb_data", wb_data_o,   32'h1234_5678);
      c32("cap_rd",      rd_o,        32'd9);
      c("cap_reg_write", reg_write_o, 1'b1);
      c("cap_retire",    retire_o,    1'b1);
      c32("cap_rf_wdata", rf_wdata,   32'h1234_5678);
      c32("cap_rf_rd",    rf_rd,      32'd9);
      c("cap_rf_we",      rf_we,      1'b1);

    // value must be HELD for the rest of the cycle, not glitch away
    #3;
      c32("hold_wb_data", wb_data_o, 32'h1234_5678);
      c("hold_reg_write", reg_write_o, 1'b1);

    // ---- store: retires but does not write a register ------------------
    drive(32'hAAAA_5555, 5'd0, 1'b0, 1'b1, 1'b0);
      c("store_no_regwrite", reg_write_o, 1'b0);
      c("store_retires",     retire_o,    1'b1);
      c("store_rf_we",       rf_we,       1'b0);

    // ---- flush inserts a bubble (Sec. 11.4) ----------------------------
    drive(32'hCAFE_F00D, 5'd11, 1'b1, 1'b1, 1'b1);
      c("flush_no_regwrite", reg_write_o, 1'b0);
      c("flush_no_retire",   retire_o,    1'b0);
      c32("flush_wb_data",   wb_data_o,   32'd0);
      c32("flush_rd",        rd_o,        32'd0);
      c("flush_rf_we",       rf_we,       1'b0);

    // ---- multi-cycle D-port wait state: bubble every cycle, no replay --
    // Load one good result, then hold flush for 4 cycles and confirm the
    // writeback is not re-issued on any of them (RTL header: "a hold here
    // would replay the previous instruction's writeback every wait cycle").
    drive(32'h0BAD_0BAD, 5'd13, 1'b1, 1'b1, 1'b0);
      c("pre_wait_regwrite", reg_write_o, 1'b1);
    for (i = 0; i < 4; i = i + 1) begin
      drive(32'h0BAD_0BAD, 5'd13, 1'b1, 1'b1, 1'b1);
      // The first flush edge still samples the PREVIOUS (legitimate)
      // instruction's retire pulse, so start counting after it.
      if (i == 0) retire_count = 0;
      c("wait_bubble_regwrite", reg_write_o, 1'b0);
      c("wait_bubble_retire",   retire_o,    1'b0);
    end
    if (retire_count !== 0) begin
      $display("FAIL wait_state_replay: %0d retire pulses during 4 flush cycles, expected 0",
               retire_count);
      errors = errors + 1;
    end

    // ---- exactly one retire pulse per retired instruction --------------
    retire_count = 0;
    drive(32'h1111_1111, 5'd1, 1'b1, 1'b1, 1'b0);   // retires
    drive(32'h2222_2222, 5'd2, 1'b1, 1'b0, 1'b0);   // faulted: no retire
    drive(32'h3333_3333, 5'd3, 1'b1, 1'b1, 1'b0);   // retires
    drive(32'h4444_4444, 5'd4, 1'b1, 1'b1, 1'b1);   // flushed: no retire
    @(posedge clk); #1;
    if (retire_count !== 2) begin
      $display("FAIL retire_count: got %0d expected 2", retire_count);
      errors = errors + 1;
    end

    // ---- reset asserted mid-stream clears the register -----------------
    drive(32'h9999_9999, 5'd21, 1'b1, 1'b1, 1'b0);
      c("pre_rst_regwrite", reg_write_o, 1'b1);
    rst_n = 0; #1;
      c("async_rst_regwrite", reg_write_o, 1'b0);
      c32("async_rst_data",   wb_data_o,   32'd0);
      c("async_rst_retire",   retire_o,    1'b0);
    @(negedge clk); rst_n = 1;

    if (errors == 0) $display("MEM_WB_REG UNIT: ALL CHECKS PASSED");
    else             $display("MEM_WB_REG UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
