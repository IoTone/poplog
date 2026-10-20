;;; test_datetime.p — suite for LIB * DATETIME (run via tools/test-libs.sh)
;;; Ground-truth epoch values generated with Python calendar.timegm.
uses poptest;
uses datetime;

check('epoch zero', dt_iso(0), '1970-01-01T00:00:00Z');
check('epoch zero fields', dt_fields(0), {1970 1 1 0 0 0});
check('known 2026', dt_parse_iso('2026-08-09T12:34:56Z'), 1786278896);
check('known 2026 iso', dt_iso(1786278896), '2026-08-09T12:34:56Z');
check('leap day 2000', dt_parse_iso('2000-02-29T00:00:00Z'), 951782400);
check('end of 1999', dt_parse_iso('1999-12-31T23:59:59Z'), 946684799);
check('2100 not leap', dt_parse_iso('2100-03-01T00:00:00Z'), 4107542400);
check('pre-epoch', dt_parse_iso('1969-07-20T20:17:00Z'), -14182980);
check('date only', dt_parse_iso('2026-08-09'), 1786233600);
check('space separator', dt_parse_iso('2026-08-09 12:34:56'), 1786278896);
check('no Z accepted', dt_parse_iso('2026-08-09T12:34:56'), 1786278896);
check('days from civil epoch', dt_days_from_civil(1970, 1, 1), 0);
check('days from civil 2026', dt_days_from_civil(2026, 8, 9), 1786233600 div 86400);

;;; round trip across a wide sweep incl. negatives and leap years
vars t, ok = true;
for t from -1000000000 by 250000007 to 2000000000 do
    unless dt_parse_iso(dt_iso(t)) == t then false -> ok endunless;
endfor;
check_true('iso round trip sweep', ok);

check_true('dt_now plausible', dt_now() > 1750000000);

;;; sys_microtime is the only REAL-time clock with sub-second resolution
;;; (REF * TIMES, HELP * CLOCK).  It matters that it is real and not CPU
;;; time: anything timing a wait -- a user typing, a socket, a subprocess
;;; -- gets nothing useful from systime(), which stops while we wait.
lvars t_us0 = sys_microtime(), t_cpu0 = systime();
syssleep(30);                                       ;;; 300ms of real waiting
lvars elapsed_ms = (sys_microtime() - t_us0) div 1000;
check_true('sys_microtime agrees with sys_real_time to the second',
           abs((sys_microtime() div 1000000) - sys_real_time()) <= 1);
check_true('sys_microtime measures a wait (>=250ms of a 300ms sleep)',
           elapsed_ms >= 250);
check_true('and is not CPU time (systime barely moved)',
           systime() - t_cpu0 < 25);

check_mishaps('bad format', procedure; dt_parse_iso('20260809').erase endprocedure);
check_mishaps('bad month', procedure; dt_parse_iso('2026-13-01').erase endprocedure);
check_mishaps('bad time', procedure; dt_parse_iso('2026-08-09T99:00:00').erase endprocedure);
check_mishaps('non-integer', procedure; dt_iso('x').erase endprocedure);

test_summary();
