`timescale 1ns/1ps
// spis_if.sv - the SPI slave's pins and a view of its APB pins.
//
// The three SPI inputs are driven by the SPI master agent at any time, with no
// relation to pclk. They are sampled here with #1step: the value just before
// the clock edge, which is the value the block's first synchroniser flop takes.
// Everything else is sampled 0.2 ns before the edge. The reference model is
// stepped from these values once per pclk.
interface spis_if (
    input logic        pclk,
    input logic        preset_n,
    input logic        psel, penable, pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata
);
    logic        rst_req = 1'b0;      // driven by a test: asks the bench for a reset
    logic        sclk = 1'b0, mosi = 1'b0, cs_n = 1'b1;   // the SPI master agent
    logic        dma_ack = 1'b0;      // the DMA responder of the test
    logic        miso, miso_oe;
    logic        irq, dma_req;
    logic [31:0] prdata;
    logic        pready, pslverr;

    clocking cb @(posedge pclk);
        default input #0.2;
        input preset_n, psel, penable, pwrite, paddr, pwdata, miso, miso_oe, irq, dma_req, dma_ack, prdata, pready, pslverr;
        input #1step sclk, mosi, cs_n;
    endclocking
endinterface
