`timescale 1ns/1ps
// pwm_if.sv - the PWM block's outputs and a view of its APB pins, sampled once
// per pclk cycle. The reference model is stepped from these values.
interface pwm_if (
    input logic        pclk,
    input logic        preset_n,
    input logic        psel, penable, pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata
);
    logic        rst_req = 1'b0;      // driven by a test: asks the bench for a reset
    logic [3:0]  pwm;
    logic        irq;
    logic [31:0] prdata;
    logic        pready, pslverr;

    clocking cb @(posedge pclk);
        default input #0.2;
        input preset_n, psel, penable, pwrite, paddr, pwdata, pwm, irq, prdata, pready, pslverr;
    endclocking
endinterface
