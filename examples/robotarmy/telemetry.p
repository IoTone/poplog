/* examples/robotarmy/telemetry.p -- one pass over a fleet telemetry log.

   Counts levels, ranks the units by how much trouble they report, and
   finds the slowest operation.  Demonstrates: line_repeater, a property
   with a default, and Poplog's regexp syntax (the escape character is
   @, not backslash).

       ./poplog basepop11 examples/robotarmy/telemetry.p </dev/null
*/
uses regexp;

;;; Poplog regexp: @[0-9@] is a digit class, @{1,@} is "one or more".
;;; A PCRE pattern pasted in here would compile and then match nothing.
vars err, match_ms;
regexp_compile('@[0-9@]@{1,@} ms') -> (err, match_ms);
if err then mishap(err, 0, 'telemetry: bad pattern') endif;

vars err2, match_unit;
regexp_compile('r@[0-9@]@{1,@}') -> (err2, match_unit);
if err2 then mishap(err2, 0, 'telemetry: bad pattern') endif;

define triage(path) -> (levels, trouble, slowest, slow_unit);
    lvars dev, rep, line, lev, i, n, ms, unit;
    newproperty([], 8,  0, true) -> levels;    ;;; default 0: += needs no branch
    newproperty([], 32, 0, true) -> trouble;
    0 -> slowest;  false -> slow_unit;
    sysopen(path, 0, "line") -> dev;
    line_repeater(dev, inits(4096)) -> rep;    ;;; size the buffer generously
    repeat
        rep() -> line;
        quitif(line == termin);

        match_unit(1, line, false, false) -> (i, n);
        if i then consword(substring(i, n, line)) -> unit else false -> unit endif;

        for lev in [INFO WARN ERROR] do
            if issubstring(lev sys_>< '', 1, line) then
                levels(lev) + 1 -> levels(lev);
                if unit and lev /== "INFO" then
                    trouble(unit) + 1 -> trouble(unit)
                endif
            endif
        endfor;

        match_ms(1, line, false, false) -> (i, n);
        if i then
            strnumber(substring(i, n - 3, line)) -> ms;
            if ms and ms > slowest then ms -> slowest; unit -> slow_unit endif
        endif;
    endrepeat;
enddefine;

define report(path);
    lvars levels, trouble, slowest, slow_unit, lev, worst = [];
    triage(path) -> (levels, trouble, slowest, slow_unit);
    for lev in [INFO WARN ERROR] do
        npr(lev sys_>< ': ' sys_>< levels(lev))
    endfor;
    appproperty(trouble,
        procedure(u, c); conspair(conspair(c, u), worst) -> worst endprocedure);
    syssort(worst, false,
        procedure(a, b); front(a) > front(b) endprocedure) -> worst;
    npr('');
    npr('units by fault count:');
    applist(worst,
        procedure(p); npr('  ' sys_>< back(p) sys_>< '  ' sys_>< front(p)) endprocedure);
    npr('');
    npr('slowest operation: ' sys_>< slowest sys_>< ' ms (' sys_>< slow_unit sys_>< ')');
enddefine;

report('examples/robotarmy/fleet.log');
