// =============================================================================
// garuda_tb_pkg.sv -- shared scoreboard / reporting for the core element TBs
//
// The six older unit TBs (tb_imm_gen.sv, tb_reg_file.sv, ...) each carry their
// own copy of an identical scoreboard class. That is 6 copies of the same
// pass/fail counter and the same [PASS]/[FAIL] format string, and the format
// is load-bearing: the Makefile's run_tb_top helper counts results with
//     grep -c '\[PASS\]'  /  grep -c '\[FAIL\]'
// so a drifted copy silently reports zero. The 14 element TBs added alongside
// them share this one definition instead.
//
// Output contract (do not change without updating the Makefile):
//   [PASS] ...        one per successful check
//   [FAIL] ...        one per failed check, followed by got/exp detail
//   RESULT: ALL CHECKS PASSED   /   RESULT: <n> CHECK(S) FAILED
// The RESULT line is what the run_test-style targets grep for.
// =============================================================================

package garuda_tb_pkg;

    // -------------------------------------------------------------------
    // Scoreboard: counts checks and prints them in the harness's format.
    //
    // verbose=0 (the default) suppresses the per-check [PASS] line for the
    // high-volume randomised sweeps -- an exhaustive ALU sweep is ~26k
    // checks and 26k [PASS] lines make the log useless and the grep slow.
    // Passes are still COUNTED; set +VERBOSE to print them all.
    // -------------------------------------------------------------------
    class scoreboard;
        int    pass_cnt = 0;
        int    fail_cnt = 0;
        string dut_name;
        bit    verbose  = 0;

        function new(string dut_name);
            this.dut_name = dut_name;
            if ($test$plusargs("VERBOSE")) verbose = 1;
        endfunction

        // Record a pass without a comparison (for properties checked inline).
        function void pass(string seq, string what);
            pass_cnt++;
            if (verbose) $display("[PASS] %-24s %s", seq, what);
        endfunction

        function void fail(string seq, string what, string detail);
            fail_cnt++;
            $display("[FAIL] %-24s %s", seq, what);
            if (detail != "") $display("       %s", detail);
        endfunction

        // Vector compare. Uses === so an X on either side is a failure
        // rather than a silent match.
        function void chk(string seq, string what,
                          logic [63:0] got, logic [63:0] exp);
            if (got === exp) begin
                pass_cnt++;
                if (verbose)
                    $display("[PASS] %-24s %-34s = 0x%0h", seq, what, got);
            end else begin
                fail_cnt++;
                $display("[FAIL] %-24s %s", seq, what);
                $display("       exp=0x%0h  act=0x%0h", exp, got);
            end
        endfunction

        // Single-bit compare, printed as %b so a control-signal failure is
        // readable at a glance.
        function void chk1(string seq, string what, logic got, logic exp);
            if (got === exp) begin
                pass_cnt++;
                if (verbose)
                    $display("[PASS] %-24s %-34s = %b", seq, what, got);
            end else begin
                fail_cnt++;
                $display("[FAIL] %-24s %s", seq, what);
                $display("       exp=%b  act=%b", exp, got);
            end
        endfunction

        function void summary(real coverage = -1.0);
            $display("\n============ %s UNIT TB SUMMARY ============", dut_name);
            $display(" CHECKS=%0d  PASS=%0d  FAIL=%0d",
                     pass_cnt + fail_cnt, pass_cnt, fail_cnt);
            if (coverage >= 0.0)
                $display(" FUNCTIONAL COVERAGE = %0.2f %%", coverage);
            if (fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
            else               $display(" RESULT: %0d CHECK(S) FAILED", fail_cnt);
            $display("=================================================\n");
        endfunction
    endclass

endpackage
