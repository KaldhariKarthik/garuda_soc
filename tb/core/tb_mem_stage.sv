// =============================================================================
// tb_mem_stage.sv -- SV integration TB for rtl/core/mem_stage.v
//                    (load_store_unit + d_port_ahb_master + load_formatter)
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 10 (memory stage and data port),
//       Sec. 11.4 (D-port wait state), Sec. 13.2 (minstret retirement),
//       Sec. 14.1/14.2 (causes 5 and 7 and their mtval), Sec. 4.1 (static
//       pins).
// Plan: C10 (load extension and store lane alignment through the real bus
//       pins), C11 ("no bus transaction issued" on a misalignment -- the half
//       the load_store_unit TB cannot see), C12 (D-port ERROR raises access
//       faults 5 and 7 precisely).
//
// The three sub-blocks each have their own unit TB. This one owns the wiring
// and the stage-level decisions that exist only here:
//
//   * start_w gating (Sec. 10.2): a misaligned access must NEVER reach the
//     bus. Checked as an SVA property that holds on every cycle, not by
//     sampling HTRANS once and hoping.
//   * The mem_to_reg mux lives in MEM, not WB (the Sec. 5.2 / 10.3
//     mux-in-MEM contract): wb_data_o is already final when it leaves.
//   * Cause assignment: load ERROR -> 5, store ERROR -> 7, mtval = the
//     access address in both cases. Both directions are run to the SAME
//     address, so a swapped mem_read/mem_write split cannot pass both.
//   * Misalignment raises NO exception here -- causes 4 and 6 are owned by
//     ex_stage (the RTL says so explicitly), and MEM owning them too would
//     double-report the trap. That ABSENCE is asserted, not assumed.
//   * retire_o = valid_i & ~exception (Sec. 13.2): a faulting access must
//     not count toward minstret.
//   * Sec. 4.1 static pins: HBURST = SINGLE and HPROT = 0b0011, always.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

// Guarded: three element TBs define these, and a whole-directory lint
// pass compiles them together even though each runs on its own filelist.
`ifndef GARUDA_LDST_F3
`define GARUDA_LDST_F3
`define F3_B  3'b000
`define F3_H  3'b001
`define F3_W  3'b010
`define F3_BU 3'b100
`define F3_HU 3'b101
`endif

interface mem_stage_if (input bit clk, input bit rst_n);
    logic [31:0] ex_result, rs2_data, pc_in;
    logic [2:0]  funct3;
    logic [4:0]  rd_in;
    logic        mem_read, mem_write, mem_to_reg, reg_write, valid;
    logic [31:0] d_haddr, d_hwdata;
    logic [1:0]  d_htrans;
    logic [2:0]  d_hsize, d_hburst;
    logic [3:0]  d_hprot;
    logic        d_hwrite;
    logic [31:0] d_hrdata;
    logic        d_hready, d_hresp;
    logic [31:0] wb_data;
    logic        reg_write_o, retire;
    logic [4:0]  rd_o;
    logic        mem_stall;
    logic        exc_valid;
    logic [31:0] exc_pc, exc_mtval;
    logic [3:0]  exc_cause;

    localparam logic [1:0] HTRANS_IDLE = 2'b00;

    // A1: the Sec. 4.1 static pin contract, in EVERY cycle.
    property p_static_pins;
        @(posedge clk) (d_hburst == 3'b000) && (d_hprot == 4'b0011);
    endproperty
    a_static_pins: assert property (p_static_pins)
        else $error("[SVA-FAIL] d_hburst_o/d_hprot_o are not the Sec. 4.1 constants");

    // A2: C11 -- a misaligned access never reaches the bus (Sec. 10.2).
    //     Stated over the misalignment condition directly, so it holds for
    //     every address and size, not just the directed vectors.
    property p_misaligned_never_issues;
        @(posedge clk)
            ((mem_read || mem_write) &&
             (((funct3[1:0] == 2'b01) && ex_result[0]) ||
              ((funct3[1:0] == 2'b10) && (|ex_result[1:0]))))
            |-> (d_htrans == HTRANS_IDLE);
    endproperty
    a_no_misaligned_bus_access: assert property (p_misaligned_never_issues)
        else $error("[SVA-FAIL] a misaligned access was presented on the D-port");

    // A3: MEM owns bus access faults ONLY. Causes 4 and 6 (misalignment)
    //     belong to ex_stage; this stage must stay silent on them or the
    //     trap is reported twice.
    property p_mem_only_raises_access_faults;
        @(posedge clk) exc_valid |-> (exc_cause inside {4'd5, 4'd7});
    endproperty
    a_cause_scope: assert property (p_mem_only_raises_access_faults)
        else $error("[SVA-FAIL] mem_stage raised a cause outside {5,7}");

    // A4: a faulting access must not retire (Sec. 13.2) -- otherwise
    //     minstret, the metric Sec. 18.1 relies on, is inflated.
    property p_fault_does_not_retire;
        @(posedge clk) exc_valid |-> !retire;
    endproperty
    a_no_retire_on_fault: assert property (p_fault_does_not_retire)
        else $error("[SVA-FAIL] a faulting access retired");

    // A5: a bubble never retires.
    property p_bubble_does_not_retire;
        @(posedge clk) (!valid) |-> !retire;
    endproperty
    a_bubble_no_retire: assert property (p_bubble_does_not_retire)
        else $error("[SVA-FAIL] an invalid instruction retired");

    // A6: mtval is the access address in both fault cases (Sec. 14.2).
    property p_mtval_is_the_address;
        @(posedge clk) exc_valid |-> (exc_mtval == ex_result);
    endproperty
    a_mtval: assert property (p_mtval_is_the_address)
        else $error("[SVA-FAIL] mtval is not the load/store address");

    // A7: the mux-in-MEM contract (Sec. 10.3) -- non-load instructions pass
    //     the EX result straight through, already final.
    property p_non_load_passes_ex_result;
        @(posedge clk) (!mem_to_reg) |-> (wb_data == ex_result);
    endproperty
    a_mux_in_mem: assert property (p_non_load_passes_ex_result)
        else $error("[SVA-FAIL] wb_data_o is not the EX result when mem_to_reg is low");

    // A8: an instruction that requests no memory access never STARTS one.
    //     Stated on d_htrans rather than on mem_stall: a data phase already
    //     in flight legitimately keeps mem_stall high for a cycle after the
    //     pipeline has moved on, so asserting on the stall would fire for a
    //     testbench-timing reason rather than a real defect.
    property p_no_access_no_new_transfer;
        @(posedge clk) disable iff (!rst_n)
            (!mem_read && !mem_write) |-> (d_htrans == HTRANS_IDLE);
    endproperty
    a_no_spurious_transfer: assert property (p_no_access_no_new_transfer)
        else $error("[SVA-FAIL] a transfer was presented with no load or store requested");
endinterface


module tb_top;
    bit clk = 0;
    bit rst_n;
    always #5 clk = ~clk;

    localparam logic [1:0] HTRANS_IDLE   = 2'b00;
    localparam logic [1:0] HTRANS_NONSEQ = 2'b10;

    mem_stage_if vif(clk, rst_n);

    mem_stage dut (
        .clk_i                 (clk),
        .rst_n_i               (rst_n),
        .ex_result_i           (vif.ex_result),
        .rs2_data_i            (vif.rs2_data),
        .funct3_i              (vif.funct3),
        .rd_i                  (vif.rd_in),
        .pc_i                  (vif.pc_in),
        .mem_read_i            (vif.mem_read),
        .mem_write_i           (vif.mem_write),
        .mem_to_reg_i          (vif.mem_to_reg),
        .reg_write_i           (vif.reg_write),
        .valid_i               (vif.valid),
        .d_haddr_o             (vif.d_haddr),
        .d_htrans_o            (vif.d_htrans),
        .d_hsize_o             (vif.d_hsize),
        .d_hburst_o            (vif.d_hburst),
        .d_hprot_o             (vif.d_hprot),
        .d_hwrite_o            (vif.d_hwrite),
        .d_hwdata_o            (vif.d_hwdata),
        .d_hrdata_i            (vif.d_hrdata),
        .d_hready_i            (vif.d_hready),
        .d_hresp_i             (vif.d_hresp),
        .wb_data_o             (vif.wb_data),
        .reg_write_o           (vif.reg_write_o),
        .rd_o                  (vif.rd_o),
        .retire_o              (vif.retire),
        .mem_stall_o           (vif.mem_stall),
        .mem_exception_valid_o (vif.exc_valid),
        .mem_exception_pc_o    (vif.exc_pc),
        .mem_exception_cause_o (vif.exc_cause),
        .mem_exception_mtval_o (vif.exc_mtval)
    );

    garuda_tb_pkg::scoreboard sb;

    covergroup cg_mem @(posedge clk);
        cp_access: coverpoint {vif.mem_read, vif.mem_write} {
            bins none  = {2'b00};
            bins load  = {2'b10};
            bins store = {2'b01};
            illegal_bins both = {2'b11};
        }
        cp_size: coverpoint vif.funct3[1:0] {
            bins byte_ = {2'b00}; bins half = {2'b01}; bins word = {2'b10};
        }
        cp_offset: coverpoint vif.ex_result[1:0];
        // Load and store, at every size, at every offset -- the alignment
        // and lane matrix that C10 and C11 together require.
        cross cp_access, cp_size, cp_offset;
        cp_cause: coverpoint vif.exc_cause iff (vif.exc_valid) {
            bins load_access_fault  = {4'd5};
            bins store_access_fault = {4'd7};
        }
        cp_stall:  coverpoint vif.mem_stall;
        cp_retire: coverpoint vif.retire;
        cp_hready: coverpoint vif.d_hready;
        cross cp_access, cp_hready;
    endgroup
    cg_mem cg;

    task automatic tick(); @(posedge clk); #1; endtask

    task automatic clr();
        vif.ex_result = 32'h2000_0000; vif.rs2_data = 32'd0;
        vif.pc_in = 32'h1000_0000; vif.funct3 = `F3_W; vif.rd_in = 5'd5;
        vif.mem_read = 0; vif.mem_write = 0; vif.mem_to_reg = 0;
        vif.reg_write = 0; vif.valid = 1;
        vif.d_hrdata = 32'd0; vif.d_hready = 1; vif.d_hresp = 0;
    endtask

    initial begin
        sb = new("MEM_STAGE");
        cg = new();

        clr();
        rst_n = 0; #3;
        sb.chk1("reset", "no stall",     vif.mem_stall, 1'b0);
        sb.chk1("reset", "no exception", vif.exc_valid, 1'b0);
        @(negedge clk); rst_n = 1;

        // =============================================================
        // LOAD WORD -- address phase, then data phase with real HRDATA
        // =============================================================
        @(negedge clk);
        clr(); vif.mem_read = 1; vif.mem_to_reg = 1; vif.reg_write = 1;
        vif.ex_result = 32'h2000_0010; vif.funct3 = `F3_W; vif.rd_in = 5'd9;
        #1;
        sb.chk ("lw", "HADDR",           vif.d_haddr,  32'h2000_0010);
        sb.chk ("lw", "HTRANS NONSEQ",   vif.d_htrans, HTRANS_NONSEQ);
        sb.chk1("lw", "HWRITE low",      vif.d_hwrite, 1'b0);
        sb.chk1("lw", "stalls in address phase", vif.mem_stall, 1'b1);
        tick();
        @(negedge clk); vif.d_hrdata = 32'hDEAD_BEEF; #1;
        sb.chk ("lw", "wb_data is the loaded word", vif.wb_data, 32'hDEAD_BEEF);
        sb.chk1("lw", "stall released",  vif.mem_stall,   1'b0);
        sb.chk1("lw", "retires",         vif.retire,      1'b1);
        sb.chk1("lw", "reg_write",       vif.reg_write_o, 1'b1);
        sb.chk ("lw", "rd passed through", vif.rd_o,      32'd9);
        sb.chk1("lw", "no exception",    vif.exc_valid,   1'b0);

        // ---- LB sign-extension through the real bus path ---------------
        @(negedge clk);
        clr(); vif.mem_read = 1; vif.mem_to_reg = 1; vif.reg_write = 1;
        vif.ex_result = 32'h2000_0021; vif.funct3 = `F3_B;    // byte lane 1
        tick();
        @(negedge clk); vif.d_hrdata = 32'h0000_80FF; #1;     // lane 1 = 0x80
        sb.chk("lb", "sign-extended", vif.wb_data, 32'hFFFF_FF80);
        @(negedge clk);
        clr(); vif.mem_read = 1; vif.mem_to_reg = 1; vif.reg_write = 1;
        vif.ex_result = 32'h2000_0021; vif.funct3 = `F3_BU;
        tick();
        @(negedge clk); vif.d_hrdata = 32'h0000_80FF; #1;
        sb.chk("lbu", "zero-extended", vif.wb_data, 32'h0000_0080);

        // ---- non-load: mem_to_reg low passes the EX result through ------
        @(negedge clk);
        clr(); vif.reg_write = 1; vif.mem_to_reg = 0;
        vif.ex_result = 32'h1234_5678; vif.d_hrdata = 32'hFFFF_FFFF; vif.rd_in = 5'd3;
        #1;
        sb.chk ("alu_op", "wb_data is the EX result", vif.wb_data, 32'h1234_5678);
        sb.chk ("alu_op", "rd passed through",        vif.rd_o,    32'd3);
        sb.chk ("alu_op", "no bus access",            vif.d_htrans, HTRANS_IDLE);
        sb.chk1("alu_op", "no stall",                 vif.mem_stall, 1'b0);
        sb.chk1("alu_op", "retires",                  vif.retire,    1'b1);

        // =============================================================
        // STORE -- lane alignment reaches the bus pins (C10)
        // =============================================================
        @(negedge clk);
        clr(); vif.mem_write = 1; vif.ex_result = 32'h2000_0032;
        vif.funct3 = `F3_B; vif.rs2_data = 32'h1234_56AB;
        #1;
        sb.chk ("sb", "HADDR",      vif.d_haddr,  32'h2000_0032);
        sb.chk1("sb", "HWRITE",     vif.d_hwrite, 1'b1);
        sb.chk ("sb", "HSIZE byte", vif.d_hsize,  3'b000);
        tick(); #1;
        sb.chk ("sb", "HWDATA on lane 2", vif.d_hwdata,    32'h00AB_0000);
        sb.chk1("sb", "completes",        vif.mem_stall,   1'b0);
        sb.chk1("sb", "retires",          vif.retire,      1'b1);
        sb.chk1("sb", "no reg_write",     vif.reg_write_o, 1'b0);

        @(negedge clk);
        clr(); vif.mem_write = 1; vif.ex_result = 32'h2000_0042;
        vif.funct3 = `F3_H; vif.rs2_data = 32'h1234_BEEF;
        tick(); #1;
        sb.chk("sh", "HWDATA on the upper half", vif.d_hwdata, 32'hBEEF_0000);
        sb.chk("sh", "HSIZE half",               vif.d_hsize,  3'b001);

        @(negedge clk);
        clr(); vif.mem_write = 1; vif.ex_result = 32'h2000_0050;
        vif.funct3 = `F3_W; vif.rs2_data = 32'hCAFE_F00D;
        tick(); #1;
        sb.chk("sw", "HWDATA unshifted", vif.d_hwdata, 32'hCAFE_F00D);
        sb.chk("sw", "HSIZE word",       vif.d_hsize,  3'b010);

        // =============================================================
        // MISALIGNMENT -- no bus transaction is ever issued (C11)
        // The SVA A2 property is the real checker; these sequences hold the
        // misaligned request up for several cycles so it has every chance
        // to leak onto the bus.
        // =============================================================
        @(negedge clk);
        clr(); vif.mem_read = 1; vif.mem_to_reg = 1; vif.reg_write = 1;
        vif.ex_result = 32'h2000_0002; vif.funct3 = `F3_W;   // misaligned word load
        repeat (6) tick();
        sb.chk ("misaligned_lw", "HTRANS stayed idle", vif.d_htrans, HTRANS_IDLE);
        sb.chk1("misaligned_lw", "no stall",           vif.mem_stall, 1'b0);
        sb.chk1("misaligned_lw", "no MEM exception (cause 4 is EX's)",
                vif.exc_valid, 1'b0);

        @(negedge clk);
        clr(); vif.mem_write = 1; vif.ex_result = 32'h2000_0001;
        vif.funct3 = `F3_H; vif.rs2_data = 32'hAAAA_5555;    // misaligned halfword store
        repeat (6) tick();
        sb.chk ("misaligned_sh", "HTRANS stayed idle", vif.d_htrans, HTRANS_IDLE);
        sb.chk1("misaligned_sh", "no MEM exception (cause 6 is EX's)",
                vif.exc_valid, 1'b0);

        // a BYTE access is never misaligned -- it must still go to the bus
        @(negedge clk);
        clr(); vif.mem_read = 1; vif.mem_to_reg = 1;
        vif.ex_result = 32'h2000_0003; vif.funct3 = `F3_B;
        #1;
        sb.chk("byte_at_odd_addr", "still issues", vif.d_htrans, HTRANS_NONSEQ);
        tick(); @(negedge clk); clr(); #1;

        // =============================================================
        // D-PORT WAIT STATES (Sec. 10.4 / 11.4)
        // =============================================================
        @(negedge clk);
        clr(); vif.mem_read = 1; vif.mem_to_reg = 1; vif.reg_write = 1;
        vif.ex_result = 32'h2000_0060; vif.funct3 = `F3_W;
        tick();                                     // address phase accepted
        @(negedge clk); vif.d_hready = 0; #1;
        repeat (3) begin
            sb.chk1("wait_states", "stalls",        vif.mem_stall, 1'b1);
            sb.chk1("wait_states", "no exception",  vif.exc_valid, 1'b0);
            tick();
        end
        @(negedge clk); vif.d_hready = 1; vif.d_hrdata = 32'h0BAD_C0DE; #1;
        sb.chk1("wait_states", "completes",     vif.mem_stall, 1'b0);
        sb.chk ("wait_states", "wb_data",       vif.wb_data,   32'h0BAD_C0DE);
        sb.chk1("wait_states", "retires",       vif.retire,    1'b1);

        // =============================================================
        // BUS ERROR -- causes 5 and 7 (C12, Sec. 14.1 / 14.2)
        // Both directions are run to the SAME address, so a swapped
        // mem_read/mem_write cause split cannot pass both.
        // =============================================================
        @(negedge clk);
        clr(); vif.mem_read = 1; vif.mem_to_reg = 1; vif.reg_write = 1;
        vif.ex_result = 32'h4000_0000; vif.funct3 = `F3_W; vif.pc_in = 32'h1000_0200;
        tick();
        @(negedge clk); vif.d_hready = 0; vif.d_hresp = 1; #1;   // ERROR cycle 1
        sb.chk1("load_fault", "quiet in cycle 1", vif.exc_valid, 1'b0);
        @(negedge clk); vif.d_hready = 1; vif.d_hresp = 1; #1;   // ERROR cycle 2
        sb.chk1("load_fault", "exception valid", vif.exc_valid, 1'b1);
        sb.chk ("load_fault", "cause 5",         vif.exc_cause, 4'd5);
        sb.chk ("load_fault", "mtval = address", vif.exc_mtval, 32'h4000_0000);
        sb.chk ("load_fault", "pc passed through", vif.exc_pc,  32'h1000_0200);
        sb.chk1("load_fault", "does not retire", vif.retire,    1'b0);
        @(negedge clk); clr(); #1;
        sb.chk1("load_fault", "clears", vif.exc_valid, 1'b0);

        @(negedge clk);
        clr(); vif.mem_write = 1; vif.ex_result = 32'h4000_0000;
        vif.funct3 = `F3_W; vif.rs2_data = 32'hFEED_FACE; vif.pc_in = 32'h1000_0300;
        tick();
        @(negedge clk); vif.d_hready = 0; vif.d_hresp = 1; #1;
        sb.chk1("store_fault", "quiet in cycle 1", vif.exc_valid, 1'b0);
        @(negedge clk); vif.d_hready = 1; vif.d_hresp = 1; #1;
        sb.chk1("store_fault", "exception valid", vif.exc_valid, 1'b1);
        sb.chk ("store_fault", "cause 7",         vif.exc_cause, 4'd7);
        sb.chk ("store_fault", "mtval = address", vif.exc_mtval, 32'h4000_0000);
        sb.chk ("store_fault", "pc passed through", vif.exc_pc,  32'h1000_0300);
        sb.chk1("store_fault", "does not retire", vif.retire,    1'b0);
        @(negedge clk); clr(); vif.d_hresp = 0; #1;

        // =============================================================
        // RETIRE TAG (Sec. 13.2)
        // =============================================================
        @(negedge clk); clr(); vif.valid = 1; vif.reg_write = 1; #1;
        sb.chk1("retire", "a valid instruction retires", vif.retire, 1'b1);
        @(negedge clk); clr(); vif.valid = 0; #1;
        sb.chk1("retire", "a bubble does not retire",    vif.retire, 1'b0);

        // =============================================================
        // RANDOMISED SOAK -- the SVA set is the checker. Requests are held
        // stable while stalled, mirroring the pipeline hold (Sec. 11.4).
        // =============================================================
        @(negedge clk); clr();
        repeat (800) begin
            @(negedge clk);
            if (!vif.mem_stall) begin
                bit do_load  = $urandom_range(0, 99) < 40;
                bit do_store = !do_load && ($urandom_range(0, 99) < 50);
                vif.mem_read   = do_load;
                vif.mem_write  = do_store;
                vif.mem_to_reg = do_load;
                vif.reg_write  = do_load;
                vif.valid      = $urandom_range(0, 99) < 90;
                vif.ex_result  = $urandom();
                vif.rs2_data   = $urandom();
                vif.rd_in      = $urandom_range(0, 31);
                vif.pc_in      = $urandom() & 32'hFFFF_FFFC;
                vif.funct3     = $urandom_range(0, 2);
            end
            vif.d_hrdata = $urandom();
            vif.d_hready = $urandom_range(0, 99) < 70;
            vif.d_hresp  = $urandom_range(0, 99) < 10;
            tick();
        end
        sb.pass("soak", "800 randomised MEM cycles with SVA armed");

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
