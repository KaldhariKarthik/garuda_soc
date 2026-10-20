`timescale 1ns/1ps
// =============================================================================
// tb_sc.sv - the planted bench of `make selfcheck_runners` (Docs/bugs/archive/BUGS_HISTORY.md TOOL-13)
//
// A runner that cannot fail is not a check. This bench fails on purpose, in one
// way per +SC= mode, and `make selfcheck_runners` runs it through every
// simulation macro of flow/mk/common.mk: each macro must report the "pass" mode
// as a pass and every other mode as a failure.
//
//   +SC=pass     prints a [PASS] line and the result line           -> must pass
//   +SC=fail     prints a [FAIL] line and RESULT: FAILED
//   +SC=assert   violates a concurrent assertion, then prints RESULT: PASSED
//   +SC=silent   ends without a result line
//   +SC=fatal    prints RESULT: PASSED, then stops with $fatal
// The file list filelist_sc_broken.f defines SC_COMPILE_ERROR, which makes the
// bench not compile at all.
//
// The module is called tb_top because the unit and element macros fix that name.
// =============================================================================
module tb_top;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg bad = 1'b0;
    reg [8*8-1:0] mode;

`ifdef __ICARUS__
    // Icarus does not parse a concurrent assertion; the same check as a process
    always @(posedge clk) if (bad) $error("[SVA-FAIL] a_sc_planted: the planted assertion failure");
`else
    a_sc_planted: assert property (@(posedge clk) !bad)
        else $error("[SVA-FAIL] a_sc_planted: the planted assertion failure");
`endif

    initial begin
        if (!$value$plusargs("SC=%s", mode)) mode = "pass";
        #20;
        if (mode == "pass") begin
            $display("[PASS] planted bench, control run");
            $display("RESULT: PASSED");
        end else if (mode == "fail") begin
            $display("[FAIL] planted bench, a failing check");
            $display("RESULT: FAILED");
        end else if (mode == "assert") begin
            bad = 1'b1;
            #20;
            $display("[PASS] planted bench, its own checks pass");
            $display("RESULT: PASSED");
        end else if (mode == "silent") begin
            // no result line at all
        end else if (mode == "fatal") begin
            $display("[PASS] planted bench, its own checks pass");
            $display("RESULT: PASSED");
            $fatal(1, "planted bench, a fatal after the result line");
        end else begin
            $display("RESULT: FAILED (unknown +SC mode)");
        end
        $finish;
    end

`ifdef SC_COMPILE_ERROR
    this line is not SystemVerilog
`endif
endmodule
