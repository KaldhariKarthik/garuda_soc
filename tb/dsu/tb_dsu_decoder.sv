// =============================================================
// tb_dsu_decoder.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/dsu_decoder.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA dsu_decoder.v
// (frozen Custom-0 DSU instruction decode table, Section 9.2/9.3)
//
// Purely combinational, but the field-extraction/legality table is
// the single most bug-prone piece of the DSU, so this TB pairs
// directed one-case-per-funct5 coverage with an EXHAUSTIVE sweep of
// every (funct5, funct3, is_custom0, acc_sel) combination --
// 32*8*2*4 = 2048 combos -- checked against a golden model derived
// independently from the documented bit layout (Section 9.2), not
// from the RTL's own field ordering.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0b. TEST CONTROL -- reproducibility, runtime knobs, log hygiene
//
// A 1500+ case constrained-random run has three practical problems
// that a 100%-coverage result does NOT reveal:
//   1. The seed is printed every run so it can be recorded for the
//      report; each run draws a fresh random seed by design.
//   2. Changing the iteration count should not need a recompile --
//      +NRAND=<n> overrides it (e.g. a long soak before sign-off).
//   3. Every case prints a [PASS]/[FAIL] line as it runs, so the
//      SUMMARY total can be cross-checked against the live log.
// -------------------------------------------------------------
real tb_cov_goal = 100.0;   // sign-off goal; relax with +COV_GOAL=<percent>

task automatic tb_control_init(inout int nrand, input string tb_name);
    int seed_arg;
    seed_arg = $urandom;
    void'($urandom(seed_arg));
    $display("[%0s] seed = %0d", tb_name, seed_arg);
    $display("[%0s] random_cases=%0d", tb_name, nrand);
endtask

// tb_signoff -- a run is only signed off if BOTH criteria hold. A green
// "ALL CHECKS PASSED" at 60% coverage means the stimulus never reached the
// logic, not that the logic is right, so coverage is part of the verdict
// rather than a number printed beside it. Goal defaults to 100% and can be
// relaxed for a smoke run with +COV_GOAL=<percent>.

task automatic tb_signoff(real cov, int fails);
    if (fails != 0)
        $display(" SIGN-OFF: FAIL          -- %0d check(s) failed (coverage %0.2f%%)", fails, cov);
    else if (cov < tb_cov_goal)
        $display(" SIGN-OFF: NOT SIGNED OFF -- checks passed, but coverage %0.2f%% < goal %0.2f%%",
                  cov, tb_cov_goal);
    else
        $display(" SIGN-OFF: PASS          -- 0 failures and coverage %0.2f%% >= goal %0.2f%%",
                  cov, tb_cov_goal);
endtask



// -------------------------------------------------------------
// 0. DEFINES (inlined from dsu_defs.vh)
// -------------------------------------------------------------
`ifndef DSU_DEFS_VH
`define DSU_DEFS_VH
`define ACC_FX  2'b00
`define ACC_FY  2'b01
`define ACC_MAG 2'b10
`define MAC_CTRL_W      7
`define MAC_CTRL_EN     6
`define MAC_CTRL_ADDSUB 5
`define MAC_CTRL_CLEAR  4
`define MAC_CTRL_LOAD   3
`define MAC_CTRL_ABS    2
`define MAC_CTRL_DOT    1
`define MAC_CTRL_FLUSH  0
`define FUNCT5_MAC_SEL  5'd0
`define FUNCT5_MACSUB   5'd1
`define FUNCT5_MACABS   5'd2
`define FUNCT5_MACDOT   5'd3
`define FUNCT5_MACLOAD  5'd4
`define FUNCT5_MACCLEAR 5'd5
`define FUNCT5_MACSAT   5'd6
`define FUNCT5_MACRD_LO 5'd7
`define FUNCT5_MACRD_HI 5'd8
`define FUNCT5_MACSHIFT 5'd9
`endif

// -------------------------------------------------------------
// 1. DUT: dsu_decoder.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
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
    assign illegal_instr = is_custom0 & dsu_en & (~any_legal_op | bad_acc_sel | bad_funct3);

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


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface dsu_decoder_if (input bit clk);
    logic [31:0] instr;
    logic        dsu_en, flush;
    logic [6:0]  control;
    logic [1:0]  acc_sel;
    logic        sat_op;
    logic        shift_op;
    logic [5:0]  shift_amt;
    logic        shift_dir;
    logic [1:0]  shift_acc_sel;
    logic        rd_lo_op, rd_hi_op;
    logic [1:0]  result_src;
    logic        writes_regfile;
    logic [4:0]  rd_addr;
    logic        illegal_instr;
    logic [4:0]  funct5;
    logic [2:0]  funct3;
    logic        is_custom0;

    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({instr, dsu_en, flush})) |-> (!$isunknown(illegal_instr));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on dsu_decoder illegal_instr with fully-known inputs");

    // writes_regfile and illegal_instr can never both be true.
    property p_illegal_never_writes;
        @(posedge clk) illegal_instr |-> !writes_regfile;
    endproperty
    a_illegal_never_writes: assert property (p_illegal_never_writes)
        else $error("[SVA-FAIL] illegal_instr and writes_regfile both asserted");

    // Nothing outside Custom-0 can ever set illegal_instr (opcode
    // mismatch is simply not a DSU-format instruction at all).
    property p_non_custom0_never_illegal;
        @(posedge clk) !is_custom0 |-> !illegal_instr;
    endproperty
    a_non_custom0_never_illegal: assert property (p_non_custom0_never_illegal)
        else $error("[SVA-FAIL] illegal_instr asserted for a non-Custom-0 opcode");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class dec_txn;
    rand bit [31:0] instr;
    rand bit        dsu_en, flush;
    string tag;

    bit [6:0] control_act, control_exp;
    bit [1:0] acc_sel_act, acc_sel_exp;
    bit sat_op_act, sat_op_exp;
    bit shift_op_act, shift_op_exp;
    bit [5:0] shift_amt_act, shift_amt_exp;
    bit shift_dir_act, shift_dir_exp;
    bit [1:0] shift_acc_sel_act, shift_acc_sel_exp;
    bit rd_lo_op_act, rd_lo_op_exp, rd_hi_op_act, rd_hi_op_exp;
    bit [1:0] result_src_act, result_src_exp;
    bit writes_regfile_act, writes_regfile_exp;
    bit [4:0] rd_addr_act, rd_addr_exp;
    bit illegal_instr_act, illegal_instr_exp;

    constraint c_opcode_dist { instr[6:0] dist { 7'b0001011 := 80, [0:127] :/ 20 }; }
    constraint c_dsu_en_dist { dsu_en dist { 1 := 85, 0 := 15 }; }
    constraint c_funct3_dist { instr[14:12] dist { 3'b000 := 45, 3'b001 := 45, [3'b010:3'b111] :/ 10 }; }
    constraint c_funct5_dist { instr[31:27] dist { [0:9] := 90, [10:31] :/ 10 }; }
    constraint c_accsel_dist { instr[26:25] dist { 2'b00:=30, 2'b01:=30, 2'b10:=30, 2'b11:=10 }; }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("instr=%08h dsu_en=%0b flush=%0b", instr, dsu_en, flush);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL -- re-derives the full field
//    extraction + legality table directly from the documented bit
//    layout, independent of the RTL's own wire ordering.
// -------------------------------------------------------------
function automatic bit [31:0] mk_rtype(bit [4:0] funct5, bit [1:0] acc_sel,
                                        bit [4:0] rs2f, bit [4:0] rs1f, bit [4:0] rdf);
    return {funct5, acc_sel, rs2f, rs1f, 3'b000, rdf, 7'b0001011};
endfunction

function automatic bit [31:0] mk_itype_shift(bit dir, bit [1:0] acc_sel,
                                              bit [5:0] shamt, bit [4:0] rs1f, bit [4:0] rdf);
    bit [11:0] imm_i = {3'b000, dir, acc_sel, shamt};
    return {imm_i, rs1f, 3'b001, rdf, 7'b0001011};
endfunction

function automatic void dec_golden(dec_txn t);
    bit [6:0]  opcode    = t.instr[6:0];
    bit [4:0]  rd_f      = t.instr[11:7];
    bit [2:0]  funct3    = t.instr[14:12];
    bit [1:0]  acc_sel_r = t.instr[26:25];
    bit [4:0]  funct5_r  = t.instr[31:27];
    bit [11:0] imm_i     = t.instr[31:20];

    bit is_custom0 = (opcode == 7'b0001011);
    bit is_rtype = is_custom0 & (funct3 == 3'b000);
    bit is_itype = is_custom0 & (funct3 == 3'b001);

    bit op_mac_sel  = is_rtype & (funct5_r == `FUNCT5_MAC_SEL);
    bit op_macsub   = is_rtype & (funct5_r == `FUNCT5_MACSUB);
    bit op_macabs   = is_rtype & (funct5_r == `FUNCT5_MACABS);
    bit op_macdot   = is_rtype & (funct5_r == `FUNCT5_MACDOT);
    bit op_macload  = is_rtype & (funct5_r == `FUNCT5_MACLOAD);
    bit op_macclear = is_rtype & (funct5_r == `FUNCT5_MACCLEAR);
    bit op_macsat   = is_rtype & (funct5_r == `FUNCT5_MACSAT);
    bit op_rd_lo    = is_rtype & (funct5_r == `FUNCT5_MACRD_LO);
    bit op_rd_hi    = is_rtype & (funct5_r == `FUNCT5_MACRD_HI);
    bit op_macshift = is_itype;

    bit [1:0] acc_sel_eff = is_itype ? imm_i[7:6] : acc_sel_r;

    bit any_legal_op = op_mac_sel | op_macsub | op_macabs | op_macdot | op_macload
                      | op_macclear | op_macsat | op_rd_lo | op_rd_hi | op_macshift;
    bit bad_acc_sel = (acc_sel_eff == 2'b11);
    bit bad_funct3  = is_custom0 & ~(is_rtype | is_itype);
    bit illegal = is_custom0 & t.dsu_en & (~any_legal_op | bad_acc_sel | bad_funct3);

    bit compute_op = op_mac_sel | op_macsub | op_macabs | op_macdot | op_macload | op_macclear;
    bit mac_en     = compute_op & t.dsu_en & ~illegal;

    t.control_exp = {mac_en, op_macsub, op_macclear, op_macload, op_macabs, op_macdot, t.flush};
    t.acc_sel_exp = acc_sel_eff;
    t.sat_op_exp  = op_macsat & t.dsu_en & ~illegal;
    t.shift_op_exp = op_macshift & t.dsu_en & ~illegal;
    t.rd_lo_op_exp = op_rd_lo & t.dsu_en & ~illegal;
    t.rd_hi_op_exp = op_rd_hi & t.dsu_en & ~illegal;
    t.shift_amt_exp = imm_i[5:0];
    t.shift_dir_exp = imm_i[8];
    t.shift_acc_sel_exp = imm_i[7:6];
    t.result_src_exp = op_rd_lo ? 2'b01 : op_rd_hi ? 2'b10 : op_macshift ? 2'b11 : 2'b00;
    t.writes_regfile_exp = (op_rd_lo | op_rd_hi | op_macshift) & t.dsu_en & ~illegal;
    t.rd_addr_exp = rd_f;
    t.illegal_instr_exp = illegal;
endfunction


// -------------------------------------------------------------
// 5. GENERATOR -- directed one-per-funct5 + illegal shapes + an
//    EXHAUSTIVE (funct5,funct3,is_custom0,acc_sel) sweep + CRV.
// -------------------------------------------------------------
class dec_generator;
    dec_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function dec_txn mk(string tag, bit [31:0] instr, bit dsu_en = 1, bit flush = 0);
        dec_txn t = new(tag);
        t.instr = instr; t.dsu_en = dsu_en; t.flush = flush;
        return t;
    endfunction

    function void build();
        items.push_back(mk("dir_mac_sel",  mk_rtype(`FUNCT5_MAC_SEL,  `ACC_FX, 5'd2,5'd1,5'd3)));
        items.push_back(mk("dir_macsub",   mk_rtype(`FUNCT5_MACSUB,   `ACC_FY, 5'd2,5'd1,5'd3)));
        items.push_back(mk("dir_macabs",   mk_rtype(`FUNCT5_MACABS,   `ACC_MAG,5'd2,5'd1,5'd3)));
        items.push_back(mk("dir_macdot",   mk_rtype(`FUNCT5_MACDOT,   `ACC_FX, 5'd2,5'd1,5'd3)));
        items.push_back(mk("dir_macload",  mk_rtype(`FUNCT5_MACLOAD,  `ACC_FY, 5'd2,5'd1,5'd3)));
        items.push_back(mk("dir_macclear", mk_rtype(`FUNCT5_MACCLEAR, `ACC_MAG,5'd2,5'd1,5'd3)));
        items.push_back(mk("dir_macsat",   mk_rtype(`FUNCT5_MACSAT,   `ACC_FX, 5'd0,5'd0,5'd4)));
        items.push_back(mk("dir_rdlo",     mk_rtype(`FUNCT5_MACRD_LO, `ACC_FY, 5'd0,5'd0,5'd5)));
        items.push_back(mk("dir_rdhi",     mk_rtype(`FUNCT5_MACRD_HI, `ACC_MAG,5'd0,5'd0,5'd6)));
        items.push_back(mk("dir_macshift_left",  mk_itype_shift(1'b1, `ACC_FX, 6'd7,  5'd1, 5'd7)));
        items.push_back(mk("dir_macshift_right", mk_itype_shift(1'b0, `ACC_FY, 6'd20, 5'd1, 5'd8)));

        items.push_back(mk("dir_illegal_accsel", mk_rtype(`FUNCT5_MAC_SEL, 2'b11, 5'd0,5'd0,5'd9)));
        items.push_back(mk("dir_illegal_funct5", mk_rtype(5'd20, `ACC_FX, 5'd0,5'd0,5'd10)));
        items.push_back(mk("dir_illegal_funct3", {5'd0, `ACC_FX, 5'd0, 5'd0, 3'b010, 5'd11, 7'b0001011}));
        items.push_back(mk("dir_not_custom0", 32'h0000_0013));                          // ADDI
        items.push_back(mk("dir_dsu_en_low",  mk_rtype(`FUNCT5_MACSUB, `ACC_FX, 5'd0,5'd0,5'd12), 0));
        items.push_back(mk("dir_flush_passthrough", 32'h0, 0, 1));

        // EXHAUSTIVE: sweep every (funct5, funct3, is_custom0, acc_sel)
        // combination -- 32*8*2*4 = 2048 combos -- since the equality/OR
        // chain deriving any_legal_op/bad_funct3/bad_acc_sel is exactly
        // where an off-by-one or a missed encoding would hide.
        for (int f5i = 0; f5i < 32; f5i++) begin
            for (int f3i = 0; f3i < 8; f3i++) begin
                for (int ic0i = 0; ic0i < 2; ic0i++) begin
                    for (int acci = 0; acci < 4; acci++) begin
                        bit [31:0] w = {f5i[4:0], acci[1:0], 5'd0, 5'd0, f3i[2:0], 5'd0, (ic0i[0] ? 7'b0001011 : 7'b0110011)};
                        items.push_back(mk($sformatf("EXH_f5%0d_f3%0d_ic0%0d_acc%0d", f5i, f3i, ic0i, acci), w));
                    end
                end
            end
        end

        // The exhaustive sweep above always leaves dsu_en at its mk() default
        // of 1, so it never touches the dsu_en=0 side of `cross cp_funct5,
        // cp_dsu_en` -- that cross needs all 32 funct5 values seen with BOTH
        // dsu_en states, and only ONE directed case (dir_dsu_en_low) and
        // whatever random luck (15% dsu_en=0 weight) cover it otherwise.
        // Sweep funct5 x dsu_en explicitly so the cross is hit by
        // construction instead of by chance.
        for (int f5j = 0; f5j < 32; f5j++) begin
            bit [31:0] wj = {f5j[4:0], `ACC_FX, 5'd0, 5'd0, 3'b000, 5'd0, 7'b0001011};
            items.push_back(mk($sformatf("EXH_dsuen0_f5%0d", f5j), wj, 0));
        end

        repeat (num_random) begin
            dec_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class dec_driver;
    virtual dsu_decoder_if vif;
    function new(virtual dsu_decoder_if vif); this.vif = vif; endfunction

    task apply(dec_txn t);
        @(negedge vif.clk);
        vif.instr <= t.instr; vif.dsu_en <= t.dsu_en; vif.flush <= t.flush;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class dec_monitor;
    virtual dsu_decoder_if vif;

    covergroup cg_dec;
        cp_funct5: coverpoint vif.instr[31:27] { bins legal[] = {[0:9]}; bins illegal_range[] = {[10:31]}; }
        cp_funct3: coverpoint vif.instr[14:12] { bins rtype={3'b000}; bins itype={3'b001}; bins bad[]={[3'b010:3'b111]}; }
        cp_is_custom0: coverpoint (vif.instr[6:0]==7'b0001011);
        cp_dsu_en: coverpoint vif.dsu_en;
        cp_illegal: coverpoint vif.illegal_instr;
        cp_accsel: coverpoint vif.instr[26:25];
        cross cp_funct5, cp_dsu_en;
    endgroup

    function new(virtual dsu_decoder_if vif); this.vif = vif; cg_dec = new(); endfunction

    task sample_one(output dec_txn a);
        a = new();
        #1;
        a.control_act = vif.control; a.acc_sel_act = vif.acc_sel; a.sat_op_act = vif.sat_op;
        a.shift_op_act = vif.shift_op; a.shift_amt_act = vif.shift_amt; a.shift_dir_act = vif.shift_dir;
        a.shift_acc_sel_act = vif.shift_acc_sel; a.rd_lo_op_act = vif.rd_lo_op; a.rd_hi_op_act = vif.rd_hi_op;
        a.result_src_act = vif.result_src; a.writes_regfile_act = vif.writes_regfile;
        a.rd_addr_act = vif.rd_addr; a.illegal_instr_act = vif.illegal_instr;
        cg_dec.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class dec_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(dec_txn t, dec_txn a);
        bit ok;
        dec_golden(t);
        ok = (a.control_act===t.control_exp) & (a.acc_sel_act===t.acc_sel_exp)
           & (a.sat_op_act===t.sat_op_exp) & (a.shift_op_act===t.shift_op_exp)
           & (a.shift_amt_act===t.shift_amt_exp) & (a.shift_dir_act===t.shift_dir_exp)
           & (a.shift_acc_sel_act===t.shift_acc_sel_exp)
           & (a.rd_lo_op_act===t.rd_lo_op_exp) & (a.rd_hi_op_act===t.rd_hi_op_exp)
           & (a.result_src_act===t.result_src_exp) & (a.writes_regfile_act===t.writes_regfile_exp)
           & (a.rd_addr_act===t.rd_addr_exp) & (a.illegal_instr_act===t.illegal_instr_exp);

        if (ok) begin
            pass_cnt++;
            $display("[PASS] %-30s %-0s -> ctrl=%07b illegal=%0b wr=%0b",
                      t.tag, t.to_s(), a.control_act, a.illegal_instr_act, a.writes_regfile_act);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-30s %-0s -> got(ctrl=%07b acc=%02b sat=%0b shift=%0b amt=%0d dir=%0b sacc=%02b lo=%0b hi=%0b rsrc=%02b wr=%0b rd=%0d ill=%0b) exp(ctrl=%07b acc=%02b sat=%0b shift=%0b amt=%0d dir=%0b sacc=%02b lo=%0b hi=%0b rsrc=%02b wr=%0b rd=%0d ill=%0b)",
                      t.tag, t.to_s(),
                      a.control_act, a.acc_sel_act, a.sat_op_act, a.shift_op_act, a.shift_amt_act, a.shift_dir_act,
                      a.shift_acc_sel_act, a.rd_lo_op_act, a.rd_hi_op_act, a.result_src_act, a.writes_regfile_act, a.rd_addr_act, a.illegal_instr_act,
                      t.control_exp, t.acc_sel_exp, t.sat_op_exp, t.shift_op_exp, t.shift_amt_exp, t.shift_dir_exp,
                      t.shift_acc_sel_exp, t.rd_lo_op_exp, t.rd_hi_op_exp, t.result_src_exp, t.writes_regfile_exp, t.rd_addr_exp, t.illegal_instr_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class dec_env;
    virtual dsu_decoder_if vif;
    dec_generator  gen;
    dec_driver     drv;
    dec_monitor    mon;
    dec_scoreboard sb;

    function new(virtual dsu_decoder_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        dec_txn a;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(a);
            sb.check(gen.items[i], a);
        end

        $display("\n================ DSU_DECODER UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_dec.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_dec.get_coverage(), sb.fail_cnt);
        $display("================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class dec_test;
    dec_env env;
    function new(virtual dsu_decoder_if vif, int num_random = 1500);
        env = new(vif, num_random);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------

module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    dsu_decoder_if vif(clk);

    dsu_decoder dut (
        .instr(vif.instr), .dsu_en(vif.dsu_en), .flush(vif.flush),
        .control(vif.control), .acc_sel(vif.acc_sel), .sat_op(vif.sat_op),
        .shift_op(vif.shift_op), .shift_amt(vif.shift_amt), .shift_dir(vif.shift_dir),
        .shift_acc_sel(vif.shift_acc_sel), .rd_lo_op(vif.rd_lo_op), .rd_hi_op(vif.rd_hi_op),
        .result_src(vif.result_src), .writes_regfile(vif.writes_regfile), .rd_addr(vif.rd_addr),
        .illegal_instr(vif.illegal_instr), .funct5(vif.funct5), .funct3(vif.funct3),
        .is_custom0(vif.is_custom0)
    );

    dec_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_decoder");
        vif.instr = 0; vif.dsu_en = 0; vif.flush = 0;
        repeat (3) @(posedge clk);

        test = new(vif, tb_nrand);
        test.run();
        $finish;
    end

endmodule
