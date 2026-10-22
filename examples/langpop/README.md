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
./poplog basepop11 examples/langpop/langpop.p --audit            # which rungs can be climbed
./poplog basepop11 examples/langpop/langpop.p --chart hiragana   # a page to print
./poplog basepop11 examples/langpop/langpop.p --zine --user bob  # a booklet to fold
./poplog basepop11 examples/langpop/langpop.p --audio preschool  # make the sound files
./poplog basepop11 examples/langpop/langpop.p --audio preschool --rate slow

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
| `graph/ja/kana.pl` | both syllabaries, voiced included, confusable pairs, mora skills | 138 kana |
| `graph/ja/items.pl` | 50 starter words, kana-only, 3 patterns | 53 |
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

**Forms are derived, not enumerated.** 138 `kana/5` facts produce 138
items and 276 forms; the katakana-after-hiragana edges, the vowels-first
edges, が-after-か and the か/が confusable pairs are rules, not data. A glyph can only be wrong in one
place — and the kana table is generated from Unicode codepoints
(`tools/mkkana.py`), so it is not wrong at all.

**Uncertainty lives in the overlay, not the graph.** A belief is a number
between 0 and 1 per item per channel, in Pop-11, where it can change
every turn. The graph holds no student state.

**A word is not known because you can read it.** An item is judged on a
list of channels — a character is `[read]`, a word is `[read hear]`, a
sound contrast is `[hear]`, a pattern is `[produce]` — and the exit
criteria name the channel they measure:

```prolog
exit(ja, n5, vocabulary(800, read), 0.80, 4000).
exit(ja, n5, vocabulary(800, hear), 0.80, 4000).
exit(ja, n5, kanji(103, read),      0.80, 4000).
```

This is the one axis that enumerates, so it is the one that gets ground:
a vocabulary count goes up while listening rots, and every JLPT level has
a 聴解 section the count does not touch. The belief store was always per
channel; what was wrong was that **one** channel decided whether a word
was known, which made *can read it* the engine's definition of knowing a
word.

Unlocking and passing stay separate questions. `lp_primary/1` is the
**gate** — the head of the channel list, and what opens the prerequisite
graph — because for reading something built on reading, reading is
enough. If the gate demanded every channel then, with no way to verify
`hear`, nothing would ever unlock and the ladder could not be climbed.
Passing a level is what the exit criteria are for, and they now report
two numbers instead of averaging them into a comfortable one.

**And the tool says what it cannot check.** `hear` is not in
`VERIFIABLE`, because there is no audio anywhere in langpop:

```
vocabulary(50, read): 0 of 50 words mastered (40 in the graph)
vocabulary(50, hear): cannot be checked here -- needs audio (40 in the graph)
```

Reporting *0 of 50* would read as a student who has learned nothing, when
what is true is that nothing here can measure it; `langpop/status`
carries `"verifiable": false` so a client cannot show the tool's limit as
the student's ability. A self-report cannot buy the score either — it is
tier 2, capped below `MASTERY` by arithmetic. The consequence is that
langpop can say *your reading is at N2 and I cannot certify your
listening*, which is true.

That gap is widest exactly where it matters most, and it is written up
rather than left implicit:
[`docs/projects/langpop-pronunciation.md`](../../docs/projects/langpop-pronunciation.md)
— for a Japanese speaker learning English, all twelve sound contrasts are
unprobeable, so `sound_contrasts` can never be mastered and
`exit(en, preschool, sound_contrasts, ...)` can never be met. That chain
was already true; the channel split stopped it being quiet.

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

### Asking about what was imported

The import had a hole in it. `lp_question/1` could only build a probe for
an item carrying a **romaji** form, and the importer emits kanji,
hiragana and katakana forms and no romaji — so every imported Japanese
item returned `shape = "none"`:

```
ja n5 grapheme  103 items, 103 unprobeable
ja n5 word      148 items, 148 unprobeable
```

251 of 521, and it failed silently. No violation, because nothing checked
that an item could be *answered*; the tutor simply said *"nothing here
can be checked by typing."*

The fix is not to emit romaji into the graph. `form(k_5c71, kanji, '山')`
together with `form(k_5c71, hiragana, 'やま')` **already is** a probe —
prompt one, answer the other. What was missing is the ability to accept
that answer typed in Latin letters, which is a fact about the writing
system rather than about any item, so it lives beside the answer checking
and not in the graph.

```
一  ->  ひと          そうです。
山  ->  yama          そうです。
日  ->  nichi         そうです。
電車 -> densya        そうです。
山  ->  kawa          Not yet.  It is やま.
```

An answer is now a **list** of acceptable spellings, head first and
canonical — so `hd(answer)` is what the tutor says when you are wrong,
and that is the kana: *It is やま*, not *It is yama*. Roughly four
spellings per item, from the kana as written, the same folded to
hiragana, and the romaji of each.

The transliteration is Hepburn with two concessions, both of which a
learner will actually type. **A long vowel may be written once** —
がっこう is `gakkou`, and a student who types `gakko` has answered the
question that was asked. **Kunrei is accepted**, because it is what a
Japanese primary school teaches: `tukue`, `densya`, `tosyokan`. The youon
rows are not optional there — a table that only knew `shi → si` rejected
`densya` while accepting nothing, and でんしゃ is the commonest row in the
syllabary.

The youon rule is where a one-liner gets it wrong. Dropping the trailing
`i` and adding the small kana's vowel turns きょ into `ko`; the stem needs
a `y` *unless* it already palatalises. And "ends in h" is not that test:

| | stem | | |
| --- | --- | --- | --- |
| き + ょ | `k` | → `kyo` | needs the y |
| し + ゃ | `sh` | → `sha` | already palatalises |
| ち + ゃ | `ch` | → `cha` | already palatalises |
| ひ + ゃ | `h` | → `hya` | **needs the y** |

Two skills, two strictnesses, and the difference is deliberate. がっこう
at pre-school is a reading-the-*kana* exercise, so `gakko` has skipped the
う and is wrong. The same word met as 学校 at N5 is a reading-the-*kanji*
exercise, where the length of the vowel is not what is being asked.

Not multiple choice, incidentally, even though the confusable pairs would
make good distractors: typing is a stronger probe than picking, there is
no one-in-four guess in it, and accepting romaji means no Japanese input
method is needed — which is the bargain the pre-school kana probe already
strikes.

**26 items remain unprobeable, and that is the right number.** They are
the eight skills (roll-ups over what they require), the three patterns
(produced, not typed) and the fifteen sound contrasts (which need audio —
see the pronunciation note). The suite asserts that shape rather than a
count: *every item that cannot be typed is a skill, a pattern or a
sound*, which is the invariant the original bug broke.

Two displays were wrong for the same stale reason. `lp_any_form/1` and
the card's `TERM_ORDER` both preferred hiragana over kanji — right while
every item was a kana or a kana-only starter word, wrong the moment the
import brought in characters. `:why k_4e00` headed itself ひと rather than
一, and the card for 山 came out as a card reading やま with no reading
line at all. A flashcard for 山 is 山 on the front and やま underneath.

## A typing slip is not a wrong answer

A Japanese learner is typing romaji, or fighting an input method they do
not know well, and a slip of the fingers is not a gap in their
knowledge. Recorded as *wrong* it costs them 0.70 of a belief and
teaches the tutor something false — the probe ends up measuring typing
rather than reading, which is the same validity problem as asking about
grammar in vocabulary the student does not have.

**Offered, not forgiven.** The first near miss on an item is not
recorded at all; the student gets one more go.

```
一    ->   hto
Typing, I think, not reading.  Once more:
一    ->   hito
そうです。
```

Taking `hto` *as* やま would credit an answer they never produced. The
point is to let them fix it, not to score it for them — so what gets
recorded is something they actually typed.

**And nothing is revealed, because the tolerance is proportional with no
floor:**

| answer | length | slips allowed |
| --- | --- | --- |
| `ka` | 2 | **0** |
| `yama` | 4 | 1 |
| `yuubinkyoku` | 11 | 2 |

That zero is the important one. For a two-character answer any edit is a
*different answer* — `ke` is not a slip for `ka`, it is the wrong kana —
so short answers get no tolerance, and with it no hint that they were
close. This is deliberately the opposite of the tolerance used for
recognising a name, where one letter out is always forgiven.

An exact match wins first, and so does a confusable partner: typing the
other half of a pair the graph records is a knowledge error however few
letters apart the two are. The clock runs from the **first** attempt, so
a deliberate slip cannot buy thinking time.

**`:oops`** is for what the detector cannot catch — an input method that
ate the line, enter hit a word early. It takes back the last answer and
puts the question back in the queue, and it restores *every* belief that
answer moved, which is more than one: a correct check also credits
whatever it contained, so undoing it has to undo those too.

```
before:        誕生日=0.0   生=0.0   日=0.0   journal=0
after answer:  誕生日=0.45  生=0.45  日=0.45  journal=3
after :oops    誕生日=0.0   生=0.0   日=0.0   journal=0
```

One answer deep, and only within the session.

On the wire the same thing is a reply rather than a reprompt:
`langpop/answer` returns `"outcome": "slip"` with `"recorded": false`
and an `expected` of `null`, and the client asks again. Sending the same
near miss twice records it — the retry is offered once, not forever.
`{"action": "oops"}` is the button version of `:oops`.

## Putting a question off, and taking an answer back

Spaced-repetition services have worked this out already. WaniKani lets a
student say they mistyped — the answer does not count and the item comes
back later — and lets them skip a question without it counting as a
failure, where it returns in the same session. Both can be **switched
off**, so a student who suspects they are leaning on them can find out.
That is the right shape, and langpop adopts it with two differences.

**The difference from a skip.** langpop already has four outcomes, so it
does not have to guess what a student meant by declining:

| at a question | means | recorded? |
| --- | --- | --- |
| *enter* | "I do not know" | **yes** — `skip`, and it counts in the denominator |
| `later` | "not this one, not now" | no |

Pressing enter is the most informative thing a beginner does: it is what
stops a placement descent, and a student who could raise their accuracy
by answering only what they knew would be measuring the wrong thing. So
it stays recorded. `later` is the other gesture, and it records nothing.

**The gap is what makes `:oops` honest.** Both routes put the item back
in the queue, and neither re-asks it immediately:

```
あ   ->  later
後で。Put it aside -- I will bring it back.
い   ->  i        そうです。
う   ->  u        そうです。
え   ->  e        そうです。
  Back to this one.
あ   ->
```

Three questions, counted in answers actually recorded. `:oops` is used
*after* the tutor has said what the answer was, so asking again straight
away would measure the echo rather than the memory — it would hand a free
correct answer to anything got wrong. (The first version did exactly
that: the deferred item had the lowest belief of anything ready, which is
precisely what `lp_choose` picks, so it came back as the very next
question. Only running it showed that.)

Twice per item, and then it has to be answered. Without a limit, `later`
is a way never to be wrong about anything.

**The switches.** `:aids` lists them; `:aids later off` takes one away.

```
    on  slip   one more go when a typed answer looks mistyped
    on  oops   :oops takes back the answer you just gave
    off later  puts a question off until later today -- type it at a question
```

An aid that cannot be refused is indistinguishable from a lower
standard, and a learner who suspects they are leaning on one has no way
to find out except to take it away. So they are the student's to switch,
not the tutor's.

They are **recorded rather than policed**. Turning one off and on again
around a hard item would otherwise be invisible; instead every change is
logged with its time, every journal entry already carries one, so what
was available at any given answer is reconstructible exactly — at the
cost of one record per change rather than a wider field on every answer.
`:status` names anything switched off, so a number is never read without
knowing which standard produced it.

On the wire: `langpop/aids` reads and sets them, and `langpop/answer`
takes `{"action": "later"}` and `{"action": "oops"}`. `langpop/next`
reports `"requeued": true` when it is handing back something owed, so a
client can say so rather than showing it as a fresh question. The queue
dies with the session, which is what "comes back in the same session"
means; `langpop/session.close` reports how much was still owed.

Both are stored by **name** rather than as a map of booleans — on disk as
`aids_off`, on the wire as `{"off": ["slip"]}` — because an absent JSON
field and a field set to `false` arrive indistinguishable, so a map could
not tell a profile written before an aid existed from one that switched
it off, and reading the first as the second would silently take an aid
away.

## Placement: find out where they are, rather than ask

> *"A teacher will jump right into 'go ahead and introduce yourself.' A
> true beginner will freeze. If they answer properly, the teacher keeps
> going — 'what day is it today?' — until they work out which section
> this person belongs in."*

The point is not the questions. It is that the teacher **starts above**
where they expect and lets failure locate the student, and that a freeze
ends that line of questioning.

`:place` in the TUI, `langpop/placement.next` on the wire.

**Placement is not a teaching mode.** It is a fast way to populate the
belief overlay, and everything downstream already works off beliefs —
`lp_choose` takes the lowest belief first, so a correctly placed student
gets their weak spots immediately and skims what they know. Which means
there is **no placement state anywhere**: `lp_place_next/0` is a pure
function of the evidence already recorded, so a client asks what to ask,
answers it through the ordinary `langpop/answer`, and asks again. A
dropped connection costs the one question in flight.

**One scalar would be the wrong answer.** A learner who knows 500 kanji
and keeps forgetting katakana is not *at* any single level, and placing
them by one number would either drown them or bore them. So the search
runs per **axis**, and the axes are the exit criteria — a ladder that
adds a criterion gets an axis for free. Simulating exactly that learner:

```
kanji              : up to n5           <- knows kanji
vocabulary         : up to preschool    <- thin at N5
recognise katakana : below the ladder   <- froze on シ/ツ, ソ/ン
recognise hiragana : up to preschool
skill mora_sokuon  : nothing here I can ask about

teach at: preschool
```

Twenty questions. And the level is **derived**, not chosen: the lowest
rung that still has an axis the student has not passed. The N5 kanji
they proved they can read sit near mastery in the overlay, so they are
not taught again.

Four things make it cheap, and each one came out of the graph rather
than out of a parameter:

**It samples across a difficulty scale.** Probing 103 kanji one at a
time to find out whether somebody reads kanji is absurd; four spread
along `rank(_, freq, _)` locate them — 日, 上, 話, 聞.

**Where there is no scale, confusable items come first.** A katakana
test made of ア and ヲ certifies everybody. シ against ツ and ソ against
ン is where forgetting actually shows, and the graph already records
which 18 pairs those are.

**A freeze ends an axis**, after two. That is the behaviour the whole
thing is modelled on, so the loop asks **one** question and looks again
— a driver handed a whole batch would keep asking past the freeze.

**Passing high means nothing below gets asked.** Failing drops one rung
and asks again. That is the descent.

One correction worth recording, because it looked right and was not.
`recognise(hiragana)` was first implemented as "every grapheme carrying
a hiragana form" — which pulls in all 103 imported kanji, because a
kanji carries its kun reading as a hiragana form. The schema already
answers this properly through `criterion_item/2`, so the axis asks it
rather than guessing from the forms.

## Can the ladder actually be climbed?

`--check` proves the graph is **consistent**: no cycle, no dangling
prerequisite, every item on a rung that exists. A ladder can pass that
and still be unclimbable, because consistency says nothing about whether
there is enough to learn. `exit(ja, n1, kanji(2230, read), 0.80, 2000)`
is perfectly consistent against 103 kanji. It is simply unreachable, and
nothing said so.

```
./poplog basepop11 examples/langpop/langpop.p --audit
```

```
  34 exit criteria over 12 ladder levels.

  lang  level      criterion                 have  askable  verdict
  ja    preschool  recognise(hiragana)       69    69       ok
  ja    preschool  skill(mora_count)         1     1        thin
  ja    preschool  skill(dakuten)            46    46       ok
  ja    preschool  vocabulary(50, read)      40    40       short by 10
  ja    preschool  vocabulary(50, hear)      40    0        needs_audio
  ja    n5         kanji(103, read)          103   103      ok
  ja    n1         kanji(2230, read)         103   103      short by 2127
  en    preschool  sound_contrasts           12    0        needs_audio
  en    b1         coverage(reading, 0.95)   0     0        unmeasured
```

Six verdicts, because they mean different things to whoever reads them:

| verdict | meaning | whose problem |
| --- | --- | --- |
| `ok` | enough askable content exists to satisfy it | nobody's |
| `thin` | passes on fewer than 3 askable items | the graph's |
| `short` | measurable, content is thin | curation |
| `no probe` | the item set exists and nothing in it can be asked | a bug |
| `needs audio` | the channel is outside `VERIFIABLE` | this build's |
| `unmeasured` | nothing measures it at all | the design's |

Only `short` is allowed to be large. The others are each a claim the
ladder makes and cannot cash.

**`thin` exists because of Goodhart.** A criterion measured over one item
is not a measurement, it is an anecdote, and it passes. Three is the
smallest number that can disagree with itself.

**`needs audio` is distinguished from `no probe` deliberately.** The
first run of this reported `sound_contrasts` as a bug, which is wrong:
the probe is not missing, the microphone is. An item-set criterion whose
every item sits on a channel outside `VERIFIABLE` is the audio limit
([the pronunciation note](../../docs/projects/langpop-pronunciation.md)),
not a defect.

Counts are **cumulative**, because the criteria are: `kanji(2230)` at N1
means every kanji through N1, not 2,230 more of them. So the pool is that
level and below.

`langpop/audit` is the same thing on the wire, with `"short_by"` computed
so a client need not subtract, and `"wanted": null` on a criterion that
is not a count. No session is needed — this is a property of the graph,
not of anybody's progress. A client that draws a ladder wants it: showing
a student `kanji(2230)` as a goal they are 0.05% of the way to, when the
graph holds 103 kanji, reports the tool's emptiness as the student's
failure. That is the same mistake `"verifiable": false` exists to prevent
on `langpop/status`.

### Rung by rung, because a criterion at a time is not enough

`--audit` walks `lp_exits`, so **a rung that declares no criterion
produces no rows** and is invisible in that table. That is how `en/a1`
came to be a room with no door and had to be found by hand — and how
`en/c1` still was, two sections later, in the same file.

```
  lang  level      criteria  can it be left?
  ja    preschool  7         not yet -- needs_audio
  ja    n5         3         not yet -- short
  en    preschool  3         not yet -- needs_audio
  en    b1         3         not yet -- unmeasured
  en    c1         0         NO -- it declares no exit criterion

  0 of 12 rungs can be left as the graph stands.
```

A rung is left by meeting **every** criterion on it, so it is exitable
only if every one is reachable. One criterion nothing can measure closes
the rung as surely as having none. The verdict names the **worst**
blocker, in the order of whose problem it is: no exit is a bug in the
ladder, `unmeasured` is a hole in the design, `short` is curation, and
`needs audio` is a limit of this build that is written down elsewhere.

**Zero of twelve** is the honest number, and it is worth sitting with.
The Japanese pre-school rung passes everything that can be typed and is
held open by one listening criterion; that is the documented state of
this build rather than a defect. The rest are short of content.

`check(graph)` now refuses a rung with no exit criterion outright, so
the next level anyone adds cannot repeat it:

```prolog
violation(level_without_exit(Lang, Level)) :-
    ladder(Lang, _, Level), \+ exit(Lang, Level, _, _, _).
```

### Two holes it found in the English ladder

**B1 declared one criterion**, `coverage(reading, 0.95)` — and nothing
measures coverage, so B1 was the same missing door A1 had, differently
disguised. The counts also jumped **1000 to 5000** with nothing between,
which is two CEFR bands of silence. B1 now carries 2500 reading and 2000
listening, estimates like every other number on that ladder.

**C1 declared nothing at all.** The top rung needs an exit criterion as
much as any other — *what does it mean to have finished?* is the
question a ladder exists to answer, and `ja/n1` answers it. C1 now
carries 8000 reading, 6000 listening and a listening coverage floor.

### What is left, and why

Coverage **was** the last `unmeasured`, and it is measured now — see the
section above. What is left on every rung is content.


### What the first run found

**A skill was measured over itself.** `criterion_item(skill(S), S)`
answered with the skill item, which has no written form and so no probe —
so `skill(dakuten)` was measured over a set of one unaskable thing,
reported *0% right over 0 answers* for ever, and could never be met.
**Three of the five Japanese pre-school criteria were in that state.** A
skill is now measured over what it rolls up over, transitively and
skipping skills on the way down, because `mora_sokuon` requires
`mora_count`, which is itself a skill: one level of expansion would have
swapped one unaskable item for another.

That is the third rung-with-no-door in this project, after `en/a1` having
no exit criterion at all and the twelve sound contrasts returning
`shape = "none"`. The first two were found by hand. Found by hand means
found by luck, which is the argument for the audit existing.

**One `thin` verdict was a criterion measuring the wrong thing, and the
voiced kana are the answer.** `skill(dakuten)` required only `hi_ka`,
and the table held base kana only — so passing it demonstrated reading
か, which says nothing whatever about か/が. The criterion named a
contrast the graph did not contain. See the next section.

Two `thin` verdicts remain, and they are content the audit can only
report: `skill(mora_count)` and `skill(mora_sokuon)` both reduce to あ,
the same single item. And `vocabulary(50, read)` at pre-school is short
by 10 — 40 kana-only starter words against a criterion of 50 — so the
first rung of the Japanese ladder still cannot be exited.

## The voiced kana, and a criterion that named a contrast the graph did not hold

`--audit` said `skill(dakuten)` passed on one item. The skill's gloss is
*か/が, は/ば/ぱ — one mark changes the sound*; it required `hi_ka`, and
the kana table held base kana only. So the criterion was answerable by
reading か — an **unvoiced** kana, the one thing that cannot possibly
demonstrate the contrast the skill is named for. It would have passed,
and it would have meant nothing.

The fix is the glyphs. Dakuten is the base codepoint **+ 1** and
handakuten the base **+ 2**, which is the second systematic thing about
the syllabaries after katakana being hiragana + 0x60 — so these are
generated by `tools/mkkana.py` like the other 92, and a glyph cannot be
subtly wrong.

```prolog
kana(hi_ga, hiragana, 'が', ga, g).
kana(hi_pa, hiragana, 'ぱ', pa, p).

voiced(hi_ga, hi_ka, dakuten).
voiced(hi_pa, hi_ha, handakuten).
```

`voiced/3` is stated once and **both** consequences are derived from it,
which is the same discipline `kana/5` already follows:

```prolog
requires(V, B) :- voiced(V, B, _).
confusable(B, V, mark(Mark)) :- voiced(V, B, Mark).
```

One mark is one new thing to notice, so the base kana is the
prerequisite and nothing else is. And the pair is confusable because one
mark apart is exactly how a beginner misreads it: か for が is not a
wild guess, it is the mark going unseen. So the tutor diagnoses it as
`near` rather than `wrong`, and can offer the partner as a distractor —
which is the whole reason `confusable/3` exists.

**ぢ and づ are deliberately absent, and it is the only judgement in the
table.** They are not a third and fourth sound: they are alternative
spellings of じ and ず, used where a base kana is reduplicated or
compounded (つづく, ちぢむ), and Hepburn spells each pair identically
**because they are the same sound**. Two consequences, and both matter:

- `skill(dakuten)` is *one mark changes the sound*, and these are the one
  place where it does not — so they are not instances of the skill the
  criterion names;
- `kana.pl` joins katakana to hiragana on the **romaji**, so two kana
  spelled `ji` would make ヂ require both じ and ぢ, **and ジ require
  ぢ** — gating a common kana behind a vanishingly rare one. `import.p`
  refuses to guess at an ambiguous JMdict key for exactly this reason;
  so does this.

23 per script, 46 in all. The aggregates fan out by rule
(`requires(hiragana_all, Id) :- kana(Id, hiragana, _, _, _).`), so the
voiced kana joined them with no edit — which closed a gap nobody had
noticed: **がっこう needs が**, and until now the starter words required a
`hiragana_all` that did not contain it.

| | before | after |
| --- | --- | --- |
| `kana/5` facts | 92 | 138 |
| `recognise(hiragana)` | 46 | 69 |
| `skill(dakuten)` | 1 item, `thin` | 46 items, `ok` |
| graph | 521 items | 567 items |


## Something to take off the screen

```
./poplog basepop11 examples/langpop/langpop.p --chart hiragana
./poplog basepop11 examples/langpop/langpop.p --sheet --user bob
```

and `:chart katakana` / `:sheet` inside a session. A4 SVG — `width="210mm"
height="297mm"` with a viewBox in tenths of a millimetre — so a browser's
print lands on real paper rather than on a 96dpi guess.

**Three charts and one record.** `hiragana` and `katakana` are the
syllabary on a page; `youon` is the 33 combinations; `today` is what the
student actually did, which is the only one that needs a student.

### The charts are generated, which is the point and not a convenience

A kana chart downloaded from somewhere is a picture of **somebody else's
table**. It can disagree with ours and nothing would notice, it carries
whatever licence it carries, and it goes stale the moment the graph
changes — as it just did, when 46 voiced kana arrived. A chart drawn from
`kana/5` cannot disagree with the tutor, because it is the same 138 facts
the tutor reads. Same argument `import.p` makes about content: hold the
curation, derive the rest.

**And the grid is derived too.** A cell's **column** is the last vowel
letter of its romaji — `ka`→a, `shi`→i, `tsu`→u, `fu`→u — and its **row**
is the row named in the fact. A hand-placed grid would be a second copy
of the table, free to disagree with the first.

Which is how the sheet tells the truth about the holes:

```
  d    だ          で    ど
       da          de    do
```

Two gaps, because `kana.pl` does not hold ぢ and づ — and the footer says
why rather than leaving a reader to wonder whether the chart is broken. A
hand-placed grid would have quietly filled them in.

The youon sheet derives its 33 combinations the same way: every kana whose
romaji ends in `i`, bar い itself, crossed with small ゃゅょ. The romaji
comes from `lp_romaji`, so the sheet says `sha` and not `shya`, and `ja`
and not `jya`, **because the engine's rule said so** — not because a
second table was typed out and might disagree.

### The day's sheet reads the journal, not the beliefs

```
Today, Sheet Tester                                        2026-10-21

What you worked on
 +  日     day, sun, Japan, counter for days                    900 ms
 +  山     mountain, hill                                      1380 ms
 +  が     ga                                                  1860 ms
 ?  ウ     u                                                   5200 ms
 ~  そ     so                                                  2400 ms
 x  ぬ     nu                                                  3100 ms

Worth another look
ウ カ そ ぬ

Next time
あ  い  う  え  お

+ right  ~ near miss  ? did not know  x wrong.
Drawn from your own answers, on this machine.
```

A sheet of **beliefs** would show the same thing every day with the
numbers slightly different. A sheet of the **journal** shows the session.
One row per item carrying the outcome that stands — an item got wrong and
then got right prints once, and prints right — in the order the questions
were asked, because a record of a session reads forwards even though the
journal is stored most-recent-first.

The four marks are the four outcomes, and `?` is deliberately not `x`:
saying *I do not know* is the most informative thing a beginner does, and
a sheet that crossed it out would be teaching them not to.

`langpop/sheet.render` is the same thing on the wire. It is the only
method that requires a session **conditionally** — a chart is a picture of
the graph and needs none, today's sheet is a picture of one student's
answers and needs one. Refusing a kana chart to someone who has not
logged in would be a privilege check protecting a table anybody can buy
on a poster.


## Coverage, which was the last `unmeasured`

`coverage(reading, 0.95)` is Nation's measure: *the words you know
account for 95% of the words on the page*. It held three English rungs
closed for as long as nothing measured it, and a number invented to fill
that gap would have looked like the others and not been one.

It is arithmetic once the data exists. **Sum what the mastered words
account for; divide by what the corpus accounts for.** No model, no
interpolation, no published table — the definition applied to the data.

```
en  b1  coverage(reading, 0.95)   100   6    short by 89
```

100 words carry a frequency; all of them together reach **6%**; the
criterion wants 95. That is a curation number now, where it used to be a
hole in the design — and the whole graph reports **zero `unmeasured`**
for the first time.

### A rank cannot do this job

`rank/3` says *where* a word sits. `freq/3` says *how much of the text it
is*, and they are not the same thing: `the` and the fifty-thousandth
word are one rank apart from their neighbours and **four orders of
magnitude** apart in how much text they cover. So the count comes across
with the rank, and the corpus total comes across once, and the engine
divides.

```prolog
rank(e_people, opensubtitles_en, 118).
freq(e_people, opensubtitles_en, 885915).
corpus(opensubtitles_en, 50000, 725119374).
```

**The denominator is the whole corpus**, not the words we happen to
teach. Dividing by our own vocabulary would give a figure that only ever
goes up and would read as progress rather than as coverage.

### The licence, which was the actual blocker

[hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords):
*"MIT License for code. CC-by-sa-4.0 for content."*

Two **named** licences partitioning the repository, rather than two
clauses contradicting each other — which is the test NGSL failed, and
the test the zine template failed. CC BY-SA is also the licence family
this project already handles: JMdict and KANJIDIC2 are CC BY-SA 4.0, and
the whole `graph/<lang>/generated/` arrangement exists so share-alike
stays on upstream's layer. The counts derive from OpenSubtitles
(opus.nlpl.eu), which asks for attribution.

**A note on fit, which is in the generated file's header.** OpenSubtitles
is **dialogue**. Its frequency profile is a good basis for
`coverage(listening, _)` and a *proxy* for `coverage(reading, _)`, whose
published thresholds come from written corpora. The scale is named in
every fact — `opensubtitles_en`, not `frequency` — so the difference is
visible rather than averaged away, and `:status` prints it:

```
coverage(reading, 0.95): 6% of running text, over 100 words
                         (opensubtitles_en, need 95%)
```

### What 6% says about the A1 list

The top 100 words of English cover **59%** of running text. Our hundred
A1 words cover **6%**. The difference is that the A1 list is nouns and
verbs — *people, family, water, mother* — and **coverage lives in
function words**: `the`, `to`, `a`, `of`, `and`.

That is not a defect in the list, which was curated to be teachable on
day one. It is a fact about what coverage measures, and it is the kind
of thing a curator can only learn from a number.


## What about English

Worse than Japanese, and in a way the audit measured but could not see.

```
  en  preschool  sound_contrasts       12  0   needs_audio
  en  preschool  no_katakana_reading   12  12  ok
  en  preschool  final_consonants      1   0   needs_audio
```

Two of the three criteria on the first rung needed audio, so the rung
could not be exited. But the real problem was worse than that: it could
not be **entered**.

### A gate nothing can open

`lp_mastered` reads the **gate** channel, and for a `sound` item the gate
is `hear` — which is outside `VERIFIABLE`, so a sound can never be
mastered, so anything requiring one is locked for ever. **All twelve
English contrasts are sounds.**

The symptom was not a bad measurement. The English pre-school rung had
*nothing ready*, ever, and the tutor said **"nothing here can be checked
by typing"** to every student who ever opened it.

```prolog
gate_ok(S, Pre) :- lp_known(S, Pre).
gate_ok(_, Pre) :- lp_unverifiable(Pre).
```

A prerequisite the tutor has no way to check does not hold the door
shut. The channels note already makes this argument one level down —
*"if the gate demanded every channel, then with no way to verify `hear`
nothing would ever unlock and the ladder could not be climbed at all"* —
and this is the same argument about prerequisites. The edge is still
true and still teaches order; it simply cannot be a *condition*, because
nothing can satisfy it.

**It does not let anybody pass anything.** `s_final` is still unmastered,
`sound_contrasts` is still `needs_audio`, and `--audit` still says so. It
unlocks the teaching, not the criterion.

### How many syllables does `slim` have?

A Japanese speaker says ドッグ for *dog* — three beats where English has
one syllable — because Japanese cannot end a syllable in a consonant and
puts a vowel there instead. That is what `skill(final_consonants)` is
named for: *ends a word without adding a vowel*.

Producing a final consonant does need a microphone. **Knowing** that
English does not add a vowel is a count, exactly as the mora half was:

```
mansion    2 syllables   vs  マンション  4 beats
slim       1             vs  スマート    4
part-time  2             vs  アルバイト  5
excited    3             vs  ハイテンション 6
```

One syllable per vowel nucleus, counted from the IPA CMUdict provides.
The five diphthongs are two symbols and one nucleus — counting vowel
*symbols* makes `child` two syllables — and the pairs are exactly the
five ARPABET diphthongs the importer maps, so this is not a guess about
English but the inverse of a table in `import.p`.

**The material picks itself.** An item with both an English pronunciation
and a katakana one, where the katakana takes more beats. The twelve
loanword traps are exactly that set — a happy consequence of what they
were curated for, since they were chosen as words a Japanese speaker
already half-knows in katakana.

### The wrong answer worth naming

```
  mansion
  How many syllables? English, not the katakana.  ->  4
  Almost.  That is the beats in マンション.  The English word has 2.
```

A learner who answers four has not guessed. They have read the katakana,
honestly, which is the whole of the katakana box. So it is recorded as
`near` rather than `wrong`, and the tutor says **which count they gave** —
a verdict that only says *no* teaches nothing, because they already know
they got it wrong and not why. `langpop/answer` carries it as
`counted_instead`.

### What the import found on the way

The traps had never been enriched: `--source cmudict` filters by level
and had only ever been run for `a1`. Running it for `preschool` wrote
`graph/en/generated/preschool-sounds.pl` — and `imp_verify` reported all
23 facts as **LOST**, because `GRAPH_GENERATED` is a hand-written list
and the engine never loaded the file.

The verifier was right and the message was baffling, so the importer now
refuses the write instead:

```
import: the engine does not load that file -- add it to
GRAPH_GENERATED in langpop.p, or pass --out
```

And one card quietly changed. `TERM_ORDER_EN` put `ipa` before
`katakana`, so the moment the traps gained a pronunciation every trap
card swapped マンション for `/mˈænʃən/` and stopped showing the thing the
item exists to contrast. A katakana form on an English item *means* the
word is a loanword trap; the IPA is a pronunciation guide, and the trap
is the point.


## The characters that are not syllables

`kana/5` holds the 138 kana that stand for a mora **on their own**. It
does not hold っ, ゃ, ゅ, ょ, the small vowels or ー — and
`recognise(hiragana)` is measured over `kana/5`, so a criterion named
*recognise hiragana* has been quietly measuring *recognise the
syllabary* since the file was written.

**They do not belong in the table, and that is not the problem.** A
gojūon grid has no cell for them. They have no reading of their own.
`type the romaji` cannot ask about ゃ, because ゃ and や are both `ya` —
so adding them would make the criterion's name true and its measurement
hollow, which is the trade this project keeps refusing.

What was missing was the **declaration**:

```prolog
modifier('ゃ', hiragana, youon).
modifier('っ', hiragana, mora_sokuon).
modifier('ー', katakana, mora_long_vowel).
```

Each is covered by a skill that is about **what it does**. Together with
`kana/5` they account for every character of the script, and now
checkably so: `check(graph)` proves the *shape* of the graph, and a
companion check proves the *content of its forms* — walking every
written form and reporting any character that is neither a kana nor a
declared modifier.

```
undeclared_kana(ゐ, w_neko)
```

It is a Pop-11 check and not a Prolog one because it walks a string
character by character and the characters are UTF-8: splitting an atom
into them is what `utf8_explode` is for and what Prolog here is not.
`lp_check/0` returns both lists.

**It found something on its first run.** `form(p_kore_wa_desu, hiragana,
'これは___です')` — a sentence pattern's form is a *template*, and its
underscores are not kana. Declared as such:

```prolog
modifier('_', any, placeholder).
```

The small vowels are declared although no item uses one yet, because the
first katakana loanword with a ファ in it should not be the thing that
breaks the check.

### And they go on the chart

A learner meets っ in がっこう on day three, so a reference sheet that
leaves it off is a reference with a hole in it. They are not cells of
the grid and never will be — so they sit in a strip along the foot,
separated by a rule, labelled with **what each one does** rather than
with a reading it does not have.

```
ヤャ              ユュ              ヨョ              ツッ              ー
joins the one     joins the one     joins the one     a beat of        lengthens
before            before            before            silence          the vowel
```

Each is drawn **beside its full-size twin**, in grey, because the
difference is the size and nothing else: ゃ on its own at chart size is
indistinguishable from や, which is exactly the confusion the strip
exists to prevent. ー has no twin and gets none.

The footer wraps now, too. A footer is one line until somebody writes a
long one, and then it is one line that runs off the right-hand edge —
which it did, the moment the strip needed explaining.


## A mora is a unit of time, and you can ask about it by typing

`--audit` called `skill(mora_count)` and `skill(mora_sokuon)` **thin**,
over a set of one item — あ — which cannot demonstrate beat counting
whatever a student does with it. The obvious reading of that was *timing
needs audio*, and it was wrong.

**Producing** correct timing needs a microphone. **Knowing** how many
beats a word has is a reading question with a number for an answer, and
the number is computable from the kana:

```
every kana       one beat
small ゃゅょ      no beat -- it joins the kana before it
small っ         one beat, of silence
ん               one beat, which is why it is `moraic`
ー               one beat
```

The first two are what make it worth asking. **きょう looks like three
characters and is two beats; きって looks like three and is three.** A
student who gets both right has the thing the criterion is named for.

```
Aoi>
  きょう
  何拍ですか。How many beats?  ->  3
  Not yet. We will come back to it.  It is 2.

Aoi>
  ちょっと
  Count the beats, not the letters:  ->  3
  そうです。
```

### A skill with a probe is measured over itself

```prolog
criterion_item(skill(S), S) :- probe(S, _).
criterion_item(skill(S), I) :- \+ probe(S, _), skill_leaf(S, I).
```

The difference is which thing the question is about. `skill(dakuten)` is
*read the voiced kana*, so reading them is the evidence and the criterion
is measured over the 46 of them. `skill(mora_count)` is *count the
beats*, and reading あ is no evidence of that at all.

`probe(Skill, morae(Feature))` says a skill carries a generated question,
and names the material the feature picks out — `sokuon`, `youon`,
`moraic_n`, `long_vowel`, `any`. The material is drawn from the graph and
the answer is counted from the kana, so **neither is written down
anywhere** and a content build that adds a thousand N5 words adds a
thousand mora questions.

### So the audit counts questions, not items

A skill with a generated probe is one item that can be asked about fifty
words. Counting it as one would call the criterion thin when it is not —
and **the reverse matters more**: when the material runs to a single
word, the criterion *is* thin, and nothing else would have said so.
`skill(mora_sokuon)` had exactly one pre-school word with a small っ in
it.

### Which named the curation, precisely

Two numbers from the same audit turned out to be one job:

| | before | after |
| --- | --- | --- |
| `vocabulary(50, read)` | short by 10 | **50 of 50, ok** |
| `skill(mora_sokuon)` | 1 question, thin | **7 questions, ok** |
| `skill(mora_count)` | 1 item, thin | **51 questions, ok** |

Ten more starter words, chosen as **words normally written in kana** —
which is the criterion a kana-only list should have had from the start
and did not. The first draft picked きっぷ, ざっし, でんしゃ, おちゃ, じしょ,
しゅくだい and でんわ: all good mora examples, and **all seven already in
the N5 pick list** as 切符, 雑誌, 電車, お茶, 辞書, 宿題 and 電話.
`--check` caught it as `requires_from_above` — one id, two levels, the
pre-school word inheriting the N5 word's kanji prerequisites.

Adverbs and expressions are the right material anyway. A learner meets
ちょっと and たくさん constantly, in kana, and will never meet them as
一寸 and 沢山 — so teaching them here costs nothing later, where teaching
でんしゃ in kana is teaching a word that has to be re-learned as 電車 two
rungs up.

**The whole Japanese pre-school rung is now `ok`.** It is the first rung
of either ladder that is.

### The long-vowel test, which went wrong first

いえ is `ie`: two vowels, and two **different** ones — い then え, two
beats of two sounds, no length anywhere. The first version of the test
took any adjacent vowel pair and duly offered いえ as a long-vowel
exercise. A long vowel is the same vowel twice, or one of the two
spellings Japanese uses for one: おう and えい.

### Still open

**The small kana are not in the table** — and now they are *declared*,
checked and printed. See the section above.

## The study plan, as a booklet

```
./poplog basepop11 examples/langpop/langpop.p --zine --user bob
```

and `:zine` in a session. Eight pages from one sheet of A4 — cover, where
you stand, how it is going, what is next, the ladder, what to look at
again, and how to fold it. Printable at any time, because the plan is a
function of the beliefs and the beliefs are always current.

| page | |
| --- | --- |
| 1 | cover: name, language, level, date |
| 2 | **where you are** — the placement report, axis by axis |
| 3 | **how it is going** — this level's exit criteria, measured |
| 4–5 | what is next, weakest belief first |
| 6 | the ladder, with a mark where you are |
| 7 | worth another look |
| 8 | how to fold it, and what the marks mean |

### Nothing is vendored, and that is the whole of the licence answer

The obvious way to build this is to take a free zine template and fill it
in. The one we looked at
([taylorsmithdesigns.co.uk/free-zine-pdf](https://www.taylorsmithdesigns.co.uk/free-zine-pdf))
says *"the template itself must not be sold commercially, but feel free
to share"* under a footer reading *"© 2025 … All Rights Reserved"*.

That is a **permission note, not a licence**: no named licence, no
version, and two clauses that disagree with each other. It is the same
shape as the NGSL word list, which this project turned down for the same
reason. It is also 37 MB of somebody else's PSD and PDF, and keeping
other people's content out of the repo is what the whole
`graph/<lang>/generated/` arrangement exists for.

**And we do not need it.** What a template gives you is the
**imposition** — which panel holds which page, and which half of the
sheet is upside down — and that is not a creative work. It is a
consequence of folding a sheet in half three times and cutting the
middle:

```
  1. A4 landscape.  Fold in half left-to-right, again, and again:
     eight panels, four columns by two rows.
  2. Unfold.  Fold in half top-to-bottom and cut the centre fold
     across the middle two columns only.
  3. Open, fold lengthwise, push the ends together so the cut opens,
     and collapse into a stack.
```

Follow a panel through that and the arrangement falls out:

```
     top row, upside down:   5   4   3   2
     bottom row, upright:    6   7   8   1
```

Every zine template in the world shows this same arrangement, because the
paper leaves no choice. So `sheet.p` derives it, the derivation is
written down beside the table, and `test_langpop_sheet.p` checks it —
each page in exactly one panel, the cover bottom-right and upright, the
top row inverted, and the cut line spanning the middle two columns
**only**. A dashed line the full width would be an instruction to cut the
booklet in half, which is the one mistake that cannot be undone.

### The booklet speaks the language the reader can read

Printing one for a Japanese speaker learning English is what showed the
first draft was unusable for exactly the person it was for: every
heading on it — *Study plan*, *Where you are*, *How it is going*, *Fold
it* — was in **English**, which is the one language a beginner English
learner cannot be assumed to read. That is the metalanguage problem this
project started from, turned round: *a question about grammar in
Japanese will be too challenging because the vocabulary used to talk
about grammar exceeds beginner level.*

So the chrome is in `lp_learner_lang()` — the **other** language from the
ladder being climbed. `card.p` has had this rule since the cards were
drawn (a loanword trap carries a Japanese gloss because the person
reading it reads Japanese), but it was spelled inside `lp_card_gloss`
and could not be used anywhere else.

| | `--lang ja` | `--lang en` |
| --- | --- | --- |
| cover | Study plan | 学習プラン |
| page 2 | Where you are | いまの実力 |
| page 3 | How it is going | とちゅう経過 |
| page 6 | The ladder | レベル表 |
| page 8 | Fold it | おりかた |
| the cut line | cut along here | ここを切る |

**The cover motto is the one exception, and it goes the other way.** A
single phrase in the language being *learned* — がんばって, *you can do
this* — is a flourish the student will meet soon and can be proud of
reading. Navigation in that language is a booklet they cannot use. The
difference is the whole of the distinction, so it has its own procedure
(`zine_say_target`) rather than a flag.

And the status page is worded twice from **one** set of numbers.
`lp_status_rows/0` returns `{criterion, kind, a, b, c, d}` and nothing
else; `lp_status_text/1` words it for the TUI and `zine_status_text/1`
for the page. Formatting the sentence in `lp_status_rows` was fine until
a second reader wanted it in a second language — at which point two
renderings would have become two measurements.

### Two things a printed page does that a screen does not

**Nothing clips.** A dictionary gloss — *"a very large and rather grand
house, in American usage an apartment building"* — set as one line
anchored to the right edge ran clean across the sheet and over the three
panels beside it. SVG does not wrap and does not clip: a line that does
not fit does not get smaller, it escapes. `zine_hint/2` cuts to the
column and marks the cut with an ellipsis, so a reader can tell a short
gloss from a trimmed one.

**Japanese has no spaces.** A space-splitting wrap put a whole Japanese
sentence on one line and sent it off the panel the same way. `zine_wrap`
now measures in **columns** (a kana is two), breaks at a space where
there is one and between characters where there is not, and keeps the
one typographic rule worth keeping — kinsoku: a line may not *begin*
with closing punctuation, or a sentence breaks before its own full stop
and the next line opens with a lone 。

English still does not break mid-word. A wrap that split
`supercalifragilistic` across two lines without a hyphen would be worse
than one that let it hang over the edge, so a mid-word break requires a
wide character.


### Not TeX, and why

TeX would do this, and it was the obvious fallback for a page with
rotation on it. But SVG already draws the cards and the sheets, and
turning half the page over is one `transform` attribute:

```xml
<g transform="translate(2970,4200) rotate(180)">
```

A whole toolchain bought for one rotation is a bad trade, and the
graphics requirement for this project has been *"a system call to run an
external program is probably good enough"* from the start.

### One measurement, one rendering

Page 3 prints `lp_status_rows/0` and so does `:status`; page 2 prints
`lp_place_says/1` and so does `:place`. Both were extracted from the
procedures that used to print them directly, because **two renderings of
one number is one too many** — the paper would drift from the screen and
nobody would notice which was right.

### The unit, which is the trap

The page is in **twentieths of a millimetre**, not the tenths the other
sheets use, so that a quarter of A4's width is an integer: 74.25 mm is
1485 units exactly. The cost is that type sizes carried over from
`sheet.p` mean half what they say, and the first draft of this page was
unreadable at about five point because of it. The sizes are now named
constants with the point size in the comment.


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
| `:status` | this level's exit criteria, measured, and which aids are off |
| `:place` | find out where they are, rather than ask |
| `later` | *at a question:* put it off until later this session |
| `:oops` | that answer was an accident — take it back and ask again later |
| `:aids` | which helps are on; `:aids later off` takes one away |
| `:sheet` | today's work, as a page to print |
| `:chart <script>` | hiragana, katakana or youon, on one page |
| `:zine` | the study plan, as a booklet to fold |
| `:say <item>` | hear it said, if a voice is installed; `:say <item> slow` |
| `:rate slow` | listen slower from now on, and it sticks (`slow`/`normal`/`fast`) |
| `:assign` | something to do away from the keyboard |
| `:report <n> ok` | done it (tier 3) |
| `:report <n> 17/20` | done it, with a result (tier 2) |
| `:level <name>` | move the goal |
| `:quit` | save and stop |

Profiles live in `~/.langpop/`: one JSON file per student, plus
`roll.json`, which is what lets the teacher recognise — and
misrecognise — somebody.

## The teacher is allowed to misremember

> *"Ideally we start to 'remember' things, and the teacher would say, ahh,
> is it Bob Smith? No, my mistake, Bob White."*

That is recognition, not lookup, and until now it was the one thing the
in-process TUI could do that the protocol could not — which made
Proposal B's premise, *the TUI is just a client*, false for exactly the
feature the project asked for by name. A client got a database lookup
where `langpop.p` got a teacher.

`langpop/recognise` closes it. No session, because it happens before
registration; it creates nothing, so a client may ignore the answer:

```json
-> {"method":"langpop/recognise",
    "params":{"student_id":"bwhite","display_name":"Bob White"}}
<- {"result":{"student_id":"bwhite","known":false,
              "guess":{"student_id":"bsmith","display_name":"Bob Smith",
                       "matched_on":"the name"}}}
```

and `langpop/register` takes `not_me` back, so a refused name is never
offered to that person again.

**A name is not a string.** `Bob Smith` against `Bob White` is three
edits apart — outside any sane tolerance — and yet it is the exact
confusion a person makes, because the two share a given name. So tokens
are compared as well as whole strings, and a close token counts with one
added so a whole-name match still wins. This will sometimes offer the
wrong one of two people sharing a first name, which is the behaviour
being modelled rather than a defect in it: the teacher asks once, is told
no, and never asks again.

**A transposition is one typo, not two.** Plain Levenshtein charges two
for `bsmiht` against `bsmith`, which is outside the budget for any short
name — so the single commonest slip a returning student makes was the one
case that got no guess at all. The distance is Damerau-Levenshtein, and
that is load-bearing rather than a nicety.

**And the same keystrokes must give the same guess.** The old matcher
compared the first three characters of the username and kept whichever
candidate a property walk reached first — so with two students on the
roll it guessed by hash order. A teacher who asks *Bob Smith?* on Monday
and *Yuki Tanaka?* on Tuesday from the same input is not remembering, it
is rolling dice. Ties now break alphabetically, not because that is the
better guess but because it has to be the same one every time.

One thing this turned up on the way. `lp_load_profile` cleared the
journal, the assignments and the refused guesses *after* its early
return, so a failed load left the previous student's behind. In the
one-shot TUI that never showed; the server is long-lived and serves
whoever asks, so binding to a student who does not exist used to leave
the last one's work sitting in the globals. Beliefs were never at risk —
`lp_bkey` puts the student in the key — but the rest was, and it is
cleared before the return now.

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
| `langpop/placement.next` / `placement.report` | find out where they are |
| `langpop/aids` | which helps are on, and switching them |
| `langpop/audit` | which rungs of the ladder are hollow |
| `langpop/card.render` | the item as a picture |
| `langpop/sheet.render` | a page to print: a chart, today, or the zine |
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

### Which face, and whose language

Two choices on every card, and both are per-language rather than fixed.

**The term is the form in the item's own language.** A flat order got
this wrong twice in a row. Hiragana-first was right while every item was
a kana or a kana-only starter word, and made the card for 山 come out as
a card reading やま with no reading line at all. Putting kanji first then
did the same thing to English: a loanword trap came out as マンション with
`mansion` — the word the item exists to teach — nowhere on it.

**The gloss is in the learner's own language**, which is the other one:
a Japanese item is glossed in English, an English item in Japanese. The
card for `water` used to print *the liquid we drink* while 水 sat in the
graph, hand-written, and never appeared on anything.

That second change turned up a modelling error it had been hiding. The
loanword traps filed **English text under `ja`** —
`gloss(t_mansion, ja, 'apartment building')` — where `schema.pl` defines
a gloss as what an item means *in a named language*. Nothing read it
that way until a card asked for the Japanese, and then the card for
`mansion` proudly displayed the very meaning the item exists to unteach.
The contrast now lives in the English gloss, where a contrast belongs,
and the Japanese slot holds Japanese:

```prolog
trap(t_mansion, 'mansion', 'マンション',
     'a very large house -- the katakana means an apartment building',
     '大邸宅').
```

So the trap is one card: `mansion`, with マンション above it and 大邸宅
below.

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

## Stage 0 of audio: the student can hear it

The first compounding factor in `docs/projects/langpop-pronunciation.md`
is not a measurement problem. It is that a learner has *little exposure
to correct pronunciation* — so asking someone to produce a sound we
declined to let them hear is a test of material we never taught.

So the first audio that ships is **output**, and it carries no verdict:

```sh
./poplog basepop11 examples/langpop/langpop.p --audio preschool
```

```
audio: 188 made, 0 already cached in ~/.langpop/audio/ja/
  8 not said: no_spoken_form
  3 not said: has_blank
audio: listen at ~/.langpop/audio/ja/listen-preschool.html
```

**It does not make `hear` verifiable**, and `--audit` still says
`needs_audio` for every criterion on that channel. Playing a sound and
checking that somebody heard it are different claims, and nothing in
`audio.p` touches a belief. The plan for the half that does measure is
`docs/projects/langpop-audio.md`.

### The voice is a command, not a dependency

Kokoro is the chosen model — 82M parameters, Apache-licensed weights,
CPU, Japanese among its voices — but nothing in the engine knows that.
The voice is a command named in `~/.langpop/audio.conf`, the way `card.p`
shells out to `open(1)`:

```json
{"ja": {"cmd":   "kokoro --voice %v --speed %r --text-file %i --out %o",
        "voice": "jf_alpha",
        "model": "kokoro-82m-v1.0",
        "rates": {"slow": "0.7", "normal": "1.0", "fast": "1.3"}}}
```

`%i` is a file holding the text, `%o` the wav to write, `%v` the voice,
`%r` the rate.
**The text goes through a file and never onto the command line**: the
words are Japanese and the shell is not, and a quoting bug in a tutor
would be a quoting bug in whatever the shell made of ひらがな.

Nothing is installed, imported or vendored. A machine with no model
configured answers `no voice for ja` and goes on teaching exactly as it
did — which is the state every fresh checkout and every CI run is in, and
the state most of the 60 checks in `test_langpop_audio.p` are about.

To hear the pipeline work before wiring Kokoro up, macOS already has a
Japanese voice:

```json
{"ja": {"cmd": "/usr/bin/say -v Kyoko -r %r -f %i -o %o --file-format=WAVE --data-format=LEI16@22050",
        "voice": "Kyoko", "model": "macos-say",
        "rates": {"slow": "110", "normal": "175", "fast": "220"}}}
```

That is not a teaching voice and it is not meant to be one. It is
something to compare Kokoro *against*, which is easier than judging a
voice in the absolute.

### `model` is declared, not detected

An external command cannot be asked what weights it loaded. So the
config declares it, and the declaration is part of the cache key:

    ~/.langpop/audio/ja/hi_a-Kyoko-3936002.wav

`{item, voice, model, text}`, three of them in the name in full and the
fourth as a hash of the text. A line edited in the config is a cache
invalidated — which is the honest behaviour, because what we cached is
what the config *said*. The key being the **filename** means there is no
index to keep in step with the directory: a corrected `form/3` writes a
new name and the old file simply stops being reachable, rather than being
served to a student as the reading of a word we have since fixed.

Beside each wav is a sidecar JSON naming the item, the text, the voice,
the model and the command that made it — provenance that goes stale with
the file it describes instead of outliving it in a manifest.

### Nothing is synthesised inside a question

`lp_audio_path/1` answers from the cache and never runs a model.
`lp_audio_make/1` is the one that does, and `--audio <level>` calls it
ahead of time. On the wire the same distinction is a positive flag,
`cached_only: true`, and **not** a `render: false` — `lp_param` cannot
tell an absent key from a JSON `false`, so a `render` parameter would
read every client that omitted it as one switching rendering off.

The reason for the rule is visible in the numbers: 188 items took **89
seconds** with `say`, nearly all of it process startup. Half a second is
not much; half a second in the middle of a question is a tutor that feels
broken.

### What has no sound, and why that is right

Eleven of the 199 pre-school items are not said, and the report names
both reasons:

- **8 skills** — `mora_count`, `youon`, `hiragana_all`. An abstraction
  has no utterance.
- **3 patterns** — `これは___です`. A voice would read the gap aloud, or
  swallow it silently, and either way the student hears a sentence that
  is not the item.

Japanese is read from **kana**, never romaji: a voice handed `gakkou`
reads English. English is read from the latin form and **never from the
IPA**, which is a notation and not a word — a voice handed `/wɜrld/` says
something, and it is not *world*. That last one means the twelve sound
contrasts have no sound of their own, which is correct: `/l/` is not
something a voice can pronounce in isolation. It is heard through the
words that exercise it, and the graph already links them.

### Controlling the rate, and the one item family it misleads

A beginner needs it slower. So the config maps a **name** to whatever
that engine's scale wants, and `%r` substitutes it:

```json
"rates": {"slow": "0.7", "normal": "1.0", "fast": "1.3"}
```

There is no portable number to use instead. Kokoro takes a multiplier
where `1.0` is normal; `say(1)` takes **words per minute** where `175` is
normal; the next engine will take a percentage. **The scale belongs to
the engine and the name belongs to us** — so langpop says `slow`, the
config says `0.7`, and nothing in the engine has an opinion about which
number means slow.

```sh
./poplog basepop11 examples/langpop/langpop.p --audio preschool --rate slow
./poplog basepop11 examples/langpop/langpop.p --audio preschool --rate all
```

In a session it is `:say <item> slow` for one word and `:rate slow` for
all of them, which **persists in the profile** beside the aids: a
beginner who has asked for slow should not have to ask again tomorrow.
On the wire it is `rate` on `langpop/audio.say`, and the reply carries
both the rate it used and the rates that voice has, so a client can
offer a control rather than guess at one.

The rate is **part of the cache key**, and so is its *value*:

    hi_a-Kyoko-slow-7083155.wav

The name is in the filename so a directory can be read; the number goes
through the hash with the model, because a config that redefines `slow`
from `0.7` to `0.8` has to invalidate what `0.7` produced — otherwise the
student goes on hearing the old speed under the new name.

**And then the part that is not plumbing.** Japanese length is
*contrastive*: きて and きって differ by a beat of silence, and four of
the mora skills exist to teach exactly that. Every TTS engine stretches
durations under a rate change, and **none of them promises to stretch a
geminate closure by the same factor as the vowel beside it** — so at
`0.7` the student may be listening to a ratio the language does not have.

Slow is still the right setting for finding the *segments* in a word. It
is the wrong one for learning its *rhythm*, and those are two different
lessons on the same item. So langpop reports it and never refuses:

```
Aoi> :say w_gakkou slow
  ~/.langpop/audio/ja/w_gakkou-Kyoko-slow-4821930.wav  (slow)
  Length is contrastive in this one.  Hear its RHYTHM
  at normal rate -- a slowed voice stretches the beats
  and not always evenly.
```

The test is `っ`, `ッ`, `ー`, `ん` or `ン` in the spoken form — the
characters `lp_morae/1` counts as beats of their own. On the wire the
same fact is `timing_sensitive`, and on the listening page those rows
carry a ♪ with the reason printed above the table.

### The listening test is the part that is not wiring

Whether Kokoro's Japanese is good enough to teach pronunciation *with* is
a question for an ear, not a benchmark — for teaching, the model's own
accent is the product. So `--audio` also writes a page with every file on
it, the voice and model named at the top, and one question: *does it
sound like a person reading, and would you learn to say it this way?*

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
