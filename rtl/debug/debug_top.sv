// =============================================================================
// GARUDA SoC - Block 12 : debug subsystem
// debug_top.v - jtag_tap + debug_dtm (tck) | dmi_cdc | debug_module +
// sba_master (hclk)
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 (Rev 4.0 set); ADR-0012, ADR-0014
//
// 4-wire JTAG, no TRST ([N-5.1]). System Bus Access is AHB master M2. The
// only asynchronous crossing in the chip is inside dmi_cdc ([N-7.16]).
// =============================================================================

module debug_top
    import garuda_pkg::*;
(
    // ---- JTAG pins ----------------------------------------------------------
    input wire tck,
    input wire tms_i,
    input wire tdi_i,
    output wire tdo_o,
    output wire tdo_oe_o,
    input wire ext_rst_n,  // ext_rst_n pin (TAP power-on reset)
    // ---- hclk side ----------------------------------------------------------
    input wire hclk,
    input wire dm_rst_n,  // reset_ctrl.dm_rst_n (excludes ndmreset)
    output wire ndmreset_o,
    output wire hartreset_o,
    output wire halt_req_o,  // RDC-1: to the core (drain before the reset)
    input wire halt_safe_i,  // RDC-1: from the core (no bus transfer in flight)
    input wire [ACC_W-1:0] dsu_acc0_i,
    input wire [ACC_W-1:0] dsu_acc1_i,
    input wire [ACC_W-1:0] dsu_acc2_i,
    input wire dsu_ovf_i,
    // ---- AHB-Lite master M2 (SBA) -------------------------------------------
    output wire [WORD_W-1:0] haddr_o,
    output wire [HTRANS_W-1:0] htrans_o,
    output wire hwrite_o,
    output wire [HSIZE_W-1:0] hsize_o,
    output wire [HBURST_W-1:0] hburst_o,
    output wire [WORD_W-1:0] hwdata_o,
    input wire [WORD_W-1:0] hrdata_i,
    input wire hready_i,
    input wire hresp_i
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [JTAG_IR_W-1:0]  ir;
    wire tlr;
    wire cap_dr;
    wire sh_dr;
    wire up_dr;
    wire dr_tdo;
    wire req_tgl;
    wire ack_tgl_sync;
    wire [DMI_ADDR_W-1:0]  req_addr;
    wire [WORD_W-1:0] req_data;
    wire [DMI_OP_W-1:0]  req_op;
    wire req_pulse;
    wire dm_done;
    wire [WORD_W-1:0] dm_rdata;

    jtag_tap u_tap (
        .tck(tck), .tms_i(tms_i), .tdi_i(tdi_i), .ext_rst_n(ext_rst_n),
        .tdo_o(tdo_o), .tdo_oe_o(tdo_oe_o), .ir_o(ir), .tlr_o(tlr),
        .capture_dr_o(cap_dr), .shift_dr_o(sh_dr), .update_dr_o(up_dr),
            .dr_tdo_i(dr_tdo));

    debug_dtm u_dtm (
        .tck(tck), .ext_rst_n(ext_rst_n), .tdi_i(tdi_i), .ir_i(ir), .tlr_i(tlr),
        .capture_dr_i(cap_dr), .shift_dr_i(sh_dr), .update_dr_i(up_dr),
            .dr_tdo_o(dr_tdo),
        .req_tgl_o(req_tgl), .req_addr_o(req_addr), .req_data_o(req_data),
            .req_op_o(req_op),
        .ack_tgl_i(ack_tgl_sync), .rsp_data_i(dm_rdata));

    dmi_cdc u_cdc (
        .tck(tck), .ext_rst_n(ext_rst_n), .req_tgl_i(req_tgl),
            .ack_tgl_sync_o(ack_tgl_sync),
        .hclk(hclk), .dm_rst_n(dm_rst_n), .req_pulse_o(req_pulse),
        .ack_pulse_i(dm_done));

    wire sba_start;
    wire sba_write;
    wire sba_done;
    wire sba_err;
    wire sba_busy;
    wire [WORD_W-1:0] sba_addr;
    wire [WORD_W-1:0] sba_wdata;
    wire [WORD_W-1:0] sba_rdata;

    debug_module u_dm (
        .hclk(hclk), .dm_rst_n(dm_rst_n),
        .req_i(req_pulse), .addr_i(req_addr), .wdata_i(req_data), .op_i(req_op),
        .rdata_o(dm_rdata), .done_o(dm_done),
        .ndmreset_o(ndmreset_o), .hartreset_o(hartreset_o),
        .halt_req_o(halt_req_o), .halt_safe_i(halt_safe_i),
        .dsu_acc0_i(dsu_acc0_i), .dsu_acc1_i(dsu_acc1_i),
            .dsu_acc2_i(dsu_acc2_i),
        .dsu_ovf_i(dsu_ovf_i),
        .sba_start_o(sba_start), .sba_write_o(sba_write), .sba_addr_o(sba_addr),
        .sba_wdata_o(sba_wdata), .sba_done_i(sba_done), .sba_err_i(sba_err),
        .sba_rdata_i(sba_rdata), .sba_busy_i(sba_busy));

    sba_master u_sba (
        .hclk(hclk), .dm_rst_n(dm_rst_n),
        .start_i(sba_start), .write_i(sba_write), .addr_i(sba_addr),
            .wdata_i(sba_wdata),
        .done_o(sba_done), .err_o(sba_err), .rdata_o(sba_rdata),
            .busy_o(sba_busy),
        .haddr_o(haddr_o), .htrans_o(htrans_o), .hwrite_o(hwrite_o),
            .hsize_o(hsize_o),
        .hburst_o(hburst_o), .hwdata_o(hwdata_o), .hrdata_i(hrdata_i),
        .hready_i(hready_i), .hresp_i(hresp_i));

endmodule
