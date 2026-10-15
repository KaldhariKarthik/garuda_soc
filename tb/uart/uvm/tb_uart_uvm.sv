`timescale 1ns/1ps
// =============================================================================
// tb_uart_uvm.sv - testbench top for the UART UVM environment.
//
//   +UVM_TESTNAME=uart_reg_test | uart_random_test | uart_directed_test
//   +INST=<0|1|2>   the instance the test starts on (block number 16, 17 or 18)
//   +NFRAME=<n>     frames in each direction (uart_random_test)
// =============================================================================
module tb_uart_uvm;
    import uvm_pkg::*;
    import uart_env_pkg::*;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;

    garuda_apb_if apb (.pclk(pclk), .preset_n(preset_n));
    uart_if uif (.pclk(pclk), .preset_n(preset_n), .psel(apb.psel), .penable(apb.penable),
                 .pwrite(apb.pwrite), .paddr(apb.paddr), .pwdata(apb.pwdata));

    // the three instances of the chip, each with its own block number
    wire [31:0] prdata [3]; wire [2:0] pready, pslverr, irq, dma_req, tx;
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : g_uart
        garuda_uart_top #(.BLOCK_NUM(8'd16 + g)) dut (
            .pclk_i(pclk), .preset_n_i(preset_n),
            .psel_i(apb.psel & (uif.inst == g)), .penable_i(apb.penable), .pwrite_i(apb.pwrite), .paddr_i(apb.paddr),
            .pwdata_i(apb.pwdata), .prdata_o(prdata[g]), .pready_o(pready[g]), .pslverr_o(pslverr[g]),
            .irq_o(irq[g]), .dma_req_o(dma_req[g]), .dma_ack_i(uif.dma_ack & (uif.inst == g)),
            .uart_tx_o(tx[g]), .uart_rx_i((uif.inst == g) ? uif.rx : 1'b1));
    end endgenerate
    assign apb.prdata = prdata[uif.inst]; assign apb.pready = pready[uif.inst]; assign apb.pslverr = pslverr[uif.inst];
    assign uif.prdata = apb.prdata; assign uif.pready = apb.pready; assign uif.pslverr = apb.pslverr;
    assign uif.irq = irq[uif.inst]; assign uif.dma_req = dma_req[uif.inst]; assign uif.tx = tx[uif.inst];

    // sb_isolation (F30): the two instances nobody talks to stay silent
    int unsigned iso_viol = 0;
    always @(posedge pclk) if (preset_n)
        for (int i = 0; i < 3; i++) if (i != uif.inst && (tx[i] !== 1'b1 || dma_req[i] !== 1'b0 || pslverr[i] !== 1'b0)) begin
            if (iso_viol < 5) $display("[FAIL] sb_isolation: instance %0d moved while instance %0d was in use (tx %b dma_req %b) at %0t", i, uif.inst, tx[i], dma_req[i], $time);
            iso_viol++;
        end

    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(apb.psel), .penable_i(apb.penable), .pwrite_i(apb.pwrite),
        .paddr_i({20'h0, apb.paddr}), .pwdata_i(apb.pwdata), .pstrb_i(4'hF),
        .pready_i(apb.pready), .pslverr_i(apb.pslverr), .viol_count_o(apbviol));

    dma_req_checker #(.NAME("uart")) u_dmachk (.clk_i(pclk), .rst_n_i(preset_n), .req_i(uif.dma_req), .ack_i(uif.dma_ack));

    initial begin
        void'($value$plusargs("INST=%d", uif.inst));
        apb.psel = 0; apb.penable = 0; apb.pwrite = 0; apb.paddr = 0; apb.pwdata = 0;
        uvm_config_db #(virtual garuda_apb_if)::set(null, "*", "vif",  apb);
        uvm_config_db #(virtual uart_if)::set(null, "*", "uvif", uif);
        fork begin repeat (5) @(posedge pclk); @(negedge pclk); preset_n = 1'b1; end join_none
        fork forever begin
            @(posedge uif.rst_req); preset_n = 1'b0;
            @(negedge uif.rst_req); @(negedge pclk); preset_n = 1'b1;
        end join_none
        run_test();
    end

    // a test that stops making progress fails instead of running for ever
    initial begin
        longint unsigned maxns = 400_000_000;
        void'($value$plusargs("MAXNS=%d", maxns));
        #(maxns * 1ns);
        $display("tb_uart_uvm: no end of test after %0d ns", maxns);
        $display("RESULT: FAILED");
        $finish;
    end

    final begin
        if (apbviol != 0) $display("[FAIL] APB protocol checker: %0d violations", apbviol);
        else              $display("[PASS] APB protocol checker: 0 violations");
        if (u_dmachk.violations() != 0) $display("[FAIL] DMA request checker: %0d violations", u_dmachk.violations());
        else                            $display("[PASS] DMA request checker: 0 violations");
        if (iso_viol != 0) $display("[FAIL] sb_isolation: %0d violations", iso_viol);
        else               $display("[PASS] sb_isolation: the instances not in use stayed silent");
    end
endmodule
