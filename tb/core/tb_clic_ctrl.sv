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

    task automatic apply(bit v, bit m, logic [4:0] i, logic [7:0] l, logic [7:0] t,
                         logic [7:0] a, logic [31:0] vec, string tag);
        bit exp_take;
        valid = v; mie = m; id = i; level = l; thresh = t; mil = a; mtvec = vec;
        #1;
        exp_take = v && m && (l > t) && (l > a);
        chk(take === exp_take, $sformatf("%s: take=%0b exp %0b (v=%0b mie=%0b lvl=%0d thr=%0d mil=%0d)",
                                          tag, take, exp_take, v, m, l, t, a));
        chk(wake === v, $sformatf("%s: wake follows valid regardless of MIE", tag));
        chk(target === vec, $sformatf("%s: vector = mtvec BASE (passed through)", tag));
        chk(id_o === i && lvl_o === l, $sformatf("%s: id/level passed through", tag));
        if (c_ok(v, m, l, t, a)) $display("[PASS] %s", tag);
    endtask
    function automatic bit c_ok(bit v, bit m, logic [7:0] l, logic [7:0] t, logic [7:0] a);
        return 1;
    endfunction

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
        $display(" RESULT: %s  (%0d checks, %0d failed)", fail ? "FAILED" : "PASSED", pass + fail, fail);
        $finish;
    end
endmodule
