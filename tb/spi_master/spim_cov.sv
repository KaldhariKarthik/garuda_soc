`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 13 : functional coverage of the SPI master wrapper
// spim_cov.sv
//
// From GARUDA-SPIM-SPEC-001 sections 6 and 7. Bound to garuda_spim_top.
//   cg_start  one sample per started transfer: device, direction, lengths, divider
//   cg_fw     firmware writes the wrapper must survive (SPIM-3, SPIM-4)
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module spim_cov (
    input wire        pclk_i, preset_n_i,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire [31:0] pwdata_i,
    input wire [7:0]  clk_div,
    input wire [5:0]  cmd_len, addr_len,
    input wire [15:0] data_len,
    input wire        dma_req_o, dma_ack_i,
    input wire [1:0]  dmactl
);
    wire st_wr = psel_i && penable_i && pwrite_i && paddr_i == 12'h000;
    wire start = st_wr && (pwdata_i[1:0] != 2'b00);
    covergroup cg_start @(posedge pclk_i iff (preset_n_i && start));
        option.per_instance = 1;
        cp_device: coverpoint pwdata_i[9:8] { bins none = {0}; bins flash = {1}; bins imu = {2}; bins both = {3}; }
        cp_dir: coverpoint pwdata_i[1:0] { bins read = {1}; bins write = {2}; bins both = {3}; }
        cp_div: coverpoint clk_div { bins boot = {3}; bins slower = {[4:15]}; bins much_slower = {[16:255]}; }
        cp_cmd: coverpoint cmd_len { bins none = {0}; bins byte_ = {8}; bins other = default; }
        cp_addr: coverpoint addr_len { bins none = {0}; bins a24 = {24}; bins a32 = {32}; bins other = default; }
        cp_data: coverpoint data_len { bins none = {0}; bins word = {32}; bins multi = {[33:65535]}; bins short = {[1:31]}; }
        cp_dma: coverpoint dmactl { bins off = {0}; bins rx = {1}; bins tx = {2}; bins both = {3}; }
        x_device_dir: cross cp_device, cp_dir { ignore_bins none = binsof(cp_device.none); }
        x_flash_read: cross cp_cmd, cp_addr, cp_data;
    endgroup
    covergroup cg_fw @(posedge pclk_i iff (preset_n_i && st_wr));
        option.per_instance = 1;
        cp_quad_bits: coverpoint pwdata_i[3:2] { bins none = {0}; bins qrd = {1}; bins qwr = {2}; bins both = {3}; }
        cp_soft_reset: coverpoint pwdata_i[4];
        cp_both_cs: coverpoint (pwdata_i[9:8] == 2'b11);
    endgroup
    covergroup cg_dma @(posedge pclk_i iff (preset_n_i && dma_ack_i));
        option.per_instance = 1;
        cp_req_at_ack: coverpoint dma_req_o;
        cp_mode: coverpoint dmactl { bins rx = {1}; bins tx = {2}; bins both = {3}; }
    endgroup
    cg_start cs = new(); cg_fw cf = new(); cg_dma cd = new();
endmodule

bind garuda_spim_top spim_cov u_spim_cov (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i), .psel_i(psel_i), .penable_i(penable_i),
    .pwrite_i(pwrite_i), .paddr_i(paddr_i), .pwdata_i(pwdata_i), .clk_div(u_spi.spi_clk_div),
    .cmd_len(u_spi.spi_cmd_len), .addr_len(u_spi.spi_addr_len), .data_len(u_spi.spi_data_len),
    .dma_req_o(dma_req_o), .dma_ack_i(dma_ack_i), .dmactl(dmactl));
`endif
`endif
`endif
