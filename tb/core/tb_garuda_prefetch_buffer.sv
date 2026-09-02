// =============================================================================
// tb_garuda_prefetch_buffer.sv -- SV unit TB for rtl/core/garuda_prefetch_buffer.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 6.3 (depth-4 circular FIFO, each
//       entry tagged with its PC and fault bit) and Sec. 6.5 (whole-buffer
//       flush in one cycle).
// Plan: C14 ("fill/drain, full backpressure, empty fetch bubble") and C15
//       ("whole-buffer flush on redirect; no stale instruction issued").
//       C13 (a flushed faulting word must not trap) needs this block to drop
//       the tagged entry -- the flush sequences are its unit-level half.
//
// The TB carries a reference FIFO (an SV queue) and compares every pop
// against it, so ordering and tag integrity are checked structurally rather
// than by a handful of directed expectations. Every pushed word uses a PC
// tag that is NOT instr+constant, so crossed instr/pc wiring cannot pass.
//
// Deliberately NOT exercised: pushing past full. The RTL does not guard the
// write at occupancy == 4 -- the I-port master owns that invariant via its
// room_for_new_fetch reservation, so overflow is out of this block's
// contract and is checked in tb_garuda_iport_ahb_master.sv instead. The
// a_no_overflow property below states the contract from this side.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

interface pfb_if (input bit clk, input bit rst_n);
    logic        redirect;
    logic        wr_en;
    logic [31:0] wr_instr, wr_pc;
    logic        wr_fault;
    logic        rd_en;
    logic [31:0] instr, instr_pc;
    logic        instr_fault, instr_valid;
    logic        full, empty;
    logic [2:0]  occupancy;

    // A1: a redirect empties the buffer in ONE cycle, whatever the occupancy
    //     was, and beats a concurrent write or read (Sec. 6.5).
    property p_flush_is_whole_buffer;
        @(posedge clk) disable iff (!rst_n)
            redirect |=> ((occupancy == 3'd0) && empty && !instr_valid);
    endproperty
    a_flush: assert property (p_flush_is_whole_buffer)
        else $error("[SVA-FAIL] a redirect did not empty the whole buffer in one cycle");

    // A2/A3: empty and full are exactly the occupancy endpoints -- IF starves
    //     on empty (a fetch bubble, not an architectural NOP) and the master
    //     backpressures on full.
    property p_empty_iff_zero;
        @(posedge clk) empty == (occupancy == 3'd0);
    endproperty
    a_empty: assert property (p_empty_iff_zero)
        else $error("[SVA-FAIL] empty_o does not track occupancy == 0");

    property p_full_iff_depth;
        @(posedge clk) full == (occupancy == 3'd4);
    endproperty
    a_full: assert property (p_full_iff_depth)
        else $error("[SVA-FAIL] full_o does not track occupancy == FIFO_DEPTH");

    // A4: instr_valid is simply "not empty" -- IF pops on it.
    property p_valid_is_not_empty;
        @(posedge clk) instr_valid == !empty;
    endproperty
    a_valid: assert property (p_valid_is_not_empty)
        else $error("[SVA-FAIL] instr_valid_o does not track ~empty");

    // A5: occupancy accounting. A simultaneous read+write must leave it
    //     UNCHANGED -- the classic off-by-one in a circular FIFO.
    property p_occupancy_accounting;
        @(posedge clk) disable iff (!rst_n)
            (!redirect) |=> (occupancy ==
                $past(occupancy) + ($past(wr_en) ? 3'd1 : 3'd0)
                                 - ($past(rd_en) ? 3'd1 : 3'd0));
    endproperty
    a_occupancy: assert property (p_occupancy_accounting)
        else $error("[SVA-FAIL] occupancy accounting is wrong for this wr/rd combination");

    // A6: the contract this block relies on and does not enforce -- the
    //     I-port master must never write into a full buffer. If the TB (or
    //     a future integration) violates it, say so here rather than let the
    //     occupancy counter run past 4 silently.
    property p_no_overflow;
        @(posedge clk) disable iff (!rst_n) (occupancy <= 3'd4);
    endproperty
    a_no_overflow: assert property (p_no_overflow)
        else $error("[SVA-FAIL] occupancy exceeded FIFO_DEPTH (master reservation broken)");
endinterface


module tb_top;
    bit clk = 0;
    bit rst_n;
    always #5 clk = ~clk;

    pfb_if vif(clk, rst_n);

    garuda_prefetch_buffer dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .redirect_i    (vif.redirect),
        .wr_en_i       (vif.wr_en),
        .wr_instr_i    (vif.wr_instr),
        .wr_pc_i       (vif.wr_pc),
        .wr_fault_i    (vif.wr_fault),
        .rd_en_i       (vif.rd_en),
        .instr_o       (vif.instr),
        .instr_pc_o    (vif.instr_pc),
        .instr_fault_o (vif.instr_fault),
        .instr_valid_o (vif.instr_valid),
        .full_o        (vif.full),
        .empty_o       (vif.empty),
        .occupancy_o   (vif.occupancy)
    );

    garuda_tb_pkg::scoreboard sb;

    // Reference FIFO: what the buffer should contain, maintained by the TB.
    typedef struct packed {
        bit [31:0] instr;
        bit [31:0] pc;
        bit        fault;
    } entry_t;
    entry_t ref_fifo[$];

    covergroup cg_pfb @(posedge clk);
        cp_occupancy: coverpoint vif.occupancy {
            bins empty_ = {0}; bins one = {1}; bins two = {2};
            bins three  = {3}; bins full_ = {4};
        }
        cp_rw: coverpoint {vif.wr_en, vif.rd_en} {
            bins neither      = {2'b00};
            bins read_only    = {2'b01};
            bins write_only   = {2'b10};
            bins simultaneous = {2'b11};     // the off-by-one corner
        }
        // Every wr/rd combination at every occupancy, including a write at
        // full and a read at empty.
        cross cp_occupancy, cp_rw;
        cp_flush_at: coverpoint vif.occupancy iff (vif.redirect) {
            bins flush_empty = {0};
            bins flush_part  = {[1:3]};
            bins flush_full  = {4};          // flush from full, in one cycle
        }
        cp_fault: coverpoint vif.wr_fault iff (vif.wr_en);
    endgroup
    cg_pfb cg;

    // ---------------------------------------------------------
    // Stimulus + reference-FIFO maintenance
    // ---------------------------------------------------------
    task automatic step(bit rdir, bit we, bit [31:0] wi, bit [31:0] wp,
                        bit wf, bit re);
        @(negedge clk);
        vif.redirect <= rdir; vif.wr_en <= we;
        vif.wr_instr <= wi;   vif.wr_pc <= wp; vif.wr_fault <= wf;
        vif.rd_en    <= re;
        @(posedge clk);
        #1;
        // Mirror the spec's update rules into the reference FIFO.
        if (rdir) ref_fifo.delete();
        else begin
            if (re && ref_fifo.size() > 0) void'(ref_fifo.pop_front());
            if (we) begin
                entry_t e;
                e.instr = wi; e.pc = wp; e.fault = wf;
                ref_fifo.push_back(e);
            end
        end
    endtask

    task automatic push(bit [31:0] wi, bit [31:0] wp, bit wf = 1'b0);
        step(1'b0, 1'b1, wi, wp, wf, 1'b0);
    endtask
    task automatic pop();
        step(1'b0, 1'b0, 32'd0, 32'd0, 1'b0, 1'b1);
    endtask
    task automatic quiet();
        step(1'b0, 1'b0, 32'd0, 32'd0, 1'b0, 1'b0);
    endtask
    task automatic flush();
        step(1'b1, 1'b0, 32'd0, 32'd0, 1'b0, 1'b0);
    endtask

    // Compare the visible head and the occupancy against the reference.
    task automatic check(string seq);
        sb.chk(seq, "occupancy", vif.occupancy, ref_fifo.size());
        sb.chk1(seq, "empty",    vif.empty,     (ref_fifo.size() == 0));
        sb.chk1(seq, "full",     vif.full,      (ref_fifo.size() == 4));
        if (ref_fifo.size() > 0) begin
            sb.chk (seq, "head instr", vif.instr,       ref_fifo[0].instr);
            sb.chk (seq, "head pc",    vif.instr_pc,    ref_fifo[0].pc);
            sb.chk1(seq, "head fault", vif.instr_fault, ref_fifo[0].fault);
        end
    endtask

    initial begin
        sb = new("PREFETCH_BUFFER");
        cg = new();

        rst_n = 0;
        vif.redirect = 0; vif.wr_en = 0; vif.rd_en = 0;
        vif.wr_instr = 0; vif.wr_pc = 0; vif.wr_fault = 0;

        // ---- reset state ------------------------------------------------
        #3;
        sb.chk1("reset", "empty",       vif.empty,       1'b1);
        sb.chk1("reset", "not full",    vif.full,        1'b0);
        sb.chk1("reset", "not valid",   vif.instr_valid, 1'b0);
        sb.chk ("reset", "occupancy 0", vif.occupancy,   3'd0);
        @(negedge clk); rst_n = 1;

        // ---- fill to full. PC tags are deliberately NOT instr+constant,
        //      so crossed instr/pc wiring cannot pass.
        push(32'h0000_0093, 32'h1000_0000); check("fill");
        push(32'hDEAD_0113, 32'h2000_0040); check("fill");
        push(32'hBEEF_0193, 32'h1000_0008); check("fill");
        push(32'hCAFE_0213, 32'h3000_0FFC); check("fill");
        sb.chk1("fill", "full at depth 4", vif.full, 1'b1);

        // ---- drain in order, tags intact (Sec. 6.3) --------------------
        pop(); check("drain");
        pop(); check("drain");
        pop(); check("drain");
        pop(); check("drain");
        sb.chk1("drain", "empty after drain",   vif.empty,       1'b1);
        sb.chk1("drain", "invalid after drain", vif.instr_valid, 1'b0);

        // ---- simultaneous read+write leaves occupancy unchanged --------
        push(32'h1111_0001, 32'h1000_0100);
        push(32'h2222_0002, 32'h1000_0104);
        check("pre_simul");
        step(0, 1, 32'h3333_0003, 32'h1000_0108, 0, 1);   // wr + rd
        check("simultaneous_rw");
        step(0, 1, 32'h4444_0004, 32'h1000_010C, 0, 1);
        check("simultaneous_rw");
        quiet();
        check("quiet_holds");
        pop(); pop();

        // ---- pointer WRAPAROUND: 8 push/pop rounds take both pointers
        //      past 3 and back to 0, never exceeding depth 4
        for (int i = 0; i < 8; i++) begin
            push(32'hA000_0000 + i, 32'h1000_0200 + (i * 4));
            check("wraparound");
            pop();
            check("wraparound");
        end

        // ---- per-entry fault bit (feeds the deferred cause-1 trap) -----
        flush();
        push(32'h0000_0013, 32'h1000_0300, 1'b0);   // clean
        push(32'h0000_0000, 32'h1000_0304, 1'b1);   // faulting fetch
        push(32'h0000_0013, 32'h1000_0308, 1'b0);   // clean
        check("fault_tag");
        pop(); check("fault_tag");                  // head is now the faulting one
        sb.chk1("fault_tag", "faulting entry flagged", vif.instr_fault, 1'b1);
        sb.chk ("fault_tag", "faulting entry pc",      vif.instr_pc, 32'h1000_0304);
        pop(); check("fault_tag");
        sb.chk1("fault_tag", "next entry clean", vif.instr_fault, 1'b0);
        pop();

        // ---- whole-buffer flush in ONE cycle (Sec. 6.5, test C15) ------
        push(32'hAAAA_0001, 32'h1000_0400);
        push(32'hAAAA_0002, 32'h1000_0404);
        push(32'hAAAA_0003, 32'h1000_0408);
        check("pre_flush");
        flush();
        check("flushed");
        // The FIRST word written after the flush must be the one that pops:
        // no pre-redirect instruction may ever be issued (C15).
        push(32'hBBBB_0001, 32'h9000_0000);
        check("post_flush");
        sb.chk("post_flush", "head is the post-redirect word",
               vif.instr, 32'hBBBB_0001);
        pop();

        // flush from FULL, also in one cycle
        push(32'hCCCC_0001, 32'h9000_0100);
        push(32'hCCCC_0002, 32'h9000_0104);
        push(32'hCCCC_0003, 32'h9000_0108);
        push(32'hCCCC_0004, 32'h9000_010C);
        sb.chk1("flush_from_full", "full before flush", vif.full, 1'b1);
        flush();
        check("flush_from_full");

        // ---- flush WINS over a concurrent write and a concurrent read --
        push(32'hDDDD_0001, 32'h9000_0200);
        push(32'hDDDD_0002, 32'h9000_0204);
        step(1, 1, 32'hDDDD_0003, 32'h9000_0208, 0, 0);   // flush + write
        check("flush_beats_write");
        push(32'hEEEE_0001, 32'h9000_0300);
        push(32'hEEEE_0002, 32'h9000_0304);
        step(1, 0, 32'd0, 32'd0, 0, 1);                   // flush + read
        check("flush_beats_read");
        // usable again immediately
        push(32'hFFFF_0001, 32'h9000_0400);
        check("usable_after_flush");
        pop();

        // ---- randomised soak against the reference FIFO ----------------
        // Writes are gated on "not full" because that is the master's
        // reservation contract (SVA A6); reads are gated on "not empty"
        // because that is what fifo_rd_en does in garuda_if_stage_top.
        repeat (2000) begin
            bit rdir = ($urandom_range(0, 99) < 5);
            bit we   = !rdir && (ref_fifo.size() < 4) && ($urandom_range(0, 99) < 60);
            bit re   = !rdir && (ref_fifo.size() > 0) && ($urandom_range(0, 99) < 55);
            bit [31:0] wi = $urandom();
            bit [31:0] wp = $urandom() & 32'hFFFF_FFFC;
            bit wf = ($urandom_range(0, 99) < 10);
            step(rdir, we, wi, wp, wf, re);
            check("soak");
        end

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
