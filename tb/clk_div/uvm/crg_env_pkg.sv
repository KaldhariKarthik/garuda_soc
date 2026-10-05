`timescale 1ns/1ps
// =============================================================================
// crg_env_pkg.sv - UVM environment for blocks 22 and 23, the clock divider and
// the reset controller, verified together as they are used.
//
// Plan: tb/clk_div/GARUDA_CLKRST_vplan.csv. The clocks and the reset sequencing
// are checked by properties bound to the two modules (rtl/clk_div/clk_div_sva.sv,
// rtl/reset_ctrl/reset_ctrl_sva.sv); many of those measure time on the pins.
// This package adds:
//
//   crg_monitor     one item per edge of the always-on clock, and one for every
//                   assertion of the reset pin (which needs no clock)
//   crg_ref_model   the registers, written from GARUDA-CLKRST-SPEC-001 section 6.
//                   Where the specification leaves a point open the model
//                   follows the RTL and the line says so.
//   crg_scoreboard  every read (sb_reason, sb_clkstat, sb_reg), every access
//                   (sb_pslverr), DIVSEL and the lock on their pins; and
//                   sb_reset: every reset measured on the pins in reference
//                   clock cycles, with its sources and what it reached
//   crg_coverage    the plan's covergroups
// =============================================================================
package crg_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import crg_reg_pkg::*;

    localparam int unsigned STRETCH_REF = 1024;     // [N-7.7]: at least this many reference cycles

    // ------------------------------------------------------------------ monitor
    class crg_cycle_item extends uvm_sequence_item;
        bit ext_event;                      // the reset pin was asserted (no clock involved)
        bit ext_rst_n, wdt_req, ndm_req, hart_req, boot_sel;
        bit psel, penable, pwrite; bit [11:0] paddr; bit [31:0] pwdata;
        logic [31:0] prdata; logic pready, pslverr;
        bit div_busy; bit [1:0] div_act, div_sel;
        bit hreset_n, preset_n, core_rst_n, dm_rst_n, ilock; bit [3:0] phase;
        `uvm_object_utils(crg_cycle_item)
        function new(string name = "crg_cycle_item"); super.new(name); endfunction
    endclass

    class crg_monitor extends uvm_monitor;
        `uvm_component_utils(crg_monitor)
        virtual crg_if vif;
        uvm_analysis_port #(crg_cycle_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual crg_if)::get(this, "", "cvif", vif)) `uvm_fatal("NOVIF", "crg_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            fork
                forever begin
                    crg_cycle_item it;
                    @(vif.acb);
                    it = crg_cycle_item::type_id::create("it");
                    it.ext_rst_n = (vif.acb.ext_rst_n === 1'b1); it.wdt_req = vif.acb.wdt_req; it.ndm_req = vif.acb.ndm_req;
                    it.hart_req = vif.acb.hart_req; it.boot_sel = vif.acb.boot_sel;
                    it.psel = (vif.acb.psel === 1'b1); it.penable = (vif.acb.penable === 1'b1); it.pwrite = vif.acb.pwrite;
                    it.paddr = vif.acb.paddr; it.pwdata = vif.acb.pwdata;
                    it.prdata = vif.acb.prdata; it.pready = vif.acb.pready; it.pslverr = vif.acb.pslverr;
                    it.div_busy = vif.acb.div_busy; it.div_act = vif.acb.div_act; it.div_sel = vif.acb.div_sel;
                    it.hreset_n = (vif.acb.hreset_n === 1'b1); it.preset_n = (vif.acb.preset_n === 1'b1);
                    it.core_rst_n = (vif.acb.core_rst_n === 1'b1); it.dm_rst_n = (vif.acb.dm_rst_n === 1'b1);
                    it.ilock = vif.acb.ilock; it.phase = vif.acb.phase;
                    ap.write(it);
                end
                forever begin
                    crg_cycle_item it;
                    @(negedge vif.ext_rst_n);
                    it = crg_cycle_item::type_id::create("it"); it.ext_event = 1;
                    ap.write(it);
                end
            join
        endtask
    endclass

    // ------------------------------------------------------------------ reference model
    class crg_ref_model extends uvm_object;
        `uvm_object_utils(crg_ref_model)
        bit [3:0] reason;        // {SW, NDM, WDT, EXT}
        bit       bootfail;
        bit [1:0] divsel;
        bit       ilock;
        // what the last step saw, for coverage
        bit       ev_wdt, ev_sw, ev_ndm, ev_bf; bit [4:0] ev_w1c;

        function new(string name = "crg_ref_model"); super.new(name); ext(); endfunction

        // the reset pin: the only thing that touches the cause register and DIVSEL from outside ([N-6.1], [N-6.5])
        function void ext();
            reason = 4'b0001; bootfail = 0; divsel = 0; ilock = 0;
        endfunction

        function bit mapped(bit [11:0] a); return a inside {12'h000, 12'h004, 12'h008, 12'h020}; endfunction

        function bit [31:0] rd(bit [11:0] a, crg_cycle_item it, bit bsel);
            case (a)
                12'h000: return {27'd0, bootfail, reason};
                12'h004: return {22'd0, divsel, 8'd0};                       // SWRST and bit 4 read 0
                12'h008: return {23'd0, bsel, 5'd0, it.div_busy, it.div_act};
                12'h020: return {31'd0, ilock};
                default: return 32'd0;
            endcase
        endfunction

        // one edge of the always-on clock, from the values sampled just before it
        function void step(crg_cycle_item it);
            bit wr = it.psel && it.penable && it.pwrite;
            ev_sw  = wr && it.paddr == 12'h004 && it.pwdata[0];
            // How software sets BOOTFAIL is not in the specification: RSTCTL bit 4 (from the RTL)
            ev_bf  = wr && it.paddr == 12'h004 && it.pwdata[4];
            ev_w1c = (wr && it.paddr == 12'h000) ? it.pwdata[4:0] : 5'd0;
            ev_wdt = it.wdt_req; ev_ndm = it.ndm_req;
            // A new cause replaces the old ones. Two in the same cycle: the specification does not
            // say; the RTL takes the watchdog, then software, then the debugger - in every cycle a
            // request is up, so of two that overlap the one that ends last is recorded (CRG-3).
            if      (ev_wdt) reason = 4'b0010;
            else if (ev_sw)  reason = 4'b1000;
            else if (ev_ndm) reason = 4'b0100;
            else             reason = reason & ~ev_w1c[3:0];
            if      (ev_bf)     bootfail = 1'b1;
            else if (ev_w1c[4]) bootfail = 1'b0;
            if (!it.preset_n) ilock = 1'b0;                                  // sticky until a reset
        endfunction
    endclass

    // ------------------------------------------------------------------ coverage
    class crg_coverage extends uvm_component;
        `uvm_component_utils(crg_coverage)

        covergroup cg_rst_apb with function sample(int kind, bit wr);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins RSTREASON = {0}; bins RSTCTL = {1}; bins CLKSTAT = {2}; bins MEMCTL = {3}; }
            cp_rw: coverpoint wr { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins next_after_clkstat = {10}; bins before_memctl = {11}; bins after_memctl = {12};
                                           bins far = {13}; bins unaligned = {14}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
        endgroup

        covergroup cg_rst_reason with function sample(int kind, int v);
            option.per_instance = 1;
            cp_cause: coverpoint v iff (kind == 0) { bins ext = {0}; bins wdt = {1}; bins ndm = {2}; bins sw = {3}; bins bootfail_by_software = {4};
                                                    bins second_cause_before_a_clear = {5}; }
            cp_clear: coverpoint v iff (kind == 1) { bins ext = {0}; bins wdt = {1}; bins ndm = {2}; bins sw = {3}; bins bootfail = {4};
                                                    bins clear_in_the_cycle_of_a_new_cause = {5}; }
        endgroup

        covergroup cg_div with function sample(int kind, int a, int b);
            option.per_instance = 1;
            cp_ratio: coverpoint a iff (kind == 0) { bins div2 = {0}; bins div4 = {1}; bins div8 = {2}; bins div16 = {3}; }
            cp_from: coverpoint a iff (kind == 1) { bins r[] = {[0:3]}; }
            cp_to:   coverpoint b iff (kind == 1) { bins r[] = {[0:3]}; }
            cp_transition: cross cp_from, cp_to { ignore_bins same = (binsof(cp_from) intersect {0} && binsof(cp_to) intersect {0}) ||
                                                                      (binsof(cp_from) intersect {1} && binsof(cp_to) intersect {1}) ||
                                                                      (binsof(cp_from) intersect {2} && binsof(cp_to) intersect {2}) ||
                                                                      (binsof(cp_from) intersect {3} && binsof(cp_to) intersect {3}); }
            // Where in the dividers' count of 16 the new value was written, from the fastest
            // ratio. A write lands on a pclk edge, and pclk edges fall on fixed values of the
            // two fast dividers, so what can vary is the quarter of the count (the two slow
            // dividers) and which way round pclk is against the second divider. Measured over
            // 320 random changes: the count is always xx00 or, after some sequences, xx10.
            cp_write_phase: coverpoint a iff (kind == 2) { bins quarter[] = {[0:3]}; }
            cp_write_pclk_phase: coverpoint b iff (kind == 2) { bins second_divider_low = {0}; bins second_divider_high = {1}; }
            cp_write_while_busy: coverpoint a iff (kind == 3) { bins second_value_while_pending = {1}; }
            cp_in_reset: coverpoint a iff (kind == 4) { bins ratio_other_than_2_during_a_reset = {1}; }
        endgroup

        covergroup cg_rst with function sample(int kind, int a, int b);
            option.per_instance = 1;
            cp_source: coverpoint a iff (kind == 0) { bins ext = {0}; bins wdt = {1}; bins ndm = {2}; bins sw = {3}; bins hart = {4}; }
            cp_src: coverpoint a iff (kind == 1) { bins ext = {0}; bins wdt = {1}; bins ndm = {2}; }
            cp_len: coverpoint b iff (kind == 1) { bins one_cycle = {0}; bins a_few = {1}; bins longer_than_the_stretch = {2}; }
            x_source_length: cross cp_src, cp_len;
            cp_request_during_reset: coverpoint a iff (kind == 2) { bins same_source = {0}; bins other_source = {1}; }
            cp_ext_width: coverpoint a iff (kind == 3) { bins shorter_than_a_reference_cycle = {0}; bins with_no_reference_clock = {1}; }
            cp_hartreset_with: coverpoint a iff (kind == 4) { bins alone = {0}; bins held_across_another_reset = {1}; bins released_during_another_reset = {2}; }
            cp_simultaneous: coverpoint a iff (kind == 5) { bins wdt_and_sw = {0}; bins wdt_and_ndm = {1}; bins sw_and_ndm = {2}; bins all_three = {3}; }
            cp_scope: coverpoint a iff (kind == 6) { bins debug_module_reset = {0}; bins debug_module_kept = {1}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_rst_apb = new(); cg_rst_reason = new(); cg_div = new(); cg_rst = new();
        endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_cyc)

    class crg_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(crg_scoreboard)
        uvm_analysis_imp_apb #(apb_item, crg_scoreboard)       apb_imp;
        uvm_analysis_imp_cyc #(crg_cycle_item, crg_scoreboard) cyc_imp;
        virtual crg_if vif;
        crg_ref_model  model;
        crg_coverage   cov;
        int unsigned n_cyc, n_rd, n_acc, n_err, n_resets, n_hart;
        int unsigned bsel_stable; bit bsel_prev; bit [1:0] sel_prev, act_prev; bit cause_pending; bit hreset_prev;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this); cyc_imp = new("cyc_imp", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual crg_if)::get(this, "", "cvif", vif)) `uvm_fatal("NOVIF", "crg_scoreboard: no virtual interface")
        endfunction

        function void err(string id, string msg);
            n_err++;
            if (n_err <= 20) `uvm_error(id, msg)
        endfunction

        function void write_cyc(crg_cycle_item it);
            bit [31:0] exp, mask; bit acc; string id;
            if (it.ext_event) begin
                cov.cg_rst_reason.sample(0, 0); cov.cg_rst.sample(0, 0, 0);
                model.ext(); cause_pending = 0; bsel_stable = 0;
                return;
            end
            n_cyc++;
            acc = it.psel && it.penable;
            bsel_stable = (it.boot_sel == bsel_prev) ? bsel_stable + 1 : 0; bsel_prev = it.boot_sel;
            // ---- the bus response, in every cycle of the access phase
            if (acc && it.preset_n) begin
                n_acc++;
                if (it.pslverr !== !model.mapped(it.paddr))
                    err("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, model %0b", it.pwrite ? "write" : "read", it.paddr, it.pslverr, !model.mapped(it.paddr)));
                if (it.pready !== 1'b1) err("sb_pready", "PREADY low");
                if (!it.pwrite) begin
                    n_rd++;
                    exp  = model.rd(it.paddr, it, it.boot_sel);
                    mask = (it.paddr == 12'h008 && bsel_stable < 80) ? 32'hFFFF_FEFF : 32'hFFFF_FFFF;   // the pin passes two pclk flops
                    if ((it.prdata & mask) !== (exp & mask)) begin
                        id = (it.paddr == 12'h000) ? "sb_reason" : (it.paddr == 12'h008) ? "sb_clkstat" : "sb_reg";
                        err(id, $sformatf("read 0x%03h: DUT %08h, model %08h", it.paddr, it.prdata, exp));
                    end
                end
            end
            // ---- DIVSEL and the lock on their pins (not in a cycle in which a write may be landing)
            if (!it.psel && it.div_sel !== model.divsel) err("sb_reg", $sformatf("div_sel pins %0d, model %0d", it.div_sel, model.divsel));
            if (!it.psel && it.preset_n && it.ilock !== model.ilock) err("sb_reg", $sformatf("ilock pin %0b, model %0b", it.ilock, model.ilock));
            // ---- coverage of what this cycle is
            cov.cg_div.sample(0, it.div_act, 0);
            if (it.div_act != act_prev) cov.cg_div.sample(1, act_prev, it.div_act);
            if (it.div_sel != sel_prev) begin
                if (act_prev == 0 && sel_prev == 0) begin
                    cov.cg_div.sample(2, it.phase[3:2], it.phase[1]);
                    `uvm_info("PHASE", $sformatf("DIVSEL changed at divider count %04b", it.phase), UVM_HIGH)
                end
                if (it.div_busy && sel_prev != act_prev) cov.cg_div.sample(3, 1, 0);
            end
            if (!it.hreset_n && it.div_act != 0) cov.cg_div.sample(4, 1, 0);
            sel_prev = it.div_sel; act_prev = it.div_act;
            model.step(it);
            // ---- causes
            if (model.ev_wdt || model.ev_sw || model.ev_ndm) begin
                int s = model.ev_wdt ? 1 : model.ev_sw ? 3 : 2;
                if (it.hreset_n) begin cov.cg_rst_reason.sample(0, s); cov.cg_rst.sample(0, s, 0); end
                if (model.ev_wdt + model.ev_sw + model.ev_ndm > 1)
                    cov.cg_rst.sample(5, (model.ev_wdt && model.ev_sw && model.ev_ndm) ? 3 : (model.ev_wdt && model.ev_sw) ? 0 : (model.ev_wdt && model.ev_ndm) ? 1 : 2, 0);
                if (cause_pending && it.hreset_n) cov.cg_rst_reason.sample(0, 5);
                if (model.ev_w1c != 0) cov.cg_rst_reason.sample(1, 5);
                cause_pending = 1;
            end
            if (model.ev_bf) cov.cg_rst_reason.sample(0, 4);
            if (model.ev_w1c != 0) begin
                if ($countones(model.ev_w1c) == 1) for (int b = 0; b < 5; b++) if (model.ev_w1c[b]) cov.cg_rst_reason.sample(1, b);
                if ((model.ev_w1c[3:0] & 4'b1110) != 0) cause_pending = 0;
            end
        endfunction

        function void write_apb(apb_item it);
            int kind;
            case (it.addr)
                12'h000: kind = 0; 12'h004: kind = 1; 12'h008: kind = 2; 12'h020: kind = 3;
                12'h00C: kind = 10; 12'h01C: kind = 11; 12'h024: kind = 12;
                default: kind = (it.addr[1:0] != 0) ? 14 : 13;
            endcase
            cov.cg_rst_apb.sample(kind, it.write);
            // a write that completed: DIVSEL is every completed write to RSTCTL; the lock is set by a 1
            if (it.write && it.addr == 12'h004) model.divsel = it.wdata[9:8];
            if (it.write && it.addr == 12'h020 && it.wdata[0]) model.ilock = 1'b1;
        endfunction

        // sb_reset: every reset measured on the pins, in reference clock cycles.
        //   [N-7.7]  the system reset lasts at least 1024 reference cycles after the last request
        //   [N-7.11] to [N-7.13]  the Debug Module is reset only by the pin, the watchdog or
        //            software; hartreset resets the core alone and is not stretched
        task run_phase(uvm_phase phase);
            bit in_rst, in_hart, req, dm_low, hart_seen, other_seen;
            bit [3:0] srcs, first, now; int unsigned n_after, n_hart_low, w_wdt, w_ndm, cyc, seen_at[4]; bit wdt_p, ndm_p;
            // the pin: its width in time, and whether the reference clock was running
            fork forever begin
                realtime t0; bit no_clk;
                @(negedge vif.ext_rst_n); t0 = $realtime; no_clk = !vif.refclk_en;
                seen_at[0] = cyc + 1;                       // the pin needs no clock edge to be a source
                @(posedge vif.ext_rst_n);
                if ($realtime - t0 < 2.0) cov.cg_rst.sample(3, 0, 0);
                if (no_clk) cov.cg_rst.sample(3, 1, 0);
                cov.cg_rst.sample(1, 0, ($realtime - t0 <= 4.0) ? 0 : ($realtime - t0 > 2.0 * 2 * STRETCH_REF) ? 2 : 1);
            end join_none
            forever begin
                @(posedge vif.refclk);
                req = (vif.ext_rst_n !== 1'b1) || vif.wdt_req || vif.ndm_req ||
                      (vif.psel === 1'b1 && vif.penable === 1'b1 && vif.pwrite && vif.paddr == 12'h004 && vif.pwdata[0]);
                // request widths, in hclk-independent reference cycles
                if (vif.wdt_req) w_wdt++; else begin if (wdt_p) cov.cg_rst.sample(1, 1, (w_wdt <= 2 * (1 << vif.div_act)) ? 0 : (w_wdt > 2 * STRETCH_REF) ? 2 : 1); w_wdt = 0; end
                if (vif.ndm_req) w_ndm++; else begin if (ndm_p) cov.cg_rst.sample(1, 2, (w_ndm <= 2 * (1 << vif.div_act)) ? 0 : (w_ndm > 2 * STRETCH_REF) ? 2 : 1); w_ndm = 0; end
                wdt_p = vif.wdt_req; ndm_p = vif.ndm_req;
                cyc++;
                now = {vif.psel === 1'b1 && vif.penable === 1'b1 && vif.pwrite && vif.paddr == 12'h004 && vif.pwdata[0],
                       vif.ndm_req, vif.wdt_req, vif.ext_rst_n !== 1'b1};
                for (int b = 0; b < 4; b++) if (now[b]) seen_at[b] = cyc;
                if (vif.hreset_n !== 1'b1) begin
                    if (!in_rst) begin
                        in_rst = 1; srcs = 0; first = 0; dm_low = 0; n_after = 0; hart_seen = vif.hart_req;
                        // the request that started this reset may already be over: a one-cycle pulse is
                        for (int b = 0; b < 4; b++) if (seen_at[b] != 0 && cyc + 1 - seen_at[b] <= 81) begin srcs[b] = 1; first[b] = 1; end
                    end
                    if (now != 0 && first == 0) first = now;
                    else if (now != 0 && n_after > 8) cov.cg_rst.sample(2, ((now & ~first) != 0) ? 1 : 0, 0);
                    srcs |= now;
                    if (seen_at[0] == cyc + 1 || seen_at[0] == cyc) srcs[0] = 1;
                    if (vif.dm_rst_n !== 1'b1) dm_low = 1;
                    if (vif.hart_req && !hart_seen) hart_seen = 1;
                    n_after = req ? 0 : n_after + 1;
                end else if (in_rst) begin
                    in_rst = 0; n_resets++;
                    if (n_after < STRETCH_REF)
                        err("sb_reset", $sformatf("hreset_n rose %0d reference cycles after the last request; at least %0d are required", n_after, STRETCH_REF));
                    if (dm_low && (srcs & 4'b1011) == 0)
                        err("sb_reset", $sformatf("the Debug Module was reset by a reset whose sources were %04b (software, debugger, watchdog, pin)", srcs));
                    if (!dm_low && (srcs & 4'b1011) != 0)
                        err("sb_reset", $sformatf("the Debug Module was not reset by sources %04b", srcs));
                    cov.cg_rst.sample(6, dm_low ? 0 : 1, 0);
                    if (hart_seen) cov.cg_rst.sample(4, vif.hart_req ? 1 : 2, 0);
                end
                // the core held alone
                if (vif.hreset_n === 1'b1 && vif.core_rst_n !== 1'b1) begin
                    if (!in_hart) begin in_hart = 1; n_hart_low = 0; other_seen = 0; end
                    if (!vif.hart_req) n_hart_low++; else n_hart_low = 0;
                    if (n_hart_low == 200) err("sb_reset", "core_rst_n still low 200 reference cycles after hartreset was withdrawn, with no system reset");
                end else if (in_hart) begin
                    in_hart = 0;
                    if (vif.hreset_n === 1'b1) begin n_hart++; cov.cg_rst.sample(0, 4, 0); cov.cg_rst.sample(4, 0, 0); end
                end
            end
        endtask

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("crg_scoreboard: %0d always-on cycles, %0d access cycles (%0d reads) compared; %0d system resets and %0d core-only resets measured; %0d mismatches",
                                      n_cyc, n_acc, n_rd, n_resets, n_hart, n_err), UVM_NONE)
            if (n_cyc == 0 || n_acc == 0) `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class crg_env extends uvm_env;
        `uvm_component_utils(crg_env)
        apb_agent       apb;
        crg_monitor     mon;
        crg_scoreboard  sb;
        crg_coverage    cov;
        crg             regmodel;
        apb_reg_adapter adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb = apb_agent::type_id::create("apb", this);
            mon = crg_monitor::type_id::create("mon", this);
            sb  = crg_scoreboard::type_id::create("sb", this);
            cov = crg_coverage::type_id::create("cov", this);
            sb.model = crg_ref_model::type_id::create("model");
            sb.cov = cov;
            regmodel = new("regmodel");
            regmodel.build();
            regmodel.lock_model();
            regmodel.reset();
            adapter   = apb_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(apb_item)::type_id::create("predictor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            mon.ap.connect(sb.cyc_imp);
            apb.mon.ap.connect(sb.apb_imp);
            regmodel.default_map.set_sequencer(apb.sqr, adapter);
            regmodel.default_map.set_auto_predict(0);
            predictor.map = regmodel.default_map; predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
        endfunction
    endclass

    `include "crg_test_lib.svh"
endpackage
