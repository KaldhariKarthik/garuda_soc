`timescale 1ns/1ps
// =============================================================================
// spi_master_model.sv -- the ESP32 at the other end of block 14's link.
//
// Mode 0, MSB first, 8 bits: sclk idles low, mosi is launched on the falling
// edge and the master samples miso on the rising edge, which is the same
// convention block 13 uses ([SPIM N-7.4], [SPIS N-7.2]).
//
// Knobs:
//   half_ns   half SCLK period. The DUT oversamples in pclk, so the tests use
//             this to walk up to and past the SCLK <= pclk/6 limit of
//             [SPIS N-7.1a] and find where reception actually breaks.
//
// xfer() runs one byte inside an open frame; packet() wraps a burst in one
// cs_n assertion, which is how an ESP-NOW frame arrives.
// =============================================================================
module spi_master_model (
    output reg  sclk,
    output reg  mosi,
    output reg  cs_n,
    input  wire miso
);

    real half_ns = 100.0;               // 5 MHz default

    byte unsigned rq[$];                // bytes received back from the slave

    initial begin sclk = 1'b0; mosi = 1'b0; cs_n = 1'b1; end

    function automatic int n_rx();      return rq.size(); endfunction
    function automatic byte unsigned get();
        byte unsigned d = rq[0]; rq.delete(0); return d;
    endfunction
    task automatic clear(); rq.delete(); endtask

    // one byte, frame already open
    task automatic xfer(input byte unsigned d, output byte unsigned got);
        int i;
        got = 8'd0;
        for (i = 7; i >= 0; i--) begin
            mosi = d[i];                // launch on the falling edge (sclk low)
            #(half_ns);
            sclk = 1'b1;                // slave samples here; so do we
            got  = {got[6:0], miso === 1'b1};
            #(half_ns);
            sclk = 1'b0;
        end
        rq.push_back(got);
    endtask

    task automatic open_frame();
        cs_n = 1'b0;
        #(half_ns);                     // setup before the first edge
    endtask

    task automatic close_frame();
        #(half_ns);
        cs_n = 1'b1;
        #(half_ns * 2);
    endtask

    // a whole ESP-NOW-style packet: one cs_n assertion, n bytes
    task automatic packet(input int n, input byte unsigned first);
        byte unsigned g;
        int i;
        open_frame();
        for (i = 0; i < n; i++) xfer(first + i[7:0], g);
        close_frame();
    endtask

    // a frame that ends mid-byte: nbits clock pulses, then cs_n rises
    task automatic partial_frame(input int nbits, input byte unsigned d);
        int i;
        cs_n = 1'b0;
        #(half_ns);
        for (i = 0; i < nbits; i++) begin
            mosi = d[7 - (i % 8)];
            #(half_ns);
            sclk = 1'b1;
            #(half_ns);
            sclk = 1'b0;
        end
        #(half_ns);
        cs_n = 1'b1;
        #(half_ns * 2);
    endtask

endmodule
