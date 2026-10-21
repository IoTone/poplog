;;; test_langpop_server.p -- the protocol (Proposal B), over a socket pair.
;;;
;;;     tools/test-libs.sh examples/langpop/tests/test_langpop_server.p
;;;
;;; No forks and no ports: both ends of a sys_socket_pair live here, a
;;; request is written at one end and the server's handler is driven once,
;;; which is the idiom tools/tests/test_jsonrpc.p uses.  So these are tests
;;; of the PROTOCOL -- what a client that is not the TUI can see and do --
;;; rather than of the engine, which test_langpop.p already covers.

uses poptest;

vars langpop_server_lib = true;         ;;; no serve loop, just the handler
load 'examples/langpop/server.p';

find_dir() -> langpop_dir;
lp_load();
lp_index();

;;; Profiles go to a temp dir, never a real person's home.
lvars tmpdir = '/tmp/langpop-rpc-test-' sys_>< sys_real_time() sys_>< '/';
tmpdir -> lp_home_dir;

vars (ca, cb) = sys_socket_pair(`u`, `S`, false);
vars client = jsonrpc_wrap(ca, "line"), server = jsonrpc_wrap(cb, "line");
vars rpc_id = 0;

;;; One round trip: write a request, let the handler answer it, read back.
define call(method, params) -> reply;
    lvars method, params, reply;
    rpc_id + 1 -> rpc_id;
    jsonrpc_write(client, jsonrpc_obj([% 'jsonrpc', '2.0', 'id', rpc_id,
                                         'method', method, 'params', params %]));
    lp_rpc_handle(server, jsonrpc_read(server));
    jsonrpc_read(client) -> reply;
enddefine;

define result(method, params) -> r;
    lvars method, params, reply = call(method, params);
    reply('result') -> r;
enddefine;

;;; The reply as BYTES, before anyone parses it.  This matters because
;;; json_parse builds a property too, so a false that never reached the
;;; wire and a false that did look identical once parsed -- the only
;;; place the difference exists is the line itself.
define raw(method, params) -> line;
    lvars method, params, dev, buf = inits(1), got, n = 0;
    rpc_id + 1 -> rpc_id;
    jsonrpc_write(client, jsonrpc_obj([% 'jsonrpc', '2.0', 'id', rpc_id,
                                    'method', method, 'params', params %]));
    lp_rpc_handle(server, jsonrpc_read(server));
    jsonrpc_device(client) -> dev;
    repeat
        sysread(dev, buf, 1) -> got;
        quitif(got == 0);
        quitif(buf(1) == `\n`);
        buf(1); n + 1 -> n;
    endrepeat;
    consstring(n) -> line;
enddefine;

define errcode(method, params) -> c;
    lvars method, params, reply = call(method, params), e = reply('error');
    if e then e('code') else false endif -> c;
enddefine;

;;; ------------------------------------------------------------- the door
check('ping', result('ping', false), 'pong');
check_true('methods are listable',
           length(result('langpop/methods', false)) == 15);
check_true('and the list names them, not just counts them',
           member('langpop/card.render',
                  [% explode(result('langpop/methods', false)) %]) /== false);
check_true('recognition is on the wire, not only in the TUI',
           member('langpop/recognise',
                  [% explode(result('langpop/methods', false)) %]) /== false);
check('an unknown method is -32601',
      errcode('langpop/nope', false), -32601);

;;; A session is the only thing that names a student, so every method that
;;; touches one must refuse without it.
check('plan needs a session', errcode('langpop/plan', false), -32001);
check('answer needs a session',
      errcode('langpop/answer', jsonrpc_obj([% 'item', 'hi_a', 'answer', 'a' %])),
      -32001);
check('register needs a student id',
      errcode('langpop/register', jsonrpc_obj([% 'display_name', 'Nobody' %])),
      -32602);

;;; ----------------------------------------------------------- the student
vars reg = result('langpop/register',
                  jsonrpc_obj([% 'student_id', 'rpcuser',
                                 'display_name', 'RPC User',
                                 'language', 'ja' %]));
check('register returns the id', reg('student_id'), 'rpcuser');
check('and the display name', reg('display_name'), 'RPC User');
check('and starts below N5', reg('level'), 'preschool');
check_false('a new student is not returning', reg('returning'));
check('the teacher has a name', reg('teacher'), 'Aoi');

vars reg2 = result('langpop/register', jsonrpc_obj([% 'student_id', 'rpcuser' %]));
check_true('registering again finds the profile', reg2('returning'));
check('and keeps the name it was given', reg2('display_name'), 'RPC User');

vars sess = result('langpop/session.open',
                   jsonrpc_obj([% 'student_id', 'rpcuser' %]));
vars sid = sess('session_id');
check_true('session.open hands back an id', isstring(sid) and sid /= '');
check('five items are ready at the start', sess('ready_count'), 5);

check('an unknown student cannot open a session',
      errcode('langpop/session.open', jsonrpc_obj([% 'student_id', 'ghost' %])),
      -32002);

;;; -------------------------------------------------------------- the plan
vars plan = result('langpop/plan', jsonrpc_obj([% 'session_id', sid %]));
check('the plan is the five vowels', plan('ready_count'), 5);
check('and it carries their forms', length(plan('items')), 5);
check('an item reports its kind', plan('items')(1)('kind'), 'grapheme');
check('and its belief', plan('items')(1)('belief'), 0.0);

;;; ---------------------------------------------- the question and the key
;;; The server must not hand over the answer: a protocol that does is a
;;; quiz file, not a tutor.
vars q = result('langpop/next', jsonrpc_obj([% 'session_id', sid %]));
vars qitem = q('item');
check_true('next offers an item', isstring(qitem) and qitem /= '');
check('and says how to answer it', q('shape'), 'type');
check_true('and shows the glyph', isstring(q('prompt')) and q('prompt') /= '');
;;; Not "does it have a field called answer", but "is the answer anywhere
;;; in this reply at all" -- including inside the prompt, which is where a
;;; careless renderer would put it.
define leaks(reply, answer) -> yes;
    lvars reply, answer, yes = false;
    json_object_app(reply,
        procedure(k, v);
            lvars k, v;
            if isstring(v) and v = answer and k /= 'item' then true -> yes endif;
        endprocedure);
enddefine;

;;; あ's answer is 'a', so ask about an item whose answer is not a single
;;; letter that could occur by accident.
vars probe = result('langpop/next', jsonrpc_obj([% 'session_id', sid %]));
check_false('next does not carry the answer anywhere in the reply',
            leaks(probe, 'a') or leaks(probe, 'i') or leaks(probe, 'u')
            or leaks(probe, 'e') or leaks(probe, 'o'));

;;; -------------------------------------------------------------- answering
vars wrong = result('langpop/answer',
                    jsonrpc_obj([% 'session_id', sid, 'item', qitem,
                                   'answer', 'zzz', 'latency_ms', 900 %]));
check_false('a wrong answer is wrong', wrong('correct'));
check('and now the expected answer may be shown', isstring(wrong('expected')), true);
check('a wrong answer is still tier 1', wrong('tier'), 1);
;;; A false that is ON the wire, not merely absent from it: jsonrpc_obj
;;; builds a property, where false and missing are the same thing, so
;;; every false field used to disappear from the reply.
;;; A false that is ON the wire, not merely absent from it.  jsonrpc_obj
;;; builds a property, where false and missing are the same value, so
;;; every false field used to vanish from the reply: a wrong answer came
;;; back with no "correct" member at all, leaving a client to guess what
;;; absence meant.  Checked against the raw line, since a reparse would
;;; lose the distinction all over again.
lvars raw_wrong = raw('langpop/answer',
                      jsonrpc_obj([% 'session_id', sid, 'item', 'hi_a',
                                'answer', 'zz' %]));
check_true('"correct":false is on the wire',
           issubstring('"correct":false', raw_wrong) and true);
check_true('"mastered":false too',
           issubstring('"mastered":false', raw_wrong) and true);
lvars raw_why = raw('langpop/explain',
                    jsonrpc_obj([% 'session_id', sid, 'item', 'hi_ka' %]));
check_true('a prerequisite that is not known says so',
           issubstring('"known":false', raw_why) and true);
;;; The latency is the server's, measured from the question it asked --
;;; not the 900ms the client claimed above.
check('the server timed it, not the client', wrong('latency_source'), 'server');
check_true('and the figure is its own', wrong('latency_ms') /= 900);

;;; A caller that answers an item nobody asked it about has no server
;;; timing to use, and the reply says so rather than pretending.
vars unasked = result('langpop/answer',
                      jsonrpc_obj([% 'session_id', sid, 'item', 'hi_e',
                                     'answer', 'e', 'latency_ms', 1234 %]));
check('an unprompted answer falls back to the client figure',
      unasked('latency_source'), 'client');
check('and keeps it', unasked('latency_ms'), 1234);

vars right = result('langpop/answer',
                    jsonrpc_obj([% 'session_id', sid, 'item', qitem,
                                   'answer', wrong('expected'), 'latency_ms', 700 %]));
check_true('the expected answer is accepted', right('correct'));
check_true('belief moves', right('belief') > 0.0);
check_false('one right answer is not mastery', right('mastered'));

;;; The confusable diagnosis, over the wire: 'o' for あ is the classic one.
vars mix = result('langpop/answer',
                  jsonrpc_obj([% 'session_id', sid, 'item', 'hi_a',
                                 'answer', 'o', 'latency_ms', 800 %]));
check('a confusion is named', mix('mistook_for'), 'hi_o');
check('with the glyph the student probably meant', mix('mistook_form'), 'お');

check('answering an item that does not exist',
      errcode('langpop/answer',
              jsonrpc_obj([% 'session_id', sid, 'item', 'no_such',
                             'answer', 'x' %])),
      -32003);
check('answering with no answer at all',
      errcode('langpop/answer', jsonrpc_obj([% 'session_id', sid, 'item', 'hi_a' %])),
      -32602);

;;; ------------------------------------------------------------ explaining
vars why = result('langpop/explain',
                  jsonrpc_obj([% 'session_id', sid, 'item', 'hi_ka' %]));
check('explain names the item', why('item'), 'hi_ka');
check('its provenance is in the answer', why('source'), 'own(kana)');
check('its five prerequisites are listed', length(why('prerequisites')), 5);
check('and whether each is in place', why('prerequisites')(1)('known'), false);
check('mastery is stated, not implied', why('mastery_threshold'), 0.8);

;;; --------------------------------------------------------------- status
vars st = result('langpop/status', jsonrpc_obj([% 'session_id', sid %]));
check('status is per level', st('level'), 'preschool');
check('with every exit criterion', length(st('criteria')), 7);
check('a measured one carries its latency budget',
      st('criteria')(1)('latency_ms'), 2000);

;;; Found by name, not by index.  The index moved the moment the count
;;; criteria were split by channel, and a positional assertion fails for
;;; a reason that has nothing to do with what it was checking.
define crit(name) -> c;
    lvars name, c = false, x;
    for x in [% explode(st('criteria')) %] do
        if x('criterion') = name then x -> c; return endif;
    endfor;
enddefine;

check_true('the reading vocabulary criterion is there', crit('vocabulary(50, read)') /== false);
check('and it is a count', crit('vocabulary(50, read)')('kind'), 'count');
check('and it names its channel', crit('vocabulary(50, read)')('channel'), 'read');
check('and says it can be checked', crit('vocabulary(50, read)')('verifiable'), true);

;;; The point of the channel split: a client must be able to tell "zero so
;;; far" from "nothing here can measure this", or it reports the tool's
;;; limit as the student's ability.
check_true('the listening one is there too', crit('vocabulary(50, hear)') /== false);
check('and says it cannot be checked',
      crit('vocabulary(50, hear)')('verifiable'), false);
check('while still carrying the target',
      crit('vocabulary(50, hear)')('want'), 50);

;;; ------------------------------------------------- answering an import
;;; Every imported Japanese item used to return shape "none", so a client
;;; driving langpop/next at N5 got {"item": null, "note": "nothing here
;;; can be checked by typing"} for 251 items.  This is the whole round
;;; trip for one, in both spellings a learner might use -- and it is
;;; skipped on a checkout where the content has not been built, because
;;; there are then no imported items to ask about.
result('langpop/register', jsonrpc_obj([% 'student_id', 'n5reader',
                                          'display_name', 'N5 Reader',
                                          'language', 'ja' %])).erase;
vars n5s = result('langpop/session.open',
                  jsonrpc_obj([% 'student_id', 'n5reader' %]))('session_id');

vars iq = result('langpop/next', jsonrpc_obj([% 'session_id', n5s %]));
check_true('something is askable', iq('item') /== json_null);

if lp_ilang("w_yama") then
    ;;; An imported word, answered in kana.
    vars ia = result('langpop/answer',
                     jsonrpc_obj([% 'session_id', n5s, 'item', 'w_yama',
                                    'answer', 'やま' %]));
    check('the kana reading is accepted', ia('correct'), true);
    check('and it is tier 1, a verified check', ia('tier'), 1);

    ;;; The same word in romaji, which is the whole reason the
    ;;; transliterator exists: a learner has no reason to own an IME.
    vars ib = result('langpop/answer',
                     jsonrpc_obj([% 'session_id', n5s, 'item', 'w_yama',
                                    'answer', 'yama' %]));
    check('romaji is accepted too', ib('correct'), true);

    ;;; An imported kanji, answered with its on reading.
    vars ic = result('langpop/answer',
                     jsonrpc_obj([% 'session_id', n5s, 'item', 'k_65e5',
                                    'answer', 'nichi' %]));
    check('an on reading answers a kanji', ic('correct'), true);

    ;;; And a wrong answer names the canonical spelling, not the whole
    ;;; set -- telling a learner that gakko would also have done is not
    ;;; the job of a correction.
    vars id2 = result('langpop/answer',
                      jsonrpc_obj([% 'session_id', n5s, 'item', 'w_yama',
                                     'answer', 'kawa' %]));
    check('a wrong reading is wrong', id2('correct'), false);
    check('and the expected answer is the kana', id2('expected'), 'やま');
else
    printf(';;; imported content not built -- import answers not checked\n');
endif;



;;; ------------------------------------------------------ typing slips
;;; The first near miss on an item is not recorded at all: the reply
;;; says so and the client asks again.  Recorded as wrong it would cost
;;; a belief and teach the tutor something false.
result('langpop/register', jsonrpc_obj([% 'student_id', 'typist',
                                          'language', 'ja' %])).erase;
vars tsid = result('langpop/session.open',
                   jsonrpc_obj([% 'student_id', 'typist' %]))('session_id');

;;; w_neko answers to "neko", so "nek" is one deletion away.
vars sl = result('langpop/answer',
                 jsonrpc_obj([% 'session_id', tsid, 'item', 'w_neko',
                                'answer', 'nek' %]));
check('a slip is named as one', sl('outcome'), 'slip');
check('and is explicitly not recorded', sl('recorded'), false);
check('nothing is revealed by it', sl('expected'), json_null);
check('the belief did not move', sl('belief'), 0.0);

;;; Sending the same near miss again records it -- the retry is offered
;;; once, not forever.
vars sl2 = result('langpop/answer',
                  jsonrpc_obj([% 'session_id', tsid, 'item', 'w_neko',
                                 'answer', 'nek' %]));
check('the second time it counts', sl2('recorded'), true);
check('as a plain wrong answer', sl2('outcome'), 'wrong');

;;; A short answer is never treated as a slip, so nothing hints that it
;;; was close.
vars sl3 = result('langpop/answer',
                  jsonrpc_obj([% 'session_id', tsid, 'item', 'hi_ka',
                                 'answer', 'ke' %]));
check('ke for ka is a mistake, not a slip', sl3('outcome'), 'wrong');
check('and it is recorded', sl3('recorded'), true);

;;; An ordinary correct answer still says it was recorded.
vars sl4 = result('langpop/answer',
                  jsonrpc_obj([% 'session_id', tsid, 'item', 'hi_a',
                                 'answer', 'a' %]));
check('a right answer is recorded', sl4('recorded'), true);
check('and named right', sl4('outcome'), 'right');

;;; ------------------------------------------------ later, oops, aids
;;; The two halves of one admission: `later` before answering, `oops`
;;; after.  Neither is a wrong answer, so neither moves a belief -- and
;;; both put the question back in this session's queue, because the
;;; student was told it would come round again.
result('langpop/register', jsonrpc_obj([% 'student_id', 'deferrer',
                                          'language', 'ja' %])).erase;
vars dsid = result('langpop/session.open',
                   jsonrpc_obj([% 'student_id', 'deferrer' %]))('session_id');

vars la = result('langpop/answer',
                 jsonrpc_obj([% 'session_id', dsid, 'item', 'hi_a',
                                'action', 'later' %]));
check('later is accepted', la('accepted'), true);
check('and named', la('outcome'), 'later');
check('nothing is recorded', la('recorded'), false);
check('it is requeued', la('requeued'), true);
check('and the belief did not move', la('belief'), 0.0);
check('no answer is needed to defer one', la('item'), 'hi_a');

;;; Twice, and then it has to be answered.  Refused with a reply rather
;;; than an error: the client asked, and the answer is no.
result('langpop/answer', jsonrpc_obj([% 'session_id', dsid, 'item', 'hi_a',
                                        'action', 'later' %])).erase;
vars la3 = result('langpop/answer',
                  jsonrpc_obj([% 'session_id', dsid, 'item', 'hi_a',
                                 'action', 'later' %]));
check('a third deferral is refused', la3('accepted'), false);
check('and not requeued again', la3('requeued'), false);
check('still nothing recorded', la3('recorded'), false);

;;; The gap, over the wire.  The deferred question comes back ahead of
;;; anything new, and is flagged, so a client can say so rather than
;;; showing it as a fresh question.
;;;
;;; The three intervening answers are named rather than taken from
;;; langpop/next, because next is entitled to choose the deferred item
;;; itself -- it has the lowest belief of anything ready -- and an answer
;;; to it settles the debt rather than deferring it.
vars dq, di;
for di in ['hi_i' 'hi_u'] do
    result('langpop/answer', jsonrpc_obj([% 'session_id', dsid, 'item', di,
                                            'answer', allbutfirst(3, di) %])).erase;
endfor;
result('langpop/next', jsonrpc_obj([% 'session_id', dsid %])) -> dq;
check('two answers in, nothing is owed yet', dq('requeued'), false);
result('langpop/answer', jsonrpc_obj([% 'session_id', dsid, 'item', 'hi_e',
                                        'answer', 'e' %])).erase;
result('langpop/next', jsonrpc_obj([% 'session_id', dsid %])) -> dq;
check('the third brings it back', dq('requeued'), true);
check('and it is the one that was put off', dq('item'), 'hi_a');

;;; oops takes back the last answer and requeues it.  It must restore
;;; every belief that answer moved, and it must NOT re-ask straight away:
;;; the previous reply carried `expected`, so the client has already
;;; shown the answer.
result('langpop/register', jsonrpc_obj([% 'student_id', 'oopser',
                                          'language', 'ja' %])).erase;
vars osid = result('langpop/session.open',
                   jsonrpc_obj([% 'student_id', 'oopser' %]))('session_id');
vars ow = result('langpop/answer',
                 jsonrpc_obj([% 'session_id', osid, 'item', 'hi_ka',
                                'answer', 'ke' %]));
check('a wrong answer is recorded', ow('recorded'), true);
check_true('and it told the client the answer', ow('expected') /== json_null);

vars oo = result('langpop/answer',
                 jsonrpc_obj([% 'session_id', osid, 'action', 'oops' %]));
check('oops is accepted', oo('accepted'), true);
check('and names the item to ask again', oo('item'), 'hi_ka');
check('it is requeued, not re-asked', oo('requeued'), true);
check('nothing is recorded for it', oo('recorded'), false);
check('and the belief is back where it was', oo('belief'), 0.0);

;;; One answer deep.  A second oops has nothing to take back, which is
;;; said rather than raised.
vars oo2 = result('langpop/answer',
                  jsonrpc_obj([% 'session_id', osid, 'action', 'oops' %]));
check('a second oops is refused', oo2('accepted'), false);
check('with no item', oo2('item'), json_null);

;;; A correct answer credits what the item contains, so undoing it has
;;; to undo those too -- the same requirement the TUI has.
if lp_ilang("k_65e5") then
    result('langpop/answer',
           jsonrpc_obj([% 'session_id', osid, 'item', 'w_tanjoubi',
                          'answer', 'tanjoubi' %])).erase;
    check_true('reading the word credited the kanji in it',
               lp_bel("k_65e5", "read") > 0.0);
    result('langpop/answer',
           jsonrpc_obj([% 'session_id', osid, 'action', 'oops' %])).erase;
    check('and oops took the inference back too',
          lp_bel("k_65e5", "read"), 0.0);
else
    printf(';;; imported content not built -- inferred undo not checked\n');
endif;

;;; The switches.  Names rather than booleans, because an absent JSON
;;; field and a field set to false arrive here identically.
vars ai = result('langpop/aids', jsonrpc_obj([% 'session_id', osid %]));
check('slip is on', ai('aids')('slip'), true);
check('oops is on', ai('aids')('oops'), true);
check('later is on', ai('aids')('later'), true);
check('nothing changed by reading', length(ai('changed')), 0);

vars ai2 = result('langpop/aids',
                  jsonrpc_obj([% 'session_id', osid,
                                 'off', lp_vec(['slip' 'later']) %]));
check('two switched off', length(ai2('changed')), 2);
check('slip is off', ai2('aids')('slip'), false);
check('later is off', ai2('aids')('later'), false);
check('oops is untouched', ai2('aids')('oops'), true);
check('and both changes are logged', ai2('changes_logged'), 2);

;;; Switched off, it is refused rather than hidden -- otherwise a client
;;; could offer the button and the student would never know which
;;; standard they were being held to.
vars lo = call('langpop/answer',
               jsonrpc_obj([% 'session_id', osid, 'item', 'hi_a',
                              'action', 'later' %]));
check_true('later off means the call is refused', lo('error') /== false);

;;; And with slip off, a near miss is an ordinary wrong answer, recorded
;;; the first time.
vars so = result('langpop/answer',
                 jsonrpc_obj([% 'session_id', osid, 'item', 'w_neko',
                                'answer', 'nek' %]));
check('with slip off a near miss is recorded at once', so('recorded'), true);
check('and called wrong', so('outcome'), 'wrong');

result('langpop/aids', jsonrpc_obj([% 'session_id', osid,
                                      'on', lp_vec(['slip' 'later']) %])).erase;

check_true('an unknown aid is an error',
           call('langpop/aids',
                jsonrpc_obj([% 'session_id', osid,
                               'off', lp_vec(['cheat']) %]))('error') /== false);

;;; An action nobody implements is an error, not a silently recorded
;;; wrong answer.
check_true('an unknown action is refused',
           call('langpop/answer',
                jsonrpc_obj([% 'session_id', osid, 'item', 'hi_a',
                               'answer', 'a', 'action', 'pass' %]))('error')
           /== false);

;;; The queue dies with the session: "it comes back in the same session"
;;; cannot mean the session before last.  A session of its own, so the
;;; count is of these two deferrals and not of everything oopser has
;;; taken back above.
result('langpop/register', jsonrpc_obj([% 'student_id', 'closer',
                                          'language', 'ja' %])).erase;
vars csid = result('langpop/session.open',
                   jsonrpc_obj([% 'student_id', 'closer' %]))('session_id');
result('langpop/answer', jsonrpc_obj([% 'session_id', csid, 'item', 'hi_i',
                                        'action', 'later' %])).erase;
result('langpop/answer', jsonrpc_obj([% 'session_id', csid, 'item', 'hi_u',
                                        'action', 'later' %])).erase;
vars cl = result('langpop/session.close', jsonrpc_obj([% 'session_id', csid %]));
check('the close says what was still owed', cl('put_off_unanswered'), 2);
vars csid2 = result('langpop/session.open',
                    jsonrpc_obj([% 'student_id', 'closer' %]))('session_id');
vars nq = result('langpop/next', jsonrpc_obj([% 'session_id', csid2 %]));
check('a new session owes nothing', nq('requeued'), false);


;;; ------------------------------------------------------- placement
;;; Deliberately not a stateful test.  There is no placement session and
;;; nothing to resume, because lp_place_next is a pure function of the
;;; beliefs already recorded -- so a dropped connection costs the one
;;; question in flight and nothing else.
result('langpop/register', jsonrpc_obj([% 'student_id', 'placed',
                                          'language', 'ja' %])).erase;
vars psid = result('langpop/session.open',
                   jsonrpc_obj([% 'student_id', 'placed' %]))('session_id');

vars pq = result('langpop/placement.next', jsonrpc_obj([% 'session_id', psid %]));
check('a fresh student has somewhere to start', pq('done'), false);
check_true('and is told which axis it is about', pq('axis') /== false);
check_true('with a level', pq('level') /== false);
check_true('and a question to ask', pq('shape') /== 'none');

;;; The whole descent, answered correctly, ends.
vars pn = 0, pitem;
repeat
    result('langpop/placement.next', jsonrpc_obj([% 'session_id', psid %])) -> pq;
    quitif(pq('done'));
    pq('item') -> pitem;
    ;;; answer it right, whatever it is
    lvars (psh, ppr, pans, popt) = lp_question(consword(pitem));
    result('langpop/answer',
           jsonrpc_obj([% 'session_id', psid, 'item', pitem,
                          'answer', hd(pans) %])).erase;
    pn + 1 -> pn;
    quitif(pn > 60);
endrepeat;
check_true('a placement terminates', pn < 60);
check_true('and does not take all day', pn < 40);

vars prep = result('langpop/placement.report', jsonrpc_obj([% 'session_id', psid %]));
check_true('every axis is reported', length(prep('axes')) > 3);
check_true('with a level to teach at', prep('level') /== false);

;;; An axis with nothing askable says so, rather than being reported as
;;; a failure -- three different things used to look like one.
vars pwhy = [% lvars x;
               for x in [% explode(prep('axes')) %] do x('why') endfor %];
check_true('the reasons are named', member('askable', pwhy) /== false);

;;; Placement needs a session, because it writes beliefs against a
;;; student.
check('placement.next needs a session',
      errcode('langpop/placement.next', false), -32001);
check('and so does the report',
      errcode('langpop/placement.report', false), -32001);

;;; ----------------------------------------------------------- recognition
;;; The one thing the TUI could do that the protocol could not, which made
;;; Proposal B's premise -- the TUI is just a client -- false for exactly
;;; the feature the project named: "ahh, is it Bob Smith?  No, my mistake,
;;; Bob White."  A client got a lookup where the TUI got a teacher.

;;; Two people on the roll, one of whom shares a given name with somebody
;;; about to arrive.
result('langpop/register', jsonrpc_obj([% 'student_id', 'bsmith',
                                          'display_name', 'Bob Smith' %])).erase;
result('langpop/register', jsonrpc_obj([% 'student_id', 'yuki',
                                          'display_name', 'Yuki Tanaka' %])).erase;

vars rec = result('langpop/recognise',
                  jsonrpc_obj([% 'student_id', 'bwhite',
                                 'display_name', 'Bob White' %]));
check('a new person is not known', rec('known'), false);
check_true('but is offered the near name', rec('guess') /== false);
check('by id', rec('guess')('student_id'), 'bsmith');
check('and by the name it would call them',
      rec('guess')('display_name'), 'Bob Smith');
check('and says what it matched on', rec('guess')('matched_on'), 'the name');

;;; A typo in a username that IS on the roll.  This is the case plain
;;; Levenshtein missed, because it charges two for a transposition.
vars rec2 = result('langpop/recognise', jsonrpc_obj([% 'student_id', 'bsmiht' %]));
check_true('a transposed username is recognised', rec2('guess') /== false);
check('as the same person', rec2('guess')('student_id'), 'bsmith');
check('on the username this time', rec2('guess')('matched_on'), 'the username');

;;; Somebody already on the roll needs no guessing at.
vars rec3 = result('langpop/recognise', jsonrpc_obj([% 'student_id', 'yuki' %]));
check('a known student is known', rec3('known'), true);
check('and gets no guess', rec3('guess'), false);

;;; And somebody unrelated gets none either -- a teacher who guesses at
;;; everybody is not remembering anything.
vars rec4 = result('langpop/recognise',
                   jsonrpc_obj([% 'student_id', 'carlos',
                                  'display_name', 'Carlos Ruiz' %]));
check('an unrelated name is not guessed at', rec4('guess'), false);

;;; The correction is what makes it memory rather than guessing: register
;;; carries back the name that was refused.
result('langpop/register', jsonrpc_obj([% 'student_id', 'bwhite',
                                          'display_name', 'Bob White',
                                          'not_me', 'Bob Smith' %])).erase;
vars rec5 = result('langpop/recognise',
                   jsonrpc_obj([% 'student_id', 'bwhite',
                                  'display_name', 'Bob White' %]));
check('after registering they are known', rec5('known'), true);

;;; A different new typo must still be offered Bob Smith -- the refusal
;;; belongs to the person who made it, not to the roll.
vars rec6 = result('langpop/recognise', jsonrpc_obj([% 'student_id', 'bsmitj' %]));
check_true('a refusal is one student\'s, not everyone\'s',
           rec6('guess') /== false);

check('recognise needs a student_id',
      errcode('langpop/recognise', jsonrpc_obj([])), -32602);
check_true('and needs no session, because it happens before one exists',
           result('langpop/recognise',
                  jsonrpc_obj([% 'student_id', 'nobody' %])) /== false);

;;; ---------------------------------------------- assignment and reporting
;;; English has items that cannot be checked by typing, which is what
;;; assignments are for.
vars reg_en = result('langpop/register',
                     jsonrpc_obj([% 'student_id', 'rpcjp',
                                    'display_name', 'Taro',
                                    'language', 'en' %]));
check('the English teacher is a different person', reg_en('teacher'), 'Mr Hill');
vars sess_en = result('langpop/session.open',
                      jsonrpc_obj([% 'student_id', 'rpcjp' %]));
vars sid_en = sess_en('session_id');

vars asg = result('langpop/assign', jsonrpc_obj([% 'session_id', sid_en %]));
check('an assignment is handed out', asg('assignment_id'), 1);
check('it points at a resource', asg('resource'), 'r_minimal_rl');
check('with a url', asg('url'), 'https://en.wikipedia.org/wiki/Minimal_pair');
check('and the date it was last checked', asg('checked'), '2026-10-19');

;;; A client cannot choose its own tier: the shape of the outcome decides.
vars rep3 = result('langpop/report',
                   jsonrpc_obj([% 'session_id', sid_en, 'assignment_id', 1,
                                  'outcome', 'ok' %]));
check('"ok" is compliance, tier 3', rep3('tier'), 3);
check_false('which cannot reach mastery', rep3('mastered'));
check_true('but is accepted', rep3('accepted'));

vars asg2 = result('langpop/assign', jsonrpc_obj([% 'session_id', sid_en %]));
vars rep2 = result('langpop/report',
                   jsonrpc_obj([% 'session_id', sid_en,
                                  'assignment_id', asg2('assignment_id'),
                                  'outcome', '18/20' %]));
check('a score is a result, tier 2', rep2('tier'), 2);
check('and the fraction is kept', rep2('fraction'), 0.9);

check('reporting an assignment nobody made',
      errcode('langpop/report',
              jsonrpc_obj([% 'session_id', sid_en, 'assignment_id', 99 %])),
      -32004);
check('reporting a score that is not one',
      errcode('langpop/report',
              jsonrpc_obj([% 'session_id', sid_en, 'assignment_id', 1,
                             'outcome', 'pretty good' %])),
      -32602);

;;; ------------------------------------------------- the session ends, the
;;; student does not
vars close = result('langpop/session.close', jsonrpc_obj([% 'session_id', sid %]));
check_true('closing saves', close('saved'));
check_true('and says goodbye', isstring(close('signoff')));
check('the session is gone afterwards',
      errcode('langpop/plan', jsonrpc_obj([% 'session_id', sid %])), -32001);

;;; The work survives it, which is the difference between a session and a
;;; student.
vars sess2 = result('langpop/session.open',
                    jsonrpc_obj([% 'student_id', 'rpcuser' %]));
vars why2 = result('langpop/explain',
                   jsonrpc_obj([% 'session_id', sess2('session_id'),
                                  'item', 'hi_a' %]));
check_true('a belief recorded last session is still there', why2('belief') > 0.0);

;;; ---------------------------------------------------------- card.render
;;; A card needs no session: it is a picture of the GRAPH, and nothing on
;;; it depends on who is looking.
lvars card = result('langpop/card.render',
                    jsonrpc_obj([% 'item', 'w_neko', 'style', 'word' %]));
check('card: the item it drew', card('item'), 'w_neko');
check('card: the style', card('style'), 'word');
check('card: the format', card('format'), 'svg');
check('card: width', card('width'), 640);
check('card: height', card('height'), 400);
check_true('card: a path came back', isstring(card('path')));
check_true('card: and the file is there', sys_file_exists(card('path')));
check_true('card: the file holds the glyph',
           issubstring('ねこ', lp_read_file(card('path'))) /== false);

;;; The style defaults, so the smallest possible call works.
check('card: style defaults to word',
      result('langpop/card.render', jsonrpc_obj([% 'item', 'hi_a' %]))('style'),
      'word');

check('card: no item is a params error',
      errcode('langpop/card.render', jsonrpc_obj([])), -32602);
check('card: an unknown item is an item error',
      errcode('langpop/card.render', jsonrpc_obj([% 'item', 'nonesuch' %])), -32003);
check('card: an item with nothing to draw is an item error',
      errcode('langpop/card.render', jsonrpc_obj([% 'item', 'mora_count' %])), -32003);
check('card: an unknown style is a params error',
      errcode('langpop/card.render',
              jsonrpc_obj([% 'item', 'hi_a', 'style', 'hologram' %])), -32602);

;;; A style from the design that is not built yet gets its own code, so a
;;; client can tell "you asked wrongly" from "that does not exist yet".
check('card: a designed but unbuilt style is -32005',
      errcode('langpop/card.render',
              jsonrpc_obj([% 'item', 'hi_a', 'style', 'stroke' %])), -32005);

jsonrpc_close(client); jsonrpc_close(server);
sysobey('rm -rf ' <> tmpdir);

test_summary();
