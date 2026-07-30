// =============================================================
// tapeout_decode_control.sv
// Tapeout-grade SV verification environment for GARUDA decode_control.v
// (ID-stage instruction decoder, Sec. 7.1-7.2)
//
// decode_control is PURELY COMBINATIONAL - no clk/rst port, no internal
// state to carry across sequences. The sequence-based generator /
// synchronous apply-sample-check loop below still applies for structural
// consistency with the rest of this test set; the reset-isolation step a
// stateful DUT needs is a documented no-op here.
//
// Requires a simulator with full IEEE1800 support (covergroup, assert
// property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0. DEFINES (inlined from garuda_defs.vh)
// -------------------------------------------------------------
`ifndef GARUDA_DEFS_VH
`define GARUDA_DEFS_VH
`define ALU_ADD   4'h0
`define ALU_SUB   4'h1
`define ALU_AND   4'h2
`define ALU_OR    4'h3
`define ALU_XOR   4'h4
`define ALU_SLL   4'h5
`define ALU_SRL   4'h6
`define ALU_SRA   4'h7
`define ALU_SLT   4'h8
`define ALU_SLTU  4'h9
`define ALU_PASSB 4'hA
`define IMM_I    3'h0
`define IMM_S    3'h1
`define IMM_B    3'h2
`define IMM_U    3'h3
`define IMM_J    3'h4
`define IMM_CSR  3'h5
`define IMM_NONE 3'h6
`endif // GARUDA_DEFS_VH

// -------------------------------------------------------------
// 1. DUT: decode_control.v (pasted verbatim, `include line substituted)
// -------------------------------------------------------------
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

    wire is_muldiv;
    wire is_mul_family;
    wire is_div_family;

    assign is_muldiv = (opcode == OP_REG) && (funct7 == 7'b0000001);
    assign is_mul_family = is_muldiv && (funct3[2] == 1'b0);
    assign is_div_family = is_muldiv && (funct3[2] == 1'b1);

    always @(*) begin
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
                alu_a_pc_o  = 1'b1;
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
                alu_op_o  = `ALU_SUB;
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
                    3'b000: alu_op_o = `ALU_ADD;
                    3'b010: alu_op_o = `ALU_SLT;
                    3'b011: alu_op_o = `ALU_SLTU;
                    3'b100: alu_op_o = `ALU_XOR;
                    3'b110: alu_op_o = `ALU_OR;
                    3'b111: alu_op_o = `ALU_AND;
                    3'b001: alu_op_o = `ALU_SLL;
                    3'b101: alu_op_o = funct7[5] ? `ALU_SRA : `ALU_SRL;
                    // funct3 is 3 bits and all 8 values are enumerated above,
                    // so this arm is unreachable in simulation -- kept only
                    // as a synthesis safety net against an inferred latch.
                    /* VCS_COVERAGE_ANALYSIS_OFF */
                    default: illegal_instr_o = 1'b1;
                    /* VCS_COVERAGE_ANALYSIS_ON */
                endcase
            end

            OP_REG: begin
                if (is_mul_family) begin
                    reg_write_o = 1'b1;
                    mul_en_o    = 1'b1;
                end else if (is_div_family) begin
                    illegal_instr_o = 1'b1;
                end else if (funct7 == 7'b0000000 || funct7 == 7'b0100000) begin
                    reg_write_o = 1'b1;
                    case (funct3)
                        3'b000:  alu_op_o = funct7[5] ? `ALU_SUB : `ALU_ADD;
                        3'b001:  alu_op_o = `ALU_SLL;
                        3'b010:  alu_op_o = `ALU_SLT;
                        3'b011:  alu_op_o = `ALU_SLTU;
                        3'b100:  alu_op_o = `ALU_XOR;
                        3'b101:  alu_op_o = funct7[5] ? `ALU_SRA : `ALU_SRL;
                        3'b110:  alu_op_o = `ALU_OR;
                        3'b111:  alu_op_o = `ALU_AND;
                        // Same reasoning as the OP_IMM funct3 case above: all
                        // 8 values of the 3-bit field are enumerated, so this
                        // default is unreachable dead code, not a stimulus gap.
                        /* VCS_COVERAGE_ANALYSIS_OFF */
                        default: illegal_instr_o = 1'b1;
                        /* VCS_COVERAGE_ANALYSIS_ON */
                    endcase
                end else begin
                    illegal_instr_o = 1'b1;
                end
            end

            OP_SYSTEM: begin
                is_system_o = 1'b1;
                if (funct3 != 3'b000) begin
                    csr_en_o    = 1'b1;
                    csr_op_o    = funct3;
                    reg_write_o = 1'b1;
                    imm_sel_o   = `IMM_CSR;
                end
            end

            OP_CUSTOM0: begin
                dsu_en_o = 1'b1;
            end

            default: begin
                illegal_instr_o = 1'b1;
            end
        endcase
    end

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface decode_if (input bit clk);
    logic [31:0] instr;
    logic [6:0]  opcode;
    logic [4:0]  rd;
    logic [2:0]  funct3;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic         reg_write, mem_read, mem_write, mem_to_reg, alu_src, alu_a_pc;
    logic [3:0]  alu_op;
    logic         branch, jal, jalr, mul_en, dsu_en, csr_en;
    logic [2:0]  csr_op;
    logic         is_system, illegal_instr;
    logic [2:0]  imm_sel;

    // A1: every raw field is a pure bit-slice of instr_i - if these ever
    //     drifted, every other assertion (which reasons in terms of
    //     opcode/funct3/funct7) would be checking the wrong thing.
    property p_field_passthrough;
        @(posedge clk)
        (opcode == instr[6:0]) && (rd == instr[11:7]) && (funct3 == instr[14:12]) &&
        (rs1 == instr[19:15]) && (rs2 == instr[24:20]);
    endproperty
    a_field_passthrough: assert property (p_field_passthrough)
        else $error("[SVA-FAIL] a raw decode field did not match its instr_i bit-slice");

    // A2: DIV/DIVU/REM/REMU are decoded but intentionally NOT executed in
    //     hardware (Sec. 7.2) - software must trap and emulate them.
    property p_div_family_is_illegal;
        @(posedge clk)
        (instr[6:0] == 7'b0110011 && instr[31:25] == 7'b0000001 && instr[14]) |-> illegal_instr;
    endproperty
    a_div_illegal: assert property (p_div_family_is_illegal)
        else $error("[SVA-FAIL] DIV/DIVU/REM/REMU did not decode as illegal");

    // A3: the DSU custom-0 opcode must NEVER be flagged illegal - it is
    //     an architecturally reserved, always-legal extension point.
    property p_custom0_never_illegal;
        @(posedge clk) (instr[6:0] == 7'b0001011) |-> !illegal_instr;
    endproperty
    a_custom0_legal: assert property (p_custom0_never_illegal)
        else $error("[SVA-FAIL] CUSTOM0 (DSU) opcode incorrectly flagged illegal");

    // A4: mutually exclusive outputs - branch/jal/jalr can never coexist.
    property p_control_flow_mutex;
        @(posedge clk) $onehot0({branch, jal, jalr});
    endproperty
    a_control_flow_mutex: assert property (p_control_flow_mutex)
        else $error("[SVA-FAIL] more than one of branch_o/jal_o/jalr_o asserted simultaneously");

    // A5: mutually exclusive outputs - no instruction is both a load and
    //     a store.
    property p_mem_rw_mutex;
        @(posedge clk) !(mem_read && mem_write);
    endproperty
    a_mem_rw_mutex: assert property (p_mem_rw_mutex)
        else $error("[SVA-FAIL] mem_read_o and mem_write_o asserted simultaneously");

    // A6: illegal-state detection - an illegal instruction must present
    //     an architecturally inert control bundle, or the pipeline could
    //     corrupt state on its way to a trap.
    property p_illegal_forces_inert_bundle;
        @(posedge clk)
        illegal_instr |-> (!reg_write && !mem_read && !mem_write && !branch && !jal && !jalr &&
                            !mul_en && !dsu_en && !csr_en);
    endproperty
    a_illegal_inert: assert property (p_illegal_forces_inert_bundle)
        else $error("[SVA-FAIL] an illegal instruction left a side-effecting control bit asserted");

    // A7: X-propagation.
    property p_no_x_propagation;
        @(posedge clk) (!$isunknown(instr)) |->
        (!$isunknown({reg_write, mem_read, mem_write, mem_to_reg, alu_src, alu_a_pc, alu_op,
                      branch, jal, jalr, mul_en, dsu_en, csr_en, csr_op, is_system, illegal_instr, imm_sel}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] the control bundle went unknown while instr_i was fully known");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV.
//    `riscv_opcode_e` gives the generator a real instruction-mnemonic
//    vocabulary instead of raw 7-bit encodings.
// -------------------------------------------------------------
typedef enum bit [6:0] {
    OPC_LUI      = 7'b0110111,
    OPC_AUIPC    = 7'b0010111,
    OPC_JAL      = 7'b1101111,
    OPC_JALR     = 7'b1100111,
    OPC_BRANCH   = 7'b1100011,
    OPC_LOAD     = 7'b0000011,
    OPC_STORE    = 7'b0100011,
    OPC_IMM      = 7'b0010011,
    OPC_REG      = 7'b0110011,
    OPC_SYSTEM   = 7'b1110011,
    OPC_CUSTOM0  = 7'b0001011,
    OPC_RESERVED = 7'b1111111
} riscv_opcode_e;

class decode_cycle;
    rand riscv_opcode_e op;
    rand bit [4:0] rd_val, rs1_val, rs2_val;
    rand bit [2:0] funct3_val;
    rand bit [6:0] funct7_val;

    constraint c_op_dist {
        op dist {
            OPC_LUI :/ 8, OPC_AUIPC :/ 8, OPC_JAL :/ 8, OPC_JALR :/ 8,
            OPC_BRANCH :/ 10, OPC_LOAD :/ 10, OPC_STORE :/ 10, OPC_IMM :/ 12,
            OPC_REG :/ 12, OPC_SYSTEM :/ 10, OPC_CUSTOM0 :/ 8, OPC_RESERVED :/ 6
        };
    }
    constraint c_reg_ranges { rd_val inside {[0:31]}; rs1_val inside {[0:31]}; rs2_val inside {[0:31]}; }

    // Converts the enum + fields into a real 32-bit instruction word -
    // the RISC-V opcode is a fixed encoding, so (unlike hazard_forward_
    // unit/branch_predict/imm_gen) this DUT genuinely needs an
    // enum-to-bits conversion step.
    function void fields(output bit [31:0] o_instr);
        o_instr = {funct7_val, rs2_val, rs1_val, funct3_val, rd_val, op};
    endfunction

    function string to_string();
        return $sformatf("op=%-10s f3=%03b f7=%07b rd=%0d rs1=%0d rs2=%0d", op.name(), funct3_val, funct7_val, rd_val, rs1_val, rs2_val);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences + exhaustive sweep + CRV.
// -------------------------------------------------------------
class decode_generator;
    decode_cycle seq_q[$][$];
    string        seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 15, int random_seq_len = 200);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function decode_cycle mk(riscv_opcode_e op, bit [2:0] f3, bit [6:0] f7, bit [4:0] rd, bit [4:0] rs1, bit [4:0] rs2);
        decode_cycle c = new();
        c.op = op; c.funct3_val = f3; c.funct7_val = f7; c.rd_val = rd; c.rs1_val = rs1; c.rs2_val = rs2;
        return c;
    endfunction

    function void add_seq(string name, decode_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) Idle/reset vector - NOP (ADDI x0,x0,0)
        begin
            decode_cycle q[$];
            q.push_back(mk(OPC_IMM, 3'b000, 7'h0, 5'd0, 5'd0, 5'd0));
            add_seq("idle_nop", q);
        end

        // 2) One legal instruction per major opcode class
        begin
            decode_cycle q[$];
            q.push_back(mk(OPC_LUI,     3'b000, 7'h0, 5'd1, 5'd0, 5'd0));
            q.push_back(mk(OPC_AUIPC,   3'b000, 7'h0, 5'd1, 5'd0, 5'd0));
            q.push_back(mk(OPC_JAL,     3'b000, 7'h0, 5'd1, 5'd0, 5'd0));
            q.push_back(mk(OPC_JALR,    3'b000, 7'h0, 5'd1, 5'd2, 5'd0));
            q.push_back(mk(OPC_BRANCH,  3'b000, 7'h0, 5'd1, 5'd2, 5'd3));
            q.push_back(mk(OPC_LOAD,    3'b010, 7'h0, 5'd1, 5'd2, 5'd0));
            q.push_back(mk(OPC_STORE,   3'b010, 7'h0, 5'd0, 5'd2, 5'd3));
            q.push_back(mk(OPC_CUSTOM0, 3'b000, 7'h0, 5'd3, 5'd1, 5'd2));
            add_seq("one_per_opcode_class", q);
        end

        // 3) Exhaustive OP_IMM funct3 sweep (incl. SRLI/SRAI disambiguation)
        begin
            decode_cycle q[$];
            for (int f3 = 0; f3 < 8; f3++) q.push_back(mk(OPC_IMM, f3[2:0], 7'h0, 5'd6, 5'd4, 5'd0));
            q.push_back(mk(OPC_IMM, 3'b101, 7'b0100000, 5'd6, 5'd4, 5'd0)); // SRAI
            add_seq("exh_op_imm_funct3", q);
        end

        // 4) Exhaustive OP_REG sweep (ALU / MUL family / DIV family / bad funct7)
        begin
            decode_cycle q[$];
            for (int f3 = 0; f3 < 8; f3++) q.push_back(mk(OPC_REG, f3[2:0], 7'b0000000, 5'd3, 5'd1, 5'd2));
            q.push_back(mk(OPC_REG, 3'b000, 7'b0100000, 5'd3, 5'd1, 5'd2)); // SUB
            q.push_back(mk(OPC_REG, 3'b101, 7'b0100000, 5'd3, 5'd1, 5'd2)); // SRA
            for (int f3 = 0; f3 < 4; f3++) q.push_back(mk(OPC_REG, f3[2:0], 7'b0000001, 5'd3, 5'd1, 5'd2)); // MUL family
            for (int f3 = 4; f3 < 8; f3++) q.push_back(mk(OPC_REG, f3[2:0], 7'b0000001, 5'd3, 5'd1, 5'd2)); // DIV family
            q.push_back(mk(OPC_REG, 3'b000, 7'b0000010, 5'd3, 5'd1, 5'd2)); // unrecognized funct7
            add_seq("exh_op_reg_sweep", q);
        end

        // 5) OP_SYSTEM - all 6 CSR ops + privileged class
        begin
            decode_cycle q[$];
            q.push_back(mk(OPC_SYSTEM, 3'b001, 7'h0, 5'd8, 5'd10, 5'd0));
            q.push_back(mk(OPC_SYSTEM, 3'b010, 7'h0, 5'd8, 5'd10, 5'd0));
            q.push_back(mk(OPC_SYSTEM, 3'b011, 7'h0, 5'd8, 5'd10, 5'd0));
            q.push_back(mk(OPC_SYSTEM, 3'b101, 7'h0, 5'd8, 5'd10, 5'd0));
            q.push_back(mk(OPC_SYSTEM, 3'b110, 7'h0, 5'd8, 5'd10, 5'd0));
            q.push_back(mk(OPC_SYSTEM, 3'b111, 7'h0, 5'd8, 5'd10, 5'd0));
            q.push_back(mk(OPC_SYSTEM, 3'b000, 7'h0, 5'd0, 5'd0, 5'd0)); // ECALL/EBREAK/MRET/WFI class
            add_seq("op_system_csr_and_priv", q);
        end

        // 6) Reserved / unassigned major opcodes
        begin
            decode_cycle q[$];
            q.push_back(mk(OPC_RESERVED, 3'b000, 7'h0, 5'd1, 5'd2, 5'd3));
            add_seq("reserved_opcode", q);
        end

        // 7) Back-to-back repeated identical decode (stress)
        begin
            decode_cycle q[$];
            repeat (10) q.push_back(mk(OPC_REG, 3'b000, 7'b0000000, 5'd3, 5'd1, 5'd2));
            add_seq("stress_repeated_decode", q);
        end

        // 8) Alternating legal/illegal toggle (stress)
        begin
            decode_cycle q[$];
            for (int i = 0; i < 8; i++) begin
                if (i % 2 == 0) q.push_back(mk(OPC_REG, 3'b000, 7'b0000000, 5'd3, 5'd1, 5'd2)); // legal ADD
                else            q.push_back(mk(OPC_REG, 3'b100, 7'b0000001, 5'd3, 5'd1, 5'd2)); // illegal DIV
            end
            add_seq("stress_alternating_legal_illegal", q);
        end

        // 9) CONSTRAINED-RANDOM sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            decode_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                decode_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- stateless. Structured as a DISPATCH TABLE of
//    small, independent, per-instruction-family pure functions, each
//    returning a packed struct - closer to how an ISA simulator is
//    actually structured than to an RTL control-decoder. Composing many
//    small independently-checkable functions makes an error in one
//    family far less likely to accidentally compensate for an error in
//    another, unlike one monolithic case statement checked against itself.
// -------------------------------------------------------------
typedef struct packed {
    bit         reg_write, mem_read, mem_write, mem_to_reg, alu_src, alu_a_pc;
    bit [3:0]  alu_op;
    bit         branch, jal, jalr, mul_en, dsu_en, csr_en;
    bit [2:0]  csr_op;
    bit         is_system, illegal;
    bit [2:0]  imm_sel;
} decode_result_t;

class decode_ref_model;
    static function decode_result_t base_defaults();
        decode_result_t r = '{default: 0};
        r.alu_op = `ALU_ADD; r.imm_sel = `IMM_NONE;
        return r;
    endfunction

    static function decode_result_t decode_lui();
        decode_result_t r = base_defaults();
        r.reg_write = 1; r.alu_src = 1; r.alu_op = `ALU_PASSB; r.imm_sel = `IMM_U;
        return r;
    endfunction
    static function decode_result_t decode_auipc();
        decode_result_t r = base_defaults();
        r.reg_write = 1; r.alu_src = 1; r.alu_a_pc = 1; r.alu_op = `ALU_ADD; r.imm_sel = `IMM_U;
        return r;
    endfunction
    static function decode_result_t decode_jal();
        decode_result_t r = base_defaults();
        r.reg_write = 1; r.jal = 1; r.imm_sel = `IMM_J;
        return r;
    endfunction
    static function decode_result_t decode_jalr();
        decode_result_t r = base_defaults();
        r.reg_write = 1; r.jalr = 1; r.imm_sel = `IMM_I;
        return r;
    endfunction
    static function decode_result_t decode_branch();
        decode_result_t r = base_defaults();
        r.branch = 1; r.alu_op = `ALU_SUB; r.imm_sel = `IMM_B;
        return r;
    endfunction
    static function decode_result_t decode_load();
        decode_result_t r = base_defaults();
        r.reg_write = 1; r.mem_read = 1; r.mem_to_reg = 1; r.alu_src = 1; r.alu_op = `ALU_ADD; r.imm_sel = `IMM_I;
        return r;
    endfunction
    static function decode_result_t decode_store();
        decode_result_t r = base_defaults();
        r.mem_write = 1; r.alu_src = 1; r.alu_op = `ALU_ADD; r.imm_sel = `IMM_S;
        return r;
    endfunction

    static function decode_result_t decode_op_imm(bit [2:0] f3, bit [6:0] f7);
        decode_result_t r = base_defaults();
        r.reg_write = 1; r.alu_src = 1; r.imm_sel = `IMM_I;
        unique case (f3)
            3'b000: r.alu_op = `ALU_ADD;
            3'b010: r.alu_op = `ALU_SLT;
            3'b011: r.alu_op = `ALU_SLTU;
            3'b100: r.alu_op = `ALU_XOR;
            3'b110: r.alu_op = `ALU_OR;
            3'b111: r.alu_op = `ALU_AND;
            3'b001: r.alu_op = `ALU_SLL;
            3'b101: r.alu_op = f7[5] ? `ALU_SRA : `ALU_SRL;
        endcase
        return r;
    endfunction

    static function decode_result_t decode_op_reg(bit [2:0] f3, bit [6:0] f7);
        decode_result_t r = base_defaults();
        bit is_muldiv = (f7 == 7'b0000001);
        bit is_mul    = is_muldiv && !f3[2];
        bit is_div    = is_muldiv && f3[2];

        if (is_mul) begin
            r.reg_write = 1; r.mul_en = 1;
        end else if (is_div) begin
            r.illegal = 1;
        end else if (f7 == 7'b0000000 || f7 == 7'b0100000) begin
            r.reg_write = 1;
            case (f3)
                3'b000:  r.alu_op = f7[5] ? `ALU_SUB : `ALU_ADD;
                3'b001:  r.alu_op = `ALU_SLL;
                3'b010:  r.alu_op = `ALU_SLT;
                3'b011:  r.alu_op = `ALU_SLTU;
                3'b100:  r.alu_op = `ALU_XOR;
                3'b101:  r.alu_op = f7[5] ? `ALU_SRA : `ALU_SRL;
                3'b110:  r.alu_op = `ALU_OR;
                3'b111:  r.alu_op = `ALU_AND;
            endcase
        end else begin
            r.illegal = 1;
        end
        return r;
    endfunction

    static function decode_result_t decode_system(bit [2:0] f3);
        decode_result_t r = base_defaults();
        r.is_system = 1;
        if (f3 != 3'b000) begin
            r.csr_en = 1; r.csr_op = f3; r.reg_write = 1; r.imm_sel = `IMM_CSR;
        end
        return r;
    endfunction

    static function decode_result_t decode_custom0();
        decode_result_t r = base_defaults();
        r.dsu_en = 1;
        return r;
    endfunction

    static function decode_result_t decode_illegal();
        decode_result_t r = base_defaults();
        r.illegal = 1;
        return r;
    endfunction

    // Returns the predicted decode_result_t for this cycle's instruction.
    // Stateless (no register-ordering subtlety) - kept as a "step" for
    // structural parity with the rest of this test set.
    function automatic decode_result_t step(bit [31:0] instr);
        bit [6:0] opcode = instr[6:0];
        bit [2:0] f3     = instr[14:12];
        bit [6:0] f7     = instr[31:25];

        case (opcode)
            OPC_LUI:     return decode_lui();
            OPC_AUIPC:   return decode_auipc();
            OPC_JAL:     return decode_jal();
            OPC_JALR:    return decode_jalr();
            OPC_BRANCH:  return decode_branch();
            OPC_LOAD:    return decode_load();
            OPC_STORE:   return decode_store();
            OPC_IMM:     return decode_op_imm(f3, f7);
            OPC_REG:     return decode_op_reg(f3, f7);
            OPC_SYSTEM:  return decode_system(f3);
            OPC_CUSTOM0: return decode_custom0();
            default:     return decode_illegal();
        endcase
    endfunction

    // Independent illegal-cause classifier used only by coverage (not by
    // the scoreboard's PASS/FAIL decision, which relies solely on step()
    // above) - kept separate so a bug in classification can never mask a
    // scoreboard mismatch.
    function automatic bit [1:0] classify_illegal_cause(bit [31:0] instr);
        bit [6:0] opcode = instr[6:0];
        bit [2:0] f3     = instr[14:12];
        bit [6:0] f7     = instr[31:25];
        bit legal_op = opcode inside {OPC_LUI, OPC_AUIPC, OPC_JAL, OPC_JALR, OPC_BRANCH,
                                       OPC_LOAD, OPC_STORE, OPC_IMM, OPC_REG, OPC_SYSTEM, OPC_CUSTOM0};
        if (!legal_op) return 2'd1;
        if (opcode == OPC_REG) begin
            if (f7 == 7'b0000001 && f3[2]) return 2'd3;
            if (!(f7 == 7'b0000000 || f7 == 7'b0100000 || f7 == 7'b0000001)) return 2'd2;
        end
        return 2'd0;
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class decode_driver;
    virtual decode_if vif;
    function new(virtual decode_if vif); this.vif = vif; endfunction

    task apply_cycle(decode_cycle c);
        bit [31:0] instr_v;
        c.fields(instr_v);
        @(negedge vif.clk);
        vif.instr <= instr_v;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class decode_monitor;
    virtual decode_if vif;
    decode_ref_model cov_ref; // used only for the illegal-cause coverage classifier
    bit [1:0] illegal_cause_cov;

    covergroup cg_decode;
        cp_opcode: coverpoint vif.instr[6:0] {
            bins op_lui = {OPC_LUI}; bins op_auipc = {OPC_AUIPC}; bins op_jal = {OPC_JAL};
            bins op_jalr = {OPC_JALR}; bins op_branch = {OPC_BRANCH}; bins op_load = {OPC_LOAD};
            bins op_store = {OPC_STORE}; bins op_imm = {OPC_IMM}; bins op_reg = {OPC_REG};
            bins op_system = {OPC_SYSTEM}; bins op_custom = {OPC_CUSTOM0}; bins op_reserved = {OPC_RESERVED};
        }
        cp_alu_op: coverpoint vif.alu_op iff (!vif.illegal_instr) {
            bins b_add={`ALU_ADD}; bins b_sub={`ALU_SUB}; bins b_and={`ALU_AND}; bins b_or={`ALU_OR};
            bins b_xor={`ALU_XOR}; bins b_sll={`ALU_SLL}; bins b_srl={`ALU_SRL}; bins b_sra={`ALU_SRA};
            bins b_slt={`ALU_SLT}; bins b_sltu={`ALU_SLTU}; bins b_passb={`ALU_PASSB};
        }
        cp_imm_sel: coverpoint vif.imm_sel {
            bins i_type={`IMM_I}; bins s_type={`IMM_S}; bins b_type={`IMM_B}; bins u_type={`IMM_U};
            bins j_type={`IMM_J}; bins csr_type={`IMM_CSR}; bins none_type={`IMM_NONE};
        }
        cp_illegal_cause: coverpoint illegal_cause_cov {
            bins legal = {0}; bins reserved_opcode = {1}; bins bad_reg_funct7 = {2}; bins div_family = {3};
        }
        cp_csr_op: coverpoint vif.csr_op iff (vif.csr_en) {
            bins csrrw={3'b001}; bins csrrs={3'b010}; bins csrrc={3'b011};
            bins csrrwi={3'b101}; bins csrrsi={3'b110}; bins csrrci={3'b111};
        }
        cp_priv: coverpoint vif.funct3 iff (vif.is_system && !vif.csr_en) { bins priv_ops = {3'b000}; }
        cp_mul_family: coverpoint vif.funct3 iff (vif.mul_en) {
            bins mul={3'b000}; bins mulh={3'b001}; bins mulhsu={3'b010}; bins mulhu={3'b011};
        }
        cross_op_illegal: cross cp_opcode, cp_illegal_cause {
            ignore_bins non_reg_causes = !binsof(cp_opcode) intersect {OPC_REG} &&
                (binsof(cp_illegal_cause) intersect {2, 3});
            // classify_illegal_cause() returns cause=1 ("reserved_opcode")
            // only when the major opcode itself is not one of the 11
            // architected opcodes (legal_op == 0) -- i.e. only ever for
            // OPC_RESERVED. For every one of the 11 legal opcodes (REG
            // included), cause=1 is a logical impossibility no matter what
            // funct3/funct7/rest of the instruction word is.
            ignore_bins reserved_cause_needs_reserved_opcode =
                !binsof(cp_opcode) intersect {OPC_RESERVED} &&
                binsof(cp_illegal_cause) intersect {1};
            // Conversely, OPC_RESERVED is never a legal_op, so cause=0
            // ("legal") can never be classified for it either.
            ignore_bins reserved_opcode_is_never_legal =
                binsof(cp_opcode) intersect {OPC_RESERVED} &&
                binsof(cp_illegal_cause) intersect {0};
        }
    endgroup

    function new(virtual decode_if vif);
        this.vif = vif;
        cov_ref = new();
        cg_decode = new();
    endfunction

    task sample_one(output decode_result_t actual);
        #1; // allow combinational logic to settle after apply_cycle()'s NBA update
        actual = '{
            reg_write: vif.reg_write, mem_read: vif.mem_read, mem_write: vif.mem_write,
            mem_to_reg: vif.mem_to_reg, alu_src: vif.alu_src, alu_a_pc: vif.alu_a_pc,
            alu_op: vif.alu_op, branch: vif.branch, jal: vif.jal, jalr: vif.jalr,
            mul_en: vif.mul_en, dsu_en: vif.dsu_en, csr_en: vif.csr_en, csr_op: vif.csr_op,
            is_system: vif.is_system, illegal: vif.illegal_instr, imm_sel: vif.imm_sel
        };
        illegal_cause_cov = cov_ref.classify_illegal_cause(vif.instr);
        cg_decode.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class decode_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(string seq_name, int cycle_idx, decode_cycle c, bit [31:0] instr, decode_result_t actual, ref decode_ref_model model);
        decode_result_t exp = model.step(instr);

        if (actual === exp) begin
            pass_cnt++;
            $display("[PASS] seq=%-30s cyc=%0d %s -> instr=0x%08h reg_write=%0b illegal=%0b",
                      seq_name, cycle_idx, c.to_string(), instr, actual.reg_write, actual.illegal);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-30s cyc=%0d %s -> instr=0x%08h", seq_name, cycle_idx, c.to_string(), instr);
            $display("       expected=%p", exp);
            $display("       actual  =%p", actual);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class decode_env;
    virtual decode_if vif;
    decode_generator  gen;
    decode_driver     drv;
    decode_monitor    mon;
    decode_scoreboard sb;

    function new(virtual decode_if vif, int num_random_seqs = 15, int random_seq_len = 200);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        decode_ref_model model;
        int total_cycles = 0;

        gen.build();

        // NOTE: decode_control.v has no registers and no clk/rst port -
        // there is no state to leak across sequences.
        model = new();

        foreach (gen.seq_q[s]) begin
            foreach (gen.seq_q[s][i]) begin
                decode_cycle c = gen.seq_q[s][i];
                bit [31:0] instr_v;
                decode_result_t actual;
                c.fields(instr_v);
                drv.apply_cycle(c);
                mon.sample_one(actual);
                sb.check(gen.seq_name[s], i, c, instr_v, actual, model);
                total_cycles++;
            end
        end

        $display("\n============ DECODE_CONTROL UNIT TB SUMMARY ============");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d", gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_decode.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display("===========================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class decode_test;
    decode_env env;
    function new(virtual decode_if vif, int num_random_seqs = 15, int random_seq_len = 200);
        env = new(vif, num_random_seqs, random_seq_len);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    decode_if vif(clk);

    decode_control dut (
        .instr_i         (vif.instr),
        .opcode_o        (vif.opcode),
        .rd_o            (vif.rd),
        .funct3_o        (vif.funct3),
        .rs1_o           (vif.rs1),
        .rs2_o           (vif.rs2),
        .reg_write_o     (vif.reg_write),
        .mem_read_o      (vif.mem_read),
        .mem_write_o     (vif.mem_write),
        .mem_to_reg_o    (vif.mem_to_reg),
        .alu_src_o       (vif.alu_src),
        .alu_a_pc_o      (vif.alu_a_pc),
        .alu_op_o        (vif.alu_op),
        .branch_o        (vif.branch),
        .jal_o           (vif.jal),
        .jalr_o          (vif.jalr),
        .mul_en_o        (vif.mul_en),
        .dsu_en_o        (vif.dsu_en),
        .csr_en_o        (vif.csr_en),
        .csr_op_o        (vif.csr_op),
        .is_system_o     (vif.is_system),
        .illegal_instr_o (vif.illegal_instr),
        .imm_sel_o       (vif.imm_sel)
    );

    decode_test test;

    initial begin
        vif.instr = 32'h0000_0013; // NOP
        repeat (3) @(posedge clk);

        test = new(vif, 15, 200);
        test.run();
        $finish;
    end
endmodule
