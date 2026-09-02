// =============================================================================
// tb_clic_ctrl.sv -- SystemVerilog unit TB for rtl/core/clic_ctrl.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 14.3 (take condition, vectoring, ack
//       handshake) and Sec. 14.5 (MIE-independent WFI wake).
// Plan: C23 (interrupt take, ack handshake, SHV and non-SHV vectoring),
//       C24 (preemptive nesting; strict > at threshold and active level),
//       and the wake half of C26.
//
// THE check in this file is the strict-greater-than pair. Sec. 14.3 says both
// level comparisons are strictly >: a source AT the threshold, or AT the
// active handling level, does NOT preempt. A >= implementation passes every
// "clearly higher priority" test and fails only lvl == mintthresh and
// lvl == mintstatus.mil. The constraint block below forces those two equality
// cases to occur often instead of leaving them to chance, and SVA A1/A2 state
// the rule independently of the reference model.
//
// This file also closes a gap in the repo: tb/core/filelist_clic_ctrl.f
// already listed a tb_clic_ctrl that did not exist ("add later; clic has no
// tb yet -- lint only for now").
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

// -------------------------------------------------------------
// 1. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface clic_if (input bit clk);
    logic        irq, shv, mie, take;
    logic [11:0] irq_id;
    logic [7:0]  irq_lvl, mintthresh, mil;
    logic [31:0] mtvec, mtvt;
    logic        ack, take_cond, wake_cond;
    logic [11:0] id_ack, irq_id_o;
    logic [7:0]  irq_lvl_o;
    logic [31:0] vector_target;

    // A1: STRICT > against the threshold (Sec. 14.3). A source at exactly
    //     the threshold must not be taken. This is test C24.
    property p_threshold_is_strict;
        @(posedge clk) (irq_lvl <= mintthresh) |-> (!take_cond);
    endproperty
    a_thresh_strict: assert property (p_threshold_is_strict)
        else $error("[SVA-FAIL] took an interrupt at or below mintthresh (must be strictly >)");

    // A2: STRICT > against the active handling level -- a source at the
    //     active level does not preempt the running handler.
    property p_active_level_is_strict;
        @(posedge clk) (irq_lvl <= mil) |-> (!take_cond);
    endproperty
    a_active_strict: assert property (p_active_level_is_strict)
        else $error("[SVA-FAIL] preempted at or below mintstatus.mil (must be strictly >)");

    // A3: MIE gates TAKING (Sec. 14.3) but not waking (Sec. 14.5).
    property p_mie_gates_take;
        @(posedge clk) (!mie) |-> (!take_cond);
    endproperty
    a_mie_take: assert property (p_mie_gates_take)
        else $error("[SVA-FAIL] take_cond asserted with mstatus.MIE clear");

    // A4: the wake condition is bare irq -- MIE-independent, level-
    //     independent. This is the "WFI wakes even if MIE=0" case (C26).
    property p_wake_is_bare_irq;
        @(posedge clk) wake_cond == irq;
    endproperty
    a_wake_bare: assert property (p_wake_is_bare_irq)
        else $error("[SVA-FAIL] wake_cond is not simply clic_irq_i");

    // A5: taking implies waking -- a source that can be taken must also be
    //     able to wake a WFI, or a WFI could sleep through a takeable IRQ.
    property p_take_implies_wake;
        @(posedge clk) take_cond |-> wake_cond;
    endproperty
    a_take_implies_wake: assert property (p_take_implies_wake)
        else $error("[SVA-FAIL] take_cond without wake_cond");

    // A6: both vector bases are 64-byte aligned in CLIC mode, so the low six
    //     bits of mtvec (which carry mtvec.mode) never reach the target.
    property p_nonshv_target_is_mtvec_base;
        @(posedge clk) (!shv) |-> (vector_target == {mtvec[31:6], 6'b0});
    endproperty
    a_nonshv: assert property (p_nonshv_target_is_mtvec_base)
        else $error("[SVA-FAIL] non-SHV target is not the 64B-aligned mtvec base");

    // A7: an SHV entry is 4 bytes wide, so the target is always word-aligned
    //     and lands inside the table.
    property p_shv_entry_is_word_aligned;
        @(posedge clk) shv |-> (vector_target[1:0] == 2'b00);
    endproperty
    a_shv_aligned: assert property (p_shv_entry_is_word_aligned)
        else $error("[SVA-FAIL] SHV vector target is not word-aligned");

    // A8: the ack is a pure function of take_i -- shaping it into a one-cycle
    //     pulse is trap_ctrl's job, not this block's.
    property p_ack_follows_take;
        @(posedge clk) (ack == take) && (id_ack == irq_id);
    endproperty
    a_ack: assert property (p_ack_follows_take)
        else $error("[SVA-FAIL] ack/id_ack did not track take_i/clic_irq_id_i");
endinterface


// -------------------------------------------------------------
// 2. STIMULUS ITEM
// -------------------------------------------------------------
typedef enum {
    CK_TAKEABLE, CK_AT_THRESHOLD, CK_AT_ACTIVE_LEVEL, CK_MIE_CLEAR,
    CK_NO_IRQ, CK_PREEMPT, CK_SHV, CK_RANDOM
} clic_kind_e;

class clic_cycle;
    rand clic_kind_e kind;
    rand bit         irq, shv, mie, take;
    rand bit [11:0]  id;
    rand bit [7:0]   lvl, thresh, mil;
    rand bit [31:0]  mtvec, mtvt;

    constraint c_kind_dist {
        kind dist { CK_TAKEABLE :/ 15, CK_AT_THRESHOLD :/ 15,
                    CK_AT_ACTIVE_LEVEL :/ 15, CK_MIE_CLEAR :/ 10,
                    CK_NO_IRQ :/ 5, CK_PREEMPT :/ 15, CK_SHV :/ 10,
                    CK_RANDOM :/ 15 };
    }

    constraint c_shape {
        (kind == CK_TAKEABLE)   -> (irq && mie && lvl > thresh && lvl > mil);
        // The two equality cases that separate > from >=. Forced, not hoped for.
        (kind == CK_AT_THRESHOLD)    -> (irq && mie && lvl == thresh && thresh > mil);
        (kind == CK_AT_ACTIVE_LEVEL) -> (irq && mie && lvl == mil && lvl > thresh);
        (kind == CK_MIE_CLEAR)  -> (irq && !mie);
        (kind == CK_NO_IRQ)     -> (!irq);
        // Nesting: a higher-level source arriving while a handler runs.
        (kind == CK_PREEMPT)    -> (irq && mie && mil > 0 && lvl == mil + 1);
        (kind == CK_SHV)        -> (irq && shv);
    }

    // Exercise the level field at both ends of its 8-bit range, including
    // the 0 and 255 boundaries where a > / >= confusion also shows up.
    constraint c_levels {
        lvl    dist { 0 :/ 10, [1:7] :/ 40, [8:250] :/ 30, [251:255] :/ 20 };
        thresh dist { 0 :/ 20, [1:7] :/ 40, [8:254] :/ 20, 255 :/ 20 };
        mil    dist { 0 :/ 30, [1:7] :/ 40, [8:255] :/ 30 };
    }

    // Bases with the low six bits DIRTY on most cycles, so the 64-byte
    // alignment masking is actually tested rather than assumed.
    constraint c_bases {
        mtvec[5:0] dist { 6'h03 :/ 40, 6'h3F :/ 20, 6'h00 :/ 20, [1:62] :/ 20 };
    }
endclass


// -------------------------------------------------------------
// 3. REFERENCE MODEL -- from Sec. 14.3 / 14.5
// -------------------------------------------------------------
class clic_result;
    bit        take_cond, wake_cond, ack;
    bit [31:0] target;
    bit [11:0] id_ack;
endclass

class clic_ref_model;
    function automatic clic_result step(bit irq, bit mie, bit shv, bit take,
                                         bit [11:0] id, bit [7:0] lvl,
                                         bit [7:0] thresh, bit [7:0] mil,
                                         bit [31:0] mtvec, bit [31:0] mtvt);
        clic_result r = new();
        // Both comparisons are STRICTLY greater-than (Sec. 14.3).
        r.take_cond = irq & mie & (lvl > thresh) & (lvl > mil);
        r.wake_cond = irq;                                  // Sec. 14.5
        r.target    = shv ? (({mtvt[31:6], 6'b0}) + ({20'd0, id} << 2))
                          : ({mtvec[31:6], 6'b0});
        r.ack       = take;
        r.id_ack    = id;
        return r;
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR
// -------------------------------------------------------------
class clic_generator;
    clic_cycle seq_q[$][$];
    string     seq_name[$];
    int        nseq, slen;

    function new(int nseq = 8, int slen = 250);
        this.nseq = nseq; this.slen = slen;
    endfunction

    function clic_cycle mk(clic_kind_e k, bit irq, bit mie, bit shv, bit take,
                            bit [11:0] id, bit [7:0] lvl, bit [7:0] th,
                            bit [7:0] mil, bit [31:0] mtvec, bit [31:0] mtvt);
        clic_cycle c = new();
        c.kind = k; c.irq = irq; c.mie = mie; c.shv = shv; c.take = take;
        c.id = id; c.lvl = lvl; c.thresh = th; c.mil = mil;
        c.mtvec = mtvec; c.mtvt = mtvt;
        return c;
    endfunction

    function void add_seq(string name, clic_cycle q[$]);
        seq_name.push_back(name); seq_q.push_back(q);
    endfunction

    function void build();
        // 1) each term of the take condition, knocked down one at a time
        //    with the other three satisfied
        begin
            clic_cycle q[$];
            q.push_back(mk(CK_TAKEABLE,  1,1,0,0, 12'h010, 8'd5, 8'd2, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_NO_IRQ,    0,1,0,0, 12'h010, 8'd5, 8'd2, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_MIE_CLEAR, 1,0,0,0, 12'h010, 8'd5, 8'd2, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_RANDOM,    1,1,0,0, 12'h010, 8'd1, 8'd2, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_RANDOM,    1,1,0,0, 12'h010, 8'd3, 8'd0, 8'd7, 32'h8000_0003, 32'h9000_0000));
            add_seq("take_condition_terms", q);
        end
        // 2) STRICT > at BOTH comparisons (C24) -- the discriminating pairs
        begin
            clic_cycle q[$];
            // at the threshold: must NOT take
            q.push_back(mk(CK_AT_THRESHOLD, 1,1,0,0, 12'h001, 8'd4, 8'd4, 8'd0, 32'h8000_0003, 32'h9000_0000));
            // one above: takes
            q.push_back(mk(CK_TAKEABLE,     1,1,0,0, 12'h001, 8'd5, 8'd4, 8'd0, 32'h8000_0003, 32'h9000_0000));
            // at the active level: must NOT preempt
            q.push_back(mk(CK_AT_ACTIVE_LEVEL, 1,1,0,0, 12'h001, 8'd6, 8'd0, 8'd6, 32'h8000_0003, 32'h9000_0000));
            // one above: preempts (nesting)
            q.push_back(mk(CK_PREEMPT,      1,1,0,0, 12'h001, 8'd7, 8'd0, 8'd6, 32'h8000_0003, 32'h9000_0000));
            // 8-bit field boundaries
            q.push_back(mk(CK_AT_THRESHOLD, 1,1,0,0, 12'h001, 8'd0,   8'd0,   8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_TAKEABLE,     1,1,0,0, 12'h001, 8'd255, 8'd254, 8'd254, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_AT_THRESHOLD, 1,1,0,0, 12'h001, 8'd255, 8'd255, 8'd0, 32'h8000_0003, 32'h9000_0000));
            add_seq("strict_greater_than_c24", q);
        end
        // 3) wake is MIE- and level-independent (Sec. 14.5, C26)
        begin
            clic_cycle q[$];
            q.push_back(mk(CK_MIE_CLEAR, 1,0,0,0, 12'h001, 8'd0, 8'd255, 8'd255, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_NO_IRQ,    0,1,0,0, 12'h001, 8'd9, 8'd0,   8'd0,   32'h8000_0003, 32'h9000_0000));
            add_seq("wake_is_mie_independent", q);
        end
        // 4) non-SHV vectoring: mtvec base, low 6 bits masked
        begin
            clic_cycle q[$];
            q.push_back(mk(CK_TAKEABLE, 1,1,0,0, 12'h010, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_TAKEABLE, 1,1,0,0, 12'h010, 8'd5, 8'd0, 8'd0, 32'h8000_103F, 32'h9000_0000));
            add_seq("nonshv_vectoring", q);
        end
        // 5) SHV vectoring: mtvt_base + id*4, including the top of a
        //    4096-entry table
        begin
            clic_cycle q[$];
            q.push_back(mk(CK_SHV, 1,1,1,0, 12'h000, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_SHV, 1,1,1,0, 12'h001, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_SHV, 1,1,1,0, 12'h010, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_SHV, 1,1,1,0, 12'h7FF, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_SHV, 1,1,1,0, 12'hFFF, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_SHV, 1,1,1,0, 12'h002, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_003F));
            // the target follows SHV even when the interrupt is not takeable
            q.push_back(mk(CK_SHV, 1,0,1,0, 12'h004, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            add_seq("shv_vectoring", q);
        end
        // 6) SHV id sweep: every entry lands on its own 4-byte slot
        begin
            clic_cycle q[$];
            for (int i = 0; i < 64; i++)
                q.push_back(mk(CK_SHV, 1,1,1,0, i[11:0], 8'd5, 8'd0, 8'd0,
                               32'h8000_0003, 32'hA000_0000));
            add_seq("shv_id_sweep", q);
        end
        // 7) ack handshake
        begin
            clic_cycle q[$];
            q.push_back(mk(CK_TAKEABLE, 1,1,0,0, 12'h123, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            q.push_back(mk(CK_TAKEABLE, 1,1,0,1, 12'h123, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            // ack tracks take_i even when the take condition is false
            q.push_back(mk(CK_MIE_CLEAR, 1,0,0,1, 12'h0AB, 8'd5, 8'd0, 8'd0, 32'h8000_0003, 32'h9000_0000));
            add_seq("ack_handshake", q);
        end
        // 8) CRV
        for (int s = 0; s < nseq; s++) begin
            clic_cycle q[$];
            for (int i = 0; i < slen; i++) begin
                clic_cycle c = new();
                if (!c.randomize()) $fatal(1, "clic_cycle randomize() failed");
                q.push_back(c);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. DRIVER / MONITOR
// -------------------------------------------------------------
class clic_driver;
    virtual clic_if vif;
    function new(virtual clic_if vif); this.vif = vif; endfunction
    task apply(clic_cycle c);
        @(negedge vif.clk);
        vif.irq <= c.irq; vif.mie <= c.mie; vif.shv <= c.shv; vif.take <= c.take;
        vif.irq_id <= c.id; vif.irq_lvl <= c.lvl;
        vif.mintthresh <= c.thresh; vif.mil <= c.mil;
        vif.mtvec <= c.mtvec; vif.mtvt <= c.mtvt;
    endtask
endclass

class clic_monitor;
    virtual clic_if vif;

    covergroup cg_clic;
        cp_irq: coverpoint vif.irq;
        cp_mie: coverpoint vif.mie;
        cp_shv: coverpoint vif.shv;
        cp_take_cond: coverpoint vif.take_cond;
        // The relation between the source level and the threshold, binned so
        // the EQUALITY case is its own bin -- that is the C24 coverage goal,
        // and a report that shows it hit is the evidence strict > was tested.
        cp_lvl_vs_thresh: coverpoint (vif.irq_lvl > vif.mintthresh   ? 2'd2 :
                                      vif.irq_lvl == vif.mintthresh  ? 2'd1 : 2'd0) {
            bins below = {0}; bins equal = {1}; bins above = {2};
        }
        cp_lvl_vs_active: coverpoint (vif.irq_lvl > vif.mil   ? 2'd2 :
                                      vif.irq_lvl == vif.mil  ? 2'd1 : 2'd0) {
            bins below = {0}; bins equal = {1}; bins above = {2};
        }
        // Both equality cases must be seen with MIE set, or C24 is untested.
        cross cp_lvl_vs_thresh, cp_lvl_vs_active, cp_mie;
        cross cp_shv, cp_take_cond;
        cp_id: coverpoint vif.irq_id {
            bins zero = {12'h000};
            bins low  = {[12'h001:12'h0FF]};
            bins high = {[12'h100:12'hFFE]};
            bins max  = {12'hFFF};              // top of a 4096-entry mtvt
        }
    endgroup

    function new(virtual clic_if vif);
        this.vif = vif; cg_clic = new();
    endfunction

    task sample_one(output clic_result r);
        #1;
        r = new();
        r.take_cond = vif.take_cond; r.wake_cond = vif.wake_cond;
        r.ack = vif.ack; r.target = vif.vector_target; r.id_ack = vif.id_ack;
        cg_clic.sample();
    endtask
endclass


// -------------------------------------------------------------
// 6. ENV
// -------------------------------------------------------------
class clic_env;
    virtual clic_if vif;
    clic_generator gen;
    clic_driver    drv;
    clic_monitor   mon;
    clic_ref_model model;
    garuda_tb_pkg::scoreboard sb;

    function new(virtual clic_if vif, int nseq = 8, int slen = 250);
        this.vif = vif;
        gen = new(nseq, slen); drv = new(vif); mon = new(vif);
        model = new(); sb = new("CLIC_CTRL");
    endfunction

    task run();
        gen.build();
        foreach (gen.seq_q[s])
            foreach (gen.seq_q[s][i]) begin
                clic_cycle  c = gen.seq_q[s][i];
                clic_result act, exp;
                string      tag;
                drv.apply(c);
                mon.sample_one(act);
                exp = model.step(c.irq, c.mie, c.shv, c.take, c.id, c.lvl,
                                 c.thresh, c.mil, c.mtvec, c.mtvt);
                tag = $sformatf("%s lvl=%0d th=%0d mil=%0d",
                                c.kind.name(), c.lvl, c.thresh, c.mil);
                sb.chk1(gen.seq_name[s], {tag, " take_cond"}, act.take_cond, exp.take_cond);
                sb.chk1(gen.seq_name[s], {tag, " wake_cond"}, act.wake_cond, exp.wake_cond);
                sb.chk1(gen.seq_name[s], {tag, " ack"},       act.ack,       exp.ack);
                sb.chk (gen.seq_name[s], {tag, " id_ack"},    act.id_ack,    exp.id_ack);
                sb.chk (gen.seq_name[s], {tag, " vector"},    act.target,    exp.target);
            end
        sb.summary(mon.cg_clic.get_coverage());
    endtask
endclass


// -------------------------------------------------------------
// 7. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    clic_if vif(clk);

    clic_ctrl #(.ID_W(12)) dut (
        .clic_irq_i        (vif.irq),
        .clic_irq_id_i     (vif.irq_id),
        .clic_irq_lvl_i    (vif.irq_lvl),
        .clic_irq_shv_i    (vif.shv),
        .clic_irq_ack_o    (vif.ack),
        .clic_irq_id_ack_o (vif.id_ack),
        .mstatus_mie_i     (vif.mie),
        .mintthresh_i      (vif.mintthresh),
        .mintstatus_mil_i  (vif.mil),
        .mtvec_i           (vif.mtvec),
        .mtvt_i            (vif.mtvt),
        .take_cond_o       (vif.take_cond),
        .wake_cond_o       (vif.wake_cond),
        .irq_id_o          (vif.irq_id_o),
        .irq_lvl_o         (vif.irq_lvl_o),
        .vector_target_o   (vif.vector_target),
        .take_i            (vif.take)
    );

    clic_env env;

    initial begin
        vif.irq = 0; vif.shv = 0; vif.mie = 0; vif.take = 0;
        vif.irq_id = 0; vif.irq_lvl = 0; vif.mintthresh = 0; vif.mil = 0;
        vif.mtvec = 32'h8000_0003; vif.mtvt = 32'h9000_0000;
        repeat (3) @(posedge clk);
        env = new(vif, 8, 250);
        env.run();
        $finish;
    end
endmodule
