// =============================================================================
// GARUDA SoC - Block 11 : timers and watchdog
// timers_top.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 (Rev 4.0 set); ADR-0003, ADR-0010
//
// The machine timer reaches the core as ONE wire, mtip_o ([N-5.1], R4): the
// 64-bit compare lives here, not in the core. The watchdog's warning goes to
// CLIC ID 22 and its reset request to reset_ctrl. Both counters run on hclk
// and are never gated - they must keep counting while the core sleeps
// ([N-9.4]).
// =============================================================================

module timers_top
    import garuda_pkg::*;
(
    input wire hclk,
    input wire hreset_n,
    input wire ext_hrst_n,  // ext-only hclk reset for the WDT request
    input wire pclk,
    input wire preset_n,
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    output wire mtip_o,
    output wire wdt_warn_irq_o,
    output wire wdt_rst_req_o
);
    timeunit 1ns;
    timeprecision 1ps;

    wire wr_lo;
    wire wr_hi;
    wire wr_clo;
    wire wr_chi;
    wire rd_lo;
    wire wr_ctl;
    wire wr_load;
    wire wr_kick;
    wire wr_warn;
    // the APB write data, as it is (F4: timers_apb's copy of it was a
    // feedthrough); it is stable through the access
    wire [WORD_W-1:0] wdata = pwdata_i;
    wire [WORD_W-1:0] lo;
    wire [WORD_W-1:0] hi;
    wire [WDT_CTL_W-1:0] ctl;
    wire [WORD_W-1:0] load;
    wire [WORD_W-1:0] val;
    wire [WORD_W-1:0] warn;
    wire [DWORD_W-1:0] cmp;

    timers_apb u_apb (
        .hclk(hclk), .hreset_n(hreset_n),
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
            .paddr_i(paddr_i),
        .prdata_o(prdata_o), .pready_o(pready_o),
            .pslverr_o(pslverr_o),
        .wr_mtime_lo_o(wr_lo), .wr_mtime_hi_o(wr_hi), .wr_cmp_lo_o(wr_clo),
            .wr_cmp_hi_o(wr_chi),
        .rd_mtime_lo_o(rd_lo), .wr_wdtctl_o(wr_ctl), .wr_wdtload_o(wr_load),
        .wr_wdtkick_o(wr_kick), .wr_wdtwarn_o(wr_warn),
        .mtime_lo_i(lo), .mtime_hi_i(hi), .mtimecmp_i(cmp),
        .wdtctl_i(ctl), .wdtload_i(load), .wdtval_i(val), .wdtwarn_i(warn));

    mtime u_mtime (
        .hclk(hclk), .hreset_n(hreset_n),
        .wr_lo_i(wr_lo), .wr_hi_i(wr_hi), .wr_cmp_lo_i(wr_clo),
            .wr_cmp_hi_i(wr_chi),
        .rd_lo_i(rd_lo), .wdata_i(wdata),
        .mtime_lo_o(lo), .mtime_hi_shadow_o(hi), .mtimecmp_o(cmp),
            .mtip_o(mtip_o));

    watchdog u_wdt (
        .hclk(hclk), .hreset_n(hreset_n), .ext_hrst_n(ext_hrst_n),
        .wr_ctl_i(wr_ctl), .wr_load_i(wr_load), .wr_kick_i(wr_kick),
            .wr_warn_i(wr_warn),
        .wdata_i(wdata), .ctl_o(ctl), .load_o(load), .val_o(val), .warn_o(warn),
        .warn_irq_o(wdt_warn_irq_o), .rst_req_o(wdt_rst_req_o));

endmodule
