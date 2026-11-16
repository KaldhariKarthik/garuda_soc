`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 10 : level selection (combinational)
// clic_select.v
//
// Spec: GARUDA-CLIC-SPEC-001 Rev 2.0 §7.3 [N-7.5]..[N-7.8]
//
// Among IDs with enable & pending, pick the highest level; ties go to the
// LOWEST id. Each node compares the key {level, ~id}, so one magnitude compare
// resolves both the level and the tie-break ([N-7.6]). Implemented as a
// balanced binary tree (32 -> 1 in five levels); no register stage (R-7).
// valid = OR(enable & pending), independent of level ([N-7.8]); a level-0
// winner is presented and the core's strict compare never takes it.
// =============================================================================

module clic_select #(
    parameter integer NUM_SRC = 32                      // power of two
)(
    input  wire [NUM_SRC-1:0]   cand_i,                 // enable & pending
    input  wire [NUM_SRC*8-1:0] level_i,
    output wire           valid_o,
    output wire [4:0]     id_o,
    output wire [7:0]     level_o
);

    localparam integer SEL_W = $clog2(NUM_SRC);

    // node key = {present, level[7:0], ~id[4:0]}
    wire [13:0] node [0:2*NUM_SRC-2];

    genvar i;
    generate
        for (i = 0; i < NUM_SRC; i = i + 1) begin : g_leaf
            assign node[NUM_SRC-1+i] = {cand_i[i], cand_i[i] ? level_i[8*i +: 8] : 8'd0,
                                  ~i[4:0]};
        end
        for (i = 0; i < NUM_SRC-1; i = i + 1) begin : g_tree
            wire [13:0] l = node[2*i+1];
            wire [13:0] r = node[2*i+2];
            assign node[i] = (l >= r) ? l : r;
        end
    endgenerate

    assign valid_o = |cand_i;
    assign level_o = node[0][12:5];
    assign id_o    = valid_o ? ~node[0][4:0] : 5'd0;

endmodule

`default_nettype wire
