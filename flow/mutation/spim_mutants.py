NAME = "spim"
BENCH = "tb/spi_master/filelist_spim.f"; FL_LINE = "-f rtl/spi_master/filelist.f"; TOP = "tb_spim"
MUTANTS = [
 ("U1 SPIM-3 fix removed", "rtl/spi_master/garuda_spim_top.sv", "assign spim_cs_imu_n_o   = csn1 | ~csn0;", "assign spim_cs_imu_n_o   = csn1;"),
 ("U2 SPIM-4 fix removed", "rtl/spi_master/garuda_spim_top.sv", "(pwdata_i & ~32'h0000_000C) : pwdata_i", "pwdata_i : pwdata_i"),
 ("M1 MISO on sdi0", "rtl/spi_master/garuda_spim_top.sv", ".spi_sdi0(1'b0), .spi_sdi1(miso_sync),", ".spi_sdi0(miso_sync), .spi_sdi1(1'b0),"),
 ("M2 poll may write", "rtl/spi_master/garuda_spim_top.sv", "wire        eff_pwrite  = poll ? 1'b0    : pwrite_i;", "wire        eff_pwrite  = pwrite_i;"),
 ("M3 chip selects swapped", "rtl/spi_master/garuda_spim_top.sv", "assign spim_cs_flash_n_o = csn0;", "assign spim_cs_flash_n_o = csn1;"),
 ("M4 poll blocks the bus", "rtl/spi_master/garuda_spim_top.sv", "wire        eff_psel    = poll ? 1'b1    : ip_psel;", "wire        eff_psel    = 1'b1;"),
]
