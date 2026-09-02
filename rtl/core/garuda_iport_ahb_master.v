`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// GARUDA SoC — Block I: Processor Core
// Module      : garuda_iport_ahb_master
// Description : I-port AHB-Lite master. Drives the pipelined address/data
//               phase protocol, issues NONSEQ/SEQ transfers, and safely
//               discards in-flight data across a redirect.
// Spec Ref    : AERO-GARUDA-DS-001 Rev 1.0, §6.4, §16
// ============================================================================
//
// Fixed (constant) outputs per §4.1: i_hsize_o, i_hprot_o, i_hwrite_o,
// i_hwdata_o, i_hburst_o.
//
// This port emits an undefined-length INCR burst per run of sequential
// fetches, broken (and reopened with NONSEQ) whenever the stream stops or
// jumps. See ERRATUM BUS-A/B/C/D below -- all four were found by
// tb/ahb/ahb_lite_checker.v, the first thing in the project ever to look at
// HBURST, and all four had been invisible because ahb_mem_slave.v services
// every transfer as an independent SINGLE and returns correct data
// regardless of what the burst signalling claims.
//
// `drop_pending` fixes a one-cycle hazard: if a redirect fires while a
// fetch is still outstanding on the bus, that fetch's data phase often
// completes ONE CYCLE AFTER the redirect pulse has already fallen. Gating
// the write only on ~redirect_i would let that stale data slip into the
// buffer right after a flush. `drop_pending` latches the discard
// obligation and holds it until the specific outstanding data phase
// completes, regardless of redirect_i's value at that later cycle (§6.5).
// ============================================================================

module garuda_iport_ahb_master #(
    parameter FIFO_DEPTH = 4
) (
    input  wire        clk_i,
    input  wire        rst_n_i,

    input  wire        redirect_i,

    // Current speculative fetch address (from PC generator)
    input  wire [31:0] fetch_pc_i,

    // Buffer occupancy (pre-edge value) and whether a pop is happening
    // this same cycle — used to correctly reserve capacity (§9.4-style
    // "don't let more become outstanding+buffered than the buffer can
    // ever hold" invariant).
    input  wire [ 2:0] fifo_occupancy_i,
    input  wire        fifo_rd_en_i,

    // ----------------------------------------------------------------
    // I-port AHB-Lite master (to interconnect)
    // ----------------------------------------------------------------
    output reg  [31:0] i_haddr_o,
    output reg  [ 1:0] i_htrans_o,
    output wire [ 2:0] i_hsize_o,
    output wire [ 2:0] i_hburst_o,
    output wire [ 3:0] i_hprot_o,
    output wire        i_hwrite_o,
    output wire [31:0] i_hwdata_o,

    input  wire [31:0] i_hrdata_i,
    input  wire        i_hready_i,
    input  wire        i_hresp_i,

    // ----------------------------------------------------------------
    // To PC generator / prefetch buffer
    // ----------------------------------------------------------------
    output wire        fetch_issue_o,   // address phase accepted this cycle
    output wire        data_valid_o,    // legitimate data phase completion
    output wire [31:0] data_instr_o,
    output wire [31:0] data_pc_o,
    output wire        data_fault_o
);

    localparam HTRANS_IDLE   = 2'b00;
    localparam HTRANS_NONSEQ = 2'b10;
    localparam HTRANS_SEQ    = 2'b11;

    // Fixed I-port outputs (§4.1)
    assign i_hsize_o  = 3'b010;
    assign i_hprot_o  = 4'b0010;
    assign i_hwrite_o = 1'b0;
    assign i_hwdata_o = 32'b0;
    // -----------------------------------------------------------------------
    // ERRATUM BUS-A
    // -----------------------------------------------------------------------
    // This was  (i_htrans_o == HTRANS_SEQ) ? 3'b001 : 3'b000  -- HBURST
    // derived from the CURRENT HTRANS. That gets the burst backwards: the
    // opening beat of every burst is NONSEQ, so it declared SINGLE, and each
    // following beat declared INCR. Two rules broken at once (IHI 0033, 3.5):
    // HBURST must be constant for every beat of a burst, and a SINGLE burst
    // consists of exactly one transfer, so the SEQ beats that followed had no
    // burst to belong to. 494 violations in a single add.hex run.
    //
    // The fix is to state the truth once: this port only ever issues
    // undefined-length incrementing bursts. INCR is legal for a run of any
    // length including one, so a lone fetch needs no special case, and being
    // a constant it cannot vary across beats or across a wait state.
    // -----------------------------------------------------------------------
    assign i_hburst_o = 3'b001;                   // INCR, always

    // -----------------------------------------------------------------------
    // ERRATUM I-1 (found by tb_boot, first full-pipeline run)
    // -----------------------------------------------------------------------
    // This module previously carried a single `fetch_outstanding` flag, set on
    // the same edge that drove i_haddr_o/i_htrans_o onto the bus, with
    //     data_phase_done = fetch_outstanding & i_hready_i
    // Because HADDR/HTRANS are REGISTERED, the cycle in which they are
    // presented IS the address phase - so that expression fired one cycle
    // early, during the address phase, and sampled i_hrdata_i before the slave
    // had driven it. Every instruction was therefore paired with the PREVIOUS
    // bus cycle's read data while keeping its own correct PC tag: the very
    // first fetch delivered (pc=reset_vector, instr=0x00000000), which decodes
    // as an illegal instruction and trapped the core to mtvec=0 on instruction
    // one. It was never caught before because no testbench had ever run a real
    // instruction stream through the I-port.
    //
    // AHB-Lite is a PIPELINED protocol: the address phase of transfer N+1
    // overlaps the data phase of transfer N. Two independent flags are
    // therefore required, not one.
    //   addr_outstanding : HADDR/HTRANS presented, address phase not yet
    //                      accepted (accepted when HREADY=1)
    //   data_outstanding : address phase accepted, slave now owes read data
    //                      (delivered on the cycle HREADY=1)
    // At most one of each can be in flight here, so up to TWO transfers are
    // live at once and the FIFO reservation below must account for both.
    // -----------------------------------------------------------------------
    reg        addr_outstanding;
    reg [31:0] addr_pc;              // PC whose address phase is on the bus
    reg        data_outstanding;
    reg [31:0] outstanding_pc;       // PC whose data phase is in progress
    reg        need_nonseq;          // next beat must open a new burst
    reg [1:0]  drop_cnt;             // in-flight transfers to discard

    wire addr_phase_done = addr_outstanding & i_hready_i;
    wire data_phase_done = data_outstanding & i_hready_i;

    // ---- burst continuation (ERRATUM BUS-B / BUS-D) ------------------------
    // A SEQ beat is legal only as the continuation of an open INCR burst, and
    // AHB-Lite constrains what "continuation" means (IHI 0033, 3.5):
    //   - the address must be the previous beat's address plus one HSIZE (4)
    //   - the burst must not cross a 1 KB boundary
    // Both are derived here from this port's own bus state rather than
    // inferred from "a redirect is the only thing that can move the PC
    // non-sequentially". That inference holds today, but it is a premise
    // about another module, and the interconnect now being built on top of
    // this port has to be able to trust HTRANS/HBURST locally.
    //
    // BUS-D is the 1 KB rule specifically. Nothing had enforced it and
    // nothing had checked it. It is harmless against a single flat memory
    // model and becomes a real defect the moment an address decoder exists,
    // because 1 KB is the minimum slave window: a burst allowed to run past
    // the boundary is a burst that can cross from one slave into another
    // while the decoder still believes it is mid-burst on the first.
    wire seq_contiguous  = (fetch_pc_i == (i_haddr_o + 32'd4));
    wire seq_within_1k   = (fetch_pc_i[9:0] != 10'd0);
    wire start_new_burst = need_nonseq | ~seq_contiguous | ~seq_within_1k;

    // Projected occupancy immediately after this cycle settles, BEFORE
    // counting the new fetch we're deciding whether to issue:
    //   + 1 if the currently-outstanding fetch is landing in the buffer
    //       this very cycle (data_phase_done)
    //   - 1 if the buffer is also being popped this cycle
    //   + every transfer still in flight that has yet to land
    // The in-flight term is what keeps a 2-deep pipeline from overrunning a
    // depth-4 FIFO: without it a new fetch could be issued while two earlier
    // ones are still owed data, silently exceeding FIFO_DEPTH.
    wire [3:0] occ_plus_landing = {1'b0, fifo_occupancy_i} +
                                  (data_phase_done ? 4'd1 : 4'd0);
    wire [3:0] occ_after_pop    = (fifo_rd_en_i && occ_plus_landing != 4'd0)
                                   ? occ_plus_landing - 4'd1
                                   : occ_plus_landing;

    wire [3:0] inflight = {3'b0, addr_outstanding} +
                          {3'b0, data_outstanding} -
                          (data_phase_done ? 4'd1 : 4'd0);

    wire [3:0] projected_occ = occ_after_pop + inflight;

    wire room_for_new_fetch = (projected_occ < FIFO_DEPTH);

    // Issue a new address phase when: the bus is ready, the previous address
    // phase has been accepted (or is being accepted this cycle), the buffer
    // will have room for everything in flight, and we're not mid-redirect.
    assign fetch_issue_o = ~redirect_i & i_hready_i &
                            (~addr_outstanding | addr_phase_done) &
                            room_for_new_fetch;

    // Only a legitimate (non-dropped) data phase writes the buffer. HRDATA is
    // sampled here in the DATA phase - one cycle after the address phase was
    // accepted - which is the whole point of ERRATUM I-1.
    assign data_valid_o  = data_phase_done & ~redirect_i & (drop_cnt == 2'd0);
    assign data_instr_o  = i_hrdata_i;
    assign data_pc_o     = outstanding_pc;
    assign data_fault_o  = i_hresp_i;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            i_haddr_o        <= 32'b0;
            i_htrans_o       <= HTRANS_IDLE;      // idle out of reset (§4.2)
            addr_outstanding <= 1'b0;
            addr_pc          <= 32'b0;
            data_outstanding <= 1'b0;
            outstanding_pc   <= 32'b0;
            need_nonseq      <= 1'b1;             // first fetch is NONSEQ
            drop_cnt         <= 2'd0;

        end else if (redirect_i) begin
            // -------------------------------------------------------------
            // ERRATUM BUS-C
            // -------------------------------------------------------------
            // This branch used to clear addr_outstanding and drive
            // i_htrans_o <= HTRANS_IDLE unconditionally. When HREADY was low
            // that RETRACTED an address phase the master had already
            // presented. AHB-Lite has no cancel (IHI 0033, 3.6): once a
            // transfer is presented, the master must hold it until the slave
            // accepts it and then discard the data that comes back. The old
            // comment here asserted the opposite -- that an unaccepted
            // address phase "never produces data" -- which is what made the
            // bug look correct. It is only true if the slave agrees to
            // forget the transfer, and nothing obliges it to.
            //
            // So on redirect there are up to three transfers whose data must
            // be discarded when it lands:
            //   - a data phase in progress that does not complete this cycle
            //   - an address phase accepted this cycle (its data comes next)
            //   - an address phase still being presented, which we are now
            //     obliged to see through to acceptance (this erratum)
            // The last two are mutually exclusive -- addr_phase_done tells
            // them apart -- so at most two are ever counted, within drop_cnt.
            drop_cnt         <= ((data_outstanding & ~data_phase_done) ? 2'd1 : 2'd0) +
                                (addr_phase_done                       ? 2'd1 : 2'd0) +
                                ((addr_outstanding & ~addr_phase_done) ? 2'd1 : 2'd0);
            data_outstanding <= (data_outstanding & ~data_phase_done) | addr_phase_done;
            need_nonseq      <= 1'b1;

            if (addr_outstanding & ~addr_phase_done) begin
                // Presented but not accepted: HOLD it. Deliberately no
                // assignment to i_haddr_o / i_htrans_o / addr_outstanding --
                // the transfer stays exactly as presented until HREADY rises,
                // at which point the normal path below turns it into a data
                // phase that drop_cnt has already marked for discard.
            end else begin
                addr_outstanding <= 1'b0;
                i_htrans_o       <= HTRANS_IDLE;  // legal: nothing presented
            end

        end else begin
            // ---- data-phase progression ----
            // An accepted address phase becomes the next data phase; a
            // completing data phase retires (and satisfies one drop, if owed).
            if (addr_phase_done) begin
                data_outstanding <= 1'b1;
                outstanding_pc   <= addr_pc;
            end else if (data_phase_done) begin
                data_outstanding <= 1'b0;
            end

            if (data_phase_done && (drop_cnt != 2'd0))
                drop_cnt <= drop_cnt - 2'd1;

            // ---- address-phase drive ----
            if (fetch_issue_o) begin
                i_haddr_o        <= fetch_pc_i;
                i_htrans_o       <= start_new_burst ? HTRANS_NONSEQ
                                                    : HTRANS_SEQ;
                addr_outstanding <= 1'b1;
                addr_pc          <= fetch_pc_i;
                need_nonseq      <= 1'b0;
            end else if (addr_outstanding && !addr_phase_done) begin
                // Wait state in progress (HREADY was low): hold HADDR and
                // HTRANS exactly as they were — do NOT touch them here.
                // (No assignment = register retains its value.)
            end else begin
                // Nothing to present this cycle (buffer full, or a just-
                // accepted address phase with no follow-on issue).
                //
                // ERRATUM BUS-B: driving IDLE here ENDS the burst, so the
                // next transfer must open a new one with NONSEQ. The old
                // `after_redirect` flag tracked only redirects, so a burst
                // broken by a full prefetch buffer resumed with SEQ -- a SEQ
                // beat with no open burst. The flag has to be set on every
                // path that emits IDLE, not just the redirect path, which is
                // why it is now named for what it means rather than for the
                // one event that used to set it.
                addr_outstanding <= 1'b0;
                i_htrans_o       <= HTRANS_IDLE;
                need_nonseq      <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
