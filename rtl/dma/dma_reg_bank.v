`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_reg_bank.v - 30 configuration registers (5 per channel x 6) + status view
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 3.1 (#2), Sec. 6, Sec. 12,
//                 Sec. 15.3
//
// The configuration registers (SAR, DAR, TCR, CR) live in the pclk domain and
// are written only by the CPU over APB. Hardware modifies exactly one bit of
// them - CR.EN, cleared on single-shot completion (Sec. 6.6) - and nothing
// else. That restraint is what makes circular mode work at all: the CIRC
// reload in Sec. 6.6 re-reads SAR/DAR/TCR from here, so if hardware were
// allowed to decrement the register-bank TCR the second lap would transfer
// zero beats. The FSMs decrement their own private working copies instead.
//
// SR is a VIEW, not storage. Sec. 7.5 puts done_flag/err_flag in the channel
// FSMs (hclk) and Sec. 6.7 defines SR.REMAINING as a live readback of the FSM's
// xfer_cnt. This module owns only the pclk-side synchronizers that make those
// hclk values readable over APB, plus the W1C write decode that turns a
// firmware clear into an event heading the other way.
//
// -----------------------------------------------------------------------------
// EVERY CLOCK-DOMAIN CROSSING IN THE BLOCK PASSES THROUGH HERE OR THE FSM
// -----------------------------------------------------------------------------
//   pclk -> hclk   CR.EN level            dma_cdc_sync   (in dma_channel_fsm)
//   pclk -> hclk   arm event              toggle here  + dma_cdc_pulse in FSM
//   pclk -> hclk   SR W1C clears          toggle here  + dma_cdc_pulse in FSM
//   pclk -> hclk   SAR/DAR/TCR/CR fields  unsynchronized, quasi-static
//                                         (Sec. 15.3 - see dma_channel_fsm
//                                          DESIGN NOTE 2 for the margin proof)
//   hclk -> pclk   CR.EN hardware clear   toggle in FSM + dma_cdc_pulse here
//   hclk -> pclk   SR.COMPLETE / SR.ERROR dma_cdc_sync  here (12 indep. bits)
//   hclk -> pclk   SR.REMAINING           dma_cdc_gray  here (x6)
//
// -----------------------------------------------------------------------------
// THE EN WRITE-PRIORITY RULE
// -----------------------------------------------------------------------------
// CR.EN has two writers in two domains. When firmware's re-arm write and the
// hardware completion clear land on the same pclk edge, SOFTWARE WINS - the
// write is the newer intent, and the clear refers to the transfer that just
// finished. This is enforced structurally: the per-channel branch below tests
// the APB write FIRST and only falls through to the hardware clear, so the two
// can never both drive the flop.
//
// Losing this race the other way would be a hang, not a glitch: firmware sets
// EN=1, hardware clears it in the same cycle, and the channel appears disabled
// while firmware believes it is armed. The arm EVENT (arm_tog) is what actually
// starts the transfer, so the channel still runs correctly either way - but
// CR.EN read back as 0 on a running channel would send anyone debugging it in
// entirely the wrong direction.
// =============================================================================

`include "dma_defs.vh"

module dma_reg_bank (
    // ---- pclk domain --------------------------------------------------------
    input  wire                       pclk_i,
    input  wire                       preset_n_i,

    // ---- hclk domain (destination/source side of the crossings) -------------
    input  wire                       hclk_i,
    input  wire                       hreset_n_i,

    // ---- decoded APB access (from dma_apb_slave) ----------------------------
    input  wire [2:0]                 ch_sel_i,
    input  wire [2:0]                 reg_sel_i,
    input  wire                       sel_valid_i,
    input  wire                       wr_en_i,
    input  wire [31:0]                wdata_i,
    output reg  [31:0]                rdata_o,

    // ---- configuration out to the channel FSMs (flattened) ------------------
    output wire [`DMA_NCH*32-1:0]         cfg_sar_o,
    output wire [`DMA_NCH*32-1:0]         cfg_dar_o,
    output wire [`DMA_NCH*`DMA_TCR_W-1:0] cfg_tcr_o,
    output wire [`DMA_NCH*`DMA_CR_W-1:0]  cfg_cr_o,

    // ---- CDC event toggles out to the channel FSMs (pclk sourced) -----------
    output reg  [`DMA_NCH-1:0]        arm_tog_o,
    output reg  [`DMA_NCH-1:0]        clr_done_tog_o,
    output reg  [`DMA_NCH-1:0]        clr_err_tog_o,

    // ---- status in from the channel FSMs (hclk sourced) ---------------------
    input  wire [`DMA_NCH-1:0]            done_flag_i,
    input  wire [`DMA_NCH-1:0]            err_flag_i,
    input  wire [`DMA_NCH-1:0]            cnt_valid_i,   // see ERRATUM DMA-1
    input  wire [`DMA_NCH-1:0]            en_clr_tog_i,
    input  wire [`DMA_NCH*`DMA_TCR_W-1:0] remaining_i
);

    // -----------------------------------------------------------------------
    // Storage. Sec. 15.1 budgets ~960 flip-flops here; this is 6*(32+32+16+13)
    // = 558, the difference being that TCR is 16 bits not 32 and CR is 13.
    // -----------------------------------------------------------------------
    reg [31:0]           sar [0:`DMA_NCH-1];
    reg [31:0]           dar [0:`DMA_NCH-1];
    reg [`DMA_TCR_W-1:0] tcr [0:`DMA_NCH-1];
    reg [`DMA_CR_W-1:0]  cr  [0:`DMA_NCH-1];

    // -----------------------------------------------------------------------
    // hclk -> pclk crossings
    // -----------------------------------------------------------------------
    wire [`DMA_NCH-1:0] en_clr_p;      // hardware EN-clear, as pclk pulses
    wire [`DMA_NCH-1:0] done_flag_p;   // SR.COMPLETE, synchronized for readback
    wire [`DMA_NCH-1:0] err_flag_p;    // SR.ERROR,    synchronized for readback
    wire [`DMA_NCH-1:0] cnt_valid_p;   // REMAINING gate, ERRATUM DMA-1

    wire [`DMA_NCH*`DMA_TCR_W-1:0] remaining_p;

    // 18 INDEPENDENT status bits - each is consumed on its own, never as a
    // multi-bit number, so a skewed capture cannot manufacture a value that
    // never existed. This is the case dma_cdc_sync's header calls out as safe
    // for WIDTH>1.
    //
    // cnt_valid MUST ride in this same synchronizer, not a separate one. Its
    // whole purpose (ERRATUM DMA-1) is to change on the same pclk edge as the
    // status flags so that SR is internally consistent when read; putting it
    // in its own instance would reintroduce the skew it exists to remove.
    dma_cdc_sync #(.WIDTH(3*`DMA_NCH), .RESET_VAL(1'b0)) u_flag_sync (
        .clk_i   (pclk_i),
        .rst_n_i (preset_n_i),
        .d_i     ({cnt_valid_i, err_flag_i,  done_flag_i}),
        .q_o     ({cnt_valid_p, err_flag_p,  done_flag_p})
    );

    genvar gi;
    generate
        for (gi = 0; gi < `DMA_NCH; gi = gi + 1) begin : g_cdc
            // Hardware EN clear: toggle sourced in the FSM (hclk), edge
            // detected here (pclk).
            dma_cdc_pulse u_en_clr (
                .clk_i   (pclk_i),
                .rst_n_i (preset_n_i),
                .tog_i   (en_clr_tog_i[gi]),
                .pulse_o (en_clr_p[gi])
            );

            // SR.REMAINING: a 16-bit counter crossing domains needs gray
            // coding, not a flat two-flop sync. See dma_cdc_gray.v.
            dma_cdc_gray #(.WIDTH(`DMA_TCR_W)) u_remaining (
                .src_clk_i   (hclk_i),
                .src_rst_n_i (hreset_n_i),
                .src_bin_i   (remaining_i[`DMA_TCR_W*gi +: `DMA_TCR_W]),
                .dst_clk_i   (pclk_i),
                .dst_rst_n_i (preset_n_i),
                .dst_bin_o   (remaining_p[`DMA_TCR_W*gi +: `DMA_TCR_W])
            );

            // Flatten the register arrays onto the output buses.
            assign cfg_sar_o[32*gi          +: 32]          = sar[gi];
            assign cfg_dar_o[32*gi          +: 32]          = dar[gi];
            assign cfg_tcr_o[`DMA_TCR_W*gi  +: `DMA_TCR_W]  = tcr[gi];
            assign cfg_cr_o [`DMA_CR_W*gi   +: `DMA_CR_W]   = cr [gi];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Write path + CDC event generation (pclk)
    // -----------------------------------------------------------------------
    integer c;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            // Sec. 12: all CR cleared (every channel disabled). SAR/DAR/TCR are
            // "undefined" per the spec; they are reset to 0 anyway so that no X
            // can reach HADDR in simulation, where it would propagate through
            // the interconnect and look like an address-decode failure.
            for (c = 0; c < `DMA_NCH; c = c + 1) begin
                sar[c] <= 32'b0;
                dar[c] <= 32'b0;
                tcr[c] <= {`DMA_TCR_W{1'b0}};
                cr [c] <= {`DMA_CR_W{1'b0}};
            end
            arm_tog_o      <= {`DMA_NCH{1'b0}};
            clr_done_tog_o <= {`DMA_NCH{1'b0}};
            clr_err_tog_o  <= {`DMA_NCH{1'b0}};
        end else begin
            for (c = 0; c < `DMA_NCH; c = c + 1) begin
                if (wr_en_i && sel_valid_i && (ch_sel_i == c[2:0])) begin
                    case (reg_sel_i)
                        `DMA_REG_SAR: sar[c] <= wdata_i;
                        `DMA_REG_DAR: dar[c] <= wdata_i;
                        // Sec. 6.5: TCR is 16 bits, [31:16] reserved, writes
                        // to the upper half ignored.
                        `DMA_REG_TCR: tcr[c] <= wdata_i[`DMA_TCR_W-1:0];
                        // Sec. 6.6: CR[31:13] reserved, writes ignored.
                        `DMA_REG_CR: begin
                            cr[c] <= wdata_i[`DMA_CR_W-1:0];
                            // "Set this bit LAST after configuring all other
                            // registers" (Sec. 6.6) IS the start trigger, so a
                            // CR write carrying EN=1 is what raises the arm
                            // event. See dma_channel_fsm DESIGN NOTE 1.
                            if (wdata_i[`DMA_CR_EN])
                                arm_tog_o[c] <= ~arm_tog_o[c];
                        end
                        // Sec. 6.7: SR bits [1:0] are W1C. Writing 1 clears;
                        // writing 0 has no effect. The clear itself happens in
                        // hclk where the flag lives - this only raises the
                        // event. Nothing in SR is stored in this domain.
                        `DMA_REG_SR: begin
                            if (wdata_i[`DMA_SR_COMPLETE])
                                clr_done_tog_o[c] <= ~clr_done_tog_o[c];
                            if (wdata_i[`DMA_SR_ERROR])
                                clr_err_tog_o[c]  <= ~clr_err_tog_o[c];
                        end
                        default: ; // reserved reg_sel: write dropped
                    endcase
                end else if (en_clr_p[c]) begin
                    // Hardware single-shot completion clears CR.EN (Sec. 6.6).
                    // Reached only when no APB write is targeting this channel
                    // this cycle - see "THE EN WRITE-PRIORITY RULE" above.
                    cr[c][`DMA_CR_EN] <= 1'b0;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Read mux (Sec. 6.1). Combinational; dma_apb_slave gates it with PSEL.
    // -----------------------------------------------------------------------
    always @(*) begin
        rdata_o = 32'h0000_0000;
        if (sel_valid_i) begin
            case (reg_sel_i)
                `DMA_REG_SAR: rdata_o = sar[ch_sel_i];
                `DMA_REG_DAR: rdata_o = dar[ch_sel_i];
                `DMA_REG_TCR: rdata_o = {16'b0, tcr[ch_sel_i]};
                `DMA_REG_CR:  rdata_o = {19'b0, cr[ch_sel_i]};
                // Sec. 6.7 layout: [31:16] REMAINING, [15:2] reserved RO 0,
                // [1] ERROR, [0] COMPLETE.
                //
                // REMAINING is gated by cnt_valid_p rather than by the FSM
                // state in hclk - ERRATUM DMA-1. Both the gate and the flags
                // come out of u_flag_sync, so every field of SR presented here
                // reflects the same hclk-domain instant.
                `DMA_REG_SR:  rdata_o = {
                                  (cnt_valid_p[ch_sel_i]
                                     ? remaining_p[`DMA_TCR_W*ch_sel_i +: `DMA_TCR_W]
                                     : {`DMA_TCR_W{1'b0}}),
                                  14'b0,
                                  err_flag_p [ch_sel_i],
                                  done_flag_p[ch_sel_i]
                              };
                default:      rdata_o = 32'h0000_0000;
            endcase
        end
    end

endmodule

`default_nettype wire
