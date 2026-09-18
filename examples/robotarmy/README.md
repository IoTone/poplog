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
| `orders.p` | 3, 4, 8 | **The fleet takes orders over the network.** The *same* `obey` and the same registry from `fleet.p`, now driven from another machine. |
| `fleetnet.p` | — | The fleet's UDP transport: `net_open`/`net_send`/`net_recv`/`net_poll`, plus `net_sign`/`net_verify` over HMAC-SHA256. Everything networked sits on this. |
| `fthwire.p` | — | **Forth words over the wire.** A robot is taught a word it has never seen, in one signed datagram, and executes it natively. |
| `deploy.p` | — | **Pop-11 source over the wire.** Signed, chunked, compiled into a running robot with `pop11_compile` — including redefining a procedure the robot is already using. |
| `deployments/patrol_order.p` | — | A capability to deploy: route planning the robot does not start with. |
| `swarm.p` | 4 | **Robots that fall into step.** Each broadcasts its phase over UDP and pulls itself towards the others; with no leader or clock the fleet ends up marching in time. |
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

### One spec, three instruction sets

The identical five lines, sent to three machines:

```
                  plant                                     call double 21
  macOS arm64     planted double/1 as native code, 2 instr.       42
  Linux x86-64    planted double/1 as native code, 2 instr.       42
  Linux aarch64   planted double/1 as native code, 2 instr.       42
```

The Pi is not on the tailnet — it sits on the x86-64 box's local network, so
that leg was driven from x86-64 rather than from the Mac: an x86-64 command
post planting aarch64 code.  Nothing in the code knows or cares; a robot is
a host and a port.

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

## Falling into step (`swarm.p`)

Each robot carries a phase and a rhythm of its own.  Every tick it
broadcasts its phase to the rest of the fleet, listens for theirs, and pulls
itself slightly towards them:

```
phase' = phase + omega*dt + (K/N) * sum over peers of sin(peer - self)
```

Left alone, robots with different natural rhythms drift apart forever.
Coupled, they pull each other into lockstep — **no leader, no clock, no
central authority**.  (Kuramoto's model; the same arithmetic describes
fireflies and pendulum clocks sharing a beam.)

```sh
for i in 0 1 2 3; do ./poplog basepop11 examples/robotarmy/swarm.p $i 4 & done
wait
./poplog basepop11 examples/robotarmy/swarm.p --render 4
```

Four separate OS processes, coupled only by signed datagrams.  Measured by
the Kuramoto order parameter — 0 is chaos, 1 is perfect lockstep:

| tick | phases | sync |
| ---: | --- | ---: |
| 0 | 0.05  1.77  3.48  5.20 | **0.096** |
| 60 | 3.72  3.90  3.98  4.13 | 0.990 |
| 120 | 1.78  1.96  2.04  2.18 | 0.990 |
| 239 | 4.11  4.29  4.37  4.51 | **0.990** |

They lock by tick 60 and *stay* locked, at a constant phase *lag* rather than
identical phases — the correct behaviour for oscillators with different
natural frequencies.  The staying is the signal: a merely *rising* order
parameter proves nothing, because uncoupled oscillators drift past each other
and the measure climbs on the way past.

Each robot reports its traffic on exit:

```
robot 0 done -- heard 717 peer messages over 240 ticks, 0 sends dropped
```

717 is 3 × 239 — every peer, every tick.  This line exists because an earlier
version of this table was an artefact: `net_poll` was built on
`sys_input_waiting`, which answers `false` forever on a datagram socket, so
the coupling term never once fired and every robot free-ran while still
producing plausible output.  See
[docs/bugs/sys-input-waiting-blind-on-sockets.md](../../docs/bugs/sys-input-waiting-blind-on-sockets.md).

### Watching it live across real machines

`swarm-live.sh` starts two robots per machine and a passive watcher on this
host.  The watcher only listens — robots copy their phase to it and it never
replies, so it cannot perturb what it measures:

```sh
./examples/robotarmy/swarm-live.sh
```

```
robot   phase track (0 .. 2pi)                    phase
  0     .............................#..........  4.594
  1     ..............................#.........  4.778
  2     ..............................#.........  4.858
  3     ................................#.......  5.031
  4     .................................#......  5.205
  5     .................................#......  5.299

sync R = 0.970   ======================================
6 robots reporting, 566 messages seen
```

Configure with `NODES` (`ssh-target:remote-dir:tailnet-ip` per machine, `-`
for this one) and `WATCH_IP`.  Robots read `SWARM_STEPS`, `SWARM_K`,
`SWARM_TICK` (wall-clock pacing) and `SWARM_DT` (model timestep) from the
environment; tick and timestep are independent, so slowing the demo down to
watch it does not change the dynamics being watched.

### Across machines, the fleet locks in pieces

Six robots over three machines — macOS arm64, Linux x86-64, a Pi on DietPi —
two per machine, 1200 ticks:

| tick | all six | mac | linux | pi |
| ---: | ---: | ---: | ---: | ---: |
| 60 | 0.730 | 0.978 | 0.978 | 0.985 |
| 240 | 0.694 | 0.977 | 0.975 | 0.983 |
| 480 | 0.313 | 0.977 | 0.976 | 0.985 |
| 960 | 0.967 | 0.977 | 0.976 | 0.984 |
| 1199 | 0.350 | 0.993 | 0.982 | 0.984 |

Each machine's pair locks at 0.98 within 60 ticks and stays there.  The fleet
as a whole never settles: global R wanders between 0.31 and 0.98, mean 0.68.
Four robots over two machines behave the same, cycling 0.94 → 0.12 → 0.94.

The clusters are **beating**, not drifting to a final value.  A local peer's
phase arrives within the tick it describes; across the link it arrives two to
five ticks stale and jittered (tick 20 ms, RTT 4–108 ms, mean 34, stddev 40),
so the groups run at slightly different rates and slide past each other
forever.  Latency partitions a swarm along the lines of the network.

**Measure the plateau, not the peak.**  Live, the fleet hits R = 0.97 around
ten seconds in and looks globally locked; that is the top of a beat, and
seconds later it is at 0.31.  A sync claim needs the value to *hold* over a
run several times longer than it took to get there.

![four robots falling into step](../../docs/images/robotarmy-swarm.png)

Time runs left to right, one band per robot, colour is phase.  At the far
left the bands are out of register, each cycling at its own rate; within the
first quarter they lock, and every column is one colour across all four bands
for the rest of the run.

### No graphics build needed

The image is a PPM, written by redirecting the character sink to a file —
the same `dlocal cucharout` trick that captures a Forth word's output in
`fthwire.p`.  Set `K = 0` in the source to remove the coupling and watch the
bands never converge.

### Trap

Poplog's trig is in **degrees** by default, so `sin` returns nearly-linear
nonsense for small radian arguments and nothing ever couples.  `swarm.p`
sets `true -> popradians` at the top, as `examples/microgpt/microgpt.p` does
for the same reason.

## Orders over the network (`orders.p`)

Chapter 4 built an order interpreter: `obey` matches a list of words against
patterns and moves robots around a registry.  Chapter 8 built a signed UDP
transport.  This is the join.

**Nothing in `fleet.p` changed.**  The order interpreter never learns that a
network exists — it still takes a list of words and returns a string.  All
`orders.p` adds is the layer that turns a datagram into that list:

```pop11
define words_of(s) -> l;
    lvars w;
    [% for w in str_split(str_trim(s), ` `) do
           if w /= '' then
               if strnumber(w) then strnumber(w) else consword(w) endif
           endif
       endfor %] -> l;
enddefine;
```

Commanding a fleet that lives in another process, on another machine, on
another architecture — an arm64 command post, an x86-64 robot:

```
report                    ->  3 of 4 units fit for duty
unit r2 advance to bridge ->  unit r2 advancing to bridge
unit r4 recharge 60       ->  unit r4 at 80%
report                    ->  4 of 4 units fit for duty
```

The state is real and it persists: the last `report` differs from the first
because `r4` was recharged in between.  That registry is an Objectclass
`Robot` heap living in the remote process.

Unsigned orders are refused before `obey` ever sees them, and leave the
fleet untouched:

```
unsigned 'all scout hold' ->  REFUSED: bad signature
  <- (unverifiable order, not obeyed)
report                    ->  4 of 4 units fit for duty     (unchanged)
```
