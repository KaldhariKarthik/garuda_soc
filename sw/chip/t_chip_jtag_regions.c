/* t_chip_jtag_regions.c - debug vPlan F32 (Track A, 2026-10-16): the debugger reaches every
 * region. Loaded and started over JTAG (tb_chip +MODE=jtag_reg). The firmware leaves values
 * in DSRAM and in an APB block and copies what IT reads from the Boot ROM and from reset_ctrl;
 * after tohost the bench reads the same places over SBA and must see the same values.
 *   0x2000_8000 marker written by the CPU     0x2000_800C RSTREASON as the CPU reads it
 *   0x2000_8014 Boot ROM word 0 as the CPU reads it; DMA channel 0 SAR/DAR set to known values */
#include "chip.h"
uint32_t trap_handler(uint32_t mcause, uint32_t mepc) { (void)mcause; return mepc + 4; }
int main(void)
{
    REG(0x20008000u) = 0xC0FFEE01u;
    DMA_SAR(0) = 0x20008004u;
    DMA_DAR(0) = 0x20008008u;
    REG(0x2000800Cu) = RSTREASON;
    REG(0x20008014u) = REG(0x10000000u);
    return 0;
}
