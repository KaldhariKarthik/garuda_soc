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

// =============================================================================
// mem_cov_vplan -- Track A functional model named after the vPlan rows
// (tb/mem/GARUDA_MEM_vplan.csv, cg_mem / cg_ilock; plan 6A.6 M3). Portable: explicit
// bins only, no `with` filters and no binsof crosses, so Verilator, Xcelium and IMC count
// the same bins. Sampled from the bus (spec level), one instance per memory; KIND
// 0 = ISRAM, 1 = DSRAM, 2 = Boot ROM. Karthik's cg_access above stays the Xcelium model.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module mem_cov_vplan #(parameter integer KIND = 0) (
    input wire        hclk_i, hreset_n_i,
    input wire        hsel_i, hready_i, hwrite_i, ilock_i, sba_i,
    input wire [1:0]  htrans_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] haddr_i,
    input wire        hresp_o
);
    wire acc = hsel_i && hready_i && htrans_i[1];
    // size and offset as one code: 0-3 byte at lane 0-3, 4/5 half at 0/2, 6 word at 0;
    // 8 half at 1, 9 half at 3, 10 word at 1, 11 word at 2, 12 word at 3, 13 wider than a word
    reg [3:0] so;
    always @(*) begin
        case (hsize_i)
            3'd0:    so = {2'b00, haddr_i[1:0]};
            3'd1:    so = haddr_i[0] ? (haddr_i[1] ? 4'd9 : 4'd8) : (haddr_i[1] ? 4'd5 : 4'd4);
            3'd2:    so = (haddr_i[1:0] == 2'd0) ? 4'd6 : 4'd9 + {2'b00, haddr_i[1:0]};
            default: so = 4'd13;
        endcase
    end
    reg       prev_v, prev_w;          // the previous accepted transfer (back to back: no idle between)
    reg [29:0] prev_word;
    reg       prev_sba, idle_gap;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) begin prev_v <= 1'b0; idle_gap <= 1'b1; end
        else if (hready_i) begin
            if (acc) begin prev_v <= 1'b1; prev_w <= hwrite_i; prev_word <= haddr_i[31:2]; prev_sba <= sba_i; idle_gap <= 1'b0; end
            else if (!hsel_i || !htrans_i[1]) idle_gap <= 1'b1;
        end
    wire [13:0] word = haddr_i[15:2];

    covergroup cg_mem @(posedge hclk_i iff (hreset_n_i && acc));
        // F04 the seven legal size/offset combinations, F05 the illegal ones, by direction
        cp_dir: coverpoint hwrite_i { bins read = {0}; bins write = {1}; }
        cp_so: coverpoint so {
            bins byte0 = {0}; bins byte1 = {1}; bins byte2 = {2}; bins byte3 = {3};
            bins half0 = {4}; bins half2 = {5}; bins word0 = {6}; }
        cp_misaligned: coverpoint so {
            bins half1 = {8}; bins half3 = {9}; bins word1 = {10}; bins word2 = {11}; bins word3 = {12};
            bins wider = {13}; }
        x_size_offset_mem: cross cp_dir, cp_so;
        // F06 an address above the memory's size (alias inside the 256 MiB granule)
        cp_alias: coverpoint (KIND == 2 ? |haddr_i[27:12] : |haddr_i[27:16]) { bins in_range = {0}; bins aliased = {1}; }
        // F07 back to back: what the previous transfer was, with no idle between
        cp_b2b: coverpoint {idle_gap, prev_w, hwrite_i, prev_word == haddr_i[31:2]} {
            bins rd_after_rd   = {4'b0000, 4'b0001};
            bins wr_after_rd   = {4'b0010, 4'b0011};
            bins rd_after_wr_other = {4'b0100};
            bins rd_after_wr_same  = {4'b0101};
            bins wr_after_wr   = {4'b0110, 4'b0111};
            bins after_idle    = {[4'b1000:4'b1111]}; }
    endgroup
    // F01 the ISRAM's first, last and other words; F02 each DSRAM bank's first, last and
    // inner word (contiguous across the banks)
    covergroup cg_mem_addr @(posedge hclk_i iff (hreset_n_i && acc && KIND != 2));
        cp_isram_addr: coverpoint word iff (KIND == 0) { bins first = {0}; bins last = {16383}; bins inner = {[1:16382]}; }
        cp_dsram_boundary: coverpoint word iff (KIND == 1) {
            bins b0_first = {0};     bins b0_inner = {[1:4094]};      bins b0_last = {4095};
            bins b1_first = {4096};  bins b1_inner = {[4097:8190]};   bins b1_last = {8191};
            bins b2_first = {8192};  bins b2_inner = {[8193:12286]};  bins b2_last = {12287};
            bins b3_first = {12288}; bins b3_inner = {[12289:16382]}; bins b3_last = {16383}; }
    endgroup
    // F11-F13 the ISRAM lock: lock x master x direction, and the master changing between
    // two back-to-back transfers while the lock is set
    covergroup cg_ilock @(posedge hclk_i iff (hreset_n_i && acc && KIND == 0));
        cp_lock: coverpoint ilock_i { bins open = {0}; bins locked = {1}; }
        cp_master: coverpoint sba_i { bins cpu_or_dma = {0}; bins debugger = {1}; }
        cp_dir: coverpoint hwrite_i { bins read = {0}; bins write = {1}; }
        x_lock_master_dir: cross cp_lock, cp_master, cp_dir;
        cp_master_switch: coverpoint {idle_gap, ilock_i, prev_sba, sba_i} {
            bins locked_to_debugger = {4'b0101}; bins locked_from_debugger = {4'b0110}; }
    endgroup
    cg_mem      c_mem  = new();
    cg_mem_addr c_addr = new();
    cg_ilock    c_lock = new();
endmodule

bind isram_top mem_cov_vplan #(.KIND(0)) u_mem_cov_vplan (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .hready_i(hready_i),
    .hwrite_i(hwrite_i), .ilock_i(ilock_i), .sba_i(hmaster_is_sba_i), .htrans_i(htrans_i),
    .hsize_i(hsize_i), .haddr_i(haddr_i), .hresp_o(hresp_o));
bind dsram_top mem_cov_vplan #(.KIND(1)) u_mem_cov_vplan (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .hready_i(hready_i),
    .hwrite_i(hwrite_i), .ilock_i(1'b0), .sba_i(1'b0), .htrans_i(htrans_i),
    .hsize_i(hsize_i), .haddr_i(haddr_i), .hresp_o(hresp_o));
bind bootrom_top mem_cov_vplan #(.KIND(2)) u_mem_cov_vplan (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .hready_i(hready_i),
    .hwrite_i(hwrite_i), .ilock_i(1'b0), .sba_i(1'b0), .htrans_i(htrans_i),
    .hsize_i(hsize_i), .haddr_i(haddr_i), .hresp_o(hresp_o));
`endif
`endif
