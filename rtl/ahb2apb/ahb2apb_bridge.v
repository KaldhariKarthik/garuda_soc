`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 8 : AHB-Lite to APB3 bridge (with Block 7, the APB fabric)
// ahb2apb_bridge.v - AHB slave side (hclk) + instances of the APB FSM (pclk)
//                    and the fabric
//
// Spec: GARUDA-AHB2APB-SPEC-001 Rev 2.0 (Rev 4.0 set)
//       Rulings: Docs/DECISIONS.md D-5 (synchronous pclk), D-6 (window map)
//
// -----------------------------------------------------------------------------
// WHAT CHANGED FROM THE REV 2.0-SET BRIDGE (2026-09-16)
// -----------------------------------------------------------------------------
// The previous bridge treated pclk as asynchronous and crossed it with toggle
// synchronisers (ahb2apb_cdc.v). Under Rev 4.0 pclk is hclk/2 from a toggle
// flop: every pclk edge is an hclk edge ([N-7.4]), so every path between the
// two sides is an ordinary synchronous path timed by STA. The synchronisers are
// gone; the request/acknowledge toggles below remain only as an EVENT
// protocol - they make "one request, one response" independent of the hclk:pclk
// ratio, so a two-hclk-long pclk DONE can never be seen as two completions
// (the failure mode behind erratum BRG-1).
//
// -----------------------------------------------------------------------------
// WINDOWS (D-6)
// -----------------------------------------------------------------------------
// PSEL bit n = haddr[15:12] = window n at 0x4000_0000 + 0x1000*n. Windows are
// present when WINDOW_MASK[n] is set. Window 0 (the removed SPI slave) and
// 0xC-0xF never exist. An access to an absent window, a sub-word access, a
// PSLVERR and a 16-pclk PREADY timeout all return the same two-cycle AHB ERROR
// ([N-7.21]) and generate no APB transfer for the first two.
//
// -----------------------------------------------------------------------------
// hclk-SIDE SEQUENCE
// -----------------------------------------------------------------------------
//   H_IDLE  hreadyout=1. Accept a transfer: bad -> H_ERR1, good -> H_CAPT.
//   H_CAPT  data phase cycle 1: capture hwdata, toggle req. hreadyout=0.
//   H_WAIT  hreadyout=0 until the APB side toggles ack.
//   H_OK    hreadyout=1, hresp=OKAY, hrdata = captured PRDATA.
//   H_ERR1  hreadyout=0, hresp=ERROR.
//   H_ERR2  hreadyout=1, hresp=ERROR.
//
// The capture registers (addr/win/write/wdata) change only in H_IDLE/H_CAPT,
// i.e. only while the APB side is idle, so they are stable whenever the pclk
// FSM samples them ([N-7.8], a_capture_stable_at_phase). pclk_phase_i is
// therefore not needed for correctness and is kept on the port list for the
// assertion and the spec's interface contract.
//
// Reset ([N-9.2], [N-9.3]): hreadyout resets low and is released only once
// both hreset_n and preset_n are deasserted. preset_n is sampled on hclk
// directly - it releases on a pclk edge, which is an hclk edge.
// =============================================================================

module ahb2apb_bridge #(
    parameter [15:0] WINDOW_MASK = 16'h0FFE,      // GARUDA_APB_WINDOW_MASK_ALL
    parameter [23:0] APB_DIV     = 24'h0,         // 2 bits per window 0..11
    parameter integer TIMEOUT    = 16             // GARUDA_APB_TIMEOUT_PCLK
)(
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        pclk_i,
    input  wire        preset_n_i,
    input  wire        pclk_phase_i,

    // ---- AHB-Lite slave ------------------------------------------------------
    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,
    output reg  [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o,

    // ---- APB3 master (pclk), one PSEL per window ----------------------------
    output wire [11:0] psel_o,
    output wire        penable_o,
    output wire        pwrite_o,
    output wire [11:0] paddr_o,
    output wire [31:0] pwdata_o,
    input  wire [12*32-1:0] prdata_i,             // window n at [32n +: 32]
    input  wire [11:0] pready_i,
    input  wire [11:0] pslverr_i
);

    localparam [2:0] H_IDLE = 3'd0, H_CAPT = 3'd1, H_WAIT = 3'd2,
                     H_OK   = 3'd3, H_ERR1 = 3'd4, H_ERR2 = 3'd5;

    // =========================================================================
    // Reset release gate
    // =========================================================================
    reg prst_ok_q;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) prst_ok_q <= 1'b0;
        else             prst_ok_q <= preset_n_i;

    // =========================================================================
    // Address-phase decode
    // =========================================================================
    wire [3:0] win     = haddr_i[15:12];
    wire       win_ok  = WINDOW_MASK[win];
    wire       word_ok = (hsize_i == 3'b010);
    wire       xfer    = hsel_i & htrans_i[1] & hready_i;

    // =========================================================================
    // hclk-side FSM and capture
    // =========================================================================
    reg  [2:0]  hstate;
    reg  [3:0]  win_cap;
    reg  [11:0] addr_cap;
    reg         write_cap;
    reg  [31:0] wdata_cap;
    reg         req_tgl;

    wire        ack_tgl;
    wire        apb_err;
    wire [31:0] apb_rdata;
    reg         ack_seen;
    wire        ack_new = (ack_tgl != ack_seen);

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            hstate    <= H_IDLE;
            win_cap   <= 4'd0;
            addr_cap  <= 12'd0;
            write_cap <= 1'b0;
            wdata_cap <= 32'd0;
            req_tgl   <= 1'b0;
            ack_seen  <= 1'b0;
            hrdata_o  <= 32'd0;
        end else begin
            case (hstate)
                H_IDLE, H_OK, H_ERR2: begin
                    // A new address phase can be accepted in any cycle where
                    // the bus is ready. One accepted during the [N-9.2] window
                    // (APB side still in reset) is captured and simply waits:
                    // the pclk FSM picks it up when preset_n releases.
                    if (!prst_ok_q && hstate == H_ERR2) begin
                        hstate <= H_ERR2;          // hold the 2nd ERROR cycle
                    end else if (xfer) begin
                        if (!win_ok || !word_ok) begin
                            hstate <= H_ERR1;
                        end else begin
                            hstate    <= H_CAPT;
                            win_cap   <= win;
                            addr_cap  <= haddr_i[11:0];
                            write_cap <= hwrite_i;
                        end
                    end else begin
                        hstate <= H_IDLE;
                    end
                end
                H_CAPT: begin
                    if (write_cap) wdata_cap <= hwdata_i;
                    req_tgl <= ~req_tgl;
                    hstate  <= H_WAIT;
                end
                H_WAIT: begin
                    if (ack_new) begin
                        ack_seen <= ack_tgl;
                        hrdata_o <= apb_rdata;
                        hstate   <= apb_err ? H_ERR1 : H_OK;
                    end
                end
                H_ERR1:  hstate <= H_ERR2;
                default: hstate <= H_IDLE;
            endcase
        end
    end

    assign hreadyout_o = prst_ok_q &&
                         (hstate == H_IDLE || hstate == H_OK || hstate == H_ERR2);
    assign hresp_o     = (hstate == H_ERR1) || (hstate == H_ERR2);

    // =========================================================================
    // APB side (pclk)
    // =========================================================================
    wire [31:0] prdata_sel;
    wire        pready_sel, pslverr_sel;

    ahb2apb_apb_fsm #(
        .APB_DIV (APB_DIV),
        .TIMEOUT (TIMEOUT)
    ) u_fsm (
        .pclk_i        (pclk_i),
        .preset_n_i    (preset_n_i),
        .req_tgl_i     (req_tgl),
        .win_i         (win_cap),
        .addr_i        (addr_cap),
        .write_i       (write_cap),
        .wdata_i       (wdata_cap),
        .ack_tgl_o     (ack_tgl),
        .err_o         (apb_err),
        .rdata_o       (apb_rdata),
        .psel_o        (psel_o),
        .penable_o     (penable_o),
        .pwrite_o      (pwrite_o),
        .paddr_o       (paddr_o),
        .pwdata_o      (pwdata_o),
        .prdata_sel_i  (prdata_sel),
        .pready_sel_i  (pready_sel),
        .pslverr_sel_i (pslverr_sel)
    );

    ahb2apb_fabric u_fabric (
        .psel_i        (psel_o),
        .prdata_i      (prdata_i),
        .pready_i      (pready_i),
        .pslverr_i     (pslverr_i),
        .prdata_o      (prdata_sel),
        .pready_o      (pready_sel),
        .pslverr_o     (pslverr_sel)
    );

`ifndef SYNTHESIS
    // a_capture_stable_at_phase: the captures never move between two cycles
    // that are both inside an APB transfer (H_WAIT), so every pclk edge the
    // FSM samples on sees a stable value.
    reg [44:0] cap_prev;
    reg [2:0]  hstate_d;
    always @(posedge hclk_i) begin
        if (hreset_n_i && hstate == H_WAIT && hstate_d == H_WAIT &&
            cap_prev !== {win_cap, addr_cap, write_cap, wdata_cap[27:0]})
            $display("[BRG-ASSERT] capture moved during an APB transfer at %0t", $time);
        cap_prev <= {win_cap, addr_cap, write_cap, wdata_cap[27:0]};
        hstate_d <= hstate;
    end
`endif

endmodule

`default_nettype wire
