/* pm_shim.c -- the smallest bridge from Poplog to MLX's C API (mlx-c), for E5.
 *
 * Same rules as Poplog's popcurl shim: plain, non-variadic entry points;
 * results copied into caller-supplied buffers with explicit lengths.  One
 * more rule, for mlx-c: its arrays and streams are structs passed BY VALUE
 * ({void *ctx}), which a C FFI may or may not pass the way the ABI says.
 * So arrays cross into Pop-11 only as their ctx pointer, and are rebuilt as
 * structs here.  Pop-11 never sees a struct.
 *
 * Build: sh build.sh /path/to/mlx-c (needs libmlxc.dylib built there).
 */
#include <stdio.h>
#include <string.h>
#include "mlx/c/mlx.h"

static char last_error[1024];
static mlx_stream stream;
static int ready = 0;

static void on_error(const char *msg, void *data) {
    (void)data;
    snprintf(last_error, sizeof last_error, "%s", msg);
}

static mlx_array A(void *ctx) { mlx_array a = {ctx}; return a; }

/* 1 for the GPU, 0 for the CPU.  Returns 0 on success. */
int pm_init(int gpu) {
    if (ready) mlx_stream_free(stream);
    mlx_set_error_handler(on_error, NULL, NULL);
    stream = gpu ? mlx_default_gpu_stream_new() : mlx_default_cpu_stream_new();
    ready = 1;
    return 0;
}

int pm_error_copy(char *out, int n) {
    int len = (int)strlen(last_error);
    if (len > n) len = n;
    memcpy(out, last_error, len);
    return len;
}

/* float32 arange: three doubles through the FFI, the case ffi-float-regression guards */
void *pm_arange(double start, double stop, double step) {
    mlx_array r = mlx_array_new();
    if (mlx_arange(&r, start, stop, step, MLX_FLOAT32, stream)) return NULL;
    return r.ctx;
}

void *pm_reshape2(void *a, int d0, int d1) {
    int shape[2] = {d0, d1};
    mlx_array r = mlx_array_new();
    if (mlx_reshape(&r, A(a), shape, 2, stream)) return NULL;
    return r.ctx;
}

void *pm_matmul(void *a, void *b) {
    mlx_array r = mlx_array_new();
    if (mlx_matmul(&r, A(a), A(b), stream)) return NULL;
    return r.ctx;
}

int pm_eval(void *a) { return mlx_array_eval(A(a)); }

void pm_free(void *a) { mlx_array_free(A(a)); }

/* MLX's own printed form of the array, so the check needs no float decoding */
int pm_tostring(void *a, char *out, int n) {
    mlx_string s = mlx_string_new();
    if (mlx_array_tostring(&s, A(a))) { mlx_string_free(s); return -1; }
    const char *d = mlx_string_data(s);
    int len = (int)strlen(d);
    if (len > n) len = n;
    memcpy(out, d, len);
    mlx_string_free(s);
    return len;
}

int pm_stream_tostring(char *out, int n) {
    mlx_string s = mlx_string_new();
    mlx_stream_tostring(&s, stream);
    const char *d = mlx_string_data(s);
    int len = (int)strlen(d);
    if (len > n) len = n;
    memcpy(out, d, len);
    mlx_string_free(s);
    return len;
}
