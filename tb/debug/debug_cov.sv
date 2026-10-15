`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 12 : functional coverage of the debug block
// debug_cov.sv
//
// From GARUDA-DEBUG-SPEC-001 sections 6 and 7 (the DTM and DM register maps,
// system bus access). Bound to debug_top.
//   cg_dmi   one sample per DMI access reaching the DM: register x operation x DM state
//   cg_sba   one sample per SBA outcome: how it started, how it ended
//   cg_scan  one sample per DMI scan on tck: what the debugger saw
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module debug_cov (
    input wire        tck_i, por_n_i, hclk_i, dm_rst_n_i,
    input wire        req_pulse,
    input wire [6:0]  req_addr,
    input wire [1:0]  req_op,
    input wire [31:0] req_data,
    input wire        dmactive, sbbusy, sbautoinc, sbreadonaddr, sbreadondata, sbbusyerror,
    input wire [2:0]  sberror, sbaccess,
    input wire        sba_done, sba_err, sba_write,
    input wire        capture_dr,
    input wire [4:0]  ir,
    input wire [1:0]  dmistat,
    input wire        busy
);
    covergroup cg_dmi @(posedge hclk_i iff (dm_rst_n_i && req_pulse));
        option.per_instance = 1;
        cp_reg: coverpoint req_addr {
            bins dmcontrol = {7'h10}; bins dmstatus = {7'h11}; bins abstractcs = {7'h16};
            bins sbcs = {7'h38}; bins sbaddress0 = {7'h39}; bins sbdata0 = {7'h3C};
            bins dsu_acc[] = {[7'h60:7'h65]}; bins dsu_ovf = {7'h66}; bins unimplemented = default;
        }
        cp_op: coverpoint req_op { bins read = {1}; bins write = {2}; }
        cp_active: coverpoint dmactive { bins inactive = {0}; bins active = {1}; }
        cp_busy: coverpoint sbbusy { bins idle = {0}; bins busy = {1}; }
        x_reg_op: cross cp_reg, cp_op {
            ignore_bins ro = (binsof(cp_reg.dmstatus) || binsof(cp_reg.dsu_acc) || binsof(cp_reg.dsu_ovf)) && binsof(cp_op.write);
        }
        // every SBA register touched while the DM is inactive and while a transfer runs
        x_sba_reg_state: cross cp_reg, cp_op, cp_active, cp_busy {
            ignore_bins other = !binsof(cp_reg.sbcs) && !binsof(cp_reg.sbaddress0) && !binsof(cp_reg.sbdata0);
            ignore_bins inactive_busy = binsof(cp_active.inactive) && binsof(cp_busy.busy);
        }
    endgroup

    // SBA outcomes
    typedef enum {SBA_OK, SBA_BUS_ERR, SBA_UNALIGNED, SBA_SIZE, SBA_BUSYERR} sba_e;
    sba_e sba_out; reg sba_ev; reg [2:0] sberror_d; reg sbbusyerror_d;
    always @(posedge hclk_i) begin sberror_d <= sberror; sbbusyerror_d <= sbbusyerror; end
    always @(*) begin
        sba_ev = 1'b0; sba_out = SBA_OK;
        if (sba_done) begin sba_ev = 1; sba_out = sba_err ? SBA_BUS_ERR : SBA_OK; end
        else if (sberror == 3'd2 && sberror_d != 3'd2) begin sba_ev = 1; sba_out = SBA_UNALIGNED; end
        else if (sberror == 3'd3 && sberror_d != 3'd3) begin sba_ev = 1; sba_out = SBA_SIZE; end
        else if (sbbusyerror && !sbbusyerror_d) begin sba_ev = 1; sba_out = SBA_BUSYERR; end
    end
    covergroup cg_sba @(posedge hclk_i iff (dm_rst_n_i && sba_ev));
        option.per_instance = 1;
        cp_out: coverpoint sba_out;
        cp_dir: coverpoint sba_write;
        cp_autoinc: coverpoint sbautoinc;
        cp_trigger: coverpoint {sbreadonaddr, sbreadondata} { bins none = {0}; bins on_data = {1}; bins on_addr = {2}; bins both = {3}; }
        x_out_dir: cross cp_out, cp_dir { ignore_bins na = !binsof(cp_out) intersect {SBA_OK, SBA_BUS_ERR}; }
        x_ok_autoinc: cross cp_out, cp_autoinc, cp_dir { ignore_bins na = !binsof(cp_out) intersect {SBA_OK}; }
    endgroup

    // what a DMI scan reported, on tck
    covergroup cg_scan @(posedge tck_i iff (por_n_i && capture_dr && ir == 5'h11));
        option.per_instance = 1;
        cp_status: coverpoint (busy ? 2'd3 : dmistat) { bins ok = {0}; bins busy = {3}; ignore_bins failed = {2}; }
        cp_sticky: coverpoint dmistat { bins clear = {0}; bins sticky_busy = {3}; }
    endgroup
    cg_dmi cd = new(); cg_sba cs = new(); cg_scan cn = new();
endmodule

bind debug_top debug_cov u_debug_cov (
    .tck_i(tck_i), .por_n_i(por_n_i), .hclk_i(hclk_i), .dm_rst_n_i(dm_rst_n_i),
    .req_pulse(req_pulse), .req_addr(req_addr), .req_op(req_op), .req_data(req_data),
    .dmactive(u_dm.dmactive), .sbbusy(u_dm.sbbusy), .sbautoinc(u_dm.sbautoinc),
    .sbreadonaddr(u_dm.sbreadonaddr), .sbreadondata(u_dm.sbreadondata), .sbbusyerror(u_dm.sbbusyerror),
    .sberror(u_dm.sberror), .sbaccess(u_dm.sbaccess),
    .sba_done(sba_done), .sba_err(sba_err), .sba_write(u_dm.pending_write),
    .capture_dr(cap_dr), .ir(ir), .dmistat(u_dtm.dmistat), .busy(u_dtm.busy));
`endif
`endif
`endif
