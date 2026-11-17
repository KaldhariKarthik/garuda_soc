// =============================================================================
// GARUDA SoC - Block 4 : Boot ROM, 4 KiB at 0x1000_0000 (reset vector)
// bootrom_top.v
//
// Spec: GARUDA-MEM-SPEC-001 Rev 2.0 (Rev 4.0 set) Sec.5.3, Sec.7.2, Sec.8
//
// Zero-wait, read-only. Byte/half/word reads are all legal ([N-7.5], .rodata
// may be byte-addressed); any write returns the two-cycle ERROR. Contents come
// from INIT_FILE (the bootloader image, sw/bootrom); in silicon this is a ROM
// macro generated from the same file. Unused words hold 0x0000_0000, an
// illegal instruction, so a stray jump into the ROM traps (yaml boot.rom_fill).
// =============================================================================

module bootrom_top
    import garuda_pkg::*;
    import mem_pkg::*;
#(
    parameter INIT_FILE = ""
)(
    input wire hclk,
    input wire hreset_n,
    input wire hsel_i,
    input wire [WORD_W-1:0] haddr_i,
    input wire [HTRANS_W-1:0] htrans_i,
    input wire hwrite_i,
    input wire [HSIZE_W-1:0] hsize_i,
    input wire [HBURST_W-1:0] hburst_i,
    input wire [HPROT_W-1:0] hprot_i,
    input wire [WORD_W-1:0] hwdata_i,
    input wire hready_i,
    output wire [WORD_W-1:0] hrdata_o,
    output wire hreadyout_o,
    output wire hresp_o
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam integer ADDR_W = 32'd10;  // 1024 words

    wire ce;
    wire we;
    wire [ADDR_W-1:0] addr;
    wire [BE_W-1:0]    be;
    wire [WORD_W-1:0] wdata;
    wire [WORD_W-1:0] rdata;

    ahb_mem_slave_if #(.ADDR_W(ADDR_W), .WRITABLE(0)) u_if (
        .hclk(hclk), .hreset_n(hreset_n),
        .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i),
        .hwrite_i(hwrite_i), .hsize_i(hsize_i), .hwdata_i(hwdata_i),
        .hready_i(hready_i), .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o),
        .hresp_o(hresp_o),
        .wr_lock_i(1'b0), .lock_bypass_i(1'b0),
        .arr_ce_o(ce), .arr_addr_o(addr), .arr_we_o(we), .arr_be_o(be),
        .arr_wdata_o(wdata), .arr_rdata_i(rdata));

    sram_wrapper #(.WORDS(MEM_BROM_WORDS), .ADDR_W(ADDR_W), .IS_ROM(1),
        .INIT_FILE(INIT_FILE)) u_array(
        .hclk(hclk), .ce(ce), .addr(addr), .wdata(wdata), .rdata(rdata),
        .we(we), .be(be));

`ifndef SYNTHESIS
    task bd_load_hex;
    input [1023:0] path;
        u_array.bd_load_hex(path);
    endtask
    task bd_write;
    input [31:0] byte_addr;
    input [31:0] data;
        begin
            u_array.bd_write(byte_addr[ADDR_W+1:2], data);
`ifndef __ICARUS__
            // the bus-side data model (rtl/mem/mem_sva.sv) did not see this
            // write
            u_if.u_mem_sva.forget({{(32-ADDR_W){1'b0}}, byte_addr[ADDR_W+1:2]});
`endif
        end
    endtask
    function automatic [31:0] bd_read;
    input [31:0] byte_addr;
        bd_read = u_array.bd_read(byte_addr[ADDR_W + 1:2]);
    endfunction
`endif

    wire _unused = |{hburst_i, hprot_i};

endmodule
