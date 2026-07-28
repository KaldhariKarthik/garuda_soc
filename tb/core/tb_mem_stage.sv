`timescale 1ns/1ps

module tb_mem_stage;

    // -------------------------------------------------------------------------
    // Clock and Reset Generation
    // -------------------------------------------------------------------------
    bit clk;
    bit rst_n;

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT Interface Signals
    // -------------------------------------------------------------------------
    // Inputs from Pipeline Control/EX-MEM Registers
    logic [31:0] ex_result;
    logic [2:0]  funct3;
    logic        mem_read;
    logic        mem_write;
    logic [31:0] rs2_data;
    logic        reg_write_i;
    logic [4:0]  rd_i;
    logic        mem_to_reg_i;

    // AHB-Lite Bus Interface (Fabric Side Inputs)
    logic        d_hready_i;
    logic        d_hresp_i;
    logic [31:0] d_hrdata_i;

    // Outputs to WB Stage / Pipeline Stall Management
    wire [31:0] d_haddr_o;
    wire        d_hwrite_o;
    wire [2:0]  d_hsize_o;
    wire [2:0]  d_hburst_o;
    wire [3:0]  d_hprot_o;
    wire [31:0] d_hwdata_o;
    wire [1:0]  d_htrans_o;

    wire [31:0] wb_data_o;
    wire        reg_write_o;
    wire [4:0]  rd_o;
    wire        mem_stall_o;

    wire        mem_exception_valid_o;
    wire [3:0]  mem_exception_cause_o;
    wire [31:0] mem_exception_mtval_o;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    mem_stage dut (
        .clk_i                   (clk),
        .rst_n_i                 (rst_n),
        .ex_result_i             (ex_result),
        .funct3_i                (funct3),
        .mem_read_i              (mem_read),
        .mem_write_i             (mem_write),
        .rs2_data_i              (rs2_data),
        .reg_write_i             (reg_write_i),
        .rd_i                    (rd_i),
        .mem_to_reg_i            (mem_to_reg_i),
       
        .d_hready_i              (d_hready_i),
        .d_hresp_i               (d_hresp_i),
        .d_hrdata_i              (d_hrdata_i),
       
        .d_haddr_o               (d_haddr_o),
        .d_hwrite_o              (d_hwrite_o),
        .d_hsize_o               (d_hsize_o),
        .d_hburst_o              (d_hburst_o),
        .d_hprot_o               (d_hprot_o),
        .d_hwdata_o              (d_hwdata_o),
        .d_htrans_o              (d_htrans_o),
       
        .wb_data_o               (wb_data_o),
        .reg_write_o             (reg_write_o),
        .rd_o                    (rd_o),
        .mem_stall_o             (mem_stall_o),
       
        .mem_exception_valid_o   (mem_exception_valid_o),
        .mem_exception_cause_o   (mem_exception_cause_o),
        .mem_exception_mtval_o   (mem_exception_mtval_o)
    );

    // -------------------------------------------------------------------------
    // SystemVerilog Concurrent Assertions (SVA)
    // -------------------------------------------------------------------------
    assert_static_burst: assert property (@(posedge clk) disable iff(!rst_n) d_hburst_o == 3'b000);
    assert_static_prot:  assert property (@(posedge clk) disable iff(!rst_n) d_hprot_o  == 4'b0011);

    property p_load_misaligned_gate;
        @(posedge clk) disable iff(!rst_n)
        (mem_read && ((funct3[1:0] == 2'b01 && ex_result[0]) || (funct3[1:0] == 2'b10 && (|ex_result[1:0]))))
        |-> (d_htrans_o == 2'b00);
    endproperty
    assert_load_misaligned_gate: assert property(p_load_misaligned_gate) else $error("SVA Error: Transaction issued during a load misalignment!");

    property p_store_misaligned_gate;
        @(posedge clk) disable iff(!rst_n)
        (mem_write && ((funct3[1:0] == 2'b01 && ex_result[0]) || (funct3[1:0] == 2'b10 && (|ex_result[1:0]))))
        |-> (d_htrans_o == 2'b00);
    endproperty
    assert_store_misaligned_gate: assert property(p_store_misaligned_gate) else $error("SVA Error: Transaction issued during a store misalignment!");

    property p_stall_assertion;
        @(posedge clk) disable iff(!rst_n)
        ((mem_read || mem_write) && !mem_exception_valid_o && !d_hready_i) |-> mem_stall_o;
    endproperty
    assert_stall: assert property(p_stall_assertion) else $error("SVA Error: Pipeline failed to assert mem_stall_o during wait-state!");

    // -------------------------------------------------------------------------
    // Functional Coverage Model
    // -------------------------------------------------------------------------
    covergroup cg_mem_stage @(posedge clk);
        option.per_instance = 1;

        cp_size: coverpoint funct3[1:0] {
            bins size_byte = {2'b00};
            bins size_half = {2'b01};
            bins size_word = {2'b10};
        }

        cp_extension: coverpoint funct3[2] {
            bins sign_extended = {1'b0};
            bins zero_extended = {1'b1};
        }

        cp_exceptions: coverpoint mem_exception_cause_o iff (mem_exception_valid_o) {
            bins load_misaligned  = {4};  
            bins load_bus_error   = {5};  
            bins store_misaligned = {6};  
            bins store_bus_error  = {7};  
        }

        cross_op_ready: cross cp_size, mem_read, d_hready_i;
    endgroup

    cg_mem_stage cov_inst = new();

    // -------------------------------------------------------------------------
    // OOP Verification: Constrained Random Stimulus Class
    // -------------------------------------------------------------------------
    class mem_transaction;
        rand bit [31:0] address;
        rand bit [2:0]  f3;
        rand bit        rd_en;
        rand bit        wr_en;
        rand bit [31:0] store_data;

        constraint op_exclusive {
            // Guarantee balanced distribution of read, write, and idle
            !(rd_en && wr_en);
        }

        constraint operations_dist {
            rd_en dist {1 := 45, 0 := 55};
            wr_en dist {1 := 45, 0 := 55};
            f3 inside {3'b000, 3 me_b001, 3'b010, 3'b100, 3'b101};
        }

        constraint address_distribution {
            address inside {[32'h0000_1000 : 32'h0000_2000]};
        }
    endclass

    // -------------------------------------------------------------------------
    // Checking Infrastructure
    // -------------------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task check_assert(string name, bit condition);
        if (condition) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("FAIL Corner Case: %s [Time: %0t ns]", name, $time);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Test Matrix Controller
    // -------------------------------------------------------------------------
    initial begin
        // Reset Setup Configuration
        rst_n        = 0;
        ex_result    = 0;
        funct3       = 0;
        mem_read     = 0;
        mem_write    = 0;
        rs2_data     = 0;
        reg_write_i  = 0;
        rd_i         = 0;
        mem_to_reg_i = 0;
        d_hready_i   = 1;
        d_hresp_i    = 0;
        d_hrdata_i   = 0;

        #20;
        rst_n = 1;
       
        @(posedge clk);
        $display("\n=== STARTING MEM_STAGE 100%% FUNCTIONAL COVERAGE SUITE ===");

        // ---------------------------------------------------------
        // TC1: Load Alignment Extraction & Extension Formats
        // ---------------------------------------------------------
        $display("TC1: Testing Load Formatting (LB, LH, LW, LBU, LHU) Lane Extraction...");
       
        @(negedge clk);
        mem_read     = 1'b1;
        mem_to_reg_i = 1'b1;
        funct3       = 3'b000; // LB
        ex_result    = 32'h0000_1001;
        d_hrdata_i   = 32'hFFFF_8A00;
        d_hready_i   = 1'b1;
       
        @(posedge clk); #2;
        check_assert("LB_sign_extension", wb_data_o === 32'hFFFF_FF8A);

        @(negedge clk);
        funct3       = 3'b100; // LBU
        @(posedge clk); #2;
        check_assert("LBU_zero_extension", wb_data_o === 32'h0000_008A);

        @(negedge clk);
        funct3       = 3'b001; // LH
        ex_result    = 32'h0000_1002;
        d_hrdata_i   = 32'h9B23_0000;
        @(posedge clk); #2;
        check_assert("LH_sign_extension", wb_data_o === 32'hFFFF_9B23);

        @(negedge clk);
        funct3       = 3'b101; // LHU
        ex_result    = 32'h0000_1002;
        d_hrdata_i   = 32'h9B23_0000;
        @(posedge clk); #2;
        check_assert("LHU_zero_extension", wb_data_o === 32'h0000_9B23);

        // ---------------------------------------------------------
        // TC2: Store Data Vector Shifting & Lane Alignment
        // ---------------------------------------------------------
        $display("TC2: Testing Store Data Vector Shifting Muxing (SB, SH, SW)...");
        @(negedge clk);
        mem_read     = 1'b0;
        mem_write    = 1'b1;
       
        // SB to byte lane 3
        funct3       = 3'b000; // SB
        ex_result    = 32'h0000_1003;
        rs2_data     = 32'h1234_5678;
        #2;
        check_assert("SB_lane_shifting", d_hwdata_o === 32'h7800_0000);

        @(negedge clk);
        // SH to halfword lane 2
        funct3       = 3'b001; // SH
        ex_result    = 32'h0000_1002;
        #2;
        check_assert("SH_lane_shifting", d_hwdata_o === 32'h5678_0000);

        @(negedge clk);
        // SW full word
        funct3       = 3'b010; // SW
        ex_result    = 32'h0000_1000;
        #2;
        check_assert("SW_word_passthrough", d_hwdata_o === 32'h1234_5678);

        // ---------------------------------------------------------
        // TC3: AHB Wait State Protocol & Multi-Cycle Stalling
        // ---------------------------------------------------------
        $display("TC3: Testing AHB Multi-Cycle Wait State Infrastructure Stalling...");
        @(negedge clk);
        mem_write    = 1'b0;
        mem_read     = 1'b1;
        funct3       = 3'b010; // LW
        ex_result    = 32'h0000_2000;
        d_hready_i   = 1'b0;  
       
        // Hold stall across 2 clock edges
        @(posedge clk); #2;
        check_assert("Stall_assert_high_cycle1", mem_stall_o === 1'b1);
        @(posedge clk); #2;
        check_assert("Stall_assert_high_cycle2", mem_stall_o === 1 me_b1);

        @(negedge clk);
        d_hready_i   = 1'b1;
        d_hrdata_i   = 32'hC0DE_BABE;
       
        @(posedge clk); #2;
        check_assert("Stall_release", mem_stall_o === 1'b0);
        check_assert("LW_captured", wb_data_o === 32'hC0DE_BABE);

        // ---------------------------------------------------------
        // TC4: Memory Addressing Misalignment Fault Exceptions
        // ---------------------------------------------------------
        $display("TC4: Testing Memory Addressing Misalignment Exceptions (Load/Store)...");
        @(negedge clk);
        mem_read     = 1'b1;
        funct3       = 3'b001; // LH
        ex_result    = 32'h0000_1005;
        #2;
        check_assert("Load_misaligned_valid", mem_exception_valid_o === 1'b1);
        check_assert("Load_misaligned_cause", mem_exception_cause_o === 4'd4);
        check_assert("Load_misaligned_mtval", mem_exception_mtval_o === 32'h0000_1005);
        check_assert("Bus_gated_idle",        d_htrans_o === 2'b00);

        @(negedge clk);
        mem_read     = 1'b0;
        mem_write    = 1'b1;
        funct3       = 3'b010; // SW
        ex_result    = 32'h0000_1002;
        #2;
        check_assert("Store_misaligned_valid", mem_exception_valid_o === 1'b1);
        check_assert("Store_misaligned_cause", mem_exception_cause_o === 4'd6);
        check_assert("Store_misaligned_mtval", mem_exception_mtval_o === 32'h0000_1002);

        // ---------------------------------------------------------
        // TC5: Two-Cycle AMBA AHB Bus Error Protocol (Load and Store)
        // ---------------------------------------------------------
        $display("TC5: Testing Bus Error Responses (Cause 5 & Cause 7)...");
        
        // --- 5A: Load Bus Error (Cause 5) ---
        @(negedge clk);
        mem_write    = 1'b0;
        mem_read     = 1'b1;
        funct3       = 3'b010; // LW
        ex_result    = 32'h0000_3000;
        d_hready_i   = 1'b0;
        d_hresp_i    = 1'b1;

        @(posedge clk);
        @(negedge clk);
        d_hready_i   = 1'b1;
       
        @(posedge clk);
        check_assert("Load_bus_error_valid", mem_exception_valid_o === 1'b1);
        check_assert("Load_bus_error_cause", mem_exception_cause_o === 4'd5);
       
        @(posedge clk); #2;
        check_assert("FSM_recovery_cycle_1", mem_stall_o === 1'b0);

        // --- 5B: Store Bus Error (Cause 7) ---
        @(negedge clk);
        d_hresp_i    = 1'b0;
        mem_read     = 1'b0;
        mem_write    = 1'b1;
        funct3       = 3'b010; // SW
        ex_result    = 32'h0000_4000;
        d_hready_i   = 1'b0;
        d_hresp_i    = 1 me_b1;

        @(posedge clk);
        @(negedge clk);
        d_hready_i   = 1'b1;

        @(posedge clk);
        check_assert("Store_bus_error_valid", mem_exception_valid_o === 1'b1);
        check_assert("Store_bus_error_cause", mem_exception_cause_o === 4'd7);

        @(posedge clk); #2;
        d_hresp_i    = 1'b0;
        mem_write    = 1'b0;

        // ---------------------------------------------------------
        // TC6: Explicit Sweep to Guarantee 100% Functional Cross Coverage
        // ---------------------------------------------------------
        $display("TC6: Sweeping all cross_op_ready bins (cp_size x mem_read x d_hready)...");
        begin
            bit [1:0] sizes[3]  = '{2'b00, 2'b01, 2'b10};
            bit       reads[2]  = '{1'b0, 1'b1};
            bit       readys[2] = '{1'b0, 1'b1};

            foreach (sizes[i]) begin
                foreach (reads[j]) begin
                    foreach (readys[k]) begin
                        @(negedge clk);
                        funct3     = {1'b0, sizes[i]};
                        mem_read   = reads[j];
                        mem_write  = ~reads[j];
                        ex_result  = 32'h0000_1000; // Aligned address
                        d_hready_i = readys[k];
                        d_hresp_i  = 1'b0;
                        @(posedge clk); #1;
                    end
                end
            end
        end

        // ---------------------------------------------------------
        // TC7: Dynamic Constrained Random Simulation Verification
        // ---------------------------------------------------------
        $display("TC7: Injecting Dense Constrained Random Transfers...");
        begin
            mem_transaction tx;
            tx = new();
            repeat (500) begin
                if (!tx.randomize()) $fatal(1, "Randomization failed inside MEM Suite!");
               
                @(negedge clk);
                ex_result    = tx.address;
                funct3       = tx.f3;
                mem_read     = tx.rd_en;
                mem_write    = tx.wr_en;
                rs2_data     = tx.store_data;
                d_hready_i   = ($random % 3 == 0) ? 1'b0 : 1'b1;
                d_hresp_i    = 1'b0;

                @(posedge clk); #1;
            end
        end

        // ---------------------------------------------------------
        // Compilation Reports
        // ---------------------------------------------------------
        $display("\n=============================================");
        $display("SIMULATION COMPLETED");
        $display("Functional Coverage achieved: %0.2f%%", cov_inst.get_inst_coverage());
        $display("TOTAL CHECKPOINTS PASSED: %0d", pass_count);
        $display("TOTAL CHECKPOINTS FAILED: %0d", fail_count);
        $display("=============================================");
       
        if (fail_count == 0) begin
            $display("RESULT: ALL TESTCASES AND CORNER CASES PASSED!");
        end else begin
            $display("RESULT: EXCEPTION OR PROTOCOL MISMATCH ENCOUNTERED.");
        end
        $finish;
    end

endmodule
