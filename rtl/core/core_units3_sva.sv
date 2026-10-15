`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - core : properties of the instruction port, the static branch
// predictor and the CSR field split, from GARUDA-CORE-SPEC-001, the RISC-V ISA and
// AHB-Lite. Bound to each unit; proved by flow/formal/run_blocks.sh.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module garuda_iport_sva #(parameter FIFO_DEPTH = 4) (
    input wire clk_i, rst_n_i, redirect_i, fifo_rd_en_i,
    input wire [31:0] fetch_pc_i, input wire [2:0] fifo_occupancy_i,
    input wire [31:0] i_haddr_o, input wire [1:0] i_htrans_o, input wire [2:0] i_hsize_o, i_hburst_o,
    input wire i_hwrite_o, i_hready_i, i_hresp_i, fetch_issue_o, data_valid_o
);
    // surroundings: the prefetch buffer never claims more than its depth, the slave's ERROR is two
    // cycles. (The fetch PC is NOT always aligned: a jump to a misaligned target puts it there for a
    // cycle while the cause-0 trap takes over, T-1 and riscv-tests ma_fetch; the IF-stage proof
    // states what the core supplies instead, see flow/formal/run_blocks.sh if_stage.)
    assume_occ_bound: assume property (@(posedge clk_i) disable iff (!rst_n_i) fifo_occupancy_i <= FIFO_DEPTH);
    assume_slave_err2: assume property (@(posedge clk_i) disable iff (!rst_n_i) (i_hresp_i && !i_hready_i) |=> (i_hresp_i && i_hready_i));

    // AHB-Lite, instruction fetch: read only, words, INCR bursts
    a_ip_fixed: assert property (@(posedge clk_i) disable iff (!rst_n_i) !i_hwrite_o && i_hsize_o == 3'b010 && i_hburst_o == 3'b001 )
        else $error("[SVA-FAIL] a_ip_fixed: the I-port is not a word-read INCR master");
    a_ip_no_busy: assert property (@(posedge clk_i) disable iff (!rst_n_i) i_htrans_o != 2'b01 )
        else $error("[SVA-FAIL] a_ip_no_busy: BUSY issued");
    a_ip_aligned: assert property (@(posedge clk_i) disable iff (!rst_n_i) i_htrans_o[1] |-> i_haddr_o[1:0] == 2'b00 )
        else $error("[SVA-FAIL] a_ip_aligned: an unaligned fetch");
    // an address phase is held until accepted (a redirect does not withdraw it)
    a_ip_addr_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (i_htrans_o[1] && !i_hready_i) |=> ($stable(i_haddr_o) && $stable(i_htrans_o)) )
        else $error("[SVA-FAIL] a_ip_addr_stable: the fetch address phase changed before acceptance");
    // a SEQ beat is the next word after the last accepted beat, inside the same 1 KB (AHB-Lite 3.5)
    reg [31:0] last_addr; reg last_v;
    always @(posedge clk_i or negedge rst_n_i)
        if (!rst_n_i) last_v <= 1'b0;
        else if (i_hready_i) begin last_v <= i_htrans_o[1]; last_addr <= i_haddr_o; end
    a_ip_seq_next_word: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        i_htrans_o == 2'b11 |-> (last_v && i_haddr_o == last_addr + 32'd4 && i_haddr_o[9:0] != 10'd0) )
        else $error("[SVA-FAIL] a_ip_seq_next_word: a SEQ beat that is not the next word of the burst");
    // nothing is accepted into the prefetch buffer when it is full and not being read
    a_ip_no_overflow: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        data_valid_o |-> (fifo_occupancy_i < FIFO_DEPTH || fifo_rd_en_i) )
        else $error("[SVA-FAIL] a_ip_no_overflow: an instruction delivered into a full prefetch buffer");
    // a redirect discards: no instruction is delivered in the cycle of a redirect
    a_ip_redirect_quiet: assert property (@(posedge clk_i) disable iff (!rst_n_i) redirect_i |-> !data_valid_o )
        else $error("[SVA-FAIL] a_ip_redirect_quiet: an instruction delivered in the cycle of a redirect");
    c_ip_seq: cover property (@(posedge clk_i) i_htrans_o == 2'b11 && i_hready_i);
    c_ip_redirect_in_wait: cover property (@(posedge clk_i) redirect_i && i_htrans_o[1] && !i_hready_i);
endmodule

module branch_predict_sva (
    input wire [31:0] pc_i, imm_b_i, imm_j_i, input wire branch_i, jal_i, fencei_i,
    input wire bp_dis_i,   // CORE-4 mgarudactl.BP_DIS (track A, 2026-10-15)
    input wire predict_taken_o, id_redirect_valid_o, input wire [31:0] id_redirect_target_o
);
    always @(*) if (!$isunknown({pc_i, imm_b_i, imm_j_i, branch_i, jal_i, fencei_i, bp_dis_i})) begin
        // CORE: static backward-taken, forward-not-taken; CORE-4: BP_DIS predicts every branch not-taken
        a_bp_btfn: assert #0 (predict_taken_o == (branch_i && imm_b_i[31] && !bp_dis_i))
            else $error("[SVA-FAIL] a_bp_btfn: the static prediction is not backward-taken");
        a_bp_jal: assert #0 (!(jal_i && !fencei_i) || (id_redirect_valid_o && id_redirect_target_o == pc_i + imm_j_i))
            else $error("[SVA-FAIL] a_bp_jal: JAL does not redirect to pc + J-imm in ID");
        a_bp_taken: assert #0 (!(predict_taken_o && !jal_i && !fencei_i) || id_redirect_target_o == pc_i + imm_b_i)
            else $error("[SVA-FAIL] a_bp_taken: a predicted-taken branch does not go to pc + B-imm");
        a_bp_fencei: assert #0 (!fencei_i || (id_redirect_valid_o && id_redirect_target_o == pc_i + 32'd4))
            else $error("[SVA-FAIL] a_bp_fencei: FENCE.I does not refetch from pc + 4");
        a_bp_none: assert #0 ((branch_i && imm_b_i[31] && !bp_dis_i) || jal_i || fencei_i || !id_redirect_valid_o)
            else $error("[SVA-FAIL] a_bp_none: an ID redirect with nothing to redirect for");
    end
endmodule

module csr_rw_sva (
    input wire [31:0] instr, rs1_fwd, csr_wdata, input wire csr_imm, input wire [11:0] csr_addr
);
    always @(*) if (!$isunknown({instr, rs1_fwd, csr_imm}))
        a_csr_fields: assert #0 (csr_addr == instr[31:20] && csr_wdata == (csr_imm ? {27'd0, instr[19:15]} : rs1_fwd))
            else $error("[SVA-FAIL] a_csr_fields: CSR address or operand is not the ISA's (uimm zero-extended)");
endmodule

bind garuda_iport_ahb_master garuda_iport_sva #(.FIFO_DEPTH(FIFO_DEPTH)) u_iport_sva (.*);
bind branch_predict branch_predict_sva u_bp_sva (.*);
bind csr_rw csr_rw_sva u_csr_rw_sva (.*);
`endif
`endif
