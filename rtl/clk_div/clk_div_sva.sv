`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 22 : properties for the clock divider
// clk_div_sva.sv
//
// Spec: GARUDA-CLKRST-SPEC-001 section 7.1 to 7.3. Plan:
// tb/clk_div/GARUDA_CLKRST_vplan.csv; each property names its feature. Bound to
// clk_div, so the properties run in the block bench, in the UVM environment and
// in every chip simulation. Several of them are about time, not cycles (a
// clock's width, two edges at the same instant), and are written with
// $realtime. Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
// Icarus Verilog does not parse concurrent assertions; under it this file is
// empty and the block is simulated without its properties (TOOL-B2).
module clk_div_sva (
    input wire       refclk,
    input wire       ext_rst_n,
    input wire [1:0] div_sel_i,
    input wire       hclk, pclk, pclk_phase_o,
    input wire [1:0] div_act_o,
    input wire       div_busy_o
);
    // ---- the reference period, measured -----------------------------------
    realtime t_ref_rise = 0, t_ref = 0;
    always @(posedge refclk) begin
        if (t_ref_rise != 0) t_ref = $realtime - t_ref_rise;
        t_ref_rise = $realtime;
    end

    // ---- F09, F13, F14: every half period of hclk is the selected ratio; never shorter
    //      than the fastest ratio's, whatever is being changed ---------------
    realtime t_hclk = 0, t_hclk_rise = 0, w;
    integer  settled = 0;                       // hclk half periods since the ratio last changed
    reg [1:0] act_prev = 2'b00;
    always @(hclk) if (ext_rst_n === 1'b1) begin
        if (t_hclk != 0 && t_ref != 0) begin
            w = $realtime - t_hclk;
            a_div_no_glitch: assert (w >= t_ref * 0.999)
                else $error("[SVA-FAIL] a_div_no_glitch: an hclk %s time of %0t, the reference period is %0t", hclk ? "low" : "high", w, t_ref);
            if (div_act_o == act_prev && !div_busy_o && settled >= 2)
                a_hclk_ratio: assert (w >= t_ref * (1 << div_act_o) * 0.999 && w <= t_ref * (1 << div_act_o) * 1.001)
                    else $error("[SVA-FAIL] a_hclk_ratio: hclk half period %0t with DIVACT %0d, expected %0t", w, div_act_o, t_ref * (1 << div_act_o));
        end
        settled  = (div_act_o == act_prev && !div_busy_o) ? settled + 1 : 0;
        act_prev = div_act_o;
        t_hclk   = $realtime;
        if (hclk) t_hclk_rise = $realtime;
    end
    always @(negedge ext_rst_n) begin t_hclk = 0; settled = 0; end

    // ---- F11: pclk never changes except with an hclk rising edge -----------
    realtime t_pclk = 0;
    // TB-34: not at time 0. A two-state simulator (Verilator) gives pclk_q its
    // initial value as a change at time 0, which is initialisation, not an
    // edge; Xcelium's X-to-value transition there happens not to fire this.
    // SIM-1: pclk now changes in the same simulation step as hclk rises, and the
    // process that records the hclk rise may run after this one. The two times
    // are therefore compared one picosecond later, when both are recorded.
    realtime t_pchg = 0;
    always @(pclk) if (ext_rst_n === 1'b1 && $realtime != 0) begin
        t_pchg = $realtime;
        if (t_pclk != 0 && t_ref != 0)
            a_pclk_no_glitch: assert (t_pchg - t_pclk >= 2 * t_ref * 0.999)
                else $error("[SVA-FAIL] a_pclk_no_glitch: a pclk %s time of %0t", pclk ? "low" : "high", t_pchg - t_pclk);
        t_pclk = t_pchg;
        #0.001;
        // (not when the reset pin fell in that picosecond: the dividers are then cleared)
        if (ext_rst_n === 1'b1)
        a_pclk_subset_hclk: assert (t_pchg == t_hclk_rise && hclk === 1'b1)
            else $error("[SVA-FAIL] a_pclk_subset_hclk: pclk changed at %0t, the last hclk rise was at %0t", t_pchg, t_hclk_rise);
    end
    always @(negedge ext_rst_n) t_pclk = 0;

    // TB-A5 (ruling D-32, 2026-11-04): hclk stops while the raw reset is low, and a
    // simulator that tests disable iff only on a clock tick (Verilator) judged an attempt
    // begun before a warm reset after it. hclk_seen counts the rises since the reset;
    // the two properties below skip the first one.
    reg [1:0] hclk_seen;
    always @(posedge hclk or negedge ext_rst_n)
        if (!ext_rst_n)            hclk_seen <= 2'd0;
        else if (hclk_seen != 2'd2)  hclk_seen <= hclk_seen + 2'd1;

    // ---- F10: pclk toggles on every hclk rising edge ----------------------------
    a_pclk_ratio: assert property (@(posedge hclk) disable iff (!ext_rst_n)
        (ext_rst_n && hclk_seen != 2'd0) |=> (pclk != $past(pclk)))
        else $error("[SVA-FAIL] a_pclk_ratio");
    // ---- F12: pclk_phase is 1 exactly in the hclk cycle that ends with a pclk rise --
    // Checked at the hclk FALLING edge (track A, 2026-10-15, for track B's OK): since SIM-1
    // pclk changes by a blocking assignment on the hclk rise itself, and Verilator 5.052
    // may evaluate a property clocked on that rise after the update (no preponed sampling
    // of a value written in the same step): the former form
    //     @(posedge hclk) ext_rst_n |=> (pclk == $past(pclk_phase_o))
    // failed on every cycle in tb_apb_env, tb_apb_probe and tb_ahb2apb (not in tb_chip).
    // Between edges pclk_phase is ~pclk (see clk_div.v), which is the same statement: the
    // cycle with pclk low is the one that ends with a pclk rise. Nothing changes on a fall.
    a_pclk_phase: assert property (@(negedge hclk) disable iff (!ext_rst_n)
        (hclk_seen == 2'd0) || (pclk_phase_o == !pclk))
        else $error("[SVA-FAIL] a_pclk_phase");
    // ---- F14: a requested ratio is in effect within one full count of the dividers,
    //      and DIVBUSY is up until then ---------------------------------------------
    a_div_takes_effect: assert property (@(posedge refclk) disable iff (!ext_rst_n)
        (ext_rst_n && div_act_o != div_sel_i) |-> ##[1:40] (div_act_o == div_sel_i || $changed(div_sel_i)))
        else $error("[SVA-FAIL] a_div_takes_effect: DIVSEL %0d not in effect after 40 reference cycles", div_sel_i);
    a_div_busy: assert property (@(posedge refclk) disable iff (!ext_rst_n)
        (div_act_o != div_sel_i) |-> div_busy_o)
        else $error("[SVA-FAIL] a_div_busy: a change is pending and DIVBUSY is 0");
    // ---- F16: the divider runs as soon as the raw reset is released --------------------
    a_div_runs_in_reset: assert property (@(posedge refclk)
        $rose(ext_rst_n) |-> ##[1:10] $changed(hclk))
        else $error("[SVA-FAIL] a_div_runs_in_reset");

    c_ratio_2:  cover property (@(posedge refclk) ext_rst_n && div_act_o == 2'd0);
    c_ratio_4:  cover property (@(posedge refclk) ext_rst_n && div_act_o == 2'd1);
    c_ratio_8:  cover property (@(posedge refclk) ext_rst_n && div_act_o == 2'd2);
    c_ratio_16: cover property (@(posedge refclk) ext_rst_n && div_act_o == 2'd3);
    c_busy:     cover property (@(posedge refclk) ext_rst_n && div_busy_o);
endmodule

bind clk_div clk_div_sva u_clk_div_sva (.*);
`endif
`endif
