`timescale 1ns/1ps
// =============================================================================
// tb_clic_ctrl.sv -- core element TB: clic_ctrl (take / wake / vector)
//
// Spec: GARUDA-CORE-SPEC-001 Rev 3.0 §7.5 [N-7.15], [N-7.16], [N-7.27];
//       GARUDA-CLIC-SPEC-001 §7.4; DECISIONS D-15.
// Rev 4.0 interface: {valid, id[4:0], level[7:0]} - no SHV, no acknowledge,
// every trap vectors to mtvec BASE. Replaces the Rev 1.1 element TB, whose
// SHV/ack checks no longer describe the hardware.
//
//   take   = valid & MIE & (level > mintthresh) & (level > mil)   (strict >)
//   wake   = valid                                                 (MIE-independent)
//   target = mtvec_i (csr_file already supplies BASE = {mtvec[31:2],2'b00})
// Directed boundary cases (equal level never preempts) plus 5000 random
// vectors against the reference expression. [PASS]/[FAIL] per check and a
// RESULT line, as the Makefile's run_tb_elem expects.
//
// Evidence that strict > was exercised (Docs/bugs/archive/BUGS_HISTORY.md ELEM-7): covergroup
// cg_lvl bins each compare as below / equal / above, crossed with take, for
// the coverage report; the same bins are also counted in plain code (Icarus
// has no covergroups) and the run FAILS if a discriminating case -- level
// equal to one bound while everything else would take -- was never applied.
// =============================================================================
module tb_top;
    logic        valid, mie;
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
        .mtvec_i(mtvec),
        .take_cond_o(take), .wake_cond_o(wake), .irq_id_o(id_o), .irq_lvl_o(lvl_o),
        .vector_target_o(target));

    int pass = 0, fail = 0;
    function automatic void chk(bit c, string what);
        if (c) begin pass++; end
        else begin fail++; $display("[FAIL] %s", what); end
    endfunction

    // ---- coverage of the two strict compares --------------------------------
    // 0 = level below the bound, 1 = equal, 2 = above. Only vectors with valid
    // and MIE set count: without them take is 0 whatever the compares say.
    function automatic int unsigned rel(logic [7:0] l, logic [7:0] b);
        return (l < b) ? 0 : (l == b) ? 1 : 2;
    endfunction
    int unsigned n_thr[3], n_mil[3];
    int unsigned n_eq_thr_only = 0;   // level == mintthresh, level > mil
    int unsigned n_eq_mil_only = 0;   // level == mil, level > mintthresh

`ifndef __ICARUS__
    covergroup cg_lvl with function sample(int unsigned thr, int unsigned act, bit tk);
        cp_lvl_vs_thresh: coverpoint thr { bins below = {0}; bins equal = {1}; bins above = {2}; }
        cp_lvl_vs_active: coverpoint act { bins below = {0}; bins equal = {1}; bins above = {2}; }
        cp_take:          coverpoint tk;
        // All nine below/equal/above pairs; take is checked on each by chk().
        x_thresh_active:  cross cp_lvl_vs_thresh, cp_lvl_vs_active;
    endgroup
    cg_lvl cg = new();
`endif

    function automatic void sample_cov(bit v, bit m, logic [7:0] l, logic [7:0] t,
                                       logic [7:0] a, bit tk);
        int unsigned rt, ra;
        if (!(v && m)) return;
        rt = rel(l, t);
        ra = rel(l, a);
        n_thr[rt]++;
        n_mil[ra]++;
        if (rt == 1 && ra == 2) n_eq_thr_only++;
        if (ra == 1 && rt == 2) n_eq_mil_only++;
`ifndef __ICARUS__
        cg.sample(rt, ra, tk);
`endif
    endfunction

    task automatic apply(bit v, bit m, logic [4:0] i, logic [7:0] l, logic [7:0] t,
                         logic [7:0] a, logic [31:0] vec, string tag);
        bit exp_take;
        int  fail0 = fail;
        valid = v; mie = m; id = i; level = l; thresh = t; mil = a; mtvec = vec;
        #1;
        exp_take = v && m && (l > t) && (l > a);
        sample_cov(v, m, l, t, a, take);
        chk(take === exp_take, $sformatf("%s: take=%0b exp %0b (v=%0b mie=%0b lvl=%0d thr=%0d mil=%0d)",
                                          tag, take, exp_take, v, m, l, t, a));
        chk(wake === v, $sformatf("%s: wake follows valid regardless of MIE", tag));
        chk(target === vec, $sformatf("%s: vector = mtvec BASE (passed through)", tag));
        chk(id_o === i && lvl_o === l, $sformatf("%s: id/level passed through", tag));
        if (fail == fail0) $display("[PASS] %s", tag);
    endtask

    initial begin
        apply(1, 1, 5'd3, 8'd10, 8'd0,  8'd0,  32'h0000_0100, "takeable");
        apply(0, 1, 5'd3, 8'd10, 8'd0,  8'd0,  32'h0000_0100, "no request");
        apply(1, 0, 5'd3, 8'd10, 8'd0,  8'd0,  32'h0000_0100, "MIE clear blocks take, not wake");
        apply(1, 1, 5'd3, 8'd10, 8'd10, 8'd0,  32'h0000_0100, "level == mintthresh does not take");
        apply(1, 1, 5'd3, 8'd11, 8'd10, 8'd0,  32'h0000_0100, "level > mintthresh takes");
        apply(1, 1, 5'd3, 8'd80, 8'd0,  8'd80, 32'h0000_0100, "equal level never preempts (mil)");
        apply(1, 1, 5'd3, 8'd81, 8'd0,  8'd80, 32'h0000_0100, "higher level preempts");
        apply(1, 1, 5'd3, 8'd0,  8'd0,  8'd0,  32'h0000_0100, "level 0 is never taken");
        apply(1, 1, 5'd31,8'd255,8'd254,8'd254,32'hFFFF_FFFC, "max values");
        for (int n = 0; n < 5000; n++)
            apply($urandom_range(0,1), $urandom_range(0,1), $urandom, $urandom, $urandom,
                  $urandom, $urandom & 32'hFFFF_FFFC, "random");
        // Random levels hit each equality about 5000/4/256 times; the
        // directed cases above hit both at least once whatever the seed.
        $display("  coverage: thresh below/equal/above = %0d/%0d/%0d, mil below/equal/above = %0d/%0d/%0d",
                 n_thr[0], n_thr[1], n_thr[2], n_mil[0], n_mil[1], n_mil[2]);
        $display("  coverage: equal to mintthresh only = %0d, equal to mil only = %0d",
                 n_eq_thr_only, n_eq_mil_only);
        for (int k = 0; k < 3; k++) begin
            chk(n_thr[k] > 0, $sformatf("coverage: level vs mintthresh bin %0d never hit", k));
            chk(n_mil[k] > 0, $sformatf("coverage: level vs mil bin %0d never hit", k));
        end
        chk(n_eq_thr_only > 0, "coverage: level == mintthresh with level > mil never applied");
        chk(n_eq_mil_only > 0, "coverage: level == mil with level > mintthresh never applied");
`ifndef __ICARUS__
        $display("  coverage: cg_lvl = %0.1f%%", cg.get_inst_coverage());
`endif
        $display(" RESULT: %s  (%0d checks, %0d failed)", fail ? "FAILED" : "PASSED", pass + fail, fail);
        $finish;
    end
endmodule
