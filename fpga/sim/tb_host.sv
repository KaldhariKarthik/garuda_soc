`timescale 1ns/1ps
// =============================================================================
// tb_host.sv - garuda_fpga_core driven by fpga/kv260/host/garuda_host.py
// itself (--sim), through two FIFOs in +DIR=<dir>:
//   cmd.fifo  (py -> sim)   "W <hex>" ctrl write | "R 0" stat read | "D <ns hex>" | "Q 0"
//   rsp.fifo  (sim -> py)   "<hex>" per R
// Each W advances 50 ns, like an AXI write at the host's pace (the host is far
// slower on the board, and slower is always safe here). This proves the
// Python sequences, not just a SystemVerilog copy of them.
// =============================================================================
module tb_host;
    reg clk = 0;
    always #10 clk = ~clk;

    reg  [31:0] ctrl = 32'h0000_0030;
    wire [31:0] stat;
    wire i2c_scl, i2c_sda, gpio0, gpio1, pwm0, pwm1, pwm2, pwm3, host_rxd;
    pullup (i2c_scl); pullup (i2c_sda); pulldown (gpio0); pulldown (gpio1);

    garuda_fpga_core #(.BROM_INIT_FILE("sw/build/bootrom.hex")) dut (
        .clk_100_i(clk), .rst_100_n_i(1'b1), .ctrl_i(ctrl), .stat_o(stat),
        .host_uart_txd_i(1'b1), .host_uart_rxd_o(host_rxd),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda), .gpio0(gpio0), .gpio1(gpio1),
        .pwm0(pwm0), .pwm1(pwm1), .pwm2(pwm2), .pwm3(pwm3));

    localparam real BIT = 1.0e9 / 115200.0;
    reg [7:0] rxb;
    always begin
        @(negedge host_rxd);
        #(BIT * 1.5);
        for (int k = 0; k < 8; k++) begin rxb[k] = host_rxd; #(BIT); end
        if (rxb == 8'h0A) $write("\n"); else if (rxb != 8'h0D) $write("%c", rxb);
        $fflush();
    end

    string dir;
    reg hr_q = 0;
    always @(posedge dut.u_chip.aon_clk) begin
        hr_q <= dut.u_chip.hreset_n;
        if ($test$plusargs("PCTRACE") && hr_q != dut.u_chip.hreset_n)
            $display("[pc] %0t hreset edge -> %b  reason=%b", $time, dut.u_chip.hreset_n, dut.u_chip.u_reset_ctrl.reason_q);
    end
    // +PCTRACE: EX-stage PC and reset state every 50 us (debug only)
    initial if ($test$plusargs("PCTRACE")) forever begin
        #50000;
        $display("[pc] %0t hrst=%b pc=%08h", $time, dut.u_chip.hreset_n, dut.u_chip.u_soc.u_core.xe_pc);
    end
    integer fc, fr, n;
    reg [8*64-1:0] line;
    reg [7:0] op;
    reg [63:0] arg;
    initial begin
        if (!$value$plusargs("DIR=%s", dir)) dir = "/tmp";
        fc = $fopen({dir, "/cmd.fifo"}, "r");
        fr = $fopen({dir, "/rsp.fifo"}, "w");
        #200;
        forever begin
            // every command is "<op> <hex>" ("R 0", "Q 0"): fixed-shape $fscanf
            // (a $fgets reg is zero-padded on the left, which breaks $sscanf %c)
            n = $fscanf(fc, " %c %h", op, arg);
            if (n != 2) begin $display("[tb_host] EOF/parse (%0d)", n); $finish; break; end
            if ($test$plusargs("TRACE")) begin $display("[tb_host] %0t cmd '%c' %h", $time, op, arg); $fflush(); end
            case (op)
                "W": begin ctrl = arg[31:0]; #50; end
                "R": begin $fwrite(fr, "%08h\n", stat); $fflush(fr); end
                "D": begin #(arg); end
                "Q": begin $display("[tb_host] quit at %0t", $time); $finish; break; end
                default: ;
            endcase
        end
    end
endmodule
