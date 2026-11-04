`timescale 1ns/1ps
// =============================================================================
// tb_debug_ocd.sv -- OpenOCD against the simulation (Track A plan 6A.5 G7, vPlan F35 in
// simulation). debug_top + a real ISRAM (locked: only the debugger may write it, as after
// boot) on hclk 250 MHz; JTAG pins come from OpenOCD over remote_bitbang (jtag_rbb.c).
// The OpenOCD script (garuda_sim.cfg, check.tcl) does the checking and quits; this bench
// adds the protocol checker on the SBA master and reports what the debug module saw.
// =============================================================================
module tb_debug_ocd;
    import "DPI-C" function int rbb_open(input int port);
    import "DPI-C" function int rbb_step(input int tdo);
    reg hclk = 0, rst_n = 0, por_n = 0;
    reg tck = 0, tms = 1, tdi = 0;
    wire tdo, tdo_oe;
    always #2 hclk = ~hclk;
    wire [31:0] haddr, hwdata, hrdata; wire [1:0] htrans; wire hwrite, hready, hresp; wire [2:0] hsize, hburst;
    wire ndmreset, hartreset, halt_req;
    debug_top dut (
        .tck_i(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo), .tdo_oe_o(tdo_oe), .por_n_i(por_n),
        .hclk_i(hclk), .dm_rst_n_i(rst_n), .ndmreset_o(ndmreset), .hartreset_o(hartreset),
        .halt_req_o(halt_req), .halt_safe_i(1'b1),
        .dsu_acc0_i(48'h0000_1234_5678), .dsu_acc1_i(48'd0), .dsu_acc2_i(48'd0), .dsu_ovf_i(1'b0),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hwdata_o(hwdata), .hrdata_i(hrdata), .hready_i(hready), .hresp_i(hresp));
    isram_top u_isram (.hclk_i(hclk), .hreset_n_i(rst_n), .hsel_i(haddr[31:28] == 4'h0), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst), .hprot_i(4'h3),
        .hwdata_i(hwdata), .hready_i(hready), .hrdata_o(hrdata), .hreadyout_o(hready), .hresp_o(hresp),
        .ilock_i(1'b1), .hmaster_is_sba_i(1'b1));
    wire [31:0] v_chk;
    ahb_lite_checker u_chk (.clk_i(hclk), .rst_n_i(rst_n), .haddr_i(haddr), .htrans_i(htrans), .hsize_i(hsize),
        .hburst_i(hburst), .hwrite_i(hwrite), .hwdata_i(hwdata), .hready_i(hready), .hresp_i(hresp), .viol_count_o(v_chk));
    integer n_sba = 0, n_hartreset = 0;
    always @(posedge hclk) if (dut.sba_start) n_sba++;
    always @(posedge hartreset) n_hartreset++;
    integer port, c;
    initial begin
        if (!$value$plusargs("PORT=%d", port)) port = 9823;
        #20 por_n = 1; #40 rst_n = 1;
        if (rbb_open(port) != 0) begin $display("[FAIL] cannot open the remote_bitbang port"); $display("RESULT: FAILED"); $finish; end
        forever begin
            c = rbb_step(tdo);
            if (c < 0) break;
            if (c <= 7) begin tck = c[2]; tms = c[1]; tdi = c[0]; #20; end   // 25 MHz-ish tck
        end
        $display("[tb_debug_ocd] OpenOCD disconnected at %0t: %0d SBA transfers, %0d hart resets, AHB checker violations %0d",
                 $time, n_sba, n_hartreset, v_chk);
        $display("RESULT: %s", (v_chk == 0 && n_sba > 0) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
