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

The key comes from the environment, because an API key in a source file is
an API key in a git history:

```sh
export TYPESAFE_API_KEY=apikey_...
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

### Settings

| variable | default |
| --- | --- |
| `ts_api_key` | `$TYPESAFE_API_KEY` (keys look like `apikey_...`) |
| `ts_model` | `'jev-latest'` |
| `ts_base_url` | `'https://api.typesafe.ai/v1'` |
| `ts_timeout` | 60 seconds |
| `ts_max_retries` | 4 |
| `ts_transport` | `http_request` |

A key that does not start with `apikey_` gets a warning, not a refusal —
it is almost always the wrong variable rather than a wrong key, and saying
so beats spending a round trip to be told 401. The prefix is an observation
about today's keys, not a rule the server promised, so it does not block.

`429` and `529` are retried with exponential backoff from 0.25s, as the API
docs require. `401` and `422` are not retried — a bad key stays bad — and
mishap with the server's own body.

## Tests

```sh
sh tools/test-libs.sh packages/typesafe/tests/test_typesafe.p
```

38 checks, no key and no network. `ts_transport` is injectable for exactly
that reason: a client whose retry logic can only be exercised by provoking a
real rate limit is a client whose retry logic is never exercised. The tests
script a transport that returns `429`, then `200`, and assert both the retry
and the call count.

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

## Versions

Three versions travel with a call and they are not the same thing:

| | where | why it matters |
| --- | --- | --- |
| **API** | `/v1` in `ts_base_url` | pinned by you; change the URL to move |
| **model** | `ts_last_model` | you ask for `jev-latest`, the server *resolves* it to e.g. `jev-1.13.0`. This is the one to record beside any result you intend to reproduce — and it arrives free in every response |
| **client** | `ts_version`, `'0.1.0'` | this library's own, sent as `User-Agent: poplog-typesafe/0.1.0 (Pop-11)` |

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
