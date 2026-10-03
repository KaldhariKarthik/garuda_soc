`timescale 1ns / 1ps
// =============================================================================
// tb_apb_checker_selftest -- negative control for apb_checker.
//
// Docs/ORACLES.md: "A clean report from a checker that has not been shown to
// fail is worth nothing." This file exists so that every clean APB report in
// this project means something.
//
// apb_checker is a passive monitor, so its taps can be driven directly. Each
// scenario below presents an exact cycle-by-cycle waveform rather than
// arranging a DUT that happens to produce one, which is the only way to hit a
// protocol corner on purpose instead of hoping stimulus wanders into it.
//
// TWO PROPERTIES PER SCENARIO, not one
//   1. the rule under test fires exactly once, and
//   2. v_total is also exactly one -- so the injected violation fired THAT
//      rule and no other.
//
// The second property is the one that catches a checker whose rules
// cross-trigger, which is how a monitor ends up reporting three violations for
// one defect and sending a reader after the wrong signal.
//
// Scenario L is the complement: legal traffic, including the cases closest to
// the rules above (back-to-back accesses through SETUP, wait states, PSLVERR
// inside an access), which must produce a zero count AND a non-zero access
// count. Requiring n_access > 0 is deliberate: this project has three recorded
// instances of a check that passed while measuring nothing (TOOL-4, TB-11, and
// the static checker that reported success having checked nothing), so a clean
// report from a checker that saw no traffic is treated as a failure here.
//
// The timeout rule needs a different MAX_WAIT than the default, so a second
// checker is bound to the same taps with MAX_WAIT=4. It also means every other
// scenario is implicitly checked against a strict stall budget.
// =============================================================================

module tb_apb_checker_selftest;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n   = 1'b1;
    reg        psel    = 1'b0;
    reg        penable = 1'b0;
    reg        pwrite  = 1'b0;
    reg [31:0] paddr   = 32'h0000_0000;
    reg [31:0] pwdata  = 32'h0000_0000;
    reg [ 3:0] pstrb   = 4'hF;
    reg        pready  = 1'b1;
    reg        pslverr = 1'b0;

    apb_checker u_chk (
        .clk_i(clk), .rst_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .pstrb_i(pstrb),
        .pready_i(pready), .pslverr_i(pslverr), .viol_count_o()
    );

    // Declares one legitimate extension cycle, the way a /2 divided window
    // does. It must tolerate exactly one and still catch two.
    apb_checker #(.EXTEND_MAX(1)) u_ext (
        .clk_i(clk), .rst_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .pstrb_i(pstrb),
        .pready_i(pready), .pslverr_i(pslverr), .viol_count_o()
    );

    apb_checker #(.MAX_WAIT(4)) u_to (
        .clk_i(clk), .rst_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .pstrb_i(pstrb),
        .pready_i(pready), .pslverr_i(pslverr), .viol_count_o()
    );

    integer checks = 0;
    integer fails  = 0;

    task ck;
        input [8*72-1:0] what;
        input integer got;
        input integer want;
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("[FAIL] %0s: got %0d, want %0d", what, got, want);
            end else begin
                $display("[PASS] %0s = %0d", what, got);
            end
        end
    endtask

    // One bus cycle. Driven just after the negedge so every value is stable
    // across the posedge the checker samples -- the checker's whole model is
    // "this cycle versus the previous one", and driving on the edge it samples
    // would make which cycle a value belongs to a race.
    task tick;
        input s, e, w;
        input [31:0] a;
        input [31:0] d;
        input [ 3:0] st;
        input r, sv;
        begin
            @(negedge clk);
            psel = s; penable = e; pwrite = w;
            paddr = a; pwdata = d; pstrb = st;
            pready = r; pslverr = sv;
        end
    endtask

    task idle;   begin tick(0,0,0, 32'h0, 32'h0, 4'hF, 1, 0); end endtask

    // Clear both checkers' counters between scenarios, so each one is measured
    // on its own waveform rather than on everything that came before it.
    task zap;
        begin
            idle; idle;
            @(negedge clk); rst_n = 1'b0;
            @(negedge clk);
            @(negedge clk); rst_n = 1'b1;
            idle;
        end
    endtask

    initial begin
        $display("=== tb_apb_checker_selftest: apb_checker negative control ===");
        idle; idle;

        // ---- A: PENABLE high in the same cycle PSEL rose -------------------
        zap;
        tick(1,1,0, 32'h40, 32'h0, 4'hF, 1, 0);     // no SETUP cycle at all
        idle; idle;
        $display("--- A: SETUP phase skipped ---");
        ck("A: v_setup_skipped", u_chk.v_setup_skipped, 1);
        ck("A: fired nothing else", u_chk.v_total, 1);

        // ---- B: SETUP held for two cycles ----------------------------------
        zap;
        tick(1,0,0, 32'h44, 32'h0, 4'hF, 1, 0);     // SETUP
        tick(1,0,0, 32'h44, 32'h0, 4'hF, 1, 0);     // SETUP again -- illegal
        tick(1,1,0, 32'h44, 32'h0, 4'hF, 1, 0);     // ACCESS, completes
        idle; idle;
        $display("--- B: SETUP longer than one cycle ---");
        ck("B: v_setup_stretched", u_chk.v_setup_stretched, 1);
        ck("B: fired nothing else", u_chk.v_total, 1);

        // ---- C: PSEL withdrawn mid-ACCESS ----------------------------------
        zap;
        tick(1,0,0, 32'h48, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h48, 32'h0, 4'hF, 0, 0);     // ACCESS, PREADY low
        idle;                                       // abandons the access
        idle;
        $display("--- C: PSEL dropped mid-ACCESS ---");
        ck("C: v_psel_dropped", u_chk.v_psel_dropped, 1);
        ck("C: fired nothing else", u_chk.v_total, 1);

        // ---- D: PENABLE withdrawn mid-ACCESS -------------------------------
        zap;
        tick(1,0,0, 32'h4C, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h4C, 32'h0, 4'hF, 0, 0);     // ACCESS, PREADY low
        tick(1,0,0, 32'h4C, 32'h0, 4'hF, 1, 0);     // back to SETUP -- illegal
        idle; idle;
        $display("--- D: PENABLE dropped mid-ACCESS ---");
        ck("D: v_penable_dropped", u_chk.v_penable_dropped, 1);
        ck("D: fired nothing else", u_chk.v_total, 1);

        // ---- E: PADDR moved during ACCESS ----------------------------------
        zap;
        tick(1,0,0, 32'h50, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h50, 32'h0, 4'hF, 0, 0);     // ACCESS, PREADY low
        tick(1,1,0, 32'h54, 32'h0, 4'hF, 1, 0);     // address moved
        idle; idle;
        $display("--- E: PADDR moved in ACCESS ---");
        ck("E: v_addr_change", u_chk.v_addr_change, 1);
        ck("E: fired nothing else", u_chk.v_total, 1);

        // ---- F: PSTRB moved during ACCESS ----------------------------------
        zap;
        tick(1,0,1, 32'h58, 32'hA5A5_A5A5, 4'hF, 1, 0);
        tick(1,1,1, 32'h58, 32'hA5A5_A5A5, 4'hF, 0, 0);
        tick(1,1,1, 32'h58, 32'hA5A5_A5A5, 4'h3, 1, 0);   // strobes moved
        idle; idle;
        $display("--- F: PWRITE/PSTRB moved in ACCESS ---");
        ck("F: v_ctrl_change", u_chk.v_ctrl_change, 1);
        ck("F: fired nothing else", u_chk.v_total, 1);

        // ---- G: PWDATA moved during a write ACCESS -------------------------
        zap;
        tick(1,0,1, 32'h5C, 32'h1111_1111, 4'hF, 1, 0);
        tick(1,1,1, 32'h5C, 32'h1111_1111, 4'hF, 0, 0);
        tick(1,1,1, 32'h5C, 32'h2222_2222, 4'hF, 1, 0);   // write data moved
        idle; idle;
        $display("--- G: PWDATA moved in write ACCESS ---");
        ck("G: v_wdata_change", u_chk.v_wdata_change, 1);
        ck("G: fired nothing else", u_chk.v_total, 1);

        // ---- H: PENABLE held past PREADY -----------------------------------
        zap;
        tick(1,0,0, 32'h60, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h60, 32'h0, 4'hF, 1, 0);     // ACCESS completes
        tick(1,1,0, 32'h60, 32'h0, 4'hF, 1, 0);     // PENABLE never dropped
        idle; idle;
        $display("--- H: PENABLE held past PREADY ---");
        ck("H: v_penable_held", u_chk.v_penable_held, 1);
        ck("H: fired nothing else", u_chk.v_total, 1);
        ck("H: EXTEND_MAX=1 instance tolerates it", u_ext.v_total, 0);
        ck("H: and still reports the stretch", u_ext.n_ext_max, 1);

        // ---- K: two extension cycles, one more than declared ---------------
        zap;
        tick(1,0,0, 32'h68, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h68, 32'h0, 4'hF, 1, 0);     // ACCESS completes
        tick(1,1,0, 32'h68, 32'h0, 4'hF, 1, 0);     // extension 1 - declared
        tick(1,1,0, 32'h68, 32'h0, 4'hF, 1, 0);     // extension 2 - not
        idle; idle;
        $display("--- K: one extension cycle more than declared ---");
        ck("K: EXTEND_MAX=1 instance flags it", u_ext.v_penable_held, 1);
        ck("K: once, not per cycle", u_ext.v_total, 1);
        ck("K: stretch reported as 2", u_ext.n_ext_max, 2);
        ck("K: one access counted, not three", u_ext.n_access, 1);

        // ---- I: PSLVERR outside an ACCESS ----------------------------------
        zap;
        tick(0,0,0, 32'h0, 32'h0, 4'hF, 1, 1);      // error with no transfer
        idle; idle;
        $display("--- I: PSLVERR outside ACCESS ---");
        ck("I: v_slverr_no_access", u_chk.v_slverr_no_access, 1);
        ck("I: fired nothing else", u_chk.v_total, 1);

        // ---- J: PREADY stalled past MAX_WAIT -------------------------------
        // Measured on the MAX_WAIT=4 instance. The default instance must stay
        // clean on the same waveform, which also proves MAX_WAIT is honoured
        // rather than ignored.
        zap;
        tick(1,0,0, 32'h64, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h64, 32'h0, 4'hF, 0, 0);
        tick(1,1,0, 32'h64, 32'h0, 4'hF, 0, 0);
        tick(1,1,0, 32'h64, 32'h0, 4'hF, 0, 0);
        tick(1,1,0, 32'h64, 32'h0, 4'hF, 0, 0);
        tick(1,1,0, 32'h64, 32'h0, 4'hF, 0, 0);
        tick(1,1,0, 32'h64, 32'h0, 4'hF, 0, 0);
        tick(1,1,0, 32'h64, 32'h0, 4'hF, 1, 0);     // finally completes
        idle; idle;
        $display("--- J: PREADY stalled beyond MAX_WAIT ---");
        ck("J: v_wait_timeout (MAX_WAIT=4)", u_to.v_wait_timeout, 1);
        ck("J: one complaint, not one per cycle", u_to.v_total, 1);
        ck("J: default MAX_WAIT instance clean", u_chk.v_total, 0);

        // ---- M: another window's traffic must not be attributed to this one -
        // APB fans a SHARED PENABLE out to every slave. With this slave's PSEL
        // low, PENABLE rising and falling is some other window's access and
        // must register here as nothing at all: no violation AND no access.
        // The first bind of this checker into tb_ahb2apb got the second half
        // wrong -- windows 1 and 11 reported identical access counts -- so the
        // zero-access half of this check is the one that matters.
        zap;
        tick(0,0,0, 32'h70, 32'h0, 4'hF, 1, 0);
        tick(0,1,0, 32'h70, 32'h0, 4'hF, 1, 0);     // someone else's ACCESS
        tick(0,1,0, 32'h74, 32'h1234_5678, 4'h3, 0, 0);
        tick(0,1,0, 32'h74, 32'h1234_5678, 4'h3, 1, 0);
        tick(0,0,0, 32'h0, 32'h0, 4'hF, 1, 0);
        idle; idle;
        $display("--- M: a shared PENABLE belonging to another window ---");
        ck("M: no violations", u_chk.v_total, 0);
        ck("M: no accesses attributed here", u_chk.n_access, 0);
        ck("M: nothing counted as abandoned", u_chk.n_abandoned, 0);

        // ---- L: legal traffic must be silent -------------------------------
        // Deliberately the cases nearest the rules above: a read, a write with
        // wait states, two back-to-back accesses returning through SETUP, and a
        // PSLVERR inside a completed access.
        zap;
        // read, no wait states
        tick(1,0,0, 32'h00, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h00, 32'h0, 4'hF, 1, 0);
        idle;
        // write with two wait states
        tick(1,0,1, 32'h04, 32'hDEAD_BEEF, 4'hF, 1, 0);
        tick(1,1,1, 32'h04, 32'hDEAD_BEEF, 4'hF, 0, 0);
        tick(1,1,1, 32'h04, 32'hDEAD_BEEF, 4'hF, 0, 0);
        tick(1,1,1, 32'h04, 32'hDEAD_BEEF, 4'hF, 1, 0);
        idle;
        // back-to-back: PSEL stays high, PENABLE dips through SETUP
        tick(1,0,0, 32'h08, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h08, 32'h0, 4'hF, 1, 0);
        tick(1,0,0, 32'h0C, 32'h0, 4'hF, 1, 0);     // SETUP of the next access
        tick(1,1,0, 32'h0C, 32'h0, 4'hF, 1, 0);
        idle;
        // a legal error response, inside the access it describes
        tick(1,0,0, 32'h800, 32'h0, 4'hF, 1, 0);
        tick(1,1,0, 32'h800, 32'h0, 4'hF, 1, 1);
        idle; idle;
        $display("--- L: legal traffic ---");
        ck("L: violations, default instance", u_chk.v_total, 0);
        ck("L: violations, MAX_WAIT=4 instance", u_to.v_total, 0);
        ck("L: accesses actually observed", u_chk.n_access, 5);
        ck("L: writes observed", u_chk.n_write, 1);
        ck("L: PSLVERR responses observed", u_chk.n_slverr, 1);

        $display("");
        u_chk.report_result;
        $display("tb_apb_checker_selftest: checks=%0d FAIL=%0d", checks, fails);
        if (fails == 0) $display("RESULT: PASSED");
        else            $display("RESULT: FAILED");
        $finish;
    end

    initial begin
        #200000;
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
