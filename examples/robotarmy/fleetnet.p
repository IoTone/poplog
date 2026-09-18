/* examples/robotarmy/fleetnet.p -- the fleet's UDP transport.

   Datagrams between robots, signed so that a robot will only act on --
   or compile -- a message from its own chain of command.  Everything in
   examples/robotarmy/ that crosses a network sits on this.

       vars robotarmy_lib = true;
       load 'examples/robotarmy/fleetnet.p';
       vars s = net_open(9500);
       net_send(s, '100.70.154.54', 9500, net_sign('unit r1 advance to ridge'));

   Measured on the tailnet this was built against: interface MTU 1380, so
   1200 is the largest payload that is safe without fragmenting (a 1372-byte
   don't-fragment ping is already dropped).  Bigger messages must be chunked
   by the caller.
*/
uses unix_sockets;
uses crypto;

lconstant NET_MTU = 1200;       ;;; max payload; see the note above

;;; The shared secret every robot is issued at enlistment.  Override it
;;; before sending anything real.
vars fleet_key = 'a shared secret, provisioned at enlistment';

;;; ------------------------------------------------------------- transport

define net_open(port) -> sock;
    sys_socket(`i`, `D`, false) -> sock;
    [* ^port] -> sys_socket_name(sock);
enddefine;

;;; TRAP: sys_socket_send leaves NOTHING on the stack, unlike
;;; sys_socket_recv which leaves a count (and the sender).  Writing the
;;; symmetric-looking `vars r = sys_socket_send(...)` underflows the open
;;; stack and the mishap surfaces in the COMPILER, lines later, pointing at
;;; an innocent string.  See docs/bugs/sys-socket-send-returns-nothing.md.
;;; A datagram send is best-effort by definition, and the kernel reports
;;; some failures late and on the wrong call -- an ICMP error provoked by
;;; one peer surfaces as a mishap on a send to a different one.  On Linux we
;;; see an intermittent EPERM ("Operation not permitted") when the whole
;;; fleet starts at the same instant; staggering the launch by a second
;;; makes it vanish.  The kernel-side cause is not isolated, so we treat it
;;; the way UDP asks to be treated: a failed send is a dropped datagram, not
;;; a dead robot.  Programming errors (an over-MTU payload) still mishap.
vars net_send_errors = 0;

define net_send(sock, host, port, msg);
    if length(msg) > NET_MTU then
        mishap(length(msg), 1, 'net_send: payload exceeds NET_MTU -- chunk it')
    endif;
    procedure;
        dlocal interrupt =
            procedure;
                net_send_errors + 1 -> net_send_errors;
                exitfrom(net_send);
            endprocedure;
        sys_socket_send(sock, msg, length(msg), 0, [^host ^port]);
    endprocedure();
enddefine;

;;; Blocking receive -> (payload, sender)
define net_recv(sock) -> (msg, sender);
    lvars buf = inits(NET_MTU + 300), n;
    sys_socket_recv(sock, buf, length(buf), 0, true) -> (n, sender);
    substring(1, n, buf) -> msg;
enddefine;

;;; Non-blocking: (false, false) when nothing is waiting
;;; TRAP: sys_input_waiting() answers false forever on a datagram socket,
;;; even with a datagram sitting in it that a blocking recv returns at once.
;;; A poll built on it is silently deaf: every read says "nothing arrived",
;;; so a loop that couples on received messages simply never couples and
;;; still produces plausible-looking output.  sys_device_wait is select(2)
;;; and is what pop/ref/sockets tells you to use.  See
;;; docs/bugs/sys-input-waiting-blind-on-sockets.md.
define net_ready(sock) -> yes;
    lvars rd;
    sys_device_wait([^sock], [], [], 0) -> (rd, , );
    rd /== [] -> yes;
enddefine;

define net_poll(sock) -> (msg, sender);
    if net_ready(sock) then
        net_recv(sock) -> (msg, sender)
    else
        false -> msg; false -> sender
    endif
enddefine;

;;; --------------------------------------------------------------- signing
;;; Wire format:  <64 hex chars of HMAC-SHA256><space><payload>
;;; A robot that cannot verify a datagram MUST NOT act on it -- and above
;;; all must not compile it.

define net_sign(text) -> wire;
    crypto_hmac_hex('sha256', fleet_key, text) <> ' ' <> text -> wire
enddefine;

define net_verify(wire) -> text;
    lvars sp = locchar(` `, 1, wire), mac, body;
    false -> text;
    if sp and sp == 65 then
        substring(1, 64, wire) -> mac;
        allbutfirst(sp, wire) -> body;
        if mac = crypto_hmac_hex('sha256', fleet_key, body) then body -> text endif
    endif
enddefine;

;;; Receive and verify in one step: false unless it is genuinely ours.
define net_recv_signed(sock) -> (text, sender);
    lvars wire;
    net_recv(sock) -> (wire, sender);
    net_verify(wire) -> text;
enddefine;

define net_poll_signed(sock) -> (text, sender);
    lvars wire;
    net_poll(sock) -> (wire, sender);
    if wire then net_verify(wire) -> text else false -> text endif
enddefine;

;;; -------------------------------------------------------------- chunking
;;; Forth words fit in one datagram; Pop-11 source generally does not.  A
;;; long message goes out as numbered chunks, each one signed in its own
;;; right -- so an attacker cannot slip an extra chunk into a message whose
;;; other parts are genuine.  Chunks are reassembled per (sender, id).
;;;
;;;     wire:  <id>:<seq>:<total>:<payload>   then signed

lconstant NET_CHUNK = 1000;     ;;; leaves room for signature + header

vars net_msgid = 0;             ;;; per-process message counter
vars net_partial = newmapping([], 32, false, true);

define net_send_big(sock, host, port, text);
    lvars len = length(text), total, i, seq = 0, chunk, hdr;
    net_msgid + 1 -> net_msgid;
    ((len + NET_CHUNK - 1) div NET_CHUNK) -> total;
    if total == 0 then 1 -> total endif;
    for i from 1 by NET_CHUNK to max(len, 1) do
        seq + 1 -> seq;
        substring(i, min(NET_CHUNK, len - i + 1), text) -> chunk;
        '' sys_>< net_msgid sys_>< ':' sys_>< seq sys_>< ':'
           sys_>< total sys_>< ':' sys_>< chunk -> hdr;
        net_send(sock, host, port, net_sign(hdr));
    endfor;
enddefine;

;;; Split "id:seq:total:payload" -> (id, seq, total, payload)
define net_unpack(s) -> (id, seq, total, payload);
    lvars a = locchar(`:`, 1, s), b, c;
    locchar(`:`, a + 1, s) -> b;
    locchar(`:`, b + 1, s) -> c;
    substring(1, a - 1, s) -> id;
    strnumber(substring(a + 1, b - a - 1, s)) -> seq;
    strnumber(substring(b + 1, c - b - 1, s)) -> total;
    allbutfirst(c, s) -> payload;
enddefine;

;;; Receive one datagram; return the whole message once its last chunk
;;; arrives, else (false, sender).  Unverifiable datagrams are dropped.
define net_collect(sock) -> (text, sender);
    lvars wire, body, id, seq, total, payload, key, slots, i;
    false -> text;
    net_recv(sock) -> (wire, sender);
    net_verify(wire) -> body;
    returnunless(body);
    net_unpack(body) -> (id, seq, total, payload);
    consword(hd(sender) sys_>< '/' sys_>< id) -> key;
    net_partial(key) -> slots;
    unless slots then initv(total) ->> slots -> net_partial(key) endunless;
    payload -> subscrv(seq, slots);
    ;;; complete?
    for i from 1 to total do returnunless(isstring(subscrv(i, slots))) endfor;
    '' -> text;
    for i from 1 to total do text <> subscrv(i, slots) -> text endfor;
    false -> net_partial(key);
enddefine;
