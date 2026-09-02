// =============================================================================
// tb_csr_rw.sv -- SystemVerilog unit TB for rtl/core/csr_rw.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 8.3 / 8.4 / 13.3.
// Plan: C21 (M-mode CSR read/write) at the seam level. Architectural CSR
//       state lives in csr_file.v and is NOT in scope here -- this block is
//       only the EX-side half of the CSR_RW <-> CONTROL exchange (Sec. 8.4).
//
// The discriminating vector is the immediate variant with uimm = 5'b11111:
// zero-extension gives 31, sign-extension would give 0xFFFF_FFFF. The uimm
// field ALIASES the rs1 index bits, so every immediate check here drives
// rs1_fwd to a conflicting non-zero value -- picking the wrong source cannot
// look correct.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps
`include "core_ex_defs.vh"

// -------------------------------------------------------------
// 1. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface csr_rw_if (input bit clk);
    logic [31:0] instr, rs1_fwd;
    logic        csr_en, csr_imm;
    logic [1:0]  csr_op;
    logic [11:0] csr_addr;
    logic [31:0] csr_wdata;
    logic [1:0]  csr_op_out;
    logic        csr_en_out;

    // A1: the CSR address is instr[31:20], always -- a pure slice.
    property p_addr_is_slice;
        @(posedge clk) csr_addr == instr[31:20];
    endproperty
    a_addr: assert property (p_addr_is_slice)
        else $error("[SVA-FAIL] csr_addr is not instr[31:20]");

    // A2: immediate variants ZERO-extend a 5-bit field (Sec. 8.4) -- bits
    //     [31:5] must be clear, whatever rs1_fwd happens to be.
    property p_imm_zero_extended;
        @(posedge clk) csr_imm |-> (csr_wdata[31:5] == 27'b0);
    endproperty
    a_imm_zext: assert property (p_imm_zero_extended)
        else $error("[SVA-FAIL] immediate CSR write data was not zero-extended");

    // A3: register variants pass the FORWARDED rs1 through untouched, so a
    //     CSRRW whose rs1 came from the previous instruction works.
    property p_reg_passes_rs1;
        @(posedge clk) (!csr_imm) |-> (csr_wdata == rs1_fwd);
    endproperty
    a_reg_rs1: assert property (p_reg_passes_rs1)
        else $error("[SVA-FAIL] register-variant write data is not the forwarded rs1");

    // A4: op and enable are transparent -- this block never decodes them.
    property p_op_transparent;
        @(posedge clk) (csr_op_out == csr_op) && (csr_en_out == csr_en);
    endproperty
    a_op_transparent: assert property (p_op_transparent)
        else $error("[SVA-FAIL] csr_op/csr_en were not passed through unchanged");

    // A5: addr and wdata stay LIVE with csr_en low. Gating belongs to the EX
    //     result mux (Sec. 8.3), not here; a future "optimisation" that
    //     gates them in this block would break the erratum 6.3-E1 path.
    property p_live_when_disabled;
        @(posedge clk) (!csr_en) |-> (csr_addr == instr[31:20]);
    endproperty
    a_live: assert property (p_live_when_disabled)
        else $error("[SVA-FAIL] csr_addr was gated off by csr_en");
endinterface


// -------------------------------------------------------------
// 2. STIMULUS ITEM
// -------------------------------------------------------------
typedef enum { CK_REG, CK_IMM, CK_DISABLED, CK_RANDOM } csr_kind_e;

class csr_cycle;
    rand csr_kind_e kind;
    rand bit [11:0] addr;
    rand bit [4:0]  rs1_or_uimm;
    rand bit [4:0]  rd;
    rand bit [31:0] rs1_val;
    rand bit        en, imm;
    rand bit [1:0]  op;

    // CSR_RW / CSR_RS / CSR_RC (= funct3[1:0]); 2'b00 is not a CSR op.
    constraint c_op { op inside {`CSR_RW, `CSR_RS, `CSR_RC}; }

    constraint c_kind {
        (kind == CK_REG)      -> (en == 1 && imm == 0);
        (kind == CK_IMM)      -> (en == 1 && imm == 1);
        (kind == CK_DISABLED) -> (en == 0);
        // rs1_fwd is always non-zero on immediate cycles so a wrong-source
        // mux cannot coincidentally match the zero-extended uimm.
        (kind == CK_IMM)      -> (rs1_val != 0 && rs1_val[31:5] != 0);
    }

    constraint c_kind_dist {
        kind dist { CK_REG :/ 35, CK_IMM :/ 35, CK_DISABLED :/ 10, CK_RANDOM :/ 20 };
    }

    // Build the SYSTEM instruction word: addr[31:20], rs1/uimm[19:15],
    // funct3[14:12], rd[11:7], opcode 1110011.
    function bit [31:0] instr_word();
        bit [2:0] f3 = {imm, op};      // funct3[2] selects the immediate form
        return {addr, rs1_or_uimm, f3, rd, 7'b1110011};
    endfunction
endclass


// -------------------------------------------------------------
// 3. REFERENCE MODEL
// -------------------------------------------------------------
class csr_ref_model;
    function automatic void step(bit [31:0] instr, bit [31:0] rs1_fwd,
                                  bit imm, bit [1:0] op, bit en,
                                  output bit [11:0] addr,
                                  output bit [31:0] wdata,
                                  output bit [1:0]  op_out,
                                  output bit        en_out);
        addr   = instr[31:20];
        wdata  = imm ? {27'b0, instr[19:15]} : rs1_fwd;   // Sec. 8.4
        op_out = op;
        en_out = en;
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR
// -------------------------------------------------------------
class csr_generator;
    csr_cycle seq_q[$][$];
    string    seq_name[$];
    int       nseq, slen;

    function new(int nseq = 6, int slen = 200);
        this.nseq = nseq; this.slen = slen;
    endfunction

    function csr_cycle mk(csr_kind_e k, bit [11:0] addr, bit [4:0] f,
                           bit [31:0] rs1v, bit en, bit imm, bit [1:0] op);
        csr_cycle c = new();
        c.kind = k; c.addr = addr; c.rs1_or_uimm = f; c.rd = 5'd3;
        c.rs1_val = rs1v; c.en = en; c.imm = imm; c.op = op;
        return c;
    endfunction

    function void add_seq(string name, csr_cycle q[$]);
        seq_name.push_back(name); seq_q.push_back(q);
    endfunction

    function void build();
        // 1) every CSR address in the Sec. 13.2 table
        begin
            csr_cycle q[$];
            bit [11:0] addrs[22] = '{12'h300, 12'h301, 12'h304, 12'h305, 12'h307,
                                     12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
                                     12'h345, 12'h347, 12'hB00, 12'hB02, 12'hB80,
                                     12'hB82, 12'hBC0, 12'hF11, 12'hF12, 12'hF13,
                                     12'hF14, 12'hFB1};
            foreach (addrs[i])
                q.push_back(mk(CK_REG, addrs[i], 5'd7, 32'hA5A5_A5A5, 1, 0, `CSR_RW));
            add_seq("sec13_2_csr_map", q);
        end
        // 2) walking ones across the whole 12-bit address field -- catches a
        //    mis-sliced field that a handful of real addresses would miss
        begin
            csr_cycle q[$];
            for (int b = 0; b < 12; b++)
                q.push_back(mk(CK_REG, 12'd1 << b, 5'd0, 32'd0, 1, 0, `CSR_RW));
            q.push_back(mk(CK_REG, 12'h000, 5'd0, 32'd0, 1, 0, `CSR_RW));
            q.push_back(mk(CK_REG, 12'hFFF, 5'd0, 32'd0, 1, 0, `CSR_RW));
            add_seq("addr_walking_ones", q);
        end
        // 3) register variants: wdata is the forwarded rs1
        begin
            csr_cycle q[$];
            q.push_back(mk(CK_REG, 12'h340, 5'd7,  32'hDEAD_BEEF, 1, 0, `CSR_RW));
            q.push_back(mk(CK_REG, 12'h340, 5'd7,  32'h0000_0000, 1, 0, `CSR_RS));
            q.push_back(mk(CK_REG, 12'h340, 5'd7,  32'hFFFF_FFFF, 1, 0, `CSR_RC));
            add_seq("register_variants", q);
        end
        // 4) immediate variants: zero-extension is the discriminator.
        //    rs1_val is deliberately 0xDEAD_BEEF on every one of these.
        begin
            csr_cycle q[$];
            q.push_back(mk(CK_IMM, 12'h340, 5'b11111, 32'hDEAD_BEEF, 1, 1, `CSR_RW));
            q.push_back(mk(CK_IMM, 12'h340, 5'b00001, 32'hDEAD_BEEF, 1, 1, `CSR_RS));
            q.push_back(mk(CK_IMM, 12'h340, 5'b00000, 32'hDEAD_BEEF, 1, 1, `CSR_RC));
            q.push_back(mk(CK_IMM, 12'h340, 5'b10000, 32'hDEAD_BEEF, 1, 1, `CSR_RW));
            add_seq("immediate_zero_extension", q);
        end
        // 5) full uimm sweep 0..31
        begin
            csr_cycle q[$];
            for (int u = 0; u < 32; u++)
                q.push_back(mk(CK_IMM, 12'h340, u[4:0], 32'hFFFF_FFFF, 1, 1, `CSR_RW));
            add_seq("uimm_sweep", q);
        end
        // 6) all three ops, enable high and low
        begin
            csr_cycle q[$];
            bit [1:0] ops[3] = '{`CSR_RW, `CSR_RS, `CSR_RC};
            foreach (ops[i]) begin
                q.push_back(mk(CK_REG,      12'h305, 5'd9, 32'h1234_5678, 1, 0, ops[i]));
                q.push_back(mk(CK_DISABLED, 12'h305, 5'd9, 32'h1234_5678, 0, 0, ops[i]));
            end
            add_seq("op_and_enable_passthrough", q);
        end
        // 7) CRV
        for (int s = 0; s < nseq; s++) begin
            csr_cycle q[$];
            for (int i = 0; i < slen; i++) begin
                csr_cycle c = new();
                if (!c.randomize()) $fatal(1, "csr_cycle randomize() failed");
                q.push_back(c);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. DRIVER / MONITOR
// -------------------------------------------------------------
class csr_driver;
    virtual csr_rw_if vif;
    function new(virtual csr_rw_if vif); this.vif = vif; endfunction
    task apply(csr_cycle c);
        @(negedge vif.clk);
        vif.instr   <= c.instr_word();
        vif.rs1_fwd <= c.rs1_val;
        vif.csr_en  <= c.en;
        vif.csr_imm <= c.imm;
        vif.csr_op  <= c.op;
    endtask
endclass

class csr_monitor;
    virtual csr_rw_if vif;

    covergroup cg_csr;
        cp_addr_group: coverpoint vif.csr_addr {
            bins machine_trap_setup  = {[12'h300:12'h307]};
            bins machine_trap_handle = {[12'h340:12'h347]};
            bins counters            = {[12'hB00:12'hB82]};
            bins dsu_ovf             = {12'hBC0};       // custom, Sec. 13.2
            bins machine_info        = {[12'hF11:12'hF14]};
            bins mintstatus          = {12'hFB1};
            bins other               = default;
        }
        cp_op: coverpoint vif.csr_op {
            bins rw = {`CSR_RW}; bins rs = {`CSR_RS}; bins rc = {`CSR_RC};
            bins unused = {2'b00};
        }
        cp_imm: coverpoint vif.csr_imm;
        cp_en:  coverpoint vif.csr_en;
        // All 3 ops x both forms: CSRRWI/SI/CI as well as CSRRW/S/C.
        cross cp_op, cp_imm;
        cross cp_op, cp_en;
        cp_uimm: coverpoint vif.instr[19:15] iff (vif.csr_imm) {
            bins zero = {0};
            bins max  = {31};          // the sign-extension discriminator
            bins mid  = {[1:30]};
        }
    endgroup

    function new(virtual csr_rw_if vif);
        this.vif = vif; cg_csr = new();
    endfunction

    task sample_one(output bit [11:0] a, output bit [31:0] w,
                    output bit [1:0] o, output bit e);
        #1;
        a = vif.csr_addr; w = vif.csr_wdata;
        o = vif.csr_op_out; e = vif.csr_en_out;
        cg_csr.sample();
    endtask
endclass


// -------------------------------------------------------------
// 6. ENV
// -------------------------------------------------------------
class csr_env;
    virtual csr_rw_if vif;
    csr_generator gen;
    csr_driver    drv;
    csr_monitor   mon;
    csr_ref_model model;
    garuda_tb_pkg::scoreboard sb;

    function new(virtual csr_rw_if vif, int nseq = 6, int slen = 200);
        this.vif = vif;
        gen = new(nseq, slen); drv = new(vif); mon = new(vif);
        model = new(); sb = new("CSR_RW");
    endfunction

    task run();
        gen.build();
        foreach (gen.seq_q[s])
            foreach (gen.seq_q[s][i]) begin
                csr_cycle  c = gen.seq_q[s][i];
                bit [11:0] a_act, a_exp;
                bit [31:0] w_act, w_exp;
                bit [1:0]  o_act, o_exp;
                bit        e_act, e_exp;
                string     tag;
                drv.apply(c);
                mon.sample_one(a_act, w_act, o_act, e_act);
                model.step(c.instr_word(), c.rs1_val, c.imm, c.op, c.en,
                           a_exp, w_exp, o_exp, e_exp);
                tag = $sformatf("%s addr=%03h imm=%0b", c.kind.name(), c.addr, c.imm);
                sb.chk (gen.seq_name[s], {tag, " csr_addr"},  a_act, a_exp);
                sb.chk (gen.seq_name[s], {tag, " csr_wdata"}, w_act, w_exp);
                sb.chk (gen.seq_name[s], {tag, " csr_op"},    o_act, o_exp);
                sb.chk1(gen.seq_name[s], {tag, " csr_en"},    e_act, e_exp);
            end
        sb.summary(mon.cg_csr.get_coverage());
    endtask
endclass


// -------------------------------------------------------------
// 7. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    csr_rw_if vif(clk);

    csr_rw dut (
        .instr      (vif.instr),
        .rs1_fwd    (vif.rs1_fwd),
        .csr_en     (vif.csr_en),
        .csr_imm    (vif.csr_imm),
        .csr_op     (vif.csr_op),
        .csr_addr   (vif.csr_addr),
        .csr_wdata  (vif.csr_wdata),
        .csr_op_out (vif.csr_op_out),
        .csr_en_out (vif.csr_en_out)
    );

    csr_env env;

    initial begin
        vif.instr = 32'h0000_0073; vif.rs1_fwd = 0;
        vif.csr_en = 0; vif.csr_imm = 0; vif.csr_op = `CSR_RW;
        repeat (3) @(posedge clk);
        env = new(vif, 6, 200);
        env.run();
        $finish;
    end
endmodule
