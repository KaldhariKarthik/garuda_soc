// pwm_test_lib.svh - tests for the PWM environment (included in pwm_env_pkg).
//
//   pwm_reg_test       register model: reset values and bit bash
//   pwm_random_test    constrained-random register traffic (+NTX=<n>)
//   pwm_directed_test  the corners the plan names one by one

class pwm_base_test extends uvm_test;
    `uvm_component_utils(pwm_base_test)
    pwm_env env;
    virtual pwm_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = pwm_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual pwm_if)::get(this, "", "pvif", vif)) `uvm_fatal("NOVIF", "test: no pwm_if")
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
    // stop, program, start: PRESCALE, PERIOD, four duties, then EN with the given channel enables
    task start(bit [15:0] ps, bit [15:0] pe, bit [15:0] d0, bit [15:0] d1, bit [15:0] d2, bit [15:0] d3, bit [3:0] ch = 4'hF);
        wr(12'h008, 0); wr(12'h000, ps); wr(12'h004, pe);
        wr(12'h010, d0); wr(12'h014, d1); wr(12'h018, d2); wr(12'h01C, d3);
        wr(12'h008, {24'd0, ch, 3'd0, 1'b1});
    endtask
    // wait for the pin of a channel to rise (a frame starts) with a bound
    task wait_rise(int c, int unsigned max = 400000);
        int unsigned n = 0;
        while (vif.pwm[c] !== 1'b0 && n < max) begin @(posedge vif.pclk); n++; end
        while (vif.pwm[c] !== 1'b1 && n < max) begin @(posedge vif.pclk); n++; end
        if (n >= max) `uvm_error("TEST", $sformatf("channel %0d did not rise", c))
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) + env.sb.n_err;
        $display("tb_pwm_uvm: test=%s errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

class pwm_reg_test extends pwm_base_test;
    `uvm_component_utils(pwm_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq; uvm_reg_bit_bash_seq bash_seq;
        phase.raise_objection(this);
        wait_reset_done();
        // the live counter and the captured events move by themselves once EN is bashed;
        // the scoreboard checks them against the model on every read
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.STATUS.get_full_name()},  "NO_REG_TESTS", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.IRQSTAT.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq"); rst_seq.model = env.regmodel; rst_seq.start(null);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq"); bash_seq.model = env.regmodel; bash_seq.start(null);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

class pwm_random_test extends pwm_base_test;
    `uvm_component_utils(pwm_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        pwm_rand_seq s = pwm_rand_seq::type_id::create("s");
        int unsigned ntx = 2500;
        void'($value$plusargs("NTX=%d", ntx));
        s.n = ntx;
        phase.raise_objection(this);
        wait_reset_done();
        s.start(env.apb.sqr);
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

class pwm_directed_test extends pwm_base_test;
    `uvm_component_utils(pwm_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        bit [31:0] d; bit [15:0] v[4];
        phase.raise_objection(this);
        wait_reset_done();

        // ---- F09, F18: every register read out of reset; nothing high before EN
        for (int a = 0; a < 8; a++) rd(4 * a, d);
        for (int a = 0; a < 4; a++) rd(12'hFE0 + 4 * a, d);
        // ---- F07: the edges of the two mapped ranges, read and written; the read-only registers written
        rd(12'h020, d); wr(12'h020, 32'hFFFF_FFFF); rd(12'hFDC, d); wr(12'hFDC, 32'hFFFF_FFFF);
        rd(12'hFF0, d); wr(12'hFF0, 32'hFFFF_FFFF); rd(12'hFFC, d); wr(12'hFFC, 32'h0);
        rd(12'h800, d); wr(12'h800, 32'h1); rd(12'hFE1, d); wr(12'hFE6, 32'h3);
        wr(12'h00C, 32'hFFFF_FFFF); wr(12'hFEC, 32'h0); rd(12'h00C, d); rd(12'hFEC, d);
        // ---- aliasing: every register written and read at each alias of its offset (one upper
        //      address bit changed). Each must answer PSLVERR and change nothing.
        for (int r = 0; r < 8; r++) for (int b = 5; b <= 11; b++) begin
            wr((4 * r) | (1 << b), 32'h0000_FFFF); rd((4 * r) | (1 << b), d);
        end
        for (int r = 0; r < 4; r++) for (int b = 5; b <= 11; b++) begin
            wr((12'hFE0 + 4 * r) & ~(12'd1 << b), 32'h0000_0003); rd((12'hFE0 + 4 * r) & ~(12'd1 << b), d);
        end
        for (int a = 0; a < 8; a++) rd(4 * a, d);
        for (int a = 0; a < 4; a++) rd(12'hFE0 + 4 * a, d);
        // ---- F18: duties and channel enables set, EN clear: the pins stay low
        wr(12'h004, 16'd10); wr(12'h010, 16'd5); wr(12'h008, 32'hF0); clks(40);

        // ---- F03: every value of the four channel enables with EN 0 and 1
        start(0, 12, 3, 6, 9, 12);
        for (int e = 0; e < 2; e++) for (int ch = 0; ch < 16; ch++) begin wr(12'h008, {24'd0, 4'(ch), 3'd0, 1'(e)}); clks(7); end

        // ---- F10, F11, F14: PRESCALE 0, 1, mid; PERIOD 1, 2, mid; DUTY 0, 1, mid, PERIOD - 1, PERIOD
        for (int ps = 0; ps < 3; ps++) begin
            bit [15:0] psv = (ps == 2) ? 16'd5 : ps;
            start(psv, 1, 0, 1, 1, 0);   clks(6 * (psv + 1));
            start(psv, 2, 0, 1, 2, 1);   clks(8 * (psv + 1));
            start(psv, 9, 0, 1, 4, 8);   clks(30 * (psv + 1));
            start(psv, 9, 9, 8, 4, 1);   clks(30 * (psv + 1));
        end
        // ---- F14: PERIOD 0 with EN set; PERIOD 0xFFFE and 0xFFFF (two frames each, PRESCALE 0)
        start(0, 0, 0, 1, 16'hFFFF, 5); clks(20);
        start(1, 0, 3, 3, 3, 3);        clks(20);
        start(0, 16'hFFFE, 0, 1, 16'hFFFD, 16'hFFFE); clks(2 * 65534 + 40);
        start(0, 16'hFFFF, 0, 1, 16'hFFFE, 16'hFFFF); clks(65535 + 40);
        wr(12'h010, 16'hFFFE); wr(12'h014, 16'hAAAA); wr(12'h018, 16'h5555); wr(12'h01C, 16'd0); clks(65535);   // channels swapped, a middle duty
        // ---- F10: PRESCALE 0xFFFF with PERIOD 1, 2 and 4 (one boundary each; two for PERIOD 4)
        start(16'hFFFF, 1, 0, 1, 1, 1); clks(65536 + 65536 / 2);
        start(16'hFFFF, 2, 0, 1, 2, 1); clks(2 * 65536 + 400);
        start(16'hFFFF, 4, 1, 2, 3, 4); clks(4 * 65536 + 400);
        wr(12'h010, 16'd0); clks(4 * 65536);
        // ---- F10: PERIOD 0xFFFF with PRESCALE 1 and 2. (Both at 0xFFFF is 4e9 cycles a frame and is not run.)
        start(1, 16'hFFFF, 0, 1, 16'h8000, 16'hFFFF); clks(2 * 65535 + 100);
        wr(12'h010, 16'hFFFE); clks(2 * 65535);
        start(2, 16'hFFFF, 16'hFFFF, 16'hFFFE, 16'h8000, 1); clks(3 * 65535 + 100);
        wr(12'h01C, 16'd0); clks(3 * 65535);
        // ---- F09, F18: reset while all four pins are high; every register is back at its reset value
        start(0, 12, 12, 12, 12, 12); clks(20);
        reset();
        for (int a = 0; a < 8; a++) rd(4 * a, d);
        for (int a = 0; a < 4; a++) rd(12'hFE0 + 4 * a, d);

        // ---- F12: the 24 orderings of four different duties; two, three and four equal
        v[0] = 2; v[1] = 5; v[2] = 8; v[3] = 11;
        for (int a = 0; a < 4; a++) for (int b = 0; b < 4; b++) for (int c = 0; c < 4; c++) for (int e = 0; e < 4; e++)
            if (a != b && a != c && a != e && b != c && b != e && c != e) begin
                start(0, 14, v[a], v[b], v[c], v[e]); clks(34);
            end
        start(0, 14, 4, 4, 9, 2);  clks(34);
        start(0, 14, 4, 4, 4, 2);  clks(34);
        start(0, 14, 7, 7, 7, 7);  clks(34);

        // ---- F15: a duty written at every position of a frame, shorter and longer than the old one
        for (int pos = 0; pos < 26; pos++) begin
            start(1, 10, 6, 6, 6, 6); wait_rise(0);
            clks(pos); wr(12'h010, (pos % 2) ? 16'd9 : 16'd2); clks(50);
        end
        // ---- F16: four consecutive duty writes with the boundary at each place between them
        for (int pos = 0; pos < 14; pos++) begin
            start(0, 12, 3, 3, 3, 3); wait_rise(0);
            clks(pos); wr(12'h010, 16'd9); wr(12'h014, 16'd9); wr(12'h018, 16'd9); wr(12'h01C, 16'd9); clks(40);
        end

        // ---- F17: PERIOD lowered below the counter, lowered, raised; PRESCALE changed; all while running
        start(0, 40, 10, 20, 30, 39); wait_rise(0); clks(25);
        wr(12'h004, 16'd8);  clks(60);
        wr(12'h004, 16'd30); clks(70);
        wr(12'h004, 16'd20); clks(70);
        wr(12'h000, 16'd3);  clks(200);
        wr(12'h000, 16'd0);  clks(80);
        // PRESCALE lowered at each count of the running prescaler, with all four pins high
        for (int pos = 0; pos < 8; pos++) begin
            start(7, 10, 6, 6, 6, 6); wait_rise(0);
            clks(8 + pos); wr(12'h000, 16'd2); clks(160);
        end

        // ---- F19, F20: EN cleared while high, while low and in the boundary cycle; then enabled again
        for (int pos = 0; pos < 16; pos++) begin
            start(0, 12, 6, 6, 6, 6); wait_rise(0);
            clks(pos); wr(12'h008, 32'hF0); clks(5); wr(12'h008, 32'hF1); clks(30);
        end
        // each channel enable cleared while its pin is high
        for (int c = 0; c < 4; c++) begin
            start(0, 12, 8, 8, 8, 8); wait_rise(c);
            wr(12'h008, {24'd0, 4'(4'hF & ~(4'd1 << c)), 3'd0, 1'b1}); clks(30);
        end

        // ---- F21: each channel clamped by PERIOD + 1 and by 0xFFFF, and by another value; one to four together; the flag clears itself
        for (int c = 0; c < 4; c++) for (int k = 0; k < 3; k++) begin
            start(0, 10, 3, 3, 3, 3);
            wr(12'h010 + 4 * c, (k == 0) ? 16'd11 : (k == 1) ? 16'hFFFF : 16'd200); clks(25); rd(12'h00C, d);
            wr(12'h010 + 4 * c, 16'd4); clks(25); rd(12'h00C, d); rd(12'hFE0, d);
        end
        start(0, 10, 11, 12, 3, 3);   clks(25); rd(12'h00C, d);
        start(0, 10, 11, 12, 13, 3);  clks(25); rd(12'h00C, d);
        start(0, 10, 11, 12, 13, 14); clks(25); rd(12'h00C, d);

        // ---- F22: each event with its enable 0 and 1; a clear in the cycle of the event
        start(0, 6, 2, 2, 2, 2);
        wr(12'hFE4, 2'b00); clks(10); rd(12'hFE0, d); wr(12'hFE0, 2'b11);
        wr(12'hFE4, 2'b01); clks(10); wr(12'hFE0, 2'b01);
        wr(12'hFE4, 2'b10); wr(12'h010, 16'd99); clks(10); wr(12'hFE0, 2'b10); wr(12'h010, 16'd2); clks(10); wr(12'hFE0, 2'b11);
        wr(12'hFE4, 2'b11);
        for (int pos = 0; pos < 14; pos++) begin clks(pos % 7); wr(12'hFE0, 2'b11); end      // PERIOD 6: a clear lands on a boundary
        wr(12'h010, 16'd99); clks(8);
        for (int pos = 0; pos < 6; pos++) wr(12'hFE0, 2'b10);                                 // the clamp event is a level: it is set again
        wr(12'hFE4, 2'b00); wr(12'hFE8, 2'b11); clks(10); wr(12'hFE8, 2'b00);
        wr(12'h008, 0);

        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass
