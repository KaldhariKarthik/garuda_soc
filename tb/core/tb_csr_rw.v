`timescale 1ns/1ps
//=============================================================================
// tb_csr_rw.v -- unit TB for rtl/core/csr_rw.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 8.3 / 8.4 / 13.3.
// Plan:  C21 (M-mode CSR read/write) at the seam level. Architectural CSR
//        state lives in csr_file.v and is NOT in scope here -- this block is
//        only the EX-side half of the CSR_RW <-> CONTROL exchange.
//
// Checked:
//   * csr_addr = instr[31:20] for every CSR named in the Sec. 13.2 table,
//     including the custom dsu_ovf at 0xBC0 and the 0xF1x read-only IDs.
//     The full-scale walk (walking 1s across all 12 address bits) catches a
//     mis-sliced bit field that a handful of directed addresses would miss.
//   * Write-source select (Sec. 8.4):
//       register  variants -> csr_wdata = rs1_fwd (the FORWARDED value, so a
//                             CSRRW whose rs1 comes from the previous
//                             instruction is covered by the same path)
//       immediate variants -> csr_wdata = {27'b0, instr[19:15]}, ZERO-extended,
//                             never sign-extended. uimm = 5'b11111 is the
//                             discriminating vector: zero-extend gives 31,
//                             sign-extend would give 0xFFFF_FFFF.
//     The uimm field aliases the rs1 index bits, so both are driven with
//     conflicting values on every immediate check to prove the mux picked
//     the right one.
//   * csr_op_out / csr_en_out are transparent pass-throughs for all three
//     ops (CSR_RW / CSR_RS / CSR_RC) -- this block never decodes them.
//   * The outputs are combinational and unconditional: addr and wdata keep
//     tracking their sources even with csr_en low (gating is the consumer's
//     job in ex_stage.v's result mux, per Sec. 8.3). Checked explicitly so a
//     future "optimisation" that gates them here is caught.
//=============================================================================

module tb_csr_rw;

  reg  [31:0] instr, rs1_fwd;
  reg         csr_en, csr_imm;
  reg  [1:0]  csr_op;
  wire [11:0] csr_addr;
  wire [31:0] csr_wdata;
  wire [1:0]  csr_op_out;
  wire        csr_en_out;
  integer     errors = 0;
  integer     i;

  csr_rw dut (
    .instr(instr), .rs1_fwd(rs1_fwd),
    .csr_en(csr_en), .csr_imm(csr_imm), .csr_op(csr_op),
    .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .csr_op_out(csr_op_out), .csr_en_out(csr_en_out));

  task c;
    input [255:0] n;
    input g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %b exp %b", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  task c32;
    input [255:0] n;
    input [31:0] g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %h exp %h", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  // Build a SYSTEM CSR instruction word: addr in [31:20], rs1/uimm in
  // [19:15], funct3 in [14:12], rd in [11:7], opcode 1110011.
  function [31:0] csr_instr;
    input [11:0] addr;
    input [4:0]  rs1_or_uimm;
    input [2:0]  f3;
    input [4:0]  rd;
    begin
      csr_instr = {addr, rs1_or_uimm, f3, rd, 7'b1110011};
    end
  endfunction

  // Check csr_addr decoding for one CSR address.
  task chk_addr;
    input [255:0] n;
    input [11:0]  addr;
    begin
      instr = csr_instr(addr, 5'd0, 3'b001, 5'd1); #1;
      if (csr_addr !== addr) begin
        $display("FAIL addr %0s: got %h exp %h", n, csr_addr, addr);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    csr_en = 1; csr_imm = 0; csr_op = 2'b01; rs1_fwd = 32'hA5A5_A5A5;

    // ---- address decode: every CSR in the Sec. 13.2 table --------------
    chk_addr("mstatus",    12'h300);
    chk_addr("misa",       12'h301);
    chk_addr("mie",        12'h304);
    chk_addr("mtvec",      12'h305);
    chk_addr("mtvt",       12'h307);
    chk_addr("mscratch",   12'h340);
    chk_addr("mepc",       12'h341);
    chk_addr("mcause",     12'h342);
    chk_addr("mtval",      12'h343);
    chk_addr("mip",        12'h344);
    chk_addr("mnxti",      12'h345);
    chk_addr("mintthresh", 12'h347);
    chk_addr("mcycle",     12'hB00);
    chk_addr("minstret",   12'hB02);
    chk_addr("mcycleh",    12'hB80);
    chk_addr("minstreth",  12'hB82);
    chk_addr("dsu_ovf",    12'hBC0);   // custom, Sec. 13.2
    chk_addr("mvendorid",  12'hF11);
    chk_addr("marchid",    12'hF12);
    chk_addr("mimpid",     12'hF13);
    chk_addr("mhartid",    12'hF14);
    chk_addr("mintstatus", 12'hFB1);
    // walking-ones across the whole 12-bit field
    for (i = 0; i < 12; i = i + 1)
      chk_addr("walk1", 12'd1 << i);
    chk_addr("all_zero", 12'h000);
    chk_addr("all_ones", 12'hFFF);

    // ---- register variants: wdata = forwarded rs1 (Sec. 8.4) ----------
    csr_imm = 0; rs1_fwd = 32'hDEAD_BEEF;
    instr = csr_instr(12'h340, 5'd7, 3'b001, 5'd3); #1;   // CSRRW x3, mscratch, x7
      c32("reg_wdata_is_rs1", csr_wdata, 32'hDEAD_BEEF);
    rs1_fwd = 32'h0000_0000; #1;
      c32("reg_wdata_zero", csr_wdata, 32'h0000_0000);
    rs1_fwd = 32'hFFFF_FFFF; #1;
      c32("reg_wdata_ones", csr_wdata, 32'hFFFF_FFFF);

    // ---- immediate variants: zero-extended uimm = instr[19:15] --------
    // rs1_fwd is deliberately non-zero and different from uimm on every
    // vector, so selecting the wrong source cannot look correct.
    csr_imm = 1; rs1_fwd = 32'hDEAD_BEEF;
    instr = csr_instr(12'h340, 5'b11111, 3'b101, 5'd3); #1;
      c32("imm_wdata_uimm31_zeroext", csr_wdata, 32'd31);  // NOT FFFF_FFFF
    instr = csr_instr(12'h340, 5'b00001, 3'b101, 5'd3); #1;
      c32("imm_wdata_uimm1", csr_wdata, 32'd1);
    instr = csr_instr(12'h340, 5'b00000, 3'b101, 5'd3); #1;
      c32("imm_wdata_uimm0", csr_wdata, 32'd0);
    instr = csr_instr(12'h340, 5'b10000, 3'b101, 5'd3); #1;
      c32("imm_wdata_uimm16", csr_wdata, 32'd16);
    // upper 27 bits must be zero for every uimm value
    for (i = 0; i < 32; i = i + 1) begin
      instr = csr_instr(12'h340, i[4:0], 3'b101, 5'd3); #1;
      if (csr_wdata !== {27'b0, i[4:0]}) begin
        $display("FAIL imm_wdata_sweep uimm=%0d: got %h exp %h",
                 i, csr_wdata, {27'b0, i[4:0]});
        errors = errors + 1;
      end
    end

    // ---- op / en pass-through (all three ops, Sec. 13.3) ---------------
    csr_op = 2'b01; csr_en = 1; #1;
      c("op_rw_lo", csr_op_out[0], 1'b1); c("op_rw_hi", csr_op_out[1], 1'b0);
      c("en_high",  csr_en_out, 1'b1);
    csr_op = 2'b10; #1;
      c("op_rs_lo", csr_op_out[0], 1'b0); c("op_rs_hi", csr_op_out[1], 1'b1);
    csr_op = 2'b11; #1;
      c("op_rc_lo", csr_op_out[0], 1'b1); c("op_rc_hi", csr_op_out[1], 1'b1);
    csr_en = 0; #1;
      c("en_low", csr_en_out, 1'b0);

    // ---- addr/wdata stay live with csr_en low --------------------------
    // Gating belongs to the EX result mux (Sec. 8.3), not to this block.
    csr_en = 0; csr_imm = 0; rs1_fwd = 32'h1234_5678;
    instr = csr_instr(12'h305, 5'd9, 3'b001, 5'd2); #1;
      c32("addr_live_when_en_low",  csr_addr,  12'h305);
      c32("wdata_live_when_en_low", csr_wdata, 32'h1234_5678);

    if (errors == 0) $display("CSR_RW UNIT: ALL CHECKS PASSED");
    else             $display("CSR_RW UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
