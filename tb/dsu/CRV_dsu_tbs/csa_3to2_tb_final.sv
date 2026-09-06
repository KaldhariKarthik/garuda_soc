// =============================================================
// csa_3to2_tb.sv
// Tapeout-grade SV verification environment for GARUDA csa_3to2.v
// (3:2 carry-save compressor, WIDTH=48, used in the DSU MAC
// accumulator tree)
//
// Two-phase strategy (standard DV practice for parameterized,
// bit-independent combinational logic):
//   Phase A: EXHAUSTIVE check at a small width (WIDTH=4, all 4096
//            input combinations) -- proves the bitwise formula is
//            correct with 100% certainty, not just "well sampled".
//   Phase B: directed corners + permutation-invariance + CRV at the
//            REAL instantiated width (WIDTH=48) -- proves the
//            formula holds at the actual silicon width, including
//            the top-bit truncation/overflow question below.
//
// Also checks the actual functional requirement of a carry-save
// compressor -- sum + carry reconstructs a+b+c -- not just
// agreement with the RTL's own formula, and explicitly separates
// "genuine mismatch" from "known, by-construction top-bit
// truncation" so the two are never conflated in the pass/fail count.
//
// Requires a simulator with full IEEE1800 support (covergroup,
// assert property, constraint solver) -- e.g. Cadence Xcelium,
// Aldec Riviera-PRO, Questa, VCS. NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 1. DUT: csa_3to2.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module csa_3to2 #(parameter WIDTH = 48) (
    input wire [WIDTH-1:0] a,
    input wire [WIDTH-1:0] b,
    input wire [WIDTH-1:0] c,
    output wire [WIDTH-1:0] sum,
    output wire [WIDTH-1:0] carry
);

    assign sum = a^b^c;
    assign carry = ((a & b) | (b&c) | (a&c)) << 1;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (WIDTH=48, matches real usage) + bound SVA assertions
// -------------------------------------------------------------
interface csa_if #(parameter WIDTH = 48) (input bit clk);
    logic [WIDTH-1:0] a, b, c;
    logic [WIDTH-1:0] sum, carry;

    // A1: sum must equal a^b^c (mirrors the RTL's own formula -- fast
    //     redundant checker alongside the independently-coded scoreboard)
    property p_sum_formula;
        @(posedge clk) (sum == (a ^ b ^ c));
    endproperty
    a_sum_formula: assert property (p_sum_formula)
        else $error("[SVA-FAIL] sum != a^b^c: sum=%0h exp=%0h", sum, a^b^c);

    // A2: carry must equal majority(a,b,c) shifted left by 1 (structural
    //     mirror of the RTL, same rationale as A1)
    property p_carry_formula;
        @(posedge clk) (carry == (((a & b) | (b & c) | (a & c)) << 1));
    endproperty
    a_carry_formula: assert property (p_carry_formula)
        else $error("[SVA-FAIL] carry != majority(a,b,c)<<1: carry=%0h", carry);

    // A3: carry[0] is a structural invariant -- always 0, by construction
    //     of the left-shift-by-1. If a future refactor of this module
    //     ever breaks that (e.g. someone "optimizes" the shift away),
    //     this catches it immediately regardless of what a/b/c are.
    property p_carry_lsb_always_zero;
        @(posedge clk) (carry[0] == 1'b0);
    endproperty
    a_carry_lsb_always_zero: assert property (p_carry_lsb_always_zero)
        else $error("[SVA-FAIL] carry[0] != 0 (violates the left-shift-by-1 structural invariant)");

    // A4: X-propagation -- if every input bit is a known 0/1, every
    //     output bit must also be a known 0/1. An X silently surviving
    //     through combinational logic is invisible to a bit-compare
    //     scoreboard if both sides read X the same way, but real
    //     silicon has no concept of X -- a masked X-bug here becomes a
    //     silicon bug. This is the single highest-value tapeout-signoff
    //     check this environment adds beyond ordinary functional checking.
    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({a, b, c})) |-> (!$isunknown({sum, carry}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on sum/carry with fully-known a/b/c inputs -- sum=%0h carry=%0h", sum, carry);

endinterface


// -------------------------------------------------------------
// 3. TRANSACTION -- rand + constraint => real CRV (full-width phase)
// -------------------------------------------------------------
class csa_transaction #(parameter WIDTH = 48);
    rand bit [WIDTH-1:0] a, b, c;

    // Weight toward the patterns that actually stress a bitwise
    // majority/XOR compressor: all-0, all-1, alternating bit patterns,
    // single-bit corners, and the top-bit region specifically (since
    // that's where the truncation question in the header comment lives).
    constraint c_dist {
        a dist { {WIDTH{1'b0}} :/ 8, {WIDTH{1'b1}} :/ 8,
                 {(WIDTH/2){2'b10}} :/ 8, {(WIDTH/2){2'b01}} :/ 8,
                 [1 : {WIDTH{1'b1}}-1] :/ 68 };
        b dist { {WIDTH{1'b0}} :/ 8, {WIDTH{1'b1}} :/ 8,
                 {(WIDTH/2){2'b10}} :/ 8, {(WIDTH/2){2'b01}} :/ 8,
                 [1 : {WIDTH{1'b1}}-1] :/ 68 };
        c dist { {WIDTH{1'b0}} :/ 8, {WIDTH{1'b1}} :/ 8,
                 {(WIDTH/2){2'b10}} :/ 8, {(WIDTH/2){2'b01}} :/ 8,
                 [1 : {WIDTH{1'b1}}-1] :/ 68 };
    }

    function string sprint();
        return $sformatf("a=%012h b=%012h c=%012h", a, b, c);
    endfunction
endclass


// -------------------------------------------------------------
// 4. RESULT
// -------------------------------------------------------------
class csa_result;
    bit [63:0] a, b, c;   // stored wide enough for any WIDTH used here
    logic [63:0] sum, carry;
endclass


// -------------------------------------------------------------
// 5. GENERATOR -- directed corners + permutation-invariance + CRV
// -------------------------------------------------------------
class csa_generator #(parameter WIDTH = 48);
    typedef bit [WIDTH-1:0] w_t;
    w_t a_q[$], b_q[$], c_q[$];
    int num_random;

    function new(int num_random = 300);
        this.num_random = num_random;
    endfunction

    function void add(w_t va, w_t vb, w_t vc);
        a_q.push_back(va); b_q.push_back(vb); c_q.push_back(vc);
    endfunction

    function void build();
        w_t ZERO = '0;
        w_t ONES = '1;
        w_t ALT_10 = {(WIDTH/2){2'b10}};
        w_t ALT_01 = {(WIDTH/2){2'b01}};
        w_t MSB_ONLY = (w_t'(1)) << (WIDTH-1);
        w_t LSB_ONLY = w_t'(1);

        // 1) All-zero / all-one -- baseline sanity
        add(ZERO, ZERO, ZERO);
        add(ONES, ONES, ONES);

        // 2) Two zero, one max (isolates single-operand behavior)
        add(ONES, ZERO, ZERO);
        add(ZERO, ONES, ZERO);
        add(ZERO, ZERO, ONES);

        // 3) Alternating patterns -- classic bit-adjacency stress
        add(ALT_10, ALT_10, ALT_10);
        add(ALT_01, ALT_01, ALT_01);
        add(ALT_10, ALT_01, ALT_10);
        add(ALT_01, ALT_10, ALT_01);

        // 4) CRITICAL CORNER: MSB-only set on each operand individually
        //    and in combination -- exercises exactly the top-bit
        //    truncation/overflow question raised in the header comment.
        //    (>=2 of the three MSBs set => majority[WIDTH-1]=1 => that
        //    bit is unconditionally lost by the carry<<1 truncation.)
        add(MSB_ONLY, ZERO, ZERO);                 // 1 of 3 MSBs set -> no loss
        add(MSB_ONLY, MSB_ONLY, ZERO);              // 2 of 3 MSBs set -> loss
        add(MSB_ONLY, MSB_ONLY, MSB_ONLY);          // 3 of 3 MSBs set -> loss
        add(MSB_ONLY, ZERO, MSB_ONLY);               // 2 of 3 MSBs set -> loss

        // 5) LSB-only, to bookend the MSB corner
        add(LSB_ONLY, LSB_ONLY, LSB_ONLY);

        // 6) PERMUTATION INVARIANCE: a 3:2 compressor is symmetric in its
        //    three inputs -- sum/carry must be identical regardless of
        //    which physical port (a/b/c) each value is wired to. This is
        //    a cheap, high-value check for exactly the kind of bug that
        //    slips through in integration: an accidentally swapped wire
        //    between two operand ports. Same 3 distinct values, all 6
        //    orderings.
        begin
            w_t v1 = w_t'(48'hAAAA_5555_1234);
            w_t v2 = w_t'(48'h0F0F_F0F0_ABCD);
            w_t v3 = w_t'(48'h1111_2222_3333);
            add(v1, v2, v3); add(v1, v3, v2);
            add(v2, v1, v3); add(v2, v3, v1);
            add(v3, v1, v2); add(v3, v2, v1);
        end

        // 7) COVERAGE CLOSURE: cross cp_a_special x cp_b_special x
        //    cp_c_special needs all 3x3x3=27 combinations of
        //    {zero, ones, other} across (a,b,c). Item 1/2 above only
        //    covers the 5 "pure" corners (all-same-category); the mixed
        //    corners (e.g. a=zero, b=ones, c=other) have <1 expected hit
        //    over a few hundred CRV reps since they need 2-3 independently
        //    rare categories to align simultaneously. Sweep all 27
        //    deterministically rather than rely on CRV luck.
        begin
            w_t OTHER_VAL = w_t'(48'h3C5A_96C3_699C);  // a generic "neither 0 nor all-1s" value
            w_t cat_vals[3] = '{ZERO, ONES, OTHER_VAL};
            foreach (cat_vals[i])
                foreach (cat_vals[j])
                    foreach (cat_vals[k])
                        add(cat_vals[i], cat_vals[j], cat_vals[k]);
        end

        // 8) CONSTRAINED-RANDOM (CRV)
        repeat (num_random) begin
            csa_transaction #(WIDTH) t = new();
            assert (t.randomize()) else $error("[GEN] randomize() failed");
            add(t.a, t.b, t.c);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class csa_driver #(parameter WIDTH = 48);
    virtual csa_if #(WIDTH) vif;

    function new(virtual csa_if #(WIDTH) vif);
        this.vif = vif;
    endfunction

    task drive_one(bit [WIDTH-1:0] va, bit [WIDTH-1:0] vb, bit [WIDTH-1:0] vc);
        @(posedge vif.clk);
        vif.a <= va;
        vif.b <= vb;
        vif.c <= vc;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class csa_monitor #(parameter WIDTH = 48);
    virtual csa_if #(WIDTH) vif;

    // Explicit, correctly-sized storage for the MSB popcount. The
    // covergroup used to coverpoint the inline expression
    // (vif.a[WIDTH-1] + vif.b[WIDTH-1] + vif.c[WIDTH-1])
    // directly -- but with three 1-bit self-determined operands and no
    // wider context forcing otherwise, that addition can size itself to
    // 1 bit, silently wrapping mod 2 and making bin values 2 and 3
    // unreachable (confirmed by xmelab's *W,OBINVE warning on a real
    // run). Sampling into an explicit 2-bit variable first removes the
    // ambiguity entirely.
    bit [1:0] msb_popcount;

    covergroup cg_csa;
        // How many of the three operands have their MSB set -- directly
        // covers the top-bit truncation/overflow question: bin msb_2of3
        // and msb_3of3 are exactly the cases where information is lost.
        cp_msb_popcount: coverpoint msb_popcount {
            bins msb_0of3 = {0};
            bins msb_1of3 = {1};
            bins msb_2of3 = {2};   // top-bit loss occurs here
            bins msb_3of3 = {3};   // and here
        }
        cp_a_special: coverpoint vif.a {
            bins zero = {0}; bins ones = {{WIDTH{1'b1}}}; bins other = default;
        }
        cp_b_special: coverpoint vif.b {
            bins zero = {0}; bins ones = {{WIDTH{1'b1}}}; bins other = default;
        }
        cp_c_special: coverpoint vif.c {
            bins zero = {0}; bins ones = {{WIDTH{1'b1}}}; bins other = default;
        }
        cross cp_a_special, cp_b_special, cp_c_special;
    endgroup

    function new(virtual csa_if #(WIDTH) vif);
        this.vif = vif;
        cg_csa = new();
    endfunction

    task sample_one(bit [WIDTH-1:0] va, bit [WIDTH-1:0] vb, bit [WIDTH-1:0] vc, output csa_result r);
        #1; // allow combinational logic to settle after drive_one()'s NBA update
        r = new();
        r.a = va; r.b = vb; r.c = vc;
        r.sum = vif.sum;
        r.carry = vif.carry;
        msb_popcount = {1'b0, vif.a[WIDTH-1]} + {1'b0, vif.b[WIDTH-1]} + {1'b0, vif.c[WIDTH-1]};
        cg_csa.sample();
    endtask

    function real get_coverage();
        return cg_csa.get_coverage();
    endfunction
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD -- independent reference model (majority via bit
//    popcount, NOT the (a&b)|(b&c)|(a&c) expression, so it cannot
//    silently repeat the same conceptual bug as the RTL) + the
//    actual arithmetic-identity check (sum+carry reconstructs a+b+c,
//    except at the documented, expected top-bit truncation point).
// -------------------------------------------------------------
class csa_scoreboard #(parameter WIDTH = 48);
    int pass_cnt = 0;
    int fail_cnt = 0;
    int expected_truncation_cnt = 0;   // informational, not a failure

    function void predict(bit [WIDTH-1:0] a, bit [WIDTH-1:0] b, bit [WIDTH-1:0] c,
                           output logic [WIDTH-1:0] e_sum, output logic [WIDTH-1:0] e_carry,
                           output bit e_top_bit_lost);
        logic [WIDTH-1:0] majority;
        for (int i = 0; i < WIDTH; i++) begin
            // independent majority computation: popcount of the 3 bits >= 2
            majority[i] = (a[i] + b[i] + c[i]) >= 2;
        end
        for (int i = 0; i < WIDTH; i++)
            e_sum[i] = a[i] ^ b[i] ^ c[i];
        e_carry = 0;
        for (int i = 0; i < WIDTH-1; i++)
            e_carry[i+1] = majority[i];
        // majority[WIDTH-1] has nowhere to go in a WIDTH-bit carry -- this
        // is the documented top-bit truncation.
        e_top_bit_lost = majority[WIDTH-1];
    endfunction

    task check(csa_result r);
        logic [WIDTH-1:0] e_sum, e_carry;
        bit e_top_bit_lost;
        logic [WIDTH+1:0] true_sum, reconstructed;
        bit formula_ok, identity_ok;

        predict(r.a[WIDTH-1:0], r.b[WIDTH-1:0], r.c[WIDTH-1:0], e_sum, e_carry, e_top_bit_lost);

        formula_ok = (r.sum[WIDTH-1:0] === e_sum) && (r.carry[WIDTH-1:0] === e_carry);

        // Arithmetic identity: does sum+carry reconstruct a+b+c? Widen to
        // WIDTH+2 bits so neither side can itself overflow the check.
        true_sum      = {2'b00, r.a[WIDTH-1:0]} + {2'b00, r.b[WIDTH-1:0]} + {2'b00, r.c[WIDTH-1:0]};
        reconstructed = {2'b00, r.sum[WIDTH-1:0]} + {2'b00, r.carry[WIDTH-1:0]};

        if (e_top_bit_lost) begin
            // Expected discrepancy: reconstructed is short by exactly the
            // value of the lost top carry bit (2^WIDTH). This is NOT a
            // failure -- it's the documented, by-construction truncation.
            identity_ok = (true_sum - reconstructed) == (logic'(1) << WIDTH);
            expected_truncation_cnt++;
        end else begin
            identity_ok = (true_sum == reconstructed);
        end

        if (formula_ok && identity_ok) begin
            pass_cnt++;
            $display("[PASS] a=%0h b=%0h c=%0h -> sum=%0h carry=%0h%s",
                      r.a[WIDTH-1:0], r.b[WIDTH-1:0], r.c[WIDTH-1:0], r.sum[WIDTH-1:0], r.carry[WIDTH-1:0],
                      e_top_bit_lost ? "  [top-bit truncation expected]" : "");
        end else begin
            fail_cnt++;
            $display("[FAIL] a=%0h b=%0h c=%0h", r.a[WIDTH-1:0], r.b[WIDTH-1:0], r.c[WIDTH-1:0]);
            $display("       formula : sum got=%0h exp=%0h | carry got=%0h exp=%0h",
                      r.sum[WIDTH-1:0], e_sum, r.carry[WIDTH-1:0], e_carry);
            $display("       identity: true_sum=%0h reconstructed=%0h top_bit_lost=%0b",
                      true_sum, reconstructed, e_top_bit_lost);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT (sequential drive -> sample -> check, no fork/join)
// -------------------------------------------------------------
class csa_env #(parameter WIDTH = 48);
    virtual csa_if #(WIDTH) vif;
    csa_generator  #(WIDTH) gen;
    csa_driver     #(WIDTH) drv;
    csa_monitor    #(WIDTH) mon;
    csa_scoreboard #(WIDTH) sb;
    int num_txns;

    function new(virtual csa_if #(WIDTH) vif, int num_random = 300);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        csa_result r;
        gen.build();
        num_txns = gen.a_q.size();

        foreach (gen.a_q[i]) begin
            drv.drive_one(gen.a_q[i], gen.b_q[i], gen.c_q[i]);
            mon.sample_one(gen.a_q[i], gen.b_q[i], gen.c_q[i], r);
            sb.check(r);
        end

        $display("\n================ CSA_3TO2 (WIDTH=%0d) UNIT TB SUMMARY ================", WIDTH);
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d  (of which %0d had expected top-bit truncation)",
                  num_txns, sb.pass_cnt, sb.fail_cnt, sb.expected_truncation_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display("========================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class csa_test #(parameter WIDTH = 48);
    csa_env #(WIDTH) env;
    function new(virtual csa_if #(WIDTH) vif, int num_random = 300);
        env = new(vif, num_random);
    endfunction
    task run();
        env.run();
    endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP -- two DUT instances:
//     dut_full       : WIDTH=48, the real instantiated width, driven
//                      by the full class-based CRV/directed environment.
//     dut_exhaustive : WIDTH=4, driven by a plain nested-loop that
//                      applies ALL 4096 possible (a,b,c) combinations
//                      and checks each one bit-exactly. Exhaustive
//                      verification is only tractable at a small width,
//                      but since every RTL statement here is a simple
//                      per-bit replicated formula (no cross-bit-position
//                      dependency except the intentional <<1 shift),
//                      proving the formula 100% correct at WIDTH=4
//                      gives very high confidence it generalizes to
//                      WIDTH=48 -- this is standard DV practice for
//                      parameterized, bit-independent combinational logic.
// -------------------------------------------------------------
module tb_top;
    localparam FULL_WIDTH = 48;
    localparam EXH_WIDTH  = 4;

    bit clk = 0;
    always #5 clk = ~clk;   // sequencing clock; DUT itself is combinational

    // ---------------- Phase B: full-width (48) ----------------
    csa_if #(FULL_WIDTH) vif(clk);

    csa_3to2 #(.WIDTH(FULL_WIDTH)) dut_full (
        .a(vif.a), .b(vif.b), .c(vif.c), .sum(vif.sum), .carry(vif.carry)
    );

    csa_test #(FULL_WIDTH) test;

    // ---------------- Phase A: exhaustive (WIDTH=4) ----------------
    logic [EXH_WIDTH-1:0] ea, eb, ec;
    logic [EXH_WIDTH-1:0] esum, ecarry;
    int exh_total, exh_pass, exh_fail;

    csa_3to2 #(.WIDTH(EXH_WIDTH)) dut_exhaustive (
        .a(ea), .b(eb), .c(ec), .sum(esum), .carry(ecarry)
    );

    task automatic run_exhaustive();
        logic [EXH_WIDTH-1:0] exp_sum, exp_carry, majority;
        exh_total = 0; exh_pass = 0; exh_fail = 0;
        for (int ia = 0; ia < (1 << EXH_WIDTH); ia++) begin
            for (int ib = 0; ib < (1 << EXH_WIDTH); ib++) begin
                for (int ic = 0; ic < (1 << EXH_WIDTH); ic++) begin
                    ea = ia[EXH_WIDTH-1:0]; eb = ib[EXH_WIDTH-1:0]; ec = ic[EXH_WIDTH-1:0];
                    #1;
                    exp_sum = ea ^ eb ^ ec;
                    for (int i = 0; i < EXH_WIDTH; i++)
                        majority[i] = (ea[i] + eb[i] + ec[i]) >= 2;
                    exp_carry = 0;
                    for (int i = 0; i < EXH_WIDTH-1; i++)
                        exp_carry[i+1] = majority[i];
                    exh_total++;
                    if (esum === exp_sum && ecarry === exp_carry) begin
                        exh_pass++;
                    end else begin
                        exh_fail++;
                        $display("[EXHAUSTIVE-FAIL] a=%0h b=%0h c=%0h -> sum got=%0h exp=%0h | carry got=%0h exp=%0h",
                                  ea, eb, ec, esum, exp_sum, ecarry, exp_carry);
                    end
                end
            end
        end
        $display("\n================ CSA_3TO2 (WIDTH=%0d) EXHAUSTIVE SUMMARY ================", EXH_WIDTH);
        $display(" TOTAL=%0d (all possible input combinations)  PASS=%0d  FAIL=%0d", exh_total, exh_pass, exh_fail);
        if (exh_fail == 0)
            $display(" RESULT: 100%% EXHAUSTIVE PROOF -- bitwise formula is correct for every possible input");
        else
            $display(" RESULT: %0d COMBINATION(S) FAILED", exh_fail);
        $display("===========================================================================\n");
    endtask

    initial begin
        vif.a = '0; vif.b = '0; vif.c = '0;

        run_exhaustive();

        test = new(vif, 300);
        test.run();

        $finish;
    end
endmodule
