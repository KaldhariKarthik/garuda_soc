`timescale 1ns/1ps
// =============================================================================
// uart_model.sv -- the thing on the other end of the serial line.
//
// Drives the DUT's rx and decodes the DUT's tx as an 8N1 (optionally 8E1)
// terminal would. Everything the tests need to vary is a variable, not a
// parameter, so one instance covers baud sweeps and error injection:
//
//   bit_ns      bit period the model USES, both directions. Set it different
//               from the DUT's divisor to measure receiver baud tolerance
//               (UART [N-8.1] - upstream samples at the bit boundary, so the
//               tolerance is not the textbook +/-5% and has to be measured).
//   parity_en   send and expect an even parity bit.
//
// It checks the DUT as well as talking to it:
//   viol_frame   the DUT's stop bit was not high
//   viol_parity  the DUT's parity bit disagreed with its own data
// min_edge_ns is the shortest gap between edges the DUT produced; send it
// 0x55 and that is exactly one bit period, which is the baud measurement.
// =============================================================================
module uart_model #(
    parameter real BIT_NS = 8680.0          // 115200 baud
)(
    output reg  dut_rx_o,                   // into the DUT's rx pin
    input  wire dut_tx_i                    // from the DUT's tx pin
);

    real bit_ns    = BIT_NS;
    bit  parity_en = 1'b0;

    byte unsigned rq[$];                    // bytes decoded from the DUT
    int viol_frame = 0, viol_parity = 0;

    initial dut_rx_o = 1'b1;                // line idle is high

    function automatic int n_rx();  return rq.size();               endfunction
    function automatic int viol();  return viol_frame + viol_parity; endfunction
    function automatic byte unsigned get();
        byte unsigned d = rq[0];
        rq.delete(0);
        return d;
    endfunction
    task automatic clear(); rq.delete(); viol_frame = 0; viol_parity = 0; endtask

    // ---- drive the DUT's receiver ---------------------------------------------
    task automatic send(input byte unsigned d, input bit bad_parity = 0);
        int i;
        dut_rx_o = 1'b0;                    // start
        #(bit_ns);
        for (i = 0; i < 8; i++) begin       // LSB first
            dut_rx_o = d[i];
            #(bit_ns);
        end
        if (parity_en) begin                // even parity
            dut_rx_o = (^d) ^ bad_parity;
            #(bit_ns);
        end
        dut_rx_o = 1'b1;                    // stop
        #(bit_ns);
    endtask

    task automatic send_str(input string s);
        int i;
        for (i = 0; i < s.len(); i++) send(byte'(s[i]));
    endtask

    // ---- decode the DUT's transmitter -------------------------------------------
    // Sampled at the CENTRE of each bit, which is what a real receiver does and
    // what makes this an independent check of the DUT rather than a mirror of it.
    byte unsigned d;
    bit p;
    int i;
    initial forever begin
        @(negedge dut_tx_i);                // start bit
        #(bit_ns * 1.5);                    // centre of bit 0
        for (i = 0; i < 8; i++) begin
            d[i] = dut_tx_i;
            #(bit_ns);
        end
        if (parity_en) begin
            p = dut_tx_i;
            #(bit_ns);
            if (p !== (^d)) begin
                viol_parity++;
                $display("[UART-MODEL] parity mismatch on 0x%02h at %0t", d, $time);
            end
        end
        if (dut_tx_i !== 1'b1) begin        // we are mid-stop-bit now
            viol_frame++;
            $display("[UART-MODEL] stop bit low after 0x%02h at %0t", d, $time);
        end
        rq.push_back(d);
    end

    // ---- measure what the DUT actually drives ------------------------------------
    real last_edge = 0, min_edge_ns = 1e9;
    always @(dut_tx_i) begin
        if (last_edge > 0 && ($realtime - last_edge) < min_edge_ns)
            min_edge_ns = $realtime - last_edge;
        last_edge = $realtime;
    end
    task automatic reset_meas(); min_edge_ns = 1e9; last_edge = 0; endtask

endmodule
