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

**Measured:** 500 round trips — sign, send, verify, compile a brand-new
native word, run it, reply — in **20 ms of client CPU**; the whole program
including engine startup ran in 84 ms wall.  A word is about sixty bytes on
the wire.

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
