`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 16: CLIC
// clic_arbiter.v - max-priority reduction tree over all sources
//
// Spec reference: GARUDA-CLIC-SPEC-001 Rev 2.0, Sec. 7.1, Sec. 7.2, Sec. 13.3
//
// =============================================================================
// THE SORT KEY IS THE WHOLE TRICK
// =============================================================================
// Each source forms
//
//     active[i] = ip[i] & ie[i] & (level[i] != 0)
//     key[i]    = active[i] ? {level[i], ~i} : 0
//
// Packing the level in the high bits and the INVERTED index in the low bits
// turns "highest level wins, lowest id breaks a tie" into a single unsigned
// maximum. No priority-encoder chain, no iteration, no second policy knob - one
// comparison operator answers both questions at once.
//
// It also means the winner does not need a parallel index tree: the id falls
// straight out of the winning key as ~key[ID_W-1:0], and the level as the top
// bits. One tree, not two, and the two can therefore never disagree about who
// won - which is the failure a separate index path invites.
//
// LEVEL 0 IS A MASK, NOT A PRIORITY. A level-0 source is excluded from `active`
// entirely, so it can never win regardless of its enable (Sec. 6.5, Sec. 7.1).
// That also makes `winner_valid_o` simply "the winning key is non-zero": every
// active source has a non-zero level, so its key is non-zero, and an all-idle
// CLIC reduces to exactly zero.
//
// =============================================================================
// AN EXPLICIT TREE, NOT A FOR-LOOP CHAIN
// =============================================================================
// Sec. 7.2 calls for a reduction tree of O(log N) depth and Sec. 13.3 explains
// why: this block must present a winner EVERY CYCLE at 200 MHz, and a ripple
// chain of comparators would be both longer in the critical path and harder to
// extend. A sequential for-loop max written in an always block describes a
// ripple and leaves it to the synthesiser to restructure - which it may or may
// not do. The heap-indexed generate below is a balanced tree by construction:
// ceil(log2(N)) comparator levels, whatever the tool decides to do with it.
//
// FIXED PRIORITY, NOT ROUND-ROBIN (Sec. 13.2). Interrupt urgency in a flight
// controller is intrinsic to the source - the IMU and the timer must be
// serviced ahead of a UART byte, always. Fixed level priority encodes that
// directly and cannot invert. Round-robin would trade the guarantee for a
// fairness that no interrupt source wants.
// =============================================================================

`include "clic_defs.vh"

module clic_arbiter #(
    parameter integer CLIC_N = `CLIC_N_DEFAULT,
    parameter integer ID_W   = 5                 // ceil(log2(CLIC_N))
)(
    input  wire [CLIC_N-1:0]              ip_i,
    input  wire [CLIC_N-1:0]              ie_i,
    input  wire [(CLIC_N*`CLIC_LVL_W)-1:0] lvl_flat_i,

    output wire                           winner_valid_o,
    output wire [ID_W-1:0]                winner_id_o,
    output wire [`CLIC_LVL_W-1:0]         winner_lvl_o
);

    localparam integer KW   = `CLIC_LVL_W + ID_W;   // key width
    localparam integer NPAD = (1 << ID_W);          // tree is a power of two

    // -----------------------------------------------------------------------
    // Leaf keys. Sources beyond CLIC_N are padding and are held at zero so
    // they can never win - the tree is sized to a power of two for a clean
    // structure, not because those sources exist.
    // -----------------------------------------------------------------------
    wire [KW-1:0] key [0:NPAD-1];

    genvar i;
    generate
        for (i = 0; i < NPAD; i = i + 1) begin : g_leaf
            if (i < CLIC_N) begin : g_real
                wire [`CLIC_LVL_W-1:0] lvl_i_w =
                    lvl_flat_i[(i*`CLIC_LVL_W) +: `CLIC_LVL_W];

                wire active = ip_i[i] && ie_i[i] && (lvl_i_w != {`CLIC_LVL_W{1'b0}});

                assign key[i] = active ? {lvl_i_w, ~i[ID_W-1:0]} : {KW{1'b0}};
            end else begin : g_pad
                assign key[i] = {KW{1'b0}};
            end
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Balanced reduction tree, heap-indexed.
    //
    // node[1] is the root; leaves live at node[NPAD .. 2*NPAD-1]; each internal
    // node is the max of its two children. Depth is exactly log2(NPAD).
    // -----------------------------------------------------------------------
    wire [KW-1:0] node [0:(2*NPAD)-1];

    generate
        for (i = 0; i < NPAD; i = i + 1) begin : g_leafmap
            assign node[NPAD + i] = key[i];
        end
        for (i = 1; i < NPAD; i = i + 1) begin : g_node
            assign node[i] = (node[2*i] >= node[(2*i)+1]) ? node[2*i]
                                                          : node[(2*i)+1];
        end
    endgenerate

    wire [KW-1:0] win_key = node[1];

    // -----------------------------------------------------------------------
    // Unpack. See the header: the id and level come out of the same key, so
    // they cannot disagree.
    // -----------------------------------------------------------------------
    assign winner_valid_o = |win_key;
    assign winner_lvl_o   = win_key[KW-1 -: `CLIC_LVL_W];
    assign winner_id_o    = ~win_key[ID_W-1:0];

    // node[0] is unused by construction (heap indexing starts at 1).
    assign node[0] = {KW{1'b0}};

endmodule

`default_nettype wire
