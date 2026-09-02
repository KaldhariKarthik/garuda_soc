// =============================================================================
// tb_mem_wb_reg.sv -- SystemVerilog unit TB for rtl/core/mem_wb_reg.v,
//                     with wb_stage.v instantiated downstream of it.
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 5.2 (pipeline registers, bubble
//       state), Sec. 10.3 (mux-in-MEM contract), Sec. 11.4 (flush), Sec. 13.2
//       (minstret retirement pulse).
// Plan: supports C28 (reset leaves the pipeline in the bubble state) and the
//       D-port-wait-state row of the Sec. 11.4 hold table.
//
// wb_stage.v is deliberately NOT given a TB of its own: Sec. 5 calls it a
// structural boundary and it is three assigns with no state. Instantiating it
// here and reading every check THROUGH it verifies the same wires plus the
// MEM/WB -> WB -> register-file-write-port ordering, which a standalone TB
// for three assigns would not.
//
// The check worth reading: retire_o is counted, not sampled. A flush that
// killed the register write but left the retire tag set would silently
// inflate minstret -- and minstret is what Sec. 18.1 lists as the built-in
// observability hook for IPC and trace checks, so the error would corrupt the
// measurement used to find other errors. The RTL header also warns that a
// HOLD here (rather than bubble-on-wait) would replay the previous
// instruction's writeback every wait-state cycle; the wait_state_replay
// sequence is the regression for that.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

// -------------------------------------------------------------
// 1. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface memwb_if (input bit clk, input bit rst_n);
    logic        flush;
    logic [31:0] wb_data_i;
    logic [4:0]  rd_i;
    logic        reg_write_i, retire_i;
    logic [31:0] wb_data_o;
    logic [4:0]  rd_o;
    logic        reg_write_o, retire_o;
    // wb_stage outputs (the register-file write port)
    logic        rf_we;
    logic [4:0]  rf_rd;
    logic [31:0] rf_wdata;

    // A1: a flush inserts a bubble -- BOTH the write enable and the retire
    //     tag must be low on the following edge (Sec. 11.4).
    property p_flush_makes_a_bubble;
        @(posedge clk) disable iff (!rst_n)
            flush |=> (!reg_write_o && !retire_o);
    endproperty
    a_flush_bubble: assert property (p_flush_makes_a_bubble)
        else $error("[SVA-FAIL] flush did not produce a full bubble (write and/or retire survived)");

    // A2: a bubble carries no payload either -- rd and data are cleared, so
    //     nothing stale can be re-presented to the write port.
    property p_bubble_is_clean;
        @(posedge clk) disable iff (!rst_n)
            flush |=> ((wb_data_o == 32'd0) && (rd_o == 5'd0));
    endproperty
    a_bubble_clean: assert property (p_bubble_is_clean)
        else $error("[SVA-FAIL] a flushed bubble still carried rd/wb_data");

    // A3: with no flush the register is transparent one cycle later -- this
    //     is what makes it a pipeline register rather than a gate.
    property p_normal_capture;
        @(posedge clk) disable iff (!rst_n)
            (!flush) |=> ($past(wb_data_i)   == wb_data_o &&
                          $past(rd_i)        == rd_o      &&
                          $past(reg_write_i) == reg_write_o &&
                          $past(retire_i)    == retire_o);
    endproperty
    a_capture: assert property (p_normal_capture)
        else $error("[SVA-FAIL] MEM/WB did not capture its inputs on the clock edge");

    // A4: wb_stage is a pass-through -- the write port always mirrors the
    //     register outputs, with no re-decoding in between.
    property p_wb_stage_is_transparent;
        @(posedge clk) (rf_we == reg_write_o) && (rf_rd == rd_o) &&
                       (rf_wdata == wb_data_o);
    endproperty
    a_wb_transparent: assert property (p_wb_stage_is_transparent)
        else $error("[SVA-FAIL] wb_stage did not pass MEM/WB straight to the write port");

    // A5: a bubble never retires -- restated as an absolute, because this is
    //     the minstret correctness property.
    property p_no_write_no_stale_retire;
        @(posedge clk) disable iff (!rst_n)
            (retire_o && !$past(flush)) |-> $past(retire_i);
    endproperty
    a_retire_sourced: assert property (p_no_write_no_stale_retire)
        else $error("[SVA-FAIL] retire_o asserted without an incoming retire tag");
endinterface


// -------------------------------------------------------------
// 2. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    bit rst_n;
    always #5 clk = ~clk;

    memwb_if vif(clk, rst_n);

    mem_wb_reg dut (
        .clk_i       (clk),
        .rst_n_i     (rst_n),
        .flush_i     (vif.flush),
        .wb_data_i   (vif.wb_data_i),
        .rd_i        (vif.rd_i),
        .reg_write_i (vif.reg_write_i),
        .retire_i    (vif.retire_i),
        .wb_data_o   (vif.wb_data_o),
        .rd_o        (vif.rd_o),
        .reg_write_o (vif.reg_write_o),
        .retire_o    (vif.retire_o)
    );

    // Sec. 5 structural boundary: WB drives the register-file write port.
    wb_stage u_wb (
        .wb_data_i   (vif.wb_data_o),
        .rd_i        (vif.rd_o),
        .reg_write_i (vif.reg_write_o),
        .rf_we_o     (vif.rf_we),
        .rf_rd_o     (vif.rf_rd),
        .rf_wdata_o  (vif.rf_wdata)
    );

    garuda_tb_pkg::scoreboard sb;

    // ---------------------------------------------------------
    // Coverage
    // ---------------------------------------------------------
    covergroup cg_memwb @(posedge clk);
        cp_flush:     coverpoint vif.flush;
        cp_regwrite:  coverpoint vif.reg_write_i;
        cp_retire:    coverpoint vif.retire_i;
        // A store retires without writing a register; a load does both; a
        // faulting access does neither. All three must be seen.
        cross cp_regwrite, cp_retire;
        cross cp_flush, cp_retire;
        cp_rd: coverpoint vif.rd_i {
            bins x0     = {5'd0};              // writes to x0 are discarded
            bins low    = {[5'd1:5'd15]};
            bins high   = {[5'd16:5'd31]};
        }
    endgroup
    cg_memwb cg;

    // Retire pulses are COUNTED, not sampled: a replayed writeback shows up
    // as an extra pulse, which a single-cycle sample would never catch.
    int retire_count;
    always @(posedge clk) if (rst_n && vif.retire_o) retire_count++;

    // ---------------------------------------------------------
    // Stimulus helpers
    // ---------------------------------------------------------
    task automatic drive(bit [31:0] d, bit [4:0] rd, bit rw, bit ret, bit fl);
        @(negedge clk);
        vif.wb_data_i   <= d;
        vif.rd_i        <= rd;
        vif.reg_write_i <= rw;
        vif.retire_i    <= ret;
        vif.flush       <= fl;
        @(posedge clk);
        #1;
    endtask

    initial begin
        sb = new("MEM_WB_REG");
        cg = new();
        retire_count = 0;

        rst_n = 0;
        vif.flush = 0; vif.wb_data_i = 32'hDEAD_BEEF; vif.rd_i = 5'd7;
        vif.reg_write_i = 1; vif.retire_i = 1;

        // ---- reset is asynchronous and forces the bubble state (C28) ----
        #3;
        sb.chk ("reset", "wb_data_o",   vif.wb_data_o,   32'd0);
        sb.chk ("reset", "rd_o",        vif.rd_o,        32'd0);
        sb.chk1("reset", "reg_write_o", vif.reg_write_o, 1'b0);
        sb.chk1("reset", "retire_o",    vif.retire_o,    1'b0);
        sb.chk1("reset", "rf_we",       vif.rf_we,       1'b0);
        @(negedge clk); rst_n = 1;

        // ---- normal capture, read through wb_stage --------------------
        drive(32'h1234_5678, 5'd9, 1'b1, 1'b1, 1'b0);
        sb.chk ("capture", "wb_data_o",   vif.wb_data_o,   32'h1234_5678);
        sb.chk ("capture", "rd_o",        vif.rd_o,        32'd9);
        sb.chk1("capture", "reg_write_o", vif.reg_write_o, 1'b1);
        sb.chk1("capture", "retire_o",    vif.retire_o,    1'b1);
        sb.chk ("capture", "rf_wdata",    vif.rf_wdata,    32'h1234_5678);
        sb.chk ("capture", "rf_rd",       vif.rf_rd,       32'd9);
        sb.chk1("capture", "rf_we",       vif.rf_we,       1'b1);

        // held for the whole cycle, not a glitch
        #3;
        sb.chk ("hold", "wb_data_o held",   vif.wb_data_o,   32'h1234_5678);
        sb.chk1("hold", "reg_write_o held", vif.reg_write_o, 1'b1);

        // ---- a store retires but writes no register --------------------
        drive(32'hAAAA_5555, 5'd0, 1'b0, 1'b1, 1'b0);
        sb.chk1("store", "no reg_write", vif.reg_write_o, 1'b0);
        sb.chk1("store", "retires",      vif.retire_o,    1'b1);
        sb.chk1("store", "rf_we low",    vif.rf_we,       1'b0);

        // ---- flush inserts a bubble (Sec. 11.4) ------------------------
        drive(32'hCAFE_F00D, 5'd11, 1'b1, 1'b1, 1'b1);
        sb.chk1("flush", "no reg_write", vif.reg_write_o, 1'b0);
        sb.chk1("flush", "no retire",    vif.retire_o,    1'b0);
        sb.chk ("flush", "wb_data zero", vif.wb_data_o,   32'd0);
        sb.chk ("flush", "rd zero",      vif.rd_o,        32'd0);
        sb.chk1("flush", "rf_we low",    vif.rf_we,       1'b0);

        // ---- multi-cycle D-port wait state: bubble every cycle, NO replay
        // The RTL header's warning: a hold here would replay the previous
        // instruction's writeback on every wait-state cycle.
        drive(32'h0BAD_0BAD, 5'd13, 1'b1, 1'b1, 1'b0);
        sb.chk1("pre_wait", "reg_write high", vif.reg_write_o, 1'b1);
        for (int i = 0; i < 4; i++) begin
            drive(32'h0BAD_0BAD, 5'd13, 1'b1, 1'b1, 1'b1);
            // The first flush edge still samples the PREVIOUS (legitimate)
            // instruction's retire pulse, so start counting after it.
            if (i == 0) retire_count = 0;
            sb.chk1("wait_state", "bubble reg_write", vif.reg_write_o, 1'b0);
            sb.chk1("wait_state", "bubble retire",    vif.retire_o,    1'b0);
        end
        if (retire_count != 0)
            sb.fail("wait_state", "writeback replayed during wait states",
                    $sformatf("%0d retire pulses across 4 flush cycles, expected 0",
                              retire_count));
        else
            sb.pass("wait_state", "no writeback replay across 4 flush cycles");

        // ---- exactly one retire pulse per retired instruction (Sec. 13.2)
        retire_count = 0;
        drive(32'h1111_1111, 5'd1, 1'b1, 1'b1, 1'b0);   // retires
        drive(32'h2222_2222, 5'd2, 1'b1, 1'b0, 1'b0);   // faulted: no retire
        drive(32'h3333_3333, 5'd3, 1'b1, 1'b1, 1'b0);   // retires
        drive(32'h4444_4444, 5'd4, 1'b1, 1'b1, 1'b1);   // flushed: no retire
        @(posedge clk); #1;
        if (retire_count != 2)
            sb.fail("minstret", "retire pulse count",
                    $sformatf("got %0d, expected 2", retire_count));
        else
            sb.pass("minstret", "exactly 2 retire pulses for 2 retired instrs");

        // ---- reset asserted mid-stream clears the register --------------
        drive(32'h9999_9999, 5'd21, 1'b1, 1'b1, 1'b0);
        sb.chk1("async_reset", "pre-reset reg_write", vif.reg_write_o, 1'b1);
        rst_n = 0; #1;
        sb.chk1("async_reset", "reg_write cleared", vif.reg_write_o, 1'b0);
        sb.chk ("async_reset", "wb_data cleared",   vif.wb_data_o,   32'd0);
        sb.chk1("async_reset", "retire cleared",    vif.retire_o,    1'b0);
        @(negedge clk); rst_n = 1;

        // ---- randomised soak: the SVA above is the checker here ---------
        // reg_write/retire/flush combinations in random order, so the
        // property set is exercised on sequences the directed cases do not
        // enumerate (e.g. flush immediately following flush).
        repeat (400) begin
            bit [31:0] d  = $urandom();
            bit [4:0]  rd = $urandom_range(0, 31);
            bit rw  = $urandom_range(0, 1);
            bit ret = $urandom_range(0, 1);
            bit fl  = ($urandom_range(0, 99) < 25);   // flush ~25% of cycles
            drive(d, rd, rw, ret, fl);
        end
        sb.pass("soak", "400 randomised cycles completed with SVA armed");

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
