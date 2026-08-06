`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core - ID Stage, Sub-block 1/5
// Decode / Control  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 7.1 - Sec. 7.2
//
// Extracts opcode/rd/funct3/rs1/rs2/funct7 and generates the full control
// bundle (reg_write, mem_read, mem_write, mem_to_reg, alu_src, alu_op,
// branch, jal, jalr, mul_en, dsu_en, csr_en, csr_op, is_system) plus the
// immediate-select tag consumed by the Immediate-Gen block.
//
// DIV/DIVU/REM/REMU are decoded but not executed (Sec. 7.2) - they raise
// illegal_instr so the software Newton-Raphson handler runs (mcause=2).
// =============================================================================
// Shared ALU-op / immediate-select encodings (single source of truth).
// Requires `-incdir rtl/common` on the compile line (see rtl/core/filelist.f).
`include "garuda_defs.vh"

module decode_control (
    input  wire [31:0] instr_i,

    output wire [6:0]  opcode_o,
    output wire [4:0]  rd_o,
    output wire [2:0]  funct3_o,
    output wire [4:0]  rs1_o,
    output wire [4:0]  rs2_o,

    output reg          reg_write_o,
    output reg          mem_read_o,
    output reg          mem_write_o,
    output reg          mem_to_reg_o,
    output reg          alu_src_o,
    output reg          alu_a_pc_o,
    output reg  [3:0]  alu_op_o,
    output reg          branch_o,
    output reg          jal_o,
    output reg          jalr_o,
    output reg          mul_en_o,
    output reg          dsu_en_o,
    output reg          csr_en_o,
    output reg  [2:0]  csr_op_o,
    output reg          is_system_o,
    output reg          illegal_instr_o,
    output reg          fencei_o,          // FENCE.I: flush prefetch, refetch
    output reg  [2:0]  imm_sel_o
);

    wire [6:0] opcode;
    wire [4:0] rd_f, rs1_f, rs2_f;
    wire [2:0] funct3;
    wire [6:0] funct7;

    assign opcode = instr_i[6:0];
    assign rd_f   = instr_i[11:7];
    assign funct3 = instr_i[14:12];
    assign rs1_f  = instr_i[19:15];
    assign rs2_f  = instr_i[24:20];
    assign funct7 = instr_i[31:25];

    assign opcode_o = opcode;
    assign rd_o     = rd_f;
    assign funct3_o = funct3;
    assign rs1_o    = rs1_f;
    assign rs2_o    = rs2_f;

    // Opcode map (Sec. 7.2)
    localparam [6:0] OP_LUI     = 7'b0110111;
    localparam [6:0] OP_AUIPC   = 7'b0010111;
    localparam [6:0] OP_JAL     = 7'b1101111;
    localparam [6:0] OP_JALR    = 7'b1100111;
    localparam [6:0] OP_BRANCH  = 7'b1100011;
    localparam [6:0] OP_LOAD    = 7'b0000011;
    localparam [6:0] OP_STORE   = 7'b0100011;
    localparam [6:0] OP_IMM     = 7'b0010011;
    localparam [6:0] OP_REG     = 7'b0110011;
    localparam [6:0] OP_SYSTEM  = 7'b1110011;
    localparam [6:0] OP_CUSTOM0 = 7'b0001011;
    localparam [6:0] OP_MISC_MEM= 7'b0001111;   // FENCE / FENCE.I (ERRATUM C-2)

    // M-extension sub-decode (OP major opcode, funct7 = 0000001)
    wire is_muldiv;
    wire is_mul_family;
    wire is_div_family;

    assign is_muldiv = (opcode == OP_REG) && (funct7 == 7'b0000001);
    // MUL/MULH/MULHSU/MULHU: funct3 000/001/010/011
    assign is_mul_family = is_muldiv && (funct3[2] == 1'b0);
    // DIV/DIVU/REM/REMU: funct3 100/101/110/111
    assign is_div_family = is_muldiv && (funct3[2] == 1'b1);

    always @(*) begin
        // Defaults - NOP-equivalent
        reg_write_o     = 1'b0;
        mem_read_o      = 1'b0;
        mem_write_o     = 1'b0;
        mem_to_reg_o    = 1'b0;
        alu_src_o       = 1'b0;
        alu_a_pc_o      = 1'b0;
        alu_op_o        = `ALU_ADD;
        branch_o        = 1'b0;
        jal_o           = 1'b0;
        jalr_o          = 1'b0;
        mul_en_o        = 1'b0;
        dsu_en_o        = 1'b0;
        csr_en_o        = 1'b0;
        csr_op_o        = 3'b000;
        is_system_o     = 1'b0;
        illegal_instr_o = 1'b0;
        fencei_o        = 1'b0;
        imm_sel_o       = `IMM_NONE;

        case (opcode)

            OP_LUI: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_op_o    = `ALU_PASSB;
                imm_sel_o   = `IMM_U;
            end

            OP_AUIPC: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_a_pc_o  = 1'b1;   // MUX_A = pc, reuses ALU adder (Sec. 8.1)
                alu_op_o    = `ALU_ADD;
                imm_sel_o   = `IMM_U;
            end

            OP_JAL: begin
                reg_write_o = 1'b1;
                jal_o       = 1'b1;
                imm_sel_o   = `IMM_J;
            end

            OP_JALR: begin
                reg_write_o = 1'b1;
                jalr_o      = 1'b1;
                imm_sel_o   = `IMM_I;
            end

            OP_BRANCH: begin
                branch_o  = 1'b1;
                alu_op_o  = `ALU_SUB;  // comparison base op; funct3 selects relation in EX
                imm_sel_o = `IMM_B;
            end

            OP_LOAD: begin
                reg_write_o  = 1'b1;
                mem_read_o   = 1'b1;
                mem_to_reg_o = 1'b1;
                alu_src_o    = 1'b1;
                alu_op_o     = `ALU_ADD;
                imm_sel_o    = `IMM_I;
            end

            OP_STORE: begin
                mem_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_op_o    = `ALU_ADD;
                imm_sel_o   = `IMM_S;
            end

            OP_IMM: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                imm_sel_o   = `IMM_I;
                case (funct3)
                    3'b000: alu_op_o = `ALU_ADD;                                  // ADDI
                    3'b010: alu_op_o = `ALU_SLT;                                  // SLTI
                    3'b011: alu_op_o = `ALU_SLTU;                                 // SLTIU
                    3'b100: alu_op_o = `ALU_XOR;                                  // XORI
                    3'b110: alu_op_o = `ALU_OR;                                   // ORI
                    3'b111: alu_op_o = `ALU_AND;                                  // ANDI
                    // ERRATUM C-1 (found by riscv-tests rv32mi/shamt)
                    // The shift-immediate forms carry the shift amount in
                    // instr[24:20] and RV32 requires instr[31:25] to be exactly
                    // 0000000 (SLLI/SRLI) or 0100000 (SRAI). Previously only
                    // funct7[5] was examined and the remaining six bits were
                    // ignored, so `slli x1,x1,32` - encoded with instr[25] set -
                    // executed as a shift by 0 instead of raising an illegal
                    // instruction. Spike traps it; GARUDA did not.
                    3'b001: if (funct7 == 7'b0000000) alu_op_o = `ALU_SLL;        // SLLI
                            else                      illegal_instr_o = 1'b1;
                    3'b101: if (funct7 == 7'b0000000) alu_op_o = `ALU_SRL;        // SRLI
                            else if (funct7 == 7'b0100000) alu_op_o = `ALU_SRA;   // SRAI
                            else                      illegal_instr_o = 1'b1;
                    default: illegal_instr_o = 1'b1;
                endcase
            end

            OP_REG: begin
                if (is_mul_family) begin
                    reg_write_o = 1'b1;
                    mul_en_o    = 1'b1;
                end else if (is_div_family) begin
                    // DIV/DIVU/REM/REMU decoded but not executed (Sec. 7.2) -> illegal
                    illegal_instr_o = 1'b1;
                end else if (funct7 == 7'b0000000 || funct7 == 7'b0100000) begin
                    reg_write_o = 1'b1;
                    case (funct3)
                        3'b000:  alu_op_o = funct7[5] ? `ALU_SUB : `ALU_ADD;      // SUB/ADD
                        3'b001:  alu_op_o = `ALU_SLL;
                        3'b010:  alu_op_o = `ALU_SLT;
                        3'b011:  alu_op_o = `ALU_SLTU;
                        3'b100:  alu_op_o = `ALU_XOR;
                        3'b101:  alu_op_o = funct7[5] ? `ALU_SRA : `ALU_SRL;      // SRA/SRL
                        3'b110:  alu_op_o = `ALU_OR;
                        3'b111:  alu_op_o = `ALU_AND;
                        default: illegal_instr_o = 1'b1;
                    endcase
                end else begin
                    illegal_instr_o = 1'b1;
                end
            end

            OP_SYSTEM: begin
                is_system_o = 1'b1;
                if (funct3 != 3'b000) begin
                    // CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI
                    csr_en_o    = 1'b1;
                    csr_op_o    = funct3;
                    reg_write_o = 1'b1;   // old CSR value returned to rd (Sec. 13.3)
                    imm_sel_o   = `IMM_CSR;
                end
                // funct3 == 000: ECALL/EBREAK/MRET/WFI - discriminated in EX/CONTROL
                // from instr[31:20]; no ID-stage regfile/ALU side effects here.
            end

            // ERRATUM C-2 (found while porting riscv-tests)
            // ------------------------------------------------
            // OP_MISC_MEM had no case at all, so FENCE fell through to the
            // `default` below and raised illegal_instr. RV32I permits FENCE to
            // be implemented as a no-op but does NOT permit it to trap, so any
            // conforming code that fences - including the upstream riscv-tests
            // RVTEST_PASS macro - took an illegal-instruction trap on a core
            // that is otherwise executing it correctly.
            //
            // FENCE (funct3=000) is a no-op here: GARUDA has a single hart and
            // no store buffer or cache, so there is nothing to order.
            //
            // FENCE.I (funct3=001) is now IMPLEMENTED (ERRATUM C-3). It was
            // previously illegal because the prefetch buffer holds already
            // fetched instructions and had no flush path, so a no-op would
            // have silently executed stale words after self-modifying code.
            //
            // The flush already exists: garuda_prefetch_buffer invalidates the
            // whole buffer on any redirect (Sec.6.5). So FENCE.I is realised as
            // an ID-stage redirect to PC+4 - architecturally a no-op that
            // happens to discard everything already fetched behind it, which is
            // exactly Zifencei's requirement. No new flush path, no new state.
            //
            // Any other funct3 in MISC-MEM remains illegal.
            OP_MISC_MEM: begin
                if      (funct3 == 3'b000) ;                    // FENCE: no-op
                else if (funct3 == 3'b001) fencei_o = 1'b1;     // FENCE.I
                else                       illegal_instr_o = 1'b1;
            end

            OP_CUSTOM0: begin
                // Custom-0 (DSU). Core does not interpret funct5/acc_sel/imm - it
                // drives the full instruction word to the DSU (Sec. 9.1/9.2).
                dsu_en_o = 1'b1;
                // reg_write for DSU ops is determined by the DSU's dsu_rd_valid in
                // EX, not decoded here (Sec. 9.4) - left low in ID.
            end

            default: begin
                illegal_instr_o = 1'b1;
            end
        endcase
    end

endmodule

`default_nettype wire
