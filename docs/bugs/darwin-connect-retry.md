# `do_connect` does not retry a refused connection on Darwin

**Status:** open, worked around.
**Found:** 2026-08-18, building the swank server (`pop/lib/lib/swank.p`).
**Affects:** macOS/arm64. Not checked on Linux, where the code appears to
work as documented.

## Symptom

`sys_socket_peername` is documented to retry a connection refused by the
peer, closing and remaking the socket each time, at one-second intervals
— five times by default, and settable:

```pop11
['localhost' 14999] -> sys_socket_peername(sock, 12);
```

On macOS the call fails immediately whatever the count. Timed against a
port with nothing listening:

```
default(5): 0s
explicit 3: 0s
explicit 12: 0s
```

and each raises

```
;;; MISHAP - CAN'T ASSIGN SOCKET PEERNAME (Connection refused)
;;; DOING    :  do_connect ...
```

## Repro

```pop11
uses jsonrpc;
define t(p);
    dlocal interrupt = procedure(); exitfrom(t) endprocedure;
    dlocal cucharerr = erase;
    p();
enddefine;
define timed(label, p);
    lvars t0 = sys_real_time();
    t(p);
    npr(label >< ': ' >< (sys_real_time() - t0) >< 's');
enddefine;
timed('explicit 12',
      procedure();
          jsonrpc_connect_n('localhost', 14999, "header", 12) -> ;
      endprocedure);
```

Expected roughly 12s; observed 0s.

## Where it goes wrong

`do_connect` (`pop/lib/lib/unix_sockets.p:483`) reaches the retry only
through

```pop11
;;; come here for (genuine) error
quitunless(ERRNO == ECONNREFUSED);
```

and the mishap text seen is the literal one from the `conn_retries == 0`
branch a few lines below, which is indistinguishable from the `%M`-
expanded message raised when that `quitunless` falls through — both read
`CAN'T ASSIGN SOCKET PEERNAME (Connection refused)`. So the branch taken
is not obvious from the message alone.

`ECONNREFUSED` itself is **not** the problem: `pop/lib/include/unix_errno.ph`
resolves to 61 on this platform, which is correct for Darwin (verified
against Python's `errno.ECONNREFUSED`). The likelier culprit is `ERRNO`
not reflecting the failed `U_connect` by the time it is read — the inner
loop runs `Sys_fd_open_check` in between — but this has not been
confirmed. Confirming it needs a traced build of `unix_sockets.p`, which
is why it is written down rather than fixed: the change would be in the
error path of a shipped library that nothing else exercises.

This is the same family as the Darwin socket bugs fixed in dev `2187c83`
(4.4BSD `sockaddr` layouts, and the separate lib-level `sysdefs.ph`).

## Workaround

`jsonrpc_connect_wait(HOST, PORT, FRAMING, SECS)` in `LIB * JSONRPC`
polls itself and returns `false` instead of mishapping. Every client in
this tree uses it, and it is what `tools/tests/test_swank.p` waits on
while the server it launched finishes starting. A failed attempt costs
nothing — that is the one silver lining of the bug.

## If you fix it

The retry is still worth having: `jsonrpc_connect_wait` reimplements at
the Pop-11 level something the C-level code is meant to do, and its
`syssleep(10)` polling interval is a guess. Keep the wrapper regardless
— returning `false` rather than raising is the better interface for a
client — but it could then stop polling.
