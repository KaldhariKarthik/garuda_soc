`timescale 1ns/1ps
// =============================================================================
// tb_dsu_decoder_spec.sv -- dsu_decoder against the DSU instruction table (Track A
// wrap-up 2026-10-12; for sign-off next to the ported tb_dsu_decoder, TB-43).
// Reference decode, written from GARUDA-DSU-SPEC-001 section 7 and the recorded
// decisions: custom-0 (0001011); R-type (funct3 000) funct5 0..8 = MAC_SEL, MACSUB,
// MACABS, MACDOT, MACLOAD, MACCLEAR, MACSAT, MACRD_LO, MACRD_HI; I-type (funct3 001)
// = MACSHIFT, imm = {rsvd[11:9], left[8], acc[7:6], amount[5:0]} (the RTL form:
// DSU-17); illegal: acc_sel 3, funct5 >= 9, another funct3, amount >= 48 (DSU-6).
// Not asserted: MACSHIFT with reserved bits [11:9] set (the spec is silent, D0
// ruling; counted). dsu_en = 0 decodes nothing. Checked: illegal, the MAC control
// word, sat / shift / readback ops, result_src, writes_regfile, rd, acc_sel.
// Every R-type funct5 x acc_sel x enable, every MACSHIFT immediate, other funct3,
// and random words.
// =============================================================================
`include "dsu_defs.vh"
module tb_dsu_decoder_spec;
    logic [31:0] instr;
    logic        dsu_en, flush;
    wire [`MAC_CTRL_W-1:0] control;
    wire [1:0] acc_sel, shift_acc_sel, result_src;
    wire sat_op, shift_op, shift_dir, rd_lo_op, rd_hi_op, writes_regfile, illegal, is_custom0;
    wire [5:0] shift_amt;
    wire [4:0] rd_addr, funct5;
    wire [2:0] funct3;
    dsu_decoder dut (.instr(instr), .dsu_en(dsu_en), .flush(flush), .control(control), .acc_sel(acc_sel),
                     .sat_op(sat_op), .shift_op(shift_op), .shift_amt(shift_amt), .shift_dir(shift_dir),
                     .shift_acc_sel(shift_acc_sel), .rd_lo_op(rd_lo_op), .rd_hi_op(rd_hi_op),
                     .result_src(result_src), .writes_regfile(writes_regfile), .rd_addr(rd_addr),
                     .illegal_instr(illegal), .funct5(funct5), .funct3(funct3), .is_custom0(is_custom0));
    int checks = 0, fails = 0, rsvd_cases = 0;
    task automatic chk(input [31:0] i, input bit en);
        bit c0 = i[6:0] == 7'b0001011, rt = c0 && i[14:12] == 3'b000, it = c0 && i[14:12] == 3'b001;
        bit [4:0] f5 = i[31:27];
        bit [1:0] sel = it ? i[27:26] : i[26:25];
        bit rsvd = it && i[31:29] != 3'b000;
        bit legal_op = (rt && f5 <= 5'd8) || it;
        bit ill = c0 && en && (!legal_op || sel == 2'b11 || (it && i[25:20] >= 6'd48) || rsvd);
        bit ok = c0 && en && !ill;
        bit compute = ok && rt && f5 <= 5'd5;
        logic [`MAC_CTRL_W-1:0] want_ctrl;
        string bad = "";
        instr = i; dsu_en = en; flush = 0; #1;
        if (rsvd && en) begin rsvd_cases++; return; end         // D0: not asserted
        want_ctrl = '0;
        want_ctrl[`MAC_CTRL_EN]     = compute;
        want_ctrl[`MAC_CTRL_ADDSUB] = rt && f5 == 5'd1;
        want_ctrl[`MAC_CTRL_CLEAR]  = rt && f5 == 5'd5;
        want_ctrl[`MAC_CTRL_LOAD]   = rt && f5 == 5'd4;
        want_ctrl[`MAC_CTRL_ABS]    = rt && f5 == 5'd2;
        want_ctrl[`MAC_CTRL_DOT]    = rt && f5 == 5'd3;
        checks++;
        if (illegal !== ill) bad = {bad, " illegal"};
        if (control[`MAC_CTRL_EN] !== want_ctrl[`MAC_CTRL_EN]) bad = {bad, " mac_en"};
        if (compute && control[`MAC_CTRL_EN-1:1] !== want_ctrl[`MAC_CTRL_EN-1:1]) bad = {bad, " control"};
        if (sat_op !== (ok && rt && f5 == 5'd6)) bad = {bad, " sat_op"};
        if (rd_lo_op !== (ok && rt && f5 == 5'd7)) bad = {bad, " rd_lo"};
        if (rd_hi_op !== (ok && rt && f5 == 5'd8)) bad = {bad, " rd_hi"};
        if (shift_op !== (ok && it)) bad = {bad, " shift_op"};
        if (writes_regfile !== (ok && (it || (rt && (f5 == 5'd7 || f5 == 5'd8))))) bad = {bad, " writes_regfile"};
        if (ok && (it || f5 == 5'd7 || f5 == 5'd8) && result_src !== (it ? 2'b11 : f5 == 5'd7 ? 2'b01 : 2'b10)) bad = {bad, " result_src"};
        if (ok && acc_sel !== sel) bad = {bad, " acc_sel"};
        if (ok && it && (shift_amt !== i[25:20] || shift_dir !== i[28])) bad = {bad, " shift fields"};
        if (rd_addr !== i[11:7]) bad = {bad, " rd"};
        if (bad != "") begin
            fails++;
            if (fails <= 10) $display("[FAIL] instr=%08h en=%0d:%s", i, en, bad);
        end
    endtask
    initial begin
        for (int en = 0; en < 2; en++) for (int f5 = 0; f5 < 32; f5++) for (int s = 0; s < 4; s++)
            chk({5'(f5), 2'(s), 5'd3, 5'd2, 3'b000, 5'd7, 7'b0001011}, en[0]);
        for (int imm = 0; imm < 4096; imm++) chk({12'(imm), 5'd4, 3'b001, 5'd9, 7'b0001011}, 1'b1);
        for (int f3 = 2; f3 < 8; f3++) chk({7'd0, 5'd1, 5'd2, 3'(f3), 5'd3, 7'b0001011}, 1'b1);
        for (int r = 0; r < 20000; r++) begin
            automatic logic [31:0] w = $urandom();
            if (r % 2) w[6:0] = 7'b0001011;
            chk(w, $urandom_range(3, 0) != 0);
        end
        $display("tb_dsu_decoder_spec: checks=%0d FAIL=%0d (MACSHIFT with reserved imm bits, not asserted until the D0 ruling: %0d)", checks, fails, rsvd_cases);
        $display("RESULT: %s", (fails == 0 && checks > 0) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
