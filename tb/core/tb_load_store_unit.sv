// =============================================================================
// tb_load_store_unit.sv -- SystemVerilog unit TB for rtl/core/load_store_unit.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 10.1 / 10.2.
// Plan: C10 (SB/SH/SW lane alignment) and C11 (misaligned LH/LW, SH/SW) at
//       the unit level. C11's "no bus transaction issued" half is a mem_stage
//       property (the start_w gate) and lives in tb_mem_stage.sv.
//
// The misalignment matrix is exhaustive rather than sampled: 3 sizes x 4
// address LSB values is 12 combinations, small enough to enumerate, and
// enumerating removes any argument about which corner was missed. The store
// lane alignment is likewise driven at every offset with an operand whose
// upper bytes are non-zero, so a shift that failed to truncate the operand
// first is visible.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

// RV32I load/store funct3 encodings.
// Guarded: three element TBs define these, and a whole-directory lint
// pass compiles them together even though each runs on its own filelist.
`ifndef GARUDA_LDST_F3
`define GARUDA_LDST_F3
`define F3_B  3'b000
`define F3_H  3'b001
`define F3_W  3'b010
`define F3_BU 3'b100
`define F3_HU 3'b101
`endif

// -------------------------------------------------------------
// 1. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface lsu_if (input bit clk);
    logic [31:0] addr, rs2_data;
    logic [2:0]  funct3;
    logic [2:0]  hsize;
    logic        load_mis, store_mis;
    logic [31:0] hwdata;

    // A1: hsize is funct3[1:0] widened -- funct3[2] (the unsigned bit) must
    //     never leak into the bus size.
    property p_hsize_from_funct3;
        @(posedge clk) hsize == {1'b0, funct3[1:0]};
    endproperty
    a_hsize: assert property (p_hsize_from_funct3)
        else $error("[SVA-FAIL] hsize_o is not {1'b0, funct3[1:0]}");

    // A2: a byte access can never be misaligned, at any address.
    property p_byte_never_misaligned;
        @(posedge clk) (funct3[1:0] == 2'b00) |-> (!load_mis && !store_mis);
    endproperty
    a_byte_aligned: assert property (p_byte_never_misaligned)
        else $error("[SVA-FAIL] a byte access was reported misaligned");

    // A3: the load and store misalign outputs are the same expression here.
    //     The cause-4-vs-cause-6 split is made by the caller ANDing with
    //     mem_read/mem_write, so these must never disagree.
    property p_load_store_agree;
        @(posedge clk) load_mis == store_mis;
    endproperty
    a_agree: assert property (p_load_store_agree)
        else $error("[SVA-FAIL] load_misaligned_o and store_misaligned_o disagree");

    // A4: a word access is aligned exactly when addr[1:0] == 0 (Sec. 10.2).
    property p_word_alignment_rule;
        @(posedge clk) (funct3[1:0] == 2'b10) |-> (load_mis == (|addr[1:0]));
    endproperty
    a_word_rule: assert property (p_word_alignment_rule)
        else $error("[SVA-FAIL] word alignment rule violated");

    // A5: a halfword access is aligned exactly when addr[0] == 0.
    property p_half_alignment_rule;
        @(posedge clk) (funct3[1:0] == 2'b01) |-> (load_mis == addr[0]);
    endproperty
    a_half_rule: assert property (p_half_alignment_rule)
        else $error("[SVA-FAIL] halfword alignment rule violated");

    // A6: even on a misaligned access -- which never reaches the bus -- the
    //     write data must stay defined. An X here would propagate onto
    //     d_hwdata_o before the access is gated off.
    property p_hwdata_defined;
        @(posedge clk) (!$isunknown({addr, rs2_data, funct3}))
                       |-> (!$isunknown(hwdata));
    endproperty
    a_hwdata_defined: assert property (p_hwdata_defined)
        else $error("[SVA-FAIL] hwdata_o went unknown with known inputs");
endinterface


// -------------------------------------------------------------
// 2. STIMULUS ITEM
// -------------------------------------------------------------
typedef enum { LK_ALIGNED, LK_MISALIGNED, LK_LANE_SWEEP, LK_PATTERN, LK_RANDOM }
        lsu_kind_e;

class lsu_cycle;
    rand lsu_kind_e kind;
    rand bit [31:0] addr, data;
    rand bit [2:0]  f3;

    constraint c_f3 { f3 inside {`F3_B, `F3_H, `F3_W, `F3_BU, `F3_HU}; }

    constraint c_kind_dist {
        kind dist { LK_ALIGNED :/ 25, LK_MISALIGNED :/ 25, LK_LANE_SWEEP :/ 20,
                    LK_PATTERN :/ 15, LK_RANDOM :/ 15 };
    }

    // Force the interesting alignment cases rather than waiting for random
    // addresses to land on them.
    constraint c_alignment {
        (kind == LK_ALIGNED) -> ((f3[1:0] == 2'b10) -> (addr[1:0] == 2'b00));
        (kind == LK_ALIGNED) -> ((f3[1:0] == 2'b01) -> (addr[0]   == 1'b0));
        (kind == LK_MISALIGNED) -> (f3[1:0] inside {2'b01, 2'b10});
        (kind == LK_MISALIGNED) -> ((f3[1:0] == 2'b01) -> (addr[0] == 1'b1));
        (kind == LK_MISALIGNED) -> ((f3[1:0] == 2'b10) -> (addr[1:0] != 2'b00));
    }

    // Complementary data patterns: aimed at the wide-bus toggle shortfall
    // described in docs/COVERAGE.md, which ordinary small constants never hit.
    constraint c_pattern {
        (kind == LK_PATTERN) -> data inside {32'h0000_0000, 32'hFFFF_FFFF,
                                             32'h5555_5555, 32'hAAAA_AAAA};
    }
endclass


// -------------------------------------------------------------
// 3. REFERENCE MODEL -- from Sec. 10.1 / 10.2
// -------------------------------------------------------------
class lsu_ref_model;
    function automatic void step(bit [31:0] addr, bit [31:0] data, bit [2:0] f3,
                                  output bit [2:0]  hsize,
                                  output bit        misaligned,
                                  output bit [31:0] hwdata);
        bit [1:0] size = f3[1:0];
        hsize = {1'b0, size};
        unique case (size)
            2'b00:   misaligned = 1'b0;              // byte: never
            2'b01:   misaligned = addr[0];           // half: addr[0]
            2'b10:   misaligned = |addr[1:0];        // word: addr[1:0]
            default: misaligned = 1'b0;
        endcase
        case (size)
            2'b00:   hwdata = {24'b0, data[7:0]}  << (addr[1:0] * 8);
            2'b01:   hwdata = {16'b0, data[15:0]} << (addr[1]   * 16);
            default: hwdata = data;                  // word: no shift
        endcase
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR
// -------------------------------------------------------------
class lsu_generator;
    lsu_cycle seq_q[$][$];
    string    seq_name[$];
    int       nseq, slen;

    function new(int nseq = 6, int slen = 200);
        this.nseq = nseq; this.slen = slen;
    endfunction

    function lsu_cycle mk(lsu_kind_e k, bit [31:0] a, bit [31:0] d, bit [2:0] f3);
        lsu_cycle c = new();
        c.kind = k; c.addr = a; c.data = d; c.f3 = f3;
        return c;
    endfunction

    function void add_seq(string name, lsu_cycle q[$]);
        seq_name.push_back(name); seq_q.push_back(q);
    endfunction

    function void build();
        // 1) hsize for all five load/store funct3 encodings
        begin
            lsu_cycle q[$];
            bit [2:0] f3s[5] = '{`F3_B, `F3_H, `F3_W, `F3_BU, `F3_HU};
            foreach (f3s[i])
                q.push_back(mk(LK_ALIGNED, 32'h2000_0000, 32'hDEAD_BEEF, f3s[i]));
            add_seq("hsize_derivation", q);
        end
        // 2) EXHAUSTIVE misalignment matrix: 3 sizes x 4 address LSBs
        begin
            lsu_cycle q[$];
            bit [2:0] f3s[3] = '{`F3_B, `F3_H, `F3_W};
            foreach (f3s[i])
                for (int off = 0; off < 4; off++)
                    q.push_back(mk(LK_RANDOM, 32'h2000_0000 | off,
                                   32'hAAAA_5555, f3s[i]));
            // and the unsigned encodings, which must behave identically
            for (int off = 0; off < 4; off++) begin
                q.push_back(mk(LK_RANDOM, 32'h2000_0000 | off, 32'h1, `F3_BU));
                q.push_back(mk(LK_RANDOM, 32'h2000_0000 | off, 32'h1, `F3_HU));
            end
            add_seq("misalign_matrix_exhaustive", q);
        end
        // 3) alignment depends only on the low two bits, not the region
        begin
            lsu_cycle q[$];
            q.push_back(mk(LK_ALIGNED,    32'hFFFF_FFFC, 32'd1, `F3_W));
            q.push_back(mk(LK_MISALIGNED, 32'hFFFF_FFFE, 32'd1, `F3_W));
            q.push_back(mk(LK_ALIGNED,    32'h0000_0000, 32'd1, `F3_W));
            add_seq("alignment_is_region_independent", q);
        end
        // 4) SB lane alignment at every offset (C10)
        begin
            lsu_cycle q[$];
            for (int off = 0; off < 4; off++)
                q.push_back(mk(LK_LANE_SWEEP, 32'h2000_0000 | off,
                               32'h1234_56AB, `F3_B));
            add_seq("sb_lane_alignment", q);
        end
        // 5) SH half alignment, and SW pass-through
        begin
            lsu_cycle q[$];
            q.push_back(mk(LK_LANE_SWEEP, 32'h2000_0000, 32'h1234_BEEF, `F3_H));
            q.push_back(mk(LK_LANE_SWEEP, 32'h2000_0002, 32'h1234_BEEF, `F3_H));
            q.push_back(mk(LK_LANE_SWEEP, 32'h2000_0000, 32'hCAFE_F00D, `F3_W));
            q.push_back(mk(LK_LANE_SWEEP, 32'h2000_0004, 32'hCAFE_F00D, `F3_W));
            add_seq("sh_half_and_sw_passthrough", q);
        end
        // 6) complementary patterns through every byte lane (toggle)
        begin
            lsu_cycle q[$];
            bit [31:0] pat[4] = '{32'h0000_0000, 32'hFFFF_FFFF,
                                  32'h5555_5555, 32'hAAAA_AAAA};
            foreach (pat[p])
                for (int off = 0; off < 4; off++) begin
                    q.push_back(mk(LK_PATTERN, 32'h2000_0000 | off, pat[p], `F3_B));
                    q.push_back(mk(LK_PATTERN, 32'h2000_0000 | off, pat[p], `F3_H));
                    q.push_back(mk(LK_PATTERN, 32'h2000_0000 | off, pat[p], `F3_W));
                end
            add_seq("toggle_patterns", q);
        end
        // 7) CRV
        for (int s = 0; s < nseq; s++) begin
            lsu_cycle q[$];
            for (int i = 0; i < slen; i++) begin
                lsu_cycle c = new();
                if (!c.randomize()) $fatal(1, "lsu_cycle randomize() failed");
                q.push_back(c);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. DRIVER / MONITOR
// -------------------------------------------------------------
class lsu_driver;
    virtual lsu_if vif;
    function new(virtual lsu_if vif); this.vif = vif; endfunction
    task apply(lsu_cycle c);
        @(negedge vif.clk);
        vif.addr <= c.addr; vif.rs2_data <= c.data; vif.funct3 <= c.f3;
    endtask
endclass

class lsu_monitor;
    virtual lsu_if vif;

    covergroup cg_lsu;
        cp_size: coverpoint vif.funct3[1:0] {
            bins byte_ = {2'b00}; bins half = {2'b01}; bins word = {2'b10};
        }
        cp_unsigned: coverpoint vif.funct3[2];
        cp_offset: coverpoint vif.addr[1:0] {
            bins off0 = {2'b00}; bins off1 = {2'b01};
            bins off2 = {2'b10}; bins off3 = {2'b11};
        }
        // The full size x offset matrix -- 12 bins, all reachable, and the
        // misalignment behaviour is defined for every one of them.
        cross cp_size, cp_offset;
        cp_misaligned: coverpoint vif.load_mis;
        cross cp_size, cp_misaligned {
            // A byte access is misaligned in no addressing mode (SVA A2),
            // so this bin is unreachable by construction, not untested.
            ignore_bins byte_cannot_misalign =
                binsof(cp_size.byte_) && binsof(cp_misaligned) intersect {1};
        }
        cp_store_data: coverpoint vif.rs2_data {
            bins zero  = {32'h0000_0000};
            bins ones  = {32'hFFFF_FFFF};
            bins alt_a = {32'h5555_5555};
            bins alt_b = {32'hAAAA_AAAA};
            bins generic = default;
        }
    endgroup

    function new(virtual lsu_if vif);
        this.vif = vif; cg_lsu = new();
    endfunction

    task sample_one(output bit [2:0] hs, output bit lm, output bit sm,
                    output bit [31:0] wd);
        #1;
        hs = vif.hsize; lm = vif.load_mis; sm = vif.store_mis; wd = vif.hwdata;
        cg_lsu.sample();
    endtask
endclass


// -------------------------------------------------------------
// 6. ENV
// -------------------------------------------------------------
class lsu_env;
    virtual lsu_if vif;
    lsu_generator gen;
    lsu_driver    drv;
    lsu_monitor   mon;
    lsu_ref_model model;
    garuda_tb_pkg::scoreboard sb;

    function new(virtual lsu_if vif, int nseq = 6, int slen = 200);
        this.vif = vif;
        gen = new(nseq, slen); drv = new(vif); mon = new(vif);
        model = new(); sb = new("LOAD_STORE_UNIT");
    endfunction

    task run();
        gen.build();
        foreach (gen.seq_q[s])
            foreach (gen.seq_q[s][i]) begin
                lsu_cycle  c = gen.seq_q[s][i];
                bit [2:0]  hs_a, hs_e;
                bit        lm_a, sm_a, mis_e;
                bit [31:0] wd_a, wd_e;
                string     tag;
                drv.apply(c);
                mon.sample_one(hs_a, lm_a, sm_a, wd_a);
                model.step(c.addr, c.data, c.f3, hs_e, mis_e, wd_e);
                tag = $sformatf("f3=%03b addr=%08h", c.f3, c.addr);
                sb.chk (gen.seq_name[s], {tag, " hsize"},      hs_a, hs_e);
                sb.chk1(gen.seq_name[s], {tag, " load_mis"},   lm_a, mis_e);
                sb.chk1(gen.seq_name[s], {tag, " store_mis"},  sm_a, mis_e);
                sb.chk (gen.seq_name[s], {tag, " hwdata"},     wd_a, wd_e);
            end
        sb.summary(mon.cg_lsu.get_coverage());
    endtask
endclass


// -------------------------------------------------------------
// 7. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    lsu_if vif(clk);

    load_store_unit dut (
        .addr_i             (vif.addr),
        .funct3_i           (vif.funct3),
        .rs2_data_i         (vif.rs2_data),
        .hsize_o            (vif.hsize),
        .load_misaligned_o  (vif.load_mis),
        .store_misaligned_o (vif.store_mis),
        .hwdata_o           (vif.hwdata)
    );

    lsu_env env;

    initial begin
        vif.addr = 32'h2000_0000; vif.rs2_data = 0; vif.funct3 = `F3_W;
        repeat (3) @(posedge clk);
        env = new(vif, 6, 200);
        env.run();
        $finish;
    end
endmodule
