`timescale 1ns/1ps
// =============================================================================
// tb_dsu_barrel_shifter_spec.sv -- barrel_shifter as a datapath element (Track A
// wrap-up 2026-10-12; for sign-off next to the ported tb_dsu_barrel_shifter, TB-43).
// Reference, independent of the RTL's structure: shift_result is the low 32 bits
// of the 48-bit accumulator shifted left (shift_dir = 1) or arithmetically right
// (shift_dir = 0) by shift_amt. Every amount 0..47 in both directions, against
// corner and random accumulators. Amounts 48..63 are not checked: they are
// undefined in the specification and the decoder refuses them (DSU-6), so they
// never reach this unit; MACSHIFT itself is under ruling (DSU-17).
// =============================================================================
module tb_dsu_barrel_shifter_spec;
    logic [47:0] acc;
    logic [5:0]  amt;
    logic        dir;
    wire  [31:0] res;
    barrel_shifter dut (.cluster_out(acc), .shift_amt(amt), .shift_dir(dir), .shift_result(res));
    int checks = 0, fails = 0;
    function automatic [31:0] ref_shift(input [47:0] a, input [5:0] n, input bit left);
        logic signed [47:0] sa = a;
        return left ? 32'(a << n) : 32'(sa >>> n);
    endfunction
    task automatic chk(input [47:0] a, input [5:0] n, input bit left);
        acc = a; amt = n; dir = left; #1;
        checks++;
        if (res !== ref_shift(a, n, left)) begin
            fails++;
            if (fails <= 10) $display("[FAIL] acc=%012h amt=%0d dir=%0d -> %08h expected %08h", a, n, left, res, ref_shift(a, n, left));
        end
    endtask
    logic [47:0] corners [8] = '{48'h0, 48'h1, 48'hFFFF_FFFF_FFFF, 48'h8000_0000_0000, 48'h7FFF_FFFF_FFFF,
                                 48'h0000_8000_0000, 48'hAAAA_5555_AAAA, 48'h1234_5678_9ABC};
    initial begin
        for (int n = 0; n < 48; n++) for (int d = 0; d < 2; d++) begin
            foreach (corners[c]) chk(corners[c], 6'(n), d[0]);
            for (int r = 0; r < 64; r++) chk({$urandom(), $urandom()}, 6'(n), d[0]);
        end
        $display("tb_dsu_barrel_shifter_spec: checks=%0d FAIL=%0d", checks, fails);
        $display("RESULT: %s", (fails == 0 && checks > 0) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
