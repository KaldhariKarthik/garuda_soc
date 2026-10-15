`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - core : properties of four core units, from GARUDA-CORE-SPEC-001
// core_units_sva.sv
//   clic_ctrl    [N-7.15] [N-7.16] [N-7.27]   the take and wake conditions
//   d_port       AHB-Lite master, one transfer at a time, section 11.4 stall
//   csr_file     traps, MRET, the interrupt-level stack, read-only and absent CSRs
//   regfile      x0 reads 0, a read returns the last write, the WB->ID bypass
// Bound to each unit; they run in every core, sanity and chip run, and are the
// property sets of flow/formal/run_blocks.sh (clic_ctrl, d_port, csr_file, regfile).
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module clic_ctrl_sva #(parameter ID_W = 5) (
    input wire clic_irq_valid_i, mstatus_mie_i, take_cond_o, wake_cond_o,
    input wire [7:0] clic_irq_level_i, mintthresh_i, mintstatus_mil_i,
    input wire [31:0] mtvec_i, vector_target_o
);
    // combinational unit: checked whenever an input changes, and by the proof
    always @(*) begin
        // [N-7.15], [N-7.16] strictly greater than the threshold and than the active level, with MIE
        a_take: assert #0 (take_cond_o == (clic_irq_valid_i && mstatus_mie_i &&
                           clic_irq_level_i > mintthresh_i && clic_irq_level_i > mintstatus_mil_i))
            else $error("[SVA-FAIL] a_take: take condition wrong");
        // [N-7.27] WFI wakes on a pending interrupt whatever MIE says
        a_wake: assert #0 (wake_cond_o == clic_irq_valid_i)
            else $error("[SVA-FAIL] a_wake: wake condition depends on more than a pending interrupt");
        a_equal_never_preempts: assert #0 (!(clic_irq_level_i == mintstatus_mil_i && take_cond_o))
            else $error("[SVA-FAIL] a_equal_never_preempts: an equal level preempted");
    end
endmodule

module d_port_sva (
    input wire clk_i, rst_n_i, start_i, hwrite_i,
    input wire [31:0] addr_i, hwdata_i,
    input wire [2:0] hsize_i,
    input wire [1:0] d_htrans_o, input wire [31:0] d_haddr_o, d_hwdata_o, input wire d_hwrite_o,
    input wire d_hready_i, d_hresp_i, mem_stall_o, ok_done_o, err_pulse_o,
    input wire [1:0] state
);
    // what the core guarantees (assumed in formal): an access is presented aligned and held
    // while the port stalls the pipeline
    assume_aligned: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        start_i |-> ((hsize_i == 3'd2) ? addr_i[1:0] == 2'b00 : (hsize_i == 3'd1) ? !addr_i[0] : 1'b1) && hsize_i <= 3'd2);
    assume_held: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        (state == 2'd0 && start_i && !d_hready_i) |=> (start_i && $stable({addr_i, hwrite_i, hsize_i, hwdata_i})));
    assume_slave_err2: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        (d_hresp_i && !d_hready_i) |=> (d_hresp_i && d_hready_i));
    assume_slave_idle_okay: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        state == 2'd0 |-> !d_hresp_i);

    a_dport_single: assert property (@(posedge clk_i) disable iff (!rst_n_i) d_htrans_o == 2'b00 || d_htrans_o == 2'b10 )
        else $error("[SVA-FAIL] a_dport_single: the D-port issued SEQ or BUSY");
    a_dport_one_at_a_time: assert property (@(posedge clk_i) disable iff (!rst_n_i) state == 2'd1 |-> d_htrans_o == 2'b00 )
        else $error("[SVA-FAIL] a_dport_one_at_a_time: a new address phase during a data phase");
    a_dport_addr_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (d_htrans_o[1] && !d_hready_i) |=> ($stable({d_haddr_o, d_htrans_o, d_hwrite_o})) )
        else $error("[SVA-FAIL] a_dport_addr_stable: the address phase changed before it was accepted");
    a_dport_wdata: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (d_htrans_o[1] && d_hwrite_o && d_hready_i) |=> d_hwdata_o === $past(hwdata_i) )
        else $error("[SVA-FAIL] a_dport_wdata: the write data phase does not carry the store's data");
    a_dport_result_once: assert property (@(posedge clk_i) disable iff (!rst_n_i) !(ok_done_o && err_pulse_o) )
        else $error("[SVA-FAIL] a_dport_result_once: OKAY and ERROR together");
    a_dport_result_only_data: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (ok_done_o || err_pulse_o) |-> (state == 2'd1 && d_hready_i) )
        else $error("[SVA-FAIL] a_dport_result_only_data: a result outside a data phase");
    // section 11.4: the pipeline is held from the address phase until the data phase ends
    a_dport_stall: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        mem_stall_o == ((state == 2'd0 && start_i) || (state == 2'd1 && !d_hready_i)) )
        else $error("[SVA-FAIL] a_dport_stall: the D-port stall does not cover its transfer");
    c_dport_write_wait: cover property (@(posedge clk_i) state == 2'd1 && !d_hready_i && d_hwrite_o == 1'b0);
    c_dport_error:      cover property (@(posedge clk_i) err_pulse_o);
endmodule

module csr_file_sva (
    input wire clk_i, rst_n_i, trap_enter_i, mret_i, is_interrupt_i,
    input wire csr_en_i, commit_i, illegal_csr_o,
    input wire [11:0] csr_addr_i, input wire [1:0] csr_op_i, input wire [31:0] csr_wdata_i,
    input wire [7:0] clic_level_i,
    input wire [31:0] trap_pc_i, trap_cause_i,
    input wire mstatus_mie, mstatus_mpie,
    input wire [7:0] mil_r, mpil_r,
    input wire [31:0] mepc_r, mcause_r
);
    // what trap_ctrl guarantees: a trap and an MRET never in the same cycle
    assume_not_both: assume property (@(posedge clk_i) disable iff (!rst_n_i) !(trap_enter_i && mret_i));

    // privileged spec 3.1.6.1: a trap saves MIE into MPIE and clears MIE; MRET restores it and sets MPIE
    a_trap_mie: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        trap_enter_i |=> (!mstatus_mie && mstatus_mpie == $past(mstatus_mie)) )
        else $error("[SVA-FAIL] a_trap_mie: MIE/MPIE wrong after a trap");
    a_mret_mie: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        mret_i |=> (mstatus_mie == $past(mstatus_mpie) && mstatus_mpie) )
        else $error("[SVA-FAIL] a_mret_mie: MIE/MPIE wrong after MRET");
    a_trap_mepc_mcause: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        trap_enter_i |=> (mepc_r == $past(trap_pc_i) && mcause_r == $past(trap_cause_i)) )
        else $error("[SVA-FAIL] a_trap_mepc_mcause: MEPC or MCAUSE not taken from the trap");
    // CORE 14.3, 14.4: an interrupt pushes the level, MRET pops it; an exception leaves it
    a_irq_push: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (trap_enter_i && is_interrupt_i) |=> (mil_r == $past(clic_level_i) && mpil_r == $past(mil_r)) )
        else $error("[SVA-FAIL] a_irq_push: the interrupt level was not pushed");
    a_exc_keeps_level: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (trap_enter_i && !is_interrupt_i) |=> $stable({mil_r, mpil_r}) )
        else $error("[SVA-FAIL] a_exc_keeps_level: an exception changed the interrupt level");
    a_mret_pop: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        mret_i |=> mil_r == $past(mpil_r) )
        else $error("[SVA-FAIL] a_mret_pop: MRET did not restore the interrupt level");
    // CORE 6.1: a write to a read-only CSR, and any access to an absent one, is illegal
    wire access = csr_en_i && csr_op_i != 2'b00;
    wire writes = access && (csr_op_i == 2'b01 || csr_wdata_i != 32'd0);
    wire ro = csr_addr_i inside {12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'h344, 12'hBC0, 12'hC00, 12'hC80, 12'hC02, 12'hC82, 12'hFB1};
    a_ro_write_illegal: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (writes && ro) |-> illegal_csr_o )
        else $error("[SVA-FAIL] a_ro_write_illegal: a write to read-only CSR %h was accepted", csr_addr_i);
    a_absent_illegal: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (access && csr_addr_i[11:8] == 4'h7) |-> illegal_csr_o )
        else $error("[SVA-FAIL] a_absent_illegal: an access to a debug-mode CSR %h was accepted", csr_addr_i);
    a_read_legal: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        (access && !writes && csr_addr_i inside {12'h300, 12'h304, 12'h305, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344, 12'hF14}) |-> !illegal_csr_o )
        else $error("[SVA-FAIL] a_read_legal: a read of implemented CSR %h was refused", csr_addr_i);
endmodule

module regfile_sva (
    input wire clk_i, rst_n_i, wb_reg_write_i,
    input wire [4:0] rs1_idx_i, rs2_idx_i, wb_rd_i,
    input wire [31:0] wb_data_i, rs1_data_o, rs2_data_o
);
    // a shadow copy of the 31 registers, written when the port writes
    reg [31:0] shadow [1:31]; reg [31:1] known = 31'd0;
    always @(posedge clk_i or negedge rst_n_i)
        if (!rst_n_i) known <= 31'd0;                       // a proof has no initial values, only reset
        else if (wb_reg_write_i && wb_rd_i != 5'd0) begin shadow[wb_rd_i] <= wb_data_i; known[wb_rd_i] <= 1'b1; end
    a_x0_rs1: assert property (@(posedge clk_i) rs1_idx_i == 5'd0 |-> rs1_data_o == 32'd0 )
        else $error("[SVA-FAIL] a_x0_rs1: x0 read non-zero");
    a_x0_rs2: assert property (@(posedge clk_i) rs2_idx_i == 5'd0 |-> rs2_data_o == 32'd0 )
        else $error("[SVA-FAIL] a_x0_rs2: x0 read non-zero");
    // [N-7.4] a register written this cycle reads as the new value (WB->ID bypass)
    a_bypass_rs1: assert property (@(posedge clk_i)
        (wb_reg_write_i && wb_rd_i != 5'd0 && wb_rd_i == rs1_idx_i) |-> rs1_data_o === wb_data_i )
        else $error("[SVA-FAIL] a_bypass_rs1: a same-cycle write was not bypassed to rs1");
    // otherwise it reads the last value written
    a_read_last_rs1: assert property (@(posedge clk_i)
        (rs1_idx_i != 5'd0 && known[rs1_idx_i] && !(wb_reg_write_i && wb_rd_i == rs1_idx_i)) |-> rs1_data_o === shadow[rs1_idx_i] )
        else $error("[SVA-FAIL] a_read_last_rs1: x%0d read %h, last written %h", rs1_idx_i, rs1_data_o, shadow[rs1_idx_i]);
    a_read_last_rs2: assert property (@(posedge clk_i)
        (rs2_idx_i != 5'd0 && known[rs2_idx_i] && !(wb_reg_write_i && wb_rd_i == rs2_idx_i)) |-> rs2_data_o === shadow[rs2_idx_i] )
        else $error("[SVA-FAIL] a_read_last_rs2: x%0d read %h, last written %h", rs2_idx_i, rs2_data_o, shadow[rs2_idx_i]);
endmodule

bind clic_ctrl clic_ctrl_sva #(.ID_W(ID_W)) u_clic_ctrl_sva (.*);
bind d_port_ahb_master d_port_sva u_d_port_sva (.*, .state(state));
bind csr_file csr_file_sva u_csr_file_sva (.*, .mstatus_mie(mstatus_mie), .mstatus_mpie(mstatus_mpie),
    .mil_r(mil_r), .mpil_r(mpil_r), .mepc_r(mepc_r), .mcause_r(mcause_r));
bind regfile regfile_sva u_regfile_sva (.*);
`endif
`endif
