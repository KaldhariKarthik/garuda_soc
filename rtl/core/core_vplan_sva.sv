`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 1 : core properties the vPlan names and no other file had
// core_vplan_sva.sv  (Track A wrap-up, 2026-10-12; found by vplan_trace core)
//
//   a_reset_pc       F36 [N-7.34]: the first address on the instruction port
//                    after reset is the boot ROM base (RESET_VECTOR)
//   a_mem_completes  F29 [N-7.19..26]: a load whose data phase completed without
//                    ERROR writes its register within two cycles: no hold, flush
//                    or trap loses it (a store's data phase cannot be abandoned
//                    by AHB-Lite; ahb_lite_checker watches that)
//   a_wake_latency   F35 [N-7.30]: with a wake condition present (a pending,
//                    locally enabled CLIC or timer interrupt) the core is never
//                    quiescent and its WFI hold is released: the gate opens in the
//                    wake cycle and the pipeline moves on in the next
// Portable subset (H4): boolean asserts with helper registers, no |->; one
// cover per antecedent. Bound in every core simulation (rtl/core/filelist_core.f).
// =============================================================================
`ifdef FORMAL
  `define GARUDA_CORE_VPLAN_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_CORE_VPLAN_SVA
`endif

`ifdef GARUDA_CORE_VPLAN_SVA
module core_vplan_sva #(
    parameter [31:0] RESET_VECTOR = 32'h1000_0000
)(
    input wire        clk, rst_n,
    input wire [1:0]  i_htrans, d_htrans,
    input wire [31:0] i_haddr,
    input wire        d_hready, d_hresp, d_hwrite,
    input wire        mem_reg_write,
    input wire [4:0]  mem_rd,
    input wire        rf_we,
    input wire [4:0]  rf_rd,
    input wire        wake, quiescent, wfi_hold
);
    // ---- reset PC -----------------------------------------------------------------
    reg seen_fetch;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) seen_fetch <= 1'b0; else if (i_htrans[1]) seen_fetch <= 1'b1;
    a_reset_pc: assert property (@(posedge clk) disable iff (!rst_n)
        !(i_htrans[1] && !seen_fetch) || i_haddr == RESET_VECTOR)
        else $error("[SVA-FAIL] a_reset_pc: first fetch at %08h, expected %08h (F36)", i_haddr, RESET_VECTOR);
    c_first_fetch: cover property (@(posedge clk) disable iff (!rst_n) i_htrans[1] && !seen_fetch);

    // ---- a completed load writes back -------------------------------------------------
    reg       dph_rd;                        // a D-port read data phase is pending
    reg       pend;                          // a completed load owes its register write
    reg [4:0] pend_rd;
    reg [1:0] pend_age;
    wire      load_ok = dph_rd && d_hready && !d_hresp;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            dph_rd <= 1'b0; pend <= 1'b0; pend_rd <= 5'd0; pend_age <= 2'd0;
        end else begin
            if (d_hready) dph_rd <= d_htrans[1] && !d_hwrite;
            if (pend && rf_we && rf_rd == pend_rd) pend <= 1'b0;
            else if (pend) pend_age <= pend_age + 2'd1;
            if (load_ok && mem_reg_write && mem_rd != 5'd0) begin
                pend <= 1'b1; pend_rd <= mem_rd; pend_age <= 2'd0;
            end
        end
    a_mem_completes: assert property (@(posedge clk) disable iff (!rst_n)
        !(pend && pend_age >= 2'd2))
        else $error("[SVA-FAIL] a_mem_completes: the load to x%0d completed on the bus but did not write back (F29)", pend_rd);
    c_load_wb: cover property (@(posedge clk) disable iff (!rst_n) load_ok && mem_reg_write && mem_rd != 5'd0);

    // ---- wake latency ---------------------------------------------------------------------
    a_wake_latency: assert property (@(posedge clk) disable iff (!rst_n)
        !(wake && (quiescent || wfi_hold)))
        else $error("[SVA-FAIL] a_wake_latency: wake condition present but the core is still asleep / held (F35)");
    reg q_q;
    always @(posedge clk or negedge rst_n) if (!rst_n) q_q <= 1'b0; else q_q <= quiescent;
    c_wake_from_sleep: cover property (@(posedge clk) disable iff (!rst_n) q_q && wake);
endmodule

bind garuda_core_top core_vplan_sva #(.RESET_VECTOR(RESET_VECTOR)) u_core_vplan_sva (
    .clk(clk_i), .rst_n(rst_n_i),
    .i_htrans(i_htrans_o), .d_htrans(d_htrans_o), .i_haddr(i_haddr_o),
    .d_hready(d_hready_i), .d_hresp(d_hresp_i), .d_hwrite(d_hwrite_o),
    .mem_reg_write(mem_reg_write), .mem_rd(mem_rd), .rf_we(rf_we), .rf_rd(rf_rd),
    .wake(clic_wake_cond | csr_mti_pending), .quiescent(quiescent), .wfi_hold(tr_wfi_hold));
`endif
