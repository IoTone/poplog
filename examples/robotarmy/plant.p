/* examples/robotarmy/plant.p -- VM specs over the wire.

   fthwire.p and deploy.p both ship SOURCE and let the robot's compiler
   front-end read it.  This ships neither Forth nor Pop-11: it ships an
   abstract instruction spec, and the robot plants VM code from it directly
   with sysPROCEDURE / sysPUSHQ / sysCALL.  No reader, no parser of any
   language -- and the identical datagram becomes arm64 on one machine and
   x86-64 on another, because the back-end below the VM is what differs.

   This is what Chapter 6 is about, done between machines.

   Wire format, deliberately trivial to parse -- one instruction per line:

       plant
       name double
       nargs 1
       pushq 2
       call fi_*

   and to invoke what was planted:

       call double 21

       ;;; on the robot
       ./poplog basepop11 examples/robotarmy/plant.p 9900
*/
vars robotarmy_lib = true;
load 'examples/robotarmy/fleetnet.p';
uses strutils;

vars planted = newproperty([], 32, false, true);

;;; A bare word if it is not a number -- the wire carries no types.
define pl_operand(s) -> v;
    if strnumber(s) then strnumber(s) -> v else consword(s) -> v endif
enddefine;

;;; TRAP: planting must happen while something is RUNNING.  At the top level
;;; of a file being compiled it mishaps with
;;;     sysEXECUTE: NOT AT EXECUTE LEVEL
;;; which is why this is a procedure and not inline.
define pl_plant(nargs, instrs) -> p;
    lvars ins, op, arg;
    sysPROCEDURE(false, nargs);
    for ins in instrs do
        hd(ins) -> op; hd(tl(ins)) -> arg;
        if      op == "pushq" then sysPUSHQ(arg)
        elseif  op == "push"  then sysPUSH(arg)
        elseif  op == "pop"   then sysPOP(arg)
        elseif  op == "call"  then sysCALL(arg)
        else    mishap(op, 1, 'plant: unknown opcode')
        endif;
    endfor;
    sysENDPROCEDURE() -> p;
enddefine;

;;; Parse a spec and plant it; returns a one-line report.
define pl_obey(text) -> reply;
    lvars lines = str_lines(text), l, verb, rest, sp;
    lvars name = false, nargs = 0, instrs = [], op, arg, p;
    returnif(lines == [])('empty spec' -> reply);
    hd(lines) -> verb;
    if verb = 'plant' then
        for l in tl(lines) do
            nextif(l = '');
            locchar(` `, 1, l) -> sp;
            if sp then substring(1, sp - 1, l) -> op; allbutfirst(sp, l) -> arg
            else l -> op; '' -> arg endif;
            if      op = 'name'  then arg -> name
            elseif  op = 'nargs' then strnumber(arg) -> nargs
            else    instrs <> [[^(consword(op)) ^(pl_operand(arg))]] -> instrs
            endif;
        endfor;
        returnunless(name)('spec has no name' -> reply);
        pl_plant(nargs, instrs) -> p;
        p -> planted(consword(name));
        'planted ' <> name <> '/' <> (nargs sys_>< '')
            <> ' as native code, ' <> (length(instrs) sys_>< '') <> ' instructions'
            -> reply;
    elseif verb = 'call' or str_starts('call ', verb) then
        ;;; "call <name> <arg>..."
        lvars toks = str_split(verb, ` `), nm, a, args = [];
        hd(tl(toks)) -> nm;
        for a in tl(tl(toks)) do args <> [^(pl_operand(a))] -> args endfor;
        planted(consword(nm)) -> p;
        returnunless(p)('no such planted procedure: ' <> nm -> reply);
        ;;; Apply FIRST, then format.  Writing `'' sys_>< fast_apply(p)`
        ;;; pushes the empty string ON TOP of the argument applist just
        ;;; pushed, so the planted procedure consumes '' instead of 21 --
        ;;; and fi_* does not type-check, so the answer is quiet nonsense
        ;;; (210.0) rather than a mishap.
        lvars res;
        applist(args, identfn);
        fast_apply(p) -> res;
        '' sys_>< res -> reply;
    else
        'unknown verb: ' <> verb -> reply;
    endif;
enddefine;

;;; ----------------------------------------------------------------- robot

vars pl_ok = true;

define pl_trapped(text) -> r;
    dlocal interrupt =
        procedure(); false -> pl_ok; exitfrom(pl_trapped) endprocedure;
    pl_obey(text) -> r;
enddefine;

define pl_restack(base);
    until stacklength() == base do
        if stacklength() fi_> base then erase() else false endif;
    enduntil;
enddefine;

define plant_robot(port, count);
    lvars s = net_open(port), n = 0, text, sender, reply, base;
    printf('robot listening on %p for signed VM specs (%p)\n',
           [% port, sys_machine_type %]);
    sysflush(popdevout);
    repeat
        quitif(count and n >= count);
        net_collect(s) -> (text, sender);
        nextunless(text);
        n + 1 -> n;
        stacklength() -> base;
        true -> pl_ok;
        pl_trapped(text) -> reply;
        pl_restack(base);
        unless pl_ok then 'ERROR planting' -> reply endunless;
        printf('  <- %p\n  -> %p\n', [% hd(str_lines(text)), reply %]);
        sysflush(popdevout);
        net_send(s, hd(sender), hd(tl(sender)), net_sign(reply));
    endrepeat;
    sysclose(s);
enddefine;

define plant_send(host, port, spec) -> reply;
    lvars s = net_open(0), sender;
    net_send_big(s, host, port, spec);
    net_recv_signed(s) -> (reply, sender);
    unless reply then '(no reply)' -> reply endunless;
    sysclose(s);
enddefine;

define plant_main();
    lvars args = poparglist;
    returnif(args == []);
    if hd(args) = '--tell' then
        printf('%p\n', [% plant_send(hd(tl(args)), strnumber(hd(tl(tl(args)))),
                                     hd(tl(tl(tl(args))))) %]);
    else
        plant_robot(strnumber(hd(args)), false);
    endif;
enddefine;

unless isdefined("plant_lib") then plant_main() endunless;
