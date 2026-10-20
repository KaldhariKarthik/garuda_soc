// Planted build failure: must be reported BLOCKED, never PASS or FAIL.
module runner_selftest_broken;
    initial begin
        $display(" RESULT: ALL CHECKS PASSED")   // missing ';' on purpose
    end
endmodule
