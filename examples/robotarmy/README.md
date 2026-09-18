# The Robot Army

The running example of *Pop-11 and the Robot Army* (`docs/book/`): a fleet
of robots commanded from a live Poplog session.  Each file is
self-contained and runs from the repository root.

| File | Chapter | What it shows |
| --- | --- | --- |
| `fleet.p` | 3, 4 | The core: a `Robot` Objectclass, a word-keyed registry, `muster()` on the open stack, and `obey()` — an order interpreter built on the list matcher. `./poplog basepop11 examples/robotarmy/fleet.p </dev/null` |
| `telemetry.p` + `fleet.log` | 4 | One pass over a fleet telemetry log: level counts, units ranked by fault count, slowest operation. `line_repeater`, default-valued properties, Poplog `@`-escaped regexps. |
| `c2.p` | 4 | The command post: `lib http_server` + `lib json` over `fleet.p`. `GET /fleet`, `GET /status?unit=r1`, `POST /order`. `./poplog basepop11 examples/robotarmy/c2.p 8099` |
| `chain.pl` | 5 | The chain of command in Prolog: `can_order/2`, `reports_to/2`, `obeys/2`. |
| `patrol.fth` | 5 | Robot control words in Poplog Forth: `drain`, `step`, `low?`, `patrol` with an early `leave`. `tools/forth.sh < examples/robotarmy/patrol.fth` |
| `signed_orders.p` | 7 | HMAC-signed orders through `lib crypto` (OpenSSL via a C shim): genuine, tampered, replayed. Build the shim first: `tools/build-popcrypto.sh` |
| `fleetnet.p` | — | The fleet's UDP transport: `net_open`/`net_send`/`net_recv`/`net_poll`, plus `net_sign`/`net_verify` over HMAC-SHA256. Everything networked sits on this. |
| `fthwire.p` | — | **Forth words over the wire.** A robot is taught a word it has never seen, in one signed datagram, and executes it natively. |
| `deploy.p` | — | **Pop-11 source over the wire.** Signed, chunked, compiled into a running robot with `pop11_compile` — including redefining a procedure the robot is already using. |
| `deployments/patrol_order.p` | — | A capability to deploy: route planning the robot does not start with. |
| `plant.p` | 6 | **VM specs over the wire.** Not source at all — an abstract instruction list the robot plants directly with `sysPROCEDURE`/`sysPUSHQ`/`sysCALL`. The same datagram becomes arm64 on one machine and x86-64 on another. |

`fleet.p` runs its demonstration when it is the program; the other
files load it as a library by declaring `robotarmy_lib` first.

## Forth over the wire (`fthwire.p`)

A robot listens on UDP.  What arrives is Forth source; the robot verifies
the signature, **compiles it** — Poplog Forth transpiles a colon definition
to Pop-11 and runs it through the incremental compiler, so the new word is
native machine code — runs it, and sends back whatever it printed.

```sh
./poplog basepop11 examples/robotarmy/fthwire.p 9600          # the robot

./poplog basepop11 examples/robotarmy/fthwire.p --tell 127.0.0.1 9600 \
    ': patrol 0 do 1 + loop ;'                                # -> ok
./poplog basepop11 examples/robotarmy/fthwire.p --tell 127.0.0.1 9600 \
    '0 10 patrol .'                                           # -> 10
```

The word persists between datagrams: it was taught in the first and
executed in the second.  Recursion works too — `: fib dup 2 < if drop 1
else dup 1 - recurse swap 2 - recurse + then ; 20 fib .` returns `10946`
from a robot that had never heard of `fib`.

**Measured on loopback:** 500 round trips — sign, send, verify, compile a
brand-new native word, run it, reply — in **20 ms of client CPU**; the whole
program including engine startup ran in 84 ms wall.  A word is about sixty
bytes on the wire.

### Verified between two machines, two architectures

The point of the exercise.  Robot on **Linux x86-64**, command post on
**macOS arm64**, over a tailnet — the word is compiled to *x86-64* native
code by a datagram sent from an *arm64* machine:

```
  <- : patrol 0 do 1 + loop ;
  -> ok
  <- 0 10 patrol .
  -> 10
  <- : fib dup 2 < if drop 1 else dup 1 - recurse swap 2 - recurse + then ; 20 fib .
  -> 10946
```

Signing holds across the network too: an unsigned datagram comes back
`REFUSED: bad signature`, a signed `7 7 * .` comes back `49`.  Twenty
cross-machine teach-and-run round trips complete inside a 0.186 s program,
engine startup included.

Source is what travels — not a saved image.  A `.psv` could not make this
trip at all (images are tied to their architecture and build), which is
exactly why the fleet ships code as text and lets each robot's own compiler
turn it into native instructions.

### Three things hold it together

1. **`dlocal cucharout` captures the output.** Forth prints through the
   character sink, so rebinding it for the dynamic extent of the call
   collects whatever the word printed — and `dlocal` restores it however the
   call exits, including when the word blows up.
2. **`dlocal interrupt` + `exitfrom` traps a bad word** so it cannot take
   the robot down.  `nosuchword` comes back as an error and the robot keeps
   serving.
3. **The stack is repaired afterwards.**  `exitfrom` unwinds the call chain
   but *not* the open stack — and Forth's data stack **is** that stack, so a
   word that died holding values would poison the next order.  After a
   deliberate crash, `.s` reports `<0>`.  (The idiom is `lib jsonrpc`'s;
   this is the same hazard one layer down.)

### Nothing unverifiable is ever compiled

Signature checking lives in the transport, not in the handler, because the
handler's job is to *compile what it is given*.  Both of these are refused
before reaching the compiler:

```
  <- (unverifiable datagram, not compiled)     # unsigned source
  <- (unverifiable datagram, not compiled)     # signed with the wrong key
```

### Sizing

`NET_MTU` is 1200, measured rather than guessed: the tailnet this was built
against has an interface MTU of 1380, and a 1372-byte don't-fragment ping to
the peer is already dropped while 1200 passes.  Forth words are tens of
bytes, so they fit comfortably; shipping Pop-11 source will need chunking.

## Pop-11 source over the wire (`deploy.p`)

The same idea as `fthwire.p` one level up.  Instead of a Forth word, a robot
receives **Pop-11 source**, signed, in as many chunks as it takes, and
compiles it into itself with `pop11_compile`.  The new procedure is native
machine code and is simply there from then on.

```sh
./poplog basepop11 examples/robotarmy/deploy.p 9800                  # the robot

./poplog basepop11 examples/robotarmy/deploy.p --tell 127.0.0.1 9800 \
    'define escort(n); n * 3 enddefine;'                             # -> compiled ok
./poplog basepop11 examples/robotarmy/deploy.p --tell 127.0.0.1 9800 \
    'npr(escort(7));'                                                # -> 21
```

### Redefinition, in a running robot

This is the part worth watching.  Redeploy the *same* procedure with a new
body and call it again — same process, no restart, no dispatch table:

```
define escort(n); n * 3 enddefine;        ->  compiled ok
npr(escort(7));                           ->  21
define escort(n); n * 100 + 1 enddefine;  ->  compiled ok
npr(escort(7));                           ->  701
```

### A real capability, chunked

`deployments/patrol_order.p` is 1898 bytes — two signed chunks, reassembled
before a single character reaches the compiler.  Immediately afterwards the
robot can plan a route it could not plan a second earlier:

```
--file  … patrol_order.p                                  ->  compiled ok
npr(describe_patrol(plan_patrol(
    [[ridge 4] [creek 2] [tower 9] [mill 3]], 10)));      ->  creek -> mill -> ridge [cost 9]
```

(`tower` is left out: it would break the budget of 10.)

### Chunking

A long message goes out as numbered chunks, `<id>:<seq>:<total>:<payload>`,
**each signed in its own right** — so an attacker cannot slip an extra chunk
into a message whose other parts are genuine.  Chunks are reassembled per
`(sender, id)`.  Verified at 7992 bytes over 8 datagrams, byte-identical.

### It survives what is thrown at it

| | |
| --- | --- |
| malformed source | `ERROR compiling deployment`, robot keeps serving |
| still knows what it learned | `alpha -> beta [cost 6]` |
| **unsigned deployment** | `refused - no backdoor` — never reaches the compiler |
| legitimately signed one | `plan_patrol present (signed, accepted)` |

The three mechanisms are the same as `fthwire.p`'s — `dlocal cucharout` to
capture, `dlocal interrupt` + `exitfrom` to trap, and restoring the open
stack afterwards — and they matter more here, not less, because what is
being compiled is arbitrary.

## VM specs over the wire (`plant.p`)

`fthwire.p` and `deploy.p` both ship *source* and let the robot's compiler
front-end read it.  This ships neither Forth nor Pop-11.  It ships an
abstract instruction spec, and the robot plants VM code from it directly —
no reader, no parser of any language.  This is Chapter 6 done between
machines.

The wire format is deliberately trivial, one instruction per line:

```
plant
name double
nargs 1
pushq 2
call fi_*
```

### One spec, two instruction sets

The identical five lines, sent to two machines:

```
                 plant                                      call double 21
  macOS arm64    planted double/1 as native code, 2 instr.        42
  Linux x86-64   planted double/1 as native code, 2 instr.        42
```

Nothing architecture-specific crossed the wire.  Each robot's own back-end
turned the same spec into its own native instructions — arm64 on one,
x86-64 on the other.  A larger spec behaves the same way:

```
plant / name score / nargs 2 / call fi_* / pushq 10 / call fi_+
  call score 6 7   ->  52     on both
```

A bad opcode gives `ERROR planting` and the robot keeps serving.

### Two traps

**Planting must happen while something is running.** At the top level of a
file being compiled it mishaps with `sysEXECUTE: NOT AT EXECUTE LEVEL`,
which is why `pl_plant` is a procedure rather than inline code.

**`fi_*` does not type-check.** An early version of the `call` path wrote

```pop11
'' sys_>< fast_apply(p)        ;;; WRONG
```

which pushes the empty string *on top of* the argument `applist` had just
pushed, so the planted procedure consumed `''` instead of `21`.  Because
the fast integer operations skip type checks, the answer came back as
`210.0` — quiet nonsense rather than a mishap.  Apply first, format second.

### Why this is the interesting one

Source needs a front-end for the language it is written in; a saved image
needs an identical architecture and build.  A spec needs neither.  It is
the smallest thing you can send that still arrives as native code.
