# The pronunciation gap, and what would close it

**Status:** not built, deliberately. This is a record of a gap the engine
cannot fill today, why it is the hardest part of the problem, and what an
integration would have to look like. Raised while adding channel-aware
mastery (`examples/langpop/langpop.p`, `VERIFIABLE`).

## The problem

For a Japanese speaker learning English, pronunciation and natural
cadence are not a topic in the syllabus — they are the mountain. And the
work is *unlearning*, which is a different exercise from learning and
needs its own items; `examples/langpop/graph/en/items.pl` already says so
about the katakana loanword traps, and the same argument applies with
more force to the sounds.

Four things compound, and they compound in a particular order:

1. **Little exposure to correct pronunciation.** The input that would
   let a learner self-correct is largely absent, so errors are not
   noticed, let alone fixed.
2. **The katakana box.** Every English word already has a Japanese
   phonological shape waiting for it. レストラン is not a mispronunciation
   of *restaurant* — it is a correct pronunciation of a different,
   Japanese, word that the learner already owns. The script that makes
   reading easier is what makes speaking harder, and it is not a gap in
   knowledge but a competing, fluent, correct habit.
3. **Testing fatigue.** The one thing a learner in this position has had
   plenty of is being tested. Another test that reports a low number is
   not information, it is discouragement, and it has been received
   before.
4. **So it is abandoned.** Commonly after years of living in an
   English-speaking country, which is the part that should be sobering:
   immersion alone does not fix it, so neither will a tool that offers
   only more immersion.

Note what (3) implies for design. A measurement that merely reports
*wrong* is worse than no measurement, because the learner has already
heard it. Anything built here has to tell someone **which** thing to
change and let them hear the difference — a verdict with no actionable
contrast is just the old test again.

## Why the engine is structurally silent about it

This is not a missing feature so much as a visible hole, and the hole is
now explicit rather than disguised.

`graph/en/items.pl` carries twelve sound contrasts as first-class items —
`s_r_l`, `s_th_un`, `s_v_b`, `s_final`, `s_cluster` and the rest — with
Japanese glosses saying what a Japanese speaker substitutes for each
(`ラ行では区別されない`, `バ行で代用しがち`). The graph knows what the
problem is, per sound, in the learner's own language. The importer even
derives which English words exercise which contrast, from CMUdict
pronunciations (`import.p --source cmudict`): `library` has an R and an L
in it, so it *is* the /r/–/l/ exercise.

What is missing is any way to **check**. A sound contrast is judged on
the `hear` channel (`lp_channels/1`), and `hear` is not in `VERIFIABLE`,
because there is no audio anywhere in langpop. Concretely:

- all twelve English sound contrasts return `shape = "none"` from
  `lp_question/1` — they cannot be asked by typing;
- so `s_r_l` can never be mastered;
- so the `sound_contrasts` skill, which requires all twelve, can never be
  mastered;
- so `exit(en, preschool, sound_contrasts, 0.90, 3000)` can never be met.

That chain is already true and was true before this note. Channel-aware
mastery did not create it; it stopped it being quiet. The tutor now says
*cannot be checked here — needs audio* instead of reporting 0%, and
`langpop/status` carries `"verifiable": false` on such a criterion, so a
client cannot show the tool's limit as the student's ability.

The evidence tiers handle the rest honestly. An assignment plus a
self-reported result is tier 2, capped at `TIER2_CAP = 0.78`, below
`MASTERY = 0.80`. So a learner **cannot** claim their way to a
pronunciation score: the arithmetic refuses it, rather than a policy
refusing it. What langpop can say today is *your reading is at this
level and I cannot certify your pronunciation*, which is true, and better
than one number that averages the two.

## What would close it

Not speech recognition. The useful observation is that the question is
far narrower than ASR:

> Given an audio sample and the target word *restaurant*, did they say it
> correctly?

That is a **decision**, not a transcription — the same shape as a small
image classifier answering *is that a car?* rather than describing the
photograph. The target is known in advance, the vocabulary is closed (the
item set of the level), and the answer is a verdict plus, ideally, which
contrast failed. A model that does only this can be far smaller, cheaper
and more private than one that transcribes open speech, and it can
plausibly run locally — which matters, because audio of someone's voice
is the most sensitive thing this project would ever touch, and the
current arrangement (no network, profiles in `~/.langpop/`) should not be
given up to get a pronunciation score.

What the graph already provides, and would not need to change:

- the **target**: `form(Id, ipa, '/wɜrld/')`, from CMUdict;
- the **item being tested**, with its own belief and channel;
- the **expected failure mode**: `confusable/3` and the contrast items
  say what a Japanese speaker is likely to substitute, so a verdict can
  be checked against a specific hypothesis rather than a general notion
  of wrongness. This is what makes the output actionable, and so what
  answers the fatigue problem in (3) above.

What would have to be built:

1. **Capture.** A way to record a sample. langpop has no audio path at
   all; `:assign` and an external recorder is the cheap first step, and
   keeps the engine out of the device business.
2. **A verdict interface, not a model.** The engine should ask
   `pronounced(Item, Sample) -> (ok, which_contrast_failed)` across a
   boundary, exactly as `langpop/card.render` is a method rather than a
   drawing library. Then the model is swappable and the graph stays
   ignorant of it.
3. **An evidence tier for a machine verdict.** It is not a human check
   and it is not a self-report. It belongs between them, with its own
   cap, for the same reason inferred prerequisite evidence does: a
   confident model is still a model. One number in `langpop.p` beside
   `MASTERY`, `TIER2_CAP` and `TIER3_CAP`.
4. **Then, and only then,** `hear` and a `speak` channel join
   `VERIFIABLE`, and the criteria that are currently unverifiable start
   returning numbers.

Note the ordering: (3) before (4). The tier is what keeps a machine
verdict from silently becoming as authoritative as a teacher's ear, and
it is cheap to add now and awkward to retrofit after clients have begun
trusting a score.

## What not to do

- **Do not report a pronunciation score that cannot be verified.** The
  current *cannot be checked here* is the correct output and should stay
  until something can genuinely check.
- **Do not send audio anywhere by default.** See the privacy note above.
  If a hosted model is ever used, it is an explicit, per-session choice,
  and the local path must remain.
- **Do not grade free speech** before the narrow case works. *Did they
  say `restaurant` correctly* is tractable and useful; judging a
  self-introduction is Proposal C territory and a much larger claim.

## Related

- `examples/langpop/langpop.p` — `lp_channels/1`, `VERIFIABLE`, the
  evidence tiers
- `examples/langpop/graph/en/items.pl` — the twelve contrasts and the
  unlearning argument
- `examples/langpop/import.p` — `--source cmudict`, which derives the
  contrast each word exercises
- `examples/langpop/graph/resources.pl` — `r_forvo_ja`, `r_minimal_rl`:
  the catalogue already points at where a human can hear the difference
