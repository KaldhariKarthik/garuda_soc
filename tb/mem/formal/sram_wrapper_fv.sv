// =============================================================================
// sram_wrapper_fv.sv -- formal-only abstraction of rtl/mem/sram_wrapper.v for the
// UNBOUNDED memory proofs (Track A plan 6A.6 step M1). Same module name and ports;
// a manifest swaps it in with `replace`.
//
// It keeps exactly one word: the word at index `trk`, which mem_fv_track (below)
// ties to the word mem_sva watches. A read of `trk` returns that word; a read of
// any other address returns a value the solver chooses freely, every cycle. The
// real macro is one of the behaviours this model allows, so a property proved
// here holds for the real array (an over-approximation). The interface timing is
// the wrapper's own: address sampled on the edge, read data the cycle after and
// held until the next read; a write of a ROM (ROM = 1) is ignored; ce low = no access.
// The full-size real arrays are still checked by the bounded tasks.
// =============================================================================
`timescale 1ns/1ps
module sram_wrapper #(
    parameter integer WORDS     = 1024,
    parameter integer AW        = 10,
    parameter integer ROM       = 0,
    parameter         INIT_FILE = ""
)(
    input  wire          clk,
    input  wire          ce,
    input  wire [AW-1:0] addr,
    input  wire [31:0]   wdata,
    output reg  [31:0]   rdata,
    input  wire          we,
    input  wire [3:0]    be
);
    wire [AW-1:0] trk;          // undriven: free; held equal to mem_sva's watch by mem_fv_track
    wire [31:0]   other;        // undriven: free every cycle (the words not tracked)
    reg  [31:0]   tw;           // contents of word trk
    wire [31:0]   tw_init;      // undriven: free; the tracked word's contents before any write
    reg           loaded = 1'b0;
    // tw is loaded once from a free value and then held: arbitrary but FIXED contents (a ROM's
    // image, or unwritten RAM). Without the load, a never-written tw (the ROM) would be
    // undriven, i.e. a new free value every cycle (seen 2026-10-15).
    always @(posedge clk) begin
        loaded <= 1'b1;
        if (!loaded) tw <= tw_init;
        if (ce) begin
            if (we && ROM == 0) begin
                if (addr == trk) begin
                    if (be[0]) tw[ 7: 0] <= wdata[ 7: 0];
                    if (be[1]) tw[15: 8] <= wdata[15: 8];
                    if (be[2]) tw[23:16] <= wdata[23:16];
                    if (be[3]) tw[31:24] <= wdata[31:24];
                end
            end else if (!we) begin
                rdata <= (addr == trk) ? tw : other;
            end
        end
    end
    wire _unused = |{INIT_FILE, WORDS};
endmodule

// The tracked word of each array is the word mem_sva watches (for the DSRAM, the
// same index inside every bank; the bank that holds the watched word is the one
// that matters, the other three are harmless extra tracking).
module mem_fv_track_1 #(parameter integer AW = 14) (
    input wire clk, input wire [AW-1:0] watch, input wire [AW-1:0] trk);
    always @(*) assume (trk == watch);
endmodule
module mem_fv_track_4 #(parameter integer AW = 14, parameter integer BAW = 12) (
    input wire clk, input wire [AW-1:0] watch, input wire [4*BAW-1:0] trk);
    always @(*) for (int b = 0; b < 4; b++) assume (trk[b*BAW +: BAW] == watch[BAW-1:0]);
endmodule

bind isram_top mem_fv_track_1 #(.AW(14)) u_fv_track (
    .clk(hclk_i), .watch(u_if.u_mem_sva.watch), .trk(u_array.trk));
bind bootrom_top mem_fv_track_1 #(.AW(10)) u_fv_track (
    .clk(hclk_i), .watch(u_if.u_mem_sva.watch), .trk(u_array.trk));
bind dsram_top mem_fv_track_4 #(.AW(14), .BAW(12)) u_fv_track (
    .clk(hclk_i), .watch(u_if.u_mem_sva.watch),
    .trk({g_bank[3].u_array.trk, g_bank[2].u_array.trk, g_bank[1].u_array.trk, g_bank[0].u_array.trk}));

// Helper invariants for the unbounded data-integrity proof (k-induction needs them; they
// are asserted, so they are proved too, not assumed). With the one-word model:
//   h_ref_vs_array : every byte of the watched word the reference model knows equals the
//                    array's tracked word, or the parked write when the write buffer holds
//                    that byte of that word;
//   h_read_pending : in a read data phase of the watched word, the macro returns the
//                    tracked word (no write reaches the macro in the read's address phase);
//   h_wbuf_vs_dphase: while the write buffer holds a write, the data phase is not a legal
//                    write (the RTL's own argument for a one-entry buffer, made inductive).
module mem_fv_helpers #(parameter integer AW = 14) (
    input wire clk, input wire rst_n,
    input wire [AW-1:0] watch, input wire [31:0] ref_data, input wire [3:0] ref_known,
    input wire [31:0] tw,
    input wire wb_v, input wire [AW-1:0] wb_word, input wire [3:0] wb_be, input wire [31:0] wb_data,
    input wire rd_dp, input wire [AW-1:0] dp_word, input wire [31:0] arr_rdata,
    input wire dp_valid, input wire dp_write, input wire dp_err,
    input wire env_own_dp, input wire err2_q,
    input wire writable, input wire [31:0] hrdata);
    // a ROM is never written over the bus, so mem_sva's reference model never learns a byte
    // (its a_data_integrity is vacuous on the ROM; found 2026-10-15) ...
    // a ROM refuses every write in its address phase, so nothing is ever parked
    h_rom_no_wbuf: assert property (@(posedge clk) disable iff (!rst_n) writable || !wb_v );
    h_rom_ref_empty: assert property (@(posedge clk) disable iff (!rst_n) writable || ref_known == 4'd0 );
    // ... so this is the ROM's data check, and a second one for the RAMs: a read of the
    // watched word, with no parked write to it, returns the stored word on HRDATA.
    a_read_returns_stored: assert property (@(posedge clk) disable iff (!rst_n)
        !(rd_dp && dp_word == watch && !(wb_v && wb_word == watch)) || hrdata == tw );
    // the environment's view (from the bus) and the RTL's agree on who owns the data phase
    h_env_owns: assert property (@(posedge clk) disable iff (!rst_n) env_own_dp == dp_valid );
    // the second ERROR cycle belongs to a refused data phase
    h_err2: assert property (@(posedge clk) disable iff (!rst_n) !err2_q || (dp_valid && dp_err) );
    h_wbuf_vs_dphase: assert property (@(posedge clk) disable iff (!rst_n)
        !(wb_v && dp_valid && dp_write && !dp_err) );
    wire [31:0] cur;
    genvar l;
    generate for (l = 0; l < 4; l = l + 1) begin : g_l
        assign cur[8*l +: 8] = (wb_v && wb_word == watch && wb_be[l]) ? wb_data[8*l +: 8] : tw[8*l +: 8];
    end endgenerate
    wire [31:0] kn = {{8{ref_known[3]}}, {8{ref_known[2]}}, {8{ref_known[1]}}, {8{ref_known[0]}}};
    h_ref_vs_array: assert property (@(posedge clk) disable iff (!rst_n)
        (cur & kn) == (ref_data & kn) );
    h_read_pending: assert property (@(posedge clk) disable iff (!rst_n)
        !(rd_dp && dp_word == watch) || arr_rdata == tw );
endmodule

bind isram_top mem_fv_helpers #(.AW(14)) u_fv_helpers (
    .clk(hclk_i), .rst_n(hreset_n_i), .watch(u_if.u_mem_sva.watch),
    .ref_data(u_if.u_mem_sva.ref_data), .ref_known(u_if.u_mem_sva.ref_known), .tw(u_array.tw),
    .wb_v(u_if.wb_v), .wb_word(u_if.wb_word), .wb_be(u_if.wb_be), .wb_data(u_if.wb_data),
    .rd_dp(u_if.rd_dp), .dp_word(u_if.dp_word), .arr_rdata(u_if.arr_rdata_i),
    .dp_valid(u_if.dp_valid), .dp_write(u_if.dp_write), .dp_err(u_if.dp_err),
    .env_own_dp(u_fv_env.own_dp), .err2_q(u_if.err2_q),
    .writable(1'b1), .hrdata(hrdata_o));
bind bootrom_top mem_fv_helpers #(.AW(10)) u_fv_helpers (
    .clk(hclk_i), .rst_n(hreset_n_i), .watch(u_if.u_mem_sva.watch),
    .ref_data(u_if.u_mem_sva.ref_data), .ref_known(u_if.u_mem_sva.ref_known), .tw(u_array.tw),
    .wb_v(u_if.wb_v), .wb_word(u_if.wb_word), .wb_be(u_if.wb_be), .wb_data(u_if.wb_data),
    .rd_dp(u_if.rd_dp), .dp_word(u_if.dp_word), .arr_rdata(u_if.arr_rdata_i),
    .dp_valid(u_if.dp_valid), .dp_write(u_if.dp_write), .dp_err(u_if.dp_err),
    .env_own_dp(u_fv_env.own_dp), .err2_q(u_if.err2_q),
    .writable(1'b0), .hrdata(hrdata_o));
bind dsram_top mem_fv_helpers #(.AW(14)) u_fv_helpers (
    .clk(hclk_i), .rst_n(hreset_n_i), .watch(u_if.u_mem_sva.watch),
    .ref_data(u_if.u_mem_sva.ref_data), .ref_known(u_if.u_mem_sva.ref_known),
    .tw(u_if.u_mem_sva.watch[13:12] == 2'd0 ? g_bank[0].u_array.tw :
        u_if.u_mem_sva.watch[13:12] == 2'd1 ? g_bank[1].u_array.tw :
        u_if.u_mem_sva.watch[13:12] == 2'd2 ? g_bank[2].u_array.tw : g_bank[3].u_array.tw),
    .wb_v(u_if.wb_v), .wb_word(u_if.wb_word), .wb_be(u_if.wb_be), .wb_data(u_if.wb_data),
    .rd_dp(u_if.rd_dp), .dp_word(u_if.dp_word), .arr_rdata(u_if.arr_rdata_i),
    .dp_valid(u_if.dp_valid), .dp_write(u_if.dp_write), .dp_err(u_if.dp_err),
    .env_own_dp(u_fv_env.own_dp), .err2_q(u_if.err2_q),
    .writable(1'b1), .hrdata(hrdata_o));
