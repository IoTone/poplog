# Audio for langpop: the options, and a plan

**Status:** a plan, not a build — but no longer an open question.
**Local-only is a hard constraint and Kokoro is the TTS**, decided
2026-10-21; §6 records what that settles and what it costs. Written
before anything audio exists in the tree, because the first decision —
*what question are we asking the microphone?* — determines almost
everything after it, and the obvious answer is the wrong one.

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

### Option 0 — the LLM runtime, which is not an option

Asked directly, because it is where anyone already running local models
starts: *we have ollama and llama.cpp, can they do this?*

**No, and the reason is instructive.** `llama.cpp` genuinely takes audio
now — [`libmtmd`](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md)
and `llama-server`'s `input_audio` content parts, with pre-quantized
GGUFs for Ultravox 0.5 1B and 8B ([PR
#13714](https://github.com/ggml-org/llama.cpp/pull/13714)) — though the
docs call it *"highly experimental"* and Qwen2-Audio has no GGUF because
the results were *"very poor"*. Ollama has no native audio at all: the
TTS request is closed as a duplicate of an older open one, and audio
input is still a feature request.

But working perfectly, that path is **ASR-shaped**, and §0 applies in
full. An Ultravox GGUF transcribes *restaurant* whichever way you say
it. That is its product and our defect.

**One consequence corrects Option 2 below.** The cheap GOP trick is
*"compute GOP from the CTC emission probabilities of a recogniser we
would be running anyway"* — but under an LLM-runtime stack there is no
such model. **Whisper is autoregressive seq2seq, not CTC**: it yields
token log-probabilities, not frame-level phone posteriors. A
[2024 study](https://taylorarnold.org/pdf/2024-whisperl2.pdf) of
whisper.cpp's confidence scores for L2 scoring finds they can *flag*
likely errors but notes they have not been validated against human
judgment the way forced-alignment GOP has. So the phone posteriors have
to come from a model chosen for the purpose, and the cost of local-only
is not quality — it is the pretence that one runtime does everything.

### Option 1 — a hosted pronunciation-assessment API — **ruled out**

Recorded because the reasoning should survive the decision, not because
it is live.

[Azure's Pronunciation
Assessment](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-pronunciation-assessment)
returns phoneme-level scores; SpeechAce, SpeechSuper and ELSA are
comparable. Around **$1.00/hour** plus a **$0.30/hour** pronunciation
add-on, or about **$0.008 per 15-second request**
([comparison](https://api.toneperfect.app/blog/pronunciation-assessment-api-pricing-compared/)).

*Ruled out because the audio leaves the machine.* A recording of
someone's voice is the most sensitive thing this project would ever
touch, the current arrangement is no network at all, and the trade is
not reversible for the person who already sent the clip.

Worth keeping on file even so: a [Microsoft Q&A
thread](https://learn.microsoft.com/en-us/answers/questions/1284533/azure-pronunciation-assessment-returning-the-same)
reports phoneme scores coming back nearly identical across a word even
when one sound was wrong. If that is still true, the per-phoneme number
— the only part langpop wanted — may not carry the information its name
implies. The hosted path was never as far ahead as it looked.

### Option 2 — local forced alignment + GOP

The classical and still-standard approach: align the known text to the
audio, then score each phone by **goodness of pronunciation** — how
likely the acoustic model thinks the expected phone was, against the
best competing phone.

For Japanese this is a well-trodden path.
[pyJuliusAlign](https://github.com/timmahrt/pyJuliusAlign) wraps Julius
for forced alignment; the [Montreal Forced
Aligner](https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner)
is the better-maintained choice for a fresh start, with a
[Japanese acoustic model](https://mfa-models.readthedocs.io/en/latest/acoustic/Japanese/Japanese%20MFA%20acoustic%20model%20v3_0_0.html)
published. [phonetic-atlas](https://github.com/ntheanh201/phonetic-atlas)
is worth reading as prior art: it pairs MFA with wav2vec2 and
fugashi/UniDic for mora and pitch-accent annotation across Japanese and
English, which is nearly the shape question (B) wants.

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

**Two corrections, from Option 0 and from §3's stack note.** The
recogniser we would *otherwise* be running is Whisper, which is not CTC
and has no emission probabilities to take — so this trick needs the
phoneme CTC model of Option 3, not an ASR model. Given that model, it is
the refinement Stage 2 reaches for first, and **MFA stops being a
runtime dependency**: the posteriors it would align with are already in
hand. MFA's place is offline validation in Stage 3.

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

### Also: TTS, for question (A) — **settled**

**Kokoro.** Not a recommendation any more: it is already in use here and
already fine, so Stage 0 is wiring rather than evaluation. 82M
parameters, 54 voices including Japanese, CPU, **Apache-licensed
weights** — the right licence shape for this repo and the right size for
a laptop.

The two alternatives are now closed, and both for licence reasons:

- **VOICEVOX — no.** The §3 note asked for its terms to be confirmed
  before depending on it. They are worse than expected. The
  [engine README](https://github.com/VOICEVOX/voicevox_engine) states
  it is *"LGPL v3 と、ソースコードの公開が不要な別ライセンスのデュアル
  ライセンス"* — LGPL-3, or a private licence negotiated with the
  author. On top of that the **character voices carry separate
  per-character terms, several requiring credit**
  ([guide](https://book.st-hakky.com/en/data-science/voicevox-usage-and-commercial-use)).
  That is Piper's GPL-3.0 problem plus a second layer on the voices.
  Its Japanese naturalness is real and it is still the right thing to
  *listen to* when judging Kokoro's Japanese by ear.
- **Piper — moot.** The question that made it interesting was *what if
  Kokoro's Japanese is not good enough*, and the
  [actively-led fork is GPL-3.0](https://github.com/OHF-Voice/piper1-gpl/discussions/199)
  anyway.

The quality caveat survives the decision: none of the sources evaluated
**Japanese** naturalness specifically, and for teaching pronunciation the
model's own accent *is* the product. Kokoro is in use for English here;
its Japanese voices need a **listening test before Stage 0 ships**, not a
benchmark. That is the one piece of Stage 0 that is not wiring.

### The local stack, and the simplification that matters

| question | local component | licence |
| --- | --- | --- |
| **A** hear the target | **Kokoro**, 82M, CPU | Apache-2.0 |
| **B** mora timing | frame posteriors from the model below | — |
| **C** contrast verdict | [`facebook/wav2vec2-lv-60-espeak-cv-ft`](https://huggingface.co/facebook/wav2vec2-lv-60-espeak-cv-ft/blob/main/README.md?code=true) | Apache-2.0 |
| offline check | [MFA](https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner) + [Japanese acoustic model v3.0.0](https://mfa-models.readthedocs.io/en/latest/acoustic/Japanese/Japanese%20MFA%20acoustic%20model%20v3_0_0.html) | MIT code / **CC BY 4.0** model |

**Two models at runtime, not three, and the reason is the whole plan.**
Stage 1 (mora timing) was scoped as *forced alignment*, which meant MFA,
which means a Kaldi-based conda install. But Stage 2 needs a phoneme CTC
model regardless — and a CTC model emits **frame-level phone
posteriors**, which is exactly what alignment is made of. The same model
therefore serves both: boundaries for (B), the phone sequence for (C).

So **MFA is demoted from a runtime dependency to an offline validation
tool** — the thing we align a held-out set with to check the cheap path
agrees. Its licence split (MIT code, CC BY 4.0 models) is the exact
arrangement `graph/*/generated/` already exists for, so no new policy is
needed to use it that way.

And this is the right home for Option 2's CTC-GOP refinement: the
posteriors are already in hand, so GOP is arithmetic over something we
compute anyway. The trick that did *not* work on Whisper works here.

**Allosaurus is out** — 2000+ languages is tempting but it is
[GPL-3.0](https://github.com/xinjli/allosaurus), the same decision as
Piper and VOICEVOX. Net result: **no GPL anywhere in the audio path.**

One integration caveat to plan around rather than discover: the espeak-
trained model emits **espeak phone labels, not textbook IPA**, so a
mapping layer sits between it and `form(Id, ipa, _)`. It is also
multilingual (~60 languages, `ja` among them), not a Japanese model.

## 4. The plan

Five stages. Each is useful alone, each gates the next, and **the first
two contain no microphone and no model** — which is deliberate, because
both are cheap now and awkward to retrofit.

Ordering note, answering §6's one remaining question by recommendation
rather than by asking: **Japanese mora before English contrasts.** Not
because it matters more — the English gap is the mountain — but because
Stage 2 needs the seam, the tier, the side-car, the cache and the mic
path all working, and Stage 1 exercises every one of them against a
**verdict that is already known to be correct**. `lp_morae/1` computes
the right answer today. Stage 1 is therefore the only stage that can be
debugged without first deciding whether the model or the plumbing is
wrong.

### Stage 0 — `say(Item)`, so the student can hear it

Kokoro behind a cache. No assessment, no verdict, no microphone.

- **Shape it like `card.render`.** A file per item, generated on demand
  and kept, exactly as the card exporter caches an SVG per item. The
  precedent is in the tree; follow it rather than inventing a second
  caching story.
- **Cache key is not the item id.** It is `{item, voice, model version,
  text hash}`. A voice change or a corrected `form/3` must invalidate,
  or the student hears yesterday's reading of a word we have since
  fixed. Store the manifest beside the audio in `~/.langpop/audio/`.
- **Never synthesise inside a question.** The engine must not block a
  prompt on a model load. Pre-generate per level — `--audio <level>`,
  the same shape as `--sheet` and `--zine`, which both already render a
  level's worth of material in one pass.
- **One new method**, `langpop/audio.say`, returning a path and not
  bytes: the TUI plays it, the protocol stays textual, and an
  18th method is a smaller change than an audio transport.
- **The listening test gates this stage**, per §3: Kokoro's *Japanese*
  judged by ear before it teaches anyone pronunciation.

**It does not make `hear` verifiable.** Playing a sound and checking a
student heard it are different claims, and the ladder must keep saying
*cannot be checked here* until something checks.

### Stage A — the seam and the tier, before any audio arrives

This was buried in §5 as a precondition. It is a stage, it is first, and
it is maybe two hundred lines.

1. **The side-car boundary.** Pop-11 is not going to do DSP and Poplog
   is not going to load ONNX. The models live in a **Python side-car
   speaking the same JSON-RPC the engine already speaks**, started on
   demand, holding the only dependency-heavy part of the system. The
   engine sends an item and a sample path; it receives a verdict. If the
   side-car is not running, every audio criterion reports exactly what
   it reports today: *cannot be checked here.* That is the property worth
   paying for — **the whole audio feature is optional at runtime**, and
   the six test suites stay green on a machine with no models at all.
2. **One call, both stages.**
   ```
   pronounced(Item, Sample) -> (verdict, which_contrast_failed, confidence)
   ```
   Stage 1 and Stage 2 put different machinery behind it and the graph
   stays ignorant of which.
3. **`MACHINE_CAP`, a new evidence tier.** A machine verdict is not a
   human check and not a self-report, so it caps between them. The
   existing constants are `MASTERY = 0.80`, `TIER2_CAP = 0.78`,
   `INFERRED_CAP = 0.75`, `TIER3_CAP = 0.50`; machine-verified belongs
   **strictly between `INFERRED_CAP` and `TIER2_CAP`** — above inference
   because something was actually observed, below a human check because
   *a confident model is still a model*. `0.77` is the proposal and the
   number is worth arguing about; the ordering is not.
4. **`--audit` learns a `machine` verdict**, so a client can tell a
   machine verdict from a check, and so the 14 criteria currently
   reporting `needs_audio` can report *which kind* of audio they need.
5. **`speak` joins the channel list but not `VERIFIABLE`.** It becomes
   verifiable when Stage 1 returns numbers, and not one commit earlier.

### Stage 1 — mora production

**Revised 2026-10-21, and the revision is the useful part.** This stage
was written as *you cannot test "きって is three beats" by typing.* That
was wrong, and half this stage shipped without a microphone: *how many
beats is this?* is a reading question with a number for an answer, and
the number is computable from the kana. `probe(Skill, morae(Feature))`
and `lp_morae/1`, in `f80513f`. The whole Japanese pre-school rung is
now `ok`.

| | needs | status |
| --- | --- | --- |
| **knowing** how many beats きって has | nothing | **done** |
| **producing** three beats when you say it | a microphone | this stage |

What is left is production only, and it is still the cheapest honest
verdict in the audio space:

- **no phoneme model and no new download** — mora boundaries from the
  frame posteriors of the model Stage 2 needs anyway;
- **the expected answer already exists and is already right**, because
  `lp_morae/1` produces it for the typed question. The audio half only
  has to agree with a number the engine computes;
- **the verdict is discrete**, so there is no threshold to calibrate
  against native speakers;
- and it is diagnosable the way this project insists on — *you gave きて
  two beats where きって has three*, not *68%*.

**The hazard to design around, named now: っ is silence.** A geminate is
a closure — the measurement is the *gap*. Consumer capture pipelines
suppress gaps for a living, and macOS voice isolation and noise gating
will cheerfully remove the only acoustic evidence `mora_sokuon` has.
**Record raw, with every enhancement off**, and verify on a recording
where we can see the closure before trusting a single verdict. A plan
that discovers this after building the scorer will blame the scorer.

### Stage 2 — the English contrast verdict

Option 3, behind Stage A's interface, with Option 2's CTC-GOP as the
refinement if the diff alone proves brittle:

1. phone sequence from the CTC model;
2. espeak labels mapped to our IPA (§3's caveat);
3. diff against `form(Id, ipa, _)`, already imported from CMUdict;
4. the difference matched to one of the twelve contrasts, so the verdict
   is **a named confusion** — *you produced ラ where the word needs
   /l/* — and not a score;
5. a **confidence floor**, so *I could not tell* is a permitted answer.
   A tutor that guesses is worse than one that abstains.

### Stage 3 — calibration, which local-only makes harder

The old Stage 3 was *run the hosted API once against a held-out set to
find out how far off we are.* Ruling out the hosted path **removes our
only external ground truth**, and that is the real price of local-only —
not accuracy, but the absence of anything to check accuracy against. A
threshold set by assertion is how a measurement instrument quietly
becomes decoration.

Two substitutes, in order of preference:

1. **A publicly scored corpus.** `speechocean762` is the obvious
   candidate — open, phone-level human scores, L2 English. **Its licence
   is unverified and that check comes before it enters the plan**, which
   is the same discipline that rejected NGSL and the zine template.
2. **Our own listening labels.** Smaller, slower, ours, and for Japanese
   mora it may be enough: a native speaker counting beats is not a
   difficult annotation task, and Stage 1's verdict is discrete.

MFA, per §3, is the third leg of this: align the held-out set properly,
offline, and see whether the cheap posterior path agrees.

**Report the agreement number in this document.** Not a claim that it
works — a number.

## 5. The interface, and the evidence tier

Both items that used to live here are now **Stage A**, because calling
them preconditions did not get them built. What remains is the argument
for why they come first:

**Then, and only then**, `hear` and `speak` join `VERIFIABLE`, and the
criteria that currently return *cannot be checked here* start returning
numbers. The ordering is the point: the tier is what keeps a machine
verdict from silently becoming as authoritative as a teacher's ear.

## 6. Decisions taken, and the one left

Three of the four questions this section used to ask are answered.

1. **Local-only: hard.** Not a default with an opt-out. This removes
   Option 1 and the old Stage 3, and §4's Stage 3 absorbs the cost.
2. **The stack: Kokoro for TTS — already running and already fine — and
   exactly one more model**, a phoneme CTC model, serving both Stage 1
   and Stage 2. No ASR anywhere. No LLM runtime in the audio path.
3. **GPL-3.0 in-tree: not needed, so no.** Kokoro is Apache, the CTC
   model is Apache, MFA is MIT code with CC BY 4.0 models used offline.
   Piper, VOICEVOX and Allosaurus all drop out on the same test.

**Left open: nothing blocking.** §4 answers the English-first question
by recommendation — Japanese mora first, because it is the only stage
whose correct answer is already known — and that is a reversible call,
not a decision needing a sign-off. Stage 0 and Stage A are useful under
either ordering.

The two checks that gate work rather than planning:

- **Kokoro's Japanese, by ear**, before Stage 0 ships;
- **`speechocean762`'s licence**, before Stage 3 depends on it.

## 7. What not to do

- **Do not start with ASR**, and that now includes the convenient one.
  §0 and Option 0: an audio GGUF under llama.cpp is still a recogniser,
  and a recogniser is trained to normalise away the only signal we want.
- **Do not make the side-car mandatory.** If the models are absent, every
  audio criterion must report *cannot be checked here* and every test
  suite must stay green. The day audio becomes a hard dependency is the
  day langpop stops running on a plain Poplog install.
- **Do not take MFA as a runtime dependency.** A Kaldi conda stack to
  count beats, when the CTC model we already need emits the posteriors
  alignment is made of, is weight without a question behind it. Offline
  validation only.
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
