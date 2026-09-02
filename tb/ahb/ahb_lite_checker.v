`timescale 1ns / 1ps
// =============================================================================
// ahb_lite_checker.v -- passive AMBA 3 AHB-Lite protocol monitor.
//
// WHY THIS FILE EXISTS
// --------------------
// Until it was written, nothing anywhere in the GARUDA testbench had ever
// looked at HBURST:
//
//     $ grep -c -i hburst rtl/ahb/ahb_mem_slave.v
//     0
//
// The verification memory model services every transfer as an independent
// SINGLE regardless of what the master asks for.  That is a perfectly
// reasonable thing for a memory model to do -- and it means a master can
// violate the burst rules on every single fetch, forever, while all 63 ISA
// tests, all 9 directed tests and every coverage run continue to pass.
// Three real defects lived in exactly that blind spot.
//
// The lesson generalises, so it is worth stating plainly at the top of the
// file that fixes it: a FUNCTIONAL MODEL IS NOT A PROTOCOL CHECKER, and it
// cannot be turned into one by adding ports to it.  A functional model answers
// "what data comes back?".  Protocol legality is a different question, it needs
// a different observer, and that observer has to be passive and separate so it
// cannot be quietly satisfied by the thing it is checking.
//
// USAGE
// -----
// Bind one instance per AHB-Lite master port, tapping the wires between master
// and slave.  It drives nothing.  Call report_result() at end of simulation.
//
//     ahb_lite_checker u_ichk (
//         .clk_i(clk), .rst_n_i(rst_n),
//         .haddr_i(i_haddr), .htrans_i(i_htrans), .hsize_i(i_hsize),
//         .hburst_i(i_hburst), .hwrite_i(i_hwrite), .hwdata_i(i_hwdata),
//         .hready_i(i_hready), .hresp_i(i_hresp), .viol_count_o(i_viol));
//
// Written in Verilog-2001 (not SystemVerilog, no SVA) on purpose: it has to
// compile under BOTH xrun 22.09 (regression) and irun 15.20 (coverage), with
// no assertion licence, and drop into the plain filelist that every existing
// test already uses.  A checker that only runs in a special mode is a checker
// that will be off when it matters.
//
// SAMPLING MODEL
// --------------
// Everything is sampled in a single `always @(posedge clk_i)`.  Because the
// master's address-phase outputs are registered, reading them at a posedge
// yields their pre-update values -- i.e. a complete and consistent picture of
// the bus cycle that just ENDED.  Combinational slave outputs (HREADY/HRESP)
// have settled by the same edge.  So one posedge == one fully observed bus
// cycle, which is the standard passive-monitor arrangement.
//
// WHAT IS CHECKED  (each has its own counter, so a hit is diagnosable)
// -------------------------------------------------------------------
//   Address-phase stability
//     v_retract        NONSEQ/SEQ withdrawn to IDLE while HREADY was low.
//                      AHB-Lite has no cancel: once presented, a transfer must
//                      be completed and its data discarded by the master.
//     v_trans_change   HTRANS changed to a different active type during a wait
//     v_addr_change    HADDR changed during a wait state
//     v_ctrl_change    HSIZE / HBURST / HWRITE changed during a wait state
//   Burst legality
//     v_seq_after_idle SEQ presented when the previous bus cycle was IDLE.
//                      The first transfer of any burst must be NONSEQ.
//     v_seq_after_sgl  SEQ beat following a SINGLE burst.  A SINGLE burst has
//                      exactly one transfer by definition.
//     v_seq_no_burst   SEQ with no open burst, other causes
//     v_burst_change   HBURST not constant across the beats of one burst
//     v_size_change    HSIZE not constant across the beats of one burst
//     v_addr_seq       SEQ address != previous address + (1 << HSIZE)
//     v_1k_cross       burst crossed a 1 KB address boundary. 1 KB is the
//                      minimum AHB slave window, so a burst that runs past
//                      the boundary can pass from one slave into another
//                      while the decoder still believes it is mid-burst on
//                      the first. Invisible against a single flat memory
//                      model; a decode bug the moment a fabric exists.
//     v_burst_short    fixed-length burst abandoned before its last beat
//     v_busy_no_burst  BUSY outside a burst
//   Transfer legality
//     v_unaligned      HADDR not aligned to HSIZE
//     v_wdata_change   HWDATA changed during a wait state of its own data phase
//   Response legality
//     v_err_single     ERROR completed in one cycle (it must be two)
//     v_resp_no_dp     HRESP asserted with no data phase in progress
//
// NOT CHECKED -- stated explicitly rather than left to be assumed
// --------------------------------------------------------------
//   * WRAP4/8/16 address wrapping.  GARUDA never emits a WRAP burst; rather
//     than write an untested wrap-boundary calculation and imply it is
//     verified, WRAP bursts are COUNTED (n_wrap_unchecked) and their addresses
//     are not checked.  If that counter is ever non-zero, this checker needs
//     extending before its silence means anything.
//   * HPROT, HMASTLOCK, and the early-burst-termination-after-ERROR
//     recommendation (which is a "should", not a "must").
//   * Anything about arbitration, decode or multi-master behaviour: AHB-Lite
//     has a single master per port and GARUDA has no interconnect yet.
// =============================================================================

module ahb_lite_checker #(
    parameter integer MAX_REPORT = 20      // per-instance printed-violation cap
)(
    input  wire        clk_i,
    input  wire        rst_n_i,

    // Passive taps -- this module drives none of these
    input  wire [31:0] haddr_i,
    input  wire [ 1:0] htrans_i,
    input  wire [ 2:0] hsize_i,
    input  wire [ 2:0] hburst_i,
    input  wire        hwrite_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,
    input  wire        hresp_i,

    output wire [31:0] viol_count_o
);

    localparam [1:0] T_IDLE   = 2'b00, T_BUSY  = 2'b01,
                     T_NONSEQ = 2'b10, T_SEQ   = 2'b11;

    localparam [2:0] B_SINGLE = 3'b000, B_INCR   = 3'b001,
                     B_WRAP4  = 3'b010, B_INCR4  = 3'b011,
                     B_WRAP8  = 3'b100, B_INCR8  = 3'b101,
                     B_WRAP16 = 3'b110, B_INCR16 = 3'b111;

    // ---- previous-cycle snapshot -------------------------------------------
    reg [31:0] p_haddr, p_hwdata;
    reg [ 1:0] p_htrans;
    reg [ 2:0] p_hsize, p_hburst;
    reg        p_hwrite, p_hready, p_hresp;
    reg        seen_first;

    // ---- burst tracking ----------------------------------------------------
    reg        burst_open;        // a multi-beat burst is in progress
    reg        burst_fixed;       // ... and it has a defined length
    reg [ 2:0] burst_type;        // HBURST of the opening NONSEQ
    reg [ 2:0] burst_size;        // HSIZE  of the opening NONSEQ
    reg [31:0] burst_next_addr;   // address the next SEQ beat must carry
    reg [21:0] burst_region;      // haddr[31:10] of the burst's opening beat
    reg [ 4:0] burst_beats_left;
    reg [ 1:0] last_acc_trans;    // HTRANS of the last COMPLETED bus cycle

    // ---- data-phase tracking -----------------------------------------------
    reg        dp_pend;           // a data phase occupies the current cycle
    reg        dp_write;

    // ---- counters ----------------------------------------------------------
    integer v_retract, v_trans_change, v_addr_change, v_ctrl_change;
    integer v_seq_after_idle, v_seq_after_sgl, v_seq_no_burst;
    integer v_burst_change, v_size_change, v_addr_seq, v_burst_short;
    integer v_1k_cross;
    integer v_busy_no_burst, v_unaligned, v_wdata_change;
    integer v_err_single, v_resp_no_dp;
    integer v_total, n_reported;
    integer n_addr_phases, n_bursts, n_wrap_unchecked, n_error_resp;

    assign viol_count_o = v_total[31:0];

    // ---- helpers -----------------------------------------------------------
    wire cur_active = (htrans_i == T_NONSEQ) || (htrans_i == T_SEQ) ||
                      (htrans_i == T_BUSY);
    wire p_active   = (p_htrans == T_NONSEQ) || (p_htrans == T_SEQ) ||
                      (p_htrans == T_BUSY);
    // A transfer is being presented for the FIRST time when the previous cycle
    // either had nothing pending or completed what it had.  Checks that belong
    // to "the master presented X" hang off this so a transfer stretched across
    // eight wait states does not count its violation eight times.
    wire new_present = cur_active && (!p_active || p_hready);

    function is_incr_family;
        input [2:0] b;
        is_incr_family = (b == B_INCR) || (b == B_INCR4) ||
                         (b == B_INCR8) || (b == B_INCR16);
    endfunction

    function [4:0] beats_of;
        input [2:0] b;
        case (b)
            B_WRAP4,  B_INCR4 : beats_of = 5'd4;
            B_WRAP8,  B_INCR8 : beats_of = 5'd8;
            B_WRAP16, B_INCR16: beats_of = 5'd16;
            default           : beats_of = 5'd1;   // SINGLE and undefined INCR
        endcase
    endfunction

    task viol;
        input [8*72-1:0] msg;
        begin
            v_total = v_total + 1;
            if (n_reported < MAX_REPORT) begin
                n_reported = n_reported + 1;
                $display("AHB-VIOLATION %0t %m: %0s", $time, msg);
                $display("               htrans=%b hburst=%b hsize=%b hwrite=%b haddr=%08x hready=%b hresp=%b",
                         htrans_i, hburst_i, hsize_i, hwrite_i, haddr_i,
                         hready_i, hresp_i);
                if (n_reported == MAX_REPORT)
                    $display("AHB-VIOLATION %0t %m: further reports suppressed (MAX_REPORT=%0d); counting continues",
                             $time, MAX_REPORT);
            end
        end
    endtask

    // =========================================================================
    // The monitor
    // =========================================================================
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            p_haddr <= 32'b0; p_hwdata <= 32'b0; p_htrans <= T_IDLE;
            p_hsize <= 3'b0;  p_hburst <= 3'b0;  p_hwrite <= 1'b0;
            p_hready <= 1'b1; p_hresp  <= 1'b0;  seen_first <= 1'b0;

            burst_open <= 1'b0; burst_fixed <= 1'b0;
            burst_type <= B_SINGLE; burst_size <= 3'b010;
            burst_next_addr <= 32'b0; burst_beats_left <= 5'd0;
            burst_region <= 22'b0;
            last_acc_trans <= T_IDLE;
            dp_pend <= 1'b0; dp_write <= 1'b0;

            v_retract = 0; v_trans_change = 0; v_addr_change = 0;
            v_ctrl_change = 0; v_seq_after_idle = 0; v_seq_after_sgl = 0;
            v_seq_no_burst = 0; v_burst_change = 0; v_size_change = 0;
            v_addr_seq = 0; v_burst_short = 0; v_busy_no_burst = 0;
            v_1k_cross = 0;
            v_unaligned = 0; v_wdata_change = 0; v_err_single = 0;
            v_resp_no_dp = 0; v_total = 0; n_reported = 0;
            n_addr_phases = 0; n_bursts = 0; n_wrap_unchecked = 0;
            n_error_resp = 0;
        end else begin

            // -----------------------------------------------------------------
            // 1. Address-phase stability across wait states
            //
            // "The master must not change the address or control signals while
            //  HREADY is LOW."  The retract case is called out separately
            //  because it is the one that reads as reasonable when you write it
            //  -- the fetch was redirected, so the master 'cancels' it by going
            //  IDLE.  There is no cancel.  The transfer must complete and the
            //  master must discard the returned data.
            // -----------------------------------------------------------------
            if (seen_first && p_active && !p_hready) begin
                if (htrans_i != p_htrans) begin
                    if (htrans_i == T_IDLE) begin
                        v_retract = v_retract + 1;
                        viol("address phase RETRACTED to IDLE while HREADY low - AHB-Lite has no cancel");
                    end else begin
                        v_trans_change = v_trans_change + 1;
                        viol("HTRANS changed while HREADY low");
                    end
                end else begin
                    if (haddr_i != p_haddr) begin
                        v_addr_change = v_addr_change + 1;
                        viol("HADDR changed while HREADY low");
                    end
                    if ((hsize_i != p_hsize) || (hburst_i != p_hburst) ||
                        (hwrite_i != p_hwrite)) begin
                        v_ctrl_change = v_ctrl_change + 1;
                        viol("HSIZE/HBURST/HWRITE changed while HREADY low");
                    end
                end
            end

            // -----------------------------------------------------------------
            // 2. Legality of a newly presented transfer
            // -----------------------------------------------------------------
            if (new_present) begin
                n_addr_phases = n_addr_phases + 1;

                if ((haddr_i & ((32'd1 << hsize_i) - 32'd1)) != 32'd0) begin
                    v_unaligned = v_unaligned + 1;
                    viol("HADDR is not aligned to HSIZE");
                end

                case (htrans_i)
                T_SEQ: begin
                    if (!burst_open) begin
                        // Every beat after the first must belong to a burst
                        // that was opened by a NONSEQ carrying a burst type.
                        if (last_acc_trans == T_IDLE) begin
                            v_seq_after_idle = v_seq_after_idle + 1;
                            viol("SEQ after an IDLE bus cycle - a burst must restart with NONSEQ");
                        end else if (burst_type == B_SINGLE) begin
                            v_seq_after_sgl = v_seq_after_sgl + 1;
                            viol("SEQ beat following a SINGLE burst - SINGLE has exactly one transfer");
                        end else begin
                            v_seq_no_burst = v_seq_no_burst + 1;
                            viol("SEQ with no burst open");
                        end
                    end else begin
                        if (hburst_i != burst_type) begin
                            v_burst_change = v_burst_change + 1;
                            viol("HBURST changed mid-burst - it must be constant for the whole burst");
                        end
                        if (hsize_i != burst_size) begin
                            v_size_change = v_size_change + 1;
                            viol("HSIZE changed mid-burst");
                        end
                        if (haddr_i[31:10] != burst_region) begin
                            v_1k_cross = v_1k_cross + 1;
                            viol("burst crossed a 1 KB boundary - it must be broken and reopened with NONSEQ");
                        end
                    end
                end

                T_BUSY: begin
                    if (!burst_open) begin
                        v_busy_no_burst = v_busy_no_burst + 1;
                        viol("BUSY presented outside a burst");
                    end
                end

                T_NONSEQ: begin
                    if (burst_open && burst_fixed && (burst_beats_left != 5'd0)) begin
                        v_burst_short = v_burst_short + 1;
                        viol("new burst started before the previous fixed-length burst finished");
                    end
                    if ((hburst_i == B_WRAP4) || (hburst_i == B_WRAP8) ||
                        (hburst_i == B_WRAP16))
                        n_wrap_unchecked = n_wrap_unchecked + 1;
                end
                default: ;    // T_IDLE is not an active transfer
                endcase
            end

            // -----------------------------------------------------------------
            // 3. Write data must hold through its own wait states
            //
            // dp_pend can only be SET on a cycle where HREADY was high, so
            // (dp_pend && !p_hready) means "this data phase was already running
            // last cycle and is being stretched" -- exactly the hold window.
            // -----------------------------------------------------------------
            if (seen_first && dp_pend && dp_write && !p_hready) begin
                if (hwdata_i != p_hwdata) begin
                    v_wdata_change = v_wdata_change + 1;
                    viol("HWDATA changed during a wait state of its own write data phase");
                end
            end

            // -----------------------------------------------------------------
            // 4. Responses
            // -----------------------------------------------------------------
            if (hresp_i) begin
                if (!dp_pend) begin
                    v_resp_no_dp = v_resp_no_dp + 1;
                    viol("HRESP asserted with no data phase in progress");
                end
                if (hready_i) begin
                    n_error_resp = n_error_resp + 1;
                    if (!(p_hresp && !p_hready)) begin
                        v_err_single = v_err_single + 1;
                        viol("ERROR completed in one cycle - AHB-Lite requires HRESP high for two, HREADY low then high");
                    end
                end
            end

            // -----------------------------------------------------------------
            // 5. State update, on completed bus cycles only
            // -----------------------------------------------------------------
            if (hready_i) begin
                case (htrans_i)
                T_NONSEQ: begin
                    burst_type       <= hburst_i;
                    burst_size       <= hsize_i;
                    burst_next_addr  <= haddr_i + (32'd1 << hsize_i);
                    burst_region     <= haddr_i[31:10];
                    burst_open       <= (hburst_i != B_SINGLE);
                    burst_fixed      <= (hburst_i != B_SINGLE) &&
                                        (hburst_i != B_INCR);
                    burst_beats_left <= beats_of(hburst_i) - 5'd1;
                    n_bursts          = n_bursts + 1;
                end

                T_SEQ: begin
                    if (burst_open) begin
                        if (is_incr_family(burst_type) &&
                            (haddr_i != burst_next_addr)) begin
                            v_addr_seq = v_addr_seq + 1;
                            viol("SEQ address is not previous address + (1 << HSIZE)");
                        end
                        burst_next_addr <= haddr_i + (32'd1 << hsize_i);
                        if (burst_fixed) begin
                            burst_beats_left <= burst_beats_left - 5'd1;
                            if (burst_beats_left <= 5'd1) burst_open <= 1'b0;
                        end
                    end
                end

                T_BUSY: ;   // burst stays open; address does not advance

                default: begin      // T_IDLE completes -- any open burst ends
                    if (burst_open && burst_fixed &&
                        (burst_beats_left != 5'd0)) begin
                        v_burst_short = v_burst_short + 1;
                        viol("IDLE inserted before a fixed-length burst finished");
                    end
                    burst_open <= 1'b0;
                end
                endcase

                last_acc_trans <= htrans_i;
                dp_pend        <= cur_active;
                dp_write       <= hwrite_i;
            end

            // -----------------------------------------------------------------
            // 6. Snapshot for the next cycle
            // -----------------------------------------------------------------
            p_haddr  <= haddr_i;  p_htrans <= htrans_i; p_hsize  <= hsize_i;
            p_hburst <= hburst_i; p_hwrite <= hwrite_i; p_hwdata <= hwdata_i;
            p_hready <= hready_i; p_hresp  <= hresp_i;
            seen_first <= 1'b1;
        end
    end

    // =========================================================================
    // End-of-simulation report.  Call hierarchically from the testbench.
    // =========================================================================
    task report_result;
        begin
            $display("--------------------------------------------------------------");
            $display("AHB-LITE CHECKER %m");
            $display("  address phases observed : %0d", n_addr_phases);
            $display("  bursts opened           : %0d", n_bursts);
            $display("  ERROR responses seen    : %0d", n_error_resp);
            if (n_wrap_unchecked != 0)
                $display("  WRAP bursts NOT CHECKED : %0d  <-- extend this checker",
                         n_wrap_unchecked);
            if (v_total == 0) begin
                $display("  VIOLATIONS              : 0   (clean)");
            end else begin
                $display("  VIOLATIONS              : %0d", v_total);
                if (v_retract)        $display("     retract-to-IDLE while HREADY low : %0d", v_retract);
                if (v_trans_change)   $display("     HTRANS changed in wait state     : %0d", v_trans_change);
                if (v_addr_change)    $display("     HADDR changed in wait state      : %0d", v_addr_change);
                if (v_ctrl_change)    $display("     HSIZE/HBURST/HWRITE in wait state: %0d", v_ctrl_change);
                if (v_seq_after_idle) $display("     SEQ after IDLE                   : %0d", v_seq_after_idle);
                if (v_seq_after_sgl)  $display("     SEQ following a SINGLE burst     : %0d", v_seq_after_sgl);
                if (v_seq_no_burst)   $display("     SEQ with no burst open           : %0d", v_seq_no_burst);
                if (v_burst_change)   $display("     HBURST changed mid-burst         : %0d", v_burst_change);
                if (v_size_change)    $display("     HSIZE changed mid-burst          : %0d", v_size_change);
                if (v_addr_seq)       $display("     SEQ address discontinuity        : %0d", v_addr_seq);
                if (v_1k_cross)       $display("     burst crossed a 1 KB boundary    : %0d", v_1k_cross);
                if (v_burst_short)    $display("     fixed-length burst truncated     : %0d", v_burst_short);
                if (v_busy_no_burst)  $display("     BUSY outside a burst             : %0d", v_busy_no_burst);
                if (v_unaligned)      $display("     HADDR unaligned to HSIZE         : %0d", v_unaligned);
                if (v_wdata_change)   $display("     HWDATA changed in wait state     : %0d", v_wdata_change);
                if (v_err_single)     $display("     one-cycle ERROR response         : %0d", v_err_single);
                if (v_resp_no_dp)     $display("     HRESP outside a data phase       : %0d", v_resp_no_dp);
            end
            $display("--------------------------------------------------------------");
        end
    endtask

endmodule
