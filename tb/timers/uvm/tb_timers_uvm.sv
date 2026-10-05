`timescale 1ns/1ps
// =============================================================================
// tb_timers_uvm.sv - testbench top for the timers and watchdog UVM environment.
//
//   +UVM_TESTNAME=tmr_reg_test | tmr_random_test | tmr_directed_test
//   +NTX=<n>   number of random actions (tmr_random_test)
//
// The reset controller is not in this bench. A small stand-in below does the
// part of its job the block depends on: a watchdog request (through two flops),
// or the pin reset, holds hreset_n low for 16 hclk, and preset_n is released on
// the next pclk edge after hreset_n. The real controller's 1024-cycle stretch is checked in its own
// bench and at chip level.
// =============================================================================
module tb_timers_uvm;
    import uvm_pkg::*;
    import timers_env_pkg::*;

    // hclk and pclk = hclk/2 from ONE process with blocking assignments, so both
    // edges are in the same simulator step and a pclk flop samples an hclk flop's
    // value from BEFORE the shared edge, as it does on silicon with a balanced
    // clock tree. (A divider written "pclk <= ~pclk" puts the pclk edge one delta
    // after the hclk flops have updated; see BUGS.md SIM-1.)
    logic hclk = 0, pclk = 0;
    initial forever begin
        #2 hclk = 1'b1; pclk = ~pclk;
        #2 hclk = 1'b0;
    end

    logic hreset_n, preset_n;
    garuda_apb_if apb (.pclk(pclk), .preset_n(preset_n));
    timers_if tif (.hclk(hclk), .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
                   .paddr(apb.paddr), .pwdata(apb.pwdata));

    // ---- reset stand-in
    int unsigned hold;
    logic [1:0] req_sync;                        // the request goes through two flops, as in reset_ctrl
    always @(posedge hclk or negedge tif.ext_rst_n)
        if (!tif.ext_rst_n)      begin hreset_n <= 1'b0; hold <= 16; req_sync <= 2'b00; end
        else begin
            req_sync <= {req_sync[0], tif.req};
            if (req_sync[1])     begin hreset_n <= 1'b0; hold <= 16; end
            else if (hold != 0)  begin hold <= hold - 1; hreset_n <= (hold == 1); end
        end
    always @(posedge pclk or negedge hreset_n)
        if (!hreset_n) preset_n <= 1'b0; else preset_n <= 1'b1;
    assign tif.hreset_n = hreset_n;
    assign tif.preset_n = preset_n;

    timers_top dut (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .ext_rst_n_i(tif.ext_rst_n),
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
        .pwdata_i(apb.pwdata), .prdata_o(apb.prdata), .pready_o(apb.pready), .pslverr_o(apb.pslverr),
        .mtip_o(tif.mtip), .wdt_warn_irq_o(tif.warn), .wdt_rst_req_o(tif.req));

    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));

    initial begin
        tif.ext_rst_n = 1'b0;
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual timers_if)::set(null, "*", "tvif", tif);
        fork begin repeat (5) @(posedge hclk); tif.ext_rst_n = 1'b1; end join_none
        run_test();
    end

    // a test that stops making progress fails instead of running for ever
    initial begin
        int unsigned maxns = 20_000_000;
        void'($value$plusargs("MAXNS=%d", maxns));
        #(maxns * 1ns);
        $display("tb_timers_uvm: no end of test after %0d ns", maxns);
        $display("RESULT: FAILED");
        $finish;
    end

    final begin
        if (apbviol != 0) $display("[FAIL] APB protocol checker: %0d violations", apbviol);
        else              $display("[PASS] APB protocol checker: 0 violations");
    end
endmodule
