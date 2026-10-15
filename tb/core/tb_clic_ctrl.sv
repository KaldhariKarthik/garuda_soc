`timescale 1ns/1ps
// =============================================================================
// tb_clic_ctrl.sv -- core element TB: clic_ctrl (take / wake / vector)
//
// Spec: GARUDA-CORE-SPEC-001 Rev 3.0 §7.5 [N-7.15], [N-7.16], [N-7.27];
//       GARUDA-CLIC-SPEC-001 §7.4; DECISIONS D-15; DN-CTL (mgarudactl).
// Rev 4.0 interface: {valid, id[4:0], level[7:0]} - no SHV, no acknowledge,
// every trap vectors to mtvec BASE. Replaces the Rev 1.1 element TB, whose
// SHV/ack checks no longer describe the hardware.
//
//   take   = valid & MIE & (level > mintthresh) & (level > mil)   (strict >)
//            & (~PREEMPT_DIS | mil == 0)                           (CORE-4)
//   wake   = valid                                                 (MIE-independent)
//   target = mtvec_i (csr_file already supplies BASE = {mtvec[31:2],2'b00})
// Directed boundary cases (equal level never preempts), 5000 random vectors and
// 5000 boundary-biased vectors (level-1 / level / level+1 for both compares)
// against the reference expression. [PASS] per vector only when all its checks
// passed, [FAIL] per failed check, and a RESULT line.
//
// Coverage (ELEM-7): cg_clic bins the level-vs-threshold and level-vs-mil
// relations with EQUALITY as its own bin, so strict > (test C24) is shown to be
// exercised, not assumed. The same relations are also counted in plain ints and
// checked at the end, so the evidence does not depend on covergroup support.
// =============================================================================
module tb_top;
    logic        valid, mie, pdis;
    logic [4:0]  id;
    logic [7:0]  level, thresh, mil;
    logic [31:0] mtvec;
    wire         take, wake;
    wire [4:0]   id_o;
    wire [7:0]   lvl_o;
    wire [31:0]  target;

    clic_ctrl #(.ID_W(5)) dut (
        .clic_irq_valid_i(valid), .clic_irq_id_i(id), .clic_irq_level_i(level),
        .mstatus_mie_i(mie), .mintthresh_i(thresh), .mintstatus_mil_i(mil),
        .preempt_dis_i(pdis),          // CORE-4 (mgarudactl.PREEMPT_DIS)
        .mtvec_i(mtvec),
        .take_cond_o(take), .wake_cond_o(wake), .irq_id_o(id_o), .irq_lvl_o(lvl_o),
        .vector_target_o(target));

    // relation of level to a compare value: 0 below, 1 equal, 2 above
    function automatic int rel(logic [7:0] l, logic [7:0] x);
        return (l < x) ? 0 : (l == x) ? 1 : 2;
    endfunction

    int rel_t, rel_a;              // sampled by cg_clic
    bit armed;                     // valid & MIE: the compares decide the take
    bit in_handler;
    covergroup cg_clic;
        cp_lvl_vs_thresh: coverpoint rel_t iff (armed) { bins below = {0}; bins equal = {1}; bins above = {2}; }
        cp_lvl_vs_active: coverpoint rel_a iff (armed) { bins below = {0}; bins equal = {1}; bins above = {2}; }
        cp_preempt_dis:   coverpoint pdis  iff (armed) { bins off = {0}; bins on = {1}; }
        cp_in_handler:    coverpoint in_handler iff (armed) { bins level0 = {0}; bins handler = {1}; }
        cp_take:          coverpoint take  { bins no = {0}; bins yes = {1}; }
    endgroup
    cg_clic cg = new();

    // the key bins again as plain counters, checked at the end
    int n_rel_t[3], n_rel_a[3], n_pdis_handler, n_pdis_level0;

    int pass = 0, fail = 0;
    function automatic void chk(bit c, string what, ref int vfail);
        if (c) begin pass++; end
        else begin fail++; vfail++; $display("[FAIL] %s", what); end
    endfunction

    task automatic apply(bit v, bit m, bit pd, logic [4:0] i, logic [7:0] l, logic [7:0] t,
                         logic [7:0] a, logic [31:0] vec, string tag);
        bit exp_take;
        int vfail = 0;
        valid = v; mie = m; pdis = pd; id = i; level = l; thresh = t; mil = a; mtvec = vec;
        #1;
        exp_take = v && m && (l > t) && (l > a) && (!pd || a == 8'd0);
        chk(take === exp_take, $sformatf("%s: take=%0b exp %0b (v=%0b mie=%0b pdis=%0b lvl=%0d thr=%0d mil=%0d)",
                                         tag, take, exp_take, v, m, pd, l, t, a), vfail);
        chk(wake === v, $sformatf("%s: wake follows valid regardless of MIE", tag), vfail);
        chk(target === vec, $sformatf("%s: vector = mtvec BASE (passed through)", tag), vfail);
        chk(id_o === i && lvl_o === l, $sformatf("%s: id/level passed through", tag), vfail);
        armed = v && m; rel_t = rel(l, t); rel_a = rel(l, a); in_handler = (a != 8'd0);
        cg.sample();
        if (armed) begin
            n_rel_t[rel_t]++; n_rel_a[rel_a]++;
            if (pd && a != 0 && l > t && l > a) n_pdis_handler++;   // would preempt, but disabled
            if (pd && a == 0 && l > t)          n_pdis_level0++;    // disabled, still taken at level 0
        end
        if (vfail == 0) $display("[PASS] %s", tag);
    endtask

    // boundary-biased compare value: level-1, level, level+1 or anything
    function automatic logic [7:0] near(logic [7:0] l);
        case ($urandom_range(0, 3))
            0: return l - 8'd1;
            1: return l;
            2: return l + 8'd1;
            default: return 8'($urandom);
        endcase
    endfunction

    initial begin
        logic [7:0] l, a;
        int unused;
        apply(1, 1, 0, 5'd3, 8'd10, 8'd0,  8'd0,  32'h0000_0100, "takeable");
        apply(0, 1, 0, 5'd3, 8'd10, 8'd0,  8'd0,  32'h0000_0100, "no request");
        apply(1, 0, 0, 5'd3, 8'd10, 8'd0,  8'd0,  32'h0000_0100, "MIE clear blocks take, not wake");
        apply(1, 1, 0, 5'd3, 8'd10, 8'd10, 8'd0,  32'h0000_0100, "level == mintthresh does not take");
        apply(1, 1, 0, 5'd3, 8'd11, 8'd10, 8'd0,  32'h0000_0100, "level > mintthresh takes");
        apply(1, 1, 0, 5'd3, 8'd80, 8'd0,  8'd80, 32'h0000_0100, "equal level never preempts (mil)");
        apply(1, 1, 0, 5'd3, 8'd81, 8'd0,  8'd80, 32'h0000_0100, "higher level preempts");
        apply(1, 1, 0, 5'd3, 8'd0,  8'd0,  8'd0,  32'h0000_0100, "level 0 is never taken");
        apply(1, 1, 0, 5'd31,8'd255,8'd254,8'd254,32'hFFFF_FFFC, "max values");
        apply(1, 1, 1, 5'd3, 8'd200,8'd0,  8'd40, 32'h0000_0100, "PREEMPT_DIS: no preemption in a handler");
        apply(1, 1, 1, 5'd3, 8'd200,8'd0,  8'd0,  32'h0000_0100, "PREEMPT_DIS: taken at level 0");
        apply(1, 1, 1, 5'd3, 8'd10, 8'd10, 8'd0,  32'h0000_0100, "PREEMPT_DIS: threshold still strict");
        for (int n = 0; n < 5000; n++)
            apply($urandom_range(0,1), $urandom_range(0,1), $urandom_range(0,1), $urandom, $urandom,
                  $urandom, $urandom, $urandom & 32'hFFFF_FFFC, "random");
        for (int n = 0; n < 5000; n++) begin
            l = $urandom;
            a = ($urandom_range(0,3) == 0) ? 8'd0 : near(l);   // a quarter at level 0 (no handler)
            apply(1, $urandom_range(0,7) != 0, $urandom_range(0,1), $urandom, l, near(l), a,
                  $urandom & 32'hFFFF_FFFC, "boundary");
        end

        // ELEM-7: every relation (below / EQUAL / above) of both compares, and
        // PREEMPT_DIS in and out of a handler, was applied while it decided the take
        unused = 0;
        foreach (n_rel_t[k]) begin
            chk(n_rel_t[k] > 0, $sformatf("coverage: level vs mintthresh relation %0d never applied", k), unused);
            chk(n_rel_a[k] > 0, $sformatf("coverage: level vs mil relation %0d never applied", k), unused);
        end
        chk(n_pdis_handler > 0, "coverage: PREEMPT_DIS never blocked a preemption", unused);
        chk(n_pdis_level0  > 0, "coverage: PREEMPT_DIS never seen at level 0", unused);
        $display(" COVERAGE: thresh below/equal/above = %0d/%0d/%0d  mil below/equal/above = %0d/%0d/%0d  pdis handler/level0 = %0d/%0d  cg_clic = %0.1f%%",
                 n_rel_t[0], n_rel_t[1], n_rel_t[2], n_rel_a[0], n_rel_a[1], n_rel_a[2],
                 n_pdis_handler, n_pdis_level0, cg.get_coverage());
        $display(" RESULT: %s  (%0d checks, %0d failed)", fail ? "FAILED" : "PASSED", pass + fail, fail);
        $finish;
    end
endmodule
