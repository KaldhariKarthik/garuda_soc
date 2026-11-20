// =============================================================================
// GARUDA SoC - SoC integration (everything except clock generation and reset
// sequencing, which live one level up in garuda_chip_top)
// garuda_soc_top.v
//
// System definition: GARUDA-SYS-001 Rev 4.0 (Design_Docs/garuda_system.yaml),
// rendered into rtl/include/garuda_map.vh. Rulings: Docs/DECISIONS.md
// D-4..D-18.
//
//   AHB-Lite, one shared layer (ADR-0004), priority DMA > SBA > D > I
//     M0 core I-port   M1 core D-port   M2 Debug SBA   M3 DMA
//     S0 ISRAM 0x0000_0000   S1 Boot ROM 0x1000_0000   S2 DSRAM 0x2000_0000
//     S3 AHB2APB 0x4000_0000 (+ default slave: two-cycle ERROR)
//
//   APB windows (window n = 0x4000_0000 + 0x1000*n = PSEL bit n, D-6)
//     5 DMA (internal)    9 reset_ctrl + MEMCTL (external: garuda_chip_top)
//     10 CLIC (internal)  11 timers (internal)
//     1 spi_master  2 i2c  3 uart0  4 uart1  6 uart2  7 gpio  8 pwm
//       -> the sourced peripheral IP, deferred: their windows are brought out
//          on the apb_ext_* port and stay MASKED (they fault) until each IP
//          lands and its bit is added to APB_WINDOW_MASK.
//
//   CLIC ID map (yaml clic.map, ADR-0009)
// 0 sentinel (tied 0) 1-6 DMA complete 7 reserved (mcause 7 = MTI) 8-13 DMA
// error
// 14 SPI slave (AUD-14: this line said 7-12 DMA error, 13,14 reserved; INT-2
// moved them)
//     15-21 peripheral IRQs (periph_irq_i[6:0])  22 watchdog warning
//   mtip goes straight to the core, not through the CLIC (ADR-0010).
//
//   Reset inputs come from reset_ctrl (garuda_chip_top): hreset_n (fabric,
//   memories, DMA, CLIC, timers), preset_n (APB side), core_rst_n (core + DSU),
//   dm_rst_n (Debug Module - excludes ndmreset), ext_hrst_n (ext-only, for the
//   watchdog request flop). Keeping reset_ctrl outside lets a testbench drive
//   every domain's reset directly.
// =============================================================================

module garuda_soc_top
    import garuda_pkg::*;
    import soc_map_pkg::*;
#(
    parameter [31:0] RESET_VECTOR    = RST_VECTOR,
    parameter        BROM_INIT_FILE  = "",
    // windows with a slave behind them; peripheral bits are added as IP lands
    parameter [15:0] APB_WINDOW_MASK = (16'd1 << WIN_DMA)    |
                                       (16'd1 << WIN_RESET_CTRL) |
                                       (16'd1 << WIN_CLIC)   |
                                       (16'd1 << WIN_TIMERS),
    parameter [23:0] APB_DIV         = 24'h000000,
    parameter integer        CORE_CLK_GATE   = 32'd1
)(
    // ---- clocks and resets --------------------------------------------------
    input wire hclk,
    input wire pclk,
    input wire pclk_phase_i,
    input wire hreset_n,
    input wire preset_n,
    input wire core_rst_n,
    input wire dm_rst_n,
    input wire ext_hrst_n,
    input wire ext_rst_n,  // ext_rst_n pin, TAP power-on reset
    // ---- reset requests (to reset_ctrl) -------------------------------------
    output wire wdt_rst_req_o,
    output wire ndmreset_o,
    output wire hartreset_o,
    // ---- MEMCTL.ILOCK (from reset_ctrl, window 9) ---------------------------
    input wire ilock_i,
    // ---- JTAG ---------------------------------------------------------------
    input wire tck,
    input wire tms_i,
    input wire tdi_i,
    output wire tdo_o,
    output wire tdo_oe_o,
    // ---- APB expansion: windows not implemented inside this level -----------
    // (window 9 = reset_ctrl in garuda_chip_top; 1-4,6-8 = sourced peripherals)
    // the expansion port: the APB_NEXT windows served outside (soc_map_pkg)
    output wire [APB_NEXT-1:0] apb_ext_psel_o,
    output wire apb_ext_penable_o,
    output wire apb_ext_pwrite_o,
    output wire [PADDR_W-1:0] apb_ext_paddr_o,
    output wire [WORD_W-1:0] apb_ext_pwdata_o,
    input wire [APB_NEXT * WORD_W - 1:0] apb_ext_prdata_i,
    input wire [APB_NEXT-1:0] apb_ext_pready_i,
    input wire [APB_NEXT-1:0] apb_ext_pslverr_i,
    // ---- peripheral sideband (deferred IP plugs in here) --------------------
    // CLIC 15..21: spi, i2c, uart0/1/2, gpio, pwm
    input wire [PERIPH_IRQ_W-1:0] periph_irq_i,
    input wire spis_irq_i,  // CLIC 14: spi_slave (block 14)
    input wire [DMA_NCH-1:0] dma_req_i,  // all six channels live
    output wire [DMA_NCH-1:0] dma_ack_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned CLIC_IDB_W = 32'd5;

    // =========================================================================
    // AHB master buses
    // =========================================================================
    wire [WORD_W-1:0] i_haddr;
    wire [WORD_W-1:0] i_hwdata;
    wire [WORD_W-1:0] i_hrdata;
    wire [HTRANS_W-1:0] i_htrans;
    wire [HSIZE_W-1:0] i_hsize;
    wire i_hwrite;
    wire i_hready;
    wire i_hresp;
    wire [WORD_W-1:0] d_haddr;
    wire [WORD_W-1:0] d_hwdata;
    wire [WORD_W-1:0] d_hrdata;
    wire [HTRANS_W-1:0] d_htrans;
    wire [HSIZE_W-1:0] d_hsize;
    wire d_hwrite;
    wire d_hready;
    wire d_hresp;
    wire [WORD_W-1:0] s_haddr;
    wire [WORD_W-1:0] s_hwdata;
    wire [WORD_W-1:0] s_hrdata;
    wire [HTRANS_W-1:0] s_htrans;
    wire [HSIZE_W-1:0] s_hsize;
    wire s_hwrite;
    wire s_hready;
    wire s_hresp;
    wire [WORD_W-1:0] m_haddr;
    wire [WORD_W-1:0] m_hwdata;
    wire [WORD_W-1:0] m_hrdata;
    wire [HTRANS_W-1:0] m_htrans;
    wire [HSIZE_W-1:0] m_hsize;
    wire m_hwrite;
    wire m_hready;
    wire m_hresp;

    // shared slave-side bundle
    wire hsel_isram;
    wire hsel_rom;
    wire hsel_dsram;
    wire hsel_bridge;
    wire hmaster_is_sba;
    wire [WORD_W-1:0] haddr;
    wire [WORD_W-1:0] hwdata;
    wire [HTRANS_W-1:0] htrans;
    wire hwrite;
    wire hready;
    wire [HSIZE_W-1:0] hsize;
    wire [WORD_W-1:0] hrdata_isram;
    wire [WORD_W-1:0] hrdata_rom;
    wire [WORD_W-1:0] hrdata_dsram;
    wire [WORD_W-1:0] hrdata_bridge;
    wire hro_isram;
    wire hro_rom;
    wire hro_dsram;
    wire hro_bridge;
    wire hresp_isram;
    wire hresp_rom;
    wire hresp_dsram;
    wire hresp_bridge;

    // interrupts / timer / debug
    wire        clic_valid;
    wire [CLIC_IDB_W-1:0] clic_id;
    wire [CLIC_LVL_W-1:0] clic_level;
    wire [DMA_NCH-1:0] dma_complete;
    wire [DMA_NCH-1:0] dma_error;
    wire mtip;
    wire wdt_warn;
    wire [ACC_W-1:0] acc_fx;
    wire [ACC_W-1:0] acc_fy;
    wire [ACC_W-1:0] acc_mag;
    wire dsu_ovf;
    wire        dm_hartreset;
    // RDC-1 halt drain (core <-> Debug Module)
    wire dm_halt_req;
    wire core_halt_safe;

    // =========================================================================
    // Block 1 (+2): core with DSU
    // =========================================================================
    garuda_core_top #(.RESET_VECTOR(RESET_VECTOR),
        .CLK_GATE(CORE_CLK_GATE)) u_core(
        .hclk(hclk), .core_rst_n(core_rst_n),
        .halt_req_i(dm_halt_req), .halt_safe_o(core_halt_safe),
        .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize),
        .i_hwrite_o(i_hwrite), .i_hwdata_o(i_hwdata),
        .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(i_hresp),
        .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize),
        .d_hwrite_o(d_hwrite), .d_hwdata_o(d_hwdata),
        .d_hrdata_i(d_hrdata), .d_hready_i(d_hready), .d_hresp_i(d_hresp),
        .clic_irq_valid_i(clic_valid), .clic_irq_id_i(clic_id),
            .clic_irq_level_i(clic_level),
        .mtip_i(mtip),
        .dbg_acc_0_o(acc_fx), .dbg_acc_1_o(acc_fy), .dbg_acc_2_o(acc_mag),
            .dsu_ovf_o(dsu_ovf));

    // =========================================================================
    // Block 12: debug (JTAG + DM + SBA master M2)
    // =========================================================================
    debug_top u_debug (
        .tck(tck), .tms_i(tms_i), .tdi_i(tdi_i), .tdo_o(tdo_o),
            .tdo_oe_o(tdo_oe_o),
        .ext_rst_n(ext_rst_n),
        .hclk(hclk), .dm_rst_n(dm_rst_n),
        .ndmreset_o(ndmreset_o), .hartreset_o(dm_hartreset),
        .halt_req_o(dm_halt_req), .halt_safe_i(core_halt_safe),
        .dsu_acc0_i(acc_fx), .dsu_acc1_i(acc_fy), .dsu_acc2_i(acc_mag),
            .dsu_ovf_i(dsu_ovf),
        .haddr_o(s_haddr), .htrans_o(s_htrans), .hwrite_o(s_hwrite),
            .hsize_o(s_hsize),
        .hwdata_o(s_hwdata), .hrdata_i(s_hrdata),
        .hready_i(s_hready), .hresp_i(s_hresp));
    assign hartreset_o = dm_hartreset;

    // =========================================================================
    // Block 9: DMA (AHB master M3, APB window 5)
    // =========================================================================
    wire [APB_NWIN-1:0] psel;
    wire penable;
    wire pwrite;
    wire [PADDR_W-1:0] paddr;
    wire [WORD_W-1:0] pwdata;
    wire [WORD_W-1:0] prd_dma;
    wire [WORD_W-1:0] prd_clic;
    wire [WORD_W-1:0] prd_tmr;
    wire rdy_dma;
    wire rdy_clic;
    wire rdy_tmr;
    wire err_dma;
    wire err_clic;
    wire err_tmr;

    dma_top u_dma (
        .hclk(hclk), .hreset_n(hreset_n), .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel[WIN_DMA]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prd_dma),
            .pready_o(rdy_dma),
        .pslverr_o(err_dma),
        .haddr_o(m_haddr), .htrans_o(m_htrans), .hwrite_o(m_hwrite),
            .hsize_o(m_hsize),
        .hwdata_o(m_hwdata), .hrdata_i(m_hrdata),
            .hready_i(m_hready),
        .hresp_i(m_hresp),
        // Channel 4 is the SPI SLAVE's (ESP-NOW mesh), per ADR-0020 Rev 2 and
        // DMA [N-6.4]. It was tied low for as long as rtl/spi_slave/ did not
        // exist; block 14 now does, so it is connected like every other.
        .dma_req_i(dma_req_i),

        .dma_ack_o(dma_ack_o),
        .dma_complete_o(dma_complete), .dma_error_o(dma_error));

    // =========================================================================
    // Block 6: AHB-Lite interconnect
    // =========================================================================
    ahb_interconnect u_ahb (
        .hclk(hclk), .hreset_n(hreset_n),
        .i_haddr_i(i_haddr), .i_htrans_i(i_htrans), .i_hwrite_i(i_hwrite),
            .i_hsize_i(i_hsize),
        .i_hwdata_i(i_hwdata),
        .i_hrdata_o(i_hrdata), .i_hready_o(i_hready), .i_hresp_o(i_hresp),
        .d_haddr_i(d_haddr), .d_htrans_i(d_htrans), .d_hwrite_i(d_hwrite),
            .d_hsize_i(d_hsize),
        .d_hwdata_i(d_hwdata),
        .d_hrdata_o(d_hrdata), .d_hready_o(d_hready), .d_hresp_o(d_hresp),
        .s_haddr_i(s_haddr), .s_htrans_i(s_htrans), .s_hwrite_i(s_hwrite),
            .s_hsize_i(s_hsize),
        .s_hwdata_i(s_hwdata),
        .s_hrdata_o(s_hrdata), .s_hready_o(s_hready), .s_hresp_o(s_hresp),
        .m_haddr_i(m_haddr), .m_htrans_i(m_htrans), .m_hwrite_i(m_hwrite),
            .m_hsize_i(m_hsize),
        .m_hwdata_i(m_hwdata),
        .m_hrdata_o(m_hrdata), .m_hready_o(m_hready), .m_hresp_o(m_hresp),
        .hsel_isram_o(hsel_isram), .hsel_rom_o(hsel_rom),
            .hsel_dsram_o(hsel_dsram),
        .hsel_bridge_o(hsel_bridge),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hwdata_o(hwdata),
            .hready_o(hready),
        .hmaster_is_sba_o(hmaster_is_sba),
        .hrdata_isram_i(hrdata_isram), .hreadyout_isram_i(hro_isram),
            .hresp_isram_i(hresp_isram),
        .hrdata_rom_i(hrdata_rom), .hreadyout_rom_i(hro_rom),
            .hresp_rom_i(hresp_rom),
        .hrdata_dsram_i(hrdata_dsram), .hreadyout_dsram_i(hro_dsram),
            .hresp_dsram_i(hresp_dsram),
        .hrdata_bridge_i(hrdata_bridge), .hreadyout_bridge_i(hro_bridge),
            .hresp_bridge_i(hresp_bridge));

    // =========================================================================
    // Blocks 3/4/5: memories
    // =========================================================================
    isram_top u_isram (
        .hclk(hclk), .hreset_n(hreset_n), .hsel_i(hsel_isram), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize),
        .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_isram), .hreadyout_o(hro_isram), .hresp_o(hresp_isram),
        .ilock_i(ilock_i), .hmaster_is_sba_i(hmaster_is_sba));

    bootrom_top #(.INIT_FILE(BROM_INIT_FILE)) u_brom (
        .hclk(hclk), .hreset_n(hreset_n), .hsel_i(hsel_rom), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize),
        .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_rom), .hreadyout_o(hro_rom), .hresp_o(hresp_rom));

    dsram_top u_dsram (
        .hclk(hclk), .hreset_n(hreset_n), .hsel_i(hsel_dsram), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize),
        .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_dsram), .hreadyout_o(hro_dsram),
            .hresp_o(hresp_dsram));

    // =========================================================================
    // Blocks 8 + 7: AHB2APB bridge and APB fabric
    // =========================================================================
    wire [APB_NWIN*WORD_W-1:0] prdata_all;
    wire [APB_NWIN-1:0] pready_all;
    wire [APB_NWIN-1:0] pslverr_all;

    // the three windows served here, and the expansion port's for the rest
    // (F4: the port carries only the windows served outside)
    assign prdata_all[32*WIN_DMA +: 32]    = prd_dma;
    assign pready_all[WIN_DMA]             = rdy_dma;
    assign pslverr_all[WIN_DMA]            = err_dma;
    assign prdata_all[32*WIN_CLIC +: 32]   = prd_clic;
    assign pready_all[WIN_CLIC]            = rdy_clic;
    assign pslverr_all[WIN_CLIC]           = err_clic;
    assign prdata_all[32*WIN_TIMERS +: 32] = prd_tmr;
    assign pready_all[WIN_TIMERS]          = rdy_tmr;
    assign pslverr_all[WIN_TIMERS]         = err_tmr;
    genvar e;
    generate for (e = 0; e < APB_NEXT; e = e + 1) begin : g_ext
        assign prdata_all[32*ext_win(unsigned'(e)) +: 32] = apb_ext_prdata_i[32*e +: 32];
        assign pready_all[ext_win(unsigned'(e))]          = apb_ext_pready_i[e];
        assign pslverr_all[ext_win(unsigned'(e))]         = apb_ext_pslverr_i[e];
        assign apb_ext_psel_o[e]               = psel[ext_win(unsigned'(e))];
    end endgenerate

    ahb2apb_bridge #(.WINDOW_MASK(APB_WINDOW_MASK), .APB_DIV(APB_DIV),
                     .TIMEOUT(APB_TIMEOUT)) u_bridge (
        .hclk(hclk), .hreset_n(hreset_n), .pclk(pclk), .preset_n(preset_n),
        .pclk_phase_i(pclk_phase_i),
        .hsel_i(hsel_bridge), .haddr_i(haddr), .htrans_i(htrans),
            .hwrite_i(hwrite),
        .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_bridge), .hreadyout_o(hro_bridge),
            .hresp_o(hresp_bridge),
        .psel_o(psel), .penable_o(penable), .pwrite_o(pwrite), .paddr_o(paddr),
        .pwdata_o(pwdata), .prdata_i(prdata_all), .pready_i(pready_all),
            .pslverr_i(pslverr_all));

    assign apb_ext_penable_o = penable;
    assign apb_ext_pwrite_o  = pwrite;
    assign apb_ext_paddr_o   = paddr;
    assign apb_ext_pwdata_o  = pwdata;

    // =========================================================================
    // Block 10: CLIC (APB window 10)
    // =========================================================================
    wire [WORD_W-1:0] irq_src;
    assign irq_src[0]     = 1'b0;  // sentinel ([N-7.12])
    assign irq_src[ID_DMA_DONE_BASE +: 6] = dma_complete;  // IDs 1-6
    // ID 7 is never a CLIC source: mcause 0x8000_0007 is the machine timer,
    // which reaches the core directly (ADR-0010), and a CLIC interrupt reports
    // 0x8000_0000 | ID. The DMA error lines sat on 7-12, so a channel-0 error
    // was indistinguishable from a timer tick (BUGS_HISTORY.md INT-2). They are
    // 8-13.
    assign irq_src[7]     = 1'b0;
    assign irq_src[ID_DMA_ERR_BASE +: 6] = dma_error;  // IDs 8-13
    // ID 14 is block 14, the SPI slave (ADR-0020 Rev 2).
    assign irq_src[14]    = spis_irq_i;
    assign irq_src[21:15] = periph_irq_i;  // IDs 15-21
    assign irq_src[22]    = wdt_warn;  // ID 22
    assign irq_src[23]    = 1'b0;  // ID 23: CLICSWI inside the CLIC ([N-6.9])
    assign irq_src[31:24] = 8'd0;

    // The enable mask comes from the map. The block's own default still
    // excluded IDs 13 and 14 from when the SPI slave had been removed, so the
    // SPI slave's interrupt could be wired, pending, and impossible to enable
    // (BUGS_HISTORY.md INT-3).
    // SWI_ID: default 23 = GARUDA_CLIC_ID_SOFTWARE
    clic_top #(.IE_MASK(CLIC_ID_MASK)) u_clic (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel[WIN_CLIC]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prd_clic),
            .pready_o(rdy_clic),
        .pslverr_o(err_clic),
        .irq_src_i(irq_src),
        .clic_irq_valid_o(clic_valid), .clic_irq_id_o(clic_id),
            .clic_irq_level_o(clic_level));

    // =========================================================================
    // Block 11: timers + watchdog (APB window 11)
    // =========================================================================
    timers_top u_timers (
        .hclk(hclk), .hreset_n(hreset_n), .ext_hrst_n(ext_hrst_n),
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel[WIN_TIMERS]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prd_tmr),
            .pready_o(rdy_tmr),
        .pslverr_o(err_tmr),
        .mtip_o(mtip), .wdt_warn_irq_o(wdt_warn),
            .wdt_rst_req_o(wdt_rst_req_o));

endmodule
