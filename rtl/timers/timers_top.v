`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 11 : timers and watchdog
// timers_top.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 (Rev 4.0 set); ADR-0003, ADR-0010
//
// The machine timer reaches the core as ONE wire, mtip_o ([N-5.1], R4): the
// 64-bit compare lives here, not in the core. The watchdog's warning goes to
// CLIC ID 22 and its reset request to reset_ctrl. Both counters run on hclk
// and are never gated - they must keep counting while the core sleeps ([N-9.4]).
// =============================================================================

module timers_top (
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        ext_rst_n_i,         // ext-only hclk reset for the WDT request
    input  wire        pclk_i,
    input  wire        preset_n_i,

    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    output wire        mtip_o,
    output wire        wdt_warn_irq_o,
    output wire        wdt_rst_req_o
);

    wire wr_lo, wr_hi, wr_clo, wr_chi, rd_lo, wr_ctl, wr_load, wr_kick, wr_warn;
    wire [31:0] wdata, lo, hi, ctl, load, val, warn;
    wire [63:0] cmp;

    timers_apb u_apb (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
        .pwdata_i(pwdata_i), .prdata_o(prdata_o), .pready_o(pready_o), .pslverr_o(pslverr_o),
        .wr_mtime_lo_o(wr_lo), .wr_mtime_hi_o(wr_hi), .wr_cmp_lo_o(wr_clo), .wr_cmp_hi_o(wr_chi),
        .rd_mtime_lo_o(rd_lo), .wr_wdtctl_o(wr_ctl), .wr_wdtload_o(wr_load),
        .wr_wdtkick_o(wr_kick), .wr_wdtwarn_o(wr_warn), .wdata_o(wdata),
        .mtime_lo_i(lo), .mtime_hi_i(hi), .mtimecmp_i(cmp),
        .wdtctl_i(ctl), .wdtload_i(load), .wdtval_i(val), .wdtwarn_i(warn));

    mtime u_mtime (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
        .wr_lo_i(wr_lo), .wr_hi_i(wr_hi), .wr_cmp_lo_i(wr_clo), .wr_cmp_hi_i(wr_chi),
        .rd_lo_i(rd_lo), .wdata_i(wdata),
        .mtime_lo_o(lo), .mtime_hi_shadow_o(hi), .mtimecmp_o(cmp), .mtip_o(mtip_o));

    wdt u_wdt (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .ext_rst_n_i(ext_rst_n_i),
        .wr_ctl_i(wr_ctl), .wr_load_i(wr_load), .wr_kick_i(wr_kick), .wr_warn_i(wr_warn),
        .wdata_i(wdata), .ctl_o(ctl), .load_o(load), .val_o(val), .warn_o(warn),
        .warn_irq_o(wdt_warn_irq_o), .rst_req_o(wdt_rst_req_o));

    wire _unused = |{pclk_i, preset_n_i};

endmodule

`default_nettype wire
