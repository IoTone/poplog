#!/bin/sh
# test-json.sh — acceptance tests for LIB * JSON (pop/lib/lib/json.p).
#
#   tools/test-json.sh [/path/to/basepop11]
#
# Runs parse/generate/round-trip cases plus must-fail malformed inputs
# through the Poplog engine and reports PASS/FAIL per case.
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
# engine command: override with $1 (e.g. a nix-built pop11), else the local
# build run through the ./poplog env wrapper
if [ -n "$1" ]; then
    engine="$1"
else
    [ -x "$repo/target/pop/basepop11" ] || {
        echo "test-json: no target/pop/basepop11 (build first, or pass an engine)" >&2; exit 2; }
    engine="$repo/poplog $repo/target/pop/basepop11"
fi
# riscv64 Poplog must run with ASLR off (see PORTING-RISCV64-LINUX.md)
case "$(uname -m)" in
    riscv64) engine="setarch -R $engine" ;;
esac

tmp="${TMPDIR:-/tmp}/test-json.$$.p"
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<'EOF'
uses json;

vars failures = 0;

define check(name, got, want);
    if got = want then
        'PASS ' >< name =>
    else
        'FAIL ' >< name =>
        got =>
        want =>
        failures + 1 -> failures;
    endif;
enddefine;

;;; run p; true if it mishaps (partial parse junk cleared off the stack)
vars trapped;
define mishaps(p);
    lvars sl = stacklength();
    false -> trapped;
    dlocal prmishap = procedure(m, c); true -> trapped; exitto(mishaps) endprocedure;
    p();
    setstacklength(sl);
    trapped
enddefine;

;;; --- scalars ---
check('integer', json_parse('42'), 42);
check('negative zero-frac', json_parse('-0.5e2'), -50.0);
check('big integer', json_parse('123456789012345678901234567890'),
      123456789012345678901234567890);
check('string', json_parse('"hi"'), 'hi');
check('true', json_parse('true'), true);
check('false', json_parse('false'), false);
check('null', json_parse('null'), json_null);
check('whitespace', json_parse('  \s\t 7 \s'), 7);

;;; --- structures ---
check('array', json_parse('[1,2,3]'), {1 2 3});
check('empty array', json_parse('[]'), {});
check('nested array', json_parse('[[1],[2,[3]]]'), {{1} {2 {3}}});
check('nested array2', json_parse('[[1],[2,[3]]]')(2)(2)(1), 3);
vars obj;
json_parse('{"a": 1, "b": [true, null]}') -> obj;
check('object member', obj('a'), 1);
check('object nested', obj('b')(2), json_null);
check('empty object keys', mishaps(procedure; json_parse('{}')('x').erase endprocedure), false);

;;; --- ordered objects ---
;;; json_object keeps insertion order on output; a property does not
vars oo = json_object();
3 -> oo('zeta'); 1 -> oo('alpha'); json_null -> oo('mid'); 2 -> oo('alpha');
check('ordered object order', json_generate(oo), '{"zeta":3,"alpha":2,"mid":null}');
check('ordered object lookup', oo('alpha'), 2);
check('ordered object absent key', oo('nope'), false);
check('ordered object is not a property', isproperty(oo), false);
check('isjson_object', isjson_object(oo), true);
vars seen = [];
json_object_app(oo, procedure(k, v); [^^seen ^k] -> seen endprocedure);
check('json_object_app in order', seen, ['zeta' 'alpha' 'mid']);
check('parse still gives properties', isproperty(json_parse('{"a":1}')), true);
true -> json_ordered_objects;
check('ordered parse round trip',
      json_generate(json_parse('{"z":1,"a":{"y":2,"b":[{"k2":1,"k1":2}]}}')),
      '{"z":1,"a":{"y":2,"b":[{"k2":1,"k1":2}]}}');
check('ordered parse duplicate keeps first place, last value',
      json_generate(json_parse('{"a":1,"b":2,"a":3}')), '{"a":3,"b":2}');
false -> json_ordered_objects;

;;; --- strings and escapes ---
check('escapes', json_parse('"a\\nb\\tc\\"d\\\\e"'),
      consstring(`a`, 10, `b`, 9, `c`, `"`, `d`, `\\`, `e`, 9));
check('unicode bmp', json_parse('"\\u0041"'), 'A');
check('unicode 2byte', json_parse('"\\u00e9"'), consstring(16:C3, 16:A9, 2));
check('surrogate pair', json_parse('"\\ud834\\udd1e"'),
      consstring(16:F0, 16:9D, 16:84, 16:9E, 4));
check('solidus escape', json_parse('"\\/"'), '/');

;;; --- generation and round trip ---
check('gen scalar', json_generate(42), '42');
check('gen string esc', json_generate('a\nb'), '"a\\nb"');
check('gen ctrl u', json_generate(consstring(1, 1)), '"\\u0001"');
check('gen array', json_generate({1 2 3}), '[1,2,3]');
check('gen list', json_generate([1 [2] 3]), '[1,[2],3]');
check('gen null/bool', json_generate({% true, false, json_null %}),
      '[true,false,null]');
check('round trip', json_parse(json_generate(obj))('b')(1), true);
check('round trip str',
      json_generate(json_parse('{"k":[1,2.5,"x",null]}')),
      '{"k":[1,2.5,"x",null]}');

;;; --- must fail ---
define badcase(name, s);
    check('reject ' >< name,
          mishaps(procedure; json_parse(s).erase endprocedure), true);
enddefine;
badcase('empty input', '');
badcase('unterminated string', '"abc');
badcase('leading zero', '01');
badcase('bare dot', '1.');
badcase('bare exponent', '1e');
badcase('truncated token', 'tru');
badcase('trailing comma array', '[1,]');
badcase('trailing comma object', '{"a":1,}');
badcase('trailing garbage', '[1] x');
badcase('unquoted key', '{a:1}');
badcase('raw control char', consstring(`"`, 9, `"`, 3));
badcase('lone low surrogate', '"\\udd1e"');
badcase('lone high surrogate', '"\\ud834x"');
badcase('bad escape', '"\\q"');
badcase('missing colon', '{"a" 1}');

if failures == 0 then
    'SUMMARY: ALL PASS' =>
else
    'SUMMARY: ' >< failures >< ' FAILURES' =>
endif;
EOF

# shellcheck disable=SC2086  # $engine may be "wrapper binary"
out="$($engine "$tmp" 2>&1)" || true
echo "$out" | grep -E '^\*\* (PASS|FAIL|SUMMARY)' | sed 's/^\*\* //'
echo "$out" | grep -q 'SUMMARY: ALL PASS'
