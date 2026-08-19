# Release sizes

Appended by `tools/release-sizes.sh` on every release, so that growth is
visible rather than discovered.

**engine** is `target/pop/basepop11` — what was compiled and linked. Only
changes under `pop/src` or `pop/extern` move it.

**tarball** is the whole download, which also carries `pop/lib` as *source*
(Poplog loads libraries at runtime with `uses`), the pop11 skill, the MCP
and LSP servers, and the freely-licensed story files. A new library grows
this and not the engine — the Z-machine added 94 KB of source and zero
bytes of binary.

Sizes are bytes.

## Before this ledger existed

The ledger starts on 2026-08-17. One earlier measurement is worth
recording because it dates the only engine change of the whole
Z-machine arc:

- **3,609,680** — `basepop11` on macos-arm64 at `83bbd5a` (2026-08-14),
  after the coroutine fix and before `I_CHECK`.

So the engine grew **48 bytes** between then and the first row below,
and that 48 bytes bought the in-loop stack-overflow and interrupt check
the runtime assembler now plants at backward jumps, a fatal-signal
diagnostic line, an env-gated break tracer, and bounded hibernation.

No measurement survives from the original port bring-up: the release
assets are clobbered on each upload and no older tarball was kept. If
that number is ever wanted, it means checking out a pre-port commit and
rebuilding.

| date | commit | platform | engine | tarball |
|---|---|---|---:|---:|
| 2026-08-17 | `e3e5a31` | linux-aarch64 | 3812712 | 2116586 |
| 2026-08-17 | `e3e5a31` | linux-riscv64 | 3836056 | 2216493 |
| 2026-08-17 | `e3e5a31` | linux-x86_64 | 3549408 | 2181393 |
| 2026-08-17 | `e3e5a31` | macos-arm64 | 3609728 | 2152959 |
