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
    // the access size, funct3[1:0]: 00 byte, 01 half, 10 word (Sec. 10.1)
    input wire [MEM_SIZE_W-1:0] size_i,
    input wire [WORD_W-1:0] rs2_data_i,  // raw (forwarded) store operand
    output wire [HSIZE_W-1:0] hsize_o,  // 000=byte, 001=half, 010=word
    // cause 4 (load) or 6 (store) candidate (Sec. 14.1): the caller ANDs it
    // with mem_read / mem_write
    output wire misaligned_o,
    // lane-aligned store data
    output wire [WORD_W-1:0] hwdata_o
);
    timeunit 1ns;
    timeprecision 1ps;


    assign hsize_o = {1'b0, size_i};

    // Misalignment (Sec. 10.2): byte never misaligns; halfword needs
    // addr[0]=0; word needs addr[1:0]=00.
    assign misaligned_o = (size_i == 2'b01) ? addr_i[0]     :
                          (size_i == 2'b10) ? (|addr_i[1:0]) :
                          1'b0;

    // Store-data lane alignment (Sec. 10.1): the byte or halfword goes onto
    // the lane addr[1:0] names, every other lane zero; a word goes as it is.
    // (A lane mux, not a shift by the address: HAL SHFTNC.)
    function automatic logic [WORD_W-1:0] lanes(
        input logic [MEM_SIZE_W-1:0] sz, input logic [BYTE_OFF_W-1:0] off,
        input logic [WORD_W-1:0] d);
        begin
            case (sz)
                2'b00: begin
                    case (off)
                        2'b00: lanes = {24'd0, d[7:0]};
                        2'b01: lanes = {16'd0, d[7:0], 8'd0};
                        2'b10: lanes = {8'd0, d[7:0], 16'd0};
                        default: lanes = {d[7:0], 24'd0};  // 2'b11
                    endcase
                end
                2'b01: lanes = off[1] ? {d[15:0], 16'd0} : {16'd0, d[15:0]};
                default: lanes = d;  // word: no shift
            endcase
        end
    endfunction

    assign hwdata_o = lanes(size_i, addr_i[1:0], rs2_data_i);

endmodule
