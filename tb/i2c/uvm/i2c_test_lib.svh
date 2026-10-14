// i2c_test_lib.svh - tests for the I2C environment (included in i2c_env_pkg).
//
//   i2c_reg_test       register model: reset values and bit bash
//   i2c_random_test    random transfers to a slave that refuses, stretches and is sometimes
//                      absent, with aborts and timeouts in between (+NXFER=<n>)
//   i2c_directed_test  the corners the plan names one by one

class i2c_base_test extends uvm_test;
    `uvm_component_utils(i2c_base_test)
    localparam bit [4:0] STA = 5'h01, STO = 5'h02, RD = 5'h04, WR = 5'h08, NACK = 5'h10;
    i2c_env env;
    virtual i2c_if vif;
    bit dma_on;                               // the DMA responder answers requests
    bit quit;                                 // a transfer in progress is being given up: its thread stops
    bit [15:0] ps;                            // PRESCALE as last written by setup()
    bit        en_set;
    int unsigned n_dma;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = i2c_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual i2c_if)::get(this, "", "ivif", vif)) `uvm_fatal("NOVIF", "test: no i2c_if")
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
        #1 vif.rst_req = 1'b1; clks(n); vif.rst_req = 1'b0; clks(2); wait_reset_done();
    endtask
    // one SCL bit, in pclk
    function int unsigned bit_time(); return 5 * (ps + 1) + ps / 4 + 12; endfunction

    // PRESCALE is changed with EN clear: with EN set the bit controller goes on counting the old
    // prescaler period before it takes the new one, up to 65536 pclk ([N-6.1b])
    task setup(bit [15:0] prescale = 16'd3, bit [15:0] timeout = 16'd0);
        if (prescale != ps || !en_set) begin wr(12'h004, 32'h0); wr(12'h000, prescale); end
        ps = prescale; en_set = 1;
        wr(12'h018, timeout); wr(12'h004, 32'h1); clks(2);
    endtask
    // poll STATUS until no transfer is in progress
    task wait_tip(output bit [31:0] st, input int unsigned max = 400);
        int unsigned n = 0;
        forever begin
            rd(12'h014, st);
            if (!st[0] || quit) break;
            if (++n > max * 12) begin `uvm_error("TEST", "TIP never cleared") break; end
            clks(bit_time() / 8 + 1);
        end
    endtask
    task cmd(bit [4:0] c, output bit [31:0] st);
        st = 0;
        if (quit) return;
        wr(12'h010, c);
        wait_tip(st);
    endtask
    // START, address, data bytes, STOP. nacked: the slave refused the address or a byte.
    task xfer_write(bit [6:0] a, bit [7:0] data[$], input bit stop = 1, output bit nacked);
        bit [31:0] st;
        nacked = 0;
        if (quit) return;
        wr(12'h008, {a, 1'b0}); cmd(STA | WR, st);
        if (quit) return;
        if (st[3]) begin nacked = 1; cmd(STO, st); return; end
        foreach (data[i]) begin
            if (quit) return;
            wr(12'h008, data[i]);
            cmd(WR | ((i == data.size() - 1 && stop) ? STO : 5'h0), st);
            if (quit) return;
            if (st[3]) begin nacked = 1; if (!(i == data.size() - 1 && stop)) cmd(STO, st); return; end
        end
        if (data.size() == 0 && stop) cmd(STO, st);
    endtask
    // START, address with the read bit, n bytes (the last one not acknowledged), STOP
    task xfer_read(bit [6:0] a, int unsigned n, output bit [7:0] data[$], input bit stop = 1, output bit nacked);
        bit [31:0] st, d;
        nacked = 0; data.delete();
        if (quit) return;
        wr(12'h008, {a, 1'b1}); cmd(STA | WR, st);
        if (quit) return;
        if (st[3]) begin nacked = 1; cmd(STO, st); return; end
        for (int unsigned i = 0; i < n; i++) begin
            if (quit) return;
            cmd(RD | ((i == n - 1) ? (NACK | (stop ? STO : 5'h0)) : 5'h0), st);
            if (quit) return;
            rd(12'h00C, d); data.push_back(d[7:0]);
        end
        // a byte read is never "not acknowledged by the slave": IRQSTAT bit 3 belongs to written bytes
        clks(4); rd(12'hFE0, d);
        if (d[3]) `uvm_error("TEST", "IRQSTAT bit 3 (NACK) set after a read")
    endtask
    // After an abort, a timeout or a lost arbitration nothing sent a STOP ([N-7.5a]). The slave
    // gives up, and firmware sends a STOP so that every device and BUSY see the bus free.
    task recover();
        bit [31:0] st;
        quit = 0;
        env.slave.release_all(); env.other.release_all();
        clks(12);
        wr(12'h004, 32'h1); clks(2);
        cmd(STO, st);
        clks(ps + 30);
        env.sb.tight();
    endtask

    // What the DMA does with a request: for a received byte it reads RXDATA; when the block is
    // ready to send it writes TXDATA. Then it acknowledges for one pclk.
    task dma_responder();
        bit [31:0] d;
        forever begin
            @(vif.cb);
            if (dma_on && vif.cb.dma_req === 1'b1) begin
                clks($urandom_range(0, 3));
                rd(12'hFE8, d);
                if (d[0]) rd(12'h00C, d); else wr(12'h008, $urandom_range(0, 255));
                @(posedge vif.pclk); vif.dma_ack <= 1'b1;
                @(posedge vif.pclk); vif.dma_ack <= 1'b0;
                n_dma++;
                clks(2);
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) + env.sb.n_err;
        $display("tb_i2c_uvm: test=%s errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

class i2c_reg_test extends i2c_base_test;
    `uvm_component_utils(i2c_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq; uvm_reg_bit_bash_seq bash_seq;
        phase.raise_objection(this);
        wait_reset_done();
        // a bit written to CMD starts a transfer and CTRL.EN enables the core: the bus then moves
        // by itself. Both are exercised by the other two tests; here they keep their reset value.
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.CMD.get_full_name()},     "NO_REG_BIT_BASH_TEST", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.STATUS.get_full_name()},  "NO_REG_BIT_BASH_TEST", 1, this);
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq"); rst_seq.model = env.regmodel; rst_seq.start(null);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq"); bash_seq.model = env.regmodel; bash_seq.start(null);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

class i2c_random_test extends i2c_base_test;
    `uvm_component_utils(i2c_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        int unsigned nx = 120; bit [7:0] wdat[$], rdat[$]; bit nacked; bit [31:0] d; int k;
        void'($value$plusargs("NXFER=%d", nx));
        phase.raise_objection(this);
        wait_reset_done();
        fork dma_responder(); join_none
        repeat (nx) begin
            i2c_slave_cfg c = env.scfg;
            int unsigned len = $urandom_range(1, 10);
            bit [6:0] a = ($urandom_range(0, 9) == 0) ? 7'h2A : c.addr;      // sometimes nobody is there
            c.plain();
            if ($urandom_range(0, 9) == 0) c.nack_data_at = $urandom_range(0, len - 1);
            if ($urandom_range(0, 3) == 0) c.stretch_addr = $urandom_range(10, 900);
            if ($urandom_range(0, 3) == 0) c.stretch_data = $urandom_range(10, 900);
            if ($urandom_range(0, 5) == 0) c.stretch_mid  = $urandom_range(10, 400);
            `uvm_info("TEST", $sformatf("transfer: len %0d addr %02h nack_at %0d stretch addr %0d data %0d mid %0d", len, a, c.nack_data_at, c.stretch_addr, c.stretch_data, c.stretch_mid), UVM_HIGH)
            setup(($urandom_range(0, 7) == 0) ? $urandom_range(15, 40) : $urandom_range(3, 14),
                  ($urandom_range(0, 2) == 0) ? 16'hFFFF : 16'd0);
            wr(12'hFE4, $urandom_range(0, 15));
            wr(12'hFE8, ($urandom_range(0, 3) == 0) ? 32'h1 : 32'h0); dma_on = 0;
            k = $urandom_range(0, 99);
            if (k < 40) begin                                                // a write
                wdat.delete(); repeat (len) wdat.push_back($urandom_range(0, 255));
                c.wr_seen.delete();
                xfer_write(a, wdat, 1, nacked);
                if (!nacked && c.wr_seen != wdat) `uvm_error("TEST", $sformatf("the slave received %p, firmware wrote %p", c.wr_seen, wdat))
            end else if (k < 75) begin                                       // a read
                c.rd_sent.delete();
                xfer_read(a, len, rdat, 1, nacked);
                if (!nacked && rdat != c.rd_sent) `uvm_error("TEST", $sformatf("firmware read %p, the slave sent %p", rdat, c.rd_sent))
            end else if (k < 88) begin                                       // a register read: write, repeated START, read
                wdat.delete(); wdat.push_back($urandom_range(0, 255));
                xfer_write(a, wdat, 0, nacked);
                if (!nacked) begin
                    c.rd_sent.delete();
                    xfer_read(a, len, rdat, 1, nacked);
                    if (!nacked && rdat != c.rd_sent) `uvm_error("TEST", $sformatf("firmware read %p, the slave sent %p", rdat, c.rd_sent))
                end
            end else if (k < 94) begin                                       // a transfer given up by ABORT at any moment
                wdat.delete(); repeat (len) wdat.push_back($urandom_range(0, 255));
                fork
                    xfer_write(a, wdat, 1, nacked);
                    begin clks($urandom_range(1, (len + 1) * 9 * bit_time())); quit = 1; wr(12'h004, 32'h3); end
                join
                clks(8); recover();
            end else begin                                                   // a transfer the timeout gives up
                c.stretch_addr = 40 * 9 * bit_time() * 10;                   // the slave holds SCL for a long time
                wr(12'h018, 9 * bit_time() + 40);
                wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR);
                wait_tip(d, 2000);
                if (!d[4]) `uvm_error("TEST", "no timeout with SCL held low by the slave")
                clks(8); recover();
            end
            clks(4); rd(12'hFE0, d); rd(12'h014, d);
            wr(12'hFE0, 32'hF);
            if ($urandom_range(0, 3) == 0) begin rd(12'hFE0, d); rd(12'h014, d); end
            if ($urandom_range(0, 9) == 0) begin dma_on = 1; wr(12'hFE8, $urandom_range(1, 3)); clks(30); wr(12'hFE8, 32'h0); dma_on = 0; clks(6); end
        end
        if (env.sb.n_ev_cmp < 20 * nx / 4) `uvm_error("TEST", $sformatf("only %0d bus events were compared with a command", env.sb.n_ev_cmp))
        phase.phase_done.set_drain_time(this, 400ns);
        phase.drop_objection(this);
    endtask
endclass

class i2c_directed_test extends i2c_base_test;
    `uvm_component_utils(i2c_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task expect_status(string what, bit [5:0] mask, bit [5:0] val);
        bit [31:0] d;
        rd(12'h014, d);
        if ((d[5:0] & mask) !== (val & mask)) `uvm_error("TEST", $sformatf("%s: STATUS %06b, expected %06b under the mask %06b", what, d[5:0], val, mask))
    endtask

    task run_phase(uvm_phase phase);
        bit [31:0] d, st; bit nacked; bit [7:0] wdat[$], rdat[$]; i2c_slave_cfg c;
        phase.raise_objection(this);
        wait_reset_done();
        c = env.scfg;

        // ---- F01 to F12: every register read and written with EN clear; every kind of offset that is not a register
        `uvm_info("TEST", "F01 to F12", UVM_LOW)
        for (int a = 0; a < 7; a++) begin rd(4 * a, d); if (a != 1 && a != 4) wr(4 * a, 32'hFFFF_FFFF); rd(4 * a, d); wr(4 * a, 32'h0); end
        wr(12'h010, WR); clks(40);                                             // F07: a CMD with EN clear does nothing
        expect_status("a CMD with EN clear", 6'b000011, 6'b000000);
        for (int a = 0; a < 4; a++) begin rd(12'hFE0 + 4 * a, d); wr(12'hFE0 + 4 * a, 32'h0); end
        for (int w = 0; w < 2; w++) begin
            bit [11:0] holes[$] = '{12'h01C, 12'h020, 12'h024, 12'h304, 12'h800, 12'hFDC, 12'hFF0, 12'hFFC, 12'hFE1, 12'hFEE, 12'h001, 12'h01A,
                                    12'h100, 12'h418, 12'hBE0, 12'hFA4, 12'h7EC};
            foreach (holes[i]) if (w) wr(holes[i], 32'hFFFF_FFFF); else rd(holes[i], d);
        end

        // ---- F17, cg_i2c_rate: the SCL period at each PRESCALE; F13: a write of one byte
        `uvm_info("TEST", "F17, cg_i2c_rate", UVM_LOW)
        begin
            bit [15:0] pv[3] = '{16'd3, 16'd61, 16'd249};
            foreach (pv[i]) begin
                setup(pv[i]); wdat = '{8'hA5};
                xfer_write(c.addr, wdat, 1, nacked);
                if (nacked) `uvm_error("TEST", $sformatf("NACK at PRESCALE %0d", pv[i]))
            end
            // I2C-8: below PRESCALE 3 the block sees its own SDA too late and reports arbitration lost.
            // It must release both lines and work again once PRESCALE is legal.
            for (int p = 0; p < 3; p++) begin
                setup(p); wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR);
                clks(400); rd(12'h014, d);
                if (d[0]) `uvm_error("TEST", $sformatf("TIP still set at PRESCALE %0d", p))
                if (vif.scl_oe !== 1'b0 || vif.sda_oe !== 1'b0) `uvm_error("TEST", $sformatf("a line still pulled low at PRESCALE %0d", p))
                wr(12'h004, 32'h3); clks(8); wr(12'hFE0, 32'hF); setup(16'd3); recover();
                rd(12'h014, d); rd(12'hFE0, d);
                wdat = '{8'h5A}; c.wr_seen.delete(); xfer_write(c.addr, wdat, 1, nacked);
                if (nacked || c.wr_seen != wdat) `uvm_error("TEST", $sformatf("the transfer after PRESCALE %0d failed", p))
            end
            // the slowest: one START, which takes two prescaler periods, then given up
            setup(16'hFFFF);
            wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR);
            wait (env.line.in_xfer); clks(20);
            expect_status("in a transfer at PRESCALE 0xFFFF", 6'b000001, 6'b000001);
            wr(12'h004, 32'h3); clks(8); setup(16'd3); recover();
        end

        // ---- F13, F14, F15, cg_i2c_xfer: writes and reads of 1, 2, 8 and 12 bytes; a repeated START
        `uvm_info("TEST", "F13, F14, F15, cg_i2c_xfer", UVM_LOW)
        setup(16'd3);
        begin
            int unsigned lens[4] = '{1, 2, 8, 12};
            foreach (lens[i]) begin
                wdat.delete(); repeat (lens[i]) wdat.push_back($urandom_range(0, 255));
                c.wr_seen.delete(); xfer_write(c.addr, wdat, 1, nacked);
                if (nacked || c.wr_seen != wdat) `uvm_error("TEST", $sformatf("write of %0d bytes: the slave received %p", lens[i], c.wr_seen))
                c.rd_sent.delete(); xfer_read(c.addr, lens[i], rdat, 1, nacked);
                if (nacked || rdat != c.rd_sent) `uvm_error("TEST", $sformatf("read of %0d bytes: got %p, the slave sent %p", lens[i], rdat, c.rd_sent))
            end
            wdat = '{8'h10}; xfer_write(c.addr, wdat, 0, nacked);              // the register address, no STOP
            c.rd_q = '{8'hDE, 8'hAD}; xfer_read(c.addr, 2, rdat, 1, nacked);   // repeated START, two bytes
            if (rdat != '{8'hDE, 8'hAD}) `uvm_error("TEST", $sformatf("register read: got %p", rdat))
        end

        // ---- F05, cg_i2c_cmd: the command combinations, the two the specification leaves open among them
        `uvm_info("TEST", "F05, cg_i2c_cmd", UVM_LOW)
        wr(12'h008, {c.addr, 1'b0}); cmd(STA | WR, st); wr(12'h008, 8'h77); cmd(WR, st); cmd(STO, st);
        wr(12'h008, {c.addr, 1'b1}); cmd(STA | WR, st); cmd(RD, st); rd(12'h00C, d); cmd(RD | NACK, st); rd(12'h00C, d); cmd(STO, st);
        wr(12'h008, {c.addr, 1'b1}); cmd(STA | WR, st); cmd(RD | NACK | STO, st); rd(12'h00C, d);
        cmd(STA | RD | NACK, st); rd(12'h00C, d); cmd(STO, st);               // a read straight after START: nobody is addressed
        wr(12'h008, 8'hFF); cmd(STA | STO, st);                                // START, the byte in TXDATA, STOP
        wr(12'h008, {c.addr, 1'b1}); cmd(STA | WR, st); cmd(RD | WR | NACK, st); rd(12'h00C, d); cmd(STO, st);   // RD wins over WR
        // F06: a CMD during a transfer is refused
        wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR); clks(6); wr(12'h010, STO); wr(12'h010, RD);
        wait_tip(st); cmd(STO, st);
        // F04: a read of RXDATA with no byte waiting starts nothing
        rd(12'h00C, d); clks(4 * bit_time()); expect_status("after a read of RXDATA", 6'b100011, 6'b000000);

        // ---- F21, cg_i2c_nack: a NACK on the address, on the first, a middle and the last byte
        `uvm_info("TEST", "F21, cg_i2c_nack", UVM_LOW)
        wr(12'hFE0, 32'hF);
        wdat = '{8'h01, 8'h02, 8'h03};
        xfer_write(7'h2A, wdat, 1, nacked); env.cov.cg_i2c_nack.sample(0);
        if (!nacked) `uvm_error("TEST", "no NACK from an address nobody answers")
        rd(12'hFE0, d); if (d[3] !== 1'b1) `uvm_error("TEST", "IRQSTAT bit 3 clear after a NACK on the address")
        for (int i = 0; i < 3; i++) begin
            wr(12'hFE0, 32'hF); c.plain(); c.nack_data_at = i;
            xfer_write(c.addr, wdat, 1, nacked); env.cov.cg_i2c_nack.sample(1 + i);
            if (!nacked) `uvm_error("TEST", $sformatf("no NACK reported for byte %0d", i))
        end
        c.plain(); wdat = '{8'h55};
        xfer_write(c.addr, wdat, 1, nacked);
        if (nacked) `uvm_error("TEST", "the transfer after a NACK failed")
        wr(12'hFE0, 32'hF);

        // ---- F18, cg_i2c_stretch: the slave holds SCL low after the address, after a byte and in mid-byte;
        `uvm_info("TEST", "F18, cg_i2c_stretch", UVM_LOW)
        // briefly, for long, and for just under the timeout
        for (int where = 0; where < 3; where++) for (int len = 0; len < 3; len++) begin
            int unsigned t = (len == 0) ? 60 : (len == 1) ? 6000 : 12000;
            c.plain();
            if (where == 0) c.stretch_addr = t; else if (where == 1) c.stretch_data = t; else c.stretch_mid = t;
            setup(16'd3, (len == 2) ? 9 * bit_time() + 1200 + ((where == 2) ? 1200 : 0) + 150 : 16'd0);
            wdat = '{8'h3C}; c.wr_seen.delete();
            xfer_write(c.addr, wdat, 1, nacked); env.cov.cg_i2c_stretch.sample(where, len);
            if (nacked || c.wr_seen != wdat) `uvm_error("TEST", $sformatf("write with a stretch (where %0d, length %0d): the slave received %p", where, len, c.wr_seen))
            clks(ps + 30); expect_status("after a stretched transfer", 6'b010111, 6'b000000);
        end
        c.plain();

        // ---- F23, cg_i2c_timeout: each value; reached at once, in the address, in a data byte and in a stretch
        `uvm_info("TEST", "F23, cg_i2c_timeout", UVM_LOW)
        setup(16'd3, 16'd1);                                                   // 1: every command is abandoned at once
        wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR); clks(6);
        expect_status("TIMEOUT = 1", 6'b010001, 6'b010000);
        rd(12'hFE0, d); wr(12'hFE0, 32'hF); setup(16'd3, 16'd0); recover();
        setup(16'd3, 5 * bit_time());                                          // under a byte: in the address
        wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR); wait_tip(st);
        if (!st[4]) `uvm_error("TEST", "no timeout with TIMEOUT under a byte time")
        wr(12'hFE0, 32'hF); setup(16'd3, 16'd0); recover();
        setup(16'd3, 16'd0);                                                   // under a byte: in a data byte
        wr(12'h008, {c.addr, 1'b0}); cmd(STA | WR, st); wr(12'h018, 5 * bit_time());
        wr(12'h008, 8'h99); wr(12'h010, WR); wait_tip(st);
        if (!st[4]) `uvm_error("TEST", "no timeout in a data byte")
        wr(12'hFE0, 32'hF); setup(16'd3, 16'd0); recover();
        for (int v = 0; v < 2; v++) begin                                      // under and over a byte: in a stretch
            c.plain(); c.stretch_addr = 40000;
            setup(16'd3, v ? 14 * bit_time() : 8 * bit_time());
            wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR); wait_tip(st, 2000);
            if (!st[4]) `uvm_error("TEST", "no timeout with SCL held low")
            expect_status("after a timeout", 6'b010001, 6'b010000);
            clks(4200); wr(12'hFE0, 32'hF); setup(16'd3, 16'd0); recover();
        end
        c.plain(); c.stretch_mid = 40000;                                      // under a byte: in a stretch in mid-byte
        setup(16'd3, 16'd150);
        wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR); wait_tip(st, 2000);
        if (!st[4]) `uvm_error("TEST", "no timeout with SCL held low in mid-byte")
        clks(4200); wr(12'hFE0, 32'hF); setup(16'd3, 16'd0); recover();
        c.plain();
        setup(16'd3, 14 * bit_time()); wdat = '{8'h01}; xfer_write(c.addr, wdat, 1, nacked);   // over a byte, not reached
        setup(16'd3, 16'hFFFF);        wdat = '{8'h02}; xfer_write(c.addr, wdat, 1, nacked);   // the largest, not reached
        clks(ps + 30); expect_status("transfers with a TIMEOUT that is not reached", 6'b010111, 6'b000000);
        setup(16'd3, 16'd0);

        // ---- F24, cg_i2c_abort: ABORT at each of the 36 bit positions of a transfer of four bytes,
        `uvm_info("TEST", "F24, cg_i2c_abort", UVM_LOW)
        // with the bus idle, and between two bytes
        wdat = '{8'hC1, 8'h5A, 8'h0F};
        for (int p = 0; p < 36; p++) begin
            fork
                xfer_write(c.addr, wdat, 1, nacked);
                begin wait (env.line.in_xfer && env.line.bit_no >= p); clks(1 + p % 4); quit = 1; wr(12'h004, 32'h3); end
            join
            clks(6);
            if (vif.scl_oe !== 1'b0 || vif.sda_oe !== 1'b0) `uvm_error("TEST", $sformatf("a line still pulled low after ABORT at bit %0d", p))
            expect_status("after ABORT", 6'b000001, 6'b000000);
            recover();
            if (p % 6 == 5) begin
                wdat = '{8'hC1, 8'h5A, 8'h0F}; c.wr_seen.delete(); xfer_write(c.addr, wdat, 1, nacked);
                if (nacked || c.wr_seen != wdat) `uvm_error("TEST", $sformatf("the transfer after ABORT at bit %0d: the slave received %p", p, c.wr_seen))
            end
        end
        wr(12'h004, 32'h3); clks(8);                                           // with the bus idle
        wr(12'h008, {c.addr, 1'b0}); cmd(STA | WR, st); wr(12'h004, 32'h3); clks(8); recover();   // between two bytes

        // ---- F25 (I2C-6): EN cleared in mid-transfer; nothing is replayed when it is set again
        `uvm_info("TEST", "F25 (I2C-6)", UVM_LOW)
        wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR);
        wait (env.line.in_xfer && env.line.bit_no >= 4); wr(12'h004, 32'h0); clks(6);
        expect_status("EN cleared in mid-transfer", 6'b000001, 6'b000000);
        if (vif.scl_oe !== 1'b0 || vif.sda_oe !== 1'b0) `uvm_error("TEST", "a line still pulled low with EN clear")
        env.slave.release_all(); clks(20);
        begin int n0 = env.line.n_start;
            wr(12'h004, 32'h1); clks(40 * bit_time());
            if (env.line.n_start != n0) `uvm_error("TEST", "a START appeared when EN was set again")
        end
        recover();
        // ---- I2C-7: a CMD with nothing to do (no RD, WR or STO) is refused: PSLVERR, and TIP is not set
        `uvm_info("TEST", "I2C-7", UVM_LOW)
        begin
            bit [4:0] nothing[4] = '{STA, NACK, 5'h00, STA | NACK};
            foreach (nothing[i]) begin
                wr(12'h010, nothing[i]); clks(6);
                expect_status($sformatf("a CMD of 0x%02h, which has nothing to do", nothing[i]), 6'b000001, 6'b000000);
            end
            wdat = '{8'h18}; c.wr_seen.delete(); xfer_write(c.addr, wdat, 1, nacked);
            if (nacked || c.wr_seen != wdat) `uvm_error("TEST", "the transfer after refused commands failed")
        end

        // ---- F22, cg_i2c_al: arbitration lost in the address, in a data byte, on the acknowledge bit, and
        `uvm_info("TEST", "F22, cg_i2c_al", UVM_LOW)
        // to another master's STOP; then a retry from START succeeds
        for (int w = 0; w < 4; w++) for (int en = 0; en < 2; en++) begin
            wr(12'hFE4, en ? 32'hF : 32'h0); wr(12'hFE0, 32'hF);
            c.plain(); c.rd_q = '{8'hFF, 8'hFF};
            case (w)
                0: begin wr(12'h008, 8'hFF); wr(12'h010, STA | WR); wait (env.line.in_xfer && env.line.bit_no >= 2); end
                1: begin wr(12'h008, {c.addr, 1'b0}); cmd(STA | WR, st); wr(12'h008, 8'hFF); wr(12'h010, WR); wait (env.line.bit_no >= 11); end
                2: begin wr(12'h008, {c.addr, 1'b1}); cmd(STA | WR, st); wr(12'h010, RD | NACK); wait (env.line.bit_no >= 17); end
                default: begin wr(12'h008, {c.addr, 1'b1}); cmd(STA | WR, st); wr(12'h010, RD); wait (env.line.bit_no >= 11); end
            endcase
            env.sb.expect_al(w); env.cov.cg_i2c_irq.sample(1, en, 0);
            if (w < 3) env.other.win_arbitration(40 * (ps + 1));
            else begin                                                         // SDA low before SCL rises, released while it is high
                @(negedge vif.scl); env.other.wait_t(2); vif.oth_sda_low = 1'b1;
                @(posedge vif.scl); env.other.wait_t(10 * (5 * (ps + 1)) / 3); vif.oth_sda_low = 1'b0;
            end
            clks(12 * bit_time());
            expect_status("after arbitration was lost", 6'b000101, 6'b000100);
            if (vif.scl_oe !== 1'b0 || vif.sda_oe !== 1'b0) `uvm_error("TEST", "a line still pulled low after arbitration was lost")
            if (vif.irq !== en[0]) `uvm_error("TEST", $sformatf("irq %0b after arbitration was lost with IRQEN %0d", vif.irq, en ? 15 : 0))
            rd(12'hFE0, d); wr(12'hFE0, 32'hF); recover();
            expect_status("AL after its interrupt bit was cleared", 6'b000100, 6'b000000);
            wdat = '{8'h42}; xfer_write(c.addr, wdat, 1, nacked);
            if (nacked) `uvm_error("TEST", "the retry after a lost arbitration failed")
        end
        wr(12'hFE4, 32'h0); c.plain();

        // ---- F19: BUSY follows the START and STOP of another master
        `uvm_info("TEST", "F19", UVM_LOW)
        env.sb.expect_foreign();
        env.other.foreign_start(400); clks(40); expect_status("after another master's START", 6'b000011, 6'b000010);
        env.other.foreign_stop(400);  clks(40); expect_status("after another master's STOP", 6'b000011, 6'b000000);
        env.sb.tight();

        // ---- F20, cg_i2c_glitch: spikes shorter than the filter, on each line, idle and inside a transfer
        `uvm_info("TEST", "F20, cg_i2c_glitch", UVM_LOW)
        setup(16'd40);
        for (int line = 0; line < 2; line++) for (int w = 0; w < 2; w++) begin
            repeat (4) begin env.other.spike(line, w ? 88 : 10); clks(30); end
            env.cov.cg_i2c_glitch.sample(line, w, 0);
            expect_status("after a spike on an idle bus", 6'b000011, 6'b000000);
            wdat = '{8'h6D, 8'h92}; c.wr_seen.delete();
            fork
                xfer_write(c.addr, wdat, 1, nacked);
                repeat (10) begin
                    // on SDA while SCL is low, on SCL while it is high: where a longer pulse would be data or a clock
                    if (line) @(negedge vif.scl); else @(posedge vif.scl);
                    env.other.wait_t(25); env.other.spike(line, w ? 88 : 10);
                end
            join
            env.cov.cg_i2c_glitch.sample(line, w, 1);
            if (nacked || c.wr_seen != wdat) `uvm_error("TEST", $sformatf("write with spikes on %s: the slave received %p", line ? "SDA" : "SCL", c.wr_seen))
        end
        setup(16'd3);

        // ---- F29, cg_i2c_irq: each source with its enable 0 and 1 (arbitration loss is above)
        `uvm_info("TEST", "F29, cg_i2c_irq", UVM_LOW)
        for (int en = 0; en < 2; en++) begin
            wr(12'hFE4, en ? 32'hF : 32'h0); wr(12'hFE0, 32'hF);
            wdat = '{8'h01}; xfer_write(c.addr, wdat, 1, nacked);
            if (vif.irq !== en[0]) `uvm_error("TEST", "irq after a transfer")
            wr(12'hFE0, 32'hF);
            xfer_write(7'h2A, wdat, 1, nacked); rd(12'hFE0, d);
            if (d[3:0] !== 4'b1001) `uvm_error("TEST", $sformatf("IRQSTAT %04b after a NACK and a STOP", d[3:0]))
            wr(12'hFE0, 32'hF);
            c.stretch_addr = 40000; wr(12'h018, 8 * bit_time());
            wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR); wait_tip(st, 2000);
            if (vif.irq !== en[0]) `uvm_error("TEST", "irq after a timeout")
            clks(4200); c.plain(); wr(12'hFE0, 32'hF); wr(12'h018, 32'h0); recover();
        end
        wr(12'hFE4, 32'h0);

        // ---- F29, a_set_beats_clear: each event in the cycle of its own clear. The clear is moved one
        // pclk at a time across the cycle of the event; the properties check that the flag survives.
        `uvm_info("TEST", "F29, an event in the cycle of its own clear", UVM_LOW)
        setup(16'd3);
        wr(12'h008, {7'h2A, 1'b0}); cmd(STA | WR, st);                         // nobody answers: every byte ends with a NACK
        for (int i = 0; i < 44; i++) begin                                     // transfer complete and NACK
            int n0 = env.line.bit_no;
            wr(12'h008, i); wr(12'h010, WR);
            wait (env.line.bit_no >= n0 + 9); clks(i); wr(12'hFE0, 32'h9);
            wait_tip(st);
        end
        cmd(STO, st); wr(12'hFE0, 32'hF);
        for (int t = 1; t < 9; t++) begin                                      // timeout
            setup(16'd3, t);
            wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR); wr(12'hFE0, 32'h4);
            clks(8); wr(12'hFE0, 32'hF); setup(16'd3, 16'd0); recover();
        end
        for (int i = 0; i < 16; i++) begin                                     // arbitration lost
            wr(12'hFE0, 32'hF);
            wr(12'h008, 8'hFF); wr(12'h010, STA | WR); wait (env.line.in_xfer && env.line.bit_no >= 2);
            env.sb.expect_al(0);
            fork
                env.other.win_arbitration(40 * (ps + 1));
                begin @(negedge vif.scl); @(posedge vif.scl); clks(i); wr(12'hFE0, 32'h2); end
            join
            clks(12 * bit_time()); wr(12'hFE0, 32'hF); recover();
        end
        // ABORT in the cycle a command ends, and in the cycles around it
        `uvm_info("TEST", "F24, ABORT as a command ends", UVM_LOW)
        for (int i = 0; i < 44; i++) begin
            wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR);
            wait (env.line.in_xfer && env.line.bit_no >= 9); clks(i); wr(12'h004, 32'h3);
            clks(8); recover();
        end
        wdat = '{8'h3D}; c.wr_seen.delete(); xfer_write(c.addr, wdat, 1, nacked);
        if (nacked || c.wr_seen != wdat) `uvm_error("TEST", "the transfer after the ABORT sweep failed")
        wr(12'hFE0, 32'hF);

        // ---- F30, cg_i2c_dma: a request for a received byte, a request when ready to send, and both
        `uvm_info("TEST", "F30, cg_i2c_dma", UVM_LOW)
        fork dma_responder(); join_none
        wr(12'hFE8, 32'h1);
        wr(12'h008, {c.addr, 1'b1}); cmd(STA | WR, st); wr(12'h010, RD | NACK | STO); wait_tip(st);
        clks(4);
        if (vif.dma_req !== 1'b1) `uvm_error("TEST", "no DMA request with a byte received and DMACTL = 1")
        dma_on = 1; clks(20); dma_on = 0;
        if (vif.dma_req !== 1'b0) `uvm_error("TEST", "the DMA request did not drop when the byte was read")
        wr(12'hFE8, 32'h2); clks(3);
        if (vif.dma_req !== 1'b1) `uvm_error("TEST", "no DMA request with the block ready to send and DMACTL = 2")
        dma_on = 1; clks(20); dma_on = 0; clks(6);
        wr(12'h004, 32'h0); clks(3);
        if (vif.dma_req !== 1'b0) `uvm_error("TEST", "a DMA request with EN clear")
        wr(12'h004, 32'h1); wr(12'hFE8, 32'h3);
        wr(12'h008, {c.addr, 1'b1}); wr(12'h010, STA | WR); clks(8);
        if (vif.dma_req !== 1'b0) `uvm_error("TEST", "a DMA request during a transfer")
        wait_tip(st); cmd(RD | NACK | STO, st); dma_on = 1; clks(40); dma_on = 0; clks(6);
        wr(12'hFE8, 32'h0); rd(12'h00C, d);

        // ---- F12, F28: a reset in the middle of a transfer
        `uvm_info("TEST", "F12, F28", UVM_LOW)
        wr(12'h008, {c.addr, 1'b0}); wr(12'h010, STA | WR);
        wait (env.line.in_xfer && env.line.bit_no >= 5);
        env.sb.expect_foreign();                               // the lines are let go in mid-transfer: not bus activity
        #1 vif.rst_req = 1'b1; #1 env.slave.release_all(); clks(3); vif.rst_req = 1'b0; clks(2); wait_reset_done(); en_set = 0;
        if (vif.scl_oe !== 1'b0 || vif.sda_oe !== 1'b0) `uvm_error("TEST", "a line pulled low after reset")
        env.sb.expect_foreign();
        for (int a = 0; a < 7; a++) rd(4 * a, d);
        setup(16'd3); recover();
        wdat = '{8'hE7}; c.wr_seen.delete(); xfer_write(c.addr, wdat, 1, nacked);
        if (nacked || c.wr_seen != wdat) `uvm_error("TEST", "the transfer after a reset failed")

        if (env.sb.n_ev_cmp < 300) `uvm_error("TEST", $sformatf("only %0d bus events were compared with a command", env.sb.n_ev_cmp))
        phase.phase_done.set_drain_time(this, 400ns);
        phase.drop_objection(this);
    endtask
endclass

// One write of two bytes at the PRESCALE given by +PS=<n>: a probe for use by hand.
class i2c_probe_test extends i2c_base_test;
    `uvm_component_utils(i2c_probe_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        int unsigned p = 3; bit nacked; bit [7:0] wdat[$]; bit [31:0] d;
        void'($value$plusargs("PS=%d", p));
        phase.raise_objection(this);
        wait_reset_done();
        if (p < 3) begin                                       // below the minimum, then given up and recovered at 3
            setup(p); wr(12'h008, {env.scfg.addr, 1'b0}); wr(12'h010, STA | WR); clks(400);
            wr(12'h004, 32'h3); clks(8); wr(12'hFE0, 32'hF); setup(16'd3); recover();
        end else setup(p);
        wdat = '{8'hA5, 8'h3C};
        xfer_write(env.scfg.addr, wdat, 1, nacked);
        rd(12'h014, d);
        $display("PROBE PRESCALE %0d: nacked %0b, the slave received %p, STATUS %06b, %0d mismatches", p, nacked, env.scfg.wr_seen, d[5:0], env.sb.n_err);
        phase.phase_done.set_drain_time(this, 400ns);
        phase.drop_objection(this);
    endtask
endclass
