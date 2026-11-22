;;; ffi-callback.p -- external calls into a library built on the spot, and
;;; callbacks from it into Pop.  Run by tools/validate-cygwin.sh, which
;;; builds ffi-callback.c into a shared library and names it in the
;;; environment variable FFI_CALLBACK_LIB.

exload ffi_callback [% systranslate('FFI_CALLBACK_LIB') %]
(language C)
    lconstant
        ffi_call_twice(f, a, b)             :int,
        ffi_call_in_loop(f, n)              :int,
        ffi_weigh7(a, b, c, d, e, f, g)     :int,
        ffi_mix(a, x, b, y, c, z)           :dfloat,
        ffi_halve(x<SF>)                    :sfloat,
        ffi_fill(buf, n, ch)                :int,
    ;
endexload;

printf(exacc ffi_weigh7(1, 2, 3, 4, 5, 6, 7), 'WEIGH7 %p\n');
printf(exacc ffi_mix(2, 1.5, 3, 2.5, 4, 0.25), 'MIX %p\n');
printf(exacc ffi_halve(5.0), 'HALVE %p\n');

vars buf = inits(8);
exacc ffi_fill(buf, 8, `z`) -> ;
printf(buf, 'FILL %p\n');

;;; The generic callback stub hands the Pop procedure a pointer to the
;;; arguments C passed; the result goes back through the first of them.
l_typespec cbargs { a :long, b :long };

define callback(exptr, p);
    lvars exptr, procedure p;
    p(exacc :cbargs exptr.a, exacc :cbargs exptr.b) -> exacc :cbargs exptr.a
enddefine;

vars minus = exfunc_export(callback(% nonop - %), 0, false);
printf(exacc ffi_call_twice(minus, 10, 3), 'TWICE %p\n');

;;; A callback that allocates, so a garbage collection can happen while C
;;; frames are on the stack, and that uses the work registers heavily.
define busy(i, k) -> r;
    lvars i, k, r, l = [% repeat 200 times i endrepeat %];
    applist(l, erase);
    length(l) * k + i -> r
enddefine;
vars cb = exfunc_export(callback(% busy %), 0, false);
printf(exacc ffi_call_in_loop(cb, 500), 'LOOP %p\n');

;;; A mishap inside a callback unwinds through the C frames.
define try();
    dlocal prmishap = procedure(); erasenum(stacklength()); printf('MISHAP-IN-CALLBACK\n'); exitfrom(try) endprocedure;
    exacc ffi_call_twice(exfunc_export(callback(% procedure(a, b); hd(a) endprocedure %), 0, false), 1, 2) ->
enddefine;
try();
printf(exacc ffi_call_twice(minus, 10, 3), 'AFTER %p\n');
