// =============================================================================
// GARUDA SoC - Blocks 3/4/5 : shared AHB-Lite slave front end for the memories
// ahb_mem_slave_if.v
//
// Spec: GARUDA-MEM-SPEC-001 Rev 2.0 (Rev 4.0 set) Sec.5, Sec.7.1-Sec.7.4, Sec.9
//
// -----------------------------------------------------------------------------
// ZERO WAIT STATES ON A SYNCHRONOUS-READ MACRO ([N-7.6])
// -----------------------------------------------------------------------------
// The macro (sram_wrapper.v) samples its address on a clock edge and returns
// data the following cycle. A READ therefore drives the macro straight from
// HADDR in the AHB address phase, and the data lands in the data phase - no
// stall.
//
// A WRITE's data only arrives in its data phase, so a write needs the macro in
// the data phase. If the next transfer is a read, its address phase wants the
// macro in that same cycle: two accesses, one port. The standard resolution is
// used - a one-entry WRITE BUFFER:
//
//   * the port is "busy" in a cycle only if a read address phase is accepted;
//   * a write in its data phase goes straight to the macro if the port is free
//     and the buffer is empty; otherwise it is parked in the buffer;
//   * a parked write commits in the next cycle where the port is free;
//   * a read whose word matches the parked write gets the parked bytes merged
//     over the macro data (read-after-write bypass).
//
// The buffer never needs to hold two writes: the cycle before any write's data
// phase is that write's own address phase, which is not a read, so the port is
// free then and any parked write has committed.
//
// -----------------------------------------------------------------------------
// ERRORS (Rev 4.0)
// -----------------------------------------------------------------------------
// Two-cycle ERROR, no array effect, for:
//   - misaligned WORD/HALF, or HSIZE wider than a word  ([N-7.4] backstop)
//   - a write to a read-only memory (Boot ROM, MEM Sec.5.3)
//   - a write to ISRAM while ILOCK is set and the master is not the Debug SBA
//     ([N-7.8], [N-7.9]); reads are never affected ([N-7.10])
// Addresses above the memory's size alias down ([N-7.2]); there is no depth
// check.
// =============================================================================

module ahb_mem_slave_if
    import garuda_pkg::*;
    import mem_pkg::*;
#(
    // word-address width into the array
    parameter integer ADDR_W       = 32'd14,
    parameter integer WRITABLE = 32'd1  // 0 = ROM: writes get ERROR
)(
    input wire hclk,
    input wire hreset_n,
    input wire hsel_i,
    input wire [WORD_W-1:0] haddr_i,
    input wire [HTRANS_W-1:0] htrans_i,
    input wire hwrite_i,
    input wire [HSIZE_W-1:0] hsize_i,
    input wire [WORD_W-1:0] hwdata_i,
    input wire hready_i,  // global HREADY
    output wire [WORD_W-1:0] hrdata_o,
    output wire hreadyout_o,
    output wire hresp_o,
    input wire wr_lock_i,  // ILOCK (ISRAM only; tie 0 elsewhere)
    input wire lock_bypass_i,  // hmaster_is_sba (address phase)
    // ---- macro port (sram_wrapper) ------------------------------------------
    output wire arr_ce_o,
    output wire [ADDR_W - 1:0] arr_addr_o,
    output wire arr_we_o,
    output wire [BE_W-1:0] arr_be_o,
    output wire [WORD_W-1:0] arr_wdata_o,
    // data for the read issued last cycle
    input wire [WORD_W-1:0] arr_rdata_i
);
    timeunit 1ns;
    timeprecision 1ps;

    // =========================================================================
    // Address phase
    // =========================================================================
    wire accept = hsel_i & hready_i & htrans_i[1];

    wire misaligned = (hsize_i == MEM_SIZE_WORD && haddr_i[1:0] != 2'b00) ||
                      (hsize_i == MEM_SIZE_HALF && haddr_i[0])            ||
                      (hsize_i >  MEM_SIZE_WORD);
    wire ro_write   = hwrite_i && (WRITABLE == 0);
    wire lock_write = hwrite_i && wr_lock_i && !lock_bypass_i;
    wire ap_err     = misaligned | ro_write | lock_write;

    wire [ADDR_W-1:0] ap_word = haddr_i[ADDR_W+1:2];
    wire          rd_now  = accept && !hwrite_i && !ap_err;  // port busy

    // =========================================================================
    // Data-phase registers (advance only when the bus advances)
    // =========================================================================
    reg dp_valid;
    reg dp_write;
    reg dp_err;
    reg [ADDR_W-1:0] dp_word;
    reg [BE_W-1:0]    dp_be;

    reg [BE_W-1:0] ap_be;
    always_comb begin : c_ap_be
        case (hsize_i)
            MEM_SIZE_BYTE: ap_be = 4'b0001 << haddr_i[1:0];
            MEM_SIZE_HALF: ap_be = haddr_i[1] ? 4'b1100 : 4'b0011;
            default: ap_be = 4'b1111;
        endcase
    end

    always_ff @(posedge hclk or negedge hreset_n) begin : p_dp_valid
        if (!hreset_n) begin
            dp_valid <= 1'b0;
            dp_write <= 1'b0;
            dp_err <= 1'b0;
            dp_word <= {ADDR_W {1'b0}};
            dp_be <= 4'b0000;
        end else if (hready_i) begin
            dp_valid <= accept;
            if (accept) begin
                dp_write <= hwrite_i;
                dp_err <= ap_err;
                dp_word <= ap_word;
                dp_be <= ap_be;
            end
        end
    end

    // =========================================================================
    // Two-cycle ERROR
    // =========================================================================
    reg err2_q;
    always_ff @(posedge hclk or negedge hreset_n) begin : p_err
        if (!hreset_n) begin
            err2_q <= 1'b0;
        end else begin
            err2_q <= dp_valid && dp_err && !err2_q;
        end
    end

    wire err_first = dp_valid && dp_err && !err2_q;
    assign hreadyout_o = ~err_first;
    assign hresp_o     = dp_valid && dp_err;

    // =========================================================================
    // Write buffer
    // =========================================================================
    // write data phase
    wire wr_dp = dp_valid && dp_write && !dp_err && hready_i;

    reg          wb_v;
    reg [ADDR_W-1:0] wb_word;
    reg [BE_W-1:0]    wb_be;
    reg [WORD_W-1:0]   wb_data;

    // Port use this cycle, in priority order: read address phase, parked write,
    // direct write.
    wire commit_wb = wb_v && !rd_now;
    wire direct_wr = wr_dp && !rd_now && !wb_v;
    wire park_wr   = wr_dp && !direct_wr;

    always_ff @(posedge hclk or negedge hreset_n) begin : p_wb_v
        if (!hreset_n) begin
            wb_v <= 1'b0;
            wb_word <= {ADDR_W {1'b0}};
            wb_be <= 4'b0000;
            wb_data <= 32'b00000000000000000000000000000000;
        end else begin
            if (park_wr) begin
                wb_v <= 1'b1;
                wb_word <= dp_word;
                wb_be <= dp_be;
                wb_data <= hwdata_i;
            end else if (commit_wb) begin
                wb_v <= 1'b0;
            end
        end
    end

    assign arr_ce_o    = rd_now | commit_wb | direct_wr;
    assign arr_we_o    = !rd_now && (commit_wb || direct_wr);
    assign arr_addr_o  = rd_now ? ap_word : (commit_wb ? wb_word : dp_word);
    assign arr_be_o    = commit_wb ? wb_be   : dp_be;
    assign arr_wdata_o = commit_wb ? wb_data : hwdata_i;

    // =========================================================================
    // Read return with read-after-write bypass
    // =========================================================================
    wire        rd_dp = dp_valid && !dp_write && !dp_err;
    wire        byp   = wb_v && (wb_word == dp_word);
    wire [WORD_W-1:0] wr_merged = {
        (byp && wb_be[3]) ? wb_data[31:24] : arr_rdata_i[31:24],
        (byp && wb_be[2]) ? wb_data[23:16] : arr_rdata_i[23:16],
        (byp && wb_be[1]) ? wb_data[15: 8] : arr_rdata_i[15: 8],
        (byp && wb_be[0]) ? wb_data[ 7: 0] : arr_rdata_i[ 7: 0] };

    assign hrdata_o = rd_dp ? wr_merged : 32'h00000000;

`ifndef SYNTHESIS
    always_ff @(posedge hclk) begin : p_blk
        if (hreset_n && park_wr && wb_v && !commit_wb) begin
            $display("[MEM-ASSERT] write buffer overflow at %0t", $time);
        end
    end
`endif

endmodule
