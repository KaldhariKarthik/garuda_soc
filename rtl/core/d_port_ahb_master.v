`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core - MEM Stage, Sub-block 2/3
// D-Port AHB-Lite master  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 10.4, Sec. 16.1 - 16.3
//
// The D-port issues only SINGLE transfers (Sec. 16.2) - no bursts, no
// pipelined back-to-back addressing. Because the pipeline stall (Sec. 11.4,
// D-port wait state) holds everything upstream of MEM for the whole access,
// ex_result_i/rs2_data_i/etc. from the ex_mem register stay stable for the
// entire transaction, including any wait states - so this FSM does not need
// to latch its own copy of the address/control; it just keeps re-driving
// the stable upstream values every cycle until HREADY completes the phase.
//
// HRESP=ERROR is the two-cycle AMBA error response (Sec. 16.2): the master
// accepts the error cycle, then drives one dead IDLE cycle before any new
// transaction can start. err_pulse_o fires in the cycle the error is
// sampled (HREADY=1, HRESP=ERROR) - CONTROL can begin trap redirect that
// same cycle; the FSM's own dead cycle is a bus-protocol formality that a
// flush will supersede anyway (Sec. 11.4: flush wins over hold).
//
// Reset/idle (Sec. 16.3): out of reset, HTRANS=IDLE.
// =============================================================================

module d_port_ahb_master (
    input  wire         clk_i,
    input  wire         rst_n_i,

    // Qualified request from Load/Store Unit + top-level misalign gating
    input  wire          start_i,       // (mem_read | mem_write) & ~misaligned
    input  wire          hwrite_i,
    input  wire [31:0]  addr_i,
    input  wire [2:0]   hsize_i,
    input  wire [31:0]  hwdata_i,

    // AHB-Lite D-port master pins (Sec. 4.1 pin table)
    output reg  [31:0]  d_haddr_o,
    output reg  [1:0]   d_htrans_o,
    output reg  [2:0]   d_hsize_o,
    output reg           d_hwrite_o,
    output reg  [31:0]  d_hwdata_o,

    input  wire          d_hready_i,
    input  wire          d_hresp_i,

    // Control-facing outputs
    output wire         mem_stall_o,   // Sec. 11.4 D-port wait-state hold
    output wire         ok_done_o,     // this cycle's access completed OKAY
    output wire         err_pulse_o    // this cycle's access completed ERROR
);

    localparam HTRANS_IDLE   = 2'b00;
    localparam HTRANS_NONSEQ = 2'b10;

    // -----------------------------------------------------------------------
    // ERRATUM D-1 (found by tb_boot, same root cause as ERRATUM I-1)
    // -----------------------------------------------------------------------
    // This module previously completed a transfer in its ADDRESS phase: it
    // drove HADDR/HTRANS/HWDATA together from one combinational block and
    // raised ok_done_o/err_pulse_o (and dropped mem_stall_o) on
    // `start_i && d_hready_i`. AHB-Lite does not work that way - the data
    // phase is the cycle AFTER the address phase is accepted. Two distinct
    // failures followed:
    //
    //   STORES: HWDATA was driven during the address phase. Once the address
    //     phase completed the pipeline advanced, start_i fell, and HWDATA
    //     collapsed to 0 in the very cycle the slave samples it. Every store
    //     wrote zero. tb_boot caught this as "sw x5,0(x4) retires, tohost
    //     stays 0, test hangs" - the store executed perfectly and stored
    //     nothing.
    //
    //   LOADS: mem_stall_o dropped in the address phase, so load_formatter
    //     sampled d_hrdata_i one cycle before the slave drove it. Every load
    //     returned the previous bus cycle's data. Nothing had caught this
    //     because no testbench had ever issued a real load.
    //
    // The header's old claim - that the upstream pipeline hold keeps operands
    // stable so the FSM "does not need to latch its own copy" - is true for
    // HADDR/HSIZE but false for HWDATA, because the hold itself is released
    // by the very event (address phase accepted) that starts the data phase.
    //
    // A D-port access is therefore a minimum of TWO cycles: address, then
    // data. That is inherent to AHB-Lite with no write buffer, not a
    // regression in throughput that can be optimised away here.
    // -----------------------------------------------------------------------
    localparam S_ADDR = 2'd0;   // idle / presenting an address phase
    localparam S_DATA = 2'd1;   // address accepted, data phase in progress

    reg [1:0] state;

    // -----------------------------------------------------------------------
    // Combinational address-phase drive
    // Gated on S_ADDR: start_i is still asserted during the data phase (MEM is
    // held), and re-presenting HTRANS=NONSEQ then would issue a second,
    // spurious transfer to the same address.
    // -----------------------------------------------------------------------
    always @(*) begin
        if ((state == S_ADDR) && start_i) begin
            d_htrans_o = HTRANS_NONSEQ;
            d_haddr_o  = addr_i;
            d_hwrite_o = hwrite_i;
            d_hsize_o  = hsize_i;
        end else begin
            d_htrans_o = HTRANS_IDLE;
            d_haddr_o  = 32'b0;
            d_hwrite_o = 1'b0;
            d_hsize_o  = 3'b010;
        end
    end

    // -----------------------------------------------------------------------
    // State register
    // -----------------------------------------------------------------------
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state      <= S_ADDR;
            d_hwdata_o <= 32'b0;
        end else begin
            case (state)
                S_ADDR: begin
                    if (start_i && d_hready_i) begin
                        // Address phase accepted; capture the write data so it
                        // is driven in the data phase that starts next cycle,
                        // and holds there across any wait states.
                        d_hwdata_o <= hwdata_i;
                        state      <= S_DATA;
                    end
                end
                S_DATA: begin
                    // The slave signals ERROR as the AMBA two-cycle response
                    // (HREADY=0/HRESP=1, then HREADY=1/HRESP=1), so waiting
                    // for HREADY here absorbs the dead cycle - no separate
                    // master-side S_ERR2 state is needed. HTRANS is already
                    // IDLE throughout the data phase.
                    if (d_hready_i)
                        state <= S_ADDR;
                end
                default: state <= S_ADDR;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Control-facing status (Sec. 10.4, Sec. 11.4)
    // Completion is a DATA-phase event: ok_done_o fires in the same cycle the
    // slave presents valid HRDATA, which is the cycle load_formatter samples
    // it and MEM/WB captures the result.
    // -----------------------------------------------------------------------
    assign ok_done_o    = (state == S_DATA) && d_hready_i && ~d_hresp_i;
    assign err_pulse_o  = (state == S_DATA) && d_hready_i &&  d_hresp_i;

    // Hold MEM for the address phase and for the data phase, releasing only
    // in the cycle the data phase completes.
    assign mem_stall_o  = ((state == S_ADDR) && start_i) ||
                          ((state == S_DATA) && ~d_hready_i);

endmodule

`default_nettype wire
