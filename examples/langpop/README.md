# langpop — a knowledge graph of a language, and a teacher who uses it

A language tutor whose knowledge is a Prolog graph and whose student
record is a Pop-11 overlay. Two languages are built together from the
start: **Japanese** for a Western learner and **English** for a Japanese
test-taker. Both begin at a level below the bottom of the official
ladder, because that is where learners actually begin.

This is **Proposal A** of the [design](https://claude.ai/code/artifact/7c9aa285-6747-4ec8-927a-a25c94f89919):
one heap, three languages. The graph is Prolog, the overlay and the TUI
are Pop-11, and nothing leaves the process — no server, no model, no
network. Proposal B puts the same engine behind one protocol; the point
of building A first is that when it is wrong, it is wrong in one address
space.

```sh
./poplog basepop11 examples/langpop/langpop.p                   # Japanese, with Aoi
./poplog basepop11 examples/langpop/langpop.p --lang en          # English, with Mr Hill
./poplog basepop11 examples/langpop/langpop.p --check            # integrity-check the graph
tools/test-libs.sh examples/langpop/tests/test_langpop.p         # 46 checks
```

A session, in full:

```
はじめまして。I am Aoi, and I will be your teacher.
Bob White, then.  We begin at preschool.

Aoi>                          <- empty line: the next thing to learn
  あ    ->  a
  そうです。

Aoi>
  い    ->  o
  Close. Look again at the shape.  That is お -- the two are confused constantly.

Aoi> :why hi_ka
  か  (grapheme, preschool, own(kana))
    ka
    missing(hi_a)  missing(hi_i)  missing(hi_u)  missing(hi_e)  missing(hi_o)
    belief 0.0 on channel read (mastery is 0.8)
```

## What is in the graph

`graph/schema.pl` states every relation the graph may contain, and
nothing else is allowed in a graph file. An item's identity is a flat
atom and **never its spelling**: `hi_a` is the item, `あ` is one of its
forms, `a` is another. That one decision is what lets the same engine
teach a syllabary, a sound contrast and a sentence pattern.

| File | Holds | Facts |
| --- | --- | --- |
| `graph/schema.pl` | the relations, the teaching rule, the integrity checks | — |
| `graph/ja/ladder.pl` | pre-school → N5 → N1, with exit criteria | 6 levels |
| `graph/ja/kana.pl` | both syllabaries, confusable pairs, mora skills | 92 kana |
| `graph/ja/items.pl` | 40 starter words, kana-only, 3 patterns | 43 |
| `graph/en/ladder.pl` | pre-school → A1 → C1, CEFR bands and section floors | 6 levels |
| `graph/en/items.pl` | 12 sound contrasts, 12 loanword traps | 27 |
| `graph/resources.pl` | the catalogue: URLs and check dates, never content | 9 |

170 items, 12 ladder levels, 17 exit criteria, no integrity violations.

Four things make it a graph rather than a table with arrows drawn on it:

**The prerequisite DAG is explicit and does the teaching.** The whole of
the tutor's choice of what to teach next is one clause:

```prolog
ready(S, Lang, Level, I) :-
    item(I, _, Lang, Level, _),
    \+ lp_known(S, I),
    all_hold(requires(I, Pre), lp_known(S, Pre)).
```

**Forms are derived, not enumerated.** 92 `kana/5` facts produce 92
items and 184 forms; the katakana-after-hiragana edges and the
vowels-first edges are rules, not data. A glyph can only be wrong in one
place — and the kana table is generated from Unicode codepoints
(`tools/mkkana.py`), so it is not wrong at all.

**Uncertainty lives in the overlay, not the graph.** A belief is a number
between 0 and 1 per item per channel, in Pop-11, where it can change
every turn. The graph holds no student state.

**Every fact carries its provenance.** `own(kana)`, `own(starter_list)`,
`estimate(community)`, `ets(cefr_mapping)`. `--check` fails any item
whose source is `unknown`.

## The boundary: Pop-11 procedures *are* Prolog predicates

The one idea the whole thing rests on. `lp_known/2` is a Pop-11
procedure defined with `define :prolog`, and `ready/4` above calls it as
if it were a table of facts:

```pop11
define :prolog lp_known/2(s, i, contn);
    lvars s, i, contn;
    if lp_mastered(prolog_deref(i)) then chain(contn) endif;
enddefine;
```

Succeeding means calling the continuation. So the prerequisite rule
consults evidence recorded seconds ago, in a property table, without
knowing that it is not consulting a database. The same trick carries the
graph *out* to Pop-11: `lp_take/1` collects solutions from a
failure-driven loop, and every query in `langpop.p` is a term built with
`prolog_maketerm` — no query strings anywhere.

This is the pattern `examples/robotarmy/chainnet.p` uses to make Prolog
backtrack across a network. Here it makes Prolog backtrack across a
*belief*.

## Evidence has tiers, and the arithmetic enforces them

The tutor assigns work it cannot watch, and the student reports back.
Three kinds of evidence, three ceilings, set in one place in
`langpop.p`:

| Tier | What it is | Ceiling |
| --- | --- | --- |
| 1 | verified here — we saw the answer and timed it | mastery (0.80) |
| 2 | a reported result — "17 out of 20" | 0.78 |
| 3 | reported compliance — "I did it" | 0.50 |

So **compliance cannot reach mastery by arithmetic**, not by good
intentions: twenty "I did it"s leave an item below 0.5, and the suite
asserts it. A reported result carries an item to just below mastery, so
one verified check here is always what settles it. Only tier-1 evidence
is measured against a level's exit criteria.

Accuracy and speed are reported separately and never averaged. A student
who is right slowly has not learned to read a syllabary — recognition is
the thing being taught, and the clock is the only way to tell the two
apart.

## Two pre-schools, which are the same problem twice

**Japanese.** N5 is not a starting point: it assumes hiragana, some
katakana and several hundred words. A learner with none of that is not a
beginner at N5, they are below the ladder. So pre-school is index 0, and
it teaches the two syllabaries, the pairs beginners actually confuse
(`あ/お`, `シ/ツ`, `ね/れ/わ`), and mora — because a student who reads
every kana and still hears きって as two beats has not finished.

**English.** A Japanese speaker starts with several thousand words
already half-known, in katakana, and some of them are *wrong*. Those are
not vocabulary to learn but vocabulary to **unlearn**, which is a
different exercise and gets its own items: `マンション` is not a
mansion, `サービス` is not a service, `クレーム` is not a claim. The same
katakana layer that makes English easier to read makes it harder to hear
and harder to use, and that asymmetry is the whole reason the level
exists. Beside it sit the twelve contrasts Japanese does not make.

## The teacher is a data file

`personas/aoi.json` and `personas/hill.json` hold a name, a gender, a
register and the lines. Nothing about a teacher is in the code, because
what a teacher says is content and a native speaker should review it.
Lines cycle round-robin — which is Weizenbaum's reassembly rule, and for
once exactly the right mechanism.

The student is whoever is at the keyboard, keyed by a username, with no
password: this is a local tool and a password would be theatre. The
teacher is allowed to *mis*remember:

```
Ah -- Bob White?  (y/n) n
My mistake.  And your name?  Bob Smith
```

The correction is kept in the profile, and that wrong guess is never
made again. Offering the nearest name and being corrected is how a
person recognises somebody; a lookup that is either right or empty is
not memory.

## Two gaps found in the tree while building this

Both are real, both are bounded, and neither is langpop's to fix alone.

**No font is loaded by either ImGui backend.** `pop/extern/lib/imgui_backend.mm`
and `imgui_backend_sdl.cpp` both use ImGui's built-in atlas, which is
ASCII. UTF-8 strings are accepted, but a glyph that is not in the atlas
does not appear, so `gfx_text` would draw Japanese as blanks today. The
fix is to load a Japanese range at `gfx_init` with a licence-clean face
(Noto Sans JP, SIL OFL 1.1), fetched at build time the way
`tools/fetch-imgui.sh` fetches ImGui. Card rendering waits on that.

**There is no wall-clock millisecond timer.** `systime()` is CPU time —
it barely moves while we wait for a human — and `sys_real_time()` is
whole seconds. Latency is load-bearing here (every pre-school exit
criterion has a millisecond budget), so for now it is measured in
seconds and stored in milliseconds, and every latency the engine records
passes through `lp_now_ms()`. A `clock_gettime` shim on the
popcrypto/popsqlite pattern would be a few dozen lines, and that one
procedure is all that changes.

## Four Poplog Prolog behaviours worth knowing

**`prolog_compile` has reconsult semantics per predicate.** A second file
that defines `item/5` silently replaces the clauses the first one gave
it, and `:- dynamic` does not change that. A seven-file graph loaded
file-by-file therefore ends up holding only the last file's items — with
no error. So `lp_load()` concatenates the manifest and compiles once.

**There is no `forall/2`** — not in `pop/plog/lib/`, not in any help
file. `schema.pl` states the idiom once as `all_hold/2`:

```prolog
all_hold(Cond, Action) :- \+ (Cond, \+ Action).
```

**A call to an undefined predicate fails** rather than raising, which is
how the missing `forall/2` hid: the rule using it simply never succeeded,
and a level with nothing ready in it looks like a data problem. This one
is *configurable* and the default is the trap, so `schema.pl` now opens
with the two lines that turn it off:

```prolog
:- library(unknown).
:- unknown(_, error).
```

See `PLOGHELP UNKNOWN` — `fail` (the default), `error`, `autoload`,
`debug`. Every graph file is loaded together, so nothing in this graph is
legitimately undefined, and a misspelled predicate now raises.

**A cycle check needs a visited list.** Without one, a two-item cycle has
infinitely many proofs and the check exhausts `pop_prolog_lim` instead of
reporting the cycle — so `reaches/2` carries the path it has walked.

### And one that is a bug, not a behaviour

Twelve words are honoured as **interactive commands while a file is being
consulted**, not just at the Prolog prompt: `ved help teach ref showlib im
source cd pwd pop11 bye` (`pop/plog/src/commands.p`). A data file
containing

```prolog
help(a).
```

does not define `help/1`. It tries to open a HELP file, and says
`;;; HELP (A). not found - try HELP HELPFILES` — with no hint that a
clause was swallowed. `langpop` hit this with `source/2` as a provenance
relation and renamed it to `provenance/2`; `help/1` is a name a tutoring
system reaches for naturally, so this will bite again.

## Commands

| | |
| --- | --- |
| *empty line* | the next thing to learn — weakest belief first, then least asked |
| `:plan` | what is ready now |
| `:why <item>` | the derivation: prerequisites, source, belief |
| `:status` | this level's exit criteria, measured |
| `:assign` | something to do away from the keyboard |
| `:report <n> ok` | done it (tier 3) |
| `:report <n> 17/20` | done it, with a result (tier 2) |
| `:level <name>` | move the goal |
| `:quit` | save and stop |

Profiles live in `~/.langpop/`: one JSON file per student, plus
`roll.json`, which is what lets the teacher recognise — and
misrecognise — somebody.

## What A deliberately does not have

No server, no API, no model, no speech, no rendering, no generated
content, no DCG, no kanji, no spaced repetition. Judging is exact match
on a string, which is the correct amount of cleverness for a level where
the right answer *is* a string. Everything else is Proposal B onwards,
and the thing to learn from A is which of those we actually miss.
