#!/usr/bin/env bash
#
# validate-cygwin.sh -- validate the Poplog x86-64 Windows (Cygwin) port.
#
# Run from a Cygwin shell, in a tree where `./configure --with_no_x` and
# `make all` have completed:
#
#     tools/validate-cygwin.sh
#
# Mirrors tools/validate-msilicon.sh and tools/validate-raspi5.sh gate for
# gate, then adds the Windows-specific gates from PORTING-X86-64-WINDOWS.md
# section 8.
#
# Every gate checks OUTPUT, never exit status alone: on this system a process
# that overruns its stack, or dies of a fault nobody claims, can exit with
# status 0 and print nothing.
#
set -u

case "$(uname -s)/$(uname -m)" in
    CYGWIN*/x86_64) ;;
    *) echo "ERROR: this tool targets Cygwin on x86_64; host is $(uname -s)/$(uname -m)."
       echo "       See PORTING-X86-64-WINDOWS.md."
       exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
[ -x ./poplog ] || { echo "FATAL: ./poplog missing -- run ./configure first."; exit 2; }
[ -x target/pop/basepop11 ] || { echo "FATAL: target/pop/basepop11 missing -- run make all first."; exit 2; }

BASE=(./poplog target/pop/basepop11)
PSV=target/psv
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; SKIP=0; OUT=""
crashed() { grep -qaiE 'Access Violation|MEMORY ACCESS|Signal *=|Segmentation|Illegal instruction|FATAL ERROR|BAD STRUCTURE|core dumped|cannot recover|cannot reserve' <<<"$OUT"; }
gate() {
    local name="$1" want="$2"
    if crashed; then
        printf '  [FAIL] %-44s crash\n' "$name"; FAIL=$((FAIL+1))
        printf '%s\n' "$OUT" | head -6 | sed 's/^/         | /'
    elif grep -qaE "$want" <<<"$OUT"; then
        printf '  [PASS] %s\n' "$name"; PASS=$((PASS+1))
    else
        printf '  [FAIL] %-44s expected /%s/\n' "$name" "$want"; FAIL=$((FAIL+1))
        printf '%s\n' "$OUT" | head -6 | sed 's/^/         | /'
    fi
}
# like gate, but a mishap is the expected outcome, so "crash" words are allowed
gate_mishap() {
    local name="$1" want="$2"
    if grep -qaE "$want" <<<"$OUT"; then
        printf '  [PASS] %s\n' "$name"; PASS=$((PASS+1))
    else
        printf '  [FAIL] %-44s expected /%s/\n' "$name" "$want"; FAIL=$((FAIL+1))
        printf '%s\n' "$OUT" | head -6 | sed 's/^/         | /'
    fi
}
skip() { printf '  [SKIP] %s\n' "$1"; SKIP=$((SKIP+1)); }
pop11() { timeout "${TMO:-30}" "${BASE[@]}" "-$PSV/startup.psv" "$@" 2>&1; }

echo "== Poplog x86-64 / Windows (Cygwin) validation =="
echo "   repo:    $ROOT"
echo "   system:  $(uname -srm)"
echo "   page size: $(getconf PAGE_SIZE)   (image VPAGE_OFFS expects 65536)"
for f in startup clisp prolog pml; do
    [ -f "$PSV/$f.psv" ] && printf '   %-12s %s bytes\n' "$f.psv" "$(stat -c %s "$PSV/$f.psv")" \
                         || printf '   %-12s MISSING\n' "$f.psv"
done
echo

echo "-- gate 1: Pop-11 core REPL (startup.psv) --"
OUT=$(printf '2 + 2 =>\n3 + 5 * 2 =>\n' | pop11)
gate "arithmetic + precedence (4, 13)"   '\*\* 13'
OUT=$(printf 'define sq(x); x * x enddefine;\nsq(9) =>\n' | pop11)
gate "user procedure (sq 9 = 81)"        '\*\* 81'
OUT=$(printf '[%% for i in_vector {7 8 9} do i endfor %%] =>\n' | pop11)
gate "for..in_vector ([7 8 9])"          '\*\* \[7 8 9\]'
OUT=$(pop11 tools/port-windows/second-light.p)
gate "objectclass, processes, properties, files" 'written and read back'
gate "second-light.p ran to its last line"       '\*\* 22_/7'

echo "-- gate 2: Common Lisp (clisp.psv) --"
if [ -f $PSV/clisp.psv ]; then
OUT=$(printf '(defun fact (n) (if (zerop n) 1 (* n (fact (1- n)))))\n(print (fact 12))\n(print (mapcar #%s1+ (quote (10 20 30))))\n' "'" \
      | timeout 30 "${BASE[@]}" -$PSV/clisp.psv 2>&1)
gate "compile + recursion (fact 12)"     '479001600'
gate "mapcar ((11 21 31))"               '\(11 21 31\)'
else skip "clisp.psv missing"; fi

echo "-- gate 3: Prolog computation (prolog.psv) --"
if [ -f $PSV/prolog.psv ]; then
OUT=$(printf ':- assertz(app([],L,L)), assertz((app([H|T],L,[H|R]):-app(T,L,R))).\n:- (app([1,2,3],[4,5],Z) -> write(Z) ; write(no)), nl.\n:- assertz(f(0,1)), assertz((f(N,R):-N>0,M is N-1,f(M,P),R is N*P)).\n:- (f(6,X) -> write(fac6=X) ; write(no)), nl.\nhalt.\n' \
      | timeout 30 "${BASE[@]}" -$PSV/prolog.psv 2>&1)
gate "recursive append ([1,2,3,4,5])"    '\[1, 2, 3, 4, 5\]'
gate "factorial (fac6 = 720)"            'fac6 *= *720'

echo "-- gate 4: Prolog error reporting (must report, not crash) --"
OUT=$(printf 'X is foo + 1, write(X), nl.\nhalt.\n' | timeout 30 "${BASE[@]}" -$PSV/prolog.psv 2>&1)
gate "type error -> clean message"       'PROLOG ERROR|NUMBER'

echo "-- gate 5: piped EOF without halt (must NOT crash) --"
OUT=$(printf 'X is 6*7, write(answer=X), nl.\n' | timeout 30 "${BASE[@]}" -$PSV/prolog.psv 2>&1)
gate "bare-EOF prolog (answer = 42)"     'answer *= *42'
else skip "prolog gates (prolog.psv missing)"; fi
OUT=$(printf '2+2=>\n' | pop11)
gate "bare-EOF pop-11 (** 4)"            '\*\* 4'

echo "-- gate 6: Standard ML (pml.psv) --"
if [ -f $PSV/pml.psv ]; then
OUT=$(printf 'fun fact 0 = 1 | fact n = n * fact (n-1);\nfact 10;\nmap (fn x => x+1) [1,2,3];\n' \
      | timeout 30 "${BASE[@]}" -$PSV/pml.psv 2>&1)
gate "ML types and evaluation (fact 10)" 'val it = 3628800 : int'
gate "ML list (int list)"                '\[2, 3, 4\] : int list'
else skip "pml.psv missing"; fi

echo "-- gate 7: interactive use under a PTY --"
if command -v script >/dev/null 2>&1; then
    OUT=$( (sleep 3; printf '6 * 7 =>\n'; sleep 2; printf 'sysexit();\n'; sleep 1) \
           | timeout 30 script -q -c "./poplog target/pop/basepop11 -$PSV/startup.psv" /dev/null 2>&1)
    gate "Pop-11 prompt and evaluation (** 42)" '\*\* 42'
    if [ -f $PSV/prolog.psv ]; then
    OUT=$( (sleep 3; printf 'X is 2+3*4, write(r=X), nl.\n'; sleep 2; printf 'halt.\n'; sleep 1) \
           | timeout 30 script -q -c "./poplog target/pop/basepop11 -$PSV/prolog.psv" /dev/null 2>&1)
    gate "interactive ?- toplevel (r = 14)" 'r *= *14'
    fi
    OUT=$( (sleep 3; printf '\033xved_q\r'; sleep 2; printf '\033xq\r'; sleep 2) \
           | TERM=xterm timeout 30 script -q -c "./poplog target/pop/basepop11 -$PSV/startup.psv %nort ved $T/ved-test.txt" /dev/null 2>&1 | head -c 4000)
    gate "VED draws a screen (escape sequences seen)" $'\033\\['
else
    skip "PTY gates (no script(1); install util-linux)"
fi

echo "-- gate 8: faults become mishaps (the vectored handler) --"
cat > "$T/faults.p" <<'EOF'
define try(p, name);
    dlocal prmishap = procedure(); erasenum(stacklength()); printf(name, 'CAUGHT %p\n'); exitfrom(try) endprocedure;
    p();
    printf(name, 'NOT CAUGHT %p\n');
enddefine;
try(procedure(); -> ; -> ; -> endprocedure, 'underflow');
try(procedure(); 1 div 0 -> endprocedure, 'intdiv');
try(procedure(); 1.5 / 0 -> endprocedure, 'fltdiv');
define deep(n); if n == 0 then 0 else 1 + deep(n - 1) endif enddefine;
try(procedure(); deep(100000000) -> endprocedure, 'recursion');
printf(deep(20000), 'DEPTH %p\n');
repeat 3 times try(procedure(); -> ; -> endprocedure, 'again') endrepeat;
printf('SURVIVED\n');
EOF
OUT=$(TMO=90 pop11 "$T/faults.p")
gate_mishap "user-stack underflow"              'CAUGHT underflow'
gate_mishap "integer divide by zero"            'CAUGHT intdiv'
gate_mishap "float divide by zero"              'CAUGHT fltdiv'
gate_mishap "recursion limit reached, recovered" 'CAUGHT recursion'
gate_mishap "recursion to depth 20000"          'DEPTH 20000'
gate_mishap "handler still works afterwards"    'SURVIVED'

echo "-- gate 9: processes and the heap --"
cat > "$T/procs.p" <<'EOF'
40000000 -> popmemlim;
vars big = [% for i from 1 to 400000 do i endfor %];
sysgarbage();
printf(length(big), 'LIST %p\n');
sysobey('echo CHILD-ONE');
vars v = initv(3000000);
sysobey('echo CHILD-TWO');
printf(length(v), 'GREW %p\n');
vars p = pipein('/bin/echo', ['echo' 'PIPED-TEXT'], false);
vars buf = inits(64);
printf(substring(1, sysread(p, buf, 64) - 1, buf), 'READ %p\n');
EOF
OUT=$(TMO=90 pop11 "$T/procs.p")
gate "garbage collection of a 400000-element list" 'LIST 400000'
gate "child process (fork + exec)"                 'CHILD-ONE'
gate "child process after the heap has grown"      'CHILD-TWO'
gate "a 24 MB vector (heap growth through the emulated break)" 'GREW 3000000'
gate "pipe from a child"                           'READ PIPED-TEXT'

echo "-- gate 10: a saved image made here loads in a fresh process --"
cat > "$T/mk.p" <<'EOF'
vars marker = 'IMAGE-STATE-' >< (6 * 7);
define answer(); marker enddefine;
if syssave(systranslate('VALIDATE_IMG')) then printf(answer(), 'RESTORED %p\n'); sysexit() endif;
printf('SAVED\n');
EOF
OUT=$(VALIDATE_IMG="$T/val.psv" pop11 "$T/mk.p")
gate "syssave"                                     'SAVED'
OUT=$(timeout 30 "${BASE[@]}" "-$PSV/startup.psv" "-$T/val.psv" 2>&1 < /dev/null)
gate "restore runs code saved in the image"        'RESTORED IMAGE-STATE-42'

echo "-- gate 11: external calls (the Windows x64 calling convention) --"
OUT=$(timeout 60 "${BASE[@]}" "-$PSV/startup.psv" tools/ffi-float-regression.p 2>&1)
gate "float arguments and results (pow/atan2/hypot/cbrt)" 'FFI-FLOAT-REGRESSION-PASSED'
cat > "$T/ffi.p" <<'EOF'
exload validate_ffi []
(language C)
    lconstant
        labs(x)                 :int,
        strlen(s)               :int,
        snprintf(b,n,f,...)     :int,
        getpid()                :int,
    ;
endexload;
printf(exacc labs(-42), 'LABS %p\n');
printf(exacc strlen('seven77'), 'STRLEN %p\n');
vars b = inits(80);
;;; six arguments, then eight: more than the four that travel in registers.
;;; (A variadic call takes its argument count last; #| |# supplies it.)
vars n = exacc snprintf(#| b, 80, '%d-%d-%d', 11, 22, 33 |#);
printf(substring(1, n, b), 'SNPRINTF %p\n');
exacc snprintf(#| b, 80, '%d %d %d %d %d', 1, 2, 3, 4, 5 |#) -> n;
printf(substring(1, n, b), 'EIGHT %p\n');
printf(exacc getpid() > 0, 'GETPID %p\n');
EOF
OUT=$(pop11 "$T/ffi.p")
gate "integer argument and result (labs)"          'LABS 42'
gate "string argument (strlen)"                    'STRLEN 7'
gate "six arguments to a variadic function"        'SNPRINTF 11-22-33'
gate "eight arguments (four on the stack)"         'EIGHT 1 2 3 4 5'
gate "no-argument call (getpid)"                   'GETPID <true>'

echo "-- gate 12: a DLL built here, and callbacks from C into Pop --"
if command -v gcc >/dev/null 2>&1 && gcc -shared -O1 -o "$T/ffi-callback.dll" tools/port-windows/ffi-callback.c 2>"$T/cc.err"; then
    OUT=$(FFI_CALLBACK_LIB="$T/ffi-callback.dll" pop11 tools/port-windows/ffi-callback.p)
    gate_mishap "seven integer arguments"               'WEIGH7 7654321'
    gate_mishap "integers and doubles interleaved"      'MIX 11\.5'
    gate_mishap "single-float argument and result"      'HALVE 2\.5'
    gate_mishap "C writes into a Pop string"            'FILL zzzzzzzz'
    gate_mishap "callback from C into Pop"              'TWICE -6993'
    gate_mishap "500 allocating callbacks, C registers intact" 'LOOP 225250'
    gate_mishap "mishap inside a callback unwinds the C frames" 'MISHAP-IN-CALLBACK'
    gate_mishap "callbacks still work afterwards"       'AFTER -6993'
else
    skip "DLL gates (no gcc, or the test library did not build)"
fi

echo
echo "== summary: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" = 0 ] && echo "   PORT VALIDATED (console core)." || echo "   VALIDATION INCOMPLETE."
exit $(( FAIL > 0 ? 1 : 0 ))
