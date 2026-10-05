// gpio_test_lib.svh - tests for the GPIO environment (included in gpio_env_pkg).
//
//   gpio_reg_test       register model: reset values and bit bash
//   gpio_random_test    constrained-random register traffic with random pad activity (+NTX=<n>)
//   gpio_directed_test  the corners the plan names one by one

class gpio_base_test extends uvm_test;
    `uvm_component_utils(gpio_base_test)
    gpio_env env;
    virtual gpio_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = gpio_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual gpio_if)::get(this, "", "gvif", vif)) `uvm_fatal("NOVIF", "test: no gpio_if")
    endfunction

    task wr(bit [11:0] a, bit [31:0] d, int unsigned idle = 0);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 1; s.wdata = d; s.idle = idle; s.start(env.apb.sqr);
    endtask
    task rd(bit [11:0] a, output bit [31:0] d, input int unsigned idle = 0);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 0; s.idle = idle; s.start(env.apb.sqr); d = s.rdata;
    endtask
    task clks(int unsigned n); repeat (n) @(posedge vif.pclk); endtask
    task wait_reset_done(); wait (vif.preset_n === 1'b1); clks(3); endtask
    task reset(int unsigned n = 3);
        #1 vif.rst_req = 1'b1; clks(n); vif.rst_req = 1'b0; clks(1); wait_reset_done();
    endtask
    // the outside world puts a level on the pads; frc makes it win against the pin's own driver
    task pads(bit [1:0] v, bit [1:0] frc = 2'b00);
        @(vif.drv_cb); vif.drv_cb.ext_val <= v; vif.drv_cb.ext_force <= frc;
    endtask
    // everything off, pads low, events cleared
    task quiet();
        bit [31:0] d;
        wr(12'h018, 0); wr(12'h000, 0); wr(12'h00C, 0); pads(2'b00); wr(12'h004, 3); clks(8);
        rd(12'h024, d); wr(12'hFE0, 1); wr(12'hFE4, 0);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) + env.sb.n_err;
        $display("tb_gpio_uvm: test=%s errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

class gpio_reg_test extends gpio_base_test;
    `uvm_component_utils(gpio_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq; uvm_reg_bit_bash_seq bash_seq;
        phase.raise_objection(this);
        wait_reset_done();
        // PADIN follows the pads; INTSTATUS and IRQSTAT are set by events; the set and clear
        // registers act on PADOUT. The scoreboard checks all of them against the model.
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.PADIN.get_full_name()},     "NO_REG_TESTS", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.INTSTATUS.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.IRQSTAT.get_full_name()},   "NO_REG_BIT_BASH_TEST", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.PADOUTSET.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.PADOUTCLR.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq"); rst_seq.model = env.regmodel; rst_seq.start(null);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq"); bash_seq.model = env.regmodel; bash_seq.start(null);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

class gpio_random_test extends gpio_base_test;
    `uvm_component_utils(gpio_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        gpio_apb_rand_seq s = gpio_apb_rand_seq::type_id::create("s");
        gpio_pad_rand_seq p = gpio_pad_rand_seq::type_id::create("p");
        int unsigned ntx = 3000;
        void'($value$plusargs("NTX=%d", ntx));
        s.n = ntx;
        phase.raise_objection(this);
        wait_reset_done();
        fork p.start(env.pad_sqr); join_none
        s.start(env.apb.sqr);
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

class gpio_directed_test extends gpio_base_test;
    `uvm_component_utils(gpio_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        bit [31:0] d;
        phase.raise_objection(this);
        wait_reset_done();

        // ---- F13, F15: every register read out of reset
        for (int a = 0; a <= 10; a++) rd(4 * a, d);
        for (int a = 0; a < 4; a++) rd(12'hFE0 + 4 * a, d);
        // ---- F10: the edges of the mapped ranges; aliases of the shim registers; the read-only registers written
        rd(12'h080, d); wr(12'h080, 32'hFFFF_FFFF); rd(12'hFDC, d); wr(12'hFDC, 32'hFFFF_FFFF);
        rd(12'hFF0, d); wr(12'hFF0, 32'hFFFF_FFFF); rd(12'hFFC, d); wr(12'hFFC, 32'h0);
        rd(12'h800, d); wr(12'h800, 32'h1); rd(12'hFE1, d); wr(12'hFE6, 32'h3);
        for (int r = 0; r < 4; r++) for (int b = 5; b <= 11; b++) begin
            wr((12'hFE0 + 4 * r) & ~(12'd1 << b), 32'h0000_0003); rd((12'hFE0 + 4 * r) & ~(12'd1 << b), d);
        end
        wr(12'h008, 32'hFFFF_FFFF); wr(12'h024, 32'hFFFF_FFFF); wr(12'hFEC, 32'h0);
        // offsets inside the vendored register file that are not GARUDA registers: no error, read 0
        rd(12'h020, d); wr(12'h020, 32'hFFFF_FFFF); rd(12'h020, d);
        for (int a = 12'h02C; a < 12'h080; a += 4) begin wr(a, 32'hFFFF_FFFF); rd(a, d); end
        for (int a = 0; a <= 10; a++) rd(4 * a, d);
        // ---- F08, F09, F11: PADCFG0 and DMACTL written, nothing moves; all ones to every register
        wr(12'h028, 32'hFFFF_FFFF); rd(12'h028, d); wr(12'h028, 0);
        wr(12'hFE8, 3); rd(12'hFE8, d); wr(12'hFE8, 0);
        wr(12'h01C, 32'hFFFF_FFFF); rd(12'h01C, d); wr(12'h01C, 0);

        // ---- F14: every combination of direction and value on the two pins
        for (int dv = 0; dv < 4; dv++) for (int ov = 0; ov < 4; ov++) begin wr(12'h000, dv); wr(12'h00C, ov); clks(3); end
        // ---- F05: set and clear on each pin with the other pin 0 and 1; both bits; set then clear and back
        wr(12'h000, 3);
        for (int o = 0; o < 2; o++) for (int n = 0; n < 2; n++) begin
            wr(12'h00C, o ? (2'b01 << (1 - n)) : 0);
            wr(12'h010, 1 << n); rd(12'h00C, d); wr(12'h014, 1 << n); rd(12'h00C, d);
            wr(12'h010, 1 << n); rd(12'h00C, d);
            wr(12'h014, 1 << n); wr(12'h010, 1 << n); wr(12'h014, 1 << n);
        end
        wr(12'h010, 3); rd(12'h00C, d); wr(12'h014, 3); rd(12'h00C, d); wr(12'h010, 0); wr(12'h014, 0);
        wr(12'h000, 0);

        // ---- F02, F03, F16: input pulses of 1, 2, 3 and more cycles on each pin, PADIN read after each
        wr(12'h004, 3);
        for (int n = 0; n < 2; n++) for (int w = 1; w <= 5; w++) begin
            pads(2'b01 << n); clks(w - 1); pads(2'b00); clks(9); rd(12'h008, d);
            pads(2'b01 << n); clks(10); rd(12'h008, d); pads(2'b00); clks(10); rd(12'h008, d);
        end
        // ---- F02: the input path stopped: PADIN holds what it had; one pin enabled: both pins are read
        pads(2'b11); clks(10); rd(12'h008, d);
        wr(12'h004, 0); pads(2'b00); clks(10); rd(12'h008, d);
        wr(12'h004, 1); clks(10); rd(12'h008, d); pads(2'b10); clks(10); rd(12'h008, d);
        wr(12'h004, 2); pads(2'b01); clks(10); rd(12'h008, d);
        wr(12'h004, 3); pads(2'b00); clks(10);
        // ---- F17: an output pin held at the other level from outside, and read
        wr(12'h000, 3); wr(12'h00C, 2'b01); clks(8); rd(12'h008, d);
        pads(2'b10, 2'b11); clks(10); rd(12'h008, d);
        wr(12'h00C, 2'b10); pads(2'b01, 2'b11); clks(10); rd(12'h008, d);
        pads(2'b00, 2'b00); wr(12'h000, 0); wr(12'h00C, 0);

        // ---- F18: each type on each pin with a rising edge, a steady high, a falling edge, a steady low
        for (int t = 0; t < 4; t++) for (int n = 0; n < 2; n++) begin
            quiet();
            wr(12'h01C, t << (2 * n)); wr(12'h018, 1 << n); wr(12'hFE4, 1); clks(4);
            pads(2'b01 << n); clks(16); rd(12'h024, d); rd(12'hFE0, d); wr(12'hFE0, 1); clks(4);
            pads(2'b00);      clks(16); rd(12'h024, d); rd(12'hFE0, d); wr(12'hFE0, 1);
        end
        // ---- F19: INTEN clear, then GPIOEN clear on the pin (the other pin keeps the input path running)
        for (int n = 0; n < 2; n++) begin
            quiet();
            wr(12'h01C, 4'b1010); wr(12'hFE4, 1);
            wr(12'h018, 0); pads(2'b01 << n); clks(10); pads(2'b00); clks(10); rd(12'hFE0, d);
            wr(12'h018, 3); wr(12'h004, 2'b10 >> n); pads(2'b01 << n); clks(10); pads(2'b00); clks(10); rd(12'hFE0, d); rd(12'h024, d);
        end
        // ---- F20: a clear before, in the same cycle as, and after an event; F07: INTSTATUS read likewise
        quiet(); wr(12'h01C, 4'b1010); wr(12'h018, 3); wr(12'hFE4, 1);
        for (int pos = 0; pos < 12; pos++) begin
            pads(pos[0] ? 2'b01 : 2'b00); clks(pos); wr(12'hFE0, 1); clks(12 - pos); rd(12'h024, d); wr(12'hFE0, 1);
        end
        for (int pos = 0; pos < 12; pos++) begin
            pads(pos[0] ? 2'b10 : 2'b00); clks(pos); rd(12'h024, d); clks(12 - pos); rd(12'h024, d); wr(12'hFE0, 1);
        end
        // ---- F21: both pins in one cycle; the second pin before the handler reads
        pads(2'b00); clks(10); rd(12'h024, d); wr(12'hFE0, 1);
        pads(2'b11); clks(10); rd(12'h024, d); rd(12'h024, d); wr(12'hFE0, 1);
        pads(2'b10); clks(10); pads(2'b00); clks(10); rd(12'h024, d); wr(12'hFE0, 1);
        pads(2'b01); clks(10); pads(2'b11); clks(10); rd(12'h024, d); wr(12'hFE0, 1);
        // ---- F23: an output pin interrupts on its own change
        quiet(); wr(12'h01C, 4'b1010); wr(12'h018, 3); wr(12'hFE4, 1); wr(12'h000, 3);
        wr(12'h010, 1); clks(10); rd(12'h024, d); wr(12'hFE0, 1);
        wr(12'h010, 2); clks(10); rd(12'h024, d); wr(12'hFE0, 1);
        wr(12'h014, 3); clks(10); rd(12'h024, d); wr(12'hFE0, 1);
        wr(12'h000, 0);
        // ---- the input path stopped, a pad moved, the path started again: the change is seen as an edge then
        quiet(); wr(12'h01C, 4'b1010); wr(12'h018, 3); wr(12'hFE4, 1);
        wr(12'h004, 0); pads(2'b01); clks(12); rd(12'hFE0, d);
        wr(12'h004, 3); clks(10); rd(12'h024, d); rd(12'hFE0, d); wr(12'hFE0, 1);
        // ---- the interrupt masked and unmasked with an event captured
        pads(2'b00); clks(10); wr(12'hFE4, 0); clks(3); wr(12'hFE4, 1); clks(3); wr(12'hFE0, 1); rd(12'h024, d);

        // ---- F13, F15: reset with both pins driven high; every register back at its reset value
        wr(12'h000, 3); wr(12'h00C, 3); clks(6);
        reset();
        for (int a = 0; a <= 10; a++) rd(4 * a, d);
        for (int a = 0; a < 4; a++) rd(12'hFE0 + 4 * a, d);

        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass
