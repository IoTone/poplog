;;; E4: the English checkpoint's embeddings and first two encoder layers, written in
;;; Pop-11 over mlx-c (via mlx_shim/pm_ops.dylib), compared with laya_mlx's own.
;;;
;;;     PM_OPS=.../pm_ops.dylib E4_DIR=...  poplog basepop11 encoder_layers.p
;;;
;;; The model's structure lives here, in Pop-11; the shim only exposes single MLX
;;; operations.  This mirrors laya_mlx/model.py: Embeddings, EncoderLayer,
;;; EncoderAttention, EncoderMLP, attention_masks.

uses fileutils;
uses json;

lconstant ops = systranslate('PM_OPS'), dir = systranslate('E4_DIR');
exload pm_ops [^ops]
(language C)
    lconstant
        pm_init(gpu) :int, pm_error_copy(out, n) :int,
        pm_load(path) :int, pm_weight(name) :exptr, pm_ids_csv(csv) :exptr,
        pm_save(x, path) :int, pm_eval(x) :int,
        pm_reshape(x, nd, d0, d1, d2, d3, d4) :exptr,
        pm_transpose(x, nd, a0, a1, a2, a3) :exptr,
        pm_index(x, axis, i) :exptr, pm_half(x, which) :exptr,
        pm_astype_f32(x) :exptr, pm_take_rows(t, ids) :exptr,
        pm_add(a, b) :exptr, pm_sub(a, b) :exptr, pm_mul(a, b) :exptr,
        pm_abs(a) :exptr, pm_erf(a) :exptr, pm_arange_i(start, stop) :exptr,
        pm_mul_scalar(x, v) :exptr, pm_add_scalar(x, v) :exptr, pm_le_scalar(x, v) :exptr,
        pm_linear(x, w) :exptr, pm_layer_norm(x, w, eps) :exptr,
        pm_rope(x, dims, base) :exptr, pm_sdpa(q, k, v, scale, mask) :exptr,
    ;
endexload;

define lconstant cstr(s); s <> consstring(0, 1) enddefine;

;;; every op result goes through here: a NULL means MLX refused, and says why
define lconstant ok(x, what) -> x;
    lvars buf;
    if is_null_external_ptr(x) then
        inits(1024) -> buf;
        mishap(what, 1, 'mlx: ' <> substring(1, exacc pm_error_copy(buf, 1024), buf))
    endif;
enddefine;

define lconstant W(name);
    ok(exacc pm_astype_f32(ok(exacc pm_weight(cstr(name)), name)), name)
enddefine;

lconstant HIDDEN = 1024, HEADS = 16, HEAD_DIM = 64, EPS = 1.0e-5;

define lconstant layer_norm(x, w); ok(exacc pm_layer_norm(x, w, EPS), 'layer_norm') enddefine;
define lconstant linear(x, w);     ok(exacc pm_linear(x, w), 'linear') enddefine;

;;; exact GELU, as nn.gelu: x * (1 + erf(x / sqrt 2)) / 2
define lconstant gelu(x);
    lvars e = ok(exacc pm_erf(ok(exacc pm_mul_scalar(x, 1.0 / sqrt(2.0)), 'gelu')), 'erf');
    ok(exacc pm_mul_scalar(ok(exacc pm_mul(x, ok(exacc pm_add_scalar(e, 1.0), 'gelu')),
                              'gelu'), 0.5), 'gelu')
enddefine;

define lconstant attention(x, mask, base, prefix, len);
    lvars qkv = ok(exacc pm_reshape(linear(x, W(prefix <> 'attn.Wqkv.weight')),
                                    5, 1, len, 3, HEADS, HEAD_DIM), 'qkv');
    ;;; qkv[:, :, i].transpose(0, 2, 1, 3)
    define lconstant part(i);
        ok(exacc pm_transpose(ok(exacc pm_index(qkv, 2, i), 'index'), 4, 0, 2, 1, 3),
           'transpose')
    enddefine;
    lvars q = ok(exacc pm_rope(part(0), HEAD_DIM, base), 'rope'),
          k = ok(exacc pm_rope(part(1), HEAD_DIM, base), 'rope'),
          v = part(2);
    lvars out = ok(exacc pm_sdpa(q, k, v, 1.0 / sqrt(HEAD_DIM), mask), 'sdpa');
    out -> ;
    ok(exacc pm_reshape(ok(exacc pm_transpose(out, 4, 0, 2, 1, 3), 'transpose'),
                        3, 1, len, HIDDEN, 0, 0), 'merge heads') -> out;
    linear(out, W(prefix <> 'attn.Wo.weight'))
enddefine;

define lconstant mlp(x, prefix);
    lvars h = linear(x, W(prefix <> 'mlp.Wi.weight'));
    linear(ok(exacc pm_mul(gelu(ok(exacc pm_half(h, 0), 'split')),
                           ok(exacc pm_half(h, 1), 'split')), 'gate'),
           W(prefix <> 'mlp.Wo.weight'))
enddefine;

;;; x + attn(attn_norm(x)); then x + mlp(mlp_norm(x)).  Layer 0 has no attn_norm.
define lconstant layer(x, i, mask, base, len);
    lvars prefix = 'encoder.layers.' sys_>< i sys_>< '.';
    lvars a = if i == 0 then x else layer_norm(x, W(prefix <> 'attn_norm.weight')) endif;
    ok(exacc pm_add(x, attention(a, mask, base, prefix, len)), 'residual') -> x;
    ok(exacc pm_add(x, mlp(layer_norm(x, W(prefix <> 'mlp_norm.weight')), prefix)),
       'residual')
enddefine;

;;; |i - j| <= window // 2, shaped to broadcast over batch and heads
define lconstant sliding_mask(len, window);
    lvars p = ok(exacc pm_arange_i(0, len), 'arange');
    lvars d = ok(exacc pm_sub(ok(exacc pm_reshape(p, 2, len, 1, 0, 0, 0), 'col'),
                              ok(exacc pm_reshape(p, 2, 1, len, 0, 0, 0), 'row')), 'sub');
    ;;; number_coerce: the C parameter is a double, and an untyped exload argument
    ;;; passes a Pop-11 integer as an integer -- in the wrong register, silently
    ok(exacc pm_reshape(ok(exacc pm_le_scalar(ok(exacc pm_abs(d), 'abs'),
                                              number_coerce(window div 2, 1.0)),
                           'le'), 4, 1, 1, len, len, 0), 'mask')
enddefine;

define lconstant save(x, name);
    lvars buf = inits(1024);
    unless exacc pm_eval(x) == 0 then
        mishap(name, 1, 'mlx: ' <> substring(1, exacc pm_error_copy(buf, 1024), buf))
    endunless;
    unless exacc pm_save(x, cstr(dir dir_>< ('pop-' <> name <> '.npy'))) == 0 then
        mishap(name, 1, 'mlx: save failed')
    endunless;
enddefine;

lvars meta = json_parse(file_to_string(dir dir_>< 'meta.json'));
lvars len = length(meta('ids')), window = meta('window');
;;; E4_DEVICE=cpu runs on the CPU, whose float32 matmul is exact enough to tell a port
;;; bug from GPU rounding
exacc pm_init(if systranslate('E4_DEVICE') = 'cpu' then 0 else 1 endif) -> ;
unless exacc pm_load(cstr(meta('weights'))) == 0 then mishap(0, 'mlx: load failed') endunless;

lvars ids = ok(exacc pm_ids_csv(cstr(file_to_string(dir dir_>< 'ids.csv'))), 'ids');
lvars h0 = layer_norm(ok(exacc pm_take_rows(W('encoder.embeddings.tok_embeddings.weight'), ids),
                         'embed'),
                      W('encoder.embeddings.norm.weight'));
save(h0, 'embeddings');
;;; layer 0: global attention (RoPE base 160000), every key visible -- no mask
lvars h1 = layer(h0, 0, null_external_ptr, 160000.0, len);
save(h1, 'layer0');
;;; layer 1: sliding window (RoPE base 10000)
lvars h2 = layer(h1, 1, sliding_mask(len, window), 10000.0, len);
save(h2, 'layer1');
npr('E4-DONE ' sys_>< len sys_>< ' tokens');
