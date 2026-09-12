`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - VERIFICATION MODEL
// ahb2apb_bridge_model.v - AHB-Lite slave (200 MHz) -> APB3 master (100 MHz)
//
// STATUS: this is a VERIFICATION MODEL standing in for Block 8, whose design
// specification has not been written. It lives in tb/ and must not migrate
// into rtl/. When GARUDA-BRIDGE-SPEC-001 exists, the real bridge replaces it.
//
// It exists because without SOME bridge the DMA cannot be configured in a SoC
// simulation at all - its configuration port is APB, in the pclk domain, and
// nothing else in the design crosses 200/100 MHz. Tying pclk to hclk instead
// would have been far less work and would have quietly turned the DMA's entire
// clock-domain-crossing design into dead logic: every toggle handshake, every
// gray coder and the ERRATUM DMA-1 fix all only do anything at a real clock
// ratio. A 1:1 "bridge" would make the SoC test look like it covered the CDC
// while covering none of it.
//
// -----------------------------------------------------------------------------
// WHAT IT MODELS
// -----------------------------------------------------------------------------
//   AHB side (hclk)   full AHB-Lite slave: HSEL + global HREADY, holds
//                     HREADYOUT low for the whole crossing, two-cycle ERROR on
//                     PSLVERR (mandatory per GARUDA-AHB-SPEC-001 Sec. 1.4 -
//                     dma_ahb_master's write-address cancel depends on it)
//   crossing          two-phase toggle handshake in each direction, two-flop
//                     synchronisers. Same structure as rtl/dma/dma_cdc_pulse.v,
//                     for the same reason: a one-cycle pulse pushed through a
//                     synchroniser into a SLOWER domain can vanish between two
//                     destination edges.
//   APB side (pclk)   APB3 SETUP -> ACCESS, honours PREADY, samples PSLVERR
//
// Round-trip cost is roughly 2 hclk + 3 pclk + 2 hclk, i.e. 10-12 hclk at a 2:1
// ratio. GARUDA-AHB-SPEC-001 Sec. 9.1 budgets "~3-4 core" cycles for a
// peripheral access; that number is optimistic for any real toggle-handshake
// bridge and is flagged in docs/SOC_RTL_LOG.md rather than tuned away here.
//
// -----------------------------------------------------------------------------
// WHAT IT DOES NOT MODEL
// -----------------------------------------------------------------------------
// No write buffering, no posted writes, no APB wait-state generation of its
// own, no protection checks, no burst optimisation. Every access is a full
// round trip. That makes it slow and completely predictable, which is what a
// stand-in should be.
// =============================================================================

module ahb2apb_bridge_model (
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- AHB-Lite slave (hclk) ----
    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,          // global HREADY
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o,

    // ---- APB3 master (pclk) ----
    output reg         psel_o,
    output reg         penable_o,
    output reg         pwrite_o,
    output reg  [31:0] paddr_o,
    output reg  [31:0] pwdata_o,
    input  wire [31:0] prdata_i,
    input  wire        pready_i,
    input  wire        pslverr_i
);

    // =======================================================================
    // hclk side
    // =======================================================================
    localparam [1:0] H_IDLE = 2'd0,   // ready, waiting for an address phase
                     H_DATA = 2'd1,   // address accepted; capture HWDATA, launch
                     H_WAIT = 2'd2,   // crossing in flight, HREADYOUT low
                     H_ERR1 = 2'd3;   // first cycle of the two-cycle ERROR

    reg [1:0]  hstate;
    reg [31:0] h_addr;
    reg        h_write;
    reg [31:0] h_wdata;
    reg [31:0] h_rdata;
    reg        h_err;
    reg        req_tog;               // hclk -> pclk request

    wire       ack_pulse;             // pclk -> hclk completion, in hclk
    wire       req_pulse;             // hclk -> pclk request,    in pclk
    reg        ack_tog;               // pclk -> hclk completion

    wire accept = hsel_i && hready_i && htrans_i[1];

    // Captured on the hclk side of the return crossing. Written in pclk,
    // read in hclk one ack_pulse later - by which time they have been stable
    // for at least a full pclk period, which is what the toggle handshake
    // exists to guarantee.
    reg [31:0] p_rdata_q;
    reg        p_err_q;


    // HREADYOUT is high only in H_IDLE and in the completing cycle. H_DATA
    // already drives it low: the address phase was accepted, so the data phase
    // has begun and must be stretched from its very first cycle.
    assign hreadyout_o = (hstate == H_IDLE);
    assign hresp_o     = (hstate == H_ERR1) || ((hstate == H_IDLE) && h_err);
    assign hrdata_o    = h_rdata;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            hstate  <= H_IDLE;
            h_addr  <= 32'b0;
            h_write <= 1'b0;
            h_wdata <= 32'b0;
            h_rdata <= 32'b0;
            h_err   <= 1'b0;
            req_tog <= 1'b0;
        end else begin
            case (hstate)
                H_IDLE: begin
                    h_err <= 1'b0;
                    if (accept) begin
                        h_addr  <= haddr_i;
                        h_write <= hwrite_i;
                        hstate  <= H_DATA;
                    end
                end

                // The write data arrives in this cycle, one after the address
                // phase was accepted. Launching the crossing before capturing
                // it would send whatever the master happened to be driving
                // during its address phase - the ERRATUM D-1 mistake, one
                // module over.
                H_DATA: begin
                    h_wdata <= hwdata_i;
                    req_tog <= ~req_tog;
                    hstate  <= H_WAIT;
                end

                H_WAIT: begin
                    if (ack_pulse) begin
                        h_rdata <= p_rdata_q;
                        h_err   <= p_err_q;
                        hstate  <= p_err_q ? H_ERR1 : H_IDLE;
                    end
                end

                // Two-cycle ERROR: H_ERR1 drives HREADYOUT=0/HRESP=ERROR, then
                // H_IDLE with h_err still set drives HREADYOUT=1/HRESP=ERROR.
                H_ERR1: hstate <= H_IDLE;

                default: hstate <= H_IDLE;
            endcase
        end
    end

    // =======================================================================
    // pclk side
    // =======================================================================
    localparam [1:0] P_IDLE = 2'd0, P_SETUP = 2'd1, P_ACCESS = 2'd2;

    reg [1:0]  pstate;
    reg [31:0] p_rdata;
    reg        p_err;

    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            pstate    <= P_IDLE;
            psel_o    <= 1'b0;
            penable_o <= 1'b0;
            pwrite_o  <= 1'b0;
            paddr_o   <= 32'b0;
            pwdata_o  <= 32'b0;
            p_rdata   <= 32'b0;
            p_err     <= 1'b0;
            p_rdata_q <= 32'b0;
            p_err_q   <= 1'b0;
            ack_tog   <= 1'b0;
        end else begin
            case (pstate)
                P_IDLE: begin
                    psel_o    <= 1'b0;
                    penable_o <= 1'b0;
                    if (req_pulse) begin
                        psel_o    <= 1'b1;
                        penable_o <= 1'b0;
                        pwrite_o  <= h_write;
                        paddr_o   <= h_addr;
                        pwdata_o  <= h_wdata;
                        pstate    <= P_SETUP;
                    end
                end

                // APB3: SETUP asserts PSEL with PENABLE low for exactly one
                // cycle, then ACCESS raises PENABLE until PREADY.
                P_SETUP: begin
                    penable_o <= 1'b1;
                    pstate    <= P_ACCESS;
                end

                P_ACCESS: begin
                    if (pready_i) begin
                        p_rdata   <= prdata_i;
                        p_err     <= pslverr_i;
                        p_rdata_q <= prdata_i;
                        p_err_q   <= pslverr_i;
                        ack_tog   <= ~ack_tog;
                        psel_o    <= 1'b0;
                        penable_o <= 1'b0;
                        pstate    <= P_IDLE;
                    end
                end

                default: pstate <= P_IDLE;
            endcase
        end
    end

    // =======================================================================
    // Crossings. Same two-phase toggle structure as rtl/dma/dma_cdc_pulse.v.
    // =======================================================================
    reg req_m, req_s, req_d;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin req_m <= 1'b0; req_s <= 1'b0; req_d <= 1'b0; end
        else             begin req_m <= req_tog; req_s <= req_m; req_d <= req_s; end
    end
    assign req_pulse = req_s ^ req_d;

    reg ack_m, ack_s, ack_d;
    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin ack_m <= 1'b0; ack_s <= 1'b0; ack_d <= 1'b0; end
        else             begin ack_m <= ack_tog; ack_s <= ack_m; ack_d <= ack_s; end
    end
    assign ack_pulse = ack_s ^ ack_d;

    // hsize_i is accepted at the port for completeness but the APB3 interface
    // has no byte strobes, so a sub-word access cannot be expressed on the far
    // side. GARUDA-DMA-SPEC-001 Sec. 5.2 already defines every DMA register as
    // word-addressed for exactly this reason. Referenced so lint sees it used.
    wire _unused_hsize = |hsize_i;

    // p_rdata / p_err are the pclk-domain working copies; p_rdata_q / p_err_q
    // are what the hclk side reads. Kept separate so a waveform shows both.
    wire _unused_p = |{p_rdata, p_err};

endmodule

`default_nettype wire
