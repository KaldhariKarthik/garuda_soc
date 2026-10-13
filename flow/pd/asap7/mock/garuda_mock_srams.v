// =============================================================================
// GARUDA / ASAP7 EXPLORATORY MOCK MEMORIES. PD-ONLY, never simulated as GARUDA
// RTL, never a real SRAM model.
//
// Hardened as ORFS blocks to give the named macros of rtl/mem/sram_wrapper.v
// (P3) a LEF and a timing .lib. Ports are identical to the macros that
// sram_wrapper instantiates. Behaviour is identical to sram_wrapper's
// behavioural model (ce gating; read when ce & !we, registered, held otherwise;
// write when ce & we with per-byte be[3:0]) EXCEPT for capacity: the array
// has 4 rows, and the full address is XOR-folded into a 2-bit row index so
// that every address pin stays connected. Distinct addresses ALIAS.
//
// The ROM mock holds 4 arbitrary constant words. It does NOT contain the boot
// image: the real boot ROM must be generated with the boot image at the
// foundry stage (ROM compiler fed from the BROM INIT_FILE).
//
// The physical size of each block is forced in its ORFS config to the approved
// dimensions (Docs/PD_LOG_2026-10-13.md §8). Area and timing are EXPLORATORY
// ASSUMPTIONS, not SRAM estimates.
// =============================================================================

module garuda_sram_16384x32 (input clk, input ce, input we, input [3:0] be,
    input [13:0] addr, input [31:0] wdata, output reg [31:0] rdata);
    wire [1:0] idx = {^addr[13:7], ^addr[6:0]};
    reg  [31:0] mem [0:3];
    integer i;
    always @(posedge clk)
        if (ce) begin
            if (we) begin
                for (i = 0; i < 4; i = i + 1)
                    if (be[i]) mem[idx][8*i +: 8] <= wdata[8*i +: 8];
            end else
                rdata <= mem[idx];
        end
endmodule

module garuda_sram_4096x32 (input clk, input ce, input we, input [3:0] be,
    input [11:0] addr, input [31:0] wdata, output reg [31:0] rdata);
    wire [1:0] idx = {^addr[11:6], ^addr[5:0]};
    reg  [31:0] mem [0:3];
    integer i;
    always @(posedge clk)
        if (ce) begin
            if (we) begin
                for (i = 0; i < 4; i = i + 1)
                    if (be[i]) mem[idx][8*i +: 8] <= wdata[8*i +: 8];
            end else
                rdata <= mem[idx];
        end
endmodule

module garuda_rom_1024x32 (input clk, input ce, input [9:0] addr, output reg [31:0] rdata);
    wire [1:0] idx = {^addr[9:5], ^addr[4:0]};
    always @(posedge clk)
        if (ce)
            case (idx)       // arbitrary constants: NOT the boot image
                2'd0: rdata <= 32'h0000_0013;
                2'd1: rdata <= 32'h1000_0537;
                2'd2: rdata <= 32'hA5A5_5A5A;
                default: rdata <= 32'h0F0F_F0F0;
            endcase
endmodule
