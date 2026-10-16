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
    http_request json_parse json_generate json_null json_object
=>
    ts_eval ts_request ts_decode ts_version ts_last_model
    ts_noul ts_choice ts_score
    ts_api_key ts_model ts_base_url ts_timeout ts_max_retries ts_transport
    ts_last_usage ts_require_key ts_last_request_id
    ts_retry_backoff_max ts_retry_jitter ts_respect_retry_after
    ts_retry_after_max ts_retry_statuses
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
constant ts_version = '0.2.0';   ;;; lconstant is lexical and cannot be exported

vars ts_api_key   = systranslate('TYPESAFE_API_KEY') or false;
vars ts_model     = 'jev-latest';
vars ts_base_url  = 'https://api.typesafe.ai/v1';
vars ts_timeout   = 60;
vars ts_max_retries = 4;

;;; Backoff.  The delay doubles from a quarter second but stops growing at
;;; ts_retry_backoff_max, and a random fraction of up to ts_retry_jitter is
;;; subtracted from each wait.  The jitter is not decoration: without it,
;;; several Poplog processes that hit the same rate limit retry in step and
;;; keep colliding.  Our own CI runs suites in parallel, so that is us.
;;; Delays are in hundredths of a second, as syssleep takes them.
vars ts_retry_backoff_max = 500;        ;;; 5 s
vars ts_retry_jitter      = 0.25;

;;; The server may say when to come back, in `retry-after` (seconds) or
;;; `retry-after-ms` (milliseconds).  Obeying it beats guessing, so it wins
;;; over the backoff above when present -- but capped, because a header is
;;; a number from someone else and a client that sleeps for however long it
;;; is told can be parked indefinitely by one bad value.  The HTTP-date
;;; form of retry-after is ignored rather than half-parsed; today's API
;;; sends the numeric form.
vars ts_respect_retry_after = true;
vars ts_retry_after_max     = 3000;     ;;; 30 s

;;; false: retry a timeout, a rate limit and any server error (408, 429,
;;; 5xx), which is what the hosted API needs.  A list replaces that set
;;; outright, and [] disables retrying -- see `retryable` below for why a
;;; local transport wants that.
vars ts_retry_statuses = false;

;;; The hosted API needs a key; a local backend (laya_serve.py, LIB LAYA)
;;; has none to check.  A loopback ts_base_url never needs one, and a
;;; library that installs its own transport sets this false.
vars ts_require_key = true;

;;; Token counts from the last call, as a property with 'input_tokens' and
;;; 'output_tokens'.  Kept separate so ts_eval can return just the answers
;;; for the common case.
vars ts_last_usage = false;

;;; The model that actually answered, e.g. 'jev-1.13.0' when 'jev-latest'
;;; was asked for.  Record it beside any result you intend to keep.
vars ts_last_model = false;

;;; The server's id for the last request, from the x-typesafe-request-id
;;; response header, or false if it sent none.  It is the one thing support
;;; asks for, it arrives on failures as well as successes, and it used to
;;; be thrown away with the rest of the headers.  Failures quote it in the
;;; mishap message, so a transcript is enough to chase one.
vars ts_last_request_id = false;

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
    ;;; The schema says 1 to 255 options.  Checking here costs nothing and
    ;;; names the call site; the alternative is a 422 from the server that
    ;;; says `questions.<id>.criteria` and leaves you to find which
    ;;; question that was.
    unless islist(options) and options /== [] then
        mishap(options, 1, 'typesafe: ts_choice needs at least one option')
    endunless;
    if length(options) > 255 then
        mishap(length(options), 1,
               'typesafe: ts_choice takes at most 255 options')
    endif;
    ;;; json_object, not a property: options must reach the wire in the
    ;;; order written.  A model reads them as a sequence, and a reordered
    ;;; set is a different question -- measured on Laya, it changed the
    ;;; pick for the same text and options.
    lvars c = json_object(), o;
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
    unless islist(levels) and levels /== [] then
        mishap(levels, 1, 'typesafe: ts_score needs at least one level')
    endunless;
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
    ;;; Questions go out in the order given, as choice options do.  Answers
    ;;; are keyed by id, so order looks irrelevant -- but a local model
    ;;; batches questions in arrival order, and on a GPU a question's
    ;;; probabilities move slightly (~1e-4) with its batch-mates.  The same
    ;;; call from Pop-11 and from Python should get the same numbers.
    unless islist(questions) and questions /== [] then
        mishap(questions, 1, 'typesafe: ts_request needs at least one question')
    endunless;
    lvars qs = json_object(), q, root = obj();
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
;;; A timeout, a rate limit and any server error are retried; everything
;;; else is a mishap with the server's own body, because a truncated error
;;; is worse than a long one.
;;;
;;; This used to be `429 or 529` and that was a bug, not a policy.  529 is
;;; not a status this API documents at all -- it is another vendor's
;;; convention, which is the tell that the set was copied rather than
;;; derived.  Meanwhile 500, 502, 503 and 504, which is what a deploy or a
;;; blip actually produces, each failed the call outright.  The official
;;; SDK retries {408, 429, 500-599}; so do we now, which covers 529 by the
;;; 5xx rule rather than by coincidence.

;;; A list in ts_retry_statuses replaces the policy entirely, and [] means
;;; "never retry".  That exists for a transport whose statuses are its own
;;; invention rather than a server's: `lib laya` reports a call that
;;; outran its deadline as 504, and retrying that would kill the child and
;;; pay the model load again, four times over, to no purpose -- a local
;;; pipe has neither a rate limit nor a gateway.
define lconstant retryable(status);
    if islist(ts_retry_statuses) then
        member(status, ts_retry_statuses) and true
    else
        status == 408 or status == 429 or (status >= 500 and status < 600)
    endif
enddefine;

;;; A delay the server asked for, in hundredths of a second, or false.
;;; retry-after-ms wins over retry-after when both are sent, being the
;;; more precise of the two.  Anything unparseable is simply not a delay:
;;; the backoff is the fallback, so there is nothing to report.
define lconstant header_delay(hdrs, name, scale) -> hsecs;
    false -> hsecs;
    lvars raw = hdrs(name), n;
    if isstring(raw) and (strnumber(raw) ->> n) and isnumber(n) and n >= 0
    then
        min(intof(n * scale), ts_retry_after_max) -> hsecs;
    endif;
enddefine;

define lconstant retry_after(hdrs) -> hsecs;
    false -> hsecs;
    unless ts_respect_retry_after and isproperty(hdrs) then return endunless;
    header_delay(hdrs, 'retry-after-ms', 0.1) -> hsecs;
    unless hsecs then header_delay(hdrs, 'retry-after', 100) -> hsecs endunless;
enddefine;

;;; How long to wait before the next attempt: what the server asked for,
;;; or our own backoff with a random slice taken off it.
define lconstant next_wait(hdrs, wait) -> hsecs;
    retry_after(hdrs) -> hsecs;
    unless hsecs then
        lvars spread = intof(wait * ts_retry_jitter);
        wait - (if spread > 0 then random0(spread + 1) else 0 endif) -> hsecs;
    endunless;
enddefine;

define lconstant request_id(hdrs);
    if isproperty(hdrs) then hdrs('x-typesafe-request-id') else false endif
enddefine;

define lconstant fail(status, body);
    lvars what =
        if status == 401 then 'invalid API key (check TYPESAFE_API_KEY)'
        elseif status == 422 then 'request rejected as malformed'
        else 'HTTP ' sys_>< status
        endif;
    if ts_last_request_id then
        what <> ' (request ' <> ts_last_request_id <> ')' -> what;
    endif;
    mishap(body, 1, 'typesafe: ' <> what);
enddefine;

;;; ----------------------------------------------------------------- call
;;; Exponential backoff, doubling from a quarter second.  The API docs say
;;; SDKs are expected to do this; it is not optional politeness.

define lconstant loopback(url);
    isstartstring('http://127.0.0.1', url)
    or isstartstring('http://localhost', url)
    or isstartstring('http://[::1]', url)
enddefine;

define ts_eval(state, questions) -> answers;
    lvars body = ts_request(state, questions), tries = 0, wait = 25;
    lvars resp, hdrs, status, usage;
    lvars need_key = ts_require_key and not(loopback(ts_base_url));
    if need_key and not(ts_api_key) then
        mishap(0, 'typesafe: no API key -- set TYPESAFE_API_KEY or ts_api_key')
    endif;
    ;;; Keys look like apikey_...  A wrong-looking key is usually a wrong
    ;;; variable rather than a wrong key, and saying so beats spending a
    ;;; round trip to be told 401.  A warning, not a refusal: the prefix is
    ;;; an observation about today's keys, not a rule the server promised.
    if need_key and not(isstartstring('apikey_', ts_api_key)) then
        printf(';;; typesafe: key does not start with apikey_ -- wrong variable?\n',
               [])
    endif;
    lvars url = ts_base_url <> '/systemone';
    ;;; [% ... %], not [ ... ]: a list literal does NOT evaluate its items,
    ;;; so the bracket form builds a list containing the word `<>` and the
    ;;; header never says Bearer anything.  Every live call would have come
    ;;; back 401 with a perfectly plausible-looking request in the log.
    ;;; No key, no Authorization header: a local backend has nothing to
    ;;; check, and a key sent to one is a key sent somewhere it need not go.
    lvars headers = [% if need_key then
                           'Authorization: Bearer ' <> ts_api_key
                       endif,
                       'Content-Type: application/json',
                       'User-Agent: poplog-typesafe/' <> ts_version
                           <> ' (Pop-11)' %];
    repeat
        ts_transport('POST', url, body, headers, ts_timeout)
            -> (resp, hdrs, status);
        ;;; Recorded before anything can fail, so a mishap can quote it.
        request_id(hdrs) -> ts_last_request_id;
        quitif(status >= 200 and status < 300);
        unless retryable(status) and tries < ts_max_retries then
            fail(status, resp)
        endunless;
        syssleep(next_wait(hdrs, wait));
        min(wait * 2, ts_retry_backoff_max) -> wait;
        tries + 1 -> tries;
    endrepeat;
    lvars model;
    ts_decode(resp) -> (answers, usage, model);
    usage -> ts_last_usage;
    model -> ts_last_model;
enddefine;

endsection;
