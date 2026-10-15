`timescale 1ns/1ps
// uart_if.sv - the pins of the UART under test and a view of its APB pins. The
// bench holds the three instances of the chip; inst says which one the APB
// agent and the serial agent are talking to. The other two are left alone, and
// the bench checks that they stay silent.
interface uart_if (
    input logic        pclk,
    input logic        preset_n,
    input logic        psel, penable, pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata
);
    logic        rst_req = 1'b0;      // driven by a test: asks the bench for a reset
    int          inst = 0;            // 0, 1 or 2: changed by a test only in reset
    logic        rx = 1'b1;           // the serial agent
    logic        tx;                  // from the selected instance
    logic        dma_ack = 1'b0;      // the DMA responder of the test
    logic        irq, dma_req;
    logic [31:0] prdata;
    logic        pready, pslverr;

    clocking cb @(posedge pclk);
        default input #0.2;
        input preset_n, psel, penable, pwrite, paddr, pwdata, tx, irq, dma_req, dma_ack, prdata, pready, pslverr;
    endclocking
endinterface
