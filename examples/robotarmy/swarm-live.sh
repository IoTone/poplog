#!/bin/sh
# swarm-live.sh -- run the Kuramoto swarm across real machines, live.
#
# Two robots per machine, plus a passive watcher on this host that draws the
# fleet as it runs.  The watcher only listens: robots copy their phase to it
# and it never replies, so it cannot perturb what it is measuring.
#
#   ./swarm-live.sh
#
# Environment:
#   NODES    "ssh-target:remote-dir:tailnet-ip" per machine, space separated.
#            Use "-" as the ssh target for this machine.
#   WATCH_IP this host's address as the other machines see it.
#   SWARM_TICK / SWARM_STEPS / SWARM_K  passed through to every robot.
#
# The tick matters: a robot couples to the phases it has received, so if the
# link RTT exceeds the tick, remote phases arrive stale and the fleet locks
# per-machine instead of globally.  Compare SWARM_TICK=20 with SWARM_TICK=100
# on a link with ~30 ms RTT and you can watch the clusters merge.

set -e

NODES=${NODES:-"-:.:100.101.120.20 red5buntu:poplog-ci:100.70.154.54 dietpi@dietpi:poplog-ci:100.75.79.61"}
WATCH_IP=${WATCH_IP:-100.101.120.20}
WATCH_PORT=${WATCH_PORT:-9940}
SWARM_TICK=${SWARM_TICK:-100}
SWARM_STEPS=${SWARM_STEPS:-600}
SWARM_K=${SWARM_K:-2.2}

# Robot i lives on node (i mod nodecount), so ids interleave across machines
# and any clustering that shows up is the network, not the numbering.
nodecount=$(echo $NODES | wc -w | tr -d ' ')
total=$((nodecount * 2))

hosts=""
i=0
while [ $i -lt $total ]; do
    ip=$(echo $NODES | cut -d' ' -f$(( (i % nodecount) + 1 )) | cut -d: -f3)
    hosts="${hosts:+$hosts,}$ip"
    i=$((i + 1))
done

echo "fleet of $total robots over $nodecount machines"
echo "  peers : $hosts"
echo "  tick  : ${SWARM_TICK}ms   steps: $SWARM_STEPS   K: $SWARM_K"
echo "  watch : $WATCH_IP:$WATCH_PORT"
echo

env="SWARM_TICK=$SWARM_TICK SWARM_STEPS=$SWARM_STEPS SWARM_K=$SWARM_K"
i=0
while [ $i -lt $total ]; do
    node=$(echo $NODES | cut -d' ' -f$(( (i % nodecount) + 1 )))
    target=$(echo $node | cut -d: -f1)
    dir=$(echo $node | cut -d: -f2)
    cmd="cd $dir && $env ./poplog basepop11 examples/robotarmy/swarm.p \
         $i $total $hosts $WATCH_IP:$WATCH_PORT"
    if [ "$target" = "-" ]; then
        sh -c "$cmd" </dev/null >/tmp/swarm-live-$i.out 2>&1 &
    else
        ssh -o ConnectTimeout=20 "$target" \
            "nohup sh -c '$cmd' >/tmp/swarm-live-$i.out 2>&1 </dev/null &" \
            </dev/null >/dev/null 2>&1 &
    fi
    echo "  robot $i -> $target"
    i=$((i + 1))
done

sleep 2
echo
exec ./poplog basepop11 examples/robotarmy/swarm.p --watch $total $WATCH_PORT
