`timescale 1ns/1ps
// =============================================================================
// tb_uart.sv -- Blocks 16/17/18 UART (vendored PULP 16550 + GARUDA wrapper)
//
// Spec: GARUDA-UART-SPEC-001 §11. Drives a real uart_model on the pins.
//
// Most tests run at divisor 124 (1 us per bit) to keep the simulation short;
// t_uart_baud uses the real 115200 divisor once, because the point of that
// test is the arithmetic in [N-7.1], not the data path.
// =============================================================================
module tb_uart;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;                        // 125 MHz

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    logic dma_ack = 0;
    wire  irq, dma_req, tx, rx;

    garuda_uart_top #(.BLOCK_NUM(8'd16)) dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .irq_o(irq), .dma_req_o(dma_req), .dma_ack_i(dma_ack),
        .uart_tx_o(tx), .uart_rx_i(rx));

    uart_model #(.BIT_NS(1000.0)) u_term (.dut_rx_o(rx), .dut_tx_i(tx));

    dma_req_checker #(.NAME("uart")) u_dchk (
        .clk_i(pclk), .rst_n_i(preset_n), .req_i(dma_req), .ack_i(dma_ack));

    int pready_viol = 0;
    always @(posedge pclk)
        if (preset_n && bfm.psel && !bfm.pready) pready_viol++;

    // ---- the other two instances (blocks 17 and 18), for R-9 --------------------
    // Same module, different BLOCK_NUM, each with its own APB master, terminal
    // and interrupt / DMA lines - which is how the chip instantiates them.
    garuda_apb_bfm bfm1 (.pclk(pclk), .preset_n(preset_n));
    garuda_apb_bfm bfm2 (.pclk(pclk), .preset_n(preset_n));
    wire irq1, dma_req1, tx1, rx1, irq2, dma_req2, tx2, rx2;

    garuda_uart_top #(.BLOCK_NUM(8'd17)) dut1 (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm1.psel), .penable_i(bfm1.penable), .pwrite_i(bfm1.pwrite),
        .paddr_i(bfm1.paddr), .pwdata_i(bfm1.pwdata), .prdata_o(bfm1.prdata),
        .pready_o(bfm1.pready), .pslverr_o(bfm1.pslverr),
        .irq_o(irq1), .dma_req_o(dma_req1), .dma_ack_i(1'b0),
        .uart_tx_o(tx1), .uart_rx_i(rx1));
    garuda_uart_top #(.BLOCK_NUM(8'd18)) dut2 (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm2.psel), .penable_i(bfm2.penable), .pwrite_i(bfm2.pwrite),
        .paddr_i(bfm2.paddr), .pwdata_i(bfm2.pwdata), .prdata_o(bfm2.prdata),
        .pready_o(bfm2.pready), .pslverr_o(bfm2.pslverr),
        .irq_o(irq2), .dma_req_o(dma_req2), .dma_ack_i(1'b0),
        .uart_tx_o(tx2), .uart_rx_i(rx2));

    uart_model #(.BIT_NS(1000.0)) u_term1 (.dut_rx_o(rx1), .dut_tx_i(tx1));
    uart_model #(.BIT_NS(2000.0)) u_term2 (.dut_rx_o(rx2), .dut_tx_i(tx2));

    // ---- things counted for the whole run -----------------------------------------
    realtime tx_fall[$];                           // every falling edge of tx
    always @(negedge tx) tx_fall.push_back($realtime);
    int irq_rises = 0, req_rises = 0;
    always @(posedge irq)     irq_rises++;
    always @(posedge dma_req) req_rises++;

    // register word offsets (UART-SPEC §6)
    localparam [11:0] R_RBR = 12'h000, R_THR = 12'h000, R_DLL = 12'h000,
                      R_IER = 12'h004, R_DLM = 12'h004, R_IIR = 12'h008,
                      R_FCR = 12'h008, R_LCR = 12'h00C, R_MCR = 12'h010,
                      R_LSR = 12'h014, R_MSR = 12'h018, R_SCR = 12'h01C,
                      R_IRQSTAT = 12'hFE0, R_IRQEN = 12'hFE4,
                      R_DMACTL  = 12'hFE8, R_ID    = 12'hFEC;
    localparam LSR_DR = 0, LSR_PE = 2, LSR_FE = 3, LSR_THRE = 5, LSR_TEMT = 6;

    // 125 MHz / (div+1); div 124 = 1 us per bit, div 1084 = 115207 baud
    localparam int DIV_FAST = 124, DIV_115K = 1084;

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    task automatic set_baud(input int div, input bit par);
        bit e;
        bfm.wr(R_LCR, 32'h83);                       // DLAB=1, 8 bits, 1 stop
        bfm.wr(R_DLL, div & 32'hFF);
        bfm.wr(R_DLM, (div >> 8) & 32'hFF);
        bfm.wr(R_LCR, par ? 32'h0B : 32'h03);        // DLAB=0, parity per arg
        u_term.parity_en = par;
    endtask

    // any divisor, any LCR setting
    task automatic set_frame(input int div, input [7:0] lcr);
        bfm.wr(R_LCR, {24'd0, 8'h80 | lcr});         // DLAB=1
        bfm.wr(R_DLL, div & 32'hFF);
        bfm.wr(R_DLM, (div >> 8) & 32'hFF);
        bfm.wr(R_LCR, {24'd0, lcr & 8'h7F});         // DLAB=0
        u_term.parity_en = lcr[3];
    endtask

    task automatic wait_dr_n(input int maxg, output bit ok);
        logic [31:0] d;
        bit e;
        int g = 0;
        do begin bfm.read(R_LSR, d, e); g++; end while (!d[LSR_DR] && g < maxg);
        ok = d[LSR_DR];
    endtask

    // wait for the terminal to have decoded n frames from the DUT
    task automatic wait_term(input int n, input int maxcyc);
        int c = 0;
        while (u_term.n_rx() < n && c < maxcyc) begin @(posedge pclk); c++; end
    endtask

    // wait for the DUT's transmitter to be completely idle
    task automatic wait_temt();
        logic [31:0] d;
        bit e;
        int g = 0;
        do begin bfm.read(R_LSR, d, e); g++; end while (!d[LSR_TEMT] && g < 200000);
    endtask

    // wait for the DUT to have a received byte
    task automatic wait_dr(output bit ok);
        logic [31:0] d;
        bit e;
        int g = 0;
        do begin bfm.read(R_LSR, d, e); g++; end while (!d[LSR_DR] && g < 20000);
        ok = d[LSR_DR];
    endtask

    task automatic drain_rx();
        logic [31:0] dd;
        bit ee;
        int g = 0;
        bfm.read(R_LSR, dd, ee);
        while (dd[LSR_DR] && g < 40) begin
            bfm.read(R_RBR, dd, ee);
            bfm.read(R_LSR, dd, ee);
            g++;
        end
        repeat (20) @(posedge pclk);          // let the line settle idle
    endtask

    task automatic put(input byte unsigned b);
        logic [31:0] d;
        bit e;
        int g = 0;
        do begin bfm.read(R_LSR, d, e); g++; end while (!d[LSR_THRE] && g < 20000);
        bfm.wr(R_THR, {24'd0, b});
    endtask

    logic [31:0] d;
    bit e, ok;
    byte unsigned b;
    int i, t, nbad;
    real lo_ok, hi_ok;
    int wl, mask, div, lat, rr0, ir0, nfall;
    real baud, errp;
    realtime tf, gap;
    logic [7:0] lsr;

    initial begin
        $display("=== tb_uart: Blocks 16/17/18 UART ===");

        repeat (4) @(posedge pclk);
        check(tx === 1'b1, "[R-8] tx is high (line idle) while in reset");
        preset_n = 1;
        repeat (4) @(posedge pclk);
        check(tx === 1'b1, "[R-8] [N-9.3] tx is high out of reset");

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd16, 8'd1} && !e, "ID register reads block 16");
        bfm.read(12'h800, d, e);
        check(e, "PSLVERR on an unmapped offset");

        // ---- word offsets reach the intended 16550 registers ---------------------
        // SCR/MCR/MSR have no write case and no read case upstream: they decode
        // cleanly (no PSLVERR) and read 0. [N-13.1]/[N-13.2] say so; this test
        // holds upstream to it, and will fail loudly if a re-vendor adds them.
        bfm.wr(R_SCR, 32'h0000_00A5);
        bfm.read(R_SCR, d, e);
        check(d == 32'd0 && !e, $sformatf("[N-13.2] SCR is not implemented: decodes, reads 0 (%08h)", d));
        bfm.read(R_MSR, d, e);
        check(d == 32'd0 && !e, "[N-13.1] MSR is not implemented: decodes, reads 0");
        bfm.read(R_LSR, d, e);
        check(d[31:8] == 24'd0, "[R-3] [N-6.2] PRDATA[31:8] reads 0, not X");
        check(d[7:0] == 8'h60, $sformatf("[N-9.2] [N-9.3] LSR is 0x60 out of reset: rx came up idle through the synchroniser, no garbage byte framed (%02h)", d[7:0]));
        bfm.wr(R_LCR, 32'h0000_0003);
        bfm.read(R_LCR, d, e);
        check(d == 32'h3, "[R-3] [N-6.1] LCR at word offset 0x0C reaches byte register 3");

        // ---- DLAB banking ---------------------------------------------------------
        bfm.wr(R_LCR, 32'h83);                       // DLAB=1
        bfm.wr(R_DLL, 32'h3C); bfm.wr(R_DLM, 32'h04);
        bfm.read(R_DLL, d, e); check(d == 32'h3C, "[R-3] [N-6.2a] DLAB=1: offset 0x00 is DLL");
        bfm.read(R_DLM, d, e); check(d == 32'h04, "[R-3] [N-6.2a] DLAB=1: offset 0x04 is DLM");
        bfm.wr(R_LCR, 32'h03);                       // DLAB=0
        bfm.read(R_IER, d, e); check(d == 32'h0, "[R-3] DLAB=0: offset 0x04 is IER");

        // ---- transmit ---------------------------------------------------------------
        set_baud(DIV_FAST, 0);
        u_term.clear();
        put(8'h41);                                   // 'A'
        t = 0;
        while (u_term.n_rx() == 0 && t < 40000) begin @(posedge pclk); t++; end
        check(u_term.n_rx() == 1, "[R-1] [N-7.2] the terminal received one frame");
        if (u_term.n_rx()) begin
            b = u_term.get();
            check(b == 8'h41, $sformatf("[R-1] and it was 0x41 (got 0x%02h)", b));
        end
        check(u_term.viol() == 0, "[R-1] frame was well formed (stop bit high)");

        // ---- receive ----------------------------------------------------------------
        u_term.send(8'h5A);
        wait_dr(ok);
        check(ok, "[R-1] [N-7.3] LSR[0] set after the terminal sent a byte");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h5A, $sformatf("[R-1] RBR returned 0x5A (got 0x%02h)", d[7:0]));
        bfm.read(R_LSR, d, e);
        check(!d[LSR_DR], "[R-1] [N-7.3] reading RBR popped the FIFO");

        // ---- loopback, both directions ------------------------------------------------
        u_term.clear();
        nbad = 0;
        for (i = 0; i < 32; i++) put(8'h20 + i[7:0]);
        t = 0;
        while (u_term.n_rx() < 32 && t < 500000) begin @(posedge pclk); t++; end
        check(u_term.n_rx() == 32, $sformatf("[R-1] 32 bytes out (%0d arrived)", u_term.n_rx()));
        for (i = 0; i < 32 && u_term.n_rx() > 0; i++) begin
            b = u_term.get();
            if (b != 8'h20 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] all 32 correct and in order (%0d wrong)", nbad));

        nbad = 0;
        for (i = 0; i < 32; i++) begin
            u_term.send(8'hC0 + i[7:0]);
            wait_dr(ok);
            bfm.read(R_RBR, d, e);
            if (!ok || d[7:0] != 8'hC0 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] 32 bytes in, all correct (%0d wrong)", nbad));
        check(u_term.viol() == 0, "[R-1] no framing violation in either direction");

        // ---- baud arithmetic at the real rate --------------------------------------
        set_baud(DIV_115K, 0);
        u_term.bit_ns = 8680.0;
        u_term.clear();
        u_term.reset_meas();
        put(8'h55);                                   // alternating: edge gap = 1 bit
        t = 0;
        while (u_term.n_rx() == 0 && t < 200000) begin @(posedge pclk); t++; end
        check(u_term.n_rx() == 1 && u_term.get() == 8'h55, "[R-2] 0x55 at divisor 1084");
        check(u_term.min_edge_ns > 8590.0 && u_term.min_edge_ns < 8770.0,
              $sformatf("[R-2] bit period %0.0f ns (8680 +/-1%% = 8593..8767)", u_term.min_edge_ns));

        // ---- receiver baud tolerance ([N-8.1], OPEN-U1) --------------------------------
        // Sweep the terminal's bit period against a fixed DUT divisor and find
        // where reception actually breaks. Upstream samples at the bit boundary,
        // so this is a measurement, not a quotation from a datasheet.
        set_baud(DIV_FAST, 0);
        u_term.bit_ns = 1000.0;
        lo_ok = 0.0; hi_ok = 0.0;
        for (i = -60; i <= 60; i = i + 5) begin
            u_term.bit_ns = 1000.0 * (1.0 + i / 1000.0);   // -6% .. +6% in 0.5% steps
            u_term.clear();
            // A point that fails can leave the receiver mid-frame and a stray
            // byte in the FIFO; without draining, one bad point poisons every
            // point after it and the measurement is meaningless.
            drain_rx();
            u_term.send(8'hA5);
            wait_dr(ok);
            bfm.read(R_RBR, d, e);
            if (ok && d[7:0] == 8'hA5) begin
                if (i < 0 && (lo_ok == 0.0 || i / 10.0 < lo_ok)) lo_ok = i / 10.0;
                if (i > 0 && i / 10.0 > hi_ok)                   hi_ok = i / 10.0;
            end
        end
        $display("[MEASURED] receiver baud tolerance: %0.1f%% .. +%0.1f%%", lo_ok, hi_ok);
        check(lo_ok <= -1.0 && hi_ok >= 1.0,
              $sformatf("[N-8.1] receiver tolerates at least +/-1%% (measured %0.1f%%..+%0.1f%%)",
                        lo_ok, hi_ok));
        u_term.bit_ns = 1000.0;

        // ---- parity and framing are REPORTED (patch 0001, was ERR-U2) -------------
        // Upstream could not do this: err_clr_i was tied high so the error flop
        // could never set, and the byte was pushed to the FIFO one state before
        // the parity bit was even checked. Both are fixed in
        // rtl/third_party/pulp/apb_uart_sv/patches/0001-*.patch.
        set_baud(DIV_FAST, 1);                        // 8E1
        drain_rx();
        bfm.wr(R_IRQSTAT, 32'h7);
        u_term.clear();
        u_term.send(8'h3C, 1'b0);                     // correct parity
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(ok && !d[LSR_PE], "[R-7] a clean 8E1 frame sets no parity error");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h3C, "[R-1] and carries its data");

        drain_rx();
        bfm.wr(R_IRQSTAT, 32'h7);
        u_term.send(8'h3C, 1'b1);                     // deliberately WRONG parity
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(d[LSR_PE], "[R-7] LSR[2] flags the parity error");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h3C, "[R-7] and the byte is still delivered, not dropped");
        bfm.read(R_IRQSTAT, d, e);
        check(d[2], "[R-7] [N-7.5a] IRQSTAT[2] captured the line error");

        // the flag belongs to ITS OWN byte and must not leak into the next one
        drain_rx();
        u_term.send(8'h5A, 1'b0);                     // clean, right after a bad one
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(!d[LSR_PE], "[R-7] the error does not leak into the following byte");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h5A, "[R-7] which is itself correct");

        // framing: hold the stop bit low
        set_baud(DIV_FAST, 0);
        drain_rx();
        bfm.wr(R_IRQSTAT, 32'h7);
        u_term.send_framing_error(8'h96);
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(d[LSR_FE], "[R-7] LSR[3] flags a low stop bit (framing error)");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h96, "[R-7] and that byte is still delivered");
        bfm.read(R_IRQSTAT, d, e);
        check(d[2], "[R-7] [N-7.5a] framing raises the same line-error event");

        drain_rx();
        u_term.send(8'h69);
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(!d[LSR_FE], "[R-7] framing error does not leak into the next byte");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h69, "[R-7] which is itself correct");

        // ---- back-to-back frames, no inter-frame gap ------------------------------
        // Patch 0001 moved the FIFO push to after STOP_BIT, so the receiver now
        // returns to IDLE at the stop/next-start boundary instead of one state
        // earlier. This is the test for that: 16 frames with zero idle time
        // between them, which is the worst case for missing the next start bit.
        drain_rx();
        u_term.clear();
        nbad = 0;
        // Each branch needs its OWN index: a shared module-level loop variable
        // is incremented by both threads and the test then checks nonsense.
        fork
            begin : b2b_send
                int si;
                for (si = 0; si < 16; si++) u_term.send(8'h80 + si[7:0]);
            end
            begin : b2b_recv
                int ri;
                logic [31:0] rd;
                bit re, rok;
                for (ri = 0; ri < 16; ri++) begin
                    wait_dr(rok);
                    bfm.read(R_RBR, rd, re);
                    if (!rok || rd[7:0] != 8'h80 + ri[7:0]) begin
                        nbad++;
                        $display("[B2B] index %0d: expected %02h got %02h ok=%b at %0t",
                                 ri, 8'h80 + ri[7:0], rd[7:0], rok, $time);
                    end
                end
            end
        join
        check(nbad == 0, $sformatf("[N-8.2] 16 back-to-back frames, no gap (%0d wrong)", nbad));
        bfm.read(R_LSR, d, e);
        check(!d[LSR_FE] && !d[LSR_PE], "[N-8.2] and none of them framed badly");
        drain_rx();

        // ---- interrupt --------------------------------------------------------------------
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_IRQEN, 32'h1);                       // RX data available only
        check(!irq, "[R-5] no interrupt with an empty RX FIFO");
        u_term.send(8'h77);
        t = 0;
        while (!irq && t < 40000) begin @(posedge pclk); t++; end
        check(irq, "[R-5] RX interrupt asserted");
        repeat (60) @(posedge pclk);
        check(irq, "[R-5] still asserted 60 pclk later (level, not a pulse)");
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (2) @(posedge pclk);
        check(irq, "[R-5] [N-7.5] W1C alone does not clear it - the byte is still waiting");
        bfm.read(R_RBR, d, e);                        // drain the source
        repeat (4) @(posedge pclk);                   // lsr_q is refreshed in idle cycles
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (4) @(posedge pclk);
        check(!irq, "[R-5] cleared once the source is drained and W1C written");
        bfm.wr(R_IRQEN, 32'h0);

        // ---- DMA -----------------------------------------------------------------------------
        bfm.wr(R_DMACTL, 32'h1);                      // request on RX data
        check(!dma_req, "[R-6] no request with an empty RX FIFO");
        u_term.send(8'hE7);
        t = 0;
        while (!dma_req && t < 40000) begin @(posedge pclk); t++; end
        check(dma_req, "[R-6] [N-7.6] dma_req asserts when a byte arrives");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'hE7, "[R-6] the DMA's read returns the byte");
        check(d[31:8] == 24'd0, "[R-6a] [N-7.6a] word-sized beat, byte in [7:0], rest 0");
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        repeat (4) @(posedge pclk);
        check(!dma_req, "[R-6] dma_req drops after the ack");
        check(u_dchk.violations() == 0, "[R-6] dma_req_checker clean");

        // ---- and never while DLAB is set ---------------------------------------------------
        u_term.send(8'h11);
        t = 0;
        while (!dma_req && t < 40000) begin @(posedge pclk); t++; end
        check(dma_req, "a byte is waiting, so a request is pending");
        bfm.wr(R_LCR, 32'h83);                        // DLAB=1
        repeat (4) @(posedge pclk);
        check(!dma_req, "[N-7.6b] the request is withdrawn while DLAB is set");
        bfm.wr(R_LCR, 32'h03);                        // DLAB=0
        repeat (4) @(posedge pclk);
        check(dma_req, "[N-7.6b] and comes back when DLAB is cleared");
        bfm.wr(R_DMACTL, 32'h0);
        bfm.read(R_RBR, d, e);

        // =========================================================================
        // Added 2026-10-04: every setting the spec lists, on the pins
        // =========================================================================

        // ---- LSR: reading it changes nothing ([N-6.3a]) ------------------------------------
        // The transmitter is still finishing a 115200-baud frame from the DMA
        // test above. The divisor must not be changed under it: the vendored
        // baud counter compares for EQUALITY, so a smaller divisor written
        // mid-frame leaves it counting to the 16-bit wrap - the line stalls for
        // up to 65 536 pclk and TEMT stays low (BUGS.md UART-3). Firmware has
        // the same obligation: wait for TEMT before touching DLL/DLM.
        wait_temt();
        set_frame(DIV_FAST, 8'h03);
        u_term.bit_ns = 1000.0;
        drain_rx();
        u_term.send(8'hB4);
        wait_dr(ok);
        nbad = 0;
        for (i = 0; i < 8; i++) begin
            bfm.read(R_LSR, d, e);
            if (d[7:0] != 8'h61) nbad++;
        end
        check(nbad == 0, $sformatf("[N-6.3a] eight LSR reads in a row all return DR|THRE|TEMT: reading LSR alters nothing (last LSR=%02h, %0d differ)", d[7:0], nbad));
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'hB4, "[N-6.3a] and the byte is still there for RBR");
        bfm.read(R_LSR, d, e);
        check(d[7:0] == 8'h60, $sformatf("[N-6.3] DR is a level: it drops when the FIFO empties (LSR=%02h)", d[7:0]));

        // ---- THRE and TEMT are different things ([N-6.3b]) ---------------------------------
        u_term.clear();
        tx_fall.delete();
        put(8'h00);                                   // nine low bit times: start + data
        repeat (375) @(posedge pclk);                 // three bit times in
        bfm.read(R_LSR, d, e);
        check(d[LSR_THRE] && !d[LSR_TEMT] && tx === 1'b0,
              $sformatf("[N-6.3b] [N-6.3] mid-frame THRE is already 1 while TEMT is 0 and the line is busy (LSR=%02h tx=%b)", d[7:0], tx));
        wait_temt();
        tf  = (tx_fall.size() > 0) ? tx_fall[0] : 0;
        gap = $realtime - tf;
        check(tx_fall.size() == 1 && gap >= 10000.0,
              $sformatf("[N-6.3b] TEMT rises only once the stop bit is complete (%0.0f ns after the start edge; the frame is 10000)", gap));
        wait_term(1, 2000);
        check(u_term.n_rx() == 1 && u_term.get() == 8'h00, "[N-6.3b] and the frame it was guarding arrived intact");

        // ---- every word length LCR[1:0] offers, both directions -----------------------------
        // The terminal is 8N1. A shorter frame from the DUT therefore decodes
        // with the stop bit and idle line in the upper bits, and a shorter
        // frame TO the DUT is sent with ones there, which the DUT sees as its
        // stop bit arriving on time.
        for (i = 0; i < 4; i++) begin
            wl   = 5 + i;
            mask = (1 << wl) - 1;
            set_frame(DIV_FAST, i[7:0]);
            drain_rx();
            u_term.clear();
            put(8'hB5);
            wait_term(1, 4000);
            b = (u_term.n_rx() == 1) ? u_term.get() : 8'h00;
            check(b == ((8'hB5 & mask) | (8'hFF & ~mask)) && u_term.viol() == 0,
                  $sformatf("[R-1] LCR[1:0]=%0d: a %0d-bit frame goes out LSB first, then the stop bit (terminal saw %02h)", i, wl, b));
            u_term.send((8'hB5 & mask) | (8'hFF & ~mask));
            wait_dr(ok);
            bfm.read(R_LSR, d, e);
            lsr = d[7:0];
            bfm.read(R_RBR, d, e);
            check(ok && d[7:0] == (8'hB5 & mask) && !lsr[LSR_FE],
                  $sformatf("[R-1] LCR[1:0]=%0d: a %0d-bit frame comes in as %02h, upper bits 0, no framing error", i, wl, d[7:0]));
        end

        // ---- LCR[2]: one stop bit or two ------------------------------------------------------
        // 0xFF has exactly one falling edge per frame, the start bit, so the
        // gap between two of them back to back is the frame length.
        for (i = 0; i < 2; i++) begin
            set_frame(DIV_FAST, i ? 8'h07 : 8'h03);
            u_term.clear();
            wait_temt();
            tx_fall.delete();
            put(8'hFF);
            bfm.wr(R_THR, 32'hFF);                    // queued right behind it
            wait_term(2, 6000);
            nfall = tx_fall.size();
            gap   = (nfall == 2) ? tx_fall[1] - tx_fall[0] : 0;
            check(nfall == 2 && gap > (10 + i) * 1000.0 - 50.0 && gap < (10 + i) * 1000.0 + 150.0,
                  $sformatf("[R-1] LCR[2]=%0d: back-to-back frames are %0d bit times apart (%0.0f ns)", i, 10 + i, gap));
        end

        // ---- 8E1 transmit: the parity bit the DUT itself sends ----------------------------------
        set_frame(DIV_FAST, 8'h0B);
        wait_temt();
        u_term.clear();
        put(8'h3C); put(8'h3D); put(8'hFF); put(8'h00);
        wait_term(4, 20000);
        nbad = (u_term.n_rx() == 4) ? 0 : 1;
        if (!nbad) begin
            if (u_term.get() != 8'h3C) nbad++;
            if (u_term.get() != 8'h3D) nbad++;
            if (u_term.get() != 8'hFF) nbad++;
            if (u_term.get() != 8'h00) nbad++;
        end
        check(nbad == 0 && u_term.viol() == 0,
              $sformatf("[R-1] 8E1 transmit: four frames, data and even parity correct on each (%0d wrong, %0d violations)", nbad, u_term.viol()));

        // ---- every baud rate [N-7.1] lists, both directions ---------------------------------------
        // The terminal runs at the NOMINAL rate, as the far end of a real link
        // does; the DUT runs at whatever its divisor actually gives.
        for (i = 0; i < 4; i++) begin
            case (i)
                0:       begin div = 1084;  baud = 115200.0; end
                1:       begin div = 2169;  baud = 57600.0;  end
                2:       begin div = 13020; baud = 9600.0;   end
                default: begin div = 134;   baud = 921600.0; end
            endcase
            set_frame(div, 8'h03);
            u_term.bit_ns = 1.0e9 / baud;
            drain_rx();
            wait_temt();
            u_term.clear();
            u_term.reset_meas();
            put(8'h55);                               // alternating: edge gap = one bit
            wait_term(1, 20 * (div + 1));
            b    = (u_term.n_rx() == 1) ? u_term.get() : 8'h00;
            errp = (1.0e9 / u_term.min_edge_ns - baud) / baud * 100.0;
            check(b == 8'h55 && errp < 1.0 && errp > -1.0,
                  $sformatf("[N-7.1] [R-2] divisor %0d: 0x55 out at %0.0f baud, %0.3f%% from %0.0f", div, 1.0e9 / u_term.min_edge_ns, errp, baud));
            u_term.send(8'hA7);
            wait_dr_n(20 * (div + 1), ok);
            bfm.read(R_RBR, d, e);
            check(ok && d[7:0] == 8'hA7,
                  $sformatf("[N-7.1] divisor %0d: 0xA7 in from a terminal at exactly %0.0f baud (got %02h)", div, baud, d[7:0]));
        end
        u_term.bit_ns = 1000.0;
        set_frame(DIV_FAST, 8'h03);

        // ---- FIFO boundaries: sixteen deep, both directions ----------------------------------------
        drain_rx();
        wait_temt();
        u_term.clear();
        // TX from empty with no status poll between writes: one byte goes
        // straight to the shifter, sixteen fill the FIFO.
        for (i = 0; i < 17; i++) bfm.wr(R_THR, 32'h30 + i);
        bfm.read(R_LSR, d, e);
        check(!d[LSR_THRE] && !d[LSR_TEMT], "[N-6.3] THRE and TEMT are both 0 with the TX FIFO full");
        wait_term(17, 17 * 1300 + 4000);
        nbad = (u_term.n_rx() == 17) ? 0 : 1;
        for (i = 0; i < 17 && u_term.n_rx() > 0; i++) begin
            b = u_term.get();
            if (b != 8'h30 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] TX FIFO full: 17 bytes written back to back all go out, in order (%0d wrong)", nbad));

        // RX: sixteen frames in, none read, then all read
        for (i = 0; i < 16; i++) u_term.send(8'h40 + i[7:0]);
        nbad = 0;
        for (i = 0; i < 16; i++) begin
            bfm.read(R_LSR, d, e);
            if (!d[LSR_DR]) nbad++;
            bfm.read(R_RBR, d, e);
            if (d[7:0] != 8'h40 + i[7:0]) nbad++;
        end
        bfm.read(R_LSR, d, e);
        check(nbad == 0 && !d[LSR_DR],
              $sformatf("[R-1] RX FIFO full: 16 bytes held and read back in order, DR drops after the sixteenth (%0d wrong)", nbad));

        // RX overrun (OPEN-U2: there is no overrun flag). What must hold is
        // that the sixteen bytes already received are not damaged by the ones
        // that did not fit, and that the receiver frames correctly afterwards.
        for (i = 0; i < 19; i++) u_term.send(8'h70 + i[7:0]);
        nbad = 0;
        for (i = 0; i < 16; i++) begin
            bfm.read(R_RBR, d, e);
            if (d[7:0] != 8'h70 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] RX overrun: the 16 bytes already in the FIFO are intact and in order (%0d wrong)", nbad));
        t = 0;
        bfm.read(R_LSR, d, e);
        while (d[LSR_DR] && t < 8) begin
            bfm.read(R_RBR, d, e);
            $display("[OBSERVED] RX overrun: byte %0d of 19 read back as %02h", 17 + t, d[7:0]);
            bfm.read(R_LSR, d, e);
            t++;
        end
        $display("[OBSERVED] RX overrun: 19 sent, %0d delivered, no status bit says so (OPEN-U2)", 16 + t);
        u_term.send(8'hE1);
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        lsr = d[7:0];
        bfm.read(R_RBR, d, e);
        check(ok && d[7:0] == 8'hE1 && !lsr[LSR_FE], "[R-1] and the receiver frames the next byte correctly after an overrun");

        // ---- IRQSTAT[1], the mask, and upstream's own IER ([N-7.5]) ----------------------------------
        drain_rx();
        wait_temt();
        bfm.wr(R_IRQEN, 32'h0);
        bfm.wr(R_IER, 32'h7);                         // every upstream enable on
        bfm.wr(R_IRQSTAT, 32'h7);
        ir0 = irq_rises;
        put(8'h21);
        u_term.send(8'h22);
        wait_dr(ok);
        wait_temt();
        check(!irq && irq_rises == ir0,
              "[N-7.5] upstream's IER reaches nothing: with IRQEN = 0, irq_o stays low through a byte out and a byte in");
        bfm.read(R_RBR, d, e);
        bfm.wr(R_IER, 32'h0);
        bfm.wr(R_IRQSTAT, 32'h7);
        repeat (4) @(posedge pclk);
        bfm.read(R_IRQSTAT, d, e);
        check(d[2:0] == 3'b010, $sformatf("[N-7.5] IRQSTAT[1] follows LSR[5]: with the TX FIFO empty it is back at once after W1C (%03b)", d[2:0]));
        check(!irq, "[R-5] IRQEN = 0 masks it");
        bfm.wr(R_IRQEN, 32'h2);
        repeat (2) @(posedge pclk);
        check(irq, "[R-5] [N-7.5] IRQEN[1] lets it through");
        bfm.wr(R_THR, 32'h00); bfm.wr(R_THR, 32'h00); bfm.wr(R_THR, 32'h00);   // two now queued
        bfm.wr(R_IRQSTAT, 32'h2);
        repeat (2) @(posedge pclk);
        bfm.read(R_IRQSTAT, d, e);
        check(!d[1] && !irq, "[N-7.5] with bytes queued, W1C clears IRQSTAT[1] and the interrupt drops");
        t = 0;
        while (!irq && t < 40000) begin @(posedge pclk); t++; end
        check(irq, "[N-7.5] and it returns when the TX FIFO drains");
        bfm.wr(R_IRQEN, 32'h0);
        wait_temt();

        // ---- DMACTL[1]: request on TX space, twenty beats ([N-7.6]) ------------------------------------
        u_term.clear();
        bfm.wr(R_DMACTL, 32'h2);
        repeat (2) @(posedge pclk);
        check(dma_req, "[N-7.6] DMACTL[1] requests while LSR[5] is set");
        nbad = 0;
        for (i = 0; i < 20; i++) begin
            t = 0;
            while (!dma_req && t < 40000) begin @(posedge pclk); t++; end
            if (!dma_req) nbad++;
            bfm.wr(R_THR, 32'h60 + i);                // the DMA's write beat
            @(posedge pclk); #0.1 dma_ack = 1;
            @(posedge pclk); #0.1 dma_ack = 0;
            #0.1 if (dma_req) nbad++;                 // the pclk after the ack
        end
        check(nbad == 0, $sformatf("[N-7.6] the request drops for at least one pclk after every ack (%0d of 20 did not)", nbad));
        bfm.wr(R_DMACTL, 32'h0);
        wait_term(20, 20 * 1300 + 8000);
        nbad = (u_term.n_rx() == 20) ? 0 : 1;
        for (i = 0; i < 20 && u_term.n_rx() > 0; i++) begin
            b = u_term.get();
            if (b != 8'h60 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[N-7.6] twenty TX beats: every byte reaches the line once, in order (%0d wrong)", nbad));

        // ---- how stale the polled status is, and what that does to the RX request ([N-7.4]) ----------
        drain_rx();
        bfm.wr(R_DMACTL, 32'h1);
        u_term.send(8'h9D);
        t = 0;
        while (!dma_req && t < 40000) begin @(posedge pclk); t++; end
        bfm.read(R_RBR, d, e);                        // the FIFO is empty from this edge
        lat = 0;
        #0.2;
        while (dma_req && lat < 10) begin @(posedge pclk); #0.2; lat++; end
        $display("[MEASURED] dma_req outlives the RBR read that empties the FIFO by %0d pclk", lat);
        check(lat <= 2, $sformatf("[N-7.4] the polled status trails the FIFO by %0d pclk: within the two idle pclk the bridge leaves after an access", lat));

        // one byte, the read, and the ack as early as dma_engine can give it
        u_term.send(8'h9E);
        t = 0;
        while (!dma_req && t < 40000) begin @(posedge pclk); t++; end
        rr0 = req_rises;
        bfm.read(R_RBR, d, e);
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        repeat (40) @(posedge pclk);
        check(d[7:0] == 8'h9E && req_rises == rr0 && !dma_req,
              $sformatf("[N-7.6] one byte, one request: dma_req does not come back for an empty FIFO (%0d extra)", req_rises - rr0));
        bfm.wr(R_DMACTL, 32'h0);
        check(u_dchk.violations() == 0, "[R-6] dma_req_checker still clean");

        // ---- break ([N-13.3]) ---------------------------------------------------------------------------
        drain_rx();
        tx_fall.delete();
        bfm.wr(R_LCR, 32'h43);                        // the 16550's "set break"
        repeat (3000) @(posedge pclk);
        check(tx === 1'b1 && tx_fall.size() == 0, "[N-13.3] LCR[6] generates no break: tx stays high");
        bfm.wr(R_LCR, 32'h03);
        u_term.dut_rx_o = 1'b0;                       // thirty bit times low
        #30000;
        u_term.dut_rx_o = 1'b1;
        #2000;
        bfm.read(R_LSR, d, e);
        check(d[LSR_DR] && d[LSR_FE] && !d[4],
              $sformatf("[N-13.3] a break on rx is not detected as one: LSR[4] stays 0 and it arrives as a framing error (LSR %02h)", d[7:0]));
        bfm.read(R_RBR, d, e);
        lsr = d[7:0];
        bfm.read(R_LSR, d, e);
        check(lsr == 8'h00 && !d[LSR_DR], "[N-13.3] one 0x00 for the whole break, not a stream of them");
        u_term.send(8'hD2);
        wait_dr(ok);
        bfm.read(R_RBR, d, e);
        check(ok && d[7:0] == 8'hD2, "[N-13.3] and the byte after the break is framed correctly");

        // ---- FCR: the clears work, the trigger level does nothing ([N-13.2a]) ---------------------------
        for (i = 0; i < 3; i++) u_term.send(8'h10 + i[7:0]);
        bfm.wr(R_FCR, 32'h02);                        // clear the RX FIFO
        repeat (4) @(posedge pclk);
        bfm.read(R_LSR, d, e);
        check(!d[LSR_DR], "FCR[1] empties the RX FIFO");
        u_term.send(8'h3E);
        wait_dr(ok);
        bfm.read(R_RBR, d, e);
        check(ok && d[7:0] == 8'h3E, $sformatf("and the next byte in is the next byte out (%02h)", d[7:0]));
        u_term.clear();
        for (i = 0; i < 4; i++) bfm.wr(R_THR, 32'hA0 + i);
        bfm.wr(R_FCR, 32'h04);                        // clear the TX FIFO: three queued bytes go
        wait_temt();
        repeat (1500) @(posedge pclk);
        check(u_term.n_rx() == 1 && u_term.get() == 8'hA0,
              $sformatf("FCR[2] empties the TX FIFO: only the frame already in the shifter goes out (%0d frames)", u_term.n_rx() + 1));
        put(8'hA9);
        wait_term(1, 4000);
        check(u_term.n_rx() == 1 && u_term.get() == 8'hA9, "and the transmitter sends the next byte written, not a stale one");
        bfm.wr(R_FCR, 32'hC0);                        // trigger level 14
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_IRQEN, 32'h1);
        u_term.send(8'h71);
        t = 0;
        while (!irq && t < 4000) begin @(posedge pclk); t++; end
        check(irq, "[N-13.2a] FCR trigger level 14 has no effect: one byte still raises the RX interrupt");
        bfm.read(R_RBR, d, e);
        bfm.wr(R_IRQEN, 32'h0);
        bfm.wr(R_FCR, 32'h00);

        // ---- three instances, nothing shared ([R-9]) -------------------------------------------------------
        // uart0 is left as it is: 8N1, idle, with its error and RX interrupts
        // enabled and both DMA requests armed, so anything leaking across from
        // the other two would show.
        bfm1.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd17, 8'd1} && !e, "[R-9] the second instance reads ID block 17");
        bfm2.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd18, 8'd1} && !e, "[R-9] the third instance reads ID block 18");
        bfm1.wr(R_LCR, 32'h8B); bfm1.wr(R_DLL, 32'd124); bfm1.wr(R_DLM, 32'd0); bfm1.wr(R_LCR, 32'h0B);
        bfm2.wr(R_LCR, 32'h83); bfm2.wr(R_DLL, 32'd249); bfm2.wr(R_DLM, 32'd0); bfm2.wr(R_LCR, 32'h03);
        u_term1.parity_en = 1'b1;
        bfm1.wr(R_IRQEN, 32'h4);
        bfm2.wr(R_IRQEN, 32'h4);
        drain_rx();
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_IRQEN, 32'h5);
        bfm.wr(R_DMACTL, 32'h1);
        ir0 = irq_rises;
        rr0 = req_rises;
        fork
            u_term1.send(8'h3C, 1'b1);                // wrong parity into uart1
            u_term2.send_framing_error(8'h96);        // low stop bit into uart2
        join
        repeat (20) @(posedge pclk);
        bfm1.read(R_LSR, d, e);
        check(d[LSR_DR] && d[LSR_PE] && !d[LSR_FE] && irq1,
              $sformatf("[R-9] [R-7] uart1 reports its parity error in its own LSR and on its own interrupt (LSR %02h)", d[7:0]));
        bfm1.read(R_RBR, d, e);
        check(d[7:0] == 8'h3C, "[R-7] uart1 still delivers the byte");
        bfm2.read(R_LSR, d, e);
        check(d[LSR_DR] && d[LSR_FE] && !d[LSR_PE] && irq2,
              $sformatf("[R-9] [R-7] uart2 reports its framing error in its own LSR and on its own interrupt (LSR %02h)", d[7:0]));
        bfm2.read(R_RBR, d, e);
        check(d[7:0] == 8'h96, "[R-7] uart2 still delivers the byte");
        // the other error on each
        bfm2.wr(R_LCR, 32'h0B);
        u_term2.parity_en = 1'b1;
        bfm1.wr(R_IRQSTAT, 32'h7);
        bfm2.wr(R_IRQSTAT, 32'h7);
        fork
            u_term1.send_framing_error(8'h69);
            u_term2.send(8'hC3, 1'b1);
        join
        repeat (20) @(posedge pclk);
        bfm1.read(R_LSR, d, e);
        lsr = d[7:0];
        bfm1.read(R_IRQSTAT, d, e);
        check(lsr[LSR_FE] && !lsr[LSR_PE] && d[2], $sformatf("[R-9] [R-7] uart1 reports a framing error too (LSR %02h)", lsr));
        bfm2.read(R_LSR, d, e);
        lsr = d[7:0];
        bfm2.read(R_IRQSTAT, d, e);
        check(lsr[LSR_PE] && !lsr[LSR_FE] && d[2], $sformatf("[R-9] [R-7] uart2 reports a parity error too (LSR %02h)", lsr));
        bfm.read(R_LSR, d, e);
        lsr = d[7:0];
        bfm.read(R_IRQSTAT, d, e);
        check(lsr == 8'h60 && d[2] == 1'b0 && d[0] == 1'b0 && irq_rises == ir0 && req_rises == rr0 && tx === 1'b1,
              $sformatf("[R-9] uart0 saw none of it: LSR %02h, IRQSTAT %03b, no interrupt, no DMA request, tx idle", lsr, d[2:0]));
        bfm.read(R_LCR, d, e);
        lsr = d[7:0];
        bfm1.read(R_LCR, d, e);
        check(lsr == 8'h03 && d[7:0] == 8'h0B, "[R-9] LCR is per instance: uart0 still 8N1, uart1 8E1");
        // and the other way: uart0 transmits, the other two lines do not move
        u_term.clear(); u_term1.clear(); u_term2.clear();
        put(8'h5E);
        wait_term(1, 4000);
        check(u_term.n_rx() == 1 && u_term1.n_rx() == 0 && u_term2.n_rx() == 0 && tx1 === 1'b1 && tx2 === 1'b1,
              "[R-9] a byte sent by uart0 appears on uart0's tx only");
        bfm.wr(R_IRQEN, 32'h0);
        bfm.wr(R_DMACTL, 32'h0);

        check(pready_viol == 0, "[R-4] PREADY high in every cycle of every access");

        $display("tb_uart: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
