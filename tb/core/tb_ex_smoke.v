//=============================================================================
// tb_ex_smoke.v -- elaboration + directed spot checks for ex_stage.
// NOT the real verification (that's the verification lead's tb against the
// real dsu_top). This exists to catch wiring/typo/priority errors at lint
// time. Run: iverilog -g2012 -I rtl/core rtl/core/*.v tb/stub/*.v && ./a.out
//=============================================================================
`timescale 1ns/1ps
`include "core_ex_defs.vh"

module tb_ex_smoke;

    reg         clk = 0, rst_n = 0;
    reg  [31:0] pc, instr, rs1_data, rs2_data, imm;
    reg  [4:0]  rd;
    reg  [2:0]  funct3;
    reg         reg_write, mem_read, mem_write, mem_to_reg;
    reg         alu_src, pc_op_a;
    reg  [3:0]  alu_op;
    reg         branch, jal, jalr, predicted_taken, mul_en, dsu_en;
    reg         csr_en, csr_imm;
    reg  [1:0]  csr_op;
    reg  [1:0]  fwd_a_sel, fwd_b_sel;
    reg  [31:0] exmem_fwd_data, memwb_fwd_data;
    reg  [31:0] csr_rdata;
    reg         csr_clear_overflow, ex_squash;

    wire [11:0] csr_addr;
    wire [31:0] csr_wdata;
    wire [1:0]  csr_op_out;
    wire        csr_en_out;
    wire [31:0] ex_result, store_data, ex_redirect_target;
    wire [4:0]  rd_out;
    wire        reg_write_out, mem_read_out, mem_write_out, mem_to_reg_out;
    wire        ex_redirect, branch_mispredict;
    wire        load_misaligned, store_misaligned, dsu_illegal_instr;
    wire        dsu_busy, dsu_overflow;
    wire [47:0] dbg_acc_0, dbg_acc_1, dbg_acc_2;

    integer errors = 0;

    ex_stage dut (
        .clk(clk),
        .rst_n(rst_n),
        .pc(pc),
        .instr(instr),
        .rs1_data(rs1_data),
        .rs2_data(rs2_data),
        .imm(imm),
        .rd(rd),
        .funct3(funct3),
        .reg_write(reg_write),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .alu_src(alu_src),
        .pc_op_a(pc_op_a),
        .alu_op(alu_op),
        .branch(branch),
        .jal(jal),
        .jalr(jalr),
        .predicted_taken(predicted_taken),
        .mul_en(mul_en),
        .dsu_en(dsu_en),
        .csr_en(csr_en),
        .csr_imm(csr_imm),
        .csr_op(csr_op),
        .fwd_a_sel(fwd_a_sel),
        .fwd_b_sel(fwd_b_sel),
        .exmem_fwd_data(exmem_fwd_data),
        .memwb_fwd_data(memwb_fwd_data),
        .csr_rdata(csr_rdata),
        .csr_clear_overflow(csr_clear_overflow),
        .ex_squash(ex_squash),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_op_out(csr_op_out),
        .csr_en_out(csr_en_out),
        .ex_result(ex_result),
        .store_data(store_data),
        .rd_out(rd_out),
        .reg_write_out(reg_write_out),
        .mem_read_out(mem_read_out),
        .mem_write_out(mem_write_out),
        .mem_to_reg_out(mem_to_reg_out),
        .ex_redirect(ex_redirect),
        .ex_redirect_target(ex_redirect_target),
        .branch_mispredict(branch_mispredict),
        .load_misaligned(load_misaligned),
        .store_misaligned(store_misaligned),
        .dsu_illegal_instr(dsu_illegal_instr),
        .dsu_busy(dsu_busy),
        .dsu_overflow(dsu_overflow),
        .dbg_acc_0(dbg_acc_0),
        .dbg_acc_1(dbg_acc_1),
        .dbg_acc_2(dbg_acc_2)
    );

    always #2.5 clk = ~clk;   // 200 MHz

    task clear_inputs;
        begin
            {pc, instr, rs1_data, rs2_data, imm} = 0;
            {rd, funct3} = 0;
            {reg_write, mem_read, mem_write, mem_to_reg} = 0;
            {alu_src, pc_op_a} = 0; alu_op = `ALU_ADD;
            {branch, jal, jalr, predicted_taken, mul_en, dsu_en} = 0;
            {csr_en, csr_imm, csr_op} = 0;
            {fwd_a_sel, fwd_b_sel} = 0;
            {exmem_fwd_data, memwb_fwd_data, csr_rdata} = 0;
            {csr_clear_overflow, ex_squash} = 0;
        end
    endtask

    task check32(input [127:0] name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %08h exp %08h", name, got, exp);
            errors = errors + 1;
        end
    endtask

    task check1(input [127:0] name, input got, input exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %b exp %b", name, got, exp);
            errors = errors + 1;
        end
    endtask

    initial begin
        clear_inputs; #10 rst_n = 1; #10;

        // --- ALU ADD with EX/MEM forward on rs1 -------------------------
        rs1_data = 32'hDEAD_0000; rs2_data = 32'd7;
        fwd_a_sel = `FWD_EXMEM; exmem_fwd_data = 32'd5;
        alu_op = `ALU_ADD; #1;
        check32("alu_add_fwd", ex_result, 32'd12);

        // --- SRA sign behavior -------------------------------------------
        clear_inputs; rst_n = 1;
        rs1_data = 32'h8000_0000; rs2_data = 32'd4; alu_op = `ALU_SRA; #1;
        check32("alu_sra", ex_result, 32'hF800_0000);

        // --- MULH signed x signed ----------------------------------------
        clear_inputs; rst_n = 1;
        mul_en = 1; funct3 = `MUL_MULH;
        rs1_data = 32'hFFFF_FFFF;  // -1
        rs2_data = 32'hFFFF_FFFF;  // -1  -> product = 1 -> high = 0
        #1; check32("mulh_ss", ex_result, 32'd0);

        // --- MULHSU: -1 (s) x 0xFFFFFFFF (u) = -(2^32-1) ------------------
        funct3 = `MUL_MULHSU; #1;
        check32("mulhsu", ex_result, 32'hFFFF_FFFF);

        // --- MULHU: max u x max u -----------------------------------------
        funct3 = `MUL_MULHU; #1;
        check32("mulhu", ex_result, 32'hFFFF_FFFE);

        // --- Result-mux priority: csr_rdata beats mul ---------------------
        csr_en = 1; csr_rdata = 32'hC5AA_0001; #1;
        check32("mux_csr_top", ex_result, 32'hC5AA_0001);

        // --- BEQ predicted-taken, actually not-taken: redirect to pc+4 ----
        clear_inputs; rst_n = 1;
        branch = 1; predicted_taken = 1; funct3 = `BR_BEQ;
        pc = 32'h0000_1000; imm = -32'd16;
        rs1_data = 32'd1; rs2_data = 32'd2; #1;
        check1 ("bmiss_flag",  branch_mispredict, 1'b1);
        check1 ("bmiss_redir", ex_redirect, 1'b1);
        check32("bmiss_tgt",   ex_redirect_target, 32'h0000_1004);

        // --- Same branch, actually taken: prediction correct, no redirect -
        rs2_data = 32'd1; #1;
        check1("bhit_no_redir", ex_redirect, 1'b0);

        // --- JALR: target masked, link on result ---------------------------
        clear_inputs; rst_n = 1;
        jalr = 1; pc = 32'h0000_2000;
        rs1_data = 32'h0000_3001; imm = 32'd2; #1;
        check1 ("jalr_redir", ex_redirect, 1'b1);
        check32("jalr_tgt",   ex_redirect_target, 32'h0000_3002); // &~1
        check32("jalr_link",  ex_result, 32'h0000_2004);

        // --- Misaligned LW: flag up, mem_read killed ------------------------
        clear_inputs; rst_n = 1;
        mem_read = 1; alu_src = 1; funct3 = 3'b010;      // LW
        rs1_data = 32'h2000_0000; imm = 32'd2; #1;
        check1("lw_mis_flag", load_misaligned, 1'b1);
        check1("lw_mis_kill", mem_read_out, 1'b0);
        check32("lw_mis_addr", ex_result, 32'h2000_0002); // mtval source

        // --- Aligned SH passes ----------------------------------------------
        clear_inputs; rst_n = 1;
        mem_write = 1; alu_src = 1; funct3 = 3'b001;     // SH
        rs1_data = 32'h2000_0000; imm = 32'd6;
        rs2_data = 32'hBEEF_1234; fwd_b_sel = `FWD_MEMWB;
        memwb_fwd_data = 32'h0000_5678; #1;
        check1 ("sh_ok",    store_misaligned, 1'b0);
        check1 ("sh_write", mem_write_out, 1'b1);
        check32("sh_data_fwd", store_data, 32'h0000_5678);

        // --- CSRRWI: wdata = zero-ext uimm, addr = instr[31:20] -------------
        clear_inputs; rst_n = 1;
        csr_en = 1; csr_imm = 1; csr_op = `CSR_RW;
        instr = {12'h305, 5'd21, 3'b101, 5'd3, 7'b1110011}; #1;
        check32("csrrwi_wdata", csr_wdata, 32'd21);
        check1 ("csr_addr_ok", (csr_addr === 12'h305), 1'b1);

        // --- LUI: ALU_PASSB passes the U-immediate to rd (regression) ------
        clear_inputs; rst_n = 1;
        reg_write = 1; alu_src = 1; alu_op = `ALU_PASSB;
        rs1_data = 32'hDEAD_BEEF;   // LUI has no rs1; must be ignored
        imm = 32'h12345000; #1;
        check32("lui_passb", ex_result, 32'h12345000);
        check1 ("lui_regwr", reg_write_out, 1'b1);

        if (errors == 0) $display("EX SMOKE: ALL CHECKS PASSED");
        else             $display("EX SMOKE: %0d FAILURES", errors);
        $finish;
    end

endmodule
