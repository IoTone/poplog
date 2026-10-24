# The Japanese tranche

A queue for a curator, like `langpop-function-words.md`, and a different
shape of problem. Mark rows `yes` / `no` / `other`. Nothing enters
`graph/ja/picks/n5.pl` or `graph/ja/items.pl` until marked.

Source: `import.p --source frequency --lang ja --gap` against
`ja_full.txt` (OpenSubtitles Japanese, 34,504 entries, 3,794,284 tokens
— a small corpus, so read the ranks with salt).

---

## Three things found before any row was proposed

**1. The queue was half false positives, and that is fixed.**
The list is tokenised so a verb arrives without its ending — 話す appears
as 話, 分かる as 分か — and the graph holds the dictionary form, so
nothing matched. `--gap` was reporting the stem of every verb already
picked as a gap. Measured: **3.90% credited, 5.16% held by a stem and
called missing, 9.06% true.** 知, 話, 分か, 聞, 持, 会 and 入 were at the
top of the queue, and a curator working it would have picked `w_shiru`,
`w_hanasu`, `w_wakaru`, `w_kiku`, `w_motsu`, `w_au` and `w_hairu` — all
already in the pick list, all refused by the importer as taken.
`imp_ja_stem` now handles this.

**2. Half the keys a curator writes will be ambiguous, by design.**
I probed 28 candidate picks against JMdict. Fourteen came back
`AMBIGUOUS` — 人 matches four entries (ひと, じん, にん, と), 家 matches
eight, 中 five. The importer refuses each and prints the candidates with
glosses, which is the workflow `picks/n5.pl`'s header describes. It
works, and it means the Japanese tranche cannot be marked without a pass
of sequence numbers. The resolutions are in Category B below.

**3. The largest single opportunity in the project needs no new words
at all.** See Category A.

---

## Category A — a spelling, for a word already taught (32 rows, 5.72%)

Pre-school is the **kana** level, so all 50 of its words are kana-only by
design: `starter(w_iku, 'いく', iku, 'to go')` yields a `hiragana` form
and a `romaji` form and nothing else.

But the corpus writes them in kanji. 行 is 1.18% of all dialogue and it
is `w_iku`, a word the graph has taught since the first commit.

**32 of the 50 pre-school words have a kanji form the corpus uses, and
together they are 5.72% of the corpus** — more than everything the graph
currently credits in Japanese. No new identity, no gloss, no level
decision, no JMdict key. A spelling.

```
  1.18%  行   <- 行く   (w_iku)        0.12%  食べ  <- 食べる  (w_taberu)
  0.94%  人   <- 人     (w_hito)       0.11%  友達  <- 友達   (w_tomodachi)
  0.69%  来   <- 来る   (w_kuru)       0.10%  明日  <- 明日   (w_ashita)
  0.35%  家   <- 家     (w_ie)         0.09%  先生  <- 先生   (w_sensei)
  0.30%  手   <- 手     (w_te)         0.08%  本    <- 本     (w_hon)
  0.29%  一緒 <- 一緒   (w_issho)      0.07%  水    <- 水     (w_mizu)
  0.26%  目   <- 目     (w_me)         0.06%  高    <- 高い   (w_takai)
  0.24%  車   <- 車     (w_kuruma)     0.06%  学校  <- 学校   (w_gakkou)
  0.20%  名前 <- 名前   (w_namae)      0.06%  口    <- 口     (w_kuchi)
  0.17%  今日 <- 今日   (w_kyou)       0.05%  大き  <- 大きい (w_ookii)
  0.13%  全部 <- 全部   (w_zenbu)      0.05%  朝    <- 朝     (w_asa)
```

and twelve more below 0.05%, down to 一寸, 玩具 and 一杯.

**The corpus is also the filter, which is the pleasing part.** ちょっと
is 一寸 in the dictionary and nobody writes it that way; its share is
0.00%, and that zero is the evidence. Same for 玩具 (おもちゃ) and 美味しい
(おいしい). A row worth adding is a row with a share, so the queue sorts
itself and the tail can simply be cut.

**How this is declared, and the objection that matters.** `starter/4` has
no kanji slot, so the mechanical part is two lines of schema and 32
facts:

```prolog
form(Id, kanji, K) :- starter_kanji(Id, K).
starter_kanji(w_iku, '行く').
```

The objection is real: if `w_iku` gains a kanji form, the tutor can ask a
pre-school student to read 行く — before any kanji has been taught. The
honest prerequisite would be `requires(w_iku, k_884c)`, and
`violation(requires_from_above)` forbids it, correctly, because `k_884c`
is n5 and `w_iku` is pre-school. Minting an n5 `w_iku2` is worse and
`import.p` already refuses it by name: a second identity for one word
splits a student's beliefs in half without telling anybody.

**Recommendation: the kanji form is declared, and it earns reading credit
only when every character in it is mastered.** Reading 行く needs the
word *and* the character, which is two facts the graph already holds
separately, and `imp_kanji_reqs` and `imp_gap_kanji` already decompose a
string into its characters for exactly this kind of question. So
coverage asks a conjunction rather than a form declaration, no schema
rule is bent, and nobody is asked to read a kanji they have not met.

That is the one piece of real engineering in this tranche, and it is the
decision I would most like your view on before I build it.

## Category B — new words (pick lines)

One line each, and the importer fetches the forms, readings and glosses
from JMdict at build time, so no Japanese is typed into the repository.
Fourteen of these needed a sequence number; those are resolved here from
the candidates the importer printed.

```prolog
pick(w_nani,     ja, n5, word, jmdict('1577100')).   % 何 なに    2.67%
pick(w_anata,    ja, n5, word, jmdict('1223615')).   % 貴方 あなた 1.61%
pick(w_iu,       ja, n5, word, jmdict_kanji('言う')).  %           1.40%
pick(w_koto,     ja, n5, word, jmdict('1313580')).   % 事 こと    0.89%
pick(w_kanojo,   ja, n5, word, jmdict_kanji('彼女')). %           0.87%
pick(w_omae,     ja, n5, word, jmdict_kanji('お前')). %           0.83%
pick(w_toki,     ja, n5, word, jmdict('1315840')).   % 時 とき    0.51%
pick(w_shinu,    ja, n5, word, jmdict_kanji('死ぬ')). %           0.51%
pick(w_korosu,   ja, n5, word, jmdict_kanji('殺す')). %           0.47%
pick(w_mae,      ja, n5, word, jmdict('1392580')).   % 前 まえ    0.47%
pick(w_naka,     ja, n5, word, jmdict('1423310')).   % 中 なか    0.47%
pick(w_hitsuyou, ja, n5, word, jmdict_kanji('必要')). %           0.43%
pick(w_ki2,      ja, n5, word, jmdict('1221520')).   % 気 き      0.42%
pick(w_daijoubu, ja, n5, word, jmdict('1414150')).   % 大丈夫     0.40%
pick(w_jibun,    ja, n5, word, jmdict_kanji('自分')). %           0.39%
pick(w_hontou,   ja, n5, word, jmdict_kanji('本当')). %           0.37%
pick(w_ichi,     ja, n5, word, jmdict('1160790')).   % 一 いち    0.37%
pick(w_nai,      ja, n5, word, jmdict_kanji('無い')). %           0.35%
pick(w_arigatou, ja, n5, word, jmdict_kana('ありがとう')). %      0.35%
pick(w_toshi,    ja, n5, word, jmdict('1468060')).   % 年 とし    0.33%
pick(w_ato,      ja, n5, word, jmdict('1269320')).   % 後 あと    0.28%
pick(w_dekiru,   ja, n5, word, jmdict_kanji('出来る')). %         0.28%
```

Two rows carry a judgement worth naming.

**`w_ki2` is a bad identity and I could not find a good one.** `w_ki`
is already taken, at n5, for 木 (tree) — `pick(w_ki, ja, n5, word,
jmdict('1534520'))`. 気 is a different word that romanises identically,
and the numeric suffix is me giving up. If you have a
convention for this, it should go in the pick list's header, because it
will happen again — Japanese has many homophones and the ids are romaji.

**The second-person pronouns are a register lesson, not three words.**
あなた (1.61%), お前 (0.83%) and あんた (0.23%) are listed separately
above, and teaching them as three vocabulary rows would be teaching a
Japanese learner's mistake in reverse: the choice between them is the
content. They want one `pattern`-ish item about politeness, or a shared
gloss note. Flagged rather than decided.

## Category C — rows I would not take (5.15%)

| row | share | why not |
|---|---|---|
| あ | 2.11% | Filler. The single biggest row in the list and it is the sound people make while thinking. |
| ああ | 0.49% | The same. |
| あの | 0.42% | Both a demonstrative (*that* ___) and hesitation filler, and the rank is mostly the second. |
| あんた | 0.23% | See the register note above. |
| 者 的 達 様 度 | 1.90% | Bound morphemes — real and necessary, but suffixes, not free-standing words. A fourth category nobody has designed. |

The fillers are the Japanese counterpart of English *just* / *like* /
*get*: the rows where a frequency list is most clearly measuring
something other than vocabulary. Taking them would buy 3.25 points and
teach nothing.

---

## What the numbers do

| | corpus share |
|---|---|
| credited before the stem fix | 3.90% |
| **now, same content** | **9.06%** |
| plus Category A (a spelling, 32 rows) | ~14.8% |
| plus Category B (22 new picks) | 29.45% |

The ladder has **no** Japanese `coverage` criterion and no ja frequency
import, so none of this is measured by `:status` yet — `exit(ja, ...)`
names `vocabulary` and `kanji` only. Worth saying plainly: Category B
moves `vocabulary(800, read)`, which is counted, and Category A moves
nothing the ladder currently asks about. If a `coverage(reading, _)`
criterion is wanted for Japanese, that is a third piece of work and it
needs `imp_ja_stem` wired into `imp_frequency`'s `want` list, which the
procedure's own comment already points at.

## What I would build, once rows are marked

1. Category B's accepted picks into `graph/ja/picks/n5.pl`, then
   `--source jmdict` to generate, then `--check`.
2. `starter_kanji/2` and the conjunction rule for Category A, with tests
   that a pre-school student is never asked to read a kanji.
3. A note in `picks/n5.pl`'s header on the homophone-id convention, once
   there is one.
4. Nothing for Category C.
