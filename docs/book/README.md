# Pop-11 and the Robot Army

**Edition 1.8, September 2026** — David J. Kordsmeier and Claude.

An introduction to Poplog and Pop-11 built around one running example: a
fleet of robots commanded from a live Poplog session by an AI agent. It
covers the two-level virtual machine, a quickstart, the core language, the
fleet's programs (telemetry triage, the command post, signed orders), the
five front-ends (Pop-11, Prolog, Common Lisp, Standard ML, Forth) as the five
robots on the cover, how to host a language of your own, and the C interface.
The programs are in `examples/robotarmy/`. Cover art by David J. Kordsmeier.
Written by Kordsmeier and Claude (Anthropic) together in Claude Code.

    make            # -> poplog-book.pdf

## Building

The build uses [tectonic](https://tectonic-typesetting.github.io), which is a
single binary and downloads the TeX packages the document needs on first run:

    brew install tectonic          # macOS
    cargo install tectonic         # anywhere with Rust

Any other LaTeX distribution works as well — the document is plain LaTeX with
common packages (`geometry`, `listings`, `tcolorbox`, `hyperref`, `titlesec`,
`fancyhdr`, `booktabs`, `multicol`, `inconsolata`):

    latexmk -pdf poplog-book.tex

## Layout

| File | What it is |
| --- | --- |
| `poplog-book.tex` | Master file — document class, and the chapter includes |
| `version.tex` | The edition number and date — bump here only |
| `preamble.tex` | Page geometry, palette, headings, listing languages, callout box |
| `ch00-title.tex` | Title page and colophon |
| `ch01-why.tex` … `ch09-next.tex` | The nine chapters |
| `ch10-appendix.tex` | Appendix A — cheat sheet, mishap decoder |
| `figures/` | Cover art and screenshots (screenshots cropped from `docs/images/`) |

## On the examples

Every Pop-11, Forth, Prolog, Common Lisp and Standard ML listing in the book
was executed against this tree (Apple Silicon, macOS `arm64`) while the text
was written, and the transcripts shown are the outputs obtained. When a
listing changes, re-run it rather than assuming — several of the traps
documented in the text were found exactly that way.

Measurements quoted in Chapter 1 come from `BENCHMARKS.md`; the
compile-throughput and image-restore figures were measured directly and are
reproducible from the listings in §1.2 and §1.4.

## Publishing

`tools/gen-docs.sh` copies `poplog-book.pdf` into `dist/docs/` and links it
from the documentation-site index when the PDF is present, so a built book is
published with the site at <https://iotone.github.io/poplog/>. The PDF is
committed, so CI does not need a TeX toolchain.

## Versions

The edition is set once, in `version.tex`, and appears on the title page,
in the page footer, in the PDF metadata and here. Bump it for a new edition
and tag the commit `book-v<edition>`.

| Edition | Date | Notes |
| --- | --- | --- |
| 1.0 | September 2026 | First edition: the Robot Army theme, six runnable examples, VM diagram, CC0. |
| 1.1 | September 2026 | Chapter 8, "The fleet rewrites itself": UDP transport, Forth/Pop-11/VM-spec code mobility between machines, and the swarm demo. Verified between macOS arm64 and Linux x86-64. |
| 1.2 | September 2026 | Corrects chapter 8. The swarm's order-parameter table in 1.1 was an artefact: `net_poll` was built on `sys_input_waiting`, which is blind on datagram sockets, so the coupling never fired and the robots free-ran. Fixed with `sys_device_wait`; real measurements substituted. The cross-machine result is also corrected — machine-local groups lock, the clusters beat, and the fleet never globally settles. Adds a live watcher and a third machine (Raspberry Pi, aarch64). |
| 1.3 | September 2026 | Adds §8.6, backtracking across machines: the chain of command split over three nodes, with `remote_commands/2` written in Pop-11 as a nondeterministic Prolog predicate. Verified on macOS arm64, Linux x86-64 and a Raspberry Pi. |
| 1.4 | September 2026 | Corrects §8.5 again. The cross-machine beating is not a latency effect: when the link became five times faster the result was unchanged. The cause is that machines disagree about how long a tick takes (macOS 25.1 ms against 20.1 ms elsewhere at a nominal 20 ms), so the fleet partitions along clock rate rather than network topology — two machines whose ticks match lock across the network at 0.952. |
| 1.5 | September 2026 | Fixes what 1.4 diagnosed. Robots now advance by measured elapsed time (`sys_microtime`) instead of a nominal tick, and broadcast their rate so a listener can extrapolate from its own arrival stamp — no shared epoch, no NTP. Across two machines with a 25% tick-rate difference, R goes from 0.665 (swinging 0.002–0.976) to 0.990 (spread 0.003). |
| 1.6 | September 2026 | Confirms the 1.5 fix on the full fleet: six robots across three machines and three architectures hold R = 0.972 (spread 0.005), against 0.690 swinging 0.309–0.977 before. Over one 40 s run the machines completed 1601, 1942/1944 and 1978 ticks respectively and agreed anyway. |
| 1.7 | September 2026 | Re-measures the single-machine swarm table under the clock-based code of 1.5, which no longer reproduces the old phase values, and re-cuts the figure from that run. Rows are now elapsed seconds rather than tick numbers, since a tick is not a fixed amount of time and so is not an axis. |
| 1.8 | September 2026 | Adds §8.7, a knowledge base of sightings that expires, windows and dedups — ages on the wire rather than timestamps, expiry owned by each node, dedup by sequence. Adds §8.8, a classifier small enough to be honest: trained in Pop-11 at 275 samples/sec, inferring at 9121/sec without the autograd graph, identical to six decimals on three architectures. |

## Licence

Written 2026 by David J. Kordsmeier, Claude and the Poplog contributors. To the
extent possible under law, the authors have waived all copyright and related
rights to the book — text, listings, diagrams and cover art — under
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/); the
full legal text is in `LICENSE` in this directory. The example programs in
`examples/robotarmy/` are part of the Poplog source tree and carry its
licence.
