`timescale 1ns/1ps
// chip_ctl_if.sv - what the UVM chip test needs from tb_chip: the program's verdict.
interface chip_ctl_if;
    logic   prog_done;
    integer prog_rc;
    logic   gpio1;          // the companion's ready line (a rising edge asks for a frame)
endinterface
