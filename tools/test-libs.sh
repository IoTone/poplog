#!/bin/sh
# test-libs.sh — run the Pop-11 library test suites in tools/tests/.
#
#   tools/test-libs.sh [engine-command] [suite ...]
#
# Each suite is a tools/tests/test_<name>.p file using LIB * POPTEST;
# a suite passes when it prints 'SUMMARY: ALL PASS'.  With no suite
# arguments, all suites run.  Exit status is the number of failing
# suites (0 = all green).
#
# TIMEOUTS.  Every suite runs under a watchdog, because a suite that hangs
# otherwise hangs the whole run -- and a test run that can hang is a test
# run nobody puts in CI.  The default is TEST_TIMEOUT seconds (120); a
# suite that legitimately needs longer says so in its own first lines:
#
#     ;;; test-timeout: 600
#
# so the limit lives with the unit that needs it rather than in the runner.
#
# The watchdog is deliberately OUTSIDE the engine.  An in-process timer
# cannot rescue a wedged engine, which is the case that matters; and there
# is no portable `timeout(1)` to lean on -- macOS ships neither it nor
# gtimeout.
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"

engine=""
if [ $# -gt 0 ]; then
    case "$1" in
        *test_*.p|*/tests/*) : ;;   # first arg is a suite, not an engine
        *) engine="$1"; shift ;;
    esac
fi
if [ -z "$engine" ]; then
    [ -x "$repo/target/pop/basepop11" ] || {
        echo "test-libs: no target/pop/basepop11 (build first, or pass an engine)" >&2; exit 2; }
    engine="$repo/poplog $repo/target/pop/basepop11"
fi
# riscv64 Poplog must run with ASLR off (see PORTING-RISCV64-LINUX.md)
case "$(uname -m)" in
    riscv64) engine="setarch -R $engine" ;;
esac

if [ $# -gt 0 ]; then
    suites="$*"
else
    suites=$(ls "$repo"/tools/tests/test_*.p)
fi

: "${TEST_TIMEOUT:=120}"

# run_suite <seconds> <suite> -- output on stdout, 124 if it had to be killed
run_suite() {
    _secs=$1; _suite=$2
    _tmp=$(mktemp) || return 2
    # shellcheck disable=SC2086  # $engine may be "wrapper binary"
    $engine "$_suite" >"$_tmp" 2>&1 &
    _pid=$!
    _waited=0
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_waited" -ge "$_secs" ]; then
            # a kill that finds the process already gone returns 1, and under
            # set -e that aborts the subshell before we can report the timeout
            kill -TERM "$_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$_pid" 2>/dev/null || true
            wait "$_pid" 2>/dev/null || true
            cat "$_tmp"; rm -f "$_tmp"
            return 124
        fi
        sleep 1
        _waited=$((_waited + 1))
    done
    wait "$_pid" 2>/dev/null || true
    cat "$_tmp"; rm -f "$_tmp"
    return 0
}

bad=0
for s in $suites; do
    name=$(basename "$s" .p)
    # a suite may raise its own limit; the runner only supplies a default
    secs=$(sed -n 's/^;;;[[:space:]]*test-timeout:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$s" \
           2>/dev/null | head -1)
    [ -n "$secs" ] || secs=$TEST_TIMEOUT
    # `|| rc=$?` not `; rc=$?`: under set -e a bare failing assignment
    # exits the script, so a timeout would kill the run silently -- which is
    # precisely the failure the watchdog exists to report.
    rc=0
    out=$(run_suite "$secs" "$s") || rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "FAIL  $name  (timed out after ${secs}s)"
        printf '%s\n' "$out" | tail -10
        bad=$((bad+1))
        continue
    fi
    line=$(printf '%s\n' "$out" | grep -o 'SUMMARY: .*' | tail -1)
    if printf '%s' "$line" | grep -q 'ALL PASS'; then
        echo "PASS  $name  ($line)"
    else
        echo "FAIL  $name"
        printf '%s\n' "$out" | grep -E '^\*\*|MISHAP|;;;' | tail -25
        bad=$((bad+1))
    fi
done
[ $bad -eq 0 ] && echo "test-libs: all suites green" || echo "test-libs: $bad suite(s) failing"
exit $bad
