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

// =============================================================================
// debug_cov_vplan -- Track A functional model named after the vPlan coverage rows
// (tb/debug/GARUDA_DEBUG_vplan.csv; plan 6A.5 G4). Portable: explicit bins only, no
// `with` filters, no binsof crosses, no enum coverpoints, so Verilator, Xcelium and IMC
// count the same bins. Karthik's debug_cov above stays the Xcelium model.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module debug_cov_vplan (
    input wire        tck_i, tms_i, por_n_i, hclk_i, dm_rst_n_i,
    input wire [3:0]  tap_st,
    input wire [4:0]  ir,
    input wire        update_dr, capture_dr,
    input wire [40:0] dtm_sh,
    input wire [1:0]  dmistat,
    input wire        dtm_busy,
    input wire        req_pulse,
    input wire [6:0]  req_addr,
    input wire [1:0]  req_op,
    input wire [31:0] req_data,
    input wire        sbbusy, sba_start, sba_write, sba_done, sba_err,
    input wire [2:0]  sberror,
    input wire [47:0] acc0, acc1, acc2, hold0, hold1, hold2
);
    // ---- tck side ---------------------------------------------------------------------
    reg [3:0] st_q; reg tms_q;
    reg [3:0] st_hist [0:5];
    reg [2:0] tms_run;
    always @(posedge tck_i) begin
        st_q <= tap_st; tms_q <= tms_i;
        st_hist[0] <= tap_st; for (int i = 1; i < 6; i++) st_hist[i] <= st_hist[i-1];
        tms_run <= tms_i ? (tms_run == 3'd7 ? tms_run : tms_run + 3'd1) : 3'd0;
    end
    // hclk activity seen from tck: hclk edges per tck period (ratio) and "hclk stopped"
    reg [7:0] h_cnt = 8'd0, h_per_t = 8'd0;
    reg       h_tgl = 1'b0, h_tgl_q = 1'b0;
    reg [7:0] t_no_h = 8'd0;
    always @(posedge hclk_i) begin h_cnt <= h_cnt + 8'd1; h_tgl <= ~h_tgl; end
    reg [7:0] h_cnt_q = 8'd0;
    always @(posedge tck_i) begin
        h_per_t <= h_cnt - h_cnt_q; h_cnt_q <= h_cnt;
        h_tgl_q <= h_tgl; t_no_h <= (h_tgl != h_tgl_q) ? 8'd0 : (t_no_h == 8'hFF ? t_no_h : t_no_h + 8'd1);
    end
    // F01 every TAP transition, F02 Test-Logic-Reset reached by 5 TMS from each state
    covergroup cg_jtag_tap @(posedge tck_i iff por_n_i);
        cp_transition: coverpoint {st_q, tms_q} { bins t[] = {[0:31]}; }
        cp_reset_from: coverpoint st_hist[5] iff (tms_run == 3'd5) { bins from[] = {[0:15]}; }
    endgroup
    // F03 the instruction register values used
    covergroup cg_jtag_ir @(posedge tck_i iff (por_n_i && tap_st == 4'hF));
        cp_ir: coverpoint ir { bins idcode = {5'h01}; bins dtmcs = {5'h10}; bins dmi = {5'h11};
                               bins bypass = {5'h1F}; bins other = {[5'h02:5'h0F], [5'h12:5'h1E], 5'h00}; }
    endgroup
    // F07 DTMCS writes, F08 DMI op x status of the scan, F10 the system's state during a scan
    covergroup cg_dtm @(posedge tck_i iff (por_n_i && update_dr));
        cp_dtmcs_write: coverpoint dtm_sh[17:16] iff (ir == 5'h10) {
            bins plain = {2'b00}; bins dmireset = {2'b01}; bins dmihardreset = {2'b10}; bins both = {2'b11}; }
        x_op_status: coverpoint {dtm_sh[1:0], dtm_busy} iff (ir == 5'h11) {
            bins nop_ok = {3'b000}; bins nop_busy = {3'b001}; bins read_ok = {3'b010}; bins read_busy = {3'b011};
            bins write_ok = {3'b100}; bins write_busy = {3'b101}; }
    endgroup
    covergroup cg_jtag_env @(posedge tck_i iff (por_n_i && capture_dr));
        cp_sys_state: coverpoint {!dm_rst_n_i, t_no_h > 8'd4} {
            bins running = {2'b00}; bins hclk_stopped = {2'b01}; bins dm_in_reset = {2'b10}; bins both = {2'b11}; }
    endgroup
    // F11 requests at every clock ratio, F12 tck stopped mid-request
    covergroup cg_cdc @(posedge tck_i iff (por_n_i && update_dr && ir == 5'h11 && !dtm_busy));
        x_ratio_phase: coverpoint h_per_t {
            bins tck_faster = {0}; bins similar = {[1:3]}; bins tck_slower = {[4:15]}; bins tck_much_slower = {[16:255]}; }
    endgroup
    reg [9:0] h_no_t = 10'd0; reg t_tgl = 1'b0, t_tgl_q = 1'b0;
    always @(posedge tck_i) t_tgl <= ~t_tgl;
    always @(posedge hclk_i) begin
        t_tgl_q <= t_tgl;
        h_no_t <= (t_tgl != t_tgl_q) ? 10'd0 : (h_no_t == 10'h3FF ? h_no_t : h_no_t + 10'd1);
    end
    covergroup cg_cdc_stop @(posedge hclk_i iff (dm_rst_n_i && dtm_busy));
        cp_tck_stop: coverpoint (h_no_t >= 10'd200) { bins running = {0}; bins stopped_mid_request = {1}; }
    endgroup
    // ---- hclk side ----------------------------------------------------------------------
    reg [6:0] last_addr; reg [1:0] last_op;
    always @(posedge hclk_i) if (req_pulse) begin last_addr <= req_addr; last_op <= req_op; end
    reg [2:0] sberror_q;
    always @(posedge hclk_i) sberror_q <= sberror;
    // F15 dmcontrol writes, F19 every DM address class
    covergroup cg_dm @(posedge hclk_i iff (dm_rst_n_i && req_pulse));
        cp_dmcontrol: coverpoint {req_data[31:29], req_data[1:0]} iff (req_addr == 7'h10 && req_op == 2'd2) {
            bins inactive = {5'b000_00}; bins active = {5'b000_01}; bins ndmreset = {5'b000_11};
            bins hartreset = {5'b001_01}; bins resumereq = {5'b010_01}; bins haltreq = {5'b100_01}; }
        cp_addr: coverpoint req_addr {
            bins dmcontrol = {7'h10}; bins dmstatus = {7'h11}; bins sbcs = {7'h38}; bins sbaddress0 = {7'h39};
            bins sbdata0 = {7'h3C}; bins taps = {[7'h60:7'h65]}; bins dsuovf = {7'h66}; bins haltinfo = {7'h70};
            bins unimplemented = {[7'h00:7'h0F], [7'h12:7'h37], [7'h3A:7'h3B], [7'h3D:7'h5F], [7'h67:7'h6F], [7'h71:7'h7F]}; }
    endgroup
    // F20 kind x trigger, F22 accesses while busy, F24 error kinds
    covergroup cg_sba @(posedge hclk_i iff (dm_rst_n_i && sba_start));
        x_kind_trigger: coverpoint {sba_write, last_addr == 7'h39, last_addr == 7'h3C, last_op == 2'd2} {
            bins read_on_address = {4'b0_1_0_1}; bins read_on_data = {4'b0_0_1_0}; bins write_on_data = {4'b1_0_1_1}; }
    endgroup
    covergroup cg_sba_busy @(posedge hclk_i iff (dm_rst_n_i && req_pulse && sbbusy));
        cp_busy_access: coverpoint {req_addr == 7'h39, req_addr == 7'h3C, req_op} {
            bins address_write = {4'b10_10}; bins data_write = {4'b01_10}; bins data_read = {4'b01_01}; }
    endgroup
    covergroup cg_sba_err @(posedge hclk_i iff (dm_rst_n_i && sberror != 3'd0 && sberror_q == 3'd0));
        x_error_kind: coverpoint {sberror, sba_write} {
            bins unaligned_read = {4'b010_0}; bins unaligned_write = {4'b010_1}; bins size_read = {4'b011_0};
            bins size_write = {4'b011_1}; bins bus_read = {4'b100_0}; bins bus_write = {4'b100_1}; }
    endgroup
    // F30 the high half of a tap read: the accumulator moved since the low-half read, or not
    covergroup cg_taps @(posedge hclk_i iff (dm_rst_n_i && req_pulse && req_op == 2'd1 &&
                                             (req_addr == 7'h61 || req_addr == 7'h63 || req_addr == 7'h65)));
        cp_change_vs_read: coverpoint ((req_addr == 7'h61) ? (acc0 != hold0) : (req_addr == 7'h63) ? (acc1 != hold1) : (acc2 != hold2)) {
            bins unchanged = {0}; bins changed = {1}; }
    endgroup
    cg_jtag_tap c1 = new(); cg_jtag_ir c2 = new(); cg_dtm c3 = new(); cg_jtag_env c4 = new();
    cg_cdc c5 = new(); cg_cdc_stop c6 = new(); cg_dm c7 = new(); cg_sba c8 = new();
    cg_sba_busy c9 = new(); cg_sba_err c10 = new(); cg_taps c11 = new();
endmodule
bind debug_top debug_cov_vplan u_debug_cov_vplan (
    .tck_i(tck_i), .tms_i(tms_i), .por_n_i(por_n_i), .hclk_i(hclk_i), .dm_rst_n_i(dm_rst_n_i),
    .tap_st(u_tap.st), .ir(ir), .update_dr(up_dr), .capture_dr(cap_dr), .dtm_sh(u_dtm.sh),
    .dmistat(u_dtm.dmistat), .dtm_busy(u_dtm.busy), .req_pulse(req_pulse), .req_addr(req_addr),
    .req_op(req_op), .req_data(req_data), .sbbusy(u_dm.sbbusy), .sba_start(sba_start),
    .sba_write(u_dm.sba_write_o), .sba_done(sba_done), .sba_err(sba_err), .sberror(u_dm.sberror),
    .acc0(dsu_acc0_i), .acc1(dsu_acc1_i), .acc2(dsu_acc2_i),
    .hold0(u_dm.hold0), .hold1(u_dm.hold1), .hold2(u_dm.hold2));
`endif
`endif
