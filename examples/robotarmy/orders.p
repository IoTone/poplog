/* examples/robotarmy/orders.p -- the fleet takes orders over the network.

   Chapter 4 built an order interpreter: `obey` matches a list of words
   against patterns and moves robots around a registry.  Chapter 8 built a
   signed UDP transport.  This is the join: the SAME `obey`, the same
   `fleet` registry, now driven from another machine.

   Nothing in fleet.p changed to make this work.  The order interpreter
   never learns that a network exists -- it still takes a list of words and
   returns a string.  All orders.p adds is the two lines that turn a
   datagram into that list and the reply back into a datagram.

       ;;; the robot, holding the fleet
       ./poplog basepop11 examples/robotarmy/orders.p 9750

       ;;; the command post
       ./poplog basepop11 examples/robotarmy/orders.p --order 127.0.0.1 9750 'report'
       ./poplog basepop11 examples/robotarmy/orders.p --order 127.0.0.1 9750 \
           'unit r1 advance to ridge'
*/
vars robotarmy_lib = true;              ;;; suppress fleet.p's own demo
load 'examples/robotarmy/fleet.p';
load 'examples/robotarmy/fleetnet.p';
uses strutils;

;;; An order arrives as text; `obey` wants a list of words and numbers.
;;; This is the whole adaptation layer.
define words_of(s) -> l;
    lvars w;
    [% for w in str_split(str_trim(s), ` `) do
           if w /= '' then
               if strnumber(w) then strnumber(w) else consword(w) endif
           endif
       endfor %] -> l;
enddefine;

;;; ----------------------------------------------------------------- robot

vars ord_ok = true;

define ord_trapped(order) -> r;
    dlocal interrupt =
        procedure(); false -> ord_ok; exitfrom(ord_trapped) endprocedure;
    obey(order) -> r;
enddefine;

define ord_restack(base);
    until stacklength() == base do
        if stacklength() fi_> base then erase() else false endif;
    enduntil;
enddefine;

define orders_robot(port, count);
    lvars s = net_open(port), n = 0, text, sender, reply, base;
    ;;; a small fleet to command
    enlist("r1", "scout")  -> _;
    enlist("r2", "sapper") -> _;
    enlist("r3", "medic")  -> _;
    enlist("r4", "scout")  -> _;
    20 -> rb_charge(fleet("r4"));
    printf('fleet post on %p: %p units enlisted\n', [% port, length(muster()) %]);
    sysflush(popdevout);
    repeat
        quitif(count and n >= count);
        net_recv_signed(s) -> (text, sender);
        if text then
            n + 1 -> n;
            stacklength() -> base;
            true -> ord_ok;
            ord_trapped(words_of(text)) -> reply;
            ord_restack(base);
            unless ord_ok then 'ERROR obeying' -> reply endunless;
            printf('  <- %p\n  -> %p\n', [% text, reply %]);
        else
            'REFUSED: bad signature' -> reply;
            printf('  <- (unverifiable order, not obeyed)\n', []);
        endif;
        sysflush(popdevout);
        net_send(s, hd(sender), hd(tl(sender)), net_sign(reply));
    endrepeat;
    sysclose(s);
enddefine;

;;; ------------------------------------------------------------ command post

define send_order(host, port, order) -> reply;
    lvars s = net_open(0), sender;
    net_send(s, host, port, net_sign(order));
    net_recv_signed(s) -> (reply, sender);
    unless reply then '(no reply)' -> reply endunless;
    sysclose(s);
enddefine;

define orders_main();
    lvars args = poparglist;
    returnif(args == []);
    if hd(args) = '--order' then
        printf('%p\n', [% send_order(hd(tl(args)), strnumber(hd(tl(tl(args)))),
                                     hd(tl(tl(tl(args))))) %]);
    else
        orders_robot(strnumber(hd(args)), false);
    endif;
enddefine;

unless isdefined("orders_lib") then orders_main() endunless;
