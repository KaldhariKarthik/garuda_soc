`timescale 1ns/1ps
// =============================================================================
// garuda_apb_bfm.sv -- the APB master the block TBs drive peripherals with.
//
// Same access shape the real bridge produces: setup cycle, access cycle,
// PRDATA sampled on the edge that ENDS the access phase (this matters for
// registers with a read side effect, e.g. the machine timer's shadow latch or
// a 16550 RBR pop). Word accesses only - the bridge rejects anything else
// before it reaches a peripheral.
// =============================================================================
interface garuda_apb_bfm (input logic pclk, input logic preset_n);
    logic        psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = 0;
    logic [31:0] pwdata = 0;
    logic [31:0] prdata;
    logic        pready, pslverr;

    task automatic write(input [11:0] a, input [31:0] d, output bit err);
        @(posedge pclk); #0.1 psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk); err = pslverr;
        #0.1 psel = 0; penable = 0; pwrite = 0;
    endtask

    task automatic read(input [11:0] a, output [31:0] d, output bit err);
        @(posedge pclk); #0.1 psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk); d = prdata; err = pslverr;
        #0.1 psel = 0; penable = 0;
    endtask

    task automatic wr(input [11:0] a, input [31:0] d);
        bit e; write(a, d, e);
    endtask
    function automatic bit ready_ok(); return pready === 1'b1; endfunction
endinterface
