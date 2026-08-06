`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core - ID Stage, Sub-block 4/5
// Branch Predict  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 12.1 - Sec. 12.2
//
// Static prediction: backward branches (negative B-immediate) are predicted
// taken; forward branches predicted not-taken. Prediction is made in ID,
// where the B-immediate sign is available; a predicted-taken branch
// redirects fetch from ID with a one-bubble penalty.
//
// JAL: target = PC + sext(J-imm), resolved unconditionally in ID (Sec. 12.2),
// also a 1-bubble redirect; link (PC+4) is generated downstream in EX.
//
// JALR is intentionally NOT handled here - it needs a forwarded rs1 and is
// resolved in EX (Sec. 12.2), with its own 2-bubble redirect from EX.
// =============================================================================

module branch_predict (
    input  wire [31:0] pc_i,
    input  wire [31:0] imm_b_i,
    input  wire [31:0] imm_j_i,
    input  wire         branch_i,   // ctrl.branch from Decode/Control
    input  wire         jal_i,      // ctrl.jal from Decode/Control
    input  wire         fencei_i,   // FENCE.I: redirect to pc+4 to flush prefetch

    output wire         predict_taken_o,
    output wire         id_redirect_valid_o,
    output wire [31:0] id_redirect_target_o
);

    wire [31:0] branch_target;
    wire [31:0] jal_target;

    assign branch_target = pc_i + imm_b_i;
    assign jal_target    = pc_i + imm_j_i;

    // Backward branch (negative B-immediate) predicted taken;
    // forward branch predicted not-taken.
    assign predict_taken_o = branch_i & imm_b_i[31];

    // ERRATUM C-3: FENCE.I redirects to the NEXT instruction. The redirect is
    // what does the work - garuda_prefetch_buffer drops its entire contents on
    // any redirect, so everything fetched after the FENCE.I is discarded and
    // refetched. Architecturally a no-op; structurally a prefetch flush.
    // Ranked first because a FENCE.I is neither a branch nor a JAL, so the
    // other two targets are meaningless for it.
    wire [31:0] fencei_target = pc_i + 32'd4;

    assign id_redirect_valid_o  = fencei_i | jal_i | predict_taken_o;
    assign id_redirect_target_o = fencei_i ? fencei_target :
                                  jal_i    ? jal_target    : branch_target;

endmodule

`default_nettype wire
