// =============================================================================
// GARUDA SoC - Block I: Processor Core - MEM Stage, Sub-block 1/3
// Load/Store Unit  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 10.1 - 10.2
//
// - d_hsize_o is derived from funct3: byte(000)/halfword(001)/word(010).
// - Misalignment check completes BEFORE the D-port address phase commits
//   (late EX / early MEM, Sec. 10.2) - this block is purely combinational
//   and feeds the AHB master's "start" qualifier, which gates the bus
//   transaction off entirely on a misalignment (no transaction issued).
// - Store data is lane-aligned: a byte/halfword is shifted onto the
//   correct byte lane of the write-data bus per AMBA convention.
// =============================================================================

module load_store_unit
    import garuda_pkg::*;
(
    input wire [WORD_W-1:0] addr_i,  // ex_result (address, computed in EX)
    input wire [FUNCT3_W-1:0] funct3_i,
    input wire [WORD_W-1:0] rs2_data_i,  // raw (forwarded) store operand
    output wire [HSIZE_W-1:0] hsize_o,  // 000=byte, 001=half, 010=word
    output wire load_misaligned_o,  // cause 4 candidate (Sec. 14.1)
    output wire store_misaligned_o,  // cause 6 candidate (Sec. 14.1)
    // lane-aligned store data
    output reg [WORD_W-1:0] hwdata_o
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [DMA_SIZE_W-1:0] size;
    assign size = funct3_i[1:0];  // 00=byte, 01=half, 10=word (Sec. 10.1)

    assign hsize_o = {1'b0, size};

    // Misalignment (Sec. 10.2): byte never misaligns; halfword needs
    // addr[0]=0; word needs addr[1:0]=00. Caller AND's this with
    // mem_read_i/mem_write_i to pick load vs store cause.
    wire misaligned;
    assign misaligned = (size == 2'b01) ? addr_i[0]     :
                         (size == 2'b10) ? (|addr_i[1:0]) :
                         1'b0;

    assign load_misaligned_o  = misaligned;
    assign store_misaligned_o = misaligned;

    // Store-data lane alignment (Sec. 10.1): shift the byte/halfword onto
    // the lane matching addr[1:0]; zero-extend to 32 bits FIRST so the
    // shift doesn't truncate, then Verilog's << zero-fills the rest.
    always_comb begin : c_hwdata
        case (size)
            2'b00 : hwdata_o = {24'b000000000000000000000000,
                rs2_data_i[7:0]} << (addr_i[1:0] * 8);
            2'b01 : hwdata_o
                = {16'b0000000000000000, rs2_data_i[15:0]} << (addr_i[1] * 16);
            default: hwdata_o = rs2_data_i;  // word: no shift
        endcase
    end

endmodule
