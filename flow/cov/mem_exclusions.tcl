# =============================================================================
# mem_exclusions.tcl - coverage waivers for the MEM block (D-40, 2026-11-20), measured in the
# main merge. Per design type. Every line has its reason; cov_chart fails on a line that matches
# nothing (IMC *W,NOMATCH).
# =============================================================================
# simulation-only code inside `ifndef SYNTHESIS: backdoor tasks the benches use to preload and
# peek memory, and a self-check that prints when the write buffer would overflow (it never firing
# is the passing result). Not hardware.
exclude -type bootrom_top -block 1 -comment "bd_load_hex call (bootrom_top.sv:63) inside ifndef SYNTHESIS: a bench backdoor preload, not hardware"
exclude -type isram_top -block 4 -comment "bd_load_hex call (isram_top.sv:79) inside ifndef SYNTHESIS: a bench backdoor preload, not hardware"
exclude -type dsram_top -block 8 -comment "backdoor bd_write to bank 1 (dsram_top.sv:89) inside ifndef SYNTHESIS: bench code, not hardware"
exclude -type dsram_top -block 9 -comment "backdoor bd_write to bank 2 (dsram_top.sv:90) inside ifndef SYNTHESIS: bench code, not hardware"
exclude -type dsram_top -block 13 -comment "backdoor bd_read of bank 0 (dsram_top.sv:103) inside ifndef SYNTHESIS: bench code, not hardware"
exclude -type dsram_top -block 14 -comment "backdoor bd_read of bank 1 (dsram_top.sv:104) inside ifndef SYNTHESIS: bench code, not hardware"
exclude -type dsram_top -block 15 -comment "backdoor bd_read of bank 2 (dsram_top.sv:105) inside ifndef SYNTHESIS: bench code, not hardware"
exclude -type sram_wrapper -block 21 -comment "readmemh preload (sram_wrapper.sv:118-120) inside ifndef SYNTHESIS: bench code, not hardware"
exclude -type ahb_mem_slave_if -block 23 -comment "simulation-only self-check (ahb_mem_slave_if.sv:198-203, ifndef SYNTHESIS) that prints on a write-buffer overflow: never firing is the passing result"
exclude -type ahb_mem_slave_if -expression 2.1.1 -comment "the condition of the same simulation-only overflow self-check (ahb_mem_slave_if.sv:200): the row park_wr AND wb_v is a write data phase with the buffer full, which a_wbuf_empty_in_write_dp proves never happens (JasperGold PROVEN, flow/formal/mem/mem_fpv.result.txt)"
# the boot ROM takes no write: its interface answers ERROR (WRITABLE = 0), so the array never sees one
exclude -type sram_wrapper -block 17 -comment "the ROM-write path (sram_wrapper.sv:101, we with IS_ROM = 1): the boot ROM's interface refuses every write (WRITABLE = 0, AHB ERROR), so its array never sees we"
exclude -type bootrom_top -toggle we -comment "the boot ROM's array write enable is constant 0: its interface refuses every write (WRITABLE = 0)"
# the bus is 32 bits: HSIZE is byte, half or word
exclude -type ahb_mem_slave_if -toggle hsize_i\[2\] -comment "the AHB is 32 bits wide: HSIZE is at most word, so bit 2 is 0"
exclude -type bootrom_top -toggle hsize_i\[2\] -comment "the AHB is 32 bits wide: HSIZE is at most word, so bit 2 is 0"
exclude -type isram_top -toggle hsize_i\[2\] -comment "the AHB is 32 bits wide: HSIZE is at most word, so bit 2 is 0"
exclude -type dsram_top -toggle hsize_i\[2\] -comment "the AHB is 32 bits wide: HSIZE is at most word, so bit 2 is 0"
