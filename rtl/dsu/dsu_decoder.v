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
    
    output wire [1:0] result_src,
    output wire       writes_regfile,
    output wire [4:0] rd_addr,
    
    output wire illegal_instr,
    
    output wire [4:0] funct5,
    output wire [2:0] funct3,
    output wire       is_custom0
);

    wire [6:0]  opcode    = instr[6:0];
    wire [4:0]  rd_f      = instr[11:7];
    assign      funct3    = instr[14:12];
    wire [4:0]  rs1_f     = instr[19:15];
    wire [4:0]  rs2_f     = instr[24:20];
    wire [1:0]  acc_sel_r = instr[26:25];
    wire [4:0]  funct5_r  = instr[31:27];
    wire [11:0] imm_i     = instr[31:20];
    
    assign is_custom0 = (opcode == 7'b0001011);
    wire is_rtype   = is_custom0 & (funct3 == 3'b000);
    wire is_itype   = is_custom0 & (funct3 == 3'b001);
    
    wire op_mac_sel  = is_rtype & (funct5_r == `FUNCT5_MAC_SEL);
    wire op_macsub   = is_rtype & (funct5_r == `FUNCT5_MACSUB);
    wire op_macabs   = is_rtype & (funct5_r == `FUNCT5_MACABS);
    wire op_macdot   = is_rtype & (funct5_r == `FUNCT5_MACDOT);
    wire op_macload  = is_rtype & (funct5_r == `FUNCT5_MACLOAD);
    wire op_macclear = is_rtype & (funct5_r == `FUNCT5_MACCLEAR);
    wire op_macsat   = is_rtype & (funct5_r == `FUNCT5_MACSAT);
    wire op_rd_lo    = is_rtype & (funct5_r == `FUNCT5_MACRD_LO);
    wire op_rd_hi    = is_rtype & (funct5_r == `FUNCT5_MACRD_HI);
    
    wire op_macshift = is_itype;
    
    wire [1:0] acc_sel_eff = is_itype ? imm_i[7:6] : acc_sel_r;
    assign acc_sel       = acc_sel_eff;
    assign shift_acc_sel = imm_i[7:6];
    
    wire any_legal_op = op_mac_sel | op_macsub | op_macabs | op_macdot | op_macload | op_macclear | op_macsat | op_rd_lo | op_rd_hi | op_macshift;
    wire bad_acc_sel  = (acc_sel_eff == 2'b11);
    wire bad_funct3   = is_custom0 & ~(is_rtype | is_itype);

    // -----------------------------------------------------------------------
    // ERRATUM DSU-6 (FLAG-D) -- MACSHIFT amount out of range
    // -----------------------------------------------------------------------
    // shift_amt is 6 bits (0..63) but the accumulator is 48. Amounts 48..63
    // were architecturally undefined: the RTL happened to be well-behaved
    // (left -> 0, arithmetic right -> all sign bits) but nothing said so, and
    // nothing stopped software using them.
    //
    // Resolved by making the range REAL rather than documented. An ABI note
    // saying "use 0..47" is exactly the kind of unenforceable contract that
    // was rejected for FLAG-C: no assembler checks it, so the first kernel to
    // compute a shift amount at run time would violate it silently.
    // -----------------------------------------------------------------------
    wire bad_shift_amt  = is_itype & (imm_i[5:0] >= 6'd48);

    // -----------------------------------------------------------------------
    // ERRATUM DSU-7 -- reserved I-type immediate bits
    // -----------------------------------------------------------------------
    // MACSHIFT uses imm_i[8]=dir, [7:6]=acc_sel, [5:0]=amt. Bits [11:9] were
    // read by nothing and checked by nothing, so ANY value decoded as a valid
    // shift - which quietly spent seven eighths of the I-type encoding space.
    // Requiring them to be zero reserves that space for future DSU
    // instructions. This has to land before firmware ships with junk in those
    // bits, because after that the space can never be reclaimed.
    // -----------------------------------------------------------------------
    wire bad_shift_rsvd = is_itype & (imm_i[11:9] != 3'b000);

    assign illegal_instr = is_custom0 & dsu_en &
                           (~any_legal_op | bad_acc_sel | bad_funct3 |
                            bad_shift_amt | bad_shift_rsvd);
    
    wire compute_op = op_mac_sel | op_macsub | op_macabs | op_macdot | op_macload | op_macclear;
    
    wire mac_en     = compute_op & dsu_en & ~illegal_instr;
    wire mac_addsub = op_macsub;
    wire mac_clear  = op_macclear;
    wire mac_load   = op_macload;
    wire mac_abs    = op_macabs;
    wire mac_dot    = op_macdot;
    wire mac_flush  = flush;
    
    assign control = {
        mac_en,
        mac_addsub,
        mac_clear,
        mac_load,
        mac_abs,
        mac_dot,
        mac_flush
    };
    
    assign sat_op   = op_macsat & dsu_en & ~illegal_instr;
    assign shift_op = op_macshift & dsu_en & ~illegal_instr;
    assign rd_lo_op = op_rd_lo & dsu_en & ~illegal_instr;
    assign rd_hi_op = op_rd_hi & dsu_en & ~illegal_instr;
    
    assign shift_amt  = imm_i [5:0]; 
    assign shift_dir  = imm_i [8];
    
    assign result_src = op_rd_lo ? 2'b01 : op_rd_hi ? 2'b10 : op_macshift ? 2'b11 : 2'b00;
    
    assign writes_regfile = (op_rd_lo | op_rd_hi | op_macshift) & dsu_en & ~illegal_instr; 
    assign rd_addr        = rd_f;
    assign funct5 = funct5_r;
    
endmodule
