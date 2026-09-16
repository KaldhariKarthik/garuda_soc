`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - top-level integration
// garuda_soc_top.v - core (+DSU) + DMA + interconnect + memories + bridge + CLIC
//
// Specs: GARUDA-CORE-SPEC-001 (Block 1), DSU (Block 2, inside the core),
//        GARUDA-MEM-SPEC-001 Rev 2.0 (Blocks 3/4/5), GARUDA-AHB-SPEC-001 Rev 2.0
//        (Block 6), GARUDA-BRG-SPEC-001 Rev 2.0 (Block 8),
//        GARUDA-DMA-SPEC-001 Rev 2.0 (Block 9), GARUDA-CLIC-SPEC-001 Rev 2.0
//        (Block 16)
//
// =============================================================================
// WHAT CHANGED, AND WHY THE PORT LIST SHRANK
// =============================================================================
// The previous revision of this file exposed the four AHB slave ports, the
// DMA's APB configuration port and the core's CLIC interface at this boundary,
// because Blocks 3/4/5, 8 and 16 had no RTL and the testbench had to supply
// models. Its own header said those groups would "move inside this module and
// disappear from the port list" when the specifications arrived.
//
// They have arrived and they have. The memories, the bridge and the CLIC are
// now instantiated here, and what remains at the boundary is what genuinely
// leaves the chip or does not exist yet:
//
//   - the APB expansion bus, for Blocks 10-15 and 18-21 (SPI/I2C/UART/PWM/
//     GPIO/timers). Those are real peripherals with no RTL, so their windows
//     are brought out rather than guessed at.
//   - the DMA peripheral sideband (dma_req/dma_ack), which terminates on those
//     same peripherals.
//   - the external interrupt sources above the DMA's twelve.
//   - the machine timer inputs, which belong to Block 20.
//   - the DSU accumulator debug taps (core Sec. 15).
//
// Clocks and resets are still inputs. Blocks 22 and 23 exist now, but they are
// instantiated one level up in garuda_chip_top.v, not here - a reset controller
// inside the block it resets makes the SoC impossible to test from a bench that
// wants to drive reset directly.
//
// =============================================================================
// THE INTERRUPT PATH IS LIVE FOR THE FIRST TIME
// =============================================================================
// Until now tb_soc_ahb.sv tied the core's clic_irq_i low and delivered no
// interrupts at all, so the entire interrupt path - the DMA raising a
// completion, the CLIC arbitrating it, the core taking the trap and
// acknowledging it - was unexercised by construction. The DMA's twelve lines
// now reach the CLIC and the CLIC reaches the core.
//
// =============================================================================
// APB FAN-OUT
// =============================================================================
// The bridge drives a one-hot PSEL, one bit per 4 KB window, and a shared
// address/data/strobe bundle. Two slaves are internal: the DMA at window 5
// (FROZEN by DMA Sec. 1.1) and the CLIC at window 9. The return path is a mux
// on the same one-hot select.
//
// A window with no slave behind it never asserts a PSEL bit at all - the bridge
// decoder masks it and raises a decode error instead, producing the mandatory
// two-cycle ERROR upstream (BRG Sec. 8.5). So the expansion bus below carries
// PSEL bits that are simply never set until WINDOW_MASK is widened as each
// peripheral lands. That is deliberate: an access to a peripheral that does not
// exist should fault, not hang and not silently read zero.
// =============================================================================

`include "ahb2apb_defs.vh"
`include "clic_defs.vh"

module garuda_soc_top #(
    parameter [31:0] RESET_VECTOR   = 32'h1000_0000,  // Boot ROM, core Sec. 17
    parameter        BROM_INIT_FILE = "",             // mask ROM contents
    parameter integer CLIC_N        = 32,
    parameter [15:0] APB_WINDOW_MASK = `BRG_WINDOW_MASK_DEFAULT
)(
    // ---- clocks and resets (from Blocks 22/23, one level up) --------------
    input  wire        hclk_i,        // 200 MHz
    input  wire        pclk_i,        // 100 MHz
    input  wire        hreset_n_i,
    input  wire        preset_n_i,

    // =====================================================================
    // APB expansion bus - Blocks 10-15, 18-21 (no RTL yet)
    // =====================================================================
    output wire [15:0] apb_psel_o,
    output wire        apb_penable_o,
    output wire        apb_pwrite_o,
    output wire [15:0] apb_paddr_o,
    output wire [31:0] apb_pwdata_o,
    output wire [3:0]  apb_pstrb_o,
    input  wire [31:0] apb_prdata_i,
    input  wire        apb_pready_i,
    input  wire        apb_pslverr_i,

    // =====================================================================
    // DMA peripheral sideband - terminates on Blocks 10-15
    // =====================================================================
    input  wire [5:0]  dma_req_i,
    output wire [5:0]  dma_ack_o,

    // =====================================================================
    // External interrupt sources above the DMA's twelve (Blocks 10-15, 18-21)
    // =====================================================================
    input  wire [CLIC_N-13:0] irq_ext_i,

    // =====================================================================
    // Machine timer - Block 20
    // =====================================================================
    input  wire [63:0] mtime_i,
    input  wire [63:0] mtimecmp_i,

    // =====================================================================
    // Watchdog reset request, passed up to Block 23 - Block 19
    // =====================================================================
    output wire        wdt_reset_o,

    // =====================================================================
    // DSU accumulator debug taps (core Sec. 15)
    // =====================================================================
    output wire [47:0] dbg_acc_0_o,
    output wire [47:0] dbg_acc_1_o,
    output wire [47:0] dbg_acc_2_o
);

    // -----------------------------------------------------------------------
    // Master-side buses
    // -----------------------------------------------------------------------
    wire [31:0] i_haddr, i_hwdata, i_hrdata;
    wire [1:0]  i_htrans;
    wire [2:0]  i_hsize, i_hburst;
    wire [3:0]  i_hprot;
    wire        i_hwrite, i_hready, i_hresp;

    wire [31:0] d_haddr, d_hwdata, d_hrdata;
    wire [1:0]  d_htrans;
    wire [2:0]  d_hsize, d_hburst;
    wire [3:0]  d_hprot;
    wire        d_hwrite, d_hready, d_hresp;

    wire [31:0] m_haddr, m_hwdata, m_hrdata;
    wire [1:0]  m_htrans;
    wire [2:0]  m_hsize, m_hburst;
    wire        m_hwrite, m_hready, m_hresp;

    // -----------------------------------------------------------------------
    // Shared slave-side bundle
    // -----------------------------------------------------------------------
    wire        hsel_isram, hsel_rom, hsel_dsram, hsel_bridge;
    wire [31:0] haddr, hwdata;
    wire [1:0]  htrans;
    wire        hwrite, hready;
    wire [2:0]  hsize, hburst;
    wire [3:0]  hprot;

    wire [31:0] hrdata_isram, hrdata_rom, hrdata_dsram, hrdata_bridge;
    wire        hreadyout_isram, hreadyout_rom, hreadyout_dsram, hreadyout_bridge;
    wire        hresp_isram, hresp_rom, hresp_dsram, hresp_bridge;

    // -----------------------------------------------------------------------
    // CLIC sideband
    // -----------------------------------------------------------------------
    wire                        clic_irq;
    wire [`CLIC_CORE_ID_W-1:0]  clic_irq_id;
    wire [`CLIC_CORE_LVL_W-1:0] clic_irq_lvl;
    wire                        clic_irq_shv;
    wire                        clic_irq_ack;
    wire [`CLIC_CORE_ID_W-1:0]  clic_irq_id_ack;
    wire [`CLIC_CORE_LVL_W-1:0] clic_mintthresh;

    wire [5:0] dma_irq, dma_err;

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

        .clic_irq_i        (clic_irq),
        .clic_irq_id_i     (clic_irq_id),
        .clic_irq_lvl_i    (clic_irq_lvl),
        .clic_irq_shv_i    (clic_irq_shv),
        .clic_irq_ack_o    (clic_irq_ack),
        .clic_irq_id_ack_o (clic_irq_id_ack),
        .clic_mintthresh_o (clic_mintthresh),

        .mtime_i    (mtime_i),
        .mtimecmp_i (mtimecmp_i),

        .dbg_acc_0_o (dbg_acc_0_o),
        .dbg_acc_1_o (dbg_acc_1_o),
        .dbg_acc_2_o (dbg_acc_2_o)
    );

    // =======================================================================
    // Block 9 : six-channel DMA controller
    //
    // Its port list is frozen by DMA Sec. 5.7 and drops the _i/_o suffix used
    // everywhere else - deliberate, and documented in dma_top.v's own header.
    // =======================================================================
    wire        dma_psel;
    wire [31:0] dma_prdata;
    wire        dma_pready, dma_pslverr;

    wire        apb_penable, apb_pwrite;
    wire [15:0] apb_paddr;
    wire [31:0] apb_pwdata;
    wire [3:0]  apb_pstrb;
    wire [15:0] apb_psel;

    dma_top u_dma (
        .hclk     (hclk_i),
        .pclk     (pclk_i),
        .hreset_n (hreset_n_i),
        .preset_n (preset_n_i),

        .psel     (dma_psel),
        .penable  (apb_penable),
        .pwrite   (apb_pwrite),
        .paddr    (apb_paddr[7:0]),
        .pwdata   (apb_pwdata),
        .prdata   (dma_prdata),
        .pready   (dma_pready),
        .pslverr  (dma_pslverr),

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
        .dma_irq  (dma_irq),
        .dma_err  (dma_err)
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

        .hsel_isram_o (hsel_isram),
        .hsel_rom_o   (hsel_rom),
        .hsel_dsram_o (hsel_dsram),
        .hsel_bridge_o(hsel_bridge),

        .haddr_o (haddr), .htrans_o(htrans), .hwrite_o(hwrite),
        .hsize_o (hsize), .hburst_o(hburst), .hprot_o (hprot),
        .hwdata_o(hwdata), .hready_o(hready),

        .hrdata_isram_i (hrdata_isram),  .hreadyout_isram_i (hreadyout_isram),  .hresp_isram_i (hresp_isram),
        .hrdata_rom_i   (hrdata_rom),    .hreadyout_rom_i   (hreadyout_rom),    .hresp_rom_i   (hresp_rom),
        .hrdata_dsram_i (hrdata_dsram),  .hreadyout_dsram_i (hreadyout_dsram),  .hresp_dsram_i (hresp_dsram),
        .hrdata_bridge_i(hrdata_bridge), .hreadyout_bridge_i(hreadyout_bridge), .hresp_bridge_i(hresp_bridge)
    );

    // =======================================================================
    // Block 3 : Instruction SRAM (S0)
    // =======================================================================
    isram_top u_isram (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .hsel_i      (hsel_isram),
        .haddr_i     (haddr),
        .htrans_i    (htrans),
        .hwrite_i    (hwrite),
        .hsize_i     (hsize),
        .hburst_i    (hburst),
        .hprot_i     (hprot),
        .hwdata_i    (hwdata),
        .hready_i    (hready),
        .hrdata_o    (hrdata_isram),
        .hreadyout_o (hreadyout_isram),
        .hresp_o     (hresp_isram)
    );

    // =======================================================================
    // Block 5 : Boot ROM (S1) - holds the reset vector
    // =======================================================================
    bootrom_top #(
        .INIT_FILE (BROM_INIT_FILE)
    ) u_brom (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .hsel_i      (hsel_rom),
        .haddr_i     (haddr),
        .htrans_i    (htrans),
        .hwrite_i    (hwrite),
        .hsize_i     (hsize),
        .hburst_i    (hburst),
        .hprot_i     (hprot),
        .hwdata_i    (hwdata),
        .hready_i    (hready),
        .hrdata_o    (hrdata_rom),
        .hreadyout_o (hreadyout_rom),
        .hresp_o     (hresp_rom)
    );

    // =======================================================================
    // Block 4 : Data SRAM (S2), 4 banks, NO bank arbiter - see dsram_top.v
    // =======================================================================
    dsram_top u_dsram (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .hsel_i      (hsel_dsram),
        .haddr_i     (haddr),
        .htrans_i    (htrans),
        .hwrite_i    (hwrite),
        .hsize_i     (hsize),
        .hburst_i    (hburst),
        .hprot_i     (hprot),
        .hwdata_i    (hwdata),
        .hready_i    (hready),
        .hrdata_o    (hrdata_dsram),
        .hreadyout_o (hreadyout_dsram),
        .hresp_o     (hresp_dsram)
    );

    // =======================================================================
    // Block 8 : AHB-to-APB bridge (S3) - the SoC's only CDC site
    // =======================================================================
    wire [31:0] apb_prdata_mux;
    wire        apb_pready_mux;
    wire        apb_pslverr_mux;

    ahb2apb_bridge #(
        .WINDOW_MASK (APB_WINDOW_MASK)
    ) u_bridge (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .pclk_i      (pclk_i),
        .preset_n_i  (preset_n_i),

        .hsel_i      (hsel_bridge),
        .haddr_i     (haddr),
        .htrans_i    (htrans),
        .hwrite_i    (hwrite),
        .hsize_i     (hsize),
        .hwdata_i    (hwdata),
        .hready_i    (hready),
        .hrdata_o    (hrdata_bridge),
        .hreadyout_o (hreadyout_bridge),
        .hresp_o     (hresp_bridge),

        .psel_o      (apb_psel),
        .penable_o   (apb_penable),
        .pwrite_o    (apb_pwrite),
        .paddr_o     (apb_paddr),
        .pwdata_o    (apb_pwdata),
        .pstrb_o     (apb_pstrb),
        .prdata_i    (apb_prdata_mux),
        .pready_i    (apb_pready_mux),
        .pslverr_i   (apb_pslverr_mux)
    );

    // =======================================================================
    // Block 16 : CLIC
    //
    // Source map (CLIC Sec. 6.2): the DMA takes the first twelve so its
    // complete/error pairs stay contiguous and easy to reason about.
    //   [5:0]   dma_irq  - channel complete
    //   [11:6]  dma_err  - channel bus error
    //   [CLIC_N-1:12]    - peripherals and timers, from outside
    // =======================================================================
    wire [CLIC_N-1:0] irq_src;
    assign irq_src = {irq_ext_i, dma_err, dma_irq};

    wire        clic_psel;
    wire [31:0] clic_prdata;
    wire        clic_pready, clic_pslverr;

    clic_top #(
        .CLIC_N (CLIC_N),
        .ID_W   (5)
    ) u_clic (
        .clk_i             (hclk_i),
        .rst_n_i           (hreset_n_i),
        .pclk_i            (pclk_i),
        .preset_n_i        (preset_n_i),

        .psel_i            (clic_psel),
        .penable_i         (apb_penable),
        .pwrite_i          (apb_pwrite),
        .paddr_i           (apb_paddr[11:0]),
        .pwdata_i          (apb_pwdata),
        .prdata_o          (clic_prdata),
        .pready_o          (clic_pready),
        .pslverr_o         (clic_pslverr),

        .irq_src_i         (irq_src),

        .clic_irq_o        (clic_irq),
        .clic_irq_id_o     (clic_irq_id),
        .clic_irq_lvl_o    (clic_irq_lvl),
        .clic_irq_shv_o    (clic_irq_shv),
        .clic_irq_ack_i    (clic_irq_ack),
        .clic_irq_id_ack_i (clic_irq_id_ack),
        .mintthresh_i      (clic_mintthresh)
    );

    // =======================================================================
    // APB fan-out and return mux
    //
    // The bridge's PSEL is already one-hot and already masked to implemented
    // windows, so selecting a slave is a bit pick, not a decode. The return mux
    // defaults to the expansion bus so that a window brought out of the chip
    // behaves normally once a peripheral is attached to it.
    // =======================================================================
    assign dma_psel  = apb_psel[`BRG_WIN_DMA];
    assign clic_psel = apb_psel[`BRG_WIN_CLIC];

    assign apb_prdata_mux  = dma_psel  ? dma_prdata   :
                             clic_psel ? clic_prdata  : apb_prdata_i;
    assign apb_pready_mux  = dma_psel  ? dma_pready   :
                             clic_psel ? clic_pready  : apb_pready_i;
    assign apb_pslverr_mux = dma_psel  ? dma_pslverr  :
                             clic_psel ? clic_pslverr : apb_pslverr_i;

    // Expansion bus: the full bundle goes out; the internal windows are simply
    // also visible on it, which costs nothing and makes external monitoring of
    // the DMA/CLIC configuration traffic possible without probing inside.
    assign apb_psel_o    = apb_psel;
    assign apb_penable_o = apb_penable;
    assign apb_pwrite_o  = apb_pwrite;
    assign apb_paddr_o   = apb_paddr;
    assign apb_pwdata_o  = apb_pwdata;
    assign apb_pstrb_o   = apb_pstrb;

    // Block 19 does not exist yet; the watchdog request is brought out so
    // garuda_chip_top can route it to the reset controller, and tied low here
    // rather than left floating.
    assign wdt_reset_o = 1'b0;

endmodule

`default_nettype wire
