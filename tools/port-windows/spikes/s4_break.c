/* Spike S4 (PORTING-X86-64-WINDOWS.md section 9).
 *
 * The memory break, emulated over a fixed reserve, together with the
 * vectored fault handler from S1.
 *
 * Cygwin commits MAP_NORESERVE pages lazily, from its own exception
 * handler.  Our vectored handler runs before Cygwin's, so it must tell a
 * first touch of a page below the break (pass it on) from an access above
 * the break (a real fault, which Poplog relies on to detect user-stack
 * underflow).  This checks that the two handlers cooperate, from code with
 * no unwind tables, and that the result survives fork.
 *
 * Build with s1_fault.s:  gcc -O1 $LOW -o s4 s4_break.c s1_fault.s
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <pthread.h>
#include <windows.h>

extern long fault_static(long *p);      /* reads *p from a non-C frame */
extern void recover(void);              /* makes fault_static return 77 */

#define BASE    ((char *) 0x10000000UL)
#define RESERVE ((size_t) 0x60000000UL)     /* ends at 0x70000000 */
#define PAGE    65536UL

static char *cur_break = BASE;
static volatile int claimed, passed;

static int pop_brk(char *nb) {
    if (nb < BASE || nb > BASE + RESERVE) { errno = ENOMEM; return -1; }
    if (nb < cur_break) {
        /* give the pages back and make them fault again */
        if (mprotect(nb, cur_break - nb, PROT_NONE)) return -1;
    } else if (nb > cur_break) {
        if (mprotect(cur_break, nb - cur_break, PROT_READ | PROT_WRITE | PROT_EXEC)) return -1;
    }
    cur_break = nb;
    return 0;
}

static LONG CALLBACK on_veh(EXCEPTION_POINTERS *ep) {
    EXCEPTION_RECORD *er = ep->ExceptionRecord;
    if (er->ExceptionCode != EXCEPTION_ACCESS_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;
    char *addr = (char *) er->ExceptionInformation[1];
    if (addr >= BASE && addr < cur_break) {
        passed++;                           /* lazy commit: Cygwin's business */
        return EXCEPTION_CONTINUE_SEARCH;
    }
    claimed++;
    ep->ContextRecord->Rip = (DWORD64) recover;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void install_veh(void) { AddVectoredExceptionHandler(1, on_veh); }

static int fails;
static void check(const char *what, int ok) {
    printf("  %-56s %s\n", what, ok ? "OK" : "FAIL");
    if (!ok) fails++;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    char *r = mmap(BASE, RESERVE, PROT_NONE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (r == MAP_FAILED) printf("  mmap: %s\n", strerror(errno));
    check("1.5 GB reserve at 0x10000000, no access", r == BASE);
    if (r != BASE) return 1;
    install_veh();

    int c = claimed;
    check("read above the break (empty heap) is a fault", fault_static((long *) BASE) == 77 && claimed == c + 1);

    check("raise the break by 64 MB", pop_brk(BASE + (64UL << 20)) == 0);
    c = claimed;
    long *p = (long *) (BASE + (32UL << 20));
    long v = fault_static(p);
    printf("    first touch below the break: result %ld, passed on %d, claimed %d\n", v, passed, claimed - c);
    check("first touch below the break is not a fault", v == 1 && claimed == c);
    *p = 0x1234;
    memset(BASE, 0x5a, 8UL << 20);
    check("pages below the break hold data", *p == 0x1234 && BASE[(8UL << 20) - 1] == 0x5a);

    static const unsigned char ret42[] = { 0xb8, 42, 0, 0, 0, 0xc3 };
    memcpy(BASE + PAGE, ret42, sizeof ret42);
    check("code below the break runs", ((int (*)(void)) (BASE + PAGE))() == 42);

    c = claimed;
    check("read just above the break is a fault",
          fault_static((long *) (BASE + (64UL << 20))) == 77 && claimed == c + 1);

    check("lower the break to 16 MB", pop_brk(BASE + (16UL << 20)) == 0);
    c = claimed;
    check("a page given back faults again", fault_static(p) == 77 && claimed == c + 1);
    check("raise the break again to 48 MB", pop_brk(BASE + (48UL << 20)) == 0);
    c = claimed;
    v = fault_static(p);
    printf("    re-raised page reads %#lx (the old value was 0x1234)\n", (unsigned long) *p);
    check("the page is usable again", v == 1 && claimed == c);

    /* A forked child is a new Windows process: the vectored handler has to
       be registered again there (set S4_NO_ATFORK to see what happens
       without).  */
    if (!getenv("S4_NO_ATFORK")) pthread_atfork(NULL, NULL, install_veh);
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) { printf("  fork: %s\n", strerror(errno)); return 1; }
    if (pid == 0) {
        int ok = BASE[100] == 0x5a && ((int (*)(void)) (BASE + PAGE))() == 42;
        BASE[100] = 1;
        long *q = (long *) (BASE + (40UL << 20));       /* never touched by the parent */
        *q = 7;
        int c2 = claimed;
        ok = ok && *q == 7 && fault_static((long *) (BASE + (48UL << 20))) == 77 && claimed == c2 + 1;
        _exit(ok ? 0 : 3);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    printf("    child status: exited=%d code=%d signalled=%d sig=%d\n",
           WIFEXITED(st), WEXITSTATUS(st), WIFSIGNALED(st), WIFSIGNALED(st) ? WTERMSIG(st) : 0);
    check("fork: child has the heap, can grow into it, still faults above", WIFEXITED(st) && WEXITSTATUS(st) == 0);
    check("fork: child's write did not reach the parent", BASE[100] == 0x5a);

    printf("s4: %s (handler passed on %d, claimed %d)\n", fails ? "FAILURES" : "ALL OK", passed, claimed);
    return fails ? 1 : 0;
}
