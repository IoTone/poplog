/* --- Process orchestration ----------------------------------------------
 > File:            pop/lib/lib/shell.p
 > Purpose:         Run commands with captured output, status, stderr,
 >                  background jobs and timeouts
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   HELP * SHELL_LIB
 > Related Files:   tools/tests/test_shell.p, LIB * STRUTILS, * FILEUTILS
 >
 > What sysobey never gave you: exit status, stderr, and control.
 > Commands run via '/bin/sh -c'.  Status is the decoded exit code
 > (0-255); a signal death decodes to 128 + signum (so SIGTERM = 143,
 > the shell convention).
 >
 > Design notes: shell_run merges stderr into the captured output
 > (2>&1 semantics); shell_run_full captures stderr separately via a
 > temp file, which cannot deadlock the way a second pipe can.  The
 > shell_timeout watchdog runs detached from the output pipe so quick
 > commands return immediately.
 */
compile_mode :pop11 +strict;

uses strutils;
uses fileutils;

section $-shell =>
    shell_run shell_run_full shell_lines
    shell_bg shell_wait shell_kill shell_timeout;

define lconstant decode_status(raw) -> code;
    if (raw && 127) == 0 then
        (raw << -8) && 16:FF -> code;
    else
        128 + (raw && 127) -> code;
    endif;
enddefine;

define lconstant read_all(dev) -> s;
    lvars buf = inits(4096), n, i, total = 0;
    repeat
        sysread(dev, buf, 4096) -> n;
        quitif(n == 0);
        for i from 1 to n do subscrs(i, buf) endfor;
        total + n -> total;
    endrepeat;
    consstring(total) -> s;
enddefine;

;;; fork '/bin/sh -c cmd'; errdest is "merge" (2>&1 into the pipe), a
;;; filename (stderr to that file), or false (inherit our stderr)
define lconstant spawn(cmd, errdest) -> (pid, outdev);
    lvars rd, wr;
    unless isstring(cmd) then
        mishap(cmd, 1, 'shell: command string needed')
    endunless;
    ;;; syspipe returns (write_end, read_end) — the same order pipein
    ;;; destructures as (dout, din)
    syspipe(false) -> (wr, rd);
    sys_fork(true) -> pid;
    if pid then
        sysclose(wr);
        rd -> outdev;
    else
        sysclose(rd);
        wr -> popdevout;
        if errdest == "merge" then
            wr -> popdeverr;
        elseif isstring(errdest) then
            syscreate(errdest, 1, false) -> popdeverr;
        endif;
        sysexecute_or_exit('/bin/sh', ['/bin/sh' '-c' ^cmd], false);
    endif;
enddefine;

define lconstant collect(pid, dev) -> (output, status);
    lvars dpid, raw;
    read_all(dev) -> output;
    sysclose(dev);
    sys_wait(pid) -> (dpid, raw);
    decode_status(raw) -> status;
enddefine;

;;; run cmd; capture stdout + stderr together, return decoded status
define shell_run(cmd) -> (output, status);
    collect(spawn(cmd, "merge")) -> (output, status);
enddefine;

;;; run cmd; stdout and stderr captured separately
define shell_run_full(cmd) -> (output, errout, status);
    lvars tf = systmpfile(false, 'shellerr', '');
    collect(spawn(cmd, tf)) -> (output, status);
    file_to_string(tf) -> errout;
    sysdelete(tf) -> ;
enddefine;

;;; run cmd; stdout+stderr as a list of lines
define shell_lines(cmd) -> (lines, status);
    lvars output;
    shell_run(cmd) -> (output, status);
    str_lines(output) -> lines;
enddefine;

;;; start cmd in the background; the job is opaque — pass it to
;;; shell_wait (and optionally shell_kill first)
define shell_bg(cmd) -> job;
    lvars pid, dev;
    spawn(cmd, "merge") -> (pid, dev);
    {% pid, dev %} -> job;
enddefine;

define shell_wait(job) -> (output, status);
    collect(subscrv(1, job), subscrv(2, job)) -> (output, status);
enddefine;

define shell_kill(job);
    sys_send_signal(subscrv(1, job), 15) -> ;       ;;; SIGTERM
enddefine;

;;; run cmd but SIGTERM it after secs seconds; a timed-out command
;;; reports status 143 (128 + SIGTERM).  The watchdog is detached from
;;; the output pipe, so fast commands return without waiting.
define shell_timeout(cmd, secs) -> (output, status);
    unless isinteger(secs) and secs > 0 then
        mishap(secs, 1, 'shell_timeout: positive seconds needed')
    endunless;
    shell_run('{ ' <> cmd <> '\n} & c=$!; '
        <> '( sleep ' <> (secs sys_>< nullstring)
        <> '; kill -TERM $c 2>/dev/null ) >/dev/null 2>&1 & w=$!; '
        <> 'wait $c; s=$?; kill $w 2>/dev/null; exit $s')
        -> (output, status);
enddefine;

endsection;
