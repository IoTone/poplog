# Popping an empty user stack on macOS read past it instead of mishapping

**Status:** FIXED 2026-11-27 · **Severity:** high ·
**Area:** `pop/extern/lib/c_core.c` (`_pop_wx_fixup`, the fault
diagnostics), `pop/src/errors.p` (`System_error`) · **Platform:**
macOS arm64 only

## What it looked like

On every other port, a pop from an empty user stack is the beginner's
mishap:

```
-> q;
;;; MISHAP - ste: STACK EMPTY (missing argument? missing result?)
```

On macOS it was one of three things, depending on what lay beyond the
stack:

- **No mishap at all.** `-> q` at the top of a file took the compiler's
  own subsystem record off the stack, and the next line failed with an
  unrelated `EXECUTING NON-PROCEDURE`.
- **"STACK EMPTY" by luck**, wrapped in three lines of register dumps
  (`[wx-decline]`, `[fatal]`, `[fatal2]`): the pop read a zero, something
  dereferenced it, and the SEGV fell into `System_error`'s "just assume
  SEGV is user stack underflow" branch.
- **A dead session.** In a notebook (TEACH STACK makes this mistake on
  purpose, `newsumsq(3)` for a two-argument procedure) the values read
  beyond the stack were `<SYSTEM_OBJECT 000000800002B980>`. Stored in a
  variable, one crashed the next GC with `FATAL ERROR -
  Gc$-Set_curr_seg: INVALID STRUCTURE POINTER`; on a build without
  graphics the same cell died with `System Error: Signal = 10` and the
  kernel restarted the session.

Measured with the same two three-line scripts on 2026-11-27:

| | x86-64 Linux | arm64 Linux (Pi 5, 16 KB pages) | macOS arm64, before | after |
| --- | --- | --- | --- | --- |
| `-> q;` | STACK EMPTY | STACK EMPTY | no mishap | STACK EMPTY |
| two-arg procedure, one arg | STACK EMPTY | STACK EMPTY | STACK EMPTY + dumps | STACK EMPTY |

The October build behaves the same as the November one, so this was not
a regression; the notebook symptom only changed with the memory layout.

## Cause

Underflow detection is a guard page. `getstore.p` locks one virtual page
above `_userhi` `PROT_NONE` (`LOCK_LIM_PAGE`), and `System_error`
reports a fault whose address rounds to that page as `User_underflow`.
Two things on macOS defeated it.

1. **The W^X fixup unlocked the guard.** `_pop_wx_fixup` repairs faults
   on the Pop heap so runtime-generated code can run under macOS's ban on
   writable-and-executable pages. It treated every *data* fault below the
   break as one to repair, and repaired it with `mprotect(page,
   READ|WRITE)`. The lim page is below the break, so the first empty pop
   opened it and the read went through. But with the RX execution view
   in place (the normal case since `57473ee`), canonical pages are never
   made executable, so a data fault on one is never a W^X fault: it is a
   protection Poplog set itself. The fixup now declines data faults when
   the view is up; the no-view fallback, which does flip pages to RX,
   keeps its repair.

2. **The fault was reported as a SYSTEM ERROR.** With the guard intact,
   macOS raises the protection fault as SIGBUS, not SIGSEGV, and the PC
   can be in the RX view at `+2^36` rather than in the canonical heap.
   `System_error` only looks for underflow on SIGSEGV, and Darwin is not
   in its list of systems with a reliable fault address, so the fault
   came out as `System Error: Signal = 10`. A Darwin branch now checks
   the fault address against the lim page for either signal, whatever
   the PC.

The `[wx-decline]` / `[wx-noprogress]` / `[fatal]` / `[fatal2]` lines
were porting diagnostics printed unconditionally on every fault reaching
the error machinery, so even a correct mishap arrived with register
dumps. They now print only with `POP_FAULT_TRACE` set, the variable the
Cygwin break emulation already uses for the same purpose.

## How it was found

The example sweep of 2026-11-27 ran every notebook against a clean build
and compared outputs with the committed ones. `stack.ipynb` crashed its
session where the committed copy showed `INVOLVING: [] []`, and
`lists.ipynb`'s `hd() =>` found the kernel's spool path on the stack.
Both committed outputs had come from this bug, as had `random.ipynb`'s
ten 5s from `random(5)` ([random-int-64bit.md](random-int-64bit.md)).
