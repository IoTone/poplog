# Production criteria

`:speak` works. It records a verdict, at tier 5, capped at 0.77, and
`--voicetest` says the scorer is not arbitrary. No rung asks anyone to
use it, and `lp_next` will not offer it.

That was deliberate: a scorer that works is not the same as a criterion
that is fair. This document is the decision that was deferred.

**Five decisions, marked `yes` / `no` / `other`.** Nothing is wired until
they are. Each one names the code it touches.

---

## What is actually in the way: three locks, at three layers

Worth establishing first, because the obvious fix -- "add
`exit(ja, n5, vocabulary(800, speak), 0.80, 3500)`" -- fails three
times over, and the three failures are not the same failure.

**Lock 1: `speak` is not verifiable.** `langpop.p:203` --
`lconstant VERIFIABLE = [read produce]`, with `hear` conditional in
`VERIFIABLE_HEARD`. A criterion naming `speak` reports *cannot be checked
here -- needs audio*, which is the correct answer today and the one the
status row was written to give (`lp_status_rows`, the `"audio"` branch:
"Reporting 0 of 800 would read as a student who has learned nothing,
when what is true is that nothing here can measure it").

**Lock 2: a criterion cannot see a machine verdict at all.**
`lp_measure` filters `e(3) == 1` -- tier-1 journal entries, a human
check, nothing else. `:speak` records at tier 5 (`langpop.p:3611`).
So with Lock 1 opened and nothing else changed, a measured production
criterion reports `0% over 0 answers`: not a student who failed, and not
an instrument that is missing, but a hundred recorded verdicts that no
criterion is allowed to look at.

**Lock 3: `MACHINE_CAP` is 0.77 and `MASTERY` is 0.80.** A counted
criterion -- `vocabulary(N, speak)`, like every vocabulary criterion in
both ladders -- asks how many items reached `MASTERY` on that channel.
A machine verdict cannot take any item there, by arithmetic. Spoken
mastery requires a human check per item, which at N=800 is not a
criterion, it is a staffing plan.

These were not accidents, and **Lock 3 is the one I would not touch.**
It is the project's whole position on machine judgement, written down in
four places. Everything below works around it rather than through it.

---

## Decision 1 -- criteria for production should be skill-shaped, not vocabulary-shaped

**Recommend: yes.**

Lock 3 makes `vocabulary(N, speak)` unsatisfiable for any interesting N,
and raising the cap to fix that would trade the project's position for a
number. The alternative is already in the ladder: a *named skill*
criterion, measured over a small generated item set, which is how
`skill(mora_sokuon)` and `final_consonants` work.

So: not "pronounce eight hundred words", but "hold the beat in the words
that have one" -- a handful of items, generated material, and a figure
that a session or two can actually move.

```prolog
% graph/ja/kana.pl, beside mora_sokuon
item(sokuon_spoken, skill, ja, n5, own(kana)).
gloss(sokuon_spoken, en, 'holds the doubled consonant when speaking').
gloss(sokuon_spoken, ja, '促音を伸ばして発音する').
requires(sokuon_spoken, mora_sokuon).
probe(sokuon_spoken, morae(sokuon)).

% graph/ja/ladder.pl
exit(ja, n5, skill(sokuon_spoken), 0.80, no_floor).
```

The `probe/2` is doing the work, and it is the same one `mora_sokuon`
already carries. `criterion_item(skill(S), S) :- probe(S, _)` means the
skill *is* the item, answers accumulate against it, and the material --
the words with a っ in them -- is drawn fresh each time by
`lp_kana_feature`. So the item set does not have to be enumerated, and
the criterion cannot go `thin` over a single word the way
`skill(mora_sokuon)` did before the probe existed.

`requires(sokuon_spoken, mora_sokuon)` is the edge that matters
pedagogically: you cannot be asked to hold a beat you cannot yet count.
It also crosses rungs, pre-school to n5, which the schema allows in that
direction only -- `violation(requires_from_above(...))` would catch it the
other way round.

**This also exposes something already in the English ladder.**
`final_consonants` is glossed *'ends a word without adding a vowel'* and
is measured by `probe(final_consonants, syllables(katakana))` -- the
student counts syllables, by typing. The name and the gloss describe
production; the probe measures knowledge *about* production. That is not
wrong, and it was the only thing possible before a microphone, but it
means **the English ladder has had a production criterion wearing a
typed probe since before Stage 0.** It is the first criterion that
should get a spoken counterpart, and the cleanest demonstration that
this is a shape the ladder already understands.

## Decision 2 -- which rungs ask at all

**Recommend: not pre-school. First spoken criterion at `ja n5` and
`en a1`.**

The Japanese argument cuts against me and is worth stating: the sokuon
is a *pre-school* skill (`exit(ja, preschool, skill(mora_sokuon), 0.85)`),
so the scorer's subject matter belongs on the bottom rung. I would still
not put it there, for two reasons. Pre-school is where a student has no
words to say -- `vocabulary(50, read)` is the rung's own vocabulary
criterion -- and a production criterion over fifty words a learner has
just met measures the recorder, not the learner. And pre-school's job is
the ear: five criteria about hearing and recognising, which is the right
order. Asking someone to perform a contrast before they can hear it is
how people stop.

n5 has eight hundred words and a student who has heard the distinction
for months. That is where producing it is a fair question.

Pre-school keeps `:speak` as **practice without assessment**, which it
already is, and which Decision 3 is partly about preserving.

## Decision 3 -- does a machine verdict count toward a criterion?

The real question, and the one I most want you to overrule me on if you
disagree.

Three options:

1. **Keep Lock 2.** Machine verdicts teach and never certify. A spoken
   criterion measures human checks only. Honest, and it makes the whole
   audio stack a practice tool that `:status` never mentions. The scorer
   becomes something the student uses and the ladder ignores.
2. **Open Lock 2, and report two numbers that are never averaged.**
   `lp_measure` takes a tier set instead of hard-coding `1`; a spoken
   criterion's status row carries both figures: *"machine: 78% over 40
   answers. Checked by a person: 6."*
3. **Count tier 5 as tier 1.** No. This is Lock 3 defeated by a
   different route, and it would make `:status` print a number that
   looks like the reading number and is not as trustworthy -- which
   `docs/projects/langpop-audio.md` §7 already forbids by name.

**Recommend (2),** and the argument is a precedent in the procedure
itself. `lp_measure` already reports accuracy and speed as two numbers
and refuses to combine them: *"a student who is right slowly has not
learned to read, and one number would hide that."* Machine-scored and
person-checked is the same shape of distinction, one layer up. The
mechanism for keeping two numbers apart is already built and already
argued for.

Cost: a tier set in `lp_measure`, a status row that can carry two
figures, `lp_status_text` and the booklet's wording, and the JSON-RPC
`status` shape. Not small, not deep.

## Decision 4 -- what an abstention does to the numerator

`near` is the scorer saying *I could not tell*. At tier 5 it moves the
belief in neither direction, deliberately.

In a criterion's accuracy it cannot go in the numerator. The question is
the denominator, and `lp_measure` has a strong existing opinion on a
neighbouring case: a `skip` counts in the denominator, because
*"declining to answer is evidence, and dropping it would let a student
raise their accuracy by answering only what they knew."*

**That argument does not transfer, and the difference is who declined.**
A skip is the student refusing. A `near` is the *instrument* refusing.
Counting it against the student charges them for the scorer's
uncertainty -- and we know that rate is not small: Kyoko, a clean
synthetic voice with no accent and no nerves, drew four abstentions out
of nineteen under `--voicetest`.

**Recommend: a `near` is in neither the numerator nor the denominator,
and the abstention rate is reported as a third number.** *"78% over 40
answers, 9 of which the scorer could not call."* That is the
`--voicetest` three-way tally exactly -- agreed, disagreed, abstained --
arriving one layer up, which is a sign the shape is right rather than a
coincidence.

If the abstention rate is high enough to make the criterion meaningless,
printing it is how anyone finds out.

## Decision 5 -- the response-time floor

Every exit carries one: `exit(ja, n5, vocabulary(800, read), 0.80, 4000)`
means 80% right, within four seconds. For reading that is a real
measure; a student who is right slowly has not learned to read.

For speaking it measures the recorder. Time-to-speak includes finding
the key, the countdown, and a person deciding whether they are ready,
and none of that is fluency.

**Recommend: spoken criteria carry `no_floor`, the status row omits the
speed figure rather than printing a meaningless one, and `--check`
refuses a spoken exit that names a numeric floor** -- so the next
criterion added cannot quietly reintroduce it. That last clause is the
pattern the ladder already uses on itself: `--check` refuses a rung with
no exit criterion, because A1 and C1 each shipped without one.

Smallest of the five, and the only one with no argument against it that
I can find.

---

## What gets built, if all five are accepted

1. `lp_can_score()` beside `lp_can_hear()` -- voice *and* recorder *and*
   scorer, all three, because two of three cannot ask the question. Then
   `VERIFIABLE_SPOKEN = [speak]`, conditional on it. An installation
   without a microphone goes on saying `needs_audio`, which is true.
2. `lp_measure` takes a tier set; `near` leaves both numerator and
   denominator; the abstention count comes back as a fourth result.
3. `sokuon_spoken` in `graph/ja/items.pl`, its exit in the ja ladder, and
   a spoken counterpart for `final_consonants` in the en ladder.
4. `no_floor` handled in `lp_status_rows`, worded in `lp_status_text`
   and in the booklet, refused by `--check` when a spoken exit names a
   number.
5. `lp_next` offers `:speak` on a rung that has a spoken criterion, and
   only when `lp_can_score()`.
6. Tests: the three locks each get one, so that reopening any of them by
   accident fails. In particular a test that a machine verdict alone
   cannot carry an item to `MASTERY`, which is Lock 3 written as an
   assertion rather than as a constant.

## What does not get built, under any of the five

A spoken criterion that can be satisfied without a person ever listening.
Lock 3 stays, `MACHINE_CAP` stays at 0.77, and the sentence the project
has been able to say since the microphone arrived stays true: *your
reading is at N5 and I cannot certify your pronunciation.*

The second pass needs ears. `--voicetest` was built so that the first
pass does not, and that is the whole of what it bought.
