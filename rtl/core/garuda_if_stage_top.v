`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// GARUDA SoC — Block I: Processor Core
// Module      : garuda_if_stage_top
// Description : Top-level Instruction Fetch stage. Instantiates and wires
//               together the three IF sub-blocks:
//                 1. garuda_pc_gen            — PC / fetch_pc generator
//                 2. garuda_iport_ahb_master  — I-port AHB-Lite master
//                 3. garuda_prefetch_buffer   — depth-4 FIFO
// Spec Ref    : AERO-GARUDA-DS-001 Rev 1.0, §5, §6, §16
// ============================================================================

module garuda_if_stage_top (
    // ----------------------------------------------------------------
    // Infrastructure
    // ----------------------------------------------------------------
    input  wire        clk_i,
    input  wire        rst_n_i,

    // ----------------------------------------------------------------
    // I-port AHB-Lite master (to interconnect)
    // ----------------------------------------------------------------
    output wire [31:0] i_haddr_o,
    output wire [ 1:0] i_htrans_o,
    output wire [ 2:0] i_hsize_o,
    output wire [ 2:0] i_hburst_o,
    output wire [ 3:0] i_hprot_o,
    output wire        i_hwrite_o,
    output wire [31:0] i_hwdata_o,

    input  wire [31:0] i_hrdata_i,
    input  wire        i_hready_i,
    input  wire        i_hresp_i,

    // ----------------------------------------------------------------
    // Pipeline interface (to IF/ID register)
    // ----------------------------------------------------------------
    output wire [31:0] instr_o,
    output wire [31:0] instr_pc_o,
    output wire        instr_valid_o,
    output wire        instr_fault_o,

    // ----------------------------------------------------------------
    // Pipeline control (from hazard unit / redirect mux)
    // ----------------------------------------------------------------
    input  wire        stall_i,
    input  wire        redirect_i,
    input  wire [31:0] redirect_pc_i
);

    // Inter-block wiring
    wire [31:0] fetch_pc;
    wire        fetch_issue;

    wire        data_valid;
    wire [31:0] data_instr;
    wire [31:0] data_pc;
    wire        data_fault;

    wire        fifo_full;
    wire        fifo_empty;
    wire [ 2:0] fifo_occupancy;
    wire        fifo_rd_en = ~fifo_empty & ~stall_i & ~redirect_i;

    // ------------------------------------------------------------------
    // 1. PC Generator
    // ------------------------------------------------------------------
    garuda_pc_gen u_pc_gen (
        .clk_i         (clk_i),
        .rst_n_i       (rst_n_i),
        .redirect_i    (redirect_i),
        .redirect_pc_i (redirect_pc_i),
        .fetch_issue_i (fetch_issue),
        .commit_i      (fifo_rd_en),
        .commit_pc_i   (instr_pc_o),      // PC of the entry being popped
        .pc_o          (/* architectural pc — expose if ID/debug need it */),
        .fetch_pc_o    (fetch_pc)
    );

    // ------------------------------------------------------------------
    // 2. I-port AHB-Lite Master
    // ------------------------------------------------------------------
    garuda_iport_ahb_master u_iport_master (
        .clk_i         (clk_i),
        .rst_n_i       (rst_n_i),
        .redirect_i    (redirect_i),
        .fetch_pc_i    (fetch_pc),
        .fifo_occupancy_i (fifo_occupancy),
        .fifo_rd_en_i  (fifo_rd_en),

        .i_haddr_o     (i_haddr_o),
        .i_htrans_o    (i_htrans_o),
        .i_hsize_o     (i_hsize_o),
        .i_hburst_o    (i_hburst_o),
        .i_hprot_o     (i_hprot_o),
        .i_hwrite_o    (i_hwrite_o),
        .i_hwdata_o    (i_hwdata_o),

        .i_hrdata_i    (i_hrdata_i),
        .i_hready_i    (i_hready_i),
        .i_hresp_i     (i_hresp_i),

        .fetch_issue_o (fetch_issue),
        .data_valid_o  (data_valid),
        .data_instr_o  (data_instr),
        .data_pc_o     (data_pc),
        .data_fault_o  (data_fault)
    );

    // ------------------------------------------------------------------
    // 3. Prefetch Buffer
    // ------------------------------------------------------------------
    garuda_prefetch_buffer u_prefetch_buffer (
        .clk_i         (clk_i),
        .rst_n_i       (rst_n_i),
        .redirect_i    (redirect_i),

        .wr_en_i       (data_valid),
        .wr_instr_i    (data_instr),
        .wr_pc_i       (data_pc),
        .wr_fault_i    (data_fault),

        .rd_en_i       (fifo_rd_en),
        .instr_o       (instr_o),
        .instr_pc_o    (instr_pc_o),
        .instr_fault_o (instr_fault_o),
        .instr_valid_o (instr_valid_o),

        .full_o        (fifo_full),
        .empty_o       (fifo_empty),
        .occupancy_o   (fifo_occupancy)
    );

endmodule

`default_nettype wire
