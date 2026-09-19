/* examples/robotarmy/fthwire.p -- Forth words over the wire.

   A robot listens on UDP.  What arrives is Forth source, signed with the
   fleet key; the robot verifies it, COMPILES it -- Poplog Forth transpiles
   a colon definition to Pop-11 and runs it through the incremental
   compiler, so the new word is native machine code -- runs it, and sends
   back whatever it printed.

   A robot that has never heard of `patrol` can be taught it in one
   datagram of about sixty bytes, and be executing it natively a
   millisecond later.

       ;;; on the robot
       ./poplog basepop11 examples/robotarmy/fthwire.p 9600

       ;;; from the command post
       ./poplog basepop11 examples/robotarmy/fthwire.p --tell 127.0.0.1 9600 \
           ': patrol 0 do low? if leave then step loop ;'

   Everything is signed: an unverifiable datagram is never compiled.
*/
uses forth;

vars robotarmy_lib = true;              ;;; fleetnet must not auto-run
load 'examples/robotarmy/fleetnet.p';

;;; ------------------------------------------------------------- capturing
;;; Forth prints through cucharout, so rebinding it for the dynamic extent
;;; of the call collects the output -- and dlocal restores it however the
;;; call exits, including when the word below blows up.

define fw_capture(p) -> out;
    lvars acc = [];
    dlocal cucharout = procedure(c); conspair(c, acc) -> acc endprocedure;
    p();
    consstring(#| applist(rev(acc), identfn) |#) -> out;
enddefine;

;;; --------------------------------------------------------------- trapping
;;; A word that mishaps must not take the robot down with it.  The idiom is
;;; lib jsonrpc's: dlocal the interrupt, exitfrom the trapping procedure.

vars fw_ok = true;

define fw_trapped(src);
    dlocal interrupt =
        procedure();
            false -> fw_ok;
            exitfrom(fw_trapped);
        endprocedure;
    forth_run(src);
enddefine;

;;; exitfrom unwinds the call chain but NOT the open stack -- and Forth's
;;; data stack IS that stack, so a word that died holding values would
;;; poison the next order.  Restore the depth we started at.
define fw_restack(base);
    until stacklength() == base do
        if stacklength() fi_> base then erase() else false endif;
    enduntil;
enddefine;

;;; Run Forth source, returning what it printed (or the error).
define fw_obey(src) -> reply;
    lvars base = stacklength();
    true -> fw_ok;
    fw_capture(fw_trapped(% src %)) -> reply;
    fw_restack(base);
    unless fw_ok then 'ERROR executing: ' <> src -> reply endunless;
    if reply = '' then 'ok' -> reply endif;
enddefine;

;;; ----------------------------------------------------------------- robot

define forth_robot(port, count);
    lvars s = net_open(port), n = 0, src, sender, reply;
    printf('robot listening on %p, fleet-signed Forth only\n', [% port %]);
    sysflush(popdevout);
    repeat
        quitif(count and n >= count);
        net_recv_signed(s) -> (src, sender);
        n + 1 -> n;
        if src then
            fw_obey(src) -> reply;
            printf('  <- %p\n  -> %p\n', [% src, reply %]);
        else
            'REFUSED: bad signature' -> reply;
            printf('  <- (unverifiable datagram, not compiled)\n', []);
        endif;
        sysflush(popdevout);
        net_send(s, hd(sender), hd(tl(sender)), net_sign(reply));
    endrepeat;
    sysclose(s);
enddefine;

;;; ------------------------------------------------------------ command post

define fleet_tell(host, port, src) -> reply;
    lvars s = net_open(0), sender;      ;;; port 0 = any free port
    net_send(s, host, port, net_sign(src));
    net_recv_signed(s) -> (reply, sender);
    unless reply then 'no/!bad reply' -> reply endunless;
    sysclose(s);
enddefine;

;;; -------------------------------------------------------------------- main

define fthwire_main();
    lvars args = poparglist;
    if args /== [] and hd(args) = '--tell' then
        lvars host = hd(tl(args)), port = strnumber(hd(tl(tl(args))));
        lvars src = hd(tl(tl(tl(args))));
        printf('%p\n', [% fleet_tell(host, port, src) %]);
    elseif args /== [] then
        forth_robot(strnumber(hd(args)), false);
    else
        printf('usage: fthwire.p <port> | --tell <host> <port> <forth>\n', []);
    endif;
enddefine;

unless isdefined("fthwire_lib") then fthwire_main() endunless;
