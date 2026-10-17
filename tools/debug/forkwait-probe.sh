#!/bin/sh
# forkwait-probe.sh — catch the intermittent process-wait hang in the act.
#
#   tools/debug/forkwait-probe.sh [rounds] [suite ...]
#
# Runs a suite repeatedly and, the moment one stops making progress,
# dumps the state of the engine and its children BEFORE killing
# anything.  That ordering is the whole point: tools/test-libs.sh's
# watchdog kills the process group after 120s, so by the time it prints
# "timed out" the evidence is gone.
#
# What this exists to settle.  The skill-release workflow runs all 16
# library suites on hosted runners for the first time (the Jenkins gate
# ran 2), and three of nine platform legs hung -- test_http_server twice
# on macOS arm64, test_sysexecute_or_exit once on x86_64 Linux, each
# after its visible checks had passed, each parked waiting for a child.
# 23 local runs, loaded and unloaded, are clean, so the evidence has to
# be collected where it happens.
#
# The question a dump has to answer first is which of two bugs this is:
#
#   child is a zombie (STAT Z, or <defunct>)
#       The child is dead and reaped-able and the parent has not noticed:
#       a sys_wait bookkeeping bug.  pop/src/syswait.p waits with
#       `repeat returnif(is_dead(pid)); syshibernate() endrepeat`, so a
#       pid whose status was consumed by another waiter loops forever --
#       and the 100ms bound added in #47 does not help, because the
#       problem is not a lost wake-up but a wait that can never succeed.
#       Both failing suites have a SECOND child alive at the same time
#       as the one being waited on, which is what makes this the leading
#       hypothesis.
#
#   child is alive (STAT S/R)
#       The child never exited, and the parent is correct to wait.  Then
#       the bug is in the child -- or, for test_http_server, the server
#       is still waiting for a request that the test believes it sent.
#
# On Linux /proc/<pid>/status settles it further: SigPnd/SigBlk tell us
# whether a SIGCHLD is sitting pending and blocked, and the fd list
# shows whether a pipe write end leaked into a later child (which would
# keep read_all from ever seeing EOF, the other way to hang here).
#
# Exit status: 0 if every round finished, 1 on the first hang (with the
# dump on stdout), 2 on a usage or setup error.
set -e

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

rounds="${1:-40}"
case "$rounds" in ''|*[!0-9]*) echo "forkwait-probe: rounds must be a number" >&2; exit 2 ;; esac
shift 2>/dev/null || true

[ -x "$repo/target/pop/basepop11" ] || {
    echo "forkwait-probe: no target/pop/basepop11 -- build first" >&2; exit 2; }

if [ $# -gt 0 ]; then
    suites="$*"
else
    suites="tools/tests/test_http_server.p tools/tests/test_sysexecute_or_exit.p"
fi

# Long enough that a slow runner is not mistaken for a hang: the slowest
# of these suites takes about 5s in CI, so 75s is ~15x headroom.
: "${PROBE_PATIENCE:=75}"

dump() {
    _pid=$1; _suite=$2; _round=$3; _log=$4
    echo "=============================================================="
    echo "HANG  $_suite  round $_round  engine pid $_pid"
    echo "uname: $(uname -srm)   patience: ${PROBE_PATIENCE}s"
    echo "=============================================================="

    echo "--- suite output so far ---"
    cat "$_log" 2>/dev/null || echo "(none)"

    # The decisive table.  A Z / <defunct> line under our pid means the
    # parent is waiting for a child that is already dead.
    echo "--- process tree ---"
    case "$(uname -s)" in
        Linux) ps -eo pid,ppid,stat,wchan:25,etime,args 2>/dev/null \
                   | awk -v p="$_pid" 'NR==1 || $1==p || $2==p' ;;
        *)     ps -eo pid,ppid,stat,etime,command 2>/dev/null \
                   | awk -v p="$_pid" 'NR==1 || $1==p || $2==p' ;;
    esac

    echo "--- descendants, any depth ---"
    # pgrep -P only gives one level; two levels is enough here (sh -> curl).
    for kid in $(pgrep -P "$_pid" 2>/dev/null); do
        ps -o pid,ppid,stat,etime,command -p "$kid" 2>/dev/null | tail -n +2
        for gkid in $(pgrep -P "$kid" 2>/dev/null); do
            ps -o pid,ppid,stat,etime,command -p "$gkid" 2>/dev/null | tail -n +2
        done
    done

    if [ -d "/proc/$_pid" ]; then
        echo "--- /proc/$_pid/wchan ---"
        cat "/proc/$_pid/wchan" 2>/dev/null; echo
        # SigPnd & SigBlk with bit 17 (SIGCHLD) set would mean the signal
        # arrived and is being held -- the lost-wake-up shape.
        echo "--- /proc/$_pid/status (signals and state) ---"
        grep -E '^(State|Threads|Sig(Pnd|Blk|Ign|Cgt)|ShdPnd)' \
            "/proc/$_pid/status" 2>/dev/null
        # A leaked pipe write end here is the other way read_all hangs.
        echo "--- /proc/$_pid/fd ---"
        ls -l "/proc/$_pid/fd" 2>/dev/null | sed 's/^.*[0-9] //'
        echo "--- /proc/$_pid/syscall ---"
        cat "/proc/$_pid/syscall" 2>/dev/null; echo
    fi

    echo "--- native backtrace ---"
    if command -v gdb >/dev/null 2>&1; then
        gdb -p "$_pid" -batch -ex 'bt' 2>&1 | tail -30
    elif command -v lldb >/dev/null 2>&1; then
        lldb -p "$_pid" --batch -o 'bt' -o 'detach' 2>&1 | tail -30
    else
        echo "(no gdb or lldb)"
    fi
    echo "=============================================================="
}

for suite in $suites; do
    name=$(basename "$suite" .p)
    r=1
    while [ "$r" -le "$rounds" ]; do
        log=$(mktemp) || exit 2
        # No test-libs.sh here: its watchdog would kill the evidence.
        ./poplog ./target/pop/basepop11 "$suite" >"$log" 2>&1 &
        pid=$!

        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$waited" -ge "$PROBE_PATIENCE" ]; then
                dump "$pid" "$name" "$r" "$log"
                # Only now, and only what this script started.
                kill -TERM "$pid" 2>/dev/null || true
                sleep 2
                kill -KILL "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                rm -f "$log"
                exit 1
            fi
            sleep 1
            waited=$((waited + 1))
        done
        wait "$pid" 2>/dev/null || true

        if grep -q 'SUMMARY: ALL PASS' "$log"; then
            printf '%s round %s/%s ok\n' "$name" "$r" "$rounds"
        else
            # A failing check is not the hang we are hunting, but it is
            # not nothing either -- say so and keep going.
            printf '%s round %s/%s CHECKS FAILED\n' "$name" "$r" "$rounds"
            grep -E '^\*\*|MISHAP' "$log" | tail -5
        fi
        rm -f "$log"
        r=$((r + 1))
    done
done

echo "forkwait-probe: no hang in $rounds rounds of each suite"
