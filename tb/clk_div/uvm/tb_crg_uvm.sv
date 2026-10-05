`timescale 1ns/1ps
// =============================================================================
// tb_crg_uvm.sv - testbench top for the clock and reset UVM environment.
//
//   +UVM_TESTNAME=crg_reg_test | crg_random_test | crg_directed_test
//   +NTX=<n>   number of random actions (crg_random_test)
//
// The two modules are connected as in the chip: the divider makes the clocks
// the reset controller runs on, and the controller holds the divider's select.
// The APB agent runs on the pclk and preset_n that come out of them.
// =============================================================================
module tb_crg_uvm;
    import uvm_pkg::*;
    import crg_env_pkg::*;

    logic refclk = 0;
    wire  aon, hclk, pclk, pclk_phase, div_busy, hreset_n, preset_n, core_rst_n, dm_rst_n, ext_hrst_n, ilock;
    wire [1:0] div_act, div_sel;

    garuda_apb_if apb (.pclk(pclk), .preset_n(preset_n));
    crg_if cif (.refclk(refclk), .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
                .paddr(apb.paddr), .pwdata(apb.pwdata));
    always #1 if (cif.refclk_en) refclk = ~refclk;        // 500 MHz

    clk_div u_clkdiv (
        .refclk_i(refclk), .raw_rst_n_i(cif.ext_rst_n), .div_sel_i(div_sel),
        .aon_clk_o(aon), .hclk_o(hclk), .pclk_o(pclk), .pclk_phase_o(pclk_phase),
        .div_act_o(div_act), .div_busy_o(div_busy));

    reset_ctrl u_rst (
        .aon_clk_i(aon), .hclk_i(hclk), .pclk_i(pclk),
        .ext_rst_n_i(cif.ext_rst_n), .wdt_rst_req_i(cif.wdt_req),
        .ndm_rst_req_i(cif.ndm_req), .hartreset_req_i(cif.hart_req), .boot_sel_i(cif.boot_sel),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
        .pwdata_i(apb.pwdata), .prdata_o(apb.prdata), .pready_o(apb.pready), .pslverr_o(apb.pslverr),
        .div_sel_o(div_sel), .div_act_i(div_act), .div_busy_i(div_busy),
        .ilock_o(ilock),
        .hreset_n_o(hreset_n), .preset_n_o(preset_n), .core_rst_n_o(core_rst_n),
        .dm_rst_n_o(dm_rst_n), .ext_hrst_n_o(ext_hrst_n));

    assign cif.aon = aon; assign cif.hclk = hclk; assign cif.pclk = pclk; assign cif.pclk_phase = pclk_phase;
    assign cif.div_busy = div_busy; assign cif.div_act = div_act; assign cif.div_sel = div_sel;
    assign cif.hreset_n = hreset_n; assign cif.preset_n = preset_n; assign cif.core_rst_n = core_rst_n;
    assign cif.dm_rst_n = dm_rst_n; assign cif.ext_hrst_n = ext_hrst_n; assign cif.ilock = ilock;
    assign cif.prdata = apb.prdata; assign cif.pready = apb.pready; assign cif.pslverr = apb.pslverr;
    assign cif.phase = {u_clkdiv.t4_q, u_clkdiv.t3_q, u_clkdiv.t2_q, u_clkdiv.t1_q};

    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));

    initial begin
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual crg_if)::set(null, "*", "cvif", cif);
        run_test();
    end

    // a test that stops making progress fails instead of running for ever
    initial begin
        int unsigned maxns = 30_000_000;
        void'($value$plusargs("MAXNS=%d", maxns));
        #(maxns * 1ns);
        $display("tb_crg_uvm: no end of test after %0d ns", maxns);
        $display("RESULT: FAILED");
        $finish;
    end

    final begin
        if (apbviol != 0) $display("[FAIL] APB protocol checker: %0d violations", apbviol);
        else              $display("[PASS] APB protocol checker: 0 violations");
    end
endmodule
