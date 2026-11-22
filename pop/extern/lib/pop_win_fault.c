/* pop_win_fault.c -- recovery from faults in Pop code on Windows.
 *
 * Poplog relies on catching faults in its own code: user-stack underflow is
 * an access violation at the end of memory, and the float routines recover
 * from arithmetic faults.  The handler (_pop_errsig_handler in c_core.c)
 * records the fault and changes the saved program counter so that the
 * thread resumes in __pop_errsig.
 *
 * Under Cygwin a signal handler cannot do that: the changed program counter
 * is ignored and the faulting instruction runs again, for ever.  Windows
 * frame-based exception handling is no use either, because Pop code has no
 * unwind tables.  A vectored exception handler runs before any unwinding and
 * may rewrite the context, so that is the route taken here: translate the
 * Windows exception into the signal the Pop side expects, call the ordinary
 * handler with a context it can edit, and copy the edited program counter
 * back.  Measured in tools/port-windows/spikes (S1, S4); design in
 * PORTING-X86-64-WINDOWS.md section 3.5.
 *
 * Nothing here depends on Cygwin beyond the siginfo and ucontext types, so a
 * native Windows port could keep it.
 */

#if defined(__CYGWIN__)

#include <signal.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <ucontext.h>
#include <windows.h>

extern void _pop_errsig_handler(int sig, siginfo_t *info, ucontext_t *context);

/* Private exception code (bit 29 set = not a system code) carrying a signal
   number as its one argument. */
#define POP_EXCEPTION_SIGNAL    0xE0504F50

/* Nonzero while _pop_errsig_handler is being called from here; c_core.c
   refuses to act on an error signal that arrives any other way. */
int _pop_in_fault_handler = 0;

/* Address range of the Cygwin DLL.  Cygwin raises and handles access
   violations of its own (for instance to turn a bad pointer passed to a
   system call into EFAULT); those are not ours. */
static char *cyg_lo = 0, *cyg_hi = 0;

static void find_cygwin_dll(void) {
    HMODULE h = GetModuleHandleA("cygwin1.dll");
    if (h) {
        IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *) h;
        IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *) ((char *) h + dos->e_lfanew);
        cyg_lo = (char *) h;
        cyg_hi = cyg_lo + nt->OptionalHeader.SizeOfImage;
    }
}

/* Set POP_FAULT_TRACE in the environment to have every exception the
   process raises reported on standard error, with what was done about it.
   A process that dies of an unclaimed fault on this system can exit with
   status 0 and no message, so this is the first thing to reach for. */
static int tracing = 0;

static void trace(EXCEPTION_POINTERS *ep, const char *what) {
    char b[200];
    EXCEPTION_RECORD *er = ep->ExceptionRecord;
    int n = snprintf(b, sizeof b,
        "[pop fault] code %#lx pc %#llx sp %#llx info %#llx %#llx: %s\n",
        (unsigned long) er->ExceptionCode,
        (unsigned long long) ep->ContextRecord->Rip,
        (unsigned long long) ep->ContextRecord->Rsp,
        (unsigned long long) (er->NumberParameters > 0 ? er->ExceptionInformation[0] : 0),
        (unsigned long long) (er->NumberParameters > 1 ? er->ExceptionInformation[1] : 0),
        what);
    write(2, b, n);
}

static LONG CALLBACK pop_fault_filter(EXCEPTION_POINTERS *ep) {
    EXCEPTION_RECORD *er = ep->ExceptionRecord;
    char *pc = (char *) ep->ContextRecord->Rip;
    int sig, code;
    void *addr = (void *) er->ExceptionAddress;

    switch (er->ExceptionCode) {
        case POP_EXCEPTION_SIGNAL:
            /* raised by _pop_win_raise below */
            sig = (int) er->ExceptionInformation[0];
            code = 0;
            addr = 0;
            pc = 0;         /* wherever it is, it is ours */
            break;
        case EXCEPTION_ACCESS_VIOLATION:
            sig = SIGSEGV;
            /* ExceptionInformation[0]: 0 read, 1 write, 8 execute;
               [1]: the address.  A protection fault on a mapped page and a
               fault on an unmapped one are not told apart by Windows. */
            code = SEGV_MAPERR;
            addr = (void *) er->ExceptionInformation[1];
            break;
        case EXCEPTION_IN_PAGE_ERROR:
            sig = SIGBUS;  code = BUS_ADRERR;
            addr = (void *) er->ExceptionInformation[1];
            break;
        case EXCEPTION_DATATYPE_MISALIGNMENT:
            sig = SIGBUS;  code = BUS_ADRALN;  break;
        case EXCEPTION_INT_DIVIDE_BY_ZERO:
            sig = SIGFPE;  code = FPE_INTDIV;  break;
        case EXCEPTION_INT_OVERFLOW:
            sig = SIGFPE;  code = FPE_INTOVF;  break;
        case EXCEPTION_FLT_DIVIDE_BY_ZERO:
            sig = SIGFPE;  code = FPE_FLTDIV;  break;
        case EXCEPTION_FLT_OVERFLOW:
            sig = SIGFPE;  code = FPE_FLTOVF;  break;
        case EXCEPTION_FLT_UNDERFLOW:
            sig = SIGFPE;  code = FPE_FLTUND;  break;
        case EXCEPTION_FLT_INEXACT_RESULT:
            sig = SIGFPE;  code = FPE_FLTRES;  break;
        case EXCEPTION_FLT_INVALID_OPERATION:
        case EXCEPTION_FLT_DENORMAL_OPERAND:
        case EXCEPTION_FLT_STACK_CHECK:
            sig = SIGFPE;  code = FPE_FLTINV;  break;
        case EXCEPTION_ILLEGAL_INSTRUCTION:
            sig = SIGILL;  code = ILL_ILLOPC;  break;
        case EXCEPTION_PRIV_INSTRUCTION:
            sig = SIGILL;  code = ILL_PRVOPC;  break;
        default:
            /* breakpoints, C++ exceptions, debugger traffic, ... */
            if (tracing) trace(ep, "not a fault we translate; passed on");
            return EXCEPTION_CONTINUE_SEARCH;
    }

    if (cyg_lo && pc >= cyg_lo && pc < cyg_hi) {
        if (tracing) trace(ep, "inside the Cygwin DLL; passed on");
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (tracing) trace(ep, "claimed");

    {
        siginfo_t info;
        ucontext_t uc;
        memset(&info, 0, sizeof info);
        memset(&uc, 0, sizeof uc);
        info.si_signo = sig;
        info.si_code = code;
        info.si_addr = addr;
        uc.uc_mcontext.rip = ep->ContextRecord->Rip;
        uc.uc_mcontext.rsp = ep->ContextRecord->Rsp;

        _pop_in_fault_handler = 1;
        _pop_errsig_handler(sig, &info, &uc);
        _pop_in_fault_handler = 0;

        ep->ContextRecord->Rip = uc.uc_mcontext.rip;
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

/* Raise an error signal in a way that can become a mishap.  The Unix code
   does kill(getpid(), sig) and lets the handler redirect the thread; here a
   signal handler cannot redirect anything, but an exception raised by the
   program goes through the vectored handler like any fault. */
void _pop_win_raise(int sig) {
    ULONG_PTR arg = (ULONG_PTR) sig;
    RaiseException(POP_EXCEPTION_SIGNAL, 0, 1, &arg);
}

static void install(void) {
    tracing = getenv("POP_FAULT_TRACE") != NULL;
    find_cygwin_dll();
    AddVectoredExceptionHandler(1, pop_fault_filter);
}

/* Called when Pop installs its error-signal handler; safe to call often. */
void _pop_win_fault_init(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    install();
    /* A forked child is a new Windows process and does not inherit the
       handler; without this it hangs or dies silently at its first fault
       (spike S4). */
    pthread_atfork(NULL, NULL, install);
}

/* Commit the whole of the main thread's stack.
 *
 * Windows grows a stack one guard page at a time: touching the page just
 * below the committed part commits it and moves the guard down, but touching
 * anything further down is an access violation, and one that cannot be
 * handled because there is no stack to handle it on -- the process simply
 * ends, with exit status 0.  C compilers probe page by page in any function
 * with a large frame.  Pop code does not: Sys$-Move_callstack, for one,
 * moves the call stack down by 32 KB in a single step during start-up, and
 * a procedure with enough local variables would do the same.  So the stack
 * is walked down once here, a page at a time, to its full size.  The cost is
 * that the stack reserve named in the executable (-Wl,--stack) is committed
 * memory from the start.
 *
 * Whether the stack is already committed depends on how the process was
 * started: from a Cygwin shell it is not; under a debugger or from a native
 * Windows parent it happened to be, which hid this for a while.
 */
#include <sys/resource.h>

void _pop_win_stack_commit(void) {
    NT_TIB *tib = (NT_TIB *) NtCurrentTeb();
    struct rlimit rl;
    volatile char *p, *low;
    if (getrlimit(RLIMIT_STACK, &rl) != 0 || rl.rlim_cur == RLIM_INFINITY) return;
    /* stay clear of the last pages, which Windows keeps for itself */
    low = (char *) tib->StackBase - rl.rlim_cur + 0x20000;
    p = (volatile char *) ((unsigned long long) &rl & ~0xfffULL);
    if (tracing || getenv("POP_FAULT_TRACE")) {
        char b[120];
        int n = snprintf(b, sizeof b, "[pop stack] base %p committing down to %p from %p%c",
                         tib->StackBase, (void *) low, (void *) p, 10);
        write(2, b, n);
    }
    for (p -= 0x1000; p > low; p -= 0x1000) *p = 0;
}

#else

/* ISO C forbids an empty translation unit */
typedef int pop_win_fault_unused;

#endif  /* __CYGWIN__ */
