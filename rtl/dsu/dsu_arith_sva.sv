`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - DSU : the two arithmetic primitives against the language's own operators
// dsu_arith_sva.sv
// kogge_stone_49: sum = a + b + cin (modulo 2^49); mult_16x16: p = signed a * signed b.
// Immediate checks, so every addition and multiplication any DSU simulation makes is
// compared with the operator. A proof of these is an equivalence problem, not a
// property one (the applicability matrix says so); simulation is where they are checked.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module kogge_stone_49_sva (input wire [48:0] a, b, sum, input wire cin);
    always @(*) if (!$isunknown({a, b, cin}))
        a_ks_sum: assert #0 (sum == (a + b + {48'd0, cin}))
            else $error("[SVA-FAIL] a_ks_sum: %h + %h + %b gave %h", a, b, cin, sum);
endmodule
module mult_16x16_sva (input wire signed [15:0] a, b, input wire signed [31:0] p);
    always @(*) if (!$isunknown({a, b}))
        a_mul_product: assert #0 (p == a * b)
            else $error("[SVA-FAIL] a_mul_product: %0d * %0d gave %0d", a, b, p);
endmodule
bind kogge_stone_49 kogge_stone_49_sva u_ks_sva (.*);
bind mult_16x16 mult_16x16_sva u_mul_sva (.*);
`endif
`endif
