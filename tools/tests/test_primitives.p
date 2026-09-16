;;; test_primitives.p — core VM/arithmetic primitives (run via tools/test-libs.sh)
;;;
;;; The layer below the libraries: the hand-written helpers in
;;; pop/src/<arch>/aarith.s and the Pop-11 they support.  Nothing else in
;;; the tree tests these, which is how a mis-ported _posword_mul_high shipped
;;; on two platforms (docs/bugs/random-int-64bit.md).
;;;
;;; The arithmetic answers below are known-answer vectors: they are
;;; architecture-independent, so any port that disagrees is wrong.  The
;;; random tests assert a DISTRIBUTION, which is the only kind of assertion
;;; that can tell a working generator from a constant one.
uses poptest;

;;; ---------------------------------------------------- integer / bigint
;;; exercises _pmult_testovf, _bgi_mult, _bgi_add, _bgi_div, _shift
check('int mult overflows to bigint', 12345678901234567890 * 98765432109876543210,
      1219326311370217952237463801111263526900);
check('bigint div exact', 1219326311370217952237463801111263526900 div 98765432109876543210,
      12345678901234567890);
check('bigint mod', (10 ** 30 + 7) mod 1000003, 999767);
check('bigint div', (10 ** 30 + 7) div 1000003, 999997000008999973000080);
check('negative product', -12345678901234567890 * 98765432109876543210,
      -1219326311370217952237463801111263526900);
check('2**63 boundary', 2 ** 63, 9223372036854775808);
check('2**64 boundary', 2 ** 64, 18446744073709551616);
check('2**64 - 1', 2 ** 64 - 1, 18446744073709551615);
check('3 * 2**62', 3 * (2 ** 62), 13835058055282163712);
check('shift past a word', 1 << 100, 1267650600228229401496703205376);
check('shift back', (1 << 100) >> 100, 1);
check('round trip through bigint', (2 ** 70) div (2 ** 35), 34359738368);

define lconstant fact(n);
    lvars i, r = 1;
    for i from 2 to n do r * i -> r endfor;
    r
enddefine;
check('factorial 25', fact(25), 15511210043330985984000000);
check('factorial 25 / 24', fact(25) div fact(24), 25);

;;; ---------------------------------------------------- random: range
;;; random0(n) must be in [0,n) and random(n) in [1,n].
define lconstant range_ok(n, lo, hi, want0) -> ok;
    lvars i, v;
    true -> ok;
    for i from 1 to 3000 do
        if want0 then random0(n) else random(n) endif -> v;
        unless isinteger(v) and v >= lo and v <= hi then false -> ok; return endunless;
    endfor;
enddefine;
check_true('random0(10) stays in 0..9',  range_ok(10, 0, 9, true));
check_true('random(10) stays in 1..10',  range_ok(10, 1, 10, false));
check_true('random(2) stays in 1..2',    range_ok(2, 1, 2, false));
check_true('random(1000) stays in range', range_ok(1000, 1, 1000, false));

;;; ---------------------------------------------------- random: not constant
;;; THE regression test for docs/bugs/random-int-64bit.md.  A generator stuck
;;; at one value passes every range check above; only this catches it.
;;; Missing a bucket in 2000 draws has probability (1-1/n)**2000 -- for n=10,
;;; about 1e-92 -- so this is not a flaky test.
define lconstant distinct_count(n, want0) -> k;
    lvars i, v, seen = newproperty([], min(4096, 2 * n + 8), false, true);
    0 -> k;
    for i from 1 to 2000 do
        if want0 then random0(n) else random(n) endif -> v;
        unless seen(v) then true -> seen(v); k + 1 -> k endunless;
    endfor;
enddefine;
check('random(10) yields all 10 values',   distinct_count(10, false), 10);
check('random0(10) yields all 10 values',  distinct_count(10, true),  10);
check('random(2) yields both values',      distinct_count(2, false),  2);
check('random(6) yields all 6 values',     distinct_count(6, false),  6);
check_true('random(1000) yields many values', distinct_count(1000, false) > 500);

;;; the small-integer path is taken below _SIMPLE_LIM (2**24) and the bigint
;;; path above it; both must work, and the boundary is where the bug hid
check_true('below 2**24 is not constant',  distinct_count(16777215, false) > 1900);
check_true('above 2**24 is not constant',  distinct_count(16777217, false) > 1900);

;;; ---------------------------------------------------- random: uniformity
;;; 6000 draws over 10 buckets: expect 600 each, sd ~23.  A +-200 band is
;;; over 8 sd, so this cannot flake, but it still catches gross skew.
define lconstant uniform_ok(n, draws, lo, hi) -> ok;
    lvars i, v, h = initv(n);
    for i from 1 to n do 0 -> subscrv(i, h) endfor;
    for i from 1 to draws do
        random(n) -> v;
        subscrv(v, h) + 1 -> subscrv(v, h);
    endfor;
    true -> ok;
    for i from 1 to n do
        unless subscrv(i, h) >= lo and subscrv(i, h) <= hi then false -> ok endunless
    endfor;
enddefine;
check_true('random(10) is roughly uniform', uniform_ok(10, 6000, 400, 800));

;;; float path (Float_random, a different code path from the integer one)
define lconstant float_mean(draws) -> m;
    lvars i, s = 0.0;
    for i from 1 to draws do random0(1.0) + s -> s endfor;
    s / draws -> m;
enddefine;
check_true('random0(1.0) has mean near 0.5',
           abs(float_mean(20000) - 0.5) < 0.02);

;;; ---------------------------------------------------- library consumers
;;; These are what users actually call, and both were silently constant.
define lconstant oneof_distinct() -> k;
    lvars i, seen = newproperty([], 16, false, true);
    0 -> k;
    for i from 1 to 500 do
        lvars v = oneof([a b c d e]);
        unless seen(v) then true -> seen(v); k + 1 -> k endunless
    endfor;
enddefine;
check('oneof reaches every element', oneof_distinct(), 5);

define lconstant shuffle_distinct() -> k;
    lvars i, seen = newproperty([], 16, false, true);
    0 -> k;
    for i from 1 to 300 do
        lvars v = hd(shuffle([1 2 3 4 5]));
        unless seen(v) then true -> seen(v); k + 1 -> k endunless
    endfor;
enddefine;
check('shuffle varies its first element', shuffle_distinct(), 5);
check('shuffle preserves the multiset',
      syssort(shuffle([3 1 4 1 5 9 2 6]), nonop <), [1 1 2 3 4 5 6 9]);
check('shuffle preserves length', length(shuffle([1 2 3 4 5 6 7])), 7);

test_summary();
