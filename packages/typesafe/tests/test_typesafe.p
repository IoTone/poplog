;;; test_typesafe.p -- the TypeSafe client, without a key or a network.
;;;
;;; ts_transport is injectable for exactly this reason.  A client whose
;;; retry logic can only be exercised by provoking a real rate limit is a
;;; client whose retry logic is never exercised.
;;;
;;;     sh tools/test-libs.sh packages/typesafe/tests/test_typesafe.p
;;;
;;; The one thing these cannot check is whether the server agrees with our
;;; reading of its schema.  See the live smoke test in the README.

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
uses typesafe;
uses poptest;
uses json;

;;; ------------------------------------------------------- request shape

lvars q1 = ts_noul('Is it safe?', 'clearly safe', 'any doubt');
lvars body = ts_request('some state', [[safety ^q1]]);
lvars sent = json_parse(body);

check('request carries the state',      sent('state'), 'some state');
check('request carries the model',      sent('model'), 'jev-latest');
check('question is keyed by its id',    sent('questions')('safety')('type'), 'noul');
check('noul keeps the true criterion',
      sent('questions')('safety')('criteria')('true'), 'clearly safe');
check('noul keeps the false criterion',
      sent('questions')('safety')('criteria')('false'), 'any doubt');

;;; choice: a false description must reach the wire as null, not as the
;;; string 'false' and not as a dropped key
lvars q2 = ts_choice('Pick one', [[red 'the red one'] [blue false] [green ^false]]);
lvars c = json_parse(ts_request('s', [[colour ^q2]]))('questions')('colour');
check('choice type',                 c('type'), 'choice');
check('choice keeps a description',  c('criteria')('red'), 'the red one');
check('choice sends null for the word false', c('criteria')('blue'), json_null);
check('choice sends null for boolean false',   c('criteria')('green'), json_null);

;;; choice options must reach the wire in the order written: a model
;;; reads them as a sequence, so a reordered set is a different question.
;;; Five keys, because with two or three a hash order can match by luck.
lvars q5 = ts_choice('Who?', [[billing false] [technical false] [sales false]
                              [legal false] [hr false]]);
lvars wire = ts_request('s', [[d ^q5]]);
check('choice options keep their order',
      issubstring('"criteria":{"billing":null,"technical":null,"sales":null,'
                  <> '"legal":null,"hr":null}', wire) and true, true);
check('choice criteria still read like a property', q5('criteria')('sales'), json_null);

;;; questions keep their order too: a local model batches them as they
;;; arrive, and batch-mates move a question's probabilities slightly
lvars many = ts_request('s', [[q5 ^q1] [q3 ^q1] [q9 ^q1] [q1 ^q1] [q7 ^q1]]);
check('questions keep their order',
      issubstring('"questions":{"q5":', many) and issubstring('},"q3":', many)
      and issubstring('},"q9":', many) and issubstring('},"q1":', many)
      and issubstring('},"q7":', many)
      and issubstring('q5', many) < issubstring('q3', many)
      and issubstring('q3', many) < issubstring('q9', many)
      and issubstring('q9', many) < issubstring('q1', many)
      and issubstring('q1', many) < issubstring('q7', many), true);

;;; score: criteria must be an ORDERED array, because the answer is an
;;; index into it
lvars q3 = ts_score('Rate it', ['bad' 'ok' 'good']);
lvars sc = json_parse(ts_request('s', [[quality ^q3]]))('questions')('quality');
check('score type',             sc('type'), 'score');
check('score criteria ordered', subscrv(3, sc('criteria')), 'good');
check('score criteria length',  length(sc('criteria')), 3);

;;; several questions in one call
lvars two = ts_request('s', [[a ^q1] [b ^q3]]);
check('two questions, first',  json_parse(two)('questions')('a')('type'), 'noul');
check('two questions, second', json_parse(two)('questions')('b')('type'), 'score');

;;; ------------------------------------------------------------- decode

lconstant SAMPLE = '{"model":"jev-1.13.0",'
    <> '"answers":{'
    <> '"safety":{"type":"noul","noul":0.95},'
    <> '"colour":{"type":"choice","choice":"red",'
    <>   '"probabilities":{"red":0.88},"confidence":0.81},'
    <> '"quality":{"type":"score","score":1.05,'
    <>   '"legend":{"0":"bad","1":"ok"},'
    <>   '"probabilities":{"0":0.95,"1":0.05},"confidence":0.92}},'
    <> '"usage":{"input_tokens":12,"output_tokens":34}}';

lvars (ans, usage, model) = ts_decode(SAMPLE);
check('decode returns the resolved model', model, 'jev-1.13.0');
check('noul answer',        ans('safety')('noul'),        0.95);
check('choice answer',      ans('colour')('choice'),      'red');
check('choice confidence',  ans('colour')('confidence'),  0.81);
check('score answer',       ans('quality')('score'),      1.05);
check('score legend',       ans('quality')('legend')('1'), 'ok');
check('usage input tokens', usage('input_tokens'), 12);
check('usage output tokens', usage('output_tokens'), 34);

;;; --------------------------------------------------- retry and errors
;;; A scripted transport: each call pops the next (status, body) from a
;;; list and records what it was given.

vars calls = 0, seen_headers = false, script = [];

;;; Response headers the fake hands back, as [name value] pairs.  Empty by
;;; default: a transport that reports no headers is the normal case, and
;;; the client must survive it.
vars resp_headers = [];

define fake_transport(method, url, body, headers, timeout) -> (rb, rh, st);
    calls + 1 -> calls;
    headers -> seen_headers;
    lvars row = hd(script);
    tl(script) -> script;
    hd(tl(row)) -> rb;
    newmapping([], 4, false, true) -> rh;
    lvars h;
    for h in resp_headers do hd(tl(h)) -> rh(hd(h)) endfor;
    hd(row) -> st;
enddefine;

'test-key' -> ts_api_key;
1 -> ts_max_retries;            ;;; keep the backoff sleeps short in tests
fake_transport -> ts_transport;

;;; happy path
0 -> calls;
[[200 ^SAMPLE]] -> script;
lvars a = ts_eval('s', [[safety ^q1]]);
check('one call when it works', calls, 1);
check('answers come back',      a('safety')('noul'), 0.95);
check('usage recorded',         ts_last_usage('input_tokens'), 12);
check('resolved model recorded', ts_last_model, 'jev-1.13.0');
check('sends a User-Agent',
      member('User-Agent: poplog-typesafe/' <> ts_version <> ' (Pop-11)',
             seen_headers) and true, true);

;;; the Authorization header must actually be sent, and as a Bearer token
check('sends bearer auth',
      member('Authorization: Bearer test-key', seen_headers) and true, true);
check('sends json content type',
      member('Content-Type: application/json', seen_headers) and true, true);

;;; 429 is retried, then succeeds
0 -> calls;
[[429 'slow down'] [200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> a;
check('429 is retried',            calls, 2);
check('retry returns the answer',  a('safety')('noul'), 0.95);

;;; 529 is retried too
0 -> calls;
[[529 'overloaded'] [200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> ;
check('529 is retried', calls, 2);

;;; retries are bounded -- with max_retries 1, a second 429 gives up
0 -> calls;
[[429 'a'] [429 'b']] -> script;
check_mishaps('gives up after max_retries',
              procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('gave up after two calls', calls, 2);

;;; 401 is NOT retried: a bad key stays bad
0 -> calls;
[[401 'unauthorized']] -> script;
check_mishaps('401 is not retried',
              procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('401 cost exactly one call', calls, 1);

;;; 422 is not retried either
0 -> calls;
[[422 'bad request']] -> script;
check_mishaps('422 is not retried',
              procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('422 cost exactly one call', calls, 1);

;;; a missing key must fail before any request goes out
false -> ts_api_key;
0 -> calls;
[[200 ^SAMPLE]] -> script;
check_mishaps('no key means no request',
              procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('nothing was sent without a key', calls, 0);
'test-key' -> ts_api_key;

;;; a local backend needs no key, and must not be sent one
lvars saved_url = ts_base_url;
false -> ts_api_key;
'http://127.0.0.1:8765/v1' -> ts_base_url;
0 -> calls;
[[200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> ;
check('loopback needs no key', calls, 1);
'test-key' -> ts_api_key;
[[200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> ;
check('loopback is not sent the key',
      member('Authorization: Bearer test-key', seen_headers), false);
saved_url -> ts_base_url;

;;; ts_require_key false: for transports that are not HTTP at all
false -> ts_require_key;
false -> ts_api_key;
0 -> calls;
[[200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> ;
check('ts_require_key false needs no key', calls, 1);
true -> ts_require_key;
'test-key' -> ts_api_key;

;;; a non-JSON body is a mishap, not a wrong answer
check_mishaps('garbage response mishaps',
              procedure; ts_decode('not json at all') -> ; -> ; -> ; endprocedure);

;;; ------------------------------------------- retry policy (v0.2.0)
;;; The set used to be {429, 529}, so a 503 -- a deploy, a blip, the
;;; ordinary weather of a hosted API -- failed the call outright.  One
;;; check per status, because the point of the fix is the ones that
;;; were missing, not the ones that already worked.

lvars st;
for st in [408 500 502 503 504 529] do
    0 -> calls;
    [% [% st; 'transient' %]; [% 200; SAMPLE %] %] -> script;
    ts_eval('s', [[safety ^q1]]) -> ;
    check(st sys_>< ' is retried', calls, 2);
endfor;

;;; ...and the boundaries hold: 4xx that are not 408 stay fatal, so a
;;; widened set has not quietly become "retry everything".
for st in [400 403 404] do
    0 -> calls;
    [% [% st; 'nope' %] %] -> script;
    check_mishaps(st sys_>< ' is not retried',
                  procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
    check(st sys_>< ' cost one call', calls, 1);
endfor;

;;; ts_retry_statuses replaces the policy outright, for a transport whose
;;; statuses are its own invention -- `lib laya` sets [] because a local
;;; pipe has no rate limit and its 504 means the child is already dead.
[] -> ts_retry_statuses;
0 -> calls;
[[429 'slow down']] -> script;
check_mishaps('[] disables retrying',
              procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('nothing was retried', calls, 1);

[503] -> ts_retry_statuses;
0 -> calls;
[[503 'down'] [200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> ;
check('a named status is retried', calls, 2);
0 -> calls;
[[429 'slow down']] -> script;
check_mishaps('an unnamed status is not',
              procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('and cost one call', calls, 1);
false -> ts_retry_statuses;

;;; ------------------------------------------------- the request id
;;; Captured on success, and still captured when the call fails -- which
;;; is the case that matters, because that is the one you report.

[['x-typesafe-request-id' 'req_abc123']] -> resp_headers;
[[200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> ;
check('request id recorded on success', ts_last_request_id, 'req_abc123');

[['x-typesafe-request-id' 'req_fail99']] -> resp_headers;
[[401 'unauthorized']] -> script;
check_mishaps('failure still mishaps',
              procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('request id recorded on failure', ts_last_request_id, 'req_fail99');

;;; No header is not an error; it is false, not a stale value from before.
[] -> resp_headers;
[[200 ^SAMPLE]] -> script;
ts_eval('s', [[safety ^q1]]) -> ;
check('no request id header leaves false', ts_last_request_id, false);

;;; -------------------------------------------- retry-after honoured
;;; Measured in real time, because the whole point is how long we sleep.
;;; Bounds are loose on the upper side (a loaded machine can always take
;;; longer) and tight on the lower, which is the direction that proves
;;; the header was read at all.

define lconstant elapsed_ms(p) -> ms;
    lvars t0 = sys_microtime();
    p();
    (sys_microtime() - t0) / 1000 -> ms;
enddefine;

lvars saved_jitter = ts_retry_jitter, saved_after_max = ts_retry_after_max,
      saved_backoff_max = ts_retry_backoff_max;
0 -> ts_retry_jitter;           ;;; so the lower bound is exact

;;; retry-after-ms: 400 means wait 0.4 s, not our 0.25 s backoff
[['retry-after-ms' '400']] -> resp_headers;
[[429 'slow down'] [200 ^SAMPLE]] -> script;
lvars ms = elapsed_ms(procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure);
check('retry-after-ms is obeyed', ms >= 380, true);

;;; retry-after is in seconds, and wins nothing over retry-after-ms when
;;; both arrive: the precise one is used, so this is 0.4 s, not 2 s.
[['retry-after' '2'] ['retry-after-ms' '400']] -> resp_headers;
[[429 'slow down'] [200 ^SAMPLE]] -> script;
elapsed_ms(procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure) -> ms;
check('retry-after-ms wins over retry-after', ms < 1500, true);

;;; A server that asks for an hour does not get one.  Without the cap a
;;; single bad header parks the process indefinitely.
5 -> ts_retry_after_max;        ;;; 0.05 s
[['retry-after' '3600']] -> resp_headers;
[[429 'slow down'] [200 ^SAMPLE]] -> script;
elapsed_ms(procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure) -> ms;
check('retry-after is capped', ms < 1000, true);
saved_after_max -> ts_retry_after_max;

;;; Garbage in the header is not a delay and not a crash: the backoff
;;; takes over.
[['retry-after' 'tomorrow please']] -> resp_headers;
[[429 'slow down'] [200 ^SAMPLE]] -> script;
0 -> calls;
ts_eval('s', [[safety ^q1]]) -> ;
check('unparseable retry-after falls back to backoff', calls, 2);

;;; Ignoring the header is a setting, for a transport that fakes them.
false -> ts_respect_retry_after;
[['retry-after' '3600']] -> resp_headers;
[[429 'slow down'] [200 ^SAMPLE]] -> script;
elapsed_ms(procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure) -> ms;
check('retry-after can be ignored', ms < 1000, true);
true -> ts_respect_retry_after;
[] -> resp_headers;

;;; ------------------------------------------------ backoff is bounded
;;; Four retries doubling from 0.25 s would be 3.75 s; capped at 0.05 s
;;; it is nothing.  This is what stops a long max_retries from turning
;;; into a long wall-clock stall.
4 -> ts_max_retries;
5 -> ts_retry_backoff_max;
[[429 'a'] [429 'b'] [429 'c'] [429 'd'] [200 ^SAMPLE]] -> script;
elapsed_ms(procedure; ts_eval('s', [[safety ^q1]]) -> ; endprocedure) -> ms;
check('backoff is capped', ms < 1500, true);
saved_backoff_max -> ts_retry_backoff_max;

;;; Full jitter must not produce a negative sleep.  syssleep would mishap
;;; on one, so this check is that the call completes at all.
1.0 -> ts_retry_jitter;
[[429 'slow down'] [200 ^SAMPLE]] -> script;
0 -> calls;
ts_eval('s', [[safety ^q1]]) -> ;
check('full jitter still sleeps legally', calls, 2);
saved_jitter -> ts_retry_jitter;
1 -> ts_max_retries;

;;; --------------------------------------- the schema's own limits
;;; Caught here, at the call site that named them, rather than as a 422
;;; whose path is `questions.<id>.criteria`.

;;; distinct keys, so the count on the wire is the count asked for
define lconstant many_options(n) -> l;
    lvars i;
    [% for i from 1 to n do [% i sys_>< ''; false %] endfor %] -> l;
enddefine;

check_mishaps('an empty choice is refused',
              procedure; ts_choice('pick', []) -> ; endprocedure);
check_mishaps('256 options are refused',
              procedure; ts_choice('pick', many_options(256)) -> ; endprocedure);
check_mishaps('an empty score rubric is refused',
              procedure; ts_score('rate', []) -> ; endprocedure);
check_mishaps('a request with no questions is refused',
              procedure; ts_request('s', []) -> ; endprocedure);

;;; 255 options is the limit, not an error
check('255 options are allowed',
      ts_choice('pick', many_options(255))('type'), 'choice');

test_summary();
