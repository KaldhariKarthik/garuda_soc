// MUTANT A01 (bus plan B1 A9): AHB-1 reverted: HWDATA follows the address-phase grant
// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_master_mux.v - 3:1 address/control/write-data mux onto the slave bus
//
// Spec reference: GARUDA-AHB-SPEC-001 Rev 2.0, Sec. 3.1, Sec. 7.6, Sec. 8.5
//
// Purely combinational. Two different selects, and getting them confused is
// the single most dangerous mistake available in this block:
//
//   ADDRESS PHASE  haddr / htrans / hwrite / hsize / hburst / hprot
//                  <- selected by grant_i       (this cycle's owner)
//   DATA PHASE     hwdata
//                  <- selected by dph_master_i  (the PREVIOUS cycle's owner)
//
// -----------------------------------------------------------------------------
// *** ERRATUM AHB-1 - HWDATA IS A DATA-PHASE SIGNAL ***
// -----------------------------------------------------------------------------
// Sec. 3.1's sub-block table lists the Master Mux as steering
// "HADDR/HTRANS/HWRITE/HSIZE/HBURST/HPROT/HWDATA" from "the granted master".
// HWDATA does not belong in that list. AHB-Lite is pipelined: HWDATA is
// sampled by the slave one cycle AFTER the address phase it belongs to, i.e.
// during the data phase. If HWDATA followed the address-phase grant, then any
// cycle where the bus changes owner - which is every cycle the arbiter does
// its job - would present the NEW master's write data to a slave that is
// still committing the OLD master's write.
//
// Concretely, with the frozen GARUDA masters: dma_ahb_master drives
// HTRANS=IDLE in S_WDATA while its write data phase is in flight, precisely so
// that the bus can be handed to somebody else. Following Sec. 3.1 literally,
// that hand-off would write the D-Port's HWDATA (or, since dport_master
// holds its captured hwdata register, a stale store value) into the DMA's
// destination address. The DMA would report the beat complete, the store would
// report OKAY, and the destination buffer would silently hold the wrong word.
//
// Selecting HWDATA on dph_master_i is not an optimisation - it is what makes
// master hand-off legal at all. Documented as a spec erratum, not a design
// choice.
//
// -----------------------------------------------------------------------------
// HTRANS rewriting (Sec. 8.5) is the one place where this mux is not a pure
// select: seq_break_i rewrites SEQ to NONSEQ for the first transfer after a
// grant change (ERRATUM AHB-3 in ahb_arbiter.sv). (HBURST and HPROT left the
// bus with D-38, and the HPROT substitution with them.)
// =============================================================================

module ahb_master_mux
    import garuda_pkg::*;
    import ahb_pkg::*;
(
    input wire [AHB_MID_W-1:0] grant_i,  // address-phase owner
    // data-phase owner (ERRATUM AHB-1)
    input wire [AHB_MID_W-1:0] dph_master_i,
    input wire seq_break_i,  // force NONSEQ (ERRATUM AHB-3)
    // ---- M0 : CPU I-Port ----
    input wire [WORD_W-1:0] i_haddr_i,
    input wire [HTRANS_W-1:0] i_htrans_i,
    input wire i_hwrite_i,
    input wire [HSIZE_W-1:0] i_hsize_i,
    input wire [WORD_W-1:0] i_hwdata_i,
    // ---- M1 : CPU D-Port ----
    input wire [WORD_W-1:0] d_haddr_i,
    input wire [HTRANS_W-1:0] d_htrans_i,
    input wire d_hwrite_i,
    input wire [HSIZE_W-1:0] d_hsize_i,
    input wire [WORD_W-1:0] d_hwdata_i,
    // ---- M2 : Debug SBA (no HPROT at its boundary) ----
    input wire [WORD_W-1:0] s_haddr_i,
    input wire [HTRANS_W-1:0] s_htrans_i,
    input wire s_hwrite_i,
    input wire [HSIZE_W-1:0] s_hsize_i,
    input wire [WORD_W-1:0] s_hwdata_i,
    // ---- M3 : DMA (no HPROT at its boundary, Sec. 7.6) ----
    input wire [WORD_W-1:0] m_haddr_i,
    input wire [HTRANS_W-1:0] m_htrans_i,
    input wire m_hwrite_i,
    input wire [HSIZE_W-1:0] m_hsize_i,
    input wire [WORD_W-1:0] m_hwdata_i,
    // ---- shared slave-side bus ----
    output reg [WORD_W-1:0] haddr_o,
    output reg [HTRANS_W-1:0] htrans_o,
    output reg hwrite_o,
    output reg [HSIZE_W-1:0] hsize_o,
    output reg [WORD_W-1:0] hwdata_o
);
    timeunit 1ns;
    timeprecision 1ps;

    // -----------------------------------------------------------------------
    // Address / control phase - selected by the CURRENT grant.
    // -----------------------------------------------------------------------
    // F4: one process; htrans_sel is its own variable (HAL REVROP)
    always_comb begin : c_haddr
        logic [HTRANS_W-1:0] htrans_sel;
        case (grant_i)
            AHB_M_DPORT: begin
                haddr_o = d_haddr_i;
                htrans_sel = d_htrans_i;
                hwrite_o = d_hwrite_i;
                hsize_o = d_hsize_i;
            end
            AHB_M_SBA: begin
                haddr_o = s_haddr_i;
                htrans_sel = s_htrans_i;
                hwrite_o = s_hwrite_i;
                hsize_o = s_hsize_i;
            end
            AHB_M_DMA: begin
                haddr_o = m_haddr_i;
                htrans_sel = m_htrans_i;
                hwrite_o = m_hwrite_i;
                hsize_o = m_hsize_i;
            end
            default: begin  // AHB_M_IPORT
                haddr_o = i_haddr_i;
                htrans_sel = i_htrans_i;
                hwrite_o = i_hwrite_i;
                hsize_o = i_hsize_i;
            end
        endcase
        // ERRATUM AHB-3: a SEQ whose burst was interrupted on the slave side by
        // another master's transfer is re-opened as NONSEQ. One-way rewrite -
        // NONSEQ is legal anywhere, so this can never make the bus less
        // compliant.
        if (seq_break_i && (htrans_sel == AHB_TRANS_SEQ)) begin
            htrans_o = AHB_TRANS_NONSEQ;
        end else begin
            htrans_o = htrans_sel;
        end
    end


    // -----------------------------------------------------------------------
    // Write data phase - selected by the PREVIOUS grant. ERRATUM AHB-1.
    // -----------------------------------------------------------------------
    always_comb begin : c_hwdata
        case (grant_i)
            AHB_M_DPORT: hwdata_o = d_hwdata_i;
            AHB_M_SBA: hwdata_o = s_hwdata_i;
            AHB_M_DMA: hwdata_o = m_hwdata_i;
            default: hwdata_o = i_hwdata_i;
        endcase
    end

endmodule
