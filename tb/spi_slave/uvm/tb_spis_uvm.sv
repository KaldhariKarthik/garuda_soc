`timescale 1ns/1ps
// =============================================================================
// tb_spis_uvm.sv - testbench top for the SPI slave UVM environment.
//
//   +UVM_TESTNAME=spis_reg_test | spis_random_test | spis_directed_test
//   +NPKT=<n>   number of random packets (spis_random_test)
// =============================================================================
module tb_spis_uvm;
    import uvm_pkg::*;
    import spis_env_pkg::*;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;

    garuda_apb_if apb (.pclk(pclk), .preset_n(preset_n));
    spis_if sif (.pclk(pclk), .preset_n(preset_n), .psel(apb.psel), .penable(apb.penable),
                 .pwrite(apb.pwrite), .paddr(apb.paddr), .pwdata(apb.pwdata));
    assign sif.prdata = apb.prdata; assign sif.pready = apb.pready; assign sif.pslverr = apb.pslverr;

    garuda_spis_top dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
        .pwdata_i(apb.pwdata), .prdata_o(apb.prdata), .pready_o(apb.pready), .pslverr_o(apb.pslverr),
        .irq_o(sif.irq), .dma_req_o(sif.dma_req), .dma_ack_i(sif.dma_ack),
        .spis_sclk_i(sif.sclk), .spis_mosi_i(sif.mosi), .spis_cs_n_i(sif.cs_n),
        .spis_miso_o(sif.miso), .spis_miso_oe_o(sif.miso_oe));

    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));

    dma_req_checker #(.NAME("spis")) u_dmachk (.clk_i(pclk), .rst_n_i(preset_n), .req_i(sif.dma_req), .ack_i(sif.dma_ack));

    initial begin
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual spis_if)::set(null, "*", "svif", sif);
        // released between two clock edges, so that no flop sees the release and an edge together
        fork begin repeat (5) @(posedge pclk); @(negedge pclk); preset_n = 1'b1; end join_none
        // a reset in mid-test, when a test asks for one: asserted at once
        fork forever begin
            @(posedge sif.rst_req); preset_n = 1'b0;
            @(negedge sif.rst_req); @(negedge pclk); preset_n = 1'b1;
        end join_none
        run_test();
    end

    // a test that stops making progress fails instead of running for ever
    initial begin
        int unsigned maxns = 200_000_000;
        void'($value$plusargs("MAXNS=%d", maxns));
        #(maxns * 1ns);
        $display("tb_spis_uvm: no end of test after %0d ns", maxns);
        $display("RESULT: FAILED");
        $finish;
    end

    final begin
        if (apbviol != 0) $display("[FAIL] APB protocol checker: %0d violations", apbviol);
        else              $display("[PASS] APB protocol checker: 0 violations");
        if (u_dmachk.violations() != 0) $display("[FAIL] DMA request checker: %0d violations", u_dmachk.violations());
        else                            $display("[PASS] DMA request checker: 0 violations");
    end
endmodule
