// =============================================================================
// GARUDA SoC - Block I: Processor Core - ID Stage, Sub-block 2/5
// Immediate Generator  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 7.3
//
// A single combinational immediate generator selects the I/S/B/U/J form
// from opcode and sign-extends to 32 bits. B- and J-immediates are
// pre-shifted (LSB zero); U-immediate is {instr[31:12], 12'b000000000000}.
// The CSR-immediate case (CSRRWI/SI/CI) is a 5-bit zero-extended field
// from rs1, per Sec. 13.3, not a sign-extended form.
// =============================================================================
// Shared ALU-op / immediate-select encodings (single source of truth).
// Requires `-incdir rtl/common` on the compile line (see rtl/core/filelist.f).

module imm_gen
    import garuda_pkg::*;
(
    input wire [WORD_W-1:0] instr_i,
    input wire [IMM_SEL_W-1:0] imm_sel_i,
    output reg [WORD_W-1:0] imm_o,
    // B/J target-adder feeds (also needed standalone by Branch-Predict)
    output wire [WORD_W-1:0] imm_b_o,
    output wire [WORD_W-1:0] imm_j_o
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [WORD_W-1:0] imm_i_f;
    wire [WORD_W-1:0] imm_s_f;
    wire [WORD_W-1:0] imm_b_f;
    wire [WORD_W-1:0] imm_u_f;
    wire [WORD_W-1:0] imm_j_f;
    wire [WORD_W-1:0] imm_csr_f;

    assign imm_i_f   = {{20{instr_i[31]}}, instr_i[31:20]};
    assign imm_s_f   = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
    assign imm_b_f   = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                         instr_i[30:25], instr_i[11:8], 1'b0};
    assign imm_u_f   = {instr_i[31:12], 12'b000000000000};
    assign imm_j_f   = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                         instr_i[20], instr_i[30:21], 1'b0};
    // zero-extended rs1 field (Sec. 13.3)
    assign imm_csr_f = {27'b000000000000000000000000000, instr_i[19:15]};

    assign imm_b_o = imm_b_f;
    assign imm_j_o = imm_j_f;

    always_comb begin : c_imm
        case (imm_sel_i)
            IMM_I: imm_o = imm_i_f;
            IMM_S: imm_o = imm_s_f;
            IMM_B: imm_o = imm_b_f;
            IMM_U: imm_o = imm_u_f;
            IMM_J: imm_o = imm_j_f;
            IMM_CSR: imm_o = imm_csr_f;
            default: imm_o = 32'b00000000000000000000000000000000;
        endcase
    end

endmodule
