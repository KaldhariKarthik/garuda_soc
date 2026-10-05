`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 19 : properties for the GPIO
// gpio_sva.sv
//
// Spec: GARUDA-GPIO-SPEC-001. Plan: tb/gpio/GARUDA_GPIO_vplan.csv; each property
// names its feature. Bound to garuda_gpio_top, so the properties run in the
// block bench, in the UVM environment and in every chip simulation. The
// interrupt-line and register-port properties are those of the shared shim
// (rtl/common/garuda_apb_shim_sva.sv). Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
module gpio_sva (
    input wire        pclk_i,
    input wire        preset_n_i,
    input wire        psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire [1:0]  gpio_i, gpio_o, gpio_oe,
    input wire [1:0]  padin,          // what PADIN reads
    input wire [1:0]  en,             // GPIOEN
    input wire        ip_rd_status,   // the vendored block sees a read of INTSTATUS
    input wire        dma_req
);
    wire wr_paddir = psel_i && penable_i && pwrite_i && (paddr_i == 12'h000);

    // cycles since reset, saturating: properties that look several cycles back wait for it
    reg [3:0] age;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) age <= 4'd0; else if (age != 4'd15) age <= age + 4'd1;

    genvar n;
    generate for (n = 0; n < 2; n = n + 1) begin : g_pin
        // ---- F15: a pin is an input in reset and until firmware writes PADDIR ----
        a_oe_reset: assert property (@(posedge pclk_i) !preset_n_i |-> !gpio_oe[n])
            else $error("[SVA-FAIL] a_oe_reset: pin %0d driven in reset", n);
        a_oe_only_by_paddir: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && $changed(gpio_oe[n])) |-> $past(wr_paddir))
            else $error("[SVA-FAIL] a_oe_only_by_paddir: pin %0d", n);
        // ---- F16: PADIN is the pad as it was five pclk earlier (two shim flops, three in
        //      the vendored block) whenever the input path has been running that long.
        //      A pad is asynchronous: one that changes at a clock edge may be caught by
        //      that edge or by the next, so the value four cycles back is accepted too.
        //      Never sooner.
        a_sync_latency: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (age >= 4'd6 && $past(|en, 1) && $past(|en, 2) && $past(|en, 3)) |->
                (padin[n] == $past(gpio_i[n], 5) || padin[n] == $past(gpio_i[n], 4)))
            else $error("[SVA-FAIL] a_sync_latency: pin %0d PADIN %b, pad five and four cycles ago %b %b",
                        n, padin[n], $past(gpio_i[n], 5), $past(gpio_i[n], 4));
        // ---- F02: with the input path stopped PADIN holds ------------------------
        a_padin_frozen: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && en == 2'b00) |=> $stable(padin[n]))
            else $error("[SVA-FAIL] a_padin_frozen: pin %0d", n);
        c_pad_rise: cover property (@(posedge pclk_i) preset_n_i && $rose(gpio_i[n]));
        c_pad_fall: cover property (@(posedge pclk_i) preset_n_i && $fell(gpio_i[n]));
        c_driven:   cover property (@(posedge pclk_i) preset_n_i && gpio_oe[n] && gpio_o[n]);
    end endgenerate

    // ---- F22: INTSTATUS is read only when the bus master reads it ([N-7.3a]) ------
    a_no_intstatus_poll: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        ip_rd_status |-> (psel_i && penable_i && !pwrite_i && paddr_i[11:7] == 5'd0 && paddr_i[6:2] == 5'd9))
        else $error("[SVA-FAIL] a_no_intstatus_poll");
    // ---- F09: no DMA request, whatever DMACTL holds ----------------------------------
    a_no_dma_req: assert property (@(posedge pclk_i) disable iff (!preset_n_i) !dma_req)
        else $error("[SVA-FAIL] a_no_dma_req");

    c_status_read: cover property (@(posedge pclk_i) preset_n_i && ip_rd_status);
endmodule

bind garuda_gpio_top gpio_sva u_gpio_sva (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_oe(gpio_oe),
    .padin(u_gpio.r_gpio_in), .en(u_gpio.r_gpio_en),
    .ip_rd_status(u_gpio.PSEL && u_gpio.PENABLE && !u_gpio.PWRITE && (u_gpio.PADDR[6:2] == 5'd9)),
    .dma_req(u_shim.dma_req_o));
`endif
