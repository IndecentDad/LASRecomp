// iPadOS host layer (runtime/platform.h). Same shape as runtime/platform/macos.c: the guest window is mapped at
// its exact guest addresses (guest address == host address), time comes from mach, crash handling from signals.
// What differs on iOS:
//   - no second process, ever: iOS apps cannot exec/posix_spawn a toolchain or a helper, so the update check, the
//     on-device game-code build (runtime/gamebuild.c, not compiled in) and the seed generator are unavailable.
//     plat_spawn() returns 0 so any accidental use fails loudly instead of hanging.
//   - the guest window base is not the macOS one: iOS user VA ends at 0xFC0000000 (xnu osfmk/mach/arm/vm_param.h
//     MACH_VM_MAX_ADDRESS_RAW), so an iOS build passes -DRT_BASE=0x400000000 to runtime/rt.h and generates the game
//     code for that base (Makefile IOS_BASE_MAIN/SDK). macOS keeps 0x7000000000: everything below ~448 GB is
//     reserved there.
//   - a re-exec cannot recover from a guest-window collision, so that path just reports (runtime/main.c).
#include <crt_externs.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <mach/vm_map.h>   // vm_allocate/vm_region: mach_vm.h (the macOS interface) is an #error stub on iOS
#include <os/proc.h>       // os_proc_available_memory(): the jetsam budget
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include "../platform.h"

static mach_timebase_info_data_t tb;

void plat_init(void) {
    // iOS has no console: everything the runtime logs goes to stderr, which is the unified log when the app is
    // started from Xcode or `devicectl process launch --console`; runtime/paths.c also tees it into the data root.
    fprintf(stderr, "[ios] available memory before boot: %llu MB\n",
            (unsigned long long)(os_proc_available_memory() >> 20));
}

// A failed reservation is fatal on iOS (no re-exec) and the log is the only way to see why: dump the task's
// virtual address space and try the bases a 12.5 GB guest window could live at. The window's base is baked into
// the recompiled game code, so this run's answer is what Makefile IOS_BASE_MAIN / ios/project.yml RT_BASE must be
// set to (then `make ios-gen && make ios-game-lib && make ios-app`).
static void ios_probe_address_space(uint64_t want_lo, uint64_t want_hi) {
    const uint64_t limit = 0xFC0000000ull;  // MACH_VM_MAX_ADDRESS_RAW on iOS
    fprintf(stderr, "[ios-probe] a %llu MB guest window at %#llx..%#llx is not free; mapping the space below %#llx:\n",
            (unsigned long long)((want_hi - want_lo) >> 20), (unsigned long long)want_lo, (unsigned long long)want_hi,
            (unsigned long long)limit);
    // What is actually mapped (skip the app's own low mappings: only list >= 4 GB).
    vm_address_t a = 0;
    int n = 0;
    while (a < limit) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        vm_address_t probe = a;
        kern_return_t kr = vm_region_64(mach_task_self(), &probe, &size, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (kr != KERN_SUCCESS || size == 0) break;
        if (probe + size > 0x100000000ull && n++ < 24)
            fprintf(stderr, "[ios-probe]   %#012llx..%#012llx  %6llu MB  %s%s\n", (unsigned long long)probe,
                    (unsigned long long)(probe + size), (unsigned long long)(size >> 20),
                    (info.protection & VM_PROT_WRITE) ? "rw" : (info.protection & VM_PROT_READ) ? "r-" : "--",
                    info.shared ? " shared" : "");
        a = probe + size;
    }
    // How large a single allocation this process may make, fixed at the base and anywhere the kernel likes: that
    // decides whether a compact guest layout is possible without the guest window.
    static const uint64_t sizes[] = {64ull << 20, 256ull << 20, 1ull << 30, 2ull << 30, 3ull << 30, 4ull << 30,
                                     6ull << 30, 8ull << 30, (uint64_t)0x320000000ull};
    for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
        vm_address_t fixed_addr = (vm_address_t)0x400000000ull;
        kern_return_t kr_fixed = vm_allocate(mach_task_self(), &fixed_addr, (vm_size_t)sizes[i], VM_FLAGS_FIXED);
        if (kr_fixed == KERN_SUCCESS) vm_deallocate(mach_task_self(), fixed_addr, (vm_size_t)sizes[i]);
        vm_address_t any = 0;
        kern_return_t kr_any = vm_allocate(mach_task_self(), &any, (vm_size_t)sizes[i], VM_FLAGS_ANYWHERE);
        fprintf(stderr, "[ios-probe] %5llu MB: fixed@16GB %s, anywhere %s%s%#llx\n",
                (unsigned long long)(sizes[i] >> 20), kr_fixed == KERN_SUCCESS ? "OK" : "no",
                kr_any == KERN_SUCCESS ? "OK at " : "no", kr_any == KERN_SUCCESS ? "" : "",
                kr_any == KERN_SUCCESS ? (unsigned long long)any : 0ull);
        if (kr_any == KERN_SUCCESS) vm_deallocate(mach_task_self(), any, (vm_size_t)sizes[i]);
    }
    fflush(stderr);
}

bool plat_reserve_guest(uint64_t lo, uint64_t hi) {
    // The whole window in one fixed allocation, like macOS (VM_FLAGS_FIXED fails instead of clobbering something
    // that is already mapped - mmap(MAP_FIXED) would silently replace it, and Darwin has no MAP_FIXED_NOREPLACE).
    // Pages are unbacked until touched, so the 8.5 GB window costs nothing but addresses.
    vm_address_t a = (vm_address_t)lo;
    if (vm_allocate(mach_task_self(), &a, (vm_size_t)(hi - lo), VM_FLAGS_FIXED) == KERN_SUCCESS) return true;
    ios_probe_address_space(lo, hi);
    _exit(1);  // (main.c would try to re-exec, which iOS cannot do)
}

bool plat_reset_guest(uint64_t lo, uint64_t hi) {  // in-place reboot: fresh zero pages over the whole window
    vm_address_t a = (vm_address_t)lo;
    return vm_allocate(mach_task_self(), &a, (vm_size_t)(hi - lo), VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE) == KERN_SUCCESS;
}

void plat_commit(uint64_t addr, uint64_t size) { (void)addr; (void)size; }

int plat_protect(uint64_t addr, uint64_t size, int prot) {
    int p = prot == PLAT_PROT_NONE ? PROT_NONE : prot == PLAT_PROT_READ ? PROT_READ : PROT_READ | PROT_WRITE;
    return mprotect((void *)(uintptr_t)addr, size, p);
}

uint64_t plat_now_ns(void) {
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

void plat_sleep_until_ns(uint64_t t) {
    if (!tb.denom) mach_timebase_info(&tb);
    mach_wait_until(t * tb.denom / tb.numer);
}

// Time-constraint (real-time) thread, as on macOS. iOS may refuse the policy for a non-audio app; that is not fatal
// (the vsync thread's sleep just gets coalesced), so the failure is logged once and ignored.
void plat_thread_realtime(uint64_t period_ns) {
    if (!tb.denom) mach_timebase_info(&tb);
    uint64_t period = period_ns * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t pol = {
        .period = (uint32_t)period,
        .computation = (uint32_t)(period / 20),
        .constraint = (uint32_t)(period / 4),
        .preemptible = 1,
    };
    kern_return_t kr = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                                         (thread_policy_t)&pol, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (kr != KERN_SUCCESS) {
        static int warned;
        if (!warned++) fprintf(stderr, "[ios] THREAD_TIME_CONSTRAINT_POLICY refused (%d): frame pacing may drift\n", kr);
    }
}

bool plat_exe_path(char *buf, size_t size) {
    uint32_t len = (uint32_t)size;
    return _NSGetExecutablePath(buf, &len) == 0;
}

// No re-exec on iOS: runtime/main.c's guest-window collision path lands here and ends with a readable message
// (the window is reserved by a constructor, before the UI exists, so this is all we can do).
void plat_exec(char *const argv[]) {
    (void)argv;
    fprintf(stderr, "FATAL: the guest address window is not free and iOS cannot re-exec\n");
    plat_fatal_notice();
    _exit(1);
}

const char *plat_symbol(uint64_t pc, uint64_t *offset) {
    Dl_info di = {0};
    if (!dladdr((void *)(uintptr_t)pc, &di) || !di.dli_sname) return NULL;
    if (offset) *offset = pc - (uint64_t)(uintptr_t)di.dli_saddr;
    return di.dli_sname;
}

// A fatal error with no console: show it (SDL's message box is a UIAlertController on iOS) and end.
void plat_fatal_notice(void) {
    fflush(stderr);
}

#if __has_include(<execinfo.h>)
#include <execinfo.h>
void plat_print_backtrace(void) {
    void *bt[64];
    int n = backtrace(bt, 64);
    char **syms = backtrace_symbols(bt, n);
    for (int i = 0; i < n; i++) fprintf(stderr, "  %s\n", syms[i]);
    free(syms);
}
#else
void plat_print_backtrace(void) { fprintf(stderr, "  (no backtrace support)\n"); }
#endif

static void crash_handler(int sig, siginfo_t *si, void *ctx) {
    ucontext_t *uc = ctx;
    static volatile int depth;
    if (sig == SIGABRT && depth++ > 0) { signal(SIGABRT, SIG_DFL); abort(); }
    uint64_t fa = (uint64_t)(uintptr_t)si->si_addr;
    uint64_t pc = uc->uc_mcontext->__ss.__pc, lr = uc->uc_mcontext->__ss.__lr;
    if (rt_fault_watch(fa, pc)) return;
    char what[32];
    snprintf(what, sizeof what, "signal %d", sig);
    rt_fault_report(what, fa, pc, lr);
}

void plat_crash_handler_install(void) {
    stack_t ss = {.ss_sp = malloc(1 << 20), .ss_size = 1 << 20};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
}

// ---- child processes: unavailable on iOS (no exec, no unsigned toolchains). The callers are desktop-only
// (runtime/gamebuild.c is not part of the iOS target; the launcher's update check is compiled out).
PlatProc plat_spawn(const char *const argv[], const char *log_path, bool append_log) {
    (void)log_path, (void)append_log;
    fprintf(stderr, "[ios] refusing to spawn %s (not possible on iOS)\n", argv && argv[0] ? argv[0] : "?");
    return 0;
}
void plat_proc_kill(PlatProc p) { (void)p; }
int plat_proc_wait(PlatProc p, bool block) { (void)p, (void)block; return 255; }
void plat_terminate(void) { _exit(0); }

// ---- filesystem
#include <fcntl.h>
#include <ftw.h>
static int rm_entry(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)sb, (void)flag, (void)ftw;
    return remove(path);
}
bool plat_remove_tree(const char *dir) { return nftw(dir, rm_entry, 16, FTW_DEPTH | FTW_PHYS) == 0; }
