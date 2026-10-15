`timescale 1ns/1ps
// =============================================================================
// dma_if.sv - the DMA's AHB-Lite master port, its peripheral sideband, its
// interrupts and the reset, as one interface for the UVM environment.
//
// Timing convention of every component that uses it (no clocking block, see
// BUGS TOOL-26): the DUT changes its outputs at the hclk rising edge; the AHB
// slave and the request driver change theirs 1 ns after it; everything is
// sampled at the falling edge, when all of it is stable. "Cycle k" is the
// hclk period that starts at rising edge k.
// =============================================================================
interface dma_if (input logic hclk, input logic pclk);
    logic        rst_n;          // drives hreset_n and preset_n of the DUT

    // AHB-Lite master M3 (DUT outputs) and the slave's response (TB outputs)
    logic [31:0] haddr;
    logic [1:0]  htrans;
    logic        hwrite;
    logic [2:0]  hsize;
    logic [2:0]  hburst;
    logic [31:0] hwdata;
    logic [31:0] hrdata;
    logic        hready;
    logic        hresp;

    // peripheral sideband and interrupts
    logic [5:0]  req;
    logic [5:0]  ack;
    logic [5:0]  complete;
    logic [5:0]  error;
endinterface
