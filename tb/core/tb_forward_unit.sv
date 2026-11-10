// =============================================================================
// tb_forward_unit.sv -- unit bench for rtl/core/forward_unit.v
//
// Spec: CORE-UARCH-001 (EX stage), DS-001 Sec. 11.1: the EX operand muxes take
// the most recent producer. EX/MEM wins over MEM/WB, MEM/WB over the register
// file; a producer counts only if it writes (reg_write) and its rd is not x0.
//
// 1-TOPS G4 row 4.8: rs1, rs2 and both-operand hazards, distance 1 (EX/MEM,
// ALU-to-use) and distance 2 (MEM/WB, which is also where a load's value comes
// from after the load-use stall). Until this bench, forward_unit was reached
// only by the tb_id_ex_fwd smoke test (no coverage model, 46% toggle).
//
// Stimulus: an exhaustive sweep over a register set that holds x0, two
// ordinary registers and x31 (4^4 index combinations x 4 write-enable
// combinations = 1024), every index as each source and each rd, then random
// cycles biased towards collisions. Every cycle is checked against a model written from the spec
// above. Top is tb_top, as for the other unit benches.
// =============================================================================
`timescale 1ns/1ps
`include "core_ex_defs.vh"

interface fwd_if (input bit clk);
    logic [4:0] rs1, rs2, exmem_rd, memwb_rd;
    logic       exmem_we, memwb_we;
    logic [1:0] sel_a, sel_b;

    // A1: x0 is never forwarded: a select other than NONE needs a real rd
    a_x0_a: assert property (@(posedge clk) (rs1 == 0) |-> (sel_a == `FWD_NONE))
        else $error("[SVA-FAIL] rs1 = x0 was forwarded (sel_a=%0d)", sel_a);
    a_x0_b: assert property (@(posedge clk) (rs2 == 0) |-> (sel_b == `FWD_NONE))
        else $error("[SVA-FAIL] rs2 = x0 was forwarded (sel_b=%0d)", sel_b);
    // A2: the select encoding 2'b11 is never produced
    a_no_11: assert property (@(posedge clk) (sel_a != 2'b11) && (sel_b != 2'b11))
        else $error("[SVA-FAIL] a forwarding select took the unused code 2'b11");
endinterface


class fwd_model;
    static function bit [1:0] sel(bit [4:0] rs, bit [4:0] exrd, bit exwe, bit [4:0] wbrd, bit wbwe);
        if (exwe && exrd != 0 && exrd == rs) return `FWD_EXMEM;
        if (wbwe && wbrd != 0 && wbrd == rs) return `FWD_MEMWB;
        return `FWD_NONE;
    endfunction
endclass

module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;
    fwd_if vif(clk);

    forward_unit dut (
        .id_ex_rs1_idx_i   (vif.rs1),
        .id_ex_rs2_idx_i   (vif.rs2),
        .exmem_rd_i        (vif.exmem_rd),
        .exmem_reg_write_i (vif.exmem_we),
        .memwb_rd_i        (vif.memwb_rd),
        .memwb_reg_write_i (vif.memwb_we),
        .fwd_a_sel_o       (vif.sel_a),
        .fwd_b_sel_o       (vif.sel_b)
    );

    // what each operand's producer situation is, for coverage:
    // 0 no match, 1 EX/MEM only, 2 MEM/WB only, 3 both match (EX/MEM must win),
    // 4 a match that does not count (rd = x0 or reg_write = 0)
    function automatic bit [2:0] kind(bit [4:0] rs);
        bit ex = vif.exmem_we && vif.exmem_rd != 0 && vif.exmem_rd == rs;
        bit wb = vif.memwb_we && vif.memwb_rd != 0 && vif.memwb_rd == rs;
        bit nc = (vif.exmem_rd == rs && !(vif.exmem_we && rs != 0)) ||
                 (vif.memwb_rd == rs && !(vif.memwb_we && rs != 0));
        if (ex && wb) return 3;
        if (ex)       return 1;
        if (wb)       return 2;
        if (nc)       return 4;
        return 0;
    endfunction

    bit [2:0] ka, kb;
    covergroup cg_fwd;
        cp_a: coverpoint ka { bins none = {0}; bins exmem = {1}; bins memwb = {2}; bins both_exmem_wins = {3}; bins not_counted = {4}; }
        cp_b: coverpoint kb { bins none = {0}; bins exmem = {1}; bins memwb = {2}; bins both_exmem_wins = {3}; bins not_counted = {4}; }
        cp_sel_a: coverpoint vif.sel_a { bins none = {`FWD_NONE}; bins exmem = {`FWD_EXMEM}; bins memwb = {`FWD_MEMWB}; }
        cp_sel_b: coverpoint vif.sel_b { bins none = {`FWD_NONE}; bins exmem = {`FWD_EXMEM}; bins memwb = {`FWD_MEMWB}; }
        // rs1-only, rs2-only and both-operand hazards, from each stage
        x_sel_a_b: cross cp_sel_a, cp_sel_b;
        // the same register on both operands (add x5, x6, x6)
        cp_same_src: coverpoint vif.sel_a iff (vif.rs1 == vif.rs2 && vif.rs1 != 0) {
            bins exmem = {`FWD_EXMEM}; bins memwb = {`FWD_MEMWB};
        }
        // a non-counting match: x0 as rd, or a producer that does not write
        cp_x0_rd: coverpoint {vif.exmem_we, vif.memwb_we} iff (vif.rs1 == 0 && (vif.exmem_rd == 0 || vif.memwb_rd == 0));
    endgroup
    cg_fwd cg = new();

    int pass = 0, fail = 0;
    task automatic apply(bit [4:0] r1, bit [4:0] r2, bit [4:0] exrd, bit exwe, bit [4:0] wbrd, bit wbwe);
        bit [1:0] ea, eb;
        @(negedge clk);
        vif.rs1 = r1; vif.rs2 = r2; vif.exmem_rd = exrd; vif.exmem_we = exwe;
        vif.memwb_rd = wbrd; vif.memwb_we = wbwe;
        #1;
        ea = fwd_model::sel(r1, exrd, exwe, wbrd, wbwe);
        eb = fwd_model::sel(r2, exrd, exwe, wbrd, wbwe);
        ka = kind(r1); kb = kind(r2);
        cg.sample();
        if (vif.sel_a === ea && vif.sel_b === eb) pass++;
        else begin
            fail++;
            $display("[FAIL] rs1=%0d rs2=%0d exmem(rd=%0d we=%0b) memwb(rd=%0d we=%0b): sel_a=%0d exp %0d, sel_b=%0d exp %0d",
                     r1, r2, exrd, exwe, wbrd, wbwe, vif.sel_a, ea, vif.sel_b, eb);
        end
    endtask

    initial begin
        bit [4:0] regs[4] = '{5'd0, 5'd5, 5'd6, 5'd31};
        bit [4:0] r1, r2, er, wr;
        int n_rand = 4000;
        void'($value$plusargs("NRAND=%d", n_rand));
        vif.rs1 = 0; vif.rs2 = 0; vif.exmem_rd = 0; vif.memwb_rd = 0; vif.exmem_we = 0; vif.memwb_we = 0;
        repeat (2) @(posedge clk);
        // exhaustive over the register set
        foreach (regs[a]) foreach (regs[b]) foreach (regs[e]) foreach (regs[w])
            for (int we = 0; we < 4; we++)
                apply(regs[a], regs[b], regs[e], we[0], regs[w], we[1]);
        // every register index as rs1, rs2 and as each producer's rd
        for (int r = 0; r < 32; r++) begin
            apply(r, 0, r, 1, 0, 0);
            apply(0, r, 0, 0, r, 1);
        end
        // random, biased so that most cycles make a producer collide with a
        // source (and MEM/WB often names the same register as EX/MEM)
        repeat (n_rand) begin
            r1 = $urandom; r2 = $urandom;
            case ($urandom_range(0, 9))
                0, 1, 2: er = r1;
                3, 4, 5: er = r2;
                default: er = $urandom;
            endcase
            case ($urandom_range(0, 9))
                0, 1, 2: wr = r1;
                3, 4, 5: wr = r2;
                6, 7:    wr = er;
                default: wr = $urandom;
            endcase
            apply(r1, r2, er, $urandom, wr, $urandom);
        end
        $display("\n============ FORWARD_UNIT UNIT TB SUMMARY ============");
        $display(" CHECKS=%0d  PASS=%0d  FAIL=%0d", pass + fail, pass, fail);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", cg.get_coverage());
        if (fail == 0) $display(" RESULT: ALL CHECKS PASSED");
        else           $display(" RESULT: %0d CHECK(S) FAILED", fail);
        $finish;
    end
endmodule
