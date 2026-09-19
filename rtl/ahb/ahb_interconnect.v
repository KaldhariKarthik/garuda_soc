`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_interconnect.v - block boundary, sub-block wiring, per-master gating
//
// Spec reference: GARUDA-AHB-SPEC-001 Rev 2.0 (GARUDA-AHB-SPEC-001)
//                 Sec. 3.3 (hierarchy), Sec. 5 (ports), Sec. 7.3 (hold rule),
//                 Sec. 8.2 (read-data return), Sec. 10 (reset)
//
// Single shared AHB-Lite layer, 3 masters x 4 slaves + default slave.
//   M0 i_  CPU I-Port   lowest priority, may issue INCR
//   M1 d_  CPU D-Port   SINGLE only
//   M2     DMA          highest priority, SINGLE only, no HPROT at its
//                       boundary (the DMA spec Sec. 5.7 port list is frozen
//                       and drops the _i/_o suffix, hence the bare names)
//
// Port names on the master side carry each master's own frozen prefix exactly
// as that master declares it (Sec. 5.0). This block has no latitude there.
//
// -----------------------------------------------------------------------------
// THE PER-MASTER HOLD RULE  (Sec. 7.3) - and the one addition it needs
// -----------------------------------------------------------------------------
// There is no HBUSREQ/HGRANT here; the masters are plain AHB-Lite. The only
// backpressure available is each master's own HREADY, and Sec. 7.3's rule is
// "a master that is not currently granted sees its <m>hready driven 0". By
// AHB-Lite rules that master then holds HADDR and all control stable, so it
// freezes its pending request until it is selected.
//
// Applied literally that rule DEADLOCKS this SoC, and the deadlock is not
// subtle once seen:
//
//     garuda_iport_ahb_master issues an address phase only when
//         fetch_issue_o = ~redirect_i & i_hready_i & ...
//     i.e. it needs HREADY high to present HTRANS!=IDLE in the first place.
//     The arbiter grants on HTRANS!=IDLE. So an ungranted I-Port cannot
//     request, and a non-requesting master cannot be granted. Out of reset,
//     with the grant parked anywhere but M0, the reset-vector fetch never
//     happens and the SoC is dead with no error anywhere.
//
// The fix is to gate only what actually needs gating. A master is held only
// while it has something in flight to hold:
//
//     pending_m = htrans_m is NONSEQ/SEQ          (an address phase presented)
//              || m owns the data phase now       (a response still owed)
//
//     hready_m  = pending_m ? (hready_shared & entitled_m) : 1'b1
//     entitled_m = (m == grant) || (m owns the data phase)
//
// A master with nothing presented and nothing owed sees HREADY=1 and is free
// to present a transfer next cycle; if it is not granted then, it sees
// HREADY=0 in that cycle and holds, exactly as Sec. 7.3 intends.
//
// That rule, the case where a master owning the data phase IS preempted while
// still presenting, and the one-deep response hold that makes it safe, are all
// implemented in ahb_master_port.v - instantiated three times below. Read that
// file before changing anything about HREADY here; the interaction between
// "HREADY accepts my address phase" and "HREADY completes my data phase" is the
// only genuinely hard thing in this block (ERRATUM AHB-2).
//
// HRESP and HRDATA are returned ONLY to the data-phase owner (Sec. 8.2).
// Driving the shared HRESP to every master would hand a live ERROR to a master
// with no transfer in flight. All three GARUDA masters happen to qualify HRESP
// with their own outstanding-transfer flag, so it would be harmless today -
// which is precisely the kind of "harmless today" that the next master added
// to this bus will not be.
//
// -----------------------------------------------------------------------------
// WHAT THIS BLOCK DOES NOT CONTAIN (Sec. 11)
// -----------------------------------------------------------------------------
// No registers, no CDC, no HMASTLOCK/HBUSREQ/HGRANT, no HPROT decode, no
// crossbar. One 200 MHz domain. All 200/100 MHz crossing lives in the
// AHB-to-APB bridge (Block 8).
// =============================================================================

`include "ahb_defs.vh"

module ahb_interconnect (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // =====================================================================
    // Master side - the interconnect is an AHB-Lite SLAVE to each of these
    // =====================================================================
    // ---- M0 : CPU I-Port ----
    input  wire [31:0] i_haddr_i,
    input  wire [1:0]  i_htrans_i,
    input  wire        i_hwrite_i,
    input  wire [2:0]  i_hsize_i,
    input  wire [2:0]  i_hburst_i,
    input  wire [3:0]  i_hprot_i,
    input  wire [31:0] i_hwdata_i,
    output wire [31:0] i_hrdata_o,
    output wire        i_hready_o,
    output wire        i_hresp_o,

    // ---- M1 : CPU D-Port ----
    input  wire [31:0] d_haddr_i,
    input  wire [1:0]  d_htrans_i,
    input  wire        d_hwrite_i,
    input  wire [2:0]  d_hsize_i,
    input  wire [2:0]  d_hburst_i,
    input  wire [3:0]  d_hprot_i,
    input  wire [31:0] d_hwdata_i,
    output wire [31:0] d_hrdata_o,
    output wire        d_hready_o,
    output wire        d_hresp_o,

    // ---- M2 : Debug SBA (Rev 4.0, no HPROT) ----
    input  wire [31:0] s_haddr_i,
    input  wire [1:0]  s_htrans_i,
    input  wire        s_hwrite_i,
    input  wire [2:0]  s_hsize_i,
    input  wire [2:0]  s_hburst_i,
    input  wire [31:0] s_hwdata_i,
    output wire [31:0] s_hrdata_o,
    output wire        s_hready_o,
    output wire        s_hresp_o,

    // ---- M3 : DMA (no HPROT, Sec. 7.6) ----
    input  wire [31:0] m_haddr_i,
    input  wire [1:0]  m_htrans_i,
    input  wire        m_hwrite_i,
    input  wire [2:0]  m_hsize_i,
    input  wire [2:0]  m_hburst_i,
    input  wire [31:0] m_hwdata_i,
    output wire [31:0] m_hrdata_o,
    output wire        m_hready_o,
    output wire        m_hresp_o,

    // =====================================================================
    // Slave side - the interconnect is an AHB-Lite MASTER to each of these
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
    output wire        hready_o,     // global HREADY to every slave
    output wire        hmaster_is_sba_o, // to ISRAM only: address phase is M2 (R-7, [N-7.14])

    input  wire [31:0] hrdata_isram_i,   input wire hreadyout_isram_i,  input wire hresp_isram_i,
    input  wire [31:0] hrdata_rom_i,     input wire hreadyout_rom_i,    input wire hresp_rom_i,
    input  wire [31:0] hrdata_dsram_i,   input wire hreadyout_dsram_i,  input wire hresp_dsram_i,
    input  wire [31:0] hrdata_bridge_i,  input wire hreadyout_bridge_i, input wire hresp_bridge_i
);

    // =====================================================================
    // Arbiter - all interconnect state lives here plus the dph_sel register
    // =====================================================================
    wire [1:0] grant;
    wire       seq_break;
    wire       dph_valid;
    wire [1:0] dph_master;

    wire [`AHB_NMASTERS*2-1:0] htrans_bus = {m_htrans_i, s_htrans_i, d_htrans_i, i_htrans_i};

    ahb_arbiter u_arb (
        .hclk_i       (hclk_i),
        .hreset_n_i   (hreset_n_i),
        .htrans_i     (htrans_bus),
        .hready_i     (hready_o),
        .grant_o      (grant),
        .seq_break_o  (seq_break),
        .dph_valid_o  (dph_valid),
        .dph_master_o (dph_master)
    );

    // =====================================================================
    // Master mux -> shared slave-side address/control/write-data
    // =====================================================================
    ahb_master_mux u_mmux (
        .grant_i      (grant),
        .dph_master_i (dph_master),
        .seq_break_i  (seq_break),

        .i_haddr_i (i_haddr_i), .i_htrans_i(i_htrans_i), .i_hwrite_i(i_hwrite_i),
        .i_hsize_i (i_hsize_i), .i_hburst_i(i_hburst_i), .i_hprot_i (i_hprot_i),
        .i_hwdata_i(i_hwdata_i),

        .d_haddr_i (d_haddr_i), .d_htrans_i(d_htrans_i), .d_hwrite_i(d_hwrite_i),
        .d_hsize_i (d_hsize_i), .d_hburst_i(d_hburst_i), .d_hprot_i (d_hprot_i),
        .d_hwdata_i(d_hwdata_i),

        .s_haddr_i (s_haddr_i), .s_htrans_i(s_htrans_i), .s_hwrite_i(s_hwrite_i),
        .s_hsize_i (s_hsize_i), .s_hburst_i(s_hburst_i),
        .s_hwdata_i(s_hwdata_i),

        .m_haddr_i (m_haddr_i), .m_htrans_i(m_htrans_i), .m_hwrite_i(m_hwrite_i),
        .m_hsize_i (m_hsize_i), .m_hburst_i(m_hburst_i),
        .m_hwdata_i(m_hwdata_i),

        .haddr_o (haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o),
        .hsize_o (hsize_o), .hburst_o(hburst_o), .hprot_o (hprot_o),
        .hwdata_o(hwdata_o)
    );

    // =====================================================================
    // Address decode (Sec. 6). One-hot for every address, default included.
    // =====================================================================
    wire [`AHB_SEL_W-1:0] hsel;

    ahb_decoder u_dec (
        .haddr_i (haddr_o),
        .hsel_o  (hsel)
    );

    assign hsel_isram_o  = hsel[`AHB_S_ISRAM ];
    assign hsel_rom_o    = hsel[`AHB_S_ROM   ];
    assign hsel_dsram_o  = hsel[`AHB_S_DSRAM ];
    assign hsel_bridge_o = hsel[`AHB_S_BRIDGE];

    // =====================================================================
    // Default slave (Sec. 8.4)
    // =====================================================================
    wire [31:0] hrdata_df;
    wire        hreadyout_df;
    wire        hresp_df;

    ahb_default_slave u_def (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .hsel_i      (hsel[`AHB_S_DEFAULT]),
        .htrans_i    (htrans_o),
        .hready_i    (hready_o),
        .hrdata_o    (hrdata_df),
        .hreadyout_o (hreadyout_df),
        .hresp_o     (hresp_df)
    );

    // =====================================================================
    // Return path (Sec. 7.5, Sec. 8.2)
    // =====================================================================
    wire [31:0] hrdata_shared;
    wire        hresp_shared;

    ahb_slave_mux u_smux (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .hsel_i      (hsel),
        .dph_valid_i (dph_valid),

        .hrdata_s0_i(hrdata_isram_i),  .hreadyout_s0_i(hreadyout_isram_i),  .hresp_s0_i(hresp_isram_i),
        .hrdata_s1_i(hrdata_rom_i),    .hreadyout_s1_i(hreadyout_rom_i),    .hresp_s1_i(hresp_rom_i),
        .hrdata_s2_i(hrdata_dsram_i),  .hreadyout_s2_i(hreadyout_dsram_i),  .hresp_s2_i(hresp_dsram_i),
        .hrdata_s3_i(hrdata_bridge_i), .hreadyout_s3_i(hreadyout_bridge_i), .hresp_s3_i(hresp_bridge_i),
        .hrdata_df_i(hrdata_df),       .hreadyout_df_i(hreadyout_df),       .hresp_df_i(hresp_df),

        .hrdata_o    (hrdata_shared),
        .hresp_o     (hresp_shared),
        .hready_o    (hready_o),
        // dph_sel_o is deliberately left unconnected. It exists so that
        // tb/cov/ can bind to the registered data-phase select and cover
        // Sec. 12's "data-phase select" and "decode coverage" rows without
        // any RTL edit - the same pattern dma_channel_fsm.state_o uses.
        .dph_sel_o   ()
    );

    // =====================================================================
    // Per-master gating and response hold (Sec. 7.3, Sec. 8.2)
    //
    // One ahb_master_port per master. Everything about "what does master m see
    // on its HREADY/HRDATA/HRESP" lives there, including the response capture
    // that makes preemption of a continuously-requesting master safe
    // (ERRATUM AHB-2). Instantiating it three times rather than writing three
    // sets of expressions here is deliberate: the rule is subtle enough that
    // three copies of it would eventually stop being three copies.
    // =====================================================================
    wire i_dph = dph_valid && (dph_master == `AHB_M_IPORT);
    wire d_dph = dph_valid && (dph_master == `AHB_M_DPORT);
    wire s_dph = dph_valid && (dph_master == `AHB_M_SBA  );
    wire m_dph = dph_valid && (dph_master == `AHB_M_DMA  );

    assign hmaster_is_sba_o = (grant == `AHB_M_SBA);

    ahb_master_port u_mp_i (
        .hclk_i          (hclk_i),
        .hreset_n_i      (hreset_n_i),
        .htrans_i        (i_htrans_i),
        .granted_i       (grant == `AHB_M_IPORT),
        .dph_own_i       (i_dph),
        .hready_shared_i (hready_o),
        .hrdata_shared_i (hrdata_shared),
        .hresp_shared_i  (hresp_shared),
        .hready_o        (i_hready_o),
        .hrdata_o        (i_hrdata_o),
        .hresp_o         (i_hresp_o)
    );

    ahb_master_port u_mp_d (
        .hclk_i          (hclk_i),
        .hreset_n_i      (hreset_n_i),
        .htrans_i        (d_htrans_i),
        .granted_i       (grant == `AHB_M_DPORT),
        .dph_own_i       (d_dph),
        .hready_shared_i (hready_o),
        .hrdata_shared_i (hrdata_shared),
        .hresp_shared_i  (hresp_shared),
        .hready_o        (d_hready_o),
        .hrdata_o        (d_hrdata_o),
        .hresp_o         (d_hresp_o)
    );

    ahb_master_port u_mp_s (
        .hclk_i          (hclk_i),
        .hreset_n_i      (hreset_n_i),
        .htrans_i        (s_htrans_i),
        .granted_i       (grant == `AHB_M_SBA),
        .dph_own_i       (s_dph),
        .hready_shared_i (hready_o),
        .hrdata_shared_i (hrdata_shared),
        .hresp_shared_i  (hresp_shared),
        .hready_o        (s_hready_o),
        .hrdata_o        (s_hrdata_o),
        .hresp_o         (s_hresp_o)
    );

    ahb_master_port u_mp_m (
        .hclk_i          (hclk_i),
        .hreset_n_i      (hreset_n_i),
        .htrans_i        (m_htrans_i),
        .granted_i       (grant == `AHB_M_DMA),
        .dph_own_i       (m_dph),
        .hready_shared_i (hready_o),
        .hrdata_shared_i (hrdata_shared),
        .hresp_shared_i  (hresp_shared),
        .hready_o        (m_hready_o),
        .hrdata_o        (m_hrdata_o),
        .hresp_o         (m_hresp_o)
    );

endmodule

`default_nettype wire
