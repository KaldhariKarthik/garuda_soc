`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_top.v - block boundary and sub-block interconnect
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 3.3, Sec. 5.7, Sec. 17
//
// Six-channel DMA: AHB-Lite master (data, 200 MHz hclk) + APB slave (config,
// 100 MHz pclk), base 0x4000_5000. Transfers are always SINGLE beats; the
// arbiter re-evaluates on every beat boundary.
//
// THE PORT LIST IS FROZEN. Sec. 5.7 publishes this exact declaration as the
// block boundary, and the SoC integration in Sec. 17.1 is written against it.
// Port names here deliberately drop the _i/_o suffix used everywhere inside
// the block (and in rtl/core) because the spec names them without it - the
// boundary matches the document, the internals match the house style.
//
// -----------------------------------------------------------------------------
// SUB-BLOCK MAP (Sec. 3.1 / Sec. 3.3)
// -----------------------------------------------------------------------------
//   dma_apb_slave    x1   APB protocol + address decode        pclk
//   dma_reg_bank     x1   30 registers + pclk side of all CDC  pclk (+hclk CDC)
//   dma_channel_fsm  x6   5-state transfer control + status    hclk (+pclk CDC)
//   dma_arbiter      x1   combinational fixed-priority encoder hclk
//   dma_ahb_master   x1   6-state beat engine + data buffer    hclk
//   dma_irq_agg      x1   12 interrupt lines to the CLIC       hclk
//
// -----------------------------------------------------------------------------
// THE ONE PIECE OF REAL LOGIC IN THIS FILE: THE BEAT-START HANDSHAKE
// -----------------------------------------------------------------------------
// Everything else here is wiring. This is not, and it is where a naive
// implementation of Sec. 8 breaks:
//
//     beat_start = arb_grant & ahb_idle
//     go[n]      = beat_start & (arb_sel == n)
//
// The arbiter is combinational and re-evaluates every cycle (Sec. 3.1 #4). Its
// grant is therefore only meaningful at an instant, not across a transaction.
// Qualifying it with ahb_idle means a beat can only be launched when the bus
// engine is free, and dma_ahb_master latches the winner (ch_lock_o) for the
// whole beat. Without the qualification, a higher-priority channel raising its
// request mid-beat would swing HADDR and HSIZE under a live AHB transaction:
// the read would come back from one channel's source and be written to another
// channel's destination. That corrupts two transfers at once and leaves no
// status bit set anywhere, because as far as both channels are concerned their
// beats completed normally.
//
// Per-beat re-evaluation (Sec. 8.3) is delivered by the beat BOUNDARY, not by
// the arbiter's timing: the winning channel drops ch_req the moment it enters
// TRANSFERRING, and re-asserts it on return to WAITING_FOR_REQUEST, so every
// beat is arbitrated afresh among whoever is asking at that moment.
//
// beat_done/bus_error are fanned back out through ch_lock_o so that only the
// channel that actually owned the beat decrements its counter. Broadcasting
// them would decrement all six.
// =============================================================================

`include "dma_defs.vh"

module dma_top (
    // Clocks and resets
    input  wire        hclk,        // 200 MHz AHB domain
    input  wire        pclk,        // 100 MHz APB domain
    input  wire        hreset_n,    // active-low, AHB domain
    input  wire        preset_n,    // active-low, APB domain

    // APB slave (config port)
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [7:0]  paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // AHB-Lite master (data port)
    output wire [31:0] haddr,
    output wire [1:0]  htrans,
    output wire        hwrite,
    output wire [2:0]  hsize,
    output wire [2:0]  hburst,
    output wire [31:0] hwdata,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire        hresp,

    // Peripheral handshake (sideband)
    input  wire [5:0]  dma_req,
    output wire [5:0]  dma_ack,

    // Interrupts to CLIC
    output wire [5:0]  dma_irq,
    output wire [5:0]  dma_err
);

    // -----------------------------------------------------------------------
    // APB slave <-> register bank
    // -----------------------------------------------------------------------
    wire [2:0]  apb_ch_sel;
    wire [2:0]  apb_reg_sel;
    wire        apb_sel_valid;
    wire        apb_wr_en;
    wire [31:0] apb_wdata;
    wire [31:0] apb_rdata;

    // -----------------------------------------------------------------------
    // Register bank <-> channel FSMs
    // -----------------------------------------------------------------------
    wire [`DMA_NCH*32-1:0]         cfg_sar;
    wire [`DMA_NCH*32-1:0]         cfg_dar;
    wire [`DMA_NCH*`DMA_TCR_W-1:0] cfg_tcr;
    wire [`DMA_NCH*`DMA_CR_W-1:0]  cfg_cr;

    wire [`DMA_NCH-1:0] arm_tog;
    wire [`DMA_NCH-1:0] clr_done_tog;
    wire [`DMA_NCH-1:0] clr_err_tog;

    wire [`DMA_NCH-1:0] done_flag;
    wire [`DMA_NCH-1:0] err_flag;
    wire [`DMA_NCH-1:0] cnt_valid;
    wire [`DMA_NCH-1:0] en_clr_tog;

    wire [`DMA_NCH*`DMA_TCR_W-1:0] remaining;

    // -----------------------------------------------------------------------
    // Channel FSMs <-> arbiter and AHB master
    // -----------------------------------------------------------------------
    wire [`DMA_NCH-1:0]     ch_req;
    wire [`DMA_NCH*3-1:0]   ch_pri;
    wire [`DMA_NCH*32-1:0]  ch_src_addr;
    wire [`DMA_NCH*32-1:0]  ch_dst_addr;
    wire [`DMA_NCH*2-1:0]   ch_size;

    wire                    arb_grant;
    wire [2:0]              arb_sel;

    wire                    ahb_idle;
    wire [2:0]              ahb_ch_lock;
    wire                    ahb_beat_done;
    wire                    ahb_bus_error;

    // Beat-start handshake - see the header block above.
    wire beat_start = arb_grant && ahb_idle;

    wire [`DMA_NCH-1:0] ch_go;
    wire [`DMA_NCH-1:0] ch_beat_done;
    wire [`DMA_NCH-1:0] ch_bus_error;

    // CR.IE / CR.EIE lifted out of the flattened CR bus for the aggregator.
    wire [`DMA_NCH-1:0] cr_ie;
    wire [`DMA_NCH-1:0] cr_eie;

    // =======================================================================
    // APB slave (Sec. 3.1 #1)
    // =======================================================================
    dma_apb_slave u_apb_slave (
        .psel_i      (psel),
        .penable_i   (penable),
        .pwrite_i    (pwrite),
        .paddr_i     (paddr),
        .pwdata_i    (pwdata),
        .prdata_o    (prdata),
        .pready_o    (pready),
        .pslverr_o   (pslverr),

        .ch_sel_o    (apb_ch_sel),
        .reg_sel_o   (apb_reg_sel),
        .sel_valid_o (apb_sel_valid),
        .wr_en_o     (apb_wr_en),
        .wdata_o     (apb_wdata),
        .rdata_i     (apb_rdata)
    );

    // =======================================================================
    // Register bank (Sec. 3.1 #2) - owns the pclk side of every crossing
    // =======================================================================
    dma_reg_bank u_reg_bank (
        .pclk_i         (pclk),
        .preset_n_i     (preset_n),
        .hclk_i         (hclk),
        .hreset_n_i     (hreset_n),

        .ch_sel_i       (apb_ch_sel),
        .reg_sel_i      (apb_reg_sel),
        .sel_valid_i    (apb_sel_valid),
        .wr_en_i        (apb_wr_en),
        .wdata_i        (apb_wdata),
        .rdata_o        (apb_rdata),

        .cfg_sar_o      (cfg_sar),
        .cfg_dar_o      (cfg_dar),
        .cfg_tcr_o      (cfg_tcr),
        .cfg_cr_o       (cfg_cr),

        .arm_tog_o      (arm_tog),
        .clr_done_tog_o (clr_done_tog),
        .clr_err_tog_o  (clr_err_tog),

        .done_flag_i    (done_flag),
        .err_flag_i     (err_flag),
        .cnt_valid_i    (cnt_valid),
        .en_clr_tog_i   (en_clr_tog),
        .remaining_i    (remaining)
    );

    // =======================================================================
    // Channel FSMs (Sec. 3.1 #3) - six independent instances
    // =======================================================================
    genvar n;
    generate
        for (n = 0; n < `DMA_NCH; n = n + 1) begin : g_ch

            // Only the channel holding the bus lock sees the beat result.
            assign ch_go[n]         = beat_start   && (arb_sel     == n[2:0]);
            assign ch_beat_done[n]  = ahb_beat_done && (ahb_ch_lock == n[2:0]);
            assign ch_bus_error[n]  = ahb_bus_error && (ahb_ch_lock == n[2:0]);

            assign cr_ie [n] = cfg_cr[`DMA_CR_W*n + `DMA_CR_IE ];
            assign cr_eie[n] = cfg_cr[`DMA_CR_W*n + `DMA_CR_EIE];

            dma_channel_fsm u_ch (
                .hclk_i         (hclk),
                .hreset_n_i     (hreset_n),

                .cfg_sar_i      (cfg_sar[32*n         +: 32]),
                .cfg_dar_i      (cfg_dar[32*n         +: 32]),
                .cfg_tcr_i      (cfg_tcr[`DMA_TCR_W*n +: `DMA_TCR_W]),
                .cfg_cr_i       (cfg_cr [`DMA_CR_W*n  +: `DMA_CR_W]),

                .arm_tog_i      (arm_tog[n]),
                .clr_done_tog_i (clr_done_tog[n]),
                .clr_err_tog_i  (clr_err_tog[n]),

                .dma_req_i      (dma_req[n]),
                .dma_ack_o      (dma_ack[n]),

                .ch_req_o       (ch_req[n]),
                .ch_pri_o       (ch_pri[3*n +: 3]),
                .go_i           (ch_go[n]),

                .src_addr_o     (ch_src_addr[32*n +: 32]),
                .dst_addr_o     (ch_dst_addr[32*n +: 32]),
                .size_o         (ch_size[2*n +: 2]),
                .beat_done_i    (ch_beat_done[n]),
                .bus_error_i    (ch_bus_error[n]),

                .done_flag_o    (done_flag[n]),
                .err_flag_o     (err_flag[n]),
                .en_clr_tog_o   (en_clr_tog[n]),
                .remaining_o    (remaining[`DMA_TCR_W*n +: `DMA_TCR_W]),
                .cnt_valid_o    (cnt_valid[n]),
                .state_o        (/* observability only */)
            );
        end
    endgenerate

    // =======================================================================
    // Arbiter (Sec. 3.1 #4) - combinational, no state
    // =======================================================================
    dma_arbiter u_arbiter (
        .ch_req_i  (ch_req),
        .ch_pri_i  (ch_pri),
        .grant_o   (arb_grant),
        .ch_sel_o  (arb_sel)
    );

    // =======================================================================
    // AHB-Lite master (Sec. 3.1 #5 + #6)
    // =======================================================================
    dma_ahb_master u_ahb_master (
        .hclk_i      (hclk),
        .hreset_n_i  (hreset_n),

        .start_i     (beat_start),
        .ch_sel_i    (arb_sel),

        .src_addr_i  (ch_src_addr),
        .dst_addr_i  (ch_dst_addr),
        .size_i      (ch_size),

        .haddr_o     (haddr),
        .htrans_o    (htrans),
        .hwrite_o    (hwrite),
        .hsize_o     (hsize),
        .hburst_o    (hburst),
        .hwdata_o    (hwdata),
        .hrdata_i    (hrdata),
        .hready_i    (hready),
        .hresp_i     (hresp),

        .idle_o      (ahb_idle),
        .ch_lock_o   (ahb_ch_lock),
        .beat_done_o (ahb_beat_done),
        .bus_error_o (ahb_bus_error)
    );

    // =======================================================================
    // Interrupt aggregator (Sec. 3.1 #7)
    // =======================================================================
    dma_irq_agg u_irq_agg (
        .hclk_i      (hclk),
        .hreset_n_i  (hreset_n),
        .done_flag_i (done_flag),
        .err_flag_i  (err_flag),
        .ie_i        (cr_ie),
        .eie_i       (cr_eie),
        .dma_irq_o   (dma_irq),
        .dma_err_o   (dma_err)
    );

endmodule

`default_nettype wire
