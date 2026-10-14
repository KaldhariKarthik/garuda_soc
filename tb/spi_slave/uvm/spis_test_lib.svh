// spis_test_lib.svh - tests for the SPI slave environment (included in spis_env_pkg).
//
//   spis_reg_test       register model: reset values and bit bash
//   spis_random_test    random packets against random register traffic (+NPKT=<n>)
//   spis_directed_test  the corners the plan names one by one

class spis_base_test extends uvm_test;
    `uvm_component_utils(spis_base_test)
    spis_env env;
    virtual spis_if vif;
    bit dma_on;                               // the DMA responder answers requests
    int unsigned n_dma;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = spis_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual spis_if)::get(this, "", "svif", vif)) `uvm_fatal("NOVIF", "test: no spis_if")
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

    // one packet: n whole bytes (random, or all equal to fill), then extra bits
    function spis_pkt mk(int unsigned n, int fill = -1, int unsigned extra = 0, int unsigned lo = 40, int unsigned hi = 40,
                         int unsigned lead = 60, int unsigned trail = 40, int unsigned gap = 60,
                         int unsigned glitch_at = 0, int unsigned glitch_t = 5);
        spis_pkt p = spis_pkt::type_id::create("p");
        p.kind = SPIS_PACKET; p.data = new[n];
        foreach (p.data[i]) p.data[i] = (fill < 0) ? $urandom_range(0, 255) : fill;
        p.extra = extra; p.extra_data = $urandom_range(0, 127); p.lo_t = lo; p.hi_t = hi; p.lead_t = lead; p.trail_t = trail;
        p.gap_t = gap; p.glitch_at = glitch_at; p.glitch_t = glitch_t; p.n_idle = 0;
        return p;
    endfunction
    task send(spis_pkt p);
        spis_one_seq s = spis_one_seq::type_id::create("s");
        s.p = p; s.start(env.spi.sqr);
    endtask
    task pkt(int unsigned n, int fill = -1, int unsigned extra = 0, int unsigned lo = 40, int unsigned hi = 40,
             int unsigned lead = 60, int unsigned trail = 40, int unsigned gap = 60);
        send(mk(n, fill, extra, lo, hi, lead, trail, gap));
    endtask
    // the model sees the end of a packet a few pclk after the pins
    task settle(); clks(8); endtask
    // read bytes until the FIFO is empty
    task drain(output int unsigned n);
        bit [31:0] d; n = 0;
        forever begin rd(12'h00C, d); if (!d[0]) break; rd(12'h000, d); n++; end
    endtask
    task wait_sclk(int unsigned n); repeat (n) @(posedge vif.sclk); endtask

    // What the DMA does with a request: reads RXDATA and acknowledges for one pclk.
    task dma_responder();
        bit [31:0] d;
        forever begin
            @(vif.cb);
            if (dma_on && vif.cb.dma_req === 1'b1) begin
                clks($urandom_range(0, 4));
                rd(12'h000, d);
                @(posedge vif.pclk); vif.dma_ack <= 1'b1;
                @(posedge vif.pclk); vif.dma_ack <= 1'b0;
                n_dma++;
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        int errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) + env.sb.n_err;
        $display("tb_spis_uvm: test=%s errors=%0d", get_type_name(), errs);
        $display("RESULT: %s", errs ? "FAILED" : "PASSED");
    endfunction
endclass

class spis_reg_test extends spis_base_test;
    `uvm_component_utils(spis_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq rst_seq; uvm_reg_bit_bash_seq bash_seq;
        phase.raise_objection(this);
        wait_reset_done();
        // the line is idle in this test, so no register moves by itself
        rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq"); rst_seq.model = env.regmodel; rst_seq.start(null);
        bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq"); bash_seq.model = env.regmodel; bash_seq.start(null);
        phase.phase_done.set_drain_time(this, 40ns);
        phase.drop_objection(this);
    endtask
endclass

class spis_random_test extends spis_base_test;
    `uvm_component_utils(spis_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        spis_spi_rand_seq s = spis_spi_rand_seq::type_id::create("s");
        spis_apb_rand_seq a = spis_apb_rand_seq::type_id::create("a");
        int unsigned npkt = 150;
        void'($value$plusargs("NPKT=%d", npkt));
        s.n = npkt;
        phase.raise_objection(this);
        wait_reset_done();
        dma_on = 1;
        fork dma_responder(); join_none
        fork a.start(env.apb.sqr); join_none
        s.start(env.spi.sqr);
        a.stop = 1; settle();
        if (env.sb.n_pkt_cmp == 0) `uvm_error("TEST", "no packet was compared with the agent")
        phase.phase_done.set_drain_time(this, 200ns);
        phase.drop_objection(this);
    endtask
endclass

class spis_directed_test extends spis_base_test;
    `uvm_component_utils(spis_directed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task expect_count(string what, int unsigned got, int unsigned want);
        if (got != want) `uvm_error("TEST", $sformatf("%s: %0d bytes in the FIFO, expected %0d", what, got, want))
    endtask

    task run_phase(uvm_phase phase);
        bit [31:0] d; int unsigned n; spis_pkt p;
        int unsigned lens[6] = '{0, 1, 2, 16, 17, 64};
        phase.raise_objection(this);
        wait_reset_done();

        // ---- F01 to F07: every register read and written; every kind of offset that is not a register
        for (int a = 0; a < 4; a++) begin rd(4 * a, d); wr(4 * a, 32'hFFFF_FFFC); rd(4 * a, d); end
        for (int a = 0; a < 4; a++) begin rd(12'hFE0 + 4 * a, d); wr(12'hFE0 + 4 * a, 32'h0); end
        wr(12'h004, 0);
        for (int w = 0; w < 2; w++) begin
            bit [11:0] holes[$] = '{12'h010, 12'h014, 12'h800, 12'hFDC, 12'hFF0, 12'hFFC, 12'hFE1, 12'hFEE, 12'h001, 12'h00E,
                                    12'h100, 12'h408, 12'hBE0, 12'hFA4, 12'h7EC};
            foreach (holes[i]) if (w) wr(holes[i], 32'hFFFF_FFFF); else rd(holes[i], d);
        end

        // ---- F15: EN set before a packet. F08, F13, cg_spis_pkt.cp_len: packets of each length.
        // A FIFO of 16 holds the first 16 bytes of the longer ones (F19: overrun of one and of several).
        wr(12'hFE4, 32'h0);
        wr(12'h008, 32'h1);
        foreach (lens[i]) begin
            wr(12'h004, 8'hA0 + i);
            pkt(lens[i]); settle();
            rd(12'h00C, d); rd(12'hFE0, d);
            drain(n); expect_count($sformatf("packet of %0d", lens[i]), n, (lens[i] > 16) ? 16 : lens[i]);
            wr(12'hFE0, 32'h7);
        end
        // 64 bytes with firmware reading as they arrive: none lost
        fork pkt(64); join_none
        n = 0;
        while (n < 64) begin rd(12'h00C, d); if (d[0]) begin rd(12'h000, d); n++; end end
        settle(); rd(12'h00C, d);
        if (d[2]) `uvm_error("TEST", "overrun with the FIFO read as the bytes arrived")
        wr(12'hFE0, 32'h7);

        // ---- F08, cg_spis_data.cp_byte: the byte values
        begin
            bit [7:0] v[$] = '{8'h00, 8'hFF, 8'h01, 8'h02, 8'h04, 8'h08, 8'h10, 8'h20, 8'h40, 8'h80,
                               8'hFE, 8'hFD, 8'hFB, 8'hF7, 8'hEF, 8'hDF, 8'hBF, 8'h7F};
            for (int k = 0; k < 2; k++) begin
                p = mk(9); foreach (p.data[i]) p.data[i] = v[9 * k + i];
                wr(12'h004, v[k]); send(p); settle(); drain(n); expect_count("byte values", n, 9);
            end
        end

        // ---- F14, cg_spis_pkt.cp_extra_bits: a packet that ends 1 to 7 bits into a byte
        for (int e = 1; e < 8; e++) begin pkt(1, -1, e); settle(); drain(n); expect_count($sformatf("one byte and %0d bits", e), n, 1); end
        pkt(0, -1, 5); settle(); drain(n); expect_count("five bits and no byte", n, 0);

        // ---- F10, cg_spis_rate.cp_halfperiod: the rates, equal and unequal halves, and one above the limit
        pkt(3, -1, 0, 30, 30); pkt(3, -1, 0, 45, 45); pkt(3, -1, 0, 70, 70); pkt(1, -1, 0, 600, 600);
        pkt(3, -1, 0, 30, 90); pkt(3, -1, 0, 90, 30);
        settle(); drain(n); expect_count("six packets at the rates of the specification", n, 16);
        pkt(3, -1, 0, 22, 22); settle(); drain(n);                // out of specification: must not hang
        pkt(2); settle(); drain(n); expect_count("a packet after one that was too fast", n, 2);

        // ---- F11, cg_spis_rate.cp_phase: the rising edge of SCLK in each tenth of the pclk period
        for (int ph = 0; ph < 20; ph++) pkt(1, -1, 0, 40, 40, 60 + ph, 40, 60);
        settle(); drain(n); expect_count("twenty packets at every phase", n, 16);
        wr(12'h008, 32'h3); wr(12'hFE0, 32'h7);
        // rates that are not a whole number of pclk, so that every edge of a packet has its own phase
        for (int ph = 0; ph < 6; ph++) begin pkt(2, -1, 0, 31 + 2 * ph, 33 + ph, 43 + ph); settle(); drain(n); expect_count("odd rates", n, 2); end

        // ---- cg_spis_pkt.cp_gap: two packets with the shortest gap the block can see, just over one pclk
        for (int g = 11; g < 16; g++) begin
            wr(12'h004, 8'h50 + g);
            pkt(2); pkt(2, -1, 0, 40, 40, 60, 40, g); settle(); drain(n); expect_count("two packets with a short gap", n, 4);
        end

        // ---- F09, cg_spis_tx.cp_update: TXDATA not rewritten, rewritten between two bytes, rewritten in mid-byte
        wr(12'h004, 8'hC3);
        pkt(3); settle();
        fork pkt(3, -1, 0, 40, 160); join_none
        wait_sclk(8);  clks(6); wr(12'h004, 8'h11);               // after the last bit of byte 0, before its falling edge
        wait_sclk(8);  clks(6); wr(12'h004, 8'h22);
        wait_sclk(8);  settle(); clks(40);
        fork pkt(3, -1, 0, 60, 60); join_none
        wait_sclk(3);  clks(6); wr(12'h004, 8'h33);               // in the middle of byte 0: the byte on the wire does not change
        wait_sclk(8);  clks(6); wr(12'h004, 8'h44);
        wait_sclk(13); settle(); clks(40); drain(n);

        // ---- F15, cg_spis_pkt.cp_en_phase: EN set while the master is inside a packet, at each bit and between bytes
        for (int i = 0; i < 20; i++) begin
            wr(12'h008, 32'h0); wr(12'hFE0, 32'h7);
            fork pkt(3, -1, 0, 50, 50); join_none
            if (i != 0) wait_sclk(i); else @(negedge vif.cs_n);
            clks(1 + i % 3);
            wr(12'h008, 32'h1);
            wait (vif.cs_n === 1'b1); settle(); drain(n);
            expect_count($sformatf("EN set after %0d bits of a packet", i), n, 0);
            rd(12'hFE0, d);                                       // a packet that was never opened does not end either
            if (d[2:0] !== 3'b000) `uvm_error("TEST", $sformatf("IRQSTAT %03b after a packet that began with EN clear", d[2:0]))
        end
        pkt(2); settle(); drain(n); expect_count("the packet after EN was set in mid-packet", n, 2);
        // EN cleared in mid-packet, then set again before the next one
        fork pkt(4); join_none
        wait_sclk(13); wr(12'h008, 32'h0);
        wait (vif.cs_n === 1'b1); settle();
        wr(12'h008, 32'h1); drain(n); expect_count("EN cleared in the second byte of a packet", n, 1);
        wr(12'hFE0, 32'h7);

        // ---- F17, cg_spis_pkt.cp_cs_glitch: pulses on chip select shorter than one pclk, idle and in mid-packet.
        // A pulse that falls between two clock edges is not seen; one that a clock edge samples is a
        // packet of no bytes (idle) or ends the packet and starts another (in mid-packet).
        for (int i = 0; i < 24; i++) begin
            p = mk(0); p.kind = SPIS_CS_GLITCH; p.glitch_t = (i < 12) ? 9 : 2; p.gap_t = 50 + i; send(p);
        end
        settle(); drain(n); expect_count("glitches on an idle chip select", n, 0);
        for (int i = 0; i < 24; i++) begin
            send(mk(2, -1, 0, 60, 60, 60, 40, 60 + i, 5, (i < 12) ? 9 : 2));
            settle(); drain(n);
        end
        wr(12'hFE0, 32'h7);

        // ---- F16: another device is clocked while this one is not selected
        p = mk(0); p.kind = SPIS_IDLE_CLOCKS; p.n_idle = 24; p.gap_t = 60; send(p);
        settle(); drain(n); expect_count("clocks with chip select high", n, 0);

        // ---- F18, F19, F20, cg_spis_fifo: levels, overrun, and a flush when empty, part full and full
        wr(12'h008, 32'h3);
        pkt(1); settle(); rd(12'h00C, d); wr(12'h008, 32'h3); rd(12'h00C, d);
        pkt(15); settle(); rd(12'h00C, d); pkt(1); settle(); rd(12'h00C, d);
        pkt(1); settle(); rd(12'h00C, d); rd(12'hFE0, d);                     // overrun of one byte
        rd(12'h000, d); pkt(1); settle();                                     // room for one again
        pkt(5); settle(); rd(12'h00C, d);                                     // overrun of several
        wr(12'h008, 32'h3); rd(12'h00C, d); wr(12'hFE0, 32'h7);
        // a flush in the cycle a byte completes: the write is moved one pclk at a time across that cycle
        for (int i = 0; i < 10; i++) begin
            fork pkt(1); join_none
            wait_sclk(8); clks(i); wr(12'h008, 32'h3);
            wait (vif.cs_n === 1'b1); settle(); drain(n);
        end

        // ---- F22, cg_spis_irq: each event with its enable 0 and 1, and cleared in the cycle of a new one
        for (int en = 0; en < 2; en++) begin
            wr(12'hFE4, en ? 32'h7 : 32'h0); wr(12'hFE0, 32'h7);
            pkt(17); settle(); rd(12'hFE0, d);
            if (d[2:0] !== 3'b111) `uvm_error("TEST", $sformatf("IRQSTAT %03b after a packet of 17 bytes", d[2:0]))
            if (vif.irq !== en[0]) `uvm_error("TEST", $sformatf("irq %0b with IRQEN %0d", vif.irq, en ? 7 : 0))
            wr(12'h008, 32'h3); wr(12'hFE0, 32'h7);
        end
        for (int i = 0; i < 10; i++) begin                                    // byte received
            fork pkt(2); join_none
            wait_sclk(16); clks(i); wr(12'hFE0, 32'h1);
            wait (vif.cs_n === 1'b1); settle(); drain(n);
        end
        for (int i = 0; i < 10; i++) begin                                    // packet complete
            fork pkt(1); join_none
            @(negedge vif.cs_n); @(posedge vif.cs_n); clks(i); wr(12'hFE0, 32'h2);
            settle(); drain(n);
        end
        pkt(16); settle();
        for (int i = 0; i < 10; i++) begin                                    // overrun
            fork pkt(1); join_none
            wait_sclk(8); clks(i); wr(12'hFE0, 32'h4);
            wait (vif.cs_n === 1'b1); settle();
        end
        wr(12'h008, 32'h3); wr(12'hFE0, 32'h7); wr(12'hFE4, 32'h0);

        // ---- F23, cg_spis_dma: a request while a byte waits; it drops for one pclk after each acknowledge
        pkt(2); settle();                                                      // data held, requests off
        rd(12'h00C, d); wr(12'hFE8, 32'h1); clks(4);                           // a request with several bytes
        fork dma_responder(); join_none
        dma_on = 1; clks(60);
        pkt(1); settle(); clks(30);                                            // a request with one byte
        pkt(12, -1, 0, 30, 30); settle(); clks(200);
        dma_on = 0; rd(12'h00C, d);
        if (d[0]) `uvm_error("TEST", "bytes left in the FIFO after the DMA responder ran")
        if (n_dma != 15) `uvm_error("TEST", $sformatf("the DMA responder took %0d bytes, 15 were sent", n_dma))
        wr(12'hFE8, 32'h2); pkt(1); settle(); clks(10);                        // bit 1 has no request in this block
        if (vif.dma_req !== 1'b0) `uvm_error("TEST", "dma_req with DMACTL = 2")
        wr(12'hFE8, 32'h0); drain(n);

        // ---- F07, F21: a reset in the middle of a packet; the master goes on clocking
        fork pkt(6); join_none
        wait_sclk(19); reset();
        wait (vif.cs_n === 1'b1); settle();
        rd(12'h008, d); rd(12'h00C, d);
        if (d !== 32'h0) `uvm_error("TEST", $sformatf("STATUS %08h after a reset in mid-packet", d))
        wr(12'h008, 32'h1); wr(12'h004, 8'h5A); pkt(3); settle(); drain(n); expect_count("a packet after the reset", n, 3);

        if (env.sb.n_pkt_cmp < 40) `uvm_error("TEST", $sformatf("only %0d packets were compared with the agent", env.sb.n_pkt_cmp))
        phase.phase_done.set_drain_time(this, 200ns);
        phase.drop_objection(this);
    endtask
endclass
