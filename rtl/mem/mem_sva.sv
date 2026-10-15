`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Blocks 10, 11, 13 : properties for the memories
// mem_sva.sv
//
// Spec: GARUDA-MEM-SPEC-001 section 7 and AHB-Lite. Bound to ahb_mem_slave_if,
// the AHB front end the ISRAM, the DSRAM and the Boot ROM share, so each memory
// gets its own copy.
//
// Data integrity end to end (front end, write buffer, read bypass, banks, array):
//   simulation  a reference model of every byte the bus has written; every read
//               must return it. A bench that writes the array through the backdoor
//               calls forget_all() afterwards.
//   formal      (+define+FORMAL) one word, chosen freely by the tool and then held,
//               is tracked: proving it for an arbitrary word proves it for all.
// Not compiled for synthesis or lint, and not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module mem_sva #(
    parameter integer AW = 14,
    parameter integer WRITABLE = 1
)(
    input wire        hclk_i, hreset_n_i,
    input wire        hsel_i, hwrite_i, hready_i,
    input wire [1:0]  htrans_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] haddr_i, hwdata_i, hrdata_o,
    input wire        hreadyout_o, hresp_o,
    input wire        wr_lock_i, lock_bypass_i,
    input wire        arr_ce_o, arr_we_o,
    // internals
    input wire        accept, misaligned, ro_write, lock_write, rd_now,
    input wire        dp_valid, dp_write, dp_err,
    input wire [AW-1:0] dp_word,
    input wire [3:0]  dp_be,
    input wire        wb_v, park_wr, commit_wb, rd_dp, byp
);
    wire wr_done = dp_valid && dp_write && !dp_err && hready_i;
    // what the spec says, computed here from HADDR and HSIZE, not taken from the RTL
    wire spec_misaligned = (hsize_i == 3'd2 && haddr_i[1:0] != 2'b00) || (hsize_i == 3'd1 && haddr_i[0]) || (hsize_i > 3'd2);
    wire [3:0] spec_be = (hsize_i == 3'd0) ? (4'b0001 << haddr_i[1:0]) :
                         (hsize_i == 3'd1) ? (haddr_i[1] ? 4'b1100 : 4'b0011) : 4'b1111;
    reg [3:0] exp_be; reg [AW-1:0] exp_word;
    always @(posedge hclk_i) if (hready_i && hsel_i && htrans_i[1]) begin exp_be <= spec_be; exp_word <= haddr_i[AW+1:2]; end
    wire rd_done = rd_dp && hready_i;

    // ======================= AHB slave ========================================
    // [N-7.5] zero wait states: HREADYOUT is low only in the first ERROR cycle
    a_zero_wait: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !hreadyout_o |-> hresp_o )
        else $error("[SVA-FAIL] a_zero_wait: a wait state that is not an ERROR cycle");
    a_err_two_cycles: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hresp_o && !hreadyout_o) |=> (hresp_o && hreadyout_o) )
        else $error("[SVA-FAIL] a_err_two_cycles: ERROR is not the two-cycle response");
    a_okay_otherwise: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hresp_o |-> (dp_valid && dp_err) )
        else $error("[SVA-FAIL] a_okay_otherwise: ERROR for an access that was legal");
    // what is refused: misaligned, any size above a word, a write to the ROM, a locked ISRAM write
    // that does not come from the debugger ([N-7.9])
    a_misaligned_refused: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hsel_i && hready_i && htrans_i[1] && spec_misaligned) |=> (hresp_o && !hreadyout_o) )
        else $error("[SVA-FAIL] a_misaligned_refused: a misaligned access was not refused");
    a_rom_write_refused: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (accept && hwrite_i && WRITABLE == 0) |=> hresp_o )
        else $error("[SVA-FAIL] a_rom_write_refused: a write to the ROM was not refused");
    a_lock_refused: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (accept && hwrite_i && wr_lock_i && !lock_bypass_i) |=> hresp_o )
        else $error("[SVA-FAIL] a_lock_refused: a locked ISRAM write was accepted");
    a_lock_bypass: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (accept && hwrite_i && wr_lock_i && lock_bypass_i && !misaligned && WRITABLE == 1) |=> !hresp_o )
        else $error("[SVA-FAIL] a_lock_bypass: the debugger's write to a locked ISRAM was refused");
    // the byte lanes and the word of a data phase are the ones the address phase asked for
    a_byte_lanes: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (dp_valid && !dp_err) |-> (dp_be == exp_be && dp_word == exp_word) )
        else $error("[SVA-FAIL] a_byte_lanes: the data phase uses other byte lanes or another word than were asked for");
    // the array is never written by a refused access, and one access per cycle
    a_no_write_on_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (dp_valid && dp_err) |-> !(arr_we_o && !commit_wb) )
        else $error("[SVA-FAIL] a_no_write_on_error: a refused write reached the array");
    a_rom_never_written: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        WRITABLE == 0 |-> !arr_we_o )
        else $error("[SVA-FAIL] a_rom_never_written: the ROM array was written");
    // the one-entry write buffer never overflows
    a_wbuf_no_overflow: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !(park_wr && wb_v && !commit_wb) )
        else $error("[SVA-FAIL] a_wbuf_no_overflow: a write was parked over a parked write");
    // read data is zero outside a read data phase
    a_rdata_quiet: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !rd_dp |-> hrdata_o == 32'd0 )
        else $error("[SVA-FAIL] a_rdata_quiet: read data outside a read");

    // ======================= data integrity ===================================
    function automatic [31:0] lanes(input [3:0] be);
        lanes = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
    endfunction
`ifdef FORMAL
    function void forget(int w); endfunction
    function void forget_all(); endfunction
    wire [AW-1:0] watch;                          // undriven: the tool chooses it
    assume_watch_fixed: assume property (@(posedge hclk_i) $stable(watch));
    reg [31:0] ref_data; reg [3:0] ref_known;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) ref_known <= 4'd0;
        else if (wr_done && exp_word == watch) begin
            ref_data  <= (ref_data & ~lanes(exp_be)) | (hwdata_i & lanes(exp_be));
            ref_known <= ref_known | exp_be;
        end
    a_data_integrity: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (rd_done && exp_word == watch) |-> ((hrdata_o & lanes(ref_known)) == (ref_data & lanes(ref_known))) )
        else $error("[SVA-FAIL] a_data_integrity: a read did not return what was written");
`else
    // 4-state: an X the bus wrote (a register the core never initialised) must read back as X
    logic [31:0] model [int];
    bit   [3:0]  known [int];
    function void forget_all(); model.delete(); known.delete(); endfunction
    // the memory's backdoor (bd_write) calls this for the word it overwrote behind the bus
    function void forget(int w); if (known.exists(w)) begin known.delete(w); model.delete(w); end endfunction
    always @(posedge hclk_i) if (hreset_n_i) begin
        if (rd_done && known.exists(exp_word)) begin
            a_data_integrity: assert ((hrdata_o & lanes(known[exp_word])) === (model[exp_word] & lanes(known[exp_word])))
                else $error("[SVA-FAIL] a_data_integrity: word %0h read %h, expected %h on lanes %b",
                            exp_word, hrdata_o, model[exp_word], known[exp_word]);
        end
        if (wr_done) begin
            if (!known.exists(exp_word)) begin known[exp_word] = 4'd0; model[exp_word] = 32'd0; end
            model[exp_word] = (model[exp_word] & ~lanes(exp_be)) | (hwdata_i & lanes(exp_be));
            known[exp_word] = known[exp_word] | exp_be;
        end
    end
`endif

    // ======================= reachability =====================================
    c_bypass:      cover property (@(posedge hclk_i) rd_done && byp);
    c_park:        cover property (@(posedge hclk_i) park_wr);
    c_commit:      cover property (@(posedge hclk_i) commit_wb);
    c_misaligned:  cover property (@(posedge hclk_i) accept && misaligned);
    c_lock:        cover property (@(posedge hclk_i) accept && lock_write);
    c_lock_bypass: cover property (@(posedge hclk_i) accept && hwrite_i && wr_lock_i && lock_bypass_i);
    c_write_read:  cover property (@(posedge hclk_i) wr_done ##1 rd_done);
endmodule

bind ahb_mem_slave_if mem_sva #(.AW(AW), .WRITABLE(WRITABLE)) u_mem_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .hwrite_i(hwrite_i),
    .hready_i(hready_i), .htrans_i(htrans_i), .hsize_i(hsize_i), .haddr_i(haddr_i),
    .hwdata_i(hwdata_i), .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o), .hresp_o(hresp_o),
    .wr_lock_i(wr_lock_i), .lock_bypass_i(lock_bypass_i), .arr_ce_o(arr_ce_o), .arr_we_o(arr_we_o),
    .accept(accept), .misaligned(misaligned), .ro_write(ro_write), .lock_write(lock_write),
    .rd_now(rd_now), .dp_valid(dp_valid), .dp_write(dp_write), .dp_err(dp_err),
    .dp_word(dp_word), .dp_be(dp_be), .wb_v(wb_v), .park_wr(park_wr), .commit_wb(commit_wb),
    .rd_dp(rd_dp), .byp(byp));
`endif
`endif
