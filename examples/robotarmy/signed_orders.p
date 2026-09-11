/* examples/robotarmy/signed_orders.p -- orders a robot can trust.

   A unit in the field must not obey an order just because it arrived.
   The command post signs each order with an HMAC under a key the unit
   shares; the unit recomputes the MAC and refuses anything that does
   not match.  LIB CRYPTO reaches OpenSSL through a small C shim --
   build it once with tools/build-popcrypto.sh.

       ./poplog basepop11 examples/robotarmy/signed_orders.p </dev/null
*/
uses crypto;

vars fleet_key = 'a shared secret, provisioned at enlistment';

;;; wire format:  <hex mac> <space> <order text>
define sign_order(text) -> wire;
    crypto_hmac_hex('sha256', fleet_key, text) <> ' ' <> text -> wire
enddefine;

define verify_order(wire) -> text;
    lvars sp = locchar(` `, 1, wire), mac, body;
    false -> text;
    if sp then
        substring(1, sp - 1, wire) -> mac;
        allbutfirst(sp, wire) -> body;
        if mac = crypto_hmac_hex('sha256', fleet_key, body) then
            body -> text
        endif
    endif
enddefine;

vars wire = sign_order('unit r1 advance to ridge');
npr('on the wire: ' sys_>< wire);
npr('genuine:     ' sys_>< verify_order(wire));

;;; an adversary changes one character of the order
vars forged = copy(wire);
`b` -> forged(length(forged));            ;;; ridge -> ridgb
npr('tampered:    ' sys_>< verify_order(forged));

;;; ...or replays a real signature on a different order
vars replay = substring(1, 64, wire) <> ' unit r1 advance to cliff';
npr('replayed:    ' sys_>< verify_order(replay));
