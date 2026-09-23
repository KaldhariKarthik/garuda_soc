`timescale 1ns/1ps
`default_nettype none
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
//   3. LOW BEATS EVERYTHING. Reset, !en, or a disabled channel forces the
//      output low combinationally. An ESC reads a low line as "no signal" and
//      holds the motor stopped, which is the state we want on every fault
//      path including a half-configured block.
// =============================================================================

module garuda_pwm_core #(
    parameter integer NCH = 4
)(
    input  wire              clk_i,
    input  wire              rst_n_i,

    input  wire              en_i,          // global run
    input  wire [NCH-1:0]    ch_en_i,       // per-channel output enable
    input  wire [15:0]       prescale_i,    // tick = clk / (prescale + 1)
    input  wire [15:0]       period_i,      // ticks per frame
    input  wire [NCH*16-1:0] duty_i,        // ticks high, per channel

    output wire [NCH-1:0]    pwm_o,
    output wire              wrap_o,        // period boundary: shadows loaded
    output wire [NCH-1:0]    clamp_o,       // this channel's duty exceeded period
    output wire [15:0]       count_o
);

    // ---- prescaler ------------------------------------------------------------
    reg [15:0] pre_q;
    wire       tick = en_i & (pre_q == prescale_i);

    always @(posedge clk_i or negedge rst_n_i)
        if (!rst_n_i)      pre_q <= 16'd0;
        else if (!en_i)    pre_q <= 16'd0;
        else if (tick)     pre_q <= 16'd0;
        else               pre_q <= pre_q + 16'd1;

    // ---- period counter ---------------------------------------------------------
    reg [15:0] cnt_q;
    wire       at_end = (cnt_q + 16'd1) >= period_i;
    wire       wrap   = tick & at_end;

    always @(posedge clk_i or negedge rst_n_i)
        if (!rst_n_i)   cnt_q <= 16'd0;
        else if (!en_i) cnt_q <= 16'd0;
        else if (tick)  cnt_q <= at_end ? 16'd0 : (cnt_q + 16'd1);

    assign wrap_o  = wrap;
    assign count_o = cnt_q;

    // ---- shadow registers, loaded only at the boundary ---------------------------
    // A duty wider than the period would hold the line high across the wrap and
    // look to an ESC like a continuous signal, so it is clamped to the period
    // (100% duty) and reported. Clamping rather than ignoring keeps the output
    // defined for every register value that can be written.
    genvar c;
    reg  [15:0] duty_s [0:NCH-1];
    reg  [NCH-1:0] clamp_q;

    generate for (c = 0; c < NCH; c = c + 1) begin : g_ch
        wire [15:0] duty_in = duty_i[16*c +: 16];
        wire        over    = (duty_in > period_i);

        always @(posedge clk_i or negedge rst_n_i)
            if (!rst_n_i) begin
                duty_s[c]  <= 16'd0;
                clamp_q[c] <= 1'b0;
            end else if (wrap || !en_i) begin
                duty_s[c]  <= over ? period_i : duty_in;
                clamp_q[c] <= over;
            end

        // Low beats everything: no enable, no output. Combinational so that
        // clearing CTRL.EN stops the motors in the same cycle rather than at
        // the end of the frame.
        assign pwm_o[c] = en_i & ch_en_i[c] & (cnt_q < duty_s[c]);
    end endgenerate

    assign clamp_o = clamp_q;

endmodule

`default_nettype wire
