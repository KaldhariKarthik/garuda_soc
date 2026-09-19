`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 11 : watchdog
// wdt.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 §6.2-§6.4, §7.5-§7.7, §9
//
//   WDTCTL.EN      RW1S, sticky, cleared only by reset ([N-6.2])
//   WDTCTL.WARNEN  RW
//   WDTLOAD        reload value, takes effect at the next kick ([N-7.18])
//   WDTKICK        0x5A5A_C3C3 reloads; any other value ignored ([N-6.4])
//   WDTVAL         down counter; reads WDTLOAD while EN is clear ([N-7.17])
//   warn           WARNEN & EN & (WDTVAL <= WDTWARN), level, held until a kick
//                  or WARNEN is cleared (DECISIONS D-17 - the spec's
//                  "== WDTWARN" is a one-hclk level a CLIC take can miss)
//
// THE RESET REQUEST FLOP ([N-7.19]..[N-7.21], ADR-0003)
//   It sits in the ext_rst_n domain: hreset_n (which this request causes) does
//   not reset it, so it cannot cancel itself into a runt pulse. It is cleared
//   synchronously once hreset_n is observed asserted - by then reset_ctrl's
//   stretch counter has captured the request and holds the reset for its full
//   length regardless of this flop. hclk keeps running during reset (the
//   divider is reset only by the pin), so the clear always happens.
//   The counter keeps running while the core is held in hartreset ([N-7.23]).
// =============================================================================

module wdt (
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        ext_rst_n_i,     // ext-only reset (reset_ctrl.ext_hrst_n_o)

    input  wire        wr_ctl_i,
    input  wire        wr_load_i,
    input  wire        wr_kick_i,
    input  wire        wr_warn_i,
    input  wire [31:0] wdata_i,

    output wire [31:0] ctl_o,
    output wire [31:0] load_o,
    output wire [31:0] val_o,
    output wire [31:0] warn_o,

    output wire        warn_irq_o,      // CLIC ID 22
    output reg         rst_req_o        // to reset_ctrl
);

    localparam [31:0] KICK_MAGIC = 32'h5A5A_C3C3;

    reg        en_q, warnen_q;
    reg [31:0] load_q, warn_q, ctr_q;

    wire kick = wr_kick_i && (wdata_i == KICK_MAGIC);

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            en_q     <= 1'b0;
            warnen_q <= 1'b0;
            load_q   <= 32'hFFFF_FFFF;
            warn_q   <= 32'd0;
            ctr_q    <= 32'hFFFF_FFFF;
        end else begin
            if (wr_ctl_i) begin
                if (wdata_i[0]) en_q <= 1'b1;             // RW1S, sticky
                warnen_q <= wdata_i[1];
            end
            if (wr_load_i) load_q <= wdata_i;
            if (wr_warn_i) warn_q <= wdata_i;

            if (!en_q)             ctr_q <= load_q;       // idle: tracks WDTLOAD
            else if (kick)         ctr_q <= load_q;
            else if (ctr_q != 0)   ctr_q <= ctr_q - 32'd1;
        end
    end

    // reset request: ext-only domain, cleared once the system reset is in force
    always @(posedge hclk_i or negedge ext_rst_n_i) begin
        if (!ext_rst_n_i)     rst_req_o <= 1'b0;
        else if (!hreset_n_i) rst_req_o <= 1'b0;
        else if (en_q && ctr_q == 32'd0) rst_req_o <= 1'b1;
    end

    assign warn_irq_o = en_q && warnen_q && (ctr_q <= warn_q);

    assign ctl_o  = {30'd0, warnen_q, en_q};
    assign load_o = load_q;
    assign val_o  = ctr_q;
    assign warn_o = warn_q;

endmodule

`default_nettype wire
