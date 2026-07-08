`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// GARUDA SoC — Block I: Processor Core
// Module      : garuda_prefetch_buffer
// Description : Depth-4 circular FIFO. Each entry is tagged with the PC it
//               was fetched from and a fault bit (I-port ERROR).
// Spec Ref    : AERO-GARUDA-DS-001 Rev 1.0, §6.3, §6.5
// ============================================================================
//
// Write side : one word written per cycle when wr_en_i is high (driven by
//              the AHB master's data_valid_o — already excludes dropped,
//              post-redirect data).
// Read side  : IF pops one word per cycle when non-empty and not stalled
//              (rd_en_i computed by the top level from stall_i/redirect_i).
// Flush      : on redirect_i, the WHOLE buffer is invalidated in one cycle
//              by resetting wr_ptr, rd_ptr, and occupancy — not entry by
//              entry (§6.5).
// ============================================================================

module garuda_prefetch_buffer (
    input  wire        clk_i,
    input  wire        rst_n_i,
    input  wire        redirect_i,

    // Write side (from AHB master)
    input  wire        wr_en_i,
    input  wire [31:0] wr_instr_i,
    input  wire [31:0] wr_pc_i,
    input  wire        wr_fault_i,

    // Read side (to IF/ID register)
    input  wire        rd_en_i,
    output wire [31:0] instr_o,
    output wire [31:0] instr_pc_o,
    output wire        instr_fault_o,
    output wire        instr_valid_o,

    // Status (to AHB master, for backpressure)
    output wire        full_o,
    output wire        empty_o,
    output wire [ 2:0] occupancy_o
);

    localparam FIFO_DEPTH = 4;
    localparam PTR_W      = 2;              // log2(FIFO_DEPTH)

    reg [31:0] fifo_instr [0:FIFO_DEPTH-1];
    reg [31:0] fifo_pc    [0:FIFO_DEPTH-1];
    reg        fifo_fault [0:FIFO_DEPTH-1];

    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;
    reg [PTR_W  :0] occupancy;              // 0..4, needs one extra bit

    assign full_o      = (occupancy == FIFO_DEPTH);
    assign empty_o     = (occupancy == 0);
    assign occupancy_o = occupancy;

    assign instr_o       = fifo_instr[rd_ptr];
    assign instr_pc_o    = fifo_pc   [rd_ptr];
    assign instr_fault_o = fifo_fault[rd_ptr];
    assign instr_valid_o = ~empty_o;

    integer i;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            wr_ptr    <= {PTR_W{1'b0}};
            rd_ptr    <= {PTR_W{1'b0}};
            occupancy <= {(PTR_W+1){1'b0}};

            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                fifo_instr[i] <= 32'h0000_0013;   // NOP (addi x0, x0, 0)
                fifo_pc[i]    <= 32'b0;
                fifo_fault[i] <= 1'b0;
            end

        end else if (redirect_i) begin
            // Whole-buffer flush in one cycle (§6.5) — not per-entry.
            wr_ptr    <= {PTR_W{1'b0}};
            rd_ptr    <= {PTR_W{1'b0}};
            occupancy <= {(PTR_W+1){1'b0}};

        end else begin
            if (wr_en_i) begin
                fifo_instr[wr_ptr] <= wr_instr_i;
                fifo_pc   [wr_ptr] <= wr_pc_i;
                fifo_fault[wr_ptr] <= wr_fault_i;
                wr_ptr             <= wr_ptr + 1'b1;
            end

            if (rd_en_i)
                rd_ptr <= rd_ptr + 1'b1;

            case ({wr_en_i, rd_en_i})
                2'b10:   occupancy <= occupancy + 1'b1;   // write only
                2'b01:   occupancy <= occupancy - 1'b1;   // read only
                default: occupancy <= occupancy;          // both or neither
            endcase
        end
    end

endmodule

`default_nettype wire
