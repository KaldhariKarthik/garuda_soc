`timescale 1ns/1ps
// =============================================================================
// tb_dsu_overflow_flag_spec.sv -- overflow_flag against GARUDA-DSU-SPEC-001
// [N-6.9] (Track A wrap-up 2026-10-12; replaces, for sign-off, the ported bench
// tb_dsu_overflow_flag, which requires clear-beats-set: TB-43).
// Reference, written from the spec: the flag is sticky; any accumulator or MACSAT
// overflow sets it; csr_clear_overflow clears it; a set and a clear in the same
// cycle leave it SET. Random stimulus (every input combination many times) plus
// the directed same-cycle cases; the output is checked after every edge.
// =============================================================================
module tb_dsu_overflow_flag_spec;
    logic clk = 0, rst_n = 0;
    logic [2:0] mac_ovf = 0;
    logic sat_ovf = 0, clr = 0;
    wire  flag;
    overflow_flag dut (.clk(clk), .rst_n(rst_n), .mac_overflow(mac_ovf), .sat_overflow(sat_ovf),
                       .csr_clear_overflow(clr), .dsu_overflow(flag));
    always #5 clk = ~clk;
    int checks = 0, fails = 0;
    logic ref_flag = 0;
    task automatic step(input [2:0] m, input bit s, input bit c, input string tag);
        mac_ovf = m; sat_ovf = s; clr = c;
        @(posedge clk); #1;
        ref_flag = (|m || s) ? 1'b1 : c ? 1'b0 : ref_flag;
        checks++;
        if (flag !== ref_flag) begin
            fails++;
            if (fails <= 10) $display("[FAIL] %s mac=%b sat=%b clr=%b -> flag=%b expected %b", tag, m, s, c, flag, ref_flag);
        end
    endtask
    initial begin
        repeat (2) @(posedge clk); #1; rst_n = 1;
        checks++; if (flag !== 1'b0) begin fails++; $display("[FAIL] flag not 0 after reset"); end
        // directed: each source sets it; a clear clears it; set beats a same-cycle clear
        for (int k = 0; k < 4; k++) begin
            step(k < 3 ? 3'(1 << k) : 3'b000, k == 3, 0, "set");
            step(0, 0, 0, "hold");
            step(0, 0, 1, "clear");
            step(k < 3 ? 3'(1 << k) : 3'b000, k == 3, 1, "set+clear same cycle");
            step(0, 0, 0, "hold after set+clear");
            step(0, 0, 1, "clear");
        end
        // random: every combination
        for (int i = 0; i < 20000; i++)
            step(3'($urandom_range(7, 0) & ($urandom_range(3, 0) == 0 ? 3'b111 : 3'b000)),
                 $urandom_range(7, 0) == 0, $urandom_range(3, 0) == 0, "random");
        // reset in the middle clears it
        step(3'b001, 0, 0, "set"); rst_n = 0; #2; ref_flag = 0;
        checks++; if (flag !== 1'b0) begin fails++; $display("[FAIL] reset did not clear the flag"); end
        rst_n = 1;
        $display("tb_dsu_overflow_flag_spec: checks=%0d FAIL=%0d", checks, fails);
        $display("RESULT: %s", (fails == 0 && checks > 0) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
