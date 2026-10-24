# The function-word tranche

A queue for a curator. Nothing here is in the graph yet, and nothing
here should be committed as content until the rows are marked.

**What is being asked:** mark each row `yes`, `no`, or `reword`. The rows
you keep, I wire in -- id, level, forms, `requires` edges, and the
re-import that attaches pronunciation and frequency. The rows you reject
cost nothing, because none of this is written anywhere the engine reads.

The source is `import.p --source frequency --lang en --gap`, run against
`en_50k.txt` (OpenSubtitles, 50,000 entries, 725,119,374 tokens).

---

## Why this tranche exists

`graph/en/a1.pl` holds 100 words. Every one of them is a content word --
*people*, *water*, *remember*, *beautiful*. `very` is the only member of
a closed class in the list.

Not one of the fifty most frequent words in English is in the graph.

That is what the 5.60% means. The 111 English words the graph answers
for carry 5.60% of subtitle dialogue, and the reason is not that the list
is short. It is that the list is made entirely of the words that
frequency lists put in the long tail. A hundred content words is a
hundred content words; a hundred of the *commonest* words would be about
half the corpus.

The ladder already depends on fixing this. `coverage(reading, 0.95)` is a
B1 exit criterion, `coverage(reading, 0.98)` is B2, and
`coverage(listening, 0.95)` is B2 as well. None of them is reachable
through content words at any list length. A learner who knows five
thousand nouns and no articles reads nothing.

**What the tranche buys:** the 36 words below take the graph from 5.60%
to 44.24% of the corpus -- thirty-nine points, from thirty-three items.
The caveat from the gap report still applies: OpenSubtitles is
dialogue, so these ranks suit `coverage(listening, _)` and are a proxy
for reading.

---

## Group A -- the people in the sentence (13 rows)

These translate. The teachable fact is not the translation; it is that
English requires the pronoun where Japanese drops it, and that `あなた`
is avoided in Japanese exactly where English says *you* most. The gloss
carries that.

```prolog
a1(e_i,     'I',     'the person speaking',              '私').
a1(e_you,   'you',   'the person spoken to',             'あなた').
a1(e_me,    'me',    'the person speaking, as object',   '私を・私に').
a1(e_my,    'my',    'belonging to the speaker',         '私の').
a1(e_your,  'your',  'belonging to the one spoken to',   'あなたの').
a1(e_we,    'we',    'the speaker and others',           '私たち').
a1(e_he,    'he',    'a male person already mentioned',  '彼').
a1(e_she,   'she',   'a female person already mentioned','彼女').
a1(e_they,  'they',  'people already mentioned',         '彼ら・それら').
a1(e_this,  'this',  'the thing near the speaker',       'これ・この').
a1(e_that,  'that',  'the thing away from the speaker',  'それ・あれ').
a1(e_here,  'here',  'the place the speaker is',         'ここ').
a1(e_there, 'there', 'a place away from the speaker',    'そこ・あそこ').
```

`requires(e_my, e_i)` and `requires(e_your, e_you)` are the edges I would
add; *this/that* and *here/there* I would leave unordered, because
neither is a prerequisite for the other and the こ/そ/あ series a Japanese
speaker already has makes both available at once.

The /ð/ edges come free. CMUdict gives `DH` to `the`, `this`, `that`,
`they`, `there` and `with`, and `import.p --source cmudict` turns that
into `requires(Id, s_th_v)` by rule -- no hand-written edges needed.

Which is worth stopping on. The pre-school contrast *this, those* has
existed since the first commit, and the only words exercising it were
*father*, *mother*, *brother* -- three nouns a learner can route around
for years. It is about to sit under six words they cannot avoid in a
single sentence. The sound contrasts were built before there was anything
frequent enough to make them matter, and this tranche is where that
groundwork gets paid.

---

## Group B -- the frame (6 rows)

These map onto particles, badly and many-to-many, which is why they are
the error class they are. The gloss is deliberately one sense, the
commonest, not a list.

```prolog
a1(e_to,   'to',   'towards, or the direction of',   'に・へ').
a1(e_of,   'of',   'belonging to, or part of',       'の').
a1(e_in,   'in',   'inside',                         'の中に').
a1(e_on,   'on',   'resting on top of',              'の上に').
a1(e_for,  'for',  'intended for, or on behalf of',  'のために').
a1(e_with, 'with', 'together with, or using',        'と・で').
```

**The honest objection to this group, stated rather than hidden:** a
preposition with one gloss is a half-truth, and the half that is missing
is where learners actually fail -- *in* the morning but *on* Monday, and
nothing in `'の中に'` predicts that. My position is that the one-sense
gloss is still worth having at A1, because a student who cannot read *to*
at all is not helped by being told it is complicated; and that the
collocations belong to A2 as `pattern` items, where they can be asked
about rather than merely glossed. If you would rather these wait for the
pattern work, cut the group and the tranche drops about 6.5 points.

---

## Group C -- joining, asking, refusing (8 rows)

```prolog
a1(e_and,  'and',  'joining two things',              'と・そして').
a1(e_but,  'but',  'joining two things that disagree','でも・しかし').
a1(e_so,   'so',   'and therefore',                   'だから').
a1(e_what, 'what', 'asking which thing',              '何').
a1(e_all,  'all',  'every one of them',               '全部').
a1(e_no,   'no',   'the answer that refuses',         'いいえ').
a1(e_not,  'not',  'making a sentence negative',      '〜ない').
a1(e_can,  'can',  'is able to',                      '〜できる').
```

`and` is worth a note: `と` joins nouns and `そして` joins clauses, and
English *and* does both jobs with one word. That asymmetry runs the
opposite way from most of this list, where English makes a distinction
Japanese does not. It is a gloss note, not a second item.

`no` against `not` is a real confusion and the two rows are adjacent on
purpose.

---

## The six that need a decision I should not make alone

### `the` and `a` -- there is no translation, and the cell wants one

Japanese has no articles. There is no word to put in the `GlossJa`
column, and `'冠詞'` ("article") is the name of the category, not the
meaning -- it tells a student what grammarians call the thing they cannot
use.

This is the precedent the graph has not set. Three ways out:

1. **Prose in the Japanese cell.** `a1(e_the, 'the', 'the one we both
   know about', '話し手と聞き手が既に知っているもの')`. Cheapest, no schema
   change, and it makes the column mean two different things in two
   different rows -- a translation here, a paragraph there.

2. **A new item kind.** `item(e_the, function, en, a1, own(a1_list))`
   with its own `note/2`. Honest, and it is a schema change plus
   `--check` work plus a question about what else becomes a `function`.

3. **`pattern` items, which already exist.** An article is only learnable
   in a frame. `p_a_noun` as `'a ___'` against `p_the_noun` as
   `'the ___'`, glossed *"a dog -- any dog, you do not know which"* and
   *"the dog -- that dog, we both know which"*, each `requires` a noun
   already in the list. The kind exists, `graph/ja/items.pl` uses it for
   exactly this reason, and the DCG work it anticipates would make the
   pair askable rather than only readable.

**My recommendation is (3), with (1) as the fallback.** The argument for
it is the one `graph/ja/items.pl:108` already makes: a pattern is an item
too, and it requires the words it needs to be demonstrated with. *The*
and *a* are not vocabulary; they are a choice made about a noun, and the
item should have the noun in it.

The cost is that a `pattern` carries no `latin` form, so
`imp_en_words()` will not find it and the frequency importer will not
enrich it -- which means **articles as patterns do not count toward
coverage**, and that is 5.14 points of the thirty-nine.  Either coverage learns
to credit a pattern for the words it frames, or articles stay words and
take option (1). That is the real decision, and it is yours.

### `it` -- the same problem, less famous

*It's raining.* 雨が降っている. There is no pronoun in the Japanese and
there cannot be one; English needs a subject in a slot where the sentence
has no subject to put there. `'それ'` is right for *it* the referring
pronoun and silently wrong for the dummy *it*, which in dialogue is most
of the 1.88%.

Proposal: `a1(e_it, 'it', 'a thing already mentioned', 'それ')` as a word
now, and an A2 `pattern` for the weather/time/distance *it* later. Marked
here because glossing it as `それ` alone is a thing I would rather you
agree to than discover.

### `is`, `are`, `was`, `be` -- one word, four rows

The frequency list counts four tokens. English has one verb. Four items
would be a lie about the language that happens to measure correctly;
one item measures wrong, because `imp_en_words()` reads
`lp_form_of(i, "latin")` -- a single form per item -- so one `e_be` with
four forms collects 0.58% and drops the 2.21% the other three carry.

Proposal, and the one code change the tranche needs:

```prolog
a1(e_be, 'be', 'joining a thing to what it is', '〜です').
form(e_be, latin, 'is').
form(e_be, latin, 'are').
form(e_be, latin, 'was').
```

plus `imp_frequency` summing every `latin` form of an item instead of
taking the first. That is correct on both axes at once -- one item for
`vocabulary(500, read)` to count, four tokens for `coverage` to credit --
and `imp_graph_words()` already walks every form, so the gap report will
stop listing the other three the moment they exist.

I would make that importer change as part of wiring, with its own test.
Say if you would rather have four flat rows and no code.

### `do` and `have` -- two jobs each

*Do you know?* and *do the dishes*. *I have a car* and *I have eaten*.
The auxiliary and the lexical verb are different things that a frequency
list cannot separate, and the auxiliary is the one carrying the rank in
dialogue.

Proposal: gloss the auxiliary, since that is what the frequency is, and
let the lexical senses arrive as ordinary A2 verbs.

```prolog
a1(e_do,   'do',   'asking or denying, before another verb', '疑問や否定を作る').
a1(e_have, 'have', 'owning, or finishing something',         '持つ・〜した').
```

`have` is the weaker of the two and I am not confident in that cell.

---

## Three I would defer, with reasons

| word | share | why not now |
|---|---|---|
| `just` | 0.46% | Four senses in dialogue (*just now*, *just one*, *just leave*, *just a moment*) and no core. The honest gloss is a page. |
| `like` | 0.41% | The rank is inflated by discourse *like*, which is not the verb and should not be taught as it. `like` the verb belongs at A1 as a verb; this row is not that. |
| `get` | 0.40% | The most polysemous word in the list. A gloss that covers the rank would say nothing. |

Deferring all three costs 1.27 points and keeps three bad glosses out of
the graph. They are the rows where a frequency list is most clearly
measuring something other than a word.

## And six rows that are not words at all

`'s`, `'t`, `'m`, `'re`, `'ll` and `don` are tokeniser shards -- the gap
report flags the first five by their leading apostrophe and misses
`don`, which is the left half of *don't*. Together they are 5.43% of the
corpus that no curation can ever claim, because there is nothing to
teach.

They will sit at the top of every English gap report forever. I would add
a short known-shards list to `--gap` so they are reported once, under the
table, as *"5.43% of this corpus is tokeniser shards and not vocabulary"*
-- which is a fact about the data worth printing, and better than six
rows of noise above the real queue. Small change, happy to fold it in.

---

## What the numbers do

The share column is the gap report's own: what fraction of the corpus
the graph's words account for. The word column is what the list
recognises, which is three higher than the item count because `is`,
`are` and `was` are forms of `be`.

| | words the list knows | corpus share |
|---|---|---|
| now | 111 | 5.60% |
| Group A (13 rows) | 124 | 21.07% |
| plus Group B (6 rows) | 130 | 27.57% |
| plus Group C (8 rows) | 138 | 33.16% |
| plus the six decided items | 147 | 44.24% |
| if articles become patterns instead | 145 | 39.10% |

A1's exit is `vocabulary(500, read)`, so 33 new items does not open the
door; it was never going to. What this changes is `coverage`, which was
the criterion with no path to it at all. Note that Group A alone --
thirteen pronouns, the easiest rows in the queue and the only group with
no objection attached -- is worth more than fifteen points on its own.

## What I do once rows are marked

1. The accepted rows into `graph/en/a1.pl`, in sections, in house style.
2. `requires` edges: `e_my -> e_i`, `e_your -> e_you`, and whatever the
   article decision implies.
3. `imp_frequency` sums every `latin` form of an item, with a test.
4. The shards note in `--gap`.
5. Re-import `cmudict` and `frequency`, which attaches pronunciation,
   the sound-contrast edges, and the counts coverage reads.
6. `--check` and the full suite, and the coverage figure before and after
   in the commit message.

Nothing in steps 1 through 6 happens before the rows are marked.
