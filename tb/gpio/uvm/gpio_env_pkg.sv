`timescale 1ns/1ps
// =============================================================================
// gpio_env_pkg.sv - UVM environment for block 19, the GPIO.
//
// Plan: tb/gpio/GARUDA_GPIO_vplan.csv. Names of checks and covergroups are the
// names in the plan.
//
//   gpio_pad_driver  the outside world: a level on each pad, held for a number
//                    of cycles, optionally overpowering the pin's own driver
//   gpio_monitor     one item per pclk cycle: reset, the APB pins and response,
//                    the pads, the two outputs with their enables, the interrupt
//   gpio_ref_model   written from GARUDA-GPIO-SPEC-001 sections 6 and 7 and
//                    DECISIONS.md D-21, stepped once per pclk. Where the
//                    specification is silent or the vendored block differs
//                    from it, the model follows the block and the line says
//                    which finding records it (Docs/BUGS.md GPIO-2).
//   gpio_scoreboard  every cycle the outputs and the interrupt (sb_pins,
//                    sb_irq); every access (sb_padin, sb_padout, sb_intstatus,
//                    sb_reg, sb_pslverr, sb_pready); and two checks that use
//                    only the pads, the registers and the pins, not the
//                    model's synchroniser: a settled pad is what PADIN reads
//                    (sb_padin_level), and an edge of the selected kind on an
//                    enabled pin raises the interrupt, and nothing else does
//                    (sb_event)
//   gpio_coverage    the plan's covergroups
// =============================================================================
package gpio_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import gpio_reg_pkg::*;

    localparam bit [31:0] GPIO_ID = 32'h6A5D_1301;

    // ------------------------------------------------------------------ pad agent
    class gpio_pad_item extends uvm_sequence_item;
        rand bit [1:0]    val, force_pad;
        rand int unsigned hold;
        constraint c_hold { hold inside {[1:40]}; }
        `uvm_object_utils(gpio_pad_item)
        function new(string name = "gpio_pad_item"); super.new(name); endfunction
    endclass

    class gpio_pad_driver extends uvm_driver #(gpio_pad_item);
        `uvm_component_utils(gpio_pad_driver)
        virtual gpio_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual gpio_if)::get(this, "", "gvif", vif)) `uvm_fatal("NOVIF", "gpio_pad_driver: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                seq_item_port.get_next_item(req);
                @(vif.drv_cb);
                vif.drv_cb.ext_val <= req.val; vif.drv_cb.ext_force <= req.force_pad;
                repeat (req.hold - 1) @(vif.drv_cb);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ------------------------------------------------------------------ monitor
    class gpio_cycle_item extends uvm_sequence_item;
        bit preset_n;
        bit psel, penable, pwrite; bit [11:0] paddr; bit [31:0] pwdata;
        logic [31:0] prdata; logic pready, pslverr;
        bit [1:0] pad, gpio_o, gpio_oe; bit irq;
        `uvm_object_utils(gpio_cycle_item)
        function new(string name = "gpio_cycle_item"); super.new(name); endfunction
    endclass

    class gpio_monitor extends uvm_monitor;
        `uvm_component_utils(gpio_monitor)
        virtual gpio_if vif;
        uvm_analysis_port #(gpio_cycle_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual gpio_if)::get(this, "", "gvif", vif)) `uvm_fatal("NOVIF", "gpio_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            gpio_cycle_item it;
            forever begin
                @(vif.cb);
                it = gpio_cycle_item::type_id::create("it");
                it.preset_n = (vif.cb.preset_n === 1'b1);
                it.psel = vif.cb.psel; it.penable = vif.cb.penable; it.pwrite = vif.cb.pwrite;
                it.paddr = vif.cb.paddr; it.pwdata = vif.cb.pwdata;
                it.prdata = vif.cb.prdata; it.pready = vif.cb.pready; it.pslverr = vif.cb.pslverr;
                it.pad = vif.cb.pad; it.gpio_o = vif.cb.gpio_o; it.gpio_oe = vif.cb.gpio_oe; it.irq = vif.cb.irq;
                ap.write(it);
            end
        endtask
    endclass

    // ------------------------------------------------------------------ reference model
    class gpio_ref_model extends uvm_object;
        `uvm_object_utils(gpio_ref_model)
        // registers (GPIO section 6)
        bit [1:0] dir, en, out, inten, status;
        bit [1:0] itype[2];
        bit [7:0] padcfg;
        // the shim registers (D-21)
        bit       irqstat, irqen; bit [1:0] dmactl;
        // input path: two shim flops, then the vendored block's two flops and the value PADIN reads
        bit [1:0] shim0, shim1, s0, s1, pin_in;
        // what the last step did, for the scoreboard and the coverage
        bit       ev_wr, ev_rd, ev_clr; bit [11:0] ev_addr; bit [31:0] ev_wdata;
        bit [1:0] ev_int, ev_rise, ev_fall;

        function new(string name = "gpio_ref_model"); super.new(name); reset(); endfunction

        function void reset();
            dir = 0; en = 0; out = 0; inten = 0; status = 0; itype[0] = 0; itype[1] = 0; padcfg = 0;
            irqstat = 0; irqen = 0; dmactl = 0; shim0 = 0; shim1 = 0; s0 = 0; s1 = 0; pin_in = 0;
            ev_wr = 0; ev_rd = 0; ev_clr = 0; ev_int = 0; ev_rise = 0; ev_fall = 0;
        endfunction

        function void copy_state(gpio_ref_model o);
            dir = o.dir; en = o.en; out = o.out; inten = o.inten; status = o.status; itype[0] = o.itype[0]; itype[1] = o.itype[1];
            padcfg = o.padcfg; irqstat = o.irqstat; irqen = o.irqen; dmactl = o.dmactl;
            shim0 = o.shim0; shim1 = o.shim1; s0 = o.s0; s1 = o.s1; pin_in = o.pin_in;
        endfunction

        // The specification lists ten registers at 0x00 to 0x28 and the four shim
        // registers. The block answers every offset below 0x80 (the vendored
        // register file; 0x20 and 0x2C to 0x7C read 0 and ignore writes): GPIO-2.
        function bit in_ip(bit [11:0] a);   return a < 12'h080; endfunction
        function bit in_tail(bit [11:0] a); return a inside {12'hFE0, 12'hFE4, 12'hFE8, 12'hFEC}; endfunction
        function bit mapped(bit [11:0] a);  return in_ip(a) || in_tail(a); endfunction

        function bit irq(); return irqstat && irqen; endfunction

        function bit [31:0] rd(bit [11:0] a);
            if (in_ip(a)) case (a[6:2])
                5'd0:  return {30'd0, dir};
                5'd1:  return {30'd0, en};
                5'd2:  return {30'd0, pin_in};
                5'd3:  return {30'd0, out};
                5'd6:  return {30'd0, inten};
                5'd7:  return {28'd0, itype[1], itype[0]};
                5'd9:  return {30'd0, status};
                5'd10: return {24'd0, padcfg};
                default: return 32'd0;                 // PADOUTSET and PADOUTCLR are write-only
            endcase
            case (a)
                12'hFE0: return {31'd0, irqstat};
                12'hFE4: return {31'd0, irqen};
                12'hFE8: return {30'd0, dmactl};
                12'hFEC: return GPIO_ID;
                default: return 32'd0;
            endcase
        endfunction

        // one pclk edge, from the values sampled just before it
        function void step(gpio_cycle_item it);
            bit acc, any;
            if (!it.preset_n) begin reset(); return; end
            acc    = it.psel && it.penable;
            ev_wr  = acc && it.pwrite && mapped(it.paddr);
            ev_rd  = acc && !it.pwrite && mapped(it.paddr);
            ev_addr = it.paddr; ev_wdata = it.pwdata;
            // an edge is seen between the last synchroniser flop and the value PADIN reads
            ev_rise = s1 & ~pin_in; ev_fall = ~s1 & pin_in;
            for (int n = 0; n < 2; n++)
                // 00 falling, 01 rising, 10 either. 11 is "level" in the specification;
                // the vendored block raises nothing for it: GPIO-2.
                ev_int[n] = inten[n] && en[n] && ((itype[n] == 2'b00 && ev_fall[n]) || (itype[n] == 2'b01 && ev_rise[n]) ||
                                                  (itype[n] == 2'b10 && (ev_rise[n] || ev_fall[n])));
            any = |ev_int;
            ev_clr  = ev_wr && it.paddr == 12'hFE0 && it.pwdata[0];
            irqstat = (irqstat && !ev_clr) || any;                         // sticky; an event beats its own clear
            // INTSTATUS accumulates; a read clears it, unless an event arrives in the same cycle
            if (any) status = status | ev_int;
            else if (ev_rd && in_ip(it.paddr) && it.paddr[6:2] == 5'd9) status = 2'b00;
            // the vendored block's input flops run while any pin of the group is enabled
            // (the specification says per pin: GPIO-2); stopped, they hold
            if (|en) begin pin_in = s1; s1 = s0; s0 = shim1; end
            shim1 = shim0; shim0 = it.pad;
            if (ev_wr && in_ip(it.paddr)) case (it.paddr[6:2])
                5'd0:  dir   = it.pwdata[1:0];
                5'd1:  en    = it.pwdata[1:0];
                5'd3:  out   = it.pwdata[1:0];
                5'd4:  out   = out |  it.pwdata[1:0];
                5'd5:  out   = out & ~it.pwdata[1:0];
                5'd6:  inten = it.pwdata[1:0];
                5'd7:  begin itype[0] = it.pwdata[1:0]; itype[1] = it.pwdata[3:2]; end
                5'd10: padcfg = it.pwdata[7:0];
                default: ;
            endcase
            if (ev_wr && it.paddr == 12'hFE4) irqen  = it.pwdata[0];
            if (ev_wr && it.paddr == 12'hFE8) dmactl = it.pwdata[1:0];
        endfunction
    endclass

    // ------------------------------------------------------------------ coverage
    class gpio_coverage extends uvm_component;
        `uvm_component_utils(gpio_coverage)
        int unsigned cyc, cyc_evt = 0, cyc_clr = 0, cyc_en_on = 0, hi_len[2], stable[2];
        bit [1:0]    pad_prev; int last_setclr = -1; bit [1:0] last_setclr_bits; bit status_one_pin; int status_pin;

        covergroup cg_gpio_apb with function sample(int kind, bit wr);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins PADDIR = {0}; bins GPIOEN = {1}; bins PADIN = {2}; bins PADOUT = {3}; bins PADOUTSET = {4};
                                      bins PADOUTCLR = {5}; bins INTEN = {6}; bins INTTYPE = {7}; bins INTSTATUS = {9}; bins PADCFG0 = {10};
                                      bins IRQSTAT = {32}; bins IRQEN = {33}; bins DMACTL = {34}; bins ID = {35}; }
            cp_rw: coverpoint wr { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins between_ip_and_tail = {40}; bins first_past_ip = {41}; bins last_before_tail = {42};
                                           bins above_tail = {43}; bins unaligned_tail = {44}; bins alias_of_shim_register = {45}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
            // inside the vendored register file but not a GARUDA register: answered, no error (GPIO-2)
            cp_ip_hole: coverpoint kind { bins offset_0x20 = {46}; bins offset_0x2c_to_0x7c = {47}; }
            x_ip_hole_rw: cross cp_ip_hole, cp_rw;
        endgroup

        covergroup cg_gpio_en with function sample(int pin, int use, bit en);
            option.per_instance = 1;
            cp_pin: coverpoint pin { bins p[] = {0, 1}; }
            cp_use: coverpoint use { bins padin_read = {0}; bins pad_edge_with_inten = {1}; }
            cp_en: coverpoint en;
            x_gpioen_use: cross cp_pin, cp_use, cp_en;
        endgroup

        covergroup cg_gpio_out with function sample(int kind, int pin, bit other);
            option.per_instance = 1;
            cp_op: coverpoint kind iff (kind < 2) { bins set = {0}; bins clr = {1}; }
            cp_pin: coverpoint pin iff (kind < 2) { bins p[] = {0, 1}; }
            cp_other: coverpoint other iff (kind < 2);
            x_setclr_pin: cross cp_op, cp_pin, cp_other;
            cp_both_bits: coverpoint kind { bins set_both = {2}; bins clr_both = {3}; }
            cp_consecutive: coverpoint kind { bins set_then_clr_same_bit = {4}; bins clr_then_set_same_bit = {5}; }
        endgroup

        covergroup cg_gpio_pin with function sample(int kind, int pin, int v);
            option.per_instance = 1;
            cp_pin: coverpoint pin iff (kind == 0) { bins p[] = {0, 1}; }
            cp_dir_out: coverpoint v[1:0] iff (kind == 0) { bins in_0 = {0}; bins in_1 = {1}; bins out_0 = {2}; bins out_1 = {3}; }
            cp_other: coverpoint v[3:2] iff (kind == 0) { bins in_0 = {0}; bins in_1 = {1}; bins out_0 = {2}; bins out_1 = {3}; }
            x_dir_out: cross cp_pin, cp_dir_out, cp_other;
            cp_input_pulse: coverpoint v iff (kind == 1) { bins p0_1 = {1}; bins p0_2 = {2}; bins p0_3 = {3}; bins p0_longer = {4};
                                                          bins p1_1 = {11}; bins p1_2 = {12}; bins p1_3 = {13}; bins p1_longer = {14}; }
            cp_contention: coverpoint v iff (kind == 2) { bins pin0_low_forced_high = {0}; bins pin0_high_forced_low = {1};
                                                         bins pin1_low_forced_high = {2}; bins pin1_high_forced_low = {3}; }
        endgroup

        covergroup cg_gpio_irq with function sample(int kind, int a, int b, int c);
            option.per_instance = 1;
            cp_type: coverpoint a iff (kind == 0) { bins falling = {0}; bins rising = {1}; bins either = {2}; bins level_11 = {3}; }
            cp_pin: coverpoint b iff (kind == 0) { bins p[] = {0, 1}; }
            cp_event: coverpoint c iff (kind == 0) { bins rise = {0}; bins fall = {1}; bins steady_high = {2}; bins steady_low = {3}; }
            x_type_pin_event: cross cp_type, cp_pin, cp_event;
            cp_intstatus: coverpoint a iff (kind == 1) { bins none = {0}; bins pin0_only = {1}; bins pin1_only = {2}; bins both = {3}; }
            cp_event_in_read_cycle: coverpoint a iff (kind == 2) { bins status_read_and_event_together = {1}; }
            cp_clear_vs_event: coverpoint a iff (kind == 3) { bins clear_then_event = {0}; bins same_cycle = {1}; bins event_then_clear = {2}; }
            cp_two_pins: coverpoint a iff (kind == 4) { bins both_in_one_cycle = {0}; bins second_pin_before_the_read = {1}; }
            cp_output_pin_event: coverpoint a iff (kind == 5) { bins pin0 = {0}; bins pin1 = {1}; }
            cp_after_enable: coverpoint a iff (kind == 6) { bins event_released_by_gpioen = {1}; }
            cp_masked: coverpoint a iff (kind == 7) { bins inten_clear = {0}; bins gpioen_clear = {1}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_gpio_apb = new(); cg_gpio_en = new(); cg_gpio_out = new(); cg_gpio_pin = new(); cg_gpio_irq = new();
        endfunction

        // pre: the state the cycle started from; m: after the step (its ev_* describe the cycle)
        function void sample_cycle(gpio_cycle_item it, gpio_ref_model pre, gpio_ref_model m);
            bit [31:0] d = m.ev_wdata; int w = m.ev_addr[6:2];
            cyc++;
            if (!it.preset_n) begin pad_prev = it.pad; return; end
            for (int n = 0; n < 2; n++) begin
                int o = 1 - n;
                cg_gpio_pin.sample(0, n, {pre.dir[o], pre.out[o], pre.dir[n], pre.out[n]});
                // pad activity
                if (it.pad[n] != pad_prev[n]) begin
                    if (pre.inten[n]) cg_gpio_en.sample(n, 1, pre.en[n]);
                    if (!it.pad[n] && !pre.dir[n] && hi_len[n] != 0) cg_gpio_pin.sample(1, n, 10 * n + ((hi_len[n] > 3) ? 4 : hi_len[n]));
                    stable[n] = 0;
                end else stable[n]++;
                hi_len[n] = it.pad[n] ? hi_len[n] + 1 : 0;
                // what the block sees: an edge, or a steady level, with the pin enabled for interrupts
                if (pre.inten[n] && pre.en[n]) begin
                    if (m.ev_rise[n]) cg_gpio_irq.sample(0, pre.itype[n], n, 0);
                    if (m.ev_fall[n]) cg_gpio_irq.sample(0, pre.itype[n], n, 1);
                    if (stable[n] == 12) cg_gpio_irq.sample(0, pre.itype[n], n, it.pad[n] ? 2 : 3);
                end else if (m.ev_rise[n] || m.ev_fall[n]) begin
                    if (!pre.inten[n] && pre.en[n]) cg_gpio_irq.sample(7, 0, 0, 0);
                    if (pre.inten[n] && !pre.en[n]) cg_gpio_irq.sample(7, 1, 0, 0);
                end
                if (m.ev_int[n] && pre.dir[n] && it.pad[n] == it.gpio_o[n]) cg_gpio_irq.sample(5, n, 0, 0);
            end
            pad_prev = it.pad;
            if (m.ev_int != 0) begin
                if (m.ev_int == 2'b11) cg_gpio_irq.sample(4, 0, 0, 0);
                if (pre.status != 0 && (m.ev_int & ~pre.status) != 0 && $countones(pre.status) == 1) cg_gpio_irq.sample(4, 1, 0, 0);
                if (m.ev_clr) cg_gpio_irq.sample(3, 1, 0, 0);
                else if (cyc - cyc_clr <= 3) cg_gpio_irq.sample(3, 0, 0, 0);
                if (cyc - cyc_en_on <= 4) cg_gpio_irq.sample(6, 1, 0, 0);
                cyc_evt = cyc;
            end
            if (m.ev_clr) begin if (m.ev_int == 0 && cyc - cyc_evt <= 3) cg_gpio_irq.sample(3, 2, 0, 0); cyc_clr = cyc; end
            // accesses
            if (m.ev_rd && m.in_ip(m.ev_addr)) begin
                if (w == 2) for (int n = 0; n < 2; n++) begin
                    cg_gpio_en.sample(n, 0, pre.en[n]);
                    if (pre.dir[n] && it.pad[n] != it.gpio_o[n]) cg_gpio_pin.sample(2, 0, 2 * n + it.gpio_o[n]);
                end
                if (w == 9) begin cg_gpio_irq.sample(1, pre.status, 0, 0); if (m.ev_int != 0) cg_gpio_irq.sample(2, 1, 0, 0); end
            end
            if (m.ev_wr && m.in_ip(m.ev_addr)) begin
                if (w == 1 && pre.en == 0 && d[1:0] != 0) cyc_en_on = cyc;
                if (w == 4 || w == 5) begin
                    if (d[1:0] == 2'b11) cg_gpio_out.sample(w == 4 ? 2 : 3, 0, 0);
                    else if (d[1:0] != 0) begin
                        int n = d[1] ? 1 : 0;
                        cg_gpio_out.sample(w == 4 ? 0 : 1, n, pre.out[1 - n]);
                        if (last_setclr == 4 && w == 5 && last_setclr_bits == d[1:0]) cg_gpio_out.sample(4, 0, 0);
                        if (last_setclr == 5 && w == 4 && last_setclr_bits == d[1:0]) cg_gpio_out.sample(5, 0, 0);
                    end
                    last_setclr = w; last_setclr_bits = d[1:0];
                end else last_setclr = -1;
            end
        endfunction

        function void apb_access(apb_item it, bit mapped);
            int kind;
            if (it.addr < 12'h080) begin
                kind = it.addr[6:2];
                if (it.addr[1:0] != 0) kind = -1;
                else if (kind == 8) kind = 46;
                else if (kind > 10) kind = 47;
            end
            else if (mapped) kind = 32 + it.addr[3:2];
            else if (it.addr[1:0] != 2'b00) kind = (it.addr >= 12'hFE0) ? 44 : -1;
            else if (it.addr == 12'h080) kind = 41;
            else if (it.addr == 12'hFDC) kind = 42;
            else if (it.addr >= 12'hFF0) kind = 43;
            else if ($countones(~it.addr[11:5]) == 1 && it.addr[4] == 1'b0) kind = 45;
            else kind = 40;
            cg_gpio_apb.sample(kind, it.write);
        endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_cyc)

    class gpio_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(gpio_scoreboard)
        uvm_analysis_imp_apb #(apb_item, gpio_scoreboard)       apb_imp;
        uvm_analysis_imp_cyc #(gpio_cycle_item, gpio_scoreboard) cyc_imp;
        gpio_ref_model model, pre;
        gpio_coverage  cov;
        int unsigned n_cyc, n_rd, n_wr, n_err, n_level, n_event, n_quiet;
        // for the two checks made from the pads, the registers and the pins alone
        int unsigned cyc, cyc_cfg = 0, pad_stable[2], en_on[2];
        bit [1:0]    pad_prev; bit irq_prev;
        int unsigned edge_cyc[$]; int edge_pin[$]; bit edge_rise[$];

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this); cyc_imp = new("cyc_imp", this);
            pre = gpio_ref_model::type_id::create("pre");
        endfunction

        function void err(string id, string msg);
            n_err++;
            if (n_err <= 20) `uvm_error(id, msg)
        endfunction

        function void write_cyc(gpio_cycle_item it);
            bit m; string id;
            n_cyc++;
            if (it.gpio_o !== (it.preset_n ? model.out : 2'b00) || it.gpio_oe !== (it.preset_n ? model.dir : 2'b00))
                err("sb_pins", $sformatf("gpio_o %02b gpio_oe %02b, model %02b %02b", it.gpio_o, it.gpio_oe, model.out, model.dir));
            if (it.irq !== (it.preset_n && model.irq()))
                err("sb_irq", $sformatf("irq %0b, model %0b (IRQSTAT=%0b IRQEN=%0b INTSTATUS=%02b)", it.irq, model.irq(), model.irqstat, model.irqen, model.status));
            if (it.preset_n && it.pready !== 1'b1) err("sb_pready", "PREADY low");
            if (it.preset_n && it.psel && it.penable) begin
                m = model.mapped(it.paddr);
                if (it.pwrite) n_wr++;
                else begin
                    n_rd++;
                    if (it.prdata !== model.rd(it.paddr)) begin
                        id = (it.paddr == 12'h008) ? "sb_padin" : (it.paddr == 12'h00C) ? "sb_padout" : (it.paddr == 12'h024) ? "sb_intstatus" : "sb_reg";
                        err(id, $sformatf("read 0x%03h: DUT %08h, model %08h", it.paddr, it.prdata, model.rd(it.paddr)));
                    end
                end
                if (it.pslverr !== !m)
                    err("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, model %0b", it.pwrite ? "write" : "read", it.paddr, it.pslverr, !m));
            end
            pin_level_checks(it);
            pre.copy_state(model);
            model.step(it);
            cov.sample_cycle(it, pre, model);
        endfunction

        // From the specification's own words, with no synchroniser model:
        //   [N-7.2] PADIN shows the level on the pin (once it has settled, for an enabled pin);
        //   6, 7.3  an edge of the selected kind on a pin with INTEN and GPIOEN set raises the
        //           interrupt, and nothing else does.
        // Both are checked only where no register that matters was written nearby.
        function bit qualifies(int n, bit rise);
            return model.inten[n] && model.en[n] &&
                   ((model.itype[n] == 2'b00 && !rise) || (model.itype[n] == 2'b01 && rise) || (model.itype[n] == 2'b10));
        endfunction

        function void pin_level_checks(gpio_cycle_item it);
            bit acc = it.psel && it.penable; bit found;
            cyc++;
            if (!it.preset_n) begin cyc_cfg = cyc; pad_prev = it.pad; irq_prev = 0; edge_cyc.delete(); edge_pin.delete(); edge_rise.delete();
                                    foreach (pad_stable[n]) begin pad_stable[n] = 0; en_on[n] = 0; end return; end
            // a write to a register that decides what a pad edge does
            if (acc && it.pwrite && it.paddr inside {12'h004, 12'h018, 12'h01C, 12'hFE0, 12'hFE4}) cyc_cfg = cyc;
            for (int n = 0; n < 2; n++) begin
                if (it.pad[n] != pad_prev[n]) begin
                    pad_stable[n] = 0;
                    edge_cyc.push_back(cyc); edge_pin.push_back(n); edge_rise.push_back(it.pad[n]);
                end else pad_stable[n]++;
                en_on[n] = model.en[n] ? en_on[n] + 1 : 0;
            end
            // [N-7.2]
            if (acc && !it.pwrite && it.paddr == 12'h008)
                for (int n = 0; n < 2; n++) if (pad_stable[n] >= 8 && en_on[n] >= 8) begin
                    n_level++;
                    if (it.prdata[n] !== it.pad[n])
                        err("sb_padin_level", $sformatf("pin %0d has been at %0b for %0d cycles and PADIN reads %0b", n, it.pad[n], pad_stable[n], it.prdata[n]));
                end
            // an edge seven cycles ago that qualifies, with nothing written since two cycles before it
            foreach (edge_cyc[i]) if (edge_cyc[i] + 7 == cyc && cyc_cfg + 2 < edge_cyc[i] && model.irqen) begin
                if (qualifies(edge_pin[i], edge_rise[i])) begin
                    n_event++;
                    if (!it.irq) err("sb_event", $sformatf("pin %0d %s seven cycles ago with its interrupt enabled, and irq is low",
                                                           edge_pin[i], edge_rise[i] ? "rose" : "fell"));
                end
            end
            // the interrupt rises: some qualifying edge must be behind it
            if (it.irq && !irq_prev && cyc_cfg + 10 < cyc) begin
                found = 0;
                foreach (edge_cyc[i]) if (edge_cyc[i] + 8 >= cyc && qualifies(edge_pin[i], edge_rise[i])) found = 1;
                n_quiet++;
                if (!found) err("sb_event", "irq rose with no qualifying edge on either pin in the last eight cycles");
            end
            irq_prev = it.irq; pad_prev = it.pad;
            while (edge_cyc.size() != 0 && edge_cyc[0] + 12 < cyc) begin void'(edge_cyc.pop_front()); void'(edge_pin.pop_front()); void'(edge_rise.pop_front()); end
        endfunction

        function void write_apb(apb_item it);
            cov.apb_access(it, model.mapped(it.addr));
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("gpio_scoreboard: %0d cycles, %0d reads, %0d writes compared; from the pads alone %0d PADIN levels, %0d edges and %0d interrupt rises checked; %0d mismatches",
                                      n_cyc, n_rd, n_wr, n_level, n_event, n_quiet, n_err), UVM_NONE)
            if (n_cyc == 0 || (n_rd + n_wr) == 0) `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class gpio_env extends uvm_env;
        `uvm_component_utils(gpio_env)
        apb_agent       apb;
        gpio_pad_driver pad_drv;
        uvm_sequencer #(gpio_pad_item) pad_sqr;
        gpio_monitor    mon;
        gpio_scoreboard sb;
        gpio_coverage   cov;
        gpio            regmodel;
        apb_reg_adapter adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb     = apb_agent::type_id::create("apb", this);
            pad_drv = gpio_pad_driver::type_id::create("pad_drv", this);
            pad_sqr = uvm_sequencer #(gpio_pad_item)::type_id::create("pad_sqr", this);
            mon = gpio_monitor::type_id::create("mon", this);
            sb  = gpio_scoreboard::type_id::create("sb", this);
            cov = gpio_coverage::type_id::create("cov", this);
            sb.model = gpio_ref_model::type_id::create("model");
            sb.cov = cov;
            regmodel = new("regmodel");
            regmodel.build();
            regmodel.lock_model();
            regmodel.reset();
            adapter   = apb_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(apb_item)::type_id::create("predictor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            pad_drv.seq_item_port.connect(pad_sqr.seq_item_export);
            mon.ap.connect(sb.cyc_imp);
            apb.mon.ap.connect(sb.apb_imp);
            regmodel.default_map.set_sequencer(apb.sqr, adapter);
            regmodel.default_map.set_auto_predict(0);
            predictor.map = regmodel.default_map; predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
        endfunction
    endclass

    `include "gpio_seq_lib.svh"
    `include "gpio_test_lib.svh"
endpackage
