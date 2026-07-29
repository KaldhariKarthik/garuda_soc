`timescale 1ns/1ps
`default_nettype none
//=============================================================================
// GARUDA SoC -- Block I: Processor Core
// ex_stage.v -- Execute stage wrapper
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sections 8, 9, 10.2, 11.1, 12.
// DSU boundary: frozen dsu_top.v per AERO-GARUDA-DS-001 Section 9.2
//               (full instr[31:0] in, dsu_rd_addr[4:0] out -- RTL overrides
//               DSU-spec Fig II.1).
//
// Contents:
//   * MUX_A / MUX_B operand forwarding (Section 11.1) + pc/imm substitution
//   * alu, mul32, branch_unit, csr_rw, dsu_top instances
//   * EX result mux, priority per Section 8.3 (erratum 6.3-E1 resolved):
//         csr_rdata (csr_en)  >  dsu_rd_data (dsu_rd_valid)  >  mul  >  alu/link
//   * PC+4 link path for JAL/JALR (see INFERENCE NOTE 1)
//   * Load/store misalignment check, pre-address-phase (Section 10.2)
//
// This module is purely combinational except for the state inside dsu_top.
// The ex_mem pipeline register lives at core top, NOT here (Section 5.2:
// pipeline registers separate the stages; they are not stage property).
//
// ---------------------------------------------------------------------------
// INTEGRATION CONSTRAINTS (normative, Section 9.4 -- read before wiring):
//
//   1. dsu_busy is a REGISTERED DSU output and is exported here raw. The
//      Hazard unit must consume it combinationally in this same cycle to
//      assert the PC / IF-ID hold. DO NOT register it again anywhere --
//      re-registering lands the bubble one cycle late.
//
//   2. ex_mem capture of the DSU result is qualified by dsu_rd_valid, NOT by
//      dsu_en (dsu_rd_valid self-gates low during a dsu_busy hold; dsu_en
//      does not). The result mux below and reg_write_out already encode
//      this -- keep it that way.
//
//   3. ex_squash (the flush pin fed to the DSU) must be the EX-STAGE squash:
//      the CONTROL-driven flush that kills the instruction currently in EX
//      and any in-flight DSU cycle-2 accumulate on trap entry. It is NOT the
//      IF/ID flush and it is NOT the mispredict flush.
//
//      INFERENCE NOTE 0 (flush domain -- flagged, not silently resolved):
//      Section 9.6's parenthetical "(mispredict or trap)" conflicts with the
//      Section 11.4 table, where a branch mispredict flushes IF and ID only
//      -- the mispredicting branch itself, and any older DSU op in its
//      accumulate cycle, are architecturally committed and must NOT be
//      squashed. Asserting the DSU flush on mispredict would kill a valid
//      older MAC's cycle-2 accumulate (state corruption). This RTL therefore
//      wires the DSU flush to the trap-driven EX squash only, per the 11.4
//      table and precise-exception rules (14.1). Spec action: reword 9.6 to
//      drop "mispredict" from the parenthetical. If the ruling goes the
//      other way, the change is one line at the dsu_top instance below.
//
// INFERENCE NOTE 1 (link path):
//      Section 8.3 enumerates a four-input result mux (CSR/DSU/MUL/ALU) but
//      JAL/JALR must write link = PC+4 to rd (Section 12.2), and for JALR the
//      ALU cannot supply it (branch_unit owns the target adder). A dedicated
//      PC+4 increment is pre-muxed into the ALU slot (alu_or_link) when
//      jal|jalr, preserving the ratified four-input priority. Spec candidate:
//      note in 8.3 that the "ALU" mux leg is alu_or_link.
//
// INFERENCE NOTE 2 (DSU destination register):
//      Section 9.2 has the DSU emit dsu_rd_addr. It equals id_ex.rd by
//      construction (both are instr[11:7]) but the DSU output is the
//      contract, so rd_out selects dsu_rd_addr when dsu_rd_valid. An
//      assertion in the core testbench should check they never diverge.
// ---------------------------------------------------------------------------

`include "core_ex_defs.vh"

module ex_stage (
    input  wire        clk,
    input  wire        rst_n,

    //------------------------------------------------------------------
    // id_ex payload (Section 5.2 field list)
    //------------------------------------------------------------------
    input  wire [31:0] pc,
    input  wire [31:0] instr,
    input  wire [31:0] rs1_data,        // register-file read (no hazard)
    input  wire [31:0] rs2_data,
    input  wire [31:0] imm,
    input  wire [4:0]  rd,
    input  wire [2:0]  funct3,

    //------------------------------------------------------------------
    // id_ex ctrl bundle
    //------------------------------------------------------------------
    input  wire        reg_write,       // NOTE: ID drives 0 for ALL Custom-0
    input  wire        mem_read,
    input  wire        mem_write,
    input  wire        mem_to_reg,
    input  wire        alu_src,         // 1: op_b = imm
    input  wire        pc_op_a,         // 1: op_a = pc (AUIPC)
    input  wire [3:0]  alu_op,
    input  wire        branch,
    input  wire        jal,
    input  wire        jalr,
    input  wire        predicted_taken, // rides in ctrl (INFERENCE, branch_unit.v)
    input  wire        mul_en,
    input  wire        dsu_en,          // (opcode == 7'b0001011) in EX
    input  wire        csr_en,
    input  wire        csr_imm,
    input  wire [1:0]  csr_op,

    //------------------------------------------------------------------
    // Hazard/Forwarding unit (Section 11.1)
    //------------------------------------------------------------------
    input  wire [1:0]  fwd_a_sel,       // FWD_NONE / FWD_EXMEM / FWD_MEMWB
    input  wire [1:0]  fwd_b_sel,
    input  wire [31:0] exmem_fwd_data,  // EX/MEM.ex_result
    input  wire [31:0] memwb_fwd_data,  // MEM/WB.wb_data (post load-format)

    //------------------------------------------------------------------
    // CONTROL/CSR/TRAP block exchange
    //------------------------------------------------------------------
    input  wire [31:0] csr_rdata,       // combinational return (Section 8.4)
    input  wire        csr_clear_overflow, // pulse on dsu_ovf CSR write
    input  wire        ex_squash,       // trap-driven EX squash (see NOTE 0)
    output wire [11:0] csr_addr,
    output wire [31:0] csr_wdata,
    output wire [1:0]  csr_op_out,
    output wire        csr_en_out,

    //------------------------------------------------------------------
    // Results toward ex_mem (register at core top)
    //------------------------------------------------------------------
    output wire [31:0] ex_result,       // for loads/stores this IS d_haddr
    output wire [31:0] store_data,      // forwarded rs2, to MEM lane-align

    // Post-forwarding register operands, fed back to ID/EX for operand
    // capture across a multi-cycle stall. See ERRATUM F-1 in id_ex.v.
    output wire [31:0] rs1_fwd_o,
    output wire [31:0] rs2_fwd_o,
    output wire [4:0]  rd_out,
    output wire        reg_write_out,
    output wire        mem_read_out,    // misalign-killed (Section 10.2)
    output wire        mem_write_out,   // misalign-killed
    output wire        mem_to_reg_out,

    //------------------------------------------------------------------
    // EX-origin redirect (into core-top redirect mux)
    //------------------------------------------------------------------
    output wire        ex_redirect,
    output wire [31:0] ex_redirect_target,
    output wire        branch_mispredict, // for perf counters / hazard

    //------------------------------------------------------------------
    // Exceptions raised in EX (to CONTROL, Section 14.1/14.2)
    //------------------------------------------------------------------
    output wire        load_misaligned,   // mcause 4, mtval = ex_result
    output wire        store_misaligned,  // mcause 6, mtval = ex_result
    output wire        dsu_illegal_instr, // OR into mcause 2, mtval = instr

    //------------------------------------------------------------------
    // DSU status / hazard / debug (Sections 9.4, 13.2, 15.2)
    //------------------------------------------------------------------
    output wire        dsu_busy,          // raw -- see integration constraint 1
    output wire        dsu_overflow,      // sticky, read via dsu_ovf CSR
    output wire [47:0] dbg_acc_0,         // straight to dbg_acc_0_o
    output wire [47:0] dbg_acc_1,
    output wire [47:0] dbg_acc_2
);

    //==================================================================
    // Operand forwarding -- MUX_A / MUX_B (Section 11.1)
    //
    // Priority (most-recent producer wins) is enforced by the Hazard
    // unit's select encoding, not re-derived here: FWD_EXMEM beats
    // FWD_MEMWB at the source of fwd_*_sel.
    //==================================================================
    reg [31:0] rs1_fwd;
    reg [31:0] rs2_fwd;

    always @(*) begin
        case (fwd_a_sel)
            `FWD_EXMEM: rs1_fwd = exmem_fwd_data;
            `FWD_MEMWB: rs1_fwd = memwb_fwd_data;
            default:    rs1_fwd = rs1_data;
        endcase
        case (fwd_b_sel)
            `FWD_EXMEM: rs2_fwd = exmem_fwd_data;
            `FWD_MEMWB: rs2_fwd = memwb_fwd_data;
            default:    rs2_fwd = rs2_data;
        endcase
    end

    // pc/imm substitution is layered AFTER forwarding: forwarding applies
    // to register operands; AUIPC/imm selection is a ctrl decision.
    wire [31:0] op_a = pc_op_a ? pc  : rs1_fwd;
    wire [31:0] op_b = alu_src ? imm : rs2_fwd;

    // Store data and DSU operands always take the forwarded REGISTER value
    // (Section 9.5: DSU operands ride the same EX forwarding paths).
    assign store_data = rs2_fwd;

    assign rs1_fwd_o = rs1_fwd;
    assign rs2_fwd_o = rs2_fwd;

    //==================================================================
    // ALU
    //==================================================================
    wire [31:0] alu_result;

    alu u_alu (
        .op_a   (op_a),
        .op_b   (op_b),
        .alu_op (alu_op),
        .result (alu_result)
    );

    //==================================================================
    // Multiplier (Section 8.2)
    //==================================================================
    wire [31:0] mul_result;

    mul32 u_mul32 (
        .rs1    (rs1_fwd),
        .rs2    (rs2_fwd),
        .funct3 (funct3),
        .result (mul_result)
    );

    //==================================================================
    // Branch / JALR resolution (Section 12)
    //==================================================================
    branch_unit u_branch (
        .pc              (pc),
        .imm             (imm),
        .funct3          (funct3),
        .rs1_fwd         (rs1_fwd),
        .rs2_fwd         (rs2_fwd),
        .branch          (branch),
        .jalr            (jalr),
        .predicted_taken (predicted_taken),
        .branch_taken    (),                 // available for BTB later; unused
        .mispredict      (branch_mispredict),
        .redirect        (ex_redirect),
        .redirect_target (ex_redirect_target)
    );

    //==================================================================
    // CSR read-modify-write seam (Sections 8.3 / 8.4)
    //==================================================================
    csr_rw u_csr_rw (
        .instr      (instr),
        .rs1_fwd    (rs1_fwd),
        .csr_en     (csr_en),
        .csr_imm    (csr_imm),
        .csr_op     (csr_op),
        .csr_addr   (csr_addr),
        .csr_wdata  (csr_wdata),
        .csr_op_out (csr_op_out),
        .csr_en_out (csr_en_out)
    );

    //==================================================================
    // DSU -- frozen boundary per Section 9.2 / dsu_top.v
    //==================================================================
    wire [31:0] dsu_rd_data;
    wire        dsu_rd_valid;
    wire [4:0]  dsu_rd_addr;

    dsu_top u_dsu (
        .clk                (clk),
        .rst_n              (rst_n),
        .flush              (ex_squash),     // EX squash ONLY -- see NOTE 0
        .dsu_en             (dsu_en),
        .instr              (instr),
        .rs1                (rs1_fwd),       // post-forwarding (Section 9.5)
        .rs2                (rs2_fwd),
        .csr_clear_overflow (csr_clear_overflow),
        .dsu_busy           (dsu_busy),
        .dsu_rd_data        (dsu_rd_data),
        .dsu_rd_valid       (dsu_rd_valid),
        .dsu_rd_addr        (dsu_rd_addr),
        .dsu_overflow       (dsu_overflow),
        .illegal_instr      (dsu_illegal_instr),
        .dbg_acc_0          (dbg_acc_0),
        .dbg_acc_1          (dbg_acc_1),
        .dbg_acc_2          (dbg_acc_2)
    );

    //==================================================================
    // Link path (INFERENCE NOTE 1) and EX result mux (Section 8.3,
    // erratum 6.3-E1 resolved -- priority is normative):
    //
    //   1. csr_rdata   when csr_en        (old CSR value -> rd)
    //   2. dsu_rd_data when dsu_rd_valid  (NOT dsu_en -- constraint 2)
    //   3. mul_result  when mul_en
    //   4. alu_or_link otherwise
    //
    // Loads override later in WB via mem_to_reg (Section 10.3).
    //==================================================================
    wire [31:0] link        = pc + 32'd4;
    wire [31:0] alu_or_link = (jal | jalr) ? link : alu_result;

    assign ex_result = csr_en       ? csr_rdata
                     : dsu_rd_valid ? dsu_rd_data
                     : mul_en       ? mul_result
                     :                alu_or_link;

    //==================================================================
    // Destination register and write-enable
    //
    // ID drives reg_write = 0 for every Custom-0 instruction (it cannot
    // know which funct5 values write -- Section 9.1: the core does not
    // interpret funct5). The DSU's dsu_rd_valid is the sole write-enable
    // source for DSU results (Section 9.4), and it self-gates during a
    // dsu_busy hold, satisfying constraint 2 with no extra logic.
    //==================================================================
    assign rd_out        = dsu_rd_valid ? dsu_rd_addr : rd;    // NOTE 2
    assign reg_write_out = reg_write | dsu_rd_valid;

    //==================================================================
    // Load/store misalignment (Section 10.2) -- checked HERE, before the
    // D-port address phase can commit; a misaligned access never issues.
    // ex_result carries the faulting address for mtval (Section 14.2).
    //
    //   funct3[1:0]: 00 byte (never misaligned), 01 half, 10 word.
    //==================================================================
    wire misaligned = (funct3[1:0] == 2'b01) ?  alu_result[0]
                    : (funct3[1:0] == 2'b10) ? |alu_result[1:0]
                    :                           1'b0;

    assign load_misaligned  = mem_read  & misaligned;
    assign store_misaligned = mem_write & misaligned;

    assign mem_read_out   = mem_read  & ~misaligned;
    assign mem_write_out  = mem_write & ~misaligned;
    assign mem_to_reg_out = mem_to_reg;

endmodule

`default_nettype wire
