/* --- TypeSafe Evaluation API client for Pop-11 -------------------------
 > File:            packages/typesafe/typesafe.p
 > Purpose:         Talk to https://api.typesafe.ai/v1/systemone from Pop-11
 > Documentation:   packages/typesafe/README.md
 >
 > NOT part of the Poplog release.  This is an out-of-tree library: it sits
 > on http_client, json and crypto, all of which ARE shipped, and installs
 > into $poplocal/local/auto where POPLOCALAUTO puts it first on
 > popautolist.  Nothing in pop/ knows it exists.
 >
 > The API is one endpoint.  You hand it some state and a map of typed
 > questions; it hands back a typed answer per question plus token usage.
 > Three question types:
 >
 >   noul    yes/no, with criteria for each side, answered as a probability
 >   choice  named options, answered with the pick plus probabilities
 >   score   an ordered rubric, answered with a position on it
 */
compile_mode :pop11 +strict;

;;; The dependencies load at top level, BEFORE the section opens: a section
;;; can only import identifiers that already exist, and `uses` inside the
;;; section would run too late to be imported from.
uses http_client;
uses json;

;;; Imports before the =>, exports after.  json_null in particular must be
;;; imported: without it the word is a fresh section-local identifier whose
;;; value is false, and false in a property is indistinguishable from an
;;; absent key -- so a null criterion silently became a missing one.
section $-typesafe
    http_request json_parse json_generate json_null
=>
    ts_eval ts_request ts_decode ts_version ts_last_model
    ts_noul ts_choice ts_score
    ts_api_key ts_model ts_base_url ts_timeout ts_max_retries ts_transport
    ts_last_usage
;

;;; ------------------------------------------------------------- settings
;;; The key is read from the environment at load time, because an API key
;;; in a source file is an API key in a git history.

;;; Three different versions travel with a call, and they are not the same
;;; thing:
;;;   * the API version, pinned in ts_base_url ('/v1')
;;;   * the model: we ASK for jev-latest and the server RESOLVES it, so the
;;;     answer says jev-1.13.0.  That is the one you need to reproduce a
;;;     result, and it arrives free in every response -- worth keeping
;;;     rather than discarding
;;;   * this client's own version, which tracks nothing upstream: it is an
;;;     independent client, not a port of anyone's SDK
constant ts_version = '0.1.0';   ;;; lconstant is lexical and cannot be exported

vars ts_api_key   = systranslate('TYPESAFE_API_KEY') or false;
vars ts_model     = 'jev-latest';
vars ts_base_url  = 'https://api.typesafe.ai/v1';
vars ts_timeout   = 60;
vars ts_max_retries = 4;

;;; Token counts from the last call, as a property with 'input_tokens' and
;;; 'output_tokens'.  Kept separate so ts_eval can return just the answers
;;; for the common case.
vars ts_last_usage = false;

;;; The model that actually answered, e.g. 'jev-1.13.0' when 'jev-latest'
;;; was asked for.  Record it beside any result you intend to keep.
vars ts_last_model = false;

;;; The transport is injectable so the retry and decode paths can be tested
;;; without a network or a key.  Signature is http_request's:
;;;     (method, url, body, headers, timeout) -> (body, headers, status)
vars procedure ts_transport = http_request;

;;; ---------------------------------------------------------- questions
;;; Each constructor returns a property shaped the way the API wants it.
;;; They are ordinary values -- build them once and reuse them.

define lconstant obj() -> p;
    newmapping([], 8, false, true) -> p;
enddefine;

;;; JSON object keys must be strings, but a Pop-11 caller will naturally
;;; write a word -- [[safety ^q]] rather than [['safety' ^q]].  Accept both
;;; rather than making every call site quote.
define lconstant key(x) -> s;
    if isword(x) then x sys_>< '' else x endif -> s;
enddefine;

;;; noul: yes/no.  CRIT_TRUE and CRIT_FALSE describe each side.
define ts_noul(instructions, crit_true, crit_false) -> q;
    lvars c = obj();
    crit_true  -> c('true');
    crit_false -> c('false');
    obj() -> q;
    'noul'       -> q('type');
    instructions -> q('instructions');
    c            -> q('criteria');
enddefine;

;;; choice: OPTIONS is a list of [key description] pairs.  A description of
;;; false is sent as JSON null, which the API allows for a key that speaks
;;; for itself.
;;;
;;; Both `false` and "false" count as null, because in a list literal --
;;; which is how these are written -- `false` is the WORD false, and a word
;;; is truthy.  [[blue false]] therefore means the boolean to every reader
;;; and the word to the compiler.  Accepting both is not indulgence: the
;;; alternative is a bare word reaching json_generate and mishapping there,
;;; a long way from the call site that caused it.
define lconstant nullish(x);
    not(x) or x == "false"
enddefine;

define ts_choice(instructions, options) -> q;
    lvars c = obj(), o;
    for o in options do
        (if nullish(hd(tl(o))) then json_null else hd(tl(o)) endif)
            -> c(key(hd(o)));
    endfor;
    obj() -> q;
    'choice'     -> q('type');
    instructions -> q('instructions');
    c            -> q('criteria');
enddefine;

;;; score: LEVELS is an ordered list of rubric descriptions, lowest first.
define ts_score(instructions, levels) -> q;
    obj() -> q;
    'score'      -> q('type');
    instructions -> q('instructions');
    {% applist(levels, identfn) %} -> q('criteria');
enddefine;

;;; ------------------------------------------------------------- request
;;; Pure: state and questions in, request body out.  Separated from the
;;; transport so it can be tested as a string, which is the only way to be
;;; sure what actually goes on the wire.
;;;
;;; QUESTIONS is a list of [id question] pairs.

define ts_request(state, questions) -> body;
    lvars qs = obj(), q, root = obj();
    for q in questions do
        hd(tl(q)) -> qs(key(hd(q)));
    endfor;
    state    -> root('state');
    ts_model -> root('model');
    qs       -> root('questions');
    json_generate(root) -> body;
enddefine;

;;; -------------------------------------------------------------- decode
;;; Pure: response body in, (answers, usage) out.  Answers is a property
;;; from question id to the answer property; the caller reads 'type' and
;;; then the field named by it.

define ts_decode(body) -> (answers, usage, model);
    lvars v = json_parse(body);
    unless isproperty(v) then
        mishap(body, 1, 'typesafe: response is not a JSON object')
    endunless;
    v('answers') -> answers;
    v('usage')   -> usage;
    v('model')   -> model;
    unless answers then
        mishap(body, 1, 'typesafe: response has no "answers"')
    endunless;
enddefine;

;;; --------------------------------------------------------------- errors
;;; 429 and 529 are retried; everything else is a mishap with the server's
;;; own body, because a truncated error is worse than a long one.

define lconstant retryable(status);
    status == 429 or status == 529
enddefine;

define lconstant fail(status, body);
    lvars what =
        if status == 401 then 'invalid API key (check TYPESAFE_API_KEY)'
        elseif status == 422 then 'request rejected as malformed'
        else 'HTTP ' sys_>< status
        endif;
    mishap(body, 1, 'typesafe: ' <> what);
enddefine;

;;; ----------------------------------------------------------------- call
;;; Exponential backoff, doubling from a quarter second.  The API docs say
;;; SDKs are expected to do this; it is not optional politeness.

define ts_eval(state, questions) -> answers;
    lvars body = ts_request(state, questions), tries = 0, wait = 25;
    lvars resp, hdrs, status, usage;
    unless ts_api_key then
        mishap(0, 'typesafe: no API key -- set TYPESAFE_API_KEY or ts_api_key')
    endunless;
    ;;; Keys look like apikey_...  A wrong-looking key is usually a wrong
    ;;; variable rather than a wrong key, and saying so beats spending a
    ;;; round trip to be told 401.  A warning, not a refusal: the prefix is
    ;;; an observation about today's keys, not a rule the server promised.
    unless isstartstring('apikey_', ts_api_key) then
        printf(';;; typesafe: key does not start with apikey_ -- wrong variable?\n',
               [])
    endunless;
    lvars url = ts_base_url <> '/systemone';
    ;;; [% ... %], not [ ... ]: a list literal does NOT evaluate its items,
    ;;; so the bracket form builds a list containing the word `<>` and the
    ;;; header never says Bearer anything.  Every live call would have come
    ;;; back 401 with a perfectly plausible-looking request in the log.
    lvars headers = [% 'Authorization: Bearer ' <> ts_api_key,
                       'Content-Type: application/json',
                       'User-Agent: poplog-typesafe/' <> ts_version
                           <> ' (Pop-11)' %];
    repeat
        ts_transport('POST', url, body, headers, ts_timeout)
            -> (resp, hdrs, status);
        quitif(status >= 200 and status < 300);
        unless retryable(status) and tries < ts_max_retries then
            fail(status, resp)
        endunless;
        syssleep(wait);
        wait * 2 -> wait;
        tries + 1 -> tries;
    endrepeat;
    lvars model;
    ts_decode(resp) -> (answers, usage, model);
    usage -> ts_last_usage;
    model -> ts_last_model;
enddefine;

endsection;
