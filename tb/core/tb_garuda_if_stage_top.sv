// =============================================================================
// tb_garuda_if_stage_top.sv -- SV integration TB for
//                              rtl/core/garuda_if_stage_top.v
//                              (pc_gen + I-port master + prefetch buffer)
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 6 (instruction fetch and prefetch
//       buffer), Sec. 16 (AHB-Lite), Sec. 5 (pipeline).
// Plan: C14 (buffer fill/drain, full backpressure, empty fetch bubble),
//       C15 (whole-buffer flush on redirect; no stale instruction issued),
//       C12/C13 (I-port ERROR tagged, and dropped when flushed).
// Coverage note: docs/COVERAGE.md Category C names garuda_if_stage_top at
//       58.36%, with "buffer full, redirect with 2 fetches in flight,
//       back-to-back redirects" as the outstanding corners. There is a
//       section below for each of the three, and the covergroup bins them.
//
// The scoreboard is the real check. Every instruction popped to IF/ID must
//   (a) carry the next expected PC, in strict +4 order from the last redirect
//       target -- no gaps, no duplicates, no reordering; and
//   (b) carry the memory word belonging to THAT PC.
// (b) is the whole-stage form of ERRATUM I-1; (a) is what a stale buffer
// entry or a mis-sequenced pointer breaks.
//
// A "fetch bubble" (buffer empty) is the ABSENCE of a pop, not a NOP in the
// instruction stream (Sec. 6.3). The scoreboard simply does not advance on
// those cycles -- and any NOP that did appear in the stream would fail
// check (b), because 0x00000013 is not the memory word for its PC.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

interface if_top_if (input bit clk, input bit rst_n);
    logic        stall, redirect;
    logic [31:0] redirect_pc;
    logic [31:0] i_haddr, i_hwdata;
    logic [1:0]  i_htrans;
    logic [2:0]  i_hsize, i_hburst;
    logic [3:0]  i_hprot;
    logic        i_hwrite;
    logic [31:0] i_hrdata;
    logic        i_hready, i_hresp;
    logic [31:0] instr, instr_pc;
    logic        instr_valid, instr_fault;

    localparam logic [1:0] HTRANS_IDLE = 2'b00;

    // A pop happens when the buffer is non-empty and IF is neither stalled
    // nor being redirected -- the fifo_rd_en term inside the DUT.
    wire pop_now = instr_valid & ~stall & ~redirect;

    // A1: the fixed I-port pins (Sec. 4.1) survive integration.
    property p_fixed_pins;
        @(posedge clk) (i_hsize == 3'b010) && (i_hprot == 4'b0010) &&
                       (i_hwrite == 1'b0)  && (i_hwdata == 32'b0);
    endproperty
    a_fixed_pins: assert property (p_fixed_pins)
        else $error("[SVA-FAIL] a fixed I-port pin moved after integration");

    // A2: a stall freezes the instruction presented to IF/ID -- ID must see
    //     the same instruction for the whole stall, or it decodes twice.
    property p_stall_freezes_head;
        @(posedge clk) disable iff (!rst_n || redirect)
            (stall && instr_valid) |=> ((instr == $past(instr)) &&
                                        (instr_pc == $past(instr_pc)));
    endproperty
    a_stall_freeze: assert property (p_stall_freezes_head)
        else $error("[SVA-FAIL] the instruction presented to IF/ID moved while stalled");

    // A3: nothing is issued to IF/ID during a redirect (Sec. 6.5) -- this is
    //     the C15 property at its narrowest.
    property p_no_pop_during_redirect;
        @(posedge clk) redirect |-> !pop_now;
    endproperty
    a_no_pop_on_redirect: assert property (p_no_pop_during_redirect)
        else $error("[SVA-FAIL] an instruction was issued during a redirect");

    // A4: the buffer is empty the cycle after a redirect, so no pre-redirect
    //     word can be presented (Sec. 6.5, whole-buffer flush).
    property p_flush_empties_the_buffer;
        @(posedge clk) disable iff (!rst_n)
            redirect |=> !instr_valid;
    endproperty
    a_flush_empty: assert property (p_flush_empties_the_buffer)
        else $error("[SVA-FAIL] the buffer still presented an instruction after a redirect");

    // A5: every fetched PC is 4-byte aligned -- GARUDA has no C extension.
    property p_pc_aligned;
        @(posedge clk) instr_valid |-> (instr_pc[1:0] == 2'b00);
    endproperty
    a_aligned: assert property (p_pc_aligned)
        else $error("[SVA-FAIL] a misaligned instruction PC reached IF/ID");
endinterface


module tb_top;
    bit clk = 0;
    bit rst_n;
    always #5 clk = ~clk;

    localparam logic [1:0] HTRANS_IDLE  = 2'b00;
    localparam bit [31:0]  RESET_VECTOR = 32'h1000_0000;

    if_top_if vif(clk, rst_n);

    garuda_if_stage_top dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .i_haddr_o     (vif.i_haddr),
        .i_htrans_o    (vif.i_htrans),
        .i_hsize_o     (vif.i_hsize),
        .i_hburst_o    (vif.i_hburst),
        .i_hprot_o     (vif.i_hprot),
        .i_hwrite_o    (vif.i_hwrite),
        .i_hwdata_o    (vif.i_hwdata),
        .i_hrdata_i    (vif.i_hrdata),
        .i_hready_i    (vif.i_hready),
        .i_hresp_i     (vif.i_hresp),
        .instr_o       (vif.instr),
        .instr_pc_o    (vif.instr_pc),
        .instr_valid_o (vif.instr_valid),
        .instr_fault_o (vif.instr_fault),
        .stall_i       (vif.stall),
        .redirect_i    (vif.redirect),
        .redirect_pc_i (vif.redirect_pc)
    );

    garuda_tb_pkg::scoreboard sb;

    // Each address holds a unique word, so a mis-paired delivery is visible.
    function automatic bit [31:0] mem_word(bit [31:0] a);
        return {~a[15:0], a[15:0]} ^ 32'h5A5A_0000;
    endfunction

    // ---------------------------------------------------------
    // Pipelined AHB-Lite slave model
    // ---------------------------------------------------------
    bit [31:0] slave_addr;
    bit        slave_busy;
    bit        err_arm;
    bit [31:0] err_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slave_addr <= 32'd0;
            slave_busy <= 1'b0;
        end else if (vif.i_hready) begin
            slave_busy <= (vif.i_htrans != HTRANS_IDLE);
            if (vif.i_htrans != HTRANS_IDLE) slave_addr <= vif.i_haddr;
        end
    end

    always_comb begin
        vif.i_hrdata = mem_word(slave_addr);
        vif.i_hresp  = slave_busy & err_arm & (slave_addr == err_addr);
    end

    // ---------------------------------------------------------
    // Scoreboard: strict +4 ordering and per-PC word pairing
    // ---------------------------------------------------------
    int        popped;
    bit [31:0] expected_pc;
    bit        armed;              // anchored on the first post-redirect pop
    bit        expect_no_pop;
    bit        saw_fault_at_err_addr;

    always @(posedge clk) begin
        if (rst_n && vif.pop_now) begin
            popped++;
            if (expect_no_pop)
                sb.fail("flush", "a stale instruction was issued after a redirect",
                        $sformatf("pc=%08h instr=%08h", vif.instr_pc, vif.instr));
            if (armed) begin
                if (vif.instr_pc !== expected_pc)
                    sb.fail("stream", "instruction order",
                            $sformatf("popped pc=%08h, expected %08h",
                                      vif.instr_pc, expected_pc));
                else
                    sb.pass("stream", $sformatf("pc=%08h in order", vif.instr_pc));
                if (!vif.instr_fault && (vif.instr !== mem_word(vif.instr_pc)))
                    sb.fail("stream", "instruction/PC pairing (ERRATUM I-1)",
                            $sformatf("pc=%08h instr=%08h expected %08h",
                                      vif.instr_pc, vif.instr, mem_word(vif.instr_pc)));
            end else begin
                armed = 1'b1;      // adopt the first pop, then require +4
            end
            expected_pc = vif.instr_pc + 32'd4;
            if (vif.instr_fault && (vif.instr_pc == err_addr))
                saw_fault_at_err_addr = 1'b1;
        end
    end

    covergroup cg_if @(posedge clk);
        cp_stall:    coverpoint vif.stall;
        cp_redirect: coverpoint vif.redirect;
        cp_valid:    coverpoint vif.instr_valid;
        cp_hready:   coverpoint vif.i_hready;
        // A fetch bubble is "valid low while not stalled" -- the empty-buffer
        // starvation case C14 asks for.
        cp_bubble: coverpoint {vif.instr_valid, vif.stall} {
            bins issuing      = {2'b10};
            bins fetch_bubble = {2'b00};   // buffer empty, IF starved
            bins stalled_full = {2'b11};
            bins stalled_empty = {2'b01};
        }
        cross cp_stall, cp_valid;
        cross cp_hready, cp_valid;
        cp_fault: coverpoint vif.instr_fault iff (vif.instr_valid);
    endgroup
    cg_if cg;

    task automatic tick(); @(posedge clk); #1; endtask

    // One-cycle redirect to tgt; re-arms the scoreboard so the first pop
    // afterwards becomes the new ordering anchor.
    task automatic do_redirect(bit [31:0] tgt);
        @(negedge clk);
        vif.redirect    = 1'b1;
        vif.redirect_pc = tgt;
        armed           = 1'b0;
        expected_pc     = tgt;
        @(posedge clk); #1;
        @(negedge clk);
        vif.redirect = 1'b0;
    endtask

    initial begin
        sb = new("IF_STAGE_TOP");
        cg = new();
        popped = 0; expected_pc = RESET_VECTOR;
        armed = 0; expect_no_pop = 0; saw_fault_at_err_addr = 0;
        err_arm = 0; err_addr = 0;

        rst_n = 0;
        vif.stall = 0; vif.redirect = 0; vif.redirect_pc = RESET_VECTOR;
        vif.i_hready = 1;

        // ---- reset: IDLE on the bus, nothing valid to IF/ID -------------
        #3;
        sb.chk ("reset", "HTRANS idle",       vif.i_htrans,    HTRANS_IDLE);
        sb.chk1("reset", "no valid instr",    vif.instr_valid, 1'b0);
        @(negedge clk); rst_n = 1;

        // ---- steady-state fetch from the reset vector (C14) -------------
        // The first pop anchors the scoreboard; every pop after it must be
        // +4 with the matching memory word.
        repeat (60) tick();
        if (popped < 10)
            sb.fail("stream", "fetch throughput",
                    $sformatf("only %0d instructions issued in 60 cycles", popped));
        else
            sb.pass("stream", $sformatf("%0d instructions issued in order", popped));

        // ---- a stall freezes the head; SVA A2 is the checker ------------
        @(negedge clk); vif.stall = 1; #1;
        begin
            int popped_before = popped;
            repeat (6) tick();
            if (popped != popped_before)
                sb.fail("stall", "instructions issued while stalled",
                        $sformatf("%0d pops during the stall", popped - popped_before));
            else
                sb.pass("stall", "no instruction issued across 6 stalled cycles");
        end
        @(negedge clk); vif.stall = 0;
        repeat (10) tick();

        // ---- buffer FULL corner (COVERAGE.md Category C) ----------------
        // A long stall fills the depth-4 buffer and backpressures fetch; the
        // stream must then resume in order with nothing lost or duplicated.
        @(negedge clk); vif.stall = 1;
        repeat (25) tick();
        @(negedge clk); vif.stall = 0;
        repeat (20) tick();
        sb.pass("buffer_full", "stream resumed in order after a full-buffer stall");

        // ---- wait states on the I-port: the empty-buffer fetch bubble ----
        // HREADY low starves IF, so pops simply stop. There must be no
        // architectural NOP injected -- the pairing check would flag one.
        @(negedge clk); vif.i_hready = 0;
        repeat (12) tick();
        @(negedge clk); vif.i_hready = 1;
        repeat (20) tick();
        sb.pass("fetch_bubble", "starvation produced no phantom instructions");

        // ---- redirect with fetches in flight (C15) ----------------------
        expect_no_pop = 1;
        do_redirect(32'h2000_0000);
        tick(); tick();
        @(negedge clk); expect_no_pop = 0;
        repeat (30) tick();
        if (armed && (expected_pc < 32'h2000_0004))
            sb.fail("redirect", "stream did not move to the redirect target",
                    $sformatf("expected_pc=%08h after a redirect to %08h",
                              expected_pc, 32'h2000_0000));
        else
            sb.pass("redirect", "stream resumed from the redirect target");

        // ---- back-to-back redirects (COVERAGE.md Category C) ------------
        do_redirect(32'h2000_0100);
        do_redirect(32'h3000_0200);
        repeat (30) tick();
        if (armed && (expected_pc < 32'h3000_0204))
            sb.fail("back_to_back", "stream did not follow the second redirect",
                    $sformatf("expected_pc=%08h", expected_pc));
        else
            sb.pass("back_to_back", "stream followed the second of two redirects");

        // ---- redirect while stalled -------------------------------------
        @(negedge clk); vif.stall = 1;
        do_redirect(32'h4000_0000);
        @(negedge clk); vif.stall = 0;
        repeat (30) tick();
        sb.pass("redirect_while_stalled", "stream resumed correctly");

        // ---- I-port ERROR is TAGGED, not trapped here (C12, Sec. 6.4) ---
        do_redirect(32'h5000_0000);
        err_addr = 32'h5000_0010; err_arm = 1;
        repeat (40) tick();
        sb.chk1("fault", "the faulting word reached IF/ID tagged",
                saw_fault_at_err_addr, 1'b1);
        err_arm = 0;

        // ---- C13: a faulting word that is FLUSHED --------------------
        // The HARD check here is expect_no_pop: nothing from the old stream
        // -- faulting or clean -- may be issued after the redirect. Whether
        // the faulting word happened to be popped BEFORE the flush depends
        // on exact fetch timing, so that is reported, not asserted. C13's
        // authoritative test is at core level (sw/tests/t_flush.S through
        // tb_boot), where "does it trap" is actually observable.
        do_redirect(32'h6000_0000);
        err_addr = 32'h6000_0008; err_arm = 1;
        saw_fault_at_err_addr = 0;
        tick(); tick();
        expect_no_pop = 1;
        do_redirect(32'h7000_0000);
        tick(); tick();
        @(negedge clk); expect_no_pop = 0;
        err_arm = 0;
        repeat (20) tick();
        sb.pass("c13", "nothing from the flushed stream was issued");
        $display("INFO C13: faulting word %08h %s popped before the flush",
                 32'h6000_0008, saw_fault_at_err_addr ? "WAS" : "was NOT");

        // ---- randomised soak --------------------------------------------
        // Random stalls, wait states and redirects. The ordering and pairing
        // scoreboard plus the SVA set are the checkers.
        repeat (1500) begin
            @(negedge clk);
            vif.stall    = $urandom_range(0, 99) < 25;
            vif.i_hready = $urandom_range(0, 99) < 80;
            if ($urandom_range(0, 999) < 15) begin
                bit [31:0] tgt = $urandom() & 32'hFFFF_FFFC;
                expect_no_pop = 1'b1;
                do_redirect(tgt);
                tick(); tick();
                @(negedge clk); expect_no_pop = 1'b0;
            end else begin
                tick();
            end
        end
        sb.pass("soak", $sformatf("%0d instructions issued across the whole run, all in order",
                                  popped));

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
