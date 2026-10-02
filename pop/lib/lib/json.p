/* --- JSON for Poplog ----------------------------------------------------
 > File:            pop/lib/lib/json.p
 > Purpose:         Parse and generate JSON (RFC 8259) in pure Pop-11
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   HELP * JSON,  TEACH * JSON (built as a worked example
 >                  of writing a new Poplog library)
 > Related Files:   tools/test-json.sh
 >
 > Data mapping (see TEACH JSON for the reasoning):
 >   object   <->  property (equality-based, via newmapping)
 >   array    <->  vector          (lists also accepted on output)
 >   string   <->  string          (UTF-8 bytes; \uXXXX decoded to UTF-8)
 >   number   <->  integer/bigint or ddecimal
 >   true     <->  true
 >   false    <->  false
 >   null     <->  json_null       (a distinct constant; false is taken)
 */
compile_mode :pop11 +strict;

section $-json => json_null json_parse json_generate json_print
                  json_object isjson_object json_object_app json_ordered_objects;

;;; JSON null must be distinguishable from JSON false, so it cannot map
;;; to <false>; a word compares by identity and prints readably.
constant json_null = "json_null";

;;; --- ordered objects ---------------------------------------------------
;;; A property is a hash table, so an object built from one is written in
;;; hash order.  RFC 8259 promises no order, and usually nothing cares --
;;; but some receivers read meaning into it.  A list of options shown to a
;;; model in a different order is a different question, and can get a
;;; different answer.
;;;
;;; json_object() remembers insertion order.  It is applied like a
;;; property -- obj(key) and val -> obj(key) -- so code that builds an
;;; object changes only its constructor.  Lookup is linear, which is the
;;; right trade for the small objects where order matters.

defclass lconstant jsonobj {jo_pairs};      ;;; [key|val] pairs, oldest first

define lconstant jo_find(key, obj);
    lvars p;
    for p in jo_pairs(obj) do
        if front(p) = key then return(p) endif;
    endfor;
    false
enddefine;

;;; an absent key gives false, as it does for a newmapping
define lconstant jo_get(key, obj);
    lvars p = jo_find(key, obj);
    if p then back(p) else false endif
enddefine;

;;; assigning to an existing key keeps its position; duplicate keys in
;;; parsed input therefore keep the first position and the last value
define updaterof jo_get(val, key, obj);
    lvars p = jo_find(key, obj);
    if p then
        val -> back(p)
    else
        jo_pairs(obj) <> [% conspair(key, val) %] -> jo_pairs(obj)
    endif;
enddefine;

jo_get -> class_apply(jsonobj_key);

define json_object() -> obj;
    consjsonobj([]) -> obj;
enddefine;

define isjson_object(x);
    isjsonobj(x)
enddefine;

;;; PROC(key, val) for each member: insertion order for a json_object,
;;; hash order for a property -- so a reader need not care which it got
define json_object_app(obj, proc);
    lvars p;
    if isjsonobj(obj) then
        for p in jo_pairs(obj) do proc(front(p), back(p)) endfor
    else
        appproperty(obj, proc)
    endif;
enddefine;

;;; true: json_parse builds json_objects, so a parse-then-generate round
;;; trip keeps member order.  Off by default because existing callers
;;; test isproperty() on what json_parse returns.
vars json_ordered_objects = false;

;;; parser state, dynamically localised by json_parse so the parser is
;;; re-entrant and resets on abnormal exit
vars jstr, jpos, jlen;

define lconstant jerror(msg);
    mishap(jpos, 1, 'json_parse: ' <> msg)
enddefine;

define lconstant cur();         ;;; current char, or -1 at end of input
    if jpos > jlen then -1 else subscrs(jpos, jstr) endif
enddefine;

define lconstant advance();
    jpos + 1 -> jpos
enddefine;

define lconstant skipwhite();
    lvars c;
    while jpos <= jlen do
        subscrs(jpos, jstr) -> c;
        quitunless(c == `\s` or c == `\t` or c == `\n` or c == `\r`);
        advance();
    endwhile;
enddefine;

define lconstant digit(c);
    c >= `0` and c <= `9`
enddefine;

define lconstant hexval(c) -> v;
    if digit(c) then c - `0` -> v
    elseif c >= `a` and c <= `f` then c - `a` + 10 -> v
    elseif c >= `A` and c <= `F` then c - `A` + 10 -> v
    else jerror('bad hex digit in \\u escape')
    endif
enddefine;

define lconstant parse_hex4() -> u;
    lvars i;
    0 -> u;
    for i from 1 to 4 do
        u * 16 + hexval(cur()) -> u;
        advance();
    endfor;
enddefine;

;;; push the UTF-8 encoding of a code point, returning how many bytes
define lconstant emit_utf8(code) -> n;
    if code < 16:80 then
        code; 1 -> n
    elseif code < 16:800 then
        16:C0 || (code << -6);  16:80 || (code && 16:3F); 2 -> n
    elseif code < 16:10000 then
        16:E0 || (code << -12); 16:80 || ((code << -6) && 16:3F);
        16:80 || (code && 16:3F); 3 -> n
    else
        16:F0 || (code << -18); 16:80 || ((code << -12) && 16:3F);
        16:80 || ((code << -6) && 16:3F); 16:80 || (code && 16:3F); 4 -> n
    endif
enddefine;

define lconstant parse_string() -> s;
    lvars c, u, u2, k, n = 0;
    advance();                          ;;; opening quote
    repeat
        cur() -> c;
        if c == -1 then jerror('unterminated string') endif;
        advance();
        if c == `"` then quitloop endif;
        if c == `\\` then
            cur() -> c; advance();
            if c == `"` or c == `\\` or c == `/` then
                c; n + 1 -> n
            elseif c == `b` then 8;  n + 1 -> n
            elseif c == `f` then 12; n + 1 -> n
            elseif c == `n` then 10; n + 1 -> n
            elseif c == `r` then 13; n + 1 -> n
            elseif c == `t` then 9;  n + 1 -> n
            elseif c == `u` then
                parse_hex4() -> u;
                if u >= 16:DC00 and u <= 16:DFFF then
                    jerror('unpaired low surrogate')
                elseif u >= 16:D800 and u <= 16:DBFF then
                    unless cur() == `\\` then jerror('unpaired surrogate') endunless;
                    advance();
                    unless cur() == `u` then jerror('unpaired surrogate') endunless;
                    advance();
                    parse_hex4() -> u2;
                    unless u2 >= 16:DC00 and u2 <= 16:DFFF then
                        jerror('bad low surrogate')
                    endunless;
                    16:10000 + ((u - 16:D800) << 10) + (u2 - 16:DC00) -> u;
                endif;
                ;;; pop the byte count *before* adding: emit_utf8 leaves its
                ;;; bytes on the stack, which must not sit between +'s operands
                emit_utf8(u) -> k;
                n + k -> n
            else
                jerror('bad escape in string')
            endif
        elseif c < 32 then
            jerror('raw control character in string')
        else
            c; n + 1 -> n
        endif;
    endrepeat;
    consstring(n) -> s;
enddefine;

define lconstant parse_number() -> num;
    lvars start = jpos;
    if cur() == `-` then advance() endif;
    if cur() == `0` then advance()              ;;; leading zero stands alone
    elseif digit(cur()) then
        while digit(cur()) do advance() endwhile
    else
        jerror('bad number')
    endif;
    if cur() == `.` then
        advance();
        unless digit(cur()) then jerror('digit needed after decimal point') endunless;
        while digit(cur()) do advance() endwhile;
    endif;
    if cur() == `e` or cur() == `E` then
        advance();
        if cur() == `+` or cur() == `-` then advance() endif;
        unless digit(cur()) then jerror('digit needed in exponent') endunless;
        while digit(cur()) do advance() endwhile;
    endif;
    unless strnumber(substring(start, jpos - start, jstr)) ->> num then
        jerror('bad number')
    endunless;
enddefine;

define lconstant parse_word(w);
    lvars i;
    for i from 1 to length(w) do
        unless cur() == subscrs(i, w) then jerror('bad token') endunless;
        advance();
    endfor;
enddefine;

lvars procedure jvalue;                 ;;; forward: mutual recursion below

define lconstant parse_array() -> arr;
    lvars n = 0;
    advance();                          ;;; [
    skipwhite();
    if cur() == `]` then
        advance();
        consvector(0) -> arr;
        return;
    endif;
    repeat
        jvalue(); n + 1 -> n;           ;;; value stays on the stack
        skipwhite();
        if cur() == `,` then advance()
        elseif cur() == `]` then advance(); quitloop
        else jerror('expected , or ] in array')
        endif;
    endrepeat;
    consvector(n) -> arr;
enddefine;

define lconstant parse_object() -> obj;
    lvars key, val;
    if json_ordered_objects then
        json_object() -> obj
    else
        newmapping([], 8, false, true) -> obj
    endif;
    advance();                          ;;; {
    skipwhite();
    if cur() == `}` then advance(); return endif;
    repeat
        skipwhite();
        unless cur() == `"` then jerror('expected string key in object') endunless;
        parse_string() -> key;
        skipwhite();
        unless cur() == `:` then jerror('expected : in object') endunless;
        advance();
        jvalue() -> val;
        val -> obj(key);
        skipwhite();
        if cur() == `,` then advance()
        elseif cur() == `}` then advance(); quitloop
        else jerror('expected , or } in object')
        endif;
    endrepeat;
enddefine;

define lconstant parse_value() -> val;
    lvars c;
    skipwhite();
    cur() -> c;
    if c == -1 then jerror('unexpected end of input')
    elseif c == `{` then parse_object() -> val
    elseif c == `[` then parse_array() -> val
    elseif c == `"` then parse_string() -> val
    elseif c == `t` then parse_word('true');  true -> val
    elseif c == `f` then parse_word('false'); false -> val
    elseif c == `n` then parse_word('null');  json_null -> val
    elseif c == `-` or digit(c) then parse_number() -> val
    else jerror('unexpected character')
    endif;
enddefine;

parse_value -> jvalue;

define json_parse(s) -> val;
    dlocal jstr, jpos, jlen;
    unless isstring(s) then
        mishap(s, 1, 'json_parse: string needed')
    endunless;
    s -> jstr; 1 -> jpos; length(s) -> jlen;
    parse_value() -> val;
    skipwhite();
    unless jpos > jlen then jerror('trailing characters after JSON value') endunless;
enddefine;


;;; --- generation --------------------------------------------------------

lconstant hexdigits = '0123456789abcdef';

lvars procedure jgen;                   ;;; forward: mutual recursion below

define lconstant genstring(s, out);
    lvars c, i;
    out(`"`);
    for i from 1 to length(s) do
        subscrs(i, s) -> c;
        if c == `"` then out(`\\`); out(`"`)
        elseif c == `\\` then out(`\\`); out(`\\`)
        elseif c == 8  then out(`\\`); out(`b`)
        elseif c == 12 then out(`\\`); out(`f`)
        elseif c == 10 then out(`\\`); out(`n`)
        elseif c == 13 then out(`\\`); out(`r`)
        elseif c == 9  then out(`\\`); out(`t`)
        elseif c < 32 then
            out(`\\`); out(`u`); out(`0`); out(`0`);
            out(subscrs((c << -4) + 1, hexdigits));
            out(subscrs((c && 15) + 1, hexdigits));
        else
            out(c)
        endif;
    endfor;
    out(`"`);
enddefine;

define lconstant genarray(v, out);
    lvars i;
    out(`[`);
    for i from 1 to length(v) do
        if i > 1 then out(`,`) endif;
        jgen(subscrv(i, v), out);
    endfor;
    out(`]`);
enddefine;

define lconstant genlist(l, out);
    lvars item, first = true;
    out(`[`);
    for item in l do
        unless first then out(`,`) endunless;
        false -> first;
        jgen(item, out);
    endfor;
    out(`]`);
enddefine;

define lconstant genobject(p, out);
    lvars first = true;
    out(`{`);
    json_object_app(p,
        procedure(key, val);
            unless first then out(`,`) endunless;
            false -> first;
            unless isstring(key) then
                mishap(key, 1, 'json_generate: object key must be a string')
            endunless;
            genstring(key, out);
            out(`:`);
            jgen(val, out);
        endprocedure);
    out(`}`);
enddefine;

define lconstant gen_value(x, out);
    if x == json_null then appdata('null', out)
    elseif x == true then appdata('true', out)
    elseif x == false then appdata('false', out)
    elseif isstring(x) then genstring(x, out)
    elseif isintegral(x) or isdecimal(x) then appdata(x sys_>< nullstring, out)
    elseif isvector(x) then genarray(x, out)
    elseif isproperty(x) or isjsonobj(x) then genobject(x, out)
    elseif ispair(x) or x == [] then genlist(x, out)
    else mishap(x, 1, 'json_generate: unsupported item')
    endif
enddefine;

gen_value -> jgen;

define json_print(x);
    gen_value(x, cucharout)
enddefine;

define json_generate(x) -> s;
    lvars n = 0;
    define lvars out(c);
        c; n + 1 -> n
    enddefine;
    gen_value(x, out);
    consstring(n) -> s;
enddefine;

endsection;
