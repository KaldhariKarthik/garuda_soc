`timescale 1ns / 1ps
// =============================================================================
// apb_checker.v -- passive AMBA 3 APB protocol monitor.
//
// WHY THIS FILE EXISTS
// --------------------
// Docs/HANDOFF.md section 11, step 3, written before any of this hardware
// existed:
//
//     "Write the APB protocol checker BEFORE the bridge ... A bridge built
//      before its oracle is a bridge nobody is looking at."
//
// The bridge was built. So were the APB shim and all seven peripherals. The
// checker was not. Eight APB blocks have been taped out of this repository's
// test suite with no independent observer on the protocol at all.
//
// The nearest thing that existed was one rule inside
// tb/ahb2apb/apb_slave_model.v -- "PENABLE must not rise with PSEL" -- and it
// lives in a RESPONDER, so it is only present in tb_ahb2apb and it is checking
// the bus it is also driving. The AHB checker states the general lesson at the
// top of its own file and it applies here unchanged: a functional model is not
// a protocol checker, and it cannot be turned into one by adding ports. A model
// answers "what data comes back?". Legality is a different question, it needs a
// different observer, and that observer must be passive and separate so it
// cannot be quietly satisfied by the thing it is checking.
//
// USAGE
// -----
// Bind one instance per APB slave port, tapping the wires between bridge and
// slave. It drives nothing. Call report_result() at end of simulation.
//
//     apb_checker u_chk (
//         .clk_i(pclk), .rst_n_i(preset_n),
//         .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
//         .paddr_i(paddr), .pwdata_i(pwdata), .pstrb_i(pstrb),
//         .pready_i(pready), .pslverr_i(pslverr), .viol_count_o(viol));
//
// PADDR is 32 bits wide here and narrower buses zero-extend into it, which is
// what plain Verilog does to an under-wide actual. PSTRB can be tied to 4'hF on
// a bus that does not implement it.
//
// Written in Verilog-2001, not SystemVerilog, and with no SVA -- deliberately,
// for the same reason ahb_lite_checker.v is: it has to compile under BOTH
// xrun 22.09 (regression) and irun 15.20 (coverage), with no assertion licence,
// and drop into the plain filelists the existing tests already use. A checker
// that only runs in a special mode is a checker that will be off when it
// matters.
//
// SAMPLING MODEL
// --------------
// One `always @(posedge clk_i)`, comparing this cycle against the previous one.
// Every rule below is phrased as a statement about a cycle that has ENDED, so
// one posedge is one fully observed bus cycle and nothing is half-sampled.
//
// WHAT IS CHECKED  (each has its own counter, so a hit is diagnosable)
//   v_setup_skipped    PENABLE high in the same cycle PSEL rose. SETUP is a
//                      cycle of its own and it is not optional.
//   v_setup_stretched  SETUP lasted more than one cycle. AMBA 3 APB: the bus
//                      remains in SETUP for exactly one clock and always moves
//                      to ACCESS on the next rising edge.
//   v_psel_dropped     PSEL withdrawn mid-ACCESS, before PREADY. An APB access,
//                      once started, has to be allowed to finish.
//   v_penable_dropped  PENABLE withdrawn mid-ACCESS, before PREADY.
//   v_addr_change      PADDR moved during ACCESS while PREADY was low.
//   v_ctrl_change      PWRITE or PSTRB moved during ACCESS while PREADY low.
//   v_wdata_change     PWDATA moved during a WRITE access while PREADY low.
//   v_penable_held     PENABLE still high the cycle after PREADY completed the
//                      access. PENABLE deasserts at the end of an access; a
//                      back-to-back access returns through SETUP.
//   v_slverr_no_access PSLVERR asserted outside an ACCESS phase, where it has
//                      no transfer to describe.
//   v_wait_timeout     PREADY held low for more than MAX_WAIT cycles in one
//                      access. Not a protocol rule -- a hang detector, so a
//                      stalled bus is reported here rather than as a testbench
//                      timeout with no attribution.
//
// WHAT IS DELIBERATELY *NOT* CHECKED
// ----------------------------------
// "PENABLE high while PSEL is low" is NOT a violation and must never be added.
//
// APB fans a SHARED PENABLE out to every peripheral and selects between them
// with a per-slave PSEL, so during an access to one window every other slave
// legitimately sees PENABLE high with its own PSEL low. That rule was tried in
// this project, in apb_slave_model.v, and it fired 25 times in a clean run
// (TB-19). It is recorded here as well as there because the failure looked like
// a bridge defect and was a defect in the checker, and because a monitor that
// cries wolf on legal traffic is worse than no monitor: the next real violation
// arrives into a log everyone has learned to ignore.
//
// PROVING IT CAN FAIL
// -------------------
// Docs/ORACLES.md: "A clean report from a checker that has not been shown to
// fail is worth nothing." tb/common/tb_apb_checker_selftest.v drives these taps
// directly and fires every rule above one at a time, then runs legal traffic
// and requires a zero count. Run it before trusting any clean report from here.
// =============================================================================

module apb_checker #(
    parameter integer MAX_REPORT = 20,     // per-instance printed-violation cap
    parameter integer MAX_WAIT   = 1024,   // PREADY-low cycles before complaint

    // Extra cycles the master may legitimately hold PENABLE after the FIRST
    // PREADY-high cycle of an access. Zero is strict APB and is the default.
    //
    // It exists because GARUDA's bridge has a per-window APB divider
    // (GARUDA-AHB2APB-SPEC-001 section 6.2): on a divided window
    // ahb2apb_apb_fsm stays in P_ACCESS for div_cnt further pclk cycles with
    // PENABLE high, even once the slave has raised PREADY. That is deliberate
    // and tb_ahb2apb measures it, so the integrator declares it here per port
    // rather than the checker either guessing or crying wolf. Window 11 in
    // tb_ahb2apb runs /2 and so binds with EXTEND_MAX=1.
    //
    // The stretch is reported either way, as "longest PENABLE extension", so
    // raising this parameter hides nothing.
    parameter integer EXTEND_MAX = 0
)(
    input  wire        clk_i,              // pclk
    input  wire        rst_n_i,            // preset_n

    // Passive taps -- this module drives none of these
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [31:0] paddr_i,
    input  wire [31:0] pwdata_i,
    input  wire [ 3:0] pstrb_i,
    input  wire        pready_i,
    input  wire        pslverr_i,

    output wire [31:0] viol_count_o
);

    // ---- previous-cycle snapshot --------------------------------------------
    reg        p_psel, p_penable, p_pwrite, p_pready, p_pslverr;
    reg [31:0] p_paddr, p_pwdata;
    reg [ 3:0] p_pstrb;
    reg        seen_first;

    // ---- counters -----------------------------------------------------------
    integer v_setup_skipped, v_setup_stretched;
    integer v_psel_dropped, v_penable_dropped;
    integer v_addr_change, v_ctrl_change, v_wdata_change;
    integer v_penable_held, v_slverr_no_access, v_wait_timeout;
    integer v_total, n_reported;
    integer n_access, n_write, n_read, n_slverr, n_wait_max;
    integer n_abandoned, n_ext_max;
    integer wcnt, ext_cnt;
    reg     timed_out;      // one complaint per stalled access, not per cycle
    reg     ext_flagged;    // likewise, one complaint per over-long extension

    assign viol_count_o = v_total[31:0];

    // ---- phase helpers ------------------------------------------------------
    // Named for the cycle they describe so the rules below read as statements
    // about a bus cycle rather than about a pile of flops.
    wire in_access      = psel_i  && penable_i;
    wire p_in_access    = p_psel  && p_penable;
    wire p_access_stall = p_in_access && !p_pready;   // ACCESS continuing
    wire p_access_done  = p_in_access &&  p_pready;   // ACCESS completed
    wire p_setup        = p_psel  && !p_penable;

    task viol;
        // 96 characters. A Verilog string argument narrower than the literal
        // passed to it drops the LEADING characters silently, which cost this
        // project a log that named no rule at all (TB-23). Keep messages under
        // 96 or widen this.
        input [8*96-1:0] msg;
        begin
            v_total = v_total + 1;
            if (n_reported < MAX_REPORT) begin
                n_reported = n_reported + 1;
                $display("APB-VIOLATION %0t %m: %0s", $time, msg);
                $display("               psel=%b penable=%b pwrite=%b paddr=%08h pstrb=%b pready=%b pslverr=%b",
                         psel_i, penable_i, pwrite_i, paddr_i, pstrb_i,
                         pready_i, pslverr_i);
            end
        end
    endtask

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            p_psel <= 1'b0; p_penable <= 1'b0; p_pwrite <= 1'b0;
            p_pready <= 1'b0; p_pslverr <= 1'b0;
            p_paddr <= 32'h0; p_pwdata <= 32'h0; p_pstrb <= 4'h0;
            seen_first <= 1'b0;

            v_setup_skipped = 0; v_setup_stretched = 0;
            v_psel_dropped  = 0; v_penable_dropped = 0;
            v_addr_change   = 0; v_ctrl_change = 0; v_wdata_change = 0;
            v_penable_held  = 0; v_slverr_no_access = 0; v_wait_timeout = 0;
            v_total = 0; n_reported = 0;
            n_access = 0; n_write = 0; n_read = 0; n_slverr = 0; n_wait_max = 0;
            n_abandoned = 0; n_ext_max = 0;
            wcnt = 0; ext_cnt = 0;
            timed_out <= 1'b0; ext_flagged <= 1'b0;
        end else begin

            // -----------------------------------------------------------------
            // 1. Entering an access: SETUP is a cycle of its own
            // -----------------------------------------------------------------
            if (psel_i && penable_i && !p_psel) begin
                v_setup_skipped = v_setup_skipped + 1;
                viol("PENABLE high in the same cycle PSEL rose - SETUP phase skipped");
            end

            if (seen_first && p_setup && psel_i && !penable_i) begin
                v_setup_stretched = v_setup_stretched + 1;
                viol("SETUP held for more than one cycle - APB must enter ACCESS next edge");
            end

            // -----------------------------------------------------------------
            // 2. An access, once started, must be allowed to finish
            // -----------------------------------------------------------------
            if (seen_first && p_access_stall) begin
                if (!psel_i) begin
                    v_psel_dropped = v_psel_dropped + 1;
                    viol("PSEL withdrawn during ACCESS before PREADY - access cannot be abandoned");
                end else if (!penable_i) begin
                    v_penable_dropped = v_penable_dropped + 1;
                    viol("PENABLE withdrawn during ACCESS before PREADY");
                end else begin
                    // Still in the same access: address and control are frozen.
                    if (paddr_i !== p_paddr) begin
                        v_addr_change = v_addr_change + 1;
                        viol("PADDR changed during ACCESS while PREADY was low");
                    end
                    if ((pwrite_i !== p_pwrite) || (pstrb_i !== p_pstrb)) begin
                        v_ctrl_change = v_ctrl_change + 1;
                        viol("PWRITE/PSTRB changed during ACCESS while PREADY was low");
                    end
                    // PWDATA is don't-care on a read, so only a write is checked.
                    if (p_pwrite && (pwdata_i !== p_pwdata)) begin
                        v_wdata_change = v_wdata_change + 1;
                        viol("PWDATA changed during a write ACCESS while PREADY was low");
                    end
                end
            end

            // -----------------------------------------------------------------
            // 3. Leaving an access
            // -----------------------------------------------------------------
            // An "extension cycle" is one where PENABLE is still high after a
            // cycle that already had PREADY high. Strictly that access was
            // over; EXTEND_MAX says how many such cycles this port is allowed.
            if (seen_first && p_access_done && psel_i && penable_i) begin
                ext_cnt = ext_cnt + 1;
                if (ext_cnt > n_ext_max) n_ext_max = ext_cnt;
                if ((ext_cnt > EXTEND_MAX) && !ext_flagged) begin
                    ext_flagged <= 1'b1;
                    v_penable_held = v_penable_held + 1;
                    viol("PENABLE still high after PREADY completed the access");
                end
            end
            if (!penable_i) begin
                ext_cnt = 0;
                ext_flagged <= 1'b0;
            end

            // -----------------------------------------------------------------
            // 4. PSLVERR has to be describing something
            //
            // Checked against ACCESS rather than against a completed access:
            // a slave may drive it combinationally from PSEL and PENABLE, which
            // is legal and is what apb_slave_model.v does. Outside ACCESS there
            // is no transfer for it to refer to.
            // -----------------------------------------------------------------
            if (pslverr_i && !in_access) begin
                v_slverr_no_access = v_slverr_no_access + 1;
                viol("PSLVERR asserted outside an ACCESS phase");
            end

            // -----------------------------------------------------------------
            // 5. Hang detector, and the statistics
            // -----------------------------------------------------------------
            if (in_access && !pready_i) begin
                wcnt = wcnt + 1;
                if (wcnt > n_wait_max) n_wait_max = wcnt;
                if ((wcnt > MAX_WAIT) && !timed_out) begin
                    timed_out <= 1'b1;
                    v_wait_timeout = v_wait_timeout + 1;
                    viol("PREADY low beyond MAX_WAIT cycles - the bus looks stalled");
                end
            end else begin
                wcnt = 0;
                timed_out <= 1'b0;
            end

            // Accesses are counted on PENABLE's falling edge, which happens
            // exactly once per access however long the access ran -- counting
            // every PREADY-high cycle instead would count a divided window's
            // extension cycles as extra accesses.
            //
            // PREADY high on that last cycle means the access completed.
            // PREADY low means the master walked away from it, which is what
            // the bridge's 16-pclk timeout does to a non-responding window; the
            // rules above have already recorded that as a violation, and this
            // counts it so the report says how often it happened.
            //
            // p_psel is part of the condition and must stay there: PENABLE is
            // SHARED across every window, so without it each per-slave checker
            // counts the whole bus instead of its own port. That is exactly
            // what happened on the first bind into tb_ahb2apb -- windows 1 and
            // 11 reported identical access counts, which is the tell.
            if (seen_first && p_psel && p_penable && !penable_i) begin
                if (p_pready) begin
                    n_access = n_access + 1;
                    if (p_pwrite) n_write = n_write + 1;
                    else          n_read  = n_read  + 1;
                    if (p_pslverr) n_slverr = n_slverr + 1;
                end else begin
                    n_abandoned = n_abandoned + 1;
                end
            end

            // -----------------------------------------------------------------
            // 6. Snapshot for the next cycle
            // -----------------------------------------------------------------
            p_psel    <= psel_i;    p_penable <= penable_i;
            p_pwrite  <= pwrite_i;  p_paddr   <= paddr_i;
            p_pwdata  <= pwdata_i;  p_pstrb   <= pstrb_i;
            p_pready  <= pready_i;  p_pslverr <= pslverr_i;
            seen_first <= 1'b1;
        end
    end

    // =========================================================================
    // End-of-simulation report.  Call hierarchically from the testbench.
    // =========================================================================
    task report_result;
        begin
            $display("--------------------------------------------------------------");
            $display("APB CHECKER %m");
            $display("  accesses observed       : %0d  (%0d write, %0d read)",
                     n_access, n_write, n_read);
            $display("  PSLVERR responses       : %0d", n_slverr);
            $display("  longest PREADY stall    : %0d cycle(s)", n_wait_max);
            if (n_ext_max != 0)
                $display("  longest PENABLE extension: %0d cycle(s) past PREADY (EXTEND_MAX=%0d)",
                         n_ext_max, EXTEND_MAX);
            if (n_abandoned != 0)
                $display("  ACCESSES ABANDONED      : %0d  <-- PENABLE dropped with PREADY low",
                         n_abandoned);
            if ((n_access == 0) && (n_abandoned == 0))
                $display("  NOTHING WAS OBSERVED    <-- this checker saw no traffic at all");
            if (v_total == 0) begin
                $display("  VIOLATIONS              : 0   (clean)");
            end else begin
                $display("  VIOLATIONS              : %0d", v_total);
                if (v_setup_skipped != 0)    $display("     PENABLE with rising PSEL        : %0d", v_setup_skipped);
                if (v_setup_stretched != 0)  $display("     SETUP longer than one cycle     : %0d", v_setup_stretched);
                if (v_psel_dropped != 0)     $display("     PSEL dropped mid-ACCESS         : %0d", v_psel_dropped);
                if (v_penable_dropped != 0)  $display("     PENABLE dropped mid-ACCESS      : %0d", v_penable_dropped);
                if (v_addr_change != 0)      $display("     PADDR moved in ACCESS           : %0d", v_addr_change);
                if (v_ctrl_change != 0)      $display("     PWRITE/PSTRB moved in ACCESS    : %0d", v_ctrl_change);
                if (v_wdata_change != 0)     $display("     PWDATA moved in write ACCESS    : %0d", v_wdata_change);
                if (v_penable_held != 0)     $display("     PENABLE held past PREADY        : %0d", v_penable_held);
                if (v_slverr_no_access != 0) $display("     PSLVERR outside ACCESS          : %0d", v_slverr_no_access);
                if (v_wait_timeout != 0)     $display("     PREADY stalled beyond MAX_WAIT  : %0d", v_wait_timeout);
            end
            $display("--------------------------------------------------------------");
        end
    endtask

endmodule
