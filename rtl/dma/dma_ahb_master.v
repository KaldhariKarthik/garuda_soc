`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_ahb_master.v - AHB-Lite master, 6-state beat engine + data buffer + MUX
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 3.1 (#5,#6), Sec. 5.3,
//                 Sec. 7.4, Sec. 11.1
// Protocol:       ARM AMBA 3 AHB-Lite, IHI 0033A
//
// One "beat" = one read from the source + one write to the destination, moving
// a single data unit of CR.SIZE width. This module owns the bus for exactly
// one beat and then returns to IDLE so the arbiter can re-evaluate (Sec. 8.3).
//
// -----------------------------------------------------------------------------
// STATE MAP - and its one deviation from the Sec. 7.4 table
// -----------------------------------------------------------------------------
// Sec. 7.4 names six states: IDLE, READ_ADDR, READ_DATA, WRITE_ADDR,
// WRITE_DATA, DONE. But that table is internally inconsistent: the "Drives"
// column for READ_DATA says "(address of next phase)" - i.e. READ_DATA is
// ALREADY driving the write address phase - and the note beneath it states
// "READ_DATA and WRITE_ADDR overlap by one cycle ... A complete beat takes
// approximately 3 hclk cycles". Three cycles is only reachable if the read
// data phase and the write address phase are the SAME cycle. Two separate
// states cannot overlap; a beat would take four bus cycles and the Sec. 11.1
// latency table would be wrong.
//
// Resolved in favour of the timing requirement (the RTL-wins rule, README):
// READ_DATA and WRITE_ADDR are one state, S_RDATA_WADDR, exactly as the
// spec's own "Drives" column describes. The freed encoding is spent on
// S_ERROR, which the Sec. 7.4 table omits and which the AMBA two-cycle ERROR
// response makes mandatory (see below). The state count stays at six.
//
//   S_IDLE        htrans=IDLE                      waiting for a granted beat
//   S_RADDR       read address phase               haddr=src, NONSEQ, hwrite=0
//   S_RDATA_WADDR read data phase  +  write        haddr=dst, NONSEQ, hwrite=1
//                 address phase (overlapped)       captures HRDATA
//   S_WDATA       write data phase                 hwdata=buffer, htrans=IDLE
//   S_DONE        htrans=IDLE                      pulse beat_done_o
//   S_ERROR       htrans=IDLE                      absorb error, pulse bus_error_o
//
// -----------------------------------------------------------------------------
// WHY S_ERROR EXISTS - the pipelined-cancel trap
// -----------------------------------------------------------------------------
// In S_RDATA_WADDR two things happen at once: the READ is in its data phase,
// and the WRITE address phase is being presented. If the read comes back
// ERROR, the write address must be CANCELLED - otherwise the DMA writes
// whatever stale rubbish is in the data buffer to the destination after the
// source read already failed. Silent data corruption on a bus fault.
//
// AMBA makes this cancellable by mandating a TWO-cycle ERROR response:
//   cycle 1:  HREADY=0, HRESP=ERROR   <- warning; address phase NOT accepted
//   cycle 2:  HREADY=1, HRESP=ERROR   <- completion
// The master gets one full cycle to react. On cycle 1 this FSM jumps to
// S_ERROR, which drives HTRANS=IDLE, so on cycle 2 the pending write address
// phase is retracted instead of accepted. This is the entire reason a separate
// state is needed rather than a flag: HTRANS must be registered to IDLE by the
// next edge.
//
// This is a REQUIREMENT ON THE INTERCONNECT, not just on this module: a slave
// that signals ERROR in a single cycle (HRESP=1 with HREADY=1, no preceding
// HREADY=0 cycle) is not AMBA-compliant and would have its write address phase
// accepted before this FSM can retract it. rtl/ahb/ahb_mem_slave.v issues the
// mandatory two-cycle response, and the AHB2APB bridge must too. The defensive
// single-cycle path below aborts the beat, but by then the write address is
// already on the bus and one spurious write may reach the destination.
//
// -----------------------------------------------------------------------------
// BYTE LANE ALIGNMENT (Sec. 5.3, "data is lane-aligned per AMBA spec")
// -----------------------------------------------------------------------------
// This is not optional bookkeeping - it is load-bearing for the headline use
// case. The IMU example in Sec. 13.2 uses CR_SZ_BYTE with a fixed source
// (SPI RX FIFO at 0x40001004) and an incrementing destination. On AHB a byte
// lives on the lane selected by HADDR[1:0]. Source byte lane is constant;
// destination byte lane walks 0,1,2,3,0,... So for 3 out of every 4 beats the
// source and destination lanes DIFFER. Passing HRDATA straight to HWDATA would
// put the byte on the wrong lane and the DSRAM buffer would fill with garbage
// in a pattern that looks like an addressing bug.
//
// Read side:  extract the addressed lane and right-justify it into the buffer.
// Write side: replicate the right-justified value across all four lanes. AMBA
// leaves unused lanes don't-care, and replication means whichever lane the
// destination address selects already carries the correct data - no second
// shifter, and no dependence on the slave's lane-select style.
// =============================================================================

`include "dma_defs.vh"

module dma_ahb_master (
    input  wire                    hclk_i,
    input  wire                    hreset_n_i,

    // ---- beat launch (from dma_top: arbiter grant qualified with idle_o) ----
    input  wire                    start_i,      // begin a beat this cycle
    input  wire [2:0]              ch_sel_i,     // arbiter winner index

    // ---- per-channel working registers, flattened (Sec. 7.5) ----
    input  wire [`DMA_NCH*32-1:0]  src_addr_i,
    input  wire [`DMA_NCH*32-1:0]  dst_addr_i,
    input  wire [`DMA_NCH*2-1:0]   size_i,       // CR.SIZE, 2 bits per channel

    // ---- AHB-Lite master port (Sec. 5.3) ----
    output reg  [31:0]             haddr_o,
    output reg  [1:0]              htrans_o,
    output reg                     hwrite_o,
    output reg  [2:0]              hsize_o,
    output wire [2:0]              hburst_o,
    output wire [31:0]             hwdata_o,
    input  wire [31:0]             hrdata_i,
    input  wire                    hready_i,
    input  wire                    hresp_i,

    // ---- status back to the channel FSMs ----
    output wire                    idle_o,       // ready to accept start_i
    output reg  [2:0]              ch_lock_o,    // channel owning the current beat
    output wire                    beat_done_o,  // 1-cycle: beat moved OK
    output wire                    bus_error_o   // 1-cycle: beat aborted, HRESP=ERROR
);

    // -----------------------------------------------------------------------
    // State encoding
    // -----------------------------------------------------------------------
    localparam [2:0] S_IDLE        = 3'd0,
                     S_RADDR       = 3'd1,
                     S_RDATA_WADDR = 3'd2,
                     S_WDATA       = 3'd3,
                     S_DONE        = 3'd4,
                     S_ERROR       = 3'd5;

    reg [2:0]  state;
    reg [31:0] src_r;        // latched at beat start - see "why latch" below
    reg [31:0] dst_r;
    reg [1:0]  size_r;
    reg [31:0] data_buf;     // right-justified payload (Sec. 3.1 #6)
    reg        err_r;        // this beat ended in a bus error

    assign idle_o   = (state == S_IDLE);
    assign hburst_o = `AHB_BURST_SINGLE;     // always SINGLE (Sec. 5.3, 16.4)

    // -----------------------------------------------------------------------
    // Beat-parameter MUX (Sec. 3.1 #5, "address/control MUX")
    //
    // WHY LATCH RATHER THAN DRIVE THE MUX CONTINUOUSLY
    // The selected channel's src_addr_r/dst_addr_r update on beat_done, in the
    // same cycle this FSM reaches S_DONE. Continuously re-driving HADDR from a
    // live mux would therefore be safe only by accident of ordering. Latching
    // at start_i makes the beat's parameters immutable for its whole duration
    // and removes any dependence on when the channel FSM updates its working
    // registers. It also means ch_sel_i is only sampled on one cycle, so a
    // mid-beat arbiter swing (which does happen - the arbiter is combinational
    // and re-evaluates every cycle) cannot reach the bus.
    // -----------------------------------------------------------------------
    wire [31:0] sel_src  = src_addr_i[32*ch_sel_i +: 32];
    wire [31:0] sel_dst  = dst_addr_i[32*ch_sel_i +: 32];
    wire [1:0]  sel_size = size_i    [ 2*ch_sel_i +:  2];

    // -----------------------------------------------------------------------
    // HSIZE from CR.SIZE.
    // CR.SIZE=2'b11 is Reserved (Sec. 6.6). It is mapped to WORD rather than
    // passed through, because {1'b0,2'b11} = 3'b011 is HSIZE=64-bit, which is
    // illegal on a 32-bit AHB data bus and would hang or corrupt a compliant
    // slave. Reserved encodings must degrade to something legal, never to
    // something that violates the bus protocol.
    // -----------------------------------------------------------------------
    wire [2:0] hsize_from_size = (size_r == 2'b11) ? `AHB_SIZE_WORD
                                                   : {1'b0, size_r};

    // -----------------------------------------------------------------------
    // Read-side lane extraction -> right-justified into the data buffer
    // -----------------------------------------------------------------------
    wire [4:0]  rd_shift  = {src_r[1:0], 3'b000};       // 0, 8, 16 or 24
    wire [31:0] rd_lanes  = hrdata_i >> rd_shift;

    reg [31:0] rd_extract;
    always @(*) begin
        case (size_r)
            `DMA_SZ_BYTE: rd_extract = {24'b0, rd_lanes[7:0]};
            `DMA_SZ_HALF: rd_extract = {16'b0, rd_lanes[15:0]};
            default:      rd_extract = hrdata_i;         // WORD and reserved
        endcase
    end

    // -----------------------------------------------------------------------
    // Write-side lane replication (see header). Driven continuously; only
    // sampled by the slave during the write data phase, where data_buf holds
    // the payload captured at the end of S_RDATA_WADDR.
    // -----------------------------------------------------------------------
    reg [31:0] wr_place;
    always @(*) begin
        case (size_r)
            `DMA_SZ_BYTE: wr_place = {4{data_buf[7:0]}};
            `DMA_SZ_HALF: wr_place = {2{data_buf[15:0]}};
            default:      wr_place = data_buf;
        endcase
    end
    assign hwdata_o = wr_place;

    // -----------------------------------------------------------------------
    // Address / control phase drive (combinational from state)
    // -----------------------------------------------------------------------
    always @(*) begin
        // Default: no transfer. HADDR/HSIZE are don't-care while HTRANS=IDLE,
        // but are driven to fixed values so waveforms are readable and no X
        // propagates into a bus monitor.
        haddr_o  = 32'h0000_0000;
        htrans_o = `AHB_TRANS_IDLE;
        hwrite_o = 1'b0;
        hsize_o  = `AHB_SIZE_WORD;

        case (state)
            S_RADDR: begin
                haddr_o  = src_r;
                htrans_o = `AHB_TRANS_NONSEQ;
                hwrite_o = 1'b0;
                hsize_o  = hsize_from_size;
            end
            S_RDATA_WADDR: begin
                // The read's DATA phase is in flight on the data bus while the
                // write's ADDRESS phase is presented here. This is the overlap
                // Sec. 7.4 describes; it is what makes a beat 3 bus cycles.
                haddr_o  = dst_r;
                htrans_o = `AHB_TRANS_NONSEQ;
                hwrite_o = 1'b1;
                hsize_o  = hsize_from_size;
            end
            // S_WDATA, S_DONE, S_ERROR and S_IDLE all drive HTRANS=IDLE.
            // S_ERROR doing so is what retracts the pending write address
            // phase during the second cycle of the AMBA error response.
            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // Error detection.
    //   err_warn - first cycle of the AMBA two-cycle response. The current
    //              address phase has NOT been accepted; retract it now.
    //   err_take - the completing cycle of an error response.
    // -----------------------------------------------------------------------
    wire err_warn = hresp_i && !hready_i;
    wire err_take = hresp_i &&  hready_i;

    // -----------------------------------------------------------------------
    // Sequential control
    // -----------------------------------------------------------------------
    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            state     <= S_IDLE;
            src_r     <= 32'b0;
            dst_r     <= 32'b0;
            size_r    <= `DMA_SZ_WORD;
            data_buf  <= 32'b0;
            ch_lock_o <= 3'b0;
            err_r     <= 1'b0;
        end else begin
            case (state)

                // -------------------------------------------------------
                S_IDLE: begin
                    err_r <= 1'b0;
                    if (start_i) begin
                        ch_lock_o <= ch_sel_i;
                        src_r     <= sel_src;
                        dst_r     <= sel_dst;
                        size_r    <= sel_size;
                        state     <= S_RADDR;
                    end
                end

                // -------------------------------------------------------
                // Read ADDRESS phase. HRESP here belongs to the PREVIOUS
                // transfer's data phase, and this FSM only ever arrives from
                // a state driving HTRANS=IDLE - an IDLE transfer always
                // responds OKAY - so HRESP cannot be meaningfully asserted
                // in this state and is deliberately not sampled.
                S_RADDR: begin
                    if (hready_i)
                        state <= S_RDATA_WADDR;
                end

                // -------------------------------------------------------
                // Read DATA phase overlapped with write ADDRESS phase.
                S_RDATA_WADDR: begin
                    if (err_warn) begin
                        // Read failed. Next cycle drives HTRANS=IDLE, which
                        // retracts the write address phase before the slave
                        // can accept it. Nothing is written.
                        err_r <= 1'b1;
                        state <= S_ERROR;
                    end else if (hready_i) begin
                        if (err_take) begin
                            // Non-compliant single-cycle ERROR: the write
                            // address phase has already been accepted. Abort;
                            // one spurious write may still land. See header.
                            err_r <= 1'b1;
                            state <= S_ERROR;
                        end else begin
                            data_buf <= rd_extract;
                            state    <= S_WDATA;
                        end
                    end
                end

                // -------------------------------------------------------
                // Write DATA phase. HTRANS is already IDLE, so there is no
                // pending address phase to retract - but the two-cycle error
                // response must still be absorbed before the bus is released.
                S_WDATA: begin
                    if (err_warn) begin
                        err_r <= 1'b1;
                        state <= S_ERROR;
                    end else if (hready_i) begin
                        if (err_take) begin
                            err_r <= 1'b1;
                            state <= S_ERROR;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end

                // -------------------------------------------------------
                // Absorb the remainder of the error response, then report.
                // Routing the error through S_DONE keeps beat_done_o and
                // bus_error_o as clean registered-state decodes rather than
                // combinational functions of HREADY.
                S_ERROR: begin
                    if (hready_i)
                        state <= S_DONE;
                end

                // -------------------------------------------------------
                S_DONE: state <= S_IDLE;

                // -------------------------------------------------------
                default: state <= S_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Beat result. Exactly one of these pulses for exactly one cycle per beat,
    // which is what makes the channel FSM's xfer_cnt decrement and dma_ack
    // pulse safe to write as unconditional edge actions.
    // -----------------------------------------------------------------------
    assign beat_done_o  = (state == S_DONE) && !err_r;
    assign bus_error_o  = (state == S_DONE) &&  err_r;

endmodule

`default_nettype wire
