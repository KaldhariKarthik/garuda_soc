`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - SoC integration (everything except clock generation and reset
// sequencing, which live one level up in garuda_chip_top)
// garuda_soc_top.v
//
// System definition: GARUDA-SYS-001 Rev 4.0 (Design_Docs/garuda_system.yaml),
// rendered into rtl/include/garuda_map.vh. Rulings: Docs/DECISIONS.md D-4..D-18.
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
//     0 sentinel (tied 0)  1-6 DMA complete  7-12 DMA error  13,14 reserved
//     15-21 peripheral IRQs (periph_irq_i[6:0])  22 watchdog warning
//   mtip goes straight to the core, not through the CLIC (ADR-0010).
//
//   Reset inputs come from reset_ctrl (garuda_chip_top): hreset_n (fabric,
//   memories, DMA, CLIC, timers), preset_n (APB side), core_rst_n (core + DSU),
//   dm_rst_n (Debug Module - excludes ndmreset), ext_hrst_n (ext-only, for the
//   watchdog request flop). Keeping reset_ctrl outside lets a testbench drive
//   every domain's reset directly.
// =============================================================================
`include "garuda_map.vh"

module garuda_soc_top #(
    parameter [31:0] RESET_VECTOR    = `GARUDA_RESET_VECTOR,
    parameter        BROM_INIT_FILE  = "",
    // windows with a slave behind them; peripheral bits are added as IP lands
    parameter [15:0] APB_WINDOW_MASK = (16'd1 << `GARUDA_APB_WIN_DMA_CFG)    |
                                       (16'd1 << `GARUDA_APB_WIN_RESET_CTRL) |
                                       (16'd1 << `GARUDA_APB_WIN_CLIC_CFG)   |
                                       (16'd1 << `GARUDA_APB_WIN_TIMERS_CFG),
    parameter [23:0] APB_DIV         = 24'h0,
    parameter        CORE_CLK_GATE   = 1
)(
    // ---- clocks and resets -----------------------------------------------------
    input  wire        hclk_i,
    input  wire        pclk_i,
    input  wire        pclk_phase_i,
    input  wire        hreset_n_i,
    input  wire        preset_n_i,
    input  wire        core_rst_n_i,
    input  wire        dm_rst_n_i,
    input  wire        ext_hrst_n_i,
    input  wire        por_n_i,            // ext_rst_n pin, TAP power-on reset

    // ---- reset requests (to reset_ctrl) -------------------------------------
    output wire        wdt_rst_req_o,
    output wire        ndmreset_o,
    output wire        hartreset_o,

    // ---- MEMCTL.ILOCK (from reset_ctrl, window 9) ---------------------------
    input  wire        ilock_i,

    // ---- JTAG -------------------------------------------------------------------
    input  wire        tck_i,
    input  wire        tms_i,
    input  wire        tdi_i,
    output wire        tdo_o,
    output wire        tdo_oe_o,

    // ---- APB expansion: windows not implemented inside this level -----------
    // (window 9 = reset_ctrl in garuda_chip_top; 1-4,6-8 = sourced peripherals)
    output wire [11:0] apb_ext_psel_o,
    output wire        apb_ext_penable_o,
    output wire        apb_ext_pwrite_o,
    output wire [11:0] apb_ext_paddr_o,
    output wire [31:0] apb_ext_pwdata_o,
    input  wire [12*32-1:0] apb_ext_prdata_i,
    input  wire [11:0] apb_ext_pready_i,
    input  wire [11:0] apb_ext_pslverr_i,

    // ---- peripheral sideband (deferred IP plugs in here) --------------------
    input  wire [6:0]  periph_irq_i,       // CLIC 15..21: spi, i2c, uart0/1/2, gpio, pwm
    input  wire [5:0]  dma_req_i,          // ch4 is spare and tied low inside
    output wire [5:0]  dma_ack_o,

    // ---- observability -------------------------------------------------------------
    output wire        core_sleep_o
);

    // =========================================================================
    // AHB master buses
    // =========================================================================
    wire [31:0] i_haddr, i_hwdata, i_hrdata;  wire [1:0] i_htrans;  wire [2:0] i_hsize, i_hburst;
    wire [3:0]  i_hprot;  wire i_hwrite, i_hready, i_hresp;
    wire [31:0] d_haddr, d_hwdata, d_hrdata;  wire [1:0] d_htrans;  wire [2:0] d_hsize, d_hburst;
    wire [3:0]  d_hprot;  wire d_hwrite, d_hready, d_hresp;
    wire [31:0] s_haddr, s_hwdata, s_hrdata;  wire [1:0] s_htrans;  wire [2:0] s_hsize, s_hburst;
    wire        s_hwrite, s_hready, s_hresp;
    wire [31:0] m_haddr, m_hwdata, m_hrdata;  wire [1:0] m_htrans;  wire [2:0] m_hsize, m_hburst;
    wire        m_hwrite, m_hready, m_hresp;

    // shared slave-side bundle
    wire        hsel_isram, hsel_rom, hsel_dsram, hsel_bridge, hmaster_is_sba;
    wire [31:0] haddr, hwdata;  wire [1:0] htrans;  wire hwrite, hready;
    wire [2:0]  hsize, hburst;  wire [3:0] hprot;
    wire [31:0] hrdata_isram, hrdata_rom, hrdata_dsram, hrdata_bridge;
    wire        hro_isram, hro_rom, hro_dsram, hro_bridge;
    wire        hresp_isram, hresp_rom, hresp_dsram, hresp_bridge;

    // interrupts / timer / debug
    wire        clic_valid;  wire [4:0] clic_id;  wire [7:0] clic_level;
    wire [5:0]  dma_complete, dma_error;
    wire        mtip, wdt_warn;
    wire [47:0] acc0, acc1, acc2;  wire dsu_ovf;
    wire        dm_hartreset;

    // =========================================================================
    // Block 1 (+2): core with DSU
    // =========================================================================
    garuda_core_top #(.RESET_VECTOR(RESET_VECTOR), .CLK_GATE(CORE_CLK_GATE)) u_core (
        .clk_i(hclk_i), .core_rst_n_i(core_rst_n_i), .hartreset_n_i(~dm_hartreset),
        .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize), .i_hburst_o(i_hburst),
        .i_hprot_o(i_hprot), .i_hwrite_o(i_hwrite), .i_hwdata_o(i_hwdata),
        .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(i_hresp),
        .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize), .d_hburst_o(d_hburst),
        .d_hprot_o(d_hprot), .d_hwrite_o(d_hwrite), .d_hwdata_o(d_hwdata),
        .d_hrdata_i(d_hrdata), .d_hready_i(d_hready), .d_hresp_i(d_hresp),
        .clic_irq_valid_i(clic_valid), .clic_irq_id_i(clic_id), .clic_irq_level_i(clic_level),
        .mtip_i(mtip),
        .dbg_acc_0_o(acc0), .dbg_acc_1_o(acc1), .dbg_acc_2_o(acc2), .dsu_ovf_o(dsu_ovf),
        .core_sleep_o(core_sleep_o));

    // =========================================================================
    // Block 12: debug (JTAG + DM + SBA master M2)
    // =========================================================================
    debug_top u_debug (
        .tck_i(tck_i), .tms_i(tms_i), .tdi_i(tdi_i), .tdo_o(tdo_o), .tdo_oe_o(tdo_oe_o),
        .por_n_i(por_n_i),
        .hclk_i(hclk_i), .dm_rst_n_i(dm_rst_n_i),
        .ndmreset_o(ndmreset_o), .hartreset_o(dm_hartreset),
        .dsu_acc0_i(acc0), .dsu_acc1_i(acc1), .dsu_acc2_i(acc2), .dsu_ovf_i(dsu_ovf),
        .haddr_o(s_haddr), .htrans_o(s_htrans), .hwrite_o(s_hwrite), .hsize_o(s_hsize),
        .hburst_o(s_hburst), .hwdata_o(s_hwdata), .hrdata_i(s_hrdata),
        .hready_i(s_hready), .hresp_i(s_hresp));
    assign hartreset_o = dm_hartreset;

    // =========================================================================
    // Block 9: DMA (AHB master M3, APB window 5)
    // =========================================================================
    wire [11:0] psel;  wire penable, pwrite;  wire [11:0] paddr;  wire [31:0] pwdata;
    wire [31:0] prd_dma, prd_clic, prd_tmr;
    wire        rdy_dma, rdy_clic, rdy_tmr, err_dma, err_clic, err_tmr;

    dma_top u_dma (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel[`GARUDA_APB_WIN_DMA_CFG]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prd_dma), .pready_o(rdy_dma),
        .pslverr_o(err_dma),
        .haddr_o(m_haddr), .htrans_o(m_htrans), .hwrite_o(m_hwrite), .hsize_o(m_hsize),
        .hburst_o(m_hburst), .hwdata_o(m_hwdata), .hrdata_i(m_hrdata), .hready_i(m_hready),
        .hresp_i(m_hresp),
        .dma_req_i({dma_req_i[5], 1'b0, dma_req_i[3:0]}),   // ch4 spare ([N-6.4])
        .dma_ack_o(dma_ack_o),
        .dma_complete_o(dma_complete), .dma_error_o(dma_error));

    // =========================================================================
    // Block 6: AHB-Lite interconnect
    // =========================================================================
    ahb_interconnect u_ahb (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
        .i_haddr_i(i_haddr), .i_htrans_i(i_htrans), .i_hwrite_i(i_hwrite), .i_hsize_i(i_hsize),
        .i_hburst_i(i_hburst), .i_hprot_i(i_hprot), .i_hwdata_i(i_hwdata),
        .i_hrdata_o(i_hrdata), .i_hready_o(i_hready), .i_hresp_o(i_hresp),
        .d_haddr_i(d_haddr), .d_htrans_i(d_htrans), .d_hwrite_i(d_hwrite), .d_hsize_i(d_hsize),
        .d_hburst_i(d_hburst), .d_hprot_i(d_hprot), .d_hwdata_i(d_hwdata),
        .d_hrdata_o(d_hrdata), .d_hready_o(d_hready), .d_hresp_o(d_hresp),
        .s_haddr_i(s_haddr), .s_htrans_i(s_htrans), .s_hwrite_i(s_hwrite), .s_hsize_i(s_hsize),
        .s_hburst_i(s_hburst), .s_hwdata_i(s_hwdata),
        .s_hrdata_o(s_hrdata), .s_hready_o(s_hready), .s_hresp_o(s_hresp),
        .m_haddr_i(m_haddr), .m_htrans_i(m_htrans), .m_hwrite_i(m_hwrite), .m_hsize_i(m_hsize),
        .m_hburst_i(m_hburst), .m_hwdata_i(m_hwdata),
        .m_hrdata_o(m_hrdata), .m_hready_o(m_hready), .m_hresp_o(m_hresp),
        .hsel_isram_o(hsel_isram), .hsel_rom_o(hsel_rom), .hsel_dsram_o(hsel_dsram),
        .hsel_bridge_o(hsel_bridge),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hprot_o(hprot), .hwdata_o(hwdata), .hready_o(hready),
        .hmaster_is_sba_o(hmaster_is_sba),
        .hrdata_isram_i(hrdata_isram),   .hreadyout_isram_i(hro_isram),   .hresp_isram_i(hresp_isram),
        .hrdata_rom_i(hrdata_rom),       .hreadyout_rom_i(hro_rom),       .hresp_rom_i(hresp_rom),
        .hrdata_dsram_i(hrdata_dsram),   .hreadyout_dsram_i(hro_dsram),   .hresp_dsram_i(hresp_dsram),
        .hrdata_bridge_i(hrdata_bridge), .hreadyout_bridge_i(hro_bridge), .hresp_bridge_i(hresp_bridge));

    // =========================================================================
    // Blocks 3/4/5: memories
    // =========================================================================
    isram_top u_isram (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_isram), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_isram), .hreadyout_o(hro_isram), .hresp_o(hresp_isram),
        .ilock_i(ilock_i), .hmaster_is_sba_i(hmaster_is_sba));

    bootrom_top #(.INIT_FILE(BROM_INIT_FILE)) u_brom (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_rom), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_rom), .hreadyout_o(hro_rom), .hresp_o(hresp_rom));

    dsram_top u_dsram (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_dsram), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_dsram), .hreadyout_o(hro_dsram), .hresp_o(hresp_dsram));

    // =========================================================================
    // Blocks 8 + 7: AHB2APB bridge and APB fabric
    // =========================================================================
    wire [12*32-1:0] prdata_all;
    wire [11:0]      pready_all, pslverr_all;

    // internal windows override the expansion port's return path
    genvar w;
    generate for (w = 0; w < 12; w = w + 1) begin : g_ret
        if (w == `GARUDA_APB_WIN_DMA_CFG) begin : g_dma
            assign prdata_all[32*w +: 32] = prd_dma;  assign pready_all[w] = rdy_dma;  assign pslverr_all[w] = err_dma;
        end else if (w == `GARUDA_APB_WIN_CLIC_CFG) begin : g_clic
            assign prdata_all[32*w +: 32] = prd_clic; assign pready_all[w] = rdy_clic; assign pslverr_all[w] = err_clic;
        end else if (w == `GARUDA_APB_WIN_TIMERS_CFG) begin : g_tmr
            assign prdata_all[32*w +: 32] = prd_tmr;  assign pready_all[w] = rdy_tmr;  assign pslverr_all[w] = err_tmr;
        end else begin : g_ext
            assign prdata_all[32*w +: 32] = apb_ext_prdata_i[32*w +: 32];
            assign pready_all[w]  = apb_ext_pready_i[w];
            assign pslverr_all[w] = apb_ext_pslverr_i[w];
        end
    end endgenerate

    ahb2apb_bridge #(.WINDOW_MASK(APB_WINDOW_MASK), .APB_DIV(APB_DIV),
                     .TIMEOUT(`GARUDA_APB_TIMEOUT_PCLK)) u_bridge (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .pclk_phase_i(pclk_phase_i),
        .hsel_i(hsel_bridge), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
        .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(hrdata_bridge), .hreadyout_o(hro_bridge), .hresp_o(hresp_bridge),
        .psel_o(psel), .penable_o(penable), .pwrite_o(pwrite), .paddr_o(paddr),
        .pwdata_o(pwdata), .prdata_i(prdata_all), .pready_i(pready_all), .pslverr_i(pslverr_all));

    assign apb_ext_psel_o    = psel & ~((12'd1 << `GARUDA_APB_WIN_DMA_CFG) |
                                        (12'd1 << `GARUDA_APB_WIN_CLIC_CFG) |
                                        (12'd1 << `GARUDA_APB_WIN_TIMERS_CFG));
    assign apb_ext_penable_o = penable;
    assign apb_ext_pwrite_o  = pwrite;
    assign apb_ext_paddr_o   = paddr;
    assign apb_ext_pwdata_o  = pwdata;

    // =========================================================================
    // Block 10: CLIC (APB window 10)
    // =========================================================================
    wire [31:0] irq_src;
    assign irq_src[0]     = 1'b0;                         // sentinel ([N-7.12])
    assign irq_src[6:1]   = dma_complete;                 // IDs 1-6
    assign irq_src[12:7]  = dma_error;                    // IDs 7-12
    assign irq_src[14:13] = 2'b00;                        // reserved
    assign irq_src[21:15] = periph_irq_i;                 // IDs 15-21
    assign irq_src[22]    = wdt_warn;                     // ID 22
    assign irq_src[31:23] = 9'd0;

    clic_top u_clic (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel[`GARUDA_APB_WIN_CLIC_CFG]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prd_clic), .pready_o(rdy_clic),
        .pslverr_o(err_clic),
        .irq_src_i(irq_src),
        .clic_irq_valid_o(clic_valid), .clic_irq_id_o(clic_id), .clic_irq_level_o(clic_level));

    // =========================================================================
    // Block 11: timers + watchdog (APB window 11)
    // =========================================================================
    timers_top u_timers (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .ext_rst_n_i(ext_hrst_n_i),
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel[`GARUDA_APB_WIN_TIMERS_CFG]), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prd_tmr), .pready_o(rdy_tmr),
        .pslverr_o(err_tmr),
        .mtip_o(mtip), .wdt_warn_irq_o(wdt_warn), .wdt_rst_req_o(wdt_rst_req_o));

endmodule

`default_nettype wire
