// =============================================================================
// GARUDA SoC - Block 12 : Debug Transport Module (tck domain)
// debug_dtm.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 Sec.6.1-Sec.6.3; RISC-V Debug 0.13
// Sec.6.1
//
//   IR 0x01 IDCODE  0x0000_0DB1          IR 0x10 DTMCS
//   IR 0x11 DMI     {addr[7], data[32], op[2]}   others -> BYPASS
//
// DTMCS: version 1, abits 7, idle 5 ([N-6.2]), dmistat, dmireset (W1),
// dmihardreset (W1).
//
// DMI: on Update-DR with op = read/write and no request in flight, the
// request is launched through dmi_cdc (req toggle). While a request is in
// flight a new one is refused and dmistat goes sticky-busy (3). On
// Capture-DR the register returns {last addr, last read data, status}.
// =============================================================================

module debug_dtm
    import garuda_pkg::*;
(
    input wire tck,
    input wire ext_rst_n,
    input wire tdi_i,
    input wire [JTAG_IR_W-1:0] ir_i,
    input wire tlr_i,
    input wire capture_dr_i,
    input wire shift_dr_i,
    input wire update_dr_i,
    output wire dr_tdo_o,
    // ---- to / from dmi_cdc (tck side) ---------------------------------------
    output reg req_tgl_o,
    output reg [DMI_ADDR_W-1:0] req_addr_o,
    output reg [WORD_W-1:0] req_data_o,
    output reg [DMI_OP_W-1:0] req_op_o,
    input wire ack_tgl_i,  // already synchronised into tck
    input wire [WORD_W-1:0] rsp_data_i  // stable once ack is seen
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned SH_W = 32'd41;
    localparam int unsigned DMISTAT_W = 32'd2;

    localparam [31:0] IDCODE = 32'h0000_0DB1;
    localparam [4:0]  IR_IDCODE = 5'h01, IR_DTMCS = 5'h10, IR_DMI = 5'h11;

    reg [SH_W-1:0] sh;
    reg        bypass;
    reg        ack_seen;
    // DMISTAT is 0 or 3 (sticky busy): the DM never reports a failed
    // operation, so the code 2 is never set (F4: rsp_err_i, tied to 0 at the
    // one instance, is gone and the field is one flag)
    reg        busy_err;
    wire [DMISTAT_W-1:0] dmistat = {DMISTAT_W{busy_err}};
    reg [WORD_W-1:0] rsp_q;

    wire busy = (req_tgl_o != ack_seen);

    wire [WORD_W-1:0] dtmcs = {14'd0, 1'b0, 1'b0, 1'b0,
                               3'd5, dmistat, 6'd7, 4'd1};

    // F4 (2026-11-17): one process per register (HAL MULNBA)
    wire cap_dmi   = capture_dr_i && (ir_i == IR_DMI);
    wire upd_dtmcs = update_dr_i && (ir_i == IR_DTMCS);
    wire dmi_op    = (sh[1:0] == 2'd1) || (sh[1:0] == 2'd2);
    wire upd_dmi   = update_dr_i && (ir_i == IR_DMI) && dmi_op;
    wire ack_now   = busy && (ack_tgl_i == req_tgl_o);
    wire issue     = !tlr_i && upd_dmi && !busy && !busy_err;

    always_ff @(posedge tck or negedge ext_rst_n) begin : p_sh
        if (!ext_rst_n) begin
            sh <= 41'd0;
        end else if (tlr_i) begin
            sh <= sh;
        end else if (capture_dr_i) begin
            case (ir_i)
                IR_IDCODE: sh <= {9'd0, IDCODE};
                IR_DTMCS: sh <= {9'd0, dtmcs};
                IR_DMI: sh <= {req_addr_o, rsp_q, busy ? 2'd3 : dmistat};
                default: sh <= sh;
            endcase
        end else if (shift_dr_i) begin
            case (ir_i)
                IR_IDCODE, IR_DTMCS: sh <= {9'd0, tdi_i, sh[31:1]};
                IR_DMI: sh <= {tdi_i, sh[40:1]};
                default: sh <= sh;
            endcase
        end
    end

    // BYPASS: 0 on capture, TDI on shift (any other instruction)
    wire ir_known = (ir_i == IR_IDCODE) || (ir_i == IR_DTMCS)
                    || (ir_i == IR_DMI);
    always_ff @(posedge tck or negedge ext_rst_n) begin : p_bypass
        if (!ext_rst_n) begin
            bypass <= 1'b0;
        end else if (!tlr_i && !ir_known) begin
            if (capture_dr_i) begin
                bypass <= 1'b0;
            end else if (shift_dr_i) begin
                bypass <= tdi_i;
            end
        end
    end

    always_ff @(posedge tck or negedge ext_rst_n) begin : p_busy_err
        if (!ext_rst_n) begin
            busy_err <= 1'b0;
        end else if (tlr_i) begin
            busy_err <= 1'b0;
        end else if ((cap_dmi || upd_dmi) && busy) begin
            busy_err <= 1'b1;  // sticky busy
        end else if (upd_dtmcs && (sh[16] || sh[17])) begin
            busy_err <= 1'b0;  // dmireset / dmihardreset
        end
    end

    // a DMI request: address, data and op, and a toggle to the DM's clock
    always_ff @(posedge tck or negedge ext_rst_n) begin : p_req
        if (!ext_rst_n) begin
            req_tgl_o <= 1'b0;
            req_addr_o <= 7'd0;
            req_data_o <= 32'd0;
            req_op_o <= 2'd0;
        end else if (issue) begin
            req_addr_o <= sh[40:34];
            req_data_o <= sh[33:2];
            req_op_o <= sh[1:0];
            req_tgl_o <= ~req_tgl_o;
        end
    end

    // the DM's answer: seen once its ack toggle matches the request
    always_ff @(posedge tck or negedge ext_rst_n) begin : p_ack
        if (!ext_rst_n) begin
            ack_seen <= 1'b0;
            rsp_q <= 32'd0;
        end else if (ack_now) begin
            ack_seen <= ack_tgl_i;
            rsp_q <= rsp_data_i;
        end
    end

    assign dr_tdo_o = (ir_i == IR_IDCODE || ir_i == IR_DTMCS || ir_i == IR_DMI)
        ? sh[0] : bypass;

endmodule
