`timescale 1ns/1ps
// =============================================================================
// tb_apb_shim.sv -- the shared peripheral front end (rtl/common/garuda_apb_shim.v)
//
// Every peripheral inherits its contract compliance from this module, so this
// TB is where the contract itself is proven, once:
//   IP pass-through, and the 16550 word->byte re-map (ADDR_SHIFT=2)
//   tail registers IRQSTAT / IRQEN / DMACTL / ID
//   PSLVERR on an unmapped offset; PREADY high in every cycle of every access
//   sticky level IRQ: a one-cycle event stays asserted until W1C (D-17)
//   set-beats-clear when an event lands on its own W1C
//   DMA request drops for >=1 pclk after ack, even with the source still full
//     (the dma_chan taken_q rule, D-21) - watched by dma_req_checker too
//   pad input synchroniser: 2 cycles, no X
// =============================================================================
module tb_apb_shim;

    localparam int N_EVT = 4;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;                      // 125 MHz

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    // ---- DUT A: word-mapped IP (ADDR_SHIFT=0) --------------------------------
    logic [N_EVT-1:0] evt = 0;
    logic rx_avail = 0, tx_space = 0, dma_ack = 0;
    wire  irq, dma_req;
    wire [1:0] dmactl;
    logic pad_async = 0;
    wire  pad_sync;

    wire        ip_psel, ip_penable, ip_pwrite;
    wire [11:0] ip_paddr;
    wire [31:0] ip_pwdata;
    logic [31:0] ip_prdata;
    logic        ip_pready = 1;

    garuda_apb_shim #(.N_EVT(N_EVT), .SYNC_W(1), .IP_LIMIT(12'h100),
                      .ADDR_SHIFT(0), .BLOCK_NUM(8'd13)) dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .ip_psel_o(ip_psel), .ip_penable_o(ip_penable), .ip_pwrite_o(ip_pwrite),
        .ip_paddr_o(ip_paddr), .ip_pwdata_o(ip_pwdata), .ip_prdata_i(ip_prdata),
        .ip_pready_i(ip_pready),
        .evt_i(evt), .irq_o(irq),
        .rx_avail_i(rx_avail), .tx_space_i(tx_space), .dma_ack_i(dma_ack),
        .dma_req_o(dma_req), .dmactl_o(dmactl),
        .pad_async_i(pad_async), .pad_sync_o(pad_sync));

    // a trivial word-addressed IP: 8 registers, PREADY high
    logic [31:0] ipregs [0:7];
    always @(posedge pclk) if (ip_psel && ip_penable && ip_pwrite) ipregs[ip_paddr[4:2]] <= ip_pwdata;
    always @(*) ip_prdata = ipregs[ip_paddr[4:2]];

    // ---- DUT B: byte-addressed IP behind ADDR_SHIFT=2 (the 16550 case) -------
    logic        b_psel = 0, b_penable = 0, b_pwrite = 0;
    logic [11:0] b_paddr = 0;
    logic [31:0] b_pwdata = 0;
    wire  [31:0] b_prdata;
    wire         b_pready, b_pslverr;
    wire         bip_psel, bip_penable, bip_pwrite;
    wire  [11:0] bip_paddr;
    wire  [31:0] bip_pwdata;
    logic [31:0] bip_prdata;

    garuda_apb_shim #(.N_EVT(1), .SYNC_W(1), .IP_LIMIT(12'h020),
                      .ADDR_SHIFT(2), .BLOCK_NUM(8'd16)) dut_b (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(b_psel), .penable_i(b_penable), .pwrite_i(b_pwrite),
        .paddr_i(b_paddr), .pwdata_i(b_pwdata), .prdata_o(b_prdata),
        .pready_o(b_pready), .pslverr_o(b_pslverr),
        .ip_psel_o(bip_psel), .ip_penable_o(bip_penable), .ip_pwrite_o(bip_pwrite),
        .ip_paddr_o(bip_paddr), .ip_pwdata_o(bip_pwdata), .ip_prdata_i(bip_prdata),
        .ip_pready_i(1'b1),
        .evt_i(1'b0), .irq_o(), .rx_avail_i(1'b0), .tx_space_i(1'b0),
        .dma_ack_i(1'b0), .dma_req_o(), .dmactl_o(),
        .pad_async_i(1'b0), .pad_sync_o());

    // byte-addressed IP: 8 registers indexed by paddr[2:0]
    logic [7:0] bregs [0:7];
    always @(posedge pclk) if (bip_psel && bip_penable && bip_pwrite) bregs[bip_paddr[2:0]] <= bip_pwdata[7:0];
    always @(*) bip_prdata = {24'd0, bregs[bip_paddr[2:0]]};

    dma_req_checker #(.NAME("shim")) u_chk (
        .clk_i(pclk), .rst_n_i(preset_n), .req_i(dma_req), .ack_i(dma_ack));

    // PREADY must be high in every cycle of every access
    int pready_viol = 0;
    always @(posedge pclk) if (preset_n && bfm.psel && !bfm.pready) pready_viol++;

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    task automatic bwrite(input [11:0] a, input [31:0] d);
        @(posedge pclk); #0.1 b_psel = 1; b_pwrite = 1; b_paddr = a; b_pwdata = d; b_penable = 0;
        @(posedge pclk); #0.1 b_penable = 1;
        @(posedge pclk); #0.1 b_psel = 0; b_penable = 0; b_pwrite = 0;
    endtask

    logic [31:0] d;
    bit e;
    int i, t0;

    initial begin
        $display("=== tb_apb_shim: shared peripheral front end ===");
        repeat (3) @(posedge pclk);
        preset_n = 1;
        repeat (2) @(posedge pclk);

        // ---- pass-through -----------------------------------------------------
        bfm.write(12'h008, 32'hCAFE_0001, e);
        bfm.read(12'h008, d, e);
        check(d == 32'hCAFE_0001 && !e, "IP pass-through: write then read at 0x008");
        check(ipregs[2] == 32'hCAFE_0001, "write reached the IP register");

        // ---- word -> byte re-map (16550) ---------------------------------------
        bwrite(12'h000, 32'h0000_00A5);
        bwrite(12'h004, 32'h0000_005A);
        bwrite(12'h01C, 32'h0000_0077);
        check(bregs[0] == 8'hA5 && bregs[1] == 8'h5A && bregs[7] == 8'h77,
              "ADDR_SHIFT=2: word offsets 0x00/0x04/0x1C hit IP regs 0/1/7");

        // ---- tail registers -----------------------------------------------------
        bfm.read(12'hFEC, d, e);
        check(d == {16'h6A5D, 8'd13, 8'd1} && !e, "ID reads {magic, block, rev}");
        bfm.write(12'hFE8, 32'h3, e);
        bfm.read(12'hFE8, d, e);
        check(d == 32'h3 && dmactl == 2'b11, "DMACTL is RW");

        // ---- PSLVERR / PREADY ----------------------------------------------------
        bfm.read(12'h800, d, e);
        check(e, "PSLVERR on an unmapped offset inside the window");
        bfm.read(12'hFE0, d, e);
        check(!e, "no PSLVERR on a tail register");
        check(pready_viol == 0, "PREADY high in every cycle of every access so far");

        // ---- sticky interrupt ------------------------------------------------------
        bfm.write(12'hFE4, 32'hF, e);                 // enable all four
        @(posedge pclk); #0.1 evt[1] = 1;             // one-cycle event
        @(posedge pclk); #0.1 evt[1] = 0;
        repeat (20) @(posedge pclk);
        check(irq, "[D-17] a one-cycle event still asserts IRQ 20 cycles later");
        bfm.read(12'hFE0, d, e);
        check(d == 32'h2, "IRQSTAT shows the captured source");
        bfm.write(12'hFE0, 32'h2, e);
        repeat (2) @(posedge pclk);
        check(!irq, "W1C clears IRQSTAT and drops the line");

        bfm.write(12'hFE4, 32'h1, e);                 // enable bit 0 only
        @(posedge pclk); #0.1 evt[2] = 1;
        @(posedge pclk); #0.1 evt[2] = 0;
        repeat (3) @(posedge pclk);
        bfm.read(12'hFE0, d, e);
        check(d[2] && !irq, "a disabled source is still captured but does not raise IRQ");
        bfm.write(12'hFE0, 32'hF, e);

        // set beats clear: while the source is still asserted, a W1C cannot
        // clear the bit - otherwise a level interrupt could be lost the moment
        // firmware acknowledges it
        bfm.write(12'hFE4, 32'hF, e);
        @(posedge pclk); #0.1 evt[0] = 1;              // source stays asserted
        repeat (2) @(posedge pclk);
        bfm.write(12'hFE0, 32'h1, e);                  // try to clear it
        bfm.read(12'hFE0, d, e);
        check(d[0], "W1C cannot clear a source that is still asserted (set beats clear)");
        @(posedge pclk); #0.1 evt[0] = 0;
        repeat (2) @(posedge pclk);
        bfm.write(12'hFE0, 32'h1, e);
        bfm.read(12'hFE0, d, e);
        check(!d[0], "once the source drops, W1C clears the bit");
        bfm.write(12'hFE0, 32'hF, e);

        // ---- DMA request and hold-off -----------------------------------------------
        bfm.write(12'hFE8, 32'h1, e);                 // request on RX data
        @(posedge pclk); #0.1 rx_avail = 1;           // and it STAYS high (FIFO level)
        repeat (2) @(posedge pclk);
        check(dma_req, "dma_req asserts while the source has data");

        @(posedge pclk); #0.1 dma_ack = 1;            // 1 pclk, as the DMA drives it
        @(posedge pclk); #0.1 dma_ack = 0;
        #0.5 check(!dma_req, "[D-21] dma_req drops on ack even with the source still full");
        t0 = 0;
        while (!dma_req && t0 < 10) begin @(posedge pclk); t0++; end
        check(dma_req && t0 >= 1, $sformatf("dma_req re-asserts after %0d cycles (>=1 pclk gap)", t0));
        check(u_chk.violations() == 0, "dma_req_checker: no stuck request after ack");

        rx_avail = 0;
        repeat (2) @(posedge pclk);
        check(!dma_req, "dma_req drops when the source empties");
        bfm.write(12'hFE8, 32'h0, e);

        // ---- pad synchroniser -------------------------------------------------------
        @(posedge pclk); #0.1 pad_async = 1;
        @(posedge pclk); #0.5 check(!pad_sync, "pad sync: not visible after 1 cycle");
        @(posedge pclk); #0.5 check(pad_sync, "pad sync: visible after 2 cycles, no X");

        check(pready_viol == 0, "PREADY never deasserted in the whole run");
        $display("tb_apb_shim: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #200_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
