`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 10 : properties for the CLIC
// clic_sva.sv
//
// Spec: GARUDA-CLIC-SPEC-001 section 10, as amended by the interrupt map of
// garuda_system.yaml (BUGS.md INT-2, INT-3). Plan: tb/clic/GARUDA_CLIC_vplan.csv;
// each property below carries the feature it belongs to.
//
// Bound to clic_top, so the properties run in the block bench, in the UVM
// environment and in every chip simulation. Not compiled for synthesis or lint.
//
// The selection logic is combinational, so "the outputs follow the inputs with
// no latency" is checked as an equality between values sampled on the same
// hclk edge: any register stage would break it one cycle after a change.
// =============================================================================
`ifndef SYNTHESIS
module clic_sva #(
    parameter integer N       = 32,
    parameter [31:0]  IE_MASK = 32'h007F_FF7E
)(
    input wire           hclk_i,
    input wire           pclk_i,
    input wire           preset_n_i,
    input wire           psel_i,
    input wire           penable_i,
    input wire           pwrite_i,
    input wire [11:0]    paddr_i,
    input wire [31:0]    prdata_o,
    input wire           pready_o,
    input wire           pslverr_o,
    input wire [N-1:0]   irq_src_i,
    input wire [N-1:0]   ie,
    input wire [N*8-1:0] level,
    input wire           clic_irq_valid_o,
    input wire [4:0]     clic_irq_id_o,
    input wire [7:0]     clic_irq_level_o
);
    wire [N-1:0] cand = irq_src_i & ie;
    wire [7:0]   lvl_of_winner = level[8*clic_irq_id_o +: 8];

    // ---- F03, F17, F18: IDs with no source can never be enabled or win ------
    a_reserved_ids: assert property (@(posedge hclk_i) (ie & ~IE_MASK[N-1:0]) == {N{1'b0}})
        else $error("[SVA-FAIL] a_reserved_ids: an unassigned enable bit is set (ie=%h)", ie);
    a_id0_never_wins: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        clic_irq_valid_o |-> (clic_irq_id_o != 5'd0))
        else $error("[SVA-FAIL] a_id0_never_wins");
    a_reserved_never_win: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        clic_irq_valid_o |-> IE_MASK[clic_irq_id_o])
        else $error("[SVA-FAIL] a_reserved_never_win: id=%0d", clic_irq_id_o);

    // ---- F12, F19: valid is the OR of enabled pending sources, same cycle ---
    a_valid_correct: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        clic_irq_valid_o == (|cand))
        else $error("[SVA-FAIL] a_valid_correct: valid=%b cand=%h", clic_irq_valid_o, cand);

    // ---- F13: the winner is enabled, pending, and presents its own level -----
    a_winner_legit: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        clic_irq_valid_o |-> cand[clic_irq_id_o])
        else $error("[SVA-FAIL] a_winner_legit: id=%0d cand=%h", clic_irq_id_o, cand);
    a_winner_own_level: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        clic_irq_valid_o |-> (clic_irq_level_o == lvl_of_winner))
        else $error("[SVA-FAIL] a_winner_own_level: id=%0d level=%0d cfg=%0d",
                    clic_irq_id_o, clic_irq_level_o, lvl_of_winner);

    // ---- F13, F14: no candidate has a higher level; none below has the same --
    genvar n;
    generate for (n = 0; n < N; n = n + 1) begin : g_n
        wire [7:0] lvl_n = level[8*n +: 8];
        a_winner_max_level: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
            (clic_irq_valid_o && cand[n]) |-> (lvl_n <= clic_irq_level_o))
            else $error("[SVA-FAIL] a_winner_max_level: id %0d (level %0d) beats winner %0d (level %0d)",
                        n, lvl_n, clic_irq_id_o, clic_irq_level_o);
        a_tiebreak_lowest_id: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
            (clic_irq_valid_o && cand[n] && (lvl_n == clic_irq_level_o)) |-> (n >= clic_irq_id_o))
            else $error("[SVA-FAIL] a_tiebreak_lowest_id: id %0d ties with winner %0d and is lower",
                        n, clic_irq_id_o);
    end endgenerate

    // ---- F16: nothing pending -> the sentinel -----------------------------------
    a_idle_outputs: assert property (@(posedge hclk_i) disable iff (!preset_n_i)
        !clic_irq_valid_o |-> (clic_irq_id_o == 5'd0 && clic_irq_level_o == 8'd0))
        else $error("[SVA-FAIL] a_idle_outputs: id=%0d level=%0d", clic_irq_id_o, clic_irq_level_o);

    // ---- F04, F11: CLICIP is the source lines, whatever was written to it ----
    a_pending_comb: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && !pwrite_i && paddr_i == 12'h008) |-> (prdata_o == irq_src_i))
        else $error("[SVA-FAIL] a_pending_comb: CLICIP=%h src=%h", prdata_o, irq_src_i);

    // ---- F08: PSLVERR for exactly the unmapped offsets; an errored write changes nothing
    wire hit_ref = (paddr_i == 12'h000) || (paddr_i == 12'h004) || (paddr_i == 12'h008) ||
                   (paddr_i >= 12'h100 && paddr_i <= 12'h17C && paddr_i[1:0] == 2'b00);
    a_pslverr_map: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        pslverr_o == (psel_i && penable_i && !hit_ref))
        else $error("[SVA-FAIL] a_pslverr_map: paddr=%h pslverr=%b", paddr_i, pslverr_o);
    a_err_no_change: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (psel_i && penable_i && pwrite_i && pslverr_o) |=> ($stable(ie) && $stable(level)))
        else $error("[SVA-FAIL] a_err_no_change");

    // ---- F09: zero wait ------------------------------------------------------------
    // (not evaluated until the reset has been seen released: at time 0 a wire's
    //  sampled value is still X, before any continuous assignment has run)
    a_pready: assert property (@(posedge pclk_i) disable iff (preset_n_i !== 1'b1) pready_o)
        else $error("[SVA-FAIL] a_pready");

    // ---- F10: reset leaves everything disabled -------------------------------------
    a_reset_disabled: assert property (@(posedge hclk_i)
        !preset_n_i |-> (ie == {N{1'b0}} && level == {(N*8){1'b0}} && !clic_irq_valid_o))
        else $error("[SVA-FAIL] a_reset_disabled");

    // ---- each implication above must be seen to trigger (sign-off criterion 4) ----
    c_valid:        cover property (@(posedge hclk_i) preset_n_i && clic_irq_valid_o);
    c_idle:         cover property (@(posedge hclk_i) preset_n_i && !clic_irq_valid_o);
    c_tie:          cover property (@(posedge hclk_i) preset_n_i && clic_irq_valid_o &&
                                    (|(cand & ~(32'd1 << clic_irq_id_o))));
    c_clicip_read:  cover property (@(posedge pclk_i) preset_n_i && psel_i && !pwrite_i && paddr_i == 12'h008 && |irq_src_i);
    c_err_write:    cover property (@(posedge pclk_i) preset_n_i && psel_i && penable_i && pwrite_i && pslverr_o);
    c_reset:        cover property (@(posedge hclk_i) !preset_n_i ##1 preset_n_i);
endmodule

bind clic_top clic_sva #(.N(N), .IE_MASK(IE_MASK)) u_clic_sva (
    .hclk_i(hclk_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .prdata_o(prdata_o), .pready_o(pready_o), .pslverr_o(pslverr_o),
    .irq_src_i(irq_src_i), .ie(ie), .level(level),
    .clic_irq_valid_o(clic_irq_valid_o), .clic_irq_id_o(clic_irq_id_o),
    .clic_irq_level_o(clic_irq_level_o));
`endif
