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

module load_formatter
    import garuda_pkg::*;
(
    input wire [WORD_W-1:0] rdata_i,  // d_hrdata_i
    // ex_result[1:0] - byte offset within the word
    input wire [BYTE_OFF_W-1:0] addr_lsbs_i,
    input wire [FUNCT3_W-1:0] funct3_i,
    output reg [WORD_W-1:0] load_data_o
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [MEM_SIZE_W-1:0] size;
    wire        unsigned_ext;

    assign size         = funct3_i[1:0];  // 00=byte,01=half,10=word
    assign unsigned_ext = funct3_i[2];  // 1 = LBU/LHU (zero-extend)

    // The byte and halfword addr_lsbs_i names (functions: HAL REVROP, MICAWS).
    function automatic logic [BYTE_W-1:0] pick_byte(
        input logic [BYTE_OFF_W-1:0] off, input logic [WORD_W-1:0] d);
        begin
            case (off)
                2'b00: pick_byte = d[7:0];
                2'b01: pick_byte = d[15:8];
                2'b10: pick_byte = d[23:16];
                default: pick_byte = d[31:24];  // 2'b11
            endcase
        end
    endfunction

    wire [BYTE_W-1:0] byte_sel = pick_byte(addr_lsbs_i, rdata_i);
    wire [HALF_W-1:0] half_sel
        = addr_lsbs_i[1] ? rdata_i[31:16] : rdata_i[15:0];

    always_comb begin : c_load_data
        case (size)
            2'b00 : load_data_o = unsigned_ext
                ? {24'b000000000000000000000000, byte_sel}
                : {{24{byte_sel[7]}}, byte_sel};
            2'b01 : load_data_o = unsigned_ext
                ? {16'b0000000000000000, half_sel}
                : {{16{half_sel[15]}}, half_sel};
            default: load_data_o = rdata_i;  // word: pass-through, no extension
        endcase
    end

endmodule
