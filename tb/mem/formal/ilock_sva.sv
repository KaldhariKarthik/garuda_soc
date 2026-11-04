// =============================================================================
// ilock_sva.sv -- MEMCTL.ILOCK, the ISRAM write lock, at its source (Track A plan
// 6A.6 step M1; vPlan F10). GARUDA-MEM-SPEC-001 [N-7.8], CLKRST MEMCTL row: RW1S,
// sticky, cleared only by reset. The register lives in Karthik's reset_ctrl_apb.v
// (track B); this checker is Track A's and is bound from here, so his file is not
// edited. Written from the spec text: the expected write decode (address 0x020,
// bit 0, an APB write access = PSEL & PENABLE & PWRITE) is computed here.
// What resets the lock (preset_n, i.e. which reset causes) is contract item 10
// of the Track A memories plan, still open with Karthik.
// =============================================================================
`timescale 1ns/1ps
module ilock_sva (
    input wire        pclk_i, preset_n_i,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire [31:0] pwdata_i, prdata_o,
    input wire        ilock_o
);
    wire set_wr  = psel_i && penable_i && pwrite_i && paddr_i == 12'h020 && pwdata_i[0];
    wire memctl_rd = psel_i && !pwrite_i && paddr_i == 12'h020;

    // F10: once set it stays set until reset; a write of 0 cannot clear it
    a_ilock_sticky: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !($past(ilock_o) && $past(preset_n_i)) || ilock_o )
        else $error("[SVA-FAIL] a_ilock_sticky: ILOCK cleared without a reset");
    // F10: it is set only by a write of 1 to MEMCTL
    a_ilock_set_by_write: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !(!$past(ilock_o) && ilock_o && $past(preset_n_i)) || $past(set_wr) )
        else $error("[SVA-FAIL] a_ilock_set_by_write: ILOCK set without a write of 1 to MEMCTL");
    // F10: a write of 1 to MEMCTL sets it
    a_ilock_w1s: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !($past(set_wr) && $past(preset_n_i)) || ilock_o )
        else $error("[SVA-FAIL] a_ilock_w1s: a write of 1 to MEMCTL did not set ILOCK");
    // reset clears it
    a_ilock_reset: assert property (@(posedge pclk_i)
        preset_n_i || !ilock_o )
        else $error("[SVA-FAIL] a_ilock_reset: ILOCK set while in reset");
    // software reads it back in bit 0, the other bits 0
    a_ilock_readback: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        !memctl_rd || prdata_o == {31'd0, ilock_o} )
        else $error("[SVA-FAIL] a_ilock_readback: MEMCTL does not read back ILOCK");

`ifdef FORMAL
    // FI-1: the proof starts in reset (cycle 0); afterwards preset_n is free, so a
    // reset may come at any time (c_cleared_by_reset shows it does)
    reg init = 1'b1;
    always @(posedge pclk_i) init <= 1'b0;
    always @(*) if (init) assume (!preset_n_i);
`endif
    c_ilock_set:        cover property (@(posedge pclk_i) !$past(ilock_o) && ilock_o);
    c_write0_while_set: cover property (@(posedge pclk_i) ilock_o && psel_i && penable_i && pwrite_i && paddr_i == 12'h020 && !pwdata_i[0]);
    c_cleared_by_reset: cover property (@(posedge pclk_i) $past(ilock_o) && !preset_n_i);
endmodule

bind reset_ctrl_apb ilock_sva u_ilock_sva (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i), .psel_i(psel_i), .penable_i(penable_i),
    .pwrite_i(pwrite_i), .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
    .ilock_o(ilock_o));
