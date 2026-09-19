`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 12 : Debug Transport Module (tck domain)
// dtm.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 §6.1-§6.3; RISC-V Debug 0.13 §6.1
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

module dtm (
    input  wire        tck_i,
    input  wire        por_n_i,
    input  wire        tdi_i,
    input  wire [4:0]  ir_i,
    input  wire        tlr_i,
    input  wire        capture_dr_i,
    input  wire        shift_dr_i,
    input  wire        update_dr_i,
    output wire        dr_tdo_o,

    // ---- to / from dmi_cdc (tck side) ------------------------------------------
    output reg         req_tgl_o,
    output reg  [6:0]  req_addr_o,
    output reg  [31:0] req_data_o,
    output reg  [1:0]  req_op_o,
    input  wire        ack_tgl_i,          // already synchronised into tck
    input  wire [31:0] rsp_data_i,         // stable once ack is seen
    input  wire        rsp_err_i
);

    localparam [31:0] IDCODE = 32'h0000_0DB1;
    localparam [4:0]  IR_IDCODE = 5'h01, IR_DTMCS = 5'h10, IR_DMI = 5'h11;

    reg [40:0] sh;
    reg        bypass;
    reg        ack_seen;
    reg [1:0]  dmistat;
    reg [31:0] rsp_q;

    wire busy = (req_tgl_o != ack_seen);

    wire [31:0] dtmcs = {14'd0, 1'b0 /*hardreset*/, 1'b0 /*dmireset*/, 1'b0,
                         3'd5 /*idle*/, dmistat, 6'd7 /*abits*/, 4'd1 /*version*/};

    always @(posedge tck_i or negedge por_n_i) begin
        if (!por_n_i) begin
            sh <= 41'd0; bypass <= 1'b0;
            req_tgl_o <= 1'b0; req_addr_o <= 7'd0; req_data_o <= 32'd0; req_op_o <= 2'd0;
            ack_seen <= 1'b0; dmistat <= 2'd0; rsp_q <= 32'd0;
        end else begin
            // response arrival
            if (busy && ack_tgl_i == req_tgl_o) begin
                ack_seen <= ack_tgl_i;
                rsp_q    <= rsp_data_i;
                if (rsp_err_i && dmistat == 2'd0) dmistat <= 2'd2;
            end

            if (tlr_i) begin
                dmistat <= 2'd0;
            end else if (capture_dr_i) begin
                case (ir_i)
                    IR_IDCODE: sh <= {9'd0, IDCODE};
                    IR_DTMCS:  sh <= {9'd0, dtmcs};
                    IR_DMI:    sh <= {req_addr_o, rsp_q, busy ? 2'd3 : dmistat};
                    default:   bypass <= 1'b0;
                endcase
            end else if (shift_dr_i) begin
                case (ir_i)
                    IR_IDCODE, IR_DTMCS: sh <= {9'd0, tdi_i, sh[31:1]};
                    IR_DMI:              sh <= {tdi_i, sh[40:1]};
                    default:             bypass <= tdi_i;
                endcase
            end else if (update_dr_i) begin
                if (ir_i == IR_DTMCS) begin
                    if (sh[16] || sh[17]) dmistat <= 2'd0;     // dmireset / dmihardreset
                end else if (ir_i == IR_DMI && (sh[1:0] == 2'd1 || sh[1:0] == 2'd2)) begin
                    if (busy)                  dmistat <= 2'd3; // sticky busy
                    else if (dmistat == 2'd0) begin
                        req_addr_o <= sh[40:34];
                        req_data_o <= sh[33:2];
                        req_op_o   <= sh[1:0];
                        req_tgl_o  <= ~req_tgl_o;
                    end
                end
            end
        end
    end

    assign dr_tdo_o = (ir_i == IR_IDCODE || ir_i == IR_DTMCS || ir_i == IR_DMI) ? sh[0] : bypass;

endmodule

`default_nettype wire
