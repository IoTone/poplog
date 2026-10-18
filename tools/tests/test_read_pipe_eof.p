;;; test_read_pipe_eof.p — a pipe at end of file must end read_pipe's
;;; drain (run via tools/test-libs.sh)
;;;
;;; A pipe at EOF stays READY for select, so read_pipe's ready branch is
;;; taken every time and the else branch -- the only one that consults
;;; cont(ref) and the only one that can return false -- is unreachable.
;;; Before the fix read_pipe returned 0 ("alive, nothing yet") for ever,
;;; and the documented drain loop span at 100% CPU: the intermittent CI
;;; hang, 7-8 of 8 sampling rounds on hosted x86_64.  See
;;; docs/bugs/popen-drain-eof-spin.md.
;;;
;;; Unlike the hang it caused, the defect itself is deterministic: no
;;; forking, no races, just a pipe whose writer is gone.

uses poptest;
uses sys_popen;

vars buf = inits(64), w, r, n;

;;; the writer closes without writing: pure EOF
syspipe("line") -> (w, r);
sysclose(w);
check('EOF with status not yet arrived is finished, not 0',
      read_pipe(r, buf, 64, consref(false)), false);
check('and stays finished on the next call',
      read_pipe(r, buf, 64, consref(false)), false);
sysclose(r);

;;; the writer writes first, then closes: data, then EOF
syspipe(false) -> (w, r);
syswrite(w, 'hi', 2);
sysclose(w);
read_pipe(r, buf, 64, consref(false)) -> n;
check('buffered output is still delivered', n, 2);
check('then end of file is finished',
      read_pipe(r, buf, 64, consref(false)), false);
sysclose(r);

;;; the whole machine together: sys_popen of a real program must drain to
;;; completion.  Before the fix this only ended when the child's status
;;; ast won a race; at EOF-mishandled plus a GC'd write end it never did.
vars dev, ref, out = '';
sys_popen('/bin/echo', ['hello']) -> (dev, ref);
repeat
    read_pipe(dev, buf, 64, ref) -> n;
    quitunless(n);
    if n > 0 then out <> substring(1, n, buf) -> out endif
endrepeat;
sysclose(dev);
check('sys_popen drains to completion', out, 'hello\n');

test_summary();
