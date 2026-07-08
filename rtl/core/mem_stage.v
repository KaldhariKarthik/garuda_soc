`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// MEM Stage (top level) - instantiates the 3 sub-blocks shown on the core
// block diagram: Load/Store Unit, D-Port AHB master, Load Formatter.
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 5, Sec. 10, Sec. 11.4,
//                  Sec. 14.1, Sec. 14.2, Sec. 16
//
// Scope notes:
//   - mem_wb only carries wb_data/ctrl/rd (Sec. 5.2), so the mem_to_reg
//     mux (Sec. 10.3) happens HERE, not in WB: wb_data_o is already the
//     final value by the time it leaves this stage.
//   - d_hburst_o and d_hprot_o are static per the pin contract (Sec. 4.1:
//     D-port always SINGLE burst, always 0b0011 privileged/data) - tied
//     directly here rather than routed through a sub-block.
//   - mem_stall_o is the raw "D-port wait state" hold source (Sec. 11.4);
//     hold/flush *composition* against DSU-hold/load-use/branch-flush is
//     a separate block, same philosophy as ID stage's load_use_stall_o.
//   - mem_exception_* are raw fault signals; trap entry (mepc/mcause
//     sequencing) is CONTROL's job, not MEM's.
// =============================================================================

module mem_stage (
    input  wire         clk_i,
    input  wire         rst_n_i,

    // -------------------------------------------------------------------
    // From ex_mem pipeline register (Sec. 5.2 field list)
    // -------------------------------------------------------------------
    input  wire [31:0] ex_result_i,   // ALU/MUL/DSU/CSR result; address for load/store
    input  wire [31:0] rs2_data_i,    // forwarded store operand
    input  wire [2:0]  funct3_i,
    input  wire [4:0]  rd_i,
    input  wire [31:0] pc_i,           // ex_mem.pc — faulting instr PC for mepc (Sec.14.4)

    // Control bits needed in MEM (subset of the full ctrl bundle)
    input  wire         mem_read_i,
    input  wire         mem_write_i,
    input  wire         mem_to_reg_i,
    input  wire         reg_write_i,

    // -------------------------------------------------------------------
    // D-port AHB-Lite master pins (Sec. 4.1)
    // -------------------------------------------------------------------
    output wire [31:0] d_haddr_o,
    output wire [1:0]  d_htrans_o,
    output wire [2:0]  d_hsize_o,
    output wire [2:0]  d_hburst_o,
    output wire [3:0]  d_hprot_o,
    output wire         d_hwrite_o,
    output wire [31:0] d_hwdata_o,

    input  wire [31:0] d_hrdata_i,
    input  wire         d_hready_i,
    input  wire         d_hresp_i,

    // -------------------------------------------------------------------
    // Outputs to mem_wb pipeline register (Sec. 5.2)
    // -------------------------------------------------------------------
    output wire [31:0] wb_data_o,
    output wire         reg_write_o,
    output wire [4:0]  rd_o,

    // -------------------------------------------------------------------
    // Hold source (Sec. 11.4) - raw signal; composition is downstream
    // -------------------------------------------------------------------
    output wire         mem_stall_o,

    // -------------------------------------------------------------------
    // Raw exception outputs (Sec. 14.1 causes 4/5/6/7, Sec. 14.2 mtval)
    // -------------------------------------------------------------------
    output wire         mem_exception_valid_o,
    output wire [31:0] mem_exception_pc_o,   // -> CONTROL: mepc source on a MEM fault
    output wire [3:0]  mem_exception_cause_o,
    output wire [31:0] mem_exception_mtval_o
);

    // -----------------------------------------------------------------------
    // Sub-block 1: Load/Store Unit
    // -----------------------------------------------------------------------
    wire [2:0]  hsize_w;
    wire         load_misaligned_w;
    wire         store_misaligned_w;
    wire [31:0] hwdata_w;

    load_store_unit u_load_store_unit (
        .addr_i               (ex_result_i),
        .funct3_i              (funct3_i),
        .rs2_data_i            (rs2_data_i),

        .hsize_o               (hsize_w),
        .load_misaligned_o     (load_misaligned_w),
        .store_misaligned_o    (store_misaligned_w),
        .hwdata_o              (hwdata_w)
    );

    // Sec. 10.2: misalignment check completes before the address phase
    // commits - gate the bus start here, before the AHB master ever sees it.
    wire misaligned_load_w  = mem_read_i  & load_misaligned_w;
    wire misaligned_store_w = mem_write_i & store_misaligned_w;
    wire any_misaligned_w   = misaligned_load_w | misaligned_store_w;

    wire start_w = (mem_read_i | mem_write_i) & ~any_misaligned_w;

    // -----------------------------------------------------------------------
    // Sub-block 2: D-Port AHB-Lite master
    // -----------------------------------------------------------------------
    wire ok_done_w;
    wire err_pulse_w;

    d_port_ahb_master u_d_port_ahb_master (
        .clk_i        (clk_i),
        .rst_n_i      (rst_n_i),

        .start_i      (start_w),
        .hwrite_i     (mem_write_i),
        .addr_i       (ex_result_i),
        .hsize_i      (hsize_w),
        .hwdata_i     (hwdata_w),

        .d_haddr_o    (d_haddr_o),
        .d_htrans_o   (d_htrans_o),
        .d_hsize_o    (d_hsize_o),
        .d_hwrite_o   (d_hwrite_o),
        .d_hwdata_o   (d_hwdata_o),

        .d_hready_i   (d_hready_i),
        .d_hresp_i    (d_hresp_i),

        .mem_stall_o  (mem_stall_o),
        .ok_done_o    (ok_done_w),
        .err_pulse_o  (err_pulse_w)
    );

    // Static per the pin contract (Sec. 4.1): D-port always SINGLE burst,
    // always privileged/data protection.
    assign d_hburst_o = 3'b000;
    assign d_hprot_o  = 4'b0011;

    // -----------------------------------------------------------------------
    // Sub-block 3: Load Formatter
    // -----------------------------------------------------------------------
    wire [31:0] load_data_w;

    load_formatter u_load_formatter (
        .rdata_i        (d_hrdata_i),
        .addr_lsbs_i    (ex_result_i[1:0]),
        .funct3_i       (funct3_i),

        .load_data_o    (load_data_w)
    );

    // -----------------------------------------------------------------------
    // Sec. 10.3: mem_to_reg overrides the EX result with the formatted
    // load value. mem_wb only carries a single wb_data field (Sec. 5.2),
    // so this mux happens here, not in WB.
    // -----------------------------------------------------------------------
    assign wb_data_o  = mem_to_reg_i ? load_data_w : ex_result_i;
    assign reg_write_o = reg_write_i;
    assign rd_o         = rd_i;

    // -----------------------------------------------------------------------
    // Exception generation (Sec. 14.1 causes, Sec. 14.2 mtval)
    //   cause 4 - load address misaligned    mtval = misaligned load addr
    //   cause 5 - load access fault          mtval = faulting load addr
    //   cause 6 - store address misaligned   mtval = misaligned store addr
    //   cause 7 - store access fault         mtval = faulting store addr
    // Misalignment and a bus ERROR are mutually exclusive by construction:
    // a misaligned access never reaches the bus (start_w is gated), so
    // err_pulse_w can only fire on an access that was NOT misaligned.
    // -----------------------------------------------------------------------
    wire store_err_w = err_pulse_w & mem_write_i;
    wire load_err_w  = err_pulse_w & mem_read_i;

    // Misalignment is owned by EX (ex_stage kills the access and raises
    // load/store_misaligned, causes 4/6). MEM owns only bus access faults
    // (causes 5/7). start_w still gates on ~any_misaligned as belt-and-braces.
    assign mem_exception_pc_o = pc_i;
    assign mem_exception_valid_o = load_err_w | store_err_w;

    assign mem_exception_cause_o = load_err_w  ? 4'd5 :
                                    store_err_w ? 4'd7 :
                                    4'd0;

    assign mem_exception_mtval_o = ex_result_i;   // the load/store address in all 4 cases

endmodule

`default_nettype wire
