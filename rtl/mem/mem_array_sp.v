`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Blocks 3/4/5: Memory Subsystem
// mem_array_sp.v - single-port array with byte write enables
//
// Spec reference: GARUDA-MEM-SPEC-001 Rev 2.0, Sec. 3.2, Sec. 8.1, Sec. 13.6
//
// =============================================================================
// THIS IS A BEHAVIOURAL STAND-IN FOR A COMPILER MACRO - ON PURPOSE
// =============================================================================
// Sec. 13.6 is FLAGGED in the specification and the flag is structural, not a
// caveat: the real arrays come from the foundry memory compiler once the PDK is
// available, and the compiler's macro timing, area and aspect ratio supersede
// every number in the spec. Until then this model sits behind the interface the
// rest of the subsystem is written against, so that the PDK swap changes THIS
// FILE ONLY and touches no wrapper, no block top and no testbench.
//
// Three things get revisited when the PDK lands (Sec. 13.6):
//   - single-cycle access at 200 MHz. If the macro cannot hold it, either the
//     memories gain a wait state - which changes the CORE's timing model, not
//     just ours - or the array is split further.
//   - the per-bank aspect ratio, which may argue for a different bank count.
//   - whether byte-write-enable is native, or whether the lane logic in
//     ahb_mem_slave_if.v has to be built around a word-write macro.
//
// =============================================================================
// THE READ IS ASYNCHRONOUS, AND THAT IS THE WHOLE TIMING ARGUMENT
// =============================================================================
// The address presented here is ALREADY REGISTERED by the slave wrapper: it is
// captured at the address-phase/data-phase boundary. The array access then
// happens combinationally DURING the data-phase cycle, which is what Sec. 9.1's
// budget describes - decode 0.6 ns + wordline/bitline 1.2 ns + sense 1.0 ns =
// 2.8 ns, inside the 5 ns cycle with roughly 2 ns of margin.
//
// This is the only arrangement that delivers zero wait states from a SINGLE
// port. Registering the read output here instead would put the data one cycle
// late and force a wait state on every read. Reading combinationally from an
// UNREGISTERED HADDR would put the full array delay in series with the
// interconnect's address path and blow the 5 ns budget. Registered address in,
// combinational array, data consumed in the same cycle - that is the contract,
// and it is why the address port is driven from dp_addr and not from haddr.
//
// One access per cycle, so the single port never conflicts: a write commits at
// the edge ending its data phase while the next access's address is being
// captured into the wrapper's register, not into this array.
//
// INIT_FILE loads the array at time zero ($readmemh). It is how the Boot ROM
// gets its mask-programmed contents, and how a testbench preloads the ISRAM
// without a backdoor. Left empty for the SRAMs, whose contents are genuinely
// undefined at power-up (Sec. 10.1) - this model leaves them X for exactly
// that reason, so firmware that reads before writing fails in simulation
// instead of quietly reading zero.
// =============================================================================

module mem_array_sp #(
    parameter integer WORDS     = 1024,
    parameter integer AW        = 10,        // ceil(log2(WORDS))
    parameter         INIT_FILE = ""
)(
    input  wire            clk_i,

    input  wire [AW-1:0]   addr_i,           // REGISTERED word index (see header)
    input  wire [3:0]      we_i,             // per-byte write enable, data phase
    input  wire [31:0]     wdata_i,
    output wire [31:0]     rdata_o           // combinational, same-cycle
);

    reg [31:0] mem [0:WORDS-1];

    // -----------------------------------------------------------------------
    // Contents at time zero.
    //
    // A ROM is initialised; an SRAM is deliberately NOT. Sec. 10.1: "SRAM
    // contents after power-up are undefined ... firmware must not read a
    // location before writing it." Zeroing the SRAM here would make that class
    // of firmware bug invisible in simulation and then very visible in silicon.
    // -----------------------------------------------------------------------
    generate
        if (INIT_FILE != "") begin : g_init
            initial $readmemh(INIT_FILE, mem);
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Byte-lane write. Four independent enables, one per lane, so a byte or
    // half-word store modifies only the addressed lanes and leaves the rest of
    // the word untouched - a read-modify-write here would corrupt a neighbour
    // on any narrow store.
    // -----------------------------------------------------------------------
    always @(posedge clk_i) begin
        if (we_i[0]) mem[addr_i][ 7: 0] <= wdata_i[ 7: 0];
        if (we_i[1]) mem[addr_i][15: 8] <= wdata_i[15: 8];
        if (we_i[2]) mem[addr_i][23:16] <= wdata_i[23:16];
        if (we_i[3]) mem[addr_i][31:24] <= wdata_i[31:24];
    end

    assign rdata_o = mem[addr_i];

    // -----------------------------------------------------------------------
    // Backdoor access for testbenches. Simulation only - never synthesised,
    // and never reachable from the bus, so it cannot become a silicon path.
    // -----------------------------------------------------------------------
`ifndef SYNTHESIS
    task bd_write;
        input [AW-1:0] word_addr;
        input [31:0]   data;
        begin
            mem[word_addr] = data;
        end
    endtask

    function [31:0] bd_read;
        input [AW-1:0] word_addr;
        begin
            bd_read = mem[word_addr];
        end
    endfunction

    task bd_load_hex;
        input [1023:0] path;
        begin
            $readmemh(path, mem);
        end
    endtask
`endif

endmodule

`default_nettype wire
