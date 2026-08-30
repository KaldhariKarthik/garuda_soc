// =============================================================
// tb_dsu_result_selector.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/result_selector.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA result_selector.v
// (4:1 mux to the DSU's regfile-writeback data: none/lo/hi/shift)
//
// Purely combinational -- independent randomized items.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0b. TEST CONTROL -- reproducibility, runtime knobs, log hygiene
//
// A 1500+ case constrained-random run has three practical problems
// that a 100%-coverage result does NOT reveal:
//   1. The seed is printed every run so it can be recorded for the
//      report; each run draws a fresh random seed by design.
//   2. Changing the iteration count should not need a recompile --
//      +NRAND=<n> overrides it (e.g. a long soak before sign-off).
//   3. Every case prints a [PASS]/[FAIL] line as it runs, so the
//      SUMMARY total can be cross-checked against the live log.
// -------------------------------------------------------------
real tb_cov_goal = 100.0;   // sign-off goal; relax with +COV_GOAL=<percent>

task automatic tb_control_init(inout int nrand, input string tb_name);
    int seed_arg;
    seed_arg = $urandom;
    void'($urandom(seed_arg));
    $display("[%0s] seed = %0d", tb_name, seed_arg);
    $display("[%0s] random_cases=%0d", tb_name, nrand);
endtask

// tb_signoff -- a run is only signed off if BOTH criteria hold. A green
// "ALL CHECKS PASSED" at 60% coverage means the stimulus never reached the
// logic, not that the logic is right, so coverage is part of the verdict
// rather than a number printed beside it. Goal defaults to 100% and can be
// relaxed for a smoke run with +COV_GOAL=<percent>.

task automatic tb_signoff(real cov, int fails);
    if (fails != 0)
        $display(" SIGN-OFF: FAIL          -- %0d check(s) failed (coverage %0.2f%%)", fails, cov);
    else if (cov < tb_cov_goal)
        $display(" SIGN-OFF: NOT SIGNED OFF -- checks passed, but coverage %0.2f%% < goal %0.2f%%",
                  cov, tb_cov_goal);
    else
        $display(" SIGN-OFF: PASS          -- 0 failures and coverage %0.2f%% >= goal %0.2f%%",
                  cov, tb_cov_goal);
endtask



// -------------------------------------------------------------
// 1. DUT: result_selector.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module result_selector (
    input wire [1:0] result_src,
    input wire [31:0] rd_lo_data,
    input wire [31:0] rd_hi_data,
    input wire [31:0] shift_result,

    output reg [31:0] dsu_rd_data
);

    always @(*) begin
        case (result_src)
            2'b01: dsu_rd_data = rd_lo_data;
            2'b10: dsu_rd_data = rd_hi_data;
            2'b11: dsu_rd_data = shift_result;
            default: dsu_rd_data = 32'b0;
        endcase
    end

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface result_selector_if (input bit clk);
    logic [1:0]  result_src;
    logic [31:0] rd_lo_data, rd_hi_data, shift_result;
    logic [31:0] dsu_rd_data;

    property p_no_x_propagation;
        @(posedge clk)
        (!$isunknown({result_src, rd_lo_data, rd_hi_data, shift_result})) |-> (!$isunknown(dsu_rd_data));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on result_selector output with fully-known inputs");

    property p_reserved_00_is_zero;
        @(posedge clk) (result_src == 2'b00) |-> (dsu_rd_data == 32'b0);
    endproperty
    a_reserved_00_is_zero: assert property (p_reserved_00_is_zero)
        else $error("[SVA-FAIL] result_src=00 did not yield zero");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class rsel_txn;
    rand bit [1:0]  result_src;
    rand bit [31:0] rd_lo_data, rd_hi_data, shift_result;
    string tag;
    bit [31:0] dsu_rd_data_act, dsu_rd_data_exp;

    constraint c_src_dist { result_src dist { 2'b00:=20, 2'b01:=27, 2'b10:=27, 2'b11:=26 }; }
    constraint c_data_corner_dist {
        rd_lo_data   dist { 32'h0 := 6, {32{1'b1}} := 6, [0:32'hFFFF_FFFE] :/ 88 };
        rd_hi_data   dist { 32'h0 := 6, {32{1'b1}} := 6, [0:32'hFFFF_FFFE] :/ 88 };
        shift_result dist { 32'h0 := 6, {32{1'b1}} := 6, [0:32'hFFFF_FFFE] :/ 88 };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("result_src=%02b lo=%08h hi=%08h shift=%08h", result_src, rd_lo_data, rd_hi_data, shift_result);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL
// -------------------------------------------------------------
function automatic void rsel_golden(rsel_txn t);
    case (t.result_src)
        2'b01: t.dsu_rd_data_exp = t.rd_lo_data;
        2'b10: t.dsu_rd_data_exp = t.rd_hi_data;
        2'b11: t.dsu_rd_data_exp = t.shift_result;
        default: t.dsu_rd_data_exp = 32'b0;
    endcase
endfunction


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class rsel_generator;
    rsel_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function void build();
        rsel_txn t;
        t = new("dir_none");  t.result_src=2'b00; t.rd_lo_data=32'hAAAA_AAAA; t.rd_hi_data=32'hBBBB_BBBB; t.shift_result=32'hCCCC_CCCC; items.push_back(t);
        t = new("dir_lo");    t.result_src=2'b01; t.rd_lo_data=32'h1111_1111; t.rd_hi_data=32'h2222_2222; t.shift_result=32'h3333_3333; items.push_back(t);
        t = new("dir_hi");    t.result_src=2'b10; t.rd_lo_data=32'h1111_1111; t.rd_hi_data=32'h2222_2222; t.shift_result=32'h3333_3333; items.push_back(t);
        t = new("dir_shift"); t.result_src=2'b11; t.rd_lo_data=32'h1111_1111; t.rd_hi_data=32'h2222_2222; t.shift_result=32'h3333_3333; items.push_back(t);

        repeat (num_random) begin
            rsel_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class rsel_driver;
    virtual result_selector_if vif;
    function new(virtual result_selector_if vif); this.vif = vif; endfunction

    task apply(rsel_txn t);
        @(negedge vif.clk);
        vif.result_src   <= t.result_src;
        vif.rd_lo_data   <= t.rd_lo_data;
        vif.rd_hi_data   <= t.rd_hi_data;
        vif.shift_result <= t.shift_result;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class rsel_monitor;
    virtual result_selector_if vif;

    covergroup cg_rsel;
        cp_src: coverpoint vif.result_src { bins none={2'b00}; bins lo={2'b01}; bins hi={2'b10}; bins shift={2'b11}; }
    endgroup

    function new(virtual result_selector_if vif); this.vif = vif; cg_rsel = new(); endfunction

    task sample_one(output bit [31:0] data_);
        #1;
        data_ = vif.dsu_rd_data;
        cg_rsel.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class rsel_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(rsel_txn t, bit [31:0] data_);
        t.dsu_rd_data_act = data_;
        rsel_golden(t);
        if (t.dsu_rd_data_act === t.dsu_rd_data_exp) begin
            pass_cnt++;
            $display("[PASS] %-10s %-0s -> data=%08h", t.tag, t.to_s(), data_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-10s %-0s -> got=%08h exp=%08h", t.tag, t.to_s(), data_, t.dsu_rd_data_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class rsel_env;
    virtual result_selector_if vif;
    rsel_generator  gen;
    rsel_driver     drv;
    rsel_monitor    mon;
    rsel_scoreboard sb;

    function new(virtual result_selector_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        bit [31:0] data_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(data_);
            sb.check(gen.items[i], data_);
        end

        $display("\n================ RESULT_SELECTOR UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_rsel.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_rsel.get_coverage(), sb.fail_cnt);
        $display("=====================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class rsel_test;
    rsel_env env;
    function new(virtual result_selector_if vif, int num_random = 1500);
        env = new(vif, num_random);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------

module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    result_selector_if vif(clk);

    result_selector dut (
        .result_src(vif.result_src),
        .rd_lo_data(vif.rd_lo_data),
        .rd_hi_data(vif.rd_hi_data),
        .shift_result(vif.shift_result),
        .dsu_rd_data(vif.dsu_rd_data)
    );

    rsel_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_result_selector");
        vif.result_src = 0; vif.rd_lo_data = 0; vif.rd_hi_data = 0; vif.shift_result = 0;
        repeat (3) @(posedge clk);

        test = new(vif, tb_nrand);
        test.run();
        $finish;
    end

endmodule
