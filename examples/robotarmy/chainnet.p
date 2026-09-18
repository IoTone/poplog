/* examples/robotarmy/chainnet.p -- the chain of command, spread over machines.

   chain.pl holds the whole org chart on one machine.  A real fleet does
   not: each squad knows who it commands, and nobody holds the whole
   picture.  This splits the same relation across nodes and lets Prolog's
   own backtracking cross the network to rebuild it.

   The trick is that a Pop-11 procedure can BE a Prolog predicate.
   remote_commands/2 below is written in Pop-11, does a UDP round trip,
   and offers each answer it gets back as a separate Prolog solution --
   so `can_order(commander, r4)` backtracks through machines without the
   Prolog above it knowing that a network exists.

       ;;; on each squad machine, serving its own slice of the chart
       ./poplog basepop11 examples/robotarmy/chainnet.p \
           --serve 9820 examples/robotarmy/chain-sq1.pl

       ;;; on the command post, which knows only its own two facts
       ./poplog basepop11 examples/robotarmy/chainnet.p \
           --ask examples/robotarmy/chain-post.pl 10.0.0.5:9820,10.0.0.6:9821 \
           'can_order(commander, r4)'

   Every query and every answer is signed with the fleet key, so a node
   cannot be fed a chain of command it did not agree to.
*/
vars robotarmy_lib = true;
load 'examples/robotarmy/fleetnet.p';
uses strutils;
uses prolog;
uses define_prolog;

vars chain_peers = [];          ;;; list of 'host:port' strings
lconstant CHAIN_WAIT = 60;      ;;; centiseconds to wait for replies

;;; ------------------------------------------------- this node's own facts
;;; Read straight out of the Prolog database rather than a Pop-11 copy of
;;; it: Prolog owns the chart, Pop-11 only serves it.  prolog_clause walks
;;; the clauses of local_commands/2 and returns [] when they run out.

define chain_local(key) -> pairs;
    lvars i = 1, cl, sup, sub;
    [] -> pairs;
    repeat
        prolog_clause(i, "local_commands", 2) -> cl;
        quitif(cl == []);
        prolog_arg(1, cl) -> sup;
        prolog_arg(2, cl) -> sub;
        if key = '*' or (sup sys_>< '') = key then
            conspair([^sup ^sub], pairs) -> pairs;
        endif;
        i + 1 -> i;
    endrepeat;
    rev(pairs) -> pairs;
enddefine;

;;; ------------------------------------------------------- the wire format
;;; query:  'q <superior>'   ('q *' for every fact this node holds)
;;; answer: 'a sup>sub sup>sub ...'  (just 'a' when the node knows nothing)

define chain_pack(pairs) -> text;
    lvars p;
    'a' -> text;
    for p in pairs do
        text <> ' ' <> (hd(p) sys_>< '') <> '>' <> (hd(tl(p)) sys_>< '') -> text;
    endfor;
enddefine;

define chain_unpack(text) -> pairs;
    lvars w, c;
    [] -> pairs;
    for w in str_split(text, ` `) do
        nextif(w = 'a' or w = '');
        locchar(`>`, 1, w) -> c;
        nextunless(c);
        conspair([% consword(substring(1, c - 1, w)),
                    consword(allbutfirst(c, w)) %], pairs) -> pairs;
    endfor;
    rev(pairs) -> pairs;
enddefine;

;;; ------------------------------------------------------------- serving
;;; A server answers from its LOCAL facts only and never recurses into
;;; can_order.  That is what stops two nodes asking each other the same
;;; question forever: the recursion lives entirely in the asking node's
;;; Prolog, and each network hop is a single flat lookup.

define chain_serve(port);
    lvars s = net_open(port), text, sender, key, reply;
    printf('chain node on %p, holding %p local facts\n',
           [% port, length(chain_local('*')) %]);
    sysflush(popdevout);
    repeat
        net_recv_signed(s) -> (text, sender);
        nextunless(text);
        nextunless(length(text) > 2 and substring(1, 2, text) = 'q ');
        allbutfirst(2, text) -> key;
        chain_pack(chain_local(key)) -> reply;
        printf('  ?- commands(%p, _)  ->  %p\n', [% key, reply %]);
        sysflush(popdevout);
        net_send(s, hd(sender), hd(tl(sender)), net_sign(reply));
    endrepeat;
enddefine;

;;; ------------------------------------------------------------- asking
;;; Ask every peer at once and gather whatever comes back before the
;;; deadline.  A node that is down simply contributes no solutions, which
;;; is the right failure mode for a relation: the chart is smaller, not
;;; wrong.

define chain_ask(key) -> pairs;
    lvars s = net_open(0), peer, c, text, sender, waited = 0, got = 0;
    [] -> pairs;
    for peer in chain_peers do
        locchar(`:`, 1, peer) -> c;
        nextunless(c);
        net_send(s, substring(1, c - 1, peer),
                 strnumber(allbutfirst(c, peer)), net_sign('q ' <> key));
    endfor;
    until got >= length(chain_peers) or waited >= CHAIN_WAIT do
        if net_ready(s) then
            net_recv_signed(s) -> (text, sender);
            if text then
                got + 1 -> got;
                pairs <> chain_unpack(text) -> pairs;
            endif;
        else
            syssleep(2);
            waited + 2 -> waited;
        endif;
    enduntil;
    sysclose(s);
enddefine;

;;; --------------------------------------------- Pop-11 AS a Prolog predicate
;;; The continuation-passing shape is what makes this a real predicate and
;;; not a function call: prolog_unifyc establishes a choice point, binds,
;;; and calls the continuation.  Calling it once per answer is exactly what
;;; makes remote_commands/2 nondeterministic -- Prolog backtracks into the
;;; next machine's answer the same way it would into the next clause.

define :prolog remote_commands/2(x, y, contn);
    lvars x, y, contn, xd, key, p;
    prolog_deref(x) -> xd;
    if isprologvar(xd) then '*' else xd sys_>< '' endif -> key;
    for p in chain_ask(key) do
        prolog_unifyc(x, hd(p),
            procedure;
                prolog_unifyc(y, hd(tl(p)), contn);
            endprocedure);
    endfor;
enddefine;

;;; ----------------------------------------------------------------- driver

define chain_main();
    lvars args = poparglist, mode;
    returnif(args == []);
    hd(args) -> mode;
    if mode = '--serve' then
        prolog_compile(discin(hd(tl(tl(args)))));
        chain_serve(strnumber(hd(tl(args))));
    elseif mode = '--ask' then
        prolog_compile(discin(hd(tl(args))));
        prolog_compile(discin('examples/robotarmy/chain-rules.pl'));
        unless hd(tl(tl(args))) = '-' then
            str_split(hd(tl(tl(args))), `,`) -> chain_peers
        endunless;
        prolog_compile(stringin(':- ' <> hd(tl(tl(tl(args)))) <> '.'));
    endif;
enddefine;

chain_main();
