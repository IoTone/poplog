# Every socket option addressed the wrong option on Linux

**Status:** fixed (2026-08-18).
**Found:** adding `SO_REUSEADDR` to `jsonrpc_listen`; the macOS tests
passed and the same code failed on `red5buntu` (Linux x86_64).
**Affects:** all Linux architectures. Not macOS or the BSDs, whose
numbering the code already had.

## Symptom

```
;;; MISHAP - ERROR SETTING SOCKET OPTION (Protocol not available)
;;; INVOLVING:  <device 'socket'> 4
;;; DOING    :  jsonrpc_listen
```

`4` is `SO_REUSEADDR` in `pop/lib/include/unix_sockets.ph`. That is the
4.4BSD value. On Linux, `SO_REUSEADDR` is `2` and `4` is `SO_ERROR`,
which is read-only — hence `ENOPROTOOPT`.

## Scope

It was not one constant. The whole `SO_*` block was 4.4BSD's numbering
with no Linux branch, so on Linux:

| Name in Poplog | Value | What Linux does with that number |
| --- | --- | --- |
| `SO_REUSEADDR` | 4 | `SO_ERROR` (read-only) |
| `SO_KEEPALIVE` | 8 | `SO_RCVBUF` |
| `SO_DONTROUTE` | 16 | — |
| `SO_BROADCAST` | 32 | — |
| `SO_LINGER` | 128 | — |

and `SOL_SOCKET`, the *level* argument, was hard-coded `16:FFFF` in
`pop/lib/lib/unix_sockets.p:129`; on Linux it is `1`. With the level
wrong, every `sys_socket_option` call fails whatever the option number,
which is the one mercy here: nothing was quietly setting the wrong
option, it was all failing loudly. Anyone who tried would have
concluded socket options simply did not work.

Nothing in the tree used `sys_socket_option` before `jsonrpc.p`, which
is presumably why this survived however many years of the Linux port.

## Fix

A `#_IF DEF LINUX` branch in `pop/lib/include/unix_sockets.ph` with the
values from `asm-generic/socket.h`, and the same treatment for
`SOL_SOCKET` in `unix_sockets.p`. Verified on x86_64 and riscv64, which
share those values; the architectures that do not (mips, sparc, parisc)
are not targets here and would need their own branch.

`SO_USELOOPBACK` and `SO_PROTOTYPE` have no Linux equivalent. They are
defined as `-1` rather than left undefined, so code mentioning them
still compiles and the kernel rejects the call loudly instead of a real
option's number being honoured by mistake.

`jsonrpc_listen` also stopped treating the option as required: it is a
nicety that avoids a `TIME_WAIT` wait on restart, and a platform whose
numbering nobody has enumerated should still get its listener.

## How it was nearly missed

The macOS test suite was green, and the change looked local. It was
found by running `tools/test-libs.sh` on the Linux CI host before
pushing — which is the only reason the numbers above are known rather
than assumed. Sockets are exactly the area where "it passed here" means
least: this is the third Darwin/Linux divergence in this tree after the
4.4BSD `sockaddr` layouts (dev `2187c83`) and
`docs/bugs/darwin-connect-retry.md`.
