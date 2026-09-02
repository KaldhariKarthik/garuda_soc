`timescale 1ns/1ps
//=============================================================================
// tb_load_store_unit.v -- unit TB for rtl/core/load_store_unit.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 10.1 / 10.2.
// Plan:  C10 (SB/SH/SW lane alignment) and C11 (misaligned LH/LW and SH/SW)
//        at the unit level. C11's "no bus transaction issued" half is a
//        mem_stage property (start_w gating) and is checked in tb_mem_stage.
//
// Checked:
//   * hsize_o = {1'b0, funct3[1:0]}: byte 000, half 001, word 010 (Sec. 10.1).
//     Driven for the signed AND unsigned load encodings (LBU=100, LHU=101),
//     because funct3[2] must not leak into hsize.
//   * Misalignment (Sec. 10.2), full address-LSB matrix:
//       byte     -- never misaligned, at any offset
//       halfword -- misaligned iff addr[0]
//       word     -- misaligned iff addr[1:0] != 00
//     load_misaligned_o and store_misaligned_o are the same expression here;
//     the load-vs-store split (causes 4 vs 6) is made by the caller ANDing
//     with mem_read/mem_write, so both outputs are checked to agree.
//   * Store-data lane alignment per AMBA (Sec. 10.1): a byte is replicated
//     onto the lane selected by addr[1:0], a halfword onto the half selected
//     by addr[1], a word passes through unshifted. The upper bytes of
//     rs2_data are non-zero on every vector, so a shift that failed to
//     truncate the operand first would be caught.
//   * Misaligned addresses still produce a defined hwdata_o -- the access is
//     killed upstream, but an X here would propagate onto the bus.
//=============================================================================

module tb_load_store_unit;

  reg  [31:0] addr, rs2_data;
  reg  [2:0]  funct3;
  wire [2:0]  hsize;
  wire        load_mis, store_mis;
  wire [31:0] hwdata;
  integer     errors = 0;
  integer     i;

  // funct3 encodings (RV32I)
  localparam F3_B  = 3'b000, F3_H  = 3'b001, F3_W = 3'b010;
  localparam F3_BU = 3'b100, F3_HU = 3'b101;

  load_store_unit dut (
    .addr_i(addr), .funct3_i(funct3), .rs2_data_i(rs2_data),
    .hsize_o(hsize), .load_misaligned_o(load_mis),
    .store_misaligned_o(store_mis), .hwdata_o(hwdata));

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

  task c3;
    input [255:0] n;
    input [2:0] g, e;
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

  // Misalignment check for one (funct3, addr) pair; both outputs must agree.
  task chk_mis;
    input [255:0] n;
    input [2:0]   f3;
    input [31:0]  a;
    input         exp;
    begin
      funct3 = f3; addr = a; #1;
      c(n, load_mis, exp);
      if (load_mis !== store_mis) begin
        $display("FAIL %0s: load_mis=%b store_mis=%b disagree",
                 n, load_mis, store_mis);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    rs2_data = 32'hDEAD_BEEF; addr = 32'h2000_0000; funct3 = F3_W;

    // ---- hsize derivation (Sec. 10.1) ----------------------------------
    funct3 = F3_B;  #1; c3("hsize_byte",     hsize, 3'b000);
    funct3 = F3_H;  #1; c3("hsize_half",     hsize, 3'b001);
    funct3 = F3_W;  #1; c3("hsize_word",     hsize, 3'b010);
    funct3 = F3_BU; #1; c3("hsize_byte_u",   hsize, 3'b000);  // funct3[2] ignored
    funct3 = F3_HU; #1; c3("hsize_half_u",   hsize, 3'b001);

    // ---- misalignment matrix (Sec. 10.2) -------------------------------
    // byte: never misaligned
    chk_mis("byte_off0", F3_B, 32'h2000_0000, 1'b0);
    chk_mis("byte_off1", F3_B, 32'h2000_0001, 1'b0);
    chk_mis("byte_off2", F3_B, 32'h2000_0002, 1'b0);
    chk_mis("byte_off3", F3_B, 32'h2000_0003, 1'b0);
    chk_mis("byteu_off3", F3_BU, 32'h2000_0003, 1'b0);
    // halfword: misaligned iff addr[0]
    chk_mis("half_off0", F3_H, 32'h2000_0000, 1'b0);
    chk_mis("half_off1", F3_H, 32'h2000_0001, 1'b1);
    chk_mis("half_off2", F3_H, 32'h2000_0002, 1'b0);
    chk_mis("half_off3", F3_H, 32'h2000_0003, 1'b1);
    chk_mis("halfu_off1", F3_HU, 32'h2000_0001, 1'b1);
    // word: misaligned unless addr[1:0] == 00
    chk_mis("word_off0", F3_W, 32'h2000_0000, 1'b0);
    chk_mis("word_off1", F3_W, 32'h2000_0001, 1'b1);
    chk_mis("word_off2", F3_W, 32'h2000_0002, 1'b1);
    chk_mis("word_off3", F3_W, 32'h2000_0003, 1'b1);
    // alignment depends only on the low two bits, not on the region
    chk_mis("word_high_addr_aligned", F3_W, 32'hFFFF_FFFC, 1'b0);
    chk_mis("word_high_addr_mis",     F3_W, 32'hFFFF_FFFE, 1'b1);

    // ---- store-data lane alignment (Sec. 10.1) -------------------------
    // SB: the byte lands on the lane picked by addr[1:0]
    rs2_data = 32'h1234_56AB; funct3 = F3_B;
    addr = 32'h2000_0000; #1; c32("sb_lane0", hwdata, 32'h0000_00AB);
    addr = 32'h2000_0001; #1; c32("sb_lane1", hwdata, 32'h0000_AB00);
    addr = 32'h2000_0002; #1; c32("sb_lane2", hwdata, 32'h00AB_0000);
    addr = 32'h2000_0003; #1; c32("sb_lane3", hwdata, 32'hAB00_0000);
    // SH: the halfword lands on the half picked by addr[1]
    rs2_data = 32'h1234_BEEF; funct3 = F3_H;
    addr = 32'h2000_0000; #1; c32("sh_half0", hwdata, 32'h0000_BEEF);
    addr = 32'h2000_0002; #1; c32("sh_half1", hwdata, 32'hBEEF_0000);
    // SW: unshifted pass-through at every offset
    rs2_data = 32'hCAFE_F00D; funct3 = F3_W;
    addr = 32'h2000_0000; #1; c32("sw_pass",  hwdata, 32'hCAFE_F00D);
    addr = 32'h2000_0004; #1; c32("sw_pass2", hwdata, 32'hCAFE_F00D);
    // all-ones and all-zeros operands through every byte lane
    for (i = 0; i < 4; i = i + 1) begin
      rs2_data = 32'hFFFF_FFFF; funct3 = F3_B; addr = 32'h2000_0000 | i; #1;
      if (hwdata !== (32'h0000_00FF << (i * 8))) begin
        $display("FAIL sb_ones lane%0d: got %h exp %h",
                 i, hwdata, 32'h0000_00FF << (i * 8));
        errors = errors + 1;
      end
      rs2_data = 32'h0000_0000; #1;
      if (hwdata !== 32'h0) begin
        $display("FAIL sb_zeros lane%0d: got %h", i, hwdata);
        errors = errors + 1;
      end
    end

    // ---- misaligned access must still produce defined write data -------
    // The access is killed in mem_stage, but an X here would reach the bus.
    rs2_data = 32'hAAAA_5555; funct3 = F3_W; addr = 32'h2000_0002; #1;
      c32("misaligned_word_hwdata_defined", hwdata, 32'hAAAA_5555);
    funct3 = F3_H; addr = 32'h2000_0001; #1;
      c32("misaligned_half_hwdata_defined", hwdata, 32'h0000_5555);

    if (errors == 0) $display("LOAD_STORE_UNIT UNIT: ALL CHECKS PASSED");
    else             $display("LOAD_STORE_UNIT UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
