`timescale 1ns/1ps
// gpio_if.sv - the GPIO block's pins, the outside world on its two pads, and a
// view of its APB pins, sampled once per pclk cycle.
interface gpio_if (
    input logic        pclk,
    input logic        preset_n,
    input logic        psel, penable, pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata
);
    logic        rst_req = 1'b0;      // driven by a test: asks the bench for a reset
    // the outside world: a level on each pad, and whether it overpowers the pin's own driver
    logic [1:0]  ext_val = 2'b00, ext_force = 2'b00;
    logic [1:0]  pad;                 // what the block's gpio_i sees
    logic [1:0]  gpio_o, gpio_oe;
    logic        irq;
    logic [31:0] prdata;
    logic        pready, pslverr;

    clocking cb @(posedge pclk);
        default input #0.2;
        input preset_n, psel, penable, pwrite, paddr, pwdata, pad, gpio_o, gpio_oe, irq, prdata, pready, pslverr;
    endclocking
    clocking drv_cb @(posedge pclk);
        output ext_val, ext_force;
    endclocking
endinterface
