`timescale 1ns/1ps
//=============================================================================
// tb_load_formatter.v -- unit TB for rtl/core/load_formatter.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 10.3 (load result formatting).
// Plan:  C10 -- "LB/LH/LW/LBU/LHU sign/zero extension".
//
// Checked:
//   * Lane extraction: LB/LBU pull the byte selected by addr[1:0]; LH/LHU
//     pull the half selected by addr[1] (addr[0] is ignored -- a misaligned
//     halfword never reaches here, it is killed in EX).
//   * Sign vs zero extension, driven by funct3[2]:
//       LB  0x80 -> FFFF_FF80      LBU 0x80 -> 0000_0080
//       LH  0x8000 -> FFFF_8000    LHU 0x8000 -> 0000_8000
//     The test data 0x80_81_82_83 makes EVERY byte and EVERY halfword
//     negative, so a byte-lane mux error and a sign-extension error cannot
//     mask each other -- the two produce different values in each lane.
//   * LW passes through unchanged at any addr_lsbs value.
//   * A positive-data pattern (0x01_02_03_04) confirms sign-extension is
//     data-driven, not unconditional.
//   * Exhaustive sweep: all 4 offsets x all 5 legal funct3 values against a
//     golden model derived from the spec text.
//=============================================================================

module tb_load_formatter;

  reg  [31:0] rdata;
  reg  [1:0]  lsbs;
  reg  [2:0]  funct3;
  wire [31:0] load_data;
  integer     errors = 0;
  integer     i, j;

  localparam F3_B  = 3'b000, F3_H  = 3'b001, F3_W = 3'b010;
  localparam F3_BU = 3'b100, F3_HU = 3'b101;

  load_formatter dut (
    .rdata_i(rdata), .addr_lsbs_i(lsbs), .funct3_i(funct3),
    .load_data_o(load_data));

  // Golden model written from Sec. 10.3, not from the RTL.
  function [31:0] golden;
    input [31:0] d;
    input [1:0]  off;
    input [2:0]  f3;
    reg   [7:0]  b;
    reg   [15:0] h;
    begin
      case (off)
        2'b00: b = d[7:0];
        2'b01: b = d[15:8];
        2'b10: b = d[23:16];
        2'b11: b = d[31:24];
      endcase
      h = off[1] ? d[31:16] : d[15:0];
      case (f3)
        F3_B:    golden = {{24{b[7]}},  b};
        F3_BU:   golden = {24'b0,       b};
        F3_H:    golden = {{16{h[15]}}, h};
        F3_HU:   golden = {16'b0,       h};
        default: golden = d;              // LW
      endcase
    end
  endfunction

  task chk;
    input [255:0] n;
    input [31:0]  d;
    input [1:0]   off;
    input [2:0]   f3;
    input [31:0]  exp;
    begin
      rdata = d; lsbs = off; funct3 = f3; #1;
      if (load_data !== exp) begin
        $display("FAIL %0s: rdata=%h off=%b f3=%b got=%h exp=%h",
                 n, d, off, f3, load_data, exp);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // ---- LB: every lane, all bytes negative in this pattern ------------
    chk("lb_lane0", 32'h8081_8283, 2'b00, F3_B, 32'hFFFF_FF83);
    chk("lb_lane1", 32'h8081_8283, 2'b01, F3_B, 32'hFFFF_FF82);
    chk("lb_lane2", 32'h8081_8283, 2'b10, F3_B, 32'hFFFF_FF81);
    chk("lb_lane3", 32'h8081_8283, 2'b11, F3_B, 32'hFFFF_FF80);
    // ---- LBU: same lanes, zero-extended --------------------------------
    chk("lbu_lane0", 32'h8081_8283, 2'b00, F3_BU, 32'h0000_0083);
    chk("lbu_lane1", 32'h8081_8283, 2'b01, F3_BU, 32'h0000_0082);
    chk("lbu_lane2", 32'h8081_8283, 2'b10, F3_BU, 32'h0000_0081);
    chk("lbu_lane3", 32'h8081_8283, 2'b11, F3_BU, 32'h0000_0080);
    // ---- LB on positive data: no extension --------------------------
    chk("lb_pos_lane0", 32'h0102_0304, 2'b00, F3_B, 32'h0000_0004);
    chk("lb_pos_lane3", 32'h0102_0304, 2'b11, F3_B, 32'h0000_0001);
    chk("lb_boundary_7F", 32'h0000_007F, 2'b00, F3_B, 32'h0000_007F);
    chk("lb_boundary_80", 32'h0000_0080, 2'b00, F3_B, 32'hFFFF_FF80);

    // ---- LH / LHU: half selected by addr[1]; addr[0] is ignored --------
    chk("lh_half0",     32'h8081_8283, 2'b00, F3_H,  32'hFFFF_8283);
    chk("lh_half0_odd", 32'h8081_8283, 2'b01, F3_H,  32'hFFFF_8283);
    chk("lh_half1",     32'h8081_8283, 2'b10, F3_H,  32'hFFFF_8081);
    chk("lh_half1_odd", 32'h8081_8283, 2'b11, F3_H,  32'hFFFF_8081);
    chk("lhu_half0",    32'h8081_8283, 2'b00, F3_HU, 32'h0000_8283);
    chk("lhu_half1",    32'h8081_8283, 2'b10, F3_HU, 32'h0000_8081);
    chk("lh_pos",       32'h0102_0304, 2'b00, F3_H,  32'h0000_0304);
    chk("lh_boundary_7FFF", 32'h0000_7FFF, 2'b00, F3_H, 32'h0000_7FFF);
    chk("lh_boundary_8000", 32'h0000_8000, 2'b00, F3_H, 32'hFFFF_8000);

    // ---- LW: pass-through at any offset --------------------------------
    chk("lw_off0", 32'hDEAD_BEEF, 2'b00, F3_W, 32'hDEAD_BEEF);
    chk("lw_off1", 32'hDEAD_BEEF, 2'b01, F3_W, 32'hDEAD_BEEF);
    chk("lw_off2", 32'hDEAD_BEEF, 2'b10, F3_W, 32'hDEAD_BEEF);
    chk("lw_off3", 32'hDEAD_BEEF, 2'b11, F3_W, 32'hDEAD_BEEF);
    chk("lw_zero", 32'h0000_0000, 2'b00, F3_W, 32'h0000_0000);
    chk("lw_ones", 32'hFFFF_FFFF, 2'b00, F3_W, 32'hFFFF_FFFF);

    // ---- exhaustive sweep vs golden: 4 offsets x 5 funct3 x N data -----
    for (i = 0; i < 500; i = i + 1) begin
      rdata = $random;
      for (j = 0; j < 4; j = j + 1) begin
        lsbs = j[1:0];
        funct3 = F3_B;  #1; if (load_data !== golden(rdata, lsbs, funct3)) begin
          $display("FAIL sweep LB  d=%h off=%b got=%h exp=%h",
                   rdata, lsbs, load_data, golden(rdata, lsbs, funct3));
          errors = errors + 1; end
        funct3 = F3_BU; #1; if (load_data !== golden(rdata, lsbs, funct3)) begin
          $display("FAIL sweep LBU d=%h off=%b got=%h exp=%h",
                   rdata, lsbs, load_data, golden(rdata, lsbs, funct3));
          errors = errors + 1; end
        funct3 = F3_H;  #1; if (load_data !== golden(rdata, lsbs, funct3)) begin
          $display("FAIL sweep LH  d=%h off=%b got=%h exp=%h",
                   rdata, lsbs, load_data, golden(rdata, lsbs, funct3));
          errors = errors + 1; end
        funct3 = F3_HU; #1; if (load_data !== golden(rdata, lsbs, funct3)) begin
          $display("FAIL sweep LHU d=%h off=%b got=%h exp=%h",
                   rdata, lsbs, load_data, golden(rdata, lsbs, funct3));
          errors = errors + 1; end
        funct3 = F3_W;  #1; if (load_data !== golden(rdata, lsbs, funct3)) begin
          $display("FAIL sweep LW  d=%h off=%b got=%h exp=%h",
                   rdata, lsbs, load_data, golden(rdata, lsbs, funct3));
          errors = errors + 1; end
      end
    end

    if (errors == 0) $display("LOAD_FORMATTER UNIT: ALL CHECKS PASSED");
    else             $display("LOAD_FORMATTER UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
