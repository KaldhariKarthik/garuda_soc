// clic_test_lib.svh - tests for the CLIC environment (included in clic_env_pkg).
//
//   clic_reg_test       register model: reset values, bit bash, aliasing
//   clic_random_test    constrained-random sources and register traffic (+NTX=<n>)
//   clic_directed_test  the corners the plan names one by one

class clic_base_test extends uvm_test;
    `uvm_component_utils(clic_base_test)
    clic_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = clic_env::type_id::create("env", this);
    endfunction

    // ---- helpers used by the directed tests
    task wr(bit [11:0] a, bit [31:0] d);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 1; s.wdata = d; s.idle = 0;
        s.start(env.apb.sqr);
    endtask
    task rd(bit [11:0] a);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 0; s.idle = 0;
        s.start(env.apb.sqr);
    endtask
    task set_src(bit [31:0] v, int unsigned hold = 2, bit do_reset = 0);
        clic_src_one_seq s = clic_src_one_seq::type_id::create("s");
        s.src = v; s.hold = hold; s.do_reset = do_reset;
        s.start(env.src.sqr);
    endtask
    task set_level(int n, bit [7:0] l); wr(12'h100 + 4 * n, l); endtask
    task wait_reset_done();
        virtual clic_src_if vif;
        void'(uvm_config_db #(virtual clic_src_if)::get(this, "", "svif", vif));
        wait (vif.rst_n === 1'b1);
        repeat (2) @(posedge vif.hclk);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL);
        $display("tb_clic_uvm: test=%s uvm_errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

// ---------------------------------------------------------------- register model
class clic_reg_test extends clic_base_test;
    `uvm_component_utils(clic_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq  rst_seq;
        uvm_reg_bit_bash_seq  bash_seq;
        uvm_status_e st; uvm_reg_data_t v;
        phase.raise_objection(this);
        wait_reset_done();
        // ral_reset_value: every register against its reset value
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq");
        rst_seq.model = env.regmodel;
        rst_seq.start(null);
        // ral_access: every bit of every register against its access policy
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq");
        bash_seq.model = env.regmodel;
        bash_seq.start(null);
        // ral_aliasing: a different value in each of the 32 level registers and
        // in the enables, then every one read back
        env.regmodel.CLICIE.write(st, 32'h0055_AA54);
        foreach (env.regmodel.CLICINTCFG[i]) env.regmodel.CLICINTCFG[i].write(st, 8'h80 + i);
        env.regmodel.CLICIE.mirror(st, UVM_CHECK);
        env.regmodel.CLICINFO.mirror(st, UVM_CHECK);
        foreach (env.regmodel.CLICINTCFG[i]) env.regmodel.CLICINTCFG[i].mirror(st, UVM_CHECK);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

// ---------------------------------------------------------------- constrained random
class clic_random_test extends clic_base_test;
    `uvm_component_utils(clic_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        clic_src_rand_seq s_src = clic_src_rand_seq::type_id::create("s_src");
        clic_apb_rand_seq s_apb = clic_apb_rand_seq::type_id::create("s_apb");
        int unsigned ntx = 4000;
        void'($value$plusargs("NTX=%d", ntx));
        s_src.n = ntx; s_apb.n = ntx / 3;
        phase.raise_objection(this);
        wait_reset_done();
        fork
            s_src.start(env.src.sqr);
            s_apb.start(env.apb.sqr);
        join
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

// ---------------------------------------------------------------- directed corners
class clic_directed_test extends clic_base_test;
    `uvm_component_utils(clic_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function int next_assigned(int n);
        for (int k = n + 1; k < 32; k++) if (is_assigned(k)) return k;
        return -1;
    endfunction

    task run_phase(uvm_phase phase);
        bit [7:0] classes [4] = '{8'd0, 8'd1, 8'd100, 8'd255};
        int nx;
        phase.raise_objection(this);
        wait_reset_done();

        // ---- F05: every level register with every level class; F07 for the IDs with no source
        set_src(32'hFFFF_FFFF, 1);
        for (int n = 0; n < 32; n++) foreach (classes[c]) begin set_level(n, classes[c]); rd(12'h100 + 4 * n); end
        set_src(32'd0, 1);

        // ---- F02, F03: each enable bit set and cleared on its own; ones written to the hardwired bits
        wr(12'h004, 32'd0);
        for (int b = 0; b < 32; b++) begin wr(12'h004, 32'd1 << b); rd(12'h004); wr(12'h004, 32'd0); end
        wr(12'h004, 32'hFFFF_FFFF); rd(12'h004);

        // ---- F13, F15: each assigned ID as the only candidate, at each level class
        for (int n = 1; n < 32; n++) if (is_assigned(n)) foreach (classes[c]) begin
            set_level(n, classes[c]); set_src(32'd1 << n, 2);
        end
        set_src(32'd0, 1);

        // ---- F14: every adjacent pair of assigned IDs tied at the top level; ties of 3 and of 5
        for (int n = 0; n < 32; n++) set_level(n, 8'd10);
        for (int n = 1; n < 32; n++) if (is_assigned(n)) begin
            nx = next_assigned(n);
            if (nx < 0) continue;
            set_level(n, 8'd200); set_level(nx, 8'd200);
            set_src((32'd1 << n) | (32'd1 << nx) | 32'h0040_0002, 2);     // plus two lower-level bystanders
            set_level(n, 8'd10); set_level(nx, 8'd10);
        end
        set_src(32'h0000_000E, 2);                                         // three tied at level 10
        set_src(32'h0000_7F00, 2);                                         // six tied
        // ---- F13: candidate counts 1, 2, 3-5, 6-20, 21
        set_src(32'h0000_0002, 2); set_src(32'h0000_0006, 2); set_src(32'h0000_001E, 2);
        set_src(32'h0000_FF00, 2); set_src(32'hFFFF_FFFF, 2);

        // ---- F11: pulses of 1, 2 and 3 hclk on each assigned line
        for (int n = 1; n < 32; n++) if (is_assigned(n)) for (int len = 1; len <= 3; len++) begin
            set_src(32'd1 << n, len); set_src(32'd0, 1);
        end

        // ---- F17, F18: lines with no ID driven high, alone and with others
        set_src(32'h0000_0001, 2); set_src(32'h0000_0003, 2);
        set_src(32'h0000_0080, 2);
        for (int b = 23; b < 32; b++) set_src(32'd1 << b, 2);
        set_src(32'd0, 1);

        // ---- F04: CLICIP read with no, one, several and all sources; written and read again
        rd(12'h008); set_src(32'h0000_0400, 3); rd(12'h008);
        set_src(32'h0000_0C06, 3); rd(12'h008); wr(12'h008, 32'hFFFF_FFFF); rd(12'h008);
        set_src(32'hFFFF_FFFF, 3); rd(12'h008); wr(12'h008, 32'd0); rd(12'h008);
        set_src(32'd0, 1);
        // ---- F01: CLICINFO written
        wr(12'h000, 32'hFFFF_FFFF); rd(12'h000); wr(12'h000, 32'd0); rd(12'h000);

        // ---- F08: offsets that do not exist, read and written
        rd(12'h00C); wr(12'h00C, 32'hFFFF_FFFF); rd(12'h0FC); wr(12'h0FC, 32'hFFFF_FFFF);
        rd(12'h180); wr(12'h180, 32'hFFFF_FFFF); rd(12'hFFC); wr(12'hFFC, 32'hFFFF_FFFF);
        rd(12'h101); wr(12'h102, 32'hFFFF_FFFF); rd(12'h17E); wr(12'h17F, 32'hFFFF_FFFF);
        rd(12'h004);

        // ---- F20: the winner's level lowered below another candidate; a loser raised above the winner
        wr(12'h004, 32'hFFFF_FFFF);
        for (int n = 0; n < 32; n++) set_level(n, 8'd10);
        set_level(5, 8'd200); set_level(9, 8'd150);
        set_src(32'h0000_0220, 4);
        set_level(5, 8'd20);            // winner 5 drops below 9
        set_level(5, 8'd250);           // loser 5 rises above 9
        // ---- F21: the winner disabled with none, one and several other candidates; a higher one enabled
        set_src(32'h0000_0020, 3); wr(12'h004, 32'hFFFF_FFDF); wr(12'h004, 32'hFFFF_FFFF);
        set_src(32'h0000_0220, 3); wr(12'h004, 32'hFFFF_FFDF); wr(12'h004, 32'hFFFF_FFFF);
        set_src(32'h0000_0E20, 3); wr(12'h004, 32'hFFFF_FFDF); wr(12'h004, 32'hFFFF_FFFF);
        set_src(32'd0, 1);

        // ---- F22: register writes while the sources change every cycle
        fork
            begin clic_src_rand_seq s = clic_src_rand_seq::type_id::create("s"); s.n = 300; s.start(env.src.sqr); end
            begin clic_apb_rand_seq a = clic_apb_rand_seq::type_id::create("a"); a.n = 120; a.start(env.apb.sqr); end
        join

        // ---- F10: reset with the sources high, and reset after register traffic
        wr(12'h004, 32'hFFFF_FFFF); set_level(3, 8'd77);
        set_src(32'h0000_0008, 2);
        set_src(32'h0000_0008, 2, 1);                  // reset with a source high
        rd(12'h004); rd(12'h10C);
        wr(12'h004, 32'hFFFF_FFFF);
        set_src(32'd0, 2, 1);                          // reset after traffic, no source
        rd(12'h004);

        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass
