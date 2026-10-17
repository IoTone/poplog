#!/bin/sh
# hang-watch.sh — photograph a wedged engine WITHOUT touching how it was run.
#
#   sh tools/debug/hang-watch.sh <repo> <age-seconds> <out-file> &
#
# Run this beside an ordinary `sh tools/test-libs.sh`, not around it.  That
# distinction is the whole reason this file exists.  forkwait-probe.sh
# wrapped the invocation -- background instead of foreground, stdout to a
# file instead of a pipe, TEST_TIMEOUT raised -- and the hang it was built
# to catch does not happen under that wrapper: 57 wrapped sequences clean,
# against 6 hangs in 21 legs of the plain invocation.  Changing three
# things at once and then measuring was the mistake; this observes instead.
#
# What is known about the target.  test-libs.sh suites wedge waiting for a
# child process, after their visible checks have passed, on all three
# platforms: test_sysexecute_or_exit on x86_64 Linux, test_http_server on
# macOS arm64 and aarch64 Linux.  Raising TEST_TIMEOUT from 120s to 600s
# changed nothing but the number in the message, so it is a real hang and
# not a slow suite.
#
# This never signals anything.  It polls, and when an engine from THIS repo
# has been alive longer than <age-seconds> it appends a dump and keeps
# going (several suites may wedge in one run).  test-libs.sh's own watchdog
# still does the killing, on its own schedule -- so the observer cannot
# change the outcome it is observing, and cannot hit a process it did not
# start, which matters on a development machine where other sessions have
# their own engines running.
#
# Ages are tracked here rather than read from `ps -o etimes=`, which is
# GNU-only; macOS prints etime as [[DD-]HH:]MM:SS and parsing that is more
# error-prone than remembering when we first saw a pid.
set -e

repo="${1:?usage: hang-watch.sh <repo> <age-seconds> <out-file>}"
age="${2:?usage: hang-watch.sh <repo> <age-seconds> <out-file>}"
out="${3:?usage: hang-watch.sh <repo> <age-seconds> <out-file>}"

: >"$out"
seen=$(mktemp) || exit 2
dumped=$(mktemp) || exit 2
trap 'rm -f "$seen" "$dumped"' EXIT HUP INT TERM

now() { date +%s; }

engines() {
    # Only this repo's engine, and only as a full-path match: a bare
    # basepop11 pattern also matches other sessions' installed skills.
    ps -eo pid=,command= 2>/dev/null \
        | grep "$repo/target/pop/basepop11" \
        | grep -v grep \
        | awk '{print $1}'
}

dump() {
    _pid=$1; _age=$2
    {
        echo "=============================================================="
        echo "WEDGED  pid $_pid  alive ${_age}s  $(date -u +%H:%M:%SZ)"
        echo "uname: $(uname -srm)"
        echo "=============================================================="
        echo "--- command ---"
        ps -o pid=,ppid=,command= -p "$_pid" 2>/dev/null

        # The first question: is the child it waits for already dead?  A Z
        # or <defunct> line here means the parent is parked on a corpse,
        # which is a sys_wait bookkeeping bug.  An S or R child means the
        # child never exited and the parent is right to wait.
        echo "--- children and grandchildren ---"
        for kid in $(pgrep -P "$_pid" 2>/dev/null); do
            ps -o pid=,ppid=,stat=,etime=,command= -p "$kid" 2>/dev/null
            for gkid in $(pgrep -P "$kid" 2>/dev/null); do
                ps -o pid=,ppid=,stat=,etime=,command= -p "$gkid" 2>/dev/null
            done
        done

        echo "--- ancestry ---"
        _p=$_pid
        _hops=0
        while [ "$_p" != 1 ] && [ -n "$_p" ] && [ "$_hops" -lt 8 ]; do
            ps -o pid=,ppid=,stat=,command= -p "$_p" 2>/dev/null
            _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
            _hops=$((_hops + 1))
        done

        if [ -d "/proc/$_pid" ]; then
            echo "--- wchan / syscall ---"
            cat "/proc/$_pid/wchan" 2>/dev/null; echo
            cat "/proc/$_pid/syscall" 2>/dev/null; echo
            # SIGCHLD is signal 17: bit 0x10000 in these masks.  A pending
            # and blocked SIGCHLD would be the lost-wake-up shape.
            echo "--- signals and state ---"
            grep -E '^(State|Threads|Sig(Pnd|Blk|Ign|Cgt)|ShdPnd)' \
                "/proc/$_pid/status" 2>/dev/null
            # A leaked pipe write end keeps read_all from ever seeing EOF,
            # which is the other way shell.p's collect() can hang.
            echo "--- fds ---"
            ls -l "/proc/$_pid/fd" 2>/dev/null | sed 's/^.*[0-9] //'
        fi

        # The one observation that says what the loop IS rather than where
        # its program counter happened to land.  Three captured stacks all
        # sat in pop_timer, which looked like a wedged timer queue until an
        # instrumented engine printed nothing: the expired branch was never
        # taken.  A spin that calls something with a timeout arms a timer
        # every iteration, so pop_timer is simply where the cycles go.  A
        # two-second syscall histogram distinguishes the candidates
        # outright -- select+read means a pipe at EOF being re-read,
        # setitimer+sigprocmask alone means the timer code itself.
        echo "--- syscall histogram (2s sample) ---"
        if command -v strace >/dev/null 2>&1; then
            # NOT `-o /dev/stdout`: -o opens its target with O_TRUNC, and
            # here that target is this dump file, so strace quietly wiped
            # every earlier dump.  strace writes its report to stderr by
            # default, which the enclosing redirect appends.
            #
            # `|| true` on the wait because strace exits non-zero when it
            # is interrupted, and `set -e` would take the watcher with it
            # -- which it did, after the first dump.
            strace -c -p "$_pid" &
            _st=$!
            sleep 2
            kill -INT "$_st" 2>/dev/null || true
            wait "$_st" 2>/dev/null || true
        else
            echo "(no strace)"
        fi

        echo "--- native backtrace (read-only attach) ---"
        if command -v gdb >/dev/null 2>&1; then
            gdb -p "$_pid" -batch -ex 'bt' -ex 'detach' 2>&1 | tail -40
        elif command -v lldb >/dev/null 2>&1; then
            lldb -p "$_pid" --batch -o 'bt' -o 'detach' 2>&1 | tail -40
        else
            echo "(no gdb or lldb)"
        fi
        echo
    } >>"$out" 2>&1
}

while :; do
    t=$(now)
    for pid in $(engines); do
        first=$(grep "^$pid " "$seen" 2>/dev/null | cut -d' ' -f2)
        if [ -z "$first" ]; then
            echo "$pid $t" >>"$seen"
            continue
        fi
        if [ $((t - first)) -ge "$age" ] && ! grep -q "^$pid\$" "$dumped"; then
            dump "$pid" $((t - first))
            echo "$pid" >>"$dumped"
        fi
    done
    sleep 5
done
