/* examples/langpop/server.p -- langpop, Proposal B: one protocol is the door.

   Proposal A put the graph, the overlay and the session in one process and
   let the TUI reach straight into them.  B keeps all of that -- the engine
   below this file is unchanged, and the Prolog still answers the questions
   -- but puts ONE protocol in front of it, so the TUI has no privileges a
   phone app would not have.  That is the whole point: an interface that is
   also the first client is an interface somebody can actually build on.

       ./poplog basepop11 examples/langpop/server.p              # stdio
       ./poplog basepop11 examples/langpop/server.p --port 7801  # tcp
       ./poplog basepop11 examples/langpop/client.p --port 7801  # the TUI

   Line framing (one JSON value per line), which is what MCP uses over
   stdio, so an MCP host can speak to this with no shim -- see HELP JSONRPC.

   What the server will NOT do is tell a client the answer to the question
   it just asked.  langpop/next returns the prompt; langpop/answer does the
   judging.  A protocol that hands over the answer key is not a tutor, it
   is a quiz file, and once the answer leaves the process no later check
   can be trusted.
*/

vars langpop_lib = true;                ;;; no TUI session from langpop.p
load 'examples/langpop/langpop.p';
load 'examples/langpop/card.p';         ;;; langpop/card.render
load 'examples/langpop/sheet.p';        ;;; langpop/sheet.render

uses jsonrpc;

;;; ------------------------------------------------------------- sessions
;;; A session is a row, not a process: id -> {student, opened_ms, seen}.
;;; Nothing in it is needed to answer a request except the student, which
;;; is what lets a crash lose a session and not a student.

vars
    lp_sessions = newproperty([], 32, false, "perm"),
    lp_session_seq = 0,
;

define lp_new_session(student) -> sid;
    lvars student, sid;
    lp_session_seq + 1 -> lp_session_seq;
    'sess-' <> (lp_session_seq sys_>< '') -> sid;
    ;;; student, opened, item asked, when it was asked, the item a typing
    ;;; slip has already been offered a retry on, and then the three
    ;;; pieces of queue state.
    ;;;
    ;;; The queue is HERE and not in the engine's globals, although the
    ;;; engine owns it, because "comes back in the same session" has to
    ;;; mean this connection's session.  lp_bind returns early when the
    ;;; student has not changed, so a global queue would survive a close
    ;;; and reopen and bring yesterday's deferred questions back as
    ;;; though they had just been put off.
    {% student, lp_now_ms(), false, 0, false,
       [], 0, newproperty([], 32, 0, "perm") %} -> lp_sessions(consword(sid));
enddefine;

;;; The engine reads and writes the queue through its own globals, so a
;;; method that touches it swaps this session's copy in on the way past.
;;; lp_need_session does the loading; a method that changes anything says
;;; so with lp_q_out.
define lp_q_in(s);
    lvars s;
    s(6) -> lp_pending; s(7) -> lp_asked_n; s(8) -> lp_laters;
enddefine;

define lp_q_out(s);
    lvars s;
    lp_pending -> s(6); lp_asked_n -> s(7); lp_laters -> s(8);
enddefine;

define lp_session(sid) -> s;
    lvars sid, s = false;
    if isstring(sid) or isword(sid) then
        lp_sessions(consword(sid sys_>< '')) -> s
    endif;
enddefine;

;;; Bind the engine's globals to a student.  A, being one process for one
;;; person, kept them as globals; the server switches them per request and
;;; writes back after anything that changes.  The profile on disk is the
;;; only durable state, which is why a restart costs a session and nothing
;;; else.
define lp_bind(student) -> ok;
    lvars student, ok = true;
    returnif(lp_user == student)(true -> ok);
    student -> lp_user;
    lp_load_profile(student) -> ok;
    lp_load_persona(if lp_lang == "en" then 'hill' else 'aoi' endif);
enddefine;

;;; --------------------------------------------------------------- errors
;;; A method returns EITHER a result or one of these.  They are returned
;;; rather than raised so that a caller which is not a JSON-RPC client --
;;; an MCP host, the voice backend later -- gets the same answer without
;;; having to catch anything.  A mishap, by contrast, stays a mishap: that
;;; is a bug in here, and jsonrpc_serve turns it into -32603 for a client
;;; while a test still sees it break.
;;;
;;; -32602 is JSON-RPC's own "invalid params"; -32001.. are in the range
;;; the spec reserves for the implementation.  They are distinguished
;;; because a client does different things about them: fix the call, open
;;; a session, register, or tell the student the item does not exist.
;;; -32005 is the one that is not the caller's fault: the method and the
;;; argument are both real and the thing behind them is not built yet.
lconstant
    LP_E_PARAMS     = -32602,
    LP_E_SESSION    = -32001,
    LP_E_STUDENT    = -32002,
    LP_E_ITEM       = -32003,
    LP_E_ASSIGNMENT = -32004,
    LP_E_UNBUILT    = -32005,
;

define lp_err(code, text) -> o;
    lvars code, text, o;
    jsonrpc_obj([% 'langpop_error', true, 'code', code, 'message', text %]) -> o;
enddefine;

define lp_is_err(o);
    lvars o;
    o and (isproperty(o) or isjson_object(o)) and o('langpop_error') and true
enddefine;

;;; ------------------------------------------------------- reply helpers
;;; Prolog atoms arrive in Pop-11 as WORDS, and json_generate does not
;;; take a word -- it mishaps with "unsupported item", some way away from
;;; the line that built the reply.  So everything that came out of the
;;; graph passes through here on its way to the wire.
define lp_jkey(x) -> s;
    lvars x;
    if isword(x) then x sys_>< '' else x endif -> s;
enddefine;

;;; The same, for a value that may be missing: false becomes JSON null.
define lp_jstr(x) -> s;
    lvars x;
    if x == false or isundef(x) then json_null else lp_jkey(x) endif -> s;
enddefine;

;;; Replies are built with jsonrpc_obj, which keeps its members as pairs
;;; and so can hold a member whose value is false.
;;;
;;; This file used to carry its own lp_obj for that.  jsonrpc_obj built a
;;; property, and a Pop-11 property cannot tell a member whose value is
;;; false from a member that is not there -- both read back as false, so
;;; json_generate never wrote them, and every false field vanished off
;;; the wire: "correct": false simply was not in the reply to a wrong
;;; answer, and a prerequisite that was NOT known came out as
;;; {"item": "hi_a"} with the "known" flag missing.  A client reading
;;; result.correct got nothing and had to guess what absence meant, which
;;; is precisely the ambiguity a protocol exists to remove.
;;;
;;; That is fixed in the library now (PR #71, docs/bugs/
;;; jsonrpc-obj-drops-false.md, HELP * JSONRPC), where it also fixed the
;;; same defect in the LSP and MCP servers -- an LSP CompletionList was
;;; going out without its required isIncomplete member.  So the local
;;; copy is gone and the insertion order comes free with it.

define lp_vec(l) -> v;
    lvars l, x;
    consvector(#| for x in l do x endfor |#) -> v;
enddefine;

define lp_param(msg, name) -> v;
    lvars msg, name, p = msg('params'), v = false;
    if p and (isproperty(p) or isjson_object(p)) then p(name) -> v endif;
enddefine;

;;; One item, as the protocol describes it.  Every client needs the same
;;; five things, and none of them is the answer.
;;; One object of channel -> belief, for every channel the item is judged
;;; on.  A word has two, so a client can see a reading belief of 0.9
;;; beside a listening belief of 0.0 instead of one number.
define lp_belief_obj(i) -> o;
    lvars i, ch;
    jsonrpc_obj([% for ch in lp_channels(i) do
                       lp_jkey(ch); lp_bel(i, ch);
                   endfor %]) -> o;
enddefine;

define lp_item_json(i) -> o;
    lvars i, o;
    jsonrpc_obj([% 'item', lp_jkey(i),
                   'form', lp_jkey(lp_any_form(i)),
                   'kind', lp_jkey(lp_kind(i)),
                   'level', lp_jkey(lp_ilevel(i)),
                   'gloss', lp_jstr(lp_gloss_of(i, "en")),
                   'belief', lp_bel(i, lp_primary(i)),
                   'mastered', lp_mastered(i),
                   ;;; Every channel, not just the gate.  A client that
                   ;;; only ever saw the gate would rebuild the same
                   ;;; single-number view this change exists to undo.
                   'channel', lp_jkey(lp_primary(i)),
                   'beliefs', lp_belief_obj(i) %]) -> o;
enddefine;

;;; ---------------------------------------------------------- the methods
;;; Each takes the parsed message and returns a result object.  They are
;;; separate procedures rather than a cond in the dispatcher so that a
;;; later transport (a socket, an MCP host, the voice backend) can call
;;; them directly without pretending to be a JSON-RPC client.

;;; Does the tutor think it has met this person?
;;;
;;; This is the one thing the TUI could do that the protocol could not,
;;; which made Proposal B's premise -- the TUI is just a client -- false
;;; for precisely the feature the project asked for by name: "ahh, is it
;;; Bob Smith?  No, my mistake, Bob White."  A client got a database
;;; lookup where the TUI got a teacher.
;;;
;;; No session, because this happens BEFORE registration.  It is also a
;;; read: it creates nothing and registers nobody, so a client is free to
;;; ignore the answer and go straight to register.
define lp_m_recognise(msg) -> res;
    lvars msg, res,
          user = lp_param(msg, 'student_id'),
          name = lp_param(msg, 'display_name'),
          known, other, display, why;
    unless user and isstring(user) and user /= '' then
        lp_err(LP_E_PARAMS, 'recognise: student_id needed') -> res; return
    endunless;
    consword(lp_norm(user)) -> lp_user;
    ;;; Loading the typed id first is what makes the guess correct rather
    ;;; than merely plausible: it settles whether this person is already
    ;;; known, and it loads THEIR refused guesses, so one that has been
    ;;; turned down before is not offered again.
    lp_load_profile(lp_user) -> known;
    if known then
        (false, false, false) -> (other, display, why);
    else
        lp_roll_guess_full(lp_user, name) -> (other, display, why);
    endif;
    jsonrpc_obj([% 'student_id', lp_jkey(lp_user),
                   'known', known and true,
                   'guess', if other then
                                jsonrpc_obj([% 'student_id', lp_jkey(other),
                                               'display_name', display,
                                               'matched_on', why %])
                            else false endif %]) -> res;
enddefine;

define lp_m_register(msg) -> res;
    lvars msg, res,
          user = lp_param(msg, 'student_id'),
          name = lp_param(msg, 'display_name'),
          lang = lp_param(msg, 'language'),
          not_me = lp_param(msg, 'not_me'),
          known;
    unless user and isstring(user) and user /= '' then
        lp_err(LP_E_PARAMS, 'register: student_id needed') -> res; return
    endunless;
    consword(lp_norm(user)) -> lp_user;
    lp_load_profile(lp_user) -> known;
    unless known then
        if name then name else user endif -> lp_display;
        if lang then consword(lang) else "ja" endif -> lp_lang;
        "preschool" -> lp_level;
        ;;; A guess that was turned down is remembered, so the same wrong
        ;;; name is never offered to this person twice.  Recorded after
        ;;; lp_display is set, because a correction is a pair of the name
        ;;; refused and the name it turned out to be.
        if not_me and isstring(not_me) and not_me /= '' then
            lp_refuse_guess(not_me);
        endif;
        lp_roll_add(lp_user, lp_display);
        lp_save();
    endunless;
    lp_load_persona(if lp_lang == "en" then 'hill' else 'aoi' endif);
    jsonrpc_obj([% 'student_id', lp_jkey(lp_user),
                   'display_name', lp_display,
                   'language', lp_jkey(lp_lang),
                   'level', lp_jkey(lp_level),
                   'teacher', lp_teacher_name(),
                   'returning', known and true %]) -> res;
enddefine;

define lp_m_session_open(msg) -> res;
    lvars msg, res, student = lp_param(msg, 'student_id'), sid;
    unless student then
        lp_err(LP_E_PARAMS, 'session.open: student_id needed') -> res; return
    endunless;
    consword(lp_norm(student)) -> student;
    unless lp_bind(student) then
        lp_err(LP_E_STUDENT, 'no such student: register first') -> res; return
    endunless;
    lp_new_session(student) -> sid;
    jsonrpc_obj([% 'session_id', sid,
                   'teacher', lp_teacher_name(),
                   ;;; A student with no history has not been here before,
                   ;;; whatever the roll says -- "welcome back" to someone
                   ;;; on their first question is the kind of small lie a
                   ;;; teacher with memory should not tell.
                   'greeting', lp_line(if lp_journal == [] then 'greeting'
                                       else 'welcome_back' endif),
                   'returning', lp_journal /== [],
                   'display_name', lp_display,
                   'language', lp_jkey(lp_lang),
                   'level', lp_jkey(lp_level),
                   'ready_count', length(lp_plan()) %]) -> res;
enddefine;

;;; Every method below this line needs a session, and the session is the
;;; only thing that says which student the caller may touch.  Returns the
;;; session, or an error object the method passes straight back.
define lp_need_session(msg) -> s;
    lvars msg, s = lp_session(lp_param(msg, 'session_id'));
    unless s then
        lp_err(LP_E_SESSION, 'no such session: call langpop/session.open') -> s;
        return;
    endunless;
    unless lp_bind(s(1)) then
        lp_err(LP_E_STUDENT, 'session: that student is gone') -> s;
        return;
    endunless;
    lp_q_in(s);
enddefine;

define lp_m_plan(msg) -> res;
    lvars msg, res, i, n = 0, limit = lp_param(msg, 'limit') or 12,
          s = lp_need_session(msg);
    returnif(lp_is_err(s))(s -> res);
    jsonrpc_obj([% 'level', lp_jkey(lp_level),
                   'ready_count', length(lp_plan()),
                   'items', lp_vec([% for i in lp_plan() do
                                          n + 1 -> n;
                                          quitif(n > limit);
                                          lp_item_json(i)
                                      endfor %]) %]) -> res;
enddefine;

;;; The question, and only the question.  No answer leaves here.
define lp_m_next(msg) -> res;
    lvars msg, res, s = lp_need_session(msg), item, shape, prompt, answer, options;
    returnif(lp_is_err(s))(s -> res);
    ;;; Anything put off, or taken back with oops, is owed: the student
    ;;; was told it would come round again, so it comes before anything
    ;;; new.  Reported as `requeued` so a client can say so rather than
    ;;; showing it as a fresh question.
    lvars requeued = lp_due();
    (requeued or lp_choose(lp_plan())) -> item;
    ;;; Everything ready is deferred and nothing else can be asked: the
    ;;; gap gives way rather than handing the client an empty reply.
    if not(item) and lp_pending /== [] then
        hd(lp_pending)(1) -> item; true -> requeued;
    endif;
    ;;; Everything ready is deferred and nothing else can be asked: the
    ;;; gap gives way rather than handing the client an empty reply.
    if not(item) and lp_pending /== [] then
        hd(lp_pending)(1) -> item; true -> requeued;
    endif;
    unless item then
        jsonrpc_obj([% 'item', json_null,
                       'note', 'nothing here can be checked by typing -- try assign' %])
            -> res;
        return;
    endunless;
    lp_question(item) -> (shape, prompt, answer, options);
    ;;; Remember what was asked and when, so the latency is OURS.  A
    ;;; client's own figure is a claim: the speed half of every pre-school
    ;;; exit criterion would be worth nothing if a client could send
    ;;; latency_ms: 1.  The clock that matters is the one the client
    ;;; cannot reach.
    item -> s(3);
    lp_now_ms() -> s(4);
    jsonrpc_obj([% 'item', lp_jkey(item),
                   'shape', lp_jkey(shape),
                   'prompt', lp_jkey(prompt),
                   'options', lp_vec([% lvars o; for o in options do lp_jkey(o) endfor %]),
                   'kind', lp_jkey(lp_kind(item)),
                   'requeued', requeued and true,
                   'belief', lp_bel(item, lp_primary(item)) %]) -> res;
enddefine;

;;; The judging, which stays here for the same reason the answer does.
define lp_m_answer(msg) -> res;
    lvars msg, res, s = lp_need_session(msg),
          item = lp_param(msg, 'item'),
          given = lp_param(msg, 'answer'),
          latency = lp_param(msg, 'latency_ms'),
          shape, prompt, answer, options, typed, correct, other = false;
    returnif(lp_is_err(s))(s -> res);

    ;;; An ACTION instead of an answer.  Both of these say "do not record
    ;;; what I just did", and they are the two halves of one admission:
    ;;; `later` before answering, `oops` after.  Neither is a wrong
    ;;; answer and neither moves a belief.
    lvars act = lp_param(msg, 'action');
    if act then (act sys_>< '') -> act endif;

    if act = 'oops' then
        unless lp_aid("oops") then
            lp_err(LP_E_PARAMS, 'oops is switched off for this student') -> res;
            return;
        endunless;
        lvars took = lp_undo_last();
        ;;; Requeued, not re-asked: the previous reply carried `expected`,
        ;;; so the client has already shown the answer, and asking again
        ;;; straight away would hand over a free correct one.
        if took then lp_requeue(took); lp_q_out(s); lp_save() endif;
        jsonrpc_obj([% 'outcome', 'oops',
                       'accepted', took and true,
                       'item', if took then lp_jkey(took) else json_null endif,
                       'recorded', false,
                       'requeued', took and true,
                       'reply', if took then 'Taken back. It will come round again.'
                                else 'nothing to take back' endif,
                       'belief', if took then lp_bel(took, lp_primary(took))
                                 else json_null endif %]) -> res;
        return;
    endif;

    ;;; `given` may be the empty string: that is a client saying "I do
    ;;; not know", which is an answer and not a missing parameter.  An
    ;;; action does not need one at all.
    unless item and (isstring(given) or act) then
        lp_err(LP_E_PARAMS, 'answer: item and answer needed') -> res; return
    endunless;
    consword(item sys_>< '') -> item;
    unless lp_kind(item) then
        lp_err(LP_E_ITEM, 'no such item: ' <> (item sys_>< '')) -> res; return
    endunless;

    if act = 'later' then
        unless lp_aid("later") then
            lp_err(LP_E_PARAMS, 'later is switched off for this student') -> res;
            return;
        endunless;
        ;;; Twice, and then it has to be answered -- see lp_can_later.
        ;;; Refused with a reply rather than an error, because the client
        ;;; did nothing wrong: it asked, and the answer is no.
        lvars may = lp_can_later(item);
        if may then lp_later(item); lp_q_out(s) endif;
        ;;; s(3) and s(4) are left alone.  A deferred question is asked
        ;;; again from scratch, so there is no clock to stop, and the
        ;;; item in flight stays in flight until something is recorded.
        jsonrpc_obj([% 'item', lp_jkey(item),
                       'outcome', 'later',
                       'accepted', may,
                       'recorded', false,
                       'requeued', may,
                       'reply', if may then lp_line('later')
                                else 'that one has been put off twice -- it needs an answer'
                                endif,
                       'belief', lp_bel(item, lp_primary(item)) %]) -> res;
        return;
    endif;
    unless act == false or act = '' or act = 'answer' then
        lp_err(LP_E_PARAMS, 'answer: action must be later, oops or answer') -> res;
        return;
    endunless;
    unless isstring(given) then
        lp_err(LP_E_PARAMS, 'answer: item and answer needed') -> res; return
    endunless;
    ;;; Server-side timing wins whenever this is the item we asked about;
    ;;; the client's figure is kept only as a fallback for a caller that
    ;;; drives the graph without going through next (a batch import, a
    ;;; test), and it is reported separately so the two never blur.
    unless isinteger(latency) and latency >= 0 then false -> latency endunless;
    lvars timed = false;
    if s(3) == item and s(4) > 0 then
        lp_now_ms() - s(4) -> timed;
        false -> s(3);
    endif;
    lvars used = timed or latency or 0;
    lp_question(item) -> (shape, prompt, answer, options);
    lp_norm(given sys_>< '') -> typed;
    member(typed, answer) and true -> correct;
    ;;; Which of the four this was.  A client says "I do not know" by
    ;;; sending an empty answer, which is the same gesture the TUI reads
    ;;; as an empty line -- and it is worth more than a guess, so it gets
    ;;; its own outcome rather than being filed as wrong.
    lvars outcome;
    unless correct then lp_mistook(item, typed) -> other endunless;

    ;;; A TYPING SLIP IS NOT AN ANSWER.  A learner typing romaji, or
    ;;; fighting an input method they do not know well, makes mistakes
    ;;; that are not gaps in their knowledge -- and recorded as wrong
    ;;; they cost a belief and teach the tutor something false.  So the
    ;;; first one on an item is not recorded at all: the reply says so
    ;;; and the client asks again.  The clock keeps running (s(3) and
    ;;; s(4) are left alone) so that a deliberate slip cannot buy time.
    ;;;
    ;;; Once per item, which is what s(5) remembers -- a client that
    ;;; sends the same near-miss twice gets it recorded the second time.
    if lp_aid("slip") and not(correct) and not(other)
    and typed /= '' and typed /= '?'
    and lp_slip(typed, answer) and s(5) /== item then
        item -> s(5);
        jsonrpc_obj([% 'item', lp_jkey(item),
                       'correct', false,
                       'outcome', 'slip',
                       'recorded', false,
                       'reply', lp_line('slip'),
                       'expected', json_null,
                       'belief', lp_bel(item, lp_primary(item)) %]) -> res;
        return;
    endif;
    false -> s(5);

    if     correct              then "right" -> outcome
    elseif typed = '' or typed = '?' then "skip" -> outcome; false -> other
    elseif other                then "near"  -> outcome
    else                             "wrong" -> outcome
    endif;
    ;;; Wrapped, so that action:oops has something to take back.
    ;;; lp_undo_last restores every belief this moved, which is more than
    ;;; one whenever a correct answer inferred a prerequisite from what
    ;;; the item contains.
    lp_undo_start(item);
    lp_record(item, lp_primary(item), 1, outcome, used);
    lp_undo_stop();
    lp_answered(item);
    lp_q_out(s);
    lp_save();
    jsonrpc_obj([% 'item', lp_jkey(item),
                   'correct', correct,
                   ;;; correct stays a plain boolean for a client that
                   ;;; only wants to know whether to move on; outcome is
                   ;;; what the belief was actually moved by.
                   'outcome', lp_jkey(outcome),
                   'recorded', true,
                   'reply', if correct then lp_line('praise')
                            elseif outcome == "skip" then lp_line('skip')
                            elseif other then lp_line('almost')
                            else lp_line('wrong') endif,
                   ;;; The canonical spelling only.  A client does not
                   ;;; need the whole accepted set, and showing it would
                   ;;; tell a learner that gakko would have done.
                   'expected', if correct then json_null
                               else lp_jkey(hd(answer)) endif,
                   'mistook_for', if other then lp_jkey(other) else json_null endif,
                   'mistook_form', if other then lp_jkey(lp_any_form(other))
                                   else json_null endif,
                   'belief', lp_bel(item, lp_primary(item)),
                   'mastered', lp_mastered(item),
                   'latency_ms', used,
                   'latency_source', if timed then 'server' else 'client' endif,
                   'tier', 1 %]) -> res;
enddefine;

;;; The derivation, which is the thing a knowledge graph owes its user.
define lp_m_explain(msg) -> res;
    lvars msg, res, s = lp_need_session(msg),
          item = lp_param(msg, 'item'), answers, a, pres = [];
    returnif(lp_is_err(s))(s -> res);
    unless item then
        lp_err(LP_E_PARAMS, 'explain: item needed') -> res; return
    endunless;
    consword(item sys_>< '') -> item;
    unless lp_kind(item) then
        lp_err(LP_E_ITEM, 'no such item: ' <> (item sys_>< '')) -> res; return
    endunless;
    lp_ask(item, "why", 1) -> answers;
    [% for a in answers do
           jsonrpc_obj([% 'item', lp_jkey(prolog_full_deref(prolog_arg(1, a))),
                          'known', prolog_functor(a) == "known" %])
       endfor %] -> pres;
    jsonrpc_obj([% 'item', lp_jkey(item),
                   'form', lp_jkey(lp_any_form(item)),
                   'kind', lp_jkey(lp_kind(item)),
                   'level', lp_jkey(lp_ilevel(item)),
                   'source', lp_term_str(lp_isrc(item)),
                   'gloss', lp_jstr(lp_gloss_of(item, "en")),
                   'channel', lp_jkey(lp_primary(item)),
                   'belief', lp_bel(item, lp_primary(item)),
                   'mastery_threshold', MASTERY,
                   'prerequisites', lp_vec(pres) %]) -> res;
enddefine;

define lp_m_status(msg) -> res;
    lvars msg, res, s = lp_need_session(msg), e, c, th, ms, items, acc, fast, n,
          crits = [];
    returnif(lp_is_err(s))(s -> res);
    [% for e in lp_exits do
           nextunless(hd(e) == lp_lang and hd(tl(e)) == lp_level);
           hd(tl(tl(e))) -> c; hd(tl(tl(tl(e)))) -> th; hd(tl(tl(tl(tl(e))))) -> ms;
           if prolog_complexterm(c) and prolog_functor(c) == "vocabulary" then
               lvars vch = prolog_deref(prolog_arg(2, c));
               jsonrpc_obj([% 'criterion', lp_term_str(c),
                              'kind', 'count',
                              'channel', lp_jkey(vch),
                              ;;; A client must be able to tell "zero so
                              ;;; far" from "nothing here can measure
                              ;;; this".  Without the flag it would show
                              ;;; a listening score of 0 of 800 and be
                              ;;; reporting the tool's limit as the
                              ;;; student's ability.
                              'verifiable', lp_verifiable(vch) and true,
                              'have', lp_count_mastered("word", vch),
                              'want', prolog_full_deref(prolog_arg(1, c)),
                              ;;; What the graph holds, which is not the
                              ;;; same as what the student is short of: a
                              ;;; client that showed 12/800 without this
                              ;;; would be reporting the curation's state
                              ;;; as the student's.
                              'in_graph', lp_count_items("word") %])
           elseif prolog_complexterm(c) and prolog_functor(c) == "kanji" then
               lvars kch = prolog_deref(prolog_arg(2, c));
               jsonrpc_obj([% 'criterion', lp_term_str(c),
                              'kind', 'count',
                              'channel', lp_jkey(kch),
                              'verifiable', lp_verifiable(kch) and true,
                              'have', lp_count_mastered_kanji(kch),
                              'want', prolog_full_deref(prolog_arg(1, c)),
                              'in_graph', lp_count_items("kanji") %])
           elseif prolog_complexterm(c) and prolog_functor(c) == "coverage" then
               jsonrpc_obj([% 'criterion', lp_term_str(c),
                              'kind', 'coverage',
                              'note', 'needs the content build' %])
           else
               lp_ask(c, "criterion_items", 1) -> items;
               lp_measure(items, ms) -> (acc, fast, n);
               jsonrpc_obj([% 'criterion', lp_term_str(c),
                              'kind', 'measured',
                              'accuracy', acc,
                              'within_latency', fast,
                              'answers', n,
                              'threshold', th,
                              'latency_ms', ms %])
           endif;
       endfor %] -> crits;
    jsonrpc_obj([% 'display_name', lp_display,
                   'language', lp_jkey(lp_lang),
                   'level', lp_jkey(lp_level),
                   'ready_count', length(lp_plan()),
                   'criteria', lp_vec(crits) %]) -> res;
enddefine;

;;; Work to do away from the keyboard.  The resource is a pointer with a
;;; date; no content from it ever passes through here.
define lp_m_assign(msg) -> res;
    lvars msg, res, s = lp_need_session(msg), item, r, a = false, plan = lp_plan();
    returnif(lp_is_err(s))(s -> res);
    for item in plan do
        nextif(lp_drillable(item));
        lp_resource_for(item) -> r;
        nextunless(r);
        {% length(lp_assigns) + 1, item, hd(r), lp_now_ms(), 'open' %} -> a;
        lp_assigns <> [^a] -> lp_assigns;
        quitloop;
    endfor;
    unless a then
        jsonrpc_obj([% 'assignment_id', json_null,
                       'note', 'everything ready for you can be checked here' %])
            -> res;
        return;
    endunless;
    lp_save();
    jsonrpc_obj([% 'assignment_id', a(1),
                   'item', lp_jkey(a(2)),
                   'form', lp_jkey(lp_any_form(a(2))),
                   'gloss', lp_jstr(lp_gloss_of(a(2), "en")),
                   'resource', lp_jkey(hd(r)),
                   'resource_kind', lp_jkey(hd(tl(tl(r)))),
                   'url', lp_jkey(hd(tl(tl(tl(tl(r)))))),
                   'checked', lp_jkey(hd(tl(tl(tl(tl(tl(r))))))),
                   'say', lp_line('assign') %]) -> res;
enddefine;

;;; The tier is decided here, from the shape of what was reported -- a
;;; client cannot choose its own evidence tier, which is the only reason
;;; the tiers mean anything.
define lp_m_report(msg) -> res;
    lvars msg, res, s = lp_need_session(msg),
          id = lp_param(msg, 'assignment_id'),
          outcome = lp_param(msg, 'outcome'),
          a, c, got, tot, frac, tier, note;
    returnif(lp_is_err(s))(s -> res);
    unless isinteger(id) then
        lp_err(LP_E_PARAMS, 'report: assignment_id needed') -> res; return
    endunless;
    lp_find_assign(id) -> a;
    unless a then
        lp_err(LP_E_ASSIGNMENT, 'no such assignment') -> res; return
    endunless;
    unless outcome then 'ok' -> outcome endunless;
    locchar(`/`, 1, outcome) -> c;
    if c then
        strnumber(substring(1, c - 1, outcome)) -> got;
        strnumber(allbutfirst(c, outcome)) -> tot;
        unless got and tot and tot > 0 then
            lp_err(LP_E_PARAMS,
                   'report: outcome is "ok" or a score like 17/20') -> res; return
        endunless;
        (got * 1.0) / tot -> frac;
        2 -> tier;
        lp_record(a(2), lp_primary(a(2)), 2,
                  if frac >= 0.7 then "right" else "wrong" endif, 0);
        'a reported result carries an item to just below mastery; '
            <> 'the next check here settles it' -> note;
    elseif member(lp_norm(outcome sys_>< ''),
                  ['ok' 'done' 'yes' 'finished' 'complete']) then
        false -> frac; 3 -> tier;
        lp_record(a(2), lp_primary(a(2)), 3, "right", 0);
        'compliance alone cannot reach mastery -- report a result, '
            <> 'or let the tutor check you' -> note;
    else
        ;;; Anything else is refused rather than filed as compliance.  A
        ;;; client that sends "18 out of 20" without the slash means a
        ;;; RESULT, and quietly recording it as "I did it" would throw the
        ;;; number away and cap the item at 0.50 without saying so.
        lp_err(LP_E_PARAMS,
               'report: outcome is a score like 17/20, or one of '
               <> 'ok/done/yes/finished/complete') -> res;
        return;
    endif;
    [% lvars e; for e in lp_assigns do
           if e(1) == id then {% e(1), e(2), e(3), e(4), 'reported' %} else e endif
       endfor %] -> lp_assigns;
    lp_save();
    jsonrpc_obj([% 'assignment_id', id,
                   'accepted', true,
                   'tier', tier,
                   'fraction', frac or json_null,
                   'item', lp_jkey(a(2)),
                   'belief', lp_bel(a(2), lp_primary(a(2))),
                   'mastered', lp_mastered(a(2)),
                   'note', note %]) -> res;
enddefine;

define lp_m_session_close(msg) -> res;
    lvars msg, res, s = lp_need_session(msg), sid = lp_param(msg, 'session_id');
    returnif(lp_is_err(s))(s -> res);
    lp_save();
    ;;; Counted BEFORE the reset, which is the whole of what it reports:
    ;;; questions the student put off and the session ended before it
    ;;; could come back to.
    lvars owed = length(lp_pending);
    ;;; The queue dies with the session, by definition -- and so does the
    ;;; count of how often each item was put off.
    lp_queue_reset();
    false -> lp_sessions(consword(sid sys_>< ''));
    jsonrpc_obj([% 'saved', true,
                   'put_off_unanswered', owed,
                   'signoff', lp_line('signoff'),
                   'answers_recorded', length(lp_journal) %]) -> res;
enddefine;

define lp_m_card_render(msg) -> res;
    lvars msg, res, item = lp_param(msg, 'item'),
          style = lp_param(msg, 'style'), path, w, h, why;
    unless item then
        lp_err(LP_E_PARAMS, 'card.render: item needed') -> res; return
    endunless;
    consword(item sys_>< '') -> item;
    consword(if style then style sys_>< '' else 'word' endif) -> style;

    ;;; No session.  A card is a picture of the GRAPH -- nothing on it
    ;;; depends on who is looking, and nothing about it is recorded -- so
    ;;; requiring a session would be a privilege check protecting nothing.
    lp_card_render(item, style) -> (path, w, h, why);

    if why = 'no_such_item' then
        lp_err(LP_E_ITEM, 'no such item: ' <> (item sys_>< '')) -> res
    elseif why = 'no_written_form' then
        lp_err(LP_E_ITEM, 'nothing to draw: ' <> (item sys_>< '')
                          <> ' has no written form') -> res
    elseif why = 'no_such_style' then
        lp_err(LP_E_PARAMS, 'no such style: ' <> (style sys_>< '')
                            <> ' (word, stroke, sentence)') -> res
    elseif why = 'style_not_built' then
        lp_err(LP_E_UNBUILT, 'style not built yet: ' <> (style sys_>< '')
                             <> ' needs the graphics path') -> res
    elseif why then
        lp_err(LP_E_PARAMS, 'card.render: ' <> why) -> res
    else
        ;;; The path is on the SERVER's filesystem.  A client sharing it
        ;;; can open the file; one that does not has to ask for the bytes,
        ;;; which this method deliberately does not send -- a card is a
        ;;; file on disk, cached by item, and sending it down a JSON-RPC
        ;;; line would make every call pay for it.
        jsonrpc_obj([% 'item', lp_jkey(item), 'style', lp_jkey(style),
                       'path', path, 'width', w, 'height', h,
                       'format', 'svg' %]) -> res
    endif;
enddefine;

;;; ------------------------------------------------------------ dispatch

;;; --------------------------------------------------------- placement
;;; The descent, over the wire.  Deliberately not a stateful test: there
;;; is no placement session, no cursor and nothing to resume, because
;;; lp_place_next is a pure function of the beliefs already recorded.  A
;;; client asks what to ask, answers it through the ordinary
;;; langpop/answer, and asks again -- so a dropped connection costs the
;;; one question in flight and nothing else.
;;;
;;; One question at a time, for the same reason the TUI does it: a
;;; second freeze has to end that axis immediately, and a client handed
;;; a whole batch would keep asking past it.
;;;
;;; action:later needs no special case here, although the TUI refuses it
;;; during a placement.  Nothing is recorded, and this is a function of
;;; the record, so the same question simply comes back -- and lp_can_later
;;; refuses the third attempt, so it cannot be used to stall a descent.
define lp_m_place_next(msg) -> res;
    lvars msg, res, s = lp_need_session(msg),
          axis, level, items, item, shape, prompt, answer, options;
    returnif(lp_is_err(s))(s -> res);
    lp_place_next() -> (axis, level, items);
    unless axis and items /== [] then
        jsonrpc_obj([% 'done', true,
                       'level', lp_jkey(lp_place_level() or lp_level) %]) -> res;
        return;
    endunless;
    hd(items) -> item;
    lp_question(item) -> (shape, prompt, answer, options);
    ;;; the clock is ours, exactly as in langpop/next -- the speed half
    ;;; of a pre-school criterion is worth nothing if a client can send
    ;;; latency_ms: 1
    item -> s(3);
    lp_now_ms() -> s(4);
    jsonrpc_obj([% 'done', false,
                   'axis', axis(1),
                   'level', lp_jkey(level),
                   'item', lp_jkey(item),
                   'shape', lp_jkey(shape),
                   'prompt', lp_jkey(prompt),
                   'options', lp_vec([% lvars o;
                                        for o in options do lp_jkey(o) endfor %]),
                   'kind', lp_jkey(lp_kind(item)) %]) -> res;
enddefine;

;;; Where the student stands on each axis.  Read-only, and callable at
;;; any point -- halfway through a placement it reports what is settled
;;; so far, which is what a client showing progress wants.
define lp_m_place_report(msg) -> res;
    lvars msg, res, s = lp_need_session(msg), r;
    returnif(lp_is_err(s))(s -> res);
    jsonrpc_obj([% 'axes', lp_vec([% for r in lp_place_report() do
                       jsonrpc_obj([% 'axis', r(1),
                                      'placed', if r(2) then lp_jkey(r(2))
                                                else json_null endif,
                                      ;;; why there is no placement, which
                                      ;;; is three different things: not
                                      ;;; passed, not reached, or nothing
                                      ;;; askable at all
                                      'why', lp_jkey(r(3)) %]);
                   endfor %]),
                   'level', lp_jkey(lp_place_level() or lp_level) %]) -> res;
enddefine;

;;; --------------------------------------------------------------- aids
;;; Read, and switch.  A client that offers "I typed it wrong" and a skip
;;; button has to be able to offer the settings too, or the student can
;;; only refuse the help by not pressing the button -- which is not the
;;; same thing, because the point of switching one off is to stop having
;;; to decide each time.
;;;
;;; NAMES rather than a map of booleans, for the reason given in lp_save:
;;; an absent JSON field and a field set to false arrive here
;;; indistinguishable, so {"slip": false} could not be told from a client
;;; that simply did not mention slip.  {"off": ["slip"]} can.
define lp_m_aids(msg) -> res;
    lvars msg, res, s = lp_need_session(msg), a, i, pair, changed = [];
    returnif(lp_is_err(s))(s -> res);
    for pair in [% {% lp_param(msg, 'on'),  true  %},
                   {% lp_param(msg, 'off'), false %} %] do
        nextunless(pair(1) and isvector(pair(1)));
        for i from 1 to length(pair(1)) do
            consword(pair(1)(i) sys_>< '') -> a;
            unless lp_aid_set(a, pair(2)) then
                lp_err(LP_E_PARAMS, 'no such aid: ' <> (a sys_>< '')) -> res;
                return;
            endunless;
            changed <> [^a] -> changed;
        endfor;
    endfor;
    ;;; Saved immediately.  A switch that did not survive a crash would be
    ;;; the one setting a student had to remember to set again, and the
    ;;; log of changes is part of the record, not a session nicety.
    if changed /== [] then lp_save() endif;
    jsonrpc_obj([% 'aids', jsonrpc_obj([% for a in lp_aid_names() do
                                             a sys_>< '', lp_aid(a) endfor %]),
                   'changed', lp_vec([% for a in changed do lp_jkey(a) endfor %]),
                   'changes_logged', length(lp_aid_log),
                   'note', 'every change is logged with its time, so what was '
                           <> 'available at any answer stays recoverable' %]) -> res;
enddefine;

;;; -------------------------------------------------------------- sheets
;;; A page to print.  A chart is a picture of the GRAPH and needs no
;;; session, exactly like card.render; today's sheet is a picture of one
;;; student's session and needs one, because it is their answers on it.
;;; So the session is required conditionally, which is the only method
;;; here that does that -- and it is the honest shape, since refusing a
;;; kana chart to someone who has not logged in would be a privilege
;;; check protecting a table anybody can buy on a poster.
define lp_m_sheet_render(msg) -> res;
    lvars msg, res, style = lp_param(msg, 'style'), s, path, why, who = false;
    unless style then
        lp_err(LP_E_PARAMS,
               'sheet.render: style needed '
               <> '(hiragana, katakana, youon, today, zine)')
            -> res;
        return;
    endunless;
    consword(style sys_>< '') -> style;
    ;;; The two that are a picture of one STUDENT rather than of the
    ;;; graph.  A chart needs no session; these do.
    if style == "today" or style == "zine" then
        lp_need_session(msg) -> s;
        returnif(lp_is_err(s))(s -> res);
        lp_user -> who;
    endif;
    lp_sheet_render(style, who) -> (path, why);
    if why = 'no_such_style' then
        lp_err(LP_E_PARAMS, 'no such sheet: ' <> (style sys_>< '')) -> res
    elseif why then
        lp_err(LP_E_PARAMS, 'sheet.render: ' <> why) -> res
    else
        ;;; The path, not the bytes -- the same bargain card.render makes.
        jsonrpc_obj([% 'style', lp_jkey(style),
                       'path', path,
                       'format', 'svg',
                       'page', 'A4',
                       ;;; the zine is the one landscape sheet, and a
                       ;;; client that printed it portrait would get a
                       ;;; booklet nobody can fold
                       'orientation', if style == "zine" then 'landscape'
                                      else 'portrait' endif,
                       'pages', if style == "zine" then 8 else 1 endif,
                       ;;; printable is the whole point, so say so in the
                       ;;; units a print dialog uses
                       'width_mm', if style == "zine" then 297 else 210 endif,
                       'height_mm', if style == "zine" then 210 else 297 endif
                       %]) -> res
    endif;
enddefine;

;;; -------------------------------------------------------------- audit
;;; Which rungs of the ladder are hollow.  No session, for the same
;;; reason card.render needs none: this is a property of the GRAPH, not
;;; of anybody's progress, and requiring a session would be a privilege
;;; check protecting nothing.
;;;
;;; A client that draws a ladder wants this. Showing a student
;;; `kanji(2230)` as a goal they are 0.05% of the way to, when the graph
;;; holds 103 kanji, reports the tool's emptiness as the student's
;;; failure -- the same mistake `"verifiable": false` exists to prevent
;;; on langpop/status.
define lp_m_audit(msg) -> res;
    lvars msg, res, r, lang = lp_param(msg, 'language'), rows;
    if lang then consword(lang sys_>< '') -> lang endif;
    lp_audit() -> rows;
    jsonrpc_obj([% 'criteria',
        lp_vec([% for r in rows do
            nextif(lang and r(1) /== lang);
            jsonrpc_obj([% 'language', lp_jkey(r(1)),
                           'level', lp_jkey(r(2)),
                           'criterion', lp_term_str(r(3)),
                           'verdict', lp_jkey(r(4)),
                           'in_graph', r(5),
                           'askable', r(6),
                           ;;; null, not 0: a criterion that is not a
                           ;;; count has no target, and a 0 there would
                           ;;; read as one that wants nothing.
                           'wanted', if r(7) then r(7) else json_null endif,
                           'short_by', if r(4) == "short" then r(7) - r(6)
                                       else json_null endif %]);
        endfor %]) %]) -> res;
enddefine;

lconstant METHODS = [
    ['langpop/recognise'     ^lp_m_recognise]
    ['langpop/register'      ^lp_m_register]
    ['langpop/session.open'  ^lp_m_session_open]
    ['langpop/session.close' ^lp_m_session_close]
    ['langpop/plan'          ^lp_m_plan]
    ['langpop/next'          ^lp_m_next]
    ['langpop/answer'        ^lp_m_answer]
    ['langpop/explain'       ^lp_m_explain]
    ['langpop/status'        ^lp_m_status]
    ['langpop/aids'          ^lp_m_aids]
    ['langpop/audit'         ^lp_m_audit]
    ['langpop/placement.next'   ^lp_m_place_next]
    ['langpop/placement.report' ^lp_m_place_report]
    ['langpop/assign'        ^lp_m_assign]
    ['langpop/report'        ^lp_m_report]
    ['langpop/card.render'   ^lp_m_card_render]
    ['langpop/sheet.render'  ^lp_m_sheet_render]
];

define lp_method(name) -> p;
    lvars name, e, p = false;
    for e in METHODS do if hd(e) = name then hd(tl(e)) -> p; return endif endfor;
enddefine;

define lp_rpc_handle(conn, msg);
    lvars conn, msg, method, id, p;
    returnunless(msg and (isproperty(msg) or isjson_object(msg)));
    msg('method') -> method;
    msg('id') -> id;
    if method = 'langpop/methods' then
        jsonrpc_respond(conn, id,
            lp_vec([% lvars e; for e in METHODS do hd(e) endfor %]));
    elseif method = 'ping' then
        jsonrpc_respond(conn, id, 'pong');
    elseif lp_method(method) ->> p then
        lvars r = p(msg);
        if lp_is_err(r) then
            jsonrpc_error(conn, id, r('code'), r('message'))
        else
            jsonrpc_respond(conn, id, r)
        endif;
    elseif id then
        jsonrpc_error(conn, id, -32601, 'method not found: ' <> (method sys_>< ''));
    endif;
enddefine;

;;; --------------------------------------------------------------- main
define lp_server_main();
    lvars args = poparglist, a, port = false, listener, conn;
    find_dir() -> langpop_dir;
    until args == [] do
        hd(args) -> a;
        if a = '--port' then strnumber(hd(tl(args))) -> port; tl(tl(args)) -> args;
        elseif a = '--data' then hd(tl(args)) -> lp_home_dir; tl(tl(args)) -> args;
        elseif a = '--stdio' then tl(args) -> args;
        else tl(args) -> args;
        endif;
    enduntil;
    lp_load();
    lp_index();
    if port then
        jsonrpc_listen(port) -> listener;
        printf('langpop: serving %p items on port %p\n',
               [% length(lp_items), port %]);
        sysflush(popdevout);
        repeat
            jsonrpc_accept(listener, "line") -> conn;
            jsonrpc_serve(conn, lp_rpc_handle);
            jsonrpc_close(conn);
        endrepeat;
    else
        jsonrpc_serve(jsonrpc_stdio("line"), lp_rpc_handle);
    endif;
enddefine;

unless isdefined("langpop_server_lib") then lp_server_main() endunless;
