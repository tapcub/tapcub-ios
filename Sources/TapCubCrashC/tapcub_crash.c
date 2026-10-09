#include "tapcub_crash.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// File format (one record per crash, read on the next launch):
//   TCSIG <signo> <unix seconds>\n
//   <image>+0x<offset>\n   or   0x<address>\n   (one line per frame)
// Everything inside the handler uses only async-signal-safe calls on preallocated memory.

static const int tapcub_signals[] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
#define TC_NSIG (sizeof(tapcub_signals) / sizeof(tapcub_signals[0]))

static struct sigaction tapcub_old[TC_NSIG];
static int tapcub_installed = 0;
static int tapcub_fd = -1;
static volatile sig_atomic_t tapcub_handling = 0;
static volatile sig_atomic_t tapcub_skip = 0;
static uintptr_t tapcub_img_base = 0;
static uintptr_t tapcub_img_end = 0;
static char tapcub_img_name[64];
static stack_t tapcub_altstack;

static void tapcub_put(const char *s, size_t n) {
    while (n > 0) {
        ssize_t w = write(tapcub_fd, s, n);
        if (w <= 0) return;
        s += w;
        n -= (size_t)w;
    }
}

static void tapcub_puts(const char *s) { tapcub_put(s, strlen(s)); }

static void tapcub_put_dec(long v) {
    char buf[24];
    int i = sizeof(buf);
    int neg = v < 0;
    unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
    do {
        buf[--i] = (char)('0' + (u % 10));
        u /= 10;
    } while (u && i > 1);
    if (neg) buf[--i] = '-';
    tapcub_put(buf + i, sizeof(buf) - (size_t)i);
}

static void tapcub_put_hex(uintptr_t v) {
    static const char digits[] = "0123456789abcdef";
    char buf[2 + sizeof(uintptr_t) * 2];
    int i = sizeof(buf);
    do {
        buf[--i] = digits[v & 0xf];
        v >>= 4;
    } while (v && i > 2);
    buf[--i] = 'x';
    buf[--i] = '0';
    tapcub_put(buf + i, sizeof(buf) - (size_t)i);
}

static int tapcub_index(int sig) {
    for (size_t i = 0; i < TC_NSIG; i++)
        if (tapcub_signals[i] == sig) return (int)i;
    return -1;
}

static void tapcub_handler(int sig, siginfo_t *info, void *ctx) {
    (void)info;
    (void)ctx;
    if (!tapcub_handling) {
        tapcub_handling = 1;
        if (tapcub_fd >= 0 && !tapcub_skip) {
            void *frames[64];
            int n = backtrace(frames, 64);
            tapcub_puts("TCSIG ");
            tapcub_put_dec(sig);
            tapcub_puts(" ");
            tapcub_put_dec((long)time(NULL));
            tapcub_puts("\n");
            // frames[0] is this handler and frames[1] is _sigtramp
            for (int i = 2; i < n; i++) {
                uintptr_t a = (uintptr_t)frames[i];
                if (a >= tapcub_img_base && a < tapcub_img_end) {
                    tapcub_puts(tapcub_img_name);
                    tapcub_puts("+");
                    tapcub_put_hex(a - tapcub_img_base);
                } else {
                    tapcub_put_hex(a);
                }
                tapcub_puts("\n");
            }
            fsync(tapcub_fd);
        }
    }
    int idx = tapcub_index(sig);
    if (idx >= 0) sigaction(sig, &tapcub_old[idx], NULL);
    raise(sig);
}

static void tapcub_find_image(void) {
    Dl_info di;
    if (!dladdr((const void *)&tapcub_crash_install, &di) || !di.dli_fbase) return;
    const struct mach_header_64 *h = (const struct mach_header_64 *)di.dli_fbase;
    if (h->magic != MH_MAGIC_64) return;
    const struct load_command *lc = (const struct load_command *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                tapcub_img_base = (uintptr_t)h;
                tapcub_img_end = tapcub_img_base + (uintptr_t)seg->vmsize;
                break;
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    const char *name = di.dli_fname ? strrchr(di.dli_fname, '/') : NULL;
    name = name ? name + 1 : (di.dli_fname ? di.dli_fname : "main");
    strncpy(tapcub_img_name, name, sizeof(tapcub_img_name) - 1);
}

int tapcub_crash_install(const char *pending_path) {
    if (tapcub_installed) return 0;
    tapcub_fd = open(pending_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (tapcub_fd < 0) return -1;
    tapcub_find_image();
    tapcub_altstack.ss_size = SIGSTKSZ * 2;
    tapcub_altstack.ss_sp = malloc(tapcub_altstack.ss_size);
    tapcub_altstack.ss_flags = 0;
    if (tapcub_altstack.ss_sp) sigaltstack(&tapcub_altstack, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = tapcub_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < TC_NSIG; i++) sigaction(tapcub_signals[i], &sa, &tapcub_old[i]);
    tapcub_installed = 1;
    return 0;
}

void tapcub_crash_uninstall(void) {
    if (!tapcub_installed) return;
    for (size_t i = 0; i < TC_NSIG; i++) sigaction(tapcub_signals[i], &tapcub_old[i], NULL);
    if (tapcub_fd >= 0) close(tapcub_fd);
    tapcub_fd = -1;
    tapcub_installed = 0;
}

void tapcub_crash_mark_handled(void) { tapcub_skip = 1; }
