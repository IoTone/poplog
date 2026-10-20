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
    jsonrpc_write(client, lp_obj([% 'jsonrpc', '2.0', 'id', rpc_id,
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
           length(result('langpop/methods', false)) == 11);
check_true('and the list names them, not just counts them',
           member('langpop/card.render',
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
                      lp_obj([% 'session_id', sid, 'item', 'hi_a',
                                'answer', 'zz' %]));
check_true('"correct":false is on the wire',
           issubstring('"correct":false', raw_wrong) and true);
check_true('"mastered":false too',
           issubstring('"mastered":false', raw_wrong) and true);
lvars raw_why = raw('langpop/explain',
                    lp_obj([% 'session_id', sid, 'item', 'hi_ka' %]));
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
check('with every exit criterion', length(st('criteria')), 6);
check('a measured one carries its latency budget',
      st('criteria')(1)('latency_ms'), 2000);
check('and the vocabulary one is a count', st('criteria')(6)('kind'), 'count');

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
                    lp_obj([% 'item', 'w_neko', 'style', 'word' %]));
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
      result('langpop/card.render', lp_obj([% 'item', 'hi_a' %]))('style'),
      'word');

check('card: no item is a params error',
      errcode('langpop/card.render', lp_obj([])), -32602);
check('card: an unknown item is an item error',
      errcode('langpop/card.render', lp_obj([% 'item', 'nonesuch' %])), -32003);
check('card: an item with nothing to draw is an item error',
      errcode('langpop/card.render', lp_obj([% 'item', 'mora_count' %])), -32003);
check('card: an unknown style is a params error',
      errcode('langpop/card.render',
              lp_obj([% 'item', 'hi_a', 'style', 'hologram' %])), -32602);

;;; A style from the design that is not built yet gets its own code, so a
;;; client can tell "you asked wrongly" from "that does not exist yet".
check('card: a designed but unbuilt style is -32005',
      errcode('langpop/card.render',
              lp_obj([% 'item', 'hi_a', 'style', 'stroke' %])), -32005);

jsonrpc_close(client); jsonrpc_close(server);
sysobey('rm -rf ' <> tmpdir);

test_summary();
