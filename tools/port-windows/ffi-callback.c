/* ffi-callback.c -- a small library for tools/port-windows/ffi-callback.p.
 *
 * Built into a DLL by tools/validate-cygwin.sh and loaded with exload.  It
 * checks, from the C side, the things the C runtime of a Windows compiler
 * relies on: that a callback into Pop preserves the registers the Microsoft
 * x64 convention says a callee preserves (RSI and RDI among them, which Pop
 * code uses freely), and that arguments arrive in the right places.
 */

typedef long (*callback2)(long, long);

/* calls back twice, with the arguments both ways round */
long ffi_call_twice(callback2 f, long a, long b) {
    return f(a, b) + 1000 * f(b, a);
}

/* calls back from inside a loop whose state lives in callee-saved
   registers; returns 0 if any of it was disturbed */
long ffi_call_in_loop(callback2 f, long n) {
    register long acc = 0, i, guard1 = 0x1111, guard2 = 0x2222, guard3 = 0x3333;
    for (i = 1; i <= n; i++)
        acc += f(i, guard1 + guard2 + guard3 - 0x6666 + 1);
    if (guard1 != 0x1111 || guard2 != 0x2222 || guard3 != 0x3333) return 0;
    return acc;
}

/* seven integer arguments: four in registers, three on the stack */
long ffi_weigh7(long a, long b, long c, long d, long e, long f, long g) {
    return a + 10 * b + 100 * c + 1000 * d + 10000 * e + 100000 * f + 1000000 * g;
}

/* integers and doubles interleaved: positional slots on Windows */
double ffi_mix(long a, double x, long b, double y, long c, double z) {
    return (double) a * x + (double) b * y + (double) c * z;
}

/* single-precision arguments and result */
float ffi_halve(float x) {
    return x / 2;
}

/* writes into a buffer supplied by the caller */
long ffi_fill(char *buf, long n, long ch) {
    long i;
    for (i = 0; i < n; i++) buf[i] = (char) ch;
    return n;
}
