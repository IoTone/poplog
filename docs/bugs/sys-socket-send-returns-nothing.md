# sys_socket_send returns nothing, and the mishap lands somewhere else

Found 2026-09-17 while building the Robot Army UDP transport.
**Not a bug in the library — an API asymmetry with a badly misleading
failure mode.**  Worth knowing before anyone else loses an hour to it.

## The asymmetry

`LIB * UNIX_SOCKETS` (`pop/lib/lib/unix_sockets.p`):

| procedure | leaves on the stack |
| --- | --- |
| `sys_socket_recv(sock, buff, nbytes, flags, want_fromname)` | the byte count, and the sender's name if `want_fromname` |
| **`sys_socket_send(sock, buff, nbytes, flags, toname)`** | **nothing** |

`sys_socket_send` ends with `if toname then sys_grbg_fixed(namebuf) endif`;
the `sendto` result is consumed into `res` and never left.  So the natural
symmetric spelling is wrong:

```pop11
vars r = sys_socket_send(s, msg, length(msg), 0, ['127.0.0.1' 9500]);   ;;; WRONG
sys_socket_send(s, msg, length(msg), 0, ['127.0.0.1' 9500]);            ;;; right
```

## Why it costs an hour

The `-> r` underflows the open stack, and nothing complains there.  The
mishap surfaces **in the compiler, on a later line, pointing at an innocent
string constant**:

```
;;; MISHAP - BAD SUBSCRIPT FOR INDEXED STACK ACCESS
;;; INVOLVING:  1
;;;   LINE NUMBER:  8            <- `npr('sent');`, which is fine
;;; DOING    :  subscr_stack read_strcon read_string null nextitem
```

Line 8 is a plain `npr('sent')`.  The real culprit is line 7.  Under other
orderings the same underflow shows up as a bare `[fatal] sig=11` from the
Darwin runtime with no Pop-11 diagnostic at all, which sends you hunting
for a sockets or FFI bug that is not there.

Both symptoms are the open stack doing exactly what it is documented to do
— a procedure leaving fewer results than the caller takes is not an error
until something else notices — but the distance between cause and report is
the worst this codebase has produced.

## Checking any FFI-ish procedure's arity

The definition is the authority; `pdnargs` gives the inputs but not the
outputs.  Read the tail of the `define`: a procedure with no `-> result` in
its header and no bare expression at the end returns nothing.

## Related

Same family as the traps in `examples/microgpt/README.md`: the failure is
real, silent at the point of the mistake, and reported somewhere
misleading.
