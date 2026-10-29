# langpop on its own, and climbing the whole ladder

Three questions, asked together because the answers depend on each
other: carve langpop out of the Poplog tree, decide what it means to
*validate* a climb from pre-school to the top of each ladder, and work
out whether a local model can be the student who climbs it.

Nothing here is built. Every number in the first two parts was measured
in the tree on 2026-10-28 and says where it came from. **Decisions are
marked `yes` / `no` / `other`.**

---

# Part 1 -- the carve

## What actually moves

`git log` over `examples/langpop` and `docs/projects/langpop-*.md`:

| | |
|---|---|
| commits touching langpop | **44**, the first `9010925` (2026-10-19), the last `f01eb23` (2026-10-26) |
| commits on the branch in total | 691 |
| files in the directory | 49, 1.2 MB |
| paths those 44 commits touch outside `examples/langpop/` | 7 |

The seven: five `docs/projects/langpop-*.md` (audio, function-words,
japanese-tranche, production-criteria, pronunciation -- six, with this
one), one row in
`examples/README.md`, and -- in one commit -- `gfx-font-test`,
`pop/extern/fonts/NotoSansJP.ttf` and `OFL.txt`.

**The font does not come.** Nothing under `examples/langpop` names
NotoSansJP: that commit was doing two things, and the SVG cards ask for
a family by name and let the renderer find it. The `examples/README.md`
row does not come either; it is a row in an index that stays behind.

So the carve is: **44 commits, `examples/langpop/` to the root, plus
the five project docs into `docs/`.** That is unusually clean -- the
history was written in one directory and never wandered.

## The three things that break

**1. Hard-coded load paths.** `server.p`, `client.p`, `dump.p` and the
test suites all say

```pop11
load 'examples/langpop/langpop.p';
```

and the tests are invoked as `./poplog basepop11
examples/langpop/tests/test_langpop.p`. Moving the directory to the root
breaks every one. There is already a right answer in the tree --
`langpop_dir`, set by `find_dir()` -- so the fix is mechanical: one
`load` of `langpop.p` by a path relative to the loading file, and
`langpop_dir` for everything after. **One commit, made in the Poplog
tree before the carve**, so that the carved history is already correct
and no commit in the new repo is broken at its own revision.

**2. Poplog library dependencies, two of them younger than langpop.**

| lib | lives at | last touched |
|---|---|---|
| `jsonrpc` | `pop/lib/lib/jsonrpc.p` | 2026-10-20 -- *during* langpop's development |
| `json` | `pop/lib/lib/json.p` | 2026-10-01 |
| `utf8`, `datetime`, `poptest` | `pop/lib/lib/` | 2026-08-10, stable |

`jsonrpc.p` and `json.p` are not incidental: `jsonrpc` was finished to
make `server.p` possible, and `json_generate`'s dropped `false` is one
of the traps in langpop's own README. A standalone langpop needs a
Poplog that has them.

Three ways, and I would not vendor:

1. **Declare a minimum Poplog, and check it at startup.** `langpop.p`
   already runs a `--check`; add to it a probe for `json_object` and
   `jsonrpc_obj` and fail with the sentence *"needs Poplog with
   lib/jsonrpc (2026-10-20 or later); see README"*. Cheapest, honest,
   and it fails at the only moment anybody can act on it.
2. **Vendor `json.p` and `jsonrpc.p` into `lib/`** and prepend to
   `popautolist`. Works offline, and guarantees drift: two copies of a
   library whose bugs are being fixed in the other repo.
3. **Submodule the Poplog tree.** A 100 MB dependency for two files.

**Recommend (1)**, with a named release. The project already publishes
builds to the `poplog-builds` bucket, so "needs release X" is a
sentence a reader can act on.

**3. The invocation.** Everything is `./poplog basepop11 ...`, which is
a wrapper in the Poplog tree, not in langpop. The new repo needs its
own two-line `./langpop` that finds a Poplog (`$usepop`, `which poplog`,
then a guess) and reports the dependency failure above if it cannot.

## Mechanics

```bash
# From a FRESH clone -- filter-repo rewrites history and refuses a dirty
# tree, and you want the poplog clone you work in left alone.
git clone --no-local /Users/dkords/dev/projects/iotone/poplog /tmp/carve
cd /tmp/carve && git checkout langpop-placement

git filter-repo \
  --path examples/langpop \
  --path-glob 'docs/projects/langpop-*' \
  --path-rename examples/langpop/: \
  --path-rename docs/projects/langpop-:docs/

git init --bare /Users/dkords/dev/projects/iotone/pop-11-langpop.git
git remote add origin /Users/dkords/dev/projects/iotone/pop-11-langpop.git
git push origin --all --tags
```

Expect 44 commits, every one of them a langpop commit, with
`examples/langpop/README.md` appearing as `README.md` throughout its
history -- `git log --follow` keeps working because filter-repo rewrites
the trees rather than adding a rename.

Afterwards, verify rather than assume: `git log --oneline | wc -l` is
44, `git log --diff-filter=A --name-only | grep examples/` is empty, and
the suites pass from the new root (which is where break (1) shows up if
it was not fixed first).

## Two decisions about order and about what stays

**Decision A -- land PR #72 first.** It is 37 commits to `dev`, and
`dev -> master` after that. Carving from an unreviewed branch means the
carved history is the unreviewed history, and any review comment lands
in a repo the reviewer cannot see from the PR. **Recommend: PR #72 to
`dev`, `dev` to `master`, then carve from `master`.** The project's own
rule -- branch to dev to master, never skipping -- says the same thing.

**Decision B -- does Poplog keep a copy?** Three options: delete the
directory and leave a pointer row in `examples/README.md`; keep it as a
frozen copy; add it as a submodule. **Recommend: delete, with the
pointer.** Two copies of a live project in two repos is the `json.p`
problem again one level up, and langpop is no longer an example of
Poplog -- it is a program that needs one. The deletion is one commit on
`master` after the carve is pushed and verified, and it is the only
commit in the sequence that is hard to undo, so it goes last.

---

# Part 2 -- what a climb is, and how far one can get today

## The ladder, and the ceiling under it

`--check` reports 577 items, 12 rungs, 39 exit criteria, no violations.
A sound graph is not a climbable one. Walking every exit criterion with
an empty student and asking only *how many items exist to measure it*:

| rung | criterion | needs | in the graph |
|---|---|---|---|
| ja preschool | recognise(hiragana) | 69 kana | **69** |
| ja preschool | recognise(katakana) | 69 kana | **69** |
| ja preschool | 3 × skill probe | generated | **generated** |
| ja preschool | vocabulary(50, read) | 50 | **50** |
| ja preschool | vocabulary(50, hear) | 50 | needs audio |
| ja n5 | kanji(103, read) | 103 | **103** |
| ja n5 | vocabulary(800, read) | 800 | **148** |
| ja n4 | vocabulary(1500) / kanji(284) | 1500 / 284 | **0 / 0** |
| ja n3 | 3750 / 650 | | **0 / 0** |
| ja n2 | 6000 / 1023 | | **0 / 0** |
| ja n1 | 10000 / 2230 | | **0 / 0** |
| en preschool | 3 named criteria | generated | **generated** |
| en a1 | vocabulary(500, read) | 500 | **100** |
| en a2 … c1 | 1000 … 8000 | | **0** |
| en b1/b2/c1 | coverage(reading/listening) | a corpus | **100-word freq list** |

**Two rungs are climbable today: `ja preschool`, in full, and the kanji
half of `ja n5`.** Everything above is an empty room with a door. The
`--check` violation `level_empty` catches a rung with no items at all;
it does not catch a rung with 148 items and a criterion asking for 800,
because that is not a malformed graph -- it is an unfinished one.

**That is the first finding of the validation work and it arrives before
any student, simulated or real: validating the climb is mostly a content
job, and the code part is small.** It also argues for a new report,
`--ceiling`, printing exactly the table above, so that the gap is a
number the build prints rather than a thing somebody remembers.

## What a climb costs in answers

Tier 1, right: `b + (1 - b) * 0.45`. From zero: 0.45, 0.6975, **0.834**.
`MASTERY` is 0.80, so **three correct checks carry an item from nothing
to mastered, and nothing carries it in two.**

A perfect student, never wrong, never skipping, lower bound, new items
only at each rung:

| | items × 3 | answers |
|---|---|---|
| ja preschool | 138 kana + 50 words + probes | ~700 |
| ja n5 | 800 words + 103 kanji | ~2,700 |
| ja n4 | +1500 + 284 | ~5,400 |
| ja n3 | +3750 + 650 | ~13,200 |
| ja n2 | +6000 + 1023 | ~21,100 |
| ja n1 | +10000 + 2230 | ~36,700 |
| **ja, pre-school to N1** | | **~79,000** |
| en preschool → c1 | 500+1000+2500+5000+8000 | **~51,000** |

A student who is right 80% of the time pays for each wrong answer twice
-- `b * 0.30` throws away most of the progress -- so a realistic climb
is roughly **double**: of order 10^5 answers per language. That number
decides Part 3 by itself.

## Pre-school to N5, as a validation target

The honest target, and the one the content can nearly reach:

1. **Content.** 652 more n5 words. The importer already does this
   (`import.p`, `tools/fetch-upstream.sh`, the n5 picks file); the
   blocker is curation, and `docs/projects/langpop-japanese-tranche.md`
   is waiting on marks. The okurigana-stripped kun readings -- about 16
   of the 28 one-character hiragana forms, 会 expecting あ -- is a bug in
   the content and must be fixed before any climb, because a simulated
   student scored against the graph would *agree with the graph* and the
   run would look clean.
2. **The climb itself**, as an assertable run: an empty profile reaches
   `ja preschool` passed and `ja n5` passed, in some bounded number of
   answers, with every rung's criteria measured and none of them `thin`.
3. **`hear` stays unmeasured** and `:status` must keep saying so. The
   climb report that prints *n5 passed* while two of its three criteria
   say `needs audio` would be the ladder lying, and the wording is
   already written for the student's screen -- the harness should assert
   that wording survives, not route around it.

## Pre-school to the top of the English ladder

Two corrections to the target as stated.

**TOEIC's ceiling is not 1600.** Listening & Reading is 10--990;
Speaking & Writing is 0--200 each, so 400; the two together cap at
**1390**, and nobody reports them as one number. If "the top score" means
L&R, it is **990**.

**990 does not need a new rung.** ETS maps L&R 945+ to CEFR C1, and the
ladder's top rung is `en c1` at `vocabulary(8000, read)` /
`vocabulary(6000, hear)`, which is the right band for it -- consistent
with the figure already on record here, a strong TOEIC reader at about
5,000 words, which is B2-to-C1 territory and not the ceiling. So the
English target is **pre-school to `en c1`**, and TOEIC enters as a
*reporting* question, not a ladder question:

- a band table in `graph/resources.pl` -- score range to rung -- so
  `:status` can say *"about 850--945 on TOEIC L&R"* beside the rung, with
  the mapping's source named, because a score range inferred from a
  vocabulary count is a weaker claim than a measured criterion and must
  read as one;
- there is no `c2`, and C1 is where the ladder stops. 990 is inside C1,
  so this is a coincidence that works. Worth writing down before
  somebody adds a rung to chase a number.

**The coverage criteria are the English blocker,** more than the
vocabulary ones. `coverage(reading, 0.95)` is measured against a
frequency list that currently holds **100 words**. Coverage is the one
criterion that cannot be satisfied by importing more items -- it needs a
corpus, with a licence checked the way speechocean762's was.

## What "validated" should mean -- three layers, separately reported

1. **Reachable** -- the `--ceiling` table: can each rung's criteria be
   satisfied at all by the content present? Static, cheap, no student.
2. **Sound** -- the invariants below hold over a long run. This is where
   bugs live.
3. **Taught** -- the order makes sense to a person. A simulated student
   cannot answer this one and should not be asked to.

### The invariants a long run should assert

Each of these is a test that a bug would break, and several of them
restate a decision the project has already made, which is the point:

- **nothing is offered before its prerequisites** -- `lp_next` never
  returns an item with an unmet `requires`; the DAG is the claim and a
  10^5-answer run is the test;
- **belief is bounded by tier** -- no machine verdict alone takes an
  item past `MACHINE_CAP`, no inference past `INFERRED_CAP`, nothing
  past `MASTERY` without a tier-1 entry. (Lock 3 of
  `langpop-production-criteria.md`, as an assertion instead of a
  constant.)
- **no criterion is satisfied without evidence** -- a rung reported
  passed has, for each criterion, a count whose journal entries exist
  and are at the tier the criterion claims;
- **`skip` is in the denominator and `near` in neither** -- the two
  arguments the project has settled, checked on real numbers;
- **the journal reconstructs the profile** -- replay `lp_journal` from
  empty and get the same beliefs. This is the strongest single
  invariant: it makes every belief in the file auditable, and any
  ordering bug or lost update shows up as a divergence;
- **save and reload is a fixed point** -- round-trip the profile at
  random points in the run and nothing changes (which is where
  `json_generate`'s dropped `false` would reappear);
- **no starvation** -- every item in the current rung's pool is offered
  within some bound; an item the scheduler can never reach is a word the
  student can never learn, and the count-based criteria make that look
  like the student's failure;
- **no crash, and no unhandled mishap, over the whole run**, with the
  file not being edited underneath it (see the README on that).

---

# Part 3 -- the student who climbs it

## One correction first: model size is not learner level

"A local LLM that has various skill levels" has a trap in it. A small
model is not a beginner; it is a *differently* wrong thing. It does not
know 300 kanji and fail on the 301st -- it hallucinates readings for
kanji a beginner has never seen, and gets 山 wrong after getting 曜 right.
Scoring the ladder against that measures the model, and every bug found
would be arguable.

**Level belongs in a knowledge mask, not in the weights.** The harness
decides, from the graph, which items this student knows and how well;
the model (where one is used at all) only renders an answer. Then "a
student at N5 level" is a precise, reproducible object, and when the
tutor disagrees with it, the tutor is wrong.

## The oracle student -- the primary harness

Deterministic, seeded, no model. For each item it carries a true
competence `p(item)`, drawn from a profile: *kana solid, 500 kanji,
grammar thin, katakana leaky* -- which is the real student this project
was written for, as a parameter.

It answers over **JSON-RPC** (`server.p`, 18 methods: `next`, `answer`,
`explain`, `status`, `placement.next`, `placement.report`, `aids`,
`audit`, …), not through the TUI. No pty, no prompt scraping, and the
same surface a GUI client would use -- so the harness tests the API that
is meant to outlive the TUI.

Its error model is drawn from the tutor's own structures, which is what
makes it worth more than random noise:

- **confusables** -- when it is wrong, it answers with the confusable
  partner (`lp_mistook`'s pairs), because ツ for シ is the mistake a real
  student makes and a random string is not;
- **typos** -- adjacent-key slips at a set rate, to exercise the `slip`
  aid and, more importantly, to check that a slip never lowers a belief;
- **latency** -- sampled around the rung's `ms` floor, including
  deliberately straddling it, since every criterion measures speed and
  nothing has ever tested the speed half;
- **skips and `later`** -- at a rate, because `skip` in the denominator
  is a decision with arithmetic behind it;
- **drift** -- competence rises slowly with exposure, so that the run
  resembles learning rather than a fixed coin, and the scheduler's
  spaced return is exercised.

Because it is seeded, a failing run is a seed, and a seed is a bug
report. That is the single biggest reason to build this before reaching
for a model.

**Cost: minutes.** 10^5 answers over a local socket is wall-clock
negligible, so the whole-ladder run can be a nightly job rather than an
occasion.

## Where a local model genuinely earns its place

Four jobs the oracle student cannot do, all of them narrow:

1. **Free text.** The front end is an Eliza-style teacher: a student
   types sentences, not just answers. The oracle student cannot produce
   *"wait, why is it きって and not きて"*, and that path -- `lp_chat`, the
   persona files, the `:why` explanations -- is otherwise untested by the
   long run.
2. **Adversarial input.** Plausible human mess: romaji with macrons,
   half-width katakana, a trailing space, an answer in the wrong script,
   a command typed at the display-name prompt. Two bugs of exactly this
   shape are already on the record (an empty username registers; a
   `:command` becomes a display name), which is evidence the class is
   productive.
3. **English production and `pick`.** Where the answer is a gloss rather
   than a reading, a model is a better generator of wrong-but-reasonable
   answers than a confusable table.
4. **Grading open answers** -- but only as a *proposal*. A model's
   verdict is tier 5 at best, and `MACHINE_CAP` is 0.77 for exactly this
   reason. The model may never certify.

Shape: Ollama locally, one small instruct model, pinned by name and
digest, temperature 0, every prompt and reply written to a transcript so
a failure is reproducible even though generation is not fully so.
**Sampled, not in the loop**: a fixed adversarial suite of a couple of
thousand turns, plus one model turn in every few hundred oracle turns.
At 300 ms--1 s per turn, 10^5 model turns is 8--28 hours; 2,000 is
minutes, and finds the same bugs.

## What this will actually find

Honest expectations, ranked by how likely I think each is:

- **content bugs, in bulk** -- the okurigana class, the homophone ids,
  the `w_ki2` placeholder. A climb over 800 words meets every curation
  decision once. *But only if the oracle's ground truth is independent
  of the graph* -- scored against the graph, a student agrees with its
  own bugs. So the oracle takes its truth from the graph and the
  **disagreements get logged for a person**, which turns the run into a
  curation queue rather than a verdict;
- **scheduler and starvation bugs** -- these need scale, and have never
  had it; 148 words is not enough to starve anything;
- **criterion arithmetic at the boundary** -- the 0.80 threshold, the
  `ms` floor, `thin` pools, and what `:status` prints at 799 of 800;
- **save/restore and journal replay** -- the round-trip invariant over a
  long run is where a dropped field finally shows;
- **the aids interacting** -- four of them now, independently switchable,
  logged, and never exercised in combination.

---

# Sequencing

Each phase ends with something checkable, and no phase depends on a
later one.

| phase | what | ends when |
|---|---|---|
| 0 | PR #72 to `dev`, `dev` to `master` | merged |
| 1 | the `load`-path fix; `./langpop`; the Poplog-version check | suites pass from a root-relative layout |
| 2 | the carve; verify 44 commits; delete from Poplog with a pointer | new repo's suites pass from a fresh clone |
| 3 | `--ceiling`, printing the Part 2 table | the gap is a number the build prints |
| 4 | the oracle student over JSON-RPC, and the invariant assertions | `ja preschool` climbs from empty, reproducibly, from a seed |
| 5 | the okurigana fix and the n5 word tranche to 800 | `ja n5` climbs; the disagreement log is a curation queue |
| 6 | the model harness: adversarial suite and sampled chat turns | the suite runs in CI-time and its failures are transcripts |
| 7 | English: the frequency corpus, the coverage criteria, the TOEIC band table | `en a1` climbs; `coverage` measures something real |

Phases 0--4 are weeks of small work. Phase 5 upward is content, and that
is where the time actually goes -- which is the same conclusion the
ceiling table reaches, arrived at from the other end.

---

# Decisions

| # | decision | recommend |
|---|---|---|
| A | land PR #72 and reach `master` before carving | **yes** |
| B | Poplog deletes its copy and keeps a pointer row | **yes** |
| C | depend on a named Poplog release rather than vendoring `json`/`jsonrpc` | **yes** |
| D | repo name `pop-11-langpop.git` as asked, keeping the `pop-11-` prefix | yes |
| E | the English target is `en c1`; TOEIC is a reported band, not a rung | **yes** |
| F | the oracle student is the primary harness; the model is sampled and adversarial only | **yes** |
| G | a model verdict never certifies -- `MACHINE_CAP` holds for the harness too | **yes**, and this one is Lock 3 |
