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

    reg        fetch_outstanding;
    reg [31:0] outstanding_pc;
    reg        after_redirect;
    reg        drop_pending;

    wire data_phase_done = fetch_outstanding & i_hready_i;

    // Projected occupancy immediately after this cycle settles, BEFORE
    // counting the new fetch we're deciding whether to issue:
    //   + 1 if the currently-outstanding fetch is landing in the buffer
    //       this very cycle (data_phase_done)
    //   - 1 if the buffer is also being popped this cycle
    // This is the fix for the overflow bug: without the data_phase_done
    // term, a new fetch could be issued in the same cycle a 4th entry
    // lands, silently exceeding FIFO_DEPTH and corrupting entry 0.
    wire [3:0] occ_plus_landing = {1'b0, fifo_occupancy_i} +
                                  (data_phase_done ? 4'd1 : 4'd0);
    wire [3:0] projected_occ    = (fifo_rd_en_i && occ_plus_landing != 4'd0)
                                   ? occ_plus_landing - 4'd1
                                   : occ_plus_landing;

    wire room_for_new_fetch = (projected_occ < FIFO_DEPTH);

    // Issue a new address phase when: bus is ready, no fetch is stuck
    // waiting for data (or that wait just resolved this cycle), the
    // buffer will have room after this cycle settles, and we're not
    // mid-redirect.
    assign fetch_issue_o = ~redirect_i & i_hready_i &
                            (~fetch_outstanding | data_phase_done) &
                            room_for_new_fetch;

    // Only a legitimate (non-dropped) data phase writes the buffer.
    assign data_valid_o  = data_phase_done & ~redirect_i & ~drop_pending;
    assign data_instr_o  = i_hrdata_i;
    assign data_pc_o     = outstanding_pc;
    assign data_fault_o  = i_hresp_i;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            i_haddr_o         <= 32'b0;
            i_htrans_o        <= HTRANS_IDLE;      // idle out of reset (§4.2)
            fetch_outstanding <= 1'b0;
            outstanding_pc    <= 32'b0;
            after_redirect    <= 1'b1;             // first fetch is NONSEQ
            drop_pending      <= 1'b0;

        end else if (redirect_i) begin
            // Latch the discard obligation if a fetch is still in flight.
            drop_pending   <= fetch_outstanding;
            after_redirect <= 1'b1;
            i_htrans_o     <= HTRANS_IDLE;         // idle this cycle

        end else begin
            if (data_phase_done) begin
                fetch_outstanding <= 1'b0;
                drop_pending      <= 1'b0;         // obligation satisfied
            end

            if (fetch_issue_o) begin
                i_haddr_o         <= fetch_pc_i;
                i_htrans_o        <= after_redirect ? HTRANS_NONSEQ
                                                     : HTRANS_SEQ;
                fetch_outstanding <= 1'b1;
                outstanding_pc    <= fetch_pc_i;
                after_redirect    <= 1'b0;
            end else if (fetch_outstanding && !data_phase_done) begin
                // Wait state in progress (HREADY was low): hold HADDR and
                // HTRANS exactly as they were — do NOT touch them here.
                // (No assignment = register retains its value.)
            end else begin
                // Genuinely nothing to drive this cycle (buffer full with
                // no outstanding fetch, or a just-completed fetch with no
                // follow-on issue because the buffer became full).
                i_htrans_o <= HTRANS_IDLE;
            end
        end
    end

endmodule
