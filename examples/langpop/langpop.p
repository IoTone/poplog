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
uses utf8;

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

;;; CHANNELS, and why a word has more than one.
;;;
;;; A word you can only READ is the whole pathology of vocabulary-book
;;; study: the count is the one axis that enumerates, so it is the one
;;; that gets ground, and listening rots while the number goes up.  The
;;; belief store has always been per item per channel -- what was wrong
;;; was that one channel decided whether a word was known, which made
;;; "can read it" the engine's definition of knowing a word.
;;;
;;; So an item is judged on a LIST of channels, gate first:
;;;
;;;   grapheme  [read]            a character is read
;;;   word      [read hear]       and a word is both
;;;   sound     [hear]            a contrast is heard or it is nothing
;;;   pattern   [produce]         a pattern is produced
;;;   skill     [read]            a roll-up over whatever it requires
define lp_channels(item) -> chs;
    lvars item, k = lp_kind(item);
    if     k == "sound"   then [hear]
    elseif k == "pattern" then [produce]
    elseif k == "word"    then [read hear]
    else                       [read]
    endif -> chs;
enddefine;

;;; The GATE channel: the one that decides whether the prerequisite graph
;;; opens.  Deliberately not the same question as whether the level has
;;; been passed, and the two must not be merged.
;;;
;;; Unlocking asks "may I proceed to something built on this?", and for
;;; reading something built on reading, reading is enough -- if the gate
;;; demanded every channel, then with no way to verify `hear` nothing
;;; would ever unlock and the ladder could not be climbed at all.
;;; Passing a level asks "have you actually learned this?", and that is
;;; what the exit criteria are for; they now name their channel, so a
;;; reading vocabulary of 5000 beside a listening vocabulary of 1500 is
;;; reported as two numbers instead of being averaged into a comfortable
;;; one.
define lp_primary(item) -> ch;
    lvars item;
    hd(lp_channels(item)) -> ch;
enddefine;

;;; Which channels this build can actually check.  `hear` is absent
;;; because there is no audio anywhere in langpop, and that is a fact
;;; about the tool rather than about the language -- which is why it is
;;; here and not in the graph.
;;;
;;; The consequence is deliberate.  A listening criterion can be driven
;;; by an assignment and a self-reported result, which is tier 2 and
;;; capped below MASTERY, so it can never be claimed to mastery.  The
;;; system therefore says "your reading is at N2 and I cannot certify
;;; your listening", which is true, and better than a single number that
;;; quietly averages the two.  See docs/projects/langpop-pronunciation.md
;;; for what would have to exist to change this.
lconstant VERIFIABLE = [read produce];

define lp_verifiable(ch); lvars ch; member(ch, VERIFIABLE) enddefine;

define lp_bel(item, ch) -> b;
    lvars item, ch;
    lp_beliefs(lp_bkey(lp_user, item, ch)) -> b;
enddefine;

define lp_mastered_on(item, ch);
    lvars item, ch;
    lp_bel(item, ch) >= MASTERY
enddefine;

;;; Mastered FOR THE PURPOSE OF UNLOCKING -- see lp_primary above.
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
                         'graph/en/ladder.pl' 'graph/en/items.pl'
                         'graph/en/a1.pl'];

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
                             'graph/ja/generated/n5-words.pl'
                             'graph/en/generated/a1-sounds.pl'];

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
    ;;; The kana-to-romaji map is built on first use rather than here --
    ;;; it reads the graph through lp_form_of, which is defined further
    ;;; down this file, and a call to it from up here would compile
    ;;; against an undefined variable.
    false -> lp_kana_rom_ready;
enddefine;

;;; ------------------------------------------------------- reading the graph
define lp_form_of(item, script) -> t;
    lvars item, script, p;
    false -> t;
    for p in lp_forms(item) do
        if hd(p) == script then hd(tl(p)) -> t; return endif;
    endfor;
enddefine;

;;; The face of an item: what to show when one form has to stand for it.
;;;
;;; Per language, because the face of an item is the form in the language
;;; it belongs to.  Two stale orders were fixed here in turn.  A flat
;;; hiragana-first list was right while every item was a kana or a
;;; kana-only starter word, and made :why k_4e00 head itself ひと rather
;;; than 一 once the import brought in characters -- the reading standing
;;; in for the character it is a reading OF.  Putting kanji first then
;;; did the same thing to English: a loanword trap headed itself マンション
;;; while `mansion`, the English word the item exists to teach, appeared
;;; nowhere on it.
define lp_any_form(item) -> t;
    lvars item, script, order;
    if lp_ilang(item) == "en" then [latin ipa katakana hiragana kanji romaji]
    else                           [kanji hiragana katakana latin ipa romaji]
    endif -> order;
    for script in order do
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
    ;;; Cleared BEFORE the early return, so that a failed load leaves
    ;;; nothing of the previous student behind.  In the one-shot TUI that
    ;;; made no difference; in the server, which is long-lived and serves
    ;;; whoever asks, binding to a student who does not exist used to
    ;;; leave the last one's journal, assignments and refused guesses
    ;;; sitting in the globals.  lp_beliefs is safe either way because
    ;;; lp_bkey puts the student in the key.
    [] -> lp_journal; [] -> lp_assigns; [] -> lp_corrections;
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
    if o('assignments') then
        for i from 1 to length(o('assignments')) do
            o('assignments')(i) -> e;
            lp_assigns <> [{% e(1), consword(e(2)), consword(e(3)),
                              e(4), e(5) %}] -> lp_assigns;
        endfor;
    endif;
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

;;; ------------------------------------------------- kana into romaji
;;; Why this exists: every imported Japanese item was UNASKABLE.
;;;
;;; lp_question could only build a probe for a ja item that had a romaji
;;; form, because the answer is typed and a learner has no reason to own
;;; a Japanese input method.  kana.pl and the starter list carry romaji;
;;; the importer emits kanji, hiragana and katakana forms and no romaji,
;;; so all 103 imported kanji and all 148 imported N5 words returned
;;; shape "none" and the tutor said "nothing here can be checked by
;;; typing".  251 of 521 items, and it failed silently -- no violation,
;;; because nothing checks that an item can be answered.
;;;
;;; The fix is not to emit romaji into the graph.  form(k_5c71, kanji,
;;; '山') together with form(k_5c71, hiragana, 'やま') already IS a probe:
;;; prompt one, answer the other.  What was missing is the ability to
;;; accept that answer typed in Latin letters, which is a fact about the
;;; writing system rather than about any item -- so it lives here, beside
;;; the answer checking, and not in the graph.

;;; The voiced and plosive kana, which kana.pl deliberately does not
;;; carry: it holds the 92 BASE kana, because a student who cannot read か
;;; cannot be taught が.  Hiragana only -- the katakana are the same block
;;; plus 0x60 and are derived below rather than typed, for the reason
;;; tools/mkkana.py gives: a glyph that is generated cannot be subtly
;;; wrong.
lconstant KANA_VOICED = [
    'が' 'ga'  'ぎ' 'gi'  'ぐ' 'gu'  'げ' 'ge'  'ご' 'go'
    'ざ' 'za'  'じ' 'ji'  'ず' 'zu'  'ぜ' 'ze'  'ぞ' 'zo'
    'だ' 'da'  'ぢ' 'ji'  'づ' 'zu'  'で' 'de'  'ど' 'do'
    'ば' 'ba'  'び' 'bi'  'ぶ' 'bu'  'べ' 'be'  'ぼ' 'bo'
    'ぱ' 'pa'  'ぴ' 'pi'  'ぷ' 'pu'  'ぺ' 'pe'  'ぽ' 'po'
];

;;; Keyed by WORD and not by string: a property compares its keys with
;;; == , so two equal strings are two different keys.  That has cost
;;; something three times in this tree already.
vars lp_kana_rom = newproperty([], 512, false, "perm"),
     lp_kana_rom_ready = false;

define lp_kata_of(hira) -> kata;
    lvars hira, kata, c;
    consutf8(#| lvars c; for c in [% utf8_explode(hira) %] do c + 16:60 endfor |#)
        -> kata;
enddefine;

define lp_kata_to_hira(s) -> h;
    lvars s, c, h;
    ;;; Only the syllabary block shifts; ー and anything else is left as it
    ;;; is, which is why this is not a blanket subtraction.
    consutf8(#| lvars c;
                for c in [% utf8_explode(s) %] do
                    if c >= 16:30A1 and c <= 16:30F6 then c - 16:60 else c endif;
                endfor |#) -> h;
enddefine;

;;; Built from the graph where the graph has it, so the 92 base kana come
;;; from the table generated out of Unicode codepoints and cannot drift
;;; from it.  Called by lp_index.
define lp_build_kana_rom();
    lvars i, r, g, l;
    returnif(lp_kana_rom_ready);
    true -> lp_kana_rom_ready;
    clearproperty(lp_kana_rom);
    for i in lp_items do
        nextunless(lp_ilang(i) == "ja" and lp_kind(i) == "grapheme");
        lp_form_of(i, "romaji") -> r;
        nextunless(r);
        lp_form_of(i, "hiragana") -> g;
        if g then (r sys_>< '') -> lp_kana_rom(consword(g sys_>< '')) endif;
        lp_form_of(i, "katakana") -> g;
        if g then (r sys_>< '') -> lp_kana_rom(consword(g sys_>< '')) endif;
    endfor;
    KANA_VOICED -> l;
    until l == [] do
        hd(tl(l)) -> r;
        hd(l) -> g;
        r -> lp_kana_rom(consword(g));
        r -> lp_kana_rom(consword(lp_kata_of(g)));     ;;; the +0x60 twin
        tl(tl(l)) -> l;
    enduntil;
enddefine;

;;; The vowel a small ya/yu/yo contributes, or false.
define lp_youon(cp) -> v;
    lvars cp, v = false;
    if     cp == 16:3083 or cp == 16:30E3 then 'a' -> v
    elseif cp == 16:3085 or cp == 16:30E5 then 'u' -> v
    elseif cp == 16:3087 or cp == 16:30E7 then 'o' -> v
    endif;
enddefine;

define lp_sokuon(cp); lvars cp; cp == 16:3063 or cp == 16:30C3 enddefine;
define lp_longmark(cp); lvars cp; cp == 16:30FC enddefine;

define lp_is_vowel_c(c); lvars c;
    c == `a` or c == `i` or c == `u` or c == `e` or c == `o`
enddefine;

;;; Kana to Hepburn.  Not a general transliterator -- just enough for a
;;; reading, which is what the graph holds.
define lp_romaji(kana) -> out;
    lvars kana, codes, n, i = 1,
          out = '', cp, nxt, g, syl, v, dbl = false, last = false;
    lp_build_kana_rom();
    [% utf8_explode(kana sys_>< '') %] -> codes;
    length(codes) -> n;
    until i > n do
        codes(i) -> cp;
        if lp_sokuon(cp) then
            ;;; a small tsu doubles the consonant that follows it
            true -> dbl; i + 1 -> i; nextloop;
        endif;
        if lp_longmark(cp) then
            ;;; ー lengthens whatever vowel came before: コーヒー is koohii
            if last then out <> last -> out endif;
            i + 1 -> i; nextloop;
        endif;
        consutf8(#| cp |#) -> g;
        lp_kana_rom(consword(g)) -> syl;
        unless syl then
            ;;; something outside the syllabary -- a kanji in a mixed
            ;;; string, say.  Give up rather than guess: a half
            ;;; transliteration accepted as an answer would be worse than
            ;;; no romaji at all.
            false -> out; return;
        endunless;
        ;;; き + ゃ is kya; し + ゃ is sha, not shya.  Drop the trailing i
        ;;; for the stem, then: a stem that already palatalises (sh, ch,
        ;;; j) takes the bare vowel, and anything else takes y plus the
        ;;; vowel.  The length test is what separates sh and ch from the h
        ;;; of hi -- "ends in h" alone would turn ひゃ into ha instead of
        ;;; hya, which is how the first version of this got きょう wrong.
        if i < n and lp_youon(codes(i + 1)) ->> v then
            lvars stem = syl;
            if length(syl) > 1 and syl(length(syl)) == `i` then
                substring(1, length(syl) - 1, syl) -> stem;
            endif;
            if (length(stem) >= 2 and stem(length(stem)) == `h`)
            or stem = 'j' then
                stem <> v -> syl;
            else
                stem <> 'y' <> v -> syl;
            endif;
            i + 2 -> i;
        else
            i + 1 -> i;
        endif;
        if dbl then
            ;;; double the leading consonant: っこ is kko
            unless lp_is_vowel_c(syl(1)) then
                consstring(syl(1), 1) <> syl -> syl;
            endunless;
            false -> dbl;
        endif;
        out <> syl -> out;
        ;;; remember the last vowel, for a following ー
        lvars k;
        false -> last;
        for k from length(syl) by -1 to 1 do
            if lp_is_vowel_c(syl(k)) then
                consstring(syl(k), 1) -> last; quitloop
            endif;
        endfor;
    enduntil;
enddefine;

;;; Replace every occurrence of one substring with another.  The
;;; parameters are not called `from` and `to`: both are Pop-11 syntax
;;; words (`for i from 1 to n`), and using them in a header reports a
;;; missing closing bracket rather than a reserved word.
define lp_subst(s, pat, rep) -> r;
    lvars s, pat, rep, r = '', i = 1, j, lf = length(pat);
    until i > length(s) do
        ;;; startlim false, not i: with i there the match had to START at
        ;;; i, so this found nothing anywhere else and no variant was ever
        ;;; generated.  N is where to search FROM; startlim is a separate
        ;;; constraint (REF * STRINGS).
        issubstring_lim(pat, i, false, false, s) -> j;
        if j then
            r <> substring(i, j - i, s) <> rep -> r;
            j + lf -> i;
        else
            r <> allbutfirst(i - 1, s) -> r; return;
        endif;
    enduntil;
enddefine;

;;; The romaji spellings a learner might reasonably type for one reading.
;;;
;;; Generous on purpose.  The probe asks whether they know how the word
;;; is READ, not whether they can spell Hepburn: がっこう is gakkou, and a
;;; student who types gakko has answered the question.  Likewise Kunrei
;;; (si, ti, tu, hu, zi) is what a Japanese primary school teaches, so
;;; refusing it would fail the very learner this is for.
;;; Add to a list of strings unless it is there already or empty.
define lp_push_str(l, x) -> l;
    lvars l, x;
    unless x = '' or not(x) or member(x, l) then l <> [^x] -> l endunless;
enddefine;

define lp_romaji_variants(kana) -> l;
    lvars kana, base = lp_romaji(kana), l = [], v, x, add;
    returnif(not(base)) ([] -> l);
    lp_push_str(l, base) -> l;
    ;;; long vowels written once
    base -> v;
    for x in ['ou' 'oo' 'uu' 'ii' 'aa' 'ee'] do
        lp_subst(v, x, consstring(x(1), 1)) -> v;
    endfor;
    lp_push_str(l, v) -> l;
    ;;; Kunrei, on both the full and the collapsed spelling.  The youon
    ;;; rows are not optional: でんしゃ is densha in Hepburn and densya in
    ;;; Kunrei, and a table that only knew shi -> si rejected densya
    ;;; while accepting denshi-nothing -- the commonest row in the
    ;;; syllabary and the one a Japanese primary school teaches.
    lvars kun = ['sha' 'sya'  'shu' 'syu'  'sho' 'syo'  'shi' 'si'
                 'cha' 'tya'  'chu' 'tyu'  'cho' 'tyo'  'chi' 'ti'
                 'ja'  'zya'  'ju'  'zyu'  'jo'  'zyo'  'ji'  'zi'
                 'tsu' 'tu'   'fu'  'hu'], kl;
    for x in [^base ^v] do
        x -> add;
        kun -> kl;
        until kl == [] do
            lp_subst(add, hd(kl), hd(tl(kl))) -> add;
            tl(tl(kl)) -> kl;
        enduntil;
        lp_push_str(l, add) -> l;
    endfor;
enddefine;

;;; Everything that counts as reading this item correctly: the kana as
;;; written, the same in hiragana if it was katakana, and the romaji
;;; spellings of each.  A kanji has two readings in the graph (kun as
;;; hiragana, on as katakana) and either one answers "can you read it".
define lp_take_reading(l, g) -> l;
    lvars l, g, h, x;
    returnunless(g);
    lp_build_kana_rom();
    g sys_>< '' -> g;
    lp_push_str(l, g) -> l;
    lp_kata_to_hira(g) -> h;
    lp_push_str(l, h) -> l;
    for x in lp_romaji_variants(g) do lp_push_str(l, x) -> l endfor;
enddefine;

define lp_readings(item) -> l;
    lvars item, l = [];
    lp_take_reading(l, lp_form_of(item, "hiragana")) -> l;
    lp_take_reading(l, lp_form_of(item, "katakana")) -> l;
enddefine;

;;; ANSWER IS A LIST, head first and canonical.  It used to be one
;;; string, which was fine while every probe had exactly one spelling --
;;; and the moment a probe accepted a reading in either kana or romaji it
;;; had to become a set.  hd(answer) is what the tutor says when the
;;; student is wrong, so it is the kana: "It is やま", not "It is yama".
define lp_question(item) -> (shape, prompt, answer, options);
    lvars item, k = lp_kind(item), r, en, ja, glyph, kanji, reads;
    ("none", '', [], []) -> (shape, prompt, answer, options);
    lp_form_of(item, "romaji") -> r;
    lp_form_of(item, "kanji") -> kanji;
    if (k == "grapheme" or k == "word") and r then
        ;;; A base kana or a starter word: the glyph is the prompt and the
        ;;; hand-written romaji is the answer, exactly one spelling.
        ;;;
        ;;; Deliberately strict, and deliberately different from the
        ;;; branch below.  がっこう at pre-school is a reading-the-kana
        ;;; exercise, so "gakko" has skipped the う and is wrong; the same
        ;;; word met as 学校 at N5 is a reading-the-kanji exercise, where
        ;;; the length of the vowel is not what is being asked and gakko
        ;;; answers the question.  Two skills, two strictnesses.
        lp_any_form(item) -> glyph;
        ("type", glyph sys_>< '', [% lp_lower(r sys_>< '') %], [])
            -> (shape, prompt, answer, options);
    elseif (k == "grapheme" or k == "word") and lp_ilang(item) == "ja"
    and kanji then
        ;;; An imported kanji or N5 word.  form(_, kanji, '山') together
        ;;; with form(_, hiragana, 'やま') already IS a probe -- prompt one
        ;;; and answer the other -- and this branch is the whole of what
        ;;; was missing: without it all 251 imported Japanese items
        ;;; returned "none" and the tutor said nothing could be checked
        ;;; by typing.
        ;;;
        ;;; Not multiple choice, even though the confusable pairs would
        ;;; make good distractors: typing is a stronger probe than
        ;;; picking, there is no one-in-four guess in it, and accepting
        ;;; romaji means no Japanese input method is needed -- which is
        ;;; exactly the bargain the pre-school kana probe already strikes.
        lp_readings(item) -> reads;
        unless reads == [] then
            ("type", kanji sys_>< '', reads, [])
                -> (shape, prompt, answer, options);
        endunless;
    elseif k == "word" and lp_ilang(item) == "en" then
        lp_gloss_of(item, "en") -> en;
        lp_gloss_of(item, "ja") -> ja;
        if en and ja then
            lp_flip + 1 -> lp_flip;
            if lp_flip mod 2 == 1 then
                ("pick", lp_form_of(item, "latin") sys_>< '', ['1'], [^en ^ja])
            else
                ("pick", lp_form_of(item, "latin") sys_>< '', ['2'], [^ja ^en])
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
    if member(typed, answer) then
        lp_record(item, lp_primary(item), 1, true, lp_now_ms() - t0);
        printf('  %p\n', [% lp_line('praise') %]);
    else
        lp_record(item, lp_primary(item), 1, false, lp_now_ms() - t0);
        lvars other = lp_mistook(item, typed);
        if other then
            printf('  %p  That is %p -- the two are confused constantly.\n',
                   [% lp_line('almost'), lp_any_form(other) %]);
        else
            printf('  %p  It is %p.\n', [% lp_line('wrong'), hd(answer) %]);
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
define lp_count_mastered(kind, ch) -> n;
    lvars kind, ch, i, n = 0;
    for i in lp_items do
        if lp_kind(i) == kind and lp_ilang(i) == lp_lang
        and lp_mastered_on(i, ch) then
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
define lp_count_mastered_kanji(ch) -> n;
    lvars ch, i, n = 0;
    for i in lp_items do
        if lp_kind(i) == "grapheme" and lp_ilang(i) == lp_lang
        and lp_form_of(i, "kanji") and lp_mastered_on(i, ch) then
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
    lvars e, c, th, ms, items, acc, fast, n, want, ch;
    printf('\n  %p, %p -- level %p\n',
           [% lp_display or (lp_user sys_>< ''), lp_lang, lp_level %]);
    for e in lp_exits do
        nextunless(hd(e) == lp_lang and hd(tl(e)) == lp_level);
        hd(tl(tl(e))) -> c; hd(tl(tl(tl(e)))) -> th; hd(tl(tl(tl(tl(e))))) -> ms;
        if prolog_complexterm(c) and prolog_functor(c) == "vocabulary" then
            prolog_full_deref(prolog_arg(1, c)) -> want;
            prolog_deref(prolog_arg(2, c)) -> ch;
            if lp_verifiable(ch) then
                printf('    %p: %p of %p words mastered (%p in the graph)\n',
                       [% lp_term_str(c), lp_count_mastered("word", ch), want,
                          lp_count_items("word") %]);
            else
                ;;; Said rather than scored.  Reporting 0 of 800 would
                ;;; read as a student who has learned nothing, when what
                ;;; is true is that nothing here can measure it.
                printf('    %p: cannot be checked here -- needs audio (%p in the graph)\n',
                       [% lp_term_str(c), lp_count_items("word") %]);
            endif;
        elseif prolog_complexterm(c) and prolog_functor(c) == "kanji" then
            prolog_full_deref(prolog_arg(1, c)) -> want;
            prolog_deref(prolog_arg(2, c)) -> ch;
            printf('    %p: %p of %p kanji mastered (%p in the graph)\n',
                   [% lp_term_str(c), lp_count_mastered_kanji(ch), want,
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

;;; Edit distance, for recognising a name that was typed slightly wrong.
;;;
;;; Damerau-Levenshtein, not plain Levenshtein: an adjacent transposition
;;; counts as ONE edit.  That is not a refinement, it is the whole point
;;; of the tolerance -- plain Levenshtein charges two for "bsmiht" against
;;; "bsmith", which is outside the budget for a six-letter name, so the
;;; single commonest typo a returning student makes was the one case that
;;; got no guess at all.
;;;
;;; A full table rather than two rolling rows, because the transposition
;;; rule reaches back two of each.  A roll holds a handful of students on
;;; somebody's own machine, so this runs a few dozen times at
;;; registration and never again.
define lp_edit(a, b) -> d;
    lvars a, b, la = length(a), lb = length(b), t, i, j, c, d;
    returnif(la == 0)(lb -> d);
    returnif(lb == 0)(la -> d);
    newarray([0 ^la 0 ^lb], 0) -> t;
    for i from 0 to la do i -> t(i, 0) endfor;
    for j from 0 to lb do j -> t(0, j) endfor;
    for i from 1 to la do
        for j from 1 to lb do
            if subscrs(i, a) == subscrs(j, b) then 0 else 1 endif -> c;
            min(min(t(i - 1, j) + 1, t(i, j - 1) + 1), t(i - 1, j - 1) + c)
                -> t(i, j);
            if i > 1 and j > 1
            and subscrs(i, a) == subscrs(j - 1, b)
            and subscrs(i - 1, a) == subscrs(j, b) then
                min(t(i, j), t(i - 2, j - 2) + 1) -> t(i, j);
            endif;
        endfor;
    endfor;
    t(la, lb) -> d;
enddefine;

;;; How wrong a name may be and still be the same person.  Proportional,
;;; because one wrong letter in "dk" is a different name while one wrong
;;; letter in "dkordsmeier" is a slip.
define lp_edit_tol(n) -> t;
    lvars n, t = n div 4;
    if t < 1 then 1 -> t endif;
enddefine;

;;; Split a name on whitespace.
define lp_split_name(str) -> l;
    lvars str, i, start = 0, len = length(str);
    [% for i from 1 to len + 1 do
           if i > len or subscrs(i, str) == `\s` then
               if start > 0 then substring(start, i - start, str) endif;
               0 -> start;
           elseif start == 0 then i -> start;
           endif;
       endfor %] -> l;
enddefine;

;;; Distance between two NAMES, which is not the same thing as distance
;;; between two strings.
;;;
;;; "Bob Smith" against "Bob White" is three edits apart and so outside
;;; any sane tolerance -- yet it is the exact confusion a person makes,
;;; because the two share a given name.  So the tokens are compared too,
;;; and a close token counts, with one added so that a whole-name match
;;; still wins over a shared first name.
;;;
;;; This will sometimes offer the wrong person of two who share a first
;;; name.  That is the behaviour being modelled, not a defect in it: the
;;; teacher says "Bob Smith?", is told no, and never says it again --
;;; which is what lp_refuse_guess is for.
define lp_name_dist(a, b) -> d;
    lvars a, b, ta, tb, x, y, dd;
    lp_edit(a, b) -> d;
    lp_split_name(a) -> ta;
    lp_split_name(b) -> tb;
    for x in ta do
        for y in tb do
            nextif(length(x) < 2 or length(y) < 2);
            lp_edit(x, y) + 1 -> dd;
            if dd < d then dd -> d endif;
        endfor;
    endfor;
enddefine;

;;; The nearest name on the roll to what was typed, or false.
;;;
;;; This used to compare the first three characters of the USERNAME and
;;; keep the first candidate it happened to meet -- and since it walked a
;;; property, "the first it happened to meet" was arbitrary.  With two
;;; students on the roll it guessed by hash order, which is not what its
;;; own comment promised.  Now it scores every candidate and takes the
;;; best, on the username AND on the display name if one was offered,
;;; because somebody who registered as dkords may well type David.
;;;
;;; Ties break alphabetically.  Not because that is the better guess, but
;;; because the guess has to be the same one every time: a teacher who
;;; asks "Bob Smith?" on Monday and "Bob White?" on Tuesday from the same
;;; keystrokes is not remembering, it is rolling dice.
define lp_roll_guess_full(user, typed_name) -> (other, display, why);
    lvars user, typed_name, r = lp_roll(), u = lp_norm(user sys_>< ''),
          nm = if typed_name then lp_norm(typed_name sys_>< '') else false endif,
          best = false, bd = false, bw = false, bscore = false;
    (false, false, false) -> (other, display, why);
    appproperty(r, procedure(k, v);
        lvars k, v, du, dn, score, w, refused, skip = false;
        returnif(k = u);                            ;;; that is the typed id
        ;;; a guess already refused by this student is never offered again
        for refused in lp_corrections do
            if isvector(refused) and length(refused) >= 1
            and (refused(1) sys_>< '') = (v sys_>< '') then
                true -> skip;
            endif;
        endfor;
        returnif(skip);
        lp_edit(u, lp_norm(k sys_>< '')) -> du;
        if du <= lp_edit_tol(max(length(u), length(k))) then
            du -> score; 'the username' -> w;
        else
            false -> score; false -> w;
        endif;
        if nm and v then
            lp_name_dist(nm, lp_norm(v sys_>< '')) -> dn;
            if dn <= lp_edit_tol(max(length(nm), length(v sys_>< '')))
            and (not(score) or dn < score) then
                dn -> score; 'the name' -> w;
            endif;
        endif;
        returnunless(score);
        if not(bscore) or score < bscore
        or (score == bscore and alphabefore(k, best)) then
            k -> best; v -> bd; w -> bw; score -> bscore;
        endif;
    endprocedure);
    returnunless(best);
    ;;; A WORD, because a student id is a word everywhere else in here
    ;;; (lp_user, lp_bkey, the profile path).  The roll's own keys are
    ;;; strings because they came back through JSON, and handing one of
    ;;; those out would make the caller's == comparisons quietly fail --
    ;;; a word and a string with the same characters print identically.
    (consword(best sys_>< ''), bd, bw) -> (other, display, why);
enddefine;

;;; The two-result form the TUI has always called.
define lp_roll_guess(user) -> (other, display);
    lvars user, w;
    lp_roll_guess_full(user, false) -> (other, display, w);
enddefine;

;;; Remember that a guess was wrong, so it is not offered again.
define lp_refuse_guess(refused_display);
    lvars refused_display;
    conspair({% refused_display, lp_display %}, lp_corrections) -> lp_corrections;
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
            guess_u -> lp_user;              ;;; already a word
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
