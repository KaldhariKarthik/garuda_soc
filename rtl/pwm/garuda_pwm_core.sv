// =============================================================================
// GARUDA SoC - Block 20 : PWM timing core
// garuda_pwm_core.v - counter, compare, double buffer. No bus interface.
//
// Spec: GARUDA-PWM-SPEC-001 Rev 1.0.
//
// This is the one peripheral GARUDA writes rather than adapts. PULP's only
// option is apb_adv_timer - four timers, four channels each, an event unit and
// a capture/trigger matrix - and the verification cost dominates the design
// cost: for a general-purpose timer you must prove that no register
// combination can glitch an ESC output, whereas for a counter-compare the
// argument is exhaustive and fits on a page (D-22).
//
// What drives that argument:
//
//   1. ONE counter, FOUR comparators. The four outputs cannot drift apart or
//      race each other because there is only one time base. Their edges are
//      aligned by construction, not by configuration.
//
//   2. DOUBLE BUFFERING. Duty values are captured into shadow registers only
//      at the period boundary, so a firmware write that lands mid-pulse can
//      never shorten the pulse already in progress. Writing 1.9 ms while a
//      1.1 ms pulse is out produces a clean 1.1 ms pulse and then a clean
//      1.9 ms one - never a runt.
//
//   3. LOW BEATS EVERYTHING. Reset forces the outputs low at once (asynchronous
//      clear of the output flops); !en or a disabled channel forces them low
//      at the next clock edge. An ESC reads a low line as "no signal" and
//      holds the motor stopped, which is the state we want on every fault
//      path including a half-configured block.
//
//   4. EVERY PIN IS A FLOP OUTPUT (erratum PWM-2, 2026-10-13). The pins were
//      the AND of two register bits and a magnitude compare. A CTRL write that
//      turned EN on and a channel off on the same edge gave a zero-width pulse
//      in an event-driven simulation, and in silicon the two flops have
//      different clock-to-Q and the comparator can glitch while the counter
//      changes. A glitch on a motor output is what this block exists to make
//      impossible, so the same expression is now registered: the waveform is
//      the one it was, one clock later, and "low" takes one clock (8 ns at
//      125 MHz) instead of none.
// =============================================================================

module garuda_pwm_core
    import garuda_pkg::*;
#(
    parameter integer NUM_CHAN = 32'd4
)(
    input wire pclk,
    input wire preset_n,
    input wire en_i,  // global run
    input wire [NUM_CHAN - 1:0] ch_en_i,  // per-channel output enable
    input wire [HALF_W-1:0] prescale_i,  // tick = clk / (prescale + 1)
    input wire [HALF_W-1:0] period_i,  // ticks per frame
    input wire [NUM_CHAN * DUTY_W - 1:0] duty_i,  // ticks high, per channel
    output wire [NUM_CHAN - 1:0] pwm_o,
    output wire wrap_o,  // period boundary: shadows loaded
    // this channel's duty exceeded period
    output wire [NUM_CHAN - 1:0] clamp_o,
    output wire [HALF_W-1:0] count_o
);
    timeunit 1ns;
    timeprecision 1ps;

    // ---- prescaler ----------------------------------------------------------
    // ERRATUM PWM-4 (2026-10-05, found by the UVM scoreboard's measured high
    // time, check sb_no_stuck_high). The compare was `==`. A PRESCALE written
    // below the running count was then never matched: the prescaler counted on
    // to 0xFFFF and round, 65,536 pclk without a tick, with the frame counter
    // frozen and every pin held as it was - a pin that was high stayed high
    // for up to 0.5 ms. [N-7.1a] tells firmware not to change PRESCALE while
    // running, but a stretched pulse on a motor output is exactly what this
    // block exists to make impossible. With `>=` the tick in progress ends in
    // the next cycle instead, the same hardening the period compare got in
    // PWM-1.
    reg [HALF_W-1:0] pre_q;
    wire       tick = en_i & (pre_q >= prescale_i);

    always_ff @(posedge pclk or negedge preset_n) begin : p_pre
        if (!preset_n) begin
            pre_q <= 16'd0;
        end else if (!en_i) begin
            pre_q <= 16'd0;
        end else if (tick) begin
            pre_q <= 16'd0;
        end else begin
            pre_q <= pre_q + 16'd1;
        end
    end

    // ---- period counter -----------------------------------------------------
    reg [HALF_W-1:0] cnt_q;
    // 17-bit compare: cnt_q + 1 must not wrap to 0 and read as "below period"
    wire       at_end = ({1'b0, cnt_q} + 17'd1) >= {1'b0, period_i};
    wire       wrap   = tick & at_end;

    always_ff @(posedge pclk or negedge preset_n) begin : p_cnt
        if (!preset_n) begin
            cnt_q <= 16'd0;
        end else if (!en_i) begin
            cnt_q <= 16'd0;
        end else if (tick) begin
            cnt_q <= at_end ? 16'd0 : (cnt_q + 16'd1);
        end
    end

    assign wrap_o  = wrap;
    assign count_o = cnt_q;

    // ---- shadow registers, loaded only at the boundary ----------------------
    // A duty wider than the period would hold the line high across the wrap and
    // look to an ESC like a continuous signal, so it is clamped to the period
    // (100% duty) and reported. Clamping rather than ignoring keeps the output
    // defined for every register value that can be written.
    genvar c;
    reg  [DUTY_W-1:0] duty_s [0:NUM_CHAN-1];
    reg  [NUM_CHAN-1:0] clamp_q;
    reg  [NUM_CHAN-1:0] pwm_q;

    generate for (c = 0; c < NUM_CHAN; c = c + 1) begin : g_ch
        wire [DUTY_W-1:0] duty_in = duty_i[16*c +: 16];
        wire        over    = (duty_in > period_i);

        always_ff @(posedge pclk or negedge preset_n) begin : p_duty_s
            if (!preset_n) begin
                duty_s[c] <= 16'd0;
                clamp_q[c] <= 1'b0;
            end else if (wrap || !en_i) begin
                duty_s[c] <= over ? period_i : duty_in;
                clamp_q[c] <= over;
            end
        end

        // Low beats everything: no enable, no output, at the next edge and
        // not at the end of the frame. Registered, so the pin cannot glitch
        // (PWM-2); reset clears it asynchronously.
        always_ff @(posedge pclk or negedge preset_n) begin : p_pwm
            if (!preset_n) begin
                pwm_q[c] <= 1'b0;
            end else begin
                pwm_q[c] <= en_i & ch_en_i[c] & (cnt_q < duty_s[c]);
            end
        end
    end endgenerate

    assign pwm_o = pwm_q;

    assign clamp_o = clamp_q;

endmodule
