`timescale 1ns/1ps
// i2c_if.sv - the I2C block's pins, the two open-drain lines, and a view of its
// APB pins. A line is low when the block or the agent pulls it low, and high
// otherwise (the pull-up).
interface i2c_if (
    input logic        pclk,
    input logic        preset_n,
    input logic        psel, penable, pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata
);
    logic        rst_req = 1'b0;      // driven by a test: asks the bench for a reset
    logic        scl_o, sda_o, scl_oe, sda_oe;             // from the block
    logic        slv_scl_low = 1'b0, slv_sda_low = 1'b0;   // the slave agent
    logic        oth_scl_low = 1'b0, oth_sda_low = 1'b0;   // a second master, and spikes
    wire         scl = ~((scl_oe === 1'b1) | slv_scl_low | oth_scl_low);
    wire         sda = ~((sda_oe === 1'b1) | slv_sda_low | oth_sda_low);
    logic        dma_ack = 1'b0;      // the DMA responder of the test
    logic        irq, dma_req;
    logic [31:0] prdata;
    logic        pready, pslverr;

    clocking cb @(posedge pclk);
        default input #0.2;
        input preset_n, psel, penable, pwrite, paddr, pwdata, scl_oe, sda_oe, scl_o, sda_o, scl, sda,
              irq, dma_req, dma_ack, prdata, pready, pslverr;
    endclocking
endinterface
