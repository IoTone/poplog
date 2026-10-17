# typesafe — a Pop-11 client for the TypeSafe Evaluation API

An alternative to the Python SDK for
[`POST /v1/systemone`](https://docs.typesafe.ai/api). One endpoint: you hand
it some state and a map of typed questions, it hands back a typed answer per
question plus token usage.

**This is not part of the Poplog release.** It is an out-of-tree library, and
the point of the arrangement is that it stays that way.

## How out-of-tree libraries work in Poplog

Poplog has had a mechanism for this since long before us. The launcher
already exports:

```sh
poplocal=$poplogroot
poplocalauto=$poplocal/local/auto
```

and `pop/src/syslibcompile.p` puts `POPLOCALAUTO` **first** on `popautolist`,
ahead of every system directory. So a library dropped there is found by
`uses` with no change to the release at all — and, because it is first, it
can also shadow a system library. That is the intended power and the obvious
footgun in one feature.

Three ways to make a library available, in descending order of how much you
want it to feel installed:

| | mechanism | use when |
| --- | --- | --- |
| 1 | drop into `$poplocal/local/auto` | a real, installable package |
| 2 | `extend_searchlist(dir, popuseslist) -> popuseslist` | it lives elsewhere; ship a one-line init |
| 3 | `vars foo_lib = true; load 'path/foo.p'` | examples and scratch work |

Option 2 is what `pop/lib/lib/flavours.p` does, and what the tests here use.

The dependency direction is what makes this comfortable: `http_client.p`,
`json.p` and `crypto.p` are all **in** the release, so an API layer sits on
shipped infrastructure and ships nothing of its own.

## Install

```sh
mkdir -p "$poplogroot/local/auto"
cp packages/typesafe/typesafe.p "$poplogroot/local/auto/"
```

Note the path. The launcher pins `poplocal=$poplogroot` (line 11 of
`poplog`), so `$poplocal/local/auto` resolves to **`<poplog>/local/auto`**,
not to anything under `$HOME` — and setting `poplocal` in the environment
does not change it, because the launcher overwrites it. Verified by
installing there and watching `uses typesafe` find it with no other
configuration.

or, without installing:

```pop11
extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
uses typesafe;
```

To take the command line with you, copy `ts-eval`, `cli.p` and `typesafe.p`
into the same directory anywhere. It finds Poplog by walking up from its own
location, so inside a checkout it needs nothing; outside one, point it:

```sh
POPLOG_ROOT=/path/to/poplog /somewhere/ts-eval noul "Is this a greeting?" "Good morning"
```

The key comes from the environment, because an API key in a source file is
an API key in a git history:

```sh
export TYPESAFE_API_KEY=apikey_...
```

## Try it from the shell

`ts-eval` is a small front end for one-off questions. It needs
`TYPESAFE_API_KEY` and nothing else — it finds Poplog by walking up from its
own location, so it works from a checkout or an installed copy.

```sh
export TYPESAFE_API_KEY=$(cat ~/.typesafe-key)

./packages/typesafe/ts-eval noul   "Is this a greeting?" "Hello there, how are you?"
./packages/typesafe/ts-eval choice "What register is this?" formal,casual "Hey, what's up"
./packages/typesafe/ts-eval score  "How urgent is this?" low,medium,high "The server room is on fire"
```

Real output, live against `jev-1.13.0`:

```
$ ts-eval noul "Is this a greeting?" "Hello there, how are you?"
0.99   (yes)
;;; jev-1.13.0, 296 tokens in / 20 out

$ ts-eval choice "What register is this?" formal,casual "Hey, what's up"
casual   (confidence 1.0)
```

`-` reads the text from stdin, which is the useful case — no shell quoting
to fight with:

```sh
$ printf 'The server room is on fire and the backups failed.\n' \
    | ts-eval score "How urgent is this?" low,medium,high -
2.0    (confidence 1.0)

$ printf 'Reminder: the coffee machine needs descaling sometime.\n' \
    | ts-eval score "How urgent is this?" low,medium,high -
0.11   (confidence 0.83)
```

## Several questions, one call

The CLI asks one question at a time, which is fine once and wasteful in a
loop: the text is re-sent and re-read every time. The API takes a *map* of
questions, so `examples/triage.p` judges one message on four axes in a
single request:

```sh
TYPESAFE_API_KEY=$(cat ~/.typesafe-key) \
    ./poplog basepop11 packages/typesafe/examples/triage.p
```

```
  urgency  : 2.14 / 3   (confidence 0.54)
  area     : infra      (confidence 0.98)
  blocked  : 0.78
  deadline : 0.94

  jev-1.13.0, 499 tokens in / 87 out -- for four questions
```

Four questions cost 499 input tokens together. Asked one at a time they cost
about 300 each, so roughly 1200 — the text is what you pay for, and you pay
for it once. The questions are independent, though: they do not see each
other's answers, so this is parallel classification rather than a chain of
reasoning.

Pass a file to judge your own text:

```sh
... examples/triage.p /path/to/message.txt
```

## Use

```pop11
uses typesafe;

;;; three question types, built once and reused
lvars safe = ts_noul('Is this response safe to send?',
                     'no harmful content',
                     'any harmful content');

lvars tone = ts_choice('What register is this in?',
                       [[formal 'business register']
                        [casual 'conversational']
                        [unclear false]]);        ;;; false => JSON null

lvars depth = ts_score('How thorough is the answer?',
                       ['cursory' 'adequate' 'thorough']);

lvars answers = ts_eval('the text being judged',
                        [[safety ^safe] [tone ^tone] [depth ^depth]]);

answers('safety')('noul') =>        ** 0.95
answers('tone')('choice') =>        ** formal
answers('tone')('confidence') =>    ** 0.81
answers('depth')('score') =>        ** 1.05
ts_last_usage('input_tokens') =>    ** 12
```

Question ids and choice keys may be words or strings — `[[safety ^q]]` and
`[['safety' ^q]]` both work.

Choice options and questions go out **in the order you wrote them**. A
model reads the options as a sequence, so reordering them asks a different
question. Measured on Laya, reordering three options changed the pick in 5
of 6 orderings. The hosted Jev API is less sensitive but not insensitive:
reordering options did not move it at all, while reordering *questions*
shifted a `score` answer by up to 0.08 (no pick or band changed). Order is
kept because that is the only behaviour correct for both. A Pop-11 property
is a hash table and would scramble them,
so the request is built with `json_object` (`LIB JSON`), which keeps
insertion order. `q('criteria')('billing')` still reads as before.

### Settings

| variable | default |
| --- | --- |
| `ts_api_key` | `$TYPESAFE_API_KEY` (keys look like `apikey_...`) |
| `ts_model` | `'jev-latest'` |
| `ts_base_url` | `'https://api.typesafe.ai/v1'` |
| `ts_timeout` | 60 seconds |
| `ts_max_retries` | 4 |
| `ts_transport` | `http_request` |
| `ts_require_key` | `true` |
| `ts_retry_backoff_max` | 500 (hundredths of a second: 5 s) |
| `ts_retry_jitter` | 0.25 |
| `ts_respect_retry_after` | `true` |
| `ts_retry_after_max` | 3000 (30 s) |
| `ts_retry_statuses` | `false` (use the policy below; a list replaces it, `[]` never retries) |

`ts_require_key` and a loopback `ts_base_url` (`http://127.0.0.1…`,
`http://localhost…`, `http://[::1]…`) both mean "no key". The key check is
skipped and no `Authorization` header is sent, because a local backend has
nothing to check and does not need to be sent a key. That covers a local
`laya_serve.py --port` (in `packages/laya`), and [`lib laya`](../laya/README.md), which swaps in
its own transport and runs Laya on this machine.

A key that does not start with `apikey_` gets a warning, not a refusal —
it is almost always the wrong variable rather than a wrong key, and saying
so beats spending a round trip to be told 401. The prefix is an observation
about today's keys, not a rule the server promised, so it does not block.

### Retries

**`408`, `429` and any `5xx` are retried**; everything else mishaps with the
server's own body, because a truncated error is worse than a long one. A bad
key stays bad, so `401` is never retried, and nor is `422`.

Until `0.2.0` the set was `429` and `529`, which was a bug rather than a
policy: `529` is not a status this API documents at all — it is another
vendor's convention, which is the tell that the set was copied rather than
derived — while `500`, `502`, `503` and `504`, the ordinary weather of a
hosted service, each failed the call outright. The official SDK retries
`{408, 429, 500–599}`, and so do we now, which covers `529` by the `5xx`
rule instead of by coincidence.

`ts_retry_statuses` replaces that set outright, for a transport whose
statuses are its own invention rather than a server's.
[`lib laya`](../laya/README.md) sets `[]`: its 504 means the call outran
`ts_timeout` and the child has already been killed, so a retry would pay the
model load again for the same answer, and a local pipe has neither a rate
limit nor a gateway to be transiently broken.

The delay doubles from 0.25 s, stops growing at `ts_retry_backoff_max`, and
has a random fraction of up to `ts_retry_jitter` subtracted. The jitter is
not decoration: without it, several Poplog processes that meet the same rate
limit retry in step and keep colliding — and our own CI runs suites in
parallel, so that is us.

When the server says when to come back, in `retry-after` (seconds) or
`retry-after-ms` (milliseconds), that wins over the backoff; the
millisecond form wins over the second form, being the more precise. The
value is capped at `ts_retry_after_max`, because a header is a number from
someone else and a client that sleeps for however long it is told can be
parked indefinitely by one bad value. An unparseable value is not a delay
and not an error — the backoff takes over. The HTTP-date form of
`retry-after` is ignored rather than half-parsed; today's API sends the
numeric form.

### Reporting a failure

`ts_last_request_id` holds the server's `x-typesafe-request-id` for the last
call, or `false` if it sent none. It is recorded on failures as well as
successes — the case that matters, since that is the one you report — and
failures quote it in the mishap message, so a transcript is enough to chase
one.

### What is checked before anything is sent

The schema's own limits, so they fail at the call site that named them
rather than as a `422` whose path is `questions.<id>.criteria`, leaving you
to work out which question that was:

* `ts_choice` wants 1 to 255 options
* `ts_score` wants at least one level
* `ts_request` wants at least one question

## Tests

```sh
sh tools/test-libs.sh packages/typesafe/tests/test_typesafe.p
```

80 checks, no key and no network. `ts_transport` is injectable for exactly
that reason: a client whose retry logic can only be exercised by provoking a
real rate limit is a client whose retry logic is never exercised. The tests
script a transport that returns `429`, then `200`, and assert both the retry
and the call count. The retry-after checks measure real elapsed time, since
how long the client sleeps is the whole point; each was confirmed to fail
when the header is ignored, so none of them passes vacuously.

Two bugs came out of writing them, both worth naming because both would have
looked like a server problem:

* The `Authorization` header was built with a list literal,
  `['Authorization: Bearer ' <> ts_api_key]`. A Pop-11 list literal does not
  evaluate its items, so the list contained the word `<>` and the header
  never said Bearer anything. Every live call would have returned 401 with a
  plausible-looking request in the log. `[% ... %]` evaluates.
* `[[blue false]]` puts the *word* `false` in the list, not the boolean, and
  a word is truthy — so a null criterion silently became a non-null one. The
  library now treats both as null.

## Validated against the live API

The offline suite cannot tell you that `noul` really is the field name on a
live answer, or that `usage` really spells it `input_tokens` — only the
server can say that. `tests/smoke_live.p` asks it, in one request with one
question of each type, and checks the 17 schema assumptions this client
depends on individually so a failure names itself:

```sh
TYPESAFE_API_KEY=$(cat ~/.typesafe-key) \
    ./poplog basepop11 packages/typesafe/tests/smoke_live.p
```

Run 2026-09-21 against `api.typesafe.ai/v1` with `jev-latest`
(answered by `jev-1.13.0`): **all 23 hold.** The envelope, the question ids
coming back as sent, all three answer shapes, an object-valued `state`, and
a bad key being rejected rather than retried.

```
greeting : 0.99                        "Hello there, how are you today?"
register : casual (confidence 1.0)
length   : 0.01 (confidence 0.99)      0..2 over [very short, medium, long]
model    : asked jev-latest, answered jev-1.13.0
```

## What this client does not do

Reviewed against the live OpenAPI schema (`api.typesafe.ai/openapi.json`,
"TypeSafe 0.2.0") and the official Python SDK at `v0.7.5`, 2026-10-15. The
wire contract we use is unchanged and correct: `POST /v1/systemone`, Bearer
auth, `{model, state, questions}` out and `{model, answers, usage}` back. Be
aware when reading that SDK that its `nouls`/`choices`/`scores`/`boxes` are
convenience views it builds over the single `answers` object — not separate
response fields.

What the API offers and this client does not:

* **`box` questions and image assets.** A `box` question locates what it
  describes in an image and answers with `{top, bottom, left, right}` as
  fractions plus a confidence. It needs a vision model and the opt-in
  header `TypeSafe-Danger-Zone-Images: true`. Worth knowing before anyone
  plans the work: the `Asset` schema accepts `data_base64`, so this does
  **not** need multipart — the SDK uses multipart, but inline base64 in the
  ordinary JSON body is a legal request, and Poplog already ships the
  `crypto` library that encodes it.
* **Long context.** Gated behind `TypeSafe-Danger-Zone-Long-Context: true`,
  which this client has no way to send, so a long `state` is unusable from
  Pop-11 today.
* **`GET /v1/models`.** The account's models, with descriptions and release
  dates. As of 2026-10-15 there are two: `jev-latest` ("The latest
  iteration of TypeSafe's System One Model: Jev") and `jev-preview` ("A
  preview version of `jev-latest`: should be better in most ways"), which is
  the one the SDK's `box` example asks for. If this is ever implemented,
  do not parse `release_date` as a date: the schema and the SDK both
  document `YYYY-MM-DD`, and the live API returns a full ISO timestamp.
* **Omitted `instructions`.** The API now makes `instructions` optional on
  every question type, and `criteria` optional on `noul`, so a
  criteria-only `noul` is legal upstream and inexpressible here — all three
  constructors require their instructions.

Deliberately not followed: the SDK's `zstd` request compression (optional,
and its own changelog warns non-official APIs may not accept it yet), HTTP/2,
and its default timeout of 10 s and 2 retries, which are not ours.

## Versions

Three versions travel with a call and they are not the same thing:

| | where | why it matters |
| --- | --- | --- |
| **API** | `/v1` in `ts_base_url` | pinned by you; change the URL to move |
| **model** | `ts_last_model` | you ask for `jev-latest`, the server *resolves* it to e.g. `jev-1.13.0`. This is the one to record beside any result you intend to reproduce — and it arrives free in every response |
| **client** | `ts_version`, `'0.2.0'` | this library's own, sent as `User-Agent: poplog-typesafe/0.2.0 (Pop-11)` |

The client version deliberately tracks nothing upstream. This is an
independent client, not a port of anyone's SDK, so matching their numbering
would imply a correspondence that does not exist. The docs mention "our
client SDKs" but publish no version for them.

Note that `ts_decode` returns `(answers, usage, model)` — the resolved model
used to be discarded, which meant a stored result could not say what
produced it.

It dumps the raw response body on any failure, because a schema mismatch you
cannot see is one you cannot fix, and it never prints the key. Re-run it when
the API version moves.
