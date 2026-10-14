// =============================================================================
// runner_selftest.sv -- planted outcomes for qualifying tools/run/garuda_run.py
//
// Each +MODE= produces exactly one kind of failure the runner must catch.
// Gate A requires every planted failure to be reported as FAIL (and the one
// broken build as BLOCKED) while MODE=pass still PASSes; see selftest.toml.
// Docs/handbook/H2_running.md, "Qualifying the runner".
// =============================================================================
`timescale 1ns/1ps
module runner_selftest;
    string mode;
    logic  clk = 1'b0;
    int    cyc = 0;
    always #5 clk = ~clk;
    always @(posedge clk) cyc <= cyc + 1;

    // planted concurrent-assertion failure: fires once at cycle 3 in
    // assert_fail mode. With +verilator+error+limit raised Verilator still
    // EXITS 0 here, so only the log count can catch it.
    a_planted: assert property (@(posedge clk) !(mode == "assert_fail" && cyc == 3))
        else $error("[SVA-PLANTED] planted assertion failure");

    initial begin
        if (!$value$plusargs("MODE=%s", mode)) mode = "pass";
        repeat (6) @(posedge clk);
        case (mode)
            "pass":        ;
            "fail_line":   $display("[FAIL] planted check failure");
            "assert_fail": ;                         // a_planted fired at cycle 3
            "error":       $error("planted $error outside any assertion");
            "no_marker":   ;                         // prints the wrong result line below
            "fatal":       $fatal(1, "planted $fatal");
            "hang":        forever @(posedge clk);   // never ends -> runner timeout
            default:       $fatal(1, "unknown MODE %s", mode);
        endcase
        // Measured on Verilator 5.052: a process keeps executing after $finish until it
        // yields, so the pass line must be skipped by control flow, never by
        // relying on an earlier $finish (measured: Docs/handbook/H2_running.md).
        if (mode == "no_marker") $display("RESULT: something else");
        else                     $display(" RESULT: ALL CHECKS PASSED (mode=%s)", mode);
        $finish;
    end
endmodule
