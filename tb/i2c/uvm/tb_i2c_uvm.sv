`timescale 1ns/1ps
// =============================================================================
// tb_i2c_uvm.sv - testbench top for the I2C UVM environment.
//
//   +UVM_TESTNAME=i2c_reg_test | i2c_random_test | i2c_directed_test
//   +NXFER=<n>   number of random transfers (i2c_random_test)
// =============================================================================
module tb_i2c_uvm;
    import uvm_pkg::*;
    import i2c_env_pkg::*;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;

    garuda_apb_if apb (.pclk(pclk), .preset_n(preset_n));
    i2c_if iif (.pclk(pclk), .preset_n(preset_n), .psel(apb.psel), .penable(apb.penable),
                .pwrite(apb.pwrite), .paddr(apb.paddr), .pwdata(apb.pwdata));
    assign iif.prdata = apb.prdata; assign iif.pready = apb.pready; assign iif.pslverr = apb.pslverr;

    garuda_i2c_top dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
        .pwdata_i(apb.pwdata), .prdata_o(apb.prdata), .pready_o(apb.pready), .pslverr_o(apb.pslverr),
        .irq_o(iif.irq), .dma_req_o(iif.dma_req), .dma_ack_i(iif.dma_ack),
        .i2c_scl_i(iif.scl), .i2c_scl_o(iif.scl_o), .i2c_scl_oe(iif.scl_oe),
        .i2c_sda_i(iif.sda), .i2c_sda_o(iif.sda_o), .i2c_sda_oe(iif.sda_oe));

    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));

    dma_req_checker #(.NAME("i2c")) u_dmachk (.clk_i(pclk), .rst_n_i(preset_n), .req_i(iif.dma_req), .ack_i(iif.dma_ack));

    initial begin
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual i2c_if)::set(null, "*", "ivif", iif);
        fork begin repeat (5) @(posedge pclk); @(negedge pclk); preset_n = 1'b1; end join_none
        fork forever begin
            @(posedge iif.rst_req); preset_n = 1'b0;
            @(negedge iif.rst_req); @(negedge pclk); preset_n = 1'b1;
        end join_none
        run_test();
    end

    // a test that stops making progress fails instead of running for ever
    initial begin
        longint unsigned maxns = 80_000_000;
        void'($value$plusargs("MAXNS=%d", maxns));
        #(maxns * 1ns);
        $display("tb_i2c_uvm: no end of test after %0d ns", maxns);
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
