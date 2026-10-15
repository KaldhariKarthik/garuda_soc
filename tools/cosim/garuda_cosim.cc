// =============================================================================
// garuda_cosim.cc -- Spike co-simulation for the GARUDA core (Karthik's plan
// 5.2 / 5.3). Spike (pinned, ~/tools/spike) runs as a library inside the
// simulation; tb_boot calls garuda_cosim_step() through DPI once per RVFI
// record and the record is compared with what Spike did for the same step.
// C++ is allowed here only (Track A rule: C++ for the Spike glue in tools/cosim).
//
// Compared per record: PC, instruction, trap or not, next PC, rd and its value,
// every store (address, size, data). A trap record must trap in Spike too.
//
// What the harness applies to Spike from the GARUDA specs (Spike has no CLIC,
// no GARUDA CSRs, no DSU):
//   - CLIC / MTI entry (5.3): queued by garuda_cosim_interrupt() when the RTL
//     takes it, applied when the first handler instruction arrives (RVFI intr
//     without a trap record): mepc = Spike's PC, mcause = interrupt | mpil<<16 |
//     id (T-12), MPIE <- MIE, MIE <- 0, PC <- mtvec BASE, mil <- level (MTI keeps
//     mil, R1). The decision is checked: MIE was set, level > mil, level >
//     mintthresh (for CLIC).
//   - T-12 on exceptions: mcause[23:16] = mil; MRET: mil <- mcause[23:16].
//   - GARUDA-only CSRs and CSRs whose value Spike cannot reproduce (counters,
//     misa M vs Zmmul, mtvec MODE = CLIC, mnxti / mintstatus / mintthresh /
//     mgarudactl / dsu_ovf / 0xFB1): rd is taken from the RTL and the write is
//     mirrored where Spike has the CSR (mtvec base).
//   - DSU custom-0 (opcode 0x0B): rd taken from the RTL (the DSU is checked
//     against its own models; a Spike DSU extension is plan 5.5).
//   - WFI: treated as a NOP in Spike (the RTL record says where execution went).
// Everything else (traps, mcause / mepc / mtval, loads, CSR reads of shared
// CSRs) is Spike's own result.
// =============================================================================
#include <riscv/cfg.h>
#include <riscv/decode.h>
#include <riscv/mmu.h>
#include <riscv/processor.h>
#include <riscv/simif.h>
#include <riscv/trap.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct garuda_sim_t : public simif_t {
    std::vector<uint8_t> mem;
    reg_t base = 0, size = 0;
    bool err_en = false;
    reg_t err_base = 0, err_size = 0;
    cfg_t cfg;
    std::map<size_t, processor_t*> harts;

    char* addr_to_mem(reg_t a) override {
        if (a < base || a >= base + size) return nullptr;            // outside: access fault
        if (err_en && a >= err_base && a < err_base + err_size) return nullptr;   // tb_boot error window
        return reinterpret_cast<char*>(&mem[a - base]);
    }
    bool mmio_load(reg_t, size_t, uint8_t*) override { return false; }
    bool mmio_store(reg_t, size_t, const uint8_t*) override { return false; }
    void proc_reset(unsigned) override {}
    const cfg_t& get_cfg() const override { return cfg; }
    const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
    const char* get_symbol(uint64_t) override { return nullptr; }
};

struct irq_event_t {
    uint32_t cause;      // RTL tr_cause: bit 31 set, low bits = CLIC id or 7 (MTI)
    uint32_t level;      // RTL tr_level
    uint32_t thresh;     // mintthresh at the take
};

garuda_sim_t* sim = nullptr;
processor_t* proc = nullptr;
std::ostringstream sout;
std::deque<irq_event_t> irq_q;
uint32_t mil = 0;                // CLIC interrupt level (mintstatus.mil), harness-held
uint64_t n_steps = 0, n_mismatch = 0, n_irq = 0, n_traps = 0, n_synced = 0;
const uint64_t max_report = 10;
uint32_t reset_pc = 0x10000000;

uint32_t ld32(const std::string& s) { return static_cast<uint32_t>(std::stoul(s, nullptr, 16)); }

bool load_hex(const char* path) {
    std::ifstream f(path);
    if (!f) return false;
    std::string ln;
    reg_t addr = sim->base;
    while (std::getline(f, ln)) {
        auto c = ln.find("//");
        if (c != std::string::npos) ln = ln.substr(0, c);
        std::istringstream is(ln);
        std::string tok;
        while (is >> tok) {
            if (tok[0] == '@') { addr = sim->base + 4 * ld32(tok.substr(1)); continue; }
            uint32_t w = ld32(tok);
            if (addr + 4 <= sim->base + sim->size) std::memcpy(&sim->mem[addr - sim->base], &w, 4);
            addr += 4;
        }
    }
    return true;
}

void mismatch(const char* what, uint32_t pc, uint64_t rtl, uint64_t ref) {
    ++n_mismatch;
    if (n_mismatch <= max_report)
        std::printf("COSIM-MISMATCH step %llu pc %08x: %s rtl=%08llx spike=%08llx\n",
                    (unsigned long long)n_steps, pc, what, (unsigned long long)rtl,
                    (unsigned long long)ref);
}

bool is_csr(uint32_t insn) { return (insn & 0x7f) == 0x73 && ((insn >> 12) & 7) != 0 && ((insn >> 12) & 7) != 4; }
uint32_t csr_of(uint32_t insn) { return insn >> 20; }

// CSRs whose value Spike cannot reproduce: rd comes from the RTL
bool synced_csr(uint32_t a) {
    switch (a) {
        case 0x301:                          // misa: M vs Zmmul (DN-ISA ruling pending)
        case 0x304: case 0x344:              // mie / mip: GARUDA keeps only MTIE / MTIP (CLIC)
        case 0xF11: case 0xF12: case 0xF13:  // mvendorid / marchid / mimpid: implementation values
        case 0x305:                          // mtvec: MODE reads 3 (CLIC)
        case 0x345: case 0x346: case 0x347:  // mnxti, mintstatus, mintthresh
        case 0x7C0: case 0xBC0: case 0xFB1:  // mgarudactl, dsu_ovf, mintstatus (std)
        case 0xB00: case 0xB02: case 0xB80: case 0xB82:   // mcycle / minstret (C-17)
        case 0xC00: case 0xC02: case 0xC80: case 0xC82:   // cycle / instret
            return true;
    }
    return false;
}

void set_x(unsigned rd, uint32_t v) {
    if (rd) proc->get_state()->XPR.write(rd, static_cast<reg_t>(static_cast<int32_t>(v)));
}

// the CSR write a synced instruction makes, mirrored where Spike has the CSR
void mirror_csr_write(uint32_t insn, uint32_t old_v) {
    uint32_t a = csr_of(insn), f3 = (insn >> 12) & 7, rs1 = (insn >> 15) & 31;
    uint32_t src = (f3 & 4) ? rs1 : static_cast<uint32_t>(proc->get_state()->XPR[rs1]);
    uint32_t nv = old_v;
    switch (f3 & 3) {
        case 1: nv = src; break;
        case 2: if (rs1) nv = old_v | src; break;
        case 3: if (rs1) nv = old_v & ~src; break;
    }
    if (a == 0x305) proc->put_csr(CSR_MTVEC, nv & ~3u);   // Spike runs it in direct mode
    if (a == 0x304) proc->put_csr(CSR_MIE, nv & 0x80u);    // GARUDA mie: MTIE only
}

void apply_interrupt(const irq_event_t& e) {
    state_t* s = proc->get_state();
    bool clic = (e.cause & 0xfff) != 7;
    reg_t ms = s->mstatus->read();
    if (!(ms & MSTATUS_MIE)) mismatch("interrupt taken with MIE clear", (uint32_t)s->pc, 1, 0);
    if (clic && !(e.level > mil)) mismatch("CLIC take with level <= mil", (uint32_t)s->pc, e.level, mil);
    if (clic && !(e.level > e.thresh)) mismatch("CLIC take with level <= mintthresh", (uint32_t)s->pc, e.level, e.thresh);
    proc->put_csr(CSR_MEPC, s->pc);
    proc->put_csr(CSR_MCAUSE, (reg_t)(0x80000000u | (mil << 16) | (e.cause & 0xfff)));
    reg_t nms = (ms & ~(MSTATUS_MPIE | MSTATUS_MIE)) | ((ms & MSTATUS_MIE) ? MSTATUS_MPIE : 0);
    proc->put_csr(CSR_MSTATUS, nms);
    s->pc = s->mtvec->read() & ~(reg_t)3;
    if (clic) mil = e.level;
    proc->clear_waiting_for_interrupt();
    ++n_irq;
}

}  // namespace

extern "C" {

// isa / mem: as tools/lockstep.py runs Spike (M-mode only, no PMP, no triggers)
int garuda_cosim_init(const char* hexfile, int base, int size, int err_en, int err_base, int err_size) {
    sim = new garuda_sim_t();
    sim->base = (uint32_t)base; sim->size = (uint32_t)size;
    sim->err_en = err_en != 0; sim->err_base = (uint32_t)err_base; sim->err_size = (uint32_t)err_size;
    sim->mem.assign(sim->size, 0);
    sim->cfg.isa = "rv32i_zmmul_zicsr_zifencei_zicntr";   // DN-ISA: MUL family in hardware, DIV/REM trap
    sim->cfg.priv = "M";
    sim->cfg.pmpregions = 0;
    sim->cfg.trigger_count = 0;
    sim->cfg.hartids = {0};
    if (!load_hex(hexfile)) { std::printf("COSIM: cannot read %s\n", hexfile); return 1; }
    // commit logging (needed for the register / memory write logs) prints to
    // this file: it must exist
    static FILE* logf = std::fopen("/dev/null", "w");
    proc = new processor_t(sim->cfg.isa, sim->cfg.priv, &sim->cfg, sim, 0, false, logf, sout);
    sim->harts[0] = proc;
    proc->enable_log_commits();
    proc->reset();
    reset_pc = (uint32_t)base;
    proc->get_state()->pc = reset_pc;
    std::printf("COSIM: spike %s, %s, mem %08x+%x%s\n", sim->cfg.isa, sim->cfg.priv, base, size,
                err_en ? " (error window)" : "");
    return 0;
}

// warm reset (tb_boot +RERESET_AT): memory keeps its contents, the hart resets
void garuda_cosim_reset() {
    if (!proc) return;
    proc->reset();
    proc->get_state()->pc = reset_pc;
    irq_q.clear();
    mil = 0;
}

void garuda_cosim_interrupt(int cause, int level, int thresh) {
    irq_q.push_back({(uint32_t)cause, (uint32_t)level, (uint32_t)thresh});
}

// one RVFI record; returns 0 when it matches Spike
int garuda_cosim_step(int pc_i, int insn_i, int trap_i, int intr_i, int npc_i, int rd_i, int rd_wdata_i,
                      int mem_addr_i, int mem_wmask_i, int mem_wdata_i) {
    if (!proc) return 1;
    ++n_steps;
    uint64_t before = n_mismatch;
    uint32_t pc = (uint32_t)pc_i, insn = (uint32_t)insn_i, npc = (uint32_t)npc_i;
    state_t* s = proc->get_state();

    // an interrupt the RTL took enters here: an intr record that follows a
    // trap record opens that exception's handler instead
    static bool last_trap = false;
    bool after_trap = last_trap;
    last_trap = trap_i != 0;
    if (intr_i && !after_trap && !irq_q.empty()) {
        apply_interrupt(irq_q.front());
        irq_q.pop_front();
    }
    if ((uint32_t)s->pc != pc) mismatch("pc", pc, pc, (uint32_t)s->pc);

    bool sync_rd = (insn & 0x7f) == 0x0b ||                       // DSU custom-0
                   (is_csr(insn) && synced_csr(csr_of(insn))) ||
                   insn == 0x10500073u;                            // WFI
    if (!trap_i && sync_rd) {
        ++n_synced;
        uint32_t old_v = 0;
        if (is_csr(insn) && csr_of(insn) == 0x305) old_v = (uint32_t)s->mtvec->read();
        if (is_csr(insn) && csr_of(insn) == 0x304) old_v = (uint32_t)proc->get_csr(CSR_MIE);
        if (is_csr(insn)) mirror_csr_write(insn, old_v);
        set_x((unsigned)rd_i, (uint32_t)rd_wdata_i);
        s->pc = pc + 4;
        if ((uint32_t)s->pc != npc) mismatch("next pc (synced)", pc, npc, (uint32_t)s->pc);
        return n_mismatch != before;
    }

    bool is_mret = insn == 0x30200073u;
    uint32_t mret_mil = is_mret ? (uint32_t)((proc->get_csr(CSR_MCAUSE) >> 16) & 0xff) : 0;

    s->log_reg_write.clear(); s->log_mem_read.clear(); s->log_mem_write.clear();
    // Spike's minstret does not advance when the instruction traps
    reg_t ir0 = proc->get_csr(CSR_MINSTRET);
    proc->step(1);
    if (proc->is_waiting_for_interrupt()) proc->clear_waiting_for_interrupt();
    reg_t mcause1 = proc->get_csr(CSR_MCAUSE);
    bool spike_trapped = proc->get_csr(CSR_MINSTRET) == ir0;

    if (is_mret) mil = mret_mil;
    if (trap_i) {
        ++n_traps;
        if (!spike_trapped) mismatch("RTL trapped, Spike did not", pc, 1, 0);
        // T-12: an exception keeps the level and saves it in mcause[23:16]
        proc->put_csr(CSR_MCAUSE, (proc->get_csr(CSR_MCAUSE) & ~(reg_t)0x00ff0000) | (mil << 16));
    } else if (spike_trapped && !is_mret) {
        mismatch("Spike trapped, RTL did not (mcause)", pc, 0, (uint32_t)mcause1);
    }
    if ((uint32_t)s->pc != npc) mismatch("next pc", pc, npc, (uint32_t)s->pc);

    // rd
    uint32_t ref_rd = 0, ref_v = 0;
    for (auto& w : s->log_reg_write) {
        if ((w.first & 0xf) == 0 && (w.first >> 4) != 0) { ref_rd = (uint32_t)(w.first >> 4); ref_v = (uint32_t)w.second.v[0]; }
    }
    if (!trap_i) {
        if ((uint32_t)rd_i != ref_rd && !(rd_i == 0 && ref_rd == 0)) mismatch("rd", pc, (uint32_t)rd_i, ref_rd);
        else if (ref_rd && (uint32_t)rd_wdata_i != ref_v) mismatch("rd value", pc, (uint32_t)rd_wdata_i, ref_v);
    }
    // stores
    uint32_t wmask = (uint32_t)mem_wmask_i;
    if (!s->log_mem_write.empty()) {
        auto& m = s->log_mem_write.front();
        uint32_t a = (uint32_t)std::get<0>(m), sz = std::get<2>(m);
        uint32_t v = (uint32_t)std::get<1>(m);
        uint32_t lane = a & 3, rmask = (((1u << sz) - 1) << lane) & 0xf;
        uint32_t rdata = (uint32_t)((uint64_t)v << (8 * lane));
        uint32_t lanemask = 0;
        for (int i = 0; i < 4; ++i) if (rmask & (1u << i)) lanemask |= 0xffu << (8 * i);
        if ((uint32_t)mem_addr_i != (a & ~3u)) mismatch("store address", pc, (uint32_t)mem_addr_i, a & ~3u);
        if (wmask != rmask) mismatch("store mask", pc, wmask, rmask);
        if (((uint32_t)mem_wdata_i & lanemask) != (rdata & lanemask)) mismatch("store data", pc, (uint32_t)mem_wdata_i, rdata);
    } else if (wmask && !trap_i) {
        mismatch("RTL stored, Spike did not", pc, (uint32_t)mem_addr_i, 0);
    }
    return n_mismatch != before;
}

void garuda_cosim_report() {
    std::printf("COSIM: %llu steps, %llu traps, %llu interrupts applied, %llu synced, %llu mismatches\n",
                (unsigned long long)n_steps, (unsigned long long)n_traps, (unsigned long long)n_irq,
                (unsigned long long)n_synced, (unsigned long long)n_mismatch);
    if (!irq_q.empty())
        std::printf("COSIM-MISMATCH: %zu interrupt(s) taken by the RTL never reached a handler\n", irq_q.size());
}

int garuda_cosim_mismatches() { return (int)(n_mismatch + irq_q.size()); }

}  // extern "C"
