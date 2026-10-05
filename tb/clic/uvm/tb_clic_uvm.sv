`timescale 1ns/1ps
`include "garuda_map.vh"
// =============================================================================
// tb_clic_uvm.sv - testbench top for the CLIC UVM environment.
//
//   +UVM_TESTNAME=clic_reg_test | clic_random_test | clic_directed_test
//   +NTX=<n>   number of random source patterns (clic_random_test)
//
// The DUT is clic_top as the SoC instantiates it: the enable mask is the
// generated GARUDA_CLIC_ID_MASK. The properties in rtl/clic/clic_sva.sv are
// bound to it, and the APB protocol checker watches its register port.
// =============================================================================
module tb_clic_uvm;
    import uvm_pkg::*;
    import clic_env_pkg::*;

    // hclk and pclk = hclk/2 from one process with blocking assignments, so both
    // edges are in the same simulator step (see BUGS.md SIM-1)
    logic hclk = 0, pclk = 0;
    initial forever begin
        #2 hclk = 1'b1; pclk = ~pclk;
        #2 hclk = 1'b0;
    end

    clic_src_if   sif (.hclk(hclk));
    garuda_apb_if apb (.pclk(pclk), .preset_n(sif.rst_n));

    clic_top #(.IE_MASK(`GARUDA_CLIC_ID_MASK)) dut (
        .hclk_i(hclk), .hreset_n_i(sif.rst_n), .pclk_i(pclk), .preset_n_i(sif.rst_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
        .pwdata_i(apb.pwdata), .prdata_o(apb.prdata), .pready_o(apb.pready), .pslverr_o(apb.pslverr),
        .irq_src_i(sif.irq_src),
        .clic_irq_valid_o(sif.valid), .clic_irq_id_o(sif.id), .clic_irq_level_o(sif.level));

    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(sif.rst_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));

    initial begin
        sif.rst_n   = 1'b0;
        sif.irq_src = 32'd0;
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual clic_src_if)::set(null, "*", "svif", sif);
        run_test();
    end

    final begin
        if (apbviol != 0) $display("[FAIL] APB protocol checker: %0d violations", apbviol);
        else              $display("[PASS] APB protocol checker: 0 violations");
    end
endmodule
