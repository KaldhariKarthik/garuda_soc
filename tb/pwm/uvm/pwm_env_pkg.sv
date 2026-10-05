`timescale 1ns/1ps
// =============================================================================
// pwm_env_pkg.sv - UVM environment for block 20, the PWM.
//
// Plan: tb/pwm/GARUDA_PWM_vplan.csv. Names of checks and covergroups are the
// names in the plan.
//
//   pwm_monitor     one item per pclk cycle: reset, the APB pins, the four pins
//                   and the interrupt
//   pwm_ref_model   written from GARUDA-PWM-SPEC-001 sections 6 and 7 and
//                   DECISIONS.md D-21; stepped once per pclk; never looks at
//                   the RTL
//   pwm_scoreboard  every cycle the four pins and the interrupt (sb_pin,
//                   sb_irq); every read (sb_status, sb_reg); every access
//                   (sb_pslverr, sb_pready); and, measured on the pins alone,
//                   the high time and the length of every undisturbed frame
//                   against DUTY x (PRESCALE + 1) and PERIOD x (PRESCALE + 1)
//                   (sb_pulse, sb_no_runt, sb_no_stuck_high)
//   pwm_coverage    the plan's covergroups
// =============================================================================
package pwm_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import pwm_reg_pkg::*;

    localparam bit [31:0] PWM_ID = 32'h6A5D_1401;

    // ------------------------------------------------------------------ monitor
    class pwm_cycle_item extends uvm_sequence_item;
        bit preset_n;
        bit psel, penable, pwrite; bit [11:0] paddr; bit [31:0] pwdata;
        bit [3:0] pwm; bit irq;
        logic [31:0] prdata; logic pready, pslverr;
        `uvm_object_utils(pwm_cycle_item)
        function new(string name = "pwm_cycle_item"); super.new(name); endfunction
    endclass

    class pwm_monitor extends uvm_monitor;
        `uvm_component_utils(pwm_monitor)
        virtual pwm_if vif;
        uvm_analysis_port #(pwm_cycle_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual pwm_if)::get(this, "", "pvif", vif))
                `uvm_fatal("NOVIF", "pwm_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            pwm_cycle_item it;
            forever begin
                @(vif.cb);
                it = pwm_cycle_item::type_id::create("it");
                it.preset_n = (vif.cb.preset_n === 1'b1);
                it.psel = vif.cb.psel; it.penable = vif.cb.penable; it.pwrite = vif.cb.pwrite;
                it.paddr = vif.cb.paddr; it.pwdata = vif.cb.pwdata;
                it.pwm = vif.cb.pwm; it.irq = vif.cb.irq;
                it.prdata = vif.cb.prdata; it.pready = vif.cb.pready; it.pslverr = vif.cb.pslverr;
                ap.write(it);
            end
        endtask
    endclass

    // ------------------------------------------------------------------ reference model
    class pwm_ref_model extends uvm_object;
        `uvm_object_utils(pwm_ref_model)
        // registers (PWM section 6)
        bit [15:0] prescale, period, duty[4];
        bit        en; bit [3:0] ch_en;
        // the shim registers (D-21)
        bit [1:0]  irqstat, irqen, dmactl;
        // time base and double buffer (PWM section 7)
        bit [15:0] pre, cnt, duty_s[4];
        bit [3:0]  clamp;
        // what the last step did, for the scoreboard and the coverage
        bit        ev_wr, ev_wrap, ev_load; bit [11:0] ev_addr; bit [31:0] ev_wdata;
        bit [1:0]  ev_evt, ev_clr;

        function new(string name = "pwm_ref_model"); super.new(name); reset(); endfunction

        function void reset();
            prescale = 0; period = 0; en = 0; ch_en = 0; irqstat = 0; irqen = 0; dmactl = 0;
            pre = 0; cnt = 0; clamp = 0;
            foreach (duty[i]) begin duty[i] = 0; duty_s[i] = 0; end
            ev_wr = 0; ev_wrap = 0; ev_load = 0; ev_evt = 0; ev_clr = 0;
        endfunction

        function void copy_state(pwm_ref_model o);
            prescale = o.prescale; period = o.period; en = o.en; ch_en = o.ch_en;
            irqstat = o.irqstat; irqen = o.irqen; dmactl = o.dmactl; pre = o.pre; cnt = o.cnt; clamp = o.clamp;
            foreach (duty[i]) begin duty[i] = o.duty[i]; duty_s[i] = o.duty_s[i]; end
        endfunction

        // the register map: eight word registers at 0x00 to 0x1C and the four shim registers
        function bit mapped(bit [11:0] a);
            return (a[1:0] == 2'b00) && ((a < 12'h020) || (a >= 12'hFE0 && a <= 12'hFEC));
        endfunction

        function bit [3:0] pins();
            bit [3:0] p;
            for (int c = 0; c < 4; c++) p[c] = en && ch_en[c] && (cnt < duty_s[c]);   // low beats everything
            return p;
        endfunction
        function bit irq(); return |(irqstat & irqen); endfunction

        function bit [31:0] rd(bit [11:0] a);
            if (!mapped(a)) return 32'd0;
            case (a)
                12'h000: return {16'd0, prescale};
                12'h004: return {16'd0, period};
                12'h008: return {24'd0, ch_en, 3'd0, en};
                12'h00C: return {12'd0, clamp, cnt};
                12'h010, 12'h014, 12'h018, 12'h01C: return {16'd0, duty[a[3:2]]};
                12'hFE0: return {30'd0, irqstat};
                12'hFE4: return {30'd0, irqen};
                12'hFE8: return {30'd0, dmactl};
                default: return PWM_ID;
            endcase
        endfunction

        // one pclk edge, from the values sampled just before it
        function void step(pwm_cycle_item it);
            bit tick, at_end, wrap, wr;
            if (!it.preset_n) begin reset(); return; end
            wr     = it.psel && it.penable && it.pwrite && mapped(it.paddr);
            tick   = en && (pre >= prescale);                      // one tick is PRESCALE + 1 cycles; never longer if PRESCALE is lowered
            at_end = ({1'b0, cnt} + 17'd1) >= {1'b0, period};        // the frame is PERIOD ticks
            wrap   = tick && at_end;
            ev_wr = wr; ev_addr = it.paddr; ev_wdata = it.pwdata; ev_wrap = wrap; ev_load = wrap || !en;
            ev_evt = {|clamp, wrap};
            ev_clr = (wr && it.paddr == 12'hFE0) ? it.pwdata[1:0] : 2'b00;
            irqstat = (irqstat & ~ev_clr) | ev_evt;                  // sticky; an event beats its own clear

            // double buffer: loaded at the boundary, and continuously while stopped
            if (ev_load) for (int c = 0; c < 4; c++) begin
                clamp[c]  = (duty[c] > period);
                duty_s[c] = clamp[c] ? period : duty[c];
            end
            if (!en)       begin pre = 0; cnt = 0; end
            else if (tick) begin pre = 0; cnt = at_end ? 16'd0 : cnt + 16'd1; end
            else           pre = pre + 16'd1;

            if (wr) case (it.paddr)
                12'h000: prescale = it.pwdata[15:0];
                12'h004: period   = it.pwdata[15:0];
                12'h008: begin en = it.pwdata[0]; ch_en = it.pwdata[7:4]; end
                12'h010, 12'h014, 12'h018, 12'h01C: duty[it.paddr[3:2]] = it.pwdata[15:0];
                12'hFE4: irqen  = it.pwdata[1:0];
                12'hFE8: dmactl = it.pwdata[1:0];
                default: ;                                           // STATUS and ID are read-only; IRQSTAT handled above
            endcase
        endfunction
    endclass

    // ------------------------------------------------------------------ coverage
    class pwm_coverage extends uvm_component;
        `uvm_component_utils(pwm_coverage)
        int unsigned cyc, cyc_wrap = 0;
        int          seq_next = 0; bit seq_split;

        covergroup cg_pwm_apb with function sample(int kind, bit wr);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins PRESCALE = {0}; bins PERIOD = {1}; bins CTRL = {2}; bins STATUS = {3};
                                      bins DUTY0 = {4}; bins DUTY1 = {5}; bins DUTY2 = {6}; bins DUTY3 = {7};
                                      bins IRQSTAT = {8}; bins IRQEN = {9}; bins DMACTL = {10}; bins ID = {11}; }
            cp_rw: coverpoint wr { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins between_ip_and_tail = {20}; bins first_past_ip = {21}; bins last_before_tail = {22};
                                           bins above_tail = {23}; bins unaligned_tail = {24};
                                           bins alias_of_ip_register = {25}; bins alias_of_shim_register = {26}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
        endgroup

        covergroup cg_pwm_ctrl with function sample(bit en, bit [3:0] ch);
            option.per_instance = 1;
            cp_en: coverpoint en; cp_ch: coverpoint ch;
            x_en_chen: cross cp_en, cp_ch;
        endgroup

        covergroup cg_pwm_cfg with function sample(int kind, int ps, int pe, int du);
            option.per_instance = 1;
            cp_prescale: coverpoint ps iff (kind == 0) { bins zero = {0}; bins one = {1}; bins mid = {2}; bins max = {3}; }
            cp_period:   coverpoint pe iff (kind == 0) { bins one = {1}; bins two = {2}; bins mid = {3}; bins max = {4}; }
            cp_duty:     coverpoint du iff (kind == 0) { bins zero = {0}; bins one = {1}; bins mid = {2}; bins period_minus_1 = {3}; bins period = {4}; }
            // a frame of 0xFFFF ticks of 0x10000 cycles is 4e9 cycles: the two maxima are covered separately
            x_prescale_period_duty: cross cp_prescale, cp_period, cp_duty {
                ignore_bins both_max = binsof(cp_prescale.max) && binsof(cp_period.max);
                // with PERIOD 1 a duty is 0 or 1; with PERIOD 2 it is 0, 1 or 2
                // (a duty equal to PERIOD is counted as "period", and a duty of 1 as "one")
                ignore_bins p1 = binsof(cp_period.one) && (binsof(cp_duty.one) || binsof(cp_duty.mid) || binsof(cp_duty.period_minus_1));
                ignore_bins p2 = binsof(cp_period.two) && (binsof(cp_duty.mid) || binsof(cp_duty.period_minus_1));
            }
            cp_period_corner: coverpoint pe iff (kind == 1) { bins zero = {0}; bins one = {1}; bins fffe = {16'hFFFE}; bins ffff = {16'hFFFF}; }
            cp_change_running: coverpoint pe iff (kind == 2) { bins period_below_counter = {0}; bins period_lowered = {1}; bins period_raised = {2};
                                                              bins prescale_changed = {3}; }
        endgroup

        covergroup cg_pwm_ch with function sample(int order, int equal);
            option.per_instance = 1;
            cp_duty_order: coverpoint order iff (equal == 0) { bins perm[] = {[0:23]}; }
            cp_equal: coverpoint equal iff (equal != 0) { bins two_equal = {2}; bins three_equal = {3}; bins four_equal = {4}; }
        endgroup

        covergroup cg_pwm_dbuf with function sample(int when, int dir, int split);
            option.per_instance = 1;
            cp_when: coverpoint when iff (split == 0) { bins pin_high = {0}; bins pin_low = {1}; bins boundary_cycle = {2};
                                                        bins cycle_before_boundary = {3}; bins cycle_after_boundary = {4}; }
            cp_dir: coverpoint dir iff (split == 0) { bins shorter = {0}; bins longer = {1}; }
            x_when_old_new: cross cp_when, cp_dir;
            cp_split_update: coverpoint split iff (split != 0) { bins boundary_inside_four_writes = {1}; }
        endgroup

        covergroup cg_pwm_stop with function sample(int kind);
            option.per_instance = 1;
            cp_stop_phase: coverpoint kind { bins en_cleared_while_high = {0}; bins en_cleared_while_low = {1}; bins en_cleared_at_boundary = {2};
                                             bins ch0_cleared_while_high = {4}; bins ch1_cleared_while_high = {5};
                                             bins ch2_cleared_while_high = {6}; bins ch3_cleared_while_high = {7}; }
            cp_restart: coverpoint kind { bins enabled_again = {8}; }
        endgroup

        covergroup cg_pwm_clamp with function sample(int ch, int amount, int together);
            option.per_instance = 1;
            cp_ch: coverpoint ch iff (together == 0) { bins c[] = {[0:3]}; }
            cp_amount: coverpoint amount iff (together == 0) { bins period_plus_1 = {0}; bins ffff = {1}; bins other = {2}; }
            x_ch_amount: cross cp_ch, cp_amount;
            cp_together: coverpoint together iff (together != 0) { bins one = {1}; bins two = {2}; bins three = {3}; bins four = {4}; }
            cp_self_clear: coverpoint amount iff (together == -1) { bins flag_cleared_at_next_boundary = {0}; }
        endgroup

        covergroup cg_pwm_irq with function sample(int src, bit en, bit clr_same_cycle);
            option.per_instance = 1;
            cp_src: coverpoint src { bins boundary = {0}; bins clamped = {1}; }
            cp_en: coverpoint en;
            x_src_en: cross cp_src, cp_en;
            cp_clear_in_event_cycle: coverpoint src iff (clr_same_cycle) { bins boundary = {0}; bins clamped = {1}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_pwm_apb = new(); cg_pwm_ctrl = new(); cg_pwm_cfg = new(); cg_pwm_ch = new();
            cg_pwm_dbuf = new(); cg_pwm_stop = new(); cg_pwm_clamp = new(); cg_pwm_irq = new();
        endfunction

        function int cls16(bit [15:0] v);     // 0, 1, mid, 0xFFFF
            return (v == 0) ? 0 : (v == 1) ? 1 : (v == 16'hFFFF) ? 3 : 2;
        endfunction

        // pre: the state the cycle started from; m: after the step (its ev_* describe the cycle)
        function void sample_cycle(pwm_cycle_item it, pwm_ref_model pre, pwm_ref_model m);
            bit [3:0] pins = pre.pins(); bit [31:0] d = m.ev_wdata; int n, c;
            cyc++;
            if (!it.preset_n) begin seq_next = 0; return; end
            // ---- events and their enables
            for (int s = 0; s < 2; s++) if (m.ev_evt[s]) cg_pwm_irq.sample(s, pre.irqen[s], m.ev_clr[s]);
            // ---- a frame starts: what it runs with
            if (m.ev_wrap) begin
                if (seq_next > 0 && seq_next < 4) seq_split = 1;
                for (c = 0; c < 4; c++) if (pre.ch_en[c]) begin
                    int pe = (pre.period == 1) ? 1 : (pre.period == 2) ? 2 : (pre.period == 16'hFFFF) ? 4 : 3;
                    int du = (m.duty_s[c] == 0) ? 0 : (m.duty_s[c] == pre.period) ? 4 : (m.duty_s[c] == 1) ? 1
                             : (m.duty_s[c] == pre.period - 1) ? 3 : 2;
                    if (pre.period != 0) cg_pwm_cfg.sample(0, cls16(pre.prescale), pe, du);
                end
                cg_pwm_cfg.sample(1, 0, pre.period, 0);
                if (pre.ch_en == 4'hF && pre.period != 0) begin
                    int eq = 1, best = 1; bit [15:0] v[4];
                    foreach (v[i]) v[i] = m.duty_s[i];
                    for (int i = 0; i < 4; i++) begin eq = 0; for (int j = 0; j < 4; j++) if (v[j] == v[i]) eq++; if (eq > best) best = eq; end
                    if (best > 1) cg_pwm_ch.sample(0, best);
                    else begin
                        // rank of the ordering: for each channel, how many later channels are smaller (Lehmer code)
                        int rank = 0, f[4] = '{6, 2, 1, 1};
                        for (int i = 0; i < 4; i++) begin n = 0; for (int j = i + 1; j < 4; j++) if (v[j] < v[i]) n++; rank += n * f[i]; end
                        cg_pwm_ch.sample(rank, 0);
                    end
                end
                n = 0;
                for (c = 0; c < 4; c++) if (m.clamp[c]) begin
                    n++;
                    cg_pwm_clamp.sample(c, (pre.duty[c] == pre.period + 1) ? 0 : (pre.duty[c] == 16'hFFFF) ? 1 : 2, 0);
                end else if (pre.clamp[c]) cg_pwm_clamp.sample(0, 0, -1);
                if (n != 0) cg_pwm_clamp.sample(0, 0, n);
                cyc_wrap = cyc;
            end
            // ---- writes
            if (m.ev_wr) case (m.ev_addr)
                12'h000: if (pre.en && d[15:0] != pre.prescale) cg_pwm_cfg.sample(2, 0, 3, 0);
                12'h004: if (pre.en) begin
                             if (d[15:0] != 0 && d[15:0] <= pre.cnt) cg_pwm_cfg.sample(2, 0, 0, 0);
                             else if (d[15:0] < pre.period)          cg_pwm_cfg.sample(2, 0, 1, 0);
                             else if (d[15:0] > pre.period)          cg_pwm_cfg.sample(2, 0, 2, 0);
                         end
                12'h008: begin
                    cg_pwm_ctrl.sample(d[0], d[7:4]);
                    if (pre.en && !d[0]) cg_pwm_stop.sample(m.ev_wrap ? 2 : (pins != 0) ? 0 : 1);
                    if (!pre.en && d[0]) cg_pwm_stop.sample(8);
                    for (c = 0; c < 4; c++) if (pre.en && d[0] && pre.ch_en[c] && !d[4 + c] && pins[c]) cg_pwm_stop.sample(4 + c);
                end
                12'h010, 12'h014, 12'h018, 12'h01C: begin
                    c = m.ev_addr[3:2];
                    if (pre.en && pre.ch_en[c] && d[15:0] != pre.duty[c] && pre.period > 3) begin
                        int when = m.ev_wrap ? 2 : (pre.pre >= pre.prescale && ({1'b0, pre.cnt} + 17'd2 >= {1'b0, pre.period}) && !m.ev_wrap) ? 3
                                   : (cyc - cyc_wrap == 1) ? 4 : pins[c] ? 0 : 1;
                        cg_pwm_dbuf.sample(when, d[15:0] > pre.duty[c], 0);
                    end
                    // four duty writes in order, with a boundary somewhere between the first and the last
                    if (c == 0) begin seq_next = 1; seq_split = 0; end
                    else if (c == seq_next) begin
                        seq_next++;
                        if (seq_next == 4) begin if (seq_split && pre.en) cg_pwm_dbuf.sample(0, 0, 1); seq_next = 0; end
                    end else seq_next = 0;
                end
                default: ;
            endcase
        endfunction

        function void apb_access(apb_item it, bit mapped);
            int kind;
            if (mapped) kind = (it.addr < 12'h020) ? it.addr[4:2] : 8 + it.addr[3:2];
            else if (it.addr[1:0] != 2'b00) kind = (it.addr >= 12'hFE0) ? 24 : -1;
            else if (it.addr == 12'h020) kind = 21;
            else if (it.addr[11:5] != 0 && $countones(it.addr[11:5]) == 1) kind = 25;          // 0x00-0x1C with one upper bit set
            else if ($countones(~it.addr[11:5]) == 1 && it.addr[4] == 1'b0) kind = 26;         // 0xFE0-0xFEC with one upper bit clear
            else if (it.addr == 12'hFDC) kind = 22;
            else if (it.addr >= 12'hFF0) kind = 23;
            else kind = 20;
            cg_pwm_apb.sample(kind, it.write);
        endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_cyc)

    class pwm_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(pwm_scoreboard)
        uvm_analysis_imp_apb #(apb_item, pwm_scoreboard)       apb_imp;
        uvm_analysis_imp_cyc #(pwm_cycle_item, pwm_scoreboard) cyc_imp;
        pwm_ref_model model, pre;
        pwm_coverage  cov;
        int unsigned n_cyc, n_rd, n_wr, n_err, n_frames, n_pulses;
        // measured on the pins: the frame in progress
        bit          f_valid, f_clean, start_prev, disturb_prev;
        int unsigned f_len, f_high[4];
        bit [15:0]   f_prescale, f_period, f_duty[4]; bit [3:0] f_chen;
        // measured on the pins: the pulse in progress (since the frame started) and the whole high time
        int unsigned run_len[4], run_exp[4], hi_total[4], hi_bound[4]; bit run_clean[4], hi_full[4]; bit [3:0] pin_prev;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this); cyc_imp = new("cyc_imp", this);
            pre = pwm_ref_model::type_id::create("pre");
        endfunction

        function void err(string id, string msg);
            n_err++;
            if (n_err <= 20) `uvm_error(id, msg)
        endfunction

        // every pclk cycle: pins, interrupt and (in the last cycle of an access) the
        // bus response against the model's state in that cycle; then step the model
        function void write_cyc(pwm_cycle_item it);
            bit [3:0] exp_pins; bit exp_irq, m;
            n_cyc++;
            exp_pins = it.preset_n ? model.pins() : 4'h0;
            exp_irq  = it.preset_n ? model.irq()  : 1'b0;
            if (it.pwm !== exp_pins) err("sb_pin", $sformatf("pins %04b, model %04b (cnt=%0d period=%0d en=%0b ch_en=%04b)",
                                                             it.pwm, exp_pins, model.cnt, model.period, model.en, model.ch_en));
            if (it.irq !== exp_irq)  err("sb_irq", $sformatf("irq %0b, model %0b (IRQSTAT=%02b IRQEN=%02b)", it.irq, exp_irq, model.irqstat, model.irqen));
            if (it.preset_n && it.pready !== 1'b1) err("sb_pready", "PREADY low");
            if (it.preset_n && it.psel && it.penable) begin
                m = model.mapped(it.paddr);
                if (it.pwrite) n_wr++;
                else begin
                    n_rd++;
                    if (it.prdata !== model.rd(it.paddr))
                        err((it.paddr == 12'h00C) ? "sb_status" : "sb_reg",
                            $sformatf("read 0x%03h: DUT %08h, model %08h", it.paddr, it.prdata, model.rd(it.paddr)));
                end
                if (it.pslverr !== !m)
                    err("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, model %0b", it.pwrite ? "write" : "read", it.paddr, it.pslverr, !m));
            end
            pre.copy_state(model);
            model.step(it);
            cov.sample_cycle(it, pre, model);
            measure(it);
        endfunction

        // The waveform as the specification states it, measured on the pins. In a
        // frame nothing disturbed, each enabled pin is high for exactly
        // DUTY x (PRESCALE + 1) cycles (DUTY clamped to PERIOD) of a frame of
        // PERIOD x (PRESCALE + 1) cycles, and a pulse that starts with a frame is
        // exactly that long. Frames are delimited by the model's period boundary.
        function void measure(pwm_cycle_item it);
            bit disturb;
            if (!it.preset_n) begin
                f_valid = 0; pin_prev = 0; start_prev = 0;
                foreach (run_len[c]) begin run_len[c] = 0; hi_total[c] = 0; end
                return;
            end
            // a write to PRESCALE, PERIOD or CTRL, or a stop, makes the frame and the pulses in progress unmeasurable
            disturb = !pre.en || (model.ev_wr && (model.ev_addr inside {12'h000, 12'h004, 12'h008}));
            if (f_valid) begin
                f_len++;
                for (int c = 0; c < 4; c++) if (it.pwm[c]) f_high[c]++;
                if (disturb) f_clean = 0;
            end
            for (int c = 0; c < 4; c++) begin
                if (it.pwm[c]) begin
                    // sb_no_runt: a pulse is measured from the start of its frame
                    // (a frame whose first cycle follows a write to PRESCALE, PERIOD or CTRL is not measured)
                    if (start_prev)        begin run_len[c] = 0; run_clean[c] = !disturb_prev; run_exp[c] = pre.duty_s[c] * (pre.prescale + 1); end
                    else if (!pin_prev[c]) begin run_len[c] = 0; run_clean[c] = 0; end     // rose in mid-frame: an enable did it
                    run_len[c]++;
                    if (disturb) run_clean[c] = 0;
                    // sb_no_stuck_high: the whole continuous high time, whatever was written meanwhile
                    if (!pin_prev[c]) begin hi_total[c] = 0; hi_bound[c] = 0; hi_full[c] = 0; end
                    hi_total[c]++;
                    if (pre.duty_s[c] >= pre.period) hi_full[c] = 1;                        // 100 percent: high across frames by design
                    if (pre.period * (pre.prescale + 1) > hi_bound[c]) hi_bound[c] = pre.period * (pre.prescale + 1);
                    if (!hi_full[c] && hi_total[c] == 2 * hi_bound[c] + 3)
                        err("sb_no_stuck_high", $sformatf("channel %0d high for %0d cycles with a duty below the period; the longest frame was %0d (now PERIOD %0d PRESCALE %0d cnt %0d prescaler %0d shadow %0d)",
                                                          c, hi_total[c], hi_bound[c], pre.period, pre.prescale, pre.cnt, pre.pre, pre.duty_s[c]));
                end else if (pin_prev[c] && run_clean[c] && !disturb && pre.ch_en[c]) begin
                    n_pulses++;
                    if (run_len[c] != run_exp[c])
                        err("sb_no_runt", $sformatf("channel %0d pulse of %0d cycles; the duty it started with makes %0d (now PERIOD %0d PRESCALE %0d cnt %0d shadow %0d)",
                                                    c, run_len[c], run_exp[c], pre.period, pre.prescale, pre.cnt, pre.duty_s[c]));
                end
            end
            pin_prev = it.pwm;
            if (model.ev_wrap) begin
                if (f_valid && f_clean) begin
                    n_frames++;
                    if (f_len != ((f_period == 0) ? 1 : f_period) * (f_prescale + 1))
                        err("sb_pulse", $sformatf("frame of %0d cycles, PERIOD %0d x (PRESCALE %0d + 1)", f_len, f_period, f_prescale));
                    for (int c = 0; c < 4; c++)
                        if (f_high[c] != (f_chen[c] ? f_duty[c] * (f_prescale + 1) : 0))
                            err("sb_pulse", $sformatf("channel %0d high for %0d cycles in the frame, DUTY %0d x (PRESCALE %0d + 1)",
                                                      c, f_high[c], f_duty[c], f_prescale));
                end
                f_valid = 1; f_clean = !disturb; f_len = 0;
                f_prescale = model.prescale; f_period = model.period; f_chen = model.ch_en;
                for (int c = 0; c < 4; c++) begin
                    f_high[c] = 0;
                    f_duty[c] = (pre.duty[c] > pre.period) ? pre.period : pre.duty[c];   // DUTY as written, clamped (PWM 7.4)
                end
            end
            if (!model.en) f_valid = 0;
            // the next cycle is the first of a frame: after a boundary, or after the write that set EN
            start_prev = model.ev_wrap || (!pre.en && model.en);
            disturb_prev = disturb && pre.en;                  // the write that sets EN starts a clean frame
        endfunction

        function void write_apb(apb_item it);
            cov.apb_access(it, model.mapped(it.addr));
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("pwm_scoreboard: %0d cycles, %0d reads, %0d writes compared; %0d frames and %0d pulses measured; %0d mismatches",
                                      n_cyc, n_rd, n_wr, n_frames, n_pulses, n_err), UVM_NONE)
            if (n_cyc == 0 || (n_rd + n_wr) == 0) `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class pwm_env extends uvm_env;
        `uvm_component_utils(pwm_env)
        apb_agent       apb;
        pwm_monitor     mon;
        pwm_scoreboard  sb;
        pwm_coverage    cov;
        pwm             regmodel;
        apb_reg_adapter adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb = apb_agent::type_id::create("apb", this);
            mon = pwm_monitor::type_id::create("mon", this);
            sb  = pwm_scoreboard::type_id::create("sb", this);
            cov = pwm_coverage::type_id::create("cov", this);
            sb.model = pwm_ref_model::type_id::create("model");
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

    `include "pwm_seq_lib.svh"
    `include "pwm_test_lib.svh"
endpackage
