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
    // Every one of the 4096 offsets of a peripheral window, read once: PSLVERR
    // must be raised exactly where there is no register (the one rule of the
    // chip, Docs/BUGS.md AUD-13). A register is a word-aligned offset below
    // 0x100 whose bit is set in ip_map (bit n is offset 4n), or one of the four
    // tail registers 0xFE0 to 0xFEC. Offsets that are not word aligned are
    // included: the bridge never sends one, but the rule does not depend on it.
    // Reads only; call it at the end of a bench, because a read can pop a FIFO.
    task automatic sweep_map(input [63:0] ip_map, output integer nbad);
        integer a; reg [31:0] d; bit e; reg is_reg; reg [11:0] o;
        nbad = 0;
        for (a = 0; a < 4096; a = a + 1) begin
            o = a;
            is_reg = (o[1:0] == 2'b00) && ((o < 12'h100 && ip_map[o[7:2]]) || (o >= 12'hFE0 && o <= 12'hFEC));
            read(o, d, e);
            if (e === is_reg) begin
                if (nbad < 6) $display("    offset 0x%03h: PSLVERR %0b, is a register: %0b", o, e, is_reg);
                nbad = nbad + 1;
            end
        end
    endtask

    function automatic bit ready_ok(); return pready === 1'b1; endfunction
endinterface
