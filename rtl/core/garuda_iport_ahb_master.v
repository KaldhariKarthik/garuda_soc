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
// i_hwdata_o. i_hburst_o follows current HTRANS (INCR while SEQ, else
// SINGLE).
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
    assign i_hburst_o = (i_htrans_o == HTRANS_SEQ) ? 3'b001 : 3'b000;

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
    reg        after_redirect;
    reg [1:0]  drop_cnt;             // in-flight transfers to discard

    wire addr_phase_done = addr_outstanding & i_hready_i;
    wire data_phase_done = data_outstanding & i_hready_i;

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
            after_redirect   <= 1'b1;             // first fetch is NONSEQ
            drop_cnt         <= 2'd0;

        end else if (redirect_i) begin
            // Count the transfers that will still deliver data AFTER this
            // cycle and must therefore be discarded when they land:
            //   - a data phase in progress that does not complete this cycle
            //   - an address phase accepted this cycle (its data comes next)
            // An address phase NOT yet accepted is retracted by the IDLE
            // below and never produces data, so it is not counted.
            drop_cnt         <= ((data_outstanding & ~data_phase_done) ? 2'd1 : 2'd0) +
                                (addr_phase_done                       ? 2'd1 : 2'd0);
            data_outstanding <= (data_outstanding & ~data_phase_done) | addr_phase_done;
            addr_outstanding <= 1'b0;
            after_redirect   <= 1'b1;
            i_htrans_o       <= HTRANS_IDLE;      // idle this cycle

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
                i_htrans_o       <= after_redirect ? HTRANS_NONSEQ
                                                   : HTRANS_SEQ;
                addr_outstanding <= 1'b1;
                addr_pc          <= fetch_pc_i;
                after_redirect   <= 1'b0;
            end else if (addr_outstanding && !addr_phase_done) begin
                // Wait state in progress (HREADY was low): hold HADDR and
                // HTRANS exactly as they were — do NOT touch them here.
                // (No assignment = register retains its value.)
            end else begin
                // Nothing to present this cycle (buffer full, or a just-
                // accepted address phase with no follow-on issue).
                addr_outstanding <= 1'b0;
                i_htrans_o       <= HTRANS_IDLE;
            end
        end
    end

endmodule

`default_nettype wire
