`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 4: Data SRAM
// dsram_bank.v - one 16 KB bank (4096 x 32, single-port 6T)
//
// Spec reference: GARUDA-MEM-SPEC-001 Rev 2.0, Sec. 7.2
//
// A thin boundary around one array. It exists as its own module rather than as
// four inline instances because the BANK is the unit the PDK swap and the
// floorplan both work in: Sec. 13.6 flags that the compiler's aspect ratio may
// argue for a different bank count, and four 16 KB macros are what the
// floorplanner places. Keeping the bank boundary explicit means that change is
// local.
//
// ce_i is the per-bank activation. It is the entire energy argument for
// banking (Sec. 7.1): exactly one bank is activated per access, so a read
// charges the bit lines of a 4096-word array instead of a 16,384-word one -
// roughly a quarter of the dynamic energy, with shorter bit lines that help
// the array fit the 5 ns cycle.
//
// In this behavioural model ce_i only gates the write enables, because a
// combinational read from an unselected array costs nothing in simulation. In
// the compiler macro it becomes the real chip-enable and the deselected banks
// genuinely do not switch. The signal is carried now so the swap needs no
// interface change - and so the intent is visible to whoever does it.
// =============================================================================

`include "mem_defs.vh"

module dsram_bank (
    input  wire        clk_i,

    input  wire        ce_i,        // bank activation - see header
    input  wire [11:0] addr_i,      // registered word index within the bank
    input  wire [3:0]  we_i,
    input  wire [31:0] wdata_i,
    output wire [31:0] rdata_o
);

    // Writes are qualified by the bank select so a write to bank 1 cannot
    // disturb bank 0. Sec. 12 tests exactly this with a write-all-banks then
    // read-all-banks pattern.
    wire [3:0] we_q = ce_i ? we_i : 4'b0000;

    mem_array_sp #(
        .WORDS     (`MEM_DSRAM_BANK_WORDS),
        .AW        (12),
        .INIT_FILE ("")
    ) u_array (
        .clk_i   (clk_i),
        .addr_i  (addr_i),
        .we_i    (we_q),
        .wdata_i (wdata_i),
        .rdata_o (rdata_o)
    );

endmodule

`default_nettype wire
