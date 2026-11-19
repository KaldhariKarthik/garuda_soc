// =============================================================================
// GARUDA SoC - Block 5 : Data SRAM, 64 KiB at 0x2000_0000, 4 x 16 KiB macros
// dsram_top.v
//
// Spec: GARUDA-MEM-SPEC-001 Rev 2.0 (Rev 4.0 set) Sec.5.2, Sec.7.5; ADR-0007
//
// One AHB slave port, four macros selected by haddr[15:14] ([N-7.11]). All
// four see the same address and write data; only the selected bank gets CE
// ([N-7.13]), so the unselected macros see no access at all (the per-macro
// clock-enable of [N-9.4]). The bank of a read is registered with the access
// so the returning data is taken from the macro that was actually read.
// No bank-level concurrency exists or is needed ([N-7.12], D-1).
// =============================================================================

module dsram_top
    import garuda_pkg::*;
    import mem_pkg::*;
(
    input wire hclk,
    input wire hreset_n,
    input wire hsel_i,
    input wire [WORD_W-1:0] haddr_i,
    input wire [HTRANS_W-1:0] htrans_i,
    input wire hwrite_i,
    input wire [HSIZE_W-1:0] hsize_i,
    input wire [WORD_W-1:0] hwdata_i,
    input wire hready_i,
    output wire [WORD_W-1:0] hrdata_o,
    output wire hreadyout_o,
    output wire hresp_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned RDATA_W = 32'd4;
    localparam int unsigned BANK_W = 32'd2;
    localparam int unsigned RD_BANK_W = 32'd2;

    localparam int unsigned ADDR_W  = 32'd14;  // 16,384 words total
    localparam int unsigned BANK_ADDR_W = 32'd12;  // 4,096 words per bank

    wire ce;
    wire we;
    wire [ADDR_W-1:0] addr;
    wire [BE_W-1:0]    be;
    wire [WORD_W-1:0]   wdata;
    wire [WORD_W-1:0]   rdata [0:RDATA_W-1];
    reg  [RD_BANK_W-1:0]    rd_bank_q;

    ahb_mem_slave_if #(.ADDR_W(ADDR_W), .WRITABLE(1)) u_if (
        .hclk(hclk), .hreset_n(hreset_n),
        .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i),
        .hwrite_i(hwrite_i), .hsize_i(hsize_i), .hwdata_i(hwdata_i),
        .hready_i(hready_i), .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o),
        .hresp_o(hresp_o),
        .wr_lock_i(1'b0), .lock_bypass_i(1'b0),
        .arr_ce_o(ce), .arr_addr_o(addr), .arr_we_o(we), .arr_be_o(be),
        .arr_wdata_o(wdata), .arr_rdata_i(rdata[rd_bank_q]));

    wire [BANK_W-1:0] bank = addr[ADDR_W-1:BANK_ADDR_W];

    // bank of the most recent read; its data is what arrives next cycle
    always_ff @(posedge hclk or negedge hreset_n) begin : p_rd_bank
        if (!hreset_n) begin
            rd_bank_q <= 2'd0;
        end else if (ce && !we) begin
            rd_bank_q <= bank;
        end
    end

    genvar b;
    wire [BANK_ADDR_W-1:0] bank_addr = addr[BANK_ADDR_W-1:0];
    generate for (b = 0; b < 4; b = b + 1) begin : g_bank
        // this bank is addressed
        wire bank_ce = ce && (bank == BANK_W'(b));
        sram_wrapper #(.WORDS(MEM_DSRAM_BANK_WORDS),
            .ADDR_W(BANK_ADDR_W)) u_array(
            .hclk(hclk), .ce(bank_ce), .addr(bank_addr),
            .wdata(wdata), .rdata(rdata[b]), .we(we), .be(be));
    end endgenerate

`ifndef SYNTHESIS
    // Byte-addressed backdoor; the testbench never sees the banking.
    task bd_write;
    input [31:0] byte_addr;
    input [31:0] data;
        begin
            case (byte_addr[15:14])
                2'd0: g_bank[0].u_array.bd_write(byte_addr[13:2], data);
                2'd1: g_bank[1].u_array.bd_write(byte_addr[13:2], data);
                2'd2: g_bank[2].u_array.bd_write(byte_addr[13:2], data);
                default: g_bank[3].u_array.bd_write(byte_addr[13:2], data);
            endcase
`ifndef __ICARUS__
            // the bus-side data model (rtl/mem/mem_sva.sv) did not see this
            // write
            u_if.u_mem_sva.forget({18'd0, byte_addr[15:2]});
`endif
        end
    endtask
    function automatic [31:0] bd_read;
    input [31:0] byte_addr;
        case (byte_addr[15:14])
            2'd0: bd_read = g_bank[0].u_array.bd_read(byte_addr[13:2]);
            2'd1: bd_read = g_bank[1].u_array.bd_read(byte_addr[13:2]);
            2'd2: bd_read = g_bank[2].u_array.bd_read(byte_addr[13:2]);
            default: bd_read = g_bank[3].u_array.bd_read(byte_addr[13:2]);
        endcase
    endfunction
`endif


endmodule
