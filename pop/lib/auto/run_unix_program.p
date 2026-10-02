/* --- Copyright University of Sussex 1996. All rights reserved. ----------
 > File:            C.unix/lib/auto/run_unix_program.p
 > Purpose:         Run Unix command from within Poplog
 > Author:          John Williams, Mar 30 1990 (see revisions)
 > Documentation:   HELP * RUN_UNIX_PROGRAM
 > Related Files:   C.unix/lisp/modules/run-unix-program.lsp
 */
compile_mode :pop11 +strict;


section;

;;; Run in the forked child: exec NAME, and never return.  The child is a copy
;;; of the whole parent Poplog -- its call stack, its dlocal'd prmishap, its
;;; exitto targets.  If the exec fails, sysexecute mishaps, and a handler
;;; further up the stack (a caller's prmishap that exits, LIB POPTEST's
;;; check_mishaps, an interrupt handler) would resume the PARENT'S code in the
;;; child, which then runs on as a second Poplog sharing the parent's input.
;;; So any way out of here other than a successful exec ends the child: the
;;; reason goes to the child's stderr (popdeverr, wherever errs pointed it),
;;; and the exit status is 127, the shell's "command not found".
define lconstant exec_or_die(name, args);
    dlocal 0 %, if dlocal_context == 2 then fast_sysexit(127) endif %;
    dlocal prmishap =
        procedure(msg, culprits);
            ;;; straight to the child's own stderr: cucharerr may still
            ;;; point wherever the parent's errors go
            lvars line = 'run_unix_program: ' <> name <> ': ' <> msg <> '\n';
            syswrite(popdeverr, line, datalength(line));
            sysflush(popdeverr);
            fast_sysexit(127)
        endprocedure;
    sysexecute(consref(name), name :: args, false);
    fast_sysexit(127)
enddefine;

define global run_unix_program(name, args, input, output, errs, wait);
    lvars child_deverr, child_devin, child_devout,
            parent_errs, parent_get, parent_send, pid, status;

    sysfileok(name) -> name;
    maplist(args, $-lisp$-get_simple_string) -> args;

    /* <input>, <output>, <errs> may be true, filename, device, or false */
    if input == true then
        syspipe(false) -> child_devin -> parent_send
    elseif isstring(input) then
        sysopen(input, 0, false) -> child_devin
    else
        input -> child_devin
    endif;

    if output == true then
        syspipe("line") -> parent_get
    elseif isstring(output) then
        syscreate(output, 1, "line")
    else
        output
    endif -> child_devout;

    if errs == true then
        syspipe("line") -> parent_errs
    elseif errs == 1 then
        child_devout
    elseif isstring(errs) then
        syscreate(errs, 1, "line")
    else
        errs
    endif -> child_deverr;

    if (sys_fork(true) ->> pid) then
        ;;; parent
        if input == true then
            false -> wait;
            sysclose(child_devin)
        endif;
        if output == true then
            false -> wait;
            sysclose(child_devout)
        endif;
        if errs == true then
            false -> wait;
            sysclose(child_deverr)
        endif;
        if wait then
            sys_wait(pid) -> (, status)
        endif
    else
        ;;; child
        if isdevice(child_devin) then
            child_devin -> popdevin
        endif;
        if isdevice(child_devout) then
            child_devout -> popdevout
        endif;
        if isdevice(child_deverr) then
            child_deverr -> popdeverr
        endif;
        if input == true then
            sysclose(parent_send)
        endif;
        if output == true then
            sysclose(parent_get)
        endif;
        if errs == true then
            sysclose(parent_errs)
        endif;
        exec_or_die(name, args)
    endif;

    /* Results (5) */
    if input == true then
        parent_send
    else
        false
    endif;
    if output == true then
        parent_get
    else
        false
    endif;
    if errs == true then
        parent_errs
    else
        false
    endif;
    if wait then
        status
    else
        true
    endif;
    pid
enddefine;

endsection;


/* --- Revision History ---------------------------------------------------
--- D.Kordsmeier (@truedat101) and Claude (@claude), Oct 1 2026
        A failed exec now always ends the child (status 127).  Before, the
        child's mishap could be caught by a handler in the copied call stack,
        and the child carried on running the parent's code.
--- John Williams, Apr 30 1996
        First arg to sysexecute now a ref (i.e. use execvp).
--- John Gibson, Jun  9 1994
        Changed arg to first call of syspipe to be false.
--- John Williams, Jun  6 1994
        Fixed incorrect use of string quotes.
--- John Gibson, Apr 21 1994
        Changed to use new sys_fork etc
 */
