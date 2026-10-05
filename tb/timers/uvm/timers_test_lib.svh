// timers_test_lib.svh - tests for the timers environment (included in timers_env_pkg).
//
//   tmr_reg_test       register model: reset values, bit bash (counting registers excluded),
//                      reset values again after a watchdog reset
//   tmr_random_test    constrained-random register traffic (+NTX=<n>)
//   tmr_directed_test  the corners the plan names one by one

class tmr_base_test extends uvm_test;
    `uvm_component_utils(tmr_base_test)
    timers_env env;
    virtual timers_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = timers_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual timers_if)::get(this, "", "tvif", vif)) `uvm_fatal("NOVIF", "test: no timers_if")
    endfunction

    task wr(bit [11:0] a, bit [31:0] d, int unsigned idle = 0);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 1; s.wdata = d; s.idle = idle; s.start(env.apb.sqr);
    endtask
    task rd(bit [11:0] a, output bit [31:0] d, input int unsigned idle = 0);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 0; s.idle = idle; s.start(env.apb.sqr); d = s.rdata;
    endtask
    task hclks(int unsigned n); repeat (n) @(posedge vif.hclk); endtask
    task wait_reset_done();
        wait (vif.preset_n === 1'b1 && vif.hreset_n === 1'b1);
        hclks(4);
    endtask
    // a watchdog expiry is expected now: wait for the reset it causes, then for its end
    task wait_wdt_reset(int unsigned max = 3000);
        int unsigned n = 0;
        while (vif.hreset_n !== 1'b0 && n < max) begin @(posedge vif.hclk); n++; end
        if (n >= max) `uvm_error("TEST", "a watchdog reset was expected and did not come")
        wait_reset_done();
    endtask
    task ext_reset(int unsigned n = 4);
        vif.ext_rst_n <= 1'b0; hclks(n); vif.ext_rst_n <= 1'b1; wait_reset_done();
    endtask
    task set_time(bit [31:0] h, bit [31:0] l); wr(12'h004, h); wr(12'h000, l); endtask
    // the three-step compare write of TIMERS [N-7.12]
    task set_cmp(bit [31:0] h, bit [31:0] l); wr(12'h008, 32'hFFFF_FFFF); wr(12'h00C, h); wr(12'h008, l); endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) + env.sb.n_err;
        $display("tb_timers_uvm: test=%s errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

class tmr_reg_test extends tmr_base_test;
    `uvm_component_utils(tmr_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq; uvm_reg_bit_bash_seq bash_seq;
        phase.raise_objection(this);
        wait_reset_done();
        // the two halves of the running counter and the live watchdog count cannot be
        // compared with a mirror; they are checked by the scoreboard on every read
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.MTIME_LO.get_full_name()}, "NO_REG_TESTS", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.MTIME_HI.get_full_name()}, "NO_REG_TESTS", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.WDTVAL.get_full_name()},   "NO_REG_TESTS", 1, this);
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq"); rst_seq.model = env.regmodel; rst_seq.start(null);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq"); bash_seq.model = env.regmodel; bash_seq.start(null);
        // F31: a watchdog expiry resets the block; every register is at its reset value again
        wr(12'h014, 32'd8); wr(12'h010, 32'h1); wr(12'h01C, KICK_MAGIC); wait_wdt_reset();
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq2"); rst_seq.model = env.regmodel; rst_seq.start(null);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

class tmr_random_test extends tmr_base_test;
    `uvm_component_utils(tmr_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        tmr_rand_seq s = tmr_rand_seq::type_id::create("s");
        int unsigned ntx = 1500;
        void'($value$plusargs("NTX=%d", ntx));
        s.n = ntx;
        phase.raise_objection(this);
        wait_reset_done();
        s.start(env.apb.sqr);
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

class tmr_directed_test extends tmr_base_test;
    `uvm_component_utils(tmr_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        bit [31:0] lo, hi, d;
        phase.raise_objection(this);
        wait_reset_done();

        // ---- F12: every register read out of reset; F02/F16: the high word read alone, never latched
        rd(12'h004, hi);
        for (int a = 0; a <= 8; a++) rd(4 * a, d);

        // ---- F15: LO then HI across the carry, with the carry at every position around the read
        for (int i = 0; i < 24; i++) begin
            set_time(32'h0000_0007, 32'hFFFF_FFE8 + i);
            rd(12'h000, lo, i % 3); rd(12'h004, hi);
        end
        // ---- F16: the high word alone after a stale latch
        hclks(60); rd(12'h004, hi);
        // ---- F13: the low-word carry with no read near it, and the 64-bit wrap
        set_time(32'h0000_0000, 32'hFFFF_FFF8); hclks(20);
        set_time(32'hFFFF_FFFF, 32'hFFFF_FFF0); hclks(30);
        // ---- F14: each half written, and the high word right after the low word
        wr(12'h000, 32'h0000_1000); wr(12'h004, 32'h0000_0002);
        wr(12'h004, 32'h0000_0000);

        // ---- F17, F18, F19: compare below, equal, one above, far above; decided by each word
        set_time(32'h0, 32'h0000_0100);
        rd(12'h000, lo); set_cmp(32'h0, lo + 60); hclks(80);       // deadline reached while waiting
        rd(12'h000, lo); set_cmp(32'h0, lo + 200);                  // advanced: mtip drops
        hclks(10);
        set_cmp(32'h0, 32'h0000_0001); hclks(6);                    // already passed: asserts at once
        set_cmp(32'h1, 32'h0); hclks(6);                            // decided by the high word
        set_cmp(32'h0, 32'hFFFF_FFFF); hclks(6);
        // ---- F03: each compare half with 0, all ones and another value
        wr(12'h008, 32'd0); wr(12'h008, 32'hFFFF_FFFF); wr(12'h008, 32'h1234_5678);
        wr(12'h00C, 32'd0); wr(12'h00C, 32'hFFFF_FFFF); wr(12'h00C, 32'h0000_0003);
        rd(12'h008, d); rd(12'h00C, d);
        // ---- F20: the one-step compare write, in the wrong order, against the three-step one
        set_time(32'h1, 32'h0000_0010); set_cmp(32'h1, 32'h0000_4000); hclks(4);
        wr(12'h008, 32'h0000_0000); wr(12'h00C, 32'h0000_0002);     // low first: momentarily in the past
        hclks(6);
        set_cmp(32'hFFFF_FFFF, 32'hFFFF_FFFF);

        // ---- F09: offsets that do not exist; F06: a write to the read-only count
        rd(12'h024, d); wr(12'h024, 32'hFFFF_FFFF); rd(12'hFFC, d); wr(12'hFFC, 32'h0);
        rd(12'h001, d); wr(12'h012, 32'hFFFF_FFFF); wr(12'h018, 32'h1234_5678);
        // ---- F11: back-to-back writes to the same and to different registers
        wr(12'h014, 32'd500); wr(12'h014, 32'd600); wr(12'h020, 32'd7); wr(12'h014, 32'd900);

        // ---- F07, F24: the kick register before the watchdog is enabled - nothing happens
        wr(12'h01C, KICK_MAGIC); rd(12'h01C, d); rd(12'h018, d);
        // ---- F04: WDTCTL written with each value before EN is set
        wr(12'h010, 32'h0); wr(12'h010, 32'h2); wr(12'h010, 32'h0);
        // ---- F27: warning enabled before the threshold is crossed; thresholds 0, 1, mid, load - 1
        wr(12'h014, 32'd300); wr(12'h020, 32'd150);
        wr(12'h010, 32'h3);                                          // EN | WARNEN
        hclks(170); rd(12'h018, d);
        wr(12'h010, 32'h1);                                          // WARNEN cleared while the warning is high
        wr(12'h010, 32'h3);                                          // and set again after the crossing
        wr(12'h01C, KICK_MAGIC);                                     // kick clears the warning
        // ---- F26: EN cannot be cleared
        wr(12'h010, 32'h0); wr(12'h010, 32'h2); rd(12'h010, d);
        // ---- F24: every value one bit away from the magic value, 0, all ones, another value
        for (int b = 0; b < 32; b++) wr(12'h01C, KICK_MAGIC ^ (32'd1 << b));
        wr(12'h01C, 32'h0); wr(12'h01C, 32'hFFFF_FFFF); wr(12'h01C, 32'hDEAD_BEEF);
        wr(12'h01C, KICK_MAGIC);
        // ---- F25: reload value raised and lowered while running; takes effect at the next kick
        wr(12'h014, 32'd800); rd(12'h018, d); wr(12'h01C, KICK_MAGIC); rd(12'h018, d);
        // ---- aliasing: every register written and read at each alias of its offset (one
        //      upper address bit set) while the watchdog runs; the kick alias gets the magic
        //      value. Each must answer PSLVERR and change nothing.
        for (int r = 0; r <= 8; r++) for (int b = 8; b <= 11; b++) begin
            wr((4 * r) | (1 << b), (r == 7) ? KICK_MAGIC : 32'hA5A5_0000 + r);
            rd((4 * r) | (1 << b), d);
        end
        for (int r = 0; r <= 8; r++) rd(4 * r, d);
        wr(12'h014, 32'd120); wr(12'h01C, KICK_MAGIC);
        wr(12'h020, 32'd0); wr(12'h020, 32'd1); wr(12'h020, 32'd119); wr(12'h020, 32'd50);
        // ---- F32: threshold equal to and above the reload value
        wr(12'h020, 32'd120); wr(12'h01C, KICK_MAGIC); hclks(6); wr(12'h020, 32'd500); hclks(6);
        wr(12'h020, 32'd10);
        // ---- F33: a second kick later and later, down to a count of 2, 1, 0 and too late
        // (an access starts on a pclk edge, so one reload value reaches only every
        // other count; two reload values of different parity reach all of them)
        for (int d = 92; d <= 121; d++) begin
            wr(12'h014, 32'd60 + (d % 2)); wr(12'h010, 32'h1); wr(12'h01C, KICK_MAGIC);
            hclks(d / 2);
            wr(12'h01C, KICK_MAGIC);
            hclks(8); wait_reset_done();
        end
        // ---- F30, F31: force an expiry; afterwards the watchdog is disabled and at its reset values
        wr(12'h014, 32'd8); wr(12'h010, 32'h1); wr(12'h01C, KICK_MAGIC); wait_wdt_reset();
        rd(12'h010, d); rd(12'h018, d); rd(12'h014, d);
        // ---- F34: EN set with a reload value of 1, then of 0
        wr(12'h014, 32'd1); wr(12'h010, 32'h1); wait_wdt_reset();
        wr(12'h014, 32'd0); wr(12'h010, 32'h3); wait_wdt_reset();
        // ---- F28, F29, F30: expiry with the warning enabled; then the pin reset while the request is up
        wr(12'h014, 32'd40); wr(12'h020, 32'd15); wr(12'h010, 32'h3);
        hclks(30);
        begin
            int unsigned n = 0;
            while (vif.req !== 1'b1 && n < 3000) begin @(negedge vif.hclk); n++; end
            if (n >= 3000) `uvm_error("TEST", "the reset request was expected and did not come")
        end
        ext_reset(3);
        rd(12'h010, d);

        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass
