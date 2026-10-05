`timescale 1ns/1ps
// timers_if.sv - the timer block's resets and outputs, plus a view of the APB
// pins on hclk, as one interface for the UVM environment. The reference model
// is stepped once per hclk cycle from the values sampled here.
interface timers_if (
    input logic        hclk,
    input logic        psel, penable, pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata
);
    logic ext_rst_n;      // driven by the test: the pin reset
    logic hreset_n;       // driven by the reset stand-in in the testbench top
    logic preset_n;
    logic mtip, warn, req;

    clocking cb @(posedge hclk);
        default input #0.2;
        input ext_rst_n, hreset_n, preset_n, mtip, warn, req;
        input psel, penable, pwrite, paddr, pwdata;
    endclocking
endinterface
