`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - chip : functional coverage of what passes between the blocks
// chip_cov.sv
//
// From GARUDA-SYS-001 / the TRM: the interrupt map, the DMA handshakes, the
// resets and their causes, the clock ratio, sleep, the pads; the address map
// per AHB master and every APB window, and the three boot modes (1-TOPS G6
// 6.15, 2026-11-21). Bound to
// garuda_chip_core, so it samples in every chip program (tb_chip).
// The blocks' own behaviour is covered by their own covergroups; this is only
// "did every wire between two blocks carry its event at least once".
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module chip_cov (
    input wire        hclk, hreset_n, aon_clk,
    input wire [31:0] irq_src,
    input wire [5:0]  dma_req, dma_ack,
    input wire        wdt_rst_req, ndmreset, hartreset, core_rst_n, ilock, core_sleep,
    input wire [3:0]  reason,
    input wire [1:0]  div_act,
    input wire        div_busy,
    input wire [1:0]  gpio_oe,
    input wire        scl_oe, sda_oe, tdo_oe,
    // the address map: each AHB master's address phases, and the APB windows
    input wire [31:0] i_haddr, d_haddr, s_haddr, m_haddr,
    input wire [1:0]  i_htrans, d_htrans, s_htrans, m_htrans,
    input wire        i_hready, d_hready, s_hready, m_hready, s_hwrite,
    input wire        pclk,
    input wire [11:0] psel,
    input wire        penable,
    // boot
    input wire        boot_sel
);
    // ---- address map (G6 6.15) ----------------------------------------------------------
    // region of an address: haddr[31:28] (MEM [N-7.1]): 0 ISRAM (with its alias), 1 boot ROM,
    // 2 DSRAM, 4 APB; anything else is in no region (the default slave's ERROR)
    function automatic [2:0] region(input [31:0] a);
        case (a[31:28])
            4'h0: region = 3'd0;
            4'h1: region = 3'd1;
            4'h2: region = 3'd2;
            4'h4: region = 3'd3;
            default: region = 3'd4;
        endcase
    endfunction
    // One covergroup per master, sampled on each accepted address phase, with the regions
    // that master can reach by design: the I-port fetches from ISRAM and ROM only (a fetch
    // elsewhere is not a path of any program; CORE [N-6.2]); the DMA moves data between
    // DSRAM and the APB peripherals, and an ISRAM destination is refused before the bus
    // (R-9), so it never presents ISRAM, ROM or no region.
    covergroup cg_map_i @(posedge hclk iff (hreset_n && i_htrans[1] && i_hready));
        option.per_instance = 1;
        cp: coverpoint region(i_haddr) { bins isram = {0}; bins rom = {1}; }
    endgroup
    covergroup cg_map_d @(posedge hclk iff (hreset_n && d_htrans[1] && d_hready));
        option.per_instance = 1;
        cp: coverpoint region(d_haddr) { bins isram = {0}; bins rom = {1}; bins dsram = {2}; bins apb = {3}; bins none = {4}; }
    endgroup
    covergroup cg_map_sba @(posedge hclk iff (hreset_n && s_htrans[1] && s_hready));
        option.per_instance = 1;
        cp: coverpoint region(s_haddr) { bins isram = {0}; bins rom = {1}; bins dsram = {2}; bins apb = {3}; bins none = {4}; }
    endgroup
    covergroup cg_map_dma @(posedge hclk iff (hreset_n && m_htrans[1] && m_hready));
        option.per_instance = 1;
        cp: coverpoint region(m_haddr) { bins dsram = {2}; bins apb = {3}; }
    endgroup
    // every APB window selected (its setup phase): all twelve have a slave
    function automatic [3:0] win_of(input [11:0] v);
        win_of = 4'd15;
        for (int k = 0; k < 12; k++) if (v[k]) win_of = k[3:0];
    endfunction
    covergroup cg_apb_win @(posedge pclk iff (hreset_n && (|psel) && !penable));
        option.per_instance = 1;
        cp: coverpoint win_of(psel) { bins win[] = {[0:11]}; }
    endgroup
    // ---- boot modes (G6 6.15; 6.9 to 6.11) -------------------------------------------------
    // Sampled when the hart first fetches from ISRAM after leaving the boot ROM: boot_sel = 0
    // is the SPI flash boot; boot_sel = 1 is the mailbox boot, or the JTAG boot when the
    // image was written into ISRAM by the debugger's system bus access since the last system
    // reset. The JTAG boot holds the hart in reset (hartreset) while it streams the image, so
    // that load is cleared only by a system reset, not by the core reset it happens under.
    reg sba_loaded = 1'b0, in_rom = 1'b0;
    always @(posedge hclk)
        if (!hreset_n) sba_loaded <= 1'b0;
        else if (s_htrans[1] && s_hready && s_hwrite && region(s_haddr) == 3'd0) sba_loaded <= 1'b1;
    always @(posedge hclk)
        if (!core_rst_n) in_rom <= 1'b1;
        else if (i_htrans[1] && i_hready && region(i_haddr) == 3'd0) in_rom <= 1'b0;
    wire boot_jump = core_rst_n && in_rom && i_htrans[1] && i_hready && region(i_haddr) == 3'd0;
    covergroup cg_boot @(posedge hclk iff boot_jump);
        option.per_instance = 1;
        cp: coverpoint {boot_sel, sba_loaded} { bins flash = {2'b00}; bins mailbox = {2'b10}; bins jtag = {2'b11};
                                                // reason: not a GARUDA boot mode (MEM §8, DEBUG §7.6): the image comes over SBA only
                                                // with boot_sel = 1 (tb_chip +MODE=jtag); a flash boot (boot_sel = 0) copies it from SPI,
                                                // so an SBA load before a flash-mode jump means the bench mixed two modes: a check, not a waiver
                                                illegal_bins sba_with_flash = {2'b01}; }
    endgroup

    // every interrupt source of the map raised at least once (rising edge on its line)
    reg [31:0] irq_d = 32'd0;
    always @(posedge hclk) irq_d <= irq_src;
    wire [31:0] irq_rise = irq_src & ~irq_d;
    covergroup cg_irq_lines @(posedge hclk iff (hreset_n && (|irq_rise)));
        option.per_instance = 1;
        cp_dma_done:  coverpoint irq_rise[6:1]   { bins ch[] = {6'b000001, 6'b000010, 6'b000100, 6'b001000, 6'b010000, 6'b100000}; }
        cp_dma_error: coverpoint irq_rise[13:8]  { bins ch[] = {6'b000001, 6'b000010, 6'b000100, 6'b001000, 6'b010000, 6'b100000}; }
        cp_spis:      coverpoint irq_rise[14];
        cp_periph:    coverpoint irq_rise[21:15] { bins spim = {7'b0000001}; bins i2c = {7'b0000010}; bins uart0 = {7'b0000100};
                                                   bins uart1 = {7'b0001000}; bins uart2 = {7'b0010000}; bins gpio = {7'b0100000}; bins pwm = {7'b1000000}; }
        cp_wdt_warn:  coverpoint irq_rise[22];
    endgroup
    // every DMA channel's request answered by its acknowledge
    covergroup cg_dma @(posedge hclk iff (hreset_n && (|dma_ack)));
        option.per_instance = 1;
        cp_ack: coverpoint dma_ack { bins ch[] = {6'b000001, 6'b000010, 6'b000100, 6'b001000, 6'b010000, 6'b100000}; }
        // A peripheral's request is never high while its acknowledge is: the shim drops it in the
        // same cycle (dma_req_o = ... && !dma_ack_i, garuda_apb_dma.sv, D-21), so only 0 can occur;
        // a request held through its acknowledge is an illegal bin and fails the run
        cp_req_still_high: coverpoint |(dma_req & dma_ack) { illegal_bins high = {1}; }
    endgroup
    // resets: every cause, as the reset controller records it
    reg [3:0] reason_d = 4'd0;
    always @(posedge aon_clk) reason_d <= reason;
    covergroup cg_reset @(posedge aon_clk iff (reason != reason_d));
        option.per_instance = 1;
        cp_cause: coverpoint reason { bins ext = {4'b0001}; bins watchdog = {4'b0010}; bins ndm = {4'b0100}; bins sw = {4'b1000}; bins cleared = {4'b0000}; }
    endgroup
    covergroup cg_misc @(posedge hclk iff hreset_n);
        option.per_instance = 1;
        cp_hartreset: coverpoint hartreset;
        cp_ilock: coverpoint ilock;
        cp_sleep: coverpoint core_sleep;
        cp_ratio: coverpoint div_act { bins div2 = {0}; bins div4 = {1}; bins div8 = {2}; bins div16 = {3}; }
        cp_ratio_change: coverpoint div_busy;
        cp_gpio_out: coverpoint gpio_oe;
        cp_i2c_drive: coverpoint {scl_oe, sda_oe};
        cp_tdo: coverpoint tdo_oe;
    endgroup
    cg_irq_lines ci = new(); cg_dma cd = new(); cg_reset cr = new(); cg_misc cm = new();
    cg_map_i cmi = new(); cg_map_d cmd = new(); cg_map_sba cms = new(); cg_map_dma cmm = new();
    cg_apb_win caw = new(); cg_boot cb = new();
endmodule

bind garuda_chip_core chip_cov u_chip_cov (
    .hclk(hclk), .hreset_n(hreset_n), .aon_clk(aon_clk),
    .irq_src(u_soc.irq_src), .dma_req(dma_req), .dma_ack(dma_ack),
    .wdt_rst_req(wdt_rst_req), .ndmreset(ndmreset), .hartreset(hartreset), .core_rst_n(core_rst_n),
    .ilock(ilock), .core_sleep(u_soc.u_core.quiescent), .reason(u_reset_ctrl.reason_q),
    .div_act(div_act), .div_busy(div_busy), .gpio_oe(gpio_oe_o), .scl_oe(i2c_scl_oe_o), .sda_oe(i2c_sda_oe_o), .tdo_oe(tdo_oe_o),
    .i_haddr(u_soc.i_haddr), .d_haddr(u_soc.d_haddr), .s_haddr(u_soc.s_haddr), .m_haddr(u_soc.m_haddr),
    .i_htrans(u_soc.i_htrans), .d_htrans(u_soc.d_htrans), .s_htrans(u_soc.s_htrans), .m_htrans(u_soc.m_htrans),
    .i_hready(u_soc.i_hready), .d_hready(u_soc.d_hready), .s_hready(u_soc.s_hready), .m_hready(u_soc.m_hready),
    .s_hwrite(u_soc.s_hwrite), .pclk(pclk), .psel(u_soc.psel), .penable(u_soc.penable), .boot_sel(boot_sel));
`endif
`endif
`endif
