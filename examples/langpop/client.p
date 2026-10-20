/* examples/langpop/client.p -- the TUI, demoted to a client.

   Same session as Proposal A, same teacher, same questions -- but this
   program holds no graph, no beliefs and no judgment.  It asks the server
   what to show and sends back what the student typed.  Everything it can
   do, an application in any language can do, which is the only honest
   test of an API: the reference client has no private door.

       ./poplog basepop11 examples/langpop/server.p --port 7801 &
       ./poplog basepop11 examples/langpop/client.p --port 7801 --user bob

   Note what is NOT here: no answer key, no scoring, no belief arithmetic.
   The client cannot tell whether an answer was right until the server
   says so, and cannot time the student either -- langpop/next starts the
   clock on the server, which is what keeps the speed half of a level's
   exit criteria worth anything.
*/

uses jsonrpc;

vars
    lp_conn = false,
    lp_rpc_seq = 0,
    lp_sid = false,
    lp_teacher = 'the teacher',
;

;;; One call, one reply.  LIB * JSONRPC does not correlate requests for a
;;; client (HELP * JSONRPC, "Limits"), which is fine here: this client is
;;; a person typing, so there is never more than one request in flight.
define rpc(method, params) -> result;
    lvars method, params, reply, err;
    lp_rpc_seq + 1 -> lp_rpc_seq;
    jsonrpc_write(lp_conn,
        jsonrpc_obj([% 'jsonrpc', '2.0', 'id', lp_rpc_seq,
                       'method', method, 'params', params %]));
    jsonrpc_read(lp_conn) -> reply;
    if reply == termin or reply == false then
        printf('\n(the tutor stopped answering)\n');
        sysexit();
    endif;
    reply('error') -> err;
    if err then
        printf('  ! %p (%p)\n', [% err('message'), err('code') %]);
        false -> result;
    else
        reply('result') -> result;
    endif;
enddefine;

define p(o, key) -> v;
    lvars o, key, v = false;
    if o and (isproperty(o) or isjson_object(o)) then o(key) -> v endif;
    if v == json_null then false -> v endif;
enddefine;

;;; ------------------------------------------------------------- the TUI
define readline() -> line;
    lvars c, n = 0;
    repeat
        charin() -> c;
        if c == termin then
            if n == 0 then termin -> line; return endif;
            quitloop;
        endif;
        quitif(c == `\n`);
        c; n + 1 -> n;
    endrepeat;
    consstring(n) -> line;
enddefine;

define trim(s) -> t;
    lvars s, i = 1, j;
    if s == termin then '' -> t; return endif;
    length(s) -> j;
    while i <= j and s(i) == ` ` do i + 1 -> i endwhile;
    while j >= i and s(j) == ` ` do j - 1 -> j endwhile;
    if j < i then '' else substring(i, j - i + 1, s) endif -> t;
enddefine;

define split2(s) -> (a, b);
    lvars s, c = locchar(` `, 1, s);
    if c then (substring(1, c - 1, s), trim(allbutfirst(c, s))) -> (a, b)
    else (s, '') -> (a, b)
    endif;
enddefine;

define help();
    printf('\n  <enter>          the next thing to learn\n');
    printf('  :plan            what is ready now\n');
    printf('  :why <item>      the derivation, from the graph\n');
    printf('  :status          the exit criteria of this level, measured\n');
    printf('  :assign          something to do away from the keyboard\n');
    printf('  :report <n> ok | 17/20\n');
    printf('  :quit            close the session and stop\n');
enddefine;

;;; Ask, show, read, send.  The client never decides anything about the
;;; answer -- it does not even know what the answer was until it is told.
define ask_one();
    lvars q = rpc('langpop/next', jsonrpc_obj([% 'session_id', lp_sid %])),
          item, shape, opts, i = 0, o, line, ans;
    returnunless(q);
    p(q, 'item') -> item;
    unless item then
        printf('  %p\n', [% p(q, 'note') or 'nothing ready' %]);
        return;
    endunless;
    p(q, 'shape') -> shape;
    p(q, 'options') -> opts;
    if shape = 'pick' then
        printf('\n  %p\n', [% p(q, 'prompt') %]);
        for o in_vector (opts or {}) do
            i + 1 -> i; printf('    %p) %p\n', [% i, o %]);
        endfor;
        printf('  -> ');
    else
        printf('\n  %p    -> ', [% p(q, 'prompt') %]);
    endif;
    sysflush(popdevout);
    readline() -> line;
    returnif(line == termin);
    rpc('langpop/answer',
        jsonrpc_obj([% 'session_id', lp_sid, 'item', item,
                       'answer', trim(line) %])) -> ans;
    returnunless(ans);
    if p(ans, 'correct') then
        printf('  %p\n', [% p(ans, 'reply') %]);
    elseif p(ans, 'mistook_form') then
        printf('  %p  That is %p -- the two are confused constantly.\n',
               [% p(ans, 'reply'), p(ans, 'mistook_form') %]);
    else
        printf('  %p  It is %p.\n', [% p(ans, 'reply'), p(ans, 'expected') %]);
    endif;
enddefine;

define show_plan();
    lvars pl = rpc('langpop/plan', jsonrpc_obj([% 'session_id', lp_sid %])), it;
    returnunless(pl);
    printf('\n');
    for it in_vector (p(pl, 'items') or {}) do
        printf('  %p  %p  (belief %p)\n',
               [% p(it, 'form'), p(it, 'kind'), p(it, 'belief') %]);
    endfor;
    printf('  ... %p ready in all\n', [% p(pl, 'ready_count') %]);
enddefine;

define show_why(item);
    lvars item, w = rpc('langpop/explain',
                        jsonrpc_obj([% 'session_id', lp_sid, 'item', item %])),
          pre;
    returnunless(w);
    printf('\n  %p  (%p, %p, %p)\n',
           [% p(w, 'form'), p(w, 'kind'), p(w, 'level'), p(w, 'source') %]);
    if p(w, 'gloss') then printf('    %p\n', [% p(w, 'gloss') %]) endif;
    for pre in_vector (p(w, 'prerequisites') or {}) do
        printf('    %p %p\n',
               [% if p(pre, 'known') then 'known  ' else 'missing' endif,
                  p(pre, 'item') %]);
    endfor;
    printf('    belief %p on channel %p (mastery is %p)\n',
           [% p(w, 'belief'), p(w, 'channel'), p(w, 'mastery_threshold') %]);
enddefine;

define show_status();
    lvars st = rpc('langpop/status', jsonrpc_obj([% 'session_id', lp_sid %])), c;
    returnunless(st);
    printf('\n  %p, %p -- level %p\n',
           [% p(st, 'display_name'), p(st, 'language'), p(st, 'level') %]);
    for c in_vector (p(st, 'criteria') or {}) do
        if p(c, 'kind') = 'measured' then
            printf('    %p: %p%% right, %p%% within %pms, over %p answers (need %p)\n',
                   [% p(c, 'criterion'), round(p(c, 'accuracy') * 100),
                      round(p(c, 'within_latency') * 100), p(c, 'latency_ms'),
                      p(c, 'answers'), round(p(c, 'threshold') * 100) %]);
        elseif p(c, 'kind') = 'count' then
            printf('    %p: %p of %p\n',
                   [% p(c, 'criterion'), p(c, 'have'), p(c, 'want') %]);
        else
            printf('    %p: %p\n', [% p(c, 'criterion'), p(c, 'note') %]);
        endif;
    endfor;
    printf('    %p items ready to teach now\n', [% p(st, 'ready_count') %]);
enddefine;

define do_assign();
    lvars a = rpc('langpop/assign', jsonrpc_obj([% 'session_id', lp_sid %]));
    returnunless(a);
    unless p(a, 'assignment_id') then
        printf('  %p\n', [% p(a, 'note') %]); return;
    endunless;
    printf('\n  Assignment %p: %p\n', [% p(a, 'assignment_id'), p(a, 'form') %]);
    if p(a, 'gloss') then printf('    %p\n', [% p(a, 'gloss') %]) endif;
    printf('    %p   (%p, checked %p)\n',
           [% p(a, 'url'), p(a, 'resource_kind'), p(a, 'checked') %]);
    printf('  %p\n', [% p(a, 'say') %]);
enddefine;

define do_report(arg);
    lvars arg, id, outcome, r;
    split2(arg) -> (id, outcome);
    strnumber(id) -> id;
    unless id then printf('  :report <number> ok|17/20\n'); return endunless;
    rpc('langpop/report',
        jsonrpc_obj([% 'session_id', lp_sid, 'assignment_id', id,
                       'outcome', if outcome = '' then 'ok' else outcome endif %]))
        -> r;
    returnunless(r);
    printf('  Recorded as tier %p evidence.  %p\n', [% p(r, 'tier'), p(r, 'note') %]);
enddefine;

;;; --------------------------------------------------------------- main
define client_main();
    lvars args = poparglist, a, host = 'localhost', port = 7801,
          user = false, name = false, lang = 'ja', reg, sess, line, cmd, arg;
    until args == [] do
        hd(args) -> a;
        if a = '--port' then strnumber(hd(tl(args))) -> port; tl(tl(args)) -> args;
        elseif a = '--host' then hd(tl(args)) -> host; tl(tl(args)) -> args;
        elseif a = '--user' then hd(tl(args)) -> user; tl(tl(args)) -> args;
        elseif a = '--name' then hd(tl(args)) -> name; tl(tl(args)) -> args;
        elseif a = '--lang' then hd(tl(args)) -> lang; tl(tl(args)) -> args;
        else tl(args) -> args;
        endif;
    enduntil;

    jsonrpc_connect_wait(host, port, "line", 5) -> lp_conn;
    unless lp_conn then
        printf('langpop: no tutor at %p:%p -- start server.p first\n',
               [% host, port %]);
        return;
    endunless;

    unless user then
        printf('Username?  '); sysflush(popdevout);
        readline() -> line;
        returnif(line == termin);
        trim(line) -> user;
    endunless;

    rpc('langpop/register',
        jsonrpc_obj([% 'student_id', user,
                       'display_name', name or user,
                       'language', lang %])) -> reg;
    returnunless(reg);
    p(reg, 'teacher') -> lp_teacher;

    rpc('langpop/session.open', jsonrpc_obj([% 'student_id', user %])) -> sess;
    returnunless(sess);
    p(sess, 'session_id') -> lp_sid;
    printf('%p\n', [% p(sess, 'greeting') %]);
    printf('%p -- %p, level %p, %p ready.\n',
           [% p(sess, 'display_name'), p(sess, 'language'),
              p(sess, 'level'), p(sess, 'ready_count') %]);
    help();

    repeat
        printf('\n%p> ', [^lp_teacher]);
        sysflush(popdevout);
        readline() -> line;
        quitif(line == termin);
        trim(line) -> line;
        if line = '' then
            ask_one();
        elseif line(1) == `:` then
            split2(allbutfirst(1, line)) -> (cmd, arg);
            if cmd = 'quit' or cmd = 'q' then quitloop
            elseif cmd = 'help' or cmd = '?' then help()
            elseif cmd = 'plan' then show_plan()
            elseif cmd = 'why' then
                if arg = '' then printf('  :why <item id>\n') else show_why(arg) endif
            elseif cmd = 'status' then show_status()
            elseif cmd = 'assign' then do_assign()
            elseif cmd = 'report' then do_report(arg)
            else printf('  I do not know ":%p".  Try :help\n', [^cmd])
            endif;
        else
            printf('  Press enter for the next question, or :help.\n');
        endif;
    endrepeat;

    lvars bye = rpc('langpop/session.close',
                    jsonrpc_obj([% 'session_id', lp_sid %]));
    if bye then printf('\n%p\n', [% p(bye, 'signoff') %]) endif;
    jsonrpc_close(lp_conn);
enddefine;

unless isdefined("langpop_client_lib") then client_main() endunless;
