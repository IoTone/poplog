# `sys_input_waiting` is blind on datagram sockets

**Severity:** high — silent wrong answers, no error, no crash
**Found:** 2026-09-18, while trying to verify cross-machine swarm entrainment
**Affects:** any non-blocking read loop over `sys_socket` built on `sys_input_waiting`

## Symptom

```pop11
lvars a = sys_socket(`i`,`D`,false);
[* 9971] -> sys_socket_name(a);
;;; ... another socket sends us a datagram, and it has arrived ...
sys_input_waiting(a) =>        ;;; ** <false>
sys_socket_recv(a, buf, 64, 0, true) -> (n, snd);
substring(1,n,buf) =>          ;;; ** 'hello'   <-- it was there all along
```

`sys_input_waiting` answers `false` forever on a datagram socket, even with a
datagram queued that a blocking `recv` returns immediately.

## Why it is nastier than a crash

`net_poll` was built on it:

```pop11
define net_poll(sock) -> (msg, sender);
    if sys_input_waiting(sock) then net_recv(sock) -> (msg, sender)
    else false -> msg; false -> sender endif
enddefine;
```

Every poll said "nothing arrived". No error was raised — a poll returning
nothing is exactly what a poll is *supposed* to do when the network is quiet.
`swarm.p` coupled its oscillators on received phases:

```pop11
if seen > 0 then phase + (K / seen) * sum * DT -> phase endif;
```

`seen` was always 0, so the coupling term never once fired and every robot
free-ran at its own `omega`. The program still produced a plausible history
file, still rendered, and the order parameter still *rose* — four independent
oscillators drift past each other and the measure momentarily read 0.911.

The result was reported as entrainment. It was arithmetic:

| id | free-running `(id*1.7 + omega*12.0) mod 2pi` | "measured" |
|----|----------------------------------------------|------------|
| 0  | 11.95 mod 2pi = 5.72                         | 5.72       |
| 1  | 17.90 mod 2pi = 5.33                         | 5.33       |
| 2  | 23.80 mod 2pi = 4.95                         | 4.95       |
| 3  | 29.70 mod 2pi = 4.57                         | 4.57       |

The tell was that a run across two machines reproduced the single-machine run
byte for byte. Real coupling over a 34 ms jittered link cannot match loopback
to the last digit; identical output meant *no* output depended on the network.

## Fix

`sys_device_wait` is Poplog's `select(2)`, and `pop/ref/sockets` line 64 says
so explicitly. It is correct in all three states — empty, queued, drained:

```pop11
define net_ready(sock) -> yes;
    lvars rd;
    sys_device_wait([^sock], [], [], 0) -> (rd, , );
    rd /== [] -> yes;
enddefine;
```

After the fix each robot heard 717 peer messages over 240 ticks (3 peers x 239)
instead of 0, and the order parameter went 0.10 -> 0.99 *and stayed there*,
which is what phase locking actually looks like.

## The lesson, and the missing test

A silent poll is untestable by observing that the program runs. The test that
would have caught this asserts on the *traffic*, not the output: count received
messages and require the count to be non-zero. `swarm.p` now reports

    robot 0 done -- heard 717 peer messages over 240 ticks, 0 sends dropped

so a future regression to a blind poll is visible in one line. This is the same
failure family as `docs/bugs/random-int-64bit.md`: a broken primitive that
returns *a* value rather than an error, checked by a test that only asked
whether anything came back.

## Related

- `docs/bugs/sys-socket-send-returns-nothing.md` — the other `sys_socket_*`
  contract trap in this layer.
