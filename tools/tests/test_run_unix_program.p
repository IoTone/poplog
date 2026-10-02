;;; test_run_unix_program.p — suite for LIB * RUN_UNIX_PROGRAM (run via tools/test-libs.sh)
;;;
;;; The case that matters: exec failing in the forked child while a mishap
;;; handler is active.  The child is a copy of this whole Poplog, handler
;;; included; before the fix, the child's mishap was caught there and the
;;; child carried on running this file as a second copy of the suite.  So
;;; every process that reaches a checkpoint appends its pid to a file, and
;;; exactly one -- this one -- may.
uses poptest;
uses fileutils;

lconstant out = systmpfile(false, 'poptest_rup_out', '');
lconstant err = systmpfile(false, 'poptest_rup_err', '');
lconstant marks = systmpfile(false, 'poptest_rup_marks', '');
lconstant missing = '/nonexistent/poptest-no-such-program';
lvars status;

;;; --- ordinary use still works ---
run_unix_program('echo', ['hello'], false, out, false, true) -> (, , , status, );
check('a found program runs', file_to_string(out), 'hello\n');
check('and exits 0', status, 0);

;;; --- a missing program: the child reports and exits ---
run_unix_program(missing, [], false, false, err, true) -> (, , , status, );
check_true('a missing program fails', status /== 0);
check_true('the reason reaches its stderr',
           issubstring(missing, file_to_string(err)) and true);

;;; --- ...even under a handler that would resume the caller ---
vars trapped = false;
define try_missing();
    dlocal prmishap =
        procedure(msg, culprits); true -> trapped; exitfrom(try_missing) endprocedure;
    run_unix_program(missing, [], false, false, err, true) -> (, , , , );
enddefine;
string_to_file('', marks);
try_missing();
file_append(poppid sys_>< '\n', marks);
syssleep(50);       ;;; time for a runaway child to get here too
check('no handler of ours saw a mishap', trapped, false);
check('only this process ran on', file_lines(marks), [% poppid sys_>< '' %]);

;;; --- and with pipes and no wait, the parent just sees end of file ---
lvars (, outdev, , , ) =
    run_unix_program(missing, [], false, true, err, false);
check('the pipe reads end of file', sysread(outdev, inits(16), 16), 0);
sysclose(outdev);

sysdelete(out) -> ;
sysdelete(err) -> ;
sysdelete(marks) -> ;

test_summary();
