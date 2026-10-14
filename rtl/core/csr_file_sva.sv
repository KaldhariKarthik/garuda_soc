`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 1 : simulation/formal properties for csr_file
// csr_file_sva.sv
//
// Bound into every csr_file instance (all core simulations) and proven at
// csr_file level by SymbiYosys (tb/core/formal/csr_file.toml). Portable subset
// (Docs/handbook/H4_coding.md): boolean properties, one cover per antecedent.
//
//   T-12  the interrupt-level stack, one step at a time (DN-T12):
//         a_trap_pushes_mpil, a_clic_int_sets_mil, a_exc_mti_keep_mil,
//         a_mret_pops_mil, a_mil_only_by_trap_or_mret, a_mintstatus_layouts
//   C-16  the read-zero CSRs of Design_Docs/regs/core_csr.yaml read 0 and never
//         trap; mconfigptr (read-only by address) traps on a write only:
//         a_readzero_reads_0, a_readzero_rw_no_trap, a_mconfigptr_read_ok,
//         a_mconfigptr_write_traps
// =============================================================================
`ifdef FORMAL
  `define GARUDA_CSR_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_CSR_SVA
`endif

`ifdef GARUDA_CSR_SVA
module csr_file_sva (
    input wire        clk,
    input wire        rst_n,
    input wire        csr_en,
    input wire [1:0]  csr_op,
    input wire [11:0] csr_addr,
    input wire        is_write,       // csr_file's own decode of a writing access
    input wire [31:0] csr_rdata,
    input wire        illegal,
    // T-12: the trap port and the level state
    input wire        trap_enter,
    input wire        mret,
    input wire        is_int,
    input wire [7:0]  lvl,
    input wire [31:0] cause,
    input wire [7:0]  mil,
    input wire [31:0] mcause,
    input wire [3:0]  ctl
);
    // ---- T-12: compare each cycle's level state with the previous cycle ----
    reg        qv, q_trap, q_mret, q_int;
    reg [7:0]  q_lvl, q_mil;
    reg [31:0] q_cause, q_mcause;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            qv <= 1'b0; q_trap <= 1'b0; q_mret <= 1'b0; q_int <= 1'b0;
            q_lvl <= 8'd0; q_mil <= 8'd0; q_cause <= 32'd0; q_mcause <= 32'd0;
        end else begin
            qv <= 1'b1; q_trap <= trap_enter; q_mret <= mret; q_int <= is_int;
            q_lvl <= lvl; q_mil <= mil; q_cause <= cause; q_mcause <= mcause;
        end
    wire q_clic = q_int && (q_lvl != 8'd0);

    a_trap_pushes_mpil: assert property (@(posedge clk) disable iff (!rst_n)
        !(qv && q_trap) || (mcause == {q_cause[31:24], q_mil, q_cause[15:0]}))
        else $error("[SVA-FAIL] T-12: a trap did not save the level it left in mcause[23:16]");
    a_clic_int_sets_mil: assert property (@(posedge clk) disable iff (!rst_n)
        !(qv && q_trap && q_clic) || (mil == q_lvl))
        else $error("[SVA-FAIL] T-12: a CLIC interrupt did not enter at its level");
    a_exc_mti_keep_mil: assert property (@(posedge clk) disable iff (!rst_n)
        !(qv && q_trap && !q_clic) || (mil == q_mil))
        else $error("[SVA-FAIL] T-12: an exception or MTI changed the interrupt level");
    a_mret_pops_mil: assert property (@(posedge clk) disable iff (!rst_n)
        !(qv && !q_trap && q_mret) || (mil == q_mcause[23:16]))
        else $error("[SVA-FAIL] T-12: mret did not restore the level from mcause[23:16]");
    a_mil_only_by_trap_or_mret: assert property (@(posedge clk) disable iff (!rst_n)
        !(qv && !q_trap && !q_mret) || (mil == q_mil))
        else $error("[SVA-FAIL] T-12: the interrupt level changed without a trap or mret");

    c_nested_interrupt:   cover property (@(posedge clk) disable iff (!rst_n) qv && q_trap && q_clic && q_mil != 8'd0);
    c_exception_in_handler: cover property (@(posedge clk) disable iff (!rst_n) qv && q_trap && !q_int && q_mil != 8'd0);
    c_mti_in_handler:     cover property (@(posedge clk) disable iff (!rst_n) qv && q_trap && q_int && q_lvl == 8'd0 && q_mil != 8'd0);
    c_mret_to_nonzero:    cover property (@(posedge clk) disable iff (!rst_n) qv && !q_trap && q_mret && q_mcause[23:16] != 8'd0);

    wire access = csr_en && (csr_op != 2'b00);
    wire rz = (csr_addr == 12'h310) || (csr_addr == 12'hF15) ||
              (csr_addr >= 12'hB03 && csr_addr <= 12'hB1F) ||
              (csr_addr >= 12'hB83 && csr_addr <= 12'hB9F) ||
              (csr_addr >= 12'h323 && csr_addr <= 12'h33F);
    wire mconfigptr = (csr_addr == 12'hF15);

    // CORE-4: mgarudactl reads its 4 bits, never traps
    a_mgarudactl_read: assert property (@(posedge clk) disable iff (!rst_n)
        !(access && csr_addr == 12'h7C0) || (csr_rdata == {28'd0, ctl} && !illegal))
        else $error("[SVA-FAIL] CORE-4: mgarudactl read or decode wrong");
    c_mgarudactl_write: cover property (@(posedge clk) disable iff (!rst_n) access && csr_addr == 12'h7C0 && is_write);

    a_mintstatus_layouts: assert property (@(posedge clk) disable iff (!rst_n)
        !(access && (csr_addr == 12'h346 || csr_addr == 12'hFB1)) ||
        (csr_rdata == ((csr_addr == 12'h346) ? {24'd0, mil} : {mil, 24'd0})))
        else $error("[SVA-FAIL] T-12: mintstatus read layout (0x346 {24'b0,mil}; 0xFB1 {mil,24'b0})");

    a_readzero_reads_0: assert property (@(posedge clk) disable iff (!rst_n)
        !(access && rz) || (csr_rdata == 32'd0))
        else $error("[SVA-FAIL] C-16: a read-zero CSR read non-zero");
    a_readzero_rw_no_trap: assert property (@(posedge clk) disable iff (!rst_n)
        !(access && rz && !mconfigptr) || !illegal)
        else $error("[SVA-FAIL] C-16: an access to a read-zero CSR trapped");
    a_mconfigptr_read_ok: assert property (@(posedge clk) disable iff (!rst_n)
        !(access && mconfigptr && !is_write) || !illegal)
        else $error("[SVA-FAIL] C-16: a read of mconfigptr trapped");
    a_mconfigptr_write_traps: assert property (@(posedge clk) disable iff (!rst_n)
        !(access && mconfigptr && is_write) || illegal)
        else $error("[SVA-FAIL] C-16: a write to the read-only mconfigptr did not trap");

    c_rz_read:          cover property (@(posedge clk) disable iff (!rst_n) access && rz && !is_write);
    c_rz_write:         cover property (@(posedge clk) disable iff (!rst_n) access && rz && !mconfigptr && is_write);
    c_mconfigptr_read:  cover property (@(posedge clk) disable iff (!rst_n) access && mconfigptr && !is_write);
    c_mconfigptr_write: cover property (@(posedge clk) disable iff (!rst_n) access && mconfigptr && is_write);
endmodule

bind csr_file csr_file_sva u_csr_sva (
    .clk      (clk_i),
    .rst_n    (rst_n_i),
    .csr_en   (csr_en_i),
    .csr_op   (csr_op_i),
    .csr_addr (csr_addr_i),
    .is_write (is_write),
    .csr_rdata(csr_rdata_o),
    .illegal  (illegal_csr_o),
    .trap_enter(trap_enter_i),
    .mret     (mret_i),
    .is_int   (is_interrupt_i),
    .lvl      (clic_level_i),
    .cause    (trap_cause_i),
    .mil      (mil_r),
    .mcause   (mcause_r),
    .ctl      (ctl_r)
);
`endif
