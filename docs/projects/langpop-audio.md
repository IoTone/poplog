# Audio for langpop: the options, and a plan

**Status:** a plan, not a build. Written before anything audio exists in
the tree, because the first decision — *what question are we asking the
microphone?* — determines almost everything after it, and the obvious
answer is the wrong one.

Companion to `docs/projects/langpop-pronunciation.md`, which records
**why the gap is hard** (the katakana box, testing fatigue, why immersion
alone does not close it). This document is about **what to build**.

As of 2026-10-21. Prices and model versions move; the architecture
arguments do not.

## 0. The one finding that reframes everything

> *"In typical ASR systems, speaker errors, such as incorrect accent
> positions, mispronunciations, fillers, and hesitations, are
> intentionally discarded."*
> — [Building Tailored Speech Recognizers for Japanese Speaking
> Assessment](https://arxiv.org/pdf/2509.20655) (2025)

**A speech recogniser is built to be robust to exactly the signal
langpop needs to measure.** Whisper's achievement is that it transcribes
*restaurant* whether an American, a Scot or a Japanese speaker says it.
That robustness is the product. For a tutor it is the defect: the one
thing we want to know is precisely what Whisper is trained to normalise
away.

So the first rule of this plan is: **do not reach for an ASR model.**
Transcription is not the question, and a pipeline built on it will be
fighting its own foundation. What we want is nearer to a measurement
instrument than a recogniser.

## 1. Three questions, not one

"Add audio" is three separate problems with different difficulties, and
conflating them is how this gets expensive. In order of cost:

| # | question | channel | difficulty |
| --- | --- | --- | --- |
| **A** | Can the student **hear** a correct model of this item? | `hear`, input side | **easy** — this is TTS, and it is solved |
| **B** | Was きって two beats or three? | `speak`, timing | **moderate** — needs alignment, not phonemes |
| **C** | Did they say *restaurant* correctly, and **which contrast failed**? | `speak`, segmental | **hard** — needs phoneme-level scoring |

(A) is not assessment at all and has no privacy problem. It is also the
thing the pronunciation note names as **compounding factor #1**: *little
exposure to correct pronunciation*. A learner who has never heard the
target cannot be fairly asked to produce it, so building (C) before (A)
would be testing someone on material we declined to teach.

(B) is the narrowest *measurement* worth making, and it is the one
langpop is already structurally ready for — see §5.

(C) is the one everybody means by "pronunciation scoring", and it is
last for a reason.

## 2. What the graph already provides

Nothing in §1 requires new facts. The graph was built for this without
meaning to be:

- **the target**: `form(Id, ipa, '/wɜrld/')`, imported from CMUdict by
  `import.p --source cmudict`;
- **the item under test**, with its own belief, channel and level;
- **the expected failure mode**: the twelve sound contrasts
  (`s_r_l`, `s_th_un`, `s_v_b`, `s_final`, `s_cluster` …) with Japanese
  glosses saying what a Japanese speaker substitutes for each, plus
  `confusable/3`. This is what makes a verdict *actionable*: not *wrong*
  but *you produced ラ where the word needs /l/*;
- **which words exercise which contrast**, already derived — `library`
  has an R and an L in it, so it **is** the /r/–/l/ exercise;
- **the mora skills**: `skill(mora_count)`, `skill(mora_sokuon)`,
  `skill(mora_long_vowel)`, `skill(mora_moraic_n)` — four declared
  criteria about **timing**, which is question (B).

## 3. The options

### Option 1 — a hosted pronunciation-assessment API

[Azure's Pronunciation
Assessment](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-pronunciation-assessment)
scores accuracy, fluency, completeness and prosody, and will return
**phoneme-level** scores through its granularity option. SpeechAce,
SpeechSuper and ELSA are the comparable commercial offerings, and all of
them also do unscripted ("open response") modes.

*For:* working phoneme scores today, no modelling, no training data, and
a reference implementation of the problem to measure ourselves against.

*Against, and it is decisive by default:* **the audio leaves the
machine.** A recording of someone's voice is the most sensitive thing
this project would ever touch, and the current arrangement is no network
at all, profiles in `~/.langpop/`. Giving that up to get a score is a bad
trade, and it is not reversible for the person who already sent the clip.

*Also worth knowing before committing:* a [Microsoft Q&A
thread](https://learn.microsoft.com/en-us/answers/questions/1284533/azure-pronunciation-assessment-returning-the-same)
reports phoneme scores coming back nearly identical across a word even
when a single sound was wrong. If that is still true, the per-phoneme
number — the only part langpop actually wants — may not carry the
information its name implies. **Test that on our own audio before paying
for it.**

*Cost, as of September 2026 and third-party:* Azure Standard real-time
around **$1.00/hour** with pronunciation as a **$0.30/hour** add-on;
SpeechAce around **$0.008 per 15-second request** on its mid plans
([comparison](https://api.toneperfect.app/blog/pronunciation-assessment-api-pricing-compared/)).
Microsoft's own documentation says pronunciation assessment costs the
same as speech-to-text at standard tier. The absolute numbers are not the
problem; the direction of the audio is.

### Option 2 — local forced alignment + GOP

The classical and still-standard approach: align the known text to the
audio, then score each phone by **goodness of pronunciation** — how
likely the acoustic model thinks the expected phone was, against the
best competing phone.

For Japanese this is a well-trodden path.
[pyJuliusAlign](https://github.com/timmahrt/pyJuliusAlign) wraps Julius
for forced alignment; the [Montreal Forced
Aligner](https://github.com/ntheanh201/phonetic-atlas) is the better-
maintained choice for a fresh start, and that same project pairs MFA with
fugashi/UniDic for mora and pitch-accent annotation — which is nearly the
shape question (B) wants.

*For:* interpretable per-phone numbers, entirely local, no training, and
an answer that maps one-to-one onto the contrast items the graph already
holds.

*Against:* a multi-stage pipeline (aligner + acoustic model + scorer),
each stage a dependency and a failure mode, and alignment on *learner*
speech is exactly where aligners are weakest — the audio is non-native,
which is the case the acoustic model saw least of.

**The cheap version of this is the one to copy.** TalTech's entry in the
[NOCASA 2025 challenge](https://arxiv.org/pdf/2509.03256) got its best
word-level system from **GOP features computed from the CTC emission
probabilities of a pretrained recogniser** — no Kaldi, no separate
aligner, no training. That is a few hundred lines over a model we would
be running anyway.

### Option 3 — local phoneme recognition, compared to the target

Run a phoneme-level CTC model (wav2vec2-style, or Allosaurus for
language-independent phones), get a phone sequence, and diff it against
the target from CMUdict.

*For:* the simplest thing to reason about and to explain to a learner —
*you produced /r/ where the word needs /l/* falls straight out of the
diff, with no score to calibrate and no threshold to argue about. It is
also the closest fit to how langpop already reports a wrong answer: not a
percentage but a **named confusion**, exactly like `confusable/3`.

*Against:* a phoneme recogniser on non-native speech is noisy, and a diff
has no notion of *nearly right*. Needs a confidence floor so the tutor
can say *I could not tell* rather than invent a verdict.

### Option 4 — end-to-end assessment models

The research frontier has moved to alignment-free scoring.
[OpenPA](https://arxiv.org/abs/2610.13826) (October 2026) is
forced-alignment-free and multi-granular;
[MultiPA](https://arxiv.org/pdf/2308.12490) targets open-response;
[GOPT](https://github.com/YuanGongND/gopt) has released code and a
pretrained model but still depends on Kaldi-generated phone-level
features. A [March 2026 paper](https://arxiv.org/html/2603.25150v1)
derives GOP without phoneme time alignment at all, using a confusion
network over an N-best list.

*For:* where the field is going, and better on free speech.

*Against:* **langpop does not have the free-speech problem.** Our target
is known in advance and the vocabulary is the item set of one level. GOP
methods are criticised for degrading in open-response settings — but the
closed-response setting is precisely the one we are in, which turns the
field's main complaint about GOP into a non-issue for us. Buying the
research-grade solution to a problem we do not have would be the wrong
kind of ambition.

### Also: TTS, for question (A)

Different problem, much easier, no privacy exposure, and the one that
should ship first.

- **Japanese.** VOICEVOX is the obvious local candidate and its
  Japanese naturalness is the reason, but I could not verify its current
  state or licence terms from the sources I checked — **confirm both
  before depending on it.**
- **Both languages.** [Kokoro](https://localaimaster.com/blog/kokoro-tts-local-setup)
  is an 82M-parameter model with **Apache-licensed weights**, 54 voices
  including Japanese, runs on CPU in roughly 2–3 GB. Apache is the right
  licence shape for this repo, and the size is right for a laptop.
- **Piper** is the other common choice, but note the licence has moved:
  the original is MIT while the [actively-led fork is
  GPL-3.0](https://github.com/OHF-Voice/piper1-gpl/discussions/199).
  Given how carefully this project has kept share-alike on upstream's
  layer (the whole `graph/*/generated/` arrangement), GPL-3.0 in-tree
  deserves a deliberate decision rather than a default.

A quality caveat that applies to all of them: none of the sources I found
evaluated **Japanese** naturalness specifically, and for teaching
pronunciation the model's own accent is the product. Listening tests, not
benchmarks.

## 4. The recommendation

Four stages, each useful on its own, each a gate on the next.

### Stage 0 — TTS, so the student can hear it

No assessment. A `say(Item)` that plays the target, cached as a file per
item exactly as `card.render` caches an SVG per item. Local model,
Apache-licensed if Kokoro holds up, VOICEVOX for Japanese if its terms
allow.

This closes compounding factor #1, it is the half of the `hear` channel
that needs no verdict at all, and it is worth shipping even if nothing
below it ever gets built.

**It does not make `hear` verifiable.** Playing a sound and checking a
student heard it are different claims, and the ladder must keep saying
*cannot be checked here* until something checks.

### Stage 1 — mora timing, and it is smaller than it was

**Revised 2026-10-21, and the revision is the useful part.** This stage
was written as *`skill(mora_count)` and `skill(mora_sokuon)` are `thin`
in `--audit`: both reduce to あ, one item, two criteria. They are thin
because a mora is a unit of time and the engine has no way to observe
time — you cannot test "きって is three beats" by typing.*

**That last clause was wrong, and half this stage shipped without a
microphone.** You can test it by typing: *how many beats is this?* is a
reading question with a number for an answer, and the number is
computable from the kana — every kana one beat, a small ゃゅょ joining
the one before it, っ and ん and ー beats of their own. `probe(Skill,
morae(Feature))` and `lp_morae/1`, in `f80513f`. The whole Japanese
pre-school rung is now `ok`.

So the distinction this stage rests on is sharper than when it was
written:

| | needs | status |
| --- | --- | --- |
| **knowing** how many beats きって has | nothing | **done** |
| **producing** three beats when you say it | a microphone | this stage |

What is left is production only, and it is still the cheapest honest
verdict in the audio space:

- it needs **no phoneme model** — beat boundaries, a duration per mora,
  a comparison against a count the graph already computes;
- energy and a VAD get a long way; alignment gets the rest;
- the expected answer is **already known and already right**, because
  `lp_morae/1` produces it for the typed question. The audio half only
  has to agree with a number that exists;
- the verdict is discrete, so it needs no threshold calibrated against
  native speakers;
- and it is diagnosable the way this project insists on — *you gave きて
  two beats where きって has three* is actionable, where *68%* is not.

The general lesson is worth carrying into the rest of this document:
**ask what the question actually needs before assuming it needs audio.**
Two of the four criteria this stage claimed to unblock were never an
audio problem at all.

### Stage 2 — the English contrast verdict

Option 3 (phoneme CTC + diff against the CMUdict target) behind the
interface in §5, with Option 2's CTC-GOP as the scoring refinement if the
diff alone proves too brittle. Local. Confidence floor, so *I could not
tell* is a permitted answer.

### Stage 3 — a hosted comparator, for calibration only

Run Option 1 against a held-out set **once**, to find out how far off the
local verdict is. Never in the student loop, never by default, and only
on audio recorded for that purpose with the person's explicit say-so.

## 5. The interface, and the evidence tier

Two things have to exist before any of Stage 1–3 lands, and both are
cheap now and awkward to retrofit.

**A verdict interface, not a model.** The engine asks across a boundary:

```
pronounced(Item, Sample) -> (verdict, which_contrast_failed, confidence)
```

exactly as `langpop/card.render` is a method rather than a drawing
library. Then the model is swappable, the graph stays ignorant of it, and
Stage 1 and Stage 2 can use different machinery behind one call.

**Its own evidence tier.** A machine verdict is not a human check and not
a self-report; it belongs between them, with its own cap, for the same
reason the inferred tier has one: *a confident model is still a model*.
One constant beside `MASTERY`, `TIER2_CAP`, `TIER3_CAP` and
`INFERRED_CAP` — and `--audit` gains a verdict for *machine-verified*
so a client can tell it apart from a check.

**Then, and only then**, `hear` and a new `speak` channel join
`VERIFIABLE`, and the criteria that currently return *cannot be checked
here* start returning numbers. The ordering is the point: the tier is
what keeps a machine verdict from silently becoming as authoritative as a
teacher's ear.

## 6. What I need from you

Four decisions, and the plan branches on them:

1. **Is local-only a hard constraint, or a default with an opt-out?** I
   have written it as hard, because that is the current arrangement and
   because audio is the most sensitive thing here. If a hosted API is
   acceptable with consent, Stage 2 gets much cheaper and Stage 3 becomes
   the main path rather than a calibration run.
2. **Which of your existing STT/TTS stacks should this sit on?** You are
   already running this locally and against APIs. If there is a model
   already loaded on your machine, the right plan may be *use that one*
   rather than anything above — particularly for Stage 0, where the
   requirement is just a decent Japanese voice.
3. **English-for-Japanese-speakers first, or Japanese-for-you first?**
   Stage 1 (mora) serves your own learning and unblocks four criteria.
   Stage 2 (contrasts) serves the harder and more valuable problem. They
   are independent.
4. **GPL-3.0 in-tree: yes or no?** It decides Piper vs Kokoro, and it is
   the same question the importer answered for data by keeping generated
   content out of the repo entirely.

## 7. What not to do

- **Do not start with ASR.** §0. The model's robustness is our enemy.
- **Do not report a pronunciation score before a verdict interface and
  an evidence tier exist.** A number that looks like the reading number
  but is not as trustworthy is worse than *cannot be checked here*.
- **Do not grade free speech** before the narrow case works. *Did they
  say `restaurant` correctly* is tractable; judging a self-introduction
  is Proposal C territory and a much larger claim.
- **Do not send audio anywhere by default**, and if a hosted model is
  ever used, make it an explicit per-session choice with the local path
  still present.
- **Do not let a verdict be just a verdict.** The pronunciation note's
  argument stands: a measurement that reports only *wrong* is worse than
  no measurement, because the learner has heard it before. Every verdict
  must name a contrast and offer the difference to hear.

## Related

- `docs/projects/langpop-pronunciation.md` — why this gap is the
  mountain, and the four compounding factors
- `examples/langpop/langpop.p` — `lp_channels/1`, `VERIFIABLE`, the
  evidence tiers, `--audit`
- `examples/langpop/graph/en/items.pl` — the twelve contrasts
- `examples/langpop/graph/ja/kana.pl` — the mora skills
- `examples/langpop/import.p` — `--source cmudict`, the IPA targets
- `examples/langpop/graph/resources.pl` — `r_forvo_ja`, `r_minimal_rl`
