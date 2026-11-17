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
    localparam int unsigned ST_W = 32'd4;

    localparam [3:0] ST_RESET = 4'h0, ST_IDLE = 4'h1, SELDR = 4'h2, CAPDR
        = 4'h3,
                     SHDR = 4'h4, EX1DR = 4'h5, PADR = 4'h6, EX2DR = 4'h7,
                     UPDR = 4'h8, SELIR = 4'h9, CAPIR = 4'hA, SHIR = 4'hB,
                     EX1IR = 4'hC, PAIR = 4'hD, EX2IR = 4'hE, UPIR = 4'hF;

    localparam [4:0] IR_IDCODE = 5'h01;

    reg [ST_W-1:0] st;
    always_ff @(posedge tck or negedge ext_rst_n) begin : p_st
        if (!ext_rst_n) begin
            st <= ST_RESET;
        end else begin
            case (st)
                ST_RESET: st <= tms_i ? ST_RESET : ST_IDLE;
                ST_IDLE: st <= tms_i ? SELDR : ST_IDLE;
                SELDR: st <= tms_i ? SELIR : CAPDR;
                CAPDR: st <= tms_i ? EX1DR : SHDR;
                SHDR: st <= tms_i ? EX1DR : SHDR;
                EX1DR: st <= tms_i ? UPDR : PADR;
                PADR: st <= tms_i ? EX2DR : PADR;
                EX2DR: st <= tms_i ? UPDR : SHDR;
                UPDR: st <= tms_i ? SELDR : ST_IDLE;
                SELIR: st <= tms_i ? ST_RESET : CAPIR;
                CAPIR: st <= tms_i ? EX1IR : SHIR;
                SHIR: st <= tms_i ? EX1IR : SHIR;
                EX1IR: st <= tms_i ? UPIR : PAIR;
                PAIR: st <= tms_i ? EX2IR : PAIR;
                EX2IR: st <= tms_i ? UPIR : SHIR;
                default: st <= tms_i ? SELDR : ST_IDLE;  // UPIR
            endcase
        end
    end

    // instruction register: shift + latched
    reg [JTAG_IR_W-1:0] ir_sh;
    reg [JTAG_IR_W-1:0] ir_q;
    always_ff @(posedge tck or negedge ext_rst_n) begin : p_ir_sh
        if (!ext_rst_n) begin
            ir_sh <= 5'd0;
            ir_q <= IR_IDCODE;
        end else begin
            if (st == ST_RESET) begin
                ir_q <= IR_IDCODE;
            end
            if (st == CAPIR) begin
                ir_sh <= 5'b00001;  // 1149.1: LSBs 01
            end
            if (st == SHIR) begin
                ir_sh <= {tdi_i, ir_sh[4:1]};
            end
            if (st == UPIR) begin
                ir_q <= ir_sh;
            end
        end
    end

    assign ir_o         = ir_q;
    assign tlr_o        = (st == ST_RESET);
    assign capture_dr_o = (st == CAPDR);
    assign shift_dr_o   = (st == SHDR);
    assign update_dr_o  = (st == UPDR);

    // TDO on the falling edge
    always_ff @(negedge tck or negedge ext_rst_n) begin : p_tdo
        if (!ext_rst_n) begin
            tdo_o <= 1'b0;
            tdo_oe_o <= 1'b0;
        end else begin
            tdo_oe_o <= (st == SHIR) || (st == SHDR);
            tdo_o <= (st == SHIR) ? ir_sh[0] : dr_tdo_i;
        end
    end

endmodule
