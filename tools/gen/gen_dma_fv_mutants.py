#!/usr/bin/env python3
"""gen_dma_fv_mutants.py -- cut the DMA's hand-made negative controls from the CURRENT RTL: the formal
mutants (tb/dma/formal/mutants/, suites fv_dma*) and the two simulation negative controls of the
register and environment suites (tb/dma/mut/*_mut_size_reset.v, *_mut_lane0.v). The 24 planted defects
of `make dma_mut` have their own generator (tools/gen/gen_dma_mutants.py). Rerun after any change to
rtl/dma; each edit must match exactly once and change the text, or the script stops (2026-11-01: these
copies were hand-made and had drifted when the DMA rulings changed the RTL).
A mutant is one edit (old, new) or several: tuples of the same length, applied in order. The
*_revert mutants undo one DMA ruling fix each (2026-11-02): they replaced the *_find tasks of the
open defects, so every fixed defect keeps a control that its detector must fail."""
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FV = "tb/dma/formal/mutants/{}"
SIM = "tb/dma/mut/{}"
EN_BLOCK_OLD = """            if (hw_clr_en || (en_q && rem_q == 16'd0 && !wr_cr_i))
                en_q <= 1'b0;
            else if (wr_cr_i) begin
                en_q <= wdata_i[0];
                if (wdata_i[0] && !en_q) rem_q <= cnt_q;       // arm
            end"""
EN_BLOCK_NEW = """            if (wr_cr_i) begin                              // MUTANT: D-2 reverted (a software
                en_q <= wdata_i[0];                         // write beats the hardware clear)
                if (wdata_i[0] && !en_q) rem_q <= cnt_q;       // arm
            end else if (hw_clr_en || (en_q && rem_q == 16'd0))
                en_q <= 1'b0;"""
MUTANTS = [
    (SIM.format("dma_chan_mut_size_reset.v"), "dma_chan.v", "SIZE resets to byte (regs suite negative control)",
     "            size_q <= 2'd2; iec_q <= 1'b0; iee_q <= 1'b0;",
     "            size_q <= 2'd0; iec_q <= 1'b0; iee_q <= 1'b0;   // MUTANT: SIZE resets to byte"),
    (SIM.format("dma_engine_mut_lane0.v"), "dma_engine.v", "byte beats always from lane 0 (env beat-checker negative control)",
     "    wire [7:0]  rd_byte = hrdata_i >> (8 * sar[1:0]);",
     "    wire [7:0]  rd_byte = hrdata_i[7:0];                 // MUTANT: byte always from lane 0"),
    (FV.format("dma_apb_slave_mut_aud13.v"), "dma_apb_slave.v", "AUD-13 reverted",
     "    assign pslverr_o = psel_i & penable_i & ~hit;",
     "    assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & (gstat | (chan_rgn & reg_ == 3'd4))));   // MUTANT: AUD-13 reverted"),
    (FV.format("dma_arbiter_mut_prio_inv.v"), "dma_arbiter.v", "priority inverted",
     "            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] > best)) begin",
     "            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] < best)) begin"),
    (FV.format("dma_arbiter_mut_tie_high.v"), "dma_arbiter.v", "ties go to the higher channel",
     "            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] > best)) begin",
     "            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] >= best)) begin"),
    (FV.format("dma_chan_mut_d2.v"), "dma_chan.v", "D-2 reverted: a software write beats the hardware EN clear",
     EN_BLOCK_OLD, EN_BLOCK_NEW),
    (FV.format("dma_chan_mut_dma8.v"), "dma_chan.v", "DMA-8 reverted: a failed beat consumes the request",
     "            else if (beat_done_i) taken_q <= 1'b1;",
     "            else if (beat_done_i || beat_err_i) taken_q <= 1'b1;   // MUTANT: DMA-8 reverted"),
    (FV.format("dma_chan_mut_iclr_wins.v"), "dma_chan.v", "ICLR beats a same-cycle COMPLETE set",
     "                if (wdata_i[0] && !(done && last)) comp_q <= 1'b0;",
     "                if (wdata_i[0]) comp_q <= 1'b0;             // MUTANT: clear beats set"),
    (FV.format("dma_engine_mut_eng1.v"), "dma_engine.v", "ENG-1 guard removed",
     "                    if (grant_valid_i && beat_done_o == 6'd0 && beat_err_o == 6'd0) begin",
     "                    if (grant_valid_i) begin                 // MUTANT: ENG-1 guard removed"),
    # ---- the DMA ruling fixes, each reverted on its own (fv_dma mut_dma*_revert)
    (FV.format("dma_chan_mut_dma9_revert.v"), "dma_chan.v",
     "DMA-9 fix reverted: a beat taken before a re-arm counts in the new transfer",
     "    wire stale    = stale_q || (arm_req && (beat_done_i || beat_err_i));",
     "    wire stale    = 1'b0;   // MUTANT: DMA-9 reverted (a beat taken before the re-arm counts in it)"),
    (FV.format("dma_engine_mut_dma10_revert.v"), "dma_engine.v",
     "DMA-10 fix reverted: no alignment check, an unaligned SAR or DAR goes on the bus",
     """    wire sar_bad = (sar[31:28] == 4'h0) || (sar[31:28] == 4'h1) ||
                   (size == 2'd1 && sar[0]) || (size == 2'd2 && sar[1:0] != 2'b00);
    wire dar_bad = (dar[31:28] == 4'h0) || (dar[31:28] == 4'h1) ||
                   (size == 2'd1 && dar[0]) || (size == 2'd2 && dar[1:0] != 2'b00);""",
     """    wire sar_bad = (sar[31:28] == 4'h0) || (sar[31:28] == 4'h1);   // MUTANT: DMA-10 reverted
    wire dar_bad = (dar[31:28] == 4'h0) || (dar[31:28] == 4'h1);   // (no alignment check)"""),
    (FV.format("dma_engine_mut_dma12_revert.v"), "dma_engine.v",
     "DMA-12 fix reverted: a bad DAR is refused only after the source read",
     ("""                    end else if (dar_bad) begin
                        beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd2;
                        st <= E_IDLE;
                    end else begin
                        haddr_o  <= sar;""",
      """                E_WA: begin                                   // DAR checked in E_RA (DMA-12)
                    haddr_o  <= dar;
                    htrans_o <= 2'b10;
                    hwrite_o <= 1'b1;
                    hsize_o  <= {1'b0, size};
                    st       <= E_WD;
                end"""),
     ("""                    end else begin                           // MUTANT: DMA-12 reverted (no DAR check here)
                        haddr_o  <= sar;""",
      """                E_WA: begin                                   // MUTANT: DMA-12 reverted (DAR checked after the read)
                    if (dar_bad) begin
                        beat_err_o[ch] <= 1'b1; err_phase_o <= 3'd2;
                        st <= E_IDLE;
                    end else begin
                        haddr_o  <= dar;
                        htrans_o <= 2'b10;
                        hwrite_o <= 1'b1;
                        hsize_o  <= {1'b0, size};
                        st       <= E_WD;
                    end
                end""")),
    (FV.format("dma_engine_mut_dma14_revert.v"), "dma_engine.v",
     "DMA-14 fix reverted: the write takes the channel's live SIZE, not the beat's",
     """                    hsize_o  <= {1'b0, size};
                    st       <= E_WD;""",
     """                    hsize_o  <= {1'b0, size_i[2*ch +: 2]};   // MUTANT: DMA-14 reverted (live SIZE)
                    st       <= E_WD;"""),
    (FV.format("dma_engine_mut_dma15_revert.v"), "dma_engine.v",
     "DMA-15 fix reverted: an M2M beat pulses dma_ack too",
     "                            if (!m2m) begin                    // DMA-15: no peripheral asked in M2M",
     "                            if (1'b1) begin                    // MUTANT: DMA-15 reverted (M2M acknowledges)"),
    (FV.format("dma_engine_mut_dma14_addr_revert.v"), "dma_engine.v",
     "DMA-14 address latch reverted: the read takes the channel's live SAR",
     "                        haddr_o  <= sar;",
     "                        haddr_o  <= sar_i[32*ch +: 32];   // MUTANT: DMA-14 address reverted (live SAR)"),
    (FV.format("dma_chan_mut_dma14_step_revert.v"), "dma_chan.v",
     "DMA-14 step reverted: SAR/DAR step by today's SIZE field, not the beat's size",
     "    wire [31:0] step = (beat_size_i == 2'd0) ? 32'd1 : (beat_size_i == 2'd1) ? 32'd2 : 32'd4;",
     "    wire [31:0] step = (size_q == 2'd0) ? 32'd1 : (size_q == 2'd1) ? 32'd2 : 32'd4;   // MUTANT: DMA-14 step reverted"),
]


def main():
    for out, src, why, a, b in MUTANTS:
        text = open(os.path.join(ROOT, "rtl/dma", src)).read()
        edits = list(zip(a, b)) if isinstance(a, tuple) else [(a, b)]
        if isinstance(a, tuple) and (not isinstance(b, tuple) or len(a) != len(b)):
            sys.exit(f"{out}: a multi-edit mutant needs old and new tuples of the same length")
        for old, new in edits:
            if text.count(old) != 1:
                sys.exit(f"{out}: edit does not match exactly once in rtl/dma/{src}: {old.strip()[:70]!r}")
            if old == new:
                sys.exit(f"{out}: the edit changes nothing")
            text = text.replace(old, new)
        open(os.path.join(ROOT, out), "w").write(f"// MUTANT (GENERATED, gen_dma_fv_mutants.py): {why}\n" + text)
        print("wrote", out)


if __name__ == "__main__":
    main()
