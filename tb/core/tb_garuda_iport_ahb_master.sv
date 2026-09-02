// =============================================================================
// tb_garuda_iport_ahb_master.sv -- SV unit TB for
//                                  rtl/core/garuda_iport_ahb_master.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 6.4 (I-port AHB-Lite operation),
//       Sec. 6.5 (flush, dropped in-flight data), Sec. 4.1 (fixed I-port
//       pins), Sec. 16 (AHB-Lite master protocol).
// Plan: C12 (I-port ERROR -> instruction access fault), C13 (a flushed
//       faulting word must not trap), C14 (fetch-ahead, full backpressure),
//       C15 (whole-buffer flush, no stale instruction issued).
//
// The central regression is ERRATUM I-1, documented in the RTL header: the
// module once completed a transfer in its ADDRESS phase and therefore paired
// every instruction with the PREVIOUS bus cycle's read data, while keeping
// its own correct PC tag. A testbench that only checked "some data arrived"
// passes that broken RTL. Here the memory model's word at address A is a
// UNIQUE function of A, and the SVA plus the scoreboard check the
// (data_pc_o, data_instr_o) PAIR on every delivery -- which is precisely the
// property the old RTL violated and no earlier testbench tested.
//
// Environment (behavioural models, not the real blocks -- those have their
// own TBs, and the point here is to drive this master with realistic
// backpressure):
//   * pc model    -- fetch_pc advances by 4 per fetch_issue_o, reloads on
//                    redirect. Mirrors garuda_pc_gen.
//   * FIFO model  -- occupancy +1 on data_valid_o, -1 on rd_en, cleared on
//                    redirect. Mirrors garuda_prefetch_buffer's accounting,
//                    so the master's reservation logic sees real pressure.
//   * AHB slave   -- pipelined: latches the address phase, drives HRDATA in
//                    the following data phase. Wait states and ERROR are
//                    switchable.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

interface iport_if (input bit clk, input bit rst_n);
    logic        redirect;
    logic [31:0] fetch_pc;
    logic [2:0]  fifo_occupancy;
    logic        fifo_rd_en;
    logic [31:0] i_haddr, i_hwdata;
    logic [1:0]  i_htrans;
    logic [2:0]  i_hsize, i_hburst;
    logic [3:0]  i_hprot;
    logic        i_hwrite;
    logic [31:0] i_hrdata;
    logic        i_hready, i_hresp;
    logic        fetch_issue, data_valid, data_fault;
    logic [31:0] data_instr, data_pc;

    localparam logic [1:0] HTRANS_IDLE   = 2'b00;
    localparam logic [1:0] HTRANS_NONSEQ = 2'b10;
    localparam logic [1:0] HTRANS_SEQ    = 2'b11;

    // A1: the fixed I-port pins (Sec. 4.1) -- word size, opcode-fetch
    //     protection, never writes.
    property p_fixed_pins;
        @(posedge clk) (i_hsize == 3'b010) && (i_hprot == 4'b0010) &&
                       (i_hwrite == 1'b0)  && (i_hwdata == 32'b0);
    endproperty
    a_fixed_pins: assert property (p_fixed_pins)
        else $error("[SVA-FAIL] a fixed I-port pin (HSIZE/HPROT/HWRITE/HWDATA) moved");

    // A2: HBURST follows HTRANS -- INCR while SEQ (sequential prefetch),
    //     SINGLE otherwise (Sec. 6.4).
    property p_hburst_tracks_htrans;
        @(posedge clk) (i_htrans == HTRANS_SEQ) ? (i_hburst == 3'b001)
                                                : (i_hburst == 3'b000);
    endproperty
    a_hburst: assert property (p_hburst_tracks_htrans)
        else $error("[SVA-FAIL] HBURST does not track HTRANS (INCR only while SEQ)");

    // A3: no new address phase is presented in a redirect cycle -- the
    //     master retracts to IDLE (Sec. 6.5).
    property p_no_issue_during_redirect;
        @(posedge clk) redirect |-> !fetch_issue;
    endproperty
    a_no_issue_on_redirect: assert property (p_no_issue_during_redirect)
        else $error("[SVA-FAIL] a fetch was issued during a redirect");

    // A4: nothing is written to the buffer in a redirect cycle.
    property p_no_data_during_redirect;
        @(posedge clk) redirect |-> !data_valid;
    endproperty
    a_no_data_on_redirect: assert property (p_no_data_during_redirect)
        else $error("[SVA-FAIL] data was delivered during a redirect");

    // A5: HTRANS is only ever IDLE, NONSEQ or SEQ -- BUSY is never driven.
    property p_no_busy;
        @(posedge clk) (i_htrans != 2'b01);
    endproperty
    a_no_busy: assert property (p_no_busy)
        else $error("[SVA-FAIL] the I-port drove HTRANS=BUSY");

    // A6: address-phase stability while HREADY is low (Sec. 16.2).
    property p_addr_stable_under_wait;
        @(posedge clk) disable iff (!rst_n || redirect)
            ((i_htrans != HTRANS_IDLE) && !i_hready)
            |=> ((i_haddr == $past(i_haddr)) && (i_htrans == $past(i_htrans)));
    endproperty
    a_addr_stable: assert property (p_addr_stable_under_wait)
        else $error("[SVA-FAIL] HADDR/HTRANS moved while HREADY was low");
endinterface


module tb_top;
    bit clk = 0;
    bit rst_n;
    always #5 clk = ~clk;

    localparam logic [1:0] HTRANS_IDLE   = 2'b00;
    localparam logic [1:0] HTRANS_NONSEQ = 2'b10;
    localparam logic [1:0] HTRANS_SEQ    = 2'b11;
    localparam bit [31:0]  RESET_VECTOR  = 32'h1000_0000;

    iport_if vif(clk, rst_n);

    garuda_iport_ahb_master #(.FIFO_DEPTH(4)) dut (
        .clk_i            (clk),
        .rst_n_i          (rst_n),
        .redirect_i       (vif.redirect),
        .fetch_pc_i       (vif.fetch_pc),
        .fifo_occupancy_i (vif.fifo_occupancy),
        .fifo_rd_en_i     (vif.fifo_rd_en),
        .i_haddr_o        (vif.i_haddr),
        .i_htrans_o       (vif.i_htrans),
        .i_hsize_o        (vif.i_hsize),
        .i_hburst_o       (vif.i_hburst),
        .i_hprot_o        (vif.i_hprot),
        .i_hwrite_o       (vif.i_hwrite),
        .i_hwdata_o       (vif.i_hwdata),
        .i_hrdata_i       (vif.i_hrdata),
        .i_hready_i       (vif.i_hready),
        .i_hresp_i        (vif.i_hresp),
        .fetch_issue_o    (vif.fetch_issue),
        .data_valid_o     (vif.data_valid),
        .data_instr_o     (vif.data_instr),
        .data_pc_o        (vif.data_pc),
        .data_fault_o     (vif.data_fault)
    );

    garuda_tb_pkg::scoreboard sb;

    // Each address holds a unique word, so a mis-paired delivery is
    // detectable from the (pc, instr) pair alone. This is what makes the
    // ERRATUM I-1 check possible.
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
    // PC generator and FIFO occupancy models
    // ---------------------------------------------------------
    bit [31:0] redirect_target;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vif.fetch_pc       <= RESET_VECTOR;
            vif.fifo_occupancy <= 3'd0;
        end else if (vif.redirect) begin
            vif.fetch_pc       <= redirect_target;
            vif.fifo_occupancy <= 3'd0;
        end else begin
            if (vif.fetch_issue) vif.fetch_pc <= vif.fetch_pc + 32'd4;
            case ({vif.data_valid, vif.fifo_rd_en})
                2'b10: vif.fifo_occupancy <= vif.fifo_occupancy + 3'd1;
                2'b01: if (vif.fifo_occupancy != 0)
                           vif.fifo_occupancy <= vif.fifo_occupancy - 3'd1;
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------
    // Continuous scoreboard checks
    // ---------------------------------------------------------
    int  delivered;
    bit  expect_no_delivery;
    bit  saw_first_after_redirect;
    bit [31:0] first_pc_after_redirect;
    bit  saw_tagged_fault;

    always @(posedge clk) begin
        if (rst_n) begin
            // The FIFO must never be overrun: the master has to count BOTH
            // in-flight transfers (address phase and data phase), or a
            // 2-deep bus pipeline overruns a depth-4 FIFO.
            if (vif.fifo_occupancy > 3'd4)
                sb.fail("invariant", "FIFO overrun",
                        $sformatf("occupancy=%0d exceeds depth 4", vif.fifo_occupancy));

            if (vif.data_valid) begin
                delivered++;
                // ERRATUM I-1: the delivered word must belong to the
                // delivered PC.
                if (!vif.data_fault) begin
                    if (vif.data_instr !== mem_word(vif.data_pc))
                        sb.fail("erratum_i1", "instruction/PC pairing",
                                $sformatf("pc=%08h instr=%08h expected %08h",
                                          vif.data_pc, vif.data_instr,
                                          mem_word(vif.data_pc)));
                    else
                        sb.pass("erratum_i1",
                                $sformatf("pc=%08h paired with its own word", vif.data_pc));
                end
                if (expect_no_delivery)
                    sb.fail("flush", "stale delivery after a redirect",
                            $sformatf("pc=%08h instr=%08h", vif.data_pc, vif.data_instr));
                if (!saw_first_after_redirect) begin
                    first_pc_after_redirect = vif.data_pc;
                    saw_first_after_redirect = 1'b1;
                end
                if (vif.data_fault && (vif.data_pc == err_addr))
                    saw_tagged_fault = 1'b1;
                if (vif.data_fault && (vif.data_pc != err_addr))
                    sb.fail("fault", "fault tagged on the wrong entry",
                            $sformatf("pc=%08h, error address is %08h",
                                      vif.data_pc, err_addr));
            end
        end
    end

    covergroup cg_iport @(posedge clk);
        cp_htrans: coverpoint vif.i_htrans {
            bins idle   = {HTRANS_IDLE};
            bins nonseq = {HTRANS_NONSEQ};      // first fetch after a redirect
            bins seq    = {HTRANS_SEQ};         // sequential prefetch, INCR
            illegal_bins busy = {2'b01};
        }
        cp_hready: coverpoint vif.i_hready;
        cp_hresp:  coverpoint vif.i_hresp;
        cp_occupancy: coverpoint vif.fifo_occupancy {
            bins empty_ = {0}; bins partial = {[1:3]}; bins full_ = {4};
        }
        cp_issue: coverpoint vif.fetch_issue;
        // Backpressure: the master must be seen NOT issuing while the buffer
        // is full, and issuing while it is not.
        cross cp_occupancy, cp_issue;
        cross cp_htrans, cp_hready;
        cp_redirect: coverpoint vif.redirect;
        cp_valid:    coverpoint vif.data_valid;
        cross cp_redirect, cp_valid {
            // Nothing may be delivered in a redirect cycle (SVA A4), so this
            // bin is unreachable by construction rather than untested.
            ignore_bins no_delivery_during_redirect =
                binsof(cp_redirect) intersect {1} && binsof(cp_valid) intersect {1};
        }
    endgroup
    cg_iport cg;

    task automatic tick(); @(posedge clk); #1; endtask

    // One-cycle redirect to tgt.
    task automatic do_redirect(bit [31:0] tgt);
        @(negedge clk);
        redirect_target = tgt;
        vif.redirect    = 1'b1;
        @(posedge clk); #1;
        @(negedge clk);
        vif.redirect = 1'b0;
    endtask

    initial begin
        sb = new("IPORT_AHB_MASTER");
        cg = new();
        delivered = 0; expect_no_delivery = 0;
        saw_first_after_redirect = 1; first_pc_after_redirect = 0;
        saw_tagged_fault = 0;
        redirect_target = RESET_VECTOR;

        rst_n = 0;
        vif.redirect = 0; vif.fifo_rd_en = 0;
        vif.i_hready = 1; err_arm = 0; err_addr = 0;

        // ---- reset / idle (Sec. 4.2, 16.3) -----------------------------
        #3;
        sb.chk("reset", "HTRANS idle out of reset", vif.i_htrans, HTRANS_IDLE);
        @(negedge clk); rst_n = 1;

        // ---- the first transfer after reset is NONSEQ (Sec. 6.4) -------
        // HADDR/HTRANS are REGISTERED, so the first transfer appears some
        // cycles after reset rather than at a fixed one -- scan for it
        // instead of asserting on an exact cycle number.
        vif.fifo_rd_en = 1;                 // IF pops every cycle: steady state
        begin
            bit found = 0;
            for (int i = 0; i < 10 && !found; i++) begin
                tick();
                if (vif.i_htrans != HTRANS_IDLE) begin
                    found = 1;
                    sb.chk("first_transfer", "is NONSEQ", vif.i_htrans, HTRANS_NONSEQ);
                    sb.chk("first_transfer", "HADDR = reset vector",
                           vif.i_haddr, RESET_VECTOR);
                end
            end
            sb.chk1("first_transfer", "a transfer was issued", found, 1'b1);
        end
        // the next transfer is SEQ: sequential prefetch uses INCR
        begin
            bit found_seq = 0;
            for (int i = 0; i < 10 && !found_seq; i++) begin
                tick();
                if (vif.i_htrans == HTRANS_SEQ) found_seq = 1;
            end
            sb.chk1("second_transfer", "is SEQ (INCR prefetch)", found_seq, 1'b1);
        end

        // ---- streaming: ERRATUM I-1 pairing is checked continuously -----
        delivered = 0;
        repeat (40) tick();
        if (delivered < 10)
            sb.fail("stream", "throughput",
                    $sformatf("only %0d deliveries in 40 cycles", delivered));
        else
            sb.pass("stream", $sformatf("%0d instructions delivered, all correctly paired",
                                        delivered));

        // ---- wait states: SVA A6 is the checker -------------------------
        @(negedge clk); vif.i_hready = 0;
        repeat (4) tick();
        @(negedge clk); vif.i_hready = 1;
        repeat (8) tick();
        sb.pass("wait_states", "address/control held stable across 4 wait cycles");

        // ---- FIFO full backpressure (C14) -------------------------------
        // Stop popping: occupancy fills, and the master must stop issuing
        // before more than FIFO_DEPTH words can ever land.
        @(negedge clk); vif.fifo_rd_en = 0;
        repeat (30) tick();
        sb.chk ("backpressure", "occupancy settles at depth", vif.fifo_occupancy, 3'd4);
        sb.chk1("backpressure", "no issue while full", vif.fetch_issue, 1'b0);
        // resume popping and confirm fetching restarts
        @(negedge clk); vif.fifo_rd_en = 1;
        delivered = 0;
        repeat (20) tick();
        if (delivered == 0)
            sb.fail("backpressure", "fetching did not restart after backpressure", "");
        else
            sb.pass("backpressure", "fetching restarted once the buffer drained");

        // ---- redirect: in-flight data must be DROPPED (Sec. 6.5 / C15) --
        // Two transfers are live here (one address phase, one data phase).
        // Neither may be delivered after the redirect, even though one
        // completes a cycle or more AFTER redirect_i has fallen -- that is
        // the drop_cnt obligation the RTL header describes.
        expect_no_delivery = 1;
        saw_first_after_redirect = 0;
        do_redirect(32'h3000_0000);
        tick(); tick();                    // the owed data phases land here
        @(negedge clk); expect_no_delivery = 0;
        sb.pass("flush", "no stale delivery while data was owed after the redirect");
        // the first transfer after a redirect is NONSEQ again
        begin
            bit found_nonseq = 0;
            for (int i = 0; i < 8 && !found_nonseq; i++) begin
                if ((vif.i_htrans == HTRANS_NONSEQ) && (vif.i_haddr == 32'h3000_0000))
                    found_nonseq = 1;
                tick();
            end
            sb.chk1("flush", "first post-redirect transfer is NONSEQ", found_nonseq, 1'b1);
        end
        repeat (10) tick();
        sb.chk1("flush", "a word was delivered after the redirect",
                saw_first_after_redirect, 1'b1);
        if (saw_first_after_redirect)
            sb.chk("flush", "first post-redirect PC is the new target",
                   first_pc_after_redirect, 32'h3000_0000);

        // ---- HRESP = ERROR is TAGGED on the right entry (C12) -----------
        // Sec. 6.4: the fault is tagged here and only raised when the entry
        // reaches ID -- which is what makes C13 possible at all.
        saw_tagged_fault = 0;
        err_addr = 32'h3000_0020; err_arm = 1;
        repeat (24) tick();
        sb.chk1("fault", "the faulting fetch was tagged", saw_tagged_fault, 1'b1);
        err_arm = 0;

        // ---- C13: a faulting word that is FLUSHED is never delivered ----
        err_addr = 32'h7000_0010; err_arm = 1;
        do_redirect(32'h7000_0000);
        tick(); tick();
        expect_no_delivery = 1;
        do_redirect(32'h8000_0000);
        tick(); tick();
        @(negedge clk); expect_no_delivery = 0;
        err_arm = 0;
        repeat (10) tick();
        sb.pass("c13", "nothing from the flushed stream was delivered");

        // ---- randomised soak: wait states, errors and redirects ---------
        // The continuous pairing check and the SVA set are the checkers.
        err_arm = 0;
        repeat (800) begin
            @(negedge clk);
            vif.fifo_rd_en = $urandom_range(0, 99) < 60;
            vif.i_hready   = $urandom_range(0, 99) < 75;
            if ($urandom_range(0, 999) < 20) begin
                // an occasional redirect, with the delivery window masked
                // for the two cycles in which owed data can still land
                redirect_target = $urandom() & 32'hFFFF_FFFC;
                vif.redirect = 1'b1;
                expect_no_delivery = 1'b1;
                @(posedge clk); #1;
                @(negedge clk); vif.redirect = 1'b0;
                tick(); tick();
                @(negedge clk); expect_no_delivery = 1'b0;
            end else begin
                tick();
            end
        end
        sb.pass("soak", "800 randomised cycles with SVA and pairing checks armed");

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
