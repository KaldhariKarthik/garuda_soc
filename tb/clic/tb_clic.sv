`timescale 1ns/1ps
// =============================================================================
// tb_clic.sv -- Block 10 CLIC, Rev 4.0 smoke
//
// Spec: GARUDA-CLIC-SPEC-001 §11. Directed register checks plus a randomised
// selection check against a reference model:
//   CLICINFO, reset state all-disabled/level-0 (R-4, [N-9.2])
//   CLICIE bits 0/13/14/23-31 hardwired zero ([N-6.2], [N-6.3])
//   CLICIP combinational and read-only ([N-6.4])
//   highest level wins, lowest ID breaks ties ([N-7.5]), valid ignores level
//   level change while pending keeps pending (R-8)
//   PSLVERR on unmapped offsets
// =============================================================================
module tb_clic;
    reg hclk = 0, pclk = 0;
    always #2 hclk = ~hclk;
    always @(posedge hclk) pclk <= ~pclk;         // pclk = hclk/2, shared edges
    reg rst_n = 0;

    reg        psel = 0, penable = 0, pwrite = 0;
    reg [11:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire        pready, pslverr;
    reg  [31:0] src = 0;
    wire        valid;
    wire [4:0]  id;
    wire [7:0]  level;

    clic_top dut (
        .hclk_i(hclk), .hreset_n_i(rst_n), .pclk_i(pclk), .preset_n_i(rst_n),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
        .pwdata_i(pwdata), .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr),
        .irq_src_i(src), .clic_irq_valid_o(valid), .clic_irq_id_o(id),
        .clic_irq_level_o(level));

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    task automatic wr(input [11:0] a, input [31:0] d);
        @(posedge pclk); #0.1 psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
        @(posedge pclk); #0.1 penable = 1;
        @(posedge pclk); #0.1 psel = 0; penable = 0; pwrite = 0;
    endtask
    task automatic rd(input [11:0] a, output [31:0] d, output bit err);
        @(posedge pclk); #0.1 psel = 1; pwrite = 0; paddr = a; penable = 0;
        @(posedge pclk); #0.1 penable = 1; #0.5 d = prdata; err = pslverr;
        @(posedge pclk); #0.1 psel = 0; penable = 0;
    endtask

    // reference model
    reg [31:0] m_ie;
    reg [7:0]  m_lvl [0:31];
    task automatic model(output bit v, output [4:0] mid, output [7:0] ml);
        v = 0; mid = 0; ml = 0;
        for (int n = 0; n < 32; n++)
            if (src[n] && m_ie[n] && (!v || m_lvl[n] > ml)) begin v = 1; mid = n; ml = m_lvl[n]; end
    endtask

    reg [31:0] d; bit e, mv; reg [4:0] mid; reg [7:0] ml;
    int i, bad;
    reg [31:0] rng = 32'hC11C_0001;
    function automatic [31:0] rnd(); rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; endfunction

    initial begin
        $display("=== tb_clic: Block 10 Rev 4.0 ===");
        repeat (4) @(posedge hclk); rst_n = 1;

        rd(12'h000, d, e);
        check(d[12:0] == 32 && d[20:13] == 1 && d[24:21] == 8, "CLICINFO = {32 IDs, v1, 8 level bits}");
        rd(12'h004, d, e); check(d == 0, "R-4: CLICIE resets to 0");
        rd(12'h104, d, e); check(d == 0, "CLICINTCFG resets to 0");

        wr(12'h004, 32'hFFFF_FFFF);
        rd(12'h004, d, e);
        check(d == 32'h007F_9FFE, "[N-6.2]/[N-6.3]: IE bits 0, 13, 14, 23-31 hardwired 0");

        src = 32'h0000_0402; #1;
        rd(12'h008, d, e);
        check(d == 32'h0000_0402, "[N-6.4]: CLICIP mirrors the source lines");
        wr(12'h008, 32'h0);
        rd(12'h008, d, e);
        check(d == 32'h0000_0402, "CLICIP ignores writes");

        // level 0 everywhere: valid but never takeable
        #1 check(valid && level == 0 && id == 1, "[N-7.8]: valid with level 0; lowest ID presented");

        // highest level wins
        wr(12'h100 + 4*1, 8'd50); wr(12'h100 + 4*10, 8'd200);
        #1 check(valid && id == 10 && level == 200, "[N-7.5]: highest level wins (ID 10 @ 200)");
        // tie -> lowest id
        wr(12'h100 + 4*1, 8'd200);
        #1 check(id == 1 && level == 200, "[N-7.5]: equal level, lowest ID wins");
        // R-8: level change while pending
        wr(12'h100 + 4*1, 8'd10);
        #1 check(id == 10 && dut.irq_src_i[1], "R-8: level changed while pending; pending kept");
        // disable -> falls to next
        wr(12'h004, 32'h0000_0002);
        #1 check(id == 1 && level == 10, "disabling ID 10 hands selection to ID 1");
        src = 0; #1 check(!valid && id == 0, "nothing pending -> valid low, ID reads 0 ([N-7.13])");

        rd(12'h00C, d, e); check(e, "PSLVERR on unmapped offset 0x00C");
        rd(12'h180, d, e); check(e, "PSLVERR beyond CLICINTCFG[31]");

        // random selection vs model
        // start the model and the DUT from the same state
        m_ie = 0; wr(12'h004, 0);
        for (i = 0; i < 32; i++) begin m_lvl[i] = 0; wr(12'h100 + 4*i, 0); end
        bad = 0;
        for (i = 0; i < 300; i++) begin
            int n;
            n = rnd() % 32;
            case (rnd() % 3)
                0: begin m_ie = rnd() & 32'h007F_9FFE; wr(12'h004, m_ie); end
                1: begin m_lvl[n] = rnd(); wr(12'h100 + 4*n, m_lvl[n]); end
                default: ;
            endcase
            src = rnd() & 32'hFFFF_FFFE;
            #1 model(mv, mid, ml);
            if (valid !== mv || (mv && (id !== mid || level !== ml))) begin
                bad++;
                if (bad <= 3) $display("  mismatch: src=%h ie=%h rtl={%b,%0d,%0d} model={%b,%0d,%0d} lvl[rtl id]=%0d",
                                       src, m_ie, valid, id, level, mv, mid, ml, m_lvl[id]);
            end
        end
        check(bad == 0, $sformatf("random selection vs reference model: %0d/300 mismatches", bad));

        $display("tb_clic: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
endmodule
