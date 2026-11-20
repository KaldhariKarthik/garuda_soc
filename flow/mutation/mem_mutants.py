NAME = "mem"
BENCH = "tb/mem/filelist_mem.f"; FL_LINE = "-f rtl/mem/filelist.f"; TOP = "tb_mem_subsystem"
MUTANTS = [
 ("M1 read bypass ignores the write buffer", "rtl/mem/ahb_mem_slave_if.sv", "wire        byp   = wb_v && (wb_word == dp_word);", "wire        byp   = 1'b0;"),
 ("M2 bypass takes all lanes", "rtl/mem/ahb_mem_slave_if.sv", "(byp && wb_be[3]) ? wb_data[31:24]", "(byp) ? wb_data[31:24]"),
 ("M3 parked write uses the wrong word", "rtl/mem/ahb_mem_slave_if.sv", "wb_word <= dp_word;", "wb_word <= dp_word ^ 1;"),
 ("M4 halfword lanes swapped", "rtl/mem/ahb_mem_slave_if.sv", "MEM_SIZE_HALF: ap_be = haddr_i[1] ? 4'b1100 : 4'b0011;", "MEM_SIZE_HALF: ap_be = haddr_i[1] ? 4'b0011 : 4'b1100;"),
 ("M5 misaligned word accepted", "rtl/mem/ahb_mem_slave_if.sv", "wire misaligned = (hsize_i == MEM_SIZE_WORD && haddr_i[1:0] != 2'b00) ||", "wire misaligned = 1'b0 ||"),
 ("M6 lock ignored", "rtl/mem/ahb_mem_slave_if.sv", "wire lock_write = hwrite_i && wr_lock_i && !lock_bypass_i;", "wire lock_write = 1'b0;"),
 ("M7 one-cycle ERROR", "rtl/mem/ahb_mem_slave_if.sv", "assign hreadyout_o = ~err_first;", "assign hreadyout_o = 1'b1;"),
 ("M8 DSRAM read bank not registered", "rtl/dsram/dsram_top.sv", "        end else if (ce && !we) begin\n            rd_bank_q <= bank;", "        end else if (ce) begin\n            rd_bank_q <= bank;"),
]
# M8 is equivalent: a write cycle never returns read data, so registering the bank on a write
# changes nothing observable. Proven: flow/formal/mem/dsram_bank_fpv.result.txt (README 2026-11-10).
EQUIVALENT = {"M8": "proven equivalent, flow/formal/mem/dsram_bank_fpv.result.txt"}
