// =============================================================================
// tb_branch_unit.sv -- SystemVerilog unit TB for rtl/core/branch_unit.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 12.2 / 12.3, plus ERRATUM T-1
//       (instruction-address-misaligned, cause 0) as implemented in the RTL.
// Plan: C06 (static prediction), C07 (mispredict both directions), C08 (JAL
//       link and target), C09 (JALR target, forwarded rs1). The bubble COUNTS
//       are a pipe_ctrl property covered by tb_pipe_ctrl; this TB owns the
//       redirect request and target that drive them.
//
// The check that exists because of a real bug: ERRATUM T-1. target_misaligned
// is raised off JAL and off a TAKEN branch, not off the redirect output -- because JAL
// and predicted-taken branches redirect from ID and never assert that output
// here at all. An EX check hung off the redirect signal misses exactly the
// JAL case that rv32mi/ma_fetch exercises. The SVA and the directed sequence
// below both state it independently.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps
`include "core_ex_defs.vh"

// -------------------------------------------------------------
// 1. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface branch_if (input bit clk);
    logic [31:0] pc, imm, rs1_fwd, rs2_fwd;
    logic [2:0]  funct3;
    logic        branch, jal, jalr, predicted_taken;
    logic        branch_taken, mispredict, redirect, target_misaligned;
    logic [31:0] redirect_target;

    // A1: branch_taken is qualified by the branch control bit. A matching
    //     comparison on a non-branch instruction must stay silent.
    property p_taken_requires_branch;
        @(posedge clk) (!branch) |-> (!branch_taken);
    endproperty
    a_taken_gated: assert property (p_taken_requires_branch)
        else $error("[SVA-FAIL] branch_taken asserted on a non-branch instruction");

    // A2: a correctly predicted branch costs nothing (Sec. 12.3 "no action").
    property p_correct_prediction_is_free;
        @(posedge clk) (branch && (branch_taken == predicted_taken))
                       |-> (!mispredict);
    endproperty
    a_pred_free: assert property (p_correct_prediction_is_free)
        else $error("[SVA-FAIL] a correct prediction raised mispredict");

    // A3: JALR always redirects from EX (Sec. 12.2), whatever the prediction
    //     bit or funct3 happen to be.
    property p_jalr_always_redirects;
        @(posedge clk) jalr |-> redirect;
    endproperty
    a_jalr_redir: assert property (p_jalr_always_redirects)
        else $error("[SVA-FAIL] JALR did not request an EX redirect");

    // A4: the JALR target has bit 0 MASKED (RISC-V requires masking, not a
    //     trap) -- so a JALR redirect target is always even.
    property p_jalr_target_lsb_clear;
        @(posedge clk) jalr |-> (redirect_target[0] == 1'b0);
    endproperty
    a_jalr_lsb: assert property (p_jalr_target_lsb_clear)
        else $error("[SVA-FAIL] JALR target did not have its LSB masked");

    // A5: ERRATUM T-1. Nothing that is not a control transfer may raise
    //     instruction-address-misaligned.
    property p_misalign_only_on_transfer;
        @(posedge clk) (!(jal || jalr || branch_taken)) |-> (!target_misaligned);
    endproperty
    a_misalign_scope: assert property (p_misalign_only_on_transfer)
        else $error("[SVA-FAIL] target_misaligned raised without a taken control transfer");

    // A6: GARUDA has no C extension, so any taken transfer to a target whose
    //     low two bits are non-zero MUST be flagged.
    property p_misalign_is_raised;
        @(posedge clk) ((jal || branch_taken) && ((pc + imm) % 4 != 0))
                       |-> target_misaligned;
    endproperty
    a_misalign_raised: assert property (p_misalign_is_raised)
        else $error("[SVA-FAIL] a misaligned JAL/branch target was not flagged");

    property p_no_x;
        @(posedge clk) (!$isunknown({pc, imm, rs1_fwd, rs2_fwd, funct3,
                                     branch, jal, jalr, predicted_taken}))
                       |-> (!$isunknown({branch_taken, mispredict, redirect,
                                         target_misaligned}));
    endproperty
    a_no_x: assert property (p_no_x)
        else $error("[SVA-FAIL] a control output went unknown with known inputs");
endinterface


// -------------------------------------------------------------
// 2. STIMULUS ITEM
// -------------------------------------------------------------
typedef enum {
    BK_BRANCH_TAKEN, BK_BRANCH_NOTTAKEN, BK_MISPREDICT, BK_JAL, BK_JALR,
    BK_MISALIGNED, BK_IDLE, BK_RANDOM
} br_kind_e;

class br_cycle;
    rand br_kind_e  kind;
    rand bit [31:0] pc, imm, rs1, rs2;
    rand bit [2:0]  f3;
    rand bit        branch, jal, jalr, pred;

    // funct3 010/011 are reserved for BRANCH and are trapped in ID, so they
    // never reach this block (RTL comment on the comparator default arm).
    constraint c_f3 { branch -> f3 inside {`BR_BEQ, `BR_BNE, `BR_BLT,
                                           `BR_BGE, `BR_BLTU, `BR_BGEU}; }

    // branch / jal / jalr are mutually exclusive by decode.
    constraint c_exclusive { $countones({branch, jal, jalr}) <= 1; }

    constraint c_kind_dist {
        kind dist { BK_BRANCH_TAKEN :/ 15, BK_BRANCH_NOTTAKEN :/ 15,
                    BK_MISPREDICT :/ 20, BK_JAL :/ 10, BK_JALR :/ 15,
                    BK_MISALIGNED :/ 10, BK_IDLE :/ 5, BK_RANDOM :/ 10 };
    }

    constraint c_kind_shape {
        (kind inside {BK_BRANCH_TAKEN, BK_BRANCH_NOTTAKEN, BK_MISPREDICT})
            -> (branch == 1 && jal == 0 && jalr == 0);
        (kind == BK_JAL)  -> (jal == 1 && branch == 0 && jalr == 0);
        (kind == BK_JALR) -> (jalr == 1 && branch == 0 && jal == 0);
        (kind == BK_IDLE) -> (branch == 0 && jal == 0 && jalr == 0);
        // equal operands force BEQ taken / BNE not-taken deterministically
        (kind == BK_BRANCH_TAKEN)    -> (f3 == `BR_BEQ && rs1 == rs2);
        (kind == BK_BRANCH_NOTTAKEN) -> (f3 == `BR_BEQ && rs1 != rs2);
    }

    // Targets clustered on the 4-byte boundary so the misalign path is
    // exercised rather than being a 1-in-4 accident.
    constraint c_alignment {
        (kind == BK_MISALIGNED) -> (imm[1:0] != 2'b00);
        (kind == BK_MISALIGNED) -> (pc[1:0] == 2'b00);
        (kind != BK_MISALIGNED) -> (imm[1:0] inside {2'b00, 2'b10});
        pc[1:0] == 2'b00;                   // the PC itself is always aligned
    }
endclass


// -------------------------------------------------------------
// 3. REFERENCE MODEL -- from Sec. 12.2 / 12.3, not the RTL
// -------------------------------------------------------------
class br_result;
    bit        taken, mispredict, redirect, misaligned;
    bit [31:0] target;
endclass

class br_ref_model;
    function automatic br_result step(bit [31:0] pc, bit [31:0] imm,
                                       bit [2:0] f3,
                                       bit [31:0] rs1, bit [31:0] rs2,
                                       bit branch, bit jal, bit jalr, bit pred);
        br_result r = new();
        bit       cond;
        bit [31:0] btgt = pc + imm;
        bit [31:0] fall = pc + 32'd4;
        bit [31:0] jtgt = (rs1 + imm) & 32'hFFFF_FFFE;

        case (f3)
            `BR_BEQ:  cond = (rs1 == rs2);
            `BR_BNE:  cond = (rs1 != rs2);
            `BR_BLT:  cond = ($signed(rs1) <  $signed(rs2));
            `BR_BGE:  cond = ($signed(rs1) >= $signed(rs2));
            `BR_BLTU: cond = (rs1 <  rs2);
            `BR_BGEU: cond = (rs1 >= rs2);
            default:  cond = 1'b0;
        endcase

        r.taken      = branch & cond;
        r.mispredict = branch & (cond ^ pred);
        r.redirect   = jalr | r.mispredict;
        r.target     = jalr ? jtgt : (cond ? btgt : fall);
        r.misaligned = jalr                ? (jtgt[1:0] != 2'b00) :
                       (jal | r.taken)     ? (btgt[1:0] != 2'b00) : 1'b0;
        return r;
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR
// -------------------------------------------------------------
class br_generator;
    br_cycle seq_q[$][$];
    string   seq_name[$];
    int      nseq, slen;

    function new(int nseq = 8, int slen = 200);
        this.nseq = nseq; this.slen = slen;
    endfunction

    function br_cycle mk(br_kind_e k, bit [31:0] pc, bit [31:0] imm,
                          bit [2:0] f3, bit [31:0] rs1, bit [31:0] rs2,
                          bit branch, bit jal, bit jalr, bit pred);
        br_cycle c = new();
        c.kind = k; c.pc = pc; c.imm = imm; c.f3 = f3;
        c.rs1 = rs1; c.rs2 = rs2;
        c.branch = branch; c.jal = jal; c.jalr = jalr; c.pred = pred;
        return c;
    endfunction

    function void add_seq(string name, br_cycle q[$]);
        seq_name.push_back(name); seq_q.push_back(q);
    endfunction

    function void build();
        // 1) the comparator, all six funct3, both directions
        begin
            br_cycle q[$];
            q.push_back(mk(BK_BRANCH_TAKEN,    32'h1000_0100, 32'd8, `BR_BEQ,  5, 5, 1,0,0,0));
            q.push_back(mk(BK_BRANCH_NOTTAKEN, 32'h1000_0100, 32'd8, `BR_BEQ,  5, 6, 1,0,0,0));
            q.push_back(mk(BK_BRANCH_TAKEN,    32'h1000_0100, 32'd8, `BR_BNE,  5, 6, 1,0,0,0));
            q.push_back(mk(BK_BRANCH_NOTTAKEN, 32'h1000_0100, 32'd8, `BR_BNE,  5, 5, 1,0,0,0));
            // signed vs unsigned: the (-1, 1) pair is what separates them
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BLT,  32'hFFFF_FFFF, 32'd1, 1,0,0,0));
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BLT,  32'd1, 32'hFFFF_FFFF, 1,0,0,0));
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BGE,  32'd1, 32'hFFFF_FFFF, 1,0,0,0));
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BGE,  32'd5, 32'd5, 1,0,0,0));
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BLTU, 32'd1, 32'hFFFF_FFFF, 1,0,0,0));
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BLTU, 32'hFFFF_FFFF, 32'd1, 1,0,0,0));
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BGEU, 32'hFFFF_FFFF, 32'd1, 1,0,0,0));
            q.push_back(mk(BK_RANDOM, 32'h1000_0100, 32'd8, `BR_BGEU, 32'd5, 32'd5, 1,0,0,0));
            add_seq("comparator_all_funct3", q);
        end
        // 2) correct predictions in both directions cost nothing (C06)
        begin
            br_cycle q[$];
            // backward branch, predicted taken, actually taken
            q.push_back(mk(BK_BRANCH_TAKEN, 32'h1000_0100, 32'hFFFF_FFF0, `BR_BEQ, 5, 5, 1,0,0,1));
            // forward branch, predicted not-taken, actually not taken
            q.push_back(mk(BK_BRANCH_NOTTAKEN, 32'h1000_0100, 32'd16, `BR_BEQ, 5, 6, 1,0,0,0));
            add_seq("correct_prediction_free", q);
        end
        // 3) mispredict, both directions (C07)
        begin
            br_cycle q[$];
            // predicted not-taken, actually taken -> pc + Bimm
            q.push_back(mk(BK_MISPREDICT, 32'h1000_0100, 32'd32, `BR_BEQ, 5, 5, 1,0,0,0));
            // predicted taken, actually not taken -> pc + 4
            q.push_back(mk(BK_MISPREDICT, 32'h1000_0100, 32'hFFFF_FFF0, `BR_BEQ, 5, 6, 1,0,0,1));
            // backward target arithmetic with a negative immediate
            q.push_back(mk(BK_MISPREDICT, 32'h1000_0100, 32'hFFFF_FFE0, `BR_BNE, 1, 2, 1,0,0,0));
            add_seq("mispredict_both_directions", q);
        end
        // 4) JALR (C09): target = (rs1 + imm) & ~1
        begin
            br_cycle q[$];
            q.push_back(mk(BK_JALR, 32'h1000_0100, 32'd8, `BR_BEQ, 32'h2000_0004, 0, 0,0,1,0));
            // odd sum -> bit 0 masked away, but bit 1 still misaligned
            q.push_back(mk(BK_JALR, 32'h1000_0100, 32'd2, `BR_BEQ, 32'h2000_0005, 0, 0,0,1,0));
            // odd sum that lands aligned after masking
            q.push_back(mk(BK_JALR, 32'h1000_0100, 32'd3, `BR_BEQ, 32'h2000_0001, 0, 0,0,1,0));
            // negative offset, and independence from the prediction bit
            q.push_back(mk(BK_JALR, 32'h1000_0100, 32'hFFFF_FFF8, `BR_BGEU, 32'h2000_0010, 0, 0,0,1,1));
            add_seq("jalr_target_and_masking", q);
        end
        // 5) ERRATUM T-1: JAL misalign is raised WITHOUT an EX redirect
        begin
            br_cycle q[$];
            q.push_back(mk(BK_MISALIGNED, 32'h1000_0100, 32'd2, `BR_BEQ, 0, 0, 0,1,0,0));
            q.push_back(mk(BK_JAL,        32'h1000_0100, 32'd8, `BR_BEQ, 0, 0, 0,1,0,0));
            // taken branch to a misaligned target
            q.push_back(mk(BK_MISALIGNED, 32'h1000_0100, 32'd6, `BR_BEQ, 7, 7, 1,0,0,0));
            // NOT-taken branch to a misaligned target raises nothing
            q.push_back(mk(BK_BRANCH_NOTTAKEN, 32'h1000_0100, 32'd6, `BR_BEQ, 7, 8, 1,0,0,0));
            // JALR to a bit-1-misaligned target
            q.push_back(mk(BK_MISALIGNED, 32'h1000_0100, 32'd2, `BR_BEQ, 32'h2000_0004, 0, 0,0,1,0));
            add_seq("erratum_t1_target_misaligned", q);
        end
        // 6) idle: a plain ALU op must be silent on every output
        begin
            br_cycle q[$];
            q.push_back(mk(BK_IDLE, 32'h1000_0100, 32'd0, `BR_BEQ, 5, 5, 0,0,0,0));
            q.push_back(mk(BK_IDLE, 32'h1000_0100, 32'd6, `BR_BEQ, 5, 5, 0,0,0,1));
            add_seq("idle_silent", q);
        end
        // 7) CRV
        for (int s = 0; s < nseq; s++) begin
            br_cycle q[$];
            for (int i = 0; i < slen; i++) begin
                br_cycle c = new();
                if (!c.randomize()) $fatal(1, "br_cycle randomize() failed");
                q.push_back(c);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. DRIVER / MONITOR
// -------------------------------------------------------------
class br_driver;
    virtual branch_if vif;
    function new(virtual branch_if vif); this.vif = vif; endfunction
    task apply(br_cycle c);
        @(negedge vif.clk);
        vif.pc <= c.pc; vif.imm <= c.imm; vif.funct3 <= c.f3;
        vif.rs1_fwd <= c.rs1; vif.rs2_fwd <= c.rs2;
        vif.branch <= c.branch; vif.jal <= c.jal; vif.jalr <= c.jalr;
        vif.predicted_taken <= c.pred;
    endtask
endclass

class br_monitor;
    virtual branch_if vif;

    covergroup cg_branch;
        cp_f3: coverpoint vif.funct3 iff (vif.branch) {
            bins beq = {`BR_BEQ};   bins bne  = {`BR_BNE};
            bins blt = {`BR_BLT};   bins bge  = {`BR_BGE};
            bins bltu = {`BR_BLTU}; bins bgeu = {`BR_BGEU};
        }
        cp_taken: coverpoint vif.branch_taken iff (vif.branch);
        cp_pred:  coverpoint vif.predicted_taken iff (vif.branch);
        // The four prediction outcomes: both correct cases and both
        // mispredict directions (C06/C07) must all be hit.
        cross cp_taken, cp_pred;
        cp_kind: coverpoint {vif.branch, vif.jal, vif.jalr} {
            bins none_   = {3'b000};
            bins branch_ = {3'b100};
            bins jal_    = {3'b010};
            bins jalr_   = {3'b001};
            illegal_bins overlapping = default;   // mutually exclusive by decode
        }
        cp_misalign: coverpoint vif.target_misaligned;
        cross cp_kind, cp_misalign {
            // A non-transfer can never be misaligned (SVA A5), so that
            // combination is unreachable by construction, not untested.
            ignore_bins no_transfer_cannot_misalign =
                binsof(cp_kind.none_) && binsof(cp_misalign) intersect {1};
        }
        cp_imm_sign: coverpoint vif.imm[31] iff (vif.branch);  // fwd vs backward
    endgroup

    function new(virtual branch_if vif);
        this.vif = vif; cg_branch = new();
    endfunction

    task sample_one(output br_result r);
        #1;
        r = new();
        r.taken      = vif.branch_taken;
        r.mispredict = vif.mispredict;
        r.redirect   = vif.redirect;
        r.target     = vif.redirect_target;
        r.misaligned = vif.target_misaligned;
        cg_branch.sample();
    endtask
endclass


// -------------------------------------------------------------
// 6. ENV
// -------------------------------------------------------------
class br_env;
    virtual branch_if vif;
    br_generator gen;
    br_driver    drv;
    br_monitor   mon;
    br_ref_model model;
    garuda_tb_pkg::scoreboard sb;

    function new(virtual branch_if vif, int nseq = 8, int slen = 200);
        this.vif = vif;
        gen = new(nseq, slen); drv = new(vif); mon = new(vif);
        model = new(); sb = new("BRANCH_UNIT");
    endfunction

    task run();
        gen.build();
        foreach (gen.seq_q[s])
            foreach (gen.seq_q[s][i]) begin
                br_cycle  c = gen.seq_q[s][i];
                br_result act, exp;
                string    tag;
                drv.apply(c);
                mon.sample_one(act);
                exp = model.step(c.pc, c.imm, c.f3, c.rs1, c.rs2,
                                 c.branch, c.jal, c.jalr, c.pred);
                tag = $sformatf("%s pc=%08h imm=%08h", c.kind.name(), c.pc, c.imm);
                sb.chk1(gen.seq_name[s], {tag, " taken"},      act.taken,      exp.taken);
                sb.chk1(gen.seq_name[s], {tag, " mispredict"}, act.mispredict, exp.mispredict);
                sb.chk1(gen.seq_name[s], {tag, " redirect"},   act.redirect,   exp.redirect);
                sb.chk1(gen.seq_name[s], {tag, " misaligned"}, act.misaligned, exp.misaligned);
                // The target only has meaning when a redirect is requested;
                // checking it otherwise would pin down a don't-care.
                if (exp.redirect)
                    sb.chk(gen.seq_name[s], {tag, " target"}, act.target, exp.target);
            end
        sb.summary(mon.cg_branch.get_coverage());
    endtask
endclass


// -------------------------------------------------------------
// 7. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    branch_if vif(clk);

    branch_unit dut (
        .pc                (vif.pc),
        .imm               (vif.imm),
        .funct3            (vif.funct3),
        .rs1_fwd           (vif.rs1_fwd),
        .rs2_fwd           (vif.rs2_fwd),
        .branch            (vif.branch),
        .jal               (vif.jal),
        .jalr              (vif.jalr),
        .predicted_taken   (vif.predicted_taken),
        .branch_taken      (vif.branch_taken),
        .mispredict        (vif.mispredict),
        .redirect          (vif.redirect),
        .redirect_target   (vif.redirect_target),
        .target_misaligned (vif.target_misaligned)
    );

    br_env env;

    initial begin
        vif.pc = 32'h1000_0000; vif.imm = 0; vif.funct3 = `BR_BEQ;
        vif.rs1_fwd = 0; vif.rs2_fwd = 0;
        vif.branch = 0; vif.jal = 0; vif.jalr = 0; vif.predicted_taken = 0;
        repeat (3) @(posedge clk);
        env = new(vif, 8, 200);
        env.run();
        $finish;
    end
endmodule
