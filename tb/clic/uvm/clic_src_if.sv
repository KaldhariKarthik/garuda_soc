`timescale 1ns/1ps
// clic_src_if.sv - the CLIC's source lines, its outputs to the core, and the
// reset, as one interface for the UVM environment.
interface clic_src_if (input logic hclk);
    logic        rst_n;          // drives hreset_n and preset_n of the DUT
    logic [31:0] irq_src;
    logic        valid;
    logic [4:0]  id;
    logic [7:0]  level;
endinterface
