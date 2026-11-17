//mac_unit.v
//one mac : 16x16 signed multiply, 48 bit accumulator, 2-cycle pipeline.
//supports MAC_SEL, MACSUB, MACABS, MACDOT, MACCLEAR, MACLOAD, MACSAT.
//MACREAD_LO/HI/SHIFT do not engage this unit - they consume mac_out externally.

module mac_unit
    import garuda_pkg::*;
(
    input wire gclk,
    input wire core_rst_n,
    input wire [WORD_W-1:0] rs1_val,
    input wire [WORD_W-1:0] rs2_val,
    input wire en,
    input wire add_sub,
    input wire clear,
    input wire load,
    input wire abs_en,
    input wire dot_en,
    input wire flush,
    input wire [ACC_W-1:0] sat_writeback,
    input wire sat_writeback_en,
    output wire [ACC_W-1:0] mac_out,
    output wire overflow,
    // a product folds into acc this cycle (DSU-14 interlock)
    output wire pending_o
);
    timeunit 1ns;
    timeprecision 1ps;

    wire [HALF_W-1:0] a_lo;
    wire [HALF_W-1:0] b_lo;
    wire [HALF_W-1:0] a_hi;
    wire [HALF_W-1:0] b_hi;
    operand_router u_router (
        .rs1_val (rs1_val),
        .rs2_val (rs2_val),
        .abs_en (abs_en),
        .dot_en (dot_en),
        .a_lo (a_lo),
        .b_lo (b_lo),
        .a_hi (a_hi),
        .b_hi (b_hi)
    );

    wire signed [WORD_W-1:0] product_a;
    wire signed [WORD_W-1:0] product_b;
    // ERRATUM DSU-10 -- the $signed() casts that used to wrap these four
    // actuals are removed. They were semantic no-ops: mult_16x16 declares its
    // ports as "input wire signed [15:0]", and the signedness of a port
    // connection is governed by the FORMAL, not the actual, so the multiply was
    // already signed with or without them. They were not harmless, though --
    // Yosys 0.69 aborts on them with an internal assertion failure
    // (arg->is_signed == sig.as_wire()->is_signed, genrtlil.cc:2145), which
    // blocked synthesis of the DSU and therefore of the whole SoC. Both Icarus
    // and Verilator accept the casts, which is why this stayed invisible until
    // the first full-SoC synthesis run.
    //
    // (Keep "Verilator" off the START of a comment line here. Verilator reads
    //  a comment whose first word is its own name as a lint pragma, so the
    //  previous wrapping of this paragraph made it report
    //  BADVLTPRAGMA "Unknown verilator comment" and ABORT -- which blocked
    //  whole-chip lint entirely, on a prose comment.)
    mult_16x16 u_mult_a (.a (a_lo),  .b (b_lo), .p (product_a));
    mult_16x16 u_mult_b (.a (a_hi),  .b (b_hi), .p (product_b));

    // -----------------------------------------------------------------------
    // ERRATUM OVF-1 (Docs/guides/ORACLES.md; closes OPEN-9) -- overflow flag
    // wrong for |acc| >= 2^46
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
    wire [ACC_W:0] pa_ext = {{17{product_a[31]}}, product_a};
    wire [ACC_W:0] pb_ext = {{17{product_b[31]}}, product_b};

    wire [ACC_W:0] pa_eff = pa_ext ^ {49{add_sub}};
    wire [ACC_W:0] pb_eff = pb_ext ^ {49{add_sub}};
    wire [ACC_W:0] sub_k
        = {47'b00000000000000000000000000000000000000000000000, add_sub, 1'b0};

    wire [ACC_W:0] csa1_sum;
    wire [ACC_W:0] csa1_carry;
    csa_3to2 #(.WIDTH(49)) u_csa1 (
        .a (pa_eff),
        .b (pb_eff),
        .c (sub_k),
        .sum (csa1_sum),
        .carry (csa1_carry)
    );

    reg [ACC_W:0] sum_reg;
    reg [ACC_W:0] carry_reg;
    wire write_en = (en | sat_writeback_en) & ~flush;

    // -----------------------------------------------------------------------
    // ERRATUM DSU-2 (FLAG-A) -- pending-product poisoning
    // -----------------------------------------------------------------------
    // sum_reg/carry_reg were gated by write_en, which is also the accumulator's
    // write enable. MACLOAD, MACCLEAR and MACSAT all assert it, so each of them
    // latched the CSA1 output - the product of its own rs1_val/rs2_val fields,
    // which are architecturally meaningless for those ops - into the
    // pending-product registers. The next accumulate to that accumulator then
    // added that garbage in. DSU_Golden.py records the symptom: "GOT FY = 63,
    // EXPECTED 0 (63 = 7x9)", the operand fields of a clear.
    //
    // It was masked only because DSU_gen.py drives rs1_val=rs2_val=0 for
    // clear/load. Real APF kernel code has no reason to.
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

    always_ff @(posedge gclk or negedge core_rst_n) begin : p_sum
        if (!core_rst_n) begin
            sum_reg <= 49'b0000000000000000000000000000000000000000000000000;
            carry_reg <= 49'b0000000000000000000000000000000000000000000000000;
        end else if (flush) begin
            sum_reg <= 49'b0000000000000000000000000000000000000000000000000;
            carry_reg <= 49'b0000000000000000000000000000000000000000000000000;
        end else if (pend_clr) begin
            sum_reg <= 49'b0000000000000000000000000000000000000000000000000;
            carry_reg <= 49'b0000000000000000000000000000000000000000000000000;
        end else if (prod_en) begin
            sum_reg <= csa1_sum;
            carry_reg <= csa1_carry;
        end
    end

    reg signed [ACC_W-1:0] acc;
    wire [ACC_W:0] csa2_sum;
    wire [ACC_W:0] csa2_carry;
    csa_3to2 #(.WIDTH(49)) u_csa2(
        .a ({acc[47], acc}),  // sign-extended to 49 (OVF-1)
        .b (sum_reg),
        .c (carry_reg),
        .sum (csa2_sum),
        .carry (csa2_carry)
    );
    // csa2 is 49 bits wide: its sum/carry feed the adder directly (OVF-1).
    wire [ACC_W:0] result_ext;
    kogge_stone_49 u_ks (
        .a (csa2_sum),
        .b (csa2_carry),
        .cin (1'b0),
        .sum (result_ext)
    );

    wire [ACC_W-1:0] adder_result = result_ext[47:0];
    wire        accum_ovf    = result_ext[48] ^ result_ext[47];

    wire signed [ACC_W-1:0] rs1_sext = {{16{rs1_val[31]}}, rs1_val};
    reg  signed [ACC_W-1:0] acc_next;

    // -----------------------------------------------------------------------
    // ERRATUM DSU-11 (proposed; found by sw/tests/t_dsu_b2b.S bits 0/1)
    // -----------------------------------------------------------------------
    // `load` and `clear` are the cluster-wide decode of the instruction in EX;
    // only `en` says whether that instruction addresses THIS accumulator. The
    // acc_next mux below used the bare signals, while acc_we already fires on
    // `pending` alone. So with a product pending here and a MACCLEAR / MACLOAD
    // for a DIFFERENT accumulator in EX, this accumulator was written with 0
    // (or with the other instruction's rs1_val) instead of acc + product:
    //     MAC acc0 ; MACCLEAR acc1   ->  acc0 = 0
    //     MAC acc0 ; MACLOAD  acc1   ->  acc0 = rs1_val
    // tb_dsu_top could not see it: it puts an idle cycle after every
    // instruction, so nothing is ever in EX while a product is being folded.
    //
    // ERRATUM DSU-13 (proposed; found by sw/tests/t_hold_flush_matrix.S bits
    // 9/10) -- flush discarded a COMMITTED accumulate
    // -----------------------------------------------------------------------
    // `pending` is stage 2 of the MAC that was in EX on the PREVIOUS cycle.
    // That instruction has left EX and will retire; it is older than whatever
    // is being trapped now, and CORE [N-7.13] requires every earlier
    // instruction to complete. flush (the trap-driven EX squash) cleared
    // `pending` and gated acc_we, so a MAC followed by an instruction that
    // traps - or by ANY instruction on which an interrupt is taken - lost its
    // product silently. DSU [N-7.9] asks only that the instruction the flush
    // KILLED does not accumulate: that is the one in EX now, and prod_en /
    // my_load / my_clear / my_sat below all carry ~flush for it.
    // -----------------------------------------------------------------------
    wire my_sat   = sat_writeback_en & ~flush;  // sat_writeback_en is per-unit
    wire my_load  = load  & en & ~flush;
    wire my_clear = clear & en & ~flush;

    always_comb begin : c_acc
        if (my_sat) begin
            acc_next = sat_writeback;
        end else if (my_load) begin
            acc_next = rs1_sext;
        end else if (my_clear) begin
            acc_next = 48'b000000000000000000000000000000000000000000000000;
        end else begin
            acc_next = adder_result;
        end
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
    // FLAG-B, restated by ERRATUM DSU-13: a trap must not destroy committed
    // accumulator state, and the pending product IS committed state - its MAC
    // has already left EX. flush therefore stops a new product being latched
    // (prod_en carries ~flush) and nothing else; a product already pending is
    // folded in on schedule.
    // -----------------------------------------------------------------------
    reg pending;
    always_ff @(posedge gclk or negedge core_rst_n) begin : p_pending
        if (!core_rst_n) begin
            pending <= 1'b0;
        end else begin
            pending <= prod_en;
        end
    end

    wire acc_we = my_sat | my_load | my_clear | pending;
    assign pending_o = pending;

    always_ff @(posedge gclk or negedge core_rst_n) begin : p_acc
        if (!core_rst_n) begin
            acc <= 48'b000000000000000000000000000000000000000000000000;
        end else if (acc_we) begin
            acc <= acc_next;
        end
    end
    assign mac_out = acc;

    // ERRATUM DSU-4 (continued): overflow must be reported on the cycle the
    // accumulate actually COMMITS, which is now `pending`, not on the cycle an
    // instruction happens to arrive (`write_en`). Leaving it on write_en after
    // making stage 2 self-draining split the two apart: the fold that
    // overflows can now happen on a cycle with no instruction present, and
    // conversely an arriving instruction no longer implies a fold. Caught by
    // tb_dsu_top as a sticky-overflow mismatch against DSUModel.
    // DSU-13: no ~flush here either - the fold belongs to the older MAC.
    // ERRATUM DSU-18 (ruling D-32, 2026-11-03): a load, clear or saturate of
    // this accumulator in the fold's cycle replaces the result (the later
    // instruction wins) but no longer hides the fold's overflow: it was dropped
    // from the sticky flag. (DSU-11 still holds: only this unit's own
    // load/clear/saturate, the my_* terms, replaces its accumulator in
    // acc_next.)
    assign overflow = accum_ovf & pending;

endmodule
