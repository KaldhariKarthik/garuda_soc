`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Blocks 3/4/5: Memory Subsystem - block-level testbench
//
// Covers GARUDA-MEM-SPEC-001 Rev 2.0 Sec. 12 (Verification Plan).
//
// The three memories are driven directly rather than through the interconnect
// and a master BFM. That is deliberate: this testbench is about the SLAVE
// CONTRACT - zero wait states, no error response, byte lanes, depth checking -
// and driving the slave bundle by hand is the only way to present the exact
// address-phase/data-phase timing each check needs, including the cases a
// compliant master would never generate.
//
// THE TEST THAT MATTERS MOST IS T4, THE ALIASING TEST.
// The interconnect decodes HADDR[31:28] only, so it selects a memory for a
// whole 256 MB region, not for its actual size. Without the local depth check
// every region address folds onto the implemented depth and 0x0001_0000 reads
// ISRAM word 0. That defect is invisible to every functional test that stays
// inside the implemented range - which is all of them, until a pointer runs
// away. T4 addresses past the end of each memory and requires a ZERO, not the
// pattern that lives at the aliased location.
//
// Plusargs
//   +VERBOSE   print every check
// =============================================================================

module tb_mem_subsystem;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg hclk = 1'b0;
    reg hreset_n = 1'b0;
    always #2.5 hclk = ~hclk;                 // 200 MHz

    // -----------------------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------------------
    integer checks = 0;
    integer fails  = 0;
    reg     verbose;

    task chk;
        input          cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("[FAIL] %0s   (t=%0t)", msg, $time);
            end else if (verbose) $display("[ ok ] %0s", msg);
        end
    endtask

    task chk_eq;
        input [63:0]   got;
        input [63:0]   exp;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s : got 0x%0h expected 0x%0h   (t=%0t)",
                         msg, got, exp, $time);
            end else if (verbose) $display("[ ok ] %0s = 0x%0h", msg, got);
        end
    endtask

    // -----------------------------------------------------------------------
    // Shared slave bundle - exactly what the interconnect drives
    // -----------------------------------------------------------------------
    reg  [31:0] haddr;
    reg  [1:0]  htrans;
    reg         hwrite;
    reg  [2:0]  hsize;
    reg  [2:0]  hburst;
    reg  [3:0]  hprot;
    reg  [31:0] hwdata;
    reg         hready;
    reg         sel_isram, sel_rom, sel_dsram;

    wire [31:0] rdata_isram, rdata_rom, rdata_dsram;
    wire        rout_isram,  rout_rom,  rout_dsram;
    wire        resp_isram,  resp_rom,  resp_dsram;

    localparam [2:0] SZ_B = 3'b000, SZ_H = 3'b001, SZ_W = 3'b010;
    localparam [1:0] T_IDLE = 2'b00, T_NONSEQ = 2'b10;

    localparam [31:0] ISRAM_BASE = 32'h0000_0000;
    localparam [31:0] ROM_BASE   = 32'h1000_0000;
    localparam [31:0] DSRAM_BASE = 32'h2000_0000;

    // -----------------------------------------------------------------------
    // DUTs
    // -----------------------------------------------------------------------
    isram_top u_isram (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .hsel_i(sel_isram), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst), .hprot_i(hprot),
        .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rdata_isram), .hreadyout_o(rout_isram), .hresp_o(resp_isram));

    bootrom_top #(.INIT_FILE("")) u_rom (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .hsel_i(sel_rom), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst), .hprot_i(hprot),
        .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rdata_rom), .hreadyout_o(rout_rom), .hresp_o(resp_rom));

    dsram_top u_dsram (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .hsel_i(sel_dsram), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst), .hprot_i(hprot),
        .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rdata_dsram), .hreadyout_o(rout_dsram), .hresp_o(resp_dsram));

    // -----------------------------------------------------------------------
    // Zero-wait-state monitor (Sec. 8.4)
    //
    // Sec. 12 requires "hreadyout is never low for any of the three memories
    // under any traffic pattern whatsoever". A continuous monitor is the right
    // shape for that: it covers every cycle of every test rather than the
    // handful of moments a directed check would sample.
    // -----------------------------------------------------------------------
    integer n_stall;
    integer n_err;
    always @(posedge hclk) begin
        if (hreset_n) begin
            if (!rout_isram || !rout_rom || !rout_dsram) n_stall = n_stall + 1;
            if (resp_isram || resp_rom || resp_dsram)    n_err   = n_err   + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Bus driver. Zero-wait slaves, so one address phase per cycle and the
    // data phase is always the very next cycle.
    // -----------------------------------------------------------------------
    task bus_idle;
        begin
            htrans    = T_IDLE;
            sel_isram = 1'b0; sel_rom = 1'b0; sel_dsram = 1'b0;
        end
    endtask

    task sel_for;
        input [31:0] a;
        begin
            sel_isram = (a[31:28] == 4'h0);
            sel_rom   = (a[31:28] == 4'h1);
            sel_dsram = (a[31:28] == 4'h2);
        end
    endtask

    task ahb_write;
        input [31:0] a;
        input [31:0] d;
        input [2:0]  sz;
        begin
            @(negedge hclk);
            sel_for(a);
            haddr = a; htrans = T_NONSEQ; hwrite = 1'b1; hsize = sz;
            @(negedge hclk);                 // data phase
            bus_idle;
            hwdata = d;
            @(negedge hclk);
        end
    endtask

    task ahb_read;
        input  [31:0] a;
        input  [2:0]  sz;
        output [31:0] d;
        begin
            @(negedge hclk);
            sel_for(a);
            haddr = a; htrans = T_NONSEQ; hwrite = 1'b0; hsize = sz;
            @(negedge hclk);                 // data phase: hrdata valid now
            bus_idle;
            case (a[31:28])
                4'h0:    d = rdata_isram;
                4'h1:    d = rdata_rom;
                default: d = rdata_dsram;
            endcase
            @(negedge hclk);
        end
    endtask

    integer i;
    reg [31:0] rd;

    initial begin
        verbose = $test$plusargs("VERBOSE");
        n_stall = 0; n_err = 0;
        haddr = 0; htrans = T_IDLE; hwrite = 0; hsize = SZ_W;
        hburst = 3'b000; hprot = 4'b0011; hwdata = 0; hready = 1'b1;
        bus_idle;

        $display("======================================================");
        $display("GARUDA Memory Subsystem (Blocks 3/4/5) testbench");
        $display("======================================================");

        repeat (4) @(posedge hclk);
        hreset_n = 1'b1;
        repeat (2) @(posedge hclk);

        // ===================================================================
        // T1 - word read/write round trip on each memory
        // ===================================================================
        ahb_write(ISRAM_BASE + 32'h100, 32'hDEAD_BEEF, SZ_W);
        ahb_read (ISRAM_BASE + 32'h100, SZ_W, rd);
        chk_eq(rd, 32'hDEAD_BEEF, "T1 ISRAM word round trip");

        ahb_write(DSRAM_BASE + 32'h200, 32'hCAFE_F00D, SZ_W);
        ahb_read (DSRAM_BASE + 32'h200, SZ_W, rd);
        chk_eq(rd, 32'hCAFE_F00D, "T1 DSRAM word round trip");

        // ===================================================================
        // T2 - byte and half-word lanes (Sec. 8.3)
        //
        // Only the addressed lanes may change. A read-modify-write in the
        // wrapper would pass a "write then read the same address" test and
        // corrupt the neighbouring lanes, so each check reads back the WHOLE
        // word and compares every lane.
        // ===================================================================
        ahb_write(DSRAM_BASE + 32'h300, 32'h1122_3344, SZ_W);

        ahb_write(DSRAM_BASE + 32'h300, 32'h0000_00AA, SZ_B);
        ahb_read (DSRAM_BASE + 32'h300, SZ_W, rd);
        chk_eq(rd, 32'h1122_33AA, "T2 byte write lane 0 leaves lanes 1-3 intact");

        ahb_write(DSRAM_BASE + 32'h302, 32'h00BB_0000, SZ_B);
        ahb_read (DSRAM_BASE + 32'h300, SZ_W, rd);
        chk_eq(rd, 32'h11BB_33AA, "T2 byte write lane 2 leaves the rest intact");

        ahb_write(DSRAM_BASE + 32'h300, 32'h0000_CCDD, SZ_H);
        ahb_read (DSRAM_BASE + 32'h300, SZ_W, rd);
        chk_eq(rd, 32'h11BB_CCDD, "T2 half-word write lanes 0-1 only");

        ahb_write(DSRAM_BASE + 32'h302, 32'hEEFF_0000, SZ_H);
        ahb_read (DSRAM_BASE + 32'h300, SZ_W, rd);
        chk_eq(rd, 32'hEEFF_CCDD, "T2 half-word write lanes 2-3 only");

        // ===================================================================
        // T3 - bank decode and isolation (Sec. 6.2, Sec. 12)
        //
        // Write a distinct pattern to the same offset in all four banks, then
        // read all four. A bank-select bug shows up as one value appearing
        // twice, which a single-bank test cannot see.
        // ===================================================================
        for (i = 0; i < 4; i = i + 1)
            ahb_write(DSRAM_BASE + (i << 14) + 32'h40, 32'hB0000000 + i, SZ_W);

        for (i = 0; i < 4; i = i + 1) begin
            ahb_read(DSRAM_BASE + (i << 14) + 32'h40, SZ_W, rd);
            chk_eq(rd, 32'hB0000000 + i, "T3 bank isolation: correct bank read back");
        end

        // Bank index must have NO timing effect: same-bank and different-bank
        // sequences are identical, because the interconnect serialises masters
        // before either reaches this block (Sec. 7.1). The zero-stall monitor
        // below is what actually proves it.
        ahb_read(DSRAM_BASE + 32'h40,   SZ_W, rd);
        ahb_read(DSRAM_BASE + 32'h4040, SZ_W, rd);
        ahb_read(DSRAM_BASE + 32'h40,   SZ_W, rd);
        chk(n_stall == 0, "T3 alternating banks never inserted a wait state");

        // ===================================================================
        // T4 - DEPTH RANGE CHECK / ALIASING (Sec. 6.4) - the important one
        // ===================================================================
        ahb_write(ISRAM_BASE, 32'hA11A_5005, SZ_W);
        ahb_read (ISRAM_BASE + 32'h0001_0000, SZ_W, rd);      // past 64 KB
        chk_eq(rd, 32'h0000_0000,
               "T4 ISRAM: address past implemented depth reads ZERO, not an alias");

        ahb_write(DSRAM_BASE, 32'h5005_A11A, SZ_W);
        ahb_read (DSRAM_BASE + 32'h0001_0000, SZ_W, rd);
        chk_eq(rd, 32'h0000_0000,
               "T4 DSRAM: address past implemented depth reads ZERO, not an alias");

        ahb_read (ROM_BASE + 32'h0000_1000, SZ_W, rd);        // past 4 KB
        chk_eq(rd, 32'h0000_0000,
               "T4 ROM: address past implemented depth reads ZERO, not an alias");

        // An out-of-depth WRITE must not disturb the location it would alias to.
        ahb_write(ISRAM_BASE + 32'h0001_0000, 32'hFFFF_FFFF, SZ_W);
        ahb_read (ISRAM_BASE, SZ_W, rd);
        chk_eq(rd, 32'hA11A_5005,
               "T4 out-of-depth write did not disturb the aliased location");

        // ===================================================================
        // T5 - Boot ROM is read-only (Sec. 8.6)
        // ===================================================================
        u_rom.bd_write(ROM_BASE + 32'h20, 32'h600D_C0DE);     // mask-program it
        ahb_read (ROM_BASE + 32'h20, SZ_W, rd);
        chk_eq(rd, 32'h600D_C0DE, "T5 ROM returns its programmed contents");

        ahb_write(ROM_BASE + 32'h20, 32'hBAD0_BAD0, SZ_W);    // try to write
        ahb_read (ROM_BASE + 32'h20, SZ_W, rd);
        chk_eq(rd, 32'h600D_C0DE, "T5 ROM write was accepted and DISCARDED");

        // ===================================================================
        // T6 - boundary addresses (Sec. 12 "full-depth addressing")
        // ===================================================================
        ahb_write(ISRAM_BASE + 32'h0000_FFFC, 32'h7EED_1234, SZ_W);  // top word
        ahb_read (ISRAM_BASE + 32'h0000_FFFC, SZ_W, rd);
        chk_eq(rd, 32'h7EED_1234, "T6 ISRAM top word is addressable");

        ahb_write(DSRAM_BASE + 32'h0000_FFFC, 32'h4321_DEEF, SZ_W);
        ahb_read (DSRAM_BASE + 32'h0000_FFFC, SZ_W, rd);
        chk_eq(rd, 32'h4321_DEEF, "T6 DSRAM top word (bank 3) is addressable");

        // ===================================================================
        // T7 - backdoor agrees with the bus (guards the TB's own assumptions)
        // ===================================================================
        chk_eq(u_dsram.bd_read(DSRAM_BASE + 32'h0000_FFFC), 32'h4321_DEEF,
               "T7 DSRAM backdoor agrees with the bus-side value");
        chk_eq(u_isram.bd_read(ISRAM_BASE + 32'h100), 32'hDEAD_BEEF,
               "T7 ISRAM backdoor agrees with the bus-side value");

        // ===================================================================
        // T8 - reset mid-transfer leaves the wrapper ready (Sec. 12)
        // ===================================================================
        @(negedge hclk);
        sel_for(DSRAM_BASE);
        haddr = DSRAM_BASE; htrans = T_NONSEQ; hwrite = 1'b1; hsize = SZ_W;
        @(negedge hclk);
        hreset_n = 1'b0;                      // reset in the data phase
        bus_idle;
        repeat (3) @(posedge hclk);
        chk(rout_dsram === 1'b1, "T8 hreadyout high while held in reset");
        @(negedge hclk);
        hreset_n = 1'b1;
        repeat (2) @(posedge hclk);

        ahb_write(DSRAM_BASE + 32'h500, 32'h0BADF00D, SZ_W);
        ahb_read (DSRAM_BASE + 32'h500, SZ_W, rd);
        chk_eq(rd, 32'h0BADF00D, "T8 first transfer after reset is clean");

        // ===================================================================
        // Continuous monitors (Sec. 8.4, Sec. 8.6)
        // ===================================================================
        chk_eq(n_stall, 0, "ZERO WAIT STATES: no memory ever drove hreadyout low");
        chk_eq(n_err,   0, "NO ERROR RESPONSE: hresp stayed OKAY on all three");

        $display("======================================================");
        $display("tb_mem_subsystem: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %0s", (fails == 0) ? "PASSED" : "FAILED");
        $display("======================================================");
        $finish;
    end

    initial begin
        #500_000;
        $display("[FAIL] tb_mem_subsystem: TIMEOUT");
        $display("RESULT: FAILED");
        $finish;
    end

endmodule
