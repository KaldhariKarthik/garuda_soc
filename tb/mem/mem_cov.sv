`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Blocks 10, 11, 13 : functional coverage of the memories
// mem_cov.sv
//
// From GARUDA-MEM-SPEC-001 section 7. Bound to ahb_mem_slave_if, so the ISRAM,
// the DSRAM and the Boot ROM each have their own instance (per_instance).
//   cg_access  one sample per accepted address phase: direction, size, byte lane,
//              outcome, and what the write buffer was doing
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module mem_cov #(parameter integer AW = 14, parameter integer WRITABLE = 1) (
    input wire        hclk_i, hreset_n_i,
    input wire        accept, hwrite_i, misaligned, ro_write, lock_write, wr_lock_i, lock_bypass_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] haddr_i,
    input wire        wb_v, dp_valid, dp_write, dp_err,
    input wire [AW-1:0] dp_word, wb_word
);
    typedef enum {OK, MISALIGNED, ROM_WRITE, LOCKED, DEBUG_BYPASS} out_e;
    out_e outcome;
    always @(*) outcome = misaligned ? MISALIGNED : ro_write ? ROM_WRITE : lock_write ? LOCKED :
                          (hwrite_i && wr_lock_i && lock_bypass_i) ? DEBUG_BYPASS : OK;
    wire [AW-1:0] ap_word = haddr_i[AW+1:2];
    covergroup cg_access @(posedge hclk_i iff (hreset_n_i && accept));
        option.per_instance = 1;
        cp_dir: coverpoint hwrite_i { bins read = {0}; bins write = {1}; }
        cp_size: coverpoint hsize_i { bins byte_ = {0}; bins half = {1}; bins word = {2}; bins wider = {[3:7]}; }
        cp_lane: coverpoint haddr_i[1:0];
        cp_outcome: coverpoint outcome {
            ignore_bins rom_only = {ROM_WRITE} with (WRITABLE == 1);
            ignore_bins ram_only = {LOCKED, DEBUG_BYPASS} with (WRITABLE == 0);
        }
        // the write buffer: a read arriving while a write is parked, to the same word and to another
        cp_wbuf: coverpoint {wb_v, wb_v && (wb_word == ap_word)} { bins empty = {2'b00}; bins other_word = {2'b10}; bins same_word = {2'b11}; }
        cp_after: coverpoint (dp_valid && dp_write && !dp_err) { bins after_other = {0}; bins after_write = {1}; }
        x_dir_size_lane: cross cp_dir, cp_size, cp_lane {
            ignore_bins wider = binsof(cp_size.wider);
            ignore_bins rom_writes = binsof(cp_dir.write) with (WRITABLE == 0);
        }
        x_read_wbuf: cross cp_dir, cp_wbuf, cp_after {
            ignore_bins writes = binsof(cp_dir.write);
            ignore_bins rom = binsof(cp_wbuf) with (WRITABLE == 0);
        }
        x_dir_outcome: cross cp_dir, cp_outcome;
    endgroup
    cg_access ca = new();
endmodule

bind ahb_mem_slave_if mem_cov #(.AW(AW), .WRITABLE(WRITABLE)) u_mem_cov (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .accept(accept), .hwrite_i(hwrite_i),
    .misaligned(misaligned), .ro_write(ro_write), .lock_write(lock_write),
    .wr_lock_i(wr_lock_i), .lock_bypass_i(lock_bypass_i), .hsize_i(hsize_i), .haddr_i(haddr_i),
    .wb_v(wb_v), .dp_valid(dp_valid), .dp_write(dp_write), .dp_err(dp_err),
    .dp_word(dp_word), .wb_word(wb_word));
`endif
`endif
`endif
