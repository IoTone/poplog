/* examples/langpop/langpop.p -- langpop, Proposal A: one heap, three languages.

   The language graph is Prolog, the learner overlay is Pop-11, and the
   session is the process.  Nothing is serialised, no server is started
   and no model is consulted: when A is wrong about something, it is
   wrong in one address space, which is the only reason to build it first.

       ./poplog basepop11 examples/langpop/langpop.p            # Japanese
       ./poplog basepop11 examples/langpop/langpop.p --lang en  # English

   The division of labour is the design:

     Prolog owns what does not change -- items, forms, prerequisites,
       ladders, exit criteria, the catalogue.  It is loaded from the
       files under graph/ and never asserted into at run time.

     Pop-11 owns what changes every turn -- who the student is, what they
       are believed to know, and the evidence for it.  Three Pop-11
       procedures (lp_known/2, lp_known_now/1, lp_take/1) are PROLOG
       PREDICATES, so a rule in schema.pl can consult the overlay without
       knowing it is not a table.  That is the whole boundary.
*/

uses prolog;
uses define_prolog;
uses json;

;;; ------------------------------------------------------------- locating
vars langpop_dir = 'examples/langpop/';

define find_dir() -> d;
    lvars c;
    for c in ['examples/langpop/' './' '../' 'langpop/'] do
        if sys_file_exists(c <> 'graph/schema.pl') then c -> d; return endif;
    endfor;
    'examples/langpop/' -> d;
enddefine;

;;; ------------------------------------------------- the overlay, in Pop-11
;;; Keys are words, not strings, because a word is interned and property
;;; lookup is identity: two strings spelled alike are different keys.

vars
    lp_taken    = [],                                   ;;; capture buffer
    lp_kind     = newproperty([], 512, false, "perm"),
    lp_ilang    = newproperty([], 512, false, "perm"),
    lp_ilevel   = newproperty([], 512, false, "perm"),
    lp_isrc     = newproperty([], 512, false, "perm"),
    lp_forms    = newproperty([], 512, [], "perm"),     ;;; item -> [[script text] ...]
    lp_gl       = newproperty([], 512, [], "perm"),     ;;; item -> [[lang text] ...]
    lp_confs    = newproperty([], 256, [], "perm"),     ;;; item -> [[other why] ...]
    lp_beliefs  = newproperty([], 1024, 0.0, "perm"),
    lp_items    = [],
    lp_ladders  = [],                                   ;;; [[lang n level] ...]
    lp_exits    = [],                                   ;;; [[lang level crit th ms] ...]
    lp_rsrc     = [],                                   ;;; [[id lang kind target url checked] ...]
    lp_gens     = [],                                   ;;; [[source lang level n date] ...]
    lp_journal  = [],
    lp_assigns  = [],
    lp_user     = false,
    lp_display  = false,
    lp_lang     = "ja",
    lp_level    = "preschool",
    lp_corrections = [],
;

;;; Belief thresholds.  These three numbers are the evidence policy, and
;;; they are deliberately in one place:
;;;
;;;   MASTERY   what "known" means, and so what unlocks the next item
;;;   TIER2_CAP a self-reported RESULT ("18 out of 20") can carry an item
;;;             to just below mastery and no further, so one verified
;;;             check is always what tips it over
;;;   TIER3_CAP a self-reported COMPLIANCE ("I did it") cannot reach
;;;             mastery at all, by arithmetic rather than by good
;;;             intentions
constant MASTERY = 0.80, TIER2_CAP = 0.78, TIER3_CAP = 0.50;

define lp_bkey(user, item, ch) -> k;
    lvars user, item, ch;
    consword((user sys_>< '') <> '|' <> (item sys_>< '') <> '|' <> (ch sys_>< '')) -> k;
enddefine;

;;; The channel an item is judged on.  A sound is heard, a pattern is
;;; produced, everything else is read.  Three beliefs per item exist in
;;; the store; this is the one that gates the prerequisite graph.
define lp_primary(item) -> ch;
    lvars item, k = lp_kind(item);
    if k == "sound" then "hear"
    elseif k == "pattern" then "produce"
    else "read"
    endif -> ch;
enddefine;

define lp_bel(item, ch) -> b;
    lvars item, ch;
    lp_beliefs(lp_bkey(lp_user, item, ch)) -> b;
enddefine;

define lp_mastered(item);
    lvars item;
    lp_bel(item, lp_primary(item)) >= MASTERY
enddefine;

;;; -------------------------------------- Pop-11 procedures AS predicates
;;; lp_known/2 is the join: schema.pl's ready/4 calls it as if it were a
;;; table of facts, and it is a property lookup over evidence recorded
;;; this minute.  Succeeding means calling the continuation; not calling
;;; it is failure.  No binding, so no prolog_unifyc here.

define :prolog lp_known/2(s, i, contn);
    lvars s, i, contn;
    if lp_mastered(prolog_deref(i)) then chain(contn) endif;
enddefine;

define :prolog lp_known_now/1(i, contn);
    lvars i, contn;
    if lp_mastered(prolog_deref(i)) then chain(contn) endif;
enddefine;

define :prolog lp_take/1(x, contn);
    lvars x, contn;
    conspair(prolog_full_deref(x), lp_taken) -> lp_taken;
    chain(contn);
enddefine;

define :prolog lp_item/5(i, k, l, lv, s, contn);
    lvars i, k, l, lv, s, contn, id = prolog_deref(i);
    prolog_deref(k) -> lp_kind(id);
    prolog_deref(l) -> lp_ilang(id);
    prolog_deref(lv) -> lp_ilevel(id);
    prolog_full_deref(s) -> lp_isrc(id);
    conspair(id, lp_items) -> lp_items;
    chain(contn);
enddefine;

define :prolog lp_form/3(i, sc, t, contn);
    lvars i, sc, t, contn, id = prolog_deref(i);
    lp_forms(id) <> [[% prolog_deref(sc), prolog_deref(t) %]] -> lp_forms(id);
    chain(contn);
enddefine;

define :prolog lp_gloss/3(i, lg, t, contn);
    lvars i, lg, t, contn, id = prolog_deref(i);
    lp_gl(id) <> [[% prolog_deref(lg), prolog_deref(t) %]] -> lp_gl(id);
    chain(contn);
enddefine;

define :prolog lp_conf/3(a, b, w, contn);
    lvars a, b, w, contn, x = prolog_deref(a), y = prolog_deref(b),
          why = prolog_full_deref(w);
    lp_confs(x) <> [[% y, why %]] -> lp_confs(x);
    lp_confs(y) <> [[% x, why %]] -> lp_confs(y);
    chain(contn);
enddefine;

define :prolog lp_ladder/3(l, n, lv, contn);
    lvars l, n, lv, contn;
    lp_ladders <> [[% prolog_deref(l), prolog_deref(n), prolog_deref(lv) %]]
        -> lp_ladders;
    chain(contn);
enddefine;

define :prolog lp_exit/5(l, lv, c, th, ms, contn);
    lvars l, lv, c, th, ms, contn;
    lp_exits <> [[% prolog_deref(l), prolog_deref(lv), prolog_full_deref(c),
                    prolog_deref(th), prolog_deref(ms) %]] -> lp_exits;
    chain(contn);
enddefine;

define :prolog lp_generated/5(sc, l, lv, n, d, contn);
    lvars sc, l, lv, n, d, contn;
    lp_gens <> [[% prolog_deref(sc), prolog_deref(l), prolog_deref(lv),
                   prolog_deref(n), prolog_deref(d) %]] -> lp_gens;
    chain(contn);
enddefine;

define :prolog lp_resource/6(r, l, k, t, u, c, contn);
    lvars r, l, k, t, u, c, contn;
    lp_rsrc <> [[% prolog_deref(r), prolog_deref(l), prolog_deref(k),
                   prolog_deref(t), prolog_deref(u), prolog_deref(c) %]] -> lp_rsrc;
    chain(contn);
enddefine;

;;; ------------------------------------------------------ plain files
define lp_read_file(path) -> s;
    lvars path, dev = false, c, n = 0;
    false -> s;
    returnunless(sys_file_exists(path));
    discin(path) -> dev;
    repeat
        dev() -> c;
        quitif(c == termin);
        c; n + 1 -> n;
    endrepeat;
    consstring(n) -> s;
enddefine;

define lp_write_file(path, s);
    lvars path, s, dev = discout(path), c;
    for c in_string s do dev(c) endfor;
    dev(termin);
enddefine;

;;; ----------------------------------------------------- loading the graph
;;; One compile, not seven.  Poplog Prolog's prolog_compile has RECONSULT
;;; semantics per predicate: a second file that defines item/5 silently
;;; replaces the clauses the first one gave it, and `:- dynamic` does not
;;; change that.  So the graph is concatenated and compiled once.  The
;;; files stay separate on disk, because a per-language file is the unit
;;; a human curates, and the manifest below is the load order.
lconstant GRAPH_FILES = ['graph/schema.pl' 'graph/resources.pl'
                         'graph/ja/ladder.pl' 'graph/ja/kana.pl'
                         'graph/ja/items.pl'
                         'graph/en/ladder.pl' 'graph/en/items.pl'];

;;; The imported levels.  Each of these is a BUILD PRODUCT written by
;;; import.p out of upstream reference data; none is committed, and the
;;; one difference from GRAPH_FILES above is that a MISSING one is not an
;;; error -- it is a level whose content has not been built, which is a
;;; thing the graph can say (schema.pl's content_built/2) and the tutor
;;; can pass on.
;;;
;;; A declared list and not a directory scan, for two reasons.  The small
;;; one is that sys_file_match has a known defect on macOS.  The real one
;;; is that a curator who adds an import should have to say so here: a
;;; graph that grew a level because a file appeared in a build directory
;;; is not a graph anybody can reason about.
lconstant GRAPH_GENERATED = ['graph/ja/generated/n5-kanji.pl'
                             'graph/ja/generated/n5-words.pl'];

;;; Load the graph, optionally holding one generated file back.  The
;;; importer is why that argument exists: it reads the graph to check that
;;; an id is not already taken, and its own previous output would
;;; otherwise answer yes to every id it is about to write again.
define lp_load_except(skip);
    lvars skip, f, src = '', s;
    for f in GRAPH_FILES do
        lp_read_file(langpop_dir <> f) -> s;
        unless s then mishap(langpop_dir <> f, 1, 'langpop: graph file missing') endunless;
        src <> '\n% ==== ' <> f <> '\n' <> s -> src;
    endfor;
    for f in GRAPH_GENERATED do
        nextif(skip and f = skip);
        lp_read_file(langpop_dir <> f) -> s;
        nextunless(s);                  ;;; not built: see above
        src <> '\n% ==== ' <> f <> '\n' <> s -> src;
    endfor;
    prolog_compile(stringin(src));
enddefine;

define lp_load();
    lp_load_except(false);
enddefine;

;;; Run a goal and collect whatever it handed to lp_take/1.  Every query
;;; in this file goes through here, which is why there is no string
;;; building: the goal is a term, made in Pop-11.
define lp_ask(/* args */ name, arity) -> answers;
    lvars name, arity, answers;
    [] -> lp_taken;
    erase(prolog_invoke(prolog_maketerm(/* args */ name, arity)));
    rev(lp_taken) -> answers;
enddefine;

define lp_index();
    ;;; The properties are cleared and not merely overwritten.  index/0
    ;;; only ever ASSIGNS, so a second load left every item of the first
    ;;; one still answering lp_ilang -- which the importer found the hard
    ;;; way: it loads the graph twice on purpose, and the second pass
    ;;; reported all 120 of its own previous ids as already taken.
    clearproperty(lp_kind); clearproperty(lp_ilang);
    clearproperty(lp_ilevel); clearproperty(lp_isrc);
    clearproperty(lp_forms); clearproperty(lp_gl); clearproperty(lp_confs);
    [] -> lp_items; [] -> lp_ladders; [] -> lp_exits; [] -> lp_rsrc;
    [] -> lp_gens;
    lp_ask("index", 0).erase;
    rev(lp_items) -> lp_items;
enddefine;

;;; ------------------------------------------------------- reading the graph
define lp_form_of(item, script) -> t;
    lvars item, script, p;
    false -> t;
    for p in lp_forms(item) do
        if hd(p) == script then hd(tl(p)) -> t; return endif;
    endfor;
enddefine;

define lp_any_form(item) -> t;
    lvars item, script;
    for script in [hiragana katakana kanji latin ipa romaji] do
        lp_form_of(item, script) -> t;
        returnif(t);
    endfor;
    item -> t;
enddefine;

define lp_gloss_of(item, lang) -> t;
    lvars item, lang, p;
    false -> t;
    for p in lp_gl(item) do
        if hd(p) == lang then hd(tl(p)) -> t; return endif;
    endfor;
enddefine;

define lp_levels(lang) -> ls;
    lvars lang, l;
    [] -> ls;
    for l in lp_ladders do
        if hd(l) == lang then conspair(hd(tl(tl(l))), ls) -> ls endif;
    endfor;
    rev(ls) -> ls;
enddefine;

;;; What the student may be taught next, straight out of ready/4.
define lp_plan() -> items;
    lvars items;
    lp_ask(lp_user, lp_lang, lp_level, "plan", 3) -> items;
enddefine;

;;; A term printed the way Prolog wrote it, without pulling in the
;;; Prolog writer: enough for why/1's known(X) and missing(X).
define lp_term_str(t) -> s;
    lvars t, i, n;
    if prolog_complexterm(t) then
        (prolog_functor(t) sys_>< '') <> '(' -> s;
        prolog_arity(t) -> n;
        for i from 1 to n do
            s <> lp_term_str(prolog_full_deref(prolog_arg(i, t))) -> s;
            if i < n then s <> ', ' -> s endif;
        endfor;
        s <> ')' -> s;
    else
        t sys_>< '' -> s;
    endif;
enddefine;

;;; ------------------------------------------------------------- evidence
;;; Latency is load-bearing here -- every pre-school exit criterion has a
;;; millisecond budget -- so it needs a REAL clock and not a CPU one.
;;; systime() is CPU time and barely moves while we wait for a human to
;;; type; sys_microtime() is microseconds of wall clock since the epoch
;;; (REF * TIMES, and now HELP * CLOCK, which did not mention it -- which
;;; is why this first shipped measuring whole seconds).  Measured at
;;; 354,849us across a 350ms sleep, with systime() at 0 over the same wait.
define lp_now_ms() -> ms;
    lvars ms;
    sys_microtime() div 1000 -> ms;
enddefine;

define lp_record(item, ch, tier, correct, latency_ms);
    lvars item, ch, tier, correct, latency_ms, b = lp_bel(item, ch), nb;
    if tier == 1 then
        if correct then b + (1.0 - b) * 0.45 else b * 0.35 endif
    elseif tier == 2 then
        min(b + (1.0 - b) * 0.20 * (if correct then 1.0 else 0.3 endif), TIER2_CAP)
    else
        min(b + 0.05, TIER3_CAP)
    endif -> nb;
    nb -> lp_beliefs(lp_bkey(lp_user, item, ch));
    conspair({% item, ch, tier, correct, latency_ms, lp_now_ms() %}, lp_journal)
        -> lp_journal;
enddefine;

;;; Accuracy and speed over the tier-1 evidence for one item set.  Speed
;;; is reported separately and never averaged into accuracy: a student
;;; who is right slowly has not learned to read, and one number would
;;; hide that.
define lp_measure(items, latency_ms) -> (acc, fast, n);
    lvars items, latency_ms, e, right = 0, quick = 0, n = 0;
    for e in lp_journal do
        nextunless(e(3) == 1 and member(e(1), items));
        n + 1 -> n;
        if e(4) then right + 1 -> right;
            if e(5) <= latency_ms then quick + 1 -> quick endif;
        endif;
    endfor;
    ;;; Floats, not Pop-11 ratios.  right / n on two integers is an exact
    ;;; rational here, which prints oddly, compares equal to the float it
    ;;; denotes (so a test does not notice), and cannot be serialised at
    ;;; all -- json_generate refuses it as an "unsupported item", which is
    ;;; how the server found this.
    if n == 0 then (0.0, 0.0, 0) -> (acc, fast, n)
    else ((right * 1.0) / n, (quick * 1.0) / n, n) -> (acc, fast, n)
    endif;
enddefine;

;;; --------------------------------------------------------- the persona
;;; A persona is a data file, not code.  What a teacher says is content,
;;; reviewed by a speaker of the language; the engine only cycles through
;;; the lines, which is Weizenbaum's reassembly rule and for once exactly
;;; the right mechanism.

vars lp_persona = false, lp_cycle = newproperty([], 32, 1, "perm");

define lp_load_persona(name);
    lvars name, s = lp_read_file(langpop_dir <> 'personas/' <> name <> '.json');
    if s then json_parse(s) -> lp_persona else false -> lp_persona endif;
enddefine;

;;; Round-robin, so the teacher does not say the same thing twice running.
define lp_line(key) -> s;
    lvars key, lines, i;
    '' -> s;
    returnunless(lp_persona);
    lp_persona(key) -> lines;
    returnunless(lines and isvector(lines) and length(lines) > 0);
    lp_cycle(key) -> i;
    if i > length(lines) then 1 -> i endif;
    lines(i) -> s;
    i + 1 -> lp_cycle(key);
enddefine;

define lp_teacher_name() -> n;
    lvars n = 'the teacher';
    if lp_persona and lp_persona('name') then lp_persona('name') -> n endif;
enddefine;

define lp_say(key);
    printf('%p\n', [% lp_line(key) %]);
enddefine;

;;; The introduction happens once, however the session was started.
vars lp_greeted = false;

define lp_greet();
    unless lp_greeted then true -> lp_greeted; lp_say('greeting') endunless;
enddefine;

;;; ----------------------------------------------------------- the profile
;;; Persistence is a file per student plus one roll, because the roll is
;;; what lets the teacher recognise somebody -- and misrecognise them.

;;; Where profiles live.  Overridable because two callers need it to be:
;;; the test suite, which must not write into a real person's home, and
;;; the server (server.p --data DIR), which may hold a different roll
;;; than the one the local TUI uses.
vars lp_home_dir = false;

define lp_home() -> d;
    lvars d;
    if lp_home_dir then
        lp_home_dir -> d;
        unless d /= '' and d(length(d)) == `/` then d <> '/' -> d endunless;
    else
        systranslate('HOME') -> d;
        unless d then '.' -> d endunless;
        d <> '/.langpop/' -> d;
    endif;
enddefine;

define lp_profile_path(user) -> p;
    lvars user, p = lp_home() <> (user sys_>< '') <> '.json';
enddefine;

define lp_ensure_home();
    unless sys_file_exists(lp_home()) then
        sysobey('mkdir -p ' <> lp_home());
    endunless;
enddefine;

define lp_roll() -> r;
    lvars s = lp_read_file(lp_home() <> 'roll.json'), r;
    if s then json_parse(s) -> r else newmapping([], 8, false, true) -> r endif;
enddefine;

define lp_roll_add(user, display);
    lvars user, display, r = lp_roll();
    display -> r(user sys_>< '');
    lp_ensure_home();
    lp_write_file(lp_home() <> 'roll.json', json_generate(r));
enddefine;

define lp_save();
    lvars o = newmapping([], 16, false, true),
          b = newmapping([], 256, false, true),
          j = [], e, a;
    returnunless(lp_user);
    lp_user sys_>< '' -> o('user');
    lp_display -> o('display');
    lp_lang sys_>< '' -> o('lang');
    lp_level sys_>< '' -> o('level');
    appproperty(lp_beliefs,
        procedure(k, v); v -> b(k sys_>< '') endprocedure);
    b -> o('beliefs');
    for e in lp_journal do
        conspair({% e(1) sys_>< '', e(2) sys_>< '', e(3), e(4), e(5), e(6) %}, j) -> j;
    endfor;
    consvector(#| for e in j do e endfor |#) -> o('journal');
    consvector(#| for a in lp_assigns do
                      {% a(1), a(2) sys_>< '', a(3) sys_>< '', a(4), a(5) %}
                  endfor |#) -> o('assignments');
    consvector(#| for a in lp_corrections do a endfor |#) -> o('corrections');
    lp_ensure_home();
    lp_write_file(lp_profile_path(lp_user), json_generate(o));
enddefine;

define lp_load_profile(user) -> found;
    lvars user, s = lp_read_file(lp_profile_path(user)), o, i, v, e;
    false -> found;
    returnunless(s);
    json_parse(s) -> o;
    true -> found;
    o('display') -> lp_display;
    if o('lang') then consword(o('lang')) -> lp_lang endif;
    if o('level') then consword(o('level')) -> lp_level endif;
    if o('beliefs') then
        appproperty(o('beliefs'),
            procedure(k, v); v -> lp_beliefs(consword(k)) endprocedure);
    endif;
    [] -> lp_journal;
    if o('journal') then
        for i from 1 to length(o('journal')) do
            o('journal')(i) -> e;
            conspair({% consword(e(1)), consword(e(2)), e(3), e(4), e(5), e(6) %},
                     lp_journal) -> lp_journal;
        endfor;
    endif;
    ;;; Assignments outlive the session on purpose: the whole point of
    ;;; assigning work is that it is done BETWEEN sessions and reported
    ;;; next time.  Saving them without reading them back meant ":report 1"
    ;;; answered "No assignment 1." the following day.
    [] -> lp_assigns;
    if o('assignments') then
        for i from 1 to length(o('assignments')) do
            o('assignments')(i) -> e;
            lp_assigns <> [{% e(1), consword(e(2)), consword(e(3)),
                              e(4), e(5) %}] -> lp_assigns;
        endfor;
    endif;
    [] -> lp_corrections;
    if o('corrections') then
        for i from 1 to length(o('corrections')) do
            conspair(o('corrections')(i), lp_corrections) -> lp_corrections;
        endfor;
    endif;
enddefine;

;;; -------------------------------------------------------- reading input
define lp_readline() -> line;
    lvars c, n = 0;
    repeat
        charin() -> c;
        if c == termin then
            if n == 0 then termin -> line; return endif;
            quitloop;
        endif;
        quitif(c == `\n`);
        c; n + 1 -> n;
    endrepeat;
    consstring(n) -> line;
enddefine;

define lp_trim(s) -> t;
    lvars s, i = 1, j;
    if s == termin then '' -> t; return endif;
    length(s) -> j;
    while i <= j and s(i) == ` ` do i + 1 -> i endwhile;
    while j >= i and s(j) == ` ` do j - 1 -> j endwhile;
    if j < i then '' else substring(i, j - i + 1, s) endif -> t;
enddefine;

define lp_lower(s) -> t;
    lvars s, c, n = 0;
    for c in_string s do
        if c >= `A` and c <= `Z` then c + 32 else c endif; n + 1 -> n;
    endfor;
    consstring(n) -> t;
enddefine;

define lp_norm(s) -> t;
    lp_lower(lp_trim(s)) -> t;
enddefine;

;;; ------------------------------------------------------------- questions
;;; Three question shapes, all judged exactly.  No model is involved and
;;; none is needed: at this level the right answer is a string, and
;;; pretending otherwise would only add a way to be wrong.

vars lp_flip = 0;                       ;;; deterministic option order, so tests repeat

define lp_question(item) -> (shape, prompt, answer, options);
    lvars item, k = lp_kind(item), r, en, ja, glyph;
    ("none", '', '', []) -> (shape, prompt, answer, options);
    lp_form_of(item, "romaji") -> r;
    if (k == "grapheme" or k == "word") and r then
        lp_any_form(item) -> glyph;
        ("type", glyph sys_>< '', lp_lower(r sys_>< ''), []) -> (shape, prompt, answer, options);
    elseif k == "word" and lp_ilang(item) == "en" then
        lp_gloss_of(item, "en") -> en;
        lp_gloss_of(item, "ja") -> ja;
        if en and ja then
            lp_flip + 1 -> lp_flip;
            if lp_flip mod 2 == 1 then
                ("pick", lp_form_of(item, "latin") sys_>< '', '1', [^en ^ja])
            else
                ("pick", lp_form_of(item, "latin") sys_>< '', '2', [^ja ^en])
            endif -> (shape, prompt, answer, options);
        endif;
    endif;
enddefine;

define lp_drillable(item);
    lvars item, shape;
    lp_question(item) -> (shape, , , );
    shape /== "none"
enddefine;

;;; The confusable that the student probably meant.  This is why the
;;; graph records pairs: a wrong answer is diagnosable, not just wrong.
define lp_mistook(item, typed) -> other;
    lvars item, typed, p, r;
    false -> other;
    for p in lp_confs(item) do
        lp_form_of(hd(p), "romaji") -> r;
        if r and lp_lower(r sys_>< '') = typed then hd(p) -> other; return endif;
    endfor;
enddefine;

define lp_drill(item) -> done;
    lvars item, shape, prompt, answer, options, o, i = 0, t0, line, typed;
    true -> done;
    lp_question(item) -> (shape, prompt, answer, options);
    returnif(shape == "none")(false -> done);
    if shape == "type" then
        printf('\n  %p    -> ', [^prompt]);
    else
        printf('\n  %p\n', [^prompt]);
        for o in options do i + 1 -> i; printf('    %p) %p\n', [% i, o %]) endfor;
        printf('  -> ');
    endif;
    sysflush(popdevout);
    lp_now_ms() -> t0;
    lp_readline() -> line;
    if line == termin then false -> done; return endif;
    lp_norm(line) -> typed;
    if typed = answer then
        lp_record(item, lp_primary(item), 1, true, lp_now_ms() - t0);
        printf('  %p\n', [% lp_line('praise') %]);
    else
        lp_record(item, lp_primary(item), 1, false, lp_now_ms() - t0);
        lvars other = lp_mistook(item, typed);
        if other then
            printf('  %p  That is %p -- the two are confused constantly.\n',
                   [% lp_line('almost'), lp_any_form(other) %]);
        else
            printf('  %p  It is %p.\n', [% lp_line('wrong'), answer %]);
        endif;
    endif;
enddefine;

;;; ----------------------------------------------------------- assignments
;;; What cannot be verified in the session is assigned and self-reported.
;;; A report carries a tier, and the tier is what keeps an honest student
;;; and an optimistic one apart without calling either a liar.

define lp_resource_for(item) -> r;
    lvars item, e;
    false -> r;
    for e in lp_rsrc do
        if hd(tl(tl(tl(e)))) == item then e -> r; return endif;
    endfor;
    for e in lp_rsrc do
        if hd(tl(e)) == lp_lang and hd(tl(tl(tl(e)))) == lp_level then
            e -> r; return
        endif;
    endfor;
enddefine;

define lp_assign() -> a;
    lvars a = false, item, r, plan = lp_plan();
    for item in plan do
        nextif(lp_drillable(item));
        lp_resource_for(item) -> r;
        nextunless(r);
        {% length(lp_assigns) + 1, item, hd(r), lp_now_ms(), 'open' %} -> a;
        lp_assigns <> [^a] -> lp_assigns;
        printf('\n  Assignment %p: %p\n', [% a(1), lp_any_form(item) %]);
        if lp_gloss_of(item, "en") then
            printf('    %p\n', [% lp_gloss_of(item, "en") %]);
        endif;
        printf('    %p   (%p, checked %p)\n',
               [% hd(tl(tl(tl(tl(r))))), hd(tl(tl(r))), hd(tl(tl(tl(tl(tl(r)))))) %]);
        printf('  %p\n', [% lp_line('assign') %]);
        return;
    endfor;
    printf('  Nothing to assign: everything ready for you can be checked here.\n');
enddefine;

define lp_find_assign(id) -> a;
    lvars id, e;
    false -> a;
    for e in lp_assigns do if e(1) == id then e -> a; return endif endfor;
enddefine;

;;; outcome is 'ok'/'done' (compliance, tier 3) or 'n/m' (a result, tier 2)
define lp_report(id, outcome) -> ok;
    lvars id, outcome, a = lp_find_assign(id), c, got, tot, frac, tier;
    false -> ok;
    unless a then printf('  No assignment %p.\n', [^id]); return endunless;
    locchar(`/`, 1, outcome) -> c;
    if c then
        strnumber(substring(1, c - 1, outcome)) -> got;
        strnumber(allbutfirst(c, outcome)) -> tot;
        unless got and tot and tot > 0 then
            printf('  Report it as "ok", or as a score like 17/20.\n'); return
        endunless;
        (got * 1.0) / tot -> frac;
        2 -> tier;
        lp_record(a(2), lp_primary(a(2)), 2, frac >= 0.7, 0);
        printf('  Recorded: %p of %p, as reported evidence (tier 2).\n', [% got, tot %]);
        printf('  A reported score carries an item to just below mastery;\n');
        printf('  the next check here is what settles it.\n');
    else
        3 -> tier;
        lp_record(a(2), lp_primary(a(2)), 3, true, 0);
        printf('  Recorded: done, as compliance (tier 3).\n');
        printf('  Compliance alone cannot reach mastery -- tell me a result\n');
        printf('  next time, or let me check you here.\n');
    endif;
    {% a(1), a(2), a(3), a(4), 'reported' %} -> a;
    [% lvars e; for e in lp_assigns do
           if e(1) == id then a else e endif endfor %] -> lp_assigns;
    true -> ok;
enddefine;

;;; ----------------------------------------------------------------- status
define lp_count_mastered(kind) -> n;
    lvars kind, i, n = 0;
    for i in lp_items do
        if lp_kind(i) == kind and lp_ilang(i) == lp_lang and lp_mastered(i) then
            n + 1 -> n
        endif;
    endfor;
enddefine;

;;; The kanji criterion.  NOT lp_count_mastered("grapheme"): the kana are
;;; graphemes too, and the 92 of them at pre-school would satisfy
;;; kanji(100) before the student had met a single character.  What counts
;;; is a grapheme with a kanji form, which is what the import makes.
;;;
;;; This arm exists because the import made the criterion measurable for
;;; the first time.  Until there were kanji in the graph, kanji(100) fell
;;; through to the measured branch, where criterion_item/2 has no clause
;;; for a count -- so it reported 0% over 0 answers, which reads like a
;;; student who has got everything wrong rather than a criterion nothing
;;; was counting.
define lp_count_mastered_kanji() -> n;
    lvars i, n = 0;
    for i in lp_items do
        if lp_kind(i) == "grapheme" and lp_ilang(i) == lp_lang
        and lp_form_of(i, "kanji") and lp_mastered(i) then
            n + 1 -> n
        endif;
    endfor;
enddefine;

;;; How many of a criterion's countable items the graph even holds, so the
;;; tutor can say "148 of the 800 are in the graph" rather than implying
;;; the student is short of 652 they have never been shown.
define lp_count_items(kind) -> n;
    lvars i, n = 0;
    for i in lp_items do
        if lp_ilang(i) == lp_lang and lp_ilevel(i) == lp_level
        and (if kind == "kanji" then
                 lp_kind(i) == "grapheme" and lp_form_of(i, "kanji")
             else lp_kind(i) == kind endif) then
            n + 1 -> n
        endif;
    endfor;
enddefine;

define lp_status();
    lvars e, c, th, ms, items, acc, fast, n, want;
    printf('\n  %p, %p -- level %p\n',
           [% lp_display or (lp_user sys_>< ''), lp_lang, lp_level %]);
    for e in lp_exits do
        nextunless(hd(e) == lp_lang and hd(tl(e)) == lp_level);
        hd(tl(tl(e))) -> c; hd(tl(tl(tl(e)))) -> th; hd(tl(tl(tl(tl(e))))) -> ms;
        if prolog_complexterm(c) and prolog_functor(c) == "vocabulary" then
            prolog_full_deref(prolog_arg(1, c)) -> want;
            printf('    %p: %p of %p words mastered (%p in the graph)\n',
                   [% lp_term_str(c), lp_count_mastered("word"), want,
                      lp_count_items("word") %]);
        elseif prolog_complexterm(c) and prolog_functor(c) == "kanji" then
            prolog_full_deref(prolog_arg(1, c)) -> want;
            printf('    %p: %p of %p kanji mastered (%p in the graph)\n',
                   [% lp_term_str(c), lp_count_mastered_kanji(), want,
                      lp_count_items("kanji") %]);
        elseif prolog_complexterm(c) and prolog_functor(c) == "coverage" then
            printf('    %p: needs the content build (not measured yet)\n',
                   [% lp_term_str(c) %]);
        else
            lp_ask(c, "criterion_items", 1) -> items;
            lp_measure(items, ms) -> (acc, fast, n);
            printf('    %p: %p%% right, %p%% within %pms, over %p answers (need %p)\n',
                   [% lp_term_str(c), round(acc * 100), round(fast * 100),
                      ms, n, round(th * 100) %]);
        endif;
    endfor;
    printf('    %p items ready to teach now\n', [% length(lp_plan()) %]);
enddefine;

define lp_why(item);
    lvars item, answers, a;
    unless lp_kind(item) then printf('  I have no item called %p.\n', [^item]); return endunless;
    printf('\n  %p  (%p, %p, %p)\n',
           [% lp_any_form(item), lp_kind(item), lp_ilevel(item),
              lp_term_str(lp_isrc(item)) %]);
    if lp_gloss_of(item, "en") then printf('    %p\n', [% lp_gloss_of(item, "en") %]) endif;
    lp_ask(item, "why", 1) -> answers;
    if answers == [] then
        printf('    no prerequisites: this is a place to start\n');
    else
        for a in answers do printf('    %p\n', [% lp_term_str(a) %]) endfor;
    endif;
    printf('    belief %p on channel %p (mastery is %p)\n',
           [% lp_bel(item, lp_primary(item)), lp_primary(item), MASTERY %]);
enddefine;

;;; -------------------------------------------------- who is at the keyboard
;;; The student is whoever is using the computer, keyed by a username.  No
;;; password: this is a local tool and a password would only be theatre.
;;;
;;; The teacher is allowed to MISremember.  Offering the nearest name and
;;; being corrected is how a person recognises somebody, and the
;;; correction is kept, so the same wrong guess is never made twice.

define lp_roll_guess(user) -> (other, display);
    lvars user, r = lp_roll(), u = user sys_>< '', best = false, bd = false,
          refused, c;
    (false, false) -> (other, display);
    appproperty(r, procedure(k, v);
        lvars k, v;
        returnif(k = u);
        returnunless(length(k) >= 3 and length(u) >= 3);
        returnunless(substring(1, 3, k) = substring(1, 3, u));
        unless best then k -> best; v -> bd endunless;
    endprocedure);
    returnunless(best);
    for refused in lp_corrections do
        if isvector(refused) and length(refused) >= 1 and refused(1) = bd then
            return
        endif;
    endfor;
    (best, bd) -> (other, display);
enddefine;

define lp_yes(line);
    lvars line, s = lp_norm(line);
    s = 'y' or s = 'yes' or s = 'はい' or s = 'hai'
enddefine;

define lp_register(user, display, batch);
    lvars user, display, batch, guess_u, guess_d, line;
    user -> lp_user;
    if lp_load_profile(user) then
        printf('%p\n', [% lp_line('welcome_back') %]);
        printf('%p, is it not?  Level %p.\n', [% lp_display, lp_level %]);
        return;
    endif;
    lp_greet();
    lp_roll_guess(user) -> (guess_u, guess_d);
    if guess_d and not(batch) then
        printf('Ah -- %p?  (y/n) ', [^guess_d]);
        sysflush(popdevout);
        lp_readline() -> line;
        if line /== termin and lp_yes(line) then
            consword(guess_u) -> lp_user;
            lp_load_profile(lp_user).erase;
            printf('%p\n', [% lp_line('welcome_back') %]);
            return;
        endif;
        printf('My mistake.  And your name?  ');
        sysflush(popdevout);
        lp_readline() -> line;
        if line /== termin then lp_trim(line) -> display endif;
        conspair({% guess_d, display %}, lp_corrections) -> lp_corrections;
    elseif not(display) and not(batch) then
        printf('And your name?  ');
        sysflush(popdevout);
        lp_readline() -> line;
        if line /== termin then lp_trim(line) -> display endif;
    endif;
    unless display then user sys_>< '' -> display endunless;
    display -> lp_display;
    lp_roll_add(user, display);
    printf('%p, then.  We begin at %p.\n', [% lp_display, lp_level %]);
enddefine;

;;; ----------------------------------------------------------------- cards
;;; card.p is loaded on demand: a session that never asks for a card pays
;;; nothing for it, and the TUI works unchanged if the file is absent.
vars lp_card_loaded = false;

define lp_show_card(i);
    lvars i, path, w, h, why;
    ;;; pop11_compile and not `load`: load is a syntax word that takes the
    ;;; rest of the line as a literal filename, so `load (dir <> 'card.p')`
    ;;; tries to open a file called "(dir<>card.p)".
    unless lp_card_loaded then
        pop11_compile(langpop_dir <> 'card.p');
        true -> lp_card_loaded;
    endunless;
    lp_card_render(i, "word") -> (path, w, h, why);
    if why = 'no_such_item' then
        printf('  I have no item called %p.\n', [^i]);
    elseif why = 'no_written_form' then
        printf('  %p has nothing written to draw -- it is a skill.\n', [^i]);
    elseif why then
        printf('  I cannot draw that: %p\n', [^why]);
    else
        printf('  %p  (%p x %p)\n', [% path, w, h %]);
        unless lp_card_open(path) then
            printf('  No viewer here; the file is on disk.\n');
        endunless;
    endif;
enddefine;

;;; ------------------------------------------------------------- the session
define lp_help();
    printf('\n  <enter>          the next thing to learn\n');
    printf('  :plan            what is ready now, and why that order\n');
    printf('  :why <item>      the derivation: prerequisites, source, belief\n');
    printf('  :status          the exit criteria of this level, measured\n');
    printf('  :card <item>     draw it, and open it in the system viewer\n');
    printf('  :assign          something to do away from the keyboard\n');
    printf('  :report <n> ok   done it (compliance)\n');
    printf('  :report <n> 17/20  done it, with a result\n');
    printf('  :level <name>    move the goal\n');
    printf('  :quit            save and stop\n');
enddefine;

define lp_split2(s) -> (a, b);
    lvars s, c = locchar(` `, 1, s);
    if c then (substring(1, c - 1, s), lp_trim(allbutfirst(c, s))) -> (a, b)
    else (s, '') -> (a, b)
    endif;
enddefine;

;;; Which of the ready items to ask about now: the weakest belief first,
;;; and among equals the one asked about least.  Without the second term
;;; the tutor hammers the first item in the plan until it is mastered,
;;; which is how a learner comes to hate a flashcard.
define lp_asked(item) -> n;
    lvars item, e, n = 0;
    for e in lp_journal do
        if e(1) == item then n + 1 -> n endif;
    endfor;
enddefine;

define lp_choose(plan) -> best;
    lvars plan, item, b, a, bb = false, ba = false;
    false -> best;
    for item in plan do
        nextunless(lp_drillable(item));
        lp_bel(item, lp_primary(item)) -> b;
        lp_asked(item) -> a;
        if not(best) or b < bb or (b == bb and a < ba) then
            item -> best; b -> bb; a -> ba;
        endif;
    endfor;
enddefine;

define lp_next();
    lvars item, plan = lp_plan();
    if plan == [] then
        printf('  Nothing is ready at %p -- everything here is either known\n',
               [% lp_level %]);
        printf('  or waiting on something you have not been taught yet.\n');
        return;
    endif;
    lp_choose(plan) -> item;
    if item then lp_drill(item).erase
    else printf('  Nothing here can be checked by typing.  Try :assign.\n')
    endif;
enddefine;

define lp_session();
    lvars line, cmd, arg, a2, id, outcome;
    lp_help();
    repeat
        printf('\n%p> ', [% lp_teacher_name() %]);
        sysflush(popdevout);
        lp_readline() -> line;
        quitif(line == termin);
        lp_trim(line) -> line;
        if line = '' then
            lp_next();
        elseif line(1) == `:` then
            lp_split2(allbutfirst(1, line)) -> (cmd, arg);
            if cmd = 'quit' or cmd = 'q' then quitloop;
            elseif cmd = 'help' or cmd = '?' then lp_help();
            elseif cmd = 'plan' then
                lvars i, n = 0;
                printf('\n');
                for i in lp_plan() do
                    n + 1 -> n;
                    quitif(n > 12);
                    printf('  %p  %p  (belief %p)\n',
                           [% lp_any_form(i), lp_kind(i), lp_bel(i, lp_primary(i)) %]);
                endfor;
                printf('  ... %p ready in all\n', [% length(lp_plan()) %]);
            elseif cmd = 'why' then
                if arg = '' then printf('  :why <item id>\n')
                else lp_why(consword(arg)) endif;
            elseif cmd = 'status' then lp_status();
            elseif cmd = 'card' then
                if arg = '' then printf('  :card <item id>\n')
                else lp_show_card(consword(arg)) endif;
            elseif cmd = 'assign' then lp_assign().erase;
            elseif cmd = 'report' then
                lp_split2(arg) -> (a2, outcome);
                strnumber(a2) -> id;
                if id then lp_report(id, outcome).erase
                else printf('  :report <number> ok|17/20\n') endif;
            elseif cmd = 'level' then
                if member(consword(arg), lp_levels(lp_lang)) then
                    consword(arg) -> lp_level;
                    printf('  Goal is now %p.\n', [% lp_level %]);
                else
                    printf('  Levels for %p: %p\n', [% lp_lang, lp_levels(lp_lang) %]);
                endif;
            elseif cmd = 'whoami' then
                printf('  %p (%p), %p at %p\n',
                       [% lp_display, lp_user, lp_lang, lp_level %]);
            else printf('  I do not know ":%p".  Try :help\n', [^cmd]);
            endif;
        else
            printf('  This is not a conversation yet -- that comes with the\n');
            printf('  dialogue layer.  Try <enter>, or :help.\n');
        endif;
    endrepeat;
    lp_save();
    printf('\n%p\n', [% lp_line('signoff') %]);
enddefine;

;;; ------------------------------------------------------------------ main
define lp_check() -> bad;
    lvars bad;
    lp_ask("graph", "check", 1) -> bad;         ;;; ?- check(graph).
enddefine;

;;; Poplog wraps terminal output at poplinewidth (70 by default), and
;;; hard-breaks at poplinemax, inserting a newline and a TAB.  That is
;;; sensible for a listing and wrong for a tutor: it had been cutting the
;;; resource URLs an assignment hands out, mid-token, so a student could
;;; not copy one -- `checked 2026-10-1\n\t9)`.  Nothing here wants
;;; automatic wrapping; what needs wrapping is wrapped by hand.
4000 -> poplinewidth;
4096 -> poplinemax;

define lp_main();
    lvars args = poparglist, a, user = false, display = false,
          batch = false, checkonly = false, rest = [];
    find_dir() -> langpop_dir;
    until args == [] do
        hd(args) -> a;
        if a = '--lang' then consword(hd(tl(args))) -> lp_lang; tl(tl(args)) -> args;
        elseif a = '--user' then consword(hd(tl(args))) -> user; tl(tl(args)) -> args;
        elseif a = '--name' then hd(tl(args)) -> display; tl(tl(args)) -> args;
        elseif a = '--batch' then true -> batch; tl(args) -> args;
        elseif a = '--data' then hd(tl(args)) -> lp_home_dir; tl(tl(args)) -> args;
        elseif a = '--check' then true -> checkonly; tl(args) -> args;
        else conspair(a, rest) -> rest; tl(args) -> args;
        endif;
    enduntil;
    if lp_lang == "en" then "preschool" else "preschool" endif -> lp_level;
    lp_load();
    lp_index();
    if checkonly then
        lvars bad = lp_check(), v;
        if bad == [] then
            printf('graph: %p items, %p ladder levels, %p exit criteria, no violations\n',
                   [% length(lp_items), length(lp_ladders), length(lp_exits) %]);
        else
            for v in bad do printf('VIOLATION %p\n', [% lp_term_str(v) %]) endfor;
        endif;
        return;
    endif;
    lp_load_persona(if lp_lang == "en" then 'hill' else 'aoi' endif);
    unless user then
        lp_greet();
        printf('Username?  ');
        sysflush(popdevout);
        lvars line = lp_readline();
        if line == termin then return endif;
        consword(lp_norm(line)) -> user;
    endunless;
    lp_register(user, display, batch);
    lp_session();
enddefine;


;;; Loaded as a library (the test suite does this) there is no session:
;;;     vars langpop_lib = true;
;;;     load 'examples/langpop/langpop.p';
unless isdefined("langpop_lib") then lp_main() endunless;
