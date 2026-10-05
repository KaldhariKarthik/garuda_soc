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
module clk_div_sva (
    input wire       refclk_i,
    input wire       raw_rst_n_i,
    input wire [1:0] div_sel_i,
    input wire       hclk_o, pclk_o, pclk_phase_o,
    input wire [1:0] div_act_o,
    input wire       div_busy_o
);
    // ---- the reference period, measured -----------------------------------
    realtime t_ref_rise = 0, t_ref = 0;
    always @(posedge refclk_i) begin
        if (t_ref_rise != 0) t_ref = $realtime - t_ref_rise;
        t_ref_rise = $realtime;
    end

    // ---- F09, F13, F14: every half period of hclk is the selected ratio; never shorter
    //      than the fastest ratio's, whatever is being changed ---------------
    realtime t_hclk = 0, t_hclk_rise = 0, w;
    integer  settled = 0;                       // hclk half periods since the ratio last changed
    reg [1:0] act_prev = 2'b00;
    always @(hclk_o) if (raw_rst_n_i === 1'b1) begin
        if (t_hclk != 0 && t_ref != 0) begin
            w = $realtime - t_hclk;
            a_div_no_glitch: assert (w >= t_ref * 0.999)
                else $error("[SVA-FAIL] a_div_no_glitch: an hclk %s time of %0t, the reference period is %0t", hclk_o ? "low" : "high", w, t_ref);
            if (div_act_o == act_prev && !div_busy_o && settled >= 2)
                a_hclk_ratio: assert (w >= t_ref * (1 << div_act_o) * 0.999 && w <= t_ref * (1 << div_act_o) * 1.001)
                    else $error("[SVA-FAIL] a_hclk_ratio: hclk half period %0t with DIVACT %0d, expected %0t", w, div_act_o, t_ref * (1 << div_act_o));
        end
        settled  = (div_act_o == act_prev && !div_busy_o) ? settled + 1 : 0;
        act_prev = div_act_o;
        t_hclk   = $realtime;
        if (hclk_o) t_hclk_rise = $realtime;
    end
    always @(negedge raw_rst_n_i) begin t_hclk = 0; settled = 0; end

    // ---- F11: pclk never changes except with an hclk rising edge -----------
    realtime t_pclk = 0;
    always @(pclk_o) if (raw_rst_n_i === 1'b1) begin
        a_pclk_subset_hclk: assert ($realtime == t_hclk_rise && hclk_o === 1'b1)
            else $error("[SVA-FAIL] a_pclk_subset_hclk: pclk changed at %0t, the last hclk rise was at %0t", $realtime, t_hclk_rise);
        if (t_pclk != 0 && t_ref != 0)
            a_pclk_no_glitch: assert ($realtime - t_pclk >= 2 * t_ref * 0.999)
                else $error("[SVA-FAIL] a_pclk_no_glitch: a pclk %s time of %0t", pclk_o ? "low" : "high", $realtime - t_pclk);
        t_pclk = $realtime;
    end
    always @(negedge raw_rst_n_i) t_pclk = 0;

    // ---- F10: pclk toggles on every hclk rising edge ----------------------------
    a_pclk_ratio: assert property (@(posedge hclk_o) disable iff (!raw_rst_n_i)
        raw_rst_n_i |=> (pclk_o != $past(pclk_o)))
        else $error("[SVA-FAIL] a_pclk_ratio");
    // ---- F12: pclk_phase is 1 exactly in the hclk cycle that ends with a pclk rise --
    a_pclk_phase: assert property (@(posedge hclk_o) disable iff (!raw_rst_n_i)
        raw_rst_n_i |=> (pclk_o == $past(pclk_phase_o)))
        else $error("[SVA-FAIL] a_pclk_phase");
    // ---- F14: a requested ratio is in effect within one full count of the dividers,
    //      and DIVBUSY is up until then ---------------------------------------------
    a_div_takes_effect: assert property (@(posedge refclk_i) disable iff (!raw_rst_n_i)
        (raw_rst_n_i && div_act_o != div_sel_i) |-> ##[1:40] (div_act_o == div_sel_i || $changed(div_sel_i)))
        else $error("[SVA-FAIL] a_div_takes_effect: DIVSEL %0d not in effect after 40 reference cycles", div_sel_i);
    a_div_busy: assert property (@(posedge refclk_i) disable iff (!raw_rst_n_i)
        (div_act_o != div_sel_i) |-> div_busy_o)
        else $error("[SVA-FAIL] a_div_busy: a change is pending and DIVBUSY is 0");
    // ---- F16: the divider runs as soon as the raw reset is released --------------------
    a_div_runs_in_reset: assert property (@(posedge refclk_i)
        $rose(raw_rst_n_i) |-> ##[1:10] $changed(hclk_o))
        else $error("[SVA-FAIL] a_div_runs_in_reset");

    c_ratio_2:  cover property (@(posedge refclk_i) raw_rst_n_i && div_act_o == 2'd0);
    c_ratio_4:  cover property (@(posedge refclk_i) raw_rst_n_i && div_act_o == 2'd1);
    c_ratio_8:  cover property (@(posedge refclk_i) raw_rst_n_i && div_act_o == 2'd2);
    c_ratio_16: cover property (@(posedge refclk_i) raw_rst_n_i && div_act_o == 2'd3);
    c_busy:     cover property (@(posedge refclk_i) raw_rst_n_i && div_busy_o);
endmodule

bind clk_div clk_div_sva u_clk_div_sva (.*);
`endif
