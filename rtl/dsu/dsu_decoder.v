//dsu_decoder.v
//Decodes Custom-0 DSU instructions
//R-type for compute/load/clear/sat/readback (funct3 = 000)
//I-Type for macshift
//produces packed control bus for mac_cluster + aux_signals for Saturation unit, Barrel Shifter, Read_back Mux, Stall FSM

`timescale 1ns / 1ps
`include "dsu_defs.vh"

module dsu_decoder (
    input wire [31:0] instr,
    input wire        dsu_en,
    input wire        flush,
    
    output wire [`MAC_CTRL_W-1:0] control,
    output wire [1:0]             acc_sel,
    
    output wire sat_op,
    
    output wire       shift_op,
    output wire [5:0] shift_amt,
    output wire       shift_dir,
    output wire [1:0] shift_acc_sel,
    
    output wire rd_lo_op,
    output wire rd_hi_op,
    
    output wire       writes_regfile,
    output wire [4:0] rd_addr,
    
    output wire illegal_instr
);

    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd_f = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1_f = instr[19:15];
    wire [4:0] rs2_f = instr[24:20];
    wire [1:0] acc_sel_r = instr[26:25];
    wire [4:0] funct5 = instr[31:27];
    wire [11:0] imm_i = instr[31:20];
    
    wire is_custom0 = (opcode == 7'b0001011);
    wire is_rtype = is_custom0 & (funct3 == 3'b000);
    wire is_itype = is_custom0 & (funct3 == 3'b001);
    
    wire op_mac_sel = is_rtype & (funct5_r == `FUNCT5_MAC_SEL);
    wire op_macsub = is_rtype & (funct5_r == `FUNCT5_MACSUB);
    wire op_macabs = is_rtype & (funct5_r == `FUNCT5_MACABS);
    wire op_macdot = is_rtype & (funct5_r == `FUNCT5_MACDOT);
    wire op_macload = is_rtype & (funct5_r == `FUNCT5_MACLOAD);
    wire op_macclear = is_rtype & (funct5_r == `FUNCT5_MACCLEAR);
    wire op_macsat = is_rtype & (funct5_r == `FUNCT5_MACSAT);
    wire op_rd_lo = is_rtype & (funct5_r == `FUNCT5_MACRD_LO);
    wire op_rd_hi = is_rtype & (funct5_r == `FUNCT5_MACRD_HI);
    
    wire op_macshift = is_itype;
    
    wire [1:0] acc_sel_eff = is_itype ? imm_i[7:6] : acc_sel_r;
    assign acc_sel = acc_sel_eff;
    assign shift_acc_sel = imm_i[7:6[;
    
    wire any_legal_op = op_mac_sel | op_macsub | op_macabs | op_macdot | op_macload | op_macclear | op_macsat | op_rd_lo | op_rd_hi | op_macshift;
    wire bad_acc_sel = (acc_sel_eff == 2`b11);
    wire bad_funct3 = is_custom0 & ~(is_rtype | is_itype);
    assign illegal_instr = is_custom0 & dsu_en & (~any_legal_op | bad_acc_sel | bad_funct3);
    
    wire compute_op = op_mac_sel | op_macsub | op_macabs | op_macdot | op_macload | op_macclear;
    
    wire mac_en = compute_op & dsu_en & ~illegal_instr;
    wire mac_addsub = op_macsub;
    wire mac_clear = op_macclear;
    wire mac_load = op_macload;
    wire mac_dot = op_macdot;
    wire mac_flush = flush;
    
    assign control = {
        mac_en,
        mac_addsub,
        mac_clear,
        mac_load,
        mac_abs,
        mac_dot,
        mac_flush
    };
    
    assign sat_op = op_macsat & dsu_en & ~illegal_instr;
    assign shift_op = op_macshift & dsu_en & ~illegal_instr;
    assign rd_lo_op = op_rd_lo & dsu_en & ~illegal_instr;
    assign rd_hi_op = op_rd_hi & dsu_en & ~illegal_instr;
    
    assign shift_amt  = imm_i [5:0]; 
    assign shift_dir = imm_i [8];
    
    assign result_src = op_rd_lo ? 2'b01 : op_rd_hi ? 2'b10 : op_macshift ? 2'b11 : 2'b00;
    
    assign writes_regfile = (op_rd_lo | op_rd_hi | op_macshift) & rd addr = rd_F;
    
endmodule
