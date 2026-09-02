// =============================================================================
// tb_d_port_ahb_master.sv -- SV unit TB for rtl/core/d_port_ahb_master.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 10.4 (wait states), Sec. 16.1-16.3
//       (AHB-Lite master, two-cycle ERROR response, reset/idle).
// Plan: C12 ("D-port ERROR raises access fault 5/7 precisely") at the bus
//       level, plus the D-port-wait-state row of the Sec. 11.4 hold table.
//       The cause NUMBERS are mem_stage's to assign (tb_mem_stage.sv); this
//       TB owns the bus protocol underneath them.
//
// THE reason this file exists is ERRATUM D-1, documented at length in the RTL
// header: the module used to complete a transfer in its ADDRESS phase, which
// made every store write zero and every load return the previous bus cycle's
// data. Three checks are direct regressions for it, and each is stated twice
// -- once as an SVA property that holds on every cycle, once as a directed
// sequence:
//
//   store_hwdata_held_after_start_falls
//       start_i and hwdata_i are DROPPED the moment the address phase is
//       accepted -- which is what the pipeline actually does, since the hold
//       is released by that very event. d_hwdata_o must still present the
//       captured value throughout the data phase. The old RTL collapsed it
//       to 0 exactly here, and every store wrote zero.
//   ok_done_is_a_data_phase_event
//       completion must not be signalled during the address phase; the data
//       phase is the cycle load_formatter samples HRDATA.
//   stall_released_only_on_completion
//       mem_stall_o must cover BOTH phases and drop only in the completing
//       cycle. Releasing it early is what made loads sample HRDATA a cycle
//       before the slave drove it.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

interface dport_if (input bit clk, input bit rst_n);
    logic        start, hwrite_in;
    logic [31:0] addr, hwdata_in;
    logic [2:0]  hsize_in;
    logic [31:0] d_haddr, d_hwdata;
    logic [1:0]  d_htrans;
    logic [2:0]  d_hsize;
    logic        d_hwrite;
    logic        d_hready, d_hresp;
    logic        mem_stall, ok_done, err_pulse;

    localparam logic [1:0] HTRANS_IDLE   = 2'b00;
    localparam logic [1:0] HTRANS_NONSEQ = 2'b10;

    // A1: ERRATUM D-1. A completion may only be signalled in a cycle where
    //     the master is NOT presenting an address phase. Restated: if HTRANS
    //     is being driven this cycle, the transfer is not done yet.
    property p_no_completion_during_address_phase;
        @(posedge clk) disable iff (!rst_n)
            (d_htrans == HTRANS_NONSEQ) |-> (!ok_done && !err_pulse);
    endproperty
    a_no_early_done: assert property (p_no_completion_during_address_phase)
        else $error("[SVA-FAIL] ERRATUM D-1: completion signalled during the address phase");

    // A2: ERRATUM D-1. Once an address phase has been accepted, the captured
    //     write data must remain stable until the data phase completes, even
    //     though start_i/hwdata_i have already gone away upstream.
    //     "Stalled with no address phase on the bus" is exactly the waiting
    //     data phase, which is where the old RTL let HWDATA collapse to 0.
    property p_hwdata_stable_in_data_phase;
        @(posedge clk) disable iff (!rst_n)
            (mem_stall && (d_htrans == HTRANS_IDLE))
            |=> (d_hwdata == $past(d_hwdata));
    endproperty
    a_hwdata_stable: assert property (p_hwdata_stable_in_data_phase)
        else $error("[SVA-FAIL] ERRATUM D-1: d_hwdata_o moved during the data phase");

    // A3: the stall covers the whole access and drops exactly when it
    //     completes (Sec. 11.4). A completion cycle is never a stall cycle.
    property p_stall_clears_on_completion;
        @(posedge clk) disable iff (!rst_n)
            (ok_done || err_pulse) |-> (!mem_stall);
    endproperty
    a_stall_clear: assert property (p_stall_clears_on_completion)
        else $error("[SVA-FAIL] mem_stall_o still asserted in the completing cycle");

    // A4: completion is mutually exclusive -- an access is OKAY or ERROR,
    //     never both.
    property p_ok_err_exclusive;
        @(posedge clk) !(ok_done && err_pulse);
    endproperty
    a_exclusive: assert property (p_ok_err_exclusive)
        else $error("[SVA-FAIL] ok_done_o and err_pulse_o asserted together");

    // A5: address-phase stability (Sec. 16.2 "the master holds address and
    //     control stable" while HREADY is low).
    property p_address_stable_under_wait;
        @(posedge clk) disable iff (!rst_n)
            ((d_htrans == HTRANS_NONSEQ) && !d_hready)
            |=> ((d_haddr == $past(d_haddr)) && (d_hwrite == $past(d_hwrite)) &&
                 (d_hsize == $past(d_hsize)) && (d_htrans == $past(d_htrans)));
    endproperty
    a_addr_stable: assert property (p_address_stable_under_wait)
        else $error("[SVA-FAIL] address/control moved while HREADY was low");

    // A6: the D-port issues SINGLE transfers only -- it never drives SEQ.
    property p_never_seq;
        @(posedge clk) (d_htrans != 2'b11);
    endproperty
    a_no_seq: assert property (p_never_seq)
        else $error("[SVA-FAIL] the D-port drove HTRANS=SEQ (Sec. 16.2: SINGLE only)");

    // A7: no transfer is presented while idle.
    property p_idle_when_no_request;
        @(posedge clk) disable iff (!rst_n)
            (!start) |-> (d_htrans == HTRANS_IDLE);
    endproperty
    a_idle: assert property (p_idle_when_no_request)
        else $error("[SVA-FAIL] a transfer was presented with start_i low");
endinterface


module tb_top;
    bit clk = 0;
    bit rst_n;
    always #5 clk = ~clk;

    localparam logic [1:0] HTRANS_IDLE   = 2'b00;
    localparam logic [1:0] HTRANS_NONSEQ = 2'b10;

    dport_if vif(clk, rst_n);

    d_port_ahb_master dut (
        .clk_i       (clk),
        .rst_n_i     (rst_n),
        .start_i     (vif.start),
        .hwrite_i    (vif.hwrite_in),
        .addr_i      (vif.addr),
        .hsize_i     (vif.hsize_in),
        .hwdata_i    (vif.hwdata_in),
        .d_haddr_o   (vif.d_haddr),
        .d_htrans_o  (vif.d_htrans),
        .d_hsize_o   (vif.d_hsize),
        .d_hwrite_o  (vif.d_hwrite),
        .d_hwdata_o  (vif.d_hwdata),
        .d_hready_i  (vif.d_hready),
        .d_hresp_i   (vif.d_hresp),
        .mem_stall_o (vif.mem_stall),
        .ok_done_o   (vif.ok_done),
        .err_pulse_o (vif.err_pulse)
    );

    garuda_tb_pkg::scoreboard sb;
    int ok_count, err_count;

    always @(posedge clk) if (rst_n) begin
        if (vif.ok_done)   ok_count++;
        if (vif.err_pulse) err_count++;
    end

    covergroup cg_dport @(posedge clk);
        cp_htrans: coverpoint vif.d_htrans {
            bins idle   = {HTRANS_IDLE};
            bins nonseq = {HTRANS_NONSEQ};
            illegal_bins seq_or_busy = {2'b01, 2'b11};   // D-port is SINGLE only
        }
        cp_hwrite: coverpoint vif.d_hwrite;
        cp_hsize:  coverpoint vif.d_hsize {
            bins byte_ = {3'b000}; bins half = {3'b001}; bins word = {3'b010};
            bins other = default;
        }
        cp_hready: coverpoint vif.d_hready;
        cp_hresp:  coverpoint vif.d_hresp;
        // Both directions must see wait states AND an error response.
        cross cp_hwrite, cp_hready;
        cross cp_hwrite, cp_hresp;
        cross cp_hwrite, cp_hsize;
        cp_completion: coverpoint {vif.ok_done, vif.err_pulse} {
            bins none  = {2'b00};
            bins okay  = {2'b10};
            bins error = {2'b01};
            illegal_bins both = {2'b11};
        }
    endgroup
    cg_dport cg;

    task automatic tick(); @(posedge clk); #1; endtask

    initial begin
        sb = new("D_PORT_AHB_MASTER");
        cg = new();
        ok_count = 0; err_count = 0;

        rst_n = 0;
        vif.start = 0; vif.hwrite_in = 0; vif.addr = 0; vif.hwdata_in = 0;
        vif.hsize_in = 3'b010; vif.d_hready = 1; vif.d_hresp = 0;

        // ---- reset / idle (Sec. 16.3) ----------------------------------
        #3;
        sb.chk ("reset", "HTRANS idle", vif.d_htrans, HTRANS_IDLE);
        sb.chk ("reset", "hwdata",      vif.d_hwdata, 32'd0);
        sb.chk1("reset", "no stall",    vif.mem_stall, 1'b0);
        sb.chk1("reset", "no done",     vif.ok_done,   1'b0);
        sb.chk1("reset", "no err",      vif.err_pulse, 1'b0);
        @(negedge clk); rst_n = 1; #1;
        sb.chk ("idle", "HTRANS idle", vif.d_htrans,  HTRANS_IDLE);
        sb.chk1("idle", "no stall",    vif.mem_stall, 1'b0);

        // =============================================================
        // STORE -- the ERRATUM D-1 regression
        // =============================================================
        @(negedge clk);
        vif.start = 1; vif.hwrite_in = 1; vif.addr = 32'h2000_0010;
        vif.hsize_in = 3'b010; vif.hwdata_in = 32'hCAFE_F00D;
        vif.d_hready = 1; vif.d_hresp = 0;
        #1;
        sb.chk ("store", "address phase HTRANS", vif.d_htrans, HTRANS_NONSEQ);
        sb.chk ("store", "address phase HADDR",  vif.d_haddr,  32'h2000_0010);
        sb.chk1("store", "address phase HWRITE", vif.d_hwrite, 1'b1);
        sb.chk1("store", "address phase stalls", vif.mem_stall, 1'b1);
        sb.chk1("store", "ok_done_is_a_data_phase_event", vif.ok_done,   1'b0);
        sb.chk1("store", "no error in address phase",     vif.err_pulse, 1'b0);
        tick();
        // The pipeline hold was released by the accepted address phase, so
        // the MEM operands are already gone. Reproduce exactly that.
        @(negedge clk);
        vif.start = 0; vif.hwdata_in = 32'd0; vif.addr = 32'd0; vif.hwrite_in = 0;
        #1;
        sb.chk ("store", "store_hwdata_held_after_start_falls",
                vif.d_hwdata, 32'hCAFE_F00D);
        sb.chk ("store", "data phase HTRANS idle", vif.d_htrans, HTRANS_IDLE);
        sb.chk1("store", "completes", vif.ok_done, 1'b1);
        sb.chk1("store", "stall_released_only_on_completion", vif.mem_stall, 1'b0);
        tick();
        sb.chk1("store", "completion is one cycle", vif.ok_done, 1'b0);

        // =============================================================
        // LOAD -- completion is a data-phase event
        // =============================================================
        @(negedge clk);
        vif.start = 1; vif.hwrite_in = 0; vif.addr = 32'h2000_0020;
        vif.hsize_in = 3'b010; vif.d_hready = 1; vif.d_hresp = 0;
        #1;
        sb.chk ("load", "address phase HTRANS", vif.d_htrans, HTRANS_NONSEQ);
        sb.chk1("load", "HWRITE low",           vif.d_hwrite, 1'b0);
        sb.chk1("load", "stalls",               vif.mem_stall, 1'b1);
        sb.chk1("load", "no early completion",  vif.ok_done,   1'b0);
        tick(); #1;
        // start_i stays asserted through the data phase (MEM is held) -- this
        // must NOT re-issue a second transfer to the same address.
        sb.chk ("load", "no spurious second transfer", vif.d_htrans, HTRANS_IDLE);
        sb.chk1("load", "completes",                   vif.ok_done,  1'b1);
        sb.chk1("load", "stall released",              vif.mem_stall, 1'b0);
        @(negedge clk); vif.start = 0; #1;

        // =============================================================
        // ADDRESS-PHASE WAIT STATES (Sec. 16.2) -- SVA A5 is the checker
        // =============================================================
        @(negedge clk);
        vif.start = 1; vif.hwrite_in = 1; vif.addr = 32'h2000_0030;
        vif.hsize_in = 3'b001; vif.hwdata_in = 32'h0000_BEEF;
        vif.d_hready = 0; vif.d_hresp = 0;
        #1;
        sb.chk ("addr_wait", "HTRANS presented", vif.d_htrans,  HTRANS_NONSEQ);
        sb.chk1("addr_wait", "stalls",           vif.mem_stall, 1'b1);
        repeat (3) begin
            tick();
            sb.chk ("addr_wait", "HADDR held",  vif.d_haddr,   32'h2000_0030);
            sb.chk ("addr_wait", "HSIZE held",  vif.d_hsize,   3'b001);
            sb.chk1("addr_wait", "still stalls", vif.mem_stall, 1'b1);
            sb.chk1("addr_wait", "no completion", vif.ok_done,  1'b0);
        end
        @(negedge clk); vif.d_hready = 1; #1;
        sb.chk1("addr_wait", "still address phase", vif.mem_stall, 1'b1);
        tick();
        @(negedge clk); vif.start = 0; vif.hwdata_in = 32'd0; #1;
        sb.chk ("addr_wait", "hwdata captured", vif.d_hwdata, 32'h0000_BEEF);
        sb.chk1("addr_wait", "completes",       vif.ok_done,  1'b1);

        // =============================================================
        // DATA-PHASE WAIT STATES (Sec. 10.4)
        // =============================================================
        @(negedge clk);
        vif.start = 1; vif.hwrite_in = 0; vif.addr = 32'h2000_0040;
        vif.hsize_in = 3'b010; vif.d_hready = 1; vif.d_hresp = 0;
        tick();                                    // address phase accepted
        @(negedge clk); vif.d_hready = 0; #1;
        repeat (3) begin
            sb.chk1("data_wait", "stalls",        vif.mem_stall, 1'b1);
            sb.chk1("data_wait", "no completion", vif.ok_done,   1'b0);
            sb.chk ("data_wait", "HTRANS idle",   vif.d_htrans,  HTRANS_IDLE);
            tick();
        end
        @(negedge clk); vif.d_hready = 1; #1;
        sb.chk1("data_wait", "completes",      vif.ok_done,   1'b1);
        sb.chk1("data_wait", "stall released", vif.mem_stall, 1'b0);
        @(negedge clk); vif.start = 0; #1;

        // =============================================================
        // TWO-CYCLE AMBA ERROR RESPONSE (Sec. 16.2)
        // =============================================================
        err_count = 0;
        @(negedge clk);
        vif.start = 1; vif.hwrite_in = 0; vif.addr = 32'h4000_0000;
        vif.hsize_in = 3'b010; vif.d_hready = 1; vif.d_hresp = 0;
        tick();
        @(negedge clk); vif.d_hready = 0; vif.d_hresp = 1; #1;   // ERROR cycle 1
        sb.chk1("load_error", "no pulse in cycle 1", vif.err_pulse, 1'b0);
        sb.chk1("load_error", "still stalled",       vif.mem_stall, 1'b1);
        @(negedge clk); vif.d_hready = 1; vif.d_hresp = 1; #1;   // ERROR cycle 2
        sb.chk1("load_error", "pulse in cycle 2",    vif.err_pulse, 1'b1);
        sb.chk1("load_error", "not OKAY",            vif.ok_done,   1'b0);
        sb.chk1("load_error", "stall released",      vif.mem_stall, 1'b0);
        @(negedge clk); vif.start = 0; vif.d_hresp = 0; #1;
        sb.chk1("load_error", "pulse is one cycle",  vif.err_pulse, 1'b0);
        tick();
        if (err_count != 1)
            sb.fail("load_error", "err_pulse count",
                    $sformatf("got %0d, expected 1", err_count));
        else
            sb.pass("load_error", "exactly one err_pulse for one error response");

        // ERROR on a STORE takes the same path (cause 7 upstream)
        err_count = 0;
        @(negedge clk);
        vif.start = 1; vif.hwrite_in = 1; vif.addr = 32'h4000_0004;
        vif.hwdata_in = 32'h1234_5678; vif.d_hready = 1; vif.d_hresp = 0;
        tick();
        @(negedge clk); vif.d_hready = 0; vif.d_hresp = 1; #1;
        sb.chk1("store_error", "no pulse in cycle 1", vif.err_pulse, 1'b0);
        @(negedge clk); vif.d_hready = 1; vif.d_hresp = 1; #1;
        sb.chk1("store_error", "pulse in cycle 2", vif.err_pulse, 1'b1);
        sb.chk ("store_error", "hwdata still driven", vif.d_hwdata, 32'h1234_5678);
        @(negedge clk); vif.start = 0; vif.d_hresp = 0; vif.hwdata_in = 0;
        tick();
        if (err_count != 1)
            sb.fail("store_error", "err_pulse count",
                    $sformatf("got %0d, expected 1", err_count));
        else
            sb.pass("store_error", "exactly one err_pulse for one error response");

        // ---- the FSM recovers: a normal access straight after an error --
        @(negedge clk);
        vif.start = 1; vif.hwrite_in = 0; vif.addr = 32'h2000_0050;
        vif.d_hready = 1; vif.d_hresp = 0;
        #1;
        sb.chk ("post_error", "address phase", vif.d_htrans, HTRANS_NONSEQ);
        tick(); #1;
        sb.chk1("post_error", "completes", vif.ok_done, 1'b1);
        @(negedge clk); vif.start = 0;

        // =============================================================
        // RANDOMISED SOAK -- random wait states, sizes, directions and
        // error injection. The SVA set above is the checker; the counter
        // below confirms transfers actually completed rather than the FSM
        // sitting idle and vacuously satisfying every property.
        // =============================================================
        // The request is only re-rolled when the master is NOT stalled --
        // that mirrors the pipeline, which HOLDS ex_mem stable for the whole
        // access (Sec. 11.4). Re-rolling the address mid-access would violate
        // the upstream contract and trip SVA A5 for a testbench reason.
        ok_count = 0; err_count = 0;
        repeat (600) begin
            @(negedge clk);
            if (!vif.mem_stall) begin
                vif.start     = $urandom_range(0, 99) < 70;
                vif.hwrite_in = $urandom_range(0, 1);
                vif.addr      = $urandom() & 32'hFFFF_FFFC;
                vif.hsize_in  = $urandom_range(0, 2);
                vif.hwdata_in = $urandom();
            end
            vif.d_hready = $urandom_range(0, 99) < 70;
            vif.d_hresp  = $urandom_range(0, 99) < 10;
            tick();
        end
        @(negedge clk); vif.start = 0; vif.d_hready = 1; vif.d_hresp = 0;
        repeat (4) tick();
        if (ok_count == 0)
            sb.fail("soak", "no OKAY completions observed", "");
        else
            sb.pass("soak", $sformatf("%0d OKAY and %0d ERROR completions",
                                      ok_count, err_count));

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
