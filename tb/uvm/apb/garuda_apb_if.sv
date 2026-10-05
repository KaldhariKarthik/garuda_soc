`timescale 1ns/1ps
// =============================================================================
// garuda_apb_if.sv - APB3 interface for the UVM block environments.
//
// One window: 12-bit offset, 32-bit data, PREADY and PSLVERR from the slave.
// The driver and the monitor both use this interface; the DUT is connected to
// it by name in each block's testbench top.
// =============================================================================
interface garuda_apb_if (input logic pclk, input logic preset_n);
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [11:0] paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;

    // Drive just after the clock edge, sample just before it.
    clocking drv_cb @(posedge pclk);
        default input #0.2 output #0.2;
        output psel, penable, pwrite, paddr, pwdata;
        input  prdata, pready, pslverr;
    endclocking

    clocking mon_cb @(posedge pclk);
        default input #0.2;
        input psel, penable, pwrite, paddr, pwdata, prdata, pready, pslverr;
    endclocking
endinterface
