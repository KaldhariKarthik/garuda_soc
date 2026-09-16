`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 16: CLIC - block-level testbench
//
// Covers GARUDA-CLIC-SPEC-001 Rev 2.0 Sec. 12 (Verification Plan).
//
// pclk IS GENERATED AS A REAL DIVIDE-BY-2 OF clk, EDGE-ALIGNED. Every other
// two-clock testbench in this project deliberately skews pclk to stress a
// crossing; this one must NOT. Sec. 5.1.1 establishes the two clocks as
// synchronous and integer-related and the CLIC instantiates no synchronisers on
// the strength of it. Driving an arbitrary phase here would be testing a
// configuration the silicon does not have, and would report failures that mean
// nothing - while hiding the real question, which is whether the block works
// when the clocks ARE related. Block 22 is what guarantees that relationship,
// and tb_crg.sv is where it is verified.
//
// Plusargs
//   +VERBOSE   print every check
// =============================================================================

module tb_clic;

    localparam integer CLIC_N = 32;

    // -----------------------------------------------------------------------
    // Clocks: pclk is a true divide-by-2 of clk (see header)
    // -----------------------------------------------------------------------
    reg clk = 1'b0;
    always #2.5 clk = ~clk;                   // 200 MHz

    reg pclk = 1'b0;
    always @(posedge clk) pclk <= ~pclk;      // 100 MHz, edge-aligned

    reg rst_n    = 1'b0;
    reg preset_n = 1'b0;

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
                $display("[FAIL] %0s : got %0d expected %0d   (t=%0t)",
                         msg, got, exp, $time);
            end else if (verbose) $display("[ ok ] %0s = %0d", msg, got);
        end
    endtask

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    reg         psel, penable, pwrite;
    reg  [11:0] paddr;
    reg  [31:0] pwdata;
    wire [31:0] prdata;
    wire        pready, pslverr;

    reg  [CLIC_N-1:0] irq_src;

    wire        clic_irq;
    wire [11:0] clic_irq_id;
    wire [7:0]  clic_irq_lvl;
    wire        clic_irq_shv;
    reg         clic_irq_ack;
    reg  [11:0] clic_irq_id_ack;
    reg  [7:0]  mintthresh;

    clic_top #(.CLIC_N(CLIC_N), .ID_W(5)) dut (
        .clk_i(clk), .rst_n_i(rst_n), .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata),
        .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr),
        .irq_src_i(irq_src),
        .clic_irq_o(clic_irq), .clic_irq_id_o(clic_irq_id),
        .clic_irq_lvl_o(clic_irq_lvl), .clic_irq_shv_o(clic_irq_shv),
        .clic_irq_ack_i(clic_irq_ack), .clic_irq_id_ack_i(clic_irq_id_ack),
        .mintthresh_i(mintthresh));

    // -----------------------------------------------------------------------
    // Register offsets (Sec. 6.1)
    // -----------------------------------------------------------------------
    function [11:0] off_ip;   input integer i; begin off_ip   = 12'h000 + i[11:0]; end endfunction
    function [11:0] off_ie;   input integer i; begin off_ie   = 12'h400 + i[11:0]; end endfunction
    function [11:0] off_attr; input integer i; begin off_attr = 12'h800 + i[11:0]; end endfunction
    function [11:0] off_ctl;  input integer i; begin off_ctl  = 12'hC00 + i[11:0]; end endfunction

    // -----------------------------------------------------------------------
    // APB v3 two-phase access
    // -----------------------------------------------------------------------
    task apb_write;
        input [11:0] a;
        input [31:0] d;
        begin
            @(posedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1; paddr = a; pwdata = d;
            @(posedge pclk);
            penable = 1'b1;                    // ACCESS
            @(posedge pclk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
        end
    endtask

    task apb_read;
        input  [11:0] a;
        output [31:0] d;
        begin
            @(posedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b0; paddr = a;
            @(posedge pclk);
            penable = 1'b1;
            #1 d = prdata;                     // settled in ACCESS
            @(posedge pclk);
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    // Program one source: enable it, set its level, set its attributes.
    task prog_src;
        input integer id;
        input [2:0]   level;
        input         edge_trig;
        input         shv;
        begin
            apb_write(off_ctl(id),  {24'b0, level, 5'b0});   // LEVEL in [7:5]
            apb_write(off_attr(id), {30'b0, shv, edge_trig});
            apb_write(off_ie(id),   32'h1);
        end
    endtask

    task pulse_ack;
        input integer id;
        begin
            @(posedge clk);
            clic_irq_ack    = 1'b1;
            clic_irq_id_ack = id[11:0];
            @(posedge clk);
            clic_irq_ack    = 1'b0;
            clic_irq_id_ack = 12'd0;
        end
    endtask

    reg [31:0] rd;
    integer    t_start, t_irq;

    initial begin
        verbose = $test$plusargs("VERBOSE");
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        irq_src = {CLIC_N{1'b0}};
        clic_irq_ack = 0; clic_irq_id_ack = 0; mintthresh = 8'd0;

        $display("======================================================");
        $display("GARUDA CLIC (Block 16) block-level testbench");
        $display("======================================================");

        repeat (4) @(posedge clk);
        rst_n = 1'b1; preset_n = 1'b1;
        repeat (4) @(posedge pclk);

        // ===================================================================
        // T1 - reset posture (Sec. 11)
        //
        // Every enable low and every level 0, so nothing can interrupt until
        // firmware opts sources in. This is the correct boot posture and it is
        // what lets a bootloader run without masking interrupts by hand.
        // ===================================================================
        chk(clic_irq === 1'b0, "T1 no interrupt presented out of reset");
        apb_read(off_ie(3), rd);
        chk_eq(rd, 32'h0, "T1 clicintie resets to 0");
        apb_read(off_ctl(3), rd);
        chk_eq(rd, 32'h0, "T1 clicintctl resets to 0");

        // ===================================================================
        // T2 - register access and PSLVERR on an undefined index (Sec. 5.3)
        // ===================================================================
        apb_write(off_ctl(5), {24'b0, 3'd6, 5'b0});
        apb_read (off_ctl(5), rd);
        chk_eq(rd[7:5], 3'd6, "T2 clicintctl LEVEL reads back in [7:5]");

        apb_write(off_attr(5), 32'h3);
        apb_read (off_attr(5), rd);
        chk_eq(rd[1:0], 2'b11, "T2 clicintattr TRIG and SHV read back");

        @(posedge pclk);
        psel = 1'b1; penable = 1'b1; pwrite = 1'b0; paddr = off_ie(CLIC_N + 4);
        #1 chk(pslverr === 1'b1, "T2 PSLVERR on an index beyond CLIC_N");
        @(posedge pclk);
        psel = 0; penable = 0;

        apb_write(off_ie(CLIC_N + 4), 32'h1);      // must be ignored, not alias
        apb_read (off_ie(4), rd);
        chk_eq(rd, 32'h0, "T2 out-of-range write did not alias onto a real source");

        // ===================================================================
        // T3 - a level-0 source NEVER interrupts, whatever its enable
        // (Sec. 6.5, Sec. 7.1)
        // ===================================================================
        apb_write(off_ie(7),  32'h1);
        apb_write(off_ctl(7), 32'h0);              // level 0
        irq_src[7] = 1'b1;
        repeat (4) @(posedge clk);
        chk(clic_irq === 1'b0, "T3 level-0 source does not interrupt even when enabled");
        irq_src[7] = 1'b0;
        apb_write(off_ie(7), 32'h0);
        repeat (4) @(posedge clk);

        // ===================================================================
        // T4 - single source, latency, and the take condition
        // ===================================================================
        prog_src(3, 3'd4, 1'b0, 1'b0);
        mintthresh = 8'd0;
        repeat (4) @(posedge clk);

        // Latency, stated precisely (Sec. 9.1).
        //
        // Sec. 9.1 budgets ONE clk from "source pending" to clic_irq, and that
        // is what the RTL does - but "pending" is itself a registered value, so
        // from the SOURCE LINE rising it is two edges:
        //     edge 1  clic_source_cond registers ip
        //     edge 2  the winner register captures id/level; clic_irq follows
        //             combinationally from the registered level vs mintthresh
        // An earlier revision of this testbench sampled after one edge and
        // reported a failure against correct RTL.
        @(posedge clk);
        t_start = $time;
        irq_src[3] = 1'b1;
        @(posedge clk);                            // ip registers
        @(posedge clk);                            // winner registers -> irq
        #1;
        chk(clic_irq === 1'b1, "T4 clic_irq asserted 1 clk after pending (2 from the line)");
        chk_eq(clic_irq_id,  12'd3, "T4 presented id is the pending source");
        chk_eq(clic_irq_lvl,  8'd4, "T4 presented level is the source's level");

        // ===================================================================
        // T5 - STRICTLY greater than threshold (Sec. 1.4, Sec. 10.3)
        //
        // A source at exactly the threshold must NOT interrupt. Getting this
        // wrong as >= also breaks the nesting-depth bound the stack budget is
        // sized against.
        // ===================================================================
        mintthresh = 8'd4;                         // equal to the source level
        #1;
        chk(clic_irq === 1'b0, "T5 source at EXACTLY the threshold does not interrupt");
        mintthresh = 8'd3;
        #1;
        chk(clic_irq === 1'b1, "T5 source above the threshold does interrupt");

        // The request is COMBINATIONAL in mintthresh (Sec. 7.3): the change
        // takes effect in the same cycle, not the next one.
        mintthresh = 8'd7;
        #1;
        chk(clic_irq === 1'b0, "T5 threshold change masks in the SAME cycle (comb.)");
        mintthresh = 8'd0;
        #1;
        chk(clic_irq === 1'b1, "T5 threshold change unmasks in the SAME cycle");

        // ===================================================================
        // T6 - priority: highest level wins, lowest id breaks a tie (Sec. 7.1)
        // ===================================================================
        prog_src(9,  3'd6, 1'b0, 1'b0);
        prog_src(11, 3'd6, 1'b0, 1'b0);            // same level as 9
        prog_src(15, 3'd7, 1'b0, 1'b0);            // highest level

        irq_src[9] = 1'b1;  irq_src[11] = 1'b1;
        repeat (3) @(posedge clk); #1;
        chk_eq(clic_irq_id, 12'd9,
               "T6 level tie broken by LOWEST id (9 beats 11)");

        irq_src[15] = 1'b1;
        repeat (3) @(posedge clk); #1;
        chk_eq(clic_irq_id, 12'd15, "T6 strictly higher level wins (15 beats 9)");
        chk_eq(clic_irq_lvl, 8'd7,  "T6 presented level follows the winner");

        // ===================================================================
        // T7 - acknowledge clears EXACTLY one source (Sec. 1.4 - NORMATIVE)
        // ===================================================================
        apb_read(off_ip(9), rd);
        chk_eq(rd[0], 1'b1, "T7 source 9 is pending before the ack");

        // The source must be cleared AT ITS ORIGIN before the acknowledge, the
        // way a real ISR does it (Sec. 10.4). Acknowledging a level source
        // whose line is still high re-asserts pending on the next cycle and it
        // simply wins again - which is correct behaviour, and is exactly what
        // T8 below goes on to verify deliberately.
        irq_src[15] = 1'b0;
        repeat (2) @(posedge clk);
        pulse_ack(15);
        repeat (3) @(posedge clk);

        apb_read(off_ip(9), rd);
        chk_eq(rd[0], 1'b1, "T7 ack for id 15 did NOT disturb source 9");
        #1;
        chk_eq(clic_irq_id, 12'd9, "T7 next winner is presented after the ack");

        // ===================================================================
        // T8 - LEVEL RE-FIRE (Sec. 8.4) - the one that catches the classic bug
        //
        // The line is still high, so pending must come back on the next cycle.
        // Only clearing the SOURCE stops it. This is why every ISR must clear
        // at the peripheral before mret.
        // ===================================================================
        pulse_ack(9);
        repeat (2) @(posedge clk);
        apb_read(off_ip(9), rd);
        chk_eq(rd[0], 1'b1,
               "T8 level source RE-ASSERTS pending after ack while its line is high");

        irq_src[9] = 1'b0;                         // clear at the source
        repeat (3) @(posedge clk);
        pulse_ack(9);
        repeat (2) @(posedge clk);
        apb_read(off_ip(9), rd);
        chk_eq(rd[0], 1'b0,
               "T8 pending stays low once the source line is cleared");

        // ===================================================================
        // T9 - edge sources latch once and do not re-fire (Sec. 8.4)
        // ===================================================================
        irq_src[11] = 1'b0; irq_src[15] = 1'b0;
        repeat (3) @(posedge clk);
        prog_src(20, 3'd5, 1'b1, 1'b0);            // edge-triggered

        @(posedge clk);
        irq_src[20] = 1'b1;                        // one pulse
        @(posedge clk);
        irq_src[20] = 1'b0;
        repeat (3) @(posedge clk);
        apb_read(off_ip(20), rd);
        chk_eq(rd[0], 1'b1, "T9 edge source latched pending from a single pulse");

        pulse_ack(20);
        repeat (3) @(posedge clk);
        apb_read(off_ip(20), rd);
        chk_eq(rd[0], 1'b0, "T9 edge source does NOT re-fire after ack without a new edge");

        // ===================================================================
        // T10 - W1C on clicintip clears an edge-latched pending (Sec. 6.3)
        // ===================================================================
        @(posedge clk);
        irq_src[20] = 1'b1;
        @(posedge clk);
        irq_src[20] = 1'b0;
        repeat (3) @(posedge clk);
        apb_read(off_ip(20), rd);
        chk_eq(rd[0], 1'b1, "T10 edge source pending again after a new edge");

        apb_write(off_ip(20), 32'h1);              // W1C
        repeat (3) @(posedge clk);
        apb_read(off_ip(20), rd);
        chk_eq(rd[0], 1'b0, "T10 W1C cleared the edge-latched pending");

        // ===================================================================
        // T11 - selective hardware vectoring is presented per source (Sec. 8.6)
        // ===================================================================
        prog_src(12, 3'd5, 1'b0, 1'b1);            // shv = 1
        irq_src[12] = 1'b1;
        repeat (3) @(posedge clk); #1;
        chk_eq(clic_irq_id, 12'd12, "T11 shv source is the winner");
        chk(clic_irq_shv === 1'b1, "T11 shv presented high for a vectored source");

        irq_src[12] = 1'b0;
        repeat (2) @(posedge clk);
        pulse_ack(12);
        prog_src(13, 3'd5, 1'b0, 1'b0);            // shv = 0
        irq_src[13] = 1'b1;
        repeat (3) @(posedge clk); #1;
        chk(clic_irq_shv === 1'b0, "T11 shv presented low for a software-dispatched source");

        // ===================================================================
        // T12 - configuration written on pclk is honoured within one clk
        // (Sec. 5.1.1, Sec. 12 "Config/clock boundary")
        // ===================================================================
        // Clear EVERY source first. Source 3 has been held high since T4 at
        // level 4, so it outranks the level-2 source programmed below and would
        // keep clic_irq asserted no matter what happened to source 6 - which is
        // correct arbitration, and made an earlier revision of this test look
        // like an enable failure.
        irq_src = {CLIC_N{1'b0}};
        repeat (4) @(posedge clk);
        pulse_ack(13);
        repeat (4) @(posedge clk); #1;
        chk(clic_irq === 1'b0, "T12 no request once every source line is low");

        prog_src(6, 3'd2, 1'b0, 1'b0);
        irq_src[6] = 1'b1;
        repeat (4) @(posedge clk); #1;
        chk(clic_irq === 1'b1, "T12 source interrupts after being enabled over APB");

        apb_write(off_ie(6), 32'h0);               // disable it again
        repeat (4) @(posedge clk); #1;
        chk(clic_irq === 1'b0, "T12 disabling over APB removes the request");

        // ===================================================================
        // Summary
        // ===================================================================
        $display("======================================================");
        $display("tb_clic: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %0s", (fails == 0) ? "PASSED" : "FAILED");
        $display("======================================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("[FAIL] tb_clic: TIMEOUT");
        $display("RESULT: FAILED");
        $finish;
    end

endmodule
