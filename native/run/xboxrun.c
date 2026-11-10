/*
 * xboxrun — runs an Xbox title in the native core from the command line
 * (adb shell, /data/local/tmp), without the app: no window, no sound, on
 * the HLE GPU as the app runs it (HAKUX_HLE_MODE=replace unless set).
 *
 *   xboxrun <disc image> [option...]
 *
 * Options: the app's for the core (native/core/options.h: loadstate=,
 * scale=, asyncpipe=, mods=, video=, clock=, ...), and
 *   hdd=DIR          the hard disk folder (Partition0-5; made as needed),
 *                    default /data/local/tmp/native/hdd
 *   vkdriver=DIR|LIB|HOOKS  a custom Vulkan driver through adrenotools, as
 *                    the app's (native/app/vkdriver.c)
 *   capture=N[,N...] frames N written to frames/fN.png in the working
 *                    directory, as presented (frames count the HLE GPU's
 *                    swaps in this process: after loadstate=, since the load)
 *   frames=N         the run ends after frame N (exit 0), the shader and
 *                    pipeline caches written first
 *   hang=S           no new frame for S seconds: the guest's state reported
 *                    and exit 6 (from the start: a load's first frame too)
 *   window=0         macOS: no window (mac/window.m; there by default, with
 *                    the keyboard and a game controller as player 1)
 * NC_TIMEOUT=S (default 30, 0 none; with a window, none) ends any run after S seconds.
 *
 * Exit status: 0 the run ended (frames=, or the guest halted), 1 boot
 * failed, 2 usage or the disc can't be opened, 3 a host fault, 5 NC_TIMEOUT,
 * 6 hang=, 7 the guest stopped (a bugcheck, an unhandled exception: its
 * "stop:" line says why), 8 the savestate couldn't be loaded, 9 the GPU
 * device was lost, 10 the title left (to the dashboard, a reboot, another
 * XBE). xboxrun.sh adds 4: the app is running.
 */
#include "native/app/app.h"
#include "native/core/core.h"
#include "native/core/mmio.h"
#include "native/core/options.h"
#include "native/hle/hle_native.h"
#include "hw/xbox/hle/vk/back.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "native/core/hostctx.h"
#include <unistd.h>
#ifdef __APPLE__
#include "mac/window.h"
#endif

static NcCore g_core;

/* capture.c: NC_CAPTURE_EVERY=<s> writes the presented frame to frames/;
 * capture= and frames= by frame. */
void nc_capture_start(void);
void nc_capture_frames(const char *list, uint64_t stop);
static void dump_ranges(const char *spec);
#ifdef NC_VM16K
static void vm16k_report(const char *when);
#endif

/* Hex dump of mapped guest bytes (unmapped pages show as ..). */
static void dump_guest(const NcVm *vm, const char *what, uint32_t va, unsigned len)
{
    char buf[512];
    int n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   %s %08x:", what, va);
    for (unsigned i = 0; i < len && n < (int)sizeof(buf) - 4; i++) {
        if (nc_vm_phys(vm, va + i) == UINT32_MAX) {
            n += snprintf(buf + n, sizeof(buf) - (size_t)n, " ..");
        } else {
            n += snprintf(buf + n, sizeof(buf) - (size_t)n, " %02x", *(const uint8_t *)nc_vm_host(vm, va + i));
        }
    }
    buf[n++] = '\n';
    write(2, buf, (size_t)n);
}

/* Guest state at a signal: registers live in host registers inside JIT code
 * (FEX's 32-bit static mapping: eax x4, ecx x7, edx x5, ebx x6, esp x8, ebp x9,
 * esi x10, edi x11). */
static void report_guest(const NcHostRegs *mc, uint32_t eip)
{
    if (eip) {
        static const char *const names[8] = {"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"};
        static const int regs[8] = {4, 7, 5, 6, 8, 9, 10, 11};
        char buf[256];
        int n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:  ");
        for (int i = 0; i < 8; i++) {
            n += snprintf(buf + n, sizeof(buf) - (size_t)n, " %s=%08x", names[i], (uint32_t)mc->regs[regs[i]]);
        }
        buf[n++] = '\n';
        write(2, buf, (size_t)n);
        dump_guest(&g_core.vm, "code", eip - 32, 64);
        dump_guest(&g_core.vm, "stack", (uint32_t)mc->regs[8], 64);
    }
    nc_mmio_dump_stats(2);
    nc_kernel_dump_recent(2);
    nc_kernel_dump_threads(&g_core.kernel, 2);
}

/* The faulting host thread and the mappings around it (a crash path: not
 * async-signal-safe, but the process is going down). */
static void report_host_thread(uintptr_t pc, uintptr_t sp, uintptr_t addr)
{
    char buf[512], comm[64] = "?";
    const int tid = (int)gettid();
    snprintf(buf, sizeof(buf), "/proc/self/task/%d/comm", tid);
    FILE *f = fopen(buf, "r");
    if (f) {
        if (fgets(comm, sizeof(comm), f)) {
            comm[strcspn(comm, "\n")] = 0;
        }
        fclose(f);
    }
#ifdef __APPLE__
    pthread_getname_np(pthread_self(), comm, sizeof(comm));
    if (!comm[0]) {
        snprintf(comm, sizeof(comm), "%s", pthread_main_np() ? "main" : "?");
    }
#endif
    int n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   thread %d (%s) sp=%llx (main %d)\n", tid, comm,
                     (unsigned long long)sp, (int)getpid());
    write(2, buf, (size_t)n);
    f = fopen("/proc/self/maps", "r");
    if (!f) {
        return;
    }
    char line[400];
    while (fgets(line, sizeof(line), f)) {
        unsigned long long lo, hi;
        if (sscanf(line, "%llx-%llx", &lo, &hi) != 2) {
            continue;
        }
        const char *what = pc >= lo && pc < hi ? "pc" : sp >= lo && sp < hi ? "sp" : addr >= lo && addr < hi ? "addr"
                         : addr >= hi && addr - hi < 0x10000 ? "below addr" : addr < lo && lo - addr < 0x10000 ? "above addr"
                                                                                                                   : NULL;
        if (what) {
            n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   map %-10s %s", what, line);
            write(2, buf, (size_t)n);
        }
    }
    fclose(f);
}

#if defined(__APPLE__) && defined(__aarch64__)
/* The host callers, by the frame pointer chain from the fault (lr first). */
static void report_host_frames(uintptr_t lr, uintptr_t fp)
{
    char buf[512];
    for (int i = 0; i < 24 && lr; i++) {
        Dl_info dl;
        const uintptr_t pc = lr & 0x0000FFFFFFFFFFFFull;    /* without the pointer's signature */
        int n;
        if (dladdr((void *)pc, &dl) && dl.dli_fbase) {
            const char *base = strrchr(dl.dli_fname, '/');
            n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   #%d %s+0x%llx (%s+0x%llx)\n", i,
                         base ? base + 1 : dl.dli_fname, (unsigned long long)(pc - (uintptr_t)dl.dli_fbase),
                         dl.dli_sname ? dl.dli_sname : "?",
                         (unsigned long long)(dl.dli_saddr ? pc - (uintptr_t)dl.dli_saddr : 0));
        } else {
            n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   #%d %llx\n", i, (unsigned long long)pc);
        }
        write(2, buf, (size_t)n);
        if (!fp || (fp & 15)) {
            break;
        }
        const uintptr_t next = ((const uintptr_t *)fp)[0];
        lr = ((const uintptr_t *)fp)[1];
        if (next <= fp) {
            break;
        }
        fp = next;
    }
}
#endif

static void fault(int sig, siginfo_t *info, void *ctx)
{
    if (nc_core_fault(&g_core, sig, info, ctx)) {
        return;
    }
    const NcHostRegs *mc = nc_host_regs(ctx);
    uint64_t guest = nc_vm_guest_of(&g_core.vm, info->si_addr);
    uint32_t eip = nc_cpu_guest_eip_at(g_core.cpu, (uintptr_t)mc->pc);
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "hakuX-native-frontier: fault sig=%d host_pc=%llx addr=%p guest_addr=%s%llx "
                     "guest_eip=%08x\n",
                     sig, (unsigned long long)mc->pc, info->si_addr,
                     guest == UINT64_MAX ? "host:" : "", (unsigned long long)(guest == UINT64_MAX ? 0 : guest),
                     eip);
    write(2, buf, (size_t)n);
    report_host_thread((uintptr_t)mc->pc, (uintptr_t)mc->sp, (uintptr_t)info->si_addr);
    if (eip) {
        n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   host insn %08x\n", *(const uint32_t *)(uintptr_t)mc->pc);
        write(2, buf, (size_t)n);
    }
    /* Host code: where in which image (llvm-addr2line on the unstripped build).
     * Any pc in an image, eip or not: another thread's guest eip can come
     * back for a crash in the system's code. */
    Dl_info dl;
    if (dladdr((void *)(uintptr_t)mc->pc, &dl) && dl.dli_fbase) {
        n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   host %s+0x%llx (%s)\n", dl.dli_fname,
                     (unsigned long long)((uintptr_t)mc->pc - (uintptr_t)dl.dli_fbase),
                     dl.dli_sname ? dl.dli_sname : "?");
        write(2, buf, (size_t)n);
        n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   host lr +0x%llx\n",
                     (unsigned long long)((uintptr_t)mc->regs[30] - (uintptr_t)dl.dli_fbase));
        write(2, buf, (size_t)n);
#if defined(__APPLE__) && defined(__aarch64__)
        report_host_frames((uintptr_t)mc->regs[30], (uintptr_t)mc->regs[29]);
#endif
    }
    if (g_core.kernel.in_call && g_core.kernel.frame) {
        /* Inside a kernel function: the guest state is the call's frame. */
        NcFrame *f = g_core.kernel.frame;
        static const char *const names[8] = {"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"};
        n = snprintf(buf, sizeof(buf), "hakuX-native-frontier:   in a kernel call; guest");
        for (int i = 0; i < 8; i++) {
            n += snprintf(buf + n, sizeof(buf) - (size_t)n, " %s=%08x", names[i], nc_frame_gpr(f, i));
        }
        buf[n++] = '\n';
        write(2, buf, (size_t)n);
        const uint32_t esp = nc_frame_gpr(f, NC_ESP);
        dump_guest(&g_core.vm, "stack", esp, 64);
        dump_guest(&g_core.vm, "stack", esp + 64, 64);
        const uint32_t ret = nc_vm_phys(&g_core.vm, esp) != UINT32_MAX ? nc_vm_rd32(&g_core.vm, esp) : 0;
        dump_guest(&g_core.vm, "caller", ret - 48, 64);
        dump_ranges(getenv("NC_FAULT_DUMP"));
        report_guest(mc, 0);
    } else {
        report_guest(mc, eip);
        dump_ranges(getenv("NC_FAULT_DUMP"));
    }
    _exit(3);
}

/* NC_TIMEOUT (seconds, default 30): a run that neither stops nor faults by
 * then is reported where it is (a guest spin shows its EIP and MMIO sites). */
static unsigned g_timeout;

static void timeout(int sig, siginfo_t *info, void *ctx)
{
    const NcHostRegs *mc = nc_host_regs(ctx);
    uint32_t eip = nc_cpu_guest_eip_at(g_core.cpu, (uintptr_t)mc->pc);
    char buf[160];
    int n = snprintf(buf, sizeof(buf), "hakuX-native-frontier: timeout after %u s: host_pc=%llx guest_eip=%08x%s\n",
                     g_timeout, (unsigned long long)mc->pc, eip, eip ? "" : " (not in guest code)");
    write(2, buf, (size_t)n);
#ifdef NC_VM16K
    vm16k_report("timeout");
#endif
    report_guest(mc, eip);
    dump_ranges(getenv("NC_FAULT_DUMP"));
    _exit(5);
}

/* NC_DUMP="va,len;va,len": after the title loads, writes guest bytes to
 * dump_<va>.bin in the working directory (for disassembly on the host). */
static void dump_ranges(const char *spec)
{
    while (spec && *spec) {
        char *end;
        uint32_t va = (uint32_t)strtoul(spec, &end, 16);
        uint32_t len = *end == ',' ? (uint32_t)strtoul(end + 1, &end, 16) : 0;
        char name[64];
        snprintf(name, sizeof(name), "dump_%08x.bin", va);
        FILE *out = fopen(name, "wb");
        for (uint32_t i = 0; out && i < len; i++) {
            const uint8_t b = nc_vm_phys(&g_core.vm, va + i) == UINT32_MAX ? 0 : *(const uint8_t *)nc_vm_host(&g_core.vm, va + i);
            fputc(b, out);
        }
        if (out) {
            fclose(out);
            nc_log("hakuX-native", "dumped %08x+%x to %s", va, len, name);
        }
        /* The physical page behind each page of the range (u32 each; ~0: none). */
        snprintf(name, sizeof(name), "dump_%08x.pa", va);
        if ((out = fopen(name, "wb")) != NULL) {
            for (uint32_t p = va & ~(NC_PAGE - 1); p < va + len; p += NC_PAGE) {
                const uint32_t pa = nc_vm_phys(&g_core.vm, p);
                fwrite(&pa, sizeof(pa), 1, out);
            }
            fclose(out);
        }
        spec = *end == ';' ? end + 1 : "";
    }
}

#ifdef NC_VM16K
/* The 16 KiB host pages over the guest space: mapped straight through,
 * trapped (their accesses emulated), and the emulated accesses' rate. */
static void vm16k_report(const char *when)
{
    uint32_t direct, trapped;
    uint64_t emulated;
    nc_vm16k_census(&g_core.vm, &direct, &trapped, &emulated);
    static uint64_t last_emulated, last_ms;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    const uint64_t now = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
    const double rate = last_ms && now > last_ms ? (double)(emulated - last_emulated) * 1000.0 / (double)(now - last_ms) : 0;
    nc_log("hakuX-native-vm16k", "%s: %u direct, %u trapped host pages (%.1f%% trapped); %llu accesses emulated, %.0f/s",
           when, direct, trapped, direct + trapped ? 100.0 * trapped / (direct + trapped) : 0.0,
           (unsigned long long)emulated, rate);
    last_emulated = emulated;
    last_ms = now;
    nc_vm16k_dump(&g_core.vm);
}
#endif

/* hang=: the watchdog over the frames (and a lost GPU, which stops them for
 * good: the run would only reach NC_TIMEOUT). */
static unsigned g_hang_s;

static uint64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void *watchdog(void *arg)
{
    uint64_t frames = hle_back_swap_count(), since = mono_ms();
#ifdef NC_VM16K
    unsigned ticks = 0;
#endif
    for (;;) {
        usleep(100 * 1000);
#ifdef NC_VM16K
        if (++ticks % 50 == 0) {
            char when[64];
            snprintf(when, sizeof(when), "%us, frame %llu", ticks / 10, (unsigned long long)hle_back_swap_count());
            vm16k_report(when);
        }
#endif
        if (nc_hle_fatal_kind() == NC_FATAL_GPU_LOST) {
            nc_log("hakuX-native-frontier", "GPU lost: %s", nc_hle_fatal() ? nc_hle_fatal() : "?");
            _exit(9);
        }
        const uint64_t n = hle_back_swap_count(), now = mono_ms();
#ifdef __APPLE__
        /* SIGALRM can land on a thread that has it blocked here: the
         * watchdog ends the run instead */
        static uint64_t start;
        if (!start) {
            start = now;
        }
        if (g_timeout && now - start >= g_timeout * 1000ull) {
            nc_log("hakuX-native-frontier", "timeout after %u s (frame %llu)", g_timeout, (unsigned long long)n);
            vm16k_report("timeout");
            report_guest(NULL, 0);
            _exit(5);
        }
#endif
        if (n != frames || nc_core_rebooting()) {
            frames = n;
            since = now;
        } else if (g_hang_s && now - since >= g_hang_s * 1000ull) {
            nc_log("hakuX-native-frontier", "hang: no frame for %u s after frame %llu", g_hang_s,
                   (unsigned long long)n);
            report_guest(NULL, 0);
            _exit(6);
        }
    }
    return NULL;
}

static int run_core(void *arg)
{
    (void)arg;
    do {
        nc_core_run(&g_core);
    } while (nc_core_reboot(&g_core));
    const NcKernel *k = &g_core.kernel;
    return k->quit || k->relaunch ? 10 : k->stop ? 7 : 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: xboxrun <disc image> [option...]\n");
        return 2;
    }
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        perror(argv[1]);
        return 2;
    }

    struct sigaction sa = {0};
    sa.sa_sigaction = fault;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sa.sa_sigaction = timeout;
    sigaction(SIGALRM, &sa, NULL);
    g_timeout = getenv("NC_TIMEOUT") ? (unsigned)atoi(getenv("NC_TIMEOUT")) : 30;
    nc_log("hakuX-native", "xboxrun pid %d", (int)getpid()); /* the HLE layer logs to logcat under this pid */
    setenv("HAKUX_HLE_MODE", "replace", 0);     /* the GPU as the app runs it */

    NcOptions opt;
    nc_options_init(&opt);
    /* The console's video settings and language also from NC_VIDEO (hex),
     * NC_AVPACK (the NC_AV_PACK_* number) and NC_LANGUAGE, as video=,
     * avpack= and lang=; HAKUX_HLE_UNCAP as uncap */
    opt.uncap = getenv("HAKUX_HLE_UNCAP") != NULL;
    if (getenv("NC_VIDEO")) {
        opt.video = (int64_t)strtoul(getenv("NC_VIDEO"), NULL, 16);
    }
    if (getenv("NC_AVPACK")) {
        opt.av_pack = atoi(getenv("NC_AVPACK"));
    }
    if (getenv("NC_LANGUAGE")) {
        nc_kernel_set_language(atoi(getenv("NC_LANGUAGE")));
    }
    const char *capture = NULL;
    uint64_t stop = 0;
    bool window = false;
#ifdef __APPLE__
    window = true;
#endif
    for (int i = 2; i < argc; i++) {
        if (nc_option(&opt, argv[i])) {
            continue;
        }
        if (!strncmp(argv[i], "hdd=", 4)) {
            nc_io_set_hdd_root(argv[i] + 4);
        } else if (!strncmp(argv[i], "vkdriver=", 9)) {
            nc_vk_driver_load(argv[i] + 9);
        } else if (!strncmp(argv[i], "capture=", 8)) {
            capture = argv[i] + 8;
        } else if (!strncmp(argv[i], "frames=", 7)) {
            stop = strtoull(argv[i] + 7, NULL, 10);
        } else if (!strncmp(argv[i], "hang=", 5)) {
            g_hang_s = (unsigned)atoi(argv[i] + 5);
        } else if (!strncmp(argv[i], "window=", 7)) {
            window = atoi(argv[i] + 7) != 0;
        } else {
            fprintf(stderr, "xboxrun: unknown option %s\n", argv[i]);
            return 2;
        }
    }
    nc_options_apply(&opt);
    nc_log("hakuX-native", "xboxrun: disc %s, hdd %s", argv[1], nc_io_hdd_root());
#ifdef __APPLE__
    /* the HLE GPU's shader and pipeline caches beside the hard disk, as the
     * app keeps them (native/app/app_main.c): the default is Android's */
    if (!getenv("HAKUX_NATIVE_BASE")) {
        char base[512];
        snprintf(base, sizeof(base), "%s/../hle", nc_io_hdd_root());
        setenv("HAKUX_NATIVE_BASE", base, 1);
    }
#endif
    if (window) {
        g_timeout = getenv("NC_TIMEOUT") ? g_timeout : 0;
        nc_present_init();
    }

    if (!nc_core_boot(&g_core, fd)) {
        nc_log("hakuX-native-frontier", "boot failed%s%s", nc_hle_fatal() ? ": " : "",
               nc_hle_fatal() ? nc_hle_fatal() : "");
        return nc_hle_fatal_kind() == NC_FATAL_STATE ? 8 : 1;
    }
    dump_ranges(getenv("NC_DUMP"));
    if (getenv("NC_DUMP_ONLY")) {
        return 0;
    }
    nc_capture_start();
    nc_capture_frames(capture, stop);
    pthread_t wd;
    pthread_create(&wd, NULL, watchdog, NULL);
    pthread_detach(wd);
#ifdef NC_VM16K
    vm16k_report("boot");
#endif
    alarm(g_timeout);
#ifdef __APPLE__
    if (window) {
        const char *name = strrchr(argv[1], '/');
        nc_mac_window_run(name ? name + 1 : argv[1], run_core, NULL);
    }
#endif
    return run_core(NULL);
}
