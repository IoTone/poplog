/* --- sysexecute_or_exit ------------------------------------------------
 > File:            pop/lib/auto/sysexecute_or_exit.p
 > Purpose:         sysexecute in a forked child, with no way back
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Oct 2026
 > Documentation:   REF * SYSUTIL (sysexecute), HELP * RUN_UNIX_PROGRAM
 > Related Files:   tools/tests/test_sysexecute_or_exit.p, and its callers:
 >                  LIB * RUN_UNIX_PROGRAM, * PIPEIN, * PIPEOUT, * SYS_POPEN,
 >                  LIB * SHELL, * PTYFORK, * SHELL_COMPILE, ved_postnews.p
 */
compile_mode :pop11 +strict;

section;

/*
sysexecute_or_exit(FILE, ARG_LIST, ENV_LIST)
    As sysexecute, for use in the child of a sys_fork: it returns only by
    the exec succeeding.  If the exec fails, the reason is written to the
    child's popdeverr and the child exits with status 127 (the shell's
    "command not found").

    Why not plain sysexecute: the forked child is a copy of the parent's
    whole Poplog -- its call stack, its dlocal'd prmishap, its exitto
    targets.  When sysexecute fails it mishaps, and any handler in that
    copied stack (a caller's prmishap that exits, LIB POPTEST's
    check_mishaps, an interrupt handler) resumes the PARENT'S code in the
    child, which then runs on as a second Poplog sharing the parent's
    files and input.  Code after the sysexecute call, such as a
    fast_sysexit "just in case", is never reached in that case.

    Here every way out other than a successful exec ends the process: a
    dlocal exit action catches any abnormal exit, and a local prmishap
    reports the failure and exits before any handler further up runs.

    Not for a vfork child with real vfork semantics: dlocal'ing prmishap
    writes the shared address space.  sys_vfork is sys_fork on every
    platform this tree builds (BSD_VFORK is not defined); see
    pop/src/sysfork.p.
*/
;;; fast_sysexit takes no argument: the status is pop_exit_ok, which an
;;; integer sets directly (REF * SYSTEM)
define lconstant die();
    127 -> pop_exit_ok;
    fast_sysexit()
enddefine;

define global sysexecute_or_exit(file, args, env);
    dlocal 0 %, if dlocal_context == 2 then die() endif %;
    dlocal prmishap =
        procedure(msg, culprits);
            ;;; straight to the child's own stderr: cucharerr may still
            ;;; point wherever the parent's errors go
            lvars name = if isref(file) then cont(file) else file endif,
                line = 'sysexecute_or_exit: ' sys_>< name <> ': ' <> msg <> '\n';
            syswrite(popdeverr, line, datalength(line));
            sysflush(popdeverr);
            die()
        endprocedure;
    sysexecute(file, args, env);
    die()
enddefine;

endsection;
