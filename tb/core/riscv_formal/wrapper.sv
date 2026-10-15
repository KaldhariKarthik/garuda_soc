// wrapper.sv -- riscv-formal wrapper for garuda_core_top (Karthik's plan 5.6).
// The solver chooses every instruction word and the bus timing (HREADY) on both
// ports. Assumptions (also in tb/core/formal/ASSUMPTIONS.md, FA-RVF-*):
//   FA-RVF-1  bus responses are OKAY: riscv-formal's ISA model has no bus
//             faults (assert spec_trap == trap); fault handling is verified by
//             the simulations (t_cov_fault, t_buserr) and fv_trap (T-13, T-17)
//   FA-RVF-2  no interrupts, no debug halt: entries are not instructions; they
//             are verified by fv_trap / fv_rdc1 and the directed tests
//   FA-RVF-3  no WFI: without an interrupt a WFI waits forever, which the
//             liveness and instruction checks would read as a hang
//   FA-RVF-4  liveness only (GARUDA_FAIRNESS): HREADY is low for at most 3
//             cycles in a row on each port
module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
    (* keep *) `rvformal_rand_reg [31:0] i_hrdata;
    (* keep *) `rvformal_rand_reg        i_hready;
    (* keep *) `rvformal_rand_reg [31:0] d_hrdata;
    (* keep *) `rvformal_rand_reg        d_hready;

    (* keep *) wire [31:0] i_haddr, d_haddr, d_hwdata;
    (* keep *) wire [1:0]  i_htrans, d_htrans;
    (* keep *) wire        d_hwrite;

    garuda_core_top uut (
        .clk_i(clock), .core_rst_n_i(!reset), .hartreset_n_i(1'b1),
        .halt_req_i(1'b0), .halt_safe_o(),
        .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(), .i_hburst_o(), .i_hprot_o(),
        .i_hwrite_o(), .i_hwdata_o(), .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(1'b0),
        .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(), .d_hburst_o(), .d_hprot_o(),
        .d_hwrite_o(d_hwrite), .d_hwdata_o(d_hwdata), .d_hrdata_i(d_hrdata), .d_hready_i(d_hready),
        .d_hresp_i(1'b0),
        .clic_irq_valid_i(1'b0), .clic_irq_id_i(5'd0), .clic_irq_level_i(8'd0), .mtip_i(1'b0),
        .dbg_acc_0_o(), .dbg_acc_1_o(), .dbg_acc_2_o(), .dsu_ovf_o(), .core_sleep_o(),
        `RVFI_CONN
    );

    always @* if (!reset) assume (i_hrdata != 32'h10500073);      // FA-RVF-3: no WFI

`ifdef GARUDA_FAIRNESS
    reg [1:0] i_wait = 0, d_wait = 0;                              // FA-RVF-4
    always @(posedge clock) begin
        i_wait <= i_hready ? 2'd0 : i_wait + 2'd1;
        d_wait <= d_hready ? 2'd0 : d_wait + 2'd1;
    end
    always @* begin
        assume (i_wait != 2'd3 || i_hready);
        assume (d_wait != 2'd3 || d_hready);
    end
`endif
endmodule
