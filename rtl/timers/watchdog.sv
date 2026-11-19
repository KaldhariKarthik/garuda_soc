// =============================================================================
// GARUDA SoC - Block 11 : watchdog
// watchdog.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 Sec.6.2-Sec.6.4, Sec.7.5-Sec.7.7, Sec.9
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

module watchdog
    import garuda_pkg::*;
(
    input wire hclk,
    input wire hreset_n,
    input wire ext_hrst_n,  // ext-only reset (reset_ctrl.ext_hrst_n)
    input wire wr_ctl_i,
    input wire wr_load_i,
    input wire wr_kick_i,
    input wire wr_warn_i,
    input wire [WORD_W-1:0] wdata_i,
    output wire [WDT_CTL_W-1:0] ctl_o,
    output wire [WORD_W-1:0] load_o,
    output wire [WORD_W-1:0] val_o,
    output wire [WORD_W-1:0] warn_o,
    output wire warn_irq_o,  // CLIC ID 22
    // to reset_ctrl
    output reg rst_req_o
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam [31:0] KICK_MAGIC = 32'h5A5A_C3C3;

    reg en_q;
    reg warnen_q;
    reg [WORD_W-1:0] load_q;
    reg [WORD_W-1:0] warn_q;
    reg [WORD_W-1:0] ctr_q;

    wire kick = wr_kick_i && (wdata_i == KICK_MAGIC);

    always_ff @(posedge hclk or negedge hreset_n) begin : p_en
        if (!hreset_n) begin
            en_q <= 1'b0;
            warnen_q <= 1'b0;
            load_q <= 32'hFFFF_FFFF;
            warn_q <= 32'd0;
            ctr_q <= 32'hFFFF_FFFF;
        end else begin
            if (wr_ctl_i) begin
                if (wdata_i[0]) begin
                    en_q <= 1'b1;  // RW1S, sticky
                end
                warnen_q <= wdata_i[1];
            end
            if (wr_load_i) begin
                load_q <= wdata_i;
            end
            if (wr_warn_i) begin
                warn_q <= wdata_i;
            end
            if (!en_q) begin
                ctr_q <= load_q;  // idle: tracks WDTLOAD
            end else if (kick) begin
                ctr_q <= load_q;
            end else if (ctr_q != 0) begin
                ctr_q <= ctr_q - 32'd1;
            end
        end
    end

    // reset request: ext-only domain, cleared once the system reset is in force
    always_ff @(posedge hclk or negedge ext_hrst_n) begin : p_rst_req
        if (!ext_hrst_n) begin
            rst_req_o <= 1'b0;
        end else if (!hreset_n) begin
            rst_req_o <= 1'b0;
        end else if (en_q && ~|ctr_q) begin
            rst_req_o <= 1'b1;
        end
    end

    assign warn_irq_o = en_q && warnen_q && (ctr_q <= warn_q);

    assign ctl_o  = {warnen_q, en_q};
    assign load_o = load_q;
    assign val_o  = ctr_q;
    assign warn_o = warn_q;

endmodule
