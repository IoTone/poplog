/* pm_ops.c -- generic MLX operations for Pop-11, for E4 (a ModernBERT layer driven
 * from Pop-11).
 *
 * Each entry point is one mlx-c operation with the struct-by-value arguments
 * flattened away: arrays travel as their ctx pointer (NULL = "none", which is
 * what mlx-c's optional arguments take), shapes and axes as plain ints, scalars
 * as doubles.  Model structure -- which weights, which ops, in what order -- is
 * all in the Pop-11 caller; nothing here knows what a transformer is.
 *
 * Every op returns NULL on failure; pm_error_copy says why.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mlx/c/mlx.h"

static char last_error[1024];
static mlx_stream S;
static mlx_map_string_to_array weights;
static int ready = 0, loaded = 0;

static void on_error(const char *msg, void *data) {
    (void)data;
    snprintf(last_error, sizeof last_error, "%s", msg);
}

static mlx_array A(void *ctx) { mlx_array a = {ctx}; return a; }

#define RESULT(call) do { mlx_array r = mlx_array_new(); \
    if (call) return NULL; return r.ctx; } while (0)

int pm_init(int gpu) {
    if (ready) mlx_stream_free(S);
    mlx_set_error_handler(on_error, NULL, NULL);
    S = gpu ? mlx_default_gpu_stream_new() : mlx_default_cpu_stream_new();
    ready = 1;
    return 0;
}

int pm_error_copy(char *out, int n) {
    int len = (int)strlen(last_error);
    if (len > n) len = n;
    memcpy(out, last_error, len);
    return len;
}

/* ------------------------------------------------------------------- data */

/* Loading has no GPU kernel ("[Load::eval_gpu] Not implemented"), so it runs on the
 * CPU stream as Python's mx.load does; ops on the weights then run on S. */
int pm_load(const char *path) {
    mlx_map_string_to_string meta = mlx_map_string_to_string_new();
    mlx_stream cpu = mlx_default_cpu_stream_new();
    if (loaded) mlx_map_string_to_array_free(weights);
    weights = mlx_map_string_to_array_new();
    int rc = mlx_load_safetensors(&weights, &meta, path, cpu);
    mlx_stream_free(cpu);
    mlx_map_string_to_string_free(meta);
    loaded = rc == 0;
    return rc;
}

void *pm_weight(const char *name) {
    mlx_array r = mlx_array_new();
    if (!loaded || mlx_map_string_to_array_get(&r, weights, name)) {
        snprintf(last_error, sizeof last_error, "no weight %s", name);
        return NULL;
    }
    return r.ctx;
}

/* int32 row vector [1, n] from "12,7,99" -- a string is the easy thing to pass */
void *pm_ids_csv(const char *csv) {
    int n = 1, i = 0;
    for (const char *p = csv; *p; p++) n += *p == ',';
    int *ids = malloc(n * sizeof *ids);
    for (char *p = (char *)csv; i < n; i++) ids[i] = (int)strtol(p, &p, 10), p += *p == ',';
    int shape[2] = {1, n};
    mlx_array r = mlx_array_new_data(ids, shape, 2, MLX_INT32);
    free(ids);
    return r.ctx;
}

int pm_save(void *x, const char *path) { return mlx_save(path, A(x)); }
int pm_eval(void *x) { return mlx_array_eval(A(x)); }
void pm_free(void *x) { mlx_array_free(A(x)); }
int pm_ndim(void *x) { return (int)mlx_array_ndim(A(x)); }
int pm_dim(void *x, int axis) { return mlx_array_dim(A(x), axis); }

/* ------------------------------------------------------------------ shape */

void *pm_reshape(void *x, int ndim, int d0, int d1, int d2, int d3, int d4) {
    int shape[5] = {d0, d1, d2, d3, d4};
    RESULT(mlx_reshape(&r, A(x), shape, ndim, S));
}

void *pm_transpose(void *x, int ndim, int a0, int a1, int a2, int a3) {
    int axes[4] = {a0, a1, a2, a3};
    RESULT(mlx_transpose_axes(&r, A(x), axes, ndim, S));
}

/* x[..., i, ...] along AXIS, dropping that axis */
void *pm_index(void *x, int axis, int i) {
    mlx_array idx = mlx_array_new_int(i);
    mlx_array r = mlx_array_new();
    int rc = mlx_take_axis(&r, A(x), idx, axis, S);
    mlx_array_free(idx);
    return rc ? NULL : r.ctx;
}

/* first (which=0) or second (which=1) half of the last axis */
void *pm_half(void *x, int which) {
    int nd = (int)mlx_array_ndim(A(x)), start[8], stop[8], strides[8];
    for (int i = 0; i < nd; i++) start[i] = 0, stop[i] = mlx_array_dim(A(x), i), strides[i] = 1;
    int half = stop[nd - 1] / 2;
    start[nd - 1] = which ? half : 0;
    stop[nd - 1] = which ? 2 * half : half;
    RESULT(mlx_slice(&r, A(x), start, nd, stop, nd, strides, nd, S));
}

/* -------------------------------------------------------------- arithmetic */

void *pm_astype_f32(void *x) { RESULT(mlx_astype(&r, A(x), MLX_FLOAT32, S)); }
void *pm_take_rows(void *table, void *ids) { RESULT(mlx_take_axis(&r, A(table), A(ids), 0, S)); }
void *pm_add(void *a, void *b) { RESULT(mlx_add(&r, A(a), A(b), S)); }
void *pm_sub(void *a, void *b) { RESULT(mlx_subtract(&r, A(a), A(b), S)); }
void *pm_mul(void *a, void *b) { RESULT(mlx_multiply(&r, A(a), A(b), S)); }
void *pm_abs(void *a) { RESULT(mlx_abs(&r, A(a), S)); }
void *pm_erf(void *a) { RESULT(mlx_erf(&r, A(a), S)); }
void *pm_arange_i(int start, int stop) { RESULT(mlx_arange(&r, start, stop, 1, MLX_INT32, S)); }

static void *with_scalar(void *x, double v, int (*op)(mlx_array *, mlx_array, mlx_array, mlx_stream)) {
    mlx_array s = mlx_array_new_float((float)v), r = mlx_array_new();
    int rc = op(&r, A(x), s, S);
    mlx_array_free(s);
    return rc ? NULL : r.ctx;
}
void *pm_mul_scalar(void *x, double v) { return with_scalar(x, v, mlx_multiply); }
void *pm_add_scalar(void *x, double v) { return with_scalar(x, v, mlx_add); }
void *pm_le_scalar(void *x, double v) { return with_scalar(x, v, mlx_less_equal); }

/* x @ W^T: a bias-free nn.Linear, with W stored [out, in] as PyTorch and MLX do */
void *pm_linear(void *x, void *w) {
    int axes[2] = {1, 0};
    mlx_array wt = mlx_array_new(), r = mlx_array_new();
    if (mlx_transpose_axes(&wt, A(w), axes, 2, S)) return NULL;
    int rc = mlx_matmul(&r, A(x), wt, S);
    mlx_array_free(wt);
    return rc ? NULL : r.ctx;
}

/* ------------------------------------------------------------- fast kernels */

void *pm_layer_norm(void *x, void *w, double eps) {
    RESULT(mlx_fast_layer_norm(&r, A(x), A(w), A(NULL), (float)eps, S));
}

void *pm_rope(void *x, int dims, double base) {
    mlx_optional_float b = {(float)base, true};
    RESULT(mlx_fast_rope(&r, A(x), dims, false, b, 1.0f, 0, A(NULL), S));
}

/* mask NULL: attend everywhere; otherwise a boolean array broadcastable to the scores */
void *pm_sdpa(void *q, void *k, void *v, double scale, void *mask) {
    RESULT(mlx_fast_scaled_dot_product_attention(
        &r, A(q), A(k), A(v), (float)scale, mask ? "array" : "", A(mask), A(NULL), false, S));
}
