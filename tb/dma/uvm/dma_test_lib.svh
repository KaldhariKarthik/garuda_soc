// dma_test_lib.svh - tests for the DMA environment (included in dma_env_pkg).
//
//   dma_reg_test       register model: reset values, bit bash, aliasing (F01, F04, F05, F11)
//   dma_directed_test  the plan's features one by one (F01..F33)
//   dma_random_test    constrained-random programs on all six channels (+NTX=<n>)

class dma_base_test extends uvm_test;
    `uvm_component_utils(dma_base_test)
    dma_env env;
    virtual dma_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = dma_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual dma_if)::get(this, "", "dvif", vif))
            `uvm_fatal("NOVIF", "dma_base_test: no virtual interface")
    endfunction

    // ---- addresses: a region per channel, so a read identifies its channel
    function bit [31:0] src(int ch); return 32'h2000_0000 + 32'h1_0000 * ch; endfunction
    function bit [31:0] dst(int ch); return 32'h2008_0000 + 32'h1_0000 * ch; endfunction
    function bit [31:0] per(int ch); return 32'h4000_0000 + 32'h100 * ch; endfunction   // a peripheral data register
    localparam bit [31:0] ERRA = 32'h2FF0_0000;                                         // the slave answers ERROR

    // ---- register access
    task wr(bit [11:0] a, bit [31:0] d);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 1; s.wdata = d; s.idle = 0;
        s.start(env.apb.sqr);
    endtask
    task rd(bit [11:0] a, output bit [31:0] d);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 0; s.idle = 0;
        s.start(env.apb.sqr);
        d = s.rdata;
    endtask
    task rd_(bit [11:0] a); bit [31:0] d; rd(a, d); endtask
    function bit [11:0] ra(int ch, int r); return 12'h020 * ch + 4 * r; endfunction   // CR 0 SAR 1 DAR 2 CNT 3 STAT 4 ICLR 5

    function bit [31:0] cr(int mode, int size, bit sinc, bit dinc, bit iec, bit iee, bit en);
        return {23'd0, iee, iec, size[1:0], dinc, sinc, mode[1:0], en};
    endfunction

    // program a channel and set EN
    task prog(int ch, int mode, int size, bit sinc, bit dinc, bit [31:0] s, bit [31:0] d,
                 int cnt, bit iec = 1, bit iee = 1);
        wr(ra(ch, 1), s);
        wr(ra(ch, 2), d);
        wr(ra(ch, 3), cnt);
        wr(ra(ch, 0), cr(mode, size, sinc, dinc, iec, iee, 1));
    endtask

    // the usual setting of each mode ([N-7.2] table)
    task program_mode(int ch, int mode, int size, int cnt, int soff = 0, int doff = 0, bit iec = 1, bit iee = 1);
        case (mode)
            P2M:     prog(ch, P2M, size, 0, 1, per(ch) + soff, dst(ch) + doff, cnt, iec, iee);
            M2P:     prog(ch, M2P, size, 1, 0, src(ch) + soff, per(ch) + 32'h80 + doff, cnt, iec, iee);
            default: prog(ch, M2M, size, 1, 1, src(ch) + soff, dst(ch) + doff, cnt, iec, iee);
        endcase
    endtask

    // peripheral requests for a channel (returns at once; the driver runs them)
    task reqs(int ch, int n, int width = 0, int gap = 1, int max_wait_pclk = 4000);
        dma_req_seq q = dma_req_seq::type_id::create("q");
        q.ch = ch; q.n = n; q.width = width; q.gap = gap; q.max_wait_pclk = max_wait_pclk;
        q.start(env.reqs.sqr);
    endtask

    // poll STAT until the channel is no longer active; every poll is a compared read
    task wait_done(int ch, output bit [31:0] stat, input int unsigned max_polls = 3000);
        int unsigned k = 0;
        do begin rd(ra(ch, 4), stat); k++; end while (stat[16] && k < max_polls);
        if (stat[16]) `uvm_error("HANG", $sformatf("channel %0d still active after %0d status reads: STAT %08h", ch, k, stat))
    endtask
    task run_one(int ch, int mode, int size, int cnt, int soff = 0, int doff = 0, int width = 0);
        bit [31:0] st;
        program_mode(ch, mode, size, cnt, soff, doff);
        if (mode != M2M) reqs(ch, cnt, width);
        wait_done(ch, st);
        env.reqs.drv.stop(ch);
        wr(ra(ch, 5), 32'h3);                                    // ICLR both
    endtask

    task wait_reset_done();
        wait (vif.rst_n === 1'b1);
        repeat (4) @(posedge vif.hclk);
    endtask
    task cycles(int n); repeat (n) @(posedge vif.hclk); endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL);
        $display("tb_dma_uvm: test=%s uvm_errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

// ---------------------------------------------------------------- register model
class dma_reg_test extends dma_base_test;
    `uvm_component_utils(dma_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq;
        uvm_reg_bit_bash_seq bash_seq;
        uvm_status_e st;
        phase.raise_objection(this);
        wait_reset_done();
        // ral_access: reset values of every register (CR resets to 0x40: SIZE = word)
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq");
        rst_seq.model = env.regmodel;
        rst_seq.start(null);
        // bit bash: SAR, DAR and CNT. Not CR (EN starts a transfer; MODE and SIZE
        // refuse 3, checked in the directed test), not STAT / GSTAT (a write is
        // refused with PSLVERR) and not ICLR (write-only strobes).
        foreach (env.regmodel.CH[n]) begin
            uvm_resource_db #(bit)::set({"REG::", env.regmodel.CH[n].CR.get_full_name()},   "NO_REG_BIT_BASH_TEST", 1);
            uvm_resource_db #(bit)::set({"REG::", env.regmodel.CH[n].STAT.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1);
            uvm_resource_db #(bit)::set({"REG::", env.regmodel.CH[n].ICLR.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1);
        end
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.GSTAT.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq");
        bash_seq.model = env.regmodel;
        bash_seq.start(null);
        // ral_aliasing (F11): a different value in every writable register of every
        // channel, CR with EN 0, then every one read back
        foreach (env.regmodel.CH[n]) begin
            env.regmodel.CH[n].SAR.write(st, 32'h2000_0000 + 32'h111 * n + 4);
            env.regmodel.CH[n].DAR.write(st, 32'h2008_0000 + 32'h222 * n + 8);
            env.regmodel.CH[n].CNT.write(st, 16'h100 + n);
            env.regmodel.CH[n].CR.write(st, {23'd0, n[0], ~n[0], n[1:0] == 3 ? 2'd2 : n[1:0], n[1], n[0], 2'(n % 3), 1'b0});
        end
        foreach (env.regmodel.CH[n]) begin
            env.regmodel.CH[n].SAR.mirror(st, UVM_CHECK);
            env.regmodel.CH[n].DAR.mirror(st, UVM_CHECK);
            env.regmodel.CH[n].CNT.mirror(st, UVM_CHECK);
            env.regmodel.CH[n].CR.mirror(st, UVM_CHECK);
            env.regmodel.CH[n].STAT.mirror(st, UVM_CHECK);
        end
        env.regmodel.GSTAT.mirror(st, UVM_CHECK);
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

// ---------------------------------------------------------------- directed features
class dma_directed_test extends dma_base_test;
    `uvm_component_utils(dma_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        bit [31:0] st, d;
        phase.raise_objection(this);
        wait_reset_done();

        // ---- F01, F02, F03: CR fields; MODE 3 and SIZE 3 refused, with EN 0 and 1
        for (int ch = 0; ch < NCH; ch++) begin
            wr(ra(ch, 0), cr(2, 1, 1, 0, 1, 0, 0)); rd_(ra(ch, 0));
            wr(ra(ch, 0), cr(3, 3, 0, 1, 0, 1, 0)); rd_(ra(ch, 0));       // both refused, the rest lands
            wr(ra(ch, 0), 32'hFFFF_FE00);           rd_(ra(ch, 0));       // reserved bits read 0
            wr(ra(ch, 0), 32'd0);
        end
        wr(ra(0, 3), 0); wr(ra(0, 0), cr(3, 3, 1, 1, 0, 0, 1)); rd_(ra(0, 0)); rd_(ra(0, 4));   // with EN: CNT 0 completes
        wr(ra(0, 5), 32'h3);

        // ---- F09: offsets that do not exist, read and written; STAT and GSTAT written
        rd_(12'h0C0); wr(12'h0C0, 32'hFFFF_FFFF); rd_(12'h0FC); wr(12'h0E4, 32'h1);
        rd_(12'h018); wr(12'h01C, 32'hFFFF_FFFF); rd_(12'h03C);
        rd_(12'h104); wr(12'h104, 32'h1); rd_(12'h200); wr(12'hFFC, 32'h1);
        rd_(12'h002); wr(12'h006, 32'h1); rd_(12'h101);
        wr(ra(2, 4), 32'hFFFF_FFFF); wr(12'h100, 32'hFFFF_FFFF); rd_(ra(2, 4)); rd_(12'h100);

        // ---- F13 .. F17, F19, F22: every channel, every mode, every size
        for (int ch = 0; ch < NCH; ch++)
            for (int mode = 0; mode < 3; mode++)
                for (int size = 0; size < 3; size++) begin
                    int so = (size == 0) ? (ch + mode) % 4 : (size == 1) ? 2 * (ch % 2) : 0;
                    int dof = (size == 0) ? (ch + mode + size + 1) % 4 : (size == 1) ? 2 * ((ch + 1) % 2) : 0;
                    run_one(ch, mode, size, 3, so, dof);
                end
        // byte beats at every source and destination offset (F17, x_size_offset)
        for (int so = 0; so < 4; so++) for (int dof = 0; dof < 4; dof++) run_one(1, M2M, 0, 1, so, dof);
        for (int so = 0; so < 4; so += 2) for (int dof = 0; dof < 4; dof += 2) run_one(2, M2M, 1, 1, so, dof);

        // ---- F05, F18: CNT 0, 1, 2 and a longer count
        run_one(3, M2M, 2, 0); run_one(3, M2M, 2, 1); run_one(3, M2M, 2, 2); run_one(3, M2M, 2, 37);

        // ---- F07, F33: ICLR before and after the flag; interrupt enable set after the flag
        wr(ra(4, 5), 32'h3);                                             // nothing to clear
        program_mode(4, M2M, 2, 2, 0, 0, 0, 0); wait_done(4, st);
        rd_(ra(4, 4));
        wr(ra(4, 0), cr(M2M, 2, 1, 1, 1, 1, 0));                         // IE_COMP after COMPLETE
        cycles(4); wr(ra(4, 5), 32'h1); rd_(ra(4, 4));

        // ---- F29, F30, F31: bus errors on the read and on the write, first / middle / last beat
        // first beat, read: the source is in the error window
        prog(0, M2M, 2, 1, 1, ERRA, dst(0), 4); wait_done(0, st); wr(ra(0, 5), 32'h3);
        // middle beat, read: the third word crosses into the window
        prog(0, M2M, 2, 1, 1, ERRA - 8, dst(0), 5); wait_done(0, st); wr(ra(0, 5), 32'h3);
        // last beat, read
        prog(0, M2M, 2, 1, 1, ERRA - 8, dst(0), 3); wait_done(0, st); wr(ra(0, 5), 32'h3);
        // write errors, first / middle / last
        prog(1, M2M, 2, 1, 1, src(1), ERRA, 4); wait_done(1, st); wr(ra(1, 5), 32'h3);
        prog(1, M2M, 2, 1, 1, src(1), ERRA - 4, 4); wait_done(1, st); wr(ra(1, 5), 32'h3);
        prog(1, M2M, 2, 1, 1, src(1), ERRA - 8, 3); wait_done(1, st); wr(ra(1, 5), 32'h3);
        // errors in the peripheral modes
        prog(2, P2M, 2, 0, 1, ERRA + 32'h10, dst(2), 3); reqs(2, 3, 0, 1, 200); wait_done(2, st);
        env.reqs.drv.stop(2); wr(ra(2, 5), 32'h3);
        prog(2, M2P, 1, 1, 0, src(2), ERRA + 32'h20, 3); reqs(2, 3, 0, 1, 200); wait_done(2, st);
        env.reqs.drv.stop(2); wr(ra(2, 5), 32'h3);
        prog(2, P2M, 0, 0, 1, per(2), ERRA + 1, 2); reqs(2, 2, 0, 1, 200); wait_done(2, st);
        env.reqs.drv.stop(2); wr(ra(2, 5), 32'h3);
        prog(3, M2P, 0, 1, 0, ERRA - 1, per(3), 2); reqs(3, 2, 0, 1, 200); wait_done(3, st);
        env.reqs.drv.stop(3); wr(ra(3, 5), 32'h3);
        // F30: an error on one channel while another is mid-transfer
        prog(5, M2M, 2, 1, 1, src(5), dst(5), 30);
        prog(0, M2M, 2, 1, 1, ERRA, dst(0), 2);
        wait_done(0, st); wait_done(5, st); wr(ra(0, 5), 32'h3); wr(ra(5, 5), 32'h3);
        // F31: no retry - the failed channel stays stopped; firmware repairs and re-arms it
        prog(0, M2M, 2, 1, 1, src(0), dst(0), 2); wait_done(0, st); wr(ra(0, 5), 32'h3);

        // ---- F32: ISRAM and Boot ROM addresses refused with a clean error, no transfer
        prog(4, M2M, 2, 1, 1, 32'h0000_0100, dst(4), 2); wait_done(4, st); wr(ra(4, 5), 32'h3);
        prog(4, M2M, 2, 1, 1, src(4), 32'h1000_0040, 2); wait_done(4, st); wr(ra(4, 5), 32'h3);
        prog(4, M2M, 2, 1, 1, 32'h1000_0000, 32'h0000_0000, 2, 0, 0); cycles(40); rd_(ra(4, 4)); rd_(12'h100);
        wr(ra(4, 0), 32'd0); wr(ra(4, 5), 32'h3);

        // ---- F20: EN cleared in the middle of a transfer, then set again
        prog(5, M2M, 2, 1, 1, src(5), dst(5), 40);
        cycles(30); wr(ra(5, 0), cr(M2M, 2, 1, 1, 1, 1, 0));
        rd_(ra(5, 4)); rd_(ra(5, 1)); rd_(ra(5, 2)); cycles(20); rd_(ra(5, 4));
        wr(ra(5, 0), cr(M2M, 2, 1, 1, 1, 1, 1)); wait_done(5, st); wr(ra(5, 5), 32'h3);

        // ---- F12: SAR, DAR and CNT written while the channel runs
        prog(5, M2M, 2, 1, 1, src(5), dst(5), 30);
        cycles(20); wr(ra(5, 1), src(5) + 32'h400); cycles(12); wr(ra(5, 2), dst(5) + 32'h400);
        cycles(12); wr(ra(5, 3), 3);
        wait_done(5, st); wr(ra(5, 5), 32'h3);

        // ---- F26, F27, F28: fixed priority; every pair together, then all six
        for (int i = 0; i < NCH; i++)
            for (int j = i + 1; j < NCH; j++) begin
                prog(i, M2M, 2, 1, 1, src(i), dst(i), 3);
                prog(j, M2M, 2, 1, 1, src(j), dst(j), 3);
                wait_done(i, st); wait_done(j, st);
                wr(ra(i, 5), 32'h3); wr(ra(j, 5), 32'h3);
            end
        for (int ch = 0; ch < NCH; ch++) prog(ch, M2M, 2, 1, 1, src(ch), dst(ch), 12);
        for (int ch = 0; ch < NCH; ch++) wait_done(ch, st);
        for (int ch = 0; ch < NCH; ch++) wr(ra(ch, 5), 32'h3);

        // ---- F21: one beat per request assertion: one pclk, several, held to the acknowledge.
        // A short pulse that comes and goes while the channel's previous beat is
        // still on the bus is withdrawn before its grant and gives no beat
        // ([N-7.10], F23), so short pulses are repeated until the channel is done.
        program_mode(1, P2M, 2, 3); reqs(1, 12, 1, 2); wait_done(1, st); env.reqs.drv.stop(1); wr(ra(1, 5), 32'h3);
        program_mode(1, P2M, 2, 3); reqs(1, 12, 4, 2); wait_done(1, st); env.reqs.drv.stop(1); wr(ra(1, 5), 32'h3);
        program_mode(1, M2P, 2, 3); reqs(1, 3, 12, 1); wait_done(1, st); env.reqs.drv.stop(1); wr(ra(1, 5), 32'h3);
        // F23: a request withdrawn while it waits behind a higher channel
        prog(0, M2M, 2, 1, 1, src(0), dst(0), 40);
        program_mode(5, P2M, 2, 2);
        reqs(5, 1, 1, 1);                                  // one pclk, while channel 0 holds the bus
        wait_done(0, st);
        reqs(5, 2, 0, 1); wait_done(5, st); wr(ra(0, 5), 32'h3); wr(ra(5, 5), 32'h3);
        // F25: requests to a disabled channel are ignored
        reqs(3, 2, 2, 2); env.reqs.drv.wait_idle(3); rd_(ra(3, 4));

        // ---- F33: interrupt enables off, on, and set after the flag, for both kinds
        for (int ch = 0; ch < NCH; ch++) begin
            program_mode(ch, M2M, 2, 1, 0, 0, ch[0], ~ch[0]); wait_done(ch, st);
            wr(ra(ch, 0), cr(M2M, 2, 1, 1, 1, 1, 0)); cycles(4); wr(ra(ch, 5), 32'h3);
            prog(ch, M2M, 2, 1, 1, ERRA, dst(ch), 1, ~ch[0], ch[0]); wait_done(ch, st);
            wr(ra(ch, 0), cr(M2M, 2, 1, 1, 1, 1, 0)); cycles(4); wr(ra(ch, 5), 32'h3);
        end

        // ---- background reads while two channels run (sb_stat in every cycle of a transfer)
        prog(4, M2M, 1, 1, 1, src(4), dst(4), 20);
        program_mode(2, P2M, 0, 10); reqs(2, 10, 0, 0);
        begin dma_poll_seq p = dma_poll_seq::type_id::create("p"); p.n = 120; p.start(env.apb.sqr); end
        wait_done(4, st); wait_done(2, st); wr(ra(4, 5), 32'h3); wr(ra(2, 5), 32'h3);
        rd_(12'h100);

        phase.phase_done.set_drain_time(this, 200ns);
        phase.drop_objection(this);
    endtask
endclass

// ---------------------------------------------------------------- constrained random
class dma_random_test extends dma_base_test;
    `uvm_component_utils(dma_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    bit busy [NCH];
    int unsigned n_done;

    // one random transfer on channel ch, then wait for it and clear its flags
    task one_program(int ch);
        int mode = $urandom_range(0, 2);
        int size = $urandom_range(0, 2);
        int cnt  = $urandom_range(1, 16);
        int step = (size == 0) ? 1 : (size == 1) ? 2 : 4;
        int fault = $urandom_range(0, 99);
        bit sinc, dinc, iec = $urandom_range(0, 1), iee = $urandom_range(0, 1);
        bit [31:0] s, d, st;
        // a source and a destination in the channel's own regions, aligned to the size
        s = src(ch) + (($urandom_range(0, 255) * step) & 32'hFFF0) + (size == 0 ? $urandom_range(0, 3) : size == 1 ? 2 * $urandom_range(0, 1) : 0);
        d = dst(ch) + (($urandom_range(0, 255) * step) & 32'hFFF0) + (size == 0 ? $urandom_range(0, 3) : size == 1 ? 2 * $urandom_range(0, 1) : 0);
        case (mode)
            P2M: begin s = per(ch) + (size == 2 ? 0 : size == 1 ? 2 : ch % 4); sinc = 0; dinc = 1; end
            M2P: begin d = per(ch) + 32'h80 + (size == 2 ? 0 : size == 1 ? 2 : ch % 4); sinc = 1; dinc = 0; end
            default: begin sinc = $urandom_range(0, 1); dinc = $urandom_range(0, 1); end
        endcase
        // (each channel has its own part of the error window, so a read still names its channel)
        if (fault < 4)       s = ERRA + 32'h1000 * ch + (s & 32'hFF);    // bus error on the read
        else if (fault < 8)  d = ERRA + 32'h1000 * ch + (d & 32'hFF);    // bus error on the write
        else if (fault < 10) s = 32'h0000_0400 + (s & 32'hF);            // refused source (ISRAM)
        else if (fault < 12) d = 32'h1000_0400 + (d & 32'hF);            // refused destination (Boot ROM)
        prog(ch, mode, size, sinc, dinc, s, d, cnt, iec, iee);
        if (mode != M2M) begin
            // held to the acknowledge, or short pulses repeated until done (a short
            // pulse can be withdrawn before its grant and give no beat, F23)
            int w = ($urandom_range(0, 3) == 0) ? 0 : $urandom_range(1, 4);
            reqs(ch, w == 0 ? cnt : 4 * cnt + 8, w, $urandom_range(0, 3), 400);
        end
        // A low channel can wait a long time behind higher ones; a peripheral that
        // gave up asking asks again while the channel still has beats to move.
        begin
            int unsigned polls = 0;
            do begin
                rd(ra(ch, 4), st); polls++;
                if (st[16] && mode != M2M && !env.reqs.drv.busy[ch]) reqs(ch, st[15:0], 0, 1, 400);
            end while (st[16] && polls < 6000);
            if (st[16]) `uvm_error("HANG", $sformatf("channel %0d still active after %0d status reads: STAT %08h", ch, polls, st))
        end
        env.reqs.drv.stop(ch);
        if ($urandom_range(0, 3) != 0) wr(ra(ch, 5), 32'h3);
        n_done++;
        busy[ch] = 0;
    endtask

    task run_phase(uvm_phase phase);
        int unsigned ntx = 60, started = 0;
        void'($value$plusargs("NTX=%d", ntx));
        phase.raise_objection(this);
        wait_reset_done();
        fork
            begin                                           // background register reads
                dma_poll_seq p = dma_poll_seq::type_id::create("p");
                p.n = ntx * 4;
                p.start(env.apb.sqr);
            end
            begin
                while (started < ntx) begin
                    int ch = $urandom_range(0, NCH - 1);
                    if (!busy[ch]) begin
                        busy[ch] = 1; started++;
                        begin
                            automatic int c = ch;
                            fork one_program(c); join_none
                        end
                    end
                    cycles($urandom_range(2, 30));
                end
                while (n_done < started) cycles(10);
            end
        join
        rd_(12'h100);
        `uvm_info("RANDOM", $sformatf("%0d random programs finished", n_done), UVM_NONE)
        phase.phase_done.set_drain_time(this, 200ns);
        phase.drop_objection(this);
    endtask
endclass
