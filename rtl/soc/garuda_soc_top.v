`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - top-level integration of the blocks that exist today
// garuda_soc_top.v - CPU core (+DSU) + DMA controller + AHB-Lite interconnect
//
// Specs: GARUDA-CORE-SPEC-001 (Block 1), GARUDA-DSU-SPEC (Block 2, inside the
//        core), GARUDA-AHB-SPEC-001 Rev 2.0 (Block 6), GARUDA-DMA-SPEC-001
//        Rev 2.0 (Block 9)
//
// =============================================================================
// WHAT THIS FILE IS, AND WHAT IT IS NOT
// =============================================================================
// This is the first file in the project where the CPU core, the DSU and the DMA
// are on the same bus. Before it, each block had only ever talked to a model:
// the core to a dual-ported memory with no decoder and no arbiter, the DMA to a
// single TB slave. Everything about multi-master arbitration, address decoding
// and slave hand-off was unverified by construction.
//
// It is NOT the finished SoC. Of the 24 blocks, four are wired here. The
// memories (Blocks 3/4/5), the AHB-to-APB bridge (Block 8), the CLIC (Block 7),
// the clock divider (Block 22) and the reset controller (Block 23) have no RTL
// and no design specification yet, so THEIR PORTS ARE EXPOSED AT THIS BOUNDARY
// rather than guessed at:
//
//   - the four slave-side AHB-Lite ports (ISRAM / ROM / DSRAM / bridge)
//   - the DMA's APB configuration port, still in the pclk domain
//   - the DMA peripheral sideband (dma_req/dma_ack) and its 12 interrupt lines
//   - the core's CLIC interface and machine-timer inputs
//
// When those specifications arrive, each of those groups moves inside this
// module and disappears from the port list. Nothing else about this file should
// need to change - which is the reason for drawing the line here rather than
// inventing placeholder memories in rtl/. A guessed memory in rtl/ would have
// to be un-guessed later, and in the meantime every test would be quietly
// validating the guess.
//
// The clock and reset ports are likewise inputs, not generated here: Block 22
// owns division and Block 23 owns reset sequencing.
//
// =============================================================================
// THE THREE THINGS THIS WIRING ACTUALLY DECIDES
// =============================================================================
// 1. The DSU is INSIDE the core. garuda_core_top instantiates dsu_top directly
//    (its header: "DSU and register file are core-internal"), so "wiring the
//    DSU" means building with rtl/core/filelist_core_dsu.f rather than the
//    stub in tb/stub/. There is no DSU port at this level and there should not
//    be one - the DSU is reached through Custom-0 instructions and the
//    accumulator debug taps, nothing else.
//
// 2. The DMA's AHB master port carries no HPROT (GARUDA-DMA-SPEC-001 Sec. 5.7
//    freezes that port list). The interconnect substitutes 4'b0011 for it -
//    see ahb_master_mux.v. Nothing is tied off here; the signal genuinely does
//    not exist at the DMA boundary.
//
// 3. hreset_n_i is shared by the core, the interconnect and the DMA's hclk
//    side; preset_n_i resets the DMA's pclk side. They are separate ports
//    because they belong to different clock domains, NOT because they may be
//    released independently. GARUDA-DMA-SPEC-001 Sec. 17.5 requires the reset
//    controller to release both together: a toggle raised in pclk while hclk is
//    still in reset could be seen as a spurious arm event when hclk leaves
//    reset. That risk is listed as untested in docs/DMA_RTL_LOG.md Sec. 12 and
//    it is a constraint on Block 23, not something this file can enforce.
// =============================================================================

module garuda_soc_top #(
    parameter [31:0] RESET_VECTOR = 32'h1000_0000   // Boot ROM, core spec Sec. 17
)(
    // ---- clocks and resets (Blocks 22 / 23) --------------------------------
    input  wire        hclk_i,        // 200 MHz: core, interconnect, DMA data
    input  wire        pclk_i,        // 100 MHz: DMA configuration port
    input  wire        hreset_n_i,    // active-low, hclk domain
    input  wire        preset_n_i,    // active-low, pclk domain

    // =====================================================================
    // AHB-Lite slave ports - Blocks 3 / 5 / 4 / 8, none of which exist yet
    // =====================================================================
    output wire        hsel_isram_o,
    output wire        hsel_rom_o,
    output wire        hsel_dsram_o,
    output wire        hsel_bridge_o,

    output wire [31:0] haddr_o,
    output wire [1:0]  htrans_o,
    output wire        hwrite_o,
    output wire [2:0]  hsize_o,
    output wire [2:0]  hburst_o,
    output wire [3:0]  hprot_o,
    output wire [31:0] hwdata_o,
    output wire        hready_o,

    input  wire [31:0] hrdata_isram_i,   input wire hreadyout_isram_i,  input wire hresp_isram_i,
    input  wire [31:0] hrdata_rom_i,     input wire hreadyout_rom_i,    input wire hresp_rom_i,
    input  wire [31:0] hrdata_dsram_i,   input wire hreadyout_dsram_i,  input wire hresp_dsram_i,
    input  wire [31:0] hrdata_bridge_i,  input wire hreadyout_bridge_i, input wire hresp_bridge_i,

    // =====================================================================
    // DMA APB configuration port - reached through Block 8 in the real SoC
    // =====================================================================
    input  wire        dma_psel_i,
    input  wire        dma_penable_i,
    input  wire        dma_pwrite_i,
    input  wire [7:0]  dma_paddr_i,
    input  wire [31:0] dma_pwdata_i,
    output wire [31:0] dma_prdata_o,
    output wire        dma_pready_o,
    output wire        dma_pslverr_o,

    // =====================================================================
    // DMA peripheral sideband and interrupts - Blocks 7 / 10-21
    // =====================================================================
    input  wire [5:0]  dma_req_i,
    output wire [5:0]  dma_ack_o,
    output wire [5:0]  dma_irq_o,
    output wire [5:0]  dma_err_o,

    // =====================================================================
    // Core CLIC interface and machine timer - Blocks 7 / 20
    // =====================================================================
    input  wire        clic_irq_i,
    input  wire [11:0] clic_irq_id_i,
    input  wire [7:0]  clic_irq_lvl_i,
    input  wire        clic_irq_shv_i,
    output wire        clic_irq_ack_o,
    output wire [11:0] clic_irq_id_ack_o,
    output wire [7:0]  clic_mintthresh_o,

    input  wire [63:0] mtime_i,
    input  wire [63:0] mtimecmp_i,

    // =====================================================================
    // DSU accumulator debug taps (core spec Sec. 15)
    // =====================================================================
    output wire [47:0] dbg_acc_0_o,
    output wire [47:0] dbg_acc_1_o,
    output wire [47:0] dbg_acc_2_o
);

    // -----------------------------------------------------------------------
    // M0 : CPU I-Port
    // -----------------------------------------------------------------------
    wire [31:0] i_haddr, i_hwdata, i_hrdata;
    wire [1:0]  i_htrans;
    wire [2:0]  i_hsize, i_hburst;
    wire [3:0]  i_hprot;
    wire        i_hwrite, i_hready, i_hresp;

    // -----------------------------------------------------------------------
    // M1 : CPU D-Port
    // -----------------------------------------------------------------------
    wire [31:0] d_haddr, d_hwdata, d_hrdata;
    wire [1:0]  d_htrans;
    wire [2:0]  d_hsize, d_hburst;
    wire [3:0]  d_hprot;
    wire        d_hwrite, d_hready, d_hresp;

    // -----------------------------------------------------------------------
    // M2 : DMA. No HPROT - see note 2 in the header.
    // -----------------------------------------------------------------------
    wire [31:0] m_haddr, m_hwdata, m_hrdata;
    wire [1:0]  m_htrans;
    wire [2:0]  m_hsize, m_hburst;
    wire        m_hwrite, m_hready, m_hresp;

    // =======================================================================
    // Block 1 : RV32IM core, with Block 2 (DSU) inside it
    // =======================================================================
    garuda_core_top #(
        .RESET_VECTOR (RESET_VECTOR)
    ) u_core (
        .clk_i   (hclk_i),
        .rst_n_i (hreset_n_i),

        .i_haddr_o (i_haddr), .i_htrans_o(i_htrans), .i_hsize_o (i_hsize),
        .i_hburst_o(i_hburst), .i_hprot_o(i_hprot),  .i_hwrite_o(i_hwrite),
        .i_hwdata_o(i_hwdata),
        .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(i_hresp),

        .d_haddr_o (d_haddr), .d_htrans_o(d_htrans), .d_hsize_o (d_hsize),
        .d_hburst_o(d_hburst), .d_hprot_o(d_hprot),  .d_hwrite_o(d_hwrite),
        .d_hwdata_o(d_hwdata),
        .d_hrdata_i(d_hrdata), .d_hready_i(d_hready), .d_hresp_i(d_hresp),

        .clic_irq_i        (clic_irq_i),
        .clic_irq_id_i     (clic_irq_id_i),
        .clic_irq_lvl_i    (clic_irq_lvl_i),
        .clic_irq_shv_i    (clic_irq_shv_i),
        .clic_irq_ack_o    (clic_irq_ack_o),
        .clic_irq_id_ack_o (clic_irq_id_ack_o),
        .clic_mintthresh_o (clic_mintthresh_o),

        .mtime_i    (mtime_i),
        .mtimecmp_i (mtimecmp_i),

        .dbg_acc_0_o (dbg_acc_0_o),
        .dbg_acc_1_o (dbg_acc_1_o),
        .dbg_acc_2_o (dbg_acc_2_o)
    );

    // =======================================================================
    // Block 9 : six-channel DMA controller
    //
    // Its port list is frozen by GARUDA-DMA-SPEC-001 Sec. 5.7 and drops the
    // _i/_o suffix used everywhere else in rtl/ - the mismatch below is
    // deliberate and documented in dma_top.v's own header.
    // =======================================================================
    dma_top u_dma (
        .hclk     (hclk_i),
        .pclk     (pclk_i),
        .hreset_n (hreset_n_i),
        .preset_n (preset_n_i),

        .psel     (dma_psel_i),
        .penable  (dma_penable_i),
        .pwrite   (dma_pwrite_i),
        .paddr    (dma_paddr_i),
        .pwdata   (dma_pwdata_i),
        .prdata   (dma_prdata_o),
        .pready   (dma_pready_o),
        .pslverr  (dma_pslverr_o),

        .haddr    (m_haddr),
        .htrans   (m_htrans),
        .hwrite   (m_hwrite),
        .hsize    (m_hsize),
        .hburst   (m_hburst),
        .hwdata   (m_hwdata),
        .hrdata   (m_hrdata),
        .hready   (m_hready),
        .hresp    (m_hresp),

        .dma_req  (dma_req_i),
        .dma_ack  (dma_ack_o),
        .dma_irq  (dma_irq_o),
        .dma_err  (dma_err_o)
    );

    // =======================================================================
    // Block 6 : AHB-Lite interconnect
    // =======================================================================
    ahb_interconnect u_ahb (
        .hclk_i     (hclk_i),
        .hreset_n_i (hreset_n_i),

        .i_haddr_i(i_haddr), .i_htrans_i(i_htrans), .i_hwrite_i(i_hwrite),
        .i_hsize_i(i_hsize), .i_hburst_i(i_hburst), .i_hprot_i (i_hprot),
        .i_hwdata_i(i_hwdata),
        .i_hrdata_o(i_hrdata), .i_hready_o(i_hready), .i_hresp_o(i_hresp),

        .d_haddr_i(d_haddr), .d_htrans_i(d_htrans), .d_hwrite_i(d_hwrite),
        .d_hsize_i(d_hsize), .d_hburst_i(d_hburst), .d_hprot_i (d_hprot),
        .d_hwdata_i(d_hwdata),
        .d_hrdata_o(d_hrdata), .d_hready_o(d_hready), .d_hresp_o(d_hresp),

        .m_haddr_i(m_haddr), .m_htrans_i(m_htrans), .m_hwrite_i(m_hwrite),
        .m_hsize_i(m_hsize), .m_hburst_i(m_hburst),
        .m_hwdata_i(m_hwdata),
        .m_hrdata_o(m_hrdata), .m_hready_o(m_hready), .m_hresp_o(m_hresp),

        .hsel_isram_o (hsel_isram_o),
        .hsel_rom_o   (hsel_rom_o),
        .hsel_dsram_o (hsel_dsram_o),
        .hsel_bridge_o(hsel_bridge_o),

        .haddr_o (haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o),
        .hsize_o (hsize_o), .hburst_o(hburst_o), .hprot_o (hprot_o),
        .hwdata_o(hwdata_o), .hready_o(hready_o),

        .hrdata_isram_i (hrdata_isram_i),  .hreadyout_isram_i (hreadyout_isram_i),  .hresp_isram_i (hresp_isram_i),
        .hrdata_rom_i   (hrdata_rom_i),    .hreadyout_rom_i   (hreadyout_rom_i),    .hresp_rom_i   (hresp_rom_i),
        .hrdata_dsram_i (hrdata_dsram_i),  .hreadyout_dsram_i (hreadyout_dsram_i),  .hresp_dsram_i (hresp_dsram_i),
        .hrdata_bridge_i(hrdata_bridge_i), .hreadyout_bridge_i(hreadyout_bridge_i), .hresp_bridge_i(hresp_bridge_i)
    );

endmodule

`default_nettype wire
