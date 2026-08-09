`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller - directed self-checking testbench
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 14 (verification plan)
//
// Covers every row of the Sec. 14 table that is reachable at block level, plus
// the cases the RTL had to resolve where the spec was silent or contradictory
// (byte-lane alignment, zero-length TCR, error-during-pipelined-write-address,
// reserved address decode). Each test is independent and re-resets nothing -
// they run in sequence against one elaboration, and every channel is left
// disabled on exit.
//
// TWO HABITS TAKEN FROM docs/HANDOFF.md Sec. 5 ("suspect the testbench too"):
//   1. All stimulus is driven on the NEGEDGE of its own clock. Driving at the
//      posedge races the DUT's flops, which cost real debugging time on the
//      core and produces failures that move when timing changes.
//   2. pclk is deliberately skewed off hclk rather than phase-aligned. A
//      divided, edge-aligned pclk is the easy case for the clock-domain
//      crossings; the skewed one is the case that finds an unsynchronized path.
//
// Run:  make test_dma        (Xcelium)
//       make test_dma SIM=xsim
// =============================================================================

module tb_dma_top;

    // -----------------------------------------------------------------------
    // Address map (matches the slave model's parameters)
    // -----------------------------------------------------------------------
    localparam [31:0] MEM_BASE  = 32'h2000_0000;
    localparam integer MEM_BYTES = 8192;
    localparam [31:0] FIFO_BASE = 32'h4000_1000;

    // Register select values (Sec. 6.2)
    localparam integer R_SAR = 0, R_DAR = 1, R_TCR = 2, R_CR = 3, R_SR = 4;

    // CR bit positions (Sec. 6.6 / Sec. 13.1)
    localparam integer B_EN = 0, B_DIR = 1, B_SZ = 3, B_SINC = 5, B_DINC = 6,
                       B_CIRC = 7, B_IE = 8, B_EIE = 9, B_PRI = 10;

    localparam [1:0] DIR_P2M = 2'b00, DIR_M2P = 2'b01, DIR_M2M = 2'b10;
    localparam [1:0] SZ_BYTE = 2'b00, SZ_HALF = 2'b01, SZ_WORD = 2'b10;

    // -----------------------------------------------------------------------
    // Clocks and resets
    // -----------------------------------------------------------------------
    reg hclk = 1'b0;
    reg pclk = 1'b0;
    reg hreset_n = 1'b0;
    reg preset_n = 1'b0;

    always #2.5 hclk = ~hclk;                       // 200 MHz

    // 100 MHz, deliberately not edge-aligned with hclk - see header note 2.
    initial begin
        #1.3;
        forever #5.0 pclk = ~pclk;
    end

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    reg         psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
    reg  [7:0]  paddr = 8'h0;
    reg  [31:0] pwdata = 32'h0;
    wire [31:0] prdata;
    wire        pready, pslverr;

    wire [31:0] haddr, hwdata;
    wire [1:0]  htrans;
    wire        hwrite;
    wire [2:0]  hsize, hburst;
    wire [31:0] hrdata;
    wire        hready, hresp;

    // -----------------------------------------------------------------------
    // dma_req drive: two modes.
    //
    // FORCED mode is a testbench-controlled level, used where a test needs to
    // dictate exactly when the request appears (arbitration precondition,
    // software abort).
    //
    // AUTO mode drives dma_req from the source FIFO's occupancy, which is what
    // Sec. 5.4 actually specifies: "Asserted when peripheral FIFO has data
    // (P->M) ... Deasserted when FIFO empty/full." This matters for more than
    // realism. A testbench that watches a beat counter and then lowers a forced
    // req is always one to two beats late, because the channel re-requests the
    // cycle after each beat completes - so "stop after exactly 3 beats" is not
    // expressible with a forced level. Letting the modelled FIFO run dry stops
    // the channel at a deterministic beat boundary with no reaction latency.
    // -----------------------------------------------------------------------
    reg  [5:0]  req_force = 6'h0;
    reg  [5:0]  req_auto  = 6'h0;
    reg  [5:0]  auto_lvl  = 6'h0;
    wire [5:0]  dma_req   = (req_auto & auto_lvl) | (~req_auto & req_force);

    integer kr;
    always @(posedge hclk) begin
        for (kr = 0; kr < 6; kr = kr + 1)
            auto_lvl[kr] <= (u_slave.rd_tail[kr] > u_slave.rd_head[kr]);
    end

    wire [5:0]  dma_ack, dma_irq, dma_err;

    // Slave-model controls.
    //
    // g_waits/g_rand are the GLOBAL bus timing applied to every test, set from
    // +GWAIT=<n> / +GRAND=1 / +SEED=<n>. A fixed wait count exercises exactly
    // one timing; randomised counts are what actually open and close the hold
    // windows in the AHB master's address and data phases. This mirrors
    // scripts/run_regression.sh's regress_rand mode, which found three stall
    // -window bugs in the core (docs/HANDOFF.md Sec. 4).
    reg  [7:0]  g_waits = 8'd0;
    reg         g_rand  = 1'b0;

    reg  [7:0]  sl_waits = 8'd0;
    reg         sl_rand  = 1'b0;
    reg         sl_err_en = 1'b0;
    reg  [31:0] sl_err_base = 32'h0, sl_err_size = 32'h0;

    // -----------------------------------------------------------------------
    dma_top u_dut (
        .hclk (hclk), .pclk (pclk),
        .hreset_n (hreset_n), .preset_n (preset_n),
        .psel (psel), .penable (penable), .pwrite (pwrite),
        .paddr (paddr), .pwdata (pwdata),
        .prdata (prdata), .pready (pready), .pslverr (pslverr),
        .haddr (haddr), .htrans (htrans), .hwrite (hwrite),
        .hsize (hsize), .hburst (hburst), .hwdata (hwdata),
        .hrdata (hrdata), .hready (hready), .hresp (hresp),
        .dma_req (dma_req), .dma_ack (dma_ack),
        .dma_irq (dma_irq), .dma_err (dma_err)
    );

    dma_ahb_slave_model #(
        .MEM_BASE (MEM_BASE), .MEM_BYTES (MEM_BYTES),
        .FIFO_BASE (FIFO_BASE), .NFIFO (8)
    ) u_slave (
        .clk_i (hclk), .rst_n_i (hreset_n),
        .waits_i (sl_waits), .rand_waits_i (sl_rand),
        .err_en_i (sl_err_en), .err_base_i (sl_err_base),
        .err_size_i (sl_err_size),
        .haddr_i (haddr), .htrans_i (htrans), .hwrite_i (hwrite),
        .hsize_i (hsize), .hwdata_i (hwdata),
        .hrdata_o (hrdata), .hready_o (hready), .hresp_o (hresp)
    );

    // -----------------------------------------------------------------------
    // Scoreboarding
    // -----------------------------------------------------------------------
    // -----------------------------------------------------------------------
    // Self-contained PRNG.
    //
    // NOT $random. Icarus Verilog 14 accepts $random(seed) and then IGNORES the
    // seed - every +SEED value produces a byte-identical stimulus stream, so a
    // "10-seed sweep" is really one run repeated ten times while reporting ten
    // passes. Verified with a 6-line standalone case before replacing it.
    //
    // A 32-bit xorshift is deterministic, seed-sensitive, and identical on
    // every simulator, so a failing seed found here replays exactly under
    // Xcelium or VCS. That portability is the point: a random regression whose
    // seeds do not reproduce across tools is not a regression.
    // -----------------------------------------------------------------------
    reg [31:0] rng_state = 32'h1;

    function [31:0] rnd32;
        input dummy;
        begin
            rng_state = rng_state ^ (rng_state << 13);
            rng_state = rng_state ^ (rng_state >> 17);
            rng_state = rng_state ^ (rng_state << 5);
            rnd32 = rng_state;
        end
    endfunction

    // Uniform in [0, n)
    function integer rnd_range;
        input integer n;
        begin rnd_range = rnd32(1'b0) % n; end
    endfunction

    integer checks = 0, failures = 0;
    integer ack_count [0:5];
    integer ack_width_bad = 0;
    reg [5:0] ack_prev = 6'h0;

    integer k;

    task chk(input cond, input [1023:0] name);
        begin
            checks = checks + 1;
            if (!cond) begin
                failures = failures + 1;
                $display("[FAIL] %0s   (t=%0t)", name, $time);
            end
        end
    endtask

    task chk_eq(input [63:0] got, input [63:0] exp, input [1023:0] name);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                failures = failures + 1;
                $display("[FAIL] %0s : got 0x%0h expected 0x%0h  (t=%0t)",
                         name, got, exp, $time);
            end
        end
    endtask

    // dma_ack must be exactly one hclk wide (Sec. 5.4). Two consecutive high
    // cycles on the same channel is a protocol violation - the peripheral
    // would pop its FIFO twice for one beat.
    always @(posedge hclk) begin
        if (hreset_n) begin
            for (k = 0; k < 6; k = k + 1) begin
                if (dma_ack[k]) ack_count[k] = ack_count[k] + 1;
                if (dma_ack[k] && ack_prev[k]) ack_width_bad = ack_width_bad + 1;
            end
            ack_prev <= dma_ack;
        end
    end

    // Arbitration probe, windowed like tb_boot's +DBG* probes. Prints each
    // channel's FSM state and the arbiter decision every cycle it changes, so
    // an arbitration surprise can be attributed to "who was actually asking"
    // rather than guessed at.
    // A hierarchical reference cannot take a variable generate index, so the
    // six FSM states are flattened into one bus by a generate loop and the
    // monitor indexes that instead.
    wire [17:0] ch_state_flat;
    genvar gp;
    generate
        for (gp = 0; gp < 6; gp = gp + 1) begin : g_probe
            assign ch_state_flat[3*gp +: 3] = u_dut.g_ch[gp].u_ch.state;
        end
    endgenerate

    reg [2:0] st_prev [0:5];
    integer   kd;
    initial for (kd = 0; kd < 6; kd = kd + 1) st_prev[kd] = 3'd0;

    always @(posedge hclk) begin
        if (hreset_n && $test$plusargs("DBGARB")) begin
            for (kd = 0; kd < 6; kd = kd + 1) begin
                if (ch_state_flat[3*kd +: 3] !== st_prev[kd]) begin
                    $display("  [ARB t=%0t] ch%0d state %0d -> %0d   req=%b grant=%b sel=%0d ahb_idle=%b",
                             $time, kd, st_prev[kd], ch_state_flat[3*kd +: 3],
                             u_dut.ch_req, u_dut.arb_grant, u_dut.arb_sel,
                             u_dut.ahb_idle);
                    st_prev[kd] = ch_state_flat[3*kd +: 3];
                end
            end
        end
    end

    // AHB protocol monitor: the DMA must only ever issue SINGLE transfers
    // (Sec. 5.3 / Sec. 16.4) and must never use BUSY/SEQ.
    integer bad_burst = 0, bad_trans = 0;
    always @(posedge hclk) begin
        if (hreset_n && htrans[1]) begin
            if (hburst !== 3'b000)  bad_burst = bad_burst + 1;
            if (htrans === 2'b11)   bad_trans = bad_trans + 1;
            if (hsize  === 3'b011)  bad_trans = bad_trans + 1; // 64-bit illegal
        end
        if (hreset_n && htrans === 2'b01) bad_trans = bad_trans + 1; // BUSY
    end

    // -----------------------------------------------------------------------
    // APB bus functional model. Driven on negedge pclk; the DUT samples at
    // posedge, so stimulus is stable across the whole sampling window.
    // -----------------------------------------------------------------------
    function [7:0] AD(input integer ch, input integer r);
        AD = (ch << 5) | (r << 2);
    endfunction

    task apb_write(input integer ch, input integer r, input [31:0] d);
        begin
            @(negedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
            paddr = AD(ch, r); pwdata = d;
            @(negedge pclk);
            penable = 1'b1;
            @(negedge pclk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0; pwdata = 32'h0;
        end
    endtask

    task apb_write_raw(input [7:0] a, input [31:0] d);
        begin
            @(negedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1; paddr = a; pwdata = d;
            @(negedge pclk);
            penable = 1'b1;
            @(negedge pclk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0; pwdata = 32'h0;
        end
    endtask

    task apb_read(input integer ch, input integer r, output [31:0] d);
        begin
            @(negedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b0; paddr = AD(ch, r);
            @(negedge pclk);
            penable = 1'b1;
            @(negedge pclk);
            d = prdata;                       // still in the access phase
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    task apb_read_raw(input [7:0] a, output [31:0] d);
        begin
            @(negedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b0; paddr = a;
            @(negedge pclk);
            penable = 1'b1;
            @(negedge pclk);
            d = prdata;
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    reg [31:0] rd;

    function [31:0] mk_cr(input [1:0] dir, input [1:0] sz, input sinc,
                          input dinc, input circ, input ie, input eie,
                          input [2:0] pri, input en);
        mk_cr = ({29'b0, pri} << B_PRI) | ({31'b0, eie} << B_EIE) |
                ({31'b0, ie} << B_IE)   | ({31'b0, circ} << B_CIRC) |
                ({31'b0, dinc} << B_DINC) | ({31'b0, sinc} << B_SINC) |
                ({30'b0, sz} << B_SZ)   | ({30'b0, dir} << B_DIR) |
                ({31'b0, en} << B_EN);
    endfunction

    task cfg_channel(input integer ch, input [31:0] sar, input [31:0] dar,
                     input [15:0] tcr, input [31:0] cr);
        begin
            apb_write(ch, R_SAR, sar);
            apb_write(ch, R_DAR, dar);
            apb_write(ch, R_TCR, {16'h0, tcr});
            apb_write(ch, R_CR,  cr);      // EN written last (Sec. 6.6)
        end
    endtask

    // Poll SR.COMPLETE / SR.ERROR. Returns the SR value, or all-ones on timeout.
    task wait_flag(input integer ch, input integer bit_idx,
                   input integer max_polls, output [31:0] sr);
        integer p;
        begin
            sr = 32'h0;
            p = 0;
            while (p < max_polls) begin
                apb_read(ch, R_SR, sr);
                if (sr[bit_idx]) p = max_polls + 10;
                else p = p + 1;
            end
            if (p == max_polls) begin
                $display("[FAIL] timeout waiting for SR bit %0d on ch%0d (t=%0t)",
                         bit_idx, ch, $time);
                failures = failures + 1;
                checks   = checks + 1;
                sr = 32'hFFFF_FFFF;
            end
        end
    endtask

    task set_req(input [5:0] v);
        begin
            @(negedge hclk);
            req_auto  = 6'h0;
            req_force = v;
        end
    endtask

    // Hand dma_req[n] over to the modelled FIFO occupancy for the masked
    // channels (see the dma_req drive note above).
    task set_req_auto(input [5:0] mask);
        begin
            @(negedge hclk);
            req_force = 6'h0;
            req_auto  = mask;
        end
    endtask

    task hclk_wait(input integer n);
        integer q;
        begin for (q = 0; q < n; q = q + 1) @(posedge hclk); end
    endtask

    task clear_all_channels;
        integer c;
        begin
            for (c = 0; c < 6; c = c + 1) begin
                apb_write(c, R_CR, 32'h0);
                apb_write(c, R_SR, 32'h3);       // W1C both flags
            end
        end
    endtask

    // =======================================================================
    // T1 - Register access (Sec. 14 "Unit - Register access")
    // =======================================================================
    task t1_register_access;
        integer c;
        reg [31:0] pat;
        // chk_eq's formals are 64-bit, and Verilog evaluates an argument
        // expression at the formal's width - so passing "~pat" directly
        // inverts a 64-bit zero-extension of pat and expects
        // 0xFFFFFFFF_5A5AFFFF. The inversion has to be materialised in a
        // 32-bit variable first.
        reg [31:0] inv_pat;
        begin
            $display("--- T1: register access, all 30 registers ---");
            for (c = 0; c < 6; c = c + 1) begin
                pat     = 32'hA5A5_0000 | (c << 8);
                inv_pat = ~pat;
                apb_write(c, R_SAR, pat);
                apb_write(c, R_DAR, inv_pat);
                apb_write(c, R_TCR, 32'hFFFF_1234 | (c << 4));
                apb_write(c, R_CR,  32'hFFFF_FFFE);  // all bits set except EN

                apb_read(c, R_SAR, rd);
                chk_eq(rd, pat, "SAR readback");
                apb_read(c, R_DAR, rd);
                chk_eq(rd, inv_pat, "DAR readback");

                // Sec. 6.5: TCR is 16-bit, [31:16] read as 0, writes ignored.
                apb_read(c, R_TCR, rd);
                chk_eq(rd, 32'h0000_1234 | (c << 4), "TCR readback, upper 16 zero");

                // Sec. 6.6: CR[31:13] reserved, read as 0.
                apb_read(c, R_CR, rd);
                chk_eq(rd, 32'h0000_1FFE, "CR readback, reserved bits zero");

                // Sec. 6.7: SR.REMAINING reads 0 while the channel is idle.
                apb_read(c, R_SR, rd);
                chk_eq(rd, 32'h0, "SR reads 0 when idle");
            end

            // Reserved channel (paddr[7:5] = 6,7) and reserved register
            // (paddr[4:2] = 5..7) must decode to nothing, not alias onto a
            // live channel.
            apb_write_raw(8'hC0, 32'hDEAD_BEEF);      // channel 6, SAR
            apb_read_raw (8'hC0, rd);
            chk_eq(rd, 32'h0, "reserved channel 6 reads 0");
            apb_read(0, R_SAR, rd);
            chk_eq(rd, 32'hA5A5_0000, "ch0 SAR unaffected by reserved-channel write");

            apb_write_raw(8'h14, 32'hDEAD_BEEF);      // channel 0, reg_sel 5
            apb_read_raw (8'h14, rd);
            chk_eq(rd, 32'h0, "reserved register select reads 0");

            chk(pready === 1'b1,  "PREADY tied high (Sec. 5.2)");
            chk(pslverr === 1'b0, "PSLVERR tied low (Sec. 5.2)");

            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T2 - Single channel P->M, 14 bytes (Sec. 14 "Unit - Single channel P->M")
    // This is the Sec. 13.2 IMU case, and the byte-lane alignment test: the
    // destination walks all four byte lanes while the source lane is fixed.
    // =======================================================================
    task t2_p2m_byte;
        integer i;
        reg [31:0] sr;
        begin
            $display("--- T2: P->M, 14 beats, byte size, lane alignment ---");
            u_slave.init_model();
            for (i = 0; i < 14; i = i + 1)
                u_slave.push_rd(0, 32'h0000_0000 | (8'h20 + i[7:0]));

            ack_count[0] = 0;
            cfg_channel(0, FIFO_BASE, MEM_BASE + 32'h100, 16'd14,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd7, 1'b1));
            set_req(6'b000001);
            wait_flag(0, 0, 400, sr);

            chk(sr[0] === 1'b1, "SR.COMPLETE set");
            chk(sr[1] === 1'b0, "SR.ERROR clear on a good transfer");
            chk_eq(sr[31:16], 16'd0, "SR.REMAINING reads 0 after completion");
            chk(dma_irq[0] === 1'b1, "dma_irq[0] asserted (IE=1)");
            chk(dma_err[0] === 1'b0, "dma_err[0] deasserted");
            chk_eq(ack_count[0], 14, "dma_ack pulsed once per beat");

            for (i = 0; i < 14; i = i + 1)
                chk_eq(u_slave.mem_byte(MEM_BASE + 32'h100 + i),
                       8'h20 + i[7:0], "destination byte in order");

            // The source FIFO must have been popped exactly 14 times - proof
            // the DMA issued 14 distinct reads rather than replaying one.
            chk_eq(u_slave.rd_avail(0), 0, "source FIFO drained exactly");

            // Sec. 6.6: hardware clears EN on COMPLETE when CIRC=0.
            apb_read(0, R_CR, rd);
            chk_eq(rd[B_EN], 1'b0, "CR.EN cleared by hardware (single-shot)");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T3 - W1C semantics (Sec. 14 "Unit - W1C semantics", Sec. 10.2)
    // =======================================================================
    task t3_w1c;
        reg [31:0] sr;
        begin
            $display("--- T3: W1C semantics and interrupt deassertion ---");
            u_slave.init_model();
            u_slave.push_rd(1, 32'h0000_0077);

            cfg_channel(1, FIFO_BASE + 32'h4, MEM_BASE + 32'h200, 16'd1,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd4, 1'b1));
            set_req(6'b000010);
            wait_flag(1, 0, 400, sr);
            chk(dma_irq[1] === 1'b1, "dma_irq[1] asserted before clear");

            // Writing 0 must have no effect.
            apb_write(1, R_SR, 32'h0000_0000);
            apb_read (1, R_SR, rd);
            chk(rd[0] === 1'b1, "writing 0 to SR.COMPLETE does not clear it");
            chk(dma_irq[1] === 1'b1, "dma_irq[1] still asserted");

            // Writing 1 clears, and the level-sensitive interrupt follows.
            apb_write(1, R_SR, 32'h0000_0001);
            hclk_wait(8);
            apb_read(1, R_SR, rd);
            chk(rd[0] === 1'b0, "writing 1 to SR.COMPLETE clears it");
            chk(dma_irq[1] === 1'b0, "dma_irq[1] deasserts after W1C");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T4 - Circular mode, 3 laps (Sec. 14 "Unit - Circular mode")
    // =======================================================================
    // A circular channel is FREE-RUNNING: on COMPLETE it reloads and restarts
    // with no CPU involvement, which is the whole point of Sec. 6.6. So the
    // testbench cannot "wait for lap N, then inspect the destination" - by the
    // time an APB read of SR has completed, lap N+1 is already overwriting the
    // same buffer (DAR is reloaded from the register bank every lap, so all
    // laps target the same bytes). Sampling that way reports lap N+1's data
    // against lap N's expectation.
    //
    // Instead the source FIFO is loaded with EXACTLY 3 laps' worth of data and
    // dma_req is driven from its occupancy. The channel then stops itself at a
    // deterministic point - parked in WAITING part-way into lap 4 - and both
    // the beat count and the final buffer contents can be checked at rest.
    task t4_circular;
        integer i;
        begin
            $display("--- T4: circular mode, 3 consecutive laps ---");
            u_slave.init_model();
            for (i = 0; i < 12; i = i + 1)
                u_slave.push_rd(2, 32'h0000_0000 | (8'h40 + i[7:0]));

            ack_count[2] = 0;
            cfg_channel(2, FIFO_BASE + 32'h8, MEM_BASE + 32'h300, 16'd4,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b1 /*CIRC*/,
                              1'b1, 1'b1, 3'd5, 1'b1));
            set_req_auto(6'b000100);

            // Let it run until the source is exhausted, then settle.
            wait (u_slave.rd_tail[2] == u_slave.rd_head[2]);
            hclk_wait(200);

            // TCR=4 and 12 beats moved means the descriptor was reloaded
            // twice with no CPU write in between - that IS circular mode.
            chk_eq(ack_count[2], 12,
                   "3 laps x 4 beats auto-reloaded, no CPU intervention");

            apb_read(2, R_SR, rd);
            chk(rd[0] === 1'b1, "SR.COMPLETE set after the final lap");

            // The buffer holds the LAST lap's data (bytes 8..11 of the source).
            for (i = 0; i < 4; i = i + 1)
                chk_eq(u_slave.mem_byte(MEM_BASE + 32'h300 + i),
                       8'h40 + 8 + i, "final lap overwrote the same buffer");

            // Sec. 6.6: EN stays set in circular mode - the CPU configured it
            // once at boot and hardware must not disarm it.
            apb_read(2, R_CR, rd);
            chk(rd[B_EN] === 1'b1, "CR.EN still set in circular mode");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T5 - dma_req deassert mid-transfer + SR.REMAINING readback
    //      (Sec. 14 "Unit - FIFO deassert", Sec. 6.7)
    // =======================================================================
    task t5_fifo_deassert;
        integer i;
        reg [31:0] sr;
        begin
            $display("--- T5: peripheral FIFO runs dry mid-transfer ---");
            u_slave.init_model();
            for (i = 0; i < 3; i = i + 1)          // only 3 of 8 beats ready
                u_slave.push_rd(3, 32'h0000_0000 | (8'h60 + i[7:0]));

            ack_count[3] = 0;
            cfg_channel(3, FIFO_BASE + 32'hC, MEM_BASE + 32'h400, 16'd8,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd2, 1'b1));

            // Only 3 of the 8 beats are available. Driving dma_req from FIFO
            // occupancy stops the channel exactly on the 3rd beat boundary;
            // a testbench-forced deassert reacts a beat or two late, because
            // the channel re-requests the cycle after each beat completes.
            set_req_auto(6'b001000);

            wait (ack_count[3] == 3);
            hclk_wait(60);

            chk_eq(ack_count[3], 3, "no further beats once the source runs dry");

            // With the channel parked in WAITING_FOR_REQUEST the counter is
            // static, so SR.REMAINING can be checked against an exact value
            // rather than a range.
            apb_read(3, R_SR, rd);
            chk_eq(rd[31:16], 16'd5, "SR.REMAINING = 5 after 3 of 8 beats");
            chk(rd[0] === 1'b0, "SR.COMPLETE not set mid-transfer");

            // Refill the peripheral FIFO; dma_req re-asserts on its own and the
            // remaining 5 beats must complete from where the channel parked.
            for (i = 3; i < 8; i = i + 1)
                u_slave.push_rd(3, 32'h0000_0000 | (8'h60 + i[7:0]));
            wait_flag(3, 0, 400, sr);
            chk_eq(ack_count[3], 8, "all 8 beats complete after resume");
            for (i = 0; i < 8; i = i + 1)
                chk_eq(u_slave.mem_byte(MEM_BASE + 32'h400 + i),
                       8'h60 + i[7:0], "data intact across the park");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T6 - Bus error handling (Sec. 14 "Unit - Error handling", Sec. 7.2 #1)
    //
    // Two sub-cases. The second is the one the spec never mentions and the
    // one that can corrupt memory: an ERROR on the READ arrives while the
    // WRITE address phase is already on the bus, so the write must be
    // retracted. The destination is checked to prove nothing was written.
    // =======================================================================
    task t6_bus_error;
        integer i;
        reg [31:0] sr;
        begin
            $display("--- T6a: ERROR on the destination write ---");
            u_slave.init_model();
            for (i = 0; i < 4; i = i + 1) u_slave.push_rd(4, 32'h0000_00AA);

            sl_err_base = MEM_BASE + 32'h500;
            sl_err_size = 32'h10;
            sl_err_en   = 1'b1;

            cfg_channel(4, FIFO_BASE + 32'h10, MEM_BASE + 32'h500, 16'd4,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd3, 1'b1));
            set_req(6'b010000);
            wait_flag(4, 1, 400, sr);

            chk(sr[1] === 1'b1, "SR.ERROR set on hresp=ERROR");
            chk(sr[0] === 1'b0, "SR.COMPLETE NOT set on an aborted transfer");
            chk(dma_err[4] === 1'b1, "dma_err[4] asserted (EIE=1)");
            chk(dma_irq[4] === 1'b0, "dma_irq[4] not asserted");
            apb_read(4, R_CR, rd);
            chk(rd[B_EN] === 1'b0, "CR.EN cleared after an error abort");

            set_req(6'b000000);
            sl_err_en = 1'b0;
            clear_all_channels();

            $display("--- T6b: ERROR on the source read, write must retract ---");
            u_slave.init_model();
            for (i = 0; i < 4; i = i + 1) u_slave.push_rd(5, 32'h0000_00BB);
            // Seed the destination with a sentinel: if the pipelined write
            // address phase is not retracted, this word changes.
            u_slave.mem_set_word(MEM_BASE + 32'h600, 32'hCAFE_F00D);

            // Error window covers the SOURCE FIFO, so the read faults.
            sl_err_base = FIFO_BASE + 32'h14;
            sl_err_size = 32'h4;
            sl_err_en   = 1'b1;

            cfg_channel(5, FIFO_BASE + 32'h14, MEM_BASE + 32'h600, 16'd4,
                        mk_cr(DIR_P2M, SZ_WORD, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd6, 1'b1));
            set_req(6'b100000);
            wait_flag(5, 1, 400, sr);

            chk(sr[1] === 1'b1, "SR.ERROR set on a source-read error");
            chk(sr[0] === 1'b0, "SR.COMPLETE not set");
            chk_eq(u_slave.mem_word(MEM_BASE + 32'h600), 32'hCAFE_F00D,
                   "destination untouched: pipelined write address retracted");

            set_req(6'b000000);
            sl_err_en = 1'b0;
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T7 - Fixed-priority arbitration and preemption
    //      (Sec. 14 "Multi-ch - Arbitration" / "Preemption")
    // =======================================================================
    task t7_arbitration;
        integer i;
        reg [31:0] sr;
        integer ch0_at_ch3_done;
        begin
            $display("--- T7: CH0 (PRI 7) starves CH3 (PRI 2) until complete ---");
            u_slave.init_model();
            for (i = 0; i < 8; i = i + 1) begin
                u_slave.push_rd(0, 32'h0000_0000 | (8'h10 + i[7:0]));
                u_slave.push_rd(3, 32'h0000_0000 | (8'h90 + i[7:0]));
            end
            ack_count[0] = 0; ack_count[3] = 0;

            // Arm the LOW priority channel first, so any bias toward
            // first-armed rather than highest-priority would show up here.
            cfg_channel(3, FIFO_BASE + 32'hC, MEM_BASE + 32'h700, 16'd8,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b0, 3'd2, 1'b1));
            cfg_channel(0, FIFO_BASE, MEM_BASE + 32'h740, 16'd8,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b0, 3'd7, 1'b1));

            // ESTABLISH THE PRECONDITION. Sec. 14's arbitration case assumes
            // both channels are simultaneously contending. Arming a channel is
            // not instantaneous: the arm event crosses pclk->hclk through three
            // flops and then spends a cycle in CONFIGURED. Raising dma_req
            // immediately after the last APB write therefore opens a ~5 hclk
            // window in which CH3 is in WAITING and CH0 has not arrived yet -
            // and CH3 legitimately wins a beat, because it is the only
            // requester. That is correct fixed-priority behaviour, not
            // starvation-avoidance, but it is not the case this test is for.
            hclk_wait(30);

            set_req(6'b001001);

            // Sample CH3's progress on the HARDWARE event "CH0 moved its last
            // beat", not on the testbench noticing SR.COMPLETE. wait_flag polls
            // over APB, so it observes completion up to ~9 hclk late - and CH3
            // starts running the instant CH0 drops its request. Measuring there
            // reports beats CH3 took legitimately AFTER CH0 was done, which is
            // not what this test is asserting.
            wait (ack_count[0] == 8);
            ch0_at_ch3_done = ack_count[3];

            wait_flag(0, 0, 600, sr);

            // Sec. 14: "CH0 completes all beats before CH3 gets any bus access."
            chk_eq(ack_count[0], 8, "CH0 completed all 8 beats");
            chk(ch0_at_ch3_done == 0,
                "CH3 got zero beats while CH0 was active");

            wait_flag(3, 0, 600, sr);
            chk_eq(ack_count[3], 8, "CH3 completes once CH0 is done (no deadlock)");
            for (i = 0; i < 8; i = i + 1) begin
                chk_eq(u_slave.mem_byte(MEM_BASE + 32'h740 + i),
                       8'h10 + i[7:0], "CH0 data correct under contention");
                chk_eq(u_slave.mem_byte(MEM_BASE + 32'h700 + i),
                       8'h90 + i[7:0], "CH3 data correct under contention");
            end

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T7b - Mid-stream preemption (Sec. 14 "Multi-ch - Preemption", Sec. 8.3)
    //
    // Distinct from T7: there, both channels contend from the start. Here CH3
    // is already streaming when CH0 arrives, which is what actually exercises
    // per-beat re-arbitration - CH0 must take the bus at the next beat
    // boundary rather than waiting for CH3 to finish.
    // =======================================================================
    task t7b_preemption;
        integer i;
        reg [31:0] sr;
        integer c3_at_preempt;
        begin
            $display("--- T7b: CH0 preempts a streaming CH3 at a beat boundary ---");
            u_slave.init_model();
            for (i = 0; i < 20; i = i + 1)
                u_slave.push_rd(3, 32'h0000_0000 | (8'hA0 + i[7:0]));
            for (i = 0; i < 6; i = i + 1)
                u_slave.push_rd(0, 32'h0000_0000 | (8'h50 + i[7:0]));
            ack_count[0] = 0; ack_count[3] = 0;

            // CH3 (low priority) streams alone.
            cfg_channel(3, FIFO_BASE + 32'hC, MEM_BASE + 32'h880, 16'd20,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b0, 3'd2, 1'b1));
            set_req(6'b001000);
            wait (ack_count[3] >= 4);
            chk(ack_count[3] >= 4, "CH3 streaming before preemption");

            // CH0 (high priority) arrives mid-stream.
            cfg_channel(0, FIFO_BASE, MEM_BASE + 32'h8C0, 16'd6,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b0, 3'd7, 1'b1));
            set_req(6'b001001);

            // Both snapshots must be taken on HARDWARE events. Bracketing the
            // window with "CH0's first beat" and "CH0's last beat" measures
            // exactly the interval CH0 owned the bus. Taking the closing
            // sample after wait_flag instead would include everything CH3 did
            // once CH0 was finished - which is a resumption, not a priority
            // violation, and shows up as a consistent off-by-one.
            wait (ack_count[0] == 1);
            c3_at_preempt = ack_count[3];

            wait (ack_count[0] == 6);
            chk_eq(ack_count[3], c3_at_preempt,
                   "CH3 advanced zero beats while CH0 held the bus");

            wait_flag(0, 0, 800, sr);
            chk_eq(ack_count[0], 6, "CH0 completed all 6 beats");

            // CH3 must resume and finish - preemption is not cancellation.
            wait_flag(3, 0, 1200, sr);
            chk_eq(ack_count[3], 20, "CH3 resumed and completed after preemption");
            for (i = 0; i < 20; i = i + 1)
                chk_eq(u_slave.mem_byte(MEM_BASE + 32'h880 + i),
                       8'hA0 + i[7:0], "CH3 data intact across preemption");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T8 - Equal-priority tiebreak: lowest channel index wins (Sec. 8.2)
    // =======================================================================
    task t8_tiebreak;
        integer i;
        reg [31:0] sr;
        integer ch4_beats_at_ch1_done;
        begin
            $display("--- T8: equal priority, lowest index wins ---");
            u_slave.init_model();
            for (i = 0; i < 6; i = i + 1) begin
                u_slave.push_rd(1, 32'h0000_0000 | (8'hC0 + i[7:0]));
                u_slave.push_rd(4, 32'h0000_0000 | (8'hE0 + i[7:0]));
            end
            ack_count[1] = 0; ack_count[4] = 0;

            // Same PRI on both; CH4 armed first.
            cfg_channel(4, FIFO_BASE + 32'h10, MEM_BASE + 32'h800, 16'd6,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b0, 3'd5, 1'b1));
            cfg_channel(1, FIFO_BASE + 32'h4, MEM_BASE + 32'h840, 16'd6,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b0, 3'd5, 1'b1));

            hclk_wait(30);           // both in WAITING before contention - see T7
            set_req(6'b010010);

            // Sample on the hardware event, not on the APB poll noticing it -
            // identical reasoning to T7. CH4 starts the cycle CH1 releases the
            // bus, so a sample taken after wait_flag returns counts beats CH4
            // was fully entitled to. Confirmed with +DBGARB: CH4 sat in
            // WAITING for all six of CH1's beats and moved on the same cycle
            // CH1 reached COMPLETE.
            wait (ack_count[1] == 6);
            ch4_beats_at_ch1_done = ack_count[4];

            wait_flag(1, 0, 600, sr);
            chk_eq(ack_count[1], 6, "CH1 completed");
            chk(ch4_beats_at_ch1_done == 0,
                "CH4 (higher index, equal PRI) got no beats first");

            wait_flag(4, 0, 600, sr);
            chk_eq(ack_count[4], 6, "CH4 completes afterwards");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T9 - Memory-to-memory (Sec. 9): dma_req is ignored, word size,
    //      both addresses increment.
    // =======================================================================
    task t9_m2m;
        integer i;
        reg [31:0] sr;
        begin
            $display("--- T9: memory-to-memory, dma_req held LOW throughout ---");
            u_slave.init_model();
            for (i = 0; i < 8; i = i + 1)
                u_slave.mem_set_word(MEM_BASE + 32'h900 + i*4,
                                     32'h1234_0000 + i);

            ack_count[0] = 0;
            set_req(6'b000000);                  // no peripheral handshake
            cfg_channel(0, MEM_BASE + 32'h900, MEM_BASE + 32'hA00, 16'd8,
                        mk_cr(DIR_M2M, SZ_WORD, 1'b1, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd7, 1'b1));
            wait_flag(0, 0, 600, sr);

            chk_eq(ack_count[0], 8, "M2M ran 8 beats with dma_req low");
            for (i = 0; i < 8; i = i + 1)
                chk_eq(u_slave.mem_word(MEM_BASE + 32'hA00 + i*4),
                       32'h1234_0000 + i, "M2M word copied");

            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T10 - Halfword size + M2P direction (fixed destination FIFO)
    // =======================================================================
    task t10_halfword_m2p;
        integer i;
        reg [31:0] sr;
        begin
            $display("--- T10: M2P, halfword beats, fixed destination FIFO ---");
            u_slave.init_model();
            // Four halfwords: 0x1111,0x2222 in one word, 0x3333,0x4444 in the next
            u_slave.mem_set_word(MEM_BASE + 32'hB00, 32'h2222_1111);
            u_slave.mem_set_word(MEM_BASE + 32'hB04, 32'h4444_3333);

            ack_count[2] = 0;
            cfg_channel(2, MEM_BASE + 32'hB00, FIFO_BASE + 32'h8, 16'd4,
                        mk_cr(DIR_M2P, SZ_HALF, 1'b1 /*SINC*/, 1'b0 /*DINC*/,
                              1'b0, 1'b1, 1'b1, 3'd5, 1'b1));
            set_req(6'b000100);
            wait_flag(2, 0, 600, sr);

            chk_eq(ack_count[2], 4, "4 halfword beats");
            chk_eq(u_slave.wr_count(2), 4, "destination FIFO received 4 pushes");
            // Source halfwords come from lanes [15:0] then [31:16]; the DMA
            // must right-justify on read and re-place on write.
            chk_eq(u_slave.wr_get(2, 0), 32'h1111, "halfword 0 lane-aligned");
            chk_eq(u_slave.wr_get(2, 1), 32'h2222, "halfword 1 lane-aligned");
            chk_eq(u_slave.wr_get(2, 2), 32'h3333, "halfword 2 lane-aligned");
            chk_eq(u_slave.wr_get(2, 3), 32'h4444, "halfword 3 lane-aligned");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T11 - Zero-length descriptor (Sec. 6.5)
    // TCR=0 must complete immediately WITHOUT moving a beat. A counter that
    // decremented from 0 would wrap to 0xFFFF and run 65,536 beats.
    // =======================================================================
    task t11_zero_length;
        reg [31:0] sr;
        begin
            $display("--- T11: TCR = 0 completes immediately, moves nothing ---");
            u_slave.init_model();
            ack_count[1] = 0;

            cfg_channel(1, FIFO_BASE + 32'h4, MEM_BASE + 32'hC00, 16'd0,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd4, 1'b1));
            set_req(6'b000010);
            wait_flag(1, 0, 200, sr);

            chk(sr[0] === 1'b1, "SR.COMPLETE set immediately for TCR=0");
            chk_eq(ack_count[1], 0, "no beats issued for TCR=0");
            chk_eq(u_slave.rd_beats, 0, "no AHB read issued for TCR=0");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T12 - Wait states (Sec. 5.3: "DMA holds address/data stable until
    //       hready=1"). Same transfer as T2, against a slow slave.
    // =======================================================================
    task t12_wait_states;
        integer i;
        reg [31:0] sr;
        begin
            $display("--- T12: 14-beat P->M with randomised 0..6 wait states ---");
            u_slave.init_model();
            for (i = 0; i < 14; i = i + 1)
                u_slave.push_rd(0, 32'h0000_0000 | (8'h30 + i[7:0]));

            sl_waits = 8'd6;                     // local override for this test
            sl_rand  = 1'b1;
            ack_count[0] = 0;

            cfg_channel(0, FIFO_BASE, MEM_BASE + 32'hD00, 16'd14,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd7, 1'b1));
            set_req(6'b000001);
            wait_flag(0, 0, 2000, sr);

            chk_eq(ack_count[0], 14, "14 beats under wait states");
            for (i = 0; i < 14; i = i + 1)
                chk_eq(u_slave.mem_byte(MEM_BASE + 32'hD00 + i),
                       8'h30 + i[7:0], "data correct under wait states");

            sl_waits = g_waits;                  // restore the global timing
            sl_rand  = g_rand;
            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T13 - All six channels concurrently (Sec. 14 "System - Full sensor
    //       suite"): no starvation, no cross-channel corruption.
    // =======================================================================
    task t13_all_channels;
        integer c, i;
        reg [31:0] sr;
        reg [2:0] pri_of [0:5];
        begin
            $display("--- T13: all 6 channels active simultaneously ---");
            u_slave.init_model();
            // Sec. 8.4 priority assignment
            pri_of[0] = 3'd7; pri_of[1] = 3'd4; pri_of[2] = 3'd5;
            pri_of[3] = 3'd2; pri_of[4] = 3'd3; pri_of[5] = 3'd6;

            for (c = 0; c < 6; c = c + 1) begin
                ack_count[c] = 0;
                for (i = 0; i < 6; i = i + 1)
                    u_slave.push_rd(c, 32'h0000_0000 | ((c*16 + i) & 8'hFF));
            end

            for (c = 0; c < 6; c = c + 1)
                cfg_channel(c, FIFO_BASE + c*4, MEM_BASE + 32'hE00 + c*16, 16'd6,
                            mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                                  1'b1, 1'b1, pri_of[c], 1'b1));

            set_req(6'b111111);

            for (c = 0; c < 6; c = c + 1) begin
                wait_flag(c, 0, 3000, sr);
                chk(sr[0] === 1'b1, "channel completed in the full-suite run");
            end

            for (c = 0; c < 6; c = c + 1) begin
                chk_eq(ack_count[c], 6, "every channel moved exactly 6 beats");
                for (i = 0; i < 6; i = i + 1)
                    chk_eq(u_slave.mem_byte(MEM_BASE + 32'hE00 + c*16 + i),
                           (c*16 + i) & 8'hFF, "no cross-channel corruption");
            end

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T14 - Software abort: clearing CR.EN on an armed channel must return it
    //       to IDLE rather than leaving it holding a request line forever.
    //       Sec. 6.6 calls this "undefined"; the RTL defines it.
    // =======================================================================
    task t14_software_abort;
        reg [31:0] sr;
        begin
            $display("--- T14: clearing CR.EN parks the channel cleanly ---");
            u_slave.init_model();
            ack_count[3] = 0;

            // Armed, but dma_req never asserts, so it sits in WAITING.
            set_req(6'b000000);
            cfg_channel(3, FIFO_BASE + 32'hC, MEM_BASE + 32'hF00, 16'd8,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd2, 1'b1));
            hclk_wait(20);

            apb_write(3, R_CR, 32'h0);        // abort
            hclk_wait(30);

            // Now raise dma_req: an aborted channel must NOT wake up.
            set_req(6'b001000);
            hclk_wait(60);
            chk_eq(ack_count[3], 0, "aborted channel does not transfer");
            apb_read(3, R_SR, rd);
            chk(rd[0] === 1'b0, "aborted channel did not set SR.COMPLETE");

            // And it must still be re-armable afterwards.
            u_slave.push_rd(3, 32'h0000_0055);
            cfg_channel(3, FIFO_BASE + 32'hC, MEM_BASE + 32'hF00, 16'd1,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd2, 1'b1));
            wait_flag(3, 0, 400, sr);
            chk_eq(ack_count[3], 1, "channel re-arms after an abort");
            chk_eq(u_slave.mem_byte(MEM_BASE + 32'hF00), 8'h55,
                   "re-armed transfer moves correct data");

            set_req(6'b000000);
            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T15 - Edge cases the spec leaves open, and the guards added for them.
    // These exist to prove the RTL cannot livelock or run away on a malformed
    // descriptor, which is the failure mode nobody writes a test for.
    // =======================================================================
    task t15_edge_cases;
        integer i;
        reg [31:0] sr;
        integer beats_after;
        begin
            $display("--- T15a: CIRC=1 plus a bus error must STOP, not loop ---");
            u_slave.init_model();
            for (i = 0; i < 40; i = i + 1) u_slave.push_rd(1, 32'h0000_0011);
            ack_count[1] = 0;

            sl_err_base = MEM_BASE + 32'h1000;
            sl_err_size = 32'h10;
            sl_err_en   = 1'b1;

            cfg_channel(1, FIFO_BASE + 32'h4, MEM_BASE + 32'h1000, 16'd4,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b1 /*CIRC*/,
                              1'b1, 1'b1, 3'd4, 1'b1));
            set_req(6'b000010);
            wait_flag(1, 1, 400, sr);
            chk(sr[1] === 1'b1, "SR.ERROR set on a circular channel");

            beats_after = ack_count[1];
            hclk_wait(400);
            // Without the !err_abort_r guard in COMPLETE, the channel would
            // reload and re-fault forever, re-asserting dma_err faster than
            // firmware could ever clear it.
            chk_eq(ack_count[1], beats_after,
                   "circular channel halted after the error, no re-arm loop");
            apb_read(1, R_CR, rd);
            chk(rd[B_EN] === 1'b0, "CR.EN cleared: circular channel disarmed");

            sl_err_en = 1'b0;
            set_req(6'b000000);
            clear_all_channels();

            $display("--- T15b: CIRC=1 with TCR=0 must not livelock ---");
            u_slave.init_model();
            ack_count[2] = 0;
            cfg_channel(2, FIFO_BASE + 32'h8, MEM_BASE + 32'h1100, 16'd0,
                        mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b1 /*CIRC*/,
                              1'b1, 1'b1, 3'd5, 1'b1));
            set_req(6'b000100);
            hclk_wait(400);
            // A zero-length circular descriptor would otherwise spin
            // CONFIGURED->COMPLETE->CONFIGURED forever, setting SR.COMPLETE
            // every other cycle and never releasing the channel.
            apb_read(2, R_SR, rd);
            chk(rd[0] === 1'b1, "zero-length circular sets SR.COMPLETE once");
            chk_eq(ack_count[2], 0, "zero-length circular moves no data");
            apb_read(2, R_CR, rd);
            chk(rd[B_EN] === 1'b0, "zero-length circular disarms (no livelock)");

            set_req(6'b000000);
            clear_all_channels();

            $display("--- T15c: reserved CR.SIZE=2'b11 degrades to WORD ---");
            u_slave.init_model();
            for (i = 0; i < 4; i = i + 1)
                u_slave.mem_set_word(MEM_BASE + 32'h1200 + i*4, 32'h7000_0000 + i);
            ack_count[0] = 0;
            set_req(6'b000000);
            // SIZE=11 is Reserved (Sec. 6.6). It must not reach HSIZE as
            // 3'b011 (64-bit), which is illegal on a 32-bit bus - the AHB
            // monitor in this TB would flag that as bad_trans.
            cfg_channel(0, MEM_BASE + 32'h1200, MEM_BASE + 32'h1300, 16'd4,
                        mk_cr(DIR_M2M, 2'b11, 1'b1, 1'b1, 1'b0,
                              1'b1, 1'b1, 3'd7, 1'b1));
            wait_flag(0, 0, 600, sr);
            chk_eq(ack_count[0], 4, "reserved SIZE still completes 4 beats");
            for (i = 0; i < 4; i = i + 1)
                chk_eq(u_slave.mem_word(MEM_BASE + 32'h1300 + i*4),
                       32'h7000_0000 + i,
                       "reserved SIZE moved words and stepped by 4");

            clear_all_channels();
        end
    endtask

    // =======================================================================
    // T16 - Randomised multi-channel soak.
    //
    // Directed tests only find the bugs someone thought of. This mixes sizes,
    // directions, counts, priorities and channel subsets against randomised
    // bus timing, then checks every destination byte. It is the closest thing
    // here to the constrained-random unit TBs in tb/core.
    // =======================================================================
    task t16_random_soak;
        integer iter, c, i, n_act;
        integer cnt   [0:5];
        integer sz    [0:5];
        integer m2m   [0:5];
        integer act   [0:5];
        reg [31:0] sr;
        reg [31:0] sbase, dbase;
        integer bytes_per;
        reg [7:0] expect_b;
        begin
            $display("--- T16: randomised multi-channel soak, 10 rounds ---");
            for (iter = 0; iter < 10; iter = iter + 1) begin
                u_slave.init_model();
                n_act = 0;

                for (c = 0; c < 6; c = c + 1) begin
                    ack_count[c] = 0;
                    act[c] = (rnd_range(100) < 60);      // ~60% active
                    sz[c]  = rnd_range(3);               // byte / half / word
                    cnt[c] = rnd_range(8) + 1;           // 1..8 beats
                    m2m[c] = (rnd_range(100) < 30);      // ~30% M2M
                    if (act[c]) n_act = n_act + 1;
                end
                if (n_act == 0) act[0] = 1;

                for (c = 0; c < 6; c = c + 1) begin
                    if (act[c]) begin
                        bytes_per = 1 << sz[c];
                        dbase = MEM_BASE + 32'h1800 + c*32'h80;
                        if (m2m[c]) begin
                            sbase = MEM_BASE + 32'h1400 + c*32'h80;
                            for (i = 0; i < cnt[c]*bytes_per; i = i + 1)
                                u_slave.mem_set_word(sbase + (i & ~32'h3),
                                    32'h0);   // clear first, filled below
                            for (i = 0; i < cnt[c]*bytes_per; i = i + 4)
                                u_slave.mem_set_word(sbase + i,
                                    {8'(c*40+i+3), 8'(c*40+i+2),
                                     8'(c*40+i+1), 8'(c*40+i)});
                        end else begin
                            sbase = FIFO_BASE + c*4;
                            for (i = 0; i < cnt[c]; i = i + 1)
                                u_slave.push_rd(c,
                                    {8'(c*40 + i*bytes_per + 3),
                                     8'(c*40 + i*bytes_per + 2),
                                     8'(c*40 + i*bytes_per + 1),
                                     8'(c*40 + i*bytes_per + 0)});
                        end

                        cfg_channel(c, sbase, dbase, cnt[c][15:0],
                            mk_cr(m2m[c] ? DIR_M2M : DIR_P2M, sz[c][1:0],
                                  m2m[c] ? 1'b1 : 1'b0, 1'b1, 1'b0,
                                  1'b1, 1'b1, rnd_range(8), 1'b1));
                    end
                end

                hclk_wait(30);
                set_req(6'b111111);

                for (c = 0; c < 6; c = c + 1)
                    if (act[c]) wait_flag(c, 0, 4000, sr);

                for (c = 0; c < 6; c = c + 1) begin
                    if (act[c]) begin
                        bytes_per = 1 << sz[c];
                        dbase = MEM_BASE + 32'h1800 + c*32'h80;
                        chk_eq(ack_count[c], cnt[c], "soak: beat count");
                        for (i = 0; i < cnt[c]*bytes_per; i = i + 1) begin
                            expect_b = 8'(c*40 + i);
                            chk_eq(u_slave.mem_byte(dbase + i), expect_b,
                                   "soak: destination byte");
                        end
                    end
                end

                set_req(6'b000000);
                clear_all_channels();
            end
        end
    endtask

    // =======================================================================
    // T17 - The hardware CR.EN clear must survive a concurrent APB write to a
    //       DIFFERENT register of the same channel.
    //
    // The EN clear (Sec. 6.6, single-shot completion) arrives in pclk as a
    // one-shot pulse recovered from a toggle. A one-shot that is dropped is
    // gone for good - CR.EN would then read 1 forever on a channel that has
    // finished and gone idle.
    //
    // The collision is a real software pattern, not a contrived one: firmware
    // servicing a completion interrupt writes SR (W1C) and often re-programs
    // SAR/DAR for the next descriptor, right in the window where the clear
    // pulse lands. The trial loop sweeps the write burst across that window in
    // 1-hclk steps so the collision is hit rather than hoped for.
    // =======================================================================
    task t17_en_clr_collision;
        integer trial, i;
        begin
            $display("--- T17: EN clear vs concurrent write to another register ---");
            for (trial = 0; trial < 14; trial = trial + 1) begin
                u_slave.init_model();
                u_slave.push_rd(0, 32'h0000_0001);
                ack_count[0] = 0;

                cfg_channel(0, FIFO_BASE, MEM_BASE + 32'h1500, 16'd1,
                            mk_cr(DIR_P2M, SZ_BYTE, 1'b0, 1'b1, 1'b0,
                                  1'b1, 1'b1, 3'd7, 1'b1));
                set_req(6'b000001);

                wait (ack_count[0] == 1);
                hclk_wait(trial);              // sweep the collision phase

                // Rewrite SAR with its own value - functionally a no-op for
                // the transfer, but it asserts wr_en for this channel.
                for (i = 0; i < 3; i = i + 1)
                    apb_write(0, R_SAR, FIFO_BASE);

                hclk_wait(40);
                apb_read(0, R_CR, rd);
                chk(rd[B_EN] === 1'b0,
                    "CR.EN cleared despite a concurrent SAR write");

                set_req(6'b000000);
                clear_all_channels();
            end
        end
    endtask

    // =======================================================================
    // Main
    // =======================================================================
    integer seed_arg;

    initial begin
        for (k = 0; k < 6; k = k + 1) ack_count[k] = 0;
        u_slave.init_model();

        // Global bus-timing controls. A failing randomised run replays exactly
        // with the same +SEED.
        if (!$value$plusargs("GWAIT=%d", g_waits)) g_waits = 8'd0;
        if (!$value$plusargs("GRAND=%d", g_rand))  g_rand  = 1'b0;
        if (!$value$plusargs("SEED=%d",  seed_arg)) seed_arg = 1;
        rng_state = (seed_arg == 0) ? 32'h1 : seed_arg[31:0];
        u_slave.set_seed(rng_state ^ 32'hA5A5_5A5A);
        sl_waits = g_waits;
        sl_rand  = g_rand;
        $display("DMA TB config: GWAIT=%0d GRAND=%0d SEED=%0d",
                 g_waits, g_rand, seed_arg);

        if ($test$plusargs("WAVES")) begin
            $dumpfile("tb_dma_top.vcd");
            $dumpvars(0, tb_dma_top);
        end

        // Asynchronous assert, synchronous deassert (Sec. 12 / Sec. 17.5).
        hreset_n = 1'b0;
        preset_n = 1'b0;
        repeat (8) @(posedge hclk);
        @(negedge hclk) hreset_n = 1'b1;
        @(negedge pclk) preset_n = 1'b1;
        repeat (10) @(posedge hclk);

        // Sec. 12 reset checks, before anything is configured.
        chk(htrans === 2'b00, "HTRANS=IDLE out of reset");
        chk(dma_irq === 6'h0,  "all dma_irq deasserted out of reset");
        chk(dma_err === 6'h0,  "all dma_err deasserted out of reset");
        chk(dma_ack === 6'h0,  "all dma_ack deasserted out of reset");

        t1_register_access();
        t2_p2m_byte();
        t3_w1c();
        t4_circular();
        t5_fifo_deassert();
        t6_bus_error();
        t7_arbitration();
        t7b_preemption();
        t8_tiebreak();
        t9_m2m();
        t10_halfword_m2p();
        t11_zero_length();
        t12_wait_states();
        t13_all_channels();
        t14_software_abort();
        t15_edge_cases();
        t17_en_clr_collision();
        t16_random_soak();

        // Protocol monitors
        chk_eq(ack_width_bad, 0, "dma_ack never wider than 1 hclk");
        chk_eq(bad_burst, 0,     "HBURST always SINGLE");
        chk_eq(bad_trans, 0,     "HTRANS/HSIZE always legal");

        $display("");
        $display("=====================================================");
        $display("DMA TB: %0d checks, %0d failures", checks, failures);
        if (failures == 0) $display("RESULT: PASSED");
        else               $display("RESULT: FAILED");
        $display("=====================================================");
        $finish;
    end

    // Global watchdog
    initial begin
        #4_000_000;
        $display("[FAIL] global timeout - simulation did not finish");
        $display("DMA TB: %0d checks, %0d failures (TIMEOUT)", checks, failures+1);
        $display("RESULT: FAILED");
        $finish;
    end

endmodule
