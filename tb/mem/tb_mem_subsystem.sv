`timescale 1ns/1ps
// =============================================================================
// tb_mem_subsystem.sv -- Blocks 3/4/5 (ISRAM, Boot ROM, DSRAM), Rev 4.0 smoke
//
// Spec: GARUDA-MEM-SPEC-001 §11. A pipelined AHB master BFM drives the three
// memories through a minimal decoder, so back-to-back write->read traffic hits
// the synchronous-read macro exactly as the core and DMA will.
//
//   zero wait states on every legal access         [N-7.6]
//   byte/half/word lanes                            [N-7.3]
//   read-after-write through the write buffer       (ahb_mem_slave_if)
//   misaligned -> ERROR, ROM write -> ERROR          [N-7.4], §5.3
//   ILOCK refuses writes, SBA bypasses, reads ok     [N-7.8]..[N-7.10]
//   aliasing inside the 256 MiB granule              [N-7.2]
//   DSRAM bank decode on haddr[15:14]                [N-7.11]
//   random soak against a shadow model
// =============================================================================
module tb_mem_subsystem;

    reg hclk = 0, hreset_n = 0;
    always #2 hclk = ~hclk;

    // ---- master -----------------------------------------------------------------
    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hready, hresp;
    wire [2:0]  hsize, hburst;
    wire [3:0]  hprot;
    ahb_lite_master_bfm #(.HPROT(4'b0011), .QDEPTH(1024)) u_m (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite),
        .hsize_o(hsize), .hburst_o(hburst), .hprot_o(hprot), .hwdata_o(hwdata),
        .hrdata_i(hrdata), .hready_i(hready), .hresp_i(hresp));

    // ---- decode + return mux ----------------------------------------------------
    wire sel_i = haddr[31:28] == 4'h0, sel_r = haddr[31:28] == 4'h1, sel_d = haddr[31:28] == 4'h2;
    reg [1:0] dsel;                          // data-phase slave: 0=I 1=R 2=D
    always @(posedge hclk or negedge hreset_n)
        if (!hreset_n) dsel <= 0;
        else if (hready && htrans[1]) dsel <= sel_r ? 1 : sel_d ? 2 : 0;

    wire [31:0] rd_i, rd_r, rd_d;
    wire        ro_i, ro_r, ro_d, re_i, re_r, re_d;
    assign hrdata = dsel == 1 ? rd_r : dsel == 2 ? rd_d : rd_i;
    assign hready = dsel == 1 ? ro_r : dsel == 2 ? ro_d : ro_i;
    assign hresp  = dsel == 1 ? re_r : dsel == 2 ? re_d : re_i;

    reg ilock = 0, is_sba = 0;
    // Track A soak (plan 6A.6 M2): while sk_on, the debugger indication belongs to the
    // address phase, as the interconnect drives it (hmaster_is_sba = grant is SBA): a
    // transfer is "from the debugger" when HADDR[27] is set, a bit every memory
    // ignores (the regions alias inside their 256 MiB granule, [N-7.2]).
    reg  sk_on = 0;
    wire is_sba_w = sk_on ? (htrans[1] && haddr[27]) : is_sba;

    isram_top u_isram (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .hsel_i(sel_i), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_i), .hreadyout_o(ro_i), .hresp_o(re_i),
        .ilock_i(ilock), .hmaster_is_sba_i(is_sba_w));
    bootrom_top #(.INIT_FILE("")) u_rom (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .hsel_i(sel_r), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_r), .hreadyout_o(ro_r), .hresp_o(re_r));
    dsram_top u_dsram (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .hsel_i(sel_d), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_d), .hreadyout_o(ro_d), .hresp_o(re_d));

    // ---- checker ----------------------------------------------------------------
    wire [31:0] v_chk;
    ahb_lite_checker u_chk (.clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(haddr), .htrans_i(htrans), .hsize_i(hsize), .hburst_i(hburst),
        .hwrite_i(hwrite), .hwdata_i(hwdata), .hready_i(hready), .hresp_i(hresp),
        .viol_count_o(v_chk));

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    localparam [2:0] B = 3'b000, H = 3'b001, W = 3'b010;
    task automatic go(input [31:0] a, input bit wr, input [31:0] d, input [2:0] sz);
        u_m.push_xfer(a, wr, d, sz, 3'b000, 2'b10, 8'd0);
    endtask
    task automatic drain;
        int g = 0;
        while (((u_m.q_head !== u_m.q_tail) || u_m.addr_outstanding || u_m.data_outstanding)
               && g < 200000) begin @(posedge hclk); g++; end
        if (g >= 200000) begin fails++; $display("[FAIL] bus hung"); end
        repeat (3) @(posedge hclk);
    endtask
    task automatic clr; u_m.r_head = 0; u_m.r_tail = 0; endtask

    // wait-state monitor: any cycle with a legal (non-error) data phase and hready low
    integer wait_viol = 0;
    always @(posedge hclk) if (hreset_n && !hready && !hresp) wait_viol++;
    integer buf_ovf = 0;
    // ---- Track A soak: bus monitor + scoreboard (plan 6A.6 M2) --------------------
    // Independent of the BFM's queue and of the RTL: every completed transfer is
    // checked when its data phase ends (HREADY high), against a byte model of all
    // three memories. Expected responses come from the spec alone: ERROR for a ROM
    // write ([MEM 5.3]) and for an ISRAM write while ILOCK is set unless the
    // address phase is the debugger's ([N-7.8], [N-7.9]); OKAY otherwise. The ROM's
    // expected contents are the formula its backdoor load used (B000_0000 + word).
    reg [7:0]  sk_mem [0:196607];          // ISRAM 64 KiB | ROM 4 KiB (at 64 K) | DSRAM 64 KiB (at 128 K)
    reg        sk_val [0:196607];
    reg        mp_v = 0, mp_w = 0, mp_lk = 0, mp_sba = 0;
    reg [31:0] mp_a = 0;
    reg [2:0]  mp_sz = 0;
    reg        last_wr = 0;                // the previous completed transfer was an OKAY write ...
    reg [31:0] last_wword = 0;             // ... to this word (region + offset)
    integer sk_rd_bytes = 0, sk_rd = 0, sk_wr = 0, sk_lock_err = 0, sk_sba_wr = 0, sk_rom_err = 0,
            sk_mism = 0, sk_same = 0, sk_xfers = 0;
    integer sk_bank_rd [0:3];
    initial for (int b = 0; b < 4; b++) sk_bank_rd[b] = 0;
    // soak2 reloads the ROM with these contents (every data bit toggles across the image)
    function automatic [31:0] rom_word(input [9:0] i);
        rom_word = ({22'd0, i} * 32'h9E37_79B1) ^ 32'hB000_0000;
    endfunction
    reg rom_reloaded = 1'b0;
    integer sk_bursts = 0, sk_edge_rd = 0;
    function automatic integer sk_idx(input [31:0] a);
        case (a[29:28])
            2'd1:    sk_idx = 65536 + a[11:0];
            2'd2:    sk_idx = 131072 + a[15:0];
            default: sk_idx = a[15:0];
        endcase
    endfunction
    function automatic [31:0] sk_word(input [31:0] a);   // region + offset of the word
        sk_word = {a[31:28], (a[31:28] == 4'h1) ? {16'd0, a[11:2], 2'b00} : {12'd0, a[15:2], 2'b00}};
    endfunction
    integer sk_resets = 0, sk_rd_after_rst = 0, sk_foreign = 0, v_before_rst = 0, sk_mis_err = 0, sk_mis_issued = 0, sk_mis_flagged = 0;
    always @(posedge hclk) if (!hreset_n) mp_v <= 1'b0;
    always @(posedge hclk) if (hreset_n && hready) begin
        if (htrans[1] && !(sel_i || sel_r || sel_d) && sk_on) sk_foreign++;
        if (mp_v && sk_on) begin : sk_check
            bit rom, exp_err;
            reg [31:0] ln, romw;
            reg [7:0]  eb;
            integer    bi;
            rom     = (mp_a[31:28] == 4'h1);
            exp_err = (mp_sz == W && mp_a[1:0] != 2'b00) || (mp_sz == H && mp_a[0]) || (mp_sz > W) ||   // [N-7.4]
                      (rom && mp_w) || (mp_a[31:28] == 4'h0 && mp_w && mp_lk && !mp_sba);
            ln      = lanes(mp_a, mp_sz);
            sk_xfers++;
            if (hresp !== exp_err) begin
                sk_mism++;
                $display("[FAIL] soak2: %s %h size %0d: HRESP %b, expected %b (ILOCK %b, debugger %b)",
                         mp_w ? "write" : "read", mp_a, mp_sz, hresp, exp_err, mp_lk, mp_sba);
            end else if (exp_err) begin
                if ((mp_sz == W && mp_a[1:0] != 2'b00) || (mp_sz == H && mp_a[0]) || (mp_sz > W)) sk_mis_err++;
                else if (rom) sk_rom_err++; else sk_lock_err++;
            end else if (mp_w) begin
                for (int l = 0; l < 4; l++) if (ln[8*l]) begin
                    bi = sk_idx({mp_a[31:2], 2'b00} + l);
                    sk_mem[bi] = hwdata[8*l +: 8]; sk_val[bi] = 1'b1;
                end
                sk_wr++;
                if (mp_a[31:28] == 4'h0 && mp_lk && mp_sba) sk_sba_wr++;
            end else begin
                romw = rom_reloaded ? rom_word(mp_a[11:2]) : 32'hB000_0000 + mp_a[11:2];
                for (int l = 0; l < 4; l++) if (ln[8*l]) begin
                    bi = sk_idx({mp_a[31:2], 2'b00} + l);
                    if (rom || sk_val[bi]) begin
                        eb = rom ? romw[8*l +: 8] : sk_mem[bi];
                        sk_rd_bytes++;
                        if (hrdata[8*l +: 8] !== eb) begin
                            sk_mism++;
                            $display("[FAIL] soak2: read %h byte %0d = %h, expected %h", mp_a, l, hrdata[8*l +: 8], eb);
                        end
                    end
                end
                sk_rd++;
                if (sk_resets > 0 && !rom) sk_rd_after_rst++;
                if (mp_a[31:28] == 4'h2) sk_bank_rd[mp_a[15:14]]++;
                if (last_wr && last_wword == sk_word(mp_a)) sk_same++;
            end
            last_wr    <= mp_w && !exp_err;
            last_wword <= sk_word(mp_a);
        end
        mp_v <= htrans[1] && (sel_i || sel_r || sel_d);   // a transfer to no memory is not checked here
        mp_a <= haddr; mp_w <= hwrite; mp_sz <= hsize; mp_lk <= ilock; mp_sba <= is_sba_w;
    end
    // ILOCK changes at random cycles during the soak, also with transfers in flight
    // (vPlan F13): the memory must use the value of each transfer's address phase.
    reg [31:0] rng_lk = 32'h0BAD_5EED;
    always @(posedge hclk) if (sk_on) begin
        rng_lk ^= rng_lk << 13; rng_lk ^= rng_lk >> 17; rng_lk ^= rng_lk << 5;
        if (rng_lk[3:0] == 4'd0) ilock <= ~ilock;
    end

    // ---- shadow model -------------------------------------------------------------
    // The soak only addresses the first 16 KiB of D-SRAM, so the model is a
    // fixed array over that window, not an associative array (Icarus has
    // none). A byte outside the window, or one never written, reads as X,
    // which the soak compare skips.
    localparam [31:0] SH_BASE = 32'h2000_0000;
    localparam int    SH_SIZE = 16384;
    reg [7:0] shadow   [0:SH_SIZE-1];
    bit       sh_valid [0:SH_SIZE-1];
    function automatic bit sh_in(input [31:0] a);
        return (a >= SH_BASE) && (a - SH_BASE < SH_SIZE);
    endfunction
    function automatic [31:0] sh_rd(input [31:0] a);
        reg [31:0] b;
        for (int k = 0; k < 4; k++) begin
            b = (a & ~32'd3) + k;
            sh_rd[8*k +: 8] = (sh_in(b) && sh_valid[b - SH_BASE]) ? shadow[b - SH_BASE] : 8'hxx;
        end
    endfunction
    task automatic sh_wr(input [31:0] a, input [31:0] d, input [2:0] sz);
        int n = (sz == B) ? 1 : (sz == H) ? 2 : 4;
        for (int k = 0; k < n; k++)
            if (sh_in(a + k)) begin
                shadow[a + k - SH_BASE]   = d[8*((a + k) % 4) +: 8];
                sh_valid[a + k - SH_BASE] = 1;
            end
    endtask

    int i, n, e;
    reg [31:0] exp_q [0:1023];
    reg [31:0] msk_q [0:1023];
    int soak_batches = 0;
    reg [31:0] a, d;
    reg [2:0]  sz;
    reg [31:0] rng = 32'h1234_5678;
    integer seed = 1;
    integer sk_batch;
    reg [31:0] sa, sd;
    reg [2:0]  ssz;
    reg        sw;
    reg [3:0]  sreg;
    function automatic [31:0] rnd();
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng;
    endfunction

    initial begin
        $display("=== tb_mem_subsystem: Blocks 3/4/5 Rev 4.0 ===");
        for (i = 0; i < 1024; i++) u_rom.bd_write(32'h1000_0000 + 4*i, 32'hB000_0000 + i);
        repeat (3) @(posedge hclk); hreset_n = 1; repeat (2) @(posedge hclk);

        // ---- back-to-back write then read, same word, every memory -----------------
        clr();
        go(32'h0000_0100, 1, 32'h1111_2222, W);  go(32'h0000_0100, 0, 0, W);
        go(32'h2000_0100, 1, 32'h3333_4444, W);  go(32'h2000_0100, 0, 0, W);
        go(32'h2000_4200, 1, 32'h5555_6666, W);  go(32'h2000_8300, 1, 32'h7777_8888, W);
        go(32'h2000_C400, 1, 32'h9999_AAAA, W);
        go(32'h2000_4200, 0, 0, W); go(32'h2000_8300, 0, 0, W); go(32'h2000_C400, 0, 0, W);
        go(32'h1000_0010, 0, 0, W);
        drain();
        check(u_m.r_data[1] == 32'h1111_2222, "ISRAM write -> immediate read (buffer bypass)");
        check(u_m.r_data[3] == 32'h3333_4444, "DSRAM write -> immediate read (buffer bypass)");
        check(u_m.r_data[7] == 32'h5555_6666 && u_m.r_data[8] == 32'h7777_8888 &&
              u_m.r_data[9] == 32'h9999_AAAA, "DSRAM banks 1/2/3 by haddr[15:14]");
        check(u_dsram.g_bank[1].u_array.bd_read(12'h080) == 32'h5555_6666 &&
              u_dsram.g_bank[3].u_array.bd_read(12'h100) == 32'h9999_AAAA,
              "each word landed in the bank its address selects");
        check(u_m.r_data[10] == 32'hB000_0004, "Boot ROM word read");

        // ---- lanes ------------------------------------------------------------------
        clr();
        go(32'h2000_0200, 1, 32'hFFFF_FFFF, W);
        go(32'h2000_0201, 1, 32'h0000_AB00, B);
        go(32'h2000_0202, 1, 32'hCDEF_0000, H);
        go(32'h2000_0200, 0, 0, W);
        go(32'h2000_0203, 0, 0, B);
        go(32'h1000_0012, 0, 0, H);
        drain();
        check(u_m.r_data[3] == 32'hCDEF_ABFF, "byte + half lanes merge (through the write buffer)");
        check(u_m.r_data[5][31:16] == 16'hB000, "Boot ROM halfword read is legal [N-7.5]");

        // ---- errors ------------------------------------------------------------------
        clr();
        go(32'h2000_0301, 0, 0, W);            // misaligned word
        go(32'h2000_0301, 1, 32'h1, H);        // misaligned half
        go(32'h1000_0000, 1, 32'hBAD, W);      // ROM write
        go(32'h2000_0300, 0, 0, W);            // then a legal access
        go(32'h2000_0308, 0, 0, 3'b011);       // HSIZE wider than the bus (Track A): ERROR, [N-7.4] backstop
        drain();
        check(u_m.r_resp[0] && u_m.r_resp[1], "[N-7.4] misaligned word/half -> ERROR");
        check(u_m.r_resp[2], "Boot ROM write -> ERROR");
        check(u_rom.bd_read(32'h1000_0000) == 32'hB000_0000, "Boot ROM contents unchanged");
        check(!u_m.r_resp[3], "legal access after errors is OKAY");
        check(u_m.r_resp[4], "[N-7.4] HSIZE wider than a word -> ERROR");

        // ---- ILOCK ---------------------------------------------------------------------
        clr();
        go(32'h0000_0400, 1, 32'hA5A5_0001, W);
        drain();
        ilock = 1;
        go(32'h0000_0400, 1, 32'hDEAD_BEEF, W);
        go(32'h0000_0400, 0, 0, W);
        drain();
        check(u_m.r_resp[1], "[N-7.8] ISRAM write refused with ILOCK set");
        check(u_m.r_data[2] == 32'hA5A5_0001 && !u_m.r_resp[2], "[N-7.10] ISRAM read unaffected, data intact");
        is_sba = 1;
        go(32'h0000_0400, 1, 32'h5BA0_5BA0, W);
        drain();
        is_sba = 0;
        go(32'h0000_0400, 0, 0, W);
        drain();
        check(!u_m.r_resp[3] && u_m.r_data[4] == 32'h5BA0_5BA0, "[N-7.9] SBA write bypasses ILOCK");
        ilock = 0;

        // ---- aliasing ----------------------------------------------------------------------
        clr();
        go(32'h0001_0400, 0, 0, W);            // ISRAM + 64 KiB -> aliases word 0x400
        go(32'h1000_1010, 0, 0, W);            // ROM   + 4 KiB
        drain();
        check(u_m.r_data[0] == 32'h5BA0_5BA0 && u_m.r_data[1] == 32'hB000_0004,
              "[N-7.2] addresses alias inside the region");

        // ---- random soak vs shadow model ----------------------------------------------------
        for (i = 0; i < SH_SIZE; i++) begin shadow[i] = 8'h00; sh_valid[i] = 1; end
        for (i = 0; i < 4096; i++) u_dsram.bd_write(32'h2000_0000 + 4*i, 32'h0);
        clr();
        n = 0;
        for (i = 0; i < 900; i++) begin
            a  = 32'h2000_0000 + (rnd() % 16384);
            case (rnd() % 3) 0: sz = B; 1: begin sz = H; a[0] = 0; end default: begin sz = W; a[1:0] = 0; end endcase
            d = rnd();
            if (rnd() % 2) begin go(a, 1, d << (8*a[1:0]), sz); sh_wr(a, d << (8*a[1:0]), sz); exp_q[n] = 32'hx; end
            else           begin go(a, 0, 0, sz); exp_q[n] = sh_rd(a); end
            msk_q[n] = lanes(a, sz);
            n++;
            if (n % 200 == 0) begin
                drain();
                e = 0;
                for (int k = 0; k < 200; k++)
                    if (exp_q[k] !== 32'hx && ((u_m.r_data[k] ^ exp_q[k]) & msk_q[k]) != 0) e++;
                if (e) begin fails++; $display("[FAIL] soak batch: %0d mismatches", e); end
                soak_batches++;
                clr(); n = 0;
            end
        end
        drain();
        check(soak_batches == 4, "random soak: 4 x 200 mixed-size accesses vs shadow model");
        // ---- Track A seeded soak (plan 6A.6 M2) -----------------------------------------
        // All three memories and all four DSRAM banks; half the traffic in a small hot
        // window per bank so reads find written data; back-to-back write -> read of the
        // same word (the read bypass of a parked sub-word write); ROM writes; debugger
        // writes; ILOCK toggling at random cycles. +SEED=<n> chooses the run.
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        rng = 32'h9E37_79B9 ^ seed; if (rng == 0) rng = 1;
        // the ILOCK toggler follows +SEED too (review 2026-11-01); seed 1 keeps the old stream
        if (seed != 1) begin rng_lk = 32'h0BAD_5EED ^ (seed * 32'h9E37_79B1); if (rng_lk == 0) rng_lk = 1; end
        $display("soak2: seed %0d", seed);
        for (i = 0; i < 196608; i++) sk_val[i] = 1'b0;
        for (i = 0; i < 1024; i++) u_rom.bd_write(32'h1000_0000 + 4*i, rom_word(i));
        rom_reloaded = 1'b1;
        @(negedge hclk); ilock = 0; sk_on = 1;      // off the clock edge: no race with the monitor and the ILOCK process
        // every illegal size/offset ([N-7.4], vPlan F05) on each memory, both directions:
        // half at 1/3, word at 1/2/3, and wider than a word; each must get ERROR (scoreboard)
        clr();
        for (int m = 0; m < 3; m++)
            for (int dir = 0; dir < 2; dir++)
                for (int c = 0; c < 7; c++) begin
                    sa = (m == 0) ? 32'h0000_0480 : (m == 1) ? 32'h2000_4480 : 32'h1000_0480;
                    case (c) 0: begin sa[1:0] = 1; ssz = H; end 1: begin sa[1:0] = 3; ssz = H; end
                             2: begin sa[1:0] = 1; ssz = W; end 3: begin sa[1:0] = 2; ssz = W; end
                             4: begin sa[1:0] = 3; ssz = W; end 5: begin sa[1:0] = 0; ssz = 3'b011; end
                             default: begin sa[1:0] = 0; ssz = 3'b100; end endcase
                    if (c < 5) sk_mis_issued++;    // the AHB checker flags misalignment, not an over-wide size
                    u_m.push_xfer(sa, dir[0], 32'hDEAD_0000 | c, ssz, 3'b000, 2'b10, 8'd0);
                end
        drain();
        sk_mis_flagged = v_chk - 2;                 // after Karthik's two deliberate misaligned transfers
        // edges (vPlan F01, F02): the ISRAM's first and last word, and each DSRAM bank's first
        // and last word, written and read back (the scoreboard checks the reads)
        clr();
        for (int e2 = 0; e2 < 10; e2++) begin
            case (e2)
                0: sa = 32'h0000_0000; 1: sa = 32'h0000_FFFC;
                2: sa = 32'h2000_0000; 3: sa = 32'h2000_3FFC; 4: sa = 32'h2000_4000; 5: sa = 32'h2000_7FFC;
                6: sa = 32'h2000_8000; 7: sa = 32'h2000_BFFC; 8: sa = 32'h2000_C000; default: sa = 32'h2000_FFFC;
            endcase
            u_m.push_xfer(sa, 1'b1, 32'hE0E0_0000 | e2, W, 3'b000, 2'b10, 8'd0);
        end
        for (int e2 = 0; e2 < 10; e2++)
            u_m.push_xfer((e2 < 2) ? (e2 ? 32'h0000_FFFC : 32'h0) : 32'h2000_0000 | ((e2 - 2) / 2 * 32'h4000) | ((e2 % 2) ? 32'h3FFC : 0),
                          1'b0, 0, W, 3'b000, 2'b10, 8'd0);
        drain();
        sk_edge_rd = sk_rd;
        for (sk_batch = 0; sk_batch < 40; sk_batch++) begin
            clr();
            for (n = 0; n < 240; ) begin
                sreg = rnd() % 8;                                  // 0-2 ISRAM, 3 ROM, 4-7 DSRAM
                case (rnd() % 3) 0: ssz = B; 1: ssz = H; default: ssz = W; endcase
                if (sreg == 3) sa = 32'h1000_0000 | (rnd() % 4096);
                else begin
                    sa = (sreg < 3) ? 32'h0000_0000 : 32'h2000_0000;
                    sa = sa | ((rnd() % 2) ? (rnd() % 65536)                               // anywhere
                                           : (((rnd() % 4) << 14) | ((rnd() % 32) << 2) | (rnd() % 4)));  // hot window per bank
                end
                if (ssz == H) sa[0] = 1'b0; else if (ssz == W) sa[1:0] = 2'b00;
                // alias bits: every memory ignores HADDR above its size inside its 256 MiB
                // granule ([N-7.2]); bit 27 stays the debugger tag
                sa = sa | (rnd() & ((sreg == 3) ? 32'h07FF_F000 : 32'h07FF_0000));
                sw = (sreg == 3) ? (rnd() % 8 == 0) : (rnd() % 2);
                if (sreg < 3 && rnd() % 4 == 0) sa[27] = 1'b1;          // the debugger's transfer (writes and reads)
                sd = rnd();
                u_m.push_xfer(sa, sw, sd << (8 * sa[1:0]), ssz, 3'b000, 2'b10, (rnd() % 4 == 0) ? rnd() % 3 : 0);
                n++;
                if (rnd() % 10 == 0) begin                             // an INCR burst of 2-4 words (SEQ beats, the I-port's pattern)
                    sa = (sreg == 3) ? 32'h1000_0000 | (rnd() & 32'h0000_0FF0) :
                         (((sreg < 3) ? 32'h0000_0000 : 32'h2000_0000) | (rnd() & 32'h0000_FFF0));
                    if (sreg < 3 && rnd() % 4 == 0) sa[27] = 1'b1;
                    sw = (sreg == 3) ? 1'b0 : rnd() % 2;
                    sk_bursts++;
                    for (int bt = 0; bt < 2 + rnd() % 3; bt++) begin
                        u_m.push_xfer(sa + 4*bt, sw, rnd(), W, 3'b001, bt == 0 ? 2'b10 : 2'b11, 8'd0);
                        n++;
                    end
                end
                if (rnd() % 16 == 0) begin                             // a transfer no memory may answer (F08)
                    sd = rnd(); sd[31:28] = 4'h4 << (rnd() % 3); sd[1:0] = 2'b00;     // 0x4..., 0x8..., 0x1... is ROM: use 4/8 only
                    if (sd[31:28] == 4'h1 || sd[31:28] == 4'h0) sd[31:28] = 4'hC;
                    u_m.push_xfer(sd, rnd() % 2, rnd(), W, 3'b000, 2'b10, 8'd0);
                    n++;
                end
                if (sw && sreg != 3 && rnd() % 4 == 0) begin           // read the same word straight after
                    case (rnd() % 3) 0: ssz = B; 1: ssz = H; default: ssz = W; endcase
                    sa = {sa[31:2], 2'b00} | ((ssz == W) ? 0 : (ssz == H) ? (rnd() % 2) * 2 : rnd() % 4);
                    sa[27] = 1'b0;
                    u_m.push_xfer(sa, 1'b0, 32'h0, ssz, 3'b000, 2'b10, 8'd0);
                    n++;
                end
            end
            drain();
            if (sk_batch == 20) begin                                 // reset mid-run: contents survive (F09)
                v_before_rst = v_chk;                                 // the checker's count restarts at reset
                @(negedge hclk); hreset_n = 0; repeat (3) @(negedge hclk); hreset_n = 1;
                sk_resets++; repeat (2) @(posedge hclk);
            end
        end
        @(negedge hclk); sk_on = 0; ilock = 0;
        $display("soak2: %0d transfers, %0d reads (%0d bytes checked), %0d writes, %0d same-word write->read, banks %0d/%0d/%0d/%0d, %0d lock refusals, %0d debugger writes to locked ISRAM, %0d ROM write refusals",
                 sk_xfers, sk_rd, sk_rd_bytes, sk_wr, sk_same, sk_bank_rd[0], sk_bank_rd[1], sk_bank_rd[2], sk_bank_rd[3], sk_lock_err, sk_sba_wr, sk_rom_err);
        check(sk_mism == 0 && sk_xfers > 9000, "soak2: every response and every read byte matches the model");
        check(sk_rd_bytes > 4000 && sk_bank_rd[0] > 0 && sk_bank_rd[1] > 0 && sk_bank_rd[2] > 0 && sk_bank_rd[3] > 0,
              "soak2: reads checked in all four DSRAM banks");
        check(sk_same > 0, "soak2: same-word write -> read back to back (read bypass)");
        check(sk_bursts > 50, "soak2: INCR bursts (SEQ beats) on all three memories");
        check(sk_edge_rd == 10, "soak2: [F01 F02] first/last word of the ISRAM and of each DSRAM bank written and read back");
        check(sk_resets == 1 && sk_rd_after_rst > 1000, "soak2: [F09] contents written before a reset read back after it");
        check(sk_foreign > 100, "soak2: transfers to other regions (no memory selected) mixed in; every later read shows the memories untouched (F08)");
        check(sk_lock_err > 0 && sk_sba_wr > 0 && sk_rom_err > 0,
              "soak2: lock refusals, debugger writes to locked ISRAM and ROM write refusals all seen");

        check(wait_viol == 0, "[N-7.6] zero wait states on every legal access");
        // the checker does not flag HSIZE wider than the 32-bit bus (logged for track A as a
        // checker gap, 2026-10-15), so the over-wide transfer is not in its count
        check(sk_mis_err == 42 && sk_mis_flagged == sk_mis_issued, "soak2: [F05] every illegal size/offset on every memory refused; the checker flagged each misaligned one");
        check(v_before_rst + v_chk == 2 + sk_mis_issued, "AHB-Lite checker: only the deliberate misaligned transfers flagged (Karthik's 2 + the F05 sweep)");

        $display("tb_mem_subsystem: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    function automatic [31:0] lanes(input [31:0] a, input [2:0] sz);
        case (sz)
            B:       lanes = 32'hFF << (8*a[1:0]);
            H:       lanes = a[1] ? 32'hFFFF_0000 : 32'h0000_FFFF;
            default: lanes = 32'hFFFF_FFFF;
        endcase
    endfunction

    initial begin #5_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
