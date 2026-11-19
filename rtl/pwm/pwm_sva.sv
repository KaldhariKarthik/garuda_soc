`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 20 : properties for the PWM
// pwm_sva.sv
//
// Spec: GARUDA-PWM-SPEC-001. Plan: tb/pwm/GARUDA_PWM_vplan.csv; each property
// names its feature. Bound to garuda_pwm_top, so the properties run in the block
// bench, in the UVM environment and in every chip simulation. The interrupt
// and register-port properties are those of the shared shim
// (rtl/common/garuda_apb_shim_sva.sv). Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
// Icarus Verilog does not parse concurrent assertions; under it this file is
// empty and the block is simulated without its properties (TOOL-B2).
module pwm_sva (
    input wire        pclk,
    input wire        preset_n,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire [3:0]  pwm_o,
    input wire        en_q,
    input wire [3:0]  ch_en_q,
    input wire [15:0] period_q,
    input wire [15:0] prescale_q,
    input wire [15:0] pre_q,
    input wire [15:0] cnt_q,
    input wire [15:0] duty_s0, duty_s1, duty_s2, duty_s3,
    input wire        wrap,
    input wire [31:0] prdata_o
);
    // packed, not an unpacked array: Verilator 5 cannot take $stable() of an
    // unpacked-array element (TOOL-B2)
    wire [3:0][15:0] duty_s;
    assign duty_s[0] = duty_s0; assign duty_s[1] = duty_s1;
    assign duty_s[2] = duty_s2; assign duty_s[3] = duty_s3;

    genvar c;
    generate for (c = 0; c < 4; c = c + 1) begin : g_ch
        // ---- PWM-2: the pin is a flop: last cycle's enables and compare, nothing else
        a_pin_registered: assert property (@(posedge pclk) disable iff (!preset_n)
            preset_n |=> (pwm_o[c] == $past(en_q && ch_en_q[c] && (cnt_q < duty_s[c]))))
            else $error("[SVA-FAIL] a_pin_registered: channel %0d", c);
        // ---- F18, F19: low beats everything: at once in reset, one clock after an enable drops
        a_low_in_reset: assert property (@(posedge pclk) !preset_n |-> !pwm_o[c])
            else $error("[SVA-FAIL] a_low_in_reset: channel %0d high in reset", c);
        a_low_when_off: assert property (@(posedge pclk) disable iff (!preset_n)
            (preset_n && (!en_q || !ch_en_q[c])) |=> !pwm_o[c])
            else $error("[SVA-FAIL] a_low_when_off: channel %0d high one clock after it was turned off", c);
        // ---- F11: a channel whose duty is 0 is never high -----------------------
        a_duty0_low: assert property (@(posedge pclk) disable iff (!preset_n)
            (preset_n && duty_s[c] == 16'd0) |=> !pwm_o[c])
            else $error("[SVA-FAIL] a_duty0_low: channel %0d", c);
        // ---- F11: at 100 percent the line does not drop at the frame boundary --
        a_duty_full_high: assert property (@(posedge pclk) disable iff (!preset_n)
            // the counter is below the duty at the boundary (not so when PERIOD was
            // lowered under a running frame), so the pin is high going into it
            (preset_n && en_q && ch_en_q[c] && wrap && duty_s[c] == period_q && period_q != 16'd0 && cnt_q < duty_s[c])
            |=> ((!en_q || !ch_en_q[c] || duty_s[c] == 16'd0) or (pwm_o[c] ##1 pwm_o[c])))
            else $error("[SVA-FAIL] a_duty_full_high: channel %0d dropped at the boundary", c);
        // ---- F15: the shadow moves only at the boundary (or while stopped) -----
        a_shadow_only_at_boundary: assert property (@(posedge pclk) disable iff (!preset_n)
            (preset_n && en_q && !wrap) |=> $stable(duty_s[c]))
            else $error("[SVA-FAIL] a_shadow_only_at_boundary: channel %0d", c);
        // ---- F21: what is loaded never exceeds the period it was loaded with ---
        a_clamp: assert property (@(posedge pclk) disable iff (!preset_n)
            (preset_n && (wrap || !en_q)) |=> (duty_s[c] <= $past(period_q)))
            else $error("[SVA-FAIL] a_clamp: channel %0d shadow above PERIOD", c);
        // ---- F13: a rise made by the counter is a rise of every running channel.
        //      The pin shows the compare of the cycle before, so "made by the
        //      counter" is: the channel was already enabled two cycles ago.
        a_aligned: assert property (@(posedge pclk) disable iff (!preset_n)
            (preset_n && $rose(pwm_o[c]) && $past(en_q && ch_en_q[c], 2) && $past(preset_n, 2)) |->
                ((!$past(ch_en_q[0]) || $past(duty_s[0]) == 0 || pwm_o[0]) && (!$past(ch_en_q[1]) || $past(duty_s[1]) == 0 || pwm_o[1]) &&
                 (!$past(ch_en_q[2]) || $past(duty_s[2]) == 0 || pwm_o[2]) && (!$past(ch_en_q[3]) || $past(duty_s[3]) == 0 || pwm_o[3])))
            else $error("[SVA-FAIL] a_aligned: channel %0d rose alone", c);
        c_rise:  cover property (@(posedge pclk) preset_n && $rose(pwm_o[c]));
        c_full:  cover property (@(posedge pclk) preset_n && en_q && ch_en_q[c] && wrap && pwm_o[c] && duty_s[c] == period_q && period_q != 0);
        c_cut:   cover property (@(posedge pclk) preset_n && $fell(pwm_o[c]) && !$past(en_q));
    end endgenerate

    // ---- F14: a counter below PERIOD stays below it while PERIOD does not change
    a_counter_bound: assert property (@(posedge pclk) disable iff (!preset_n)
        (preset_n && cnt_q < period_q) |=> (cnt_q < period_q || period_q != $past(period_q)))
        else $error("[SVA-FAIL] a_counter_bound: cnt=%0d period=%0d", cnt_q, period_q);
    // ---- F17: the time base never stalls - a prescaler that has reached or
    //      passed PRESCALE starts a new tick in the next cycle (erratum PWM-4)
    a_tick_no_stall: assert property (@(posedge pclk) disable iff (!preset_n)
        (preset_n && en_q && pre_q >= prescale_q) |=> (pre_q == 16'd0))
        else $error("[SVA-FAIL] a_tick_no_stall: prescaler %0d past PRESCALE %0d", pre_q, prescale_q);
    // ---- F20: stopped means the counter is at 0, so a restart begins a frame --
    a_stopped_at_zero: assert property (@(posedge pclk) disable iff (!preset_n)
        (preset_n && !en_q) |=> (cnt_q == 16'd0))
        else $error("[SVA-FAIL] a_stopped_at_zero");
    // ---- F06 (D-39): no DMA channel; DMACTL reads 0 and keeps no write ------
    a_dmactl_zero: assert property (@(posedge pclk) disable iff (!preset_n)
        (psel_i && penable_i && !pwrite_i && paddr_i == 12'hFE8) |-> (prdata_o == 32'd0))
        else $error("[SVA-FAIL] a_dmactl_zero");

    c_wrap:      cover property (@(posedge pclk) preset_n && wrap);
    c_prescale_lowered: cover property (@(posedge pclk) preset_n && en_q && pre_q > prescale_q);
    c_period_0:  cover property (@(posedge pclk) preset_n && en_q && period_q == 16'd0);
endmodule

bind garuda_pwm_top pwm_sva u_pwm_sva (
    .pclk(pclk), .preset_n(preset_n), .pwm_o(pwm_o),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .en_q(en_q), .ch_en_q(ch_en_q), .period_q(period_q), .prescale_q(prescale_q), .pre_q(u_core.pre_q),
    .cnt_q(u_core.cnt_q),
    .duty_s0(u_core.duty_s[0]), .duty_s1(u_core.duty_s[1]),
    .duty_s2(u_core.duty_s[2]), .duty_s3(u_core.duty_s[3]),
    .wrap(wrap), .prdata_o(prdata_o));
`endif
`endif
