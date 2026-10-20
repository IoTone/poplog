# langpop — a knowledge graph of a language, and a teacher who uses it

A language tutor whose knowledge is a Prolog graph and whose student
record is a Pop-11 overlay. Two languages are built together from the
start: **Japanese** for a Western learner and **English** for a Japanese
test-taker. Both begin at a level below the bottom of the official
ladder, because that is where learners actually begin.

Two programs, from the [design](https://claude.ai/code/artifact/7c9aa285-6747-4ec8-927a-a25c94f89919)'s
first two proposals:

**A — one heap, three languages.** `langpop.p`: the graph is Prolog, the
overlay and the TUI are Pop-11, and nothing leaves the process. No
server, no model, no network. When A is wrong it is wrong in one address
space, which is why it was built first.

**B — one protocol is the door.** `server.p` + `client.p`: the same
engine, unchanged, behind JSON-RPC. The TUI becomes a client with no
privileges a phone app would not have.

```sh
# A: the whole thing in one process
./poplog basepop11 examples/langpop/langpop.p                   # Japanese, with Aoi
./poplog basepop11 examples/langpop/langpop.p --lang en          # English, with Mr Hill
./poplog basepop11 examples/langpop/langpop.p --check            # integrity-check the graph

# B: the same session, over a protocol
./poplog basepop11 examples/langpop/server.p --port 7801 &
./poplog basepop11 examples/langpop/client.p --port 7801 --user bob

tools/test-libs.sh examples/langpop/tests/test_langpop.p \
                   examples/langpop/tests/test_langpop_server.p   # 55 + 63 checks
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
| `graph/en/a1.pl` | 100 A1 words with Japanese glosses, hand-written | 100 |
| `graph/ja/picks/n5.pl` | which words are N5, by upstream key — the curation | 148 picks |
| `graph/*/generated/*.pl` | imported content, a build product, never committed | 251 + 100 |
| `viewer/page.html` | the curator's view of all of it, filled by `dump.p` | — |

270 committed items, 521 once the content is built; 12 ladder levels,
17 exit criteria, no integrity violations either way.

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
`estimate(community)`, `ets(cefr_mapping)`, `jmdict('1302680')`,
`kanjidic2(ucs('65e5'), jlpt(4))`. `--check` fails any item whose source
is `unknown`.

## Filling a level from upstream

The graph above had **one rung**. All 170 items sat at pre-school while
both ladders declared exit criteria — `kanji(100)`, `vocabulary(800)`,
four reading-coverage criteria — that nothing in the graph could satisfy.
A student who finished pre-school walked off the end of it.

`import.p` fills the rungs from upstream reference data. Two things make
that safe to do, and they are the whole design.

**The repo holds curation, never content.** JMdict and KANJIDIC2 are CC
BY-SA 4.0 (EDRDG). Share-alike is fine for a dictionary and poison for a
tutor, which is exactly why the project's decision was *importer in the
tree, decks never*. So what the importer emits is a **build product**:
`graph/<lang>/generated/` is gitignored, regenerated on demand, and
carries upstream's notice in its own header. What *is* committed is
`graph/<lang>/picks/*.pl` — which entries, at which level, under which
identity — because that is the teaching judgment, and it is ours.

**An identity is never generated.** An item is its identity and not its
spelling, so an id minted from upstream would change when upstream
renumbered, and every belief a student had recorded against it would
quietly detach. Word ids are written by the curator. The one exception is
a kanji, whose id is `k_<codepoint>` — and a codepoint is not upstream's
opinion, which is the same argument `tools/mkkana.py` makes for
generating the kana table rather than typing it.

The two sources need different treatment, because they differ in what
they know:

```
tools/fetch-upstream.sh ~/langpop-upstream

# KANJIDIC2 carries the level, so the selection is a RULE
./poplog basepop11 examples/langpop/import.p --source kanjidic \
    --file ~/langpop-upstream/kanjidic2.xml --level n5 --jlpt 4

# JMdict does not, so the selection is a PICK LIST
./poplog basepop11 examples/langpop/import.p --source jmdict \
    --file ~/langpop-upstream/JMdict_e --picks graph/ja/picks/n5.pl
```

KANJIDIC2's `<jlpt>` is the **pre-2010** four-level JLPT, and old level 4
is exactly what became N5 — official and exact at this end of the ladder,
unlike old level 3, which split into N4 and N3 with no clean answer. So
N5's kanji come from upstream wholesale: 103 of them, against the
ladder's `kanji(100)`, which is as close as a withdrawn syllabus gets.
N4's cannot, and the importer is not asked to pretend otherwise.

JMdict has no level marking at all, so a pick names an entry one of three
ways:

```prolog
pick(w_neko,  ja, n5, word, jmdict_kana('ねこ')).
pick(w_yomu,  ja, n5, word, jmdict_kanji('読む')).
pick(w_yama,  ja, n5, word, jmdict('1302680')).
```

The first two are what a person can write; the third is the escape hatch,
and it is needed more often than it looks. **An ambiguous key is an error
with the candidates listed, never a guess:**

```
AMBIGUOUS w_otoko: jmdict_kanji(男) matches 5 entries --
    jmdict('1419990')  男  おとこ/おっこ  man, male
    jmdict('2742850')  男/男の子  おのこ  man, boy
    jmdict('2742870')  雄/男/夫/牡  お  male
    jmdict('2742890')  男  なん  son
    jmdict('2843485')  男  だん  masculine noun
    -- say which, with pick(w_otoko, ..., jmdict('NNNNNNN')).
```

28 of the 148 picks came back like that, and the report is what resolved
them. A tutor that silently taught *chopsticks* for a pick meaning
*bridge* would be wrong in a way nothing downstream could detect.

**The importer draws one kind of edge by itself.** A word written with a
kanji the graph already holds requires that kanji — 本 is in 日本, and
that is not an opinion. 73 of the 148 words gained such an edge:

```prolog
item(w_tanjoubi, word, ja, n5, jmdict('1419110')).
form(w_tanjoubi, kanji, '誕生日').
form(w_tanjoubi, hiragana, 'たんじょうび').
gloss(w_tanjoubi, en, 'birthday').
requires(w_tanjoubi, hiragana_all).
requires(w_tanjoubi, k_751f).          % 生
requires(w_tanjoubi, k_65e5).          % 日
```

誕 gets no edge, because it is not an N5 character — the word is then
taught in kana, which is what a learner does before they meet it. What
the importer will *not* invent is teaching order between words, even
though KANJIDIC2 has the radical and stroke data to support a deeper
prerequisite ordering: which radicals come before which kanji is a claim
upstream does not make, and 100 edges nobody chose is not a graph anyone
can reason about. Those few that matter are stated by hand, in the pick
file, as `pick_requires/2`.

**A level with no content and a level that was never built are not the
same thing.** Both have no items, and `ready/4` cannot tell them apart,
so each generated file stamps itself:

```prolog
generated(kanjidic2, ja, n5, 103, '2026-10-20T17:41:56Z').
```

`content_built/2` reads that, and `langpop.p`'s `GRAPH_GENERATED` treats
a missing file as an unbuilt level rather than an error — the one way the
imported manifest differs from the committed one. Every suite passes both
with the content and without it.

What the tutor says afterwards, at N5:

```
David, ja -- level n5
  vocabulary(800): 0 of 800 words mastered (148 in the graph)
  kanji(100): 0 of 100 kanji mastered (103 in the graph)
  0 items ready to teach now
```

`kanji(100)` is measurable for the first time; until there were kanji in
the graph it fell through to the measured branch and reported *0% over 0
answers*, which reads like a student who got everything wrong rather than
a criterion nothing was counting. `148 in the graph` is the honest state
of the curation, stated separately from the student's own count so that a
client cannot report one as the other. And **0 ready** is correct: every
imported item requires `hiragana_all`, so the ladder is refusing to start
N5 before pre-school.

### Three import modes, because the sources differ in what they know

| Source | Licence | Knows | So the selection is |
| --- | --- | --- | --- |
| KANJIDIC2 | CC BY-SA 4.0 | the JLPT level of a character | a **rule** — `--jlpt 4` |
| JMdict | CC BY-SA 4.0 | readings and meanings, no level | a **pick list** |
| CMUdict | 2-clause BSD | how an English word is pronounced | **nothing** — it enriches |

The third is a different kind of import. It creates no items at all: it
adds a pronunciation, and the prerequisite edges that pronunciation
implies, to English words a committed graph file already declared.

```sh
./poplog basepop11 examples/langpop/import.p --source cmudict \
    --file ~/langpop-upstream/cmudict.dict --lang en --level a1
```

**The sound contrast an English word exercises is derivable from how it
is said.** This is the kanji edge again — 本 is in 日本, so a student who
cannot read 本 cannot read 日本 — applied to sounds instead of characters.
`library` has an R and an L in it, so it *is* the /r/–/l/ exercise, and
that is a fact about the word rather than an opinion about teaching:

```prolog
form(e_world, ipa, '/wɜrld/').
requires(e_world, s_r_l).

form(e_street, ipa, '/strit/').
requires(e_street, s_cluster).

form(e_mother, ipa, '/mˈʌðər/').
requires(e_mother, s_th_v).
```

The rules are **selective, and that was measured rather than guessed.** A
rule for `s_final` — "ends in a consonant", the contrast about not adding
a vowel after it — is true of 67 of these 100 words, and an edge two
items in three carry tells a reader nothing and a planner nothing either.
It is left out, with `s_stress` (which needs the stress-shifting *pair*,
and one CMUdict entry cannot show one) and `s_rhythm` (a property of a
sentence). What remains fires on 2% to 14% of the list. The minimal-pair
rules want *both* phonemes present, since a word with an R and no L is
not the r/l exercise, just a word with an R in it — and `ER` counts as
carrying the R, because it is a rhotic vowel and `world` is one of the
hardest words on the list for a Japanese speaker.

The importer then reports what the list is missing, which is the question
a curator filling a level actually has — and distinguishes the two
answers, because one is fixable by curation and the other is not:

```
contrasts exercised at a1: 7 of 12
  no word at a1 exercises these -- a gap in the word list:
    s_v_b  vote and boat
    s_f_h  food and hood
  not derivable from a pronunciation, so never emitted:
    s_final  need, not need-o
    s_stress  PREsent and preSENT
    s_rhythm  stress-timed, not mora-timed
```

### Why English words are committed and Japanese ones are not

The asymmetry is not an inconsistency; it is what the sources know.
JMdict can be read **backwards** — find the entries whose English gloss
is `water`, take their Japanese headwords — and that was the obvious way
to get the Japanese glosses for free. It was measured before it was
built, and it does not work:

| English | what the reverse lookup returns |
| --- | --- |
| water | 水分, お水, ウォーター — and never 水 |
| think | シンク, the katakana loanword |
| mountain | ベルグ, マウンテン, 山 — the first is German |
| very | 迚も, an archaic spelling |
| remember | 銘記 |

Filtering to JMdict's priority-tagged entries and dropping the
katakana-only ones cleans up the worst of it (`mountain` → 山) and still
leaves `water` → 水分, which means *moisture*. An exact match on a gloss
is not a translation: a bilingual dictionary is organised to explain
Japanese words in English, and read the other way it finds whichever
Japanese word happens to carry the bare English word as a gloss — which
favours archaisms and transliterated loanwords, the latter being exactly
what the pre-school level warns about. Teaching `water` as 水分 is worse
than not glossing it at all.

So the Japanese glosses in `graph/en/a1.pl` are ours, typed by hand. No
licence reaches them, nothing upstream has an opinion about which English
words are A1, and the importer's job for English is the one thing no
person should type a hundred times: the pronunciation.

## Seeing the graph

The tutor reads the graph one item at a time, chosen for one student. That
is the right view for teaching and the wrong one for **curating**:
`check(graph)` catches the seven things that are wrong by definition, and
everything else is a judgment, which needs to see the thing. A
prerequisite edge pointing somewhere silly looks exactly like one that
does not.

`dump.p` is the reader. It starts no session, registers no student and
records no evidence, so what it shows is the shape of the graph and
nobody's progress:

```
./poplog basepop11 examples/langpop/dump.p --html --out /tmp/graph.html
./poplog basepop11 examples/langpop/dump.p                 # JSON on stdout
./poplog basepop11 examples/langpop/dump.p --dot | dot -Tsvg -o graph.svg
./poplog basepop11 examples/langpop/dump.p --text          # a report
./poplog basepop11 examples/langpop/dump.p --lang ja       # one language
```

`--html` is the one to reach for: it inlines the dump into
`viewer/page.html` and writes **one file** that opens by double-clicking
it. That is not a convenience — a browser refuses `fetch()` of a sibling
file under `file://`, so a viewer that loaded its data separately would
need a web server before it showed anybody anything. `viewer/page.html`
is deliberately a fragment with an embed marker in it, so the standalone
file and the shared copy are the same page rather than two that drift.

The page lays the DAG out in **prerequisite order** — one row per
topological layer, earliest first, which is the order a teacher has to
follow — and shows one item's three relations at a time: what must come
first, what it unlocks, and what it is confused with. Confusable pairs are
drawn always and in a different colour from prerequisites, because the two
edge kinds mean opposite things (*teach after* versus *do not teach
together*) and a viewer that drew them alike would be worse than none.

Two things the exporter needed that the tutor did not:

- **`edges/0` in `schema.pl`.** `index/0` collects every relation except
  `requires/2`, because `ready/4` only ever asks the one-level question and
  the overlay would otherwise carry 423 pairs nothing reads. The exporters
  ask for them once.
- **`--lang` drops an edge unless both ends survive the filter.** The
  English katakana traps are confusable *with* Japanese kana, so narrowing
  to `en` has to drop those pairs rather than half-emit them and leave the
  viewer with arrows into nothing.

`tests/test_langpop_dump.p` reads the output back rather than the source:
52 checks over the parsed JSON, the DOT and the standalone page. Three of
them compare **bytes**, because a mangled encoding parses perfectly and
comes out wrong — a JSON round trip cannot tell あ from mojibake, and the
glyphs are the content.

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

## Three things this found in the tree, and what came of them

Building the thing is what turned these up, and none of them is langpop's
to carry.

**No font was loaded by either ImGui backend** — so `gfx_text` took UTF-8
and drew Japanese as blank space, with no error. Both backends went
`CreateContext()` → renderer init, leaving ImGui's built-in ASCII atlas in
place. **Fixed**: `pop/extern/lib/imgui_font.cpp` loads a CJK-capable face
(`tools/fetch-gfx-font.sh` pins Noto Sans JP, SIL OFL 1.1, by commit and
sha256; the OS's own font is the fallback), `gfx_font()` reports which
file, and `make gfx-font-test` asserts both halves without needing a
display. See `docs/bugs/imgui-atlas-ascii-only.md`. Card rendering is no
longer blocked.

**A millisecond wall clock was there all along.** I first wrote
`lp_now_ms()` against `sys_real_time()` — whole seconds — having concluded
from `HELP CLOCK` that nothing finer existed. `REF TIMES` has
`sys_microtime()`, which is microseconds of real time, and HELP CLOCK
simply never mentioned it. **Fixed** in the help file, with three checks
in `test_datetime.p` holding the real-vs-CPU distinction down; langpop now
uses it, and the latency criteria mean what they say.

**Twelve words were honoured as interactive commands while a file was
being consulted.** `source/2` as a provenance relation made the graph fail
to load with an error naming a goal the file does not contain; `help(a).`
tries to open a HELP file. **Fixed** in `pop/plog/src/prolog_compile.p`,
with the first test suite for the Prolog subsystem in this fork
(`tools/tests/test_prolog_consult.p`). See
`docs/bugs/prolog-commands-swallow-clauses.md`. The relation here is still
called `provenance/2`, which reads better anyway.

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

### And one that was a bug, now fixed

Twelve words used to be honoured as **interactive commands while a file
was being consulted**, not just at the Prolog prompt: `ved help teach ref
showlib im source cd pwd pop11 bye` (`pop/plog/src/commands.p`). A data
file containing `help(a).` did not define `help/1` — it tried to open a
HELP file and said `;;; HELP (A). not found`, with no hint that a clause
had been swallowed. That is fixed in `pop/plog/src/prolog_compile.p`
(commands now apply only in query mode, i.e. at the prompt), with
`tools/tests/test_prolog_consult.p` to keep it fixed.

## And four more the importer found

Three where Pop-11 does something reasonable that is not what the code
asked for, and one where Poplog Prolog quietly discards a clause. In
every case nothing warns.

**A property compares its keys with `==`.** So two equal strings are two
different keys:

```pop11
lvars p = newproperty([], 8, [], "perm"), a = 'yama';
[x] -> p(a);
p(consstring(`y`,`a`,`m`,`a`,4)) =>      ;;; ** []
```

The importer keyed 148 wanted headwords by string and every single lookup
missed, which read back as *matches no entry* for all 148 picks — a
plausible-looking result, since a missing word is exactly what a bad key
produces. Words are interned, so the fix is `consword`; the entry side
then needs a cheap pre-filter (`imp_sig`, the length and first byte) so
that interning 148 keys does not mean interning three quarters of a
million headwords to find them.

This is the same shape as the `false`-dropping defect in `lib jsonrpc`:
a property doing something sensible that the caller did not mean.

**`printf` has no hex conversion.** `REF * PRINT` lists `p P s S c M` and
`%%`, then says of `b`, `d`, `i` and `x` that they are "reserved for
system use". `%x` duly prints the raw **tagged machine word**:

```pop11
sprintf('%x', [16:5C71]) =>      ;;; ** '00000000000171C7'   (23665*4+3)
```

Every kanji id is minted from a codepoint, so this produced 103 items
named `k_00000000000171c7` and not one of the word-to-kanji edges
matched. It also means `dump.p`'s JSON escape for a control character
was emitting `\u00000000000000a9` for a newline — invalid JSON, latent
since nothing in the graph has a control character in it. Both now use a
hex formatter written out longhand.

**`==` on two string literals is `false`.** The emitter decided which
source name to stamp with `srcname == 'JMdict'`, which is never true, so
the words file announced itself as `generated(kanjidic2, ...)`. The same
mistake as the first one, one layer up.

**And one that cost data.** Standard Prolog escapes a quote inside a
quoted atom by doubling it. Poplog Prolog does not accept that:

```prolog
d1('doubled''quote').     % FOUND : 'quote'  -- the clause is DROPPED
d2('backslash\'quote').   % ok
```

A syntax error in a consulted file is **not fatal** — Prolog reports it,
skips that clause and carries on — so the first import emitted three
glosses containing an apostrophe that silently never reached the graph,
and `--check` still said *no violations*, because no integrity rule says
an item must have a gloss. The error does print, in a line of loading
noise, among several hundred others.

Two things came out of that. The escape is a backslash now; and the
importer **reads back what it wrote** (`imp_verify`), comparing what the
emitter meant to emit against what the graph actually holds, so any
emission bug by this route is loud:

```
LOST w_byouin: gloss missing or wrong
;;; MISHAP - import: facts written but not in the graph (quoting? syntax?)
```

The test that should have caught it was asserting the *shape* of
`imp_atom`'s output — and passing, because it asserted the standard's
doubled quote, which is wrong here. The checks now round-trip the atom
through `prolog_compile` and ask the real consumer, including one that
asserts the doubled form would **not** have survived.

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

## B: one protocol is the door

`server.p` serves ten methods over JSON-RPC with line framing — one JSON
value per line, which is what MCP uses over stdio, so an MCP host can
speak to it with no shim. `--port N` for TCP, nothing for stdio.

| Method | |
| --- | --- |
| `langpop/register` | a student, by username; no password, because this is a local tool |
| `langpop/session.open` / `session.close` | a session is a row, not a process |
| `langpop/plan` | what is ready now, and why that order |
| `langpop/next` | the question — **and not its answer** |
| `langpop/answer` | the judging, which stays on this side |
| `langpop/explain` | the derivation: prerequisites, provenance, belief |
| `langpop/status` | the level's exit criteria, measured |
| `langpop/assign` / `report` | work to do elsewhere, and what came of it |

Three things are deliberately on the server's side of the line, and each
one is a property the design would lose if it moved:

**The answer never leaves.** `langpop/next` returns the prompt; the
client cannot tell whether what the student typed was right until
`langpop/answer` says so. A protocol that hands over the answer key is a
quiz file, not a tutor, and no later check of it means anything.

**The clock is the server's.** `langpop/next` starts it, `langpop/answer`
stops it. Every pre-school exit criterion has a millisecond budget, and a
client that could send `latency_ms: 1` would make the speed half of each
one worthless. The reply says which clock was used
(`latency_source: "server"`), and the client's own figure is a fallback
for a caller that never asked a question — a batch import, a test.

**The tier is decided from the evidence, not chosen.** A client reports
`ok` or `17/20`; the server decides that the first is tier 3 and the
second tier 2. Anything else is refused rather than quietly filed as
compliance, because `"18 out of 20"` written without a slash means a
result, and recording it as "I did it" would throw the number away and
cap the item at 0.50 without saying so.

Errors are typed, so a client can tell a mistake it made from a bug in
here: `-32602` invalid params, `-32001` no such session, `-32002` no such
student, `-32003` no such item, `-32004` no such assignment. A mishap
stays a mishap — that is a bug, and `jsonrpc_serve` turns it into
`-32603` for the client while a test still sees it break.

`client.p` is the same session as A to look at, and holds no graph, no
beliefs and no judgment — 288 lines of asking and printing. That is the
only honest test of an API: the reference client has no private door.

The protocol suite drives the handler over a `sys_socket_pair` with both
ends in one process, the idiom `tools/tests/test_jsonrpc.p` uses, so
there are no forks, no ports and no sleeps. 63 checks, including that
`langpop/next` does not leak the answer anywhere in its reply — not just
in a field called `answer`.

## The item as a picture

A terminal can print あ. It cannot print あ at 150 points with its reading
in furigana position above it, which is the one view that teaches a glyph
rather than naming it. So `langpop/card.render` is a **method**, not a TUI
feature: the TUI shells out to `open(1)` like anybody else, and a
non-Pop-11 caller gets the identical picture by the identical route.

```
:card hi_a                                   # the TUI, either front end
{"method":"langpop/card.render","params":{"item":"w_neko"}}
  -> {"item":"w_neko","style":"word","path":"…/cards/w_neko-word.svg",
      "width":640,"height":400,"format":"svg"}
```

**V1 renders SVG, and the design said raster.** That is a deliberate
departure. The design specified `gfx_text` over a Noto Sans JP atlas drawn
headless — but no headless path exists that Pop-11 can drive:
`tools/validate-gfx-headless.sh` runs a standalone C++ harness
(`pop/extern/lib/imgui_headless.cpp`) that draws one hard-coded scene, and
the Pop-11 `gfx_*` surface needs `pop_gfx_init`, which opens a window.
Turning that into a renderer langpop can call means new C exports, a build
flag and a PPM-to-PNG step, on Linux only — a graphics-backend change, not
a langpop change.

SVG keeps every property `card.render` was asked for and costs none of
that. The text is drawn from the font, by the viewer, named as a family
rather than rasterised here; the output is **deterministic and diffable in
CI**, which a GPU rasterisation is not; it opens on all four platforms
with no graphics build; and it carries its own provenance line. The
design's rule survives intact: *if the output contains text the student is
asked to read, it came from the font.*

What SVG genuinely cannot do is the other two styles — stroke order wants
line drawing frame by frame. Those answer with `-32005`, a code of their
own, so a client can tell "that does not exist yet" from "you asked
wrongly".

### What goes on the card

The term is the form the student has to recognise, and the line above it
is whatever helps them get there. Which form that is depends on the item,
and the four kinds in the graph want four different answers:

| Item | Term | Above it |
| --- | --- | --- |
| kana grapheme `hi_a` | あ | `a` |
| starter word `w_gakkou` | がっこう | `gakkou` |
| loanword trap `t_mansion` | マンション | `manshon` |
| sound contrast `s_r_l` | `/r/ - /l/` | ラ行では区別されない |

The last one is the interesting case. A sound contrast has an IPA form and
nothing else, so the IPA *is* the term — and the line above it is the
**Japanese** gloss, because the learner reads Japanese and the point of
the card is the distinction their own language does not make.

Three details that are not decoration:

- **The term shrinks to fit.** マンション at the full 150pt is half again
  as wide as the card. The width is estimated from two classes (a CJK or
  kana glyph is one em square by design; Latin in this face averages a
  little over half that), and the fitted size is floored, not rounded —
  rounding up is how a fitted term still overflows by a point or two.
- **A gloss that only repeats the reading is dropped.** A kana grapheme's
  English gloss *is* its romaji, so printing both puts `a` on the card
  twice and says nothing the second time.
- **Each font family is quoted.** An unquoted multi-word family name is
  not valid CSS; a strict renderer drops the whole list and the kana come
  out as boxes.

### Why determinism was the point

`tests/test_langpop_card.p` renders the same item twice and compares the
bytes. That check is the whole argument for this approach: a rendering
regression becomes a failing diff rather than something somebody notices
months later. 43 checks over the term rule, the SVG, the escaping, the
fitting and the refusals.

The path in the reply is on the **server's** filesystem. Where client and
server share one — every run of the pair today — the client opens the file
it was handed. Where they do not, the path is still the honest answer: the
client says where it is rather than pretending, and a remote client that
wants the bytes needs a method that sends them, which `card.render`
deliberately is not. A card is a file on disk, cached by item; putting it
down a JSON-RPC line would make every call pay for it.

## What A deliberately does not have

No model, no speech, no rendering, no generated content, no DCG, no
kanji, no spaced repetition. Judging is exact match on a string, which is
the correct amount of cleverness for a level where the right answer *is*
a string. (A had no server either; B is that gap closed.) Proposal C — a
model that may classify and rank but never assert into the graph — stays
behind a flag until B has been used in anger.

What building B cost, which is the useful number: the engine needed three
changes, and two of them were bugs A had and nobody had noticed.
Assignments were written to the profile and never read back, so a student
who was given work on Monday was told "No assignment 1." on Tuesday —
which is the entire assignment model, broken in the one place a local TUI
never looks. `lp_measure` returned Pop-11 ratios rather than floats, which
compare equal to the float they denote (so the tests passed) and cannot be
serialised at all. The third was a data-dir override, so the suite can
write profiles somewhere other than a real person's home.
