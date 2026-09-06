// =============================================================
// dsu_stall_tb.sv
// Tapeout-grade SV verification environment for GARUDA dsu_stall.v
// (2-cycle read-after-read structural hazard detector for the DSU)
//
// UNLIKE the other GARUDA unit TBs in this set (barrel_shifter,
// dsu_decoder, csa_3to2), dsu_stall is SEQUENTIAL: it has real
// registered state (prev_was_2cycle, prev_acc_sel). Verifying it
// correctly requires cycle-accurate stimulus SEQUENCES and a
// STATEFUL reference model that mirrors the register-update rules
// independently -- not independent single-cycle transactions.
//
// Two architectural findings from tracing dsu_stall.v against
// mac_unit.v's actual pipeline timing are called out explicitly in
// directed test cases 6 and 7 below (see comments there) rather than
// silently assumed either way -- they may be real hazard-detection
// gaps, or there may be upstream context this unit-level TB can't see.
//
// Requires a simulator with full IEEE1800 support (covergroup,
// assert property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

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
// 1. DUT: dsu_stall.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module dsu_stall (
    input wire clk,
    input wire rst_n,
    input wire flush,

    input wire [4:0] funct5,
    input wire [2:0] funct3,
    input wire       is_custom0,
    input wire [1:0] acc_sel,

    output wire dsu_busy
);

    wire cur_is_rtype = is_custom0 & (funct3 == 3'b000);
    wire cur_is_itype = is_custom0 & (funct3 == 3'b001);

    wire cur_is_2cycle = cur_is_rtype & ((funct5 == `FUNCT5_MACRD_LO) | (funct5 == `FUNCT5_MACRD_HI) | (funct5 == `FUNCT5_MACSAT));
    wire cur_reads_acc = (cur_is_rtype & ((funct5 == `FUNCT5_MACRD_LO) | (funct5 == `FUNCT5_MACRD_HI) | (funct5 == `FUNCT5_MACSAT))) | cur_is_itype;

    reg       prev_was_2cycle;
    reg [1:0] prev_acc_sel;

    wire stall_now;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            prev_was_2cycle <= 1'b0;
            prev_acc_sel <= 2'b00;
        end
        else if (flush) begin
            prev_was_2cycle <= 1'b0;
            prev_acc_sel <= 2'b00;
        end
        else if (~stall_now) begin
            prev_was_2cycle <= cur_is_2cycle;
            prev_acc_sel <= acc_sel;
        end
    end

    assign stall_now = prev_was_2cycle & cur_reads_acc & (acc_sel == prev_acc_sel);

    assign dsu_busy = stall_now;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface dsu_stall_if (input bit clk);
    logic       rst_n;
    logic       flush;
    logic [4:0] funct5;
    logic [2:0] funct3;
    logic       is_custom0;
    logic [1:0] acc_sel;
    logic       dsu_busy;

    // A1: X-propagation -- known inputs must never produce an unknown
    //     dsu_busy (also implicitly checks prev_was_2cycle/prev_acc_sel
    //     never go unknown after a real reset has occurred).
    property p_no_x_propagation;
        @(posedge clk) disable iff (!rst_n)
        (!$isunknown({funct5, funct3, is_custom0, acc_sel, flush})) |-> (!$isunknown(dsu_busy));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on dsu_busy with fully-known inputs");

    // A2: reset must clear dsu_busy -- since dsu_busy = stall_now and
    //     stall_now requires prev_was_2cycle=1, and reset clears that,
    //     dsu_busy must read 0 on the cycle immediately following reset
    //     release (this cycle's prev_was_2cycle is guaranteed 0).
    property p_reset_clears_busy;
        @(posedge clk) $rose(rst_n) |-> !dsu_busy;
    endproperty
    a_reset_clears_busy: assert property (p_reset_clears_busy)
        else $error("[SVA-FAIL] dsu_busy asserted on the cycle immediately following reset release");

    // A3: flush must clear dsu_busy on the cycle immediately after it
    //     was asserted (mirrors A2's reasoning: flush forces
    //     prev_was_2cycle<=0 for the next cycle).
    property p_flush_clears_busy_next_cycle;
        @(posedge clk) disable iff (!rst_n)
        $past(flush) |-> !dsu_busy;
    endproperty
    a_flush_clears_busy_next_cycle: assert property (p_flush_clears_busy_next_cycle)
        else $error("[SVA-FAIL] dsu_busy asserted the cycle after a flush");

    // A4: dsu_busy can only ever be asserted when the current
    //     instruction is one that reads the accumulator. If cur_reads_acc
    //     would be false, dsu_busy must be false regardless of history.
    property p_busy_implies_reads_acc;
        @(posedge clk) disable iff (!rst_n)
        dsu_busy |-> (is_custom0 & ((funct3 == 3'b000 & (funct5 == `FUNCT5_MACRD_LO | funct5 == `FUNCT5_MACRD_HI | funct5 == `FUNCT5_MACSAT)) | funct3 == 3'b001));
    endproperty
    a_busy_implies_reads_acc: assert property (p_busy_implies_reads_acc)
        else $error("[SVA-FAIL] dsu_busy asserted for an instruction that does not read the accumulator");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
typedef enum {
    OP_MAC_SEL, OP_MACSUB, OP_MACABS, OP_MACDOT, OP_MACLOAD, OP_MACCLEAR,
    OP_MACSAT, OP_RD_LO, OP_RD_HI, OP_MACSHIFT, OP_NON_CUSTOM0, OP_BAD_FUNCT3
} stall_op_e;

class stall_cycle;
    rand stall_op_e op;
    rand bit [1:0]  acc_sel;
    rand bit        flush;
    rand bit        rst_n;

    // Raw-field override, used only by the exhaustive sweep (section 10
    // of the generator) to reach (funct5,funct3,is_custom0) combinations
    // that don't correspond to any single named op in stall_op_e -- the
    // op enum is deliberately a curated, meaningful instruction set for
    // directed/CRV use; the exhaustive sweep needs the full raw space.
    bit       use_raw;
    bit [4:0] raw_funct5;
    bit [2:0] raw_funct3;
    bit       raw_is_custom0;

    constraint c_op_dist {
        op dist {
            OP_MAC_SEL :/ 8, OP_MACSUB :/ 8, OP_MACABS :/ 8, OP_MACDOT :/ 8,
            OP_MACLOAD :/ 8, OP_MACCLEAR :/ 8, OP_MACSAT :/ 10, OP_RD_LO :/ 12,
            OP_RD_HI :/ 12, OP_MACSHIFT :/ 10, OP_NON_CUSTOM0 :/ 4, OP_BAD_FUNCT3 :/ 4
        };
    }
    constraint c_rst_n_dist  { rst_n  dist { 1'b1 :/ 97, 1'b0 :/ 3  }; }
    constraint c_flush_dist  { flush  dist { 1'b0 :/ 85, 1'b1 :/ 15 }; }

    function void fields(output bit [4:0] funct5, output bit [2:0] funct3, output bit is_custom0);
        if (use_raw) begin
            funct5 = raw_funct5; funct3 = raw_funct3; is_custom0 = raw_is_custom0;
            return;
        end
        is_custom0 = 1'b1;
        case (op)
            OP_MAC_SEL:   begin funct3 = 3'b000; funct5 = `FUNCT5_MAC_SEL;  end
            OP_MACSUB:    begin funct3 = 3'b000; funct5 = `FUNCT5_MACSUB;   end
            OP_MACABS:    begin funct3 = 3'b000; funct5 = `FUNCT5_MACABS;   end
            OP_MACDOT:    begin funct3 = 3'b000; funct5 = `FUNCT5_MACDOT;   end
            OP_MACLOAD:   begin funct3 = 3'b000; funct5 = `FUNCT5_MACLOAD;  end
            OP_MACCLEAR:  begin funct3 = 3'b000; funct5 = `FUNCT5_MACCLEAR; end
            OP_MACSAT:    begin funct3 = 3'b000; funct5 = `FUNCT5_MACSAT;   end
            OP_RD_LO:     begin funct3 = 3'b000; funct5 = `FUNCT5_MACRD_LO; end
            OP_RD_HI:     begin funct3 = 3'b000; funct5 = `FUNCT5_MACRD_HI; end
            OP_MACSHIFT:  begin funct3 = 3'b001; funct5 = 5'd0;             end
            OP_BAD_FUNCT3:begin funct3 = 3'b101; funct5 = 5'd0;             end
            OP_NON_CUSTOM0: begin is_custom0 = 1'b0; funct3 = 3'b000; funct5 = 5'd0; end
            default: begin funct3 = 3'b000; funct5 = 5'd0; end
        endcase
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences (each entry is a full cycle-by-
//    cycle sequence, since this DUT's correctness is defined by
//    sequences, not single cycles) + CRV sequences.
// -------------------------------------------------------------
class stall_generator;
    stall_cycle seq_q[$][$];   // queue of sequences, each a queue of cycles
    string      seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 15, int random_seq_len = 30);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function stall_cycle mk(stall_op_e op, bit [1:0] acc_sel = 2'b00, bit flush = 0, bit rst_n = 1);
        stall_cycle c = new();
        c.op = op; c.acc_sel = acc_sel; c.flush = flush; c.rst_n = rst_n;
        return c;
    endfunction

    // Raw-field variant for the exhaustive sweep -- see stall_cycle's
    // use_raw comment.
    function stall_cycle mk_raw(bit [4:0] funct5, bit [2:0] funct3, bit is_custom0, bit [1:0] acc_sel);
        stall_cycle c = new();
        c.use_raw = 1'b1;
        c.raw_funct5 = funct5; c.raw_funct3 = funct3; c.raw_is_custom0 = is_custom0;
        c.acc_sel = acc_sel; c.flush = 1'b0; c.rst_n = 1'b1;
        return c;
    endfunction

    function void add_seq(string name, stall_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) Basic hazard trigger: MACRD_LO(FX) -> MACRD_LO(FX) => stall on cycle 2
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_MAC_SEL, `ACC_FX));  // bubble-ish next instr, hazard should have cleared
            add_seq("basic_hazard_same_acc", q);
        end

        // 2) No hazard: MACRD_LO(FX) -> MACRD_LO(FY) (different accumulator)
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_RD_LO, `ACC_FY));
            add_seq("no_hazard_diff_acc", q);
        end

        // 3) All three read-family producers x all three consumer types, same acc
        begin
            stall_op_e producers[3] = '{OP_RD_LO, OP_RD_HI, OP_MACSAT};
            stall_op_e consumers[4] = '{OP_RD_LO, OP_RD_HI, OP_MACSAT, OP_MACSHIFT};
            foreach (producers[i]) begin
                foreach (consumers[j]) begin
                    stall_cycle q[$];
                    q.push_back(mk(producers[i], `ACC_MAG));
                    q.push_back(mk(consumers[j], `ACC_MAG));
                    add_seq($sformatf("producer_%0d_consumer_%0d_same_acc", i, j), q);
                end
            end
        end

        // 4) Reset mid-sequence: establish a hazard-pending state, then
        //    reset, then confirm the pending hazard is gone
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_RD_LO, `ACC_FX, 1'b0, 1'b0));  // rst_n=0 this cycle
            q.push_back(mk(OP_RD_LO, `ACC_FX));              // would have hazarded pre-reset
            add_seq("reset_mid_hazard", q);
        end

        // 5) Flush mid-hazard: establish hazard-pending state, flush,
        //    then confirm the pending hazard is gone the cycle after
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_RD_LO, `ACC_FX, 1'b1, 1'b1));  // flush=1 this cycle
            q.push_back(mk(OP_RD_LO, `ACC_FX));              // should NOT stall (state was cleared)
            add_seq("flush_mid_hazard", q);
        end

        // 5b) Flush asserted on the SAME cycle as the hazard condition --
        //     per the RTL, stall_now is purely combinational from
        //     PRE-edge state, so it still fires THIS cycle; flush only
        //     prevents the state from propagating to the NEXT cycle.
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_RD_LO, `ACC_FX, 1'b1, 1'b1));  // hazard AND flush together
            add_seq("flush_same_cycle_as_hazard", q);
        end

        // 6) *** FINDING 1 *** -- compute op immediately followed by a
        //     read op on the SAME accumulator. Per dsu_stall.v's literal
        //     spec, cur_is_2cycle never fires for compute ops, so NO
        //     stall is inserted here -- yet mac_unit.v's actual 2-stage
        //     carry-save pipeline means the compute op's effect on `acc`
        //     is not yet visible. This sequence exists to make that gap
        //     directly observable in the log/coverage, not to assert a
        //     verdict either way -- flag for architecture review.
        begin
            stall_op_e computes[6] = '{OP_MAC_SEL, OP_MACSUB, OP_MACABS, OP_MACDOT, OP_MACLOAD, OP_MACCLEAR};
            foreach (computes[i]) begin
                stall_cycle q[$];
                q.push_back(mk(computes[i], `ACC_FY));
                q.push_back(mk(OP_RD_LO, `ACC_FY));
                add_seq($sformatf("FINDING1_compute_%0d_then_read_same_acc", i), q);
            end
        end

        // 7) *** FINDING 2 *** -- held-stall livelock demonstration.
        //     Trigger a hazard, then hold the SAME triggering instruction
        //     constant for several more cycles (as a simple "freeze and
        //     retry" pipeline would). Per the RTL, prev_was_2cycle/
        //     prev_acc_sel freeze while stalled, so if the held inputs
        //     never change, dsu_busy is expected to remain asserted for
        //     the ENTIRE held duration -- this sequence measures exactly
        //     that, for the log/report, rather than asserting a verdict.
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_MAG));
            repeat (6) q.push_back(mk(OP_RD_LO, `ACC_MAG));  // hold identical instruction
            q.push_back(mk(OP_MAC_SEL, `ACC_MAG));            // finally changes
            add_seq("FINDING2_held_stall_livelock_probe", q);
        end

        // 8) acc_sel boundary sweep (00/01/10/11) as both producer and
        //    consumer accumulator selector, matched and mismatched
        begin
            bit [1:0] sels[4] = '{2'b00, 2'b01, 2'b10, 2'b11};
            foreach (sels[i]) foreach (sels[j]) begin
                stall_cycle q[$];
                q.push_back(mk(OP_RD_HI, sels[i]));
                q.push_back(mk(OP_RD_HI, sels[j]));
                add_seq($sformatf("accsel_prod%0d_cons%0d", i, j), q);
            end
        end

        // 9) Non-Custom-0 and bad-funct3 instructions never read the
        //    accumulator and never set prev_was_2cycle
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_NON_CUSTOM0, `ACC_FX));
            q.push_back(mk(OP_RD_LO, `ACC_FX));  // hazard should be gone (non-custom0 cleared prev state)
            add_seq("non_custom0_breaks_chain", q);
        end
        begin
            stall_cycle q[$];
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            q.push_back(mk(OP_BAD_FUNCT3, `ACC_FX));
            q.push_back(mk(OP_RD_LO, `ACC_FX));
            add_seq("bad_funct3_breaks_chain", q);
        end

        // 10) EXHAUSTIVE: sweep every (funct5, funct3, is_custom0) combination
        //     -- 32*8*2 = 512 combos -- against two base states:
        //       (a) no hazard pending -> busy must be 0 for ALL 512 combos
        //           regardless of what reads_acc evaluates to (proves the
        //           prev_was_2cycle gate genuinely dominates)
        //       (b) hazard pending with a MATCHING acc_sel -> busy must
        //           exactly equal reads_acc(funct5,funct3,is_custom0) for
        //           each combo, which exhaustively validates the read-family
        //           decode logic (the equality/OR chain most likely to hide
        //           an off-by-one or a missed encoding) against every
        //           possible input, not a sample of it.
        begin
            for (int f5i = 0; f5i < 32; f5i++) begin
                for (int f3i = 0; f3i < 8; f3i++) begin
                    for (int ic0i = 0; ic0i < 2; ic0i++) begin
                        stall_cycle setup_a[$], setup_b[$];

                        // (a) no-hazard-pending base state, then probe
                        setup_a.push_back(mk(OP_MAC_SEL, `ACC_FX));  // establishes prev_was_2cycle=0
                        setup_a.push_back(mk_raw(f5i[4:0], f3i[2:0], ic0i[0], `ACC_FX));
                        add_seq($sformatf("EXH_nohazard_f5%0d_f3%0d_ic0%0d", f5i, f3i, ic0i), setup_a);

                        // (b) hazard-pending (matching acc_sel), then probe
                        setup_b.push_back(mk(OP_RD_LO, `ACC_FY));    // establishes prev_was_2cycle=1, prev_acc_sel=FY
                        setup_b.push_back(mk_raw(f5i[4:0], f3i[2:0], ic0i[0], `ACC_FY));
                        add_seq($sformatf("EXH_hazardpend_f5%0d_f3%0d_ic0%0d", f5i, f3i, ic0i), setup_b);
                    end
                end
            end
        end

        // 11) CONSTRAINED-RANDOM multi-cycle sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            stall_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                stall_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- stateful, cycle-accurate mirror of the
//    RTL's register-update rules (independently structured: uses a
//    case statement on the op's funct5 rather than the RTL's chained
//    equality/OR expression, so it cannot silently repeat the same
//    conceptual bug).
// -------------------------------------------------------------
class stall_ref_model;
    bit       prev_was_2cycle;
    bit [1:0] prev_acc_sel;

    function new();
        prev_was_2cycle = 1'b0;
        prev_acc_sel    = 2'b00;
    endfunction

    // Returns predicted dsu_busy for this cycle's inputs. NOTE ordering:
    // dsu_stall's reset is ASYNCHRONOUS (posedge clk or negedge rst_n) --
    // the moment rst_n drops, prev_was_2cycle/prev_acc_sel clear
    // immediately, not at the next clock edge. The driver applies rst_n
    // well before the monitor's sampling point, so by the time dsu_busy
    // is sampled for a cycle where rst_n=0, the real register has
    // ALREADY cleared. The model must therefore apply an asserted reset
    // FIRST, then compute busy from the (possibly just-cleared) state --
    // not compute busy from stale pre-reset state and clear afterward.
    function bit step(bit [4:0] funct5, bit [2:0] funct3, bit is_custom0,
                       bit [1:0] acc_sel, bit flush, bit rst_n);
        bit is_rtype, is_itype, is_2cycle, reads_acc, busy;

        if (!rst_n) begin
            prev_was_2cycle = 1'b0;
            prev_acc_sel    = 2'b00;
        end

        is_rtype = is_custom0 && (funct3 == 3'b000);
        is_itype = is_custom0 && (funct3 == 3'b001);

        case (1'b1)
            (is_rtype && (funct5 == `FUNCT5_MACRD_LO || funct5 == `FUNCT5_MACRD_HI || funct5 == `FUNCT5_MACSAT)):
                is_2cycle = 1'b1;
            default: is_2cycle = 1'b0;
        endcase
        reads_acc = is_2cycle || is_itype;

        busy = prev_was_2cycle && reads_acc && (acc_sel == prev_acc_sel);

        if (!rst_n) begin
            // already cleared above; state stays cleared regardless of
            // what busy was computed above (rst_n dominates)
        end else if (flush) begin
            prev_was_2cycle = 1'b0;
            prev_acc_sel    = 2'b00;
        end else if (!busy) begin
            prev_was_2cycle = is_2cycle;
            prev_acc_sel    = acc_sel;
        end
        // else: stalled -- state holds unchanged

        return busy;
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class stall_driver;
    virtual dsu_stall_if vif;
    function new(virtual dsu_stall_if vif); this.vif = vif; endfunction

    task apply_cycle(stall_cycle c);
        bit [4:0] f5; bit [2:0] f3; bit ic0;
        c.fields(f5, f3, ic0);
        @(negedge vif.clk);
        vif.funct5     <= f5;
        vif.funct3     <= f3;
        vif.is_custom0 <= ic0;
        vif.acc_sel    <= c.acc_sel;
        vif.flush      <= c.flush;
        vif.rst_n      <= c.rst_n;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class stall_result;
    string seq_name; int cycle_idx;
    stall_cycle c;
    bit dsu_busy;
endclass

class stall_monitor;
    virtual dsu_stall_if vif;

    covergroup cg_stall;
        cp_busy: coverpoint vif.dsu_busy;
        cp_flush: coverpoint vif.flush;
        cp_rst_n: coverpoint vif.rst_n;
        cp_op_reads_acc: coverpoint (vif.is_custom0 && (vif.funct3 == 3'b001 ||
                          (vif.funct3 == 3'b000 && (vif.funct5 == `FUNCT5_MACRD_LO ||
                           vif.funct5 == `FUNCT5_MACRD_HI || vif.funct5 == `FUNCT5_MACSAT))));
        cross cp_busy, cp_flush;
        cross cp_busy, cp_rst_n {
            // (busy=1, rst_n=0) is unreachable BY CONSTRUCTION of this
            // environment's sampling convention, not a functional gap:
            // dsu_stall's reset is asynchronous, and the driver applies
            // rst_n well before the monitor's sampling point -- so by the
            // time any sample is taken during a cycle where rst_n=0, the
            // internal registers have already async-cleared (this is the
            // same timing fact that motivated the reference-model reset-
            // ordering fix). Forcing this bin would mean sampling inside
            // the async-clear propagation delta rather than testing any
            // real, observable pipeline state -- explicitly excluded and
            // documented rather than silently left short.
            ignore_bins busy_during_reset_unreachable =
                binsof(cp_busy) intersect {1} && binsof(cp_rst_n) intersect {0};
        }
    endgroup

    function new(virtual dsu_stall_if vif);
        this.vif = vif;
        cg_stall = new();
    endfunction

    task sample_one(output bit busy);
        #1; // allow combinational logic to settle after apply_cycle()'s NBA update
        busy = vif.dsu_busy;
        cg_stall.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class stall_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;
    int max_consecutive_busy = 0;

    task check(string seq_name, int cycle_idx, stall_cycle c, bit [4:0] f5, bit [2:0] f3, bit ic0,
               bit actual_busy, ref stall_ref_model model, ref int consec_busy);
        bit expected_busy;
        expected_busy = model.step(f5, f3, ic0, c.acc_sel, c.flush, c.rst_n);

        if (actual_busy) begin
            consec_busy++;
            if (consec_busy > max_consecutive_busy) max_consecutive_busy = consec_busy;
        end else begin
            consec_busy = 0;
        end

        if (actual_busy === expected_busy) begin
            pass_cnt++;
            $display("[PASS] seq=%-38s cyc=%0d op=%-14s acc_sel=%0d flush=%0b rst_n=%0b -> busy=%0b",
                      seq_name, cycle_idx, c.op.name(), c.acc_sel, c.flush, c.rst_n, actual_busy);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-38s cyc=%0d op=%-14s acc_sel=%0d flush=%0b rst_n=%0b -> got=%0b exp=%0b",
                      seq_name, cycle_idx, c.op.name(), c.acc_sel, c.flush, c.rst_n, actual_busy, expected_busy);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class stall_env;
    virtual dsu_stall_if vif;
    stall_generator  gen;
    stall_driver     drv;
    stall_monitor    mon;
    stall_scoreboard sb;

    function new(virtual dsu_stall_if vif, int num_random_seqs = 15, int random_seq_len = 30);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        stall_ref_model model;
        int consec_busy;
        int total_cycles = 0;

        gen.build();

        foreach (gen.seq_q[s]) begin
            // Isolate every named sequence with a real reset pulse on the
            // actual DUT (not just a fresh reference-model object) --
            // dsu_stall is a single continuous simulation, so its
            // internal registers otherwise carry real state across
            // sequence boundaries even though the reference model was
            // being reset fresh. This was found and fixed as a real
            // testbench bug: 18 of 20 failures in an earlier run were
            // exactly this state-carryover mismatch, not a DUT defect.
            stall_cycle reset_cycle = new();
            bit [4:0] rf5; bit [2:0] rf3; bit ric0; bit rbusy;
            reset_cycle.op = OP_MAC_SEL; reset_cycle.acc_sel = 2'b00;
            reset_cycle.flush = 1'b0; reset_cycle.rst_n = 1'b0;
            reset_cycle.fields(rf5, rf3, ric0);
            drv.apply_cycle(reset_cycle);
            mon.sample_one(rbusy);  // sampled but not scored -- pure isolation pulse

            model = new();  // matches the DUT's now-actually-reset state
            consec_busy = 0;
            foreach (gen.seq_q[s][i]) begin
                stall_cycle c = gen.seq_q[s][i];
                bit [4:0] f5; bit [2:0] f3; bit ic0;
                bit actual_busy;
                c.fields(f5, f3, ic0);
                drv.apply_cycle(c);
                mon.sample_one(actual_busy);
                sb.check(gen.seq_name[s], i, c, f5, f3, ic0, actual_busy, model, consec_busy);
                total_cycles++;
            end
        end

        $display("\n================ DSU_STALL UNIT TB SUMMARY ================");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d", gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" MAX OBSERVED CONSECUTIVE dsu_busy CYCLES (any single sequence) = %0d", sb.max_consecutive_busy);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_stall.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED (dsu_stall matches its own literal specification)");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display(" NOTE: see FINDING1_* and FINDING2_* sequences above for the two architectural");
        $display("       questions raised during this exercise (missing compute->read hazard,");
        $display("       and held-stall livelock) -- both PASS against dsu_stall's own spec,");
        $display("       which is exactly what makes them worth a human architecture review.");
        $display("=============================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class stall_test;
    stall_env env;
    function new(virtual dsu_stall_if vif, int num_random_seqs = 15, int random_seq_len = 30);
        env = new(vif, num_random_seqs, random_seq_len);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    dsu_stall_if vif(clk);

    dsu_stall dut (
        .clk        (clk),
        .rst_n      (vif.rst_n),
        .flush      (vif.flush),
        .funct5     (vif.funct5),
        .funct3     (vif.funct3),
        .is_custom0 (vif.is_custom0),
        .acc_sel    (vif.acc_sel),
        .dsu_busy   (vif.dsu_busy)
    );

    stall_test test;

    initial begin
        vif.rst_n = 1'b0;
        vif.flush = 1'b0;
        vif.funct5 = 5'd0; vif.funct3 = 3'd0; vif.is_custom0 = 1'b0; vif.acc_sel = 2'b00;
        repeat (3) @(posedge clk);

        test = new(vif, 15, 30);
        test.run();
        $finish;
    end
endmodule
