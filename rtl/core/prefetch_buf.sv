// ============================================================================
// GARUDA SoC - Block I: Processor Core
// Module      : prefetch_buf
// Description : Depth-4 circular FIFO. Each entry is tagged with the PC it
//               was fetched from and a fault bit (I-port ERROR).
// Spec Ref    : AERO-GARUDA-DS-001 Rev 1.0, Sec.6.3, Sec.6.5
// ============================================================================
//
// Write side : one word written per cycle when wr_en_i is high (driven by
//              the AHB master's data_valid_o - already excludes dropped,
//              post-redirect data).
// Read side  : IF pops one word per cycle when non-empty and not stalled
//              (rd_en_i computed by the top level from stall_i/redirect_i).
// Flush      : on redirect_i, the WHOLE buffer is invalidated in one cycle
//              by resetting wr_ptr, rd_ptr, and occupancy - not entry by
//              entry (Sec.6.5).
// ============================================================================

module prefetch_buf
    import garuda_pkg::*;
(
    input wire gclk,
    input wire core_rst_n,
    input wire redirect_i,
    // Write side (from AHB master)
    input wire wr_en_i,
    input wire [WORD_W-1:0] wr_instr_i,
    input wire [WORD_W-1:0] wr_pc_i,
    input wire wr_fault_i,
    // Read side (to IF/ID register)
    input wire rd_en_i,
    output wire [WORD_W-1:0] instr_o,
    output wire [WORD_W-1:0] instr_pc_o,
    output wire instr_fault_o,
    output wire instr_valid_o,
    // Status (to AHB master, for backpressure)
    output wire empty_o,
    output wire [PFB_OCC_W-1:0] occupancy_o
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam integer FIFO_DEPTH = 32'd4;
    localparam integer PTR_W      = 32'd2;  // log2(FIFO_DEPTH)
    localparam integer OCC_W      = PTR_W + 1;  // 0..4, needs one extra bit

    reg [WORD_W-1:0] fifo_instr [0:FIFO_DEPTH-1];
    // {fault, pc}: the fetch fault travels with its pc (one array, HAL MEMSIZ)
    reg [WORD_W:0]   fifo_pcf   [0:FIFO_DEPTH-1];

    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;
    reg [OCC_W-1:0] occupancy;

    assign empty_o     = (occupancy == '0);
    assign occupancy_o = occupancy;

    assign instr_o       = fifo_instr[rd_ptr];
    assign instr_pc_o    = fifo_pcf[rd_ptr][WORD_W-1:0];
    assign instr_fault_o = fifo_pcf[rd_ptr][WORD_W];
    assign instr_valid_o = ~empty_o;

    integer i;

    always_ff @(posedge gclk or negedge core_rst_n) begin : p_wr_ptr
        if (!core_rst_n) begin
            wr_ptr <= {PTR_W {1'b0}};
            rd_ptr <= {PTR_W {1'b0}};
            occupancy <= {(PTR_W + 1) {1'b0}};
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                fifo_instr[i] <= NOP_INSTR;
                fifo_pcf[i] <= '0;
            end
        end else if (redirect_i) begin
            // Whole-buffer flush in one cycle (Sec.6.5) - not per-entry.
            wr_ptr <= {PTR_W {1'b0}};
            rd_ptr <= {PTR_W {1'b0}};
            occupancy <= {(PTR_W + 1) {1'b0}};
        end else begin
            if (wr_en_i) begin
                fifo_instr[wr_ptr] <= wr_instr_i;
                fifo_pcf[wr_ptr] <= {wr_fault_i, wr_pc_i};
                wr_ptr <= PTR_W'(wr_ptr + PTR_W'(1));  // wraps by design
            end
            if (rd_en_i) begin
                rd_ptr <= PTR_W'(rd_ptr + PTR_W'(1));  // wraps by design
            end
            case ({wr_en_i, rd_en_i})
                // write only
                2'b10: occupancy <= OCC_W'(occupancy + OCC_W'(1));
                2'b01: occupancy <= OCC_W'(occupancy - OCC_W'(1));  // read only
                default: occupancy <= occupancy;  // both or neither
            endcase
        end
    end

endmodule
