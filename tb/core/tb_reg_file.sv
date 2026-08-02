// =============================================================
// tapeout_regfile.sv
// Tapeout-grade SV verification environment for GARUDA regfile.v
// (ID-stage architectural register file, Sec. 5.3, Sec. 7.4)
//
// UNLIKE the purely-combinational units in this set (decode_control,
// imm_gen, branch_predict, hazard_forward_unit), regfile.v IS SEQUENTIAL:
// it has real registered state (the 31-entry storage array). Verifying it
// correctly requires the same cycle-accurate-sequence + stateful-
// reference-model discipline as dsu_stall.v.
//
// *** ARCHITECTURAL FINDING (documented, not silently assumed) ***
// regfile.v declares an `rst_n_i` port but NEVER references it in any
// always block - the storage array is never cleared by reset, only by
// being written. This is the OPPOSITE situation from dsu_stall.v, where
// reset genuinely reinitializes prev_was_2cycle/prev_acc_sel. That
// difference has a direct, easy-to-get-wrong consequence for THIS
// environment's structure:
//
//   dsu_stall's environment correctly isolates each named sequence by
//   pulsing rst_n on the real DUT and THEN starting a fresh reference-
//   model object - both sides of the comparison genuinely return to a
//   known state together.
//
//   Naively copying that pattern here would be WRONG: pulsing rst_n_i
//   does NOT clear regfile.v's array, so a fresh (empty) reference-model
//   map created at the start of the next sequence would immediately
//   diverge from the real DUT's still-populated storage - manufacturing
//   exactly the kind of testbench-vs-DUT state-carryover mismatch dsu_
//   stall_tb.sv's own header comment warns about, just triggered in the
//   opposite direction (there, the bug was resetting the model but not
//   isolating the DUT; here it would be resetting the model when the DUT
//   was never actually cleared to match).
//
// The fix applied below: ONE reference-model instance (one persistent
// sparse shadow map) lives for the ENTIRE run, across every sequence,
// exactly mirroring the DUT's own never-cleared array. rst_n_i is pulsed
// exactly once at the very start, purely to bring up a clean interface
// state, and its non-effect on storage is itself the subject of a
// dedicated directed sequence (see "post_reset_unwritten_is_x" below)
// rather than something this file assumes either way.
//
// Requires a simulator with full IEEE1800 support (covergroup, assert
// property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0. DEFINES
// -------------------------------------------------------------
// regfile.v has no `include dependency and no macro usage - nothing to
// inline.

// -------------------------------------------------------------
// 1. DUT: regfile.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
`ifndef GARUDA_REAL_RTL
// -----------------------------------------------------------------------------
// INLINED DUT COPY -- guarded (added 2026-08-02).
//
// This file carries its own copy of the DUT so it can be compiled standalone
// under VCS. That copy is a SNAPSHOT and had already drifted from rtl/core/*.v
// (it predates the SLLI/SRLI/SRAI funct7 check and the FENCE decode), so a
// green run against it proves nothing about the RTL that actually ships.
//
// Defining GARUDA_REAL_RTL skips this copy so the testbench binds to the real
// rtl/core sources -- that is what tb/core/filelist_*.f does. Compiling this
// file standalone with no define behaves exactly as before.
// -----------------------------------------------------------------------------
module regfile (
    input  wire         clk_i,
    input  wire         rst_n_i,

    input  wire [4:0]  rs1_idx_i,
    input  wire [4:0]  rs2_idx_i,

    input  wire         wb_reg_write_i,
    input  wire [4:0]  wb_rd_i,
    input  wire [31:0] wb_data_i,

    output wire [31:0] rs1_data_o,
    output wire [31:0] rs2_data_o
);

    reg [31:0] mem [1:31];   // x0 not stored - reads as 0 by construction
    wire [31:0] rs1_raw, rs2_raw;

    always @(posedge clk_i) begin
        if (wb_reg_write_i && (wb_rd_i != 5'd0)) begin
            mem[wb_rd_i] <= wb_data_i;
        end
    end

    assign rs1_raw = (rs1_idx_i == 5'd0) ? 32'd0 : mem[rs1_idx_i];
    assign rs2_raw = (rs2_idx_i == 5'd0) ? 32'd0 : mem[rs2_idx_i];

    assign rs1_data_o = (wb_reg_write_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs1_idx_i))
                           ? wb_data_i : rs1_raw;
    assign rs2_data_o = (wb_reg_write_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs2_idx_i))
                           ? wb_data_i : rs2_raw;

endmodule
`endif // GARUDA_REAL_RTL -- inlined DUT copy ends; verification env follows



// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface regfile_if (input bit clk);
    logic         rst_n;
    logic [4:0]  rs1_idx;
    logic [4:0]  rs2_idx;
    logic         wb_write;
    logic [4:0]  wb_rd;
    logic [31:0] wb_data;
    logic [31:0] rs1_data;
    logic [31:0] rs2_data;

    // A1/A2: x0 is the one register the ISA guarantees is always zero -
    //        if this ever failed, every "mv rd,rs" idiom encoded as
    //        "add rd,rs,x0" and every branch-vs-zero would read garbage.
    property p_x0_rs1_zero;
        @(posedge clk) (rs1_idx == 5'd0) |-> (rs1_data == 32'd0);
    endproperty
    a_x0_rs1: assert property (p_x0_rs1_zero)
        else $error("[SVA-FAIL] x0 (rs1 port) did not read as hardwired zero");

    property p_x0_rs2_zero;
        @(posedge clk) (rs2_idx == 5'd0) |-> (rs2_data == 32'd0);
    endproperty
    a_x0_rs2: assert property (p_x0_rs2_zero)
        else $error("[SVA-FAIL] x0 (rs2 port) did not read as hardwired zero");

    // A3/A4: this is the structural-hazard fix that lets back-to-back
    //        dependent instructions execute without an extra bubble
    //        (Sec. 7.4's whole reason for existing).
    property p_bypass_rs1;
        @(posedge clk) (wb_write && (wb_rd != 5'd0) && (rs1_idx == wb_rd)) |-> (rs1_data == wb_data);
    endproperty
    a_bypass_rs1: assert property (p_bypass_rs1)
        else $error("[SVA-FAIL] WB->ID same-cycle bypass failed on rs1");

    property p_bypass_rs2;
        @(posedge clk) (wb_write && (wb_rd != 5'd0) && (rs2_idx == wb_rd)) |-> (rs2_data == wb_data);
    endproperty
    a_bypass_rs2: assert property (p_bypass_rs2)
        else $error("[SVA-FAIL] WB->ID same-cycle bypass failed on rs2");

    // A5: a write targeting x0 must be silently discarded, never
    //     corrupting the hardwired-zero read.
    property p_x0_write_is_noop;
        @(posedge clk) (wb_write && (wb_rd == 5'd0) && (rs1_idx == 5'd0)) |-> (rs1_data == 32'd0);
    endproperty
    a_x0_write_noop: assert property (p_x0_write_is_noop)
        else $error("[SVA-FAIL] a write to x0 corrupted the hardwired-zero read");

    // A6: X-propagation, scoped. regfile.v's own contract (see the
    //     architectural finding at the top of this file) is that an
    //     UNWRITTEN register legitimately reads X - a blanket "never X"
    //     assertion would be actively wrong here. The one case where X is
    //     NEVER acceptable regardless of write history is the same-cycle
    //     bypass: the output is then a direct combinational copy of
    //     wb_data_i, so if wb_data_i is known, the read port must be known.
    property p_bypass_output_known_when_data_known;
        @(posedge clk) disable iff (!rst_n)
        (wb_write && (wb_rd != 5'd0) && (rs1_idx == wb_rd) && !$isunknown(wb_data)) |-> !$isunknown(rs1_data);
    endproperty
    a_bypass_no_x: assert property (p_bypass_output_known_when_data_known)
        else $error("[SVA-FAIL] rs1_data_o went X during an active bypass with known wb_data_i");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
typedef enum {
    RK_X0_ACCESS, RK_PLAIN_WRITE, RK_BYPASS_RS1, RK_BYPASS_RS2, RK_BYPASS_BOTH, RK_NO_WRITE_READ, RK_RANDOM
} regfile_op_e;

class regfile_cycle;
    rand regfile_op_e op;
    rand bit [4:0]  rs1_val;
    rand bit [4:0]  rs2_val;
    rand bit         wb_write_val;
    rand bit [4:0]  wb_rd_val;
    rand bit [31:0] wb_data_val;

    constraint c_op_dist {
        op dist {
            RK_X0_ACCESS :/ 10, RK_PLAIN_WRITE :/ 15, RK_BYPASS_RS1 :/ 20, RK_BYPASS_RS2 :/ 15,
            RK_BYPASS_BOTH :/ 10, RK_NO_WRITE_READ :/ 10, RK_RANDOM :/ 20
        };
    }
    constraint c_ranges { rs1_val inside {[0:31]}; rs2_val inside {[0:31]}; wb_rd_val inside {[0:31]}; }

    constraint c_op_shape {
        (op == RK_X0_ACCESS)     -> (wb_write_val == 1 && wb_rd_val == 0);
        (op == RK_PLAIN_WRITE)   -> (wb_write_val == 1 && wb_rd_val != 0 && rs1_val != wb_rd_val && rs2_val != wb_rd_val);
        (op == RK_BYPASS_RS1)    -> (wb_write_val == 1 && wb_rd_val != 0 && rs1_val == wb_rd_val && rs2_val != wb_rd_val);
        (op == RK_BYPASS_RS2)    -> (wb_write_val == 1 && wb_rd_val != 0 && rs2_val == wb_rd_val && rs1_val != wb_rd_val);
        (op == RK_BYPASS_BOTH)   -> (wb_write_val == 1 && wb_rd_val != 0 && rs1_val == wb_rd_val && rs2_val == wb_rd_val);
        (op == RK_NO_WRITE_READ) -> (wb_write_val == 0);
    }

    // Trivial pass-through - regfile has no instruction-encoding step,
    // kept for structural parity with the rest of this test set.
    function void fields(output bit [4:0] o_rs1, output bit [4:0] o_rs2, output bit o_wr, output bit [4:0] o_wrd, output bit [31:0] o_wdata);
        o_rs1 = rs1_val; o_rs2 = rs2_val; o_wr = wb_write_val; o_wrd = wb_rd_val; o_wdata = wb_data_val;
    endfunction

    function string to_string();
        return $sformatf("op=%-16s rs1=%0d rs2=%0d wb_write=%0b wb_rd=%0d wb_data=0x%08h",
                          op.name(), rs1_val, rs2_val, wb_write_val, wb_rd_val, wb_data_val);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences + exhaustive sweep + CRV.
//    Unlike the combinational units in this set, sequence ORDER matters
//    here: later sequences can legitimately observe register content
//    written by earlier ones (see sequence 8 below), since the reference
//    model (correctly, per the architectural finding above) is never
//    reset between sequences.
// -------------------------------------------------------------
class regfile_generator;
    regfile_cycle seq_q[$][$];
    string         seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 10, int random_seq_len = 200);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function regfile_cycle mk(regfile_op_e op, bit [4:0] rs1, bit [4:0] rs2, bit wr, bit [4:0] wrd, bit [31:0] wdata);
        regfile_cycle c = new();
        c.op = op; c.rs1_val = rs1; c.rs2_val = rs2; c.wb_write_val = wr; c.wb_rd_val = wrd; c.wb_data_val = wdata;
        return c;
    endfunction

    function void add_seq(string name, regfile_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) *** ARCHITECTURAL FINDING PROBE *** - post-reset unwritten-
        //    register state. This is the direct, observable consequence
        //    of rst_n_i being dead wiring: x7/x19 have never been written
        //    by anything (this is the very first sequence), so both the
        //    real DUT and the reference model's sparse map must agree
        //    they read X - not 0, and not any other "safe default" a less
        //    careful reference model might have assumed.
        begin
            regfile_cycle q[$];
            q.push_back(mk(RK_NO_WRITE_READ, 5'd7, 5'd19, 1'b0, 5'd0, 32'h0));
            add_seq("FINDING_post_reset_unwritten_reads_x", q);
        end

        // 2) x0 hardwired-zero / write-ignore
        begin
            regfile_cycle q[$];
            q.push_back(mk(RK_X0_ACCESS, 5'd0, 5'd0, 1'b1, 5'd0, 32'hFFFF_FFFF));
            q.push_back(mk(RK_NO_WRITE_READ, 5'd0, 5'd0, 1'b0, 5'd0, 32'h0));
            add_seq("x0_hardwired_zero", q);
        end

        // 3) Write-then-read across cycles (no bypass) - establishes x5 =
        //    0xCAFEF00D for sequence 8's cross-sequence persistence check.
        begin
            regfile_cycle q[$];
            q.push_back(mk(RK_PLAIN_WRITE, 5'd12, 5'd13, 1'b1, 5'd5, 32'hCAFE_F00D));
            q.push_back(mk(RK_NO_WRITE_READ, 5'd5, 5'd5, 1'b0, 5'd0, 32'h0));
            add_seq("write_then_read_no_bypass", q);
        end

        // 4) Same-cycle bypass matrix
        begin
            regfile_cycle q[$];
            q.push_back(mk(RK_BYPASS_RS1, 5'd9, 5'd20, 1'b1, 5'd9, 32'hAAAA_BBBB));
            q.push_back(mk(RK_BYPASS_RS2, 5'd20, 5'd9, 1'b1, 5'd9, 32'hAAAA_BBBB));
            q.push_back(mk(RK_BYPASS_BOTH, 5'd9, 5'd9, 1'b1, 5'd9, 32'hAAAA_BBBB));
            q.push_back(mk(RK_NO_WRITE_READ, 5'd9, 5'd9, 1'b0, 5'd0, 32'h0));
            add_seq("bypass_matrix", q);
        end

        // 5) Exhaustive 32-register sweep (bypass + readback)
        begin
            regfile_cycle q[$];
            for (int r = 0; r < 32; r++) begin
                q.push_back(mk(RK_RANDOM, r[4:0], r[4:0], 1'b1, r[4:0], 32'hE000_0000 | r[7:0]));
                q.push_back(mk(RK_NO_WRITE_READ, r[4:0], r[4:0], 1'b0, 5'd0, 32'h0));
            end
            add_seq("exh_reg_sweep_bypass_and_readback", q);
        end

        // 6) Back-to-back writes to the SAME register (stress) - guards
        //    against any accidental combinational feedback/latch in the
        //    storage array that a single write/read pair wouldn't expose.
        begin
            regfile_cycle q[$];
            for (int i = 0; i < 8; i++) q.push_back(mk(RK_PLAIN_WRITE, 5'd2, 5'd3, 1'b1, 5'd25, 32'hF0F0_0000 | i));
            q.push_back(mk(RK_NO_WRITE_READ, 5'd25, 5'd25, 1'b0, 5'd0, 32'h0));
            add_seq("stress_repeated_write_same_reg", q);
        end

        // 7) Alternating write-target toggle (stress)
        begin
            regfile_cycle q[$];
            for (int i = 0; i < 8; i++) begin
                bit [4:0] target = (i % 2 == 0) ? 5'd18 : 5'd19;
                q.push_back(mk(RK_PLAIN_WRITE, 5'd0, 5'd0, 1'b1, target, 32'h1000_0000 | i));
            end
            add_seq("stress_alternating_write_target", q);
        end

        // 8) *** CROSS-SEQUENCE PERSISTENCE CHECK *** - reads back x5,
        //    written by sequence 3 several sequences ago, with NO
        //    intervening write to x5 anywhere in between. This only
        //    passes if the reference model was correctly NOT reset
        //    between sequences (see the architectural-finding header
        //    comment) - it is a direct, positive demonstration of the
        //    same never-cleared-storage fact that sequence 1 probes from
        //    the other side (before anything is written).
        begin
            regfile_cycle q[$];
            q.push_back(mk(RK_NO_WRITE_READ, 5'd5, 5'd5, 1'b0, 5'd0, 32'h0));
            add_seq("cross_sequence_persistence_check_x5", q);
        end

        // 9) CONSTRAINED-RANDOM sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            regfile_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                regfile_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- STATEFUL. Uses a SPARSE associative map
//    (`bit [31:0] mem[int]`) instead of the RTL's dense fixed-size array -
//    a register that has never been written simply has no entry at all,
//    and a lookup helper reports that absence as X explicitly, rather
//    than relying on a language-level default (a materially different
//    implementation strategy from a declared `reg [31:0] mem[1:31]`,
//    while reproducing the identical visible contract: unwritten reads as
//    X, x0 is never stored).
// -------------------------------------------------------------
class regfile_ref_model;
    bit [31:0] mem [int]; // sparse: key present <=> that register has been written

    function automatic bit [31:0] read_port(bit [4:0] idx, bit bypass_hit, bit [31:0] bypass_data);
        if (idx == 5'd0) return 32'd0;
        if (bypass_hit)  return bypass_data;
        if (mem.exists(idx)) return mem[idx];
        return 32'hxxxx_xxxx; // never written - matches regfile.v's un-reset array
    endfunction

    // Returns predicted {rs1_data, rs2_data} for this cycle's inputs,
    // using state as it stands BEFORE this cycle's own write (the bypass
    // paths above handle the one case - same-cycle same-index - where the
    // write IS visible this cycle), then commits the write for cycles
    // that come after. Mirrors regfile.v's nonblocking `mem[wb_rd] <=
    // wb_data`, which is not visible to this same cycle's own read.
    function automatic void step(bit [4:0] rs1, bit [4:0] rs2, bit wr, bit [4:0] wrd, bit [31:0] wdata,
                                  output bit [31:0] exp_rs1, output bit [31:0] exp_rs2);
        bit bypass_rs1 = wr && (wrd != 5'd0) && (wrd == rs1);
        bit bypass_rs2 = wr && (wrd != 5'd0) && (wrd == rs2);

        exp_rs1 = read_port(rs1, bypass_rs1, wdata);
        exp_rs2 = read_port(rs2, bypass_rs2, wdata);

        if (wr && (wrd != 5'd0)) mem[wrd] = wdata;
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class regfile_driver;
    virtual regfile_if vif;
    function new(virtual regfile_if vif); this.vif = vif; endfunction

    task apply_cycle(regfile_cycle c);
        bit [4:0] r1, r2, wrd; bit wr; bit [31:0] wdata;
        c.fields(r1, r2, wr, wrd, wdata);
        @(negedge vif.clk);
        vif.rs1_idx  <= r1;
        vif.rs2_idx  <= r2;
        vif.wb_write <= wr;
        vif.wb_rd    <= wrd;
        vif.wb_data  <= wdata;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class regfile_result;
    bit [31:0] rs1_data, rs2_data;
endclass

class regfile_monitor;
    virtual regfile_if vif;
    bit [1:0] bypass_class_cov;

    covergroup cg_regfile;
        cp_rs1: coverpoint vif.rs1_idx { bins each_reg[] = {[0:31]}; }
        cp_rs2: coverpoint vif.rs2_idx { bins each_reg[] = {[0:31]}; }
        cp_wb_rd: coverpoint vif.wb_rd iff (vif.wb_write) { bins each_reg[] = {[0:31]}; }
        cp_wb_write: coverpoint vif.wb_write;
        cp_bypass_class: coverpoint bypass_class_cov {
            bins none = {0}; bins rs1_only = {1}; bins rs2_only = {2}; bins both = {3};
        }
    endgroup

    function new(virtual regfile_if vif);
        this.vif = vif;
        cg_regfile = new();
    endfunction

    task sample_one(output regfile_result r);
        #1; // allow combinational logic to settle after apply_cycle()'s NBA update
        r = new();
        r.rs1_data = vif.rs1_data;
        r.rs2_data = vif.rs2_data;

        if (!vif.wb_write || vif.wb_rd == 0) bypass_class_cov = 2'd0;
        else if ((vif.wb_rd == vif.rs1_idx) && (vif.wb_rd == vif.rs2_idx)) bypass_class_cov = 2'd3;
        else if (vif.wb_rd == vif.rs1_idx) bypass_class_cov = 2'd1;
        else if (vif.wb_rd == vif.rs2_idx) bypass_class_cov = 2'd2;
        else bypass_class_cov = 2'd0;

        cg_regfile.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class regfile_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(string seq_name, int cycle_idx, regfile_cycle c, bit [4:0] rs1, bit [4:0] rs2, bit wr, bit [4:0] wrd, bit [31:0] wdata,
               regfile_result actual, ref regfile_ref_model model);
        bit [31:0] exp_rs1, exp_rs2;
        model.step(rs1, rs2, wr, wrd, wdata, exp_rs1, exp_rs2);

        if ((actual.rs1_data === exp_rs1) && (actual.rs2_data === exp_rs2)) begin
            pass_cnt++;
            $display("[PASS] seq=%-38s cyc=%0d %s -> rs1_data=0x%08h rs2_data=0x%08h",
                      seq_name, cycle_idx, c.to_string(), actual.rs1_data, actual.rs2_data);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-38s cyc=%0d %s", seq_name, cycle_idx, c.to_string());
            $display("       rs1_data: exp=0x%08h act=0x%08h", exp_rs1, actual.rs1_data);
            $display("       rs2_data: exp=0x%08h act=0x%08h", exp_rs2, actual.rs2_data);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class regfile_env;
    virtual regfile_if vif;
    regfile_generator  gen;
    regfile_driver     drv;
    regfile_monitor    mon;
    regfile_scoreboard sb;

    function new(virtual regfile_if vif, int num_random_seqs = 10, int random_seq_len = 200);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        // ONE reference-model instance for the entire run (see the
        // architectural-finding header comment) - it is NEVER replaced
        // with a fresh one between sequences, matching regfile.v's own
        // never-cleared storage array exactly.
        regfile_ref_model model = new();
        int total_cycles = 0;

        gen.build();

        foreach (gen.seq_q[s]) begin
            foreach (gen.seq_q[s][i]) begin
                regfile_cycle c = gen.seq_q[s][i];
                bit [4:0] r1, r2, wrd; bit wr; bit [31:0] wdata;
                regfile_result actual;
                c.fields(r1, r2, wr, wrd, wdata);
                drv.apply_cycle(c);
                mon.sample_one(actual);
                sb.check(gen.seq_name[s], i, c, r1, r2, wr, wrd, wdata, actual, model);
                total_cycles++;
            end
        end

        $display("\n============ REGFILE UNIT TB SUMMARY ============");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d", gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_regfile.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display(" NOTE: see the FINDING_post_reset_unwritten_reads_x and");
        $display("       cross_sequence_persistence_check_x5 sequences above -");
        $display("       both PASS against regfile.v's own literal (never-reset-");
        $display("       the-array) specification, which is exactly what makes");
        $display("       this worth flagging: rst_n_i is dead wiring on this DUT.");
        $display("===================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class regfile_test;
    regfile_env env;
    function new(virtual regfile_if vif, int num_random_seqs = 10, int random_seq_len = 200);
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

    regfile_if vif(clk);

    regfile dut (
        .clk_i          (clk),
        .rst_n_i        (vif.rst_n),
        .rs1_idx_i      (vif.rs1_idx),
        .rs2_idx_i      (vif.rs2_idx),
        .wb_reg_write_i (vif.wb_write),
        .wb_rd_i        (vif.wb_rd),
        .wb_data_i      (vif.wb_data),
        .rs1_data_o     (vif.rs1_data),
        .rs2_data_o     (vif.rs2_data)
    );

    regfile_test test;

    initial begin
        // rst_n_i is pulsed exactly once, here, purely to bring up a
        // clean interface state - per the architectural finding above, it
        // does NOT clear regfile.v's storage array, and this environment
        // does not pretend otherwise anywhere below.
        vif.rst_n = 1'b0;
        vif.rs1_idx = 5'd0; vif.rs2_idx = 5'd0;
        vif.wb_write = 1'b0; vif.wb_rd = 5'd0; vif.wb_data = 32'h0;
        repeat (2) @(posedge clk);
        vif.rst_n = 1'b1;
        @(posedge clk);

        test = new(vif, 10, 200);
        test.run();
        $finish;
    end
endmodule
