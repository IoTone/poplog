;;; E5: can MLX run on the GPU inside a Poplog process?
;;;
;;;     PM_SHIM=.../mlx_shim/pm_shim.dylib  poplog basepop11 mlx_inprocess.p
;;;
;;; Poplog on Apple Silicon runs its compiled code from MAP_JIT memory with W^X
;;; toggling, and installs its own signal handlers.  MLX brings Metal, its own
;;; threads and a JIT of its own for kernels.  This loads MLX into basepop11 and
;;; checks a GPU matmul gives the right answer -- with doubles crossing the FFI on
;;; the way in, the case tools/ffi-float-regression.p guards.

lconstant shim = systranslate('PM_SHIM');
exload pm_shim [^shim]
(language C)
    lconstant
        pm_init(gpu)                    :int,
        pm_error_copy(out, n)           :int,
        pm_arange(start, stop, step)    :exptr,
        pm_reshape2(a, d0, d1)          :exptr,
        pm_matmul(a, b)                 :exptr,
        pm_eval(a)                      :int,
        pm_free(a)                      :void,
        pm_tostring(a, out, n)          :int,
        pm_stream_tostring(out, n)      :int,
    ;
endexload;

define lconstant shown(a) -> s;
    lvars buf = inits(512), n = exacc pm_tostring(a, buf, 512);
    if n < 0 then mishap(0, 'pm_tostring failed') endif;
    substring(1, n, buf) -> s;
enddefine;

define lconstant mlx_error() -> s;
    lvars buf = inits(1024);
    substring(1, exacc pm_error_copy(buf, 1024), buf) -> s;
enddefine;

define lconstant run(gpu);
    lvars buf = inits(128), a, b, c, i, x, xs;
    exacc pm_init(gpu) -> ;
    npr('stream: ' <> substring(1, exacc pm_stream_tostring(buf, 128), buf));
    ;;; [[0 1 2] [3 4 5]] @ [[0 1] [2 3] [4 5]] = [[10 13] [28 40]]
    exacc pm_reshape2(exacc pm_arange(0.0, 6.0, 1.0), 2, 3) -> a;
    exacc pm_reshape2(exacc pm_arange(0.0, 6.0, 1.0), 3, 2) -> b;
    exacc pm_matmul(a, b) -> c;
    unless exacc pm_eval(c) == 0 then mishap(0, 'eval: ' <> mlx_error()) endunless;
    npr(shown(c));
    ;;; a bigger one, so the GPU does real work: (512x512 arange/1e5)^2, twice
    exacc pm_reshape2(exacc pm_arange(0.0, 262144.0, 1.0), 512, 512) -> x;
    repeat 2 times exacc pm_matmul(x, x) -> xs; exacc pm_eval(xs) -> ; endrepeat;
    npr(shown(xs));
    exacc pm_free(a); exacc pm_free(b); exacc pm_free(c); exacc pm_free(x); exacc pm_free(xs);
    ;;; Pop-11 is still well: compile and run something after MLX has run
    define lconstant fib(n); if n < 2 then n else fib(n - 1) + fib(n - 2) endif enddefine;
    npr('pop11 still runs: fib(25) = ' sys_>< fib(25));
    sysgarbage();
    npr('gc ok');
enddefine;

run(1);
run(0);
npr('MLX-INPROCESS-DONE');
