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

    localparam S_NORMAL = 1'b0;
    localparam S_ERR2   = 1'b1;   // the mandatory 2nd (dead) cycle of an error response

    reg state;

    // -----------------------------------------------------------------------
    // Combinational bus drive
    // -----------------------------------------------------------------------
    always @(*) begin
        if (state == S_ERR2) begin
            // Sec. 16.2: master drives IDLE during the error's 2nd cycle
            d_htrans_o = HTRANS_IDLE;
            d_haddr_o  = 32'b0;
            d_hwrite_o = 1'b0;
            d_hsize_o  = 3'b010;
            d_hwdata_o = 32'b0;
        end else if (start_i) begin
            d_htrans_o = HTRANS_NONSEQ;
            d_haddr_o  = addr_i;
            d_hwrite_o = hwrite_i;
            d_hsize_o  = hsize_i;
            d_hwdata_o = hwdata_i;
        end else begin
            d_htrans_o = HTRANS_IDLE;
            d_haddr_o  = 32'b0;
            d_hwrite_o = 1'b0;
            d_hsize_o  = 3'b010;
            d_hwdata_o = 32'b0;
        end
    end

    // -----------------------------------------------------------------------
    // State register
    // -----------------------------------------------------------------------
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state <= S_NORMAL;
        end else begin
            case (state)
                S_NORMAL: begin
                    if (start_i && d_hready_i && d_hresp_i)
                        state <= S_ERR2;    // error sampled -> one dead cycle
                    else
                        state <= S_NORMAL;  // no access, still waiting, or OKAY-done
                end
                S_ERR2: begin
                    state <= S_NORMAL;      // exactly one dead cycle, then resume
                end
                default: state <= S_NORMAL;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Control-facing status (Sec. 10.4, Sec. 11.4)
    // -----------------------------------------------------------------------
    assign ok_done_o    = (state == S_NORMAL) && start_i && d_hready_i && ~d_hresp_i;
    assign err_pulse_o  = (state == S_NORMAL) && start_i && d_hready_i &&  d_hresp_i;
    assign mem_stall_o  = ((state == S_NORMAL) && start_i && ~d_hready_i) ||
                           (state == S_ERR2);

endmodule

`default_nettype wire
