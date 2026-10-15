;;; test_sysexecute_or_exit.p — suite for LIB * SYSEXECUTE_OR_EXIT and the
;;; fork-and-exec libraries that use it (run via tools/test-libs.sh)
;;;
;;; Each case makes an exec fail in a forked child while a handler is active
;;; that would resume the caller.  Before sysexecute_or_exit, the child's
;;; mishap reached that handler -- the child is a copy of this Poplog, handler
;;; and all -- and the child ran on through the rest of this file.  So every
;;; process that gets past a case appends its pid to a file, and exactly one
;;; may.  The exec fails on a file that exists but is not executable, which
;;; gets past the PATH checks some callers make before forking.
uses poptest;
uses fileutils;

lconstant noexec = systmpfile(false, 'poptest_noexec', '');
lconstant marks = systmpfile(false, 'poptest_seoe_marks', '');
string_to_file('#!/bin/sh\necho should not run\n', noexec);   ;;; mode 0644: EACCES

;;; exit code from a sys_wait status, as LIB SHELL decodes it
define exit_code(raw);
    if (raw && 127) == 0 then (raw >> 8) && 16:FF else 128 + (raw && 127) endif
enddefine;

;;; all of a device's output, as a string
define drain(dev) -> s;
    lvars buf = inits(4096), n;
    '' -> s;
    while (sysread(dev, buf, 4096) ->> n) > 0 do
        s <> substring(1, n, buf) -> s
    endwhile;
    sysclose(dev);
enddefine;

;;; sys_popen's parent keeps the pipe's write end open, so end of file never
;;; comes: its output is read with read_pipe, which stops once the child has
;;; been reported finished
define popen_drain(dev, ref) -> s;
    lvars buf = inits(4096), n;
    '' -> s;
    repeat
        read_pipe(dev, buf, 4096, ref) -> n;
        quitunless(n);
        if n > 0 then s <> substring(1, n, buf) -> s endif
    endrepeat;
    sysclose(dev);
enddefine;

vars trapped;
define under_exiting_handler(p);
    dlocal prmishap =
        procedure(msg, culprits); true -> trapped; exitfrom(under_exiting_handler) endprocedure;
    p();
enddefine;

;;; run P under a handler that would resume us; then only this process may
;;; reach the checkpoint, and that handler must not have fired
define no_runaway(name, p);
    false -> trapped;
    string_to_file('', marks);
    under_exiting_handler(p);
    file_append(poppid sys_>< '\n', marks);
    syssleep(50);       ;;; time for a runaway copy to get here too
    check(name <> ': no handler of ours saw a mishap', trapped, false);
    check(name <> ': only this process ran on', file_lines(marks),
          [% poppid sys_>< '' %]);
enddefine;

;;; --- the helper itself ---
vars status = false;
no_runaway('sysexecute_or_exit',
    procedure;
        lvars pid = sys_fork(true);
        if pid then
            sys_wait(pid) -> (, status)
        else
            sysexecute_or_exit(noexec, [^noexec], false)
        endif
    endprocedure);
check('sysexecute_or_exit exits 127', exit_code(status), 127);

;;; --- run_unix_program ---
no_runaway('run_unix_program',
    procedure;
        run_unix_program(noexec, [], false, false, false, true) -> (, , , status, )
    endprocedure);
check('run_unix_program reports 127', exit_code(status), 127);

;;; --- pipein: the reason arrives on the pipe, then end of file ---
vars output = false;
no_runaway('pipein',
    procedure; drain(pipein(noexec, [^noexec], false)) -> output endprocedure);
check_true('pipein output names the program', issubstring(noexec, output) and true);

;;; --- pipeout, waiting for the child ---
no_runaway('pipeout',
    procedure; pipeout(consref(erase), noexec, [^noexec], true) endprocedure);

;;; --- sys_popen ---
no_runaway('sys_popen',
    procedure; popen_drain(sys_popen(noexec, [])) -> output endprocedure);
check_true('sys_popen output names the program', issubstring(noexec, output) and true);

;;; --- a successful exec is untouched ---
check('a working program still runs',
      drain(pipein('/bin/echo', ['/bin/echo' 'hello'], false)), 'hello\n');

sysdelete(noexec) -> ;
sysdelete(marks) -> ;

test_summary();
