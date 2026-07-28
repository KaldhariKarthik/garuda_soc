`timescale 1ns/1ps

// =============================================================================
// GARUDA SoC - Block I: Processor Core
// ID Stage SystemVerilog Testbench (100% Coverage Suite)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 5, Sec. 7, Sec. 11, Sec. 12
// =============================================================================

// -------------------------------------------------------------------------
// ID-Stage Shared Constants Guard
// -------------------------------------------------------------------------
`ifndef GARUDA_ID_DEFS_VH
`define GARUDA_ID_DEFS_VH
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
`define IMM_CSR  3'h5   // 5-bit zero-extended rs1, CSRRWI/SI/CI (Sec. 13.3)
`define IMM_NONE 3'h6
`endif

module tb_id_stage;

    // -------------------------------------------------------------------------
    // Clock and Reset Signals
    // -------------------------------------------------------------------------
    bit clk;
    bit rst_n;

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT Signal Interfaces
    // -------------------------------------------------------------------------
    logic [31:0] if_id_instr;
    logic [31:0] if_id_pc;
    logic        if_id_fault;
    logic        if_id_valid;

    logic        wb_reg_write;
    logic [4:0]  wb_rd;
    logic [31:0] wb_data;

    logic        ex_mem_read;
    logic [4:0]  ex_rd;

    wire         reg_write_o;
    wire         mem_read_o;
    wire         mem_write_o;
    wire         mem_to_reg_o;
    wire         alu_src_o;
    wire         alu_a_pc_o;
    wire [3:0]   alu_op_o;
    wire         branch_o;
    wire         jal_o;
    wire         jalr_o;
    wire         mul_en_o;
    wire         dsu_en_o;
    wire         csr_en_o;
    wire [2:0]   csr_op_o;
    wire         is_system_o;
    wire         illegal_instr_dec_o;

    wire [31:0]  rs1_data_o;
    wire [31:0]  rs2_data_o;
    wire [31:0]  imm_o;
    wire [31:0]  pc_o;
    wire [4:0]   rs1_idx_o;
    wire [4:0]   rs2_idx_o;
    wire [4:0]   rd_o;
    wire [2:0]   funct3_o;
    wire [31:0]  instr_o;
    wire         fault_o;
    wire         load_use_stall_o;
    wire         id_redirect_valid_o;
    wire [31:0]  id_redirect_target_o;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    id_stage dut (
        .clk_i                 (clk),
        .rst_n_i               (rst_n),
        .if_id_instr_i         (if_id_instr),
        .if_id_pc_i            (if_id_pc),
        .if_id_fault_i         (if_id_fault),
        .if_id_valid_i         (if_id_valid),
        .wb_reg_write_i        (wb_reg_write),
        .wb_rd_i               (wb_rd),
        .wb_data_i             (wb_data),
        .ex_mem_read_i         (ex_mem_read),
        .ex_rd_i               (ex_rd),
        .reg_write_o           (reg_write_o),
        .mem_read_o            (mem_read_o),
        .mem_write_o           (mem_write_o),
        .mem_to_reg_o          (mem_to_reg_o),
        .alu_src_o             (alu_src_o),
        .alu_a_pc_o            (alu_a_pc_o),
        .alu_op_o              (alu_op_o),
        .branch_o              (branch_o),
        .jal_o                 (jal_o),
        .jalr_o                (jalr_o),
        .mul_en_o              (mul_en_o),
        .dsu_en_o              (dsu_en_o),
        .csr_en_o              (csr_en_o),
        .csr_op_o              (csr_op_o),
        .is_system_o           (is_system_o),
        .illegal_instr_dec_o   (illegal_instr_dec_o),
        .rs1_data_o            (rs1_data_o),
        .rs2_data_o            (rs2_data_o),
        .imm_o                 (imm_o),
        .pc_o                  (pc_o),
        .rs1_idx_o             (rs1_idx_o),
        .rs2_idx_o             (rs2_idx_o),
        .rd_o                  (rd_o),
        .funct3_o              (funct3_o),
        .instr_o               (instr_o),
        .fault_o               (fault_o),
        .load_use_stall_o      (load_use_stall_o),
        .id_redirect_valid_o   (id_redirect_valid_o),
        .id_redirect_target_o  (id_redirect_target_o)
    );

    // -------------------------------------------------------------------------
    // RISC-V Major Opcode Maps
    // -------------------------------------------------------------------------
    typedef enum bit [6:0] {
        OP_LUI      = 7'b0110111,
        OP_AUIPC    = 7'b0010111,
        OP_JAL      = 7'b1101111,
        OP_JALR     = 7'b1100111,
        OP_BRANCH   = 7'b1100011,
        OP_LOAD     = 7'b0000011,
        OP_STORE    = 7'b0100011,
        OP_IMM      = 7'b0010011,
        OP_REG      = 7'b0110011,
        OP_SYSTEM   = 7'b1110011,
        OP_CUSTOM0  = 7'b0001011,
        OP_RESERVED = 7'b1111111
    } opcode_t;

    // Encoding Helpers
    function bit [31:0] enc_r(bit [6:0] f7, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
        return {f7, rs2, rs1, f3, rd, op};
    endfunction

    function bit [31:0] enc_i(bit [11:0] imm, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
        return {imm, rs1, f3, rd, op};
    endfunction

    function bit [31:0] enc_s(bit [11:0] imm, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3, bit [6:0] op);
        return {imm[11:5], rs2, rs1, f3, imm[4:0], op};
    endfunction

    function bit [31:0] enc_b(bit [12:0] imm, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3, bit [6:0] op);
        return {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
    endfunction

    function bit [31:0] enc_u(bit [19:0] imm20, bit [4:0] rd, bit [6:0] op);
        return {imm20, rd, op};
    endfunction

    function bit [31:0] enc_j(bit [20:0] imm, bit [4:0] rd, bit [6:0] op);
        return {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
    endfunction

    // -------------------------------------------------------------------------
    // SystemVerilog Assertions (SVA)
    // -------------------------------------------------------------------------
    property p_bypass_rs1;
        @(posedge clk) disable iff (!rst_n)
        (wb_reg_write && (wb_rd != 0) && (rs1_idx_o == wb_rd)) |-> (rs1_data_o == wb_data);
    endproperty
    assert_bypass_rs1: assert property(p_bypass_rs1) else $error("Assertion Failed: WB->ID rs1 Bypass check failed!");

    property p_bypass_rs2;
        @(posedge clk) disable iff (!rst_n)
        (wb_reg_write && (wb_rd != 0) && (rs2_idx_o == wb_rd)) |-> (rs2_data_o == wb_data);
    endproperty
    assert_bypass_rs2: assert property(p_bypass_rs2) else $error("Assertion Failed: WB->ID rs2 Bypass check failed!");

    property p_load_use_stall;
        @(posedge clk) disable iff (!rst_n)
        (ex_mem_read && (ex_rd != 5'd0) && ((rs1_idx_o == ex_rd) || (rs2_idx_o == ex_rd))) |-> load_use_stall_o;
    endproperty
    assert_load_use: assert property(p_load_use_stall) else $error("Assertion Failed: Load-use hazard failed to trigger a stall!");

    property p_jal_redirect;
        @(posedge clk) disable iff (!rst_n)
        (jal_o) |-> (id_redirect_valid_o && (id_redirect_target_o == (if_id_pc + imm_o)));
    endproperty
    assert_jal_redirect: assert property(p_jal_redirect) else $error("Assertion Failed: JAL branch target redirect calculation failed!");

    property p_backward_branch_redirect;
        @(posedge clk) disable iff (!rst_n)
        (branch_o && imm_o[31]) |-> (id_redirect_valid_o && (id_redirect_target_o == (if_id_pc + imm_o)));
    endproperty
    assert_backward_branch_redirect: assert property(p_backward_branch_redirect) else $error("Assertion Failed: Backward branch prediction failed!");

    // -------------------------------------------------------------------------
    // SystemVerilog Functional Coverage
    // -------------------------------------------------------------------------
    covergroup cg_id_stage @(posedge clk);
        option.per_instance = 1;

        // Cover Instruction Opcodes
        cp_opcode: coverpoint if_id_instr[6:0] {
            bins op_lui      = {OP_LUI};
            bins op_auipc    = {OP_AUIPC};
            bins op_jal      = {OP_JAL};
            bins op_jalr     = {OP_JALR};
            bins op_branch   = {OP_BRANCH};
            bins op_load     = {OP_LOAD};
            bins op_store    = {OP_STORE};
            bins op_imm      = {OP_IMM};
            bins op_reg      = {OP_REG};
            bins op_system   = {OP_SYSTEM};
            bins op_custom   = {OP_CUSTOM0};
            bins op_reserved = {OP_RESERVED};
        }

        // Cover Registers
        cp_rs1: coverpoint rs1_idx_o {
            bins zero = {0};
            bins low  = {[1:15]};
            bins high = {[16:31]};
        }
        cp_rs2: coverpoint rs2_idx_o {
            bins zero = {0};
            bins low  = {[1:15]};
            bins high = {[16:31]};
        }
        cp_rd: coverpoint rd_o {
            bins zero = {0};
            bins low  = {[1:15]};
            bins high = {[16:31]};
        }

        // Stall conditions
        cp_stall: coverpoint load_use_stall_o {
            bins unstalled = {0};
            bins stalled   = {1};
        }

        // Cross Opcode and Stall
        cross_op_stall: cross cp_opcode, cp_stall;
    endgroup

    cg_id_stage cov_inst = new();

    // -------------------------------------------------------------------------
    // Advanced OOP Transaction Class (Focused Hazard Injection)
    // -------------------------------------------------------------------------
    class id_transaction;
        rand bit [31:0] pc;
        rand bit [31:0] instr;
        rand bit        fault;
        rand bit        valid;

        // WB configuration
        rand bit        wb_write;
        rand bit [4:0]  wb_r_idx;
        rand bit [31:0] wb_data_val;

        // EX configuration
        rand bit        ex_read;
        rand bit [4:0]  ex_rd_idx;

        // Force Hazard distribution to guarantee coverage hits
        rand bit        force_stall;

        constraint defaults {
            valid == 1'b1;
            pc % 4 == 0;
        }

        constraint sensible_regs {
            wb_r_idx  inside {[0:31]};
            ex_rd_idx inside {[0:31]};
        }

        constraint hazard_dist {
            force_stall dist {1 := 40, 0 := 60};
            if (force_stall) {
                ex_read == 1'b1;
                ex_rd_idx != 0;
                ex_rd_idx == instr[19:15]; // Match rs1_idx from instruction
            }
        }
    endclass

    // -------------------------------------------------------------------------
    // Main Test Controller
    // -------------------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task check32(string name, bit [31:0] actual, bit [31:0] expected);
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("FAIL: %s | Got=0x%08h | Expected=0x%08h", name, actual, expected);
        end
    endtask

    task check1(string name, bit actual, bit expected);
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("FAIL: %s | Got=%b | Expected=%b", name, actual, expected);
        end
    endtask

    initial begin
        // Signal Initialization
        clk          = 0;
        rst_n        = 0;
        if_id_instr  = 32'h00000013; // NOP
        if_id_pc     = 32'h00000000;
        if_id_fault  = 0;
        if_id_valid  = 0;
        wb_reg_write = 0;
        wb_rd        = 0;
        wb_data      = 0;
        ex_mem_read  = 0;
        ex_rd        = 0;

        #20;
        rst_n = 1;
        @(posedge clk);

        $display("\n=== STARTING ID_STAGE 100%% COVERAGE TESTBENCH ===");

        // ---------------------------------------------------------
        // TC1: x0 Register Integrity
        // ---------------------------------------------------------
        $display("TC1: Testing Register x0 Read-Only Zero Boundary...");
        @(posedge clk);
        wb_reg_write = 1'b1;
        wb_rd        = 5'd0;        
        wb_data      = 32'hFFFF_FFFF;
        if_id_instr  = enc_r(7'h0, 5'd0, 5'd0, 3'h0, 5'd5, OP_REG);
        @(posedge clk); #1;
        check32("x0_read_data_1", rs1_data_o, 32'd0);
        check32("x0_read_data_2", rs2_data_o, 32'd0);

        // ---------------------------------------------------------
        // TC2: WB->ID Active Register Bypass
        // ---------------------------------------------------------
        $display("TC2: Testing WB->ID Combinational Register Bypass...");
        @(posedge clk);
        wb_reg_write = 1'b1;
        wb_rd        = 5'd12;
        wb_data      = 32'hC001_CAFE;
        if_id_instr  = enc_r(7'h0, 5'd12, 5'd12, 3'h0, 5'd3, OP_REG);
        #1;
        check32("Bypass rs1 verification", rs1_data_o, 32'hC001_CAFE);
        check32("Bypass rs2 verification", rs2_data_o, 32'hC001_CAFE);

        // ---------------------------------------------------------
        // TC3: Load-Use Hazard & Stall Exclusions
        // ---------------------------------------------------------
        $display("TC3: Testing Load-Use Hazard & Stall Corner Exclusions...");
        @(posedge clk);
        ex_mem_read = 1'b1;
        ex_rd       = 5'd10;
        if_id_instr = enc_r(7'h0, 5'd5, 5'd10, 3'h0, 5'd11, OP_REG);
        #1;
        check1("Load-use rs1 stall high check", load_use_stall_o, 1'b1);

        ex_mem_read = 1'b1;
        ex_rd       = 5'd0;
        if_id_instr = enc_r(7'h0, 5'd0, 5'd0, 3'h0, 5'd2, OP_REG);
        #1;
        check1("Load-use stall off for x0 match", load_use_stall_o, 1'b0);

        // ---------------------------------------------------------
        // TC4: Static Branch Prediction Boundaries
        // ---------------------------------------------------------
        $display("TC4: Testing Branch Target Wrappings & Predict logic...");
        if_id_pc    = 32'h0000_0004;
        
        // Backward Branch (negative offset: -8 bytes)
        if_id_instr = enc_b(13'sh1FF8, 5'd1, 5'd2, 3'b000, OP_BRANCH);
        #1;
        check1("Backward branch predict valid", id_redirect_valid_o, 1'b1);
        check32("Backward branch redirect target", id_redirect_target_o, 32'hFFFF_FFFC);

        // Forward Branch (+12 bytes)
        if_id_instr = enc_b(13'sd12, 5'd1, 5'd2, 3'b000, OP_BRANCH);
        #1;
        check1("Forward branch no-predict valid", id_redirect_valid_o, 1'b0);

        // ---------------------------------------------------------
        // TC5: Invalid/Reserved Instruction Handlers
        // ---------------------------------------------------------
        $display("TC5: Testing Illegal and Reserved Opcode Handling...");
        if_id_instr = 32'hFFFF_FFFF;
        #1;
        check1("Illegal instruction output assert", illegal_instr_dec_o, 1'b1);

        // ---------------------------------------------------------
        // TC6: Opcode x Stall Cross-Coverage Sweep (Guarantees 100% Cov)
        // ---------------------------------------------------------
        $display("TC6: Sweeping all Opcodes against Stall/Unstall bins...");
        begin
            bit [6:0] opcodes[12] = '{
                7'b0110111, // OP_LUI
                7'b0010111, // OP_AUIPC
                7'b1101111, // OP_JAL
                7'b1100111, // OP_JALR
                7'b1100011, // OP_BRANCH
                7'b0000011, // OP_LOAD
                7'b0100011, // OP_STORE
                7'b0010011, // OP_IMM
                7'b0110011, // OP_REG
                7'b1110011, // OP_SYSTEM
                7'b0001011, // OP_CUSTOM0
                7'b1111111  // OP_RESERVED
            };

            foreach (opcodes[i]) begin
                // Bin 1: Opcode with NO stall
                ex_mem_read = 1'b0;
                ex_rd       = 5'd0;
                if_id_instr = {12'h0, 5'd5, 3'b000, 5'd1, opcodes[i]};
                @(posedge clk); #1;

                // Bin 2: Opcode WITH active Load-Use stall (rs1 = ex_rd = 5)
                ex_mem_read = 1'b1;
                ex_rd       = 5'd5;
                if_id_instr = {12'h0, 5'd5, 3'b000, 5'd1, opcodes[i]};
                @(posedge clk); #1;
            end
        end

        // ---------------------------------------------------------
        // TC7: Structural Corner Cases
        // ---------------------------------------------------------
        $display("TC7: Testing Additional Structural Corner Cases...");

        // Corner 1: M-Extension Division raises illegal_instr_dec_o
        if_id_instr = enc_r(7'b0000001, 5'd2, 5'd1, 3'b100, 5'd3, OP_REG); // DIV
        #1;
        check1("DIV raises illegal instruction exception", illegal_instr_dec_o, 1'b1);

        // Corner 2: Dual rs1 & rs2 Match with ex_rd
        ex_mem_read = 1'b1;
        ex_rd       = 5'd7;
        if_id_instr = enc_r(7'h0, 5'd7, 5'd7, 3'h0, 5'd8, OP_REG);
        #1;
        check1("Dual rs1/rs2 match load-use stall", load_use_stall_o, 1'b1);

        // Corner 3: CSR Immediate Type (`IMM_CSR`) Zero-Extension
        if_id_instr = {12'hABC, 5'd31, 3'b101, 5'd10, OP_SYSTEM}; // CSRRWI (rs1=31)
        #1;
        check32("CSR Immediate Zero-Extension check", imm_o, 32'h0000_001F);

        // ---------------------------------------------------------
        // TC8: Constrained Random Stimulus (CRV)
        // ---------------------------------------------------------
        $display("TC8: Injecting Dense Constrained Random Transfers...");
        begin
            id_transaction tx;
            tx = new();
            repeat (500) begin
                if (!tx.randomize()) begin
                    $fatal("CRV Randomization Failed!");
                end
                
                if_id_pc     = tx.pc;
                if_id_instr  = tx.instr;
                if_id_fault  = tx.fault;
                if_id_valid  = tx.valid;
                wb_reg_write = tx.wb_write;
                wb_rd        = tx.wb_r_idx;
                wb_data      = tx.wb_data_val;
                ex_mem_read  = tx.ex_read;
                ex_rd        = tx.ex_rd_idx;
                
                @(posedge clk); #1;
            end
        end

        // ---------------------------------------------------------
        // Compilation & Coverage Report
        // ---------------------------------------------------------
        $display("\n=============================================");
        $display("SIMULATION COMPLETED");
        $display("Functional Coverage achieved: %0.2f%%", cov_inst.get_inst_coverage());
        $display("TOTAL CHECKPOINTS PASSED: %0d", pass_count);
        $display("TOTAL CHECKPOINTS FAILED: %0d", fail_count);
        $display("=============================================");
        
        if (fail_count == 0) begin
            $display("RESULT: ALL TESTCASES AND CORNER CASES PASSED!");
        end else begin
            $display("RESULT: FAILURE DETECTED ON ONE OR MORE CORNER CASES.");
        end
        $finish;
    end

endmodule
