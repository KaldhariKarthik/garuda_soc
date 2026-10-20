// filelist_boot_mem2m.f -- tb_boot with a 2 MiB memory (riscv-arch-test, plan
// 5.4: the largest tests do not fit 256 KiB). The define comes first.
-define GARUDA_TB_MEM2M
-f tb/soc/filelist_boot.f
