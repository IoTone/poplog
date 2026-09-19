/* examples/robotarmy/deploy.p -- Pop-11 source over the wire.

   The same idea as fthwire.p one level up: instead of a Forth word, a
   robot receives POP-11 SOURCE, signed, in as many chunks as it takes,
   and compiles it into itself with pop11_compile.  The new procedure is
   native machine code and is simply there from then on -- no restart, no
   reload, no dynamic-dispatch table.

       ;;; on the robot
       ./poplog basepop11 examples/robotarmy/deploy.p 9800

       ;;; from the command post: teach it a new order, then give it
       ./poplog basepop11 examples/robotarmy/deploy.p --file 127.0.0.1 9800 new_order.p
       ./poplog basepop11 examples/robotarmy/deploy.p --tell 127.0.0.1 9800 'escort(3) =>'

   This is the sharp end of the whole idea: a datagram arrives and the
   fleet's behaviour changes.  So nothing unverifiable is ever compiled,
   and the check lives in the transport rather than here.
*/
vars robotarmy_lib = true;
load 'examples/robotarmy/fleetnet.p';

;;; --------------------------------------------- capture, trap, and repair
;;; Same three mechanisms as fthwire.p, and for the same reasons: dlocal
;;; rebinds the output sink and restores it however the call exits; dlocal
;;; interrupt traps a mishap so a bad deployment cannot kill the robot; and
;;; the open stack is restored afterwards, because exitfrom unwinds the call
;;; chain but not the stack.

vars dp_ok = true;

define dp_trapped(src);
    dlocal interrupt =
        procedure();
            false -> dp_ok;
            exitfrom(dp_trapped);
        endprocedure;
    pop11_compile(stringin(src));
enddefine;

define dp_capture(p) -> out;
    lvars acc = [];
    dlocal cucharout = procedure(c); conspair(c, acc) -> acc endprocedure;
    p();
    consstring(#| applist(rev(acc), identfn) |#) -> out;
enddefine;

define dp_restack(base);
    until stacklength() == base do
        if stacklength() fi_> base then erase() else false endif;
    enduntil;
enddefine;

;;; Compile source into this robot; return whatever it printed.
define dp_obey(src) -> reply;
    lvars base = stacklength();
    true -> dp_ok;
    dp_capture(dp_trapped(% src %)) -> reply;
    dp_restack(base);
    unless dp_ok then 'ERROR compiling deployment' -> reply endunless;
    if reply = '' then 'compiled ok' -> reply endif;
enddefine;

;;; ----------------------------------------------------------------- robot

define deploy_robot(port, count);
    lvars s = net_open(port), n = 0, src, sender, reply;
    printf('robot listening on %p for signed Pop-11\n', [% port %]);
    sysflush(popdevout);
    repeat
        quitif(count and n >= count);
        net_collect(s) -> (src, sender);
        nextunless(src);                ;;; partial, or unverifiable
        n + 1 -> n;
        dp_obey(src) -> reply;
        printf('  <- %p bytes\n  -> %p\n', [% length(src), reply %]);
        sysflush(popdevout);
        net_send(s, hd(sender), hd(tl(sender)), net_sign(reply));
    endrepeat;
    sysclose(s);
enddefine;

;;; ------------------------------------------------------------ command post

define deploy_send(host, port, src) -> reply;
    lvars s = net_open(0), sender;
    net_send_big(s, host, port, src);
    net_recv_signed(s) -> (reply, sender);
    unless reply then '(no reply)' -> reply endunless;
    sysclose(s);
enddefine;

define deploy_main();
    lvars args = poparglist, mode, host, port, arg;
    returnif(args == []);
    hd(args) -> mode;
    if mode = '--tell' or mode = '--file' then
        hd(tl(args)) -> host;
        strnumber(hd(tl(tl(args)))) -> port;
        hd(tl(tl(tl(args)))) -> arg;
        if mode = '--file' then
            lvars dev = sysopen(arg, 0, "line"), rep = line_repeater(dev, inits(4096));
            lvars line, src = '';
            repeat
                rep() -> line;
                quitif(line == termin);
                src <> line <> '\n' -> src;
            endrepeat;
            src -> arg;
        endif;
        printf('%p\n', [% deploy_send(host, port, arg) %]);
    else
        deploy_robot(strnumber(mode), false);
    endif;
enddefine;

unless isdefined("deploy_lib") then deploy_main() endunless;
