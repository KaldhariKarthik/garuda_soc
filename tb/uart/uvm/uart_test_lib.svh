// uart_test_lib.svh - tests for the UART environment (included in uart_env_pkg).
//
//   uart_reg_test       register model: reset values and bit bash
//   uart_random_test    random frames in both directions at a random format and divisor,
//                       with errors, a baud mismatch and register traffic (+NFRAME=<n>)
//   uart_directed_test  the corners the plan names one by one
//   uart_probe_test     a few bytes each way at the divisor given by +DIV=<n>, by hand

class uart_one_seq extends uvm_sequence #(uart_frame);
    `uvm_object_utils(uart_one_seq)
    uart_frame f;
    function new(string name = "uart_one_seq"); super.new(name); endfunction
    task body(); start_item(f); finish_item(f); endtask
endclass

class uart_base_test extends uvm_test;
    `uvm_component_utils(uart_base_test)
    uart_env env;
    virtual uart_if vif;
    uart_line_cfg cfg;
    bit dma_on;                               // the DMA responder answers requests
    int unsigned n_dma;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = uart_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual uart_if)::get(this, "", "uvif", vif)) `uvm_fatal("NOVIF", "test: no uart_if")
    endfunction
    function void connect_phase(uvm_phase phase); cfg = env.line_agt.cfg; endfunction

    task wr(bit [11:0] a, bit [31:0] d, int unsigned idle = 1);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 1; s.wdata = d; s.idle = idle; s.start(env.apb.sqr);
    endtask
    task rd(bit [11:0] a, output bit [31:0] d, input int unsigned idle = 1);
        apb_access_seq s = apb_access_seq::type_id::create("s");
        s.addr = a; s.write = 0; s.idle = idle; s.start(env.apb.sqr); d = s.rdata;
    endtask
    task clks(int unsigned n); repeat (n) @(posedge vif.pclk); endtask
    task bits(real n); clks(int'(n * (cfg.div + 1)) + 1); endtask
    task wait_reset_done(); wait (vif.preset_n === 1'b1); clks(3); endtask
    task reset(int unsigned n = 3, int inst = -1);
        #1 vif.rst_req = 1'b1; clks(1); if (inst >= 0) vif.inst = inst; clks(n); vif.rst_req = 1'b0; clks(2); wait_reset_done();
        cfg.div = 0; cfg.bits = 5; cfg.parity = 0; cfg.stop2 = 0;
    endtask
    // wait until nothing is being sent: the divisor and the format are changed only then (UART-3)
    task wait_temt(int unsigned max = 200000);
        bit [31:0] d; int unsigned n = 0;
        forever begin rd(12'h014, d); if (d[6]) break; if (++n > max) begin `uvm_error("TEST", "TEMT never set") break; end clks((cfg.div + 1) / 4 + 1); end
    endtask
    // the divisor through the DLAB bank, then the format
    task setup_line(bit [15:0] div, int nbits = 8, bit parity = 0, bit stop2 = 0);
        bit [7:0] fmt = {4'h0, parity, stop2, 2'(nbits - 5)};
        wait_temt();
        wr(12'h00C, 8'h80 | fmt); wr(12'h000, div[7:0]); wr(12'h004, div[15:8]); wr(12'h00C, fmt);
        cfg.div = div; cfg.bits = nbits; cfg.parity = parity; cfg.stop2 = stop2;
        clks(4);
    endtask
    function uart_frame mk(bit [7:0] d, bit bad_parity = 0, bit bad_stop = 0, int skew = 0, int unsigned gap = 10);
        uart_frame f = uart_frame::type_id::create("f");
        f.kind = UART_FRAME; f.data = d; f.bad_parity = bad_parity; f.bad_stop = bad_stop; f.skew = skew; f.gap = gap; f.len = 0;
        return f;
    endfunction
    task send(uart_frame f);
        uart_one_seq s = uart_one_seq::type_id::create("s");
        s.f = f; s.start(env.line_agt.sqr);
    endtask
    task rxb(bit [7:0] d, bit bad_parity = 0, bit bad_stop = 0, int skew = 0, int unsigned gap = 10); send(mk(d, bad_parity, bad_stop, skew, gap)); endtask
    // read bytes until LSR says there is none; LSR before RBR, as the specification tells firmware
    task drain(output int unsigned n);
        bit [31:0] d; n = 0;
        forever begin rd(12'h014, d); if (!d[0]) break; rd(12'h000, d); n++; end
    endtask
    task expect_count(string what, int unsigned got, int unsigned want);
        if (got != want) `uvm_error("TEST", $sformatf("%s: %0d bytes, expected %0d", what, got, want))
    endtask

    // What the DMA does with a request: it reads RBR if a byte waits, else it writes THR; then it
    // acknowledges for one pclk.
    task dma_responder();
        bit [31:0] d;
        forever begin
            @(vif.cb);
            if (dma_on && vif.cb.dma_req === 1'b1) begin
                clks($urandom_range(0, 3));
                rd(12'hFE8, d);
                if (d[0]) begin rd(12'h014, d); if (d[0]) rd(12'h000, d); else wr(12'h000, $urandom_range(0, 255)); end
                else wr(12'h000, $urandom_range(0, 255));
                @(posedge vif.pclk); vif.dma_ack <= 1'b1;
                @(posedge vif.pclk); vif.dma_ack <= 1'b0;
                n_dma++;
                clks(3);
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) + env.sb.n_err;
        $display("tb_uart_uvm: test=%s errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

class uart_reg_test extends uart_base_test;
    `uvm_component_utils(uart_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq; uvm_reg_bit_bash_seq bash_seq;
        phase.raise_objection(this);
        wait_reset_done();
        // IRQSTAT bit 1 follows "the transmit FIFO is empty", which is true out of reset: the flag
        // sets itself and comes back after a clear. The scoreboard checks it on every read.
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.IRQSTAT.get_full_name()}, "NO_REG_TESTS", 1, this);
        // Offsets 0x00 and 0x08 are each a read-only and a write-only register. The register model's
        // own tests cannot read the write-only one or write the read-only one; the directed test and
        // the random test do both, and the scoreboard checks them.
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.THR.get_full_name()}, "NO_REG_TESTS", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.FCR.get_full_name()}, "NO_REG_TESTS", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.RBR.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.IIR.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        // LCR bit 7 changes what offsets 0x00 and 0x04 are: bashed by the directed test, through the bank
        uvm_resource_db #(bit)::set({"REG::", env.regmodel.LCR.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq"); rst_seq.model = env.regmodel; rst_seq.start(null);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq"); bash_seq.model = env.regmodel; bash_seq.start(null);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

class uart_random_test extends uart_base_test;
    `uvm_component_utils(uart_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        int unsigned nf = 60, n; bit [31:0] d; bit done_rx, done_tx;
        void'($value$plusargs("NFRAME=%d", nf));
        phase.raise_objection(this);
        wait_reset_done();
        fork dma_responder(); join_none
        repeat (4) begin
            bit [15:0] dv = ($urandom_range(0, 3) == 0) ? $urandom_range(30, 80) : $urandom_range(3, 24);
            setup_line(dv, $urandom_range(5, 8), $urandom_range(0, 1), $urandom_range(0, 1));
            wr(12'hFE4, $urandom_range(0, 7));
            done_rx = 0; done_tx = 0;
            fork
                begin                                                    // the other end sends
                    repeat (nf) begin
                        uart_frame f = uart_frame::type_id::create("f");
                        if (!f.randomize() with { if (local::dv < 30) skew == 0; }) `uvm_fatal("RAND", "uart_frame did not randomize")
                        send(f);
                    end
                    done_rx = 1;
                end
                begin                                                    // firmware sends: never more than the FIFO holds
                    repeat (nf) begin
                        forever begin rd(12'h014, d); if (d[5]) break; clks(dv + 1); end
                        repeat ($urandom_range(1, 12)) wr(12'h000, $urandom_range(0, 255));
                        clks($urandom_range(0, 40 * (dv + 1)));
                    end
                    done_tx = 1;
                end
                begin                                                    // firmware reads what arrives, and looks at the flags
                    while (!done_rx || !done_tx) begin
                        rd(12'h014, d);
                        if (d[0]) rd(12'h000, d);
                        case ($urandom_range(0, 19))
                            0: rd(12'hFE0, d);
                            1: wr(12'hFE0, $urandom_range(0, 7));
                            2: rd(12'h008, d);
                            3: rd(4 * $urandom_range(3, 7), d);
                            4: wr(12'hFE8, $urandom_range(0, 3));
                            5: begin dma_on = 1; clks($urandom_range(20, 200)); dma_on = 0; wr(12'hFE8, 0); clks(6); end
                            default: ;
                        endcase
                        clks($urandom_range(0, 3 * (dv + 1)));
                    end
                end
            join
            bits(14); drain(n); wait_temt();
            wr(12'hFE8, 0); wr(12'hFE0, 32'h7);
        end
        if (env.sb.n_tx_cmp < nf || env.sb.n_rx_cmp < nf) `uvm_error("TEST", $sformatf("only %0d frames on tx and %0d bytes read were compared", env.sb.n_tx_cmp, env.sb.n_rx_cmp))
        phase.phase_done.set_drain_time(this, 400ns);
        phase.drop_objection(this);
    endtask
endclass

class uart_directed_test extends uart_base_test;
    `uvm_component_utils(uart_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        bit [31:0] d; int unsigned n; uart_frame f;
        phase.raise_objection(this);
        wait_reset_done();

        // ---- F01 to F12: every register read and written; every kind of offset that is not a register
        `uvm_info("TEST", "F01 to F12: registers and holes", UVM_LOW)
        rd(12'h014, d); rd(12'h008, d); rd(12'hFE0, d);
        for (int a = 3; a < 8; a++) begin rd(4 * a, d); if (a != 3) wr(4 * a, 32'hFFFF_FFFF); rd(4 * a, d); end   // MCR, LSR, MSR, SCR: a write does nothing
        for (int a = 0; a < 4; a++) begin rd(12'hFE0 + 4 * a, d); wr(12'hFE0 + 4 * a, 32'h0); end
        for (int w = 0; w < 2; w++) begin
            bit [11:0] holes[$] = '{12'h020, 12'h024, 12'h304, 12'h800, 12'hFDC, 12'hFF0, 12'hFFC, 12'hFE1, 12'hFEE, 12'h001, 12'h01A,
                                    12'h100, 12'h418, 12'hBE0, 12'hFA4, 12'h7EC};
            foreach (holes[i]) if (w) wr(holes[i], 32'hFFFF_FFFF); else rd(holes[i], d);
        end
        // F02: the divisor bank. With DLAB set, 0x00 and 0x04 are the divisor and nothing else moves.
        wr(12'h004, 8'h05); rd(12'h004, d);
        wr(12'h00C, 8'h83); wr(12'h000, 8'hA5); wr(12'h004, 8'h5A); rd(12'h000, d); rd(12'h004, d); rd(12'h00C, d);
        wr(12'h00C, 8'h03); rd(12'h004, d); rd(12'h00C, d);
        if (d[7:0] !== 8'h03) `uvm_error("TEST", "LCR did not read back")
        wr(12'h00C, 8'h7F); rd(12'h00C, d); wr(12'h00C, 8'h00);              // every LCR bit but DLAB, which has been both ways
        // F03: the 16550's own interrupt enables do not reach irq_o
        for (int b = 0; b < 3; b++) begin wr(12'h004, 8'h01 << b); rd(12'h004, d); clks(4); end
        wr(12'h004, 8'hFF); rd(12'h008, d); wr(12'h004, 8'h00); rd(12'h008, d);

        // ---- F13, cg_uart_fmt: every word length, parity off and on, 1 and 2 stop bits, both ways
        `uvm_info("TEST", "F13: frame formats", UVM_LOW)
        for (int nb = 5; nb < 9; nb++) for (int par = 0; par < 2; par++) for (int st = 0; st < 2; st++) begin
            setup_line(7, nb, par, st);
            for (int k = 0; k < 3; k++) wr(12'h000, (k == 0) ? 8'h00 : (k == 1) ? 8'hFF : $urandom_range(0, 255));
            rxb(8'h00); rxb(8'hFF, 0, 0, 0, 0); rxb($urandom_range(0, 255), 0, 0, 0, 0);
            bits(3); drain(n); expect_count($sformatf("%0d bits, parity %0d, %0d stop bits", nb, par, st + 1), n, 3);
        end

        // ---- F14, cg_uart_baud: the divisors of the specification, the smallest ones, and the largest
        `uvm_info("TEST", "F14: divisors", UVM_LOW)
        begin
            bit [15:0] dv[6] = '{16'd2, 16'd3, 16'd134, 16'd1084, 16'd2169, 16'd13020};
            // Divisors 0 and 1 are below the smallest that works ([N-7.1a]): the start bit on tx is one
            // pclk longer than the other bits, which at two pclk a bit is half a bit. The block must
            // not hang, and must work again at a legal divisor.
            for (int dz = 0; dz < 2; dz++) begin
                env.sb.tx_loose = 1; env.sb.rx_loose = 1;
                setup_line(dz); wr(12'h000, 8'hA5); wr(12'h000, 8'h3C); rxb(8'hC3); rxb(8'h5A);
                clks(200); wait_temt(); setup_line(7); clks(40);
                wr(12'h008, 8'h06); clks(8); wr(12'hFE0, 32'h7); env.sb.resync(); clks(10);
                wr(12'h000, 8'h69); rxb(8'h96); bits(3); drain(n); expect_count($sformatf("a byte after divisor %0d", dz), n, 1);
            end
            foreach (dv[i]) begin
                setup_line(dv[i]);
                wr(12'h000, 8'hA5); wr(12'h000, 8'h3C);
                rxb(8'hC3); rxb(8'h5A, 0, 0, 0, 0);
                bits(3); drain(n); expect_count($sformatf("divisor %0d", dv[i]), n, 2);
            end
            setup_line(16'hFFFF); wr(12'h000, 8'h81); rxb(8'h7E); bits(2); drain(n); expect_count("divisor 0xFFFF", n, 1);
        end

        // ---- F21, cg_uart_baud.cp_mismatch: a sender 1 to 4 percent slow or fast, frames with no gap
        `uvm_info("TEST", "F21: baud mismatch", UVM_LOW)
        setup_line(49, 8, 1, 0);
        for (int sk = -40; sk <= 40; sk += 10) begin
            for (int k = 0; k < 4; k++) rxb($urandom_range(0, 255), 0, 0, sk, 0);
            bits(3); drain(n); expect_count($sformatf("sender %0d tenths of a percent off", sk), n, 4);
        end

        // ---- F16, cg_uart_fifo.cp_tx_level: the transmit FIFO empty, 1, 15, 16, and a write while full
        `uvm_info("TEST", "F16, F17: the FIFOs", UVM_LOW)
        setup_line(199);
        for (int k = 0; k < 20; k++) wr(12'h000, 8'h40 + k);                  // the shifter takes the first; 16 fit; the last 3 are dropped
        rd(12'h014, d); wait_temt();
        // ---- F17, cg_uart_fifo.cp_rx_level: the receive FIFO filled, overrun by one and by several
        setup_line(7);
        for (int k = 0; k < 16; k++) rxb(8'h80 + k, 0, 0, 0, 2);
        bits(3); rd(12'h014, d);
        rxb(8'hE1); bits(3);                                                  // the seventeenth: the receiver holds it
        rxb(8'hE2); rxb(8'hE3); bits(3);                                      // lost
        drain(n); expect_count("after an overrun of three", n, 17);
        for (int k = 0; k < 17; k++) rxb(8'h20 + k, 0, 0, 0, 2);              // overrun by exactly one
        bits(3); drain(n); expect_count("after an overrun of one", n, 17);

        // ---- F04, cg_uart_fcr: each FIFO cleared when empty, part full and full; the frame in the shifter still goes out
        `uvm_info("TEST", "F04: FCR", UVM_LOW)
        setup_line(49);
        wr(12'h008, 8'h06);                                                   // both, empty
        wr(12'h000, 8'h11); bits(2); wr(12'h008, 8'h04); wait_temt();         // transmit: only a frame in the shifter
        for (int k = 0; k < 5; k++) wr(12'h000, 8'h60 + k);
        bits(1); wr(12'h008, 8'h04); wait_temt();                             // transmit: part full
        for (int k = 0; k < 17; k++) wr(12'h000, 8'h70 + k);
        bits(1); wr(12'h008, 8'h04); wait_temt();                             // transmit: full
        setup_line(7);
        for (int k = 0; k < 5; k++) rxb(8'h30 + k, 0, 0, 0, 2);
        bits(3); wr(12'h008, 8'h02); bits(1); drain(n); expect_count("after the receive FIFO was cleared part full", n, 0);
        for (int k = 0; k < 16; k++) rxb(8'h50 + k, 0, 0, 0, 2);
        bits(3); wr(12'h008, 8'h02); bits(1); drain(n); expect_count("after the receive FIFO was cleared full", n, 0);
        rxb(8'h99); bits(3); drain(n); expect_count("a byte after the clears", n, 1);

        // ---- F18, F19, cg_uart_err: a parity and a framing error on the first, a middle and the last byte
        // of a full FIFO; two in a row. The flag is read with its own byte and with no other.
        `uvm_info("TEST", "F18, F19: line errors", UVM_LOW)
        setup_line(7, 8, 1, 0);
        for (int kind = 0; kind < 2; kind++) for (int pos = 0; pos < 3; pos++) begin
            int at = (pos == 0) ? 0 : (pos == 1) ? 7 : 15;
            wr(12'hFE0, 32'h7);
            for (int k = 0; k < 16; k++) rxb(8'h10 + k, (k == at) && kind == 0, (k == at) && kind == 1, 0, 2);
            bits(3); env.cov.cg_uart_err.sample(kind, at);
            rd(12'hFE0, d);
            if (d[2] !== (at == 0)) `uvm_error("TEST", $sformatf("IRQSTAT bit 2 is %0b with the bad byte at position %0d of the FIFO", d[2], at))
            n = 0;
            forever begin
                rd(12'h014, d); if (!d[0]) break;
                if ({d[3], d[2]} !== ((n == at) ? (kind ? 2'b10 : 2'b01) : 2'b00)) `uvm_error("TEST", $sformatf("LSR FE PE %02b at byte %0d, the bad one is %0d", d[3:2], n, at))
                rd(12'h000, d); n++;
            end
            expect_count("a FIFO with one bad byte", n, 16);
        end
        rxb(8'hAA, 1, 0); rxb(8'h55, 0, 1); rxb(8'h33, 1, 1); rxb(8'h0F); bits(3); env.cov.cg_uart_err.sample(3, 0);
        drain(n); expect_count("two bad bytes in a row", n, 4);
        // UART-5: with the FIFO empty again there is no line-error event, and the flag clears and stays clear
        wr(12'hFE0, 32'h7); clks(20); rd(12'hFE0, d);
        if (d[2] !== 1'b0) `uvm_error("TEST", "IRQSTAT bit 2 set with no byte in the FIFO (UART-5)")

        // ---- F20, cg_uart_rx.cp_break: a break of 1, 2 and 10 frame lengths is one 0x00 with a framing error
        `uvm_info("TEST", "F20, F23: break and short pulses", UVM_LOW)
        setup_line(7, 8, 0, 0);
        begin int unsigned fl[3] = '{1, 2, 10};
            foreach (fl[i]) begin
                f = mk(0); f.kind = UART_BREAK; f.len = fl[i] * 100; send(f); bits(3); env.cov.cg_uart_rx.sample(1, fl[i]);
                rd(12'h014, d);
                if (d[4:0] !== 5'b01001) `uvm_error("TEST", $sformatf("LSR %02h after a break of %0d frames", d[7:0], fl[i]))
                drain(n); expect_count("a break", n, 1);
            end
        end
        // F23: a low pulse shorter than half a bit. The vendored receiver starts on any falling edge
        // and does not look at the start bit again, so each one is received as a byte (UART-6):
        // the test records what arrives and the scoreboard is told not to expect a frame.
        setup_line(63, 8, 0, 0);
        begin int unsigned pl[3] = '{2, 25, 48}; int unsigned got = 0;
            env.sb.rx_loose = 1;
            foreach (pl[i]) begin
                f = mk(0); f.kind = UART_PULSE; f.len = pl[i]; send(f); bits(12); env.cov.cg_uart_rx.sample(0, i);
                drain(n); got += n;
            end
            `uvm_info("TEST", $sformatf("UART-6: three low pulses shorter than half a bit left %0d byte(s) in the receive FIFO", got), UVM_LOW)
            wr(12'h008, 8'h06); clks(8); wr(12'hFE0, 32'h7); env.sb.resync(); clks(10);
        end

        // ---- F24, F25, cg_uart_irq: each source with its enable 0 and 1; cleared with the condition gone and still true
        `uvm_info("TEST", "F24, F25: interrupts", UVM_LOW)
        setup_line(7, 8, 1, 0);
        for (int en = 0; en < 2; en++) begin
            wr(12'hFE4, en ? 32'h7 : 32'h0);
            wr(12'h000, 8'h01); wr(12'h000, 8'h02); wr(12'hFE0, 32'h2); clks(6);       // transmit FIFO not empty: the flag clears
            rd(12'hFE0, d); wait_temt(); clks(12); rd(12'hFE0, d);
            wr(12'hFE0, 32'h2); clks(12); rd(12'hFE0, d);                             // empty again: it comes back after a clear
            rxb(8'h77, 1, 0); bits(3); rd(12'hFE0, d);
            if (vif.irq !== en[0]) `uvm_error("TEST", $sformatf("irq %0b with a bad byte waiting and IRQEN %0d", vif.irq, en ? 7 : 0))
            wr(12'hFE0, 32'h5); clks(12); rd(12'hFE0, d);                             // the byte is still there: both come back
            drain(n); wr(12'hFE0, 32'h5); clks(12); rd(12'hFE0, d);                   // gone: both stay clear
            if (d[2] || d[0]) `uvm_error("TEST", $sformatf("IRQSTAT %03b with the receive FIFO empty after a clear", d[2:0]))
        end
        wr(12'hFE4, 32'h0);

        // ---- F26 to F29, cg_uart_dma: a request with 1 and 16 bytes waiting, with the transmit FIFO empty and
        // nearly full, with both bits set, and none while DLAB is set
        `uvm_info("TEST", "F26 to F29: DMA", UVM_LOW)
        fork dma_responder(); join_none
        setup_line(7, 8, 0, 0);
        wr(12'hFE8, 32'h1); rxb(8'hD1); bits(3); clks(12);
        if (vif.dma_req !== 1'b1) `uvm_error("TEST", "no DMA request with a byte received and DMACTL = 1")
        wr(12'h00C, 8'h83); clks(4);                                          // DLAB: the request is held off
        if (vif.dma_req !== 1'b0) `uvm_error("TEST", "a DMA request with DLAB set")
        clks(12); wr(12'h00C, 8'h03); clks(12);
        dma_on = 1; clks(40); dma_on = 0;
        for (int k = 0; k < 16; k++) rxb(8'hB0 + k, 0, 0, 0, 2);
        bits(3); clks(30); dma_on = 1; clks(600); dma_on = 0; wr(12'hFE8, 32'h0); clks(8);
        drain(n); expect_count("left after the DMA responder read sixteen bytes", n, 0);
        setup_line(199);
        wr(12'hFE8, 32'h2); clks(20); dma_on = 1; clks(700); dma_on = 0; clks(8);      // it fills the transmit FIFO
        wr(12'hFE8, 32'h0); wr(12'h008, 8'h04); wait_temt();
        setup_line(7);
        wr(12'hFE8, 32'h3); rxb(8'h66); bits(3); clks(30); dma_on = 1; clks(120); dma_on = 0; clks(8);
        wr(12'hFE8, 32'h0); wr(12'h008, 8'h06); wait_temt(); drain(n); wr(12'hFE0, 32'h7);

        // ---- F12, F22: a reset in the middle of a frame in each direction
        `uvm_info("TEST", "F12, F22: reset in mid-frame", UVM_LOW)
        setup_line(49);
        wr(12'h000, 8'hF0); fork rxb(8'h0F); join_none
        bits(4); env.sb.tx_loose = 1; env.sb.rx_loose = 1; reset();
        rd(12'h014, d);
        if (d[7:0] !== 8'h60) `uvm_error("TEST", $sformatf("LSR %02h after a reset in mid-frame", d[7:0]))
        env.sb.tx_loose = 1; env.sb.rx_loose = 1;                             // the rest of the frame the other end was sending
        clks(14 * 50);                                                        // both ends finish the frame they were on, at the old divisor
        wr(12'h008, 8'h06); clks(8); env.sb.resync(); clks(10);
        setup_line(7); wr(12'h000, 8'h5A); rxb(8'hA5); bits(3); drain(n); expect_count("a byte after the reset", n, 1); wait_temt();

        // ---- F30: the other two instances, each with its own block number
        `uvm_info("TEST", "F30: the other instances", UVM_LOW)
        for (int i = 1; i < 3; i++) begin
            reset(3, (vif.inst + 1) % 3);
            rd(12'hFEC, d); rd(12'h014, d);
            setup_line(7); wr(12'h000, 8'h30 + i); rxb(8'h40 + i); bits(3); drain(n); expect_count("a byte on another instance", n, 1); wait_temt();
        end

        if (env.sb.n_tx_cmp < 90 || env.sb.n_rx_cmp < 250) `uvm_error("TEST", $sformatf("only %0d frames on tx and %0d bytes read were compared", env.sb.n_tx_cmp, env.sb.n_rx_cmp))
        phase.phase_done.set_drain_time(this, 400ns);
        phase.drop_objection(this);
    endtask
endclass

// A few bytes each way at the divisor given by +DIV=<n>: a probe for use by hand.
class uart_probe_test extends uart_base_test;
    `uvm_component_utils(uart_probe_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        int unsigned dv = 7, n; bit [31:0] d;
        void'($value$plusargs("DIV=%d", dv));
        phase.raise_objection(this);
        wait_reset_done();
        setup_line(dv);
        wr(12'h000, 8'hA5); wr(12'h000, 8'h3C); wr(12'h000, 8'hFF);
        rxb(8'hC3); rxb(8'h5A, 0, 0, 0, 0); rxb(8'h00, 0, 0, 0, 0);
        bits(4); drain(n); wait_temt(); rd(12'h014, d);
        $display("PROBE divisor %0d: %0d of 3 bytes received, %0d frames on tx compared, LSR %02h, %0d mismatches", dv, n, env.sb.n_tx_cmp, d[7:0], env.sb.n_err);
        phase.phase_done.set_drain_time(this, 400ns);
        phase.drop_objection(this);
    endtask
endclass
