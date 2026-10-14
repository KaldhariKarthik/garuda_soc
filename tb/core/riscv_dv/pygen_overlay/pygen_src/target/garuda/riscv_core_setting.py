"""GARUDA core settings for riscv-dv pygen (plan 5.5, DN-ISA).

Loaded by tools/gen/garuda_dv_gen.py, which puts tb/core/riscv_dv/pygen_overlay
on sys.path (pygen_src is a namespace package), so the pinned riscv-dv
checkout is never modified.
DN-ISA: RV32I + the multiply half of M (Zmmul). DIV/DIVU/REM/REMU raise an
illegal-instruction trap on GARUDA (and on Spike with zmmul), so the
generator never emits them as ordinary instructions. Machine mode only, no C,
no PMP, no debug, misaligned loads/stores trap (no hardware support).
Interrupts are not generated here: GARUDA uses CLIC, not mie/mip; interrupts
come from the directed tests and the tb_boot test device.
"""
import math
from pygen_src.riscv_instr_pkg import (privileged_reg_t, satp_mode_t,
                                       riscv_instr_group_t, mtvec_mode_t,
                                       privileged_mode_t, riscv_instr_name_t)

XLEN = 32
SATP_MODE = satp_mode_t.BARE
supported_privileged_mode = [privileged_mode_t.MACHINE_MODE]
unsupported_instr = [riscv_instr_name_t.DIV, riscv_instr_name_t.DIVU,
                     riscv_instr_name_t.REM, riscv_instr_name_t.REMU]
supported_isa = [riscv_instr_group_t.RV32I, riscv_instr_group_t.RV32M]
supported_interrupt_mode = [mtvec_mode_t.DIRECT]
max_interrupt_vector_num = 16
support_pmp = 0
support_debug_mode = 0
support_umode_trap = 0
support_sfence = 0
support_unaligned_load_store = 0
NUM_FLOAT_GPR = 32
NUM_GPR = 32
NUM_VEC_GPR = 32
VECTOR_EXTENSION_ENABLE = 0
VLEN = 512
ELEN = 32
SELEN = 8
VELEN = int(math.log(ELEN) // math.log(2)) - 3
MAX_LMUL = 8
NUM_HARTS = 1
# the CSRs the generator may touch: the standard machine set GARUDA implements
# (spec/regs/core.yaml); mip/mie are excluded (CLIC mode), misa is read-only
implemented_csr = [privileged_reg_t.MVENDORID, privileged_reg_t.MARCHID,
                   privileged_reg_t.MIMPID, privileged_reg_t.MHARTID,
                   privileged_reg_t.MSTATUS, privileged_reg_t.MTVEC,
                   privileged_reg_t.MSCRATCH, privileged_reg_t.MEPC,
                   privileged_reg_t.MCAUSE, privileged_reg_t.MTVAL]
custom_csr = []
