`timescale 1ns/1ps
// =============================================================================
// tb_gpio_uvm.sv - testbench top for the GPIO UVM environment.
//
//   +UVM_TESTNAME=gpio_reg_test | gpio_random_test | gpio_directed_test
//   +NTX=<n>   number of random register accesses (gpio_random_test)
//
// The pad cells are at the chip top, not in this block. The two lines below
// stand in for them: a pad carries the pin's own driver when the pin is an
// output, and the outside level otherwise or when the outside overpowers it.
// =============================================================================
module tb_gpio_uvm;
    import uvm_pkg::*;
    import gpio_env_pkg::*;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;

    garuda_apb_if apb (.pclk(pclk), .preset_n(preset_n));
    gpio_if gif (.pclk(pclk), .preset_n(preset_n), .psel(apb.psel), .penable(apb.penable),
                 .pwrite(apb.pwrite), .paddr(apb.paddr), .pwdata(apb.pwdata));
    assign gif.prdata = apb.prdata; assign gif.pready = apb.pready; assign gif.pslverr = apb.pslverr;

    assign gif.pad[0] = (gif.gpio_oe[0] && !gif.ext_force[0]) ? gif.gpio_o[0] : gif.ext_val[0];
    assign gif.pad[1] = (gif.gpio_oe[1] && !gif.ext_force[1]) ? gif.gpio_o[1] : gif.ext_val[1];

    garuda_gpio_top dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
        .pwdata_i(apb.pwdata), .prdata_o(apb.prdata), .pready_o(apb.pready), .pslverr_o(apb.pslverr),
        .irq_o(gif.irq), .gpio_i(gif.pad), .gpio_o(gif.gpio_o), .gpio_oe(gif.gpio_oe));

    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));

    initial begin
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual gpio_if)::set(null, "*", "gvif", gif);
        fork begin repeat (5) @(posedge pclk); preset_n = 1'b1; end join_none
        // a reset in mid-test, when a test asks for one: asserted at once, released on a clock edge
        fork forever begin
            @(posedge gif.rst_req); preset_n = 1'b0;
            @(negedge gif.rst_req); @(posedge pclk); preset_n = 1'b1;
        end join_none
        run_test();
    end

    // a test that stops making progress fails instead of running for ever
    initial begin
        int unsigned maxns = 20_000_000;
        void'($value$plusargs("MAXNS=%d", maxns));
        #(maxns * 1ns);
        $display("tb_gpio_uvm: no end of test after %0d ns", maxns);
        $display("RESULT: FAILED");
        $finish;
    end

    final begin
        if (apbviol != 0) $display("[FAIL] APB protocol checker: %0d violations", apbviol);
        else              $display("[PASS] APB protocol checker: 0 violations");
    end
endmodule
