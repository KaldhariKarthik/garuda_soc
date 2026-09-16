`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 16: CLIC (Core-Local Interrupt Controller)
// clic_top.v - block boundary
//
// Spec reference: GARUDA-CLIC-SPEC-001 Rev 2.0, Sec. 3, Sec. 5, Sec. 8, Sec. 11
//
// =============================================================================
// WHAT THIS BLOCK IS - AND WHAT IT IS NOT
// =============================================================================
// This is the one EXTERNAL interrupt controller in GARUDA. It collects every
// peripheral interrupt line, applies enable/priority/threshold policy, and
// presents the single highest-priority pending source to the CPU over the
// frozen CLIC sideband.
//
// It is NOT the core's trap CSRs. mstatus/mie/mip/mtvec/mcause/mepc live inside
// Block 1, every RISC-V hart has them, and they are the core's privileged trap
// plumbing - not a second CLIC. Calling that block "a CLIC" is a category error
// the naming here is careful to avoid. The split is deliberate (Sec. 13.1): the
// core owns architectural trap state because the ISA defines it; this block
// owns POLICY - which sources, what priority - because that is SoC integration
// state that changes as peripherals are added. Splitting them keeps the core
// boundary frozen while letting the interrupt map grow.
//
// =============================================================================
// FLAGGED, CARRIED FORWARD: GENUINELY ASYNCHRONOUS SOURCES (Sec. 11.1)
// =============================================================================
// Every source line is sampled DIRECTLY in clk_i. That is correct for sources
// generated in either on-chip clock domain, because pclk is a ÷2 of clk from
// the same source and the two are related (Sec. 5.1.1).
//
// It is NOT correct for a source genuinely asynchronous to clk_i - the clearest
// candidate being a GPIO interrupt driven from an external pad, whose edge
// bears no relationship to any internal clock. Such a source MUST be passed
// through a two-flop synchroniser BEFORE it reaches this block, and an
// edge-triggered pad input additionally needs the edge detected AFTER the
// synchroniser, never before.
//
// This block assumes every line arriving at irq_src_i is already clean and
// clk_i-relatable. The GPIO specification must state explicitly whether the pad
// interrupt is synchronised inside the GPIO block or is expected to arrive raw
// here - and if raw, a synchroniser must be added at this boundary. Tracked in
// docs/DECISIONS.md under carried-forward open items. Nothing in the current
// SoC trips it: the only sources wired today are the DMA's twelve, which are
// generated in clk_i.
//
// =============================================================================
// THE THREE PRIORITY SYSTEMS - DO NOT CONFLATE THEM (Sec. 10.1)
// =============================================================================
//   DMA arbiter         decides which DMA CHANNEL gets the AHB bus. Block 9.
//   DMA IRQ aggregator  a passive collector that ORs channel flags into the
//                       dma_irq/dma_err lines. No prioritisation at all.
//   CLIC (this block)   decides which interrupt SOURCE the CPU services, by
//                       level. The dma_irq/dma_err lines are just twelve of
//                       its inputs.
// =============================================================================

`include "clic_defs.vh"

module clic_top #(
    parameter integer CLIC_N = `CLIC_N_DEFAULT,
    parameter integer ID_W   = 5                  // ceil(log2(CLIC_N))
)(
    // ---- clocks and resets ------------------------------------------------
    input  wire        clk_i,          // 200 MHz: fabric and core presentation
    input  wire        rst_n_i,
    input  wire        pclk_i,         // 100 MHz: APB configuration port
    input  wire        preset_n_i,

    // ---- APB v3 configuration slave (behind Block 8) ----------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- interrupt sources (Sec. 5.4) -------------------------------------
    // GARUDA mapping: [5:0] = dma_irq, [11:6] = dma_err, then peripherals.
    input  wire [CLIC_N-1:0] irq_src_i,

    // ---- core sideband (frozen names, core Sec. 4.1) ----------------------
    output wire                        clic_irq_o,
    output wire [`CLIC_CORE_ID_W-1:0]  clic_irq_id_o,
    output wire [`CLIC_CORE_LVL_W-1:0] clic_irq_lvl_o,
    output wire                        clic_irq_shv_o,
    input  wire                        clic_irq_ack_i,
    input  wire [`CLIC_CORE_ID_W-1:0]  clic_irq_id_ack_i,
    input  wire [`CLIC_CORE_LVL_W-1:0] mintthresh_i
);

    // -----------------------------------------------------------------------
    // Configuration registers (pclk domain)
    // -----------------------------------------------------------------------
    wire [CLIC_N-1:0]               ie;
    wire [CLIC_N-1:0]               trig;
    wire [CLIC_N-1:0]               shv;
    wire [(CLIC_N*`CLIC_LVL_W)-1:0] lvl_flat;
    wire [CLIC_N-1:0]               ip;
    wire [CLIC_N-1:0]               ip_w1c;

    clic_apb_regs #(.CLIC_N(CLIC_N)) u_regs (
        .pclk_i     (pclk_i),
        .preset_n_i (preset_n_i),
        .psel_i     (psel_i),
        .penable_i  (penable_i),
        .pwrite_i   (pwrite_i),
        .paddr_i    (paddr_i),
        .pwdata_i   (pwdata_i),
        .prdata_o   (prdata_o),
        .pready_o   (pready_o),
        .pslverr_o  (pslverr_o),
        .ie_o       (ie),
        .trig_o     (trig),
        .shv_o      (shv),
        .lvl_flat_o (lvl_flat),
        .ip_i       (ip),
        .ip_w1c_o   (ip_w1c)
    );

    // -----------------------------------------------------------------------
    // Acknowledge decode (Sec. 1.4 - NORMATIVE)
    //
    // The acknowledge is a one-cycle pulse from the core naming the taken id.
    // It MUST clear the pending state of EXACTLY that source and MUST NOT
    // disturb any other. A decode that cleared a range, or that cleared the
    // current winner rather than the acknowledged id, would drop a
    // higher-priority source that went pending in the same cycle the core took
    // a lower one - and that loss is silent.
    // -----------------------------------------------------------------------
    wire [CLIC_N-1:0] ack_clr;

    genvar a;
    generate
        for (a = 0; a < CLIC_N; a = a + 1) begin : g_ack
            assign ack_clr[a] = clic_irq_ack_i &&
                                (clic_irq_id_ack_i == a[`CLIC_CORE_ID_W-1:0]);
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Per-source conditioning (clk domain)
    // -----------------------------------------------------------------------
    generate
        for (a = 0; a < CLIC_N; a = a + 1) begin : g_src
            clic_source_cond u_cond (
                .clk_i      (clk_i),
                .rst_n_i    (rst_n_i),
                .src_i      (irq_src_i[a]),
                .trig_i     (trig[a]),
                .ack_clr_i  (ack_clr[a]),
                .w1c_clr_i  (ip_w1c[a]),
                .ip_o       (ip[a])
            );
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Arbitration (combinational) and presentation (registered)
    // -----------------------------------------------------------------------
    wire                    winner_valid;
    wire [ID_W-1:0]         winner_id;
    wire [`CLIC_LVL_W-1:0]  winner_lvl;

    clic_arbiter #(.CLIC_N(CLIC_N), .ID_W(ID_W)) u_arb (
        .ip_i           (ip),
        .ie_i           (ie),
        .lvl_flat_i     (lvl_flat),
        .winner_valid_o (winner_valid),
        .winner_id_o    (winner_id),
        .winner_lvl_o   (winner_lvl)
    );

    // shv for the winning source. A mux on the recovered id rather than a
    // parallel tree - one tree decides the winner, everything else is a lookup
    // against that single answer (Sec. 7.2).
    wire winner_shv = shv[winner_id];

    clic_present #(.ID_W(ID_W)) u_present (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),
        .winner_valid_i (winner_valid),
        .winner_id_i    (winner_id),
        .winner_lvl_i   (winner_lvl),
        .winner_shv_i   (winner_shv),
        .mintthresh_i   (mintthresh_i),
        .clic_irq_o     (clic_irq_o),
        .clic_irq_id_o  (clic_irq_id_o),
        .clic_irq_lvl_o (clic_irq_lvl_o),
        .clic_irq_shv_o (clic_irq_shv_o)
    );

    // -----------------------------------------------------------------------
    // Simulation-only invariants from Sec. 12's assertion set.
    // -----------------------------------------------------------------------
`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_n_i && clic_irq_o && (clic_irq_lvl_o == {`CLIC_CORE_LVL_W{1'b0}}))
            $display("[CLIC-ASSERT] request asserted with a level-0 winner t=%0t",
                     $time);
        if (rst_n_i && clic_irq_ack_i &&
            (clic_irq_id_ack_i >= CLIC_N[`CLIC_CORE_ID_W-1:0]))
            $display("[CLIC-ASSERT] ack for unimplemented id %0d t=%0t",
                     clic_irq_id_ack_i, $time);
    end
`endif

endmodule

`default_nettype wire
