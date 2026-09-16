`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge
// ahb2apb_bridge.v - block boundary: AHB-Lite slave S3 <-> APB4 master
//
// Spec reference: GARUDA-BRG-SPEC-001 Rev 2.0, Sec. 3, Sec. 5, Sec. 13.1
//
// =============================================================================
// THIS IS THE SoC's ONLY CLOCK-DOMAIN CROSSING, BY DESIGN
// =============================================================================
// Every 200/100 MHz crossing in GARUDA is concentrated in this one block. The
// alternative - letting each peripheral or the interconnect cross clocks
// locally - would scatter metastability risk across a dozen blocks, each
// needing its own CDC sign-off. Concentrating it here is precisely why the
// core, the interconnect, the DMA and every peripheral can be single-domain and
// timing-trivial. This is inherited from the core specification (Sec. 2.1,
// Sec. 4.3), not invented here, and NO OTHER BLOCK MAY ADD A SECOND CDC SITE.
//
// (The one apparent exception is not one: the CLIC spans pclk and hclk for its
// configuration registers, but Sec. 5.1.1 of that spec establishes those clocks
// as synchronous and integer-related, so it is not an asynchronous crossing and
// instantiates no synchronisers. If the clock relationship ever changes, that
// block needs CDC and this comment needs revisiting - see clk_div.v.)
//
// =============================================================================
// SINGLE-OUTSTANDING AND NON-POSTED (Sec. 13.3)
// =============================================================================
// Exactly one transfer is in flight at a time and the AHB side completes only
// after the APB side has. RTL must not add a write buffer, a posted-write path
// or a second outstanding transaction. Posting would let the CPU retire a store
// before APB finished, which (a) adds a second thing to get right across the
// CDC, (b) breaks the in-order two-cycle-ERROR reporting the interconnect and
// the DMA depend on - a posted write that later errors has no master still
// waiting to receive the fault - and (c) buys nothing measurable, since
// peripheral traffic is around 0.2% of the control-loop budget.
//
// It also makes the bundled-data invariant hold by construction rather than by
// timing argument, which is the quiet benefit that matters most.
//
// =============================================================================
// PORT NOTES
// =============================================================================
// HBURST is not brought to the interface at all (Sec. 5.2, Sec. 13.6): accesses
// to this region are single-beat, so there is no burst to decompose. HPROT is
// dropped because GARUDA is M-mode with no MPU. Both are genuinely absent
// rather than tied off, so a reader cannot mistake them for something consumed.
//
// paddr_o is 16 bits, not 32: the interconnect has already consumed the region
// nibble, and within the bridge only PADDR[15:0] is meaningful - [15:12] picks
// the window, [11:0] the register offset (Sec. 5.3.1).
// =============================================================================

`include "ahb2apb_defs.vh"

module ahb2apb_bridge #(
    parameter [15:0] WINDOW_MASK = `BRG_WINDOW_MASK_DEFAULT
)(
    // ---- clocks and resets (Block 23; coordinated, Sec. 10.1) -------------
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- AHB-Lite slave S3 (frozen bundle, interconnect Sec. 5.3) --------
    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o,

    // ---- APB4 master (Sec. 5.3) -------------------------------------------
    output wire [15:0] psel_o,
    output wire        penable_o,
    output wire        pwrite_o,
    output wire [15:0] paddr_o,
    output wire [31:0] pwdata_o,
    output wire [3:0]  pstrb_o,
    input  wire [31:0] prdata_i,
    input  wire        pready_i,
    input  wire        pslverr_i
);

    // ---- request payload and toggle (hclk -> pclk) ------------------------
    wire [15:0] req_addr;
    wire        req_write;
    wire [3:0]  req_strb;
    wire [31:0] req_wdata;
    wire        req_tog;
    wire        req_pulse;

    // ---- response payload and toggle (pclk -> hclk) -----------------------
    wire [31:0] rsp_rdata;
    wire        rsp_err;
    wire        ack_tog;
    wire        ack_pulse;

    // ---- address-phase decode --------------------------------------------
    wire [3:0]  dec_win;
    wire [15:0] dec_psel_unused;
    wire        dec_err;

    // =======================================================================
    // Address-phase decode. Combinational off the bus address so the decode
    // fault is known at capture time and the access can be faulted without
    // ever crossing to the APB side (Sec. 8.5).
    // =======================================================================
    ahb2apb_decoder #(.WINDOW_MASK(WINDOW_MASK)) u_dec_ap (
        .win_i     (dec_win),
        .psel_o    (dec_psel_unused),
        .dec_err_o (dec_err)
    );

    // =======================================================================
    // hclk side
    // =======================================================================
    ahb2apb_hclk_fsm u_hclk (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .hsel_i      (hsel_i),
        .haddr_i     (haddr_i),
        .htrans_i    (htrans_i),
        .hwrite_i    (hwrite_i),
        .hsize_i     (hsize_i),
        .hwdata_i    (hwdata_i),
        .hready_i    (hready_i),
        .hrdata_o    (hrdata_o),
        .hreadyout_o (hreadyout_o),
        .hresp_o     (hresp_o),
        .req_addr_o  (req_addr),
        .req_write_o (req_write),
        .req_strb_o  (req_strb),
        .req_wdata_o (req_wdata),
        .req_tog_o   (req_tog),
        .rsp_rdata_i (rsp_rdata),
        .rsp_err_i   (rsp_err),
        .ack_pulse_i (ack_pulse),
        .dec_win_o   (dec_win),
        .dec_err_i   (dec_err)
    );

    // =======================================================================
    // pclk side
    // =======================================================================
    ahb2apb_pclk_fsm #(.WINDOW_MASK(WINDOW_MASK)) u_pclk (
        .pclk_i      (pclk_i),
        .preset_n_i  (preset_n_i),
        .req_addr_i  (req_addr),
        .req_write_i (req_write),
        .req_strb_i  (req_strb),
        .req_wdata_i (req_wdata),
        .req_pulse_i (req_pulse),
        .rsp_rdata_o (rsp_rdata),
        .rsp_err_o   (rsp_err),
        .ack_tog_o   (ack_tog),
        .psel_o      (psel_o),
        .penable_o   (penable_o),
        .pwrite_o    (pwrite_o),
        .paddr_o     (paddr_o),
        .pwdata_o    (pwdata_o),
        .pstrb_o     (pstrb_o),
        .prdata_i    (prdata_i),
        .pready_i    (pready_i),
        .pslverr_i   (pslverr_i)
    );

    // =======================================================================
    // The crossing itself. Two toggles, two destination-side synchronisers,
    // and nothing else passes between the domains except payload held stable
    // in registers (Sec. 7.3).
    // =======================================================================
    ahb2apb_cdc u_req_sync (
        .clk_i   (pclk_i),
        .rst_n_i (preset_n_i),
        .tog_i   (req_tog),
        .pulse_o (req_pulse)
    );

    ahb2apb_cdc u_ack_sync (
        .clk_i   (hclk_i),
        .rst_n_i (hreset_n_i),
        .tog_i   (ack_tog),
        .pulse_o (ack_pulse)
    );

    wire _unused = |dec_psel_unused;

endmodule

`default_nettype wire
