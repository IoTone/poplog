/* microgpt.p -- train a GPT and run inference, in pure, dependency-free
   Pop-11.  A port of @karpathy's microgpt.py.  This file is the complete
   algorithm; everything else is just efficiency.

   Nothing is loaded: no library, no shim, no C.  Scalar autograd, a
   transformer, Adam and sampling, in about 300 lines.

       ./poplog basepop11 examples/microgpt/microgpt.p </dev/null
       ./poplog basepop11 examples/microgpt/microgpt.p 200 </dev/null
*/
compile_mode :pop11 +strict;

;;; Two Poplog defaults that must be changed, or the model trains on
;;; nonsense.  TRAP 1: without popdprecision, **, log, exp and sqrt return
;;; SINGLE-precision decimals.  TRAP 2: the trig functions take DEGREES by
;;; default, so the cos() in Box-Muller below returns ~1.0 for every input
;;; and every "gaussian" parameter comes out positive.
true -> popdprecision;
true -> popradians;

;;; TRAP 3: the graph for one document runs to tens of thousands of nodes.
;;; Poplog's default heap ceiling is 1.5M words (12 MB) and a training step
;;; walks straight through it.
max(popmemlim, 60000000) -> popmemlim;

lconstant PI = 3.141592653589793;

;;; ===================================================================== RNG
42 -> ranseed;                    ;;; let there be order among chaos

;;; TRAP 4, and it is a real bug in this Poplog, not a misuse: on 64-bit
;;; builds random(n) and random0(n) are broken for every integer n <= 2**24.
;;; random0 always returns 0 and random always returns n, so a Fisher-Yates
;;; shuffle written the obvious way silently does nothing.  The FLOAT path is
;;; correct, so every integer draw here goes through it.
define rand_int(n) -> k;                    ;;; uniform in 1..n
    intof(random0(1.0) * n) + 1 -> k
enddefine;

define gauss(mu, sigma) -> g;
    lvars u1 = random0(1.0), u2 = random0(1.0);
    if u1 < 1.0e-12 then 1.0e-12 -> u1 endif;
    mu + sigma * sqrt(-2.0 * log(u1)) * cos(2.0 * PI * u2) -> g
enddefine;

;;; ================================================================= Dataset
;;; Let there be a dataset `docs`: a vector of documents (here, names)
lconstant NAMES_URL =
    'https://raw.githubusercontent.com/karpathy/makemore/988aa59/names.txt';

define read_docs(path) -> docs;
    lvars dev, rep, line, acc = [];
    unless sys_file_exists(path) then
        npr(';;; fetching ' sys_>< NAMES_URL);
        sysobey('curl -fsSL ' <> NAMES_URL <> ' -o ' <> path);
    endunless;
    sysopen(path, 0, "line") -> dev;
    line_repeater(dev, inits(256)) -> rep;
    repeat
        rep() -> line;
        quitif(line == termin);
        if length(line) > 0 then conspair(line, acc) -> acc endif;
    endrepeat;
    {% applist(acc, identfn) %} -> docs;
enddefine;

define shuffle(v);                          ;;; Fisher-Yates, in place
    lvars i, j, t;
    for i from length(v) by -1 to 2 do
        rand_int(i) -> j;
        subscrv(i, v) -> t;
        subscrv(j, v) -> subscrv(i, v);
        t -> subscrv(j, v);
    endfor
enddefine;

;;; =============================================================== Tokenizer
;;; Unique characters become token ids 1..n; BOS is n+1.  (Pop-11 indexes
;;; from 1, so the token ids index the embedding vectors directly.)
define build_vocab(docs) -> (uchars, char2id);
    lvars d, c, i, seen = newproperty([], 256, false, true), cs = [];
    for d in_vector docs do
        for c in_string d do
            unless seen(c) then true -> seen(c); conspair(c, cs) -> cs endunless
        endfor
    endfor;
    consstring(#| applist(syssort(cs, nonop <), identfn) |#) -> uchars;
    initv(256) -> char2id;
    for i from 1 to 256 do false -> subscrv(i, char2id) endfor;
    for i from 1 to length(uchars) do i -> subscrv(subscrs(i, uchars), char2id) endfor;
enddefine;

;;; ================================================================ Autograd
;;; Let there be autograd, to apply the chain rule through a computation
;;; graph.  A node holds its value, its gradient, its children, and the
;;; local derivative of itself with respect to each child.
recordclass Value v_data v_grad v_kids v_lgrads;

lconstant NOKIDS = {}, ONES = {1.0 1.0};

;;; TRAP: without a print method, one Value printed by a mishap dumps its
;;; ENTIRE subgraph -- tens of thousands of nodes -- and the real error
;;; scrolls away.  Print the scalar and stop.
define print_value(v); printf('<V %p>', [% v_data(v) %]) enddefine;
print_value -> class_print(Value_key);

define v_leaf(x) -> r;  consValue(x, 0.0, NOKIDS, NOKIDS) -> r  enddefine;

define v_add(a, b) -> r;
    consValue(v_data(a) + v_data(b), 0.0, {%a, b%}, ONES) -> r
enddefine;

define v_mul(a, b) -> r;
    consValue(v_data(a) * v_data(b), 0.0, {%a, b%}, {%v_data(b), v_data(a)%}) -> r
enddefine;

define v_pow(a, k) -> r;                    ;;; k is an ordinary number
    consValue(v_data(a) ** k, 0.0, {%a%}, {%k * (v_data(a) ** (k - 1))%}) -> r
enddefine;

define v_log(a) -> r;
    consValue(log(v_data(a)), 0.0, {%a%}, {%1.0 / v_data(a)%}) -> r
enddefine;

define v_exp(a) -> r;
    lvars e = exp(v_data(a));
    consValue(e, 0.0, {%a%}, {%e%}) -> r
enddefine;

define v_relu(a) -> r;
    lvars d = v_data(a);
    consValue(if d > 0.0 then d else 0.0 endif, 0.0,
              {%a%}, {%if d > 0.0 then 1.0 else 0.0 endif%}) -> r
enddefine;

define v_div(a, b) -> r;  v_mul(a, v_pow(b, -1)) -> r  enddefine;

;;; Topological order, then one sweep of the chain rule.  `seen` is a
;;; property matched by IDENTITY -- which is exactly Python's set() of
;;; objects, and exactly what a graph of distinct nodes wants.
vars topo_seen = newproperty([], 65536, false, true);
vars nodes_seen = 0;             ;;; graph nodes built, for the record

define build_topo(x);                       ;;; leaves nodes on the open stack
    lvars c;
    unless topo_seen(x) then
        true -> topo_seen(x);
        for c in_vector v_kids(x) do build_topo(c) endfor;
        x;                                  ;;; children first, then self
    endunless
enddefine;

define v_backward(root);
    lvars topo, i, t, kids, lg, k, g;
    clearproperty(topo_seen);
    {% build_topo(root) %} -> topo;
    nodes_seen + length(topo) -> nodes_seen;
    1.0 -> v_grad(root);
    for t from length(topo) by -1 to 1 do   ;;; ...so walk it backwards
        subscrv(t, topo) -> k;
        v_kids(k) -> kids;  v_lgrads(k) -> lg;  v_grad(k) -> g;
        for i from 1 to length(kids) do
            v_grad(subscrv(i, kids)) + subscrv(i, lg) * g
                -> v_grad(subscrv(i, kids))
        endfor
    endfor;
    clearproperty(topo_seen);    ;;; release the graph to the collector
enddefine;
;;; ============================================================== Parameters
;;; Let there be parameters, to store the knowledge of the model
vars n_layer = 1;        ;;; depth (number of transformer layers)
vars n_embd = 16;        ;;; width (embedding dimension)
vars block_size = 16;    ;;; maximum context length (longest name is 15)
vars n_head = 4;         ;;; number of attention heads
vars head_dim;           ;;; derived: n_embd / n_head
vars vocab_size, BOS, uchars, char2id, docs;
vars state_dict, params;

define matrix(nout, nin, std) -> m;
    lvars o, i;
    {% for o from 1 to nout do
           {% for i from 1 to nin do v_leaf(gauss(0.0, std)) endfor %}
       endfor %} -> m
enddefine;

define pkey(li, nm) -> w;  consword('l' >< li >< '_' >< nm) -> w  enddefine;

define init_params();
    lvars li, mat, row, p, acc = [];
    n_embd div n_head -> head_dim;
    newproperty([], 32, false, true) -> state_dict;
    matrix(vocab_size,  n_embd, 0.08) -> state_dict("wte");
    matrix(block_size,  n_embd, 0.08) -> state_dict("wpe");
    matrix(vocab_size,  n_embd, 0.08) -> state_dict("lm_head");
    for li from 1 to n_layer do
        matrix(n_embd, n_embd, 0.08) -> state_dict(pkey(li, 'attn_wq'));
        matrix(n_embd, n_embd, 0.08) -> state_dict(pkey(li, 'attn_wk'));
        matrix(n_embd, n_embd, 0.08) -> state_dict(pkey(li, 'attn_wv'));
        matrix(n_embd, n_embd, 0.08) -> state_dict(pkey(li, 'attn_wo'));
        matrix(4 * n_embd, n_embd, 0.08) -> state_dict(pkey(li, 'mlp_fc1'));
        matrix(n_embd, 4 * n_embd, 0.08) -> state_dict(pkey(li, 'mlp_fc2'));
    endfor;
    ;;; flatten every parameter into one vector
    appproperty(state_dict,
        procedure(k, mat);
            lvars row, p;
            for row in_vector mat do
                for p in_vector row do conspair(p, acc) -> acc endfor
            endfor
        endprocedure);
    {% applist(acc, identfn) %} -> params;
enddefine;

;;; ============================================================ Architecture
;;; GPT-2, blessed among the GPTs, with minor differences: layernorm ->
;;; rmsnorm, no biases, GeLU -> ReLU.

define dot(w_row, x) -> s;
    lvars j;
    v_leaf(0.0) -> s;
    for j from 1 to length(x) do
        v_add(s, v_mul(subscrv(j, w_row), subscrv(j, x))) -> s
    endfor
enddefine;

define linear(x, w) -> y;
    lvars row;
    {% for row in_vector w do dot(row, x) endfor %} -> y
enddefine;

define softmax(logits) -> probs;
    lvars i, n = length(logits), mx, total, exps, d;
    v_data(subscrv(1, logits)) -> mx;
    for i from 2 to n do
        v_data(subscrv(i, logits)) -> d;
        if d > mx then d -> mx endif
    endfor;
    {% for i from 1 to n do
           v_exp(v_add(subscrv(i, logits), v_leaf(-mx)))
       endfor %} -> exps;
    v_leaf(0.0) -> total;
    for i from 1 to n do v_add(total, subscrv(i, exps)) -> total endfor;
    {% for i from 1 to n do v_div(subscrv(i, exps), total) endfor %} -> probs
enddefine;

define rmsnorm(x) -> y;
    lvars i, n = length(x), ss, scale;
    v_leaf(0.0) -> ss;
    for i from 1 to n do
        v_add(ss, v_mul(subscrv(i, x), subscrv(i, x))) -> ss
    endfor;
    v_mul(ss, v_leaf(1.0 / n)) -> ss;                     ;;; mean square
    v_pow(v_add(ss, v_leaf(1.0e-5)), -0.5) -> scale;
    {% for i from 1 to n do v_mul(subscrv(i, x), scale) endfor %} -> y
enddefine;

;;; keys/values are vectors (one slot per layer) of vectors (one per
;;; position): the KV cache, with no growing lists anywhere.
define new_kv() -> kv;
    lvars li;
    {% for li from 1 to n_layer do initv(block_size) endfor %} -> kv
enddefine;

define gpt(token_id, pos_id, keys, values) -> logits;
    lvars x, x_res, x_attn, q, k, v, li, h, hs, j, t, i, s, sc, aw, al;
    lvars tok_emb = subscrv(token_id, state_dict("wte"));
    lvars pos_emb = subscrv(pos_id,   state_dict("wpe"));
    {% for i from 1 to n_embd do
           v_add(subscrv(i, tok_emb), subscrv(i, pos_emb))
       endfor %} -> x;
    rmsnorm(x) -> x;   ;;; not redundant: the residual path needs it too

    for li from 1 to n_layer do
        ;;; --- 1) multi-head attention ---
        x -> x_res;
        rmsnorm(x) -> x;
        linear(x, state_dict(pkey(li, 'attn_wq'))) -> q;
        linear(x, state_dict(pkey(li, 'attn_wk'))) -> k;
        linear(x, state_dict(pkey(li, 'attn_wv'))) -> v;
        k -> subscrv(pos_id, subscrv(li, keys));
        v -> subscrv(pos_id, subscrv(li, values));
        initv(n_embd) -> x_attn;
        1.0 / sqrt(head_dim) -> sc;
        for h from 0 to n_head - 1 do
            h * head_dim -> hs;
            {% for t from 1 to pos_id do                  ;;; attention logits
                   v_leaf(0.0) -> s;
                   lvars kt = subscrv(t, subscrv(li, keys));
                   for j from 1 to head_dim do
                       v_add(s, v_mul(subscrv(hs + j, q), subscrv(hs + j, kt))) -> s
                   endfor;
                   v_mul(s, v_leaf(sc));
               endfor %} -> al;
            softmax(al) -> aw;
            for j from 1 to head_dim do                    ;;; weighted sum of v
                v_leaf(0.0) -> s;
                for t from 1 to pos_id do
                    v_add(s, v_mul(subscrv(t, aw),
                                   subscrv(hs + j, subscrv(t, subscrv(li, values))))) -> s
                endfor;
                s -> subscrv(hs + j, x_attn);
            endfor;
        endfor;
        linear(x_attn, state_dict(pkey(li, 'attn_wo'))) -> x;
        {% for i from 1 to n_embd do
               v_add(subscrv(i, x), subscrv(i, x_res)) endfor %} -> x;
        ;;; --- 2) MLP ---
        x -> x_res;
        rmsnorm(x) -> x;
        linear(x, state_dict(pkey(li, 'mlp_fc1'))) -> x;
        {% for i from 1 to length(x) do v_relu(subscrv(i, x)) endfor %} -> x;
        linear(x, state_dict(pkey(li, 'mlp_fc2'))) -> x;
        {% for i from 1 to n_embd do
               v_add(subscrv(i, x), subscrv(i, x_res)) endfor %} -> x;
    endfor;
    linear(x, state_dict("lm_head")) -> logits;
enddefine;
;;; ==================================================================== Adam
;;; Let there be Adam, the blessed optimizer, and its buffers
vars learning_rate = 0.01, beta1 = 0.85, beta2 = 0.99, eps_adam = 1.0e-8;
vars adam_m, adam_v;

define init_adam();
    lvars i, np = length(params);
    initv(np) -> adam_m;  initv(np) -> adam_v;
    for i from 1 to np do
        0.0 -> subscrv(i, adam_m);  0.0 -> subscrv(i, adam_v)
    endfor;
enddefine;

define adam_step(sn, num_steps);
    lvars i, p, g, mi, vi, mh, vh, np = length(params);
    lvars lr_t = learning_rate * (1.0 - (sn - 1) / num_steps);
    lvars b1c = 1.0 - beta1 ** sn, b2c = 1.0 - beta2 ** sn;
    for i from 1 to np do
        subscrv(i, params) -> p;
        v_grad(p) -> g;
        beta1 * subscrv(i, adam_m) + (1.0 - beta1) * g -> mi;
        beta2 * subscrv(i, adam_v) + (1.0 - beta2) * g * g -> vi;
        mi -> subscrv(i, adam_m);  vi -> subscrv(i, adam_v);
        mi / b1c -> mh;  vi / b2c -> vh;
        v_data(p) - lr_t * mh / (sqrt(vh) + eps_adam) -> v_data(p);
        0.0 -> v_grad(p);
    endfor
enddefine;

;;; ================================================================ Training
define tokenize(doc) -> toks;
    lvars c;
    {% BOS;
       for c in_string doc do subscrv(c, char2id) endfor;
       BOS
    %} -> toks
enddefine;

define train(num_steps);
    lvars sn, doc, toks, n, keys, vals, pos, tid, target, lg, probs;
    lvars loss, losses, t0 = systime(), every = max(1, num_steps div 20);
    for sn from 1 to num_steps do
        ;;; one document, tokenized, wrapped in BOS on both sides
        subscrv(((sn - 1) mod length(docs)) + 1, docs) -> doc;
        tokenize(doc) -> toks;
        min(block_size, length(toks) - 1) -> n;

        ;;; forward, building the graph all the way to the loss
        new_kv() -> keys;  new_kv() -> vals;
        {% for pos from 1 to n do
               subscrv(pos, toks) -> tid;
               subscrv(pos + 1, toks) -> target;
               gpt(tid, pos, keys, vals) -> lg;
               softmax(lg) -> probs;
               v_mul(v_log(subscrv(target, probs)), v_leaf(-1.0));
           endfor %} -> losses;
        v_leaf(0.0) -> loss;
        for pos from 1 to n do v_add(loss, subscrv(pos, losses)) -> loss endfor;
        v_mul(loss, v_leaf(1.0 / n)) -> loss;    ;;; may yours be low

        v_backward(loss);                        ;;; backward
        adam_step(sn, num_steps);              ;;; update

        if sn mod every == 0 or sn == 1 then
            printf('step %p / %p | loss %p\n',
                   [% sn, num_steps, v_data(loss) %])
        endif;
    endfor;
    printf(';;; trained %p steps in %p s CPU\n',
           [% num_steps, (systime() - t0) / 100.0 %]);
enddefine;

;;; =============================================================== Inference
define sample_from(probs) -> id;
    lvars i, r = random0(1.0), c = 0.0;
    length(probs) -> id;                         ;;; fall back to the last
    for i from 1 to length(probs) do
        v_data(subscrv(i, probs)) + c -> c;
        if r < c then i -> id; return endif
    endfor
enddefine;

define generate(count, temperature);
    lvars s, pos, tid, keys, vals, lg, probs, i, out;
    for s from 1 to count do
        new_kv() -> keys;  new_kv() -> vals;
        BOS -> tid;
        consstring(#|
            for pos from 1 to block_size do
                gpt(tid, pos, keys, vals) -> lg;
                {% for i from 1 to vocab_size do
                       v_mul(subscrv(i, lg), v_leaf(1.0 / temperature))
                   endfor %} -> lg;
                softmax(lg) -> probs;
                sample_from(probs) -> tid;
                quitif(tid == BOS);
                subscrs(tid, uchars);
            endfor
        |#) -> out;
        printf('sample %p: %p\n', [% s, out %]);
    endfor
enddefine;

;;; ==================================================================== Main
define microgpt_main(num_steps, data_path);
    read_docs(data_path) -> docs;
    printf('num docs: %p\n', [% length(docs) %]);
    shuffle(docs);
    build_vocab(docs) -> (uchars, char2id);
    length(uchars) + 1 -> vocab_size;
    vocab_size -> BOS;
    printf('vocab size: %p\n', [% vocab_size %]);
    init_params();
    printf('num params: %p\n', [% length(params) %]);
    init_adam();
    train(num_steps);
    printf('\n--- inference (new, hallucinated names) ---\n', []);
    generate(20, 0.5);
enddefine;

define microgpt_run();
    lvars args = poparglist, nsteps = 1000;
    lvars path = 'examples/microgpt/input.txt';
    if args /== [] and strnumber(hd(args)) then strnumber(hd(args)) -> nsteps endif;
    if args /== [] and tl(args) /== [] then hd(tl(args)) -> path endif;
    microgpt_main(nsteps, path);
    printf(';;; %p graph nodes built (%p per second)\n',
           [% nodes_seen, round(nodes_seen / max(0.01, systime() / 100.0)) %]);
enddefine;

;;; run when this file is the program; stay quiet when another file loads it
;;; as a library (declare microgpt_lib first)
unless isdefined("microgpt_lib") then microgpt_run() endunless;
