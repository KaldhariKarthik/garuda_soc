`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 12 : IEEE 1149.1 TAP controller + instruction register
// jtag_tap.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 §5.1, §6.1
//
// 16-state TAP, 5-bit IR. No TRST: Test-Logic-Reset is reached by five TCK
// cycles with TMS high ([N-5.1]). The TAP also takes a power-on reset from
// the ext_rst_n pin so it has a defined state at power-up (DECISIONS D-18).
// IR resets to IDCODE (0x01). TDO changes on the FALLING edge of TCK and is
// enabled only in Shift-IR / Shift-DR.
// =============================================================================

module jtag_tap (
    input  wire       tck_i,
    input  wire       tms_i,
    input  wire       tdi_i,
    input  wire       por_n_i,          // ext_rst_n (power-on only)
    output reg        tdo_o,
    output reg        tdo_oe_o,

    output wire [4:0] ir_o,
    output wire       tlr_o,            // in Test-Logic-Reset
    output wire       capture_dr_o,
    output wire       shift_dr_o,
    output wire       update_dr_o,
    input  wire       dr_tdo_i          // serial out of the selected DR
);

    localparam [3:0] TLR = 4'h0, RTI = 4'h1, SELDR = 4'h2, CAPDR = 4'h3,
                     SHDR = 4'h4, EX1DR = 4'h5, PADR = 4'h6, EX2DR = 4'h7,
                     UPDR = 4'h8, SELIR = 4'h9, CAPIR = 4'hA, SHIR = 4'hB,
                     EX1IR = 4'hC, PAIR = 4'hD, EX2IR = 4'hE, UPIR = 4'hF;

    localparam [4:0] IR_IDCODE = 5'h01;

    reg [3:0] st;
    always @(posedge tck_i or negedge por_n_i) begin
        if (!por_n_i) st <= TLR;
        else case (st)
            TLR:   st <= tms_i ? TLR   : RTI;
            RTI:   st <= tms_i ? SELDR : RTI;
            SELDR: st <= tms_i ? SELIR : CAPDR;
            CAPDR: st <= tms_i ? EX1DR : SHDR;
            SHDR:  st <= tms_i ? EX1DR : SHDR;
            EX1DR: st <= tms_i ? UPDR  : PADR;
            PADR:  st <= tms_i ? EX2DR : PADR;
            EX2DR: st <= tms_i ? UPDR  : SHDR;
            UPDR:  st <= tms_i ? SELDR : RTI;
            SELIR: st <= tms_i ? TLR   : CAPIR;
            CAPIR: st <= tms_i ? EX1IR : SHIR;
            SHIR:  st <= tms_i ? EX1IR : SHIR;
            EX1IR: st <= tms_i ? UPIR  : PAIR;
            PAIR:  st <= tms_i ? EX2IR : PAIR;
            EX2IR: st <= tms_i ? UPIR  : SHIR;
            default: st <= tms_i ? SELDR : RTI;       // UPIR
        endcase
    end

    // instruction register: shift + latched
    reg [4:0] ir_sh, ir_q;
    always @(posedge tck_i or negedge por_n_i) begin
        if (!por_n_i) begin
            ir_sh <= 5'd0; ir_q <= IR_IDCODE;
        end else begin
            if (st == TLR)   ir_q  <= IR_IDCODE;
            if (st == CAPIR) ir_sh <= 5'b00001;          // 1149.1: LSBs 01
            if (st == SHIR)  ir_sh <= {tdi_i, ir_sh[4:1]};
            if (st == UPIR)  ir_q  <= ir_sh;
        end
    end

    assign ir_o         = ir_q;
    assign tlr_o        = (st == TLR);
    assign capture_dr_o = (st == CAPDR);
    assign shift_dr_o   = (st == SHDR);
    assign update_dr_o  = (st == UPDR);

    // TDO on the falling edge
    always @(negedge tck_i or negedge por_n_i) begin
        if (!por_n_i) begin
            tdo_o <= 1'b0; tdo_oe_o <= 1'b0;
        end else begin
            tdo_oe_o <= (st == SHIR) || (st == SHDR);
            tdo_o    <= (st == SHIR) ? ir_sh[0] : dr_tdo_i;
        end
    end

endmodule

`default_nettype wire
