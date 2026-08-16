# Story files for the Pop-11 Z-machine

Z-code story files used to develop and test `lib zmachine`
(see `docs/projects/zmachine-design.md`).

**Only freely-licensed files live here.** Commercial Infocom story
files — Zork I, Mini-Zork, and the rest — are Activision property and
are *never* committed to this repository, however widely they circulate.
The runner takes a path, so use your own copy:

```sh
./poplog basepop11 examples/zplay.p ~/games/zork1.z3
```

## What's here

| File | What it is | Terms |
|------|------------|-------|
| `czech.inf` | Source of CZECH — the Comprehensive Z-machine Emulation CHecker, by Amir Karger, based on Evin Robertson's public-domain nitfol test script | The source states: *"See README.txt for license. (Basically, use/copy/modify, but be nice.)"* — freely distributable |
| `czech.z3` | `czech.inf` compiled for Z-machine **version 3**, by us (`tools/zmachine/build-testgames.sh`) | as above |
| `parsertest.inf` | A tiny v3 story written for this project: a known six-word dictionary, one `@sread`, and a report of what the interpreter put in the parse buffer | MIT, same as this repository |
| `parsertest.z3` | `parsertest.inf` compiled for v3 | as above |

## Rebuilding

`czech.z3` is a build artifact, committed so CI needs no toolchain:

```sh
brew install inform6          # provides the `inform` binary (Inform 6.44+)
tools/zmachine/build-testgames.sh
```

CZECH compiles for several Z-machine versions (`-v3`, `-v4`, `-v6`,
`-v8`); v3 is what the interpreter targets first. On v3 the suite is a
clean gate — **368 tests, 349 passed, 0 failed, 19 print tests** —
which is what `tools/tests/test_zmachine.p` asserts.

## Development-only story files (not committed)

These live outside the repo and are used locally for bring-up:

- **`minizork.z3`** — Mini-Zork I (Infocom, 1988, Release 34). A real
  v3 Infocom game and the ideal M3 target: 52 KB, the full "West of
  House" opening, mailbox, leaflet, trap door. **Activision property**;
  historically given away on a UK magazine cassette but never formally
  licensed. Local development only.
- **`advent.z5`** — Adventure (Crowther & Woods; Graham Nelson's Inform
  port, Release 9). Freely distributable and *could* be committed when
  the interpreter reaches v5 (milestone M4).

Both, plus a reference TypeScript interpreter and walkthrough scripts,
are in the sibling project `IfWhenZMachineSpectacles` (see
`docs/projects/zmachine-design.md` §7 for how it is used as a
differential-testing oracle).
