// =============================================================================
// GARUDA / ASAP7 exploratory flow: BLACK-BOX declarations for the named memory
// macros that rtl/mem/sram_wrapper.v instantiates under GARUDA_SRAM_MACRO (P3).
// PD-only. Not RTL, never simulated. Ports must match sram_wrapper's macro
// branch exactly. Replaced by the mock-SRAM abstracts (LEF + liberty) once those
// exist.
// =============================================================================
(* blackbox *)
module garuda_sram_16384x32 (input clk, input ce, input we, input [3:0] be,
    input [13:0] addr, input [31:0] wdata, output [31:0] rdata);
endmodule

(* blackbox *)
module garuda_sram_4096x32 (input clk, input ce, input we, input [3:0] be,
    input [11:0] addr, input [31:0] wdata, output [31:0] rdata);
endmodule

(* blackbox *)
module garuda_rom_1024x32 (input clk, input ce, input [9:0] addr, output [31:0] rdata);
endmodule
