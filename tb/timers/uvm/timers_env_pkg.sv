`timescale 1ns/1ps
// =============================================================================
// timers_env_pkg.sv - UVM environment for block 11, timers and watchdog.
//
// Plan: tb/timers/GARUDA_TIMERS_vplan.csv. Names of checks and covergroups are
// the names in the plan.
//
//   tmr_monitor     one item per hclk cycle: resets, the APB pins, the outputs
//   tmr_ref_model   written from GARUDA-TIMERS-SPEC-001 sections 6, 7 and
//                   decisions D-16, D-17; stepped once per hclk; never looks
//                   at the RTL
//   tmr_scoreboard  every read (sb_mtime, sb_wdtval, sb_reg), every access
//                   (sb_pslverr, sb_pready), and in every hclk cycle mtip, the
//                   warning and the reset request (sb_mtip, sb_warn, sb_req)
//   tmr_coverage    the plan's covergroups
// =============================================================================
package timers_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import timers_reg_pkg::*;

    localparam bit [31:0] KICK_MAGIC = 32'h5A5A_C3C3;

    // ------------------------------------------------------------------ monitor
    class tmr_cycle_item extends uvm_sequence_item;
        bit ext_rst_n, hreset_n, preset_n;
        bit psel, penable, pwrite; bit [11:0] paddr; bit [31:0] pwdata;
        bit mtip, warn, req;
        `uvm_object_utils(tmr_cycle_item)
        function new(string name = "tmr_cycle_item"); super.new(name); endfunction
    endclass

    class tmr_monitor extends uvm_monitor;
        `uvm_component_utils(tmr_monitor)
        virtual timers_if vif;
        uvm_analysis_port #(tmr_cycle_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual timers_if)::get(this, "", "tvif", vif))
                `uvm_fatal("NOVIF", "tmr_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            tmr_cycle_item it;
            forever begin
                @(vif.cb);
                it = tmr_cycle_item::type_id::create("it");
                it.ext_rst_n = (vif.cb.ext_rst_n === 1'b1); it.hreset_n = (vif.cb.hreset_n === 1'b1);
                it.preset_n  = (vif.cb.preset_n === 1'b1);
                it.psel = vif.cb.psel; it.penable = vif.cb.penable; it.pwrite = vif.cb.pwrite;
                it.paddr = vif.cb.paddr; it.pwdata = vif.cb.pwdata;
                it.mtip = vif.cb.mtip; it.warn = vif.cb.warn; it.req = vif.cb.req;
                ap.write(it);
            end
        endtask
    endclass

    // ------------------------------------------------------------------ reference model
    class tmr_ref_model extends uvm_object;
        `uvm_object_utils(tmr_ref_model)
        // architectural state
        bit [63:0] mtime, cmp;
        bit [31:0] shadow, lo_cap;
        bit        mtip;
        bit        en, warnen;
        bit [31:0] load, warn, ctr;
        bit        rst_req;
        // bus bookkeeping
        bit        acc_prev, setup_prev;
        int        setup_cnt;
        bit [31:0] prdata_exp;
        // what the last step did, for coverage
        bit        ev_wr, ev_rd, ev_kick, ev_carry, ev_wrap, ev_req_rise;
        int        ev_idx;
        bit [31:0] ev_wdata;

        function new(string name = "tmr_ref_model"); super.new(name); reset_h(); rst_req = 0; endfunction

        function void reset_h();
            mtime = 64'd0; cmp = {64{1'b1}}; shadow = 32'd0; lo_cap = 32'd0; mtip = 1'b0;
            en = 1'b0; warnen = 1'b0; load = 32'hFFFF_FFFF; warn = 32'd0; ctr = 32'hFFFF_FFFF;
            acc_prev = 0; setup_prev = 0; setup_cnt = 0;
        endfunction

        function bit mapped(bit [11:0] a); return (a[11:8] == 4'h0) && (a[1:0] == 2'b00) && (a[7:2] <= 6'd8); endfunction
        function bit read_only(bit [11:0] a); return mapped(a) && (a[7:2] == 6'd6); endfunction
        function bit warn_irq(); return en && warnen && (ctr <= warn); endfunction
        function void copy_state(tmr_ref_model o);
            mtime = o.mtime; cmp = o.cmp; shadow = o.shadow; lo_cap = o.lo_cap; mtip = o.mtip;
            en = o.en; warnen = o.warnen; load = o.load; warn = o.warn; ctr = o.ctr; rst_req = o.rst_req;
        endfunction

        function bit [31:0] rd_mux(int w);
            case (w)
                0: return lo_cap;
                1: return shadow;
                2: return cmp[31:0];
                3: return cmp[63:32];
                4: return {30'd0, warnen, en};
                5: return load;
                6: return ctr;
                8: return warn;
                default: return 32'd0;            // WDTKICK reads 0
            endcase
        endfunction

        // one hclk edge, from the values sampled just before it
        function void step(tmr_cycle_item it);
            bit acc, setup_rd, wr, rd, kick; int idx;
            bit [63:0] mtime_n; bit [31:0] ctr_n; bit rst_req_n;
            ev_wr = 0; ev_rd = 0; ev_kick = 0; ev_carry = 0; ev_wrap = 0; ev_req_rise = 0;
            if (!it.ext_rst_n) begin reset_h(); rst_req = 0; return; end
            if (!it.hreset_n)  begin reset_h(); rst_req = 0; return; end   // the request is cleared once the reset is in force

            // expected read data: registered at the pclk edge that ends the setup phase
            if (it.psel && !it.penable) begin
                setup_cnt++;
                if (setup_cnt == 2) prdata_exp = mapped(it.paddr) ? rd_mux(it.paddr[7:2]) : 32'd0;
            end else setup_cnt = 0;

            idx      = it.paddr[7:2];
            acc      = it.psel && it.penable && it.pwrite && mapped(it.paddr);
            setup_rd = it.psel && !it.penable && !it.pwrite && mapped(it.paddr);
            wr = acc && !acc_prev;                 // one strobe per write (D-16)
            rd = setup_rd && !setup_prev;
            acc_prev = acc; setup_prev = setup_rd;
            kick = wr && (idx == 7) && (it.pwdata == KICK_MAGIC);
            ev_wr = wr; ev_rd = rd; ev_idx = idx; ev_wdata = it.pwdata; ev_kick = kick;

            // ---- machine timer: next state from the current one
            if      (wr && idx == 0) mtime_n = {mtime[63:32], it.pwdata};
            else if (wr && idx == 1) mtime_n = {it.pwdata, mtime[31:0]};
            else begin
                mtime_n  = mtime + 64'd1;
                ev_carry = (mtime[31:0] == 32'hFFFF_FFFF);
                ev_wrap  = (mtime == {64{1'b1}});
            end
            mtip = (mtime >= cmp);
            if (rd && idx == 0) begin shadow = mtime[63:32]; lo_cap = mtime[31:0]; end
            if (wr && idx == 2) cmp[31:0]  = it.pwdata;
            if (wr && idx == 3) cmp[63:32] = it.pwdata;
            mtime = mtime_n;

            // ---- watchdog
            rst_req_n = rst_req | (en && ctr == 32'd0);
            ev_req_rise = rst_req_n && !rst_req;
            if      (!en)        ctr_n = load;
            else if (kick)       ctr_n = load;
            else if (ctr != 0)   ctr_n = ctr - 32'd1;
            else                 ctr_n = ctr;
            if (wr && idx == 4) begin if (it.pwdata[0]) en = 1'b1; warnen = it.pwdata[1]; end
            if (wr && idx == 5) load = it.pwdata;
            if (wr && idx == 8) warn = it.pwdata;
            ctr = ctr_n; rst_req = rst_req_n;
        endfunction
    endclass

    // ------------------------------------------------------------------ coverage
    class tmr_coverage extends uvm_component;
        `uvm_component_utils(tmr_coverage)
        int unsigned cyc, cyc_last_wr = 0, cyc_lo_rd = 0; int last_wr_idx = -1; bit lo_rd_seen, hi_pending;
        bit en_seen_before;

        covergroup cg_tmr_apb with function sample(int kind, bit wr, int b2b);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins MTIME_LO = {0}; bins MTIME_HI = {1}; bins MTIMECMP_LO = {2}; bins MTIMECMP_HI = {3};
                                      bins WDTCTL = {4}; bins WDTLOAD = {5}; bins WDTVAL = {6}; bins WDTKICK = {7}; bins WDTWARN = {8}; }
            cp_rw: coverpoint wr { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins above = {9}; bins unaligned = {10}; bins first_above = {11};
                                           bins alias_bit8 = {12}; bins alias_bit9 = {13}; bins alias_bit10 = {14}; bins alias_bit11 = {15}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
            cp_back_to_back: coverpoint b2b { bins same_reg = {1}; bins other_reg = {2}; }
        endgroup

        covergroup cg_wdt_ctl with function sample(bit [1:0] v, bit en_before);
            option.per_instance = 1;
            cp_v: coverpoint v; cp_en_before: coverpoint en_before;
            x_en_warnen: cross cp_v, cp_en_before;
        endgroup

        covergroup cg_wdt_kick with function sample(int kind, int bitpos);
            option.per_instance = 1;
            cp_value: coverpoint kind { bins magic = {0}; bins one_bit_off = {1}; bins zero = {2}; bins ones = {3}; bins other = {4}; }
            cp_neighbour: coverpoint bitpos iff (kind == 1) { bins b[] = {[0:31]}; }
        endgroup

        covergroup cg_mtime with function sample(int kind);
            option.per_instance = 1;
            cp_carry: coverpoint kind { bins low_word_carry = {0}; bins wrap_64 = {1}; }
            cp_write_half: coverpoint kind { bins lo = {2}; bins hi = {3}; bins hi_right_after_lo = {4}; }
            cp_carry_vs_read: coverpoint kind { bins carry_in_lo_read_cycle = {5}; bins carry_between_lo_and_hi = {6};
                                                bins no_carry_near_read = {7}; }
            cp_hi_alone: coverpoint kind { bins never_latched = {8}; bins stale = {9}; }
        endgroup

        covergroup cg_mtip with function sample(int rel, int decided_by);
            option.per_instance = 1;
            cp_compare: coverpoint rel { bins below = {0}; bins equal = {1}; bins one_above = {2}; bins far_above = {3}; }
            cp_decided_by: coverpoint decided_by { bins high_word = {0}; bins low_word = {1}; }
            x_cmp_half_value: coverpoint rel iff (decided_by >= 10) { bins lo_zero = {10}; bins lo_ones = {11}; bins lo_other = {12};
                                                                    bins hi_zero = {13}; bins hi_ones = {14}; bins hi_other = {15}; }
        endgroup

        covergroup cg_wdt with function sample(int kind, int v);
            option.per_instance = 1;
            cp_load_while_running: coverpoint v iff (kind == 0) { bins raised = {1}; bins lowered = {0}; }
            cp_warn_threshold: coverpoint v iff (kind == 1) { bins zero = {0}; bins one = {1}; bins mid = {2}; bins load_minus_1 = {3}; }
            cp_warn_ge_load: coverpoint v iff (kind == 2) { bins equal = {0}; bins above = {1}; }
            cp_kick_at: coverpoint v iff (kind == 3) { bins at_2 = {2}; bins at_1 = {1}; bins at_0 = {0}; bins earlier = {3}; }
            cp_load_zero: coverpoint v iff (kind == 4) { bins load_0 = {0}; bins load_1 = {1}; }
            cp_warnen_timing: coverpoint v iff (kind == 5) { bins set_before_crossing = {0}; bins set_after_crossing = {1}; bins cleared_while_warning = {2}; }
            cp_reset: coverpoint v iff (kind == 6) { bins request_seen = {0}; bins request_survived_hreset = {1}; bins ext_reset_with_request = {2}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_tmr_apb = new(); cg_wdt_ctl = new(); cg_wdt_kick = new(); cg_mtime = new(); cg_mtip = new(); cg_wdt = new();
        endfunction

        // called by the scoreboard before the model takes the step: m is the state
        // the cycle starts from
        function void pre_step(tmr_cycle_item it, tmr_ref_model m);
            int rel, by;
            cyc++;
            if (!it.ext_rst_n) begin if (m.rst_req) cg_wdt.sample(6, 2); return; end
            if (!it.hreset_n)  begin if (m.rst_req) cg_wdt.sample(6, 1); lo_rd_seen = 0; hi_pending = 0; return; end
            // compare relation, every cycle
            if (m.mtime < m.cmp) rel = 0; else if (m.mtime == m.cmp) rel = 1;
            else if (m.mtime == m.cmp + 64'd1) rel = 2; else rel = 3;
            by = (m.mtime[63:32] != m.cmp[63:32]) ? 0 : 1;
            cg_mtip.sample(rel, by);
        endfunction

        // called after the step: m holds the events of this cycle; pre is a copy of
        // the state before it
        function void post_step(tmr_cycle_item it, tmr_ref_model m, tmr_ref_model pre);
            int k, bp; bit [31:0] d;
            if (!it.ext_rst_n || !it.hreset_n) return;
            if (m.ev_req_rise) cg_wdt.sample(6, 0);
            if (m.ev_carry) begin
                cg_mtime.sample(0);
                if (m.ev_rd && m.ev_idx == 0) cg_mtime.sample(5);
                else if (hi_pending && (cyc - cyc_lo_rd) <= 16) cg_mtime.sample(6);
            end
            if (m.ev_wrap) cg_mtime.sample(1);
            if (m.ev_rd && m.ev_idx == 0) begin lo_rd_seen = 1; hi_pending = 1; cyc_lo_rd = cyc; end
            if (m.ev_rd && m.ev_idx == 1) begin
                if (!lo_rd_seen) cg_mtime.sample(8);
                else if (!hi_pending || (cyc - cyc_lo_rd) > 40) cg_mtime.sample(9);
                else cg_mtime.sample(7);
                hi_pending = 0;
            end
            if (m.ev_wr) begin
                d = m.ev_wdata;
                cg_tmr_apb.sample(-1, 1, (cyc - cyc_last_wr == 4) ? ((m.ev_idx == last_wr_idx) ? 1 : 2) : 0);
                case (m.ev_idx)
                    0: cg_mtime.sample(2);
                    1: begin cg_mtime.sample(3); if (last_wr_idx == 0 && (cyc - cyc_last_wr) <= 8) cg_mtime.sample(4); end
                    2: cg_mtip.sample(d == 0 ? 10 : (d == 32'hFFFF_FFFF ? 11 : 12), 10);
                    3: cg_mtip.sample(d == 0 ? 13 : (d == 32'hFFFF_FFFF ? 14 : 15), 13);
                    4: begin
                        cg_wdt_ctl.sample(d[1:0], pre.en);
                        if (d[0] && !pre.en && pre.load <= 1) cg_wdt.sample(4, pre.load);
                        if (d[1] && !pre.warnen) cg_wdt.sample(5, (pre.en && pre.ctr <= pre.warn) ? 1 : 0);
                        if (!d[1] && pre.warnen && pre.en && pre.ctr <= pre.warn) cg_wdt.sample(5, 2);
                    end
                    5: if (pre.en) cg_wdt.sample(0, d > pre.load);
                    7: begin
                        if (d == KICK_MAGIC) begin
                            k = 0;
                            if (pre.en) cg_wdt.sample(3, pre.ctr <= 2 ? pre.ctr : 3);
                        end else if ($countones(d ^ KICK_MAGIC) == 1) begin
                            k = 1; for (int b = 0; b < 32; b++) if ((d ^ KICK_MAGIC) == (32'd1 << b)) bp = b;
                        end else if (d == 0) k = 2; else if (d == 32'hFFFF_FFFF) k = 3; else k = 4;
                        cg_wdt_kick.sample(k, bp);
                    end
                    8: begin
                        if (d == 0) cg_wdt.sample(1, 0); else if (d == 1) cg_wdt.sample(1, 1);
                        else if (d == pre.load - 1) cg_wdt.sample(1, 3); else if (d < pre.load) cg_wdt.sample(1, 2);
                        if (d == pre.load) cg_wdt.sample(2, 0); else if (d > pre.load) cg_wdt.sample(2, 1);
                    end
                    default: ;
                endcase
                last_wr_idx = m.ev_idx; cyc_last_wr = cyc;
            end
        endfunction

        function void apb_access(apb_item it, bit mapped);
            int kind;
            if (mapped) kind = it.addr[7:2];
            else if (it.addr[1:0] != 2'b00) kind = 10;
            else if (it.addr == 12'h024) kind = 11;                                  // the first offset past the last register
            else if (it.addr[7:2] <= 6'd8 && $countones(it.addr[11:8]) == 1)         // a register's offset with one upper bit set
                kind = 12 + (it.addr[9] ? 1 : 0) + (it.addr[10] ? 2 : 0) + (it.addr[11] ? 3 : 0);
            else kind = 9;
            cg_tmr_apb.sample(kind, it.write, 0);
        endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_cyc)

    class tmr_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(tmr_scoreboard)
        uvm_analysis_imp_apb #(apb_item, tmr_scoreboard)       apb_imp;
        uvm_analysis_imp_cyc #(tmr_cycle_item, tmr_scoreboard) cyc_imp;
        tmr_ref_model model, pre;
        tmr_coverage  cov;
        int unsigned n_cyc, n_rd, n_wr, n_err, n_resets;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this); cyc_imp = new("cyc_imp", this);
            pre = tmr_ref_model::type_id::create("pre");
        endfunction

        function void err(string id, string msg);
            n_err++;
            if (n_err <= 20) `uvm_error(id, msg)
        endfunction

        // every hclk cycle: outputs against the model, then step the model
        function void write_cyc(tmr_cycle_item it);
            bit exp_mtip, exp_warn, exp_req;
            n_cyc++;
            if (!it.ext_rst_n)      begin exp_mtip = 0; exp_warn = 0; exp_req = 0; end
            else if (!it.hreset_n)  begin exp_mtip = 0; exp_warn = 0; exp_req = model.rst_req; if (model.rst_req) n_resets++; end
            else                    begin exp_mtip = model.mtip; exp_warn = model.warn_irq(); exp_req = model.rst_req; end
            if (it.mtip !== exp_mtip) err("sb_mtip", $sformatf("mtip %0b, model %0b (mtime=%h cmp=%h)", it.mtip, exp_mtip, model.mtime, model.cmp));
            if (it.warn !== exp_warn) err("sb_warn", $sformatf("warning %0b, model %0b (ctr=%0d warn=%0d en=%0b warnen=%0b)",
                                                               it.warn, exp_warn, model.ctr, model.warn, model.en, model.warnen));
            if (it.req  !== exp_req)  err("sb_req",  $sformatf("reset request %0b, model %0b (ctr=%0d en=%0b hreset_n=%0b)",
                                                               it.req, exp_req, model.ctr, model.en, it.hreset_n));
            cov.pre_step(it, model);
            pre.copy_state(model);
            model.step(it);
            cov.post_step(it, model, pre);
        endfunction

        // every completed access: read data and PSLVERR
        function void write_apb(apb_item it);
            bit m = model.mapped(it.addr);
            bit exp_err = !m || (it.write && model.read_only(it.addr));
            cov.apb_access(it, m);
            if (it.write) n_wr++;
            else begin
                n_rd++;
                if (it.rdata !== model.prdata_exp)
                    err((it.addr[7:3] == 5'd0 && m) ? "sb_mtime" : ((it.addr == 12'h018) ? "sb_wdtval" : "sb_reg"), $sformatf("read 0x%03h: DUT %08h, model %08h", it.addr, it.rdata, model.prdata_exp));
            end
            if (it.slverr !== exp_err) err("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, model %0b", it.write ? "write" : "read", it.addr, it.slverr, exp_err));
            if (it.waits != 0) err("sb_pready", $sformatf("access to 0x%03h waited %0d pclk", it.addr, it.waits));
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("tmr_scoreboard: %0d cycles, %0d reads, %0d writes compared; %0d watchdog resets seen; %0d mismatches",
                                      n_cyc, n_rd, n_wr, n_resets, n_err), UVM_NONE)
            if (n_cyc == 0 || (n_rd + n_wr) == 0) `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class timers_env extends uvm_env;
        `uvm_component_utils(timers_env)
        apb_agent       apb;
        tmr_monitor     mon;
        tmr_scoreboard  sb;
        tmr_coverage    cov;
        timers          regmodel;
        apb_reg_adapter adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb = apb_agent::type_id::create("apb", this);
            mon = tmr_monitor::type_id::create("mon", this);
            sb  = tmr_scoreboard::type_id::create("sb", this);
            cov = tmr_coverage::type_id::create("cov", this);
            sb.model = tmr_ref_model::type_id::create("model");
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

    `include "timers_seq_lib.svh"
    `include "timers_test_lib.svh"
endpackage
