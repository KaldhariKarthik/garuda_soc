// =============================================================================
// GARUDA SoC - Block 10 : level selection (combinational)
// clic_select.v
//
// Spec: GARUDA-CLIC-SPEC-001 Rev 2.0 Sec.7.3 [N-7.5]..[N-7.8]
//
// Among IDs with enable & pending, pick the highest level; ties go to the
// LOWEST id. Each node compares the key {level, ~id}, so one magnitude compare
// resolves both the level and the tie-break ([N-7.6]). Implemented as a
// balanced binary tree (32 -> 1 in five levels); no register stage (R-7).
// valid = OR(enable & pending), independent of level ([N-7.8]); a level-0
// winner is presented and the core's strict compare never takes it.
// =============================================================================

module clic_select
    import garuda_pkg::*;
#(
    parameter integer NUM_SRC = 32'd32  // power of two
)(
    input wire [NUM_SRC - 1:0] cand_i,  // enable & pending
    input wire [NUM_SRC * CLIC_LVL_W - 1:0] level_i,
    output wire valid_o,
    output wire [CLIC_ID_W-1:0] id_o,
    output wire [CLIC_LVL_W-1:0] level_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned NUM_NODES = 2 * NUM_SRC - 1;  // the comparison tree
    localparam int unsigned NODE_W = 32'd14;
    localparam int unsigned XL_W = 32'd14;
    localparam int unsigned XR_W = 32'd14;

    localparam integer SEL_W = $clog2(NUM_SRC);

    // node key = {present, level[7:0], ~id[4:0]}
    wire [NODE_W-1:0] node [0:NUM_NODES-1];

    genvar i;
    generate
        for (i = 0; i < NUM_SRC; i = i + 1) begin : g_leaf
            assign node[NUM_SRC - 1 + i]
                = {cand_i[i], cand_i[i] ? level_i[8 * i+:8] : 8'd0,
                                  ~i[4:0]};
        end
        for (i = 0; i < NUM_SRC-1; i = i + 1) begin : g_tree
            wire [XL_W-1:0] l = node[2*i+1];
            wire [XR_W-1:0] r = node[2*i+2];
            assign node[i] = (l >= r) ? l : r;
        end
    endgenerate

    assign valid_o = |cand_i;
    assign level_o = node[0][12:5];
    assign id_o    = valid_o ? ~node[0][4:0] : 5'd0;

endmodule
