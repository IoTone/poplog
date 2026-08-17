# Z-machine in Pop-11 — technical design

**Companion to** `docs/projects/zmachine.md` (the why and the hosting
ladder). This is the how. · Drafted 2026-08-16

## 1. Goals, non-goals

**Goals.** A Z-machine interpreter that (a) plays real story files —
v3 first (Zork I era), then v5 (`Advent.z5`); (b) reads as a *tutorial*,
because a TEACH file grows beside it; (c) is idiomatic Pop-11, not C
transliterated into Pop-11; (d) is regression-tested against the
public Z-machine conformance suites.

**Non-goals (for now).** Versions 1, 2, 6 (graphics). Sound. Unicode
beyond ZSCII's own extension table. Blorb packaging. A v6 screen model.
Each is additive later; none shapes the core.

**Design tension to hold.** Speed is *not* a constraint (see §9 — a
spike measured 45M dispatches/sec, and Z-machine games need ~10⁵/sec),
so wherever clarity and speed conflict, clarity wins. This is the rare
interpreter that can afford to be written for a reader.

## 2. Module decomposition

Seven files, each one lesson-sized. `uses zmachine` pulls the rest.

| File (`pop/lib/lib/`) | Holds | The Pop-11 lesson |
|---|---|---|
| `zmachine_mem.p` | story loading, byte/word access, address unpacking, header fields | strings as byte arrays; `fast_subscrs` |
| `zmachine_text.p` | ZSCII decode/encode, alphabets, abbreviations | state machines over packed data |
| `zmachine_obj.p` | object tree, attributes, properties | records vs. computed addresses |
| `zmachine_dict.p` | dictionary lookup, input tokenising | binary search; itemisation by hand |
| `zmachine_ops.p` | the opcode tables and every handler | procedures as first-class data |
| `zmachine_io.p` | screen/input abstraction, front ends | `dlocal` as a plug-in mechanism |
| `zmachine_core.p` | stack, frames, decoder, the fetch–decode–execute loop | the interpreter loop itself |
| `zmachine.p` | the umbrella: `uses` the six modules above | how a Poplog library is assembled |

Runner: `examples/zplay.p` (`zplay <story-file>`). Tutorial:
`pop/teach/zmachine`. Tests: `tools/tests/test_zmachine.p`.

Story files live in `examples/games/` and **only if freely licensed**
(`Advent.z5`, `czech.z5`, `praxix.z5`). Zork I is Activision's — the
runner takes a path, the repo never ships one.

## 3. Core representations

### 3.1 Memory is a string

Poplog strings are unsigned-byte arrays, which is exactly the
Z-machine's memory model. No new datatype, no `exload`, no copying.

```pop11
;;; Z addresses are 0-based; Pop-11 subscripts are 1-based.
define zbyte(addr);   fast_subscrs(addr fi_+ 1, zmem)  enddefine;
define zword(addr);
    (fast_subscrs(addr fi_+ 1, zmem) fi_<< 8)
        fi_|| fast_subscrs(addr fi_+ 2, zmem)
enddefine;
```

Writes go through `zbyte_put`/`zword_put`, which assert the address is
below `static_base` — the spec's one memory rule, enforced in one place
and reported as a mishap naming the offending PC.

**Address kinds** are a classic source of bugs, so they get distinct
procedures rather than bare arithmetic: *byte addresses* (as-is),
*word addresses* (×2, used only by the abbreviations table), and
*packed addresses* (×2 in v3, ×4 in v5 — plus v5's routine/string
offsets). The multiplier is decided **once at load time** by installing
`unpack_routine`/`unpack_string` as version-appropriate procedures, not
by testing the version on every call.

### 3.2 Values: 16-bit, and signed only when the opcode says so

Everything in memory is an unsigned 16-bit word; arithmetic opcodes
interpret operands as *signed*. Two helpers, used deliberately:

```pop11
define signed16(v);   if v fi_>= 16:8000 then v fi_- 16:10000 else v endif enddefine;
define unsigned16(v); v fi_&& 16:FFFF enddefine;
```

Every arithmetic handler reads through `signed16` and stores through
`unsigned16`. Stated as a rule in the TEACH file, because forgetting it
is *the* classic Z-machine bug (`jl`/`jg` on large object numbers).

### 3.3 Frames and the evaluation stack

The Z-machine has one shared evaluation stack plus a chain of call
frames. Mirroring that faithfully keeps Quetzal save/restore honest
later:

```pop11
defclass zframe {
    zf_return_pc,       ;;; where to resume in the caller
    zf_store_var,       ;;; variable to store the result in, or false (call_n)
    zf_locals,          ;;; intvec, 15 slots
    zf_nargs,           ;;; for check_arg_count (v5)
    zf_eval_base        ;;; zsp on entry — the frame's slice of the stack
};
```

The evaluation stack itself is one `initintvec(1024)` plus an integer
`zsp`; frames record their base so `throw`/`ret` can unwind exactly and
so a save file can be written by walking the frame chain.

Locals as a 15-slot intvec per frame is a deliberate small waste (a few
hundred bytes per call) bought for clarity and for `copy`-free frame
handling.

### 3.4 Objects stay in memory, not in Pop-11 records

Tempting to parse the object tree into `defclass` records — wrong: game
code mutates the tree (`insert_obj`) and reads it back through
`get_prop_addr`, so the story file's own bytes must stay authoritative.
`zmachine_obj.p` is therefore a set of *address calculators*
(`obj_addr`, `attr_addr`, `prop_table_addr`, `first_prop`, `next_prop`)
with the v3/v4+ layout differences isolated in those few procedures:
v3 is 9-byte entries with 1-byte relatives and 32 attributes; v4+ is
14-byte entries with 2-byte relatives and 48. Every opcode above them
is then version-agnostic — which is the whole point of the split, and a
good lesson in where to put a conditional.

## 4. Decode and dispatch

### 4.1 One flat table, the standard numbering

Four instruction forms (long/short/variable/extended) collapse into one
256-entry opcode space plus a second table for v5's `EXT`:

| Range | Form |
|---|---|
| 0–31 | 2OP |
| 128–143 | 1OP |
| 176–191 | 0OP |
| 224–255 | VAR |

```pop11
lconstant zops     = initv(256);    ;;; procedures, indexed opcode+1
lconstant zops_ext = initv(256);
```

Unfilled slots hold a handler that mishaps with the decoded opcode name
and PC. That turns "unimplemented" into a precise, actionable message —
and makes the bring-up loop *run it, see which opcode it names, write
that one*, which is a genuinely nice way to learn a VM.

### 4.2 Operands ride the Pop-11 open stack

The Z-machine is a stack machine and Pop-11 has an open stack, so
operands are passed on it — no per-instruction vector or list
allocation anywhere in the hot path:

```pop11
;;; decoder pushes each operand value, then the count; every handler
;;; is called the same way and pops what it needs.
define op_add(n);
    lvars n, a, b;
    () -> (a, b);                       ;;; two operands, in order
    zstore(unsigned16(signed16(a) fi_+ signed16(b)))
enddefine;
```

This uniform convention is worth the one paragraph it costs to explain,
and it is the design's clearest "because this is Pop-11" moment.

### 4.3 Store and branch belong to the opcode, not to a table

Many interpreters carry parallel `stores_result[]` / `branches[]`
metadata tables. Here each handler simply calls `zstore(value)` or
`zbranch(bool)`, which read the store byte / branch offset from the PC
themselves. The knowledge lives in the one place that already has it —
the handler — and each handler reads as a description of its opcode.

Branch data is the spec's fiddliest encoding (bit 7 = polarity, bit 6 =
short form; offsets 0 and 1 mean *return false* / *return true*), so it
is written once in `zbranch` with the spec quoted above it.

## 5. I/O: front ends plug in with `dlocal`

The interpreter never calls `cucharout` directly. It calls through
variables:

```pop11
vars procedure (zio_print, zio_read_line, zio_status, zio_split);
```

A front end binds them with `dlocal` for the duration of a game, which
is Pop-11's native answer to dependency injection and needs no
interface machinery:

- **tty** (default): `cucharout` plus a character-level line reader —
  the same one the MCP server uses.
- **notebook**: buffers output per turn; a cell is one move. Gives us a
  committed, executed Adventure transcript in the gallery.
- **VED**: status line as the v3 status window; the natural home for
  the split-window model later.
- **MCP**: exposes a game as an agent-playable tool.

Only the tty front end is in scope for M1–M3.

## 6. Errors

Every failure is a mishap carrying the Z-machine context, not a Pop-11
stack trace alone:

```
;;; MISHAP - zmachine: unimplemented opcode VAR:248 (call_vn2) at PC 0x4a12
```

Story-file problems (bad header, truncated file, unsupported version)
are caught at load with the same specificity. A running game never
takes down the session: `zmachine_run` traps mishaps the way
`skill_run` does, so a crash returns you to the Pop-11 prompt with the
PC and the last opcode.

## 7. Testing

We are unusually well equipped here, because the sibling project
`IfWhenZMachineSpectacles` already contains a working TypeScript
Z-machine (`tszm`), a curated story library with the licensing research
done, and scripted walkthroughs. That turns testing from "write golden
files by hand" into "diff against a reference implementation".

**Four layers:**

1. **Unit** (`tools/tests/test_zmachine.p`, poptest, joins
   `tools/test-libs.sh`): header parsing against a hand-built byte
   string; `signed16`/`unsigned16` edges; ZSCII decode of known words
   and encode/decode round trips; object accessors against a synthesized
   miniature object table; branch-offset decoding of all four forms.

2. **Conformance — the hard gate.** CZECH (the Comprehensive Z-machine
   Emulation CHecker) compiled for v3. Its source is freely
   distributable, so we compile and commit the artifact ourselves
   (`tools/zmachine/build-testgames.sh` → `examples/games/czech.z3`,
   10.7 KB) and CI needs no Inform toolchain. A correct v3 interpreter
   reports exactly:

   ```
   Performed 368 tests.
   Passed: 349, Failed: 0, Print tests: 19
   ```

   Verified against the reference interpreter before we wrote a line.
   (An early note here claimed the v5 suite exposed a bug in the
   reference at test 241. That was misread from a *stored* transcript
   in the sibling project, presumably from an older build; run live,
   the reference passes v5 cleanly. The correction is kept visible
   because the lesson is the point: a checked-in transcript is not a
   test result.)

3. **Differential against the oracle.** `node tszm/test/run.js
   <story> <input-script>` replays a scripted session; our runner takes
   the same story and script and the transcripts are diffed. This is far
   stronger than hand-written goldens: any story file plus any command
   list becomes a test, and disagreements point at a specific turn.
   Bring-up target is `minizork.z3` (Mini-Zork I — a real 52 KB v3
   Infocom game) with the project's existing `minizork-walk.txt`, which
   exercises the mailbox, leaflet, lamp, rug, trap door, and a
   save/restore pair.

   Caveat, learned from the v5 czech run: the oracle is a reference, not
   an authority. Where they disagree, CZECH and the standard decide.
   This was not hypothetical. On `take brass lamp, north xyzzy` the
   reference returns five tokens, gluing the comma onto `lamp`; the
   standard (§13.6.1) says a word separator **is itself a word**, so the
   answer is six. Mini-Zork settles it: given our tokens, `open mailbox.
   north` opens the mailbox *and* walks north, while the reference
   answers *"You used the word 'north' in a way that I don't
   understand"*. Commands addressed to characters (`TROLL, HELLO`) fail
   the same way there. `examples/games/parsertest.inf` pins this down as
   a regression test.

4. **End-to-end golden transcript** for the committable story files, so
   the public repo has a regression test that needs no external assets.

The notebook front end doubles as a demo *and* a test: an executed
notebook is a transcript that must reproduce.

**Licensing line.** `czech.z3` (ours, from free source) is committed.
`minizork.z3` is Activision property and stays out of the repository —
it is a local bring-up target only, reached by path. `advent.z5` is
freely distributable and can be committed when v5 lands in M4. Recorded
in `examples/games/README.md`.

## 8. Milestones

Each ends in something runnable, and the acceptance test is written
before the milestone starts.

| M | Delivers | Acceptance |
|---|---|---|
| M1 ✅ | `zmachine_mem` + `zmachine_text` + `zmachine_obj` (done 2026-08-16) | load `czech.z3` and `minizork.z3`; dump both headers; print the abbreviations table and every object's short name — "West of House", "small mailbox", "brass lantern" prove decode + object tree in one shot |
| M2 ✅ | frames, decoder, `zstore`/`zbranch`, the v3 instruction set bar `sread`/`save`/`restore` (done 2026-08-16) | `czech.z3` runs until it *names* an unimplemented opcode; each new opcode moves the test number up |
| M3 ✅ | full v3 opcode set, dictionary, `read`, save/restore (done 2026-08-16) | **`czech.z3`: 349 passed, 0 failed** — and **Mini-Zork playable**, its walkthrough transcript matching the oracle |
| M4 ✅ | v5: extended opcodes, eight-operand calls, windows, output streams, the v5 input model (done 2026-08-16) | **Adventure playable**, its walkthrough matching the reference; `czech.z5` committed, 406/406 green in CI. `advent.z5` itself is NOT committed pending a licence confirmation (see `examples/games/README.md`) |
| M5 ✅ | Quetzal save/restore (done 2026-08-16) | **bidirectional interoperability with Frotz 2.55**: our save restores there and its save restores here, both landing on the same room, inventory and move count |
| M6 | notebook + VED + MCP front ends | executed Adventure notebook in the gallery |

TEACH ZMACHINE grows one section per milestone, written *from* the code
that just landed.

## 9. Performance

Measured spike on this Mac (M-series, current engine), 5M iterations of
*read opcode byte, read two operand bytes, dispatch through a 256-entry
procedure vector*:

```
elapsed  = 0.11 s for 5000000 dispatches
rate     = 45,454,544 instructions/sec
```

Real instructions cost more (operand-type decoding, store/branch, memory
writes) — call it a 10–20× haircut, so ~2–4M instructions/sec. Infocom
games ran playably at ~10⁵. **Two to three orders of magnitude of
headroom**, which is what licenses the "clarity wins" rule in §1. No
optimisation work is planned; if a hot spot ever appears, `fast_subscrs`
and lexical locals are already in use and the next lever is simply
inlining `zbyte`.

## 10. Decisions

1. **v3 first, then v5** — *decided 2026-08-16*. Simpler decoder, and
   the bring-up target is Mini-Zork I, a real Infocom v3 game. The v5
   czech failure in the reference interpreter (§7) is a second reason
   not to start there.
2. **Story files** — *resolved*. `czech.z3` is compiled from free
   source and committed; `advent.z5` joins it at M4; Mini-Zork and Zork
   stay outside the repo and are reached by path. Recorded in
   `examples/games/README.md`.
3. **Where the notebook front end lands** — still open, and needed for
   M6: `examples/notebooks/` beside the TEACH gallery, or its own
   games page.

Nothing here needs an external account or any hosting decision; those
start at rung 3 of the hosting ladder in the companion brief.

## 11. Assets in hand

From the sibling project `IfWhenZMachineSpectacles` (nothing is copied
into this repo except where the licence allows):

- **`tszm`** — a working TypeScript Z-machine with a scripted-I/O CLI
  harness (`node test/run.js <story> <input-file>`). Our oracle.
- **`minizork.z3`** (52 KB, v3) + **`minizork-walk.txt`** — the M3
  bring-up target and its walkthrough.
- **`advent.z5`** (135 KB, v5) + **`advent-walk.txt`** — the M4 target;
  freely distributable, committable when we get there.
- **`czech.inf`** — conformance source, from which we build v3.
- **`GAMES-LICENSES.md`** — provenance and terms for 11 story files,
  already researched. Worth re-reading before committing any of them.
