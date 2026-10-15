`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - core : properties of six more core units, from the RISC-V ISA and
// GARUDA-CORE-SPEC-001. The encodings are written as the ISA's literals, not the
// RTL's macros, so a wrong `define, a sign error or a wrong target formula fails.
//   branch_unit           RV32I conditional branches, JALR target, prediction check
//   forward_unit          EX/MEM before MEM/WB, never x0, only from a writing stage
//   hazard_forward_unit   the load-use stall
//   load_store_unit       sizes, misalignment (no misaligned access, CORE 14.1), byte lanes
//   garuda_pc_gen         redirect, fetch and commit PCs
//   garuda_prefetch_buffer  a FIFO: order kept, nothing lost, nothing invented, emptied by a redirect
// Bound to each unit; they run in every core run and are proved by flow/formal/run_blocks.sh.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module branch_unit_sva (
    input wire [31:0] pc, imm, rs1_fwd, rs2_fwd, redirect_target,
    input wire [2:0]  funct3,
    input wire        branch, jal, jalr, predicted_taken, branch_taken, mispredict, redirect, target_misaligned
);
    reg isa_taken;
    always @(*) begin
        case (funct3)                                   // RV32I B-type funct3
            3'b000: isa_taken = (rs1_fwd == rs2_fwd);                        // BEQ
            3'b001: isa_taken = (rs1_fwd != rs2_fwd);                        // BNE
            3'b100: isa_taken = ($signed(rs1_fwd) <  $signed(rs2_fwd));      // BLT
            3'b101: isa_taken = ($signed(rs1_fwd) >= $signed(rs2_fwd));      // BGE
            3'b110: isa_taken = (rs1_fwd <  rs2_fwd);                        // BLTU
            3'b111: isa_taken = (rs1_fwd >= rs2_fwd);                        // BGEU
            default: isa_taken = 1'b0;
        endcase
        if (!$isunknown({pc, imm, rs1_fwd, rs2_fwd, funct3, branch, jal, jalr, predicted_taken})) begin
            a_br_taken: assert #0 (!branch || funct3 inside {3'b010, 3'b011} || branch_taken == isa_taken)
                else $error("[SVA-FAIL] a_br_taken: funct3 %b gave taken=%b, the ISA says %b", funct3, branch_taken, isa_taken);
            a_br_mispredict: assert #0 (!branch || funct3 inside {3'b010, 3'b011} || mispredict == (isa_taken != predicted_taken))
                else $error("[SVA-FAIL] a_br_mispredict: misprediction flag wrong");
            a_jalr_target: assert #0 (!jalr || (redirect && redirect_target == ((rs1_fwd + imm) & ~32'd1)))
                else $error("[SVA-FAIL] a_jalr_target: JALR target is not (rs1 + imm) & ~1");
            a_br_target: assert #0 (!(branch && !jalr && mispredict) ||
                                    redirect_target == (isa_taken ? pc + imm : pc + 32'd4))
                else $error("[SVA-FAIL] a_br_target: a mispredicted branch does not go to pc+imm or pc+4");
            // no C extension: a taken target must be 4-byte aligned, or the fetch-misaligned trap
            a_target_misaligned: assert #0 (!(jalr) || target_misaligned == ((((rs1_fwd + imm) & ~32'd1) & 32'd3) != 0))
                else $error("[SVA-FAIL] a_target_misaligned: JALR misalignment flag wrong");
        end
    end
endmodule

module forward_unit_sva (
    input wire [4:0] id_ex_rs1_idx_i, id_ex_rs2_idx_i, exmem_rd_i, memwb_rd_i,
    input wire exmem_reg_write_i, memwb_reg_write_i,
    input wire [1:0] fwd_a_sel_o, fwd_b_sel_o
);
    function automatic [1:0] want(input [4:0] rs);
        want = (exmem_reg_write_i && exmem_rd_i != 0 && exmem_rd_i == rs) ? 2'b01 :      // EX/MEM is younger
               (memwb_reg_write_i && memwb_rd_i != 0 && memwb_rd_i == rs) ? 2'b10 : 2'b00;
    endfunction
    always @(*) if (!$isunknown({id_ex_rs1_idx_i, id_ex_rs2_idx_i, exmem_rd_i, memwb_rd_i, exmem_reg_write_i, memwb_reg_write_i})) begin
        a_fwd_a: assert #0 (fwd_a_sel_o == want(id_ex_rs1_idx_i))
            else $error("[SVA-FAIL] a_fwd_a: forwarding for rs1 wrong");
        a_fwd_b: assert #0 (fwd_b_sel_o == want(id_ex_rs2_idx_i))
            else $error("[SVA-FAIL] a_fwd_b: forwarding for rs2 wrong");
    end
endmodule

module hazard_forward_unit_sva (
    input wire [4:0] id_rs1_idx_i, id_rs2_idx_i, ex_rd_i, input wire ex_mem_read_i, load_use_stall_o
);
    always @(*) if (!$isunknown({id_rs1_idx_i, id_rs2_idx_i, ex_rd_i, ex_mem_read_i}))
        a_load_use: assert #0 (load_use_stall_o == (ex_mem_read_i && ex_rd_i != 0 &&
                                                    (ex_rd_i == id_rs1_idx_i || ex_rd_i == id_rs2_idx_i)))
            else $error("[SVA-FAIL] a_load_use: load-use stall wrong");
endmodule

module load_store_unit_sva (
    input wire [31:0] addr_i, rs2_data_i, hwdata_o, input wire [2:0] funct3_i, hsize_o,
    input wire load_misaligned_o, store_misaligned_o
);
    wire [1:0] sz = funct3_i[1:0];                      // LB/LBU/SB 00, LH/LHU/SH 01, LW/SW 10
    always @(*) if (!$isunknown({addr_i, funct3_i, rs2_data_i})) begin
        a_lsu_size: assert #0 (hsize_o == {1'b0, sz})
            else $error("[SVA-FAIL] a_lsu_size: HSIZE does not follow funct3");
        a_lsu_misaligned: assert #0 (load_misaligned_o == ((sz == 2'b01 && addr_i[0]) || (sz == 2'b10 && addr_i[1:0] != 0)) &&
                                    store_misaligned_o == load_misaligned_o)
            else $error("[SVA-FAIL] a_lsu_misaligned: misalignment flag wrong for size %b address %h", sz, addr_i);
        // the store data sits in the byte lanes the address selects (AHB-Lite little-endian)
        a_lsu_lanes: assert #0 ((sz == 2'b00) ? hwdata_o[8*addr_i[1:0] +: 8] == rs2_data_i[7:0] :
                                (sz == 2'b01) ? hwdata_o[16*addr_i[1] +: 16] == rs2_data_i[15:0] :
                                                hwdata_o == rs2_data_i)
            else $error("[SVA-FAIL] a_lsu_lanes: store data not in the addressed lanes");
    end
endmodule

module garuda_pc_gen_sva (
    input wire clk_i, rst_n_i, redirect_i, fetch_issue_i, commit_i,
    input wire [31:0] redirect_pc_i, commit_pc_i, pc_o, fetch_pc_o
);
    a_pc_redirect: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && redirect_i) |=> (pc_o == $past(redirect_pc_i) && fetch_pc_o == $past(redirect_pc_i)) )
        else $error("[SVA-FAIL] a_pc_redirect: a redirect did not move both PCs");
    a_pc_fetch_next: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && !redirect_i && fetch_issue_i) |=> fetch_pc_o == $past(fetch_pc_o) + 32'd4 )
        else $error("[SVA-FAIL] a_pc_fetch_next: the fetch PC did not advance by 4");
    a_pc_fetch_hold: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && !redirect_i && !fetch_issue_i) |=> $stable(fetch_pc_o) )
        else $error("[SVA-FAIL] a_pc_fetch_hold: the fetch PC moved without a fetch");
    a_pc_commit: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (rst_n_i && !redirect_i && commit_i) |=> pc_o == $past(commit_pc_i) + 32'd4 )
        else $error("[SVA-FAIL] a_pc_commit: the PC is not the committed one plus 4");
endmodule

module garuda_prefetch_buffer_sva (
    input wire clk_i, rst_n_i, redirect_i, wr_en_i, wr_fault_i, rd_en_i,
    input wire [31:0] wr_instr_i, wr_pc_i, instr_o, instr_pc_o,
    input wire instr_fault_o, instr_valid_o, full_o, empty_o, input wire [2:0] occupancy_o
);
    // the users' contract (assumed in formal): no write into a full buffer, no read from an empty one
    assume_no_overflow: assume property (@(posedge clk_i) disable iff (!rst_n_i) (full_o && !rd_en_i) |-> !wr_en_i);
    assume_no_underflow: assume property (@(posedge clk_i) disable iff (!rst_n_i) empty_o |-> !rd_en_i);
    // a reference queue of four entries
    reg [64:0] q [0:3]; reg [2:0] n;
    always @(posedge clk_i or negedge rst_n_i)
        if (!rst_n_i) n <= 3'd0;
        else if (redirect_i) n <= 3'd0;
        else begin
            if (rd_en_i && n != 0) begin q[0] <= q[1]; q[1] <= q[2]; q[2] <= q[3]; end
            if (wr_en_i) q[(rd_en_i && n != 0) ? n - 1 : n] <= {wr_fault_i, wr_pc_i, wr_instr_i};
            n <= n + (wr_en_i ? 3'd1 : 3'd0) - ((rd_en_i && n != 0) ? 3'd1 : 3'd0);
        end
    a_pfb_count: assert property (@(posedge clk_i) disable iff (!rst_n_i) occupancy_o == n && n <= 3'd4 )
        else $error("[SVA-FAIL] a_pfb_count: occupancy %0d, the reference holds %0d", occupancy_o, n);
    a_pfb_flags: assert property (@(posedge clk_i) disable iff (!rst_n_i) (empty_o == (n == 0)) && (full_o == (n == 4)) && (instr_valid_o == (n != 0)) )
        else $error("[SVA-FAIL] a_pfb_flags: empty/full/valid disagree with the occupancy");
    a_pfb_order: assert property (@(posedge clk_i) disable iff (!rst_n_i) (n != 0) |-> {instr_fault_o, instr_pc_o, instr_o} === q[0] )
        else $error("[SVA-FAIL] a_pfb_order: head %b %h %h, reference %h, n %0d", instr_fault_o, instr_pc_o, instr_o, q[0], n);
    a_pfb_redirect_empties: assert property (@(posedge clk_i) disable iff (!rst_n_i) redirect_i |=> empty_o )
        else $error("[SVA-FAIL] a_pfb_redirect_empties: a redirect left instructions in the buffer");
    c_pfb_full: cover property (@(posedge clk_i) full_o);
    c_pfb_wr_rd_full: cover property (@(posedge clk_i) full_o && wr_en_i && rd_en_i);
endmodule

bind branch_unit branch_unit_sva u_branch_unit_sva (.*);
bind forward_unit forward_unit_sva u_forward_unit_sva (.*);
bind hazard_forward_unit hazard_forward_unit_sva u_hazard_sva (.*);
bind load_store_unit load_store_unit_sva u_lsu_sva (.*);
bind garuda_pc_gen garuda_pc_gen_sva u_pc_gen_sva (.*);
bind garuda_prefetch_buffer garuda_prefetch_buffer_sva u_pfb_sva (.*);
`endif
`endif
