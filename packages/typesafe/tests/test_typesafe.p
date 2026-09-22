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

define fake_transport(method, url, body, headers, timeout) -> (rb, rh, st);
    calls + 1 -> calls;
    headers -> seen_headers;
    lvars row = hd(script);
    tl(script) -> script;
    hd(tl(row)) -> rb;
    newmapping([], 4, false, true) -> rh;
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

;;; a non-JSON body is a mishap, not a wrong answer
check_mishaps('garbage response mishaps',
              procedure; ts_decode('not json at all') -> ; -> ; -> ; endprocedure);

test_summary();
