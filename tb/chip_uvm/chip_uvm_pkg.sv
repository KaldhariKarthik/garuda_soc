`timescale 1ns/1ps
// =============================================================================
// chip_uvm_pkg.sv - the UVM environment of the whole chip (G6 6.1, ruling D-42).
//
// The core runs a C program from sw/chip; the UVM components sit around it:
//   - every peripheral's own UVM environment, unchanged, with its APB agent
//     PASSIVE: the core drives the APB through the fabric, the environment's
//     monitors, reference model, scoreboard and coverage check the block on that
//     real traffic (the same checks as the block's own runs);
//   - the pin agents of those environments on the chip's pads (UART line agents
//     today; the others are added block by block, tb/chip_uvm/README.md).
// The test passes only if the program reports success (tohost = 1, tb_chip's
// verdict and its AHB checkers), every scoreboard reports no mismatch, and the
// run has no UVM error.
//
// Components written for the chip (the block environments are not changed apart
// from connecting the register model to a sequencer only when one exists):
//   uart_cfg_follow  keeps a UART agent's line format equal to what the firmware
//                    programmed (DLL/DLM under DLAB, LCR), as a block test would
//                    set it by hand
//   uart_echo        sends every frame the chip transmits back on its own rx: the
//                    UVM form of tb_chip's wire loopback, so the scoreboard sees
//                    both directions
// =============================================================================
package chip_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import uart_env_pkg::*;
    import gpio_env_pkg::*;
    import pwm_env_pkg::*;
    import i2c_env_pkg::*;
    import spis_env_pkg::*;
    import timers_env_pkg::*;
    import clic_env_pkg::*;
    import crg_env_pkg::*;
    import dma_env_pkg::*;

    // ------------------------------------------------------------------ UART helpers
    class uart_cfg_follow extends uvm_subscriber #(apb_item);
        `uvm_component_utils(uart_cfg_follow)
        uart_line_cfg cfg;
        bit dlab;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void write(apb_item t);
            if (!t.write || t.slverr) return;
            case (t.addr)
                12'h00C: begin
                    dlab = t.wdata[7];
                    cfg.bits = 5 + t.wdata[1:0]; cfg.stop2 = t.wdata[2]; cfg.parity = t.wdata[3];
                end
                12'h000: if (dlab) cfg.div[7:0]  = t.wdata[7:0];
                12'h004: if (dlab) cfg.div[15:8] = t.wdata[7:0];
                default: ;
            endcase
        endfunction
    endclass

    class uart_echo extends uvm_component;
        `uvm_component_utils(uart_echo)
        uvm_analysis_imp #(uart_tx_ev, uart_echo) imp;
        uvm_sequencer #(uart_frame) sqr;
        uart_frame q[$];
        int unsigned n_echo;
        function new(string name, uvm_component parent); super.new(name, parent); imp = new("imp", this); endfunction
        function void write(uart_tx_ev e);
            uart_frame f;
            if (e.kind != UART_TX_DONE) return;
            f = uart_frame::type_id::create("f");
            f.kind = UART_FRAME; f.data = e.f.data; f.bad_parity = 0; f.bad_stop = 0; f.skew = 0; f.gap = 0; f.len = 0;
            q.push_back(f);
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                uart_one_seq s;
                wait (q.size() != 0);
                s = uart_one_seq::type_id::create("s");
                s.f = q.pop_front();
                s.start(sqr);
                n_echo++;
            end
        endtask
    endclass

    // ------------------------------------------------------------------ SPI slave companion
    // The ESP32 companion of the board (tb_chip's spi_master_model when not under UVM): on
    // every rising edge of gpio1 it sends one frame, A5 then 3C, mode 0 at 5 MHz. Here the
    // SPI slave environment's master agent sends it, so its scoreboard checks the bytes
    // the block receives and the MISO bytes it returns.
    class spis_companion extends uvm_component;
        `uvm_component_utils(spis_companion)
        uvm_sequencer #(spis_pkt) sqr;
        virtual chip_ctl_if ctl;
        int unsigned n_frames;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            forever begin
                spis_one_seq s;
                @(posedge ctl.gpio1);
                s = spis_one_seq::type_id::create("s");
                s.p = spis_pkt::type_id::create("p");
                s.p.kind = SPIS_PACKET; s.p.data = '{8'hA5, 8'h3C}; s.p.extra = 0; s.p.extra_data = 0;
                s.p.lo_t = 125; s.p.hi_t = 125;                 // 100 ns: 5 MHz
                s.p.lead_t = 125; s.p.trail_t = 125; s.p.gap_t = 20;
                s.p.glitch_at = 0; s.p.glitch_t = 1; s.p.n_idle = 0;
                s.start(sqr);
                n_frames++;
            end
        endtask
    endclass

    // ------------------------------------------------------------------ the chip environment
    class chip_env extends uvm_env;
        `uvm_component_utils(chip_env)
        uart_env        uart[3];
        uart_cfg_follow ufol[3];
        uart_echo       uecho[3];
        gpio_env        gpio;
        pwm_env         pwm;
        i2c_env         i2c;
        spis_env        spis;
        spis_companion  esp;
        timers_env      timers;
        clic_env        clic;
        crg_env         crg;
        dma_env         dma;
        string blk4[4] = '{"timers", "clic", "crg", "dma"};
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            for (int i = 0; i < 3; i++) begin
                uvm_config_db #(uvm_active_passive_enum)::set(this, $sformatf("uart%0d.apb", i), "is_active", UVM_PASSIVE);
                uart[i]  = uart_env::type_id::create($sformatf("uart%0d", i), this);
                ufol[i]  = uart_cfg_follow::type_id::create($sformatf("uart%0d_cfg", i), this);
                uecho[i] = uart_echo::type_id::create($sformatf("uart%0d_echo", i), this);
            end
            uvm_config_db #(uvm_active_passive_enum)::set(this, "gpio.apb", "is_active", UVM_PASSIVE);
            uvm_config_db #(uvm_active_passive_enum)::set(this, "pwm.apb", "is_active", UVM_PASSIVE);
            gpio = gpio_env::type_id::create("gpio", this);
            pwm  = pwm_env::type_id::create("pwm", this);
            uvm_config_db #(uvm_active_passive_enum)::set(this, "i2c.apb", "is_active", UVM_PASSIVE);
            i2c  = i2c_env::type_id::create("i2c", this);
            uvm_config_db #(uvm_active_passive_enum)::set(this, "spis.apb", "is_active", UVM_PASSIVE);
            spis = spis_env::type_id::create("spis", this);
            esp  = spis_companion::type_id::create("esp", this);
            // Inside the chip these four watch only: the CLIC's source agent, the DMA's AHB
            // slave and request agent, and the CRG's pin stimulus are bench stand-ins for
            // the chip itself; their signals are the chip's own (tb_chip_uvm forces them),
            // and no sequence is started on them.
            foreach (blk4[i]) uvm_config_db #(uvm_active_passive_enum)::set(this, {blk4[i], ".apb"}, "is_active", UVM_PASSIVE);
            timers = timers_env::type_id::create("timers", this);
            clic   = clic_env::type_id::create("clic", this);
            crg    = crg_env::type_id::create("crg", this);
            dma    = dma_env::type_id::create("dma", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            for (int i = 0; i < 3; i++) begin
                ufol[i].cfg = uart[i].line_agt.cfg;
                uart[i].apb.mon.ap.connect(ufol[i].analysis_export);
                uart[i].line_agt.mon.ap.connect(uecho[i].imp);
                uecho[i].sqr = uart[i].line_agt.sqr;
            end
            // the board's slave model (tb_chip, address 0x48) answers the chip; the agent's
            // own slave stays silent. The scoreboard takes ACK/NACK and read data from the
            // wire (its bus monitor), so it checks the block against what the board did.
            i2c.scfg.present = 0;
            esp.sqr = spis.spi.sqr;
        endfunction
    endclass

    // ------------------------------------------------------------------ blocks a program leaves alone
    // +BLOCKS=<a,b,...> names the environments whose block the program uses (default: all).
    // For any other block only the scoreboard's "compared nothing" error is demoted to a
    // note: every other check of that environment stays on (outputs idle, no interrupt in
    // reset, reset values on any read), so an unused block must still stay quiet.
    class chip_unused_catcher extends uvm_report_catcher;
        string unused[$];
        int unsigned n_demoted;
        function new(string name = "chip_unused_catcher"); super.new(name); endfunction
        function action_e catch();
            if (get_severity() == UVM_ERROR && get_message() == "the scoreboard compared nothing")
                foreach (unused[i])
                    if (get_client().get_full_name() == {"uvm_test_top.env.", unused[i], ".sb"}) begin
                        set_severity(UVM_INFO);
                        set_message({"the scoreboard compared nothing (", unused[i], " is not used by this program: +BLOCKS)"});
                        n_demoted++;
                    end
            return THROW;
        endfunction
    endclass

    // ------------------------------------------------------------------ tests
    class chip_base_test extends uvm_test;
        `uvm_component_utils(chip_base_test)
        chip_env env;
        virtual chip_ctl_if ctl;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = chip_env::type_id::create("env", this);
            if (!uvm_config_db #(virtual chip_ctl_if)::get(this, "", "ctl", ctl)) `uvm_fatal("NOVIF", "chip_base_test: no chip_ctl_if")
        endfunction
        function void connect_phase(uvm_phase phase);
            env.esp.ctl = ctl;
        endfunction
        function void end_of_elaboration_phase(uvm_phase phase);
            string blocks, all[$], used[$];
            chip_unused_catcher c = new();
            all = '{"uart0", "uart1", "uart2", "gpio", "pwm", "i2c", "spis", "timers", "clic", "crg", "dma"};
            if ($value$plusargs("BLOCKS=%s", blocks)) begin
                string w = "";
                for (int i = 0; i <= blocks.len(); i++)
                    if (i == blocks.len() || blocks[i] == ",") begin
                        if (w == "uart") begin used.push_back("uart0"); used.push_back("uart1"); used.push_back("uart2"); end
                        else if (w != "") used.push_back(w);
                        w = "";
                    end else w = {w, string'(blocks[i])};
                foreach (all[i]) begin
                    bit u = 0;
                    foreach (used[j]) if (used[j] == all[i]) u = 1;
                    if (!u) c.unused.push_back(all[i]);
                end
            end
            uvm_report_cb::add(null, c);
            `uvm_info("CHIP", $sformatf("blocks the program uses: %s; left alone (checked to stay quiet): %p",
                      blocks == "" ? "all" : blocks, c.unused), UVM_NONE)
        endfunction
        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            wait (ctl.prog_done === 1'b1);
            #(20us);                                  // let the last frames and echoes finish
            phase.drop_objection(this);
        endtask
        function void report_phase(uvm_phase phase);
            uvm_report_server srv = uvm_report_server::get_server();
            int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL);
            for (int i = 0; i < 3; i++) errs += env.uart[i].sb.n_err;
            errs += env.gpio.sb.n_err + env.pwm.sb.n_err + env.i2c.sb.n_err + env.spis.sb.n_err;
            errs += env.timers.sb.n_err + env.clic.sb.n_err + env.crg.sb.n_err + env.dma.sb.n_err;
            for (int i = 0; i < 3; i++)
                $display("tb_chip_uvm: uart%0d echoed %0d frame(s)", i, env.uecho[i].n_echo);
            $display("tb_chip_uvm: the SPI companion sent %0d frame(s)", env.esp.n_frames);
            if (ctl.prog_rc != 0) begin $display("[FAIL] the chip program reported %0d", ctl.prog_rc); errs++; end
            $display("tb_chip_uvm: test=%s program rc=%0d errors=%0d", get_type_name(), ctl.prog_rc, errs);
            $display("RESULT: %s", errs ? "FAILED" : "PASSED");
        endfunction
    endclass
endpackage
