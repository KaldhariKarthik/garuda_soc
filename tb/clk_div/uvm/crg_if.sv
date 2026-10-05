`timescale 1ns/1ps
// crg_if.sv - everything around the clock divider and the reset controller: the
// reference clock and the pins a test drives, the clocks and resets that come
// out, and a view of the APB pins.
interface crg_if (
    input logic        refclk,
    input logic        psel, penable, pwrite,
    input logic [11:0] paddr,
    input logic [31:0] pwdata
);
    // driven by a test
    logic        refclk_en = 1'b1;    // 0 stops the reference clock (power-on with no clock yet)
    logic        ext_rst_n = 1'b0;    // the pin: asynchronous
    logic        wdt_req = 1'b0, ndm_req = 1'b0, hart_req = 1'b0;   // hclk domain
    logic        boot_sel = 1'b0;     // a pin
    // out of the block
    logic        aon, hclk, pclk, pclk_phase, div_busy;
    logic [1:0]  div_act, div_sel;
    logic        hreset_n, preset_n, core_rst_n, dm_rst_n, ext_hrst_n, ilock;
    logic [31:0] prdata;
    logic        pready, pslverr;
    logic [3:0]  phase;               // the divider's count, for coverage only

    // the cause register lives on the always-on clock: one sample per edge of it
    clocking acb @(posedge aon);
        default input #0.1;
        input ext_rst_n, wdt_req, ndm_req, hart_req, boot_sel, psel, penable, pwrite, paddr, pwdata,
              prdata, pready, pslverr, div_busy, div_act, div_sel, hreset_n, preset_n, core_rst_n, dm_rst_n, ilock, phase;
    endclocking
endinterface
