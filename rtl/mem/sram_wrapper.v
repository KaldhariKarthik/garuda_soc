`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Blocks 3/4/5 : the ONLY place an SRAM/ROM macro is instantiated
// sram_wrapper.v
//
// Spec: GARUDA-MEM-SPEC-001 §4.1 [N-4.1]..[N-4.3], ADR-0021
//
// Interface (and no other): clk, addr, wdata, rdata, we, be.
//   - synchronous: addr (and we/be/wdata for a write) sampled on the rising
//     edge; rdata valid the cycle after, and held until the next access.
//   - be[3:0] are byte write enables, qualified by we.
//   - ce gates the access (a macro's CEN); with ce low nothing changes.
//
// Macro selection
//   `GARUDA_SRAM_MACRO` defined : instantiate the foundry macro here, with any
//                                 sleep/retain/test pins tied inactive (N-4.2).
//                                 Not written yet - no compiler output exists.
//   otherwise                   : behavioural model (simulation and generic
//                                 synthesis). Under SIM_SRAM an uninitialised
//                                 word reads X, as the spec requires; an array
//                                 that is never written is X in any case.
//
// ROM = 1 builds the Boot ROM: writes are ignored and the array is loaded from
// INIT_FILE. On silicon this becomes a ROM macro generated from the same file.
// =============================================================================

module sram_wrapper #(
    parameter integer WORDS     = 1024,
    parameter integer AW        = 10,
    parameter integer ROM       = 0,
    parameter         INIT_FILE = ""
)(
    input  wire          clk,
    input  wire          ce,
    input  wire [AW-1:0] addr,
    input  wire [31:0]   wdata,
    output reg  [31:0]   rdata,
    input  wire          we,
    input  wire [3:0]    be
);

`ifdef GARUDA_SRAM_BLACKBOX
    // Structural synthesis only (scripts/run_genus.sh): the arrays would
    // elaborate as ~1M flops. The macro boundary is kept; data reads 0.
    always @(posedge clk) rdata <= 32'd0;
    wire _unused = |{ce, addr, wdata, we, be};
`elsif GARUDA_SRAM_MACRO
    // Foundry macro goes here (OPEN-7 / ADR-0021). Deliberately a hard error
    // until it exists, so a macro build cannot silently fall back to flops.
    initial begin
        $display("sram_wrapper: GARUDA_SRAM_MACRO set but no macro is instantiated");
        $finish;
    end
`else
    reg [31:0] mem [0:WORDS-1];

    generate
        if (INIT_FILE != "") begin : g_init
            initial $readmemh(INIT_FILE, mem);
        end
    endgenerate

    always @(posedge clk) begin
        if (ce) begin
            if (we && ROM == 0) begin
                if (be[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
                if (be[1]) mem[addr][15: 8] <= wdata[15: 8];
                if (be[2]) mem[addr][23:16] <= wdata[23:16];
                if (be[3]) mem[addr][31:24] <= wdata[31:24];
            end else if (!we) begin
                rdata <= mem[addr];
            end
        end
    end

`ifndef SYNTHESIS
    // Backdoor access for testbenches (never used by RTL).
    task bd_write;
        input [AW-1:0] word_addr;
        input [31:0]   data;
        mem[word_addr] = data;
    endtask
    function [31:0] bd_read;
        input [AW-1:0] word_addr;
        bd_read = mem[word_addr];
    endfunction
    task bd_load_hex;
        input [1023:0] path;
        $readmemh(path, mem);
    endtask
`endif
`endif

endmodule

`default_nettype wire
