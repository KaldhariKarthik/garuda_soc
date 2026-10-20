`timescale 1ns/1ps
// =============================================================================
// tb_dsu_stall_spec.sv -- dsu_stall (the RAW interlock) against GARUDA-DSU-SPEC-001
// [N-7.6]-[N-7.8] (Track A wrap-up 2026-10-12; for sign-off next to the ported
// tb_dsu_stall, TB-43). The bench drives one DSU instruction per cycle and, like
// the pipeline, re-presents an instruction while dsu_busy is high.
// Reference: an instruction that READS an accumulator (MACRD_LO, MACRD_HI, MACSAT,
// MACSHIFT) presented right after an accumulate (MAC_SEL, MACSUB, MACABS, MACDOT)
// on the same accumulator stalls exactly one cycle ([N-7.6], [N-7.7]); on another
// accumulator it never stalls ([N-7.8]); a non-reading instruction never stalls.
// Accepted and counted, not asserted: the RTL also stalls a read right after a
// MACRD / MACSAT of the same accumulator (one cycle, performance only; ruling on
// narrowing the interlock, TB-43). flush = 0 (flush is covered at core level).
// =============================================================================
`include "dsu_defs.vh"
module tb_dsu_stall_spec;
    logic clk = 0, rst_n = 0, flush = 0, is_c0 = 0;
    logic [4:0] f5 = 0; logic [2:0] f3 = 0; logic [1:0] sel = 0;
    wire busy;
    dsu_stall dut (.clk(clk), .rst_n(rst_n), .flush(flush), .funct5(f5), .funct3(f3), .is_custom0(is_c0),
                   .acc_sel(sel), .dsu_busy(busy));
    always #5 clk = ~clk;
    int checks = 0, fails = 0, extra = 0, stalls = 0, n_want = 0, n_want_ok = 0;
    function automatic bit is_acc(input bit c0, input [2:0] t3, input [4:0] t5);
        return c0 && t3 == 3'b000 && t5 <= 5'd3;
    endfunction
    function automatic bit is_read(input bit c0, input [2:0] t3, input [4:0] t5);
        return c0 && ((t3 == 3'b000 && (t5 == 5'd6 || t5 == 5'd7 || t5 == 5'd8)) || t3 == 3'b001);
    endfunction
    bit p_c0 = 0, p_val = 0; logic [2:0] p3; logic [4:0] p5; logic [1:0] psel;
    task automatic issue(input bit c0, input [2:0] t3, input [4:0] t5, input [1:0] s);
        int held = 0;
        bit want = p_val && is_acc(p_c0, p3, p5) && is_read(c0, t3, t5) && psel == s;
        // the read-after-read stall: the previous op was MACRD_LO / MACRD_HI / MACSAT (a MACSHIFT is
        // not two-cycle in the RTL), the current one reads the same accumulator
        bit maybe = p_val && p_c0 && p3 == 3'b000 && (p5 == 5'd6 || p5 == 5'd7 || p5 == 5'd8) &&
                    is_read(c0, t3, t5) && psel == s;
        is_c0 = c0; f3 = t3; f5 = t5; sel = s;
        #1;
        while (busy) begin held++; @(posedge clk); #1; if (held > 4) break; end
        checks++;
        n_want += want; n_want_ok += want && held == 1;
        if (want && held != 1) begin fails++; if (fails <= 10) $display("[FAIL] read of acc%0d after an accumulate: held %0d cycles, expected 1", s, held); end
        else if (!want && held != 0) begin
            if (maybe && held == 1) extra++;
            else begin fails++; if (fails <= 10) $display("[FAIL] f3=%0d f5=%0d acc%0d after f3=%0d f5=%0d acc%0d: held %0d, expected 0", t3, t5, s, p3, p5, psel, held); end
        end
        stalls += held;
        @(posedge clk); #1;                    // the next inputs change after the edge, never on it
        p_c0 = c0; p3 = t3; p5 = t5; psel = s; p_val = 1;
    endtask
    initial begin
        repeat (2) @(posedge clk); #1; rst_n = 1; @(posedge clk); #1;
        // directed: every producer x every consumer x same / other accumulator
        for (int a = 0; a < 10; a++) for (int b = 0; b < 10; b++) for (int same = 0; same < 2; same++) begin
            issue(1, a == 9 ? 3'b001 : 3'b000, a == 9 ? 5'd0 : 5'(a), 2'd0);
            issue(1, b == 9 ? 3'b001 : 3'b000, b == 9 ? 5'd0 : 5'(b), same ? 2'd0 : 2'd1);
            issue(0, 3'b000, 5'd0, 2'd0);                              // a non-DSU instruction between pairs
        end
        // random streams
        for (int r = 0; r < 20000; r++) begin
            automatic int op = $urandom_range(10, 0);
            issue(op != 10, op == 9 ? 3'b001 : 3'b000, op >= 9 ? 5'd0 : 5'(op), 2'($urandom_range(2, 0)));
        end
        $display("tb_dsu_stall_spec: checks=%0d FAIL=%0d required stalls %0d/%0d, stall cycles=%0d (extra read-after-read stalls accepted until the ruling: %0d)",
                 checks, fails, n_want_ok, n_want, stalls, extra);
        $display("RESULT: %s", (fails == 0 && checks > 0 && n_want > 100 && n_want_ok == n_want) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
