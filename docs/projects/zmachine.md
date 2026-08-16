# Learning project: a Z-machine in Pop-11 (play Adventure/Zork)

**Status:** flagged 2026-08-16 · **Type:** learning project (2030plan 1.5) ·
**Owner:** open

## The pitch

Implement a Z-machine interpreter in Pop-11 and ship classic
interactive fiction — Zork I (the canonical Z-machine target) and a
z-code build of Colossal Cave Adventure — playable inside Poplog.
Infocom's Z-machine is the best-documented VM ever reverse-engineered
([the Z-Machine Standards Document](https://inform-fiction.org/zmachine/standards/z1point1/index.html), v1.1),
which makes it a *teaching-sized* VM: memory map, object tree with
properties, a stack machine with ~120 opcodes, ZSCII text with
dictionary lookup. Every piece maps onto things Pop-11 teaches
naturally:

| Z-machine piece | Pop-11 lesson it carries |
|---|---|
| story-file memory map | vectors/strings as byte memory, bit fields |
| object tree + properties | records, association lists |
| opcode dispatch loop | procedures as data, `go_on`/vectors of closures |
| ZSCII text decoding | itemisation, character/string handling |
| save/restore (Quetzal) | datafiles; compare with Poplog's own `syssave` |
| the REPL loop | readline, our popsession/pty machinery |

A TEACH ZMACHINE file grows alongside the code — the project *is* the
tutorial, the way TEACH CHAT builds Eliza.

## Design

The technical design — module decomposition, data representations,
dispatch strategy, testing layers, milestones — is in
[`zmachine-design.md`](zmachine-design.md). Headline decisions: memory
is a Pop-11 string (byte array), operands ride the open stack through a
256-entry vector of opcode procedures, front ends plug in via `dlocal`,
and a measured spike puts dispatch at 45M/sec — two to three orders of
magnitude more than the games need, so the code is written for a reader.

## Scope ladder

1. **Rung 1 — v3 story files** (Zork I, era-standard `.z3`): memory
   map, dispatch loop, text decode, object ops, parser I/O. Playable
   Zork I at the pop11 prompt. Adventure: use the freely distributable
   z-code port (`Advent.z5` is v5) — start with a v3 build or take
   rung 2.
2. **Rung 2 — v5 support** (extended opcodes, colour/window ops can be
   stubbed): unlocks `Advent.z5` (Graham Nelson's port, freely
   redistributable) and most modern Inform games.
3. **Rung 3 — Quetzal save/restore + transcripts**; regression via the
   `czech`/`praxix` Z-machine conformance suites in CI.
4. **Rung 4 — front ends**: VED as the status-line screen; a Jupyter
   notebook front end (cell = one turn) for the gallery; MCP tool
   (`pop11_zork`?) as a demo agents can play.

Story files: Zork I is abandonware-adjacent (Activision-owned; often
tolerated but NOT freely licensed — do not commit it). Commit only
freely-licensed story files: `Advent.z5` (public-domain-adjacent),
`czech.z5`/`praxix.z5` (test suites), and any Inform-compiled originals
we write.

## Hosting plan (if we want it playable outside a Poplog install)

Staged, cheapest-first — aligned with 2030plan 1.4's playground ladder,
and the same infrastructure serves both:

- **Stage 0 — no hosting:** playable via the notebooks (committed
  executed transcript) and `pop11 zmachine.p advent.z5` locally.
  Zero cost, zero ops. Ship this first.
- **Stage 1 — recorded:** asciinema/GIF of a Zork session on the README
  and docs site. Static, free (GitHub Pages already serves the site).
- **Stage 2 — server-backed live demo:** one small VPS (Fly.io /
  Hetzner, ~$5/mo) running N sandboxed popsession instances behind a
  tiny websocket→pty bridge, xterm.js front end served from the
  existing GitHub Pages site. Per-session limits (CPU/mem/idle
  timeout), no filesystem writes outside the session dir, story files
  baked into the image. This is EXACTLY playground 1.4a — building it
  for the z-machine gives us the playground for free (same bridge, a
  different banner command).
- **Stage 3 — serverless/wasm:** rides 1.4c (true wasm backend);
  no z-machine-specific work.

Decision point: stages 0–1 need no approval or accounts; stage 2 needs
a VPS account and a domain decision (subdomain of an IoTone property
vs fly.dev default) — user-side sign-off required before anything goes
live.
