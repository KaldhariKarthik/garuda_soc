NAME = "mem"
FILES = ["rtl/mem/sram_wrapper.v", "rtl/mem/ahb_mem_slave_if.v", "rtl/isram/isram_top.v", "rtl/dsram/dsram_top.v", "rtl/brom/bootrom_top.v", "rtl/mem/mem_sva.sv"]
INCDIRS = ["rtl/mem"]
BENCH = "tb/mem/filelist_mem.f"; FL_LINE = "-f rtl/mem/filelist.f"; TOP = "tb_mem_subsystem"
MUTANTS = [
 ("M1 read bypass ignores the write buffer", "rtl/mem/ahb_mem_slave_if.v", "wire        byp   = wb_v && (wb_word == dp_word);", "wire        byp   = 1'b0;"),
 ("M2 bypass takes all lanes", "rtl/mem/ahb_mem_slave_if.v", "(byp && wb_be[3]) ? wb_data[31:24]", "(byp) ? wb_data[31:24]"),
 ("M3 parked write uses the wrong word", "rtl/mem/ahb_mem_slave_if.v", "wb_word <= dp_word;", "wb_word <= dp_word ^ 1;"),
 ("M4 halfword lanes swapped", "rtl/mem/ahb_mem_slave_if.v", "`MEM_SIZE_HALF: ap_be = haddr_i[1] ? 4'b1100 : 4'b0011;", "`MEM_SIZE_HALF: ap_be = haddr_i[1] ? 4'b0011 : 4'b1100;"),
 ("M5 misaligned word accepted", "rtl/mem/ahb_mem_slave_if.v", "wire misaligned = (hsize_i == `MEM_SIZE_WORD && haddr_i[1:0] != 2'b00) ||", "wire misaligned = 1'b0 ||"),
 ("M6 lock ignored", "rtl/mem/ahb_mem_slave_if.v", "wire lock_write = hwrite_i && wr_lock_i && !lock_bypass_i;", "wire lock_write = 1'b0;"),
 ("M7 one-cycle ERROR", "rtl/mem/ahb_mem_slave_if.v", "assign hreadyout_o = ~err_first;", "assign hreadyout_o = 1'b1;"),
 ("M8 DSRAM read bank not registered", "rtl/dsram/dsram_top.v", "else if (ce && !we)  rd_bank_q <= bank;", "else if (ce)  rd_bank_q <= bank;"),
]
