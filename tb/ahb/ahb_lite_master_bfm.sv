`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - VERIFICATION MODEL
// ahb_lite_master_bfm.sv - queue-driven AHB-Lite master bus functional model
//
// STATUS: verification only. Never synthesised, never instantiated by rtl/.
//
// Models a COMPLIANT AHB-Lite master, because the whole point of the
// interconnect tests is that the fabric behaves correctly against masters that
// obey the protocol. In particular it reproduces the two behaviours that the
// interconnect's hardest bug (ERRATUM AHB-2) turns on:
//
//   1. It presents the next address phase in the same cycle the previous
//      transfer's data phase is in flight, whenever its command queue is not
//      empty and gap==0. That is what makes a master "continuously requesting"
//      - the shape that starves a naive arbiter.
//   2. It holds HADDR/HTRANS/HSIZE/HBURST/HWRITE absolutely still while HREADY
//      is low, and completes its data phase only on HREADY high. So if the
//      interconnect ever drops a response, this BFM notices by never retiring
//      the transfer - and the scoreboard's expected-count check fails.
//
// It records every completed data phase into a response queue tagged with the
// address it belongs to, so a test can assert "master M's read of A returned
// D" rather than "some read somewhere returned D" - which is the check that
// actually catches a read-data mux steering data to the wrong master.
//
// Commands are pushed with push_xfer(). `gap` is the number of IDLE cycles to
// insert BEFORE presenting that transfer, which is how a test controls whether
// a master requests back-to-back or leaves the bus free.
// =============================================================================

module ahb_lite_master_bfm #(
    parameter integer QDEPTH = 256,
    parameter [3:0]   HPROT  = 4'b0011
)(
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    output reg  [31:0] haddr_o,
    output reg  [1:0]  htrans_o,
    output reg         hwrite_o,
    output reg  [2:0]  hsize_o,
    output reg  [2:0]  hburst_o,
    output wire [3:0]  hprot_o,
    output reg  [31:0] hwdata_o,

    input  wire [31:0] hrdata_i,
    input  wire        hready_i,
    input  wire        hresp_i
);

    localparam [1:0] T_IDLE   = 2'b00;
    localparam [1:0] T_NONSEQ = 2'b10;
    localparam [1:0] T_SEQ    = 2'b11;

    assign hprot_o = HPROT;

    // ---- command queue -----------------------------------------------------
    reg [31:0] q_addr  [0:QDEPTH-1];
    reg [31:0] q_wdata [0:QDEPTH-1];
    reg        q_write [0:QDEPTH-1];
    reg [2:0]  q_size  [0:QDEPTH-1];
    reg [2:0]  q_burst [0:QDEPTH-1];
    reg [1:0]  q_trans [0:QDEPTH-1];
    reg [7:0]  q_gap   [0:QDEPTH-1];
    integer    q_head, q_tail;

    // ---- response queue ----------------------------------------------------
    reg [31:0] r_addr  [0:QDEPTH-1];
    reg [31:0] r_data  [0:QDEPTH-1];
    reg        r_resp  [0:QDEPTH-1];
    reg        r_write [0:QDEPTH-1];
    integer    r_head, r_tail;

    // ---- bus-side state ----------------------------------------------------
    reg        addr_outstanding;   // presented, not yet accepted
    reg [31:0] addr_tag;
    reg        addr_is_write;
    reg [31:0] addr_wdata;

    reg        data_outstanding;   // accepted, response owed
    reg [31:0] data_tag;
    reg        data_is_write;

    reg [7:0]  gap_cnt;
    integer    issued, retired;

    wire addr_phase_done = addr_outstanding && hready_i;
    wire data_phase_done = data_outstanding && hready_i;
    wire q_empty         = (q_head == q_tail);

    // A new address phase may be presented when the bus is ready and the
    // previous one has been accepted (or is being accepted right now). This is
    // the same gating garuda_iport_ahb_master uses, deliberately.
    wire can_issue = hready_i && (!addr_outstanding || addr_phase_done) &&
                     !q_empty && (gap_cnt == 8'd0);

    task push_xfer;
        input [31:0] addr;
        input        write;
        input [31:0] wdata;
        input [2:0]  size;
        input [2:0]  burst;
        input [1:0]  trans;
        input [7:0]  gap;
        begin
            q_addr [q_tail] = addr;
            q_write[q_tail] = write;
            q_wdata[q_tail] = wdata;
            q_size [q_tail] = size;
            q_burst[q_tail] = burst;
            q_trans[q_tail] = trans;
            q_gap  [q_tail] = gap;
            q_tail = (q_tail + 1) % QDEPTH;
        end
    endtask

    function integer rsp_count;
        begin
            rsp_count = (r_tail - r_head + QDEPTH) % QDEPTH;
        end
    endfunction

    function [31:0] rsp_addr;  input integer i; begin rsp_addr = r_addr[(r_head+i)%QDEPTH]; end endfunction
    function [31:0] rsp_data;  input integer i; begin rsp_data = r_data[(r_head+i)%QDEPTH]; end endfunction
    function        rsp_resp;  input integer i; begin rsp_resp = r_resp[(r_head+i)%QDEPTH]; end endfunction
    function        rsp_write; input integer i; begin rsp_write = r_write[(r_head+i)%QDEPTH]; end endfunction

    task rsp_clear; begin r_head = 0; r_tail = 0; end endtask

    function integer xfers_issued;  begin xfers_issued  = issued;  end endfunction
    function integer xfers_retired; begin xfers_retired = retired; end endfunction
    function        busy;
        begin
            busy = (!q_empty) || addr_outstanding || data_outstanding;
        end
    endfunction

    integer qi;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            haddr_o          <= 32'b0;
            htrans_o         <= T_IDLE;
            hwrite_o         <= 1'b0;
            hsize_o          <= 3'b010;
            hburst_o         <= 3'b000;
            hwdata_o         <= 32'b0;
            addr_outstanding <= 1'b0;
            addr_tag         <= 32'b0;
            addr_is_write    <= 1'b0;
            addr_wdata       <= 32'b0;
            data_outstanding <= 1'b0;
            data_tag         <= 32'b0;
            data_is_write    <= 1'b0;
            gap_cnt          <= 8'd0;
            q_head           <= 0;
            q_tail           <= 0;
            r_head           <= 0;
            r_tail           <= 0;
            issued           <= 0;
            retired          <= 0;
        end else begin
            // ---- data-phase bookkeeping ----
            if (data_phase_done) begin
                r_addr [r_tail] <= data_tag;
                r_data [r_tail] <= hrdata_i;
                r_resp [r_tail] <= hresp_i;
                r_write[r_tail] <= data_is_write;
                r_tail          <= (r_tail + 1) % QDEPTH;
                retired         <= retired + 1;
            end

            if (addr_phase_done) begin
                data_outstanding <= 1'b1;
                data_tag         <= addr_tag;
                data_is_write    <= addr_is_write;
                hwdata_o         <= addr_wdata;   // drive it in the data phase
            end else if (data_phase_done) begin
                data_outstanding <= 1'b0;
            end

            // ---- address-phase drive ----
            if (can_issue) begin
                haddr_o          <= q_addr [q_head];
                htrans_o         <= q_trans[q_head];
                hwrite_o         <= q_write[q_head];
                hsize_o          <= q_size [q_head];
                hburst_o         <= q_burst[q_head];
                addr_outstanding <= 1'b1;
                addr_tag         <= q_addr [q_head];
                addr_is_write    <= q_write[q_head];
                addr_wdata       <= q_wdata[q_head];
                gap_cnt          <= q_gap  [q_head];
                q_head           <= (q_head + 1) % QDEPTH;
                issued           <= issued + 1;
            end else if (addr_outstanding && !addr_phase_done) begin
                // HREADY low: hold HADDR and every control signal untouched.
                // No assignment here on purpose.
                ;
            end else begin
                // Nothing to present: go IDLE, and burn a gap cycle if one was
                // requested for the NEXT transfer.
                htrans_o         <= T_IDLE;
                addr_outstanding <= 1'b0;
                if (gap_cnt != 8'd0 && hready_i) gap_cnt <= gap_cnt - 8'd1;
            end
        end
    end

    // Referenced so lint does not flag it; the loop variable is used only by
    // the tasks above.
    initial qi = 0;

endmodule
