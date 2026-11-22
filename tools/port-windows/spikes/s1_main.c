/* Spike S1 (PORTING-X86-64-WINDOWS.md section 9).
 *
 * Can a fault in code with no unwind tables be caught, and the thread
 * resumed at a different address?  Poplog's _pop_errsig_handler does exactly
 * that.  Two routes are tried:
 *     sig   sigaction(SA_SIGINFO), rewrite uc_mcontext.rip
 *     veh   AddVectoredExceptionHandler, rewrite ContextRecord->Rip
 * A third mode checks stack growth with unprobed frames:
 *     deep N
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <ucontext.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>
#include <windows.h>

extern long fault_static(long *bad);
extern long div_static(long divisor);
extern long call_jit(void *fn, long arg);
extern long deep(long n);
extern void recover(void);

static volatile int hits;
static volatile int last_sig;

static void on_sig(int sig, siginfo_t *info, void *vctx) {
    ucontext_t *ctx = vctx;
    hits++;
    last_sig = sig;
    if (hits <= 3 || hits % 100000 == 0) {
        char b[96];
        int n = snprintf(b, sizeof b, "    [handler: sig %d, call %d, rip %#lx]\n",
                         sig, hits, (unsigned long) ctx->uc_mcontext.rip);
        write(2, b, n);
    }
    ctx->uc_mcontext.rip = (unsigned long) recover;
}

static LONG CALLBACK on_veh(EXCEPTION_POINTERS *ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION
        && code != EXCEPTION_INT_DIVIDE_BY_ZERO
        && code != EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    hits++;
    last_sig = (int) (code & 0xffff);
    ep->ContextRecord->Rip = (DWORD64) recover;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static int report(const char *what, long r, int before) {
    int ok = (r == 77 && hits == before + 1);
    printf("  %-34s result=%ld handler_calls=%d last=%d  %s\n",
           what, r, hits - before, last_sig, ok ? "OK" : "FAIL");
    fflush(stdout);
    return ok;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "sig";
    int i, ok = 1, h;
    int only = argc > 2 ? atoi(argv[2]) : 0;    /* run just test 1..4 */

    setvbuf(stdout, NULL, _IONBF, 0);

    if (!strcmp(mode, "deep")) {
        long n = argc > 2 ? atol(argv[2]) : 100;
        struct rlimit rl;
        getrlimit(RLIMIT_STACK, &rl);
        printf("deep: RLIMIT_STACK cur=%lu KB, recursing %ld frames of 12 KB (%ld KB)\n",
               (unsigned long) (rl.rlim_cur / 1024), n, n * 12);
        fflush(stdout);
        deep(n);
        printf("deep: returned normally\n");
        return 0;
    }

    if (!strcmp(mode, "sig")) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = on_sig;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGFPE, &sa, NULL);
        sigaction(SIGILL, &sa, NULL);
    } else if (!strcmp(mode, "veh")) {
        AddVectoredExceptionHandler(1, on_veh);
    } else {
        fprintf(stderr, "usage: s1 sig|veh|deep N\n");
        return 2;
    }
    printf("mode %s\n", mode);

    /* run-time generated code: no image, no function table at all */
    unsigned char *jit = mmap(NULL, 65536, PROT_READ | PROT_WRITE | PROT_EXEC,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (jit == MAP_FAILED) { perror("mmap rwx"); return 1; }
    static const unsigned char load[] = { 0x48, 0x8b, 0x01, 0xc3 }; /* mov (%rcx),%rax; ret */
    memcpy(jit, load, sizeof load);

    /* three rounds: the handler must keep working after it has been used */
    for (i = 0; i < 3; i++) {
        printf(" round %d\n", i + 1);
        if (!only || only == 1) { h = hits; ok &= report("bad read, static code", fault_static((long *) 8), h); }
        if (!only || only == 2) { h = hits; ok &= report("divide by zero, static code", div_static(0), h); }
        if (!only || only == 3) { h = hits; ok &= report("bad read, generated code", call_jit(jit, 8), h); }
        if (!only || only == 4) { h = hits; ok &= report("call to unmapped address", call_jit((void *) 16, 0), h); }
    }
    printf("%s: %s\n", mode, ok ? "ALL OK" : "FAILURES");
    return ok ? 0 : 1;
}
