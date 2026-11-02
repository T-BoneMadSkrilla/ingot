/*
 * hakuX macOS prototype — smoke test: x86 guest code under hakuX's FEXCore
 * glue (native/cpu) on Apple silicon, against 4 KiB guest pages on the 16 KiB
 * host (vm16k). Checks direct and trapped blocks give the same results, then
 * times an access through each.
 *
 * Guest layout:
 *   0x00010000  code, stack below 0x00110000      direct
 *   0x00200000  16 KiB at pa 0x400000             direct
 *   0x00300000  four pages from scattered pa      trapped
 *   0x00310000  one page, an alias of 0x00300000  trapped
 */
#include "mac/proto/vm16k.h"
#include "native/cpu/cpu.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

V16 g_vm;
int g_failures;

constexpr uint32_t CODE = 0x10000, BENCH = 0x11000, STACK_TOP = 0x10F000;
constexpr uint32_t D_VA = 0x200000, D_PA = 0x400000;
constexpr uint32_t T_VA = 0x300000, ALIAS_VA = 0x310000;
constexpr uint32_t T_PA[4] = {0x508000, 0x50D000, 0x502000, 0x50F000};

void check(const char* what, uint64_t got, uint64_t want) {
  const bool ok = got == want;
  g_failures += !ok;
  printf("  %-44s %s (got %llx, want %llx)\n", what, ok ? "ok  " : "FAIL", (unsigned long long)got, (unsigned long long)want);
}

uint32_t rd32(uint32_t pa) {
  uint32_t v;
  memcpy(&v, g_vm.phys + pa, 4);
  return v;
}

void wr32(uint32_t pa, uint32_t v) {
  memcpy(g_vm.phys + pa, &v, 4);
}

bool sysop(void*, NcFrame* f, NcSysOp op, unsigned) {
  fprintf(stderr, "smoke: unexpected system op %d at %08x\n", op, nc_frame_eip(f));
  return false;
}

void put(uint32_t va, std::initializer_list<uint8_t> bytes) {
  const uint32_t pa = v16_phys(&g_vm, va);
  memcpy(g_vm.phys + pa, bytes.begin(), bytes.size());
}

// The functional program, hand-assembled (32-bit x86).
std::vector<uint8_t> program() {
  std::vector<uint8_t> c;
  auto emit = [&](std::initializer_list<uint8_t> b) { c.insert(c.end(), b); };
  auto imm = [&](uint32_t v) { emit({uint8_t(v), uint8_t(v >> 8), uint8_t(v >> 16), uint8_t(v >> 24)}); };
  emit({0xA1}), imm(T_VA);                                   // mov eax, [T]          trapped load
  emit({0xA3}), imm(T_VA + 0x1FFC);                          // mov [T+1ffc], eax     trapped store
  emit({0xC7, 0x05}), imm(T_VA + 0x1FFE), imm(0xAABBCCDD);   // mov dword [T+1ffe]    across two scattered pages
  emit({0x8B, 0x1D}), imm(ALIAS_VA);                         // mov ebx, [alias]      second VA, same page
  emit({0xC7, 0x05}), imm(ALIAS_VA + 4), imm(0x12345678);    // mov dword [alias+4]
  emit({0xB9}), imm(7);                                      // mov ecx, 7
  emit({0xF0, 0x0F, 0xC1, 0x0D}), imm(T_VA + 0x2010);        // lock xadd [T+2010], ecx
  emit({0x89, 0x0D}), imm(D_VA + 0x104);                     // mov [D+104], ecx
  emit({0xB8}), imm(0x55);                                   // mov eax, 0x55
  emit({0xBA}), imm(0x66);                                   // mov edx, 0x66
  emit({0xF0, 0x0F, 0xB1, 0x15}), imm(T_VA + 0x2014);        // lock cmpxchg [T+2014], edx
  emit({0x89, 0x05}), imm(D_VA + 0x108);                     // mov [D+108], eax
  emit({0x0F, 0x10, 0x05}), imm(T_VA + 0x3000);              // movups xmm0, [T+3000] trapped 16-byte load
  emit({0x0F, 0x11, 0x05}), imm(D_VA + 0x20);                // movups [D+20], xmm0
  emit({0xBE}), imm(D_VA);                                   // mov esi, D
  emit({0xBF}), imm(T_VA + 0x3100);                          // mov edi, T+3100
  emit({0xB9}), imm(16);                                     // mov ecx, 16
  emit({0xFC, 0xF3, 0xA5});                                  // cld; rep movsd        string copy into trapped
  emit({0xBF}), imm(T_VA + 0x3200);                          // mov edi, T+3200
  emit({0xB9}), imm((0x1000 - 0x200) / 4);                   // mov ecx, to the page's end
  emit({0xB8}), imm(0x5A5A5A5A);                             // mov eax, 5a5a5a5a
  emit({0xF3, 0xAB});                                        // rep stosd             fill the rest of the trapped page
  emit({0x89, 0x1D}), imm(D_VA + 0x100);                     // mov [D+100], ebx
  emit({0xF4});                                              // hlt
  return c;
}

double run_bench(NcCpu* cpu, uint32_t addr, uint32_t iters) {
  NcCpuContext c;
  nc_context_init(cpu, &c, BENCH, STACK_TOP);
  nc_context_set_gpr(&c, NC_ESI, addr);
  nc_context_set_gpr(&c, NC_ECX, iters);
  const auto t0 = std::chrono::steady_clock::now();
  nc_cpu_run(cpu, &c);
  const auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::nano>(t1 - t0).count() / iters;
}

} // namespace

int main() {
  printf("hakuX macOS prototype: FEXCore + 4 KiB guest pages on a 16 KiB host\n");
  if (!v16_init(&g_vm, 64u << 20)) {
    return 1;
  }
  v16_trap_install(&g_vm);

  // The layout: direct where the kernel's allocator can line pages up, trapped where a title's mapping can't.
  bool ok = v16_map(&g_vm, CODE, CODE, 0x100000, false) && v16_map(&g_vm, D_VA, D_PA, 0x4000, false);
  for (unsigned i = 0; i < 4; i++) {
    ok = ok && v16_map(&g_vm, T_VA + i * V16_GPAGE, T_PA[i], V16_GPAGE, false);
  }
  ok = ok && v16_map(&g_vm, ALIAS_VA, T_PA[0], V16_GPAGE, false);
  // The contiguous window over all of RAM, as the Xbox kernel's 0x80000000 view.
  ok = ok && v16_map(&g_vm, 0x80000000u, 0, g_vm.ram_size, false);
  if (!ok) {
    return 1;
  }
  uint32_t direct, trapped;
  v16_census(&g_vm, &direct, &trapped);
  printf("blocks: %u direct, %u trapped\n", direct, trapped);

  // Seeds, through the host's view.
  wr32(T_PA[0], 0x11111111);
  wr32(T_PA[2] + 0x10, 100);
  wr32(T_PA[2] + 0x14, 0x55);
  for (unsigned i = 0; i < 16; i++) {
    g_vm.phys[T_PA[3] + i] = (uint8_t)i;
  }
  for (unsigned i = 0; i < 64; i++) {
    g_vm.phys[D_PA + i] = (uint8_t)(0xC0 + i);
  }
  const auto code = program();
  memcpy(g_vm.phys + CODE, code.data(), code.size());
  put(BENCH, {0x31, 0xC0, 0x03, 0x06, 0x49, 0x75, 0xFB, 0xF4}); // xor eax,eax; L: add eax,[esi]; dec ecx; jnz L; hlt

  NcCpuConfig cfg {};
  cfg.membase = g_vm.base;
  cfg.sysop = sysop;
  NcCpu* cpu = nc_cpu_create(&cfg, 0);
  if (!cpu) {
    fprintf(stderr, "smoke: nc_cpu_create failed\n");
    return 1;
  }
  printf("JIT up; running the functional program\n");

  NcCpuContext ctx;
  nc_context_init(cpu, &ctx, CODE, STACK_TOP);
  nc_cpu_run(cpu, &ctx);

  printf("results:\n");
  check("trapped load -> trapped store", rd32(T_PA[1] + 0xFFC), 0xCCDD1111);
  check("store across scattered pages (low half)", rd32(T_PA[1] + 0xFFC) >> 16, 0xCCDD);
  check("store across scattered pages (high half)", rd32(T_PA[2]) & 0xFFFF, 0xAABB);
  check("alias VA reads the same physical page", rd32(D_PA + 0x100), 0x11111111);
  check("store through alias lands in the page", rd32(T_PA[0] + 4), 0x12345678);
  check("lock xadd: memory", rd32(T_PA[2] + 0x10), 107);
  check("lock xadd: old value", rd32(D_PA + 0x104), 100);
  check("lock cmpxchg: memory", rd32(T_PA[2] + 0x14), 0x66);
  check("lock cmpxchg: eax", rd32(D_PA + 0x108), 0x55);
  check("movups from trapped (bytes 0-3)", rd32(D_PA + 0x20), 0x03020100);
  check("movups from trapped (bytes 12-15)", rd32(D_PA + 0x2C), 0x0F0E0D0C);
  check("rep movsd into trapped", memcmp(g_vm.phys + T_PA[3] + 0x100, g_vm.phys + D_PA, 64), 0);
  check("rep stosd within trapped (last dword)", rd32(T_PA[3] + 0xFFC), 0x5A5A5A5A);
  check("contiguous window sees the page", *(uint32_t*)(g_vm.base + 0x80000000u + T_PA[0] + 4), 0x12345678);
  printf("accesses emulated: %llu\n", (unsigned long long)g_vm.trapped);

  // Timing: the same load loop against a direct and a trapped page.
  wr32(D_PA + 0x200, 1);
  wr32(T_PA[1] + 0x200, 1);
  run_bench(cpu, D_VA + 0x200, 1000); // translate it once
  const uint64_t before = g_vm.trapped;
  const double direct_ns = run_bench(cpu, D_VA + 0x200, 50'000'000);
  const double trapped_ns = run_bench(cpu, T_VA + 0x1200, 200'000);
  printf("loop iteration with a direct load:  %8.2f ns\n", direct_ns);
  printf("loop iteration with a trapped load: %8.2f ns (%llu emulated)\n", trapped_ns,
         (unsigned long long)(g_vm.trapped - before));
  printf("a trapped access costs ~%.0fx a direct one\n", trapped_ns / direct_ns);

  printf("%s\n", g_failures ? "FAILED" : "all checks passed");
  return g_failures ? 1 : 0;
}
