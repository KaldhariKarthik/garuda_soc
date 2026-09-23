`timescale 1ns/1ps
// =============================================================================
// i2c_slave_model.sv -- a 7-bit-addressed I2C slave with a register file.
//
// Behaves like the sensors GARUDA actually talks to: address byte, register
// pointer, then data; a read is a write of the pointer, a REPEATED START, and
// then bytes out. Open drain throughout - it only ever pulls a line low.
//
// Knobs the tests use:
//   ADDR         7-bit slave address (parameter)
//   stretch_ns   hold SCL low for this long after the address ACK, which is
//                what a slow or wedged sensor does. Set it longer than the
//                DUT's TIMEOUT to prove the master abandons the transfer
//                rather than hanging (I2C R-8).
//   nack_all     refuse to acknowledge, as an absent device would
//
// It checks the master as well as answering it:
//   viol_sda     SDA changed while SCL was high outside a START/STOP, which
//                is the one framing rule I2C has
//   n_start / n_stop / n_rx / n_tx   traffic counters the tests assert on
// =============================================================================
module i2c_slave_model #(
    parameter [6:0] ADDR = 7'h48
)(
    inout wire scl,
    inout wire sda
);

    localparam S_IDLE = 0, S_ADDR = 1, S_ACK_A = 2,
               S_WDATA = 3, S_ACK_W = 4, S_RDATA = 5, S_ACK_R = 6, S_OFF = 7;

    reg sda_low = 1'b0;                 // 1 = we pull SDA low
    reg scl_low = 1'b0;                 // 1 = we stretch the clock
    assign sda = sda_low ? 1'b0 : 1'bz;
    assign scl = scl_low ? 1'b0 : 1'bz;

    reg [7:0] mem [0:255];
    integer   i;
    initial for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;

    real stretch_ns = 0.0;
    bit  nack_all   = 1'b0;

    integer st = S_IDLE, nbit = 0, ptr = 0;
    reg [7:0] sh = 8'h0, txb = 8'h0;
    bit reading = 0, got_ptr = 0, mack = 0, stretch_pending = 0;

    integer n_start = 0, n_stop = 0, n_rx = 0, n_tx = 0, viol_sda = 0;

    function automatic int viol(); return viol_sda; endfunction
    task automatic bd_write(input int a, input [7:0] d); mem[a & 8'hFF] = d; endtask
    function automatic byte unsigned bd_read(input int a); return mem[a & 8'hFF]; endfunction
    task automatic clear();
        n_start = 0; n_stop = 0; n_rx = 0; n_tx = 0; viol_sda = 0;
    endtask

    // ---- START and STOP, which are the only legal SDA edges while SCL is high --
    always @(negedge sda) if (scl === 1'b1) begin          // START
        n_start++;
        st      = S_ADDR;
        nbit    = 0;
        sh      = 8'h0;
        sda_low = 1'b0;
        got_ptr = 1'b0;
    end
    always @(posedge sda) if (scl === 1'b1 && st != S_IDLE) begin   // STOP
        n_stop++;
        st      = S_IDLE;
        sda_low = 1'b0;
    end

    // ---- sample on the rising edge --------------------------------------------
    always @(posedge scl) begin
        case (st)
            S_ADDR, S_WDATA: begin sh = {sh[6:0], sda === 1'b1}; nbit = nbit + 1; end
            S_RDATA:         nbit = nbit + 1;
            S_ACK_R:         mack = (sda === 1'b1);   // 1 = master NACKed
            default: ;
        endcase
    end

    // ---- act on the falling edge ------------------------------------------------
    always @(negedge scl) begin
        case (st)
            S_ADDR: if (nbit == 8) begin
                nbit = 0;
                if (sh[7:1] == ADDR && !nack_all) begin
                    sda_low = 1'b1;                   // ACK
                    reading = sh[0];
                    st      = S_ACK_A;
                end else begin
                    sda_low = 1'b0;                   // NACK - not us
                    st      = S_OFF;
                end
            end

            S_ACK_A: begin
                sda_low = 1'b0;
                if (stretch_ns > 0.0) stretch_pending = 1'b1;
                if (reading) begin
                    txb     = mem[ptr & 8'hFF];
                    ptr     = ptr + 1;
                    sda_low = ~txb[7];                // drive MSB first
                    txb     = {txb[6:0], 1'b0};
                    nbit    = 0;
                    st      = S_RDATA;
                end else begin
                    st = S_WDATA;
                end
            end

            S_WDATA: if (nbit == 8) begin
                nbit = 0;
                if (!got_ptr) begin
                    ptr     = sh;                     // first byte is the pointer
                    got_ptr = 1'b1;
                end else begin
                    mem[ptr & 8'hFF] = sh;
                    ptr  = ptr + 1;
                    n_rx = n_rx + 1;
                end
                sda_low = 1'b1;                       // ACK the byte
                st      = S_ACK_W;
            end

            S_ACK_W: begin
                sda_low = 1'b0;
                st      = S_WDATA;
            end

            S_RDATA: begin
                if (nbit == 8) begin
                    nbit    = 0;
                    n_tx    = n_tx + 1;
                    sda_low = 1'b0;                   // release for master's ACK
                    st      = S_ACK_R;
                end else begin
                    sda_low = ~txb[7];
                    txb     = {txb[6:0], 1'b0};
                end
            end

            S_ACK_R: begin
                if (mack) begin
                    st      = S_OFF;                  // master NACKed: last byte
                    sda_low = 1'b0;
                end else begin
                    txb     = mem[ptr & 8'hFF];
                    ptr     = ptr + 1;
                    sda_low = ~txb[7];
                    txb     = {txb[6:0], 1'b0};
                    nbit    = 0;
                    st      = S_RDATA;
                end
            end

            default: sda_low = 1'b0;
        endcase
    end

    // ---- clock stretching -------------------------------------------------------
    // Applied after the address ACK, which is where a real sensor that needs
    // thinking time inserts it.
    always @(stretch_pending) if (stretch_pending) begin
        scl_low = 1'b1;
        #(stretch_ns);
        scl_low = 1'b0;
        stretch_pending = 1'b0;
    end

    // ---- SDA must be stable for the whole SCL high phase ------------------------
    // Stated the way I2C actually states it, which removes every ambiguity
    // about WHEN in the high phase a change happened: the value the master
    // presents at the rising edge must be the value still there at the falling
    // edge. sda_d is SDA one nanosecond ago, so the comparison at the falling
    // edge cannot race the model's own drive in that same delta.
    //
    // Only the eight data bits are checked. START and STOP are deliberate
    // mid-high-phase edges, and the ACK slot has both sides handing over.
    logic    sda_at_rise = 1'b1, sda_d = 1'b1;
    realtime t_rise = 0;

    always @(sda) sda_d <= #1.0 sda;

    always @(posedge scl) begin
        sda_at_rise <= sda;
        t_rise      <= $realtime;
    end

    always @(negedge scl) begin
        if (t_rise > 0 && (st == S_WDATA || st == S_RDATA)
            && nbit > 0 && nbit <= 8 && (sda_d !== sda_at_rise)) begin
            viol_sda++;
            $display("[I2C-SLAVE] SDA %b at the rise but %b at the fall, %0t (st=%0d bit=%0d)",
                     sda_at_rise, sda_d, $time, st, nbit);
        end
    end

endmodule
