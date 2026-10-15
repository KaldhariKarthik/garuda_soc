`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - core : properties of decode_control against the ISA's own tables
// decode_control_sva.sv
// RV32I + the multiplies of M (CORE 7.2: division traps) + Zicsr + Zifencei, the four SYSTEM instructions GARUDA implements
// (ECALL, EBREAK, MRET, WFI) and Custom-0 (the DSU, whose own decoder rules on its
// encodings). Everything else is illegal and must have no side effect. Encodings are
// written as the ISA's literals. Bound to decode_control; proved by run_blocks.sh decode.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module decode_control_sva (
    input wire [31:0] instr_i,
    input wire reg_write_o, mem_read_o, mem_write_o, mem_to_reg_o, branch_o, jal_o, jalr_o,
    input wire mul_en_o, dsu_en_o, csr_en_o, is_system_o, illegal_instr_o, fencei_o,
    input wire [4:0] rd_o, rs1_o, rs2_o, input wire [2:0] funct3_o
);
    wire [6:0] op = instr_i[6:0]; wire [2:0] f3 = instr_i[14:12]; wire [6:0] f7 = instr_i[31:25];
    wire lui = op == 7'b0110111, auipc = op == 7'b0010111, jal = op == 7'b1101111;
    wire jalr   = op == 7'b1100111 && f3 == 3'b000;
    wire branch = op == 7'b1100011 && f3 != 3'b010 && f3 != 3'b011;
    wire load   = op == 7'b0000011 && (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010 || f3 == 3'b100 || f3 == 3'b101);
    wire store  = op == 7'b0100011 && (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010);
    wire opimm  = op == 7'b0010011 && (f3 == 3'b001 ? f7 == 7'b0000000 :
                                       f3 == 3'b101 ? (f7 == 7'b0000000 || f7 == 7'b0100000) : 1'b1);
    // CORE [7.2]: of the M extension only MUL, MULH, MULHSU and MULHU execute; DIV, DIVU,
    // REM and REMU are illegal so the firmware's Newton-Raphson handler runs (mcause 2)
    wire opreg  = op == 7'b0110011 && (f7 == 7'b0000000 || (f7 == 7'b0000001 && !f3[2]) ||
                                       (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101)));
    wire mext   = op == 7'b0110011 && f7 == 7'b0000001 && !f3[2];
    wire fence  = op == 7'b0001111 && f3 == 3'b000;
    wire fencei = op == 7'b0001111 && f3 == 3'b001;
    wire sys    = instr_i == 32'h0000_0073 || instr_i == 32'h0010_0073 || instr_i == 32'h3020_0073 || instr_i == 32'h1050_0073;
    wire csr    = op == 7'b1110011 && f3 != 3'b000 && f3 != 3'b100;
    wire cust0  = op == 7'b0001011;
    wire legal  = instr_i[1:0] == 2'b11 && (lui || auipc || jal || jalr || branch || load || store || opimm || opreg ||
                                            fence || fencei || sys || csr || cust0);
    always @(*) if (!$isunknown(instr_i)) begin
        a_dec_legal: assert #0 (illegal_instr_o == !legal)
            else $error("[SVA-FAIL] a_dec_legal: %h decoded as %s, the ISA says %s", instr_i, illegal_instr_o ? "illegal" : "legal", legal ? "legal" : "illegal");
        a_dec_fields: assert #0 (rd_o == instr_i[11:7] && rs1_o == instr_i[19:15] && rs2_o == instr_i[24:20] && funct3_o == f3)
            else $error("[SVA-FAIL] a_dec_fields: register fields not taken from the ISA positions");
        a_dec_illegal_quiet: assert #0 (!illegal_instr_o || !(reg_write_o || mem_read_o || mem_write_o || branch_o ||
                                         jal_o || jalr_o || mul_en_o || dsu_en_o || csr_en_o || fencei_o))
            else $error("[SVA-FAIL] a_dec_illegal_quiet: %h is illegal but enables something", instr_i);
        a_dec_load:  assert #0 (!(legal && load)  || (mem_read_o && mem_to_reg_o && reg_write_o && !mem_write_o))
            else $error("[SVA-FAIL] a_dec_load: %h is a load", instr_i);
        a_dec_store: assert #0 (!(legal && store) || (mem_write_o && !mem_read_o && !reg_write_o))
            else $error("[SVA-FAIL] a_dec_store: %h is a store", instr_i);
        a_dec_branch: assert #0 (!(legal && branch) || (branch_o && !reg_write_o && !mem_read_o && !mem_write_o))
            else $error("[SVA-FAIL] a_dec_branch: %h is a branch", instr_i);
        a_dec_jumps: assert #0 ((!(legal && jal) || (jal_o && reg_write_o)) && (!(legal && jalr) || (jalr_o && reg_write_o)))
            else $error("[SVA-FAIL] a_dec_jumps: %h is a jump and links", instr_i);
        a_dec_mul: assert #0 (!legal || (mul_en_o == mext))
            else $error("[SVA-FAIL] a_dec_mul: %h multiply enable wrong", instr_i);
        a_dec_dsu: assert #0 (!legal || (dsu_en_o == cust0))
            else $error("[SVA-FAIL] a_dec_dsu: %h DSU enable wrong", instr_i);
        a_dec_csr: assert #0 (!legal || (csr_en_o == csr))
            else $error("[SVA-FAIL] a_dec_csr: %h CSR enable wrong", instr_i);
        a_dec_fencei: assert #0 (!legal || (fencei_o == fencei))
            else $error("[SVA-FAIL] a_dec_fencei: %h FENCE.I flag wrong", instr_i);
        a_dec_nowrite_store_branch: assert #0 (!(legal && (store || branch || fence || fencei || sys)) || !reg_write_o)
            else $error("[SVA-FAIL] a_dec_nowrite: %h writes a register it must not", instr_i);
    end
endmodule
bind decode_control decode_control_sva u_decode_sva (.*);
`endif
`endif
