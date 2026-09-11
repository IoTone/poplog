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

`fleet.p` runs its demonstration when it is the program; the other
files load it as a library by declaring `robotarmy_lib` first.
