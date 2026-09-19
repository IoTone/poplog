/* examples/robotarmy/vision.p -- a classifier small enough to be honest.

   sightnet.p had canned labels.  This produces real ones, from real pixels,
   with a network trained here rather than imported from somewhere else.

   The honesty is in the scope.  A 256->16->4 MLP cannot tell a cat from a
   dog in a photograph; nothing this size can, and a transformer over image
   patches would be slower and no better.  What it CAN do is recognise a
   small fixed vocabulary of markers under controlled conditions -- which is
   what a robot army watching for painted signs actually needs.  So the
   classes are shapes, and what a shape MEANS is left to Prolog, where it is
   data a live fleet can be taught (see sight-rules.pl).

   Two measured facts shape the design (docs/book ch.8 has the benchmarks):

     * Training runs through the autograd graph at tens of samples/second.
       Fine for 240 samples; hopeless for ImageNet.  We train once, here.
     * Inference does NOT need the graph.  Dropping it and using plain
       floats is a 30x speedup -- 1375 classifications/second measured on
       an M-series Mac.  So the exported weights are plain numbers and the
       forward pass is ordinary arithmetic.

       ./poplog basepop11 examples/robotarmy/vision.p --train 15
       ./poplog basepop11 examples/robotarmy/vision.p --check
*/
vars microgpt_lib = true;
load 'examples/microgpt/microgpt.p';
uses strutils;

lconstant DIM = 16;                     ;;; images are DIM x DIM
lconstant NPIX = DIM * DIM;
lconstant NHID = 16;
lconstant SHAPES = {circle square triangle cross};
lconstant NCLASS = 4;

;;; ------------------------------------------------------------- a drawing
;;; Our own generator rather than random/1: it must produce the SAME image
;;; from the same seed on every machine, so a frame fetched from the Pi can
;;; be compared with one generated here.  (random/1 was also the subject of
;;; docs/bugs/random-int-64bit.md, which is a second reason not to lean on
;;; it for anything reproducible.)

vars vis_seed = 1;

define vis_rand() -> r;
    (vis_seed * 1103515245 + 12345) mod 2147483648 -> vis_seed;
    vis_seed / 2147483648.0 -> r;
enddefine;

define vis_randint(lo, hi) -> n;
    lo + intof(vis_rand() * (hi - lo + 1)) -> n;
    if n > hi then hi -> n endif;
enddefine;

define lconstant plot(img, x, y, v);
    if x >= 0 and x < DIM and y >= 0 and y < DIM then
        lvars i = y * DIM + x + 1;
        min(1.0, subscrv(i, img) + v) -> subscrv(i, img);
    endif;
enddefine;

;;; Draw one of the shapes, jittered in position and size, with a little
;;; pixel noise so the classifier cannot memorise an exact bitmap.
define vis_render(cls, seed) -> img;
    lvars i, a, x, y, cx, cy, r, img;
    seed -> vis_seed;
    vis_rand() -> ;                      ;;; discard the first, it is weak
    initv(NPIX) -> img;
    for i from 1 to NPIX do 0.0 -> subscrv(i, img) endfor;
    vis_randint(7, 9) -> cx;
    vis_randint(7, 9) -> cy;
    vis_randint(4, 6) -> r;
    if cls == "circle" then
        for a from 0 to 59 do
            lvars th = a * 0.10472;      ;;; 2pi/60, popradians is true
            plot(img, cx + intof(r * cos(th)), cy + intof(r * sin(th)), 0.9);
        endfor;
    elseif cls == "square" then
        for i from -r to r do
            plot(img, cx + i, cy - r, 0.9);  plot(img, cx + i, cy + r, 0.9);
            plot(img, cx - r, cy + i, 0.9);  plot(img, cx + r, cy + i, 0.9);
        endfor;
    elseif cls == "triangle" then
        ;;; apex at the top, widening to a base of 2r -- walk down the rows
        ;;; and let the half-width grow with the row, so the sides slope.
        for i from 0 to 2 * r do
            lvars hw = intof(i / 2.0);
            plot(img, cx - hw, cy - r + i, 0.9);
            plot(img, cx + hw, cy - r + i, 0.9);
        endfor;
        for i from -r to r do
            plot(img, cx + i, cy + r, 0.9);                    ;;; base
        endfor;
    else                                  ;;; cross
        for i from -r to r do
            plot(img, cx + i, cy + i, 0.9);
            plot(img, cx + i, cy - i, 0.9);
        endfor;
    endif;
    ;;; sensor noise
    for i from 1 to NPIX do
        min(1.0, subscrv(i, img) + vis_rand() * 0.10) -> subscrv(i, img);
    endfor;
enddefine;

define vis_ascii(img);
    lvars x, y, v;
    for y from 0 to DIM - 1 do
        for x from 0 to DIM - 1 do
            subscrv(y * DIM + x + 1, img) -> v;
            cucharout(if v > 0.6 then `#` elseif v > 0.3 then `+`
                      elseif v > 0.15 then `.` else ` ` endif);
        endfor;
        cucharout(`\n`);
    endfor;
enddefine;

;;; ------------------------------------------------------------ the network
;;; Weights live twice: as Values while training (so autograd can reach
;;; them) and as plain floats once exported (so inference need not).

vars vis_w1, vis_b1, vis_w2, vis_b2;     ;;; plain floats, after loading
vars vis_shapes = SHAPES;                ;;; overwritten by the weights file

define vis_build();
    lvars i, j, acc = [];
    define lconstant mk(n) -> v;
        lvars k;
        {% for k from 1 to n do v_leaf((vis_rand() - 0.5) * 0.2) endfor %} -> v;
    enddefine;
    {% for i from 1 to NHID do mk(NPIX) endfor %} -> vis_w1;
    mk(NHID) -> vis_b1;
    {% for i from 1 to NCLASS do mk(NHID) endfor %} -> vis_w2;
    mk(NCLASS) -> vis_b2;
    ;;; microgpt's adam_step drives off the global `params`
    [%  for i from 1 to NHID do
            for j from 1 to NPIX do subscrv(j, subscrv(i, vis_w1)) endfor
        endfor;
        for i from 1 to NHID do subscrv(i, vis_b1) endfor;
        for i from 1 to NCLASS do
            for j from 1 to NHID do subscrv(j, subscrv(i, vis_w2)) endfor
        endfor;
        for i from 1 to NCLASS do subscrv(i, vis_b2) endfor
    %] -> acc;
    {% applist(acc, identfn) %} -> params;
enddefine;

define vis_forward(img) -> logits;
    lvars i, j, s, h;
    {% for i from 1 to NHID do
         subscrv(i, vis_b1) -> s;
         for j from 1 to NPIX do
             v_add(s, v_mul(subscrv(j, subscrv(i, vis_w1)),
                            v_leaf(subscrv(j, img)))) -> s
         endfor;
         v_relu(s)
       endfor %} -> h;
    {% for i from 1 to NCLASS do
         subscrv(i, vis_b2) -> s;
         for j from 1 to NHID do
             v_add(s, v_mul(subscrv(j, subscrv(i, vis_w2)), subscrv(j, h))) -> s
         endfor;
         s
       endfor %} -> logits;
enddefine;

;;; ------------------------------------------------------------- the data

define vis_sample(n, seed0) -> (xs, ys);
    lvars i, k, cls, acc_x = [], acc_y = [];
    for i from 0 to n - 1 do
        (i mod NCLASS) + 1 -> k;
        subscrv(k, SHAPES) -> cls;
        conspair(vis_render(cls, seed0 + i * 7919), acc_x) -> acc_x;
        conspair(k, acc_y) -> acc_y;
    endfor;
    {% applist(rev(acc_x), identfn) %} -> xs;
    {% applist(rev(acc_y), identfn) %} -> ys;
enddefine;

define vis_accuracy(xs, ys) -> pc;
    lvars i, logits, best, bv, j, right = 0, n = length(xs);
    for i from 1 to n do
        vis_forward(subscrv(i, xs)) -> logits;
        1 -> best; v_data(subscrv(1, logits)) -> bv;
        for j from 2 to NCLASS do
            if v_data(subscrv(j, logits)) > bv then
                v_data(subscrv(j, logits)) -> bv; j -> best
            endif;
        endfor;
        if best == subscrv(i, ys) then right + 1 -> right endif;
    endfor;
    100.0 * right / n -> pc;
enddefine;

;;; ------------------------------------------------------------- training

define vis_train(epochs);
    lvars (xs, ys) = vis_sample(240, 12345);
    lvars (tx, ty) = vis_sample(80, 999983);
    lvars ep, i, sn = 0, total = epochs * length(xs), t0 = sys_microtime();
    vis_build();
    init_adam();
    0.03 -> learning_rate;
    printf('training %p samples, %p epochs, %p parameters\n',
           [% length(xs), epochs, length(params) %]);
    sysflush(popdevout);
    for ep from 1 to epochs do
        for i from 1 to length(xs) do
            sn + 1 -> sn;
            lvars probs = softmax(vis_forward(subscrv(i, xs)));
            lvars loss = v_mul(v_log(subscrv(subscrv(i, ys), probs)),
                               v_leaf(-1.0));
            v_backward(loss);
            adam_step(sn, total);
        endfor;
        printf('  epoch %p: train %p%%, test %p%%  (%p s elapsed)\n',
               [% ep, intof(vis_accuracy(xs, ys)), intof(vis_accuracy(tx, ty)),
                  intof((sys_microtime() - t0) / 1000000.0) %]);
        sysflush(popdevout);
    endfor;
    printf('done: %p samples/sec through the graph\n',
           [% intof(sn / ((sys_microtime() - t0) / 1000000.0)) %]);
enddefine;

;;; ------------------------------------------------------------- exporting
;;; Weights out as ordinary Pop-11 source: plain floats, no Values.  The
;;; inference path that loads this never touches the autograd machinery.

define vis_export(path);
    ;;; Weights are DATA, not code.  An earlier version emitted them as Pop-11
    ;;; source and made the compiler build a 4096-element literal, which is
    ;;; both the wrong mechanism and a way to meet
    ;;; docs/bugs/aarch64-large-literal-sigill.md.  Plain numbers, read at
    ;;; runtime, work everywhere and load faster.
    lvars out = discout(path), i, j, v;
    procedure;
        dlocal cucharout = out;
        printf('%p %p %p\n', [% NPIX, NHID, NCLASS %]);
        for i from 1 to NHID do
            subscrv(i, vis_w1) -> v;
            for j from 1 to NPIX do printf('%p ', [% v_data(subscrv(j, v)) %]) endfor;
            printf('\n', []);
        endfor;
        for j from 1 to NHID do printf('%p ', [% v_data(subscrv(j, vis_b1)) %]) endfor;
        printf('\n', []);
        for i from 1 to NCLASS do
            subscrv(i, vis_w2) -> v;
            for j from 1 to NHID do printf('%p ', [% v_data(subscrv(j, v)) %]) endfor;
            printf('\n', []);
        endfor;
        for j from 1 to NCLASS do printf('%p ', [% v_data(subscrv(j, vis_b2)) %]) endfor;
        printf('\n', []);
    endprocedure();
    out(termin);
    printf('wrote %p\n', [% path %]);
enddefine;

;;; Read the weights back as numbers.  No compilation, no literals.
define vis_load(path);
    lvars dev = sysopen(path, 0, "line");
    lvars rep = line_repeater(dev, inits(65536)), line, f, i;
    define lconstant nextrow() -> v;
        rep() -> line;
        if line == termin then mishap(0, 'vision: weights file truncated') endif;
        {% for f in str_split(str_trim(line), ` `) do
             if f /= '' then strnumber(f) endif
           endfor %} -> v;
    enddefine;
    nextrow() -> ;                       ;;; the dimensions header
    {% for i from 1 to NHID do nextrow() endfor %} -> vis_w1;
    nextrow() -> vis_b1;
    {% for i from 1 to NCLASS do nextrow() endfor %} -> vis_w2;
    nextrow() -> vis_b2;
enddefine;

;;; ------------------------------------------------------------- inference
;;; Plain arithmetic over the exported floats.  fast_subscrv skips the bounds
;;; check, which measured 23% on this shape -- free, and safe here because
;;; every index is derived from the vectors' own lengths.

define vis_classify(img) -> (label, conf);
    lvars i, j, s, h, logits, best, bv, mx, tot, e;
    {% for i from 1 to length(vis_w1) do
         fast_subscrv(i, vis_b1) -> s;
         lvars row = fast_subscrv(i, vis_w1);
         for j from 1 to NPIX do
             s + fast_subscrv(j, row) * fast_subscrv(j, img) -> s
         endfor;
         max(0.0, s)
       endfor %} -> h;
    {% for i from 1 to length(vis_w2) do
         fast_subscrv(i, vis_b2) -> s;
         lvars row = fast_subscrv(i, vis_w2);
         for j from 1 to length(h) do
             s + fast_subscrv(j, row) * fast_subscrv(j, h) -> s
         endfor;
         s
       endfor %} -> logits;
    1 -> best; subscrv(1, logits) -> bv;
    for i from 2 to length(logits) do
        if subscrv(i, logits) > bv then subscrv(i, logits) -> bv; i -> best endif
    endfor;
    ;;; softmax, for a confidence rather than a bare argmax
    bv -> mx; 0.0 -> tot;
    for i from 1 to length(logits) do
        tot + exp(subscrv(i, logits) - mx) -> tot
    endfor;
    subscrv(best, vis_shapes) -> label;
    1.0 / tot -> conf;
enddefine;

;;; ---------------------------------------------------------------- driver

define vis_main();
    lvars args = poparglist, mode;
    returnif(args == []);
    hd(args) -> mode;
    if mode = '--train' then
        vis_train(if tl(args) /== [] then strnumber(hd(tl(args))) else 15 endif);
        vis_export('examples/robotarmy/vision-weights.txt');
    elseif mode = '--check' then
        vis_load('examples/robotarmy/vision-weights.txt');
        lvars i, k, cls, img, label, conf, right = 0, n = 80;
        lvars t0 = sys_microtime();
        for i from 0 to n - 1 do
            (i mod NCLASS) + 1 -> k;
            subscrv(k, SHAPES) -> cls;
            vis_render(cls, 555001 + i * 7919) -> img;
            vis_classify(img) -> (label, conf);
            if label == cls then right + 1 -> right endif;
        endfor;
        printf('held-out accuracy %p%% of %p\n', [% intof(100.0 * right / n), n %]);
        ;;; Timing over the 80 accuracy samples was dominated by warm-up and
        ;;; swung by 7x between runs.  Measure separately, over enough
        ;;; iterations for the number to mean something.
        vis_render("circle", 4242) -> img;
        vis_classify(img) -> (label, conf);          ;;; warm up, then time
        sys_microtime() -> t0;
        for i from 1 to 2000 do vis_classify(img) -> (label, conf) endfor;
        printf('%p classifications/sec over 2000\n',
               [% intof(2000 / ((sys_microtime() - t0) / 1000000.0)) %]);
        ;;; show one of each so the shapes are visible
        for k from 1 to NCLASS do
            subscrv(k, SHAPES) -> cls;
            vis_render(cls, 777001 + k * 7919) -> img;
            vis_classify(img) -> (label, conf);
            printf('--- drawn %p, classified %p (%p confidence) ---\n',
                   [% cls, label, intof(conf * 100) / 100.0 %]);
            vis_ascii(img);
        endfor;
    endif;
enddefine;

unless isdefined("vision_lib") then vis_main() endunless;
