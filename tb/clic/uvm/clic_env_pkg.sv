`timescale 1ns/1ps
`include "garuda_map.vh"
// =============================================================================
// clic_env_pkg.sv - UVM environment for block 10, the CLIC.
//
// Plan: tb/clic/GARUDA_CLIC_vplan.csv. Names of checks and covergroups below
// are the names in the plan.
//
//   clic_src_agent   drives the 32 source lines and the reset
//   clic_monitor     samples sources and outputs in the middle of every hclk
//                    cycle, when both are stable
//   clic_ref_model   written from GARUDA-CLIC-SPEC-001 section 6 and 7 and the
//                    ID map; it never looks at the RTL
//   clic_scoreboard  sb_sel (outputs every cycle), sb_ie / sb_cfg / sb_ip
//                    (every read), sb_pslverr (every access)
//   clic_coverage    the plan's covergroups
// =============================================================================
package clic_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import clic_reg_pkg::*;

    localparam bit [31:0] ID_MASK = `GARUDA_CLIC_ID_MASK;   // every ID that has a source

    function automatic bit is_assigned(int n); return ID_MASK[n]; endfunction

    // ------------------------------------------------------------------ source agent
    class clic_src_item extends uvm_sequence_item;
        rand bit [31:0]   src;
        rand int unsigned hold;       // hclk cycles this pattern is held
        rand bit          do_reset;   // pulse the reset before driving
        constraint c_hold  { hold inside {[1:6]}; }
        constraint c_reset { soft do_reset == 0; }
        `uvm_object_utils(clic_src_item)
        function new(string name = "clic_src_item"); super.new(name); endfunction
    endclass

    typedef uvm_sequencer #(clic_src_item) clic_src_sequencer;

    class clic_src_driver extends uvm_driver #(clic_src_item);
        `uvm_component_utils(clic_src_driver)
        virtual clic_src_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual clic_src_if)::get(this, "", "svif", vif))
                `uvm_fatal("NOVIF", "clic_src_driver: no virtual interface")
        endfunction
        task reset_pulse(int unsigned cycles);
            vif.rst_n <= 1'b0;
            repeat (cycles) @(posedge vif.hclk);
            vif.rst_n <= 1'b1;
            repeat (2) @(posedge vif.hclk);
        endtask
        task run_phase(uvm_phase phase);
            vif.irq_src <= 32'd0;
            reset_pulse(5);
            forever begin
                seq_item_port.get_next_item(req);
                if (req.do_reset) reset_pulse(3);
                @(posedge vif.hclk);
                vif.irq_src <= req.src;
                repeat (req.hold - 1) @(posedge vif.hclk);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ------------------------------------------------------------------ monitor
    class clic_out_item extends uvm_sequence_item;
        bit        in_reset;
        bit [31:0] src;
        bit        valid;
        bit [4:0]  id;
        bit [7:0]  level;
        `uvm_object_utils(clic_out_item)
        function new(string name = "clic_out_item"); super.new(name); endfunction
    endclass

    class clic_monitor extends uvm_monitor;
        `uvm_component_utils(clic_monitor)
        virtual clic_src_if vif;
        uvm_analysis_port #(clic_out_item) ap;
        function new(string name, uvm_component parent);
            super.new(name, parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual clic_src_if)::get(this, "", "svif", vif))
                `uvm_fatal("NOVIF", "clic_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            clic_out_item it;
            forever begin
                @(negedge vif.hclk);
                it = clic_out_item::type_id::create("it");
                it.in_reset = (vif.rst_n !== 1'b1);
                it.src   = vif.irq_src;
                it.valid = vif.valid;
                it.id    = vif.id;
                it.level = vif.level;
                ap.write(it);
            end
        endtask
    endclass

    class clic_src_agent extends uvm_agent;
        `uvm_component_utils(clic_src_agent)
        clic_src_sequencer sqr;
        clic_src_driver    drv;
        clic_monitor       mon;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = clic_src_sequencer::type_id::create("sqr", this);
            drv = clic_src_driver::type_id::create("drv", this);
            mon = clic_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ------------------------------------------------------------------ reference model
    // From the specification only: section 6 (registers), 7.1 (pending), 7.3
    // (selection), 7.5 (ID 0) and the ID map.
    class clic_ref_model extends uvm_object;
        `uvm_object_utils(clic_ref_model)
        bit [31:0] ie;
        bit [7:0]  lvl [32];
        function new(string name = "clic_ref_model"); super.new(name); reset(); endfunction

        function void reset();
            ie = 32'd0;
            foreach (lvl[i]) lvl[i] = 8'd0;
        endfunction

        function bit mapped(bit [11:0] a);
            return (a == 12'h000) || (a == 12'h004) || (a == 12'h008) ||
                   (a >= 12'h100 && a <= 12'h17C && a[1:0] == 2'b00);
        endfunction

        function bit is_cfg(bit [11:0] a);
            return (a >= 12'h100 && a <= 12'h17C && a[1:0] == 2'b00);
        endfunction

        // returns 1 if the access must raise PSLVERR
        function bit write(bit [11:0] a, bit [31:0] d);
            if (!mapped(a)) return 1;
            if (a == 12'h004)     ie = d & ID_MASK;
            else if (is_cfg(a))   lvl[(a - 12'h100) >> 2] = d[7:0];
            return 0;                                   // CLICINFO, CLICIP: ignored, no error
        endfunction

        function bit read(bit [11:0] a, bit [31:0] src, output bit [31:0] d);
            d = 32'd0;
            if (!mapped(a)) return 1;
            if      (a == 12'h000) d = {7'd0, 4'd8, 8'd1, 13'd32};
            else if (a == 12'h004) d = ie;
            else if (a == 12'h008) d = src;
            else                   d = {24'd0, lvl[(a - 12'h100) >> 2]};
            return 0;
        endfunction

        // highest level among enabled pending IDs; lowest ID on a tie
        function void select(bit [31:0] src, output bit v, output bit [4:0] wid, output bit [7:0] wl);
            v = 0; wid = 0; wl = 0;
            for (int n = 0; n < 32; n++)
                if (src[n] && ie[n] && (!v || lvl[n] > wl)) begin v = 1; wid = n; wl = lvl[n]; end
        endfunction

        function int ncand(bit [31:0] src); return $countones(src & ie); endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_out)

    class clic_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(clic_scoreboard)
        uvm_analysis_imp_apb #(apb_item, clic_scoreboard)      apb_imp;
        uvm_analysis_imp_out #(clic_out_item, clic_scoreboard) out_imp;
        clic_ref_model model;
        bit [31:0] cur_src;
        int unsigned n_sel, n_rd, n_wr, n_err, n_resets;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this);
            out_imp = new("out_imp", this);
        endfunction

        // sb_sel: the outputs against the model, in the middle of every cycle
        function void write_out(clic_out_item it);
            bit v; bit [4:0] wid; bit [7:0] wl;
            if (it.in_reset) begin
                model.reset(); cur_src = it.src;
                if (it.valid !== 1'b0) begin n_err++; `uvm_error("sb_sel", "valid high in reset") end
                return;
            end
            cur_src = it.src;
            model.select(it.src, v, wid, wl);
            n_sel++;
            if (it.valid !== v || it.id !== wid || it.level !== wl) begin
                n_err++;
                `uvm_error("sb_sel", $sformatf("src=%08h ie=%08h: DUT {valid=%0b id=%0d level=%0d}, model {%0b %0d %0d}",
                                               it.src, model.ie, it.valid, it.id, it.level, v, wid, wl))
            end
        endfunction

        // sb_ie, sb_cfg, sb_ip, sb_pslverr: every completed APB access
        function void write_apb(apb_item it);
            bit err; bit [31:0] exp;
            if (it.write) begin
                err = model.write(it.addr, it.wdata);
                n_wr++;
            end else begin
                err = model.read(it.addr, cur_src, exp);
                n_rd++;
                if (!err && it.rdata !== exp) begin
                    n_err++;
                    `uvm_error("sb_reg", $sformatf("read 0x%03h: DUT %08h, model %08h", it.addr, it.rdata, exp))
                end
                if (err && it.rdata !== 32'd0) begin
                    n_err++;
                    `uvm_error("sb_reg", $sformatf("read of unmapped 0x%03h returned %08h, expected 0", it.addr, it.rdata))
                end
            end
            if (it.slverr !== err) begin
                n_err++;
                `uvm_error("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, model %0b",
                                                   it.write ? "write" : "read", it.addr, it.slverr, err))
            end
            if (it.waits != 0) begin
                n_err++;
                `uvm_error("sb_pready", $sformatf("access to 0x%03h waited %0d pclk", it.addr, it.waits))
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("clic_scoreboard: %0d output samples, %0d reads, %0d writes compared; %0d mismatches",
                                      n_sel, n_rd, n_wr, n_err), UVM_NONE)
            if (n_sel == 0 || (n_rd + n_wr) == 0)
                `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ coverage
    class clic_coverage extends uvm_component;
        `uvm_component_utils(clic_coverage)
        uvm_analysis_imp_apb #(apb_item, clic_coverage)      apb_imp;
        uvm_analysis_imp_out #(clic_out_item, clic_coverage) out_imp;
        clic_ref_model model;                   // read only: shared with the scoreboard

        // state kept between samples
        bit [31:0] prev_src; bit prev_valid; bit prev_in_reset = 1;
        int unsigned run_len [32];
        bit [31:0] ie_before;
        bit        apb_this_cycle, cfg_write_this_cycle;

        // -------- register access
        covergroup cg_clic_apb with function sample(int kind, bit wr, int nsrc);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins CLICINFO = {0}; bins CLICIE = {1}; bins CLICIP = {2}; bins CLICINTCFG = {3}; }
            cp_rw:  coverpoint wr   { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins low = {4}; bins high = {5}; bins unaligned = {6}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
            cp_ip_read: coverpoint nsrc iff (kind == 2 && !wr) { bins none = {0}; bins one = {1}; bins several = {[2:31]}; bins all = {32}; }
        endgroup

        covergroup cg_clic_ie with function sample(int kind, int idx);
            option.per_instance = 1;
            cp_set:   coverpoint idx iff (kind == 0) { bins id[] = {[1:6], [8:22]}; }
            cp_clear: coverpoint idx iff (kind == 1) { bins id[] = {[1:6], [8:22]}; }
            cp_reserved_write: coverpoint idx iff (kind == 2) { bins id[] = {0, 7, [23:31]}; }
        endgroup

        covergroup cg_clic_cfg with function sample(int n, bit [7:0] l, bit unassigned_live);
            option.per_instance = 1;
            cp_n: coverpoint n { bins id[] = {[0:31]}; }
            cp_level: coverpoint l { bins zero = {0}; bins one = {1}; bins mid = {[2:254]}; bins max = {255}; }
            x_n_level: cross cp_n, cp_level;
            cp_unassigned_level: coverpoint n iff (unassigned_live) { bins id[] = {0, 7, [23:31]}; }
        endgroup

        covergroup cg_clic_src with function sample(int kind, int idx, int len);
            option.per_instance = 1;
            cp_pulse_id:  coverpoint idx iff (kind == 0) { bins id[] = {[1:6], [8:22]}; }
            cp_pulse_len: coverpoint len iff (kind == 0) { bins one = {1}; bins two = {2}; bins held = {[3:$]}; }
            cp_pulse: cross cp_pulse_id, cp_pulse_len;
            cp_src0_high: coverpoint len iff (kind == 1) { bins alone = {0}; bins with_others = {1}; }
            cp_reserved_high: coverpoint idx iff (kind == 2) { bins id[] = {7, [23:31]}; }
        endgroup

        covergroup cg_clic_sel with function sample(bit [4:0] w, int ncand, bit [7:0] wl, bit tie_next, int tie_size);
            option.per_instance = 1;
            cp_winner: coverpoint w { bins id[] = {[1:6], [8:22]}; }
            cp_ncand:  coverpoint ncand { bins one = {1}; bins two = {2}; bins few = {[3:5]}; bins many = {[6:20]}; bins all = {21}; }
            cp_win_level: coverpoint wl { bins zero = {0}; bins one = {1}; bins mid = {[2:254]}; bins max = {255}; }
            cp_tie_pair: coverpoint w iff (tie_next) { bins lower_of_pair[] = {[1:6], [8:21]}; }
            cp_tie_size: coverpoint tie_size { bins two = {2}; bins three = {3}; bins more = {[4:$]}; }
        endgroup

        covergroup cg_clic_dyn with function sample(int kind);
            option.per_instance = 1;
            cp_level_move: coverpoint kind { bins winner_lowered = {0}; bins loser_raised = {1}; }
            cp_ie_move: coverpoint kind { bins winner_disabled_alone = {2}; bins winner_disabled_one_other = {3};
                                          bins winner_disabled_several = {4}; bins higher_enabled = {5}; }
            cp_coincident: coverpoint kind { bins write_with_src_rise = {6}; bins write_with_src_fall = {7}; }
        endgroup

        covergroup cg_clic_rst with function sample(int kind);
            option.per_instance = 1;
            cp_reset_with_sources: coverpoint kind { bins sources_high = {0}; bins after_traffic = {1}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this);
            out_imp = new("out_imp", this);
            cg_clic_apb = new(); cg_clic_ie = new(); cg_clic_cfg = new();
            cg_clic_src = new(); cg_clic_sel = new(); cg_clic_dyn = new(); cg_clic_rst = new();
        endfunction

        function int next_assigned(int n);
            for (int k = n + 1; k < 32; k++) if (is_assigned(k)) return k;
            return -1;
        endfunction

        // The APB monitor reports at the pclk edge that ends the access; the model
        // has not yet applied it when this is called (the scoreboard is connected
        // after the coverage collector), so "before" values are still in the model.
        function void write_apb(apb_item it);
            int kind; bit v0, v1; bit [4:0] w0, w1; bit [7:0] l0, l1;
            bit [31:0] ie_new; bit [7:0] lvl_new; int n;
            if      (it.addr == 12'h000) kind = 0;
            else if (it.addr == 12'h004) kind = 1;
            else if (it.addr == 12'h008) kind = 2;
            else if (model.is_cfg(it.addr)) kind = 3;
            else if (it.addr >= 12'h100 && it.addr <= 12'h17F) kind = 6;     // unaligned inside the level array
            else if (it.addr < 12'h100) kind = 4;
            else kind = 5;
            cg_clic_apb.sample(kind, it.write, $countones(prev_src));
            apb_this_cycle = 1;
            if (!it.write) return;

            model.select(prev_src, v0, w0, l0);
            if (kind == 1) begin
                ie_new = it.wdata & ID_MASK;
                for (int b = 0; b < 32; b++) begin
                    if (is_assigned(b)) begin
                        if (it.wdata[b] && !model.ie[b]) cg_clic_ie.sample(0, b);
                        if (!it.wdata[b] && model.ie[b]) cg_clic_ie.sample(1, b);
                    end else if (it.wdata[b]) cg_clic_ie.sample(2, b);
                end
                // what does this write do to the selection?
                if (v0 && !ie_new[w0]) begin
                    int others = $countones(prev_src & ie_new);
                    cg_clic_dyn.sample(others == 0 ? 2 : (others == 1 ? 3 : 4));
                end
                for (int b = 0; b < 32; b++)
                    if (v0 && prev_src[b] && ie_new[b] && !model.ie[b] && model.lvl[b] > l0) cg_clic_dyn.sample(5);
                cfg_write_this_cycle = 1;
            end
            if (kind == 3) begin
                n = (it.addr - 12'h100) >> 2; lvl_new = it.wdata[7:0];
                cg_clic_cfg.sample(n, lvl_new, !is_assigned(n) && prev_src[n] && lvl_new != 0);
                if (v0 && n == w0 && lvl_new < l0) begin
                    for (int b = 0; b < 32; b++)
                        if (b != n && prev_src[b] && model.ie[b] && model.lvl[b] > lvl_new) begin cg_clic_dyn.sample(0); break; end
                end
                if (v0 && n != w0 && prev_src[n] && model.ie[n] && lvl_new > l0) cg_clic_dyn.sample(1);
                cfg_write_this_cycle = 1;
            end
        endfunction

        function void write_out(clic_out_item it);
            bit v; bit [4:0] w; bit [7:0] wl; int nc, ts; bit tie_next; int nx;
            if (it.in_reset) begin
                if (!prev_in_reset) cg_clic_rst.sample(|prev_src ? 0 : 1);
                if (!prev_in_reset && apb_this_cycle) cg_clic_rst.sample(1);
                prev_in_reset = 1; prev_src = it.src; foreach (run_len[i]) run_len[i] = 0;
                apb_this_cycle = 0; cfg_write_this_cycle = 0;
                return;
            end
            // a register write that completed in the cycle a source changed
            if (cfg_write_this_cycle && !prev_in_reset) begin
                if (|(it.src & ~prev_src)) cg_clic_dyn.sample(6);
                if (|(~it.src & prev_src)) cg_clic_dyn.sample(7);
            end
            // pulse lengths per source line
            for (int b = 0; b < 32; b++) begin
                if (it.src[b]) run_len[b]++;
                else if (run_len[b] != 0) begin
                    if (is_assigned(b)) cg_clic_src.sample(0, b, run_len[b]);
                    run_len[b] = 0;
                end
                if (it.src[b] && !is_assigned(b) && b != 0) cg_clic_src.sample(2, b, 0);
            end
            if (it.src[0]) cg_clic_src.sample(1, 0, |it.src[31:1]);
            // selection
            model.select(it.src, v, w, wl);
            if (v) begin
                nc = model.ncand(it.src); ts = 0;
                for (int b = 0; b < 32; b++) if (it.src[b] && model.ie[b] && model.lvl[b] == wl) ts++;
                nx = next_assigned(w);
                tie_next = (nx >= 0) && it.src[nx] && model.ie[nx] && (model.lvl[nx] == wl);
                cg_clic_sel.sample(w, nc, wl, tie_next, ts);
            end
            prev_src = it.src; prev_valid = v; prev_in_reset = 0;
            apb_this_cycle = 0; cfg_write_this_cycle = 0;
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class clic_env extends uvm_env;
        `uvm_component_utils(clic_env)
        apb_agent        apb;
        clic_src_agent   src;
        clic_scoreboard  sb;
        clic_coverage    cov;
        clic_ref_model   model;
        clic             regmodel;
        apb_reg_adapter  adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb   = apb_agent::type_id::create("apb", this);
            src   = clic_src_agent::type_id::create("src", this);
            sb    = clic_scoreboard::type_id::create("sb", this);
            cov   = clic_coverage::type_id::create("cov", this);
            model = clic_ref_model::type_id::create("model");
            sb.model = model; cov.model = model;
            regmodel = new("regmodel");
            regmodel.build();
            regmodel.lock_model();
            regmodel.reset();
            adapter   = apb_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(apb_item)::type_id::create("predictor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // coverage first: it needs the model's state from before each write
            apb.mon.ap.connect(cov.apb_imp);
            apb.mon.ap.connect(sb.apb_imp);
            src.mon.ap.connect(sb.out_imp);
            src.mon.ap.connect(cov.out_imp);
            regmodel.default_map.set_sequencer(apb.sqr, adapter);
            regmodel.default_map.set_auto_predict(0);
            predictor.map     = regmodel.default_map;
            predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
        endfunction
    endclass

    `include "clic_seq_lib.svh"
    `include "clic_test_lib.svh"
endpackage
