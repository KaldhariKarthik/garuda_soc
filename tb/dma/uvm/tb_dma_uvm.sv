`timescale 1ns/1ps
// =============================================================================
// tb_dma_uvm.sv - testbench top for the DMA UVM environment.
//
//   +UVM_TESTNAME=dma_reg_test | dma_directed_test | dma_random_test
//   +NTX=<n>          random programs (dma_random_test, default 60)
//   +AHB_MAXWAIT=<n>  wait states the AHB slave inserts, 0..n per transfer (default 2)
//
// The DUT is dma_top with the SoC's default channel priorities and a 2-hclk
// acknowledge. The properties of rtl/dma/dma_sva.sv are bound to it, and the
// AHB-Lite and APB protocol checkers watch both of its ports.
// =============================================================================
module tb_dma_uvm;
    import uvm_pkg::*;
    import dma_env_pkg::*;

    // hclk and pclk = hclk/2 from one process with blocking assignments, so both
    // edges are in the same simulator step (see BUGS.md SIM-1)
    logic hclk = 0, pclk = 0;
    initial forever begin
        #2 hclk = 1'b1; pclk = ~pclk;
        #2 hclk = 1'b0;
    end

    dma_if        dif (.hclk(hclk), .pclk(pclk));
    garuda_apb_if apb (.pclk(pclk), .preset_n(dif.rst_n));

    dma_top dut (
        .hclk_i(hclk), .hreset_n_i(dif.rst_n), .pclk_i(pclk), .preset_n_i(dif.rst_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
        .pwdata_i(apb.pwdata), .prdata_o(apb.prdata), .pready_o(apb.pready), .pslverr_o(apb.pslverr),
        .haddr_o(dif.haddr), .htrans_o(dif.htrans), .hwrite_o(dif.hwrite), .hsize_o(dif.hsize),
        .hburst_o(dif.hburst), .hwdata_o(dif.hwdata), .hrdata_i(dif.hrdata),
        .hready_i(dif.hready), .hresp_i(dif.hresp),
        .dma_req_i(dif.req), .dma_ack_o(dif.ack),
        .dma_complete_o(dif.complete), .dma_error_o(dif.error));

    wire [31:0] apbviol, ahbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(dif.rst_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));
    ahb_lite_checker u_ahbchk (
        .clk_i(hclk), .rst_n_i(dif.rst_n),
        .haddr_i(dif.haddr), .htrans_i(dif.htrans), .hsize_i(dif.hsize), .hburst_i(dif.hburst),
        .hwrite_i(dif.hwrite), .hwdata_i(dif.hwdata), .hready_i(dif.hready), .hresp_i(dif.hresp),
        .viol_count_o(ahbviol));

    initial begin
        dif.rst_n = 1'b0;
        dif.req   = 6'd0;
        dif.hready = 1'b1; dif.hresp = 1'b0; dif.hrdata = 32'd0;
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual dma_if)::set(null, "*", "dvif", dif);
        fork
            begin repeat (6) @(posedge hclk); #1 dif.rst_n = 1'b1; end
        join_none
        run_test();
    end

    final begin
        if (apbviol != 0) $display("[FAIL] APB protocol checker: %0d violations", apbviol);
        else              $display("[PASS] APB protocol checker: 0 violations");
        if (ahbviol != 0) $display("[FAIL] AHB-Lite protocol checker: %0d violations", ahbviol);
        else              $display("[PASS] AHB-Lite protocol checker: 0 violations");
    end
endmodule
