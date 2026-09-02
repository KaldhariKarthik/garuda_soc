`timescale 1ns/1ps
//=============================================================================
// tb_mem_stage.v -- integration TB for rtl/core/mem_stage.v
//                   (load_store_unit + d_port_ahb_master + load_formatter)
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 10 (memory stage and data port),
//        Sec. 11.4 (D-port wait state), Sec. 13.2 (minstret retirement),
//        Sec. 14.1/14.2 (causes 5/7 and their mtval), Sec. 4.1 (static pins).
// Plan:  C10 (load extension and store lane alignment through the real bus
//        pins), C11 ("no bus transaction issued" on a misalignment -- the
//        half that the load_store_unit TB cannot see), C12 (D-port ERROR
//        raises access faults 5 and 7 precisely).
//
// The sub-blocks each have their own unit TB; this one verifies the wiring
// and the stage-level decisions that only exist here:
//
//   * start_w gating (Sec. 10.2): a misaligned access must never reach the
//     bus. Checked by watching d_htrans stay IDLE for the entire access
//     window, not merely by sampling one cycle.
//   * The mem_to_reg mux lives in MEM, not WB (Sec. 5.2 / 10.3 mux-in-MEM
//     contract): wb_data_o is already final when it leaves this stage.
//   * Cause assignment: load ERROR -> 5, store ERROR -> 7 (Sec. 14.1), with
//     mtval = the access address in both cases (Sec. 14.2). The load/store
//     split is driven by mem_read_i/mem_write_i, so a swapped pair is
//     caught by running both directions to the same address.
//   * Misalignment raises NO exception here -- causes 4 and 6 are owned by
//     ex_stage (the RTL comment says so explicitly), and MEM owning them
//     too would double-report the trap.
//   * retire_o = valid_i & ~exception (Sec. 13.2): a faulting access must
//     not count toward minstret, and a bubble (valid_i low) never retires.
//   * Static pins per the Sec. 4.1 pin contract: d_hburst_o = SINGLE (000)
//     and d_hprot_o = 0b0011, always, in every state.
//
// A minimal AHB-Lite slave model drives HRDATA in the data phase and can be
// told to insert wait states or return the two-cycle ERROR response.
//=============================================================================

module tb_mem_stage;

  reg         clk = 0, rst_n;
  reg  [31:0] ex_result, rs2_data, pc_in;
  reg  [2:0]  funct3;
  reg  [4:0]  rd_in;
  reg         mem_read, mem_write, mem_to_reg, reg_write, valid;

  wire [31:0] d_haddr, d_hwdata;
  wire [1:0]  d_htrans;
  wire [2:0]  d_hsize, d_hburst;
  wire [3:0]  d_hprot;
  wire        d_hwrite;
  reg  [31:0] d_hrdata;
  reg         d_hready, d_hresp;

  wire [31:0] wb_data;
  wire        reg_write_o, retire;
  wire [4:0]  rd_o;
  wire        mem_stall;
  wire        exc_valid;
  wire [31:0] exc_pc, exc_mtval;
  wire [3:0]  exc_cause;

  integer errors = 0;
  integer i;
  reg     saw_nonidle;

  localparam HTRANS_IDLE   = 2'b00;
  localparam HTRANS_NONSEQ = 2'b10;
  localparam F3_B  = 3'b000, F3_H  = 3'b001, F3_W = 3'b010;
  localparam F3_BU = 3'b100, F3_HU = 3'b101;

  always #5 clk = ~clk;

  mem_stage dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .ex_result_i(ex_result), .rs2_data_i(rs2_data), .funct3_i(funct3),
    .rd_i(rd_in), .pc_i(pc_in),
    .mem_read_i(mem_read), .mem_write_i(mem_write),
    .mem_to_reg_i(mem_to_reg), .reg_write_i(reg_write), .valid_i(valid),
    .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize),
    .d_hburst_o(d_hburst), .d_hprot_o(d_hprot),
    .d_hwrite_o(d_hwrite), .d_hwdata_o(d_hwdata),
    .d_hrdata_i(d_hrdata), .d_hready_i(d_hready), .d_hresp_i(d_hresp),
    .wb_data_o(wb_data), .reg_write_o(reg_write_o), .rd_o(rd_o),
    .retire_o(retire), .mem_stall_o(mem_stall),
    .mem_exception_valid_o(exc_valid), .mem_exception_pc_o(exc_pc),
    .mem_exception_cause_o(exc_cause), .mem_exception_mtval_o(exc_mtval));

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

  // Static pin contract (Sec. 4.1) -- must hold in EVERY cycle, so it is
  // checked continuously rather than at a few sample points.
  always @(posedge clk) begin
    if (rst_n) begin
      if (d_hburst !== 3'b000) begin
        $display("FAIL d_hburst not SINGLE: %b", d_hburst);
        errors = errors + 1;
      end
      if (d_hprot !== 4'b0011) begin
        $display("FAIL d_hprot not 0011: %b", d_hprot);
        errors = errors + 1;
      end
    end
  end

  task clr;
    begin
      ex_result = 32'h2000_0000; rs2_data = 32'd0; pc_in = 32'h1000_0000;
      funct3 = F3_W; rd_in = 5'd5;
      mem_read = 0; mem_write = 0; mem_to_reg = 0; reg_write = 0; valid = 1;
      d_hrdata = 32'd0; d_hready = 1; d_hresp = 0;
    end
  endtask

  task tick; begin @(posedge clk); #1; end endtask

  initial begin
    clr;
    rst_n = 0; #3;
      c("reset_no_stall", mem_stall, 1'b0);
      c("reset_no_exc",   exc_valid, 1'b0);
    @(negedge clk); rst_n = 1;

    // =================================================================
    // LOAD WORD -- address phase, then data phase with real HRDATA
    // =================================================================
    @(negedge clk);
      clr; mem_read = 1; mem_to_reg = 1; reg_write = 1;
      ex_result = 32'h2000_0010; funct3 = F3_W; rd_in = 5'd9;
    #1;
      c32("lw_haddr",   d_haddr,  32'h2000_0010);
      c("lw_hwrite",    d_hwrite, 1'b0);
      c("lw_addr_stall", mem_stall, 1'b1);
      if (d_htrans !== HTRANS_NONSEQ) begin
        $display("FAIL lw_htrans: got %b exp %b", d_htrans, HTRANS_NONSEQ);
        errors = errors + 1;
      end
    tick;
      @(negedge clk); d_hrdata = 32'hDEAD_BEEF; #1;
      c32("lw_wb_data",  wb_data, 32'hDEAD_BEEF);
      c("lw_stall_done", mem_stall, 1'b0);
      c("lw_retires",    retire,   1'b1);
      c("lw_reg_write",  reg_write_o, 1'b1);
      c32("lw_rd",       rd_o,     32'd9);
      c("lw_no_exc",     exc_valid, 1'b0);

    // ---- LB sign-extension through the real bus path -------------------
    @(negedge clk);
      clr; mem_read = 1; mem_to_reg = 1; reg_write = 1;
      ex_result = 32'h2000_0021; funct3 = F3_B;   // byte lane 1
    tick;
      @(negedge clk); d_hrdata = 32'h0000_80FF; #1;   // lane1 = 0x80
      c32("lb_sign_extended", wb_data, 32'hFFFF_FF80);
    @(negedge clk);
      clr; mem_read = 1; mem_to_reg = 1; reg_write = 1;
      ex_result = 32'h2000_0021; funct3 = F3_BU;
    tick;
      @(negedge clk); d_hrdata = 32'h0000_80FF; #1;
      c32("lbu_zero_extended", wb_data, 32'h0000_0080);

    // ---- non-load: mem_to_reg low passes the EX result through ---------
    @(negedge clk);
      clr; reg_write = 1; mem_to_reg = 0; ex_result = 32'h1234_5678;
      d_hrdata = 32'hFFFF_FFFF; rd_in = 5'd3;
    #1;
      c32("alu_result_passthrough", wb_data, 32'h1234_5678);
      c32("alu_rd_passthrough",     rd_o,    32'd3);
      c("alu_no_bus_access", d_htrans === HTRANS_IDLE, 1'b1);
      c("alu_no_stall",  mem_stall, 1'b0);
      c("alu_retires",   retire,    1'b1);

    // =================================================================
    // STORE -- lane alignment reaches the bus pins (C10)
    // =================================================================
    @(negedge clk);
      clr; mem_write = 1; ex_result = 32'h2000_0032; funct3 = F3_B;
      rs2_data = 32'h1234_56AB;
    #1;
      c32("sb_haddr",  d_haddr,  32'h2000_0032);
      c("sb_hwrite",   d_hwrite, 1'b1);
      c32("sb_hsize",  d_hsize,  32'b000);
    tick; #1;
      c32("sb_hwdata_lane2", d_hwdata, 32'h00AB_0000);
      c("sb_completes", mem_stall, 1'b0);
      c("sb_retires",   retire,   1'b1);
      c("sb_no_regwrite", reg_write_o, 1'b0);
    // SH on the upper half
    @(negedge clk);
      clr; mem_write = 1; ex_result = 32'h2000_0042; funct3 = F3_H;
      rs2_data = 32'h1234_BEEF;
    tick; #1;
      c32("sh_hwdata_half1", d_hwdata, 32'hBEEF_0000);
      c32("sh_hsize", d_hsize, 32'b001);
    // SW passes through unshifted
    @(negedge clk);
      clr; mem_write = 1; ex_result = 32'h2000_0050; funct3 = F3_W;
      rs2_data = 32'hCAFE_F00D;
    tick; #1;
      c32("sw_hwdata", d_hwdata, 32'hCAFE_F00D);
      c32("sw_hsize",  d_hsize,  32'b010);

    // =================================================================
    // MISALIGNMENT -- no bus transaction is ever issued (C11, Sec. 10.2)
    // =================================================================
    @(negedge clk);
      clr; mem_read = 1; mem_to_reg = 1; reg_write = 1;
      ex_result = 32'h2000_0002; funct3 = F3_W;   // misaligned word load
    saw_nonidle = 0;
    for (i = 0; i < 6; i = i + 1) begin
      #1;
      if (d_htrans !== HTRANS_IDLE) saw_nonidle = 1;
      @(posedge clk);
    end
    #1;
      c("misaligned_lw_never_on_bus", saw_nonidle, 1'b0);
      c("misaligned_lw_no_stall",     mem_stall,   1'b0);
      c("misaligned_lw_no_mem_exc",   exc_valid,   1'b0); // cause 4 is EX's
    @(negedge clk);
      clr; mem_write = 1; ex_result = 32'h2000_0001; funct3 = F3_H;
      rs2_data = 32'hAAAA_5555;
    saw_nonidle = 0;
    for (i = 0; i < 6; i = i + 1) begin
      #1;
      if (d_htrans !== HTRANS_IDLE) saw_nonidle = 1;
      @(posedge clk);
    end
    #1;
      c("misaligned_sh_never_on_bus", saw_nonidle, 1'b0);
      c("misaligned_sh_no_mem_exc",   exc_valid,   1'b0); // cause 6 is EX's
    // a misaligned BYTE access does not exist -- it must still go to the bus
    @(negedge clk);
      clr; mem_read = 1; mem_to_reg = 1; ex_result = 32'h2000_0003; funct3 = F3_B;
    #1;
      c("byte_always_issues", d_htrans === HTRANS_NONSEQ, 1'b1);
    tick; @(negedge clk); clr; #1;

    // =================================================================
    // D-PORT WAIT STATES (Sec. 10.4 / 11.4)
    // =================================================================
    @(negedge clk);
      clr; mem_read = 1; mem_to_reg = 1; reg_write = 1;
      ex_result = 32'h2000_0060; funct3 = F3_W;
    tick;                                        // address phase accepted
    @(negedge clk); d_hready = 0; #1;
      c("wait_stalls",   mem_stall, 1'b1);
      c("wait_no_exc",   exc_valid, 1'b0);
    tick; #1;
      c("wait_stalls2",  mem_stall, 1'b1);
    tick; #1;
      c("wait_stalls3",  mem_stall, 1'b1);
    @(negedge clk); d_hready = 1; d_hrdata = 32'h0BAD_C0DE; #1;
      c("wait_completes",  mem_stall, 1'b0);
      c32("wait_wb_data",  wb_data,   32'h0BAD_C0DE);
      c("wait_retires",    retire,    1'b1);

    // =================================================================
    // BUS ERROR -- causes 5 and 7 (C12, Sec. 14.1/14.2)
    // =================================================================
    // load access fault -> cause 5, mtval = the load address
    @(negedge clk);
      clr; mem_read = 1; mem_to_reg = 1; reg_write = 1;
      ex_result = 32'h4000_0000; funct3 = F3_W; pc_in = 32'h1000_0200;
    tick;
    @(negedge clk); d_hready = 0; d_hresp = 1; #1;      // ERROR cycle 1
      c("load_err_cycle1_quiet", exc_valid, 1'b0);
    @(negedge clk); d_hready = 1; d_hresp = 1; #1;      // ERROR cycle 2
      c("load_err_valid",  exc_valid, 1'b1);
      c32("load_err_cause", exc_cause, 32'd5);
      c32("load_err_mtval", exc_mtval, 32'h4000_0000);
      c32("load_err_pc",    exc_pc,    32'h1000_0200);
      c("load_err_no_retire", retire,  1'b0);           // Sec. 13.2
    @(negedge clk); clr; #1;
      c("load_err_clears", exc_valid, 1'b0);

    // store access fault -> cause 7, SAME address as the load above so a
    // swapped mem_read/mem_write split cannot pass both
    @(negedge clk);
      clr; mem_write = 1; ex_result = 32'h4000_0000; funct3 = F3_W;
      rs2_data = 32'hFEED_FACE; pc_in = 32'h1000_0300;
    tick;
    @(negedge clk); d_hready = 0; d_hresp = 1; #1;
      c("store_err_cycle1_quiet", exc_valid, 1'b0);
    @(negedge clk); d_hready = 1; d_hresp = 1; #1;
      c("store_err_valid",  exc_valid, 1'b1);
      c32("store_err_cause", exc_cause, 32'd7);
      c32("store_err_mtval", exc_mtval, 32'h4000_0000);
      c32("store_err_pc",    exc_pc,    32'h1000_0300);
      c("store_err_no_retire", retire,  1'b0);
    @(negedge clk); clr; d_hresp = 0; #1;

    // =================================================================
    // RETIRE TAG (Sec. 13.2)
    // =================================================================
    @(negedge clk); clr; valid = 1; reg_write = 1; #1;
      c("valid_instr_retires", retire, 1'b1);
    @(negedge clk); clr; valid = 0; #1;
      c("bubble_does_not_retire", retire, 1'b0);

    if (errors == 0) $display("MEM_STAGE INTEG: ALL CHECKS PASSED");
    else             $display("MEM_STAGE INTEG: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
