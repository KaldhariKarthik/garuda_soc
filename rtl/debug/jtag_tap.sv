// =============================================================================
// GARUDA SoC - Block 12 : IEEE 1149.1 TAP controller + instruction register
// jtag_tap.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 Sec.5.1, Sec.6.1
//
// 16-state TAP, 5-bit IR. No TRST: Test-Logic-Reset is reached by five TCK
// cycles with TMS high ([N-5.1]). The TAP also takes a power-on reset from
// the ext_rst_n pin so it has a defined state at power-up (DECISIONS D-18).
// IR resets to IDCODE (0x01). TDO changes on the FALLING edge of TCK and is
// enabled only in Shift-IR / Shift-DR.
// =============================================================================

module jtag_tap
    import garuda_pkg::*;
(
    input wire tck,
    input wire tms_i,
    input wire tdi_i,
    input wire ext_rst_n,  // ext_rst_n (power-on only)
    output reg tdo_o,
    output reg tdo_oe_o,
    output wire [JTAG_IR_W-1:0] ir_o,
    output wire tlr_o,  // in Test-Logic-Reset
    output wire capture_dr_o,
    output wire shift_dr_o,
    output wire update_dr_o,
    // serial out of the selected DR
    input wire dr_tdo_i
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam [4:0] IR_IDCODE = 5'h01;

    // the TAP states this block acts on (tap_fsm)
    wire cap_ir;
    wire sh_ir;
    wire up_ir;
    tap_fsm u_fsm (
        .tck(tck), .ext_rst_n(ext_rst_n), .tms_i(tms_i),
        .tlr_o(tlr_o), .cap_dr_o(capture_dr_o), .sh_dr_o(shift_dr_o),
        .up_dr_o(update_dr_o), .cap_ir_o(cap_ir), .sh_ir_o(sh_ir),
        .up_ir_o(up_ir)
    );

    // the IR shift register: 01 on Capture-IR (1149.1), TDI in on Shift-IR
    reg [JTAG_IR_W-1:0] ir_sh;
    always_ff @(posedge tck or negedge ext_rst_n) begin : p_ir_sh
        if (!ext_rst_n) begin
            ir_sh <= 5'd0;
        end else if (cap_ir) begin
            ir_sh <= 5'b00001;
        end else if (sh_ir) begin
            ir_sh <= {tdi_i, ir_sh[4:1]};
        end
    end

    // the IR: IDCODE in Test-Logic-Reset, the shifted value on Update-IR
    reg [JTAG_IR_W-1:0] ir_q;
    always_ff @(posedge tck or negedge ext_rst_n) begin : p_ir_q
        if (!ext_rst_n) begin
            ir_q <= IR_IDCODE;
        end else if (tlr_o) begin
            ir_q <= IR_IDCODE;
        end else if (up_ir) begin
            ir_q <= ir_sh;
        end
    end

    assign ir_o = ir_q;

    // TDO changes on the falling edge of TCK (1149.1)
    always_ff @(negedge tck or negedge ext_rst_n) begin : p_tdo
        if (!ext_rst_n) begin
            tdo_o <= 1'b0;
            tdo_oe_o <= 1'b0;
        end else begin
            tdo_oe_o <= sh_ir || shift_dr_o;
            tdo_o <= sh_ir ? ir_sh[0] : dr_tdo_i;
        end
    end

endmodule
