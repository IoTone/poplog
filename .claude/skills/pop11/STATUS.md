# pop11 skill — status & post-demo checklist

Last updated: 2026-08-13 (field-fix port + Tier-2 stdlib supersede). Companion docs: [SKILL.md](SKILL.md)
(usage), [demo/DEMO.md](demo/DEMO.md) (walkthrough),
[../../tools/bench-skill/README.md](../../../tools/bench-skill/README.md)
(numbers).

## ✅ Done (validated end-to-end on macOS arm64, 2026-07-31)

- [x] `popsession` runtime — persistent basepop11 across shell invocations
      (FIFO + inherited O_RDWR fd, no daemon); mishap-proof via `skill_run`
      `dlocal interrupt` trap; per-send unique sentinels; spool-file chunks
- [x] Checkpoint / restore via saved images (raw-send path; state + native
      procedures survive process death; ~190 KB image, ~8 ms restore)
- [x] `pop11run` one-shot runner
- [x] `popcurl` HTTPS shim (runtime dlopen, non-variadic surface; GET/POST;
      curl-CLI fallback) + `build-popcurl`
- [x] SKILL.md crash course; 5-beat demo script; session-retention benchmark
- [x] `install.sh` — one-command setup from a checkout (engine discovery,
      persisted config, `~/.claude/skills` link, shim build, live smoke test)
- [x] `popsqlite` sqlite shim (2026-08-01) — int-handle surface over
      sqlite3 (open/exec/prepare/step/bind, all values as text, NULL→false)
      + generated loader with `sqlite_query`/`sqlite_run_b` conveniences.
      Measured against the field scenario that motivated it: 52-query
      report pass 435 ms via sqlite3-CLI spawns → 6.5 ms in-session;
      ~47 µs/query steady-state (~180×).

## 📚 Library roadmap — what great tooling/shell orchestration needs

Priority order. "P" = pure Pop-11 (portable to every port for free),
"C" = needs a small C shim like popcurl.

None of these block the skill: the 2026-08-01 odysseus field trials went
4/4 with zero of them written, using shipped builtins + CLI bridges
(jq, sqlite3, sysobey). This roadmap deepens the "in-process at
microsecond cost" story; ranked by field evidence, not theory.

- [x] **sqlite shim** — DONE 2026-08-01, see above. v0.2 ideas: typed
      column accessors (int64/double), blob support, `sqlite_rows_iter`
      streaming for huge result sets.
- [x] **The rest of this roadmap was superseded by the in-tree Tier-2
      stdlib sweep (2026-08-08/09)** — shipped as real Poplog libraries
      (`uses` from any session, no skill-level code needed): `lib shell`
      (status/stderr/timeouts/background jobs), `lib json` (RFC 8259 + a
      TEACH walkthrough), `lib strutils`/`fileutils`/`csv`/`datetime`,
      `lib utf8`, `lib regexp` + `lib pcre` (PCRE2), `lib poptest`,
      `lib http_server` + `lib http_client` (retiring the popcurl v0.2
      item), `lib crypto`. 223 checks green via `tools/test-libs.sh`.
      See `docs/2030plan.md` Tier 2. Tarballs ship them via `pop/lib`.
- [ ] **lib argvenv** (P, 0.5 day) — `poparglist` niceties, `getenv`/
      `setenv` (`systranslate`), script exit codes for `pop11run`. The one
      survivor of the original list; low urgency.

## 🔧 Runtime hardening (popsession)

- [x] **Binary-safe log reader** (2026-08-13) — `await_sentinel` reads
      `out.log` in binary, does offset arithmetic in bytes, decodes per
      line with `errors="replace"`. Fixes the field-hit UnicodeDecodeError
      (session output containing non-UTF-8 bytes, e.g. shelled-out npm)
      that also corrupted the resume offset.
- [x] **Stack-underflow immunity** (2026-08-14) — a chunk that popped an
      empty stack (`-> x;`) used to KILL the whole engine: the underflow
      ate the outer stdin compiler's buffered itemiser state (the queued
      sentinel statement), and the stack pointer was left below base for
      the next chunk's itemiser to die on. Two-part fix in the skill_run
      protocol: the sentinel is now an ARGUMENT to skill_run (consumed
      before user code runs, so the outer compiler holds no state during
      execution), and skill_run refills the stack to its entry depth
      after every chunk. Verified: single and triple underflows survive
      with the session healthy. Found via the Jupyter TEACH conversions
      (TEACH LISTS teaches `->` in split halves).
- [x] **Validation-gated checkpoints** (2026-08-13) —
      `checkpoint PATH --verify 'EXPR'` runs EXPR through the
      mishap-trapped path first; mishap or false → no image written,
      rc 1, gate visible in the transcript. A checkpoint records state,
      not quality — this stops a badly-driving model from persisting
      garbage on vibes. `sysgarbage()` now runs before every `syssave`
      to keep images compact.
- [ ] `popsession interrupt` — SIGINT a runaway chunk without killing the
      session (needs a check that batch-mode SIGINT doesn't exit basepop11)
- [ ] Auto-checkpoint on `stop` (`--checkpoint-on-stop PATH`), plus
      `popsession log` (tail out.log) and log rotation
- [ ] Structured send results (`--json`: output, error flag, duration)
- [ ] Long-running-chunk progress: stream output as it appears rather than
      only at sentinel time
- [ ] Multi-session docs + `popsession list`
- [ ] Grow SKILL.md's mishap decoder from real observed model errors
      (each documented error-pattern saves a full model retry turn)

## 📦 Developer experience / distribution — the "one command" ladder

Today (works now, from a checkout):

```sh
sh .claude/skills/pop11/install.sh [--poplog-root DIR]
```

discovers the engine, persists it to `~/.cache/pop11-skill/config.json`
(so no env var is ever needed), links the skill into `~/.claude/skills/`
for all projects, builds popcurl, and smoke-tests a live session.

The ladder to true one-command-from-nothing (in order):

- [x] **Relocatable binary tarballs** — `tools/release-skill-tarball.sh`
      packages a built tree (wrapper + basepop11 + pop/lib + skill/) as
      `pop11-skill-<os>-<arch>.tar.gz` — **2.4 MB** on macos-arm64 (~12 MB
      unpacked: one 4.4 MB engine binary — pop11/clisp/prolog/pml are hard
      links to it, so ship just basepop11 — plus 7.2 MB pop/lib). Relocation
      verified: rewriting the wrapper's `poplogroot=` line is the only
      fix-up needed (binaries/images/autoload are path-clean).
- [x] **`tools/install-skill.sh` network installer** — the true one-liner:
      `curl -fsSL https://raw.githubusercontent.com/IoTone/poplog/master/tools/install-skill.sh | sh`
      downloads the platform tarball from the latest GitHub release, unpacks
      to `~/.local/share/pop11-skill`, relocates, runs the bundled
      install.sh (config, skill link, popcurl, live smoke test).
      `POP11_SKILL_URL`/`POP11_SKILL_PREFIX` override for pinning/testing.
      Full chain validated locally via a `file://` URL in a sandbox $HOME.
- [x] **Publish the assets** — `skill-2026.10` (2026-10-15) carries
      tarballs for **all four** platforms — macos-arm64, linux-x86_64,
      linux-aarch64, linux-riscv64 — each built on its own hardware from
      `d6be806` through `tools/ci/build-and-verify.sh`, plus the three
      editor artifacts and `SHA256SUMS.pop11-skill`. The curl one-liner is
      verified end-to-end against it. Supersedes `v160200-skill`
      (2026-07-31), which had only macos-arm64 and linux-x86_64.

      Note on `latest`: there is one Latest slot and two release series
      want it. The skill releases own it, because that is what
      `install-skill.sh` fetches by default; the seeds are addressed by
      their `corepops-YYYY.MM` tag, pinned in `build-and-verify.sh`. When
      corepops-2026.08 held the slot (2026-08-09 to 2026-10-15) the
      installer's default URL 404'd, so do not publish a corepops release
      as `--latest`. Remaining refinement: a CI job per platform so every
      release ships fresh assets instead of hand-built uploads.
- [ ] **Nix path** (0.5–1 day) — teach `popsession` the Nix store layout
      (today it requires `./poplog` + `./target/pop/basepop11`; the flake's
      out-path differs), then `nix profile install github:IoTone/poplog#poplog`
      + `install.sh` just works; later a `#pop11-skill` flake output that
      does both.
- [ ] **Homebrew tap** (1–2 days, optional) — `brew install iotone/tap/poplog`
      wrapping the tarball; reaches the largest macOS audience.
- [ ] Installer polish: `--uninstall`, version pinning, upgrade-in-place,
      CI job that runs install.sh + smoke on macOS and Linux runners.
