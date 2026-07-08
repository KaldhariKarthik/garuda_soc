`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core - MEM Stage, Sub-block 3/3
// Load Formatter  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 10.3
//
// Load data from d_hrdata_i is extracted from the addressed lane and then
// sign- or zero-extended per funct3: LB/LH sign-extend, LBU/LHU zero-extend,
// LW passes through. This module is purely combinational; whether its
// output is actually latched into wb_data is decided by the top-level
// mem_to_reg mux (only meaningful once the D-port master confirms OKAY).
// =============================================================================

module load_formatter (
    input  wire [31:0] rdata_i,     // d_hrdata_i
    input  wire [1:0]  addr_lsbs_i, // ex_result[1:0] - byte offset within the word
    input  wire [2:0]  funct3_i,

    output reg  [31:0] load_data_o
);

    wire [1:0] size;
    wire        unsigned_ext;

    assign size         = funct3_i[1:0];  // 00=byte,01=half,10=word
    assign unsigned_ext = funct3_i[2];    // 1 = LBU/LHU (zero-extend)

    reg [7:0]  byte_sel;
    reg [15:0] half_sel;

    always @(*) begin
        case (addr_lsbs_i)
            2'b00: byte_sel = rdata_i[7:0];
            2'b01: byte_sel = rdata_i[15:8];
            2'b10: byte_sel = rdata_i[23:16];
            2'b11: byte_sel = rdata_i[31:24];
        endcase

        case (addr_lsbs_i[1])
            1'b0: half_sel = rdata_i[15:0];
            1'b1: half_sel = rdata_i[31:16];
        endcase
    end

    always @(*) begin
        case (size)
            2'b00: load_data_o = unsigned_ext ? {24'b0, byte_sel}
                                               : {{24{byte_sel[7]}}, byte_sel};
            2'b01: load_data_o = unsigned_ext ? {16'b0, half_sel}
                                               : {{16{half_sel[15]}}, half_sel};
            default: load_data_o = rdata_i;   // word: pass-through, no extension
        endcase
    end

endmodule

`default_nettype wire
