NAME = "spim"
FILES = ["rtl/common/garuda_apb_shim.v", "rtl/common/garuda_apb_shim_sva.sv", "rtl/spi_master/garuda_spim_top.v", "rtl/spi_master/garuda_spim_sva.sv"]
BENCH = "tb/spi_master/filelist_spim.f"; FL_LINE = "-f rtl/spi_master/filelist.f"; TOP = "tb_spim"
MUTANTS = [
 ("U1 SPIM-3 fix removed", "rtl/spi_master/garuda_spim_top.v", "assign spim_cs_imu_n_o   = csn1 | ~csn0;", "assign spim_cs_imu_n_o   = csn1;"),
 ("U2 SPIM-4 fix removed", "rtl/spi_master/garuda_spim_top.v", "(ip_pwdata & ~32'h0000_000C)", "ip_pwdata"),
 ("M1 MISO on sdi0", "rtl/spi_master/garuda_spim_top.v", ".spi_sdi0(1'b0), .spi_sdi1(miso_sync),", ".spi_sdi0(miso_sync), .spi_sdi1(1'b0),"),
 ("M2 poll may write", "rtl/spi_master/garuda_spim_top.v", "wire        eff_pwrite  = poll ? 1'b0    : ip_pwrite;", "wire        eff_pwrite  = ip_pwrite;"),
 ("M3 chip selects swapped", "rtl/spi_master/garuda_spim_top.v", "assign spim_cs_flash_n_o = csn0;", "assign spim_cs_flash_n_o = csn1;"),
 ("M4 poll blocks the bus", "rtl/spi_master/garuda_spim_top.v", "wire        eff_psel    = poll ? 1'b1    : ip_psel;", "wire        eff_psel    = 1'b1;"),
]
KEEP = ["-f rtl/third_party/pulp/apb_spi_master/filelist.f", "-sv"]
