// =============================================================================
// tb_ahb_checker_selftest -- negative control for ahb_lite_checker
//
// WHY THIS EXISTS
// ---------------
// Docs/ORACLES.md: "A clean report from a checker that has not been shown to
// fail is worth nothing."  ahb_lite_checker is the oracle that found BUS-A/B/C/D
// and it is fatal by default, so it is now load-bearing -- and until this file
// there was nothing that drove it with KNOWN-BAD traffic to confirm it still
// fires, nor with known-GOOD traffic to confirm it does not.
//
// The checker is a purely passive monitor: it drives none of its inputs.  That
// makes it directly drivable.  Rather than arranging a DUT that happens to
// produce the waveform of interest, each scenario below presents the exact
// cycle-by-cycle tap values, which is the only way to hit a corner
// deterministically instead of hoping stimulus wanders into it.
//
// WHAT IT PINS DOWN (TB-15)
// -------------------------
// IHI 0033A s5.1.3 lets a master cancel the remaining transfers of a burst when
// a slave responds ERROR.  The first ERROR cycle is HRESP high with HREADY low
// -- inside the "HREADY is low" window where the checker polices address-phase
// stability -- so a legal cancel read as an illegal retraction.  dma_ahb_master
// does exactly this, so the first SoC-level bus-error-into-DMA test would have
// reported a false violation.
//
// The distinction is one bit of history, so the test is two scenarios that
// differ in that one bit and nothing else:
//
//   A  wait state WITH an ERROR response, then IDLE  -> legal cancel
//   B  wait state with NO error at all,    then IDLE -> genuine retraction
//
// A must not count a violation.  B must.  A test that only showed A clean would
// equally be passed by deleting the check, which is why B is here.
// =============================================================================
`timescale 1ns/1ps

module tb_ahb_checker_selftest;

    localparam [1:0] T_IDLE = 2'b00, T_NONSEQ = 2'b10;
    localparam [2:0] B_SINGLE = 3'b000;
    localparam [2:0] S_WORD   = 3'b010;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer checks = 0;
    integer fails  = 0;

    task check(input [255:0] what, input integer got, input integer want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("[FAIL] %0s: got %0d, want %0d", what, got, want);
            end else begin
                $display("[PASS] %0s = %0d", what, got);
            end
        end
    endtask

    // ---- scenario A: wait state carrying ERROR, then the master cancels -----
    reg        a_rst_n  = 1'b0;
    reg [31:0] a_haddr  = 32'h0;
    reg [ 1:0] a_htrans = T_IDLE;
    reg        a_hready = 1'b1;
    reg        a_hresp  = 1'b0;

    ahb_lite_checker u_a (
        .clk_i(clk), .rst_n_i(a_rst_n),
        .haddr_i(a_haddr), .htrans_i(a_htrans), .hsize_i(S_WORD),
        .hburst_i(B_SINGLE), .hwrite_i(1'b0), .hwdata_i(32'h0),
        .hready_i(a_hready), .hresp_i(a_hresp), .viol_count_o()
    );

    // ---- scenario B: plain wait state, then the master cancels --------------
    reg        b_rst_n  = 1'b0;
    reg [31:0] b_haddr  = 32'h0;
    reg [ 1:0] b_htrans = T_IDLE;
    reg        b_hready = 1'b1;
    reg        b_hresp  = 1'b0;

    ahb_lite_checker u_b (
        .clk_i(clk), .rst_n_i(b_rst_n),
        .haddr_i(b_haddr), .htrans_i(b_htrans), .hsize_i(S_WORD),
        .hburst_i(B_SINGLE), .hwrite_i(1'b0), .hwdata_i(32'h0),
        .hready_i(b_hready), .hresp_i(b_hresp), .viol_count_o()
    );

    initial begin
        $display("=== tb_ahb_checker_selftest: ahb_lite_checker negative control ===");

        @(negedge clk); a_rst_n = 1'b1; b_rst_n = 1'b1;

        // Taps are driven on the negative edge so each value is stable across
        // the rising edge the checker samples -- the checker's whole model is
        // "this cycle versus the previous cycle", and driving on the same edge
        // it samples would make which cycle a value belongs to a race.

        // --------------------------------------------------------------------
        // A: IDLE / NONSEQ(A) accepted / NONSEQ(B) held with ERROR / cancel
        // --------------------------------------------------------------------
        @(negedge clk);                                  // cycle 1: accepted
        a_haddr = 32'h2000_0000; a_htrans = T_NONSEQ;
        a_hready = 1'b1;         a_hresp  = 1'b0;

        @(negedge clk);     // cycle 2: data phase of A errors, first cycle:
        a_haddr = 32'h2000_0004; a_htrans = T_NONSEQ;   // B's address presented
        a_hready = 1'b0;         a_hresp  = 1'b1;       // HREADY low, HRESP high

        @(negedge clk);     // cycle 3: master abandons B; ERROR second cycle
        a_htrans = T_IDLE;
        a_hready = 1'b1;         a_hresp  = 1'b1;

        @(negedge clk);
        a_hresp = 1'b0;

        // --------------------------------------------------------------------
        // B: identical, except the wait state carries no error
        // --------------------------------------------------------------------
        @(negedge clk);
        b_haddr = 32'h2000_0000; b_htrans = T_NONSEQ;
        b_hready = 1'b1;         b_hresp  = 1'b0;

        @(negedge clk);
        b_haddr = 32'h2000_0004; b_htrans = T_NONSEQ;
        b_hready = 1'b0;         b_hresp  = 1'b0;       // plain wait state

        @(negedge clk);
        b_htrans = T_IDLE;
        b_hready = 1'b1;         b_hresp  = 1'b0;

        repeat (4) @(negedge clk);

        // --------------------------------------------------------------------
        // Verdict
        // --------------------------------------------------------------------
        $display("--- scenario A: error-cancel (AMBA-legal) ---");
        check("A: v_retract",   u_a.v_retract,   0);
        check("A: n_err_cancel", u_a.n_err_cancel, 1);
        check("A: v_err_single", u_a.v_err_single, 0);
        check("A: v_trans_change", u_a.v_trans_change, 0);

        $display("--- scenario B: genuine retraction (illegal) ---");
        check("B: v_retract",   u_b.v_retract,   1);
        check("B: n_err_cancel", u_b.n_err_cancel, 0);

        $display("");
        $display("tb_ahb_checker_selftest: checks=%0d FAIL=%0d", checks, fails);
        if (fails == 0) $display("RESULT: PASSED");
        else            $display("RESULT: FAILED");
        $finish;
    end

    initial begin
        #10000;
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
