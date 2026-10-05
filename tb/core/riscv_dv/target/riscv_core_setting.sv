// =============================================================================
// riscv_core_setting.sv - what riscv-dv may generate for the GARUDA core.
//
// riscv-dv (github.com/chipsalliance/riscv-dv, cloned at ~/external/riscv-dv)
// reads this file as its "target". Source for every line: GARUDA-CORE-SPEC-001.
// =============================================================================

parameter int XLEN = 32;
parameter satp_mode_t SATP_MODE = BARE;                       // no MMU

privileged_mode_t supported_privileged_mode[] = {MACHINE_MODE};   // machine mode only

// DIV, DIVU, REM and REMU trap to a software handler on GARUDA (CORE [N-7.5]).
// Spike executes them in one step, so a program that uses them cannot be
// compared instruction by instruction. They are tested by riscv-tests p-div,
// p-divu, p-rem and p-remu instead.
riscv_instr_name_t unsupported_instr[] = {DIV, DIVU, REM, REMU};

riscv_instr_group_t supported_isa[$] = {RV32I, RV32M};        // no C, A, F, D

// Exceptions enter at the mtvec base. (Interrupts are CLIC and are not driven
// in these runs: Spike is not told when the RTL takes one.)
mtvec_mode_t supported_interrupt_mode[$] = {DIRECT};
int max_interrupt_vector_num = 16;

bit support_pmp = 0;
bit support_epmp = 0;
bit support_debug_mode = 0;
bit support_umode_trap = 0;
bit support_sfence = 0;
bit support_unaligned_load_store = 1'b0;                      // misaligned accesses trap

parameter int NUM_FLOAT_GPR = 32;
parameter int NUM_GPR = 32;
parameter int NUM_VEC_GPR = 32;
parameter int VECTOR_EXTENSION_ENABLE = 0;
parameter int VLEN = 512;
parameter int ELEN = 32;
parameter int SELEN = 8;
parameter int VELEN = int'($ln(ELEN)/$ln(2)) - 3;
parameter int MAX_LMUL = 8;
parameter int NUM_HARTS = 1;

// CSRs that exist on GARUDA and on Spike with the same meaning (CORE 6.1)
`ifdef DSIM
privileged_reg_t implemented_csr[] = {
`else
const privileged_reg_t implemented_csr[] = {
`endif
    MVENDORID, MARCHID, MIMPID, MHARTID,
    MSTATUS, MISA, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL, MIP
};

// riscv-dv builds its "access to a CSR that does not exist" instructions from
// every address NOT in the list above or the one below. Three groups are
// therefore listed here, so that such an instruction traps on GARUDA and on
// Spike alike:
//   the counters, which both have;
//   what only GARUDA has (CLIC registers, the DSU flag);
//   what only Spike has (mstatush, mcountinhibit, the hpm counters, trigger
//   registers, time, mconfigptr).
// The last two groups are the output of tools/csr_map.py (make csr_map), which
// reads all 4096 addresses on both and is the test of those differences.
bit [11:0] custom_csr[] = {
    12'hB00, 12'hB02, 12'hB80, 12'hB82, 12'hC00, 12'hC02, 12'hC80, 12'hC82,
    12'h345, 12'h346, 12'h347, 12'hBC0, 12'hFB1,
    12'h310, 12'h320, 12'h323, 12'h324, 12'h325, 12'h326, 12'h327, 12'h328, 12'h329, 12'h32A,
    12'h32B, 12'h32C, 12'h32D, 12'h32E, 12'h32F, 12'h330, 12'h331, 12'h332, 12'h333, 12'h334,
    12'h335, 12'h336, 12'h337, 12'h338, 12'h339, 12'h33A, 12'h33B, 12'h33C, 12'h33D, 12'h33E,
    12'h33F, 12'h7A0, 12'h7A1, 12'h7A2, 12'h7A3, 12'h7A4, 12'h7A8, 12'hB03, 12'hB04, 12'hB05,
    12'hB06, 12'hB07, 12'hB08, 12'hB09, 12'hB0A, 12'hB0B, 12'hB0C, 12'hB0D, 12'hB0E, 12'hB0F,
    12'hB10, 12'hB11, 12'hB12, 12'hB13, 12'hB14, 12'hB15, 12'hB16, 12'hB17, 12'hB18, 12'hB19,
    12'hB1A, 12'hB1B, 12'hB1C, 12'hB1D, 12'hB1E, 12'hB1F, 12'hB83, 12'hB84, 12'hB85, 12'hB86,
    12'hB87, 12'hB88, 12'hB89, 12'hB8A, 12'hB8B, 12'hB8C, 12'hB8D, 12'hB8E, 12'hB8F, 12'hB90,
    12'hB91, 12'hB92, 12'hB93, 12'hB94, 12'hB95, 12'hB96, 12'hB97, 12'hB98, 12'hB99, 12'hB9A,
    12'hB9B, 12'hB9C, 12'hB9D, 12'hB9E, 12'hB9F, 12'hC01, 12'hC81, 12'hF15
};

`ifdef DSIM
interrupt_cause_t implemented_interrupt[] = {
`else
const interrupt_cause_t implemented_interrupt[] = {
`endif
    M_TIMER_INTR
};

`ifdef DSIM
exception_cause_t implemented_exception[] = {
`else
const exception_cause_t implemented_exception[] = {
`endif
    INSTRUCTION_ADDRESS_MISALIGNED,
    INSTRUCTION_ACCESS_FAULT,
    ILLEGAL_INSTRUCTION,
    BREAKPOINT,
    LOAD_ADDRESS_MISALIGNED,
    LOAD_ACCESS_FAULT,
    STORE_AMO_ADDRESS_MISALIGNED,
    STORE_AMO_ACCESS_FAULT,
    ECALL_MMODE
};
