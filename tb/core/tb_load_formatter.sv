// =============================================================================
// tb_load_formatter.sv -- SystemVerilog unit TB for rtl/core/load_formatter.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 10.3 (load result formatting).
// Plan: C10 -- "LB/LH/LW/LBU/LHU sign/zero extension".
//
// The chosen test datum is 0x8081_8283: EVERY byte and EVERY halfword in it
// is negative, and all four bytes differ. That matters because a lane-mux
// error and a sign-extension error can otherwise cancel each other out --
// with this pattern they produce different values in every lane, so neither
// can hide.
//
// The stimulus space here is genuinely small (4 offsets x 5 funct3), so the
// directed sequences enumerate it exhaustively and the CRV layer sweeps the
// data value across it rather than re-rolling the control combinations.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

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
interface load_fmt_if (input bit clk);
    logic [31:0] rdata;
    logic [1:0]  lsbs;
    logic [2:0]  funct3;
    logic [31:0] load_data;

    // A1: LW is a pure pass-through at any offset (Sec. 10.3 "LW passes
    //     through") -- no extension, no lane selection.
    property p_lw_passthrough;
        @(posedge clk) (funct3[1:0] == 2'b10) |-> (load_data == rdata);
    endproperty
    a_lw: assert property (p_lw_passthrough)
        else $error("[SVA-FAIL] LW did not pass the bus data through unchanged");

    // A2: the unsigned forms ZERO-extend -- the bits above the loaded field
    //     must be clear whatever the data is.
    property p_lbu_zero_extends;
        @(posedge clk) (funct3 == `F3_BU) |-> (load_data[31:8] == 24'b0);
    endproperty
    a_lbu: assert property (p_lbu_zero_extends)
        else $error("[SVA-FAIL] LBU did not zero-extend");

    property p_lhu_zero_extends;
        @(posedge clk) (funct3 == `F3_HU) |-> (load_data[31:16] == 16'b0);
    endproperty
    a_lhu: assert property (p_lhu_zero_extends)
        else $error("[SVA-FAIL] LHU did not zero-extend");

    // A3: the signed forms replicate the loaded field's top bit -- stated as
    //     "the extension bits are all equal to the sign bit", which is the
    //     property, not a restatement of the RTL expression.
    property p_lb_sign_extends;
        @(posedge clk) (funct3 == `F3_B)
                       |-> (load_data[31:8] == {24{load_data[7]}});
    endproperty
    a_lb: assert property (p_lb_sign_extends)
        else $error("[SVA-FAIL] LB did not sign-extend");

    property p_lh_sign_extends;
        @(posedge clk) (funct3 == `F3_H)
                       |-> (load_data[31:16] == {16{load_data[15]}});
    endproperty
    a_lh: assert property (p_lh_sign_extends)
        else $error("[SVA-FAIL] LH did not sign-extend");

    // A4: a halfword access ignores addr[0] -- only addr[1] picks the half.
    //     (A misaligned halfword never reaches here; it is killed in EX.)
    property p_half_ignores_lsb0;
        @(posedge clk) (funct3[1:0] == 2'b01)
                       |-> (load_data[15:0] == (lsbs[1] ? rdata[31:16] : rdata[15:0]));
    endproperty
    a_half_lane: assert property (p_half_ignores_lsb0)
        else $error("[SVA-FAIL] halfword lane selection used addr[0]");

    property p_no_x;
        @(posedge clk) (!$isunknown({rdata, lsbs, funct3}))
                       |-> (!$isunknown(load_data));
    endproperty
    a_no_x: assert property (p_no_x)
        else $error("[SVA-FAIL] load_data_o went unknown with known inputs");
endinterface


// -------------------------------------------------------------
// 2. STIMULUS ITEM
// -------------------------------------------------------------
typedef enum { FK_NEGATIVE, FK_POSITIVE, FK_BOUNDARY, FK_RANDOM } fmt_kind_e;

class fmt_cycle;
    rand fmt_kind_e kind;
    rand bit [31:0] data;
    rand bit [1:0]  off;
    rand bit [2:0]  f3;

    constraint c_f3 { f3 inside {`F3_B, `F3_H, `F3_W, `F3_BU, `F3_HU}; }

    constraint c_kind_dist {
        kind dist { FK_NEGATIVE :/ 30, FK_POSITIVE :/ 25,
                    FK_BOUNDARY :/ 20, FK_RANDOM :/ 25 };
    }

    // Force every byte negative / every byte positive, so sign extension is
    // exercised in both directions on every lane rather than at random.
    constraint c_shape {
        (kind == FK_NEGATIVE) -> (data[7] && data[15] && data[23] && data[31]);
        (kind == FK_POSITIVE) -> (!data[7] && !data[15] && !data[23] && !data[31]);
        (kind == FK_BOUNDARY) -> data inside {32'h0000_007F, 32'h0000_0080,
                                              32'h0000_7FFF, 32'h0000_8000,
                                              32'h0000_0000, 32'hFFFF_FFFF,
                                              32'h7FFF_FFFF, 32'h8000_0000};
    }
endclass


// -------------------------------------------------------------
// 3. REFERENCE MODEL -- written from Sec. 10.3
// -------------------------------------------------------------
class fmt_ref_model;
    function automatic bit [31:0] step(bit [31:0] d, bit [1:0] off, bit [2:0] f3);
        bit [7:0]  b;
        bit [15:0] h;
        unique case (off)
            2'b00: b = d[7:0];
            2'b01: b = d[15:8];
            2'b10: b = d[23:16];
            2'b11: b = d[31:24];
        endcase
        h = off[1] ? d[31:16] : d[15:0];
        case (f3)
            `F3_B:   return {{24{b[7]}},  b};
            `F3_BU:  return {24'b0,       b};
            `F3_H:   return {{16{h[15]}}, h};
            `F3_HU:  return {16'b0,       h};
            default: return d;                     // LW
        endcase
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR
// -------------------------------------------------------------
class fmt_generator;
    fmt_cycle seq_q[$][$];
    string    seq_name[$];
    int       nseq, slen;

    function new(int nseq = 6, int slen = 200);
        this.nseq = nseq; this.slen = slen;
    endfunction

    function fmt_cycle mk(fmt_kind_e k, bit [31:0] d, bit [1:0] off, bit [2:0] f3);
        fmt_cycle c = new();
        c.kind = k; c.data = d; c.off = off; c.f3 = f3;
        return c;
    endfunction

    function void add_seq(string name, fmt_cycle q[$]);
        seq_name.push_back(name); seq_q.push_back(q);
    endfunction

    function void build();
        // 1) LB / LBU across all four lanes of 0x8081_8283 -- every byte is
        //    negative AND distinct, so lane and extension errors separate
        begin
            fmt_cycle q[$];
            for (int off = 0; off < 4; off++) begin
                q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, off[1:0], `F3_B));
                q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, off[1:0], `F3_BU));
            end
            add_seq("lb_lbu_all_lanes", q);
        end
        // 2) LH / LHU on both halves, with addr[0] set and clear to show it
        //    is ignored
        begin
            fmt_cycle q[$];
            q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, 2'b00, `F3_H));
            q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, 2'b01, `F3_H));  // same half
            q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, 2'b10, `F3_H));
            q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, 2'b11, `F3_H));  // same half
            q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, 2'b00, `F3_HU));
            q.push_back(mk(FK_NEGATIVE, 32'h8081_8283, 2'b10, `F3_HU));
            add_seq("lh_lhu_half_selection", q);
        end
        // 3) positive data: extension must be data-driven, not unconditional
        begin
            fmt_cycle q[$];
            q.push_back(mk(FK_POSITIVE, 32'h0102_0304, 2'b00, `F3_B));
            q.push_back(mk(FK_POSITIVE, 32'h0102_0304, 2'b11, `F3_B));
            q.push_back(mk(FK_POSITIVE, 32'h0102_0304, 2'b00, `F3_H));
            add_seq("positive_data_no_extension", q);
        end
        // 4) sign boundaries: 0x7F/0x80 and 0x7FFF/0x8000
        begin
            fmt_cycle q[$];
            q.push_back(mk(FK_BOUNDARY, 32'h0000_007F, 2'b00, `F3_B));
            q.push_back(mk(FK_BOUNDARY, 32'h0000_0080, 2'b00, `F3_B));
            q.push_back(mk(FK_BOUNDARY, 32'h0000_007F, 2'b00, `F3_BU));
            q.push_back(mk(FK_BOUNDARY, 32'h0000_0080, 2'b00, `F3_BU));
            q.push_back(mk(FK_BOUNDARY, 32'h0000_7FFF, 2'b00, `F3_H));
            q.push_back(mk(FK_BOUNDARY, 32'h0000_8000, 2'b00, `F3_H));
            q.push_back(mk(FK_BOUNDARY, 32'h0000_8000, 2'b00, `F3_HU));
            add_seq("sign_boundaries", q);
        end
        // 5) LW pass-through at every offset, plus the extremes
        begin
            fmt_cycle q[$];
            for (int off = 0; off < 4; off++)
                q.push_back(mk(FK_RANDOM, 32'hDEAD_BEEF, off[1:0], `F3_W));
            q.push_back(mk(FK_BOUNDARY, 32'h0000_0000, 2'b00, `F3_W));
            q.push_back(mk(FK_BOUNDARY, 32'hFFFF_FFFF, 2'b00, `F3_W));
            add_seq("lw_passthrough", q);
        end
        // 6) EXHAUSTIVE control sweep: 4 offsets x 5 funct3 at fixed data
        begin
            fmt_cycle q[$];
            bit [2:0] f3s[5] = '{`F3_B, `F3_H, `F3_W, `F3_BU, `F3_HU};
            foreach (f3s[i])
                for (int off = 0; off < 4; off++)
                    q.push_back(mk(FK_RANDOM, 32'hA5C3_5A3C, off[1:0], f3s[i]));
            add_seq("control_sweep_exhaustive", q);
        end
        // 7) CRV -- sweeps the DATA across the (already exhausted) control space
        for (int s = 0; s < nseq; s++) begin
            fmt_cycle q[$];
            for (int i = 0; i < slen; i++) begin
                fmt_cycle c = new();
                if (!c.randomize()) $fatal(1, "fmt_cycle randomize() failed");
                q.push_back(c);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. DRIVER / MONITOR
// -------------------------------------------------------------
class fmt_driver;
    virtual load_fmt_if vif;
    function new(virtual load_fmt_if vif); this.vif = vif; endfunction
    task apply(fmt_cycle c);
        @(negedge vif.clk);
        vif.rdata <= c.data; vif.lsbs <= c.off; vif.funct3 <= c.f3;
    endtask
endclass

class fmt_monitor;
    virtual load_fmt_if vif;

    covergroup cg_fmt;
        cp_f3: coverpoint vif.funct3 {
            bins lb = {`F3_B}; bins lh = {`F3_H}; bins lw = {`F3_W};
            bins lbu = {`F3_BU}; bins lhu = {`F3_HU};
        }
        cp_off: coverpoint vif.lsbs {
            bins off0 = {2'b00}; bins off1 = {2'b01};
            bins off2 = {2'b10}; bins off3 = {2'b11};
        }
        // Every load type at every byte offset -- the lane-selection matrix.
        cross cp_f3, cp_off;
        // Whether the extension actually fired: the result's sign bit.
        cp_result_sign: coverpoint vif.load_data[31];
        cross cp_f3, cp_result_sign {
            // LBU/LHU zero-extend, so their result can only be negative when
            // the datum itself is a full-width negative word -- impossible
            // for the sub-word forms. Excluded rather than left as an
            // apparent hole.
            ignore_bins unsigned_forms_never_negative =
                binsof(cp_f3) intersect {`F3_BU, `F3_HU} &&
                binsof(cp_result_sign) intersect {1};
        }
    endgroup

    function new(virtual load_fmt_if vif);
        this.vif = vif; cg_fmt = new();
    endfunction

    task sample_one(output bit [31:0] r);
        #1; r = vif.load_data; cg_fmt.sample();
    endtask
endclass


// -------------------------------------------------------------
// 6. ENV
// -------------------------------------------------------------
class fmt_env;
    virtual load_fmt_if vif;
    fmt_generator gen;
    fmt_driver    drv;
    fmt_monitor   mon;
    fmt_ref_model model;
    garuda_tb_pkg::scoreboard sb;

    function new(virtual load_fmt_if vif, int nseq = 6, int slen = 200);
        this.vif = vif;
        gen = new(nseq, slen); drv = new(vif); mon = new(vif);
        model = new(); sb = new("LOAD_FORMATTER");
    endfunction

    task run();
        gen.build();
        foreach (gen.seq_q[s])
            foreach (gen.seq_q[s][i]) begin
                fmt_cycle  c = gen.seq_q[s][i];
                bit [31:0] act, exp;
                drv.apply(c);
                mon.sample_one(act);
                exp = model.step(c.data, c.off, c.f3);
                sb.chk(gen.seq_name[s],
                       $sformatf("f3=%03b off=%02b rdata=%08h", c.f3, c.off, c.data),
                       act, exp);
            end
        sb.summary(mon.cg_fmt.get_coverage());
    endtask
endclass


// -------------------------------------------------------------
// 7. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    load_fmt_if vif(clk);

    load_formatter dut (
        .rdata_i     (vif.rdata),
        .addr_lsbs_i (vif.lsbs),
        .funct3_i    (vif.funct3),
        .load_data_o (vif.load_data)
    );

    fmt_env env;

    initial begin
        vif.rdata = 0; vif.lsbs = 2'b00; vif.funct3 = `F3_W;
        repeat (3) @(posedge clk);
        env = new(vif, 6, 200);
        env.run();
        $finish;
    end
endmodule
