// =============================================================================
// GARUDA SoC - Block 13 : JTAG TAP controller state machine (IEEE 1149.1)
// tap_fsm.sv
//
// Spec: GARUDA-DEBUG-SPEC-001 Sec.6.1; IEEE 1149.1 Fig. 6-1
//
// The sixteen TAP states and their TMS transitions, on their own (F4,
// 2026-11-17: HAL BADFSM / EXTFSM ask for the state register and one
// combinational block for the next state and the outputs, with no other logic
// beside them). jtag_tap keeps the instruction register and TDO.
// The state encoding is the standard's numbering; its transitions cannot all
// change one bit (HAL TRNMBT), the graph has odd cycles.
// =============================================================================

module tap_fsm (
    input wire tck,
    input wire ext_rst_n,  // power-on only
    input wire tms_i,
    output logic tlr_o,      // Test-Logic-Reset
    output logic cap_dr_o,   // Capture-DR
    output logic sh_dr_o,    // Shift-DR
    output logic up_dr_o,    // Update-DR
    output logic cap_ir_o,   // Capture-IR
    output logic sh_ir_o,    // Shift-IR
    output logic up_ir_o     // Update-IR
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned ST_W = 32'd4;

    localparam [3:0] ST_RESET = 4'h0, ST_IDLE = 4'h1, SELDR = 4'h2;
    localparam [3:0] CAPDR = 4'h3, SHDR = 4'h4, EX1DR = 4'h5, PADR = 4'h6;
    localparam [3:0] EX2DR = 4'h7, UPDR = 4'h8, SELIR = 4'h9, CAPIR = 4'hA;
    localparam [3:0] SHIR = 4'hB, EX1IR = 4'hC, PAIR = 4'hD, EX2IR = 4'hE;
    localparam [3:0] UPIR = 4'hF;

    reg [ST_W-1:0] st;
    logic [ST_W-1:0] st_next;

    always_ff @(posedge tck or negedge ext_rst_n) begin : p_st
        if (!ext_rst_n) begin
            st <= ST_RESET;
        end else begin
            st <= st_next;
        end
    end

    always_comb begin : c_next
        tlr_o = 1'b0;
        cap_dr_o = 1'b0;
        sh_dr_o = 1'b0;
        up_dr_o = 1'b0;
        cap_ir_o = 1'b0;
        sh_ir_o = 1'b0;
        up_ir_o = 1'b0;
        case (st)
            ST_RESET: begin
                tlr_o = 1'b1;
                st_next = tms_i ? ST_RESET : ST_IDLE;
            end
            ST_IDLE: st_next = tms_i ? SELDR : ST_IDLE;
            SELDR: st_next = tms_i ? SELIR : CAPDR;
            CAPDR: begin
                cap_dr_o = 1'b1;
                st_next = tms_i ? EX1DR : SHDR;
            end
            SHDR: begin
                sh_dr_o = 1'b1;
                st_next = tms_i ? EX1DR : SHDR;
            end
            EX1DR: st_next = tms_i ? UPDR : PADR;
            PADR: st_next = tms_i ? EX2DR : PADR;
            EX2DR: st_next = tms_i ? UPDR : SHDR;
            UPDR: begin
                up_dr_o = 1'b1;
                st_next = tms_i ? SELDR : ST_IDLE;
            end
            SELIR: st_next = tms_i ? ST_RESET : CAPIR;
            CAPIR: begin
                cap_ir_o = 1'b1;
                st_next = tms_i ? EX1IR : SHIR;
            end
            SHIR: begin
                sh_ir_o = 1'b1;
                st_next = tms_i ? EX1IR : SHIR;
            end
            EX1IR: st_next = tms_i ? UPIR : PAIR;
            PAIR: st_next = tms_i ? EX2IR : PAIR;
            EX2IR: st_next = tms_i ? UPIR : SHIR;
            default: begin  // UPIR
                up_ir_o = 1'b1;
                st_next = tms_i ? SELDR : ST_IDLE;
            end
        endcase
    end

endmodule
