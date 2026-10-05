// crg_test_lib.svh - tests for the clock and reset environment (included in crg_env_pkg).
//
//   crg_reg_test       register model: reset values, and bit bash where it does not reset the chip
//   crg_random_test    random requests, ratio changes and register traffic (+NTX=<n>)
//   crg_directed_test  the cases the plan names one by one; expected values written out here

class crg_base_test extends uvm_test;
    `uvm_component_utils(crg_base_test)
    crg_env env;
    virtual crg_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = crg_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual crg_if)::get(this, "", "cvif", vif)) `uvm_fatal("NOVIF", "test: no crg_if")
    endfunction

    task wr(bit [11:0] a, bit [31:0] d, int unsigned idle = 0);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 1; s.wdata = d; s.idle = idle; s.start(env.apb.sqr);
    endtask
    task rd(bit [11:0] a, output bit [31:0] d, input int unsigned idle = 0);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 0; s.idle = idle; s.start(env.apb.sqr); d = s.rdata;
    endtask
    // a read whose value the specification gives: checked here, not by the model
    task expect_rd(bit [11:0] a, bit [31:0] exp, string what, bit [31:0] mask = 32'hFFFF_FFFF);
        bit [31:0] d;
        rd(a, d);
        if ((d & mask) !== (exp & mask)) `uvm_error("TEST", $sformatf("%s: read 0x%03h = %08h, the specification gives %08h", what, a, d, exp))
    endtask
    task hclks(int unsigned n); repeat (n) @(posedge vif.hclk); endtask
    // the reset in force has ended and the bus can be used
    task wait_ready();
        wait (vif.preset_n === 1'b1 && vif.hreset_n === 1'b1);
        repeat (3) @(posedge vif.pclk);
    endtask
    // a reset is expected now: wait for it to start, then to end
    task wait_reset(int unsigned max = 400);
        int unsigned n = 0;
        while (vif.hreset_n !== 1'b0 && n < max) begin @(posedge vif.refclk); n++; end
        if (n >= max) `uvm_error("TEST", "a reset was expected and did not start")
        wait_ready();
    endtask
    task power_on(realtime after = 7.3);
        #after vif.ext_rst_n = 1'b1;
        wait_ready();
    endtask
    // the pin, asserted at any moment for any length of time
    task ext_pulse(realtime width);
        vif.ext_rst_n = 1'b0; #width; vif.ext_rst_n = 1'b1;
    endtask
    // requests as their sources make them: flops on hclk
    task wdt_pulse(int unsigned n = 1);
        @(posedge vif.hclk); vif.wdt_req <= 1'b1; hclks(n); vif.wdt_req <= 1'b0;
    endtask
    task ndm_level(int unsigned n);
        @(posedge vif.hclk); vif.ndm_req <= 1'b1; hclks(n); vif.ndm_req <= 1'b0;
    endtask
    task hart_level(int unsigned n);
        @(posedge vif.hclk); vif.hart_req <= 1'b1; hclks(n); vif.hart_req <= 1'b0;
    endtask
    // a software reset with the watchdog and/or the debugger request arriving in the very
    // always-on cycle in which the write is seen
    task sw_with(bit wdt, bit ndm);
        fork
            wr(12'h004, {22'd0, vif.div_sel, 8'd1});
            begin
                @(posedge vif.penable);
                vif.wdt_req = wdt; vif.ndm_req = ndm;
                @(posedge vif.aon);                          // seen together on this one edge, like the strobe
                vif.wdt_req = 1'b0; vif.ndm_req = 1'b0;
            end
        join
        wait_reset();
    endtask
    // DIVSEL, written the way firmware must: the register also holds two strobes
    task set_div(bit [1:0] v, bit wait_done = 1);
        wr(12'h004, {22'd0, v, 8'd0});
        if (wait_done) begin
            int unsigned n = 0;
            while ((vif.div_act != v || vif.div_busy) && n < 200) begin @(posedge vif.refclk); n++; end
            if (n >= 200) `uvm_error("TEST", $sformatf("ratio %0d did not take effect", v))
            repeat (2) @(posedge vif.pclk);
        end
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) + env.sb.n_err;
        $display("tb_crg_uvm: test=%s errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

class crg_reg_test extends crg_base_test;
    `uvm_component_utils(crg_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq; uvm_reg_bit_bash_seq bash_seq;
        phase.raise_objection(this);
        power_on();
        // RSTCTL bit 0 resets the chip and RSTREASON is the record of it: both are tested by the
        // directed test with expected values; here, the reset values and the lock
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.RSTCTL.get_full_name()},    "NO_REG_BIT_BASH_TEST", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.RSTREASON.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq"); rst_seq.model = env.regmodel; rst_seq.start(null);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq"); bash_seq.model = env.regmodel; bash_seq.start(null);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

class crg_random_test extends crg_base_test;
    `uvm_component_utils(crg_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        int unsigned ntx = 260; int k; bit [31:0] d; bit [1:0] dv = 0;
        void'($value$plusargs("NTX=%d", ntx));
        phase.raise_objection(this);
        power_on($urandom_range(3, 40) * 0.37);
        repeat (ntx) begin
            k = $urandom_range(0, 99);
            if      (k < 18) begin dv = $urandom_range(0, 3); set_div(dv, $urandom_range(0, 3) != 0); end
            else if (k < 22) begin wr(12'h004, {22'd0, 2'($urandom_range(0, 3)), 8'd0}); dv = $urandom_range(0, 3); set_div(dv); end   // a second value while busy
            else if (k < 36) rd(12'h008, d, $urandom_range(0, 4));
            else if (k < 46) rd(12'h000, d, $urandom_range(0, 4));
            else if (k < 52) wr(12'h000, ($urandom_range(0, 1)) ? (1 << $urandom_range(0, 4)) : $urandom_range(1, 31), $urandom_range(0, 4));
            else if (k < 55) wr(12'h004, {22'd0, dv, 3'd0, 1'b1, 4'd0});                       // BOOTFAIL, keeping the ratio
            else if (k < 58) wr(12'h020, $urandom_range(0, 1));
            else if (k < 61) rd(12'h020, d);
            else if (k < 64) begin case ($urandom_range(0, 4)) 0: rd(12'h00C, d); 1: wr(12'h01C, $urandom()); 2: rd(12'h024, d);
                                                              3: wr(4 * $urandom_range(10, 1023), $urandom()); default: rd($urandom_range(1, 35) | 1, d); endcase end
            else if (k < 66) wr(12'h008, $urandom());                                         // the read-only register
            else if (k < 72) begin fork wdt_pulse($urandom_range(1, 3)); join_none hclks($urandom_range(0, 6));
                                   if ($urandom_range(0, 2) == 0) fork ndm_level($urandom_range(1, 40)); join_none
                                   wait_reset(); wait fork; end
            else if (k < 77) begin fork ndm_level($urandom_range(1, 60)); join_none wait_reset(); wait fork; wait_ready(); end
            else if (k < 82) begin wr(12'h004, {22'd0, dv, 8'd1}); wait_reset(); end           // software reset, ratio kept
            else if (k < 88) begin hart_level($urandom_range(1, 30)); hclks(8); end
            else if (k < 91) begin fork hart_level($urandom_range(20, 400)); join_none hclks($urandom_range(1, 10)); wdt_pulse(1); wait_reset(); wait fork; hclks(8); end
            else if (k < 94) begin #($urandom_range(0, 300) * 0.11); ext_pulse($urandom_range(1, 60) * 0.45); dv = 0; wait_ready(); end
            else if (k < 96) begin wdt_pulse(1); repeat ($urandom_range(100, 1500)) @(posedge vif.refclk);      // a second request while the counter runs
                                   if ($urandom_range(0, 1)) wdt_pulse(1); else ndm_level(3); wait_ready(); end
            else if (k < 98) begin vif.boot_sel = ~vif.boot_sel; hclks(4); end
            else hclks($urandom_range(1, 80));
        end
        wait_ready();
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

class crg_directed_test extends crg_base_test;
    `uvm_component_utils(crg_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        bit [31:0] d;
        phase.raise_objection(this);

        // ---- F27, F01, F09: power-on. The cause is the pin, the ratio is 2, nothing is locked
        power_on();
        expect_rd(12'h000, 32'h1, "after power-on RSTREASON is EXT");
        expect_rd(12'h004, 32'h0, "RSTCTL reset value");
        expect_rd(12'h008, 32'h0, "CLKSTAT: ratio 2, not busy, boot_sel 0");
        expect_rd(12'h020, 32'h0, "MEMCTL reset value");
        // ---- F06: the boot select pin
        vif.boot_sel = 1'b1; repeat (120) @(posedge vif.aon);
        expect_rd(12'h008, 32'h100, "CLKSTAT shows boot_sel");
        // ---- F08: offsets that do not exist; the read-only register written
        rd(12'h00C, d); wr(12'h00C, 32'hFFFF_FFFF); rd(12'h01C, d); wr(12'h01C, 32'h1); rd(12'h024, d); wr(12'h024, 32'h1);
        rd(12'hFFC, d); wr(12'hFFC, 32'h1); rd(12'h001, d); wr(12'h006, 32'h1); wr(12'h800, 32'h1); rd(12'h800, d);
        wr(12'h008, 32'hFFFF_FFFF); expect_rd(12'h008, 32'h100, "CLKSTAT unchanged by a write");
        // ---- F03: each cause bit cleared by a write of 1, and only by that
        wr(12'h000, 32'h0); expect_rd(12'h000, 32'h1, "a write of 0 clears nothing");
        wr(12'h000, 32'h1E); expect_rd(12'h000, 32'h1, "writing other bits leaves EXT");
        wr(12'h000, 32'h1); expect_rd(12'h000, 32'h0, "EXT cleared");

        // ---- F04, F20, F17: the watchdog, one hclk cycle wide, at each ratio; full length; cause WDT
        for (int r = 0; r < 4; r++) begin
            set_div(r);
            wdt_pulse(1); wait_reset();
            expect_rd(12'h000, 32'h2, "after a watchdog reset the cause is WDT alone");
            expect_rd(12'h004, {22'd0, 2'(r), 8'd0}, "DIVSEL survives a watchdog reset");
            wr(12'h000, 32'h2);
        end
        // ---- F13, F14: all twelve changes of ratio
        for (int a = 0; a < 4; a++) for (int b = 0; b < 4; b++) if (a != b) begin
            set_div(a); set_div(b);
            expect_rd(12'h008, {23'd0, 1'b1, 6'd0, 2'(b)}, "CLKSTAT shows the new ratio and no change pending");
        end
        // ---- F14: a new ratio written at each position of the dividers' count, from the fastest ratio
        for (int pos = 0; pos < 48; pos++) begin
            set_div(0); repeat (pos) @(posedge vif.aon); set_div(1 + pos % 3);
        end
        // ---- F15: a second value while the first is pending - the last one written is the one that takes effect
        set_div(0);
        wr(12'h004, 32'h300); wr(12'h004, 32'h100); rd(12'h008, d);
        set_div(1); expect_rd(12'h008, 32'h101, "the last DIVSEL written is in effect");
        wr(12'h004, 32'h200); wr(12'h004, 32'h000); set_div(0);

        // ---- F04, F05: software reset. Written as firmware must, with the ratio in the same write
        set_div(2);
        wr(12'h004, 32'h201); wait_reset();
        expect_rd(12'h000, 32'h8, "after a software reset the cause is SW alone");
        expect_rd(12'h004, 32'h200, "DIVSEL survives a software reset");
        expect_rd(12'h008, 32'h102, "the ratio in effect survives a software reset");
        // a software reset written with other DIVSEL bits: the write is cut short by the reset
        // it causes, so the ratio does not change (BUGS.md CRG-3)
        wr(12'h004, 32'h001); wait_reset();
        expect_rd(12'h004, 32'h200, "DIVSEL after a reset written with DIVSEL bits 00");
        wr(12'h000, 32'h8);
        set_div(0);

        // ---- F21, F29: the debugger's reset: the cause is NDM and the Debug Module is not reset
        ndm_level(1);  wait_reset(); expect_rd(12'h000, 32'h4, "after ndmreset the cause is NDM alone"); wr(12'h000, 32'h4);
        ndm_level(12); wait_reset();
        fork ndm_level(2400); join_none wait_reset(5000); wait fork; wait_ready();          // held longer than the stretch
        expect_rd(12'h000, 32'h4, "cause NDM");
        // two causes in a row with no clear between: the later one replaces the earlier
        wdt_pulse(1); wait_reset(); expect_rd(12'h000, 32'h2, "a watchdog reset after ndmreset: WDT alone");
        wr(12'h000, 32'h2);
        // ---- F17: the watchdog request a few cycles wide, and held longer than the stretch
        wdt_pulse(5); wait_reset();
        fork wdt_pulse(2400); join_none wait_reset(5000); wait fork; wait_ready();
        wr(12'h000, 32'h2);

        // ---- F25: hartreset alone; held across another reset; withdrawn during another reset
        hart_level(20); hclks(10);
        hart_level(1);  hclks(10);
        fork hart_level(3000); join_none hclks(5); wdt_pulse(1); wait_reset(); wait fork; hclks(10);
        fork hart_level(300);  join_none hclks(5); wdt_pulse(1); wait_reset(); wait fork; hclks(10);
        expect_rd(12'h000, 32'h2, "hartreset leaves no cause of its own");
        wr(12'h000, 32'h2);

        // ---- F19: a request while the counter runs, from the same source and from another
        wdt_pulse(1); repeat (700) @(posedge vif.refclk); wdt_pulse(1); wait_ready();
        wdt_pulse(1); repeat (700) @(posedge vif.refclk); ndm_level(4); wait_ready();
        expect_rd(12'h000, 32'h4, "the later cause is recorded");
        ndm_level(4); repeat (700) @(posedge vif.refclk); wdt_pulse(1); wait_ready();
        expect_rd(12'h000, 32'h2, "the later cause is recorded");
        wr(12'h000, 32'h6);

        // ---- F26: two and three requests in the same cycle. Not in the specification; the RTL takes
        //      the watchdog, then software, then the debugger
        fork wdt_pulse(1); ndm_level(1); join wait_reset();
        expect_rd(12'h000, 32'h2, "watchdog and debugger together");
        sw_with(0, 1); expect_rd(12'h000, 32'h8, "software and debugger together");
        sw_with(1, 0); expect_rd(12'h000, 32'h2, "watchdog and software together");
        sw_with(1, 1); expect_rd(12'h000, 32'h2, "all three together");
        // The cause is rewritten in every cycle a request is up, so of two that overlap the one
        // that ends last is the one recorded, whatever the order above (BUGS.md CRG-3)
        fork wdt_pulse(1); ndm_level(6); join wait_reset();
        expect_rd(12'h000, 32'h4, "a watchdog request outlasted by the debugger's");
        wr(12'h000, 32'h4);
        wr(12'h000, 32'h2);

        // ---- F01, F03: BOOTFAIL is set by RSTCTL bit 4 and cleared like the others; it survives a reset
        wr(12'h004, 32'h010); expect_rd(12'h000, 32'h10, "BOOTFAIL set by software");
        wdt_pulse(1); wait_reset(); expect_rd(12'h000, 32'h12, "BOOTFAIL survives a watchdog reset");
        wr(12'h000, 32'h10); expect_rd(12'h000, 32'h2, "BOOTFAIL cleared alone"); wr(12'h000, 32'h2);
        // a clear in the cycle a new cause arrives: the cause wins
        fork
            wr(12'h000, 32'h1F);
            begin @(posedge vif.penable); vif.wdt_req = 1'b1; @(posedge vif.aon); vif.wdt_req = 1'b0; end
        join
        wait_reset();
        expect_rd(12'h000, 32'h2, "a cause arriving with a clear is recorded");
        wr(12'h000, 32'h2);

        // ---- F07: the lock: set by 1, not cleared by 0, cleared by a reset
        wr(12'h020, 32'h0); expect_rd(12'h020, 32'h0, "lock still clear");
        wr(12'h020, 32'h1); wr(12'h020, 32'h0); expect_rd(12'h020, 32'h1, "the lock is sticky");
        ndm_level(1); wait_reset(); expect_rd(12'h020, 32'h0, "a reset clears the lock"); wr(12'h000, 32'h4);

        // ---- F22: the pin, at a ratio other than 2 and with the lock set: shorter than a reference cycle,
        //      then long; then with the reference clock stopped
        set_div(3); wr(12'h020, 32'h1);
        #0.7 ext_pulse(0.6); wait_ready();
        expect_rd(12'h000, 32'h1, "after the pin the cause is EXT alone");
        expect_rd(12'h004, 32'h0, "the pin resets DIVSEL");
        expect_rd(12'h020, 32'h0, "the pin clears the lock");
        set_div(1); #3.1 ext_pulse(37.3); wait_ready();
        expect_rd(12'h008, 32'h100, "ratio 2 after the pin", 32'h7);
        ext_pulse(4500.0); wait_ready();
        vif.refclk_en = 1'b0; #20 vif.ext_rst_n = 1'b0; #40 vif.ext_rst_n = 1'b1; #20 vif.refclk_en = 1'b1; wait_ready();
        expect_rd(12'h000, 32'h1, "power-on with the clock starting late");
        // a watchdog request and the pin together
        fork wdt_pulse(2); begin #1.3 ext_pulse(9.0); end join wait_ready();
        rd(12'h000, d);

        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass
