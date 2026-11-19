// =============================================================================
// GARUDA SoC - peripheral DMA request (APB window tail register DMACTL)
// garuda_apb_dma.sv
//
// Spec: Docs/DECISIONS.md D-21 (peripheral DMA contract), D-16 (dma_ack
//       width), D-39 (only the blocks with a DMA channel have it)
//
// DMACTL (0xFE8, RW, reset 0): [0] request while the IP has data to read,
// [1] request while it can take data. dma_chan takes exactly one beat per
// request assertion (its taken flag clears only when the request drops), so a
// level request that stayed high would move one beat and stall; the request
// therefore drops for one pclk after every dma_ack_i.
//
// The UART, I2C, SPI master and SPI slave wrappers instantiate this next to
// garuda_apb_shim and OR rdata_o into the shim's read data (the shim reads 0
// at DMACTL). PWM and GPIO have no DMA channel and no instance: their DMACTL
// reads 0 (D-39; split out of the shim in F4, 2026-11-18).
// =============================================================================

module garuda_apb_dma
    import garuda_pkg::*;
(
    input wire pclk,
    input wire preset_n,
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] rdata_o,  // DMACTL when it is addressed, else 0
    input wire [DMACTL_W-1:0] src_i,   // {can take data, has data to read}
    input wire dma_ack_i,  // 2 hclk = 1 pclk (D-16)
    output wire dma_req_o
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam [11:0] A_DMACTL = 12'hFE8;

    wire at_dmactl = at12(paddr_i, A_DMACTL);
    wire wr_dmactl = psel_i && penable_i && pwrite_i && at_dmactl;

    reg [DMACTL_W-1:0] dmactl_q;
    always_ff @(posedge pclk or negedge preset_n) begin : p_dmactl
        if (!preset_n) begin
            dmactl_q <= 2'b00;
        end else if (wr_dmactl) begin
            dmactl_q <= pwdata_i[1:0];
        end
    end

    // one pclk of guaranteed deassertion after every ack (D-21)
    reg holdoff_q;
    always_ff @(posedge pclk or negedge preset_n) begin : p_holdoff
        if (!preset_n) begin
            holdoff_q <= 1'b0;
        end else begin
            holdoff_q <= dma_ack_i;
        end
    end

    assign dma_req_o = (|(dmactl_q & src_i)) && !holdoff_q && !dma_ack_i;
    assign rdata_o   = at_dmactl ? {{(WORD_W - DMACTL_W){1'b0}}, dmactl_q}
                                 : 32'd0;

endmodule
