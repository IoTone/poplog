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
| `zmachine.p` | header validation, frames, the fetch–decode–execute loop, `zmachine_run` | the interpreter loop itself |

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

Three layers, all cheap to run:

1. **Unit** (`tools/tests/test_zmachine.p`, poptest, joins
   `tools/test-libs.sh`): header parsing against a hand-built byte
   string; `signed16`/`unsigned16` edges; ZSCII decode of known words
   and encode/decode round trips; object accessors against a synthesized
   miniature object table; branch-offset decoding of all four forms.
2. **Conformance**: `czech.z5` and `praxix.z5` — the public Z-machine
   test suites — run headless, output diffed against their expected
   transcripts. This is the real correctness gate.
3. **End-to-end golden transcript**: a fixed command sequence fed to
   `Advent.z5`, output diffed against a committed transcript. Catches
   the parser/dictionary/text bugs a conformance suite doesn't.

The notebook front end doubles as a demo *and* a test: an executed
notebook is a transcript that must reproduce.

## 8. Milestones

Each ends in something runnable, and the acceptance test is written
before the milestone starts.

| M | Delivers | Acceptance |
|---|---|---|
| M1 | `zmachine_mem` + `zmachine_text` | load a story file; dump the header; print the abbreviations table and every object's short name |
| M2 | frames, decoder, `zstore`/`zbranch`, ~30 opcodes | run `czech.z5` until it names an unimplemented opcode |
| M3 | full v3 opcode set, dictionary, `read` | **Zork I playable**; golden-transcript test green |
| M4 | v5 additions (EXT ops, extended dictionary, `call_n`) | **`Advent.z5` playable**; conformance suites green in CI |
| M5 | Quetzal save/restore | save, quit, restore, continue — verified against another interpreter's save file |
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

## 10. Decisions needed

1. **v3 first, then v5** *(recommended)*. v3 has the simpler decode and
   Zork I is the icon; v5 follows immediately in M4 because
   `Advent.z5` is the only *shippable* game. Alternative is v5-first,
   which reaches a committable, legally-clean playable game one
   milestone sooner at the cost of a harder first decoder.
2. **Story files**: confirm the repo ships only `Advent.z5` + the test
   suites, and that Zork I stays user-supplied (`zplay ~/zork1.z3`).
3. **Where the notebook front end lands** — `examples/notebooks/` beside
   the TEACH gallery, or its own `examples/games/` page.

Nothing here needs an external account or any hosting decision; those
start at rung 3 of the hosting ladder in the companion brief.
