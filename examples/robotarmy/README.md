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

| elapsed | phases | sync |
| ---: | --- | ---: |
| 0.00 s | 0.00  1.70  3.40  5.10 | **0.085** |
| 0.75 s | 0.59  2.29  5.12  0.48 | 0.422 |
| 1.50 s | 1.50  2.08  1.30  1.85 | 0.954 |
| 3.00 s | 3.76  3.88  3.99  4.13 | 0.991 |
| 5.97 s | 1.94  2.06  2.18  2.31 | **0.990** |

Rows are seconds, not tick numbers — a tick isn't a fixed amount of time, so
it isn't an axis.  R passes 0.985 about 1.75 s in and never drops below it
again, at a constant phase *lag* rather than identical phases — the correct behaviour for oscillators with different
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

## vision.p — a classifier small enough to be honest

`sightnet.p` had canned labels.  This produces real ones, from real pixels,
with a network trained here rather than imported.

```sh
./poplog basepop11 examples/robotarmy/vision.p --train 12    # ~10 seconds
./poplog basepop11 examples/robotarmy/vision.p --check
```

```
epoch 12: train 100%, test 100%  (10 s elapsed)
done: 275 samples/sec through the graph
held-out accuracy 100% of 80
9121 classifications/sec over 2000
```

### The honesty is in the scope

A 256→16→4 MLP cannot tell a cat from a dog in a photograph.  Nothing this
size can, and a transformer over image patches would be slower and no better.
What it *can* do is recognise a small fixed vocabulary of markers — which is
what a robot army watching for painted signs actually needs.  So the classes
are shapes, and what a shape **means** is left to Prolog, where it is data:

```prolog
means(circle, cat).      means(triangle, hazard).
alarming(cat).           alarming(hazard).
suspicious(Id,R,M,A) :- recently(Id,R,Shape,C,A), C >= 0.8,
                        means(Shape,M), alarming(M).
```

A live fleet can be taught a new sign, or a new alarm, with `deploy.p` and no
restart.  100% accuracy is real but easy by construction: four well-separated
shapes with light noise, jittered in position and size.

### Two measured facts shape the design

**Training goes through the autograd graph** at 275 samples/sec — fine for
240 samples, hopeless for anything real.  Train once.

**Inference does not need the graph.**  Dropping it for plain floats is a 30×
speedup.  So the exported weights are plain numbers and the forward pass is
ordinary arithmetic, with `fast_subscrv` for another 23%.

| | classifications/sec |
| --- | ---: |
| macOS arm64 | 9121 |
| Linux x86-64 | 7717 |
| Pi aarch64 | 3417 |

All three give **100% held-out accuracy and identical confidences to six
decimal places** — the same weights, the same answers, three architectures.

### Weights are data, not code

An earlier version emitted weights as Pop-11 source, making the compiler
build a 4096-element literal.  That is the wrong mechanism — and on the Pi it
is also a way to meet
[a SIGILL](../../docs/bugs/aarch64-large-literal-sigill.md).  Weights are now
written as plain numbers and read with `line_repeater`/`strnumber`, which
works everywhere and loads faster.

### Wired into the fleet

With weights present, `sightnet.p`'s reel renders a frame, classifies it, and
records the network's answer.  `--fetch` returns the actual frame that was
classified, so a requestor can pull the evidence:

```
  [reel] r1 saw circle (drawn circle, 0.99 confidence), 1 held
  r1-5 / cat / 3.7          <- saw/4, shape resolved to meaning
  r1-3 / hazard / 11.8
```

## sightnet.p — what the fleet has seen lately

`chainnet.p` distributes a relation that never changes.  This distributes one
that is always changing: each robot records what its camera saw, records
expire, and any robot can ask the fleet *"what has anyone seen in the last
five minutes that I don't already know about?"*

```sh
# a node with canned sightings, plus a "reel" that keeps seeing things
SIGHT_REEL=8 ./poplog basepop11 examples/robotarmy/sightnet.p \
    --serve r1 9871 --seed

# ask the fleet
./poplog basepop11 examples/robotarmy/sightnet.p --ask r0 "$LNX:9871,$PI:9872" \
    '(recently(Id,R,L,C,A), write(Id/L/C/A), nl, fail ; true)'

# stand watch: poll, shout about anything alarming AND new
./poplog basepop11 examples/robotarmy/sightnet.p --watch r0 "$LNX:9871" 600

# fetch the frame behind a sighting (chunked)
./poplog basepop11 examples/robotarmy/sightnet.p \
    --fetch r0 $PI:9872 r2-11 /tmp/frame.pgm
```

### Three decisions, each a trap avoided

**The wire carries ages, not timestamps.**  These machines don't agree about
what time it is — the Pi runs with NTP inactive — so a timestamp from another
node isn't comparable with ours.  An age is a *duration*: it needs agreement
on the length of a second, which they have, not on an epoch, which they don't.
Same correction `swarm.p` needed, one layer up.

**Expiry is the owner's job.**  A node prunes its own store; nobody prunes
anyone else's.  `SIGHT_TTL` defaults to 86400 and is overridable so the
boundary can be demonstrated without waiting a day:

```
SIGHT_TTL=86400 -> seeded 7 sightings, 6 survive   (one was 25h old)
SIGHT_TTL=600   -> seeded 7 sightings, 3 survive
```

**Dedup is by (robot, sequence), not by content.**  Each robot numbers its own
sightings; a requestor remembers the highest sequence per robot and sends
those marks with the query, so the reply carries only what's new — which also
keeps it inside one datagram.  Content hashing would collide the moment two
frames of the same quiet corridor looked alike.

The watcher shows it working — first poll returns the backlog, then exactly
one new row per node per reel tick, never a repeat:

```
  ** ALERT cat (0.91 confidence) seen 22.0 s ago -- r2-1
  ** ALERT cat (0.91 confidence) seen 22.0 s ago -- r1-1
  8 new rows, 2 alerts
  2 new rows, 0 alerts
  2 new rows, 0 alerts
  ** ALERT cat (0.86 confidence) seen 0.5 s ago -- r2-14
  2 new rows, 2 alerts
```

### The query language is Prolog, the store is Pop-11

The store is mutable and expiring, which is exactly why Pop-11 owns it and
Prolog reads it through a `define :prolog` predicate — one heap, no
marshalling.  Both the local store and the remote fleet are reached the same
way, so the rules can't tell them apart:

```prolog
sighting(Id,R,L,C,A) :- local_sighting(Id,R,L,C,A).
sighting(Id,R,L,C,A) :- remote_sighting(Id,R,L,C,A).

recently(Id,R,L,C,A)  :- sighting(Id,R,L,C,A), A =< 300.
today(Id,R,L,C,A)     :- sighting(Id,R,L,C,A), A =< 86400.

alarming(cat).
suspicious(Id,R,L,A) :- recently(Id,R,L,C,A), C >= 0.8, alarming(L).
```

`alarming/1` is data, so a live fleet can be taught a new alarm with
`deploy.p` without restarting anything.

### Asset transfer

A frame is a 32×32 ASCII PGM, ~3.7 KB — deliberately larger than one
datagram, so fetching exercises the chunked path (`net_send_big` /
`net_collect`) rather than the single-datagram path everything else uses.
Verified byte-identical fetching from a Pi (aarch64) and a Linux box
(x86-64) to macOS arm64.

### Where the camera goes

`sight_frame/1` generates a canned frame from a sequence number.  A real node
replaces it with a read of the newest file in a common image directory —
whatever platform-specific thing wrote it, in whatever format everyone
agrees on.  Nothing above that function cares which it was, and the classifier
result is the only thing that enters the knowledge base.

## chainnet.p — backtracking across machines

`chain.pl` holds the whole org chart on one machine.  A real fleet doesn't:
each squad knows who it commands, nobody holds the whole picture.
`chainnet.p` splits the relation across nodes and lets Prolog's own
backtracking put it back together.

```prolog
commands(X, Y) :- local_commands(X, Y).     % ordinary Prolog facts
commands(X, Y) :- remote_commands(X, Y).    % Pop-11, doing a UDP round trip

can_order(X, Y) :- commands(X, Y).
can_order(X, Z) :- commands(X, Y), can_order(Y, Z).
```

`remote_commands/2` is written in Pop-11 with `define :prolog`, and calls
`prolog_unifyc` once per answer it gets back.  That establishes a real choice
point each time, so the predicate is genuinely **nondeterministic**: Prolog
backtracks into the next machine's answer exactly as it would into the next
clause.  This works because Prolog and Pop-11 share one heap — there is no
serialisation boundary, so a Pop-11 procedure can simply *be* a predicate.

A node answers from its local facts only and never recurses into `can_order`.
That is what stops two nodes asking each other the same question forever.

```sh
# on each squad machine
./poplog basepop11 examples/robotarmy/chainnet.p \
    --serve 9821 examples/robotarmy/chain-sq1.pl

# on the command post, which knows only commander->sq1, commander->sq2
./poplog basepop11 examples/robotarmy/chainnet.p \
    --ask examples/robotarmy/chain-post.pl "$LNX:9821,$PI:9822" \
    '(can_order(commander, X), write(X), nl, fail ; true)'
```

Verified across three machines and three architectures — post on macOS arm64,
squad 1 on Linux x86-64, squad 2 on a Raspberry Pi:

```
sq1   <- local        r1  <- Linux box      r3  <- Pi
sq2   <- local        r2  <- Linux box      r4  <- Pi
```

`can_order(sq1, r4)` correctly answers **no** — squad 1 does not command
squad 2's robot.  A relation that only ever says yes is not a relation.

**With a node down**, the same query returns `sq1 sq2 r1 r2`: the chart is
*smaller*, not wrong.  That's the right failure mode for a relation, and also
the honest limitation — this design can't tell "no such subordinate" from
"the machine that knew is unreachable".  Two other limits: every remote call
is a fresh round trip with no cache, and backtracking asks the same question
often; and an unreachable node costs the full timeout on each call that
consults it.

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

### Across machines, the fleet locks by clock rate — not by network

Two robots each on macOS arm64, Linux x86-64 and a Raspberry Pi.  Each
machine's pair holds at 0.97 for the whole run; the fleet as a whole wanders
between 0.32 and 0.97 (mean 0.69) and never settles.

The obvious explanation is latency, and it is wrong.  That was the claim here
in edition 1.2: 20 ms tick, RTT 4–108 ms, so remote phases must arrive stale.
The link later became direct (4.6–16.3 ms, mean 7.2), putting every remote
phase well inside its tick.  The result didn't move: mean 0.70 vs 0.69.

What actually differs is how long a tick *takes*:

| | nominal 20 ms | nominal 100 ms |
| --- | ---: | ---: |
| macOS arm64 | 25.1 ms | 104.5 ms |
| Linux x86-64 | 20.2 ms | 100.3 ms |
| Raspberry Pi | 20.1 ms | — |

The Mac carries ~4.5 ms of fixed overhead per tick.  A robot advances by
`omega*dt` per tick, so 25% longer ticks means 25% slower phase advance *in
real time* — a frequency error far bigger than the 0.35 spread between the
model's omegas.  Robots on one machine share the error exactly; robots on
different machines don't.

Grouping the same run by machine makes it sharp:

| group | mean R | |
| --- | ---: | --- |
| mac pair | 0.974 | one machine |
| linux pair | 0.969 | one machine |
| pi pair | 0.967 | one machine |
| **linux + pi** (4 robots) | **0.952** | *two* machines, ticks matched |
| **mac + linux** (4 robots) | **0.607** | two machines, ticks differ |
| all six | 0.690 | |

Four robots across two machines, two architectures and a network link hold
0.952 — as tight as any single machine.  The same count spanning the Mac
collapses to 0.607.  **The fleet partitions along clock rate, not network
topology.**

Shrink the mismatch and the beat slows: at a 100 ms tick the Mac's overhead is
4.2% instead of 25%, and the fleet stays coherent several times longer (0.969
at tick 60, still 0.890 at 300) before drifting.  It doesn't lock forever,
because 4.2% is still more than this K can absorb.

Kuramoto assumes every oscillator shares one clock, and the program quietly
substituted "one tick of my own loop" for it.  Invisible on one machine;
dominant as soon as the fleet spans machines that tick differently.

### The fix: stop counting ticks

Two changes, neither needing the machines to agree what time it is.

**1 — advance by the time that actually passed:**

```pop11
lvars now = sys_microtime(), dt = (now - last) / 1000000.0;
if dt < 0.0 or dt > CLOCK_JUMP then DT -> dt endif;   ;;; clock step guard
now -> last;
phase + omega * dt -> phase;
```

A slower machine takes a bigger step, so 25 ms and 20 ms ticks describe the
same trajectory.  `sys_microtime()` is microsecond resolution and purely
local.  The guard matters — it's a wall-clock reading, so an NTP correction
can hand you a negative or enormous `dt`.

**2 — messages carry a rate, not just a position.**  Each robot sends its
phase *and* its `omega`; the listener stamps arrival with its own clock and
extrapolates:

```pop11
sys_microtime() -> subscrv(who + 1, p_at);          ;;; on arrival
(now - subscrv(j + 1, p_at)) / 1000000.0 -> age;    ;;; when coupling
sum + sin(subscrv(j+1, p_phase) + subscrv(j+1, p_omega) * age - phase) -> sum;
```

Note what is *not* on the wire: a send timestamp.  Carrying the sender's clock
would need an agreed epoch; stamping on arrival needs only agreement on the
length of a second, which change 1 already gives.  No NTP, no offset
estimation.  Coupling also now uses the last thing each peer said rather than
only what arrived this tick, so a dropped datagram costs precision rather than
a missed beat.

The same fleets that would not lock:

| | mean R | min | max |
| --- | ---: | ---: | ---: |
| two machines, counting ticks | 0.665 | 0.002 | 0.976 |
| two machines, **on the clock** | **0.990** | 0.989 | 0.992 |
| six robots / three machines, ticks | 0.690 | 0.309 | 0.977 |
| six robots / three machines, **clock** | **0.972** | 0.970 | 0.975 |

Spreads of 0.003 and 0.005, where before they swung the whole range and never
settled.  The partition is gone — and it was never the network.

The clearest sign is what the robots report.  Over one 40-second run the two
on macOS did 1601 ticks, the two on Linux 1942 and 1944, the two on the Pi
1978 — and all six held 0.972 throughout.  Three machines doing visibly
different amounts of work, agreeing on the physics anyway, because none of
them is counting.

Once a tick isn't a fixed length, a tick *count* isn't a duration either: 1200
ticks is 30 s on one machine and 24 s on the other, so the fleet stopped in
pieces.  `SWARM_SECONDS` ends the run on the clock instead.

**Measure the plateau, not the peak.**  Live, the fleet hits R = 0.97 around
ten seconds in and looks globally locked; that is the top of a beat, and
seconds later it is at 0.31.  A sync claim needs the value to *hold* over a
run several times longer than it took to get there.

**And vary what you blame.**  Having measured the beat correctly, 1.2 then
explained it by latency — the link was slow and the story fit.  Nobody varied
the latency.  When the link got five times faster the result was unchanged,
and the real cause had been in plain sight.  A measurement consistent with
your explanation is not evidence for it until you have tried something that
would tell them apart.

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
