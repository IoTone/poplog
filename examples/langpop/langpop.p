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
    lp_ranks    = newproperty([], 512, false, "perm"),  ;;; item|scale -> n
    ;;; Two maps are read out of the graph on first use rather than at
    ;;; index time, because they go through procedures defined further
    ;;; down this file.  The flags live up here so lp_index can clear
    ;;; them without a forward reference.
    lp_edges_ready = false,
    lp_kana_rom_ready = false,
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
constant MASTERY = 0.80, TIER2_CAP = 0.78, TIER3_CAP = 0.50,
;;; INFERRED is evidence the student never gave directly: they read
;;; 誕生日, so they can probably read 日.  Strong -- better than a
;;; self-reported score, because something was actually observed -- and
;;; capped below MASTERY anyway, because the inference is sometimes
;;; simply false.  Japanese is full of compounds whose reading does not
;;; decompose: 大人 is おとな, which tells you nothing about 大 or 人.
;;; So an inferred item is never TAUGHT as new and always CONFIRMED once
;;; on contact, which is exactly the behaviour wanted for a learner who
;;; arrives already knowing 500 kanji.
         INFERRED_CAP = 0.75,
;;; MACHINE is a verdict from a model: the student spoke, something
;;; measured it, and nobody listened.  Stronger than an inference,
;;; because what was observed IS the item -- and capped below a human
;;; check for the reason the audio plan gives: a confident model is
;;; still a model.  It sits strictly between INFERRED_CAP and TIER2_CAP,
;;; and the ordering is the part that matters: above inference because
;;; something was actually heard, below a self-reported score because a
;;; student who reports 18 out of 20 was marked by a person.
;;;
;;; 0.77 leaves room for exactly one check to tip an item over MASTERY,
;;; which is the property TIER2_CAP was chosen for, and the same
;;; argument applies: however good the model gets, a teacher's ear is
;;; what certifies pronunciation.
         MACHINE_CAP = 0.77;

;;; The tier numbers are identifiers, not an ordering -- 4 was added
;;; after 1, 2 and 3 existed and sits second in strength:
;;;
;;;   1  a check: watched them do it                    -> MASTERY
;;;   5  a machine verdict: a model measured them       -> MACHINE_CAP
;;;   4  inferred: watched them do something requiring it -> INFERRED_CAP
;;;   2  a reported result: "18 out of 20"              -> TIER2_CAP
;;;   3  compliance: "I did it"                         -> TIER3_CAP

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
;;; `speak` is SAYING it, and it is not `produce`.  produce is composing
;;; a sentence, which a pattern item asks for and a keyboard can answer;
;;; speak is making the sound, which wants a microphone.  Two different
;;; things that English calls production, kept apart because the ladder
;;; measures them separately and one of them this build can check by
;;; typing.
;;;
;;; The primary channel is unchanged in every case -- it is hd(chs), and
;;; speak is appended -- because lp_primary is the GATE and adding a
;;; channel must not move a door.
define lp_channels(item) -> chs;
    lvars item, k = lp_kind(item);
    if     k == "sound"    then [hear speak]
    elseif k == "pattern"  then [produce]
    elseif k == "word"     then [read hear speak]
    elseif k == "grapheme" then [read speak]
    else                        [read]
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

;;; Which channels this build can actually check.
;;;
;;; `hear` WAS absent, on the grounds that there is no audio anywhere in
;;; langpop.  Those grounds expired when Stage 0 shipped, and the mistake
;;; underneath them is worth keeping on the record: `hear` and `produce`
;;; were parked together as "audio", when hearing needs a SPEAKER and
;;; only producing needs a microphone.  A listening question -- play the
;;; word, the student types what they heard -- is a typed answer graded
;;; by exact match, exactly as a reading question is.  Nothing in it is
;;; machine-judged, so it needs no new evidence tier: the only machine
;;; involved is the one that spoke.
;;;
;;; It is conditional rather than constant because it is a fact about the
;;; INSTALLATION.  A machine with no voice configured cannot ask a
;;; listening question and must go on saying `needs_audio`, rather than
;;; reporting a listening vocabulary of zero -- which would read as a
;;; student who failed instead of a tutor that cannot ask.
;;;
;;; `produce` stays unverifiable by typing, for the harder reason: it
;;; wants a microphone, which is Stage 1 and Stage 2 of
;;; docs/projects/langpop-audio.md.  The self-report path stays too -- a
;;; criterion can still be driven by an assignment at tier 2, capped
;;; below MASTERY -- so "your reading is at N2 and I cannot certify your
;;; production" remains sayable, and true.
lconstant VERIFIABLE = [read produce];
lconstant VERIFIABLE_HEARD = [hear];

;;; audio.p is loaded on demand, so this asks "is there a voice in this
;;; session", and the `and` short-circuits before naming anything
;;; audio.p defines.
define lp_can_hear() -> yes;
    lvars yes = (lp_audio_loaded and lp_audio_ready(lp_lang)) and true;
enddefine;

define lp_verifiable(ch);
    lvars ch;
    member(ch, VERIFIABLE)
    or (member(ch, VERIFIABLE_HEARD) and lp_can_hear())
enddefine;

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

;;; A prerequisite nothing can check does not hold the door shut.
;;;
;;; lp_mastered reads the GATE channel, and for a sound item the gate is
;;; `hear` -- which is outside VERIFIABLE, so a sound can never be
;;; mastered, so anything requiring one is locked for ever.  All twelve
;;; English contrasts are sounds.  The consequence was not that the
;;; English pre-school rung measured badly: it was that the rung had
;;; NOTHING READY, ever, and the tutor said "nothing here can be checked
;;; by typing" to every student who ever opened it.
;;;
;;; The channels note already makes this argument one level down -- "if
;;; the gate demanded every channel, then with no way to verify hear
;;; nothing would ever unlock and the ladder could not be climbed at
;;; all" -- and this is the same argument about prerequisites.  The edge
;;; is still true and still teaches order; it simply cannot be a
;;; condition, because the tutor has no way to satisfy it.
;;;
;;; What it does NOT do is let the student pass anything.  s_final is
;;; still unmastered, sound_contrasts is still unreachable, and --audit
;;; still says needs_audio.  It unlocks the teaching, not the criterion.
;;; REFINED when `hear` became verifiable, and the refinement is the
;;; point.  This used to ask "is the gate channel outside VERIFIABLE?",
;;; which exempted every sound item because `hear` was unverifiable
;;; wholesale.  Install a voice and that exemption vanishes -- so the
;;; twelve English contrasts, which are sound items that no listening
;;; question can yet ask (a contrast wants a minimal PAIR, not a word),
;;; would have gone straight back to locking the whole English ladder.
;;; That is the defect 570849c fixed, re-entering by the back door.
;;;
;;; The honest test was never about the channel in the abstract: it is
;;; whether THIS ITEM can be asked about at all.  A prerequisite nothing
;;; can check does not hold the door shut, and it makes no difference
;;; whether the reason is a missing microphone or a missing probe.
;;; Can nothing ever move this item's gate belief?
;;;
;;; For `read` and `produce` the answer is the channel alone, exactly as
;;; it was before listening existed -- and deliberately NOT drillability,
;;; which was the first attempt and was wrong.  hiragana_all has no probe
;;; and is not drillable, but its belief rises by INFERENCE from the 46
;;; kana it requires, so it is perfectly checkable and must go on holding
;;; the door shut.  Treating undrillable as uncheckable made every
;;; aggregate a free pass and declared all 50 starter words ready at the
;;; first question.
;;;
;;; For `hear` the channel became verifiable only because a voice is
;;; installed, so there it means precisely "a listening question can be
;;; asked" -- and where one cannot be, nothing has changed from the state
;;; before the voice arrived.  That is the case this clause exists for:
;;; the twelve English contrasts are sound items, their gate is `hear`,
;;; and no listening question can ask them (a contrast wants a minimal
;;; PAIR, not a word).  Without it, installing a voice would re-lock the
;;; entire English ladder -- the defect 570849c fixed, coming back in
;;; through the door Stage 0 opened.
define lp_ungateable(item) -> yes;
    lvars item, ch = lp_primary(item);
    if not(lp_verifiable(ch)) then true
    elseif member(ch, VERIFIABLE_HEARD) then not(lp_drillable_on(item, ch))
    else false
    endif -> yes;
enddefine;

define :prolog lp_unverifiable/1(i, contn);
    lvars i, contn;
    if lp_ungateable(prolog_deref(i)) then chain(contn) endif;
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

;;; An item's place on a named difficulty scale.  Keyed by item AND scale
;;; in one word, because an item sits on several at once.
define :prolog lp_rank/3(i, sc, n, contn);
    lvars i, sc, n, contn;
    prolog_deref(n) -> lp_ranks(consword((prolog_deref(i) sys_>< '') <> '|'
                                         <> (prolog_deref(sc) sys_>< '')));
    chain(contn);
enddefine;

define lp_rank_of(item, scale) -> n;
    lvars item, scale;
    lp_ranks(consword((item sys_>< '') <> '|' <> (scale sys_>< ''))) -> n;
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
;;; The build products the engine will load if they are there.  Hand
;;; listed rather than globbed, which is the right trade -- a directory
;;; scan would load whatever happened to be lying in it -- but it means a
;;; new import level has to be declared here, and nothing used to say so:
;;; `--source cmudict --level preschool` wrote preschool-sounds.pl, the
;;; engine never read it, and imp_verify duly reported all 23 facts as
;;; LOST.  The verifier was right and the message was baffling, so the
;;; importer now refuses the write instead (see lp_generated_files).
lconstant GRAPH_GENERATED = ['graph/ja/generated/n5-kanji.pl'
                             'graph/ja/generated/n5-words.pl'
                             'graph/en/generated/a1-sounds.pl'
                             'graph/en/generated/preschool-sounds.pl'
                             'graph/en/generated/a1-frequency.pl'];

define lp_generated_files() -> l; lvars l = GRAPH_GENERATED; enddefine;

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
    clearproperty(lp_ranks);
    [] -> lp_items; [] -> lp_ladders; [] -> lp_exits; [] -> lp_rsrc;
    [] -> lp_gens;
    false -> lp_edges_ready;
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

;;; OUTCOMES, and why there are four of them rather than two.
;;;
;;; A boolean threw away the most useful thing a wrong answer carries.
;;; A learner who freezes has told you something quite different from one
;;; who answers wrongly, and a learner who answers シ for ツ has told you
;;; something different again -- they knew it was a kana and knew roughly
;;; which, which is most of the way there.  The graph already states which
;;; pairs are confused (confusable/3), so the distinction is available
;;; for free and was simply being discarded.
;;;
;;;   "right"   answered correctly
;;;   "near"    wrong, but confused with a DECLARED confusable partner
;;;   "wrong"   wrong, with no recognisable confusion behind it
;;;   "skip"    no answer offered at all
;;;
;;; The beliefs differ accordingly: a near miss is nearly knowing, a
;;; freeze is the absence of a claim, and a wild guess sits between them.
;;; Only "right" counts toward an exit criterion, and only "skip" stops a
;;; placement descent -- which is the whole reason the four exist.
lconstant OUTCOMES = [right near wrong skip];

;;; lconstant is file-local, and audio.p has to check a verdict that came
;;; from somebody else's program against this list before handing it to
;;; lp_record -- which mishaps on an outcome it does not know, and a
;;; tutor crashing because a model said something unexpected is not an
;;; acceptable way to find out.
define lp_outcomes() -> l;
    lvars l = OUTCOMES;
enddefine;

define lp_outcome_ok(o); lvars o; o == "right" enddefine;

;;; The prerequisite edges, which index/0 deliberately does not collect
;;; -- the tutor only needs ready/4's one-level check, so the overlay
;;; would otherwise carry 800 pairs nothing reads.  Built on first use,
;;; the same way the kana map is, and for the same reason: it reads the
;;; graph through procedures defined further down this file.
vars lp_edges = newproperty([], 512, [], "perm");

;;; Declared, not left to the compiler to guess at.  lp_record infers
;;; from a check and lp_infer records what it inferred, so the two refer
;;; to each other and one of them must be forward.
vars procedure lp_record;

define lp_build_edges();
    lvars t, a, b;
    returnif(lp_edges_ready);
    true -> lp_edges_ready;
    clearproperty(lp_edges);
    for t in lp_ask("edges", 0) do
        prolog_full_deref(prolog_arg(1, t)) -> a;
        prolog_full_deref(prolog_arg(2, t)) -> b;
        lp_edges(a) <> [^b] -> lp_edges(a);
    endfor;
enddefine;

define lp_edges_of(item) -> es;
    lvars item, es;
    lp_build_edges();
    lp_edges(item) -> es;
enddefine;

;;; Is the prerequisite WRITTEN INSIDE the item?
;;;
;;; This is what decides whether a correct answer says anything about a
;;; prerequisite, and it has to be decided here because requires/2 does
;;; not distinguish its three uses:
;;;
;;;   requires(w_tanjoubi, k_65e5)      containment -- 日 is in 誕生日
;;;   requires(w_mijikai, w_nagai)      teaching order -- 短い after 長い
;;;   requires(w_mijikai, hiragana_all) a roll-up over 46 kana
;;;
;;; Only the first carries an inference.  Knowing 短い says nothing about
;;; 長い, and reading one word exercises two kana out of forty-six.  Both
;;; fall out of this test for free: an antonym is not a substring, and a
;;; skill has no written form at all.
;;;
;;; Byte-wise substring, which is safe for UTF-8 rather than lucky: no
;;; character's encoding can appear inside another's at a non-boundary,
;;; because every continuation byte is distinguishable from every
;;; leading one.
define lp_contains(item, pre) -> yes;
    lvars item, pre, sc, a, b, yes = false;
    for sc in [kanji hiragana katakana latin] do
        lp_form_of(item, sc) -> a;
        lp_form_of(pre, sc) -> b;
        nextunless(a and b);
        a sys_>< '' -> a; b sys_>< '' -> b;
        nextif(a = b);                      ;;; identity is not containment
        if issubstring(b, a) then true -> yes; return endif;
    endfor;
enddefine;

;;; Evidence the student never gave directly.  One level only: inferring
;;; transitively would compound an inference that is already sometimes
;;; wrong.
define lp_infer(item);
    lvars item, pre;
    for pre in lp_edges_of(item) do
        nextunless(lp_contains(item, pre));
        lp_record(pre, lp_primary(pre), 4, "right", 0);
    endfor;
enddefine;


;;; ---------------------------------------------------------- the aids
;;; Three things in here help a student who has not made a mistake of
;;; knowledge: the slip detector, ":oops", and ":later".  Each can be
;;; turned off, and that switch is not a convenience for the tutor -- it
;;; is for the student.  An aid that cannot be refused is
;;; indistinguishable from a lower standard, and a learner who suspects
;;; they are leaning on one has no way to find out except to take it
;;; away.  Spaced-repetition services that offer these (WaniKani's
;;; "I typed it wrong" and its skip are the pattern) make them optional
;;; for exactly this reason, and they are right to.
;;;
;;; They are RECORDED rather than policed.  Turning one off and on again
;;; around a hard item would otherwise be invisible.  Instead every
;;; change is logged with the time; every journal entry already carries a
;;; time; so what was available at any given answer is reconstructible
;;; exactly -- at the cost of one record per change, rather than a wider
;;; field on every answer.
lconstant AIDS = [slip oops later];

;;; `true` has to be lifted in with ^, because `true` inside a list
;;; literal is the WORD true, which is not the boolean and is not false
;;; either -- so an unlifted default would read as on and never go off.
vars lp_aids = newproperty([[slip ^true] [oops ^true] [later ^true]],
                           8, false, "perm"),
     lp_aid_log = [];                   ;;; [{aid on? when_ms} ...]

define lp_aid_names() -> l; lvars l = AIDS; enddefine;

;;; Declared forward: the queue lives next to lp_drill because lp_due
;;; needs lp_drillable, and lp_load_profile above here has to be able to
;;; empty it when the student changes.
vars procedure lp_queue_reset;

define lp_aid(a); lvars a; lp_aids(a) enddefine;

;;; `on` cannot be the parameter name: it is a Pop-11 syntax word, as
;;; `from`, `to`, `step` and `back` are, and it reads as the `for x on
;;; list` form inside the header.
define lp_aid_set(a, val) -> ok;
    lvars a, val, ok = false;
    returnunless(member(a, AIDS));
    true -> ok;
    returnif(lp_aid(a) == val);         ;;; no change is not a change
    val -> lp_aids(a);
    lp_aid_log <> [{% a, val, lp_now_ms() %}] -> lp_aid_log;
enddefine;

define lp_aids_reset();
    lvars a;
    for a in AIDS do true -> lp_aids(a) endfor;
    [] -> lp_aid_log;
enddefine;

define lp_aid_why(a) -> s;
    lvars a, s;
    if     a == "slip"  then 'one more go when a typed answer looks mistyped'
    elseif a == "oops"  then ':oops takes back the answer you just gave'
    else                     'puts a question off until later today -- type it'
                             <> ' at a question'
    endif -> s;
enddefine;

define lp_aids_show();
    lvars a, n = length(lp_aid_log), nm;
    printf('\n');
    for a in AIDS do
        ;;; Padded by hand.  Poplog's printf has no field width for %p,
        ;;; and a ragged column of three is still a ragged column.
        a sys_>< '' -> nm;
        until length(nm) >= 6 do nm <> ' ' -> nm enduntil;
        printf('    %p %p %p\n',
               [% if lp_aid(a) then 'on ' else 'off' endif, nm, lp_aid_why(a) %]);
    endfor;
    printf('\n  :aids <name> on|off.  Changes are logged with the time');
    if n > 0 then printf(' (%p so far)', [^n]) endif;
    printf(',\n  so what was switched on at any answer stays recoverable.\n');
enddefine;

;;; ------------------------------------------------------ typing slips
;;; A Japanese learner is typing romaji, or fighting an input method they
;;; do not know well, and a slip of the fingers is not a gap in their
;;; knowledge.  Recorded as "wrong" it costs them 0.70 of a belief and
;;; teaches the tutor something false -- the probe ends up measuring
;;; typing rather than reading, which is the same validity problem as
;;; asking about grammar in vocabulary the student does not have.

;;; How far off a typed answer may be and still be a slip.
;;;
;;; PROPORTIONAL, and with no floor, which is the opposite of
;;; lp_edit_tol: a name may always be one letter out, an answer may not.
;;; For a two-character answer any edit is a DIFFERENT answer -- ke is
;;; not a slip for ka, it is the wrong kana -- so short answers get no
;;; tolerance at all, and with it no hint that they were close.
define lp_typo_tol(n) -> t;
    lvars n, t = n div 4;
enddefine;

;;; Does this look like a slip rather than a mistake?
define lp_slip(typed, answers) -> yes;
    lvars typed, answers, a, t, yes = false;
    returnif(typed = '' or not(typed)) (false -> yes);
    for a in answers do
        a sys_>< '' -> a;
        lp_typo_tol(max(length(typed), length(a))) -> t;
        nextif(t == 0);
        if lp_edit(typed, lp_lower(a)) <= t then true -> yes; return endif;
    endfor;
enddefine;

;;; ------------------------------------------------------------- undo
;;; One answer deep, and only within the session.  ":oops" is for what
;;; the slip detector cannot catch -- an input method that ate the line,
;;; or enter hit a word early -- and it restores every belief the answer
;;; moved, which is more than one: a correct check also credits whatever
;;; it contained, so undoing it has to undo those too.
vars lp_undo = false,                   ;;; [[key before] ...] or false
    lp_undo_item = false,
    lp_undo_journal = false,
    lp_undo_watch = false;

define lp_undo_start(item);
    lvars item;
    [] -> lp_undo;
    item -> lp_undo_item;
    lp_journal -> lp_undo_journal;
    true -> lp_undo_watch;
enddefine;

define lp_undo_stop();
    false -> lp_undo_watch;
enddefine;

define lp_undo_last() -> ok;
    lvars ok = false, p;
    returnunless(lp_undo and lp_undo_item);
    for p in lp_undo do hd(tl(p)) -> lp_beliefs(hd(p)) endfor;
    lp_undo_journal -> lp_journal;
    lp_undo_item -> ok;
    false -> lp_undo; false -> lp_undo_item;
enddefine;

define lp_record(item, ch, tier, outcome, latency_ms);
    lvars item, ch, tier, outcome, latency_ms, b = lp_bel(item, ch), nb;
    ;;; A caller still passing a boolean is reading an older profile or an
    ;;; older call site; map it rather than storing something nothing
    ;;; downstream can interpret.
    if outcome == true then "right" -> outcome
    elseif outcome == false then "wrong" -> outcome
    endif;
    unless member(outcome, OUTCOMES) then
        mishap(outcome, 1, 'lp_record: outcome must be right, near, wrong or skip')
    endunless;
    if tier == 1 then
        if     outcome == "right" then b + (1.0 - b) * 0.45
        elseif outcome == "near"  then b * 0.45
        elseif outcome == "wrong" then b * 0.30
        else                           b * 0.20      ;;; skip
        endif
    elseif tier == 5 then
        ;;; A machine verdict.  Moves like a check, because what was
        ;;; observed is the item itself -- and stops short of mastery
        ;;; because the observer was a model.  `near` is a real outcome
        ;;; here and not a near-miss on spelling: it is the confidence
        ;;; floor, the verdict that says `I could not tell`, and it must
        ;;; move the belief in neither direction.
        if     outcome == "near"  then b
        elseif outcome == "right" then min(b + (1.0 - b) * 0.45, MACHINE_CAP)
        elseif outcome == "wrong" then b * 0.30
        else                           b * 0.20      ;;; skip
        endif
    elseif tier == 4 then
        ;;; moves like a check, because something was observed -- and
        ;;; stops short of mastery, because what was observed was a
        ;;; different item
        min(b + (1.0 - b) * 0.45, INFERRED_CAP)
    elseif tier == 2 then
        min(b + (1.0 - b) * 0.20
              * (if outcome == "right" then 1.0 else 0.3 endif), TIER2_CAP)
    else
        min(b + 0.05, TIER3_CAP)
    endif -> nb;
    if lp_undo_watch then
        ;;; every belief this answer moves, so the undo is complete
        lp_undo <> [[% lp_bkey(lp_user, item, ch), b %]] -> lp_undo;
    endif;
    nb -> lp_beliefs(lp_bkey(lp_user, item, ch));
    ;;; A WORD in memory and a string on disk, converted in lp_save and
    ;;; back in lp_load_profile.  Converting at one end only is how the
    ;;; first version of this both failed to measure anything (a string
    ;;; is never == to the word "right") and crashed json_generate on the
    ;;; next save, which has no idea what a Pop-11 word is.
    conspair({% item, ch, tier, outcome, latency_ms, lp_now_ms() %},
             lp_journal) -> lp_journal;
    ;;; Only a CHECK infers, and an inference records at tier 4, so this
    ;;; cannot run away: one level, once.
    if tier == 1 and outcome == "right" then lp_infer(item) endif;
enddefine;

;;; Accuracy and speed over the tier-1 evidence for one item set.  Speed
;;; is reported separately and never averaged into accuracy: a student
;;; who is right slowly has not learned to read, and one number would
;;; hide that.
define lp_measure(items, latency_ms) -> (acc, fast, n);
    lvars items, latency_ms, e, right = 0, quick = 0, n = 0;
    for e in lp_journal do
        nextunless(e(3) == 1 and member(e(1), items));
        ;;; A skipped question counts in the denominator.  Declining to
        ;;; answer is evidence, and dropping it would let a student raise
        ;;; their accuracy by answering only what they knew.
        n + 1 -> n;
        if lp_outcome_ok(e(4)) then right + 1 -> right;
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

;;; Named here rather than in audio.p because lp_main has to ask whether
;;; a voice exists before it decides whether to load audio.p at all.
define lp_audio_conf_path() -> p;
    lvars p = lp_home() <> 'audio.conf';
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
        conspair({% e(1) sys_>< '', e(2) sys_>< '', e(3),
                    e(4) sys_>< '', e(5), e(6) %}, j) -> j;
    endfor;
    consvector(#| for e in j do e endfor |#) -> o('journal');
    consvector(#| for a in lp_assigns do
                      {% a(1), a(2) sys_>< '', a(3) sys_>< '', a(4), a(5) %}
                  endfor |#) -> o('assignments');
    consvector(#| for a in lp_corrections do a endfor |#) -> o('corrections');
    ;;; The aids that are OFF, by name, rather than a map of booleans.
    ;;; An absent JSON field and a field set to false are the same thing
    ;;; on the way back in, so a map could not tell a profile written
    ;;; before an aid existed from one that switched it off -- and
    ;;; reading the first as the second would silently take an aid away.
    consvector(#| for a in lp_aid_names() do
                      unless lp_aid(a) then a sys_>< '' endunless
                  endfor |#) -> o('aids_off');
    consvector(#| for a in lp_aid_log do
                      {% a(1) sys_>< '', a(2), a(3) %}
                  endfor |#) -> o('aid_changes');
    ;;; The listening rate, if one was ever chosen.  Written from the
    ;;; HELD name rather than lp_rate, because a session that never
    ;;; loaded audio.p still has to save the choice it was started with.
    if lp_audio_loaded then lp_rate -> lp_rate_want endif;
    if lp_rate_want then lp_rate_want sys_>< '' -> o('rate') endif;
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
    lp_aids_reset(); lp_queue_reset();
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
            ;;; e(4) is an outcome word.  A profile written before there
            ;;; were four of them holds a boolean there, so map it.
            conspair({% consword(e(1)), consword(e(2)), e(3),
                        if e(4) == true then "right"
                        elseif e(4) == false then "wrong"
                        else consword(e(4) sys_>< '') endif,
                        e(5), e(6) %}, lp_journal) -> lp_journal;
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
    ;;; Into the held name, not lp_rate: the profile is read at login and
    ;;; audio.p is not loaded until something asks to hear a word.
    if o('rate') then consword(o('rate') sys_>< '') -> lp_rate_want endif;
    if o('aids_off') then
        for i from 1 to length(o('aids_off')) do
            false -> lp_aids(consword(o('aids_off')(i) sys_>< ''));
        endfor;
    endif;
    ;;; The log is loaded, not replayed: it is the audit of what the
    ;;; student chose, which outlives the session the choices were made
    ;;; in, and the state it ends at is the one above.
    if o('aid_changes') then
        for i from 1 to length(o('aid_changes')) do
            o('aid_changes')(i) -> e;
            lp_aid_log <> [{% consword(e(1) sys_>< ''), e(2), e(3) %}]
                -> lp_aid_log;
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
vars lp_kana_rom = newproperty([], 512, false, "perm");

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

;;; ------------------------------------------------------------ morae
;;; A mora is a unit of TIME, and it is the thing about Japanese that an
;;; English speaker gets wrong without noticing: きって is three beats,
;;; not two syllables, and がっこう is four.
;;;
;;; --audit reported skill(mora_count) and skill(mora_sokuon) as `thin`
;;; over a set of one item -- あ -- which cannot demonstrate beat
;;; counting whatever the student does with it.  The obvious reading of
;;; that was "timing needs audio".  It does not: PRODUCING correct timing
;;; needs a microphone, but KNOWING how many beats a word has is a
;;; reading question with a number for an answer, and the number is
;;; computable from the kana.
;;;
;;; The rules, and all four matter:
;;;
;;;   every kana        one beat
;;;   small ゃゅょ       no beat -- it joins the kana before it
;;;   small っ          one beat, of silence
;;;   ん                one beat, which is why it is `moraic`
;;;   ー                one beat
;;;
;;; The first two are what make this worth asking at all.  きょう looks
;;; like three characters and is two beats; きって looks like three and is
;;; three.  A student who gets both right has the thing the criterion is
;;; named for.

;;; The small kana that COMBINE with the one before, and so add no beat.
;;; Small っ is deliberately not among them -- it IS a beat, of silence,
;;; and that is the whole of skill(mora_sokuon).
define lp_small_kana(cp) -> yes;
    lvars cp, c, yes = false;
    for c in [% 16:3041, 16:3043, 16:3045, 16:3047, 16:3049,     ;;; ぁぃぅぇぉ
                 16:3083, 16:3085, 16:3087, 16:308E %] do        ;;; ゃゅょゎ
        if cp == c or cp == c + 16:60 then true -> yes; return endif;
    endfor;
enddefine;

define lp_morae(kana) -> n;
    lvars kana, cp, n = 0;
    for cp in [% utf8_explode(kana sys_>< '') %] do
        nextif(lp_small_kana(cp));
        n + 1 -> n;
    endfor;
enddefine;

;;; Does this kana string exercise the feature a probe asks about?
;;;
;;; `long_vowel` is the awkward one.  ー is explicit, but hiragana spells
;;; a long vowel by doubling: おおきい is お+お, こうこう is お+う.  So the
;;; test is a vowel-or-u following the kana whose vowel it lengthens,
;;; which is the same `last vowel` the romaji builder already computes --
;;; asked of lp_romaji rather than spelled a second time, because two
;;; spellings of one rule is how きょう came out as ko the first time.
define lp_kana_feature(kana, f) -> yes;
    lvars kana, f, cps, i, n, rom, yes = false;
    [% utf8_explode(kana sys_>< '') %] -> cps;
    length(cps) -> n;
    if f == "any" then
        return(lp_morae(kana) >= 2 -> yes);
    elseif f == "sokuon" then
        for i from 1 to n do
            if lp_sokuon(cps(i)) then true -> yes; return endif;
        endfor;
    elseif f == "moraic_n" then
        for i from 1 to n do
            if cps(i) == 16:3093 or cps(i) == 16:30F3 then
                true -> yes; return
            endif;
        endfor;
    elseif f == "youon" then
        for i from 1 to n do
            if lp_youon(cps(i)) then true -> yes; return endif;
        endfor;
    elseif f == "long_vowel" then
        for i from 1 to n do
            if lp_longmark(cps(i)) then true -> yes; return endif;
        endfor;
        ;;; Otherwise the romaji is where it shows -- but NOT simply as
        ;;; two vowels in a row.  いえ is `ie`, which is two vowels and
        ;;; two different ones: い then え, two beats of two sounds, no
        ;;; length anywhere.  The first version of this test took any
        ;;; adjacent pair and duly offered いえ as a long-vowel exercise.
        ;;;
        ;;; A long vowel is the SAME vowel twice, or one of the two
        ;;; spellings Japanese uses for a long one: おう and えい.
        lp_romaji(kana) -> rom;
        returnunless(rom);
        rom sys_>< '' -> rom;
        for i from 1 to length(rom) - 1 do
            nextunless(lp_is_vowel_c(rom(i)) and lp_is_vowel_c(rom(i + 1)));
            if rom(i) == rom(i + 1)
            or (rom(i) == `o` and rom(i + 1) == `u`)
            or (rom(i) == `e` and rom(i + 1) == `i`) then
                true -> yes; return
            endif;
        endfor;
    endif;
enddefine;

;;; --------------------------------------------------------- syllables
;;; The English half of the same idea, and the same mistake underneath.
;;;
;;; A Japanese speaker says ドッグ for `dog` -- three beats where English
;;; has one syllable -- because Japanese has no way to end a syllable in
;;; a consonant and puts a vowel there instead.  That is what
;;; skill(final_consonants) is named for: "ends a word without adding a
;;; vowel".  It was measured over s_final, a `hear` item, so it needed
;;; audio and the English pre-school rung could not be exited.
;;;
;;; But the knowledge half is countable, exactly as the mora half was:
;;; how many syllables does the English word have?  One per vowel
;;; nucleus, and the IPA CMUdict gives us is enough to count them.
;;;
;;; The five diphthongs are two symbols and one nucleus.  Counting
;;; vowel SYMBOLS makes `child` two syllables; counting nuclei makes it
;;; one.  The pairs are exactly the five ARPABET diphthongs the importer
;;; maps, so this is not a guess about English, it is the inverse of a
;;; table in import.p.
lconstant EN_VOWELS = 'ɑæʌɔɛɜəɪiʊueoɝɚa';
lconstant EN_DIPHTHONGS = ['aʊ' 'aɪ' 'eɪ' 'oʊ' 'ɔɪ'];

define lp_en_vowel(cp) -> yes;
    lvars cp, c, yes = false;
    for c in [% utf8_explode(EN_VOWELS) %] do
        if c == cp then true -> yes; return endif;
    endfor;
enddefine;

define lp_syllables(ipa) -> n;
    lvars ipa, cps, i, len, n = 0, pair;
    [% utf8_explode(ipa sys_>< '') %] -> cps;
    length(cps) -> len;
    1 -> i;
    until i > len do
        unless lp_en_vowel(cps(i)) then i + 1 -> i; nextloop endunless;
        n + 1 -> n;
        ;;; one nucleus, and the glide of a diphthong belongs to it
        if i < len and lp_en_vowel(cps(i + 1))
        and member(consutf8(#| cps(i), cps(i + 1) |#), EN_DIPHTHONGS) then
            i + 2 -> i
        else
            i + 1 -> i
        endif;
    enduntil;
enddefine;

;;; Which skills carry a generated question, from the graph.  Built on
;;; first use, the same way the kana map and the edges are, and for the
;;; same reason: the tutor does not need it until something asks.
vars lp_probes = newproperty([], 16, false, "perm"),
     lp_probes_ready = false;

define lp_probe_of(skill) -> f;
    lvars skill, t, f;
    unless lp_probes_ready then
        true -> lp_probes_ready;
        clearproperty(lp_probes);
        lvars p;
        for p in lp_ask("probes", 0) do
            prolog_full_deref(prolog_arg(2, p))
                -> lp_probes(prolog_deref(prolog_arg(1, p)));
        endfor;
    endunless;
    lp_probes(skill) -> f;
enddefine;

;;; Which kind of question a skill's probe is: `morae` or `syllables`.
define lp_probe_kind(skill) -> k;
    lvars skill, f = lp_probe_of(skill), k = false;
    returnunless(f and prolog_complexterm(f));
    prolog_functor(f) -> k;
enddefine;

;;; The English material: an item with BOTH an English pronunciation and
;;; a katakana one, where the katakana takes more beats than the English
;;; takes syllables.  That difference is the lesson, and an item where
;;; the two agree would be a question with nothing in it.
;;;
;;; The twelve loanword traps are exactly this set, which is a happy
;;; accident of what they were curated for rather than a coincidence:
;;; they were chosen as words a Japanese speaker already half-knows in
;;; katakana.
define lp_syl_material(skill) -> items;
    lvars skill, i, ipa, kata, items = [], top = lp_level_index(lp_level);
    for i in lp_items do
        nextunless(lp_ilang(i) == "en");
        nextunless(lp_level_index(lp_ilevel(i)) >= 0
                   and lp_level_index(lp_ilevel(i)) <= top);
        lp_form_of(i, "ipa") -> ipa;
        lp_form_of(i, "katakana") -> kata;
        nextunless(ipa and kata);
        if lp_morae(kata) > lp_syllables(ipa) then
            items <> [^i] -> items
        endif;
    endfor;
enddefine;

;;; The material: every word or kanji in this language whose kana form
;;; has the feature, with at least two beats so the question is a real
;;; one.  Drawn from the graph rather than listed, so a content build
;;; that adds a thousand N5 words adds a thousand mora questions.
define lp_mora_material(skill) -> items;
    lvars skill, f = lp_probe_of(skill), i, k, items = [];
    returnunless(f and prolog_complexterm(f));
    prolog_deref(prolog_arg(1, f)) -> f;
    lvars top = lp_level_index(lp_level);
    for i in lp_items do
        nextunless(lp_ilang(i) == "ja");
        nextif(lp_kind(i) == "skill");
        ;;; At this level or below.  The question is about beats and not
        ;;; about meaning, but it is still asked in kana, and showing a
        ;;; pre-school student an N5 word is showing them characters they
        ;;; have not been taught.
        nextunless(lp_level_index(lp_ilevel(i)) >= 0
                   and lp_level_index(lp_ilevel(i)) <= top);
        lp_form_of(i, "hiragana") -> k;
        nextunless(k);
        nextunless(lp_morae(k) >= 2);
        if lp_kana_feature(k, f) then items <> [^i] -> items endif;
    endfor;
enddefine;

;;; Either kind, one procedure, so lp_question and --audit both ask the
;;; same question about a skill rather than each knowing the two cases.
define lp_probe_material(skill) -> items;
    lvars skill, k = lp_probe_kind(skill), items = [];
    if     k == "morae"     then lp_mora_material(skill) -> items
    elseif k == "syllables" then lp_syl_material(skill) -> items
    endif;
enddefine;

;;; Which piece of material to use this time.  Rotated by how often the
;;; SKILL has been asked, so a student meets a different word each time
;;; without the tutor having to remember anything -- the journal already
;;; knows.
define lp_mora_item(skill) -> i;
    lvars skill, items = lp_probe_material(skill), i = false;
    returnif(items == []);
    items(1 + (lp_asked(skill) mod length(items))) -> i;
enddefine;

;;; The prompt and the answer for one piece of material.
define lp_probe_ask(skill, m) -> (prompt, answer);
    lvars skill, m, k = lp_probe_kind(skill), f;
    (false, false) -> (prompt, answer);
    if k == "morae" then
        lp_form_of(m, "hiragana") -> f;
        if f then (f sys_>< '', lp_morae(f)) -> (prompt, answer) endif;
    elseif k == "syllables" then
        lp_form_of(m, "latin") -> f;
        if f then
            (f sys_>< '', lp_syllables(lp_form_of(m, "ipa"))) -> (prompt, answer)
        endif;
    endif;
enddefine;

;;; The wrong answer worth naming.
;;;
;;; A Japanese speaker asked how many syllables `slim` has will answer
;;; four, because スマート has four beats -- and that is not a guess, it
;;; is the katakana box, answered honestly.  So it is recorded as `near`
;;; rather than `wrong`, and the tutor says which count they gave.  A
;;; verdict that only says `no` to this teaches nothing: they already
;;; know they got it wrong, and not why.
define lp_count_near(item, typed) -> why;
    lvars item, typed, kata, why = false, n;
    returnunless(lp_probe_kind(item) == "syllables");
    lp_mora_item(item) -> item;
    returnunless(item);
    lp_form_of(item, "katakana") -> kata;
    returnunless(kata);
    strnumber(typed sys_>< '') -> n;
    returnunless(n and n == lp_morae(kata));
    (kata sys_>< '') -> why;
enddefine;

;;; -------------------------------------------------- confusion pairs
;;; pair(Contrast, A, B) from the graph: two real words the contrast
;;; keeps apart and a Japanese speaker is liable to merge.  See the
;;; comment on the facts in graph/en/items.pl for why they are not called
;;; minimal pairs.
vars lp_pairs = newproperty([], 16, [], "perm"), lp_pairs_ready = false;

define lp_pairs_of(contrast) -> ps;
    lvars contrast, ps, pr, c;
    unless lp_pairs_ready then
        true -> lp_pairs_ready;
        clearproperty(lp_pairs);
        for pr in lp_ask("pairs", 0) do
            prolog_deref(prolog_arg(1, pr)) -> c;
            lp_pairs(c) <> [[% prolog_full_deref(prolog_arg(2, pr)),
                               prolog_full_deref(prolog_arg(3, pr)) %]]
                -> lp_pairs(c);
        endfor;
    endunless;
    lp_pairs(contrast) -> ps;
enddefine;

;;; Rotated by how often this contrast has been asked, exactly as the
;;; mora material is: four pairs is four questions, and a bigger graph
;;; is a bigger question bank for free.
define lp_pair_item(contrast) -> pr;
    lvars contrast, ps = lp_pairs_of(contrast), pr = false;
    returnif(ps == []);
    ps(1 + (lp_asked(contrast) mod length(ps))) -> pr;
enddefine;

;;; A pair word is drill material belonging to a contrast, not an item,
;;; so its audio is cached under a slug of the word itself.  Several
;;; contrasts share a word -- `berry` separates /r/-/l/ from belly and
;;; /v/-/b/ from very -- and one file serves both.
define lp_pair_word_name(word) -> n;
    lvars word, n = 'pair-' <> lp_audio_slug(word);
enddefine;

;;; "en" literally: the pairs are English words and so is their audio,
;;; whichever language the session is being taught in.  A Japanese
;;; speaker drilling /r/ against /l/ needs an English voice saying them,
;;; and lp_lang at that moment is "en" anyway -- but the contrast is a
;;; property of English, not of the session.
define lp_pair_audio(word, rate) -> (path, why);
    lvars word, rate, path, why;
    lp_audio_path_of(lp_pair_word_name(word), word, "en", rate)
        -> (path, why);
enddefine;

;;; WHICH WORD DID YOU HEAR.  Discrimination, and it needs no microphone
;;; -- the answer is one of two words on the screen.  This is what makes
;;; a sound contrast askable at all: a contrast has no written form, so
;;; lp_question returned `none` for all twelve of them and --audit called
;;; the whole family needs_audio.  It was never the microphone that was
;;; missing; it was a pair.
;;;
;;; Deliberately shaped as listen_pick and NOT as a new shape.  The
;;; interaction is identical -- hear a sound, choose between two options
;;; -- so lp_drill, every client and the protocol need no new arm.  The
;;; difference is only what the options mean: two glosses for a trap,
;;; two words for a contrast.
;;;
;;; The one-in-two guess is real and is the same bargain the trap
;;; questions already strike.  There is no typing version of this
;;; question: a student who cannot hear /r/ from /l/ cannot type the
;;; difference either, and asking them to spell what they heard would be
;;; testing spelling.
define lp_pair_question(item) -> (shape, prompt, answer, options);
    lvars item, shape, prompt, answer, options, pr, said, other, path, why;
    ("none", '', [], []) -> (shape, prompt, answer, options);
    lp_pair_item(item) -> pr;
    returnunless(pr);
    ;;; Which of the two is played, and in which position it is offered,
    ;;; both turn over -- otherwise the answer is always 1, or always the
    ;;; first word of the pair, and the student learns the pattern
    ;;; instead of the contrast.
    ;;;
    ;;; The side turns over per CYCLE and not per question, which is the
    ;;; difference between rotating and not.  lp_pair_item already picks
    ;;; the pair with `asked mod 4`, so a side chosen with `asked mod 2`
    ;;; gives pair 0 an even count every time: right/light would play
    ;;; `right` for ever and `light` never, and the student could learn
    ;;; the pair number instead of the contrast.  Dividing first means
    ;;; the first pass through the four pairs plays one side of each and
    ;;; the second pass plays the other.
    lvars ps = lp_pairs_of(item);
    lp_flip + 1 -> lp_flip;
    if (lp_asked(item) div length(ps)) mod 2 == 0 then (hd(pr), hd(tl(pr)))
    else (hd(tl(pr)), hd(pr)) endif -> (said, other);
    lp_pair_audio(said, "normal") -> (path, why);
    returnif(why);
    if lp_flip mod 2 == 1 then
        ("listen_pick", path, ['1'], [% said, other %])
    else
        ("listen_pick", path, ['2'], [% other, said %])
    endif -> (shape, prompt, answer, options);
enddefine;

;;; A LISTENING QUESTION IS THE SAME ANSWER KEY WITH A DIFFERENT
;;; STIMULUS.  The reading question shows あ and wants `a`; the listening
;;; question plays あ and wants `a`.  Only the prompt changes, so the
;;; grading, the slip tolerance, the confusable diagnosis and the whole
;;; of lp_drill below it are reused rather than reimplemented -- and
;;; `vocabulary(50, hear)` means exactly "can you recognise these fifty
;;; words by ear", which is what that substitution measures.
;;;
;;; The prompt is the PATH to the sound, not a glyph.  Printing the glyph
;;; would hand over the answer, so a listening question has nothing to
;;; read, and a client that cannot play audio gets a shape it does not
;;; know and should refuse rather than render.
;;;
;;; Two conditions, both checked here so no caller can forget them:
;;;   - the audio must ALREADY BE CACHED.  lp_audio_path never runs a
;;;     model, because a student waiting on a model load mid-question is
;;;     a tutor that feels broken (--audio <level> is how it gets there).
;;;   - at the NORMAL rate.  A slowed voice is an easier exposure, and
;;;     for the geminate words it is a rhythm the language does not have
;;;     -- so it is a fine way to study and not a way to be measured.
define lp_hear_question(item) -> (shape, prompt, answer, options);
    lvars item, shape, prompt, answer, options, path, why;
    ("none", '', [], []) -> (shape, prompt, answer, options);
    returnunless(lp_can_hear());
    returnunless(member("hear", lp_channels(item)));
    ;;; A sound contrast has no written form of its own -- it is not a
    ;;; word -- so there is no reading question to swap the stimulus of.
    ;;; It is asked through the two words it keeps apart.
    if lp_kind(item) == "sound" then
        lp_pair_question(item) -> (shape, prompt, answer, options);
        return;
    endif;
    lp_audio_path(item, "normal") -> (path, why);
    returnif(why);
    lp_question(item, lp_primary(item)) -> (shape, prompt, answer, options);
    if shape == "type" then "listen" -> shape;
    elseif shape == "pick" then "listen_pick" -> shape;
    else
        ;;; A counting probe is not made into a listening question here.
        ;;; "How many beats in what you just heard" is a real and useful
        ;;; question -- it is perception, not production, so it needs no
        ;;; microphone either -- but it is a different probe with a
        ;;; different answer, not this one with the glyph taken away.
        ("none", '', [], []) -> (shape, prompt, answer, options); return;
    endif;
    path -> prompt;
enddefine;

define lp_question(item, ch) -> (shape, prompt, answer, options);
    lvars item, ch, k = lp_kind(item), r, en, ja, glyph, kanji, reads;
    ("none", '', [], []) -> (shape, prompt, answer, options);
    if ch == "hear" then
        lp_hear_question(item) -> (shape, prompt, answer, options);
        return;
    endif;
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
    elseif k == "skill" and lp_probe_of(item) then
        ;;; "How many beats is this?", or "how many syllables?"  The
        ;;; material comes from the graph and the answer is counted from
        ;;; the forms, so neither is written down anywhere and a bigger
        ;;; graph is a bigger question bank for free.
        lvars m = lp_mora_item(item), mp, ma;
        if m then
            lp_probe_ask(item, m) -> (mp, ma);
            if mp then
                ("count", mp, [% ma sys_>< '' %], [])
                    -> (shape, prompt, answer, options);
            endif;
        endif;
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

define lp_drillable_on(item, ch);
    lvars item, ch, shape;
    lp_question(item, ch) -> (shape, , , );
    shape /== "none"
enddefine;

;;; On its GATE channel, which is what the plan and the gate ask about.
define lp_drillable(item);
    lvars item;
    lp_drillable_on(item, lp_primary(item))
enddefine;

;;; The confusable that the student probably meant.  This is why the
;;; graph records pairs: a wrong answer is diagnosable, not just wrong.
;;; Which confusable partner the student reached for, if any.
;;;
;;; Any of the partner's forms, not only its romaji.  The answer space is
;;; romaji at pre-school, so comparing romaji alone was enough there --
;;; but a student who types お for あ has made exactly the confusion the
;;; pair records, and got told "Not yet" as though they had typed
;;; nonsense.  It matters more above pre-school, where a reading may be
;;; answered in kana.
define lp_mistook(item, typed) -> other;
    lvars item, typed, p, sc, f;
    false -> other;
    for p in lp_confs(item) do
        for sc in [romaji hiragana katakana kanji latin] do
            lp_form_of(hd(p), sc) -> f;
            if f and lp_lower(f sys_>< '') = typed then
                hd(p) -> other; return
            endif;
        endfor;
    endfor;
enddefine;

;;; ------------------------------------------------------ putting it off
;;; A question a student does not want to answer now is not a question
;;; they got wrong, and it should come back.  Two routes lead here:
;;;
;;;   later    typed at a question -- they decline it, nothing is recorded
;;;   :oops    the last answer was an input accident -- it is undone
;;;
;;; and both end in the same place: the item goes back in the queue and
;;; is asked again THIS session, after other questions have intervened.
;;;
;;; The gap is the point, and it is what makes :oops honest.  :oops is
;;; used after the tutor has already said what the answer was, so asking
;;; again immediately would measure the echo rather than the memory --
;;; it would hand a free correct answer to anything got wrong.  Three
;;; questions is not spaced repetition, but it is enough that the answer
;;; has to be recalled rather than read back off the screen.
;;;
;;; Distinct from the empty line, which is NOT this.  Pressing enter is
;;; "I do not know": a real answer, and the most informative one a
;;; beginner gives.  It is recorded, it counts in the denominator of
;;; every criterion, and it is what stops a placement descent.  A
;;; service with one pass button has to guess which of the two a student
;;; meant; langpop has four outcomes and can afford to keep them apart.
lconstant REQUEUE_GAP = 3, LATER_MAX = 2;

vars lp_pending = [],                   ;;; [{item not_before channel} ...]
     lp_asked_n = 0,                    ;;; questions actually recorded
     lp_later_n = 0,                    ;;; questions put off, this session
     lp_laters = newproperty([], 32, 0, "perm");

;;; Placement does not offer it.  A freeze is the signal the descent runs
;;; on, so a student who could defer every hard question would never be
;;; placed -- and "press enter, that is an answer" is the right thing to
;;; say there anyway.
vars lp_allow_later = true;

define lp_queue_reset();
    [] -> lp_pending; 0 -> lp_asked_n; 0 -> lp_later_n;
    clearproperty(lp_laters);
enddefine;

define lp_unqueue(item);
    lvars item, p;
    [% for p in lp_pending do unless p(1) == item then p endunless endfor %]
        -> lp_pending;
enddefine;

;;; The queue remembers the CHANNEL, because a listening question put off
;;; must come back as a listening question.  Without it the deferred
;;; item returned as a reading question -- not wrong data, but the hear
;;; belief the student was being asked about would never move, so the
;;; criterion they were working on would stand still.
define lp_requeue_on(item, ch);
    lvars item, ch;
    lp_unqueue(item);                   ;;; one copy, the later gap wins
    lp_pending <> [{% item, lp_asked_n + REQUEUE_GAP, ch %}] -> lp_pending;
enddefine;

define lp_requeue(item);
    lvars item;
    lp_requeue_on(item, lp_primary(item));
enddefine;

;;; Which channel this one is waiting on.  Primary when it is not
;;; waiting at all, so a caller need not ask twice.
define lp_due_ch(item) -> ch;
    lvars item, p, ch = lp_primary(item);
    for p in lp_pending do
        if p(1) == item then p(3) -> ch; return endif;
    endfor;
enddefine;

;;; Is this one waiting, and not yet due?
;;;
;;; lp_choose has to know.  Without this the deferral achieved nothing:
;;; the item put off had the lowest belief of anything ready, which is
;;; exactly what lp_choose picks, so it came straight back as the very
;;; next question -- and so did one taken back with :oops, which is the
;;; free correct answer the gap exists to prevent.  Found by running it,
;;; which is the only way that one shows.
define lp_deferred(item) -> yes;
    lvars item, p, yes = false;
    for p in lp_pending do
        if p(1) == item then p(2) > lp_asked_n -> yes; return endif;
    endfor;
enddefine;

;;; The item that has waited longest among those whose gap has elapsed.
define lp_due() -> item;
    lvars p, item = false;
    for p in lp_pending do
        if p(2) <= lp_asked_n and lp_drillable_on(p(1), p(3)) then
            p(1) -> item; return
        endif;
    endfor;
enddefine;

;;; Twice, and then it is asked for real.  Without a limit "later" is a
;;; way never to be wrong about anything, which is precisely the
;;; self-deception the switch in :aids exists to let a student refuse --
;;; and a limit is cheaper than asking them to be disciplined.
define lp_can_later(item) -> yes;
    lvars item, yes = lp_aid("later") and lp_allow_later
                      and lp_laters(item) < LATER_MAX;
enddefine;

;;; One recorded answer.  The item is no longer waiting to be asked, and
;;; the counter the requeue gap is measured in moves -- it counts
;;; QUESTIONS ANSWERED rather than prompts printed, so a slip retry and a
;;; deferral do not shorten the gap for anything else.
;;;
;;; A procedure rather than two lines inline, because langpop/answer
;;; records without going through the drill loop at all.
define lp_answered(item);
    lvars item;
    lp_unqueue(item);
    lp_asked_n + 1 -> lp_asked_n;
enddefine;

define lp_later_on(item, ch);
    lvars item, ch;
    lp_laters(item) + 1 -> lp_laters(item);
    lp_later_n + 1 -> lp_later_n;
    lp_requeue_on(item, ch);
enddefine;

define lp_later(item);
    lvars item;
    lp_later_on(item, lp_primary(item));
enddefine;

;;; `ch` is the channel the answer is RECORDED on, and for everything but
;;; a listening question it is the item's gate channel.  It is a
;;; parameter rather than lp_primary(item) inside, because the same item
;;; now carries two independent beliefs -- read it, and hear it -- and a
;;; listening answer credited to reading would be the comfortable
;;; averaging that channels were introduced to stop.
define lp_drill(item, ch) -> done;
    lvars item, ch, shape, prompt, answer, options, o, i = 0, t0, line, typed,
          other, kslip = false, retried = false, heard = false, shown;
    true -> done;
    lp_question(item, ch) -> (shape, prompt, answer, options);
    returnif(shape == "none")(false -> done);
    if shape == "listen" or shape == "listen_pick" then true -> heard endif;
    ;;; WHAT TO SAY IT WAS.  For a typed question the answer is the
    ;;; answer.  For a question answered by number the answer is a
    ;;; NUMBER, and "It is 2." tells a student nothing they can learn
    ;;; from -- the first contrast-pair session read
    ;;;
    ;;;     Not yet.  It is 2 -- /v/ - /b/.
    ;;;
    ;;; when what they needed was the word: it was `vote`, and the thing
    ;;; they missed was /v/ against /b/.  Also true of the trap
    ;;; questions, which have been revealing option numbers all along.
    if (shape == "pick" or shape == "listen_pick")
    and strnumber(hd(answer)) and strnumber(hd(answer)) <= length(options)
    then options(strnumber(hd(answer))) else hd(answer) endif -> shown;
    lp_now_ms() -> t0;
    repeat
        0 -> i;
        if heard then
            ;;; Nothing to read.  The sound is the whole prompt, so the
            ;;; glyph must not appear anywhere until the answer is in.
            printf('\n  %p\n', [% lp_line('listen') %]);
            ;;; AND NOTHING IS RECORDED IF IT DID NOT PLAY.  Asking "what
            ;;; did you hear?" of a student who heard nothing, and then
            ;;; filing the answer, would be recording a failure of this
            ;;; machine as a failure of the learner.  The first version
            ;;; printed the path and carried on, because lp_audio_play
            ;;; only checked that a player BINARY existed -- and the
            ;;; session transcript duly showed afplay failing on every
            ;;; question while the questions kept coming.
            unless lp_audio_play(prompt) then
                printf('  I cannot play that here, so I will not mark it.\n');
                printf('  (%p)\n', [^prompt]);
                false -> done; lp_undo_stop(); return;
            endunless;
            if shape == "listen_pick" then
                for o in options do
                    i + 1 -> i; printf('    %p) %p\n', [% i, o %]);
                endfor;
            endif;
            printf('  -> ');
        elseif shape == "type" then
            printf('\n  %p    -> ', [^prompt]);
        elseif shape == "count" then
            ;;; The word, then the question, because the question is the
            ;;; same every time and the word is not -- a student reading
            ;;; down the transcript should see what changed.
            ;;;
            ;;; Beats or syllables depending on which it is: asking a
            ;;; Japanese speaker how many BEATS `mansion` has is asking
            ;;; them for the katakana count, which is the one answer the
            ;;; question exists to catch.
            printf('\n  %p\n', [^prompt]);
            printf('  %p  -> ',
                   [% lp_line(if lp_probe_kind(item) == "syllables"
                              then 'syllables' else 'beats' endif) %]);
        else
            printf('\n  %p\n', [^prompt]);
            for o in options do i + 1 -> i; printf('    %p) %p\n', [% i, o %]) endfor;
            printf('  -> ');
        endif;
        sysflush(popdevout);
        lp_readline() -> line;
        if line == termin then false -> done; lp_undo_stop(); return endif;
        lp_norm(line) -> typed;

        ;;; A replay is free and unlimited.  A listening question the
        ;;; student may only hear once is a memory test with a hearing
        ;;; test on top of it, and the belief would be measuring the
        ;;; wrong one of the two.  Nothing is recorded, and the clock
        ;;; deliberately keeps running: speed on a listening item is
        ;;; speed from the first playing, or a replay would be a way to
        ;;; stop the clock.
        if heard and (typed = 'again' or typed = ':again') then
            printf('  %p\n', [% lp_line('again') %]);
            nextloop;
        endif;

        ;;; "later" is not an answer, and nothing about it is recorded.
        ;;; It is deliberately a word rather than a blank line, because
        ;;; the blank line already means something quite different and
        ;;; more useful.
        if typed = 'later' or typed = ':later' then
            if not(lp_aid("later")) then
                printf('  "later" is off -- :aids later on puts it back.\n');
            elseif not(lp_allow_later) then
                printf('  Not during a placement.  Press enter if you do not\n');
                printf('  know it -- that is an answer, and it tells me more.\n');
            elseif not(lp_can_later(item)) then
                printf('  That is twice now.  Let us settle this one: press\n');
                printf('  enter if you do not know it.\n');
            else
                lp_later_on(item, ch);
                printf('  %p\n', [% lp_line('later') %]);
                return;
            endif;
            nextloop;
        endif;

        lp_mistook(item, typed) -> other;

        ;;; A slip gets ONE more go, and the first attempt is not
        ;;; recorded.  Offered rather than forgiven: "I will take that as
        ;;; やま" would credit an answer they did not actually produce,
        ;;; and the point is to let them fix it, not to score it for
        ;;; them.  Nothing is revealed -- short answers get no tolerance,
        ;;; so ke for ka never reaches here and never hints that it was
        ;;; close.
        ;;;
        ;;; An exact match wins first, and so does a confusable partner:
        ;;; typing the other half of a pair the graph records is a
        ;;; knowledge error, not a slip, however few letters apart they
        ;;; are.
        if lp_aid("slip") and not(retried) and not(member(typed, answer))
        and not(other)
        and typed /= '' and typed /= '?' and lp_slip(typed, answer) then
            true -> retried;
            printf('  %p\n', [% lp_line('slip') %]);
            nextloop;
        endif;
        quitloop;
    endrepeat;

    lp_undo_start(item);
    lp_answered(item);
    ;;; The clock runs from the FIRST attempt.  Resetting it on a retry
    ;;; would make a deliberate slip a way to buy time, and the speed
    ;;; half of every pre-school criterion is what tells reading from
    ;;; working it out.
    if member(typed, answer) then
        lp_record(item, ch, 1, "right", lp_now_ms() - t0);
        printf('  %p%p\n',
               [% lp_line('praise'),
                  ;;; After a listening question, SHOW it: the student
                  ;;; has just recognised a sound and the written form is
                  ;;; the other half of the same item.
                  if heard then '  ' <> (lp_any_form(item) sys_>< '')
                  else '' endif %]);
    elseif typed = '' or typed = '?' then
        ;;; An empty line, or a question mark, is "I do not know" -- and
        ;;; saying so is worth more than a guess, both to the student and
        ;;; to the belief.  A tutor that forced a guess would be throwing
        ;;; the most informative answer away.
        lp_record(item, ch, 1, "skip", lp_now_ms() - t0);
        printf('  %p  It is %p%p.\n',
               [% lp_line('skip'), shown,
                  if heard then ' -- ' <> (lp_any_form(item) sys_>< '')
                  else '' endif %]);
    else
        ;;; The wrong answer worth naming: a count that is the katakana's
        ;;; and not the English word's.  Computed BEFORE lp_record,
        ;;; because recording changes lp_asked and lp_asked is what
        ;;; chooses the material.
        if shape == "count" then lp_count_near(item, typed) -> kslip endif;
        lp_record(item, ch, 1,
                  if other or kslip then "near" else "wrong" endif,
                  lp_now_ms() - t0);
        if other then
            printf('  %p  That is %p -- the two are confused constantly.\n',
                   [% lp_line('almost'), lp_any_form(other) %]);
        elseif kslip then
            printf('  %p  That is the beats in %p.  The English word has %p.\n',
                   [% lp_line('almost'), kslip, shown %]);
        else
            printf('  %p  It is %p%p.\n',
                   [% lp_line('wrong'), shown,
                      if heard then ' -- ' <> (lp_any_form(item) sys_>< '')
                      else '' endif %]);
        endif;
    endif;
    lp_undo_stop();
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
        lp_record(a(2), lp_primary(a(2)), 2,
                  if frac >= 0.7 then "right" else "wrong" endif, 0);
        printf('  Recorded: %p of %p, as reported evidence (tier 2).\n', [% got, tot %]);
        printf('  A reported score carries an item to just below mastery;\n');
        printf('  the next check here is what settles it.\n');
    else
        3 -> tier;
        lp_record(a(2), lp_primary(a(2)), 3, "right", 0);
        printf('  Recorded: done, as compliance (tier 3).\n');
        printf('  Compliance alone cannot reach mastery -- tell me a result\n');
        printf('  next time, or let me check you here.\n');
    endif;
    {% a(1), a(2), a(3), a(4), 'reported' %} -> a;
    [% lvars e; for e in lp_assigns do
           if e(1) == id then a else e endif endfor %] -> lp_assigns;
    true -> ok;
enddefine;

;;; ------------------------------------------------------------ placement
;;; "Go ahead and introduce yourself."  A true beginner freezes; one who
;;; answers gets "and what day is it today?", and so on until they stop
;;; -- which is how a teacher works out, in five minutes, which section
;;; somebody belongs in.  The point is not the questions.  It is that the
;;; teacher starts ABOVE where they expect and lets failure locate the
;;; student, and that a freeze ends the line of questioning.
;;;
;;; Placement is NOT a teaching mode.  It is a fast way to populate the
;;; belief overlay, and everything downstream already works off beliefs:
;;; lp_choose takes the lowest belief first, so a correctly placed
;;; student gets their weak spots immediately and skims what they know.
;;;
;;; So there is no placement state anywhere.  lp_place_next is a pure
;;; function of the beliefs already recorded -- "given what I know about
;;; you, what should I ask to locate you?" -- which means it can be
;;; called from the TUI in a loop, or over the wire by a client that
;;; answers through the ordinary langpop/answer, and nothing has to
;;; remember a session halfway through a test.
;;;
;;; ONE SCALAR WOULD BE THE WRONG ANSWER.  A learner who knows 500 kanji
;;; and keeps forgetting katakana is not "at" any single level, and
;;; placing them by one number would either drown them or bore them.  So
;;; the search runs per AXIS, and an axis is a kind of criterion rather
;;; than a level: the exit criteria already name them.

;;; How many answers settle an axis, and how well they have to go.
lconstant PLACE_SAMPLE = 4, PLACE_PASS = 0.75, PLACE_FREEZE = 2;

;;; The axes, as [name kind script] -- kind and script say which items
;;; probe it.  Derived from the exit criteria the language declares, so
;;; a ladder that adds a criterion gets an axis for free.
define lp_place_axes() -> axes;
    lvars e, c, f, axes = [], a;
    for e in lp_exits do
        nextunless(hd(e) == lp_lang);
        hd(tl(tl(e))) -> c;
        nextunless(prolog_complexterm(c));
        prolog_functor(c) -> f;
        ;;; {name  how  arg}, where `how` says which items probe it:
        ;;;   crit  ask the schema -- criterion_item/2 already answers
        ;;;         this for recognise and skill, and asking it here
        ;;;         rather than guessing from the forms is the whole
        ;;;         point.  A form scan looked right and was not: an
        ;;;         imported kanji carries a hiragana form (its kun
        ;;;         reading), so "every grapheme with a hiragana form"
        ;;;         pulled all 103 kanji into recognise(hiragana).
        ;;;   skill probe what the skill REQUIRES; a roll-up cannot be
        ;;;         typed, so the skill itself is not a question.
        ;;;   kind  scan by kind and script, for the counting criteria
        ;;;         that criterion_item/2 deliberately does not answer.
        if     f == "recognise" then
            {% 'recognise ' <> (prolog_deref(prolog_arg(1, c)) sys_>< ''),
               "crit", c %} -> a
        elseif f == "skill" then
            {% 'skill ' <> (prolog_deref(prolog_arg(1, c)) sys_>< ''),
               "skill", prolog_deref(prolog_arg(1, c)) %} -> a
        elseif f == "kanji" then
            ;;; a character is read, never heard: the reading is the
            ;;; word's channel, not the character's
            {% 'kanji', "kind", [grapheme kanji] %} -> a
        elseif f == "vocabulary" then
            nextunless(lp_verifiable(prolog_deref(prolog_arg(2, c))));
            {% 'vocabulary', "kind", [% "word", false %] %} -> a
        else
            nextloop                        ;;; coverage: nothing to probe
        endif;
        unless lp_place_seen(axes, a) then axes <> [^a] -> axes endunless;
    endfor;
    ;;; Hardest first, which is the teacher's move: open above where you
    ;;; expect them to be and let failure locate them.  An axis is as
    ;;; hard as the highest rung it reaches.  Every axis is still
    ;;; searched -- knowing 500 kanji says nothing about katakana, which
    ;;; is the whole reason this runs per axis -- so the order is about
    ;;; the shape of the conversation rather than the result.
    syssort(axes, false, procedure(x, y);
        lvars x, y, lx = lp_place_levels(x), ly = lp_place_levels(y);
        lp_level_index(if lx == [] then false else hd(lx) endif)
            > lp_level_index(if ly == [] then false else hd(ly) endif);
    endprocedure) -> axes;
enddefine;

;;; Where a level sits on its ladder, or -1 for none.
define lp_level_index(level) -> n;
    lvars level, l, n = -1;
    returnunless(level);
    for l in lp_ladders do
        if hd(l) == lp_lang and hd(tl(tl(l))) == level then
            hd(tl(l)) -> n; return
        endif;
    endfor;
enddefine;

;;; Two axes are the same if they have the same name.  Needed because a
;;; criterion is declared once per level and the axis is one thing.
define lp_place_seen(axes, a) -> yes;
    lvars axes, a, x, yes = false;
    for x in axes do
        if x(1) = a(1) then true -> yes; return endif;
    endfor;
enddefine;

;;; The items at one level that probe one axis, and that can be asked.
;;; An axis with nothing askable at a level is not searched there, which
;;; is how the empty rungs and the unprobeable roll-ups drop out.
define lp_place_items(axis, level) -> items;
    lvars axis, level, i, items = [], pool, sh, how = axis(2), arg = axis(3);
    if     how == "crit"  then lp_ask(arg, "criterion_items", 1) -> pool
    elseif how == "skill" then lp_edges_of(arg) -> pool
    else                       lp_items -> pool
    endif;
    for i in pool do
        nextunless(lp_ilang(i) == lp_lang and lp_ilevel(i) == level);
        if how == "kind" then
            nextunless(lp_kind(i) == hd(arg));
            nextunless(not(hd(tl(arg))) or lp_form_of(i, hd(tl(arg))));
        endif;
        lp_question(i, lp_primary(i)) -> (sh, , , );
        nextif(sh == "none");
        items <> [^i] -> items;
    endfor;
enddefine;

;;; n items spread across the difficulty of the set, which is the whole
;;; reason rank/3 was imported: probing 103 kanji one at a time to find
;;; out whether somebody reads kanji is absurd, and four spread along a
;;; frequency rank locate them.
;;;
;;; Where there is no scale, confusable items come first -- a katakana
;;; test made of ア and ヲ certifies everybody, while シ against ツ and ソ
;;; against ン is where forgetting actually shows.  Only then does it
;;; fall back to an even spread of whatever order the graph gave.
define lp_place_sample(items, n) -> sample;
    lvars items, n, sample = [], ranked = [], ordered, i, stride, k, len;
    returnif(items == []) ([] -> sample);

    for i in items do
        if lp_rank_of(i, "freq") then ranked <> [^i] -> ranked endif;
    endfor;

    if length(ranked) >= n then
        ;;; A real difficulty scale: sort by it and take an EVEN SPREAD,
        ;;; which is what locates somebody in four questions rather than
        ;;; a hundred.  Taking the first four would only ever ask about
        ;;; the four commonest characters.
        syssort(ranked, false, procedure(a, b); lvars a, b;
            lp_rank_of(a, "freq") < lp_rank_of(b, "freq") endprocedure)
            -> ordered;
        length(ordered) -> len;
        returnif(len <= n) (ordered -> sample);
        max(1, len div n) -> stride;
        [% for k from 1 by stride to len do ordered(k) endfor %] -> sample;
    else
        ;;; No scale: put the confusable ones first and take them from
        ;;; the FRONT, because that ordering already is the difficulty
        ;;; ordering.  Spreading across it with a stride would reach
        ;;; past them into the easy tail -- and a katakana test made of
        ;;; ア and ヲ certifies everybody, while シ against ツ and ソ
        ;;; against ン is where forgetting actually shows.
        [% for i in items do if lp_confs(i) /== [] then i endif endfor;
           for i in items do if lp_confs(i) == [] then i endif endfor %]
            -> ordered;
        ordered -> sample;
    endif;
    [% for k from 1 to min(n, length(sample)) do sample(k) endfor %] -> sample;
enddefine;

;;; How an axis stands at a level, from the evidence already recorded.
;;; No state: this is read back out of the journal every time.
define lp_place_state(axis, level) -> (state, acc, n, frozen);
    lvars axis, level, items = lp_place_items(axis, level), e, acc, fast, n,
          frozen = 0, state;
    "nothing" -> state; 0.0 -> acc; 0 -> n;
    returnif(items == []);
    lp_measure(items, 99999999) -> (acc, fast, n);
    for e in lp_journal do
        if e(3) == 1 and e(4) == "skip" and member(e(1), items) then
            frozen + 1 -> frozen
        endif;
    endfor;
    ;;; Settled once the sample is in -- OR once everything there is has
    ;;; been asked.  An axis with fewer probeable items than PLACE_SAMPLE
    ;;; would otherwise never settle, and a driver looping on
    ;;; lp_place_next would ask about it forever.  skill(mora_count) has
    ;;; exactly one askable item, so this is not hypothetical.
    if     frozen >= PLACE_FREEZE                     then "failed"
    elseif n < min(PLACE_SAMPLE, length(items))       then "untested"
    elseif n == 0                                     then "nothing"
    elseif acc >= PLACE_PASS                          then "passed"
    else                                                   "failed"
    endif -> state;
enddefine;

;;; The levels an axis can be searched at, highest first.
define lp_place_levels(axis) -> ls;
    lvars axis, l, ls = [];
    for l in lp_levels(lp_lang) do
        unless lp_place_items(axis, l) == [] then
            conspair(l, ls) -> ls              ;;; reversing as it goes
        endunless;
    endfor;
enddefine;

;;; What to ask next, or false when there is nothing left to settle.
;;;
;;; The descent, and it is the teacher's: start at the highest level the
;;; axis exists at.  Passed there -- nothing below needs asking, they are
;;; at least that good.  Failed or frozen -- drop one rung and ask again.
define lp_place_next() -> (axis, level, items);
    lvars axis, level, items, a, l, st, acc, n, frozen;
    (false, false, []) -> (axis, level, items);
    for a in lp_place_axes() do
        for l in lp_place_levels(a) do
            lp_place_state(a, l) -> (st, acc, n, frozen);
            ;;; Passed here: nothing below this rung needs asking, they
            ;;; are at least that good.  quitloop and not return -- this
            ;;; settles the AXIS, and the next one still has to be
            ;;; searched.  Returning here placed a student on the first
            ;;; axis they passed and never asked about anything else.
            quitif(st == "passed");
            if st == "untested" then
                ;;; Sampled from what has NOT been asked yet.  Sampling
                ;;; the whole set each time returns the same head every
                ;;; time, so a driver that asks one question and looks
                ;;; again asked ウ four times running.
                lvars pool = [% lvars i;
                                for i in lp_place_items(a, l) do
                                    if lp_asked(i) == 0 then i endif;
                                endfor %];
                quitif(pool == []);
                (a, l, lp_place_sample(pool, PLACE_SAMPLE - n))
                    -> (axis, level, items);
                return;
            endif;
            ;;; failed here: try the rung below
        endfor;
    endfor;
enddefine;

;;; Where the student has been placed, per axis.  The highest level each
;;; axis passed at, or below the ladder if it passed nowhere.
;;; Where the student has been placed, per axis: the highest level each
;;; one passed at.  `why` says why an axis has no placement, which is
;;; three different things and used to be reported as one --
;;;   "askable"  tested, and did not pass
;;;   "unasked"  there are questions for it, but it was not reached
;;;   "none"     there is nothing here that can be asked at all
define lp_place_report() -> rows;
    lvars rows = [], a, l, st, acc, n, frozen, placed, tested, any, why;
    for a in lp_place_axes() do
        false -> placed; false -> tested; false -> any;
        for l in lp_place_levels(a) do
            true -> any;
            lp_place_state(a, l) -> (st, acc, n, frozen);
            nextif(st == "nothing");
            unless st == "untested" then true -> tested endunless;
            if st == "passed" and not(placed) then l -> placed endif;
        endfor;
        if     placed      then "askable"
        elseif not(any)    then "none"
        elseif tested      then "askable"
        else                    "unasked"
        endif -> why;
        rows <> [[% a(1), placed, why %]] -> rows;
    endfor;
enddefine;


;;; Where teaching should START, derived rather than chosen: the lowest
;;; rung that still has an axis the student has not passed.
;;;
;;; This is why placement writes beliefs rather than a verdict.  The
;;; spiky learner above is put at pre-school to fix katakana, and the
;;; N5 kanji they proved they can read are already sitting near mastery
;;; in the overlay -- so lp_choose, which takes the lowest belief first,
;;; gives them their katakana immediately and skims the rest.
define lp_place_level() -> level;
    lvars level = false, a, l, st, acc, n, frozen;
    for l in lp_levels(lp_lang) do
        for a in lp_place_axes() do
            nextif(lp_place_items(a, l) == []);
            lp_place_state(a, l) -> (st, acc, n, frozen);
            if st /== "passed" then l -> level; return endif;
        endfor;
    endfor;
enddefine;

;;; How many questions a placement may take before it gives up.  A
;;; placement that outlasts the patience of the person taking it has
;;; failed whatever it concluded -- and the one thing a learner in this
;;; position has had plenty of is being tested.
lconstant PLACE_MAX = 40;

;;; What to tell the student about one axis.  Here rather than inside
;;; lp_place_show because the zine prints the same standing on paper,
;;; and two wordings of one verdict is one too many -- `askable` is what
;;; the report says and "below the ladder" is what it means.
define lp_place_says(r) -> s;
    lvars r, s;
    if     r(2)             then r(2) sys_>< ''
    elseif r(3) == "none"   then 'nothing here I can ask about'
    elseif r(3) == "unasked" then 'not asked about yet'
    else                         'below the ladder'
    endif -> s;
enddefine;

define lp_place_show();
    lvars r, rows = lp_place_report(), lv;
    printf('\n  Here is where I think you are.\n');
    for r in rows do
        printf('    %p: %p\n', [% r(1), lp_place_says(r) %]);
    endfor;
    lp_place_level() -> lv;
    if lv then
        lv -> lp_level;
        printf('\n  We will work at %p -- that is the lowest thing not yet\n', [^lv]);
        printf('  settled.  What you already showed me is remembered, so I\n');
        printf('  will not teach you those again.\n');
    else
        printf('\n  Nothing here is left to settle.\n');
    endif;
enddefine;

define lp_place_run();
    dlocal lp_allow_later = false;
    lvars ax, lv, its, asked = 0, last = false;
    printf('\n  Let me find out where you are rather than guess.  Say nothing\n');
    printf('  -- just press enter -- for anything you do not know; that is\n');
    printf('  worth more to me than a guess.\n');
    repeat
        lp_place_next() -> (ax, lv, its);
        quitunless(ax);
        quitif(its == []);
        ;;; ONE question, then look again.  Asking a whole sample before
        ;;; re-reading the state meant a student could freeze twice and
        ;;; still be asked the rest of the batch -- and stopping on the
        ;;; freeze is the entire point of having one.  The axis header is
        ;;; printed only when it changes, so the conversation still reads
        ;;; as sections rather than as forty separate questions.
        unless last = (ax(1) sys_>< '') <> '/' <> (lv sys_>< '') then
            printf('\n  -- %p, at %p\n', [% ax(1), lv %]);
            (ax(1) sys_>< '') <> '/' <> (lv sys_>< '') -> last;
        endunless;
        quitunless(lp_drill(hd(its), lp_primary(hd(its))));
        asked + 1 -> asked;
        quitif(asked >= PLACE_MAX);
    endrepeat;
    printf('\n  %p questions.\n', [^asked]);
    lp_place_show();
enddefine;

;;; ---------------------------------------------------------- coverage
;;; What fraction of running text a student can read.
;;;
;;; Nation's measure, and the thing three English rungs were held closed
;;; by: coverage(reading, 0.95) means "the words you know account for
;;; 95% of the words on the page".  It was `unmeasured` for as long as
;;; the graph had no frequency data, and inventing a number to fill the
;;; gap would have produced one that looked like the others and was not.
;;;
;;; Now it is arithmetic.  Sum what the mastered words account for,
;;; divide by what the corpus accounts for.  No model, no interpolation,
;;; no published table -- the definition applied to the data.
;;;
;;; The DENOMINATOR is the whole corpus and not the words we happen to
;;; teach.  Dividing by our own vocabulary would give a figure that only
;;; ever goes up and would read as progress rather than as coverage.
vars lp_freqs = newproperty([], 512, 0, "perm"),
     lp_fscale = newproperty([], 512, false, "perm"),
     lp_corpora = newproperty([], 8, false, "perm"),
     lp_freqs_ready = false;

define lp_build_freqs();
    lvars t;
    returnif(lp_freqs_ready);
    true -> lp_freqs_ready;
    clearproperty(lp_freqs); clearproperty(lp_fscale);
    clearproperty(lp_corpora);
    for t in lp_ask("freqs", 0) do
        lvars id = prolog_deref(prolog_arg(1, t));
        prolog_deref(prolog_arg(2, t)) -> lp_fscale(id);
        prolog_full_deref(prolog_arg(3, t)) -> lp_freqs(id);
    endfor;
    for t in lp_ask("corpora", 0) do
        prolog_full_deref(prolog_arg(3, t))
            -> lp_corpora(prolog_deref(prolog_arg(1, t)));
    endfor;
enddefine;

;;; How many words in this language carry a frequency at all.  Separate
;;; from the coverage sum because a listening criterion filters every
;;; item out -- nothing is probeable on `hear` -- and reporting `0 words
;;; in the graph` beside `needs audio` would say the data was missing
;;; when it is the microphone that is.
define lp_freq_count() -> n;
    lvars i, n = 0;
    lp_build_freqs();
    for i in lp_items do
        if lp_ilang(i) == lp_lang and lp_freqs(i) > 0 then n + 1 -> n endif;
    endfor;
enddefine;

;;; The axis a coverage criterion names, as a channel.  `reading` is the
;;; read channel and `listening` the hear one, which is the whole reason
;;; the ladder carries two of them.
define lp_cov_channel(axis) -> ch;
    lvars axis, ch = if axis == "listening" then "hear" else "read" endif;
enddefine;

;;; `every` is the audit's question -- how far could a student get with
;;; the content that exists -- and `mastered` is the student's.  One
;;; procedure, because the difference between the two is one test and
;;; keeping them apart is how they drift.
define lp_coverage(ch, every) -> (frac, nwords, scale);
    lvars ch, every, i, sum = 0, n = 0, tot, scale = false;
    lp_build_freqs();
    (0.0, 0, false) -> (frac, nwords, scale);
    for i in lp_items do
        nextunless(lp_ilang(i) == lp_lang);
        nextunless(lp_freqs(i) > 0);
        lp_fscale(i) -> scale;
        if every then
            nextunless(lp_probeable(i, ch))
        else
            nextunless(lp_mastered_on(i, ch))
        endif;
        sum + lp_freqs(i) -> sum;
        n + 1 -> n;
    endfor;
    returnunless(scale);
    lp_corpora(scale) -> tot;
    unless tot and tot > 0 then false -> scale; return endunless;
    ((sum * 1.0) / tot, n, scale) -> (frac, nwords, scale);
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

;;; One criterion, measured, as {criterion-text, what-it-says}.
;;;
;;; Pulled out of lp_status because the zine prints the same thing on
;;; paper, and two renderings of a number is one too many: the sheet
;;; would quietly drift from the screen and nobody would notice which
;;; was right.  lp_status prints these; so does the booklet.
;;; One criterion, measured, as NUMBERS and not as a sentence:
;;;
;;;     {criterion-text, kind, a, b, c, d}
;;;
;;;   counted   a of b mastered, c in the graph
;;;   audio     c in the graph, and nothing here can check them
;;;   unbuilt   nothing measures it
;;;   measured  a% right, b% within c ms, over d answers
;;;
;;; The sentence used to be built here, which was fine until a second
;;; thing wanted to print it: the study booklet, whose reader may not
;;; read English.  Formatting it twice would be two renderings of one
;;; measurement -- paper drifting from screen -- so the NUMBERS are the
;;; shared thing and each caller words them.
define lp_status_rows() -> rows;
    lvars e, c, th, ms, items, acc, fast, n, want, ch, rows = [], row;
    for e in lp_exits do
        nextunless(hd(e) == lp_lang and hd(tl(e)) == lp_level);
        hd(tl(tl(e))) -> c; hd(tl(tl(tl(e)))) -> th; hd(tl(tl(tl(tl(e))))) -> ms;
        if prolog_complexterm(c) and prolog_functor(c) == "vocabulary" then
            prolog_full_deref(prolog_arg(1, c)) -> want;
            prolog_deref(prolog_arg(2, c)) -> ch;
            if lp_verifiable(ch) then
                {% "counted", lp_count_mastered("word", ch), want,
                   lp_count_items("word"), "word" %}
            else
                ;;; Said rather than scored.  Reporting 0 of 800 would
                ;;; read as a student who has learned nothing, when what
                ;;; is true is that nothing here can measure it.
                {% "audio", 0, want, lp_count_items("word"), "word" %}
            endif -> row;
        elseif prolog_complexterm(c) and prolog_functor(c) == "kanji" then
            prolog_full_deref(prolog_arg(1, c)) -> want;
            prolog_deref(prolog_arg(2, c)) -> ch;
            {% "counted", lp_count_mastered_kanji(ch), want,
               lp_count_items("kanji"), "kanji" %} -> row;
        elseif prolog_complexterm(c) and prolog_functor(c) == "coverage" then
            lvars axis = prolog_deref(prolog_arg(1, c)), frac, nw, scale;
            prolog_full_deref(prolog_arg(2, c)) -> want;
            lp_coverage(lp_cov_channel(axis), false) -> (frac, nw, scale);
            if scale then
                {% "covered", round(frac * 100), round(want * 100),
                   lp_freq_count(), scale %}
            else
                {% "unbuilt", 0, 0, 0, false %}
            endif -> row;
        else
            lp_ask(c, "criterion_items", 1) -> items;
            lp_measure(items, ms) -> (acc, fast, n);
            {% "measured", round(acc * 100), round(fast * 100), ms, n,
               round(th * 100) %} -> row;
        endif;
        rows <> [{% lp_term_str(c), row(1), row(2), row(3), row(4), row(5),
                    if length(row) > 5 then row(6) else false endif %}]
            -> rows;
    endfor;
enddefine;

;;; The English wording, which is what the TUI prints.  The booklet has
;;; its own, in the language its reader can read.
define lp_status_text(r) -> txt;
    lvars r, txt;
    if     r(2) == "counted" then
        sprintf('%p of %p %ps mastered (%p in the graph)',
                [% r(3), r(4), r(6), r(5) %])
    elseif r(2) == "audio" then
        sprintf('cannot be checked here -- needs audio (%p in the graph)',
                [% r(5) %])
    elseif r(2) == "covered" then
        sprintf('%p%% of running text, over %p words (%p, need %p%%)',
                [% r(3), r(5), r(6), r(4) %])
    elseif r(2) == "unbuilt" then
        'needs the content build (not measured yet)'
    else
        sprintf('%p%% right, %p%% within %pms, over %p answers (need %p)',
                [% r(3), r(4), r(5), r(6), r(7) %])
    endif -> txt;
enddefine;

define lp_status();
    lvars r;
    printf('\n  %p, %p -- level %p\n',
           [% lp_display or (lp_user sys_>< ''), lp_lang, lp_level %]);
    for r in lp_status_rows() do
        printf('    %p: %p\n', [% r(1), lp_status_text(r) %]);
    endfor;
    printf('    %p items ready to teach now\n', [% length(lp_plan()) %]);
    ;;; What was helping, if anything was not.  A number read without
    ;;; this is a number of unknown strictness, which is the whole
    ;;; argument for letting the aids be switched off at all.
    lvars off = [% lvars a; for a in lp_aid_names() do
                       unless lp_aid(a) then a endunless endfor %];
    if off /== [] then
        printf('    switched off by choice: %p\n', [^off]);
    endif;
    if lp_later_n > 0 or lp_pending /== [] then
        printf('    %p put off this session, %p still to come round again\n',
               [% lp_later_n, length(lp_pending) %]);
    endif;
enddefine;


;;; ------------------------------------------------------------- the audit
;;; Can this criterion be met at all, with the content the graph actually
;;; holds?
;;;
;;; --check answers a different question: it proves the graph is
;;; internally consistent -- no cycle, no dangling prerequisite, every
;;; item on a rung that exists.  A ladder can pass that and still be
;;; unclimbable, because consistency says nothing about whether there is
;;; enough to learn.  `exit(ja, n1, kanji(2230, read), ...)` is perfectly
;;; consistent against 103 kanji; it is simply unreachable, and nothing
;;; said so.
;;;
;;; This is the same move imp_verify makes for the importer: read back
;;; what is there and compare it against what was claimed, rather than
;;; trusting that writing it worked.  A rung with no door was found by
;;; hand once already (en/a1 had no exit criterion at all).  Found by
;;; hand means found by luck.
;;;
;;; Four verdicts, and they mean different things to whoever reads them:
;;;
;;;   ok           enough askable content exists to satisfy it
;;;   thin         measurable, and over so few items that passing it
;;;                says very little -- the Goodhart case, stated
;;;   short        measurable, but there is not enough content yet
;;;                -- a curation number, not a bug
;;;   no probe     the item set exists and nothing in it can be asked
;;;                -- a bug, or an unbuilt import
;;;   needs audio  the channel is outside VERIFIABLE
;;;                -- a limit of this build, recorded in
;;;                docs/projects/langpop-pronunciation.md
;;;   unmeasured   nothing measures this criterion at all
;;;                -- the honest verdict for coverage/2
;;;
;;; Only `short` is allowed to be large.  The others are each a claim the
;;; ladder makes and cannot cash.

;;; Fewer askable items than this and a percentage over them is not a
;;; measurement, it is an anecdote.  Three is the smallest number that
;;; can disagree with itself.
lconstant AUDIT_THIN = 3;

define lp_pad(x, n) -> s;
    lvars x, n, s = x sys_>< '';
    until length(s) >= n do s <> ' ' -> s enduntil;
enddefine;

;;; Is there a probe for this item on this channel?
;;;
;;; lp_question/1 takes no channel: it asks about the item on its GATE
;;; channel and lp_drill records there, so a word's `hear` belief can
;;; only ever be moved by an assignment.  That is why the channel has to
;;; match lp_primary and not merely be one of lp_channels -- the first
;;; version of this reported vocabulary(50, hear) as askable, which is
;;; exactly the comfortable answer channels were introduced to stop.
;;; UPDATED when the listening question arrived.  The comment above was
;;; right about the old code and is now the history: lp_question takes a
;;; channel, so `hear` is askable on a word when a voice is installed and
;;; the sound is cached -- and lp_drillable_on answers exactly that,
;;; which is why this no longer needs to know anything about channels
;;; beyond asking.
define lp_probeable(item, ch) -> yes;
    lvars item, ch, yes = false;
    returnunless(lp_verifiable(ch));
    returnunless(member(ch, lp_channels(item)));
    lp_drillable_on(item, ch) -> yes;
enddefine;

;;; How many DIFFERENT questions this item can be asked.  One, for
;;; anything with a written form; for a skill whose probe is generated,
;;; as many as there is material in the graph.
define lp_probe_breadth(item) -> n;
    lvars item, n = 1;
    if lp_kind(item) == "skill" and lp_probe_of(item) then
        length(lp_probe_material(item)) -> n;
    elseif lp_kind(item) == "sound" and lp_pairs_of(item) /== [] then
        ;;; One question per confusion pair, which is why four pairs were
        ;;; written for most contrasts: AUDIT_THIN is three.
        length(lp_pairs_of(item)) -> n;
    endif;
enddefine;

;;; Items of a countable kind at this level or below, in this language.
;;; Cumulative, because the criteria are: kanji(2230) at N1 means every
;;; kanji through N1 and not 2230 more of them.
define lp_audit_pool(kind, level) -> items;
    lvars kind, level, i, top = lp_level_index(level), items = [];
    for i in lp_items do
        nextunless(lp_ilang(i) == lp_lang);
        nextunless(lp_level_index(lp_ilevel(i)) >= 0
                   and lp_level_index(lp_ilevel(i)) <= top);
        if (if kind == "kanji" then
                lp_kind(i) == "grapheme" and lp_form_of(i, "kanji")
            else lp_kind(i) == kind endif) then
            conspair(i, items) -> items
        endif;
    endfor;
enddefine;

;;; One criterion: {verdict have askable want}.  `want` is false for a
;;; criterion that is not a count, where the question is whether the set
;;; can be asked at all rather than whether there is enough of it.
;;; `silent` is how many items of an ITEM-SET criterion cannot be asked
;;; about at all.  It exists because the breadth change cost the reader
;;; something: askable counts distinct QUESTIONS, so `12 29` for
;;; sound_contrasts looks like full coverage when four of the twelve
;;; contrasts have no confusion pair and no question.  The verdict is
;;; unchanged and deliberately so -- accuracy is measured over the
;;; answers given, which is the argument in the branch below -- but a
;;; criterion measured over part of its set now says which part.
define lp_audit_one(crit, level) -> (verdict, have, askable, want, silent);
    lvars crit, level, f, i, pool, items, ch, n = 0;
    false -> want; 0 -> silent;
    if prolog_complexterm(crit) then prolog_functor(crit) else crit endif -> f;
    if f == "vocabulary" or f == "kanji" then
        prolog_full_deref(prolog_arg(1, crit)) -> want;
        prolog_deref(prolog_arg(2, crit)) -> ch;
        lp_audit_pool(if f == "kanji" then "kanji" else "word" endif,
                      level) -> pool;
        length(pool) -> have;
        for i in pool do if lp_probeable(i, ch) then n + 1 -> n endif endfor;
        n -> askable;
        if not(lp_verifiable(ch)) then "needs_audio"
        elseif askable >= want then "ok"
        else "short"
        endif -> verdict;
    elseif f == "coverage" then
        ;;; Coverage is measured in PERCENTAGE POINTS, not items: `have`
        ;;; is how many words carry a frequency and `askable` is how far
        ;;; a student could get with all of them, so `short by 89` reads
        ;;; as points of coverage.  A second set of columns for one
        ;;; criterion family would be worse.
        lvars axis = prolog_deref(prolog_arg(1, crit)), frac, nw, scale, ch;
        prolog_full_deref(prolog_arg(2, crit)) -> want;
        round(want * 100) -> want;
        lp_cov_channel(axis) -> ch;
        lp_coverage(ch, true) -> (frac, nw, scale);
        lp_freq_count() -> have;
        round(frac * 100) -> askable;
        if     not(scale)             then "unmeasured"
        elseif not(lp_verifiable(ch)) then 0 -> askable; "needs_audio"
        elseif askable >= want        then "ok"
        else                               "short"
        endif -> verdict;
    else
        ;;; An item-set criterion: recognise/1, skill/1.  Accuracy is
        ;;; measured over the answers given, so an item nobody can be
        ;;; asked about does not cap the percentage -- it quietly leaves
        ;;; the measurement, which is worse.  Both numbers are reported
        ;;; so that a criterion measured over part of its set says so.
        lp_ask(crit, "criterion_items", 1) -> items;
        length(items) -> have;
        lvars audible = 0;
        for i in items do
            unless lp_probeable(i, lp_primary(i)) then
                silent + 1 -> silent;
            endunless;
            if lp_probeable(i, lp_primary(i)) then
                ;;; DISTINCT QUESTIONS, not items.  A skill with a
                ;;; generated probe is one item that can be asked about
                ;;; forty words, and counting it as one would call the
                ;;; criterion thin when it is not.  The reverse matters
                ;;; more: when the material runs to a single word, the
                ;;; criterion IS thin, and nothing else would say so --
                ;;; skill(mora_sokuon) has exactly one pre-school word
                ;;; with a small っ in it.
                n + lp_probe_breadth(i) -> n
            elseunless lp_verifiable(lp_primary(i)) then
                audible + 1 -> audible
            endif;
        endfor;
        n -> askable;
        ;;; Nothing askable, and every item of the set sits on a channel
        ;;; this build cannot check: that is the audio limit and not a
        ;;; missing probe.  sound_contrasts was reported as a bug the
        ;;; first time this ran, which is wrong -- the probe is not
        ;;; missing, the microphone is.
        if     have == 0                     then "unmeasured"
        elseif askable == 0 and audible == have then "needs_audio"
        elseif askable == 0                  then "no_probe"
        elseif askable < AUDIT_THIN          then "thin"
        else                                      "ok"
        endif -> verdict;
    endif;
enddefine;

;;; Every criterion on every rung of every ladder.  Deliberately not
;;; restricted to the current language or level: a ladder is hollow in
;;; places nobody is standing, and those are the places that need
;;; curating.
define lp_audit() -> rows;
    lvars e, rows = [], lang, level, crit, verdict, have, askable, want;
    dlocal lp_lang, lp_level;
    for e in lp_exits do
        hd(e) -> lang; hd(tl(e)) -> level; hd(tl(tl(e))) -> crit;
        lang -> lp_lang; level -> lp_level;
        lvars silent;
        lp_audit_one(crit, level) -> (verdict, have, askable, want, silent);
        rows <> [{% lang, level, crit, verdict, have, askable, want, silent %}]
            -> rows;
    endfor;
enddefine;

;;; ------------------------------------------------------- the rungs
;;; A criterion at a time is not enough.  --audit walks lp_exits, so a
;;; rung that declares NO criterion produces no rows and is invisible in
;;; the report -- which is how en/a1 came to be a room with no door and
;;; had to be found by hand, and how en/c1 still is.
;;;
;;; A rung is left by meeting EVERY criterion on it, so it is exitable
;;; only if every one of them is reachable.  One criterion that nothing
;;; can measure closes the rung as surely as having none.
;;;
;;; The verdict names the WORST blocker, in the order of whose problem
;;; it is: a rung with no exit is a bug in the ladder, an unmeasured
;;; criterion is a hole in the design, short is curation, and needs
;;; audio is a limit of this build that is written down elsewhere.
define lp_audit_rungs() -> rows;
    lvars l, r, rows = [], lang, level, n, verdict, seen;
    for l in lp_ladders do
        hd(l) -> lang; hd(tl(tl(l))) -> level;
        [] -> seen; 0 -> n;
        for r in lp_audit() do
            nextunless(r(1) == lang and r(2) == level);
            n + 1 -> n;
            unless member(r(4), seen) then seen <> [% r(4) %] -> seen endunless;
        endfor;
        if     n == 0                        then "no_exit"
        elseif member("no_probe", seen)      then "no_probe"
        elseif member("unmeasured", seen)    then "unmeasured"
        elseif member("short", seen)         then "short"
        elseif member("needs_audio", seen)   then "needs_audio"
        elseif member("thin", seen)          then "thin"
        else                                      "ok"
        endif -> verdict;
        rows <> [{% lang, level, n, verdict %}] -> rows;
    endfor;
enddefine;

define lp_audit_rungs_show();
    lvars r, rows = lp_audit_rungs(), bad = 0;
    printf('\n  %p%p%p%p\n',
           [% lp_pad('lang', 6), lp_pad('level', 11),
              lp_pad('criteria', 10), 'can it be left?' %]);
    for r in rows do
        unless r(4) == "ok" then bad + 1 -> bad endunless;
        printf('  %p%p%p%p\n',
               [% lp_pad(r(1), 6), lp_pad(r(2), 11), lp_pad(r(3), 10),
                  if r(4) == "ok" then 'yes'
                  elseif r(4) == "no_exit" then 'NO -- it declares no exit criterion'
                  else 'not yet -- ' <> (r(4) sys_>< '') endif %]);
    endfor;
    printf('\n  %p of %p rungs can be left as the graph stands.\n',
           [% length(rows) - bad, length(rows) %]);
enddefine;

define lp_audit_show();
    lvars r, rows = lp_audit(), v, tot = newproperty([], 8, 0, "perm"), k;
    printf('\n  %p exit criteria over %p ladder levels.\n',
           [% length(rows), length(lp_ladders) %]);
    printf('\n  %p%p%p%p%p%p\n',
           [% lp_pad('lang', 6), lp_pad('level', 11),
              lp_pad('criterion', 26), lp_pad('have', 6),
              lp_pad('askable', 9), 'verdict' %]);
    for r in rows do
        r(4) -> v;
        tot(v) + 1 -> tot(v);
        printf('  %p%p%p%p%p%p%p\n',
               [% lp_pad(r(1), 6), lp_pad(r(2), 11),
                  lp_pad(lp_term_str(r(3)), 26), lp_pad(r(5), 6),
                  lp_pad(r(6), 9), v,
                  if v == "short" then ' by ' <> ((r(7) - r(6)) sys_>< '')
                  elseif r(8) > 0 then
                      ;;; Not a different verdict: the same one, with the
                      ;;; part of the set it does not reach.
                      ' -- ' <> (r(8) sys_>< '') <> ' of ' <> (r(5) sys_>< '')
                      <> ' cannot be asked'
                  else '' endif %]);
    endfor;
    printf('\n');
    for k in [ok thin short no_probe needs_audio unmeasured] do
        if tot(k) > 0 then printf('  %p %p\n', [% tot(k), k %]) endif;
    endfor;
    ;;; Said plainly, because the three are not the same problem and a
    ;;; single "N failing" would hide which of them anyone can fix.
    lp_audit_rungs_show();
    printf('\n  thin        = passes on fewer than %p askable items\n', [^AUDIT_THIN]);
    printf('  short       = curation: the criterion works, the content is thin\n');
    printf('  no probe    = a criterion nothing can ask about -- a bug, or an unbuilt import\n');
    printf('  needs audio = outside VERIFIABLE; see docs/projects/langpop-pronunciation.md\n');
    printf('  unmeasured  = nothing measures it at all\n');
    printf('  "N of M cannot be asked" = an item-set criterion whose accuracy\n');
    printf('                is measured over part of its set -- see lp_audit_one\n');
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

;;; ----------------------------------------------------------------- audio
;;; The speak channel, which is the one thing in langpop that wants a
;;; microphone.  Deliberately NOT wired into lp_next: no criterion on any
;;; rung asks a student to produce a sound, so a tutor that started
;;; demanding it would be grading something the ladder never promised.
;;; `:speak <item>` is the capability; whether the ladder should declare
;;; production criteria is a curation question, and an open one.
;;;
;;; A separate drill rather than an arm of lp_drill, because there is no
;;; typed answer: the student presses enter, the recorder runs, the
;;; scorer answers, and none of lp_drill's machinery -- the slip
;;; tolerance, the confusable diagnosis, the answer list -- has anything
;;; to do.  Bending one into the other would have cost both.
;;; A VERDICT YOU CANNOT ATTRIBUTE TO THE RECORDING IS USELESS.  `wrong`
;;; from a microphone that was not plugged in, or from a room with a fan
;;; in it, is indistinguishable from `wrong` from a learner who dropped
;;; the beat -- unless somebody looks at the signal.  So :mic records
;;; two seconds and shows what the scorer would see: the level, the
;;; floor, the voiced span, and the silences inside it.
;;;
;;; Say anything at all into it.  The point is not the word; it is
;;; whether the microphone is working and whether the room is quiet
;;; enough for a held beat -- which is silence -- to survive.
define lp_mic_check();
    lvars sample, swhy, line;
    lp_load_audio();
    unless lp_recorder() then
        printf('  I have no recorder.  It is a command named in %p --\n',
               [% lp_audio_conf_path() %]);
        printf('  see the header of examples/langpop/audio.p.\n');
        return;
    endunless;
    printf('\n  Say anything -- a word, a count to three.  I will show you\n');
    printf('  the level and the silences the scorer would see.\n');
    printf('  (enter to record)  -> ');
    sysflush(popdevout);
    lp_readline() -> line;
    returnif(line == termin);
    lp_audio_capture("mic") -> (sample, swhy);
    if swhy then
        printf('  The recorder wrote nothing (%p).  Check the command in\n',
               [^swhy]);
        printf('  %p, and that the terminal has microphone permission.\n',
               [% lp_audio_conf_path() %]);
        return;
    endif;
    printf('\n');
    unless lp_mic_meter(sample) then
        printf('  I could not run the meter.  The recording is at %p\n',
               [^sample]);
        return;
    endunless;
    ;;; Same rule as a scored sample: it goes.
    if sys_file_exists(sample) then sysdelete(sample) endif;
enddefine;

define lp_speak_drill(item) -> done;
    lvars item, done = false, text, why, sample, swhy,
          outcome, confidence, detail, t0, line, expect;
    lp_load_audio();
    unless lp_kind(item) then
        printf('  I have no item called %p.\n', [^item]); return;
    endunless;
    unless member("speak", lp_channels(item)) then
        printf('  %p is not something to say.\n', [^item]); return;
    endunless;
    lp_audio_text(item) -> (text, why);
    if why then
        printf('  There is nothing to say for %p (%p).\n', [% item, why %]);
        return;
    endif;
    unless lp_can_speak() then
        printf('  I have no microphone or no scorer.  Both are commands\n');
        printf('  named in %p -- see the header of\n',
               [% lp_audio_conf_path() %]);
        printf('  examples/langpop/audio.p for the shape.\n');
        return;
    endunless;
    ;;; The one question this build can score is the held beat, so it is
    ;;; the one it asks.  An item with no geminate, or one whose geminate
    ;;; is a lengthened fricative, is declined HERE rather than recorded
    ;;; and then abstained on -- a student should not be asked to say
    ;;; something nobody can mark.
    unless lp_sokuon_detectable(item) then
        ;;; Two different refusals, because they are two different facts.
        ;;; ねこ has no held beat to time; いっしょ has one and it is not a
        ;;; silence.  One message for both told the student about し when
        ;;; there was no っ in the word at all.
        if issubstring('っ', text) or issubstring('ッ', text) then
            printf('  %p holds a fricative rather than a silence -- っ\n',
                   [% lp_any_form(item) %]);
            printf('  before し is a long し, so there is no gap to time.\n');
        else
            printf('  %p has no held beat in it.  The only thing I can mark\n',
                   [% lp_any_form(item) %]);
            printf('  by ear so far is っ before か, た or ぱ.\n');
        endif;
        return;
    endunless;
    lp_morae(text) -> expect;

    printf('\n  Say it: %p\n', [^text]);
    printf('  (enter to record, and hold the small っ)  -> ');
    sysflush(popdevout);
    lp_readline() -> line;
    returnif(line == termin);
    lp_now_ms() -> t0;
    lp_audio_capture(item) -> (sample, swhy);
    if swhy then
        printf('  The recorder wrote nothing (%p), so there is nothing to\n',
               [^swhy]);
        printf('  mark -- and I have recorded nothing.\n');
        return;
    endif;
    lp_pronounced(item, sample, "sokuon", expect)
        -> (outcome, confidence, detail, why);
    if why then
        if sys_file_exists(sample) then sysdelete(sample) endif;
        printf('  I could not get a verdict (%p).  Nothing recorded.\n',
               [^why]);
        return;
    endif;
    printf('  %p\n', [% detail or (outcome sys_>< '') %]);
    ;;; Anything but a clean `right` and the signal is worth seeing: it
    ;;; is the only way to tell a learner who dropped the beat from a
    ;;; room that buried it.
    unless outcome == "right" then
        printf('\n');
        lp_mic_meter(sample).erase;
    endunless;
    ;;; `near` is the scorer saying it could not tell, and tier 5 moves
    ;;; the belief in neither direction for it -- but it is still
    ;;; recorded, because "I asked and could not tell" is a fact about
    ;;; the session, and the journal is what the sheet reads.
    lp_record(item, "speak", 5, outcome, lp_now_ms() - t0);
    printf('  (machine verdict, confidence %p -- capped at %p, because a\n',
           [% confidence, MACHINE_CAP %]);
    printf('   confident model is still a model)\n');
    ;;; The sample goes, whatever happened.  See lp_sample_path.
    if sys_file_exists(sample) then sysdelete(sample) endif;
    true -> done;
enddefine;

;;; audio.p on the same terms as card.p: loaded on demand, absent without
;;; consequence.  A tutor whose Japanese voice is not installed asks the
;;; same questions it asked yesterday.
vars lp_audio_loaded = false;

;;; The rate the student asked for, held HERE and not in audio.p, because
;;; audio.p is loaded on demand and its `vars lp_rate = RATE_DEFAULT`
;;; runs at that moment -- so a choice made before the first :say (by
;;; --rate, or by a profile read at login) would be overwritten by the
;;; load that was supposed to honour it.
vars lp_rate_want = false;

define lp_load_audio();
    unless lp_audio_loaded then
        pop11_compile(langpop_dir <> 'audio.p');
        true -> lp_audio_loaded;
        if lp_rate_want then lp_rate_want -> lp_rate endif;
    endunless;
enddefine;

;;; :say DOES synthesise, where a question never would.  The rule is
;;; about not making a student wait mid-question; here the student asked
;;; for the sound and is waiting on purpose.
define lp_show_say(i, rate);
    lvars i, rate, path, made, why;
    lp_load_audio();
    unless lp_kind(i) then
        printf('  I have no item called %p.\n', [^i]); return;
    endunless;
    unless lp_audio_ready(lp_ilang(i)) then
        printf('  I have no %p voice.  Name one in %p -- the shape is in\n',
               [% lp_ilang(i), lp_audio_conf_path() %]);
        printf('  the header of examples/langpop/audio.p.\n');
        return;
    endunless;
    unless rate == false or member(rate, lp_audio_rates(lp_ilang(i))) then
        printf('  This voice has no %p rate.  It has: %p\n',
               [% rate, lp_audio_rates(lp_ilang(i)) %]);
        return;
    endunless;
    lp_audio_make(i, rate) -> (path, made, why);
    if why = 'no_spoken_form' then
        printf('  %p is a skill, not a sound -- there is nothing to say.\n',
               [^i]);
    elseif why = 'has_blank' then
        printf('  %p is a pattern with a blank in it; I would be reading\n',
               [^i]);
        printf('  the gap aloud.\n');
    elseif why = 'voice_failed' then
        printf('  The voice ran and wrote nothing.  Check the command in %p.\n',
               [% lp_audio_conf_path() %]);
    elseif why then
        printf('  I cannot say that: %p\n', [^why]);
    else
        printf('  %p  (%p%p)\n',
               [% path, lp_audio_rate_of(rate),
                  if made then '' else ', cached' endif %]);
        ;;; A slowed voice is good for finding the segments and wrong for
        ;;; learning the rhythm -- see the note in audio.p.  Said once,
        ;;; where the student can act on it, and not as a refusal.
        if lp_audio_rate_of(rate) /== "normal" and lp_audio_timing(i) then
            printf('  Length is contrastive in this one.  Hear its RHYTHM\n');
            printf('  at normal rate -- a slowed voice stretches the beats\n');
            printf('  and not always evenly.\n');
        endif;
        unless lp_audio_play(path) then
            printf('  No player here; the file is on disk.\n');
        endunless;
    endif;
enddefine;

;;; The rate the student listens at, which sticks: a beginner who has
;;; asked for slow should not have to ask again tomorrow.
define lp_show_rate(arg);
    lvars arg, r;
    lp_load_audio();
    unless lp_audio_ready(lp_lang) then
        printf('  I have no %p voice, so there is no rate to set.\n',
               [% lp_lang %]);
        return;
    endunless;
    if arg = '' then
        printf('  Listening at %p.  This voice has: %p\n',
               [% lp_rate, lp_audio_rates(lp_lang) %]);
        return;
    endif;
    consword(arg) -> r;
    unless member(r, lp_audio_rates(lp_lang)) then
        printf('  This voice has no %p rate.  It has: %p\n',
               [% r, lp_audio_rates(lp_lang) %]);
        return;
    endunless;
    r -> lp_rate; r -> lp_rate_want;
    printf('  Listening at %p from now on.\n', [% lp_rate %]);
enddefine;

;;; ------------------------------------------------------------- the session
define lp_help();
    printf('\n  <enter>          the next thing to learn\n');
    printf('  :plan            what is ready now, and why that order\n');
    printf('  :why <item>      the derivation: prerequisites, source, belief\n');
    printf('  :status          the exit criteria of this level, measured\n');
    printf('  :place           find out where you are, instead of guessing\n');
    printf('  :oops            that answer was an accident -- ask me again later\n');
    printf('  :aids            which helps are on (slip, oops, later)\n');
    printf('  :card <item>     draw it, and open it in the system viewer\n');
    printf('  :say <item>      hear it said, if a voice is installed\n');
    printf('  :rate slow       listen slower from now on (slow|normal|fast)\n');
    printf('  :mic             check the microphone level, and the room\n');
    printf('  :speak <item>    say it, and have the held beat timed\n');
    printf('  :sheet           today\'s work, as a page to print\n');
    printf('  :zine            the study plan, as a booklet to fold\n');
    printf('  :chart <script>  hiragana, katakana or youon, on one page\n');
    printf('  :assign          something to do away from the keyboard\n');
    printf('  :report <n> ok   done it (compliance)\n');
    printf('  :report <n> 17/20  done it, with a result\n');
    printf('  :level <name>    move the goal\n');
    printf('  :quit            save and stop\n');
    printf('\n  At a question: enter means "I do not know", which is an answer.\n');
    printf('  Typing "later" puts the question off until later today instead.\n');
    printf('  At a listening question, "again" plays it once more, for free.\n');
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

;;; ------------------------------------------------- the listening pool
;;; WHY THIS IS NOT lp_plan().  ready/4 excludes anything already known,
;;; and `known` reads the gate channel -- so the moment a word is
;;; mastered on READ it leaves the plan, and a listening question over
;;; the plan could never reach it.  vocabulary(50, hear) is measured over
;;; the same fifty words as vocabulary(50, read), so the pool has to be
;;; the words the student has already read-mastered.
;;;
;;; Which is also the right teaching order, and not merely the
;;; convenient one: recognising a word by ear that you cannot read is a
;;; harder and different task, and langpop has no criterion that asks
;;; for it.  Hearing comes after reading, on the same item.
define lp_hear_plan() -> items;
    lvars items = [], i, top = lp_level_index(lp_level);
    returnunless(lp_can_hear())(items);
    for i in lp_items do
        nextunless(lp_ilang(i) == lp_lang);
        nextunless(lp_level_index(lp_ilevel(i)) >= 0
                   and lp_level_index(lp_ilevel(i)) <= top);
        nextunless(member("hear", lp_channels(i)));
        nextunless(lp_mastered_on(i, "read"));
        nextif(lp_mastered_on(i, "hear"));
        nextif(lp_deferred(i));
        nextunless(lp_drillable_on(i, "hear"));
        items <> [^i] -> items;
    endfor;
enddefine;

;;; Weakest belief first, then least asked -- the same rule lp_choose
;;; uses, on the other channel.
define lp_choose_hear() -> best;
    lvars best = false, i, b, a, bb = false, ba = false;
    for i in lp_hear_plan() do
        lp_bel(i, "hear") -> b;
        lp_asked(i) -> a;
        if not(best) or b < bb or (b = bb and a < ba) then   ;;; `=`: see lp_choose
            i -> best; b -> bb; a -> ba;
        endif;
    endfor;
enddefine;

define lp_choose(plan) -> best;
    lvars plan, item, b, a, bb = false, ba = false;
    false -> best;
    for item in plan do
        nextunless(lp_drillable(item));
        nextif(lp_deferred(item));
        lp_bel(item, lp_primary(item)) -> b;
        lp_asked(item) -> a;
        ;;; `=` AND NOT `==`.  A belief is a float, and in Pop-11 `==` on
        ;;; floats is identity: two 0.0 LITERALS are not `==` each other,
        ;;; let alone two separately computed ones.  So `b == bb` was
        ;;; false for every pair of beliefs this has ever compared, the
        ;;; tie-break never fired once, and lp_choose returned the first
        ;;; item in plan order until it was mastered -- which is exactly
        ;;; what the comment above says it exists to prevent, and what it
        ;;; says makes a learner come to hate a flashcard.  Found by
        ;;; running a listening session and being asked ひと twice in a
        ;;; row with 49 untouched words in the pool.
        if not(best) or b < bb or (b = bb and a < ba) then
            item -> best; b -> bb; a -> ba;
        endif;
    endfor;
enddefine;

;;; One listening question in every HEAR_EVERY, when there is a pool for
;;; it.  A ratio rather than "listening once the reading is done",
;;; because a student with reading work left would otherwise never
;;; practise listening at all, and the criterion would only start moving
;;; at the very end of a level.
lconstant HEAR_EVERY = 4;

;;; lconstant is file-local, and server.p interleaves by the same rule.
define lp_hear_every() -> n;
    lvars n = HEAR_EVERY;
enddefine;

define lp_next();
    lvars item, due = lp_due(), plan, hitem;
    ;;; Anything put off, or taken back, comes before anything new.  It
    ;;; is owed: the student was told it would come back -- and on the
    ;;; channel it was put off on.
    if due then
        printf('  Back to this one.\n');
        lp_drill(due, lp_due_ch(due)).erase;
        return;
    endif;
    ;;; Every fourth question, by ear.
    if (lp_asked_n + 1) mod HEAR_EVERY == 0 then
        lp_choose_hear() -> hitem;
        if hitem then lp_drill(hitem, "hear").erase; return endif;
    endif;
    lp_plan() -> plan;
    if plan == [] then
        printf('  Nothing is ready at %p -- everything here is either known\n',
               [% lp_level %]);
        printf('  or waiting on something you have not been taught yet.\n');
        return;
    endif;
    lp_choose(plan) -> item;
    ;;; Everything ready has been put off and nothing else can be asked
    ;;; by typing.  The gap gives way: the student asked for later, not
    ;;; for never, and an empty session is the worse answer.
    unless item then
        if lp_pending /== [] then hd(lp_pending)(1) -> item endif;
    endunless;
    ;;; Nothing left to read at this level, but something left to hear:
    ;;; that is how a rung whose reading is finished gets finished.
    unless item then
        lp_choose_hear() -> hitem;
        if hitem then lp_drill(hitem, "hear").erase; return endif;
    endunless;
    if item then lp_drill(item, lp_primary(item)).erase
    else printf('  Nothing here can be checked by typing.  Try :assign.\n')
    endif;
enddefine;

define lp_session();
    ;;; `back` is a Pop-11 syntax word, as `from`, `to` and `step` are
    lvars line, cmd, arg, a2, id, outcome, retaken;
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
            elseif cmd = 'place' then lp_place_run();
            elseif cmd = 'oops' then
                if not(lp_aid("oops")) then
                    printf('  :oops is off -- :aids oops on puts it back.\n');
                elseif lp_undo_last() ->> retaken then
                    ;;; Requeued, not re-asked.  I have just said what the
                    ;;; answer was, so asking it again now would be a free
                    ;;; mark for anything got wrong.
                    lp_requeue(retaken);
                    printf('  Taken back, and nothing recorded.  I will ask it\n');
                    printf('  again shortly -- not now, because you have just\n');
                    printf('  seen the answer.\n');
                else
                    printf('  Nothing to take back.\n');
                endif;
            elseif cmd = 'aids' then
                lp_split2(arg) -> (a2, outcome);
                if a2 = '' then lp_aids_show();
                elseif not(member(consword(a2), lp_aid_names())) then
                    printf('  There is no "%p".  They are: %p\n',
                           [% a2, lp_aid_names() %]);
                elseif outcome /= 'on' and outcome /= 'off' then
                    printf('  :aids %p on|off\n', [^a2]);
                else
                    lp_aid_set(consword(a2), outcome = 'on').erase;
                    lp_aids_show();
                endif;
            elseif cmd = 'sheet' then lp_show_sheet("today");
            elseif cmd = 'zine' then lp_show_sheet("zine");
            elseif cmd = 'chart' then
                if arg = '' then
                    printf('  :chart hiragana|katakana|youon\n')
                else lp_show_sheet(consword(arg)) endif;
            elseif cmd = 'card' then
                if arg = '' then printf('  :card <item id>\n')
                else lp_show_card(consword(arg)) endif;
            elseif cmd = 'mic' then lp_mic_check();
            elseif cmd = 'speak' then
                if arg = '' then printf('  :speak <item id>\n')
                else lp_speak_drill(consword(arg)).erase endif;
            elseif cmd = 'say' then
                lp_split2(arg) -> (a2, outcome);
                if a2 = '' then printf('  :say <item id> [slow|normal|fast]\n')
                else lp_show_say(consword(a2),
                                 if outcome = '' then false
                                 else consword(outcome) endif)
                endif;
            elseif cmd = 'rate' then lp_show_rate(arg);
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
        elseif line = 'later' then
            ;;; Typed at the wrong prompt, which is an easy mistake to
            ;;; make: it is an answer to a question, and there is no
            ;;; question open here.
            printf('  "later" is for when I have asked you something.  Press\n');
            printf('  enter for a question, and type it then.\n');
        else
            printf('  This is not a conversation yet -- that comes with the\n');
            printf('  dialogue layer.  Try <enter>, or :help.\n');
        endif;
    endrepeat;
    lp_save();
    printf('\n%p\n', [% lp_line('signoff') %]);
enddefine;

;;; --------------------------------------------------- the other language
;;; Which language the STUDENT can already read.  Not lp_lang, which is
;;; what they are learning and therefore the one thing they cannot be
;;; assumed to follow.
;;;
;;; card.p has had this rule since the cards were drawn -- a loanword
;;; trap carries a Japanese gloss because the person reading it reads
;;; Japanese -- but it was spelled inside lp_card_gloss and so could not
;;; be used anywhere else.  It is needed anywhere else the moment a page
;;; carries words of its own: a study booklet for a Japanese speaker
;;; learning English, whose every heading was in English, is the same
;;; defect as asking a beginner a grammar question in vocabulary they do
;;; not have.
define lp_learner_lang() -> l;
    lvars l = if lp_lang == "ja" then "en" else "ja" endif;
enddefine;

;;; ---------------------------------------------------------------- sheets
;;; Something to take away from the screen and put on a desk.  Loaded on
;;; demand exactly as card.p is, and for the same reason.
vars lp_sheet_loaded = false;

define lp_load_sheet();
    unless lp_sheet_loaded then
        pop11_compile(langpop_dir <> 'sheet.p');
        true -> lp_sheet_loaded;
    endunless;
enddefine;

define lp_show_sheet(style);
    lvars style, path, why;
    lp_load_sheet();
    ;;; lp_card_open is card.p's, and opening the file is the whole point
    ;;; of printing one -- so the viewer comes along even when no card
    ;;; was ever asked for.
    unless lp_card_loaded then
        pop11_compile(langpop_dir <> 'card.p');
        true -> lp_card_loaded;
    endunless;
    lp_sheet_render(style, lp_user) -> (path, why);
    if why = 'no_such_style' then
        printf('  There is no "%p" sheet.  Try hiragana, katakana,\n', [^style]);
        printf('  youon, or :sheet for today.\n');
    elseif why then
        printf('  I cannot draw that: %p\n', [^why]);
    else
        printf('  %p\n', [^path]);
        unless lp_card_open(path) then
            printf('  No viewer here; the file is on disk.\n');
        endunless;
    endif;
enddefine;

;;; ------------------------------------------------------------------ main
;;; The modifiers, from the graph: characters a written form may hold
;;; that are not kana in their own right.  Built on first use, like the
;;; probes and the edges.
vars lp_mods = newproperty([], 64, false, "perm"), lp_mods_ready = false;

define lp_modifier_of(glyph) -> why;
    lvars glyph, m, why;
    unless lp_mods_ready then
        true -> lp_mods_ready;
        clearproperty(lp_mods);
        for m in lp_ask("modifiers", 0) do
            prolog_deref(prolog_arg(3, m))
                -> lp_mods(consword(prolog_full_deref(prolog_arg(1, m))
                                    sys_>< ''));
        endfor;
    endunless;
    lp_mods(consword(glyph sys_>< '')) -> why;
enddefine;

;;; Every character of every written form is either a kana the graph
;;; holds or a modifier the graph declares.
;;;
;;; This is a Pop-11 check and not a Prolog one because it has to walk a
;;; string character by character, and the characters are UTF-8: splitting
;;; an atom into them is what utf8_explode is for and what Prolog here is
;;; not.  So check(graph) proves the shape of the graph and this proves
;;; the content of its forms, and lp_check returns both.
;;;
;;; What it is for: recognise(hiragana) is measured over kana/5, which
;;; holds only the kana that stand for a mora on their own.  That is the
;;; right set to measure -- ゃ has no reading to type -- but it means the
;;; graph can hold a form with a character in it that nothing teaches and
;;; nothing checks.  Now it cannot, silently.
define lp_undeclared_kana() -> bad;
    lvars i, sc, f, cp, c, bad = [],
          seen = newproperty([], 64, false, "perm");
    lp_build_kana_rom();
    for i in lp_items do
        for sc in [hiragana katakana] do
            lp_form_of(i, sc) -> f;
            nextunless(f);
            for cp in [% utf8_explode(f sys_>< '') %] do
                consutf8(#| cp |#) -> c;
                nextif(lp_kana_rom(consword(c)));
                nextif(lp_modifier_of(c));
                nextif(seen(c));
                true -> seen(c);
                bad <> [% 'undeclared_kana(' <> c <> ', ' <> (i sys_>< '')
                          <> ')' %] -> bad;
            endfor;
        endfor;
    endfor;
enddefine;

define lp_check() -> bad;
    lvars bad;
    lp_ask("graph", "check", 1) -> bad;         ;;; ?- check(graph).
    bad <> lp_undeclared_kana() -> bad;
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
          batch = false, checkonly = false, auditonly = false,
          sheetonly = false, audioonly = false, rate = false, rest = [];
    find_dir() -> langpop_dir;
    until args == [] do
        hd(args) -> a;
        if a = '--lang' then consword(hd(tl(args))) -> lp_lang; tl(tl(args)) -> args;
        elseif a = '--user' then consword(hd(tl(args))) -> user; tl(tl(args)) -> args;
        elseif a = '--name' then hd(tl(args)) -> display; tl(tl(args)) -> args;
        elseif a = '--batch' then true -> batch; tl(args) -> args;
        elseif a = '--data' then hd(tl(args)) -> lp_home_dir; tl(tl(args)) -> args;
        elseif a = '--check' then true -> checkonly; tl(args) -> args;
        elseif a = '--audit' then true -> auditonly; tl(args) -> args;
        elseif a = '--chart' then
            consword(hd(tl(args))) -> sheetonly; tl(tl(args)) -> args;
        elseif a = '--sheet' then "today" -> sheetonly; tl(args) -> args;
        elseif a = '--zine' then "zine" -> sheetonly; tl(args) -> args;
        elseif a = '--audio' then
            consword(hd(tl(args))) -> audioonly; tl(tl(args)) -> args;
        elseif a = '--rate' then
            consword(hd(tl(args))) -> rate; tl(tl(args)) -> args;
        else conspair(a, rest) -> rest; tl(args) -> args;
        endif;
    enduntil;
    if lp_lang == "en" then "preschool" else "preschool" endif -> lp_level;
    lp_load();
    lp_index();
    ;;; On demand everywhere else, but every mode below has to know up
    ;;; front whether it can ask a listening question: lp_verifiable
    ;;; ("hear") is consulted by the plan, the gate, --audit and --check,
    ;;; long before anything would have asked to hear a word.  A machine
    ;;; with no audio.conf still never compiles audio.p.
    if sys_file_exists(lp_audio_conf_path()) then lp_load_audio() endif;
    ;;; Before the check, because a hollow rung is a fact about the
    ;;; graph and wants no student bound to it.
    if auditonly then lp_audit_show(); return endif;
    ;;; Ahead of time, and with no student: the audio of an item is a
    ;;; property of the graph, like a card.
    if audioonly then
        lp_load_audio();
        lp_audio_show(audioonly, rate);
        return;
    endif;
    ;;; A chart needs no student; today's sheet needs one, and says so
    ;;; rather than drawing an empty page under somebody's name.
    if sheetonly then
        lvars spath, swhy;
        lp_load_sheet();
        if user then
            user -> lp_user; lp_load_profile(user).erase;
        endif;
        lp_sheet_render(sheetonly, user) -> (spath, swhy);
        if swhy then printf('sheet: %p\n', [^swhy])
        else printf('sheet: wrote %p\n', [^spath]) endif;
        return;
    endif;
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
    ;;; --rate outside --audio is the student saying how they want to be
    ;;; spoken to for the whole session.  audio.p may not be loaded yet,
    ;;; so the name is held and lp_load_audio picks it up.
    if rate then rate -> lp_rate_want endif;
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
