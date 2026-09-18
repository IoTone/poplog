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
define net_send(sock, host, port, msg);
    if length(msg) > NET_MTU then
        mishap(length(msg), 1, 'net_send: payload exceeds NET_MTU -- chunk it')
    endif;
    sys_socket_send(sock, msg, length(msg), 0, [^host ^port]);
enddefine;

;;; Blocking receive -> (payload, sender)
define net_recv(sock) -> (msg, sender);
    lvars buf = inits(NET_MTU + 300), n;
    sys_socket_recv(sock, buf, length(buf), 0, true) -> (n, sender);
    substring(1, n, buf) -> msg;
enddefine;

;;; Non-blocking: (false, false) when nothing is waiting
define net_poll(sock) -> (msg, sender);
    if sys_input_waiting(sock) then
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
