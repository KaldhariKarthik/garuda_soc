`timescale 1ns/1ps
//=============================================================================
// tb_clic_ctrl.v -- unit TB for rtl/core/clic_ctrl.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 14.3 (take condition, vectoring,
//        ack handshake) and Sec. 14.5 (MIE-independent WFI wake).
// Plan:  C23 ("CLIC interrupt take, ack handshake, vectoring SHV and
//        non-SHV") and C24 ("preemptive nesting honours mintthresh /
//        mintstatus; strict-> compare at threshold and active level").
//
// NOTE: tb/core/filelist_clic_ctrl.f already referenced tb_clic_ctrl.v with
// the comment "(add later; clic has no tb yet -- lint only for now)". This
// file is that testbench; the filelist's trailing '#' comment is not valid
// Verilog filelist syntax and is corrected alongside it.
//
// Checked:
//   * Take condition, all four terms ANDed (Sec. 14.3):
//       irq & MIE & (lvl > mintthresh) & (lvl > mintstatus.mil)
//     Each term is knocked down individually with the other three satisfied,
//     so a missing term cannot hide behind another.
//   * BOTH level comparisons are STRICTLY greater-than. The lvl == thresh
//     and lvl == mil vectors are the entire point of C24: a >= implementation
//     passes every "clearly higher" test and fails only these two.
//   * wake_cond_o is MIE-independent (Sec. 14.5) and ignores both level
//     comparisons -- it is bare irq. Checked with MIE=0 and with a level
//     below both threshold and active level, which is the "WFI wakes even if
//     MIE=0" case of test C26.
//   * Vectoring (Sec. 14.3): SHV -> mtvt_base + id*4; non-SHV -> mtvec_base.
//     Both bases are 64-byte aligned in CLIC mode, so the low 6 bits of
//     mtvec/mtvt (which carry mtvec.mode) must be masked off -- driven with
//     mode bits set on every vector check.
//   * The id*4 scaling is checked at id 0, 1, 0x7FF and 0xFFF; the top id
//     also proves the table offset does not overflow into the base.
//   * Ack handshake: clic_irq_ack_o is a pure function of take_i (the
//     one-cycle pulse is trap_ctrl's to shape), and clic_irq_id_ack_o always
//     mirrors the presented id.
//   * irq_id_o / irq_lvl_o are transparent pass-throughs.
//=============================================================================

module tb_clic_ctrl;

  reg         irq, shv, mie, take;
  reg  [11:0] irq_id;
  reg  [7:0]  irq_lvl, mintthresh, mil;
  reg  [31:0] mtvec, mtvt;
  wire        ack, take_cond, wake_cond;
  wire [11:0] id_ack, irq_id_o;
  wire [7:0]  irq_lvl_o;
  wire [31:0] vector_target;

  integer errors = 0;
  integer i;

  clic_ctrl #(.ID_W(12)) dut (
    .clic_irq_i(irq), .clic_irq_id_i(irq_id), .clic_irq_lvl_i(irq_lvl),
    .clic_irq_shv_i(shv),
    .clic_irq_ack_o(ack), .clic_irq_id_ack_o(id_ack),
    .mstatus_mie_i(mie), .mintthresh_i(mintthresh),
    .mintstatus_mil_i(mil), .mtvec_i(mtvec), .mtvt_i(mtvt),
    .take_cond_o(take_cond), .wake_cond_o(wake_cond),
    .irq_id_o(irq_id_o), .irq_lvl_o(irq_lvl_o),
    .vector_target_o(vector_target),
    .take_i(take));

  task c;
    input [255:0] n;
    input g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %b exp %b", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  task c32;
    input [255:0] n;
    input [31:0] g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %h exp %h", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  // A cleanly takeable interrupt: every term of Sec. 14.3 satisfied.
  task clr;
    begin
      irq = 1; irq_id = 12'h010; irq_lvl = 8'd5; shv = 0;
      mie = 1; mintthresh = 8'd2; mil = 8'd0;
      mtvec = 32'h8000_0003;   // base 0x8000_0000, mode 3 (CLIC)
      mtvt  = 32'h9000_0000;
      take = 0;
      #1;
    end
  endtask

  initial begin
    clr;
      c("baseline_take", take_cond, 1'b1);
      c("baseline_wake", wake_cond, 1'b1);

    // ---- each term of the take condition, knocked down alone ----------
    clr; irq = 0; #1;
      c("no_irq_no_take", take_cond, 1'b0);
      c("no_irq_no_wake", wake_cond, 1'b0);
    clr; mie = 0; #1;
      c("mie0_no_take", take_cond, 1'b0);
      c("mie0_still_wakes", wake_cond, 1'b1);        // Sec. 14.5
    clr; irq_lvl = 8'd1; mintthresh = 8'd2; #1;
      c("below_thresh_no_take", take_cond, 1'b0);
    clr; irq_lvl = 8'd3; mil = 8'd7; #1;
      c("below_active_no_take", take_cond, 1'b0);

    // ---- STRICT greater-than, both comparisons (C24) -------------------
    // at the threshold: must NOT take
    clr; irq_lvl = 8'd4; mintthresh = 8'd4; mil = 8'd0; #1;
      c("lvl_eq_thresh_no_take", take_cond, 1'b0);
    // one above the threshold: takes
    clr; irq_lvl = 8'd5; mintthresh = 8'd4; mil = 8'd0; #1;
      c("lvl_gt_thresh_takes", take_cond, 1'b1);
    // at the active level: must NOT preempt
    clr; irq_lvl = 8'd6; mintthresh = 8'd0; mil = 8'd6; #1;
      c("lvl_eq_active_no_take", take_cond, 1'b0);
    // one above the active level: preempts (nesting, Sec. 14.3)
    clr; irq_lvl = 8'd7; mintthresh = 8'd0; mil = 8'd6; #1;
      c("lvl_gt_active_preempts", take_cond, 1'b1);
    // boundaries of the 8-bit level field
    clr; irq_lvl = 8'd0; mintthresh = 8'd0; mil = 8'd0; #1;
      c("lvl0_thresh0_no_take", take_cond, 1'b0);    // 0 > 0 is false
    clr; irq_lvl = 8'd255; mintthresh = 8'd254; mil = 8'd254; #1;
      c("lvl255_takes", take_cond, 1'b1);
    clr; irq_lvl = 8'd255; mintthresh = 8'd255; mil = 8'd0; #1;
      c("lvl255_eq_thresh255_no_take", take_cond, 1'b0);

    // ---- wake is bare irq: level and MIE both irrelevant (Sec. 14.5) ---
    clr; mie = 0; irq_lvl = 8'd0; mintthresh = 8'd255; mil = 8'd255; #1;
      c("wake_ignores_everything", wake_cond, 1'b1);
      c("no_take_under_wake",      take_cond, 1'b0);

    // ---- vectoring: non-SHV -> mtvec base, 64-byte aligned -------------
    clr; shv = 0; mtvec = 32'h8000_0003; #1;         // mode bits set
      c32("nonshv_target_masks_mode", vector_target, 32'h8000_0000);
    clr; shv = 0; mtvec = 32'h8000_103F; #1;         // all 6 low bits set
      c32("nonshv_target_masks_low6", vector_target, 32'h8000_1000);

    // ---- vectoring: SHV -> mtvt_base + id*4 ----------------------------
    clr; shv = 1; mtvt = 32'h9000_0000; irq_id = 12'h000; #1;
      c32("shv_id0", vector_target, 32'h9000_0000);
    clr; shv = 1; mtvt = 32'h9000_0000; irq_id = 12'h001; #1;
      c32("shv_id1", vector_target, 32'h9000_0004);
    clr; shv = 1; mtvt = 32'h9000_0000; irq_id = 12'h010; #1;
      c32("shv_id16", vector_target, 32'h9000_0040);
    clr; shv = 1; mtvt = 32'h9000_0000; irq_id = 12'h7FF; #1;
      c32("shv_id7FF", vector_target, 32'h9000_1FFC);
    clr; shv = 1; mtvt = 32'h9000_0000; irq_id = 12'hFFF; #1;
      c32("shv_idFFF", vector_target, 32'h9000_3FFC);   // 4096-entry table
    // mtvt low 6 bits are masked too
    clr; shv = 1; mtvt = 32'h9000_003F; irq_id = 12'h002; #1;
      c32("shv_masks_low6", vector_target, 32'h9000_0008);
    // the target follows SHV, not the take condition
    clr; shv = 1; mie = 0; irq_id = 12'h004; mtvt = 32'h9000_0000; #1;
      c32("shv_target_independent_of_take", vector_target, 32'h9000_0010);
    // sweep the id field: every entry lands on its own 4-byte slot
    clr; shv = 1; mtvt = 32'hA000_0000;
    for (i = 0; i < 64; i = i + 1) begin
      irq_id = i[11:0]; #1;
      if (vector_target !== (32'hA000_0000 + (i * 4))) begin
        $display("FAIL shv_sweep id=%0d: got %h exp %h",
                 i, vector_target, 32'hA000_0000 + (i * 4));
        errors = errors + 1;
      end
    end

    // ---- ack handshake (Sec. 14.3) -------------------------------------
    clr; take = 0; #1;
      c("ack_low_when_not_taken", ack, 1'b0);
    clr; take = 1; irq_id = 12'h123; #1;
      c("ack_follows_take", ack, 1'b1);
      c32("ack_id", id_ack, 32'h123);
    // ack tracks take_i even when the take condition itself is false --
    // shaping the pulse is trap_ctrl's job, not this block's
    clr; take = 1; mie = 0; irq_id = 12'h0AB; #1;
      c("ack_is_pure_function_of_take", ack, 1'b1);
      c32("ack_id_mirrors_input", id_ack, 32'h0AB);

    // ---- transparent pass-throughs -------------------------------------
    clr; irq_id = 12'h456; irq_lvl = 8'd99; #1;
      c32("irq_id_passthrough",  irq_id_o,  32'h456);
      c32("irq_lvl_passthrough", irq_lvl_o, 32'd99);

    if (errors == 0) $display("CLIC_CTRL UNIT: ALL CHECKS PASSED");
    else             $display("CLIC_CTRL UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
