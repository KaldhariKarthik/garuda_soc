`timescale 1ns/1ps
`default_nettype none
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
// that hand-off would write the D-Port's HWDATA (or, since d_port_ahb_master
// holds its captured hwdata register, a stale store value) into the DMA's
// destination address. The DMA would report the beat complete, the store would
// report OKAY, and the destination buffer would silently hold the wrong word.
//
// Selecting HWDATA on dph_master_i is not an optimisation - it is what makes
// master hand-off legal at all. Documented as a spec erratum, not a design
// choice.
//
// -----------------------------------------------------------------------------
// HPROT (Sec. 7.6) and HTRANS rewriting (Sec. 8.5) are the two places where
// this mux is not a pure select:
//   - the DMA boundary has no HPROT port, so `AHB_HPROT_DMA is substituted;
//   - seq_break_i rewrites SEQ to NONSEQ for the first transfer after a grant
//     change. See ERRATUM AHB-3 in ahb_arbiter.v.
// =============================================================================

`include "ahb_defs.vh"

module ahb_master_mux (
    input  wire [1:0]  grant_i,        // address-phase owner
    input  wire [1:0]  dph_master_i,   // data-phase owner (ERRATUM AHB-1)
    input  wire        seq_break_i,    // force NONSEQ (ERRATUM AHB-3)

    // ---- M0 : CPU I-Port ----
    input  wire [31:0] i_haddr_i,
    input  wire [1:0]  i_htrans_i,
    input  wire        i_hwrite_i,
    input  wire [2:0]  i_hsize_i,
    input  wire [2:0]  i_hburst_i,
    input  wire [3:0]  i_hprot_i,
    input  wire [31:0] i_hwdata_i,

    // ---- M1 : CPU D-Port ----
    input  wire [31:0] d_haddr_i,
    input  wire [1:0]  d_htrans_i,
    input  wire        d_hwrite_i,
    input  wire [2:0]  d_hsize_i,
    input  wire [2:0]  d_hburst_i,
    input  wire [3:0]  d_hprot_i,
    input  wire [31:0] d_hwdata_i,

    // ---- M2 : DMA (no HPROT at its boundary, Sec. 7.6) ----
    input  wire [31:0] m_haddr_i,
    input  wire [1:0]  m_htrans_i,
    input  wire        m_hwrite_i,
    input  wire [2:0]  m_hsize_i,
    input  wire [2:0]  m_hburst_i,
    input  wire [31:0] m_hwdata_i,

    // ---- shared slave-side bus ----
    output reg  [31:0] haddr_o,
    output reg  [1:0]  htrans_o,
    output reg         hwrite_o,
    output reg  [2:0]  hsize_o,
    output reg  [2:0]  hburst_o,
    output reg  [3:0]  hprot_o,
    output reg  [31:0] hwdata_o
);

    // -----------------------------------------------------------------------
    // Address / control phase - selected by the CURRENT grant.
    // -----------------------------------------------------------------------
    reg [1:0] htrans_sel;

    always @(*) begin
        case (grant_i)
            `AHB_M_DPORT: begin
                haddr_o    = d_haddr_i;
                htrans_sel = d_htrans_i;
                hwrite_o   = d_hwrite_i;
                hsize_o    = d_hsize_i;
                hburst_o   = d_hburst_i;
                hprot_o    = d_hprot_i;
            end
            `AHB_M_DMA: begin
                haddr_o    = m_haddr_i;
                htrans_sel = m_htrans_i;
                hwrite_o   = m_hwrite_i;
                hsize_o    = m_hsize_i;
                hburst_o   = m_hburst_i;
                hprot_o    = `AHB_HPROT_DMA;   // Sec. 7.6 substitution
            end
            default: begin                      // `AHB_M_IPORT
                haddr_o    = i_haddr_i;
                htrans_sel = i_htrans_i;
                hwrite_o   = i_hwrite_i;
                hsize_o    = i_hsize_i;
                hburst_o   = i_hburst_i;
                hprot_o    = i_hprot_i;
            end
        endcase
    end

    // ERRATUM AHB-3: a SEQ whose burst was interrupted on the slave side by
    // another master's transfer is re-opened as NONSEQ. One-way rewrite -
    // NONSEQ is legal anywhere, so this can never make the bus less compliant.
    always @(*) begin
        if (seq_break_i && (htrans_sel == `AHB_TRANS_SEQ))
            htrans_o = `AHB_TRANS_NONSEQ;
        else
            htrans_o = htrans_sel;
    end

    // -----------------------------------------------------------------------
    // Write data phase - selected by the PREVIOUS grant. ERRATUM AHB-1.
    // -----------------------------------------------------------------------
    always @(*) begin
        case (dph_master_i)
            `AHB_M_DPORT: hwdata_o = d_hwdata_i;
            `AHB_M_DMA:   hwdata_o = m_hwdata_i;
            default:      hwdata_o = i_hwdata_i;
        endcase
    end

endmodule

`default_nettype wire
