`timescale 1ns/1ps
module tb_id_ex_fwd;
  integer errors = 0;
  task chk2(input [127:0] name, input [1:0] got, input [1:0] exp);
    begin if (got!==exp) begin $display("FAIL %0s: got %b exp %b",name,got,exp); errors=errors+1; end end
  endtask
  task chk1(input [127:0] name, input got, input exp);
    begin if (got!==exp) begin $display("FAIL %0s: got %b exp %b",name,got,exp); errors=errors+1; end end
  endtask
  task chk32(input [127:0] name, input [31:0] got, input [31:0] exp);
    begin if (got!==exp) begin $display("FAIL %0s: got %h exp %h",name,got,exp); errors=errors+1; end end
  endtask

  // ---------------- forward_unit (combinational) ----------------
  reg [4:0] fa_rs1, fa_rs2, fa_exrd, fa_wbrd; reg fa_exwe, fa_wbwe;
  wire [1:0] fa_sela, fa_selb;
  forward_unit fu(.id_ex_rs1_idx_i(fa_rs1), .id_ex_rs2_idx_i(fa_rs2),
    .exmem_rd_i(fa_exrd), .exmem_reg_write_i(fa_exwe),
    .memwb_rd_i(fa_wbrd), .memwb_reg_write_i(fa_wbwe),
    .fwd_a_sel_o(fa_sela), .fwd_b_sel_o(fa_selb));

  // ---------------- id_ex (sequential) ----------------
  reg clk=0, rst_n, stall, flush;
  reg [31:0] pc_i, instr_i, imm_i; reg [4:0] rd_i, rs1i, rs2i;
  reg rw_i, mr_i, dsu_i, pt_i;
  wire [31:0] pc_o, instr_o; wire [4:0] rd_o; wire rw_o, mr_o, dsu_o, pt_o;
  id_ex dut(.clk_i(clk), .rst_n_i(rst_n), .stall_i(stall), .flush_i(flush),
    .pc_i(pc_i), .instr_i(instr_i), .rs1_data_i(32'd0), .rs2_data_i(32'd0), .imm_i(imm_i),
    .rs1_idx_i(rs1i), .rs2_idx_i(rs2i), .rd_i(rd_i), .funct3_i(3'd0),
    .reg_write_i(rw_i), .mem_read_i(mr_i), .mem_write_i(1'b0), .mem_to_reg_i(1'b0),
    .alu_src_i(1'b0), .pc_op_a_i(1'b0), .alu_op_i(4'd0), .branch_i(1'b0), .jal_i(1'b0),
    .jalr_i(1'b0), .predicted_taken_i(pt_i), .mul_en_i(1'b0), .dsu_en_i(dsu_i), .csr_en_i(1'b0),
    .csr_imm_i(1'b0), .csr_op_i(2'd0), .is_system_i(1'b0), .illegal_instr_dec_i(1'b0), .fault_i(1'b0),
    .pc_o(pc_o), .instr_o(instr_o), .rs1_data_o(), .rs2_data_o(), .imm_o(), .rs1_idx_o(), .rs2_idx_o(),
    .rd_o(rd_o), .funct3_o(), .reg_write_o(rw_o), .mem_read_o(mr_o), .mem_write_o(), .mem_to_reg_o(),
    .alu_src_o(), .pc_op_a_o(), .alu_op_o(), .branch_o(), .jal_o(), .jalr_o(), .predicted_taken_o(pt_o),
    .mul_en_o(), .dsu_en_o(dsu_o), .csr_en_o(), .csr_imm_o(), .csr_op_o(), .is_system_o(),
    .illegal_instr_dec_o(), .fault_o());
  always #5 clk=~clk;

  initial begin
    // ---- forward_unit vectors ----
    // no producers -> NONE
    fa_rs1=5'd5; fa_rs2=5'd6; fa_exrd=0; fa_exwe=0; fa_wbrd=0; fa_wbwe=0; #1;
    chk2("fwd_none_a",fa_sela,2'b00); chk2("fwd_none_b",fa_selb,2'b00);
    // EX/MEM hit on rs1
    fa_exrd=5'd5; fa_exwe=1; #1; chk2("fwd_exmem_a",fa_sela,2'b01);
    // MEM/WB hit on rs2 only
    fa_exrd=5'd9; fa_wbrd=5'd6; fa_wbwe=1; #1; chk2("fwd_memwb_b",fa_selb,2'b10);
    // both hit rs1 -> EX/MEM wins (priority)
    fa_exrd=5'd5; fa_exwe=1; fa_wbrd=5'd5; fa_wbwe=1; #1; chk2("fwd_priority",fa_sela,2'b01);
    // producer is x0 -> no forward
    fa_rs1=5'd0; fa_exrd=5'd0; fa_exwe=1; #1; chk2("fwd_x0",fa_sela,2'b00);
    // producer reg_write low -> no forward
    fa_rs1=5'd7; fa_exrd=5'd7; fa_exwe=0; fa_wbrd=5'd7; fa_wbwe=0; #1; chk2("fwd_nowe",fa_sela,2'b00);

    // ---- id_ex vectors ----
    rst_n=0; stall=0; flush=0; pc_i=32'hAAAA0000; instr_i=32'hDEADBEEF; imm_i=0;
    rd_i=5'd7; rs1i=0; rs2i=0; rw_i=1; mr_i=1; dsu_i=1; pt_i=1;
    @(negedge clk) rst_n=1;                 // reset released; outputs should be bubble
    chk1("rst_bubble_rw",rw_o,1'b0); chk1("rst_bubble_mr",mr_o,1'b0); chk32("rst_bubble_instr",instr_o,32'h13);
    @(negedge clk);                          // normal capture
    chk32("cap_pc",pc_o,32'hAAAA0000); chk32("cap_rd",{27'd0,rd_o},32'd7);
    chk1("cap_rw",rw_o,1'b1); chk1("cap_dsu",dsu_o,1'b1); chk1("cap_pt",pt_o,1'b1);
    // STALL holds: change inputs, assert stall, outputs must not move
    pc_i=32'h11112222; rd_i=5'd9; stall=1; @(negedge clk);
    chk32("stall_hold_pc",pc_o,32'hAAAA0000); chk32("stall_hold_rd",{27'd0,rd_o},32'd7);
    // release stall -> now captures new
    stall=0; @(negedge clk); chk32("stall_release_pc",pc_o,32'h11112222);
    // FLUSH bubbles even with valid inputs, and flush>stall
    rw_i=1; mr_i=1; dsu_i=1; flush=1; stall=1; @(negedge clk);
    chk1("flush_rw",rw_o,1'b0); chk1("flush_dsu",dsu_o,1'b0); chk32("flush_instr",instr_o,32'h13);

    if (errors==0) $display("ID_EX + FWD SMOKE: ALL CHECKS PASSED");
    else           $display("ID_EX + FWD SMOKE: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
