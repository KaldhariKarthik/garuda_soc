//mac_unit.v
//one mac : 16x16 signed multiply, 48 bit accumulator, 2-cycle pipeline.
//supports MAC_SEL, MACSUB, MACABS, MACDOT, MACCLEAR, MACLOAD, MACSAT.
//MACREAD_LO/HI/SHIFT do not engage this unit - they consume mac_out externally.

`timescale 1ns / 1ps

module mac_unit(
    input wire         clk,
    input wire         rst_n,
    
    input wire  [31:0] rs1,
    input wire  [31:0] rs2,
    
    input wire         en,
    input wire         add_sub,
    input wire         clear,
    input wire         load,
    input wire         abs_en,
    input wire         dot_en,
    input wire         flush,
    
    input wire  [47:0] sat_writeback,
    input wire         sat_writeback_en,
    
    output wire [47:0] mac_out,        
    output wire        overflow
);

    wire [15:0] a0, b0, a1, b1;
    operand_router u_router (
        .rs1 (rs1),
        .rs2 (rs2),
        .abs_en (abs_en),
        .dot_en (dot_en),
        .a0 (a0),
        .b0 (b0),
        .a1 (a1),
        .b1 (b1)        
    );       
    
    wire signed [31:0] product_a, product_b;
    // ERRATUM DSU-10 -- the $signed() casts that used to wrap these four
    // actuals are removed. They were semantic no-ops: mult_16x16 declares its
    // ports as "input wire signed [15:0]", and the signedness of a port
    // connection is governed by the FORMAL, not the actual, so the multiply was
    // already signed with or without them. They were not harmless, though --
    // Yosys 0.69 aborts on them with an internal assertion failure
    // (arg->is_signed == sig.as_wire()->is_signed, genrtlil.cc:2145), which
    // blocked synthesis of the DSU and therefore of the whole SoC. Icarus and
    // Verilator both accept the casts, which is why this stayed invisible until
    // the first full-SoC synthesis run.
    mult_16x16 U_mult_a (.a (a0),  .b (b0), .p (product_a));
    mult_16x16 U_mult_b (.a (a1),  .b (b1), .p (product_b));
    
    // -----------------------------------------------------------------------
    // ERRATUM OVF-1 (Docs/ORACLES.md; closes OPEN-9) -- overflow flag wrong
    // for |acc| >= 2^46
    // -----------------------------------------------------------------------
    // The carry-save path was 48 bits wide and the 49-bit adder was fed
    // SIGN-EXTENDED csa sum and carry. A carry-save pair is not two signed
    // numbers: csa_3to2 shifts the majority left and drops maj[47], so the pair
    // reconstructs the true value only modulo 2^48, and bit 48 of the adder
    // carried no sign information. The low 48 bits (the accumulator value)
    // were always right; the overflow flag was wrong for about half of all
    // accumulates in the top quarter of the range.
    //
    // Fix: run the whole carry-save path one bit wider. Every operand is
    // sign-extended to 49 bits BEFORE compression, so the pair reconstructs
    // (acc + P) exactly modulo 2^49. |acc| < 2^47 and |P| < 2^34, so the true
    // sum always fits a 49-bit signed value, and result[48] ^ result[47] is
    // exactly signed overflow of the 48-bit accumulator. No carry-propagate
    // logic is added to stage 1; the CSA/Kogge-Stone structure is unchanged
    // apart from one bit of width.
    // -----------------------------------------------------------------------
    wire [48:0] pa_ext = {{17{product_a[31]}}, product_a};
    wire [48:0] pb_ext = {{17{product_b[31]}}, product_b};
    
    wire [48:0] pa_eff = pa_ext ^ {49{add_sub}};
    wire [48:0] pb_eff = pb_ext ^ {49{add_sub}};
    wire [48:0] sub_k = {47'b0, add_sub , 1'b0};
    
    wire [48:0] csa1_sum, csa1_carry;
    csa_3to2 #(.WIDTH(49)) u_csa1 (
        .a (pa_eff),
        .b (pb_eff),
        .c (sub_k),
        .sum (csa1_sum),
        .carry (csa1_carry)
    );
    
    reg [48:0] sum_reg, carry_reg;
    wire write_en = (en | sat_writeback_en) & ~flush;

    // -----------------------------------------------------------------------
    // ERRATUM DSU-2 (FLAG-A) -- pending-product poisoning
    // -----------------------------------------------------------------------
    // sum_reg/carry_reg were gated by write_en, which is also the accumulator's
    // write enable. MACLOAD, MACCLEAR and MACSAT all assert it, so each of them
    // latched the CSA1 output - the product of its own rs1/rs2 fields, which
    // are architecturally meaningless for those ops - into the pending-product
    // registers. The next accumulate to that accumulator then added that
    // garbage in. DSU_Golden.py records the symptom: "GOT FY = 63, EXPECTED 0
    // (63 = 7x9)", the operand fields of a clear.
    //
    // It was masked only because DSU_gen.py drives rs1=rs2=0 for clear/load.
    // Real APF kernel code has no reason to.
    //
    // Two separate obligations, previously conflated:
    //   prod_en  - only a genuine multiply may latch a new pending product.
    //   pend_clr - clear/load/saturate REPLACE the accumulator outright, so any
    //              pending product is now stale and must be discarded too.
    //              Holding it would let a product from before a MACCLEAR land
    //              in the accumulator after it, which is the same bug wearing
    //              a different hat.
    // -----------------------------------------------------------------------
    wire prod_en  =  en & ~clear & ~load & ~sat_writeback_en & ~flush;
    wire pend_clr = (clear | load | sat_writeback_en) & ~flush;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_reg   <= 49'b0;
            carry_reg <= 49'b0;
        end
        else if (flush) begin
            sum_reg   <= 49'b0;
            carry_reg <= 49'b0;
        end
        else if (pend_clr) begin
            sum_reg   <= 49'b0;
            carry_reg <= 49'b0;
        end
        else if (prod_en) begin
            sum_reg   <= csa1_sum;
            carry_reg <= csa1_carry;
        end
    end
    
    reg signed [47:0] acc;
    wire [48:0] csa2_sum, csa2_carry;
    csa_3to2 #(.WIDTH(49)) u_csa2(
        .a ({acc[47], acc}),                  // sign-extended to 49 (OVF-1)
        .b (sum_reg),
        .c (carry_reg),
        .sum (csa2_sum),
        .carry (csa2_carry)
    );
    // csa2 is 49 bits wide: its sum/carry feed the adder directly (OVF-1).
    wire [48:0] result_ext;
    kogge_stone_49 u_ks (
        .a (csa2_sum),
        .b (csa2_carry),
        .cin (1'b0),
        .sum (result_ext)
    );
    
    wire [47:0] adder_result = result_ext[47:0];
    wire        accum_ovf    = result_ext[48] ^ result_ext[47]; 
    
    wire signed [47:0] rs1_sext = {{16{rs1[31]}}, rs1};
    reg  signed [47:0] acc_next;
    always @(*) begin
        if      (sat_writeback_en) acc_next = sat_writeback;
        else if (load)             acc_next = rs1_sext;
        else if (clear)            acc_next = 48'b0;
        else                       acc_next = adder_result;    
    end
    
    
    // -----------------------------------------------------------------------
    // ERRATUM DSU-4 -- the second pipeline stage did not self-drain
    // -----------------------------------------------------------------------
    // acc was written only when write_en was asserted, i.e. only when a NEW
    // instruction arrived for this accumulator. But the multiply is a two-stage
    // pipeline: stage 1 latches the product into sum_reg/carry_reg, stage 2
    // (CSA2 + Kogge-Stone) is supposed to fold it into acc on the following
    // cycle. With no instruction on that following cycle, stage 2 never
    // clocked and the product sat in sum_reg/carry_reg indefinitely - the
    // "stranded final product" in the DSU plan's Open Questions row 4, and the
    // real reason dsu_flag2.S read 0 rather than 15. The FLAG-C interlock
    // (DSU-3) alone cannot fix it: stalling one cycle does not help when the
    // commit needs an instruction that never comes.
    //
    // `pending` makes stage 2 drain itself: a product latched this cycle is
    // committed on the next, instruction or no instruction. Back-to-back
    // computes still chain correctly - each cycle commits the previous product
    // while latching a new one, which is what a two-stage pipeline should do.
    //
    // FLAG-B is preserved: flush clears the PENDING product but leaves acc
    // intact, because a trap must not destroy committed accumulator state.
    // -----------------------------------------------------------------------
    reg pending;
    always @(posedge clk or negedge rst_n) begin
        if      (!rst_n) pending <= 1'b0;
        else if (flush)  pending <= 1'b0;
        else             pending <= prod_en;
    end

    wire acc_we = (sat_writeback_en | ((load | clear) & en) | pending) & ~flush;

    always @(posedge clk or negedge rst_n) begin
        if      (!rst_n) acc <= 48'b0;
        else if (acc_we) acc <= acc_next;
    end
    assign mac_out = acc;
    
    wire is_accum = ~(load | clear | sat_writeback_en);

    // ERRATUM DSU-4 (continued): overflow must be reported on the cycle the
    // accumulate actually COMMITS, which is now `pending`, not on the cycle an
    // instruction happens to arrive (`write_en`). Leaving it on write_en after
    // making stage 2 self-draining split the two apart: the fold that
    // overflows can now happen on a cycle with no instruction present, and
    // conversely an arriving instruction no longer implies a fold. Caught by
    // tb_dsu_top as a sticky-overflow mismatch against DSUModel.
    assign overflow = accum_ovf & pending & ~flush & is_accum;
    
endmodule
