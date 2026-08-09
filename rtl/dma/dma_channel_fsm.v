`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_channel_fsm.v - per-channel 5-state transfer controller (x6)
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 3.1 (#3), Sec. 7, Sec. 9,
//                 Sec. 15.3
//
// Six identical, independent instances clocked by hclk. Each owns its channel's
// working registers (src_addr_r, dst_addr_r, xfer_cnt and the latched CR
// fields), its two SR status flags, and the CDC into the pclk register bank.
//
// STATES (Sec. 7.1, encoding fixed by the spec table - see dma_defs.vh)
//   IDLE                 waiting to be armed
//   CONFIGURED           single cycle: latch SAR/DAR/TCR/CR into working regs
//   WAITING_FOR_REQUEST  request the bus; wait for dma_req AND grant
//   TRANSFERRING         one beat in flight in the AHB master
//   COMPLETE             set status flag, then reload (CIRC) or stop
//
// =============================================================================
// DESIGN NOTE 1 - ARMING: why an event, not just the synchronized EN level
// =============================================================================
// Sec. 15.3 specifies a two-flop synchronizer on CR.EN, and that is present
// (u_en_sync). But a synchronized LEVEL alone cannot safely start a channel,
// because EN has two writers in two different clock domains:
//   - software SETS it from pclk (an APB write to CR);
//   - hardware CLEARS it from hclk on single-shot completion (Sec. 6.6), which
//     has to cross BACK to pclk as en_clr_tog_o.
//
// Start on the RISING EDGE of the synchronized level and you get this hang:
// the channel completes, hardware requests the EN clear, and before that clear
// lands in pclk, firmware re-arms by writing CR with EN=1. The pclk flop never
// went low, so no rising edge is ever produced in hclk, and the channel sits in
// IDLE forever with CR.EN reading 1. Start on the LEVEL instead and you get the
// opposite failure: after completion EN is still high for the few cycles the
// clear takes to propagate, so the channel instantly re-runs the transfer it
// just finished.
//
// Neither is acceptable, so arming is carried as an EVENT instead. The register
// bank inverts arm_tog_o on every APB write to CR that has EN=1 - which is
// exactly the "set the EN bit LAST" action Sec. 6.6 defines as the start
// trigger - and this FSM converts it to a one-cycle hclk pulse. A toggle
// survives any clock ratio and any concurrent hardware clear, so re-arming in
// the same pclk cycle as the hardware clear works: software's write wins the
// flop AND produces the arm event.
//
// The synchronized EN level is still used, for the abort check below.
//
// =============================================================================
// DESIGN NOTE 2 - CONFIG CDC: why SAR/DAR/TCR/CR are sampled unsynchronized
// =============================================================================
// Per Sec. 15.3 these are guaranteed stable by software protocol, not by
// hardware. That is sound here, and the timing margin is worth stating because
// it is what makes CONFIGURED a real design feature rather than a spare cycle:
//   - SAR/DAR/TCR are written in APB transfers that COMPLETE before the CR
//     write that arms the channel - at least 2 pclk = 4 hclk earlier.
//   - The CR fields written alongside EN settle on the same pclk edge that
//     flips arm_tog_o. That toggle then crosses three hclk flops, and this FSM
//     samples in CONFIGURED one cycle after the pulse - four hclk (2 pclk)
//     after the CR flops settled.
// Sampling is therefore always well clear of the write edge. These paths are
// multi-cycle/false paths for STA and must be constrained as such in the SDC.
//
// =============================================================================
// DESIGN NOTE 3 - status flags live HERE, not in the register bank
// =============================================================================
// Sec. 3.1 lists SR under the pclk register bank, but Sec. 7.5 lists
// done_flag[5:0]/err_flag[5:0] as coming FROM the channel FSMs, and Sec. 3.1
// puts the IRQ aggregator in hclk. Sec. 7.5 is followed: the flags are set in
// hclk where the events happen, the aggregator reads them directly, and the
// register bank synchronizes them for APB readback. Putting the flags in pclk
// instead would mean synchronizing every set event across, which is strictly
// more crossings for the same result.
//
// The W1C clear arrives from pclk as a pulse. Set beats clear in the same
// cycle, deliberately: the clear is firmware acknowledging an OLDER event, so
// letting it win would silently drop a completion or a bus error. This is the
// same defect shape as ERRATUM DSU-8 in rtl/dsu/overflow_flag.v, where an
// overflow coinciding with its own clear was lost. Ordering in the always
// block is what enforces it - the flag-set assignments appear after the clear
// assignments, and the last non-blocking write wins.
// =============================================================================

`include "dma_defs.vh"

// No CH_ID parameter: the six instances are genuinely identical, and the
// generate label (dma_top.g_ch[n].u_ch) already identifies the channel in
// waveforms and in coverage hierarchy paths. A parameter carried only for
// naming would be dead logic that lint flags on every run.
module dma_channel_fsm (
    input  wire                  hclk_i,
    input  wire                  hreset_n_i,

    // ---- configuration from the pclk register bank (quasi-static, Note 2) --
    input  wire [31:0]           cfg_sar_i,
    input  wire [31:0]           cfg_dar_i,
    input  wire [`DMA_TCR_W-1:0] cfg_tcr_i,
    input  wire [`DMA_CR_W-1:0]  cfg_cr_i,

    // ---- CDC event toggles from the pclk register bank (Note 1) ------------
    input  wire                  arm_tog_i,        // CR written with EN=1
    input  wire                  clr_done_tog_i,   // SR.COMPLETE W1C
    input  wire                  clr_err_tog_i,    // SR.ERROR    W1C

    // ---- peripheral sideband (Sec. 5.4) ------------------------------------
    input  wire                  dma_req_i,
    output reg                   dma_ack_o,

    // ---- arbiter (Sec. 7.5) ------------------------------------------------
    output wire                  ch_req_o,
    output wire [2:0]            ch_pri_o,
    input  wire                  go_i,        // granted AND the AHB master is free

    // ---- AHB master beat interface -----------------------------------------
    output wire [31:0]           src_addr_o,
    output wire [31:0]           dst_addr_o,
    output wire [1:0]            size_o,
    input  wire                  beat_done_i, // qualified for THIS channel
    input  wire                  bus_error_i, // qualified for THIS channel

    // ---- status ------------------------------------------------------------
    output reg                   done_flag_o,     // SR.COMPLETE (hclk)
    output reg                   err_flag_o,      // SR.ERROR    (hclk)
    output reg                   en_clr_tog_o,    // toggle -> pclk: clear CR.EN
    output wire [`DMA_TCR_W-1:0] remaining_o,     // SR.REMAINING source (raw)
    output wire                  cnt_valid_o,     // remaining_o is meaningful
    output wire [2:0]            state_o          // observability / coverage
);

    // -----------------------------------------------------------------------
    // Clock-domain crossings into hclk
    // -----------------------------------------------------------------------
    wire en_p = cfg_cr_i[`DMA_CR_EN];
    wire en_h;                                   // EN, synchronized (Sec. 15.3)

    dma_cdc_sync #(.WIDTH(1), .RESET_VAL(1'b0)) u_en_sync (
        .clk_i   (hclk_i),
        .rst_n_i (hreset_n_i),
        .d_i     (en_p),
        .q_o     (en_h)
    );

    wire arm_pulse, clr_done, clr_err;

    dma_cdc_pulse u_arm_sync (
        .clk_i (hclk_i), .rst_n_i (hreset_n_i),
        .tog_i (arm_tog_i), .pulse_o (arm_pulse)
    );
    dma_cdc_pulse u_clr_done_sync (
        .clk_i (hclk_i), .rst_n_i (hreset_n_i),
        .tog_i (clr_done_tog_i), .pulse_o (clr_done)
    );
    dma_cdc_pulse u_clr_err_sync (
        .clk_i (hclk_i), .rst_n_i (hreset_n_i),
        .tog_i (clr_err_tog_i), .pulse_o (clr_err)
    );

    // -----------------------------------------------------------------------
    // Working registers (Sec. 7.1, CONFIGURED). The register-bank copies are
    // never modified by hardware - that is what makes the CIRC reload of
    // Sec. 6.6 possible without the CPU rewriting anything.
    // -----------------------------------------------------------------------
    reg [2:0]            state;
    reg [31:0]           src_addr_r;
    reg [31:0]           dst_addr_r;
    reg [`DMA_TCR_W-1:0] xfer_cnt;
    reg [1:0]            dir_r;
    reg [1:0]            size_r;
    reg                  sinc_r;
    reg                  dinc_r;
    reg                  circ_r;
    reg [2:0]            pri_r;
    reg                  err_abort_r;   // this COMPLETE was reached via bus error

    assign state_o    = state;
    assign src_addr_o = src_addr_r;
    assign dst_addr_o = dst_addr_r;
    assign size_o     = size_r;
    assign ch_pri_o   = pri_r;

    // -----------------------------------------------------------------------
    // Address increment step: 1, 2 or 4 bytes from CR.SIZE (Sec. 6.6).
    // Reserved SIZE=2'b11 steps by 4, matching dma_ahb_master's mapping of the
    // reserved encoding to a word transfer - the two MUST agree or a reserved
    // setting would walk the address at a different rate than it moves data.
    // -----------------------------------------------------------------------
    reg [2:0] addr_step;
    always @(*) begin
        case (size_r)
            `DMA_SZ_BYTE: addr_step = 3'd1;
            `DMA_SZ_HALF: addr_step = 3'd2;
            default:      addr_step = 3'd4;
        endcase
    end

    // -----------------------------------------------------------------------
    // Bus request (Sec. 7.5).
    // Memory-to-Memory has no peripheral behind it, so Sec. 9 states dma_req is
    // ignored and the channel proceeds on grant alone. Without this exception a
    // M2M transfer would wait forever on a dma_req line nothing drives.
    // -----------------------------------------------------------------------
    wire is_m2m   = (dir_r == `DMA_DIR_M2M);
    assign ch_req_o = (state == `DMA_ST_WAITING) && (dma_req_i || is_m2m);

    // -----------------------------------------------------------------------
    // SR.REMAINING source (Sec. 6.7). Crossed to pclk by dma_cdc_gray.
    //
    // ERRATUM DMA-1 - inconsistent SR snapshot across the clock crossing
    // -----------------------------------------------------------------------
    // This used to force the value to zero HERE, in hclk:
    //     assign remaining_o = (IDLE || COMPLETE) ? 0 : xfer_cnt;
    // which reads correctly but is not what firmware sees, because the two
    // halves of SR reach the pclk domain by paths of DIFFERENT depth:
    //
    //     SR.COMPLETE   flag -> 2 pclk flops                    (dma_cdc_sync)
    //     SR.REMAINING  count -> 1 hclk flop -> 2 pclk flops    (dma_cdc_gray)
    //
    // The gray coder registers binary->gray in the SOURCE domain before the
    // synchronizer - correctly, so the synchronizer never samples settling
    // combinational logic - but that extra stage delays REMAINING by up to one
    // hclk relative to the flag. One hclk is enough to land on the far side of
    // a pclk edge, so a single APB read of SR could return COMPLETE=1 together
    // with a stale REMAINING=1: a snapshot of a state the channel was never in,
    // contradicting Sec. 6.7 ("Reads 0 when ... transfer is complete").
    //
    // Found by the wait-state sweep at +GWAIT=8 (T2). It is invisible at low
    // wait counts purely because the completion happens to land in a different
    // pclk phase - exactly the kind of timing-sensitive defect that passes a
    // fixed-timing regression and fails silicon.
    //
    // Fixed by making the consistency STRUCTURAL instead of a latency
    // coincidence: the counter is exported raw, and a "this count is
    // meaningful" level is exported alongside it. The register bank pushes that
    // level through the SAME synchronizer as the status flags, so it changes on
    // the same pclk edge they do, and gates REMAINING to zero in the pclk
    // domain. Matching two synchronizer depths would also work today and would
    // break again the moment either path changes depth.
    //
    // A useful side effect: the gray source no longer takes a multi-bit jump to
    // zero on completion, so its one-bit-per-change property now holds for
    // every transition except the TCR load.
    // -----------------------------------------------------------------------
    assign remaining_o = xfer_cnt;

    assign cnt_valid_o = (state == `DMA_ST_WAITING) ||
                         (state == `DMA_ST_TRANSFER);

    // -----------------------------------------------------------------------
    // Zero-length guard.
    // Sec. 6.5 says TCR=0 means "no transfer, channel enters COMPLETE
    // immediately on enable"; Sec. 7.1 says CONFIGURED "always transitions to
    // WAITING_FOR_REQUEST". They contradict. Sec. 6.5 is the more specific
    // statement and is followed - a zero-beat transfer must not enter the
    // request/grant loop, because xfer_cnt would decrement from 0 and wrap to
    // 0xFFFF, turning an empty descriptor into a 65,536-beat runaway.
    // -----------------------------------------------------------------------
    wire tcr_is_zero = (cfg_tcr_i == {`DMA_TCR_W{1'b0}});

    // -----------------------------------------------------------------------
    // Main sequential block
    // -----------------------------------------------------------------------
    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            // Sec. 12: all channels to IDLE, all SR flags to 0, no bus
            // activity, dma_ack low. Working registers are reset too (the spec
            // calls their contents undefined) so simulation never propagates X
            // into an address that a bus monitor would flag.
            state        <= `DMA_ST_IDLE;
            src_addr_r   <= 32'b0;
            dst_addr_r   <= 32'b0;
            xfer_cnt     <= {`DMA_TCR_W{1'b0}};
            dir_r        <= `DMA_DIR_P2M;
            size_r       <= `DMA_SZ_WORD;
            sinc_r       <= 1'b0;
            dinc_r       <= 1'b0;
            circ_r       <= 1'b0;
            pri_r        <= 3'b0;
            err_abort_r  <= 1'b0;
            done_flag_o  <= 1'b0;
            err_flag_o   <= 1'b0;
            en_clr_tog_o <= 1'b0;
            dma_ack_o    <= 1'b0;
        end else begin
            // dma_ack is a 1-hclk pulse (Sec. 5.4): default low, re-asserted
            // only by the beat-complete arm below.
            dma_ack_o <= 1'b0;

            // ---------------------------------------------------------------
            // W1C clears (Sec. 6.7). These come FIRST so that a set later in
            // this same block overrides them - see DESIGN NOTE 3.
            // ---------------------------------------------------------------
            if (clr_done) done_flag_o <= 1'b0;
            if (clr_err)  err_flag_o  <= 1'b0;

            case (state)

                // -----------------------------------------------------------
                `DMA_ST_IDLE: begin
                    err_abort_r <= 1'b0;
                    if (arm_pulse)
                        state <= `DMA_ST_CONFIGURED;
                end

                // -----------------------------------------------------------
                // Single cycle. Latches every working register (Sec. 7.1).
                // This is also the CIRC reload path, which is why the latch
                // lives in the state rather than on the IDLE->CONFIGURED edge:
                // COMPLETE->CONFIGURED reuses it verbatim.
                `DMA_ST_CONFIGURED: begin
                    src_addr_r <= cfg_sar_i;
                    dst_addr_r <= cfg_dar_i;
                    xfer_cnt   <= cfg_tcr_i;
                    dir_r      <= cfg_cr_i[`DMA_CR_DIR_HI :`DMA_CR_DIR_LO];
                    size_r     <= cfg_cr_i[`DMA_CR_SZ_HI  :`DMA_CR_SZ_LO ];
                    sinc_r     <= cfg_cr_i[`DMA_CR_SINC];
                    dinc_r     <= cfg_cr_i[`DMA_CR_DINC];
                    circ_r     <= cfg_cr_i[`DMA_CR_CIRC];
                    pri_r      <= cfg_cr_i[`DMA_CR_PRI_HI:`DMA_CR_PRI_LO];

                    if (tcr_is_zero) begin
                        done_flag_o <= 1'b1;             // Sec. 6.5
                        state       <= `DMA_ST_COMPLETE;
                    end else begin
                        state       <= `DMA_ST_WAITING;
                    end
                end

                // -----------------------------------------------------------
                // Assert ch_req (combinational above) and wait for the arbiter.
                `DMA_ST_WAITING: begin
                    if (go_i) begin
                        state <= `DMA_ST_TRANSFER;
                    end else if (!en_h) begin
                        // Software cleared CR.EN. Sec. 6.6 calls this
                        // "undefined behavior"; undefined is given a definition
                        // here rather than left to chance, because the
                        // alternative is a channel parked in WAITING forever
                        // holding a request line the arbiter keeps honouring.
                        // Aborting is only allowed at a beat boundary - never
                        // from TRANSFERRING - so no bus transaction is ever
                        // abandoned mid-flight.
                        state <= `DMA_ST_IDLE;
                    end
                end

                // -----------------------------------------------------------
                // One beat in flight. Exit priority per Sec. 7.2.
                `DMA_ST_TRANSFER: begin
                    if (bus_error_i) begin
                        // Priority 1: abort immediately, do not decrement, do
                        // not acknowledge the peripheral - the beat did not
                        // move data.
                        err_flag_o  <= 1'b1;
                        err_abort_r <= 1'b1;
                        state       <= `DMA_ST_COMPLETE;
                    end else if (beat_done_i) begin
                        dma_ack_o <= 1'b1;                       // Sec. 5.4

                        if (sinc_r) src_addr_r <= src_addr_r + {29'b0, addr_step};
                        if (dinc_r) dst_addr_r <= dst_addr_r + {29'b0, addr_step};
                        xfer_cnt <= xfer_cnt - {{(`DMA_TCR_W-1){1'b0}}, 1'b1};

                        // Compare against 1, not 0: xfer_cnt still holds the
                        // pre-decrement value in this cycle, so "this was the
                        // last beat" is xfer_cnt==1.
                        if (xfer_cnt == {{(`DMA_TCR_W-1){1'b0}}, 1'b1}) begin
                            done_flag_o <= 1'b1;                 // Sec. 7.2 #2
                            state       <= `DMA_ST_COMPLETE;
                        end else begin
                            // Sec. 7.2 #3 and #4 both land here: release the
                            // bus so the arbiter re-evaluates (Sec. 8.3),
                            // whether or not dma_req is still asserted.
                            state <= `DMA_ST_WAITING;
                        end
                    end
                end

                // -----------------------------------------------------------
                // Single cycle. The status flag was set on the transition in.
                `DMA_ST_COMPLETE: begin
                    if (circ_r && !err_abort_r && !tcr_is_zero) begin
                        // Sec. 6.6 CIRC: reload SAR/DAR/TCR from the register
                        // bank and restart, without CPU involvement. EN stays
                        // set.
                        //
                        // Two guards on that restart, both preventing a
                        // livelock the spec does not address:
                        //   !err_abort_r - restarting after a bus error would
                        //     hammer the faulting address forever and re-raise
                        //     dma_err on every lap, with firmware unable to
                        //     clear it faster than hardware re-sets it. A
                        //     circular channel that faults stops and reports.
                        //   !tcr_is_zero - CIRC with TCR=0 would spin
                        //     CONFIGURED->COMPLETE->CONFIGURED forever, setting
                        //     SR.COMPLETE every other cycle.
                        state <= `DMA_ST_CONFIGURED;
                    end else begin
                        // Single-shot (or a stopped circular channel): clear
                        // CR.EN back in the pclk domain and go idle.
                        en_clr_tog_o <= ~en_clr_tog_o;
                        state        <= `DMA_ST_IDLE;
                    end
                end

                // -----------------------------------------------------------
                default: state <= `DMA_ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
