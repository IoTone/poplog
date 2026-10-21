% examples/langpop/graph/schema.pl -- the item schema, and what makes it a graph.
%
% Everything the tutor knows about a language is one of the relations
% below.  Nothing else is allowed in a graph file: a fact that does not
% fit one of these shapes is a fact nothing can reason over.
%
%   item(Id, Kind, Lang, Level, Source)
%       Id      a flat atom, the item's IDENTITY.  An item is not its
%               spelling: hi_a is the identity, 'あ' is one of its forms.
%       Kind    grapheme | sound | word | pattern | skill
%       Lang    ja | en
%       Level   a ladder node (ladder/3 below), never an integer
%       Source  provenance, always: own(kana) | jmdict('1358280') |
%               tatoeba('82431') | ets(cefr_mapping) | ...
%
%   form(Id, Script, Text)        one item, many written forms
%       Script  hiragana | katakana | kanji | romaji | latin | ipa
%   gloss(Id, Lang, Text)         what it means, in a named language
%   requires(Id, Pre)             the prerequisite DAG, within one language
%   confusable(A, B, Why)         declared one way, read both ways
%
%   rank(Id, Scale, N)            an ordinal difficulty proxy, lower first
%       Scale   freq | grade | strokes
%
%       NOT provenance, and not a property of the item's meaning: it is
%       how hard or how common the item is, on a named scale that
%       somebody else published.  Optional -- English carries none,
%       because no source we can use publishes one.
%
%       Placement is what wants it.  Probing 103 kanji one at a time to
%       find out whether somebody reads kanji is absurd; four probes
%       spread along a frequency rank locate them.  A criterion stated as
%       a bare count has the same weakness from the other side --
%       kanji(2230) is satisfied by any 2,230 characters, including
%       2,230 obscure ones -- which is the argument for ranking one.
%
%   ladder(Lang, Index, Level)    the levels of a language, in order
%   exit(Lang, Level, Criterion, Threshold, LatencyMs)
%
% Nothing here names JLPT or TOEIC.  A ladder is a per-language list, so
% the same engine drives 5->1 and a band of cut scores.
%
% The learner overlay is NOT here.  Beliefs live in Pop-11 (langpop.p)
% and reach Prolog as lp_belief/3 and lp_known/2, because they change
% every turn and the graph does not.

% A call to an undefined predicate FAILS in Poplog Prolog by default,
% which hides a typo in a rule as a level with nothing ready in it.  Say
% so once, here, and a misspelled predicate raises instead (PLOGHELP
% UNKNOWN).  Every graph file is loaded together, so nothing in this
% graph is legitimately undefined.
:- library(unknown).
:- unknown(_, error).

% Poplog Prolog has no forall/2 -- it is in no library and no help file --
% so state the idiom once, here.  Under unknown(_, error) above, a rule
% that reached for forall/2 would now raise rather than quietly never
% succeed, which is how this was found the slow way.
all_hold(Cond, Action) :- \+ (Cond, \+ Action).

% Confusability is symmetric; the data states each pair once.
confused_with(A, B, Why) :- confusable(A, B, Why).
confused_with(A, B, Why) :- confusable(B, A, Why).

% --- Imported content ----------------------------------------------------
% A level's content can come from upstream reference data rather than from
% this directory (examples/langpop/import.p), and a generated file stamps
% itself with one of these.  The point of the stamp is a distinction the
% rest of the graph cannot make: a level with no items because nobody has
% curated it yet and a level with no items because its content was never
% BUILT look identical to ready/4, and they are not remotely the same
% thing to say to a student.
%
% The clause below matches no real stamp.  It is here because a predicate
% with no clauses at all RAISES under the unknown(_, error) above, and
% with nothing imported there would be none -- so every caller of
% content_built/2 would have failed in the one case it exists to report.
generated(none, none, none, 0, none).

% Same reason: with no imported content there is not a single rank/3 in
% the graph, and a predicate with no clauses RAISES under the
% unknown(_, error) above rather than failing.  This one matches nothing.
rank(none, none, 0).

content_built(Lang, Level) :- generated(_, Lang, Level, N, _), N > 0.

% A level that declares an exit criterion but holds no items.  Not a
% violation: it is the honest state of a ladder whose upper rungs are
% still to be written, and check(graph) would then never be clean.  It is
% reported on its own, by whoever asks.
level_empty(Lang, Level) :-
    ladder(Lang, _, Level),
    \+ item(_, _, Lang, Level, _).

% --- Teaching ------------------------------------------------------------
% An item is ready when the student does not know it and knows everything
% it requires.  This is the whole of the tutor's choice, and it is one
% clause because the prerequisite edges carry the pedagogy.

ready(S, Lang, Level, I) :-
    item(I, _, Lang, Level, _),
    \+ lp_known(S, I),
    all_hold(requires(I, Pre), lp_known(S, Pre)).

% Everything ready at the student's current level, for the Pop-11 driver.
plan(S, Lang, Level) :- ready(S, Lang, Level, I), lp_take(I), fail.
plan(_, _, _).

% Why this item: its prerequisites, and whether each is in place.
why(I) :-
    requires(I, Pre),
    ( lp_known_now(Pre) -> lp_take(known(Pre)) ; lp_take(missing(Pre)) ),
    fail.
why(_).

% --- Integrity -----------------------------------------------------------
% Checks the test suite runs over whatever graph is loaded.  Each one
% enumerates violations; no answers means the graph is sound.

violation(level_not_on_ladder(I, Lang, Level)) :-
    item(I, _, Lang, Level, _), \+ ladder(Lang, _, Level).

violation(requires_crosses_language(I, Pre)) :-
    requires(I, Pre),
    item(I, _, L1, _, _), item(Pre, _, L2, _, _), L1 \== L2.

violation(requires_unknown_item(I, Pre)) :-
    requires(I, Pre), \+ item(Pre, _, _, _, _).

violation(requires_from_above(I, Pre)) :-
    requires(I, Pre),
    item(I, _, Lang, Li, _), item(Pre, _, Lang, Lp, _),
    ladder(Lang, Ni, Li), ladder(Lang, Np, Lp), Np > Ni.

violation(cycle(I)) :- item(I, _, _, _, _), reaches(I, I).

violation(item_without_form(I)) :-
    item(I, Kind, _, _, _), Kind \== skill, \+ form(I, _, _).

violation(item_without_source(I)) :- item(I, _, _, _, _), \+ provenance_ok(I).
provenance_ok(I) :- item(I, _, _, _, S), nonvar(S), S \== unknown.

% Reachability that terminates on a graph which is NOT yet known to be a
% DAG -- which is the only interesting case, since this is what finds the
% cycles.  Without the visited list, a two-item cycle has infinitely many
% proofs and the check exhausts pop_prolog_lim instead of reporting it.
reaches(X, Y) :- reaches_(X, Y, [X]).
reaches_(X, Y, _) :- requires(X, Y).
reaches_(X, Z, Seen) :-
    requires(X, Y), \+ in_list(Y, Seen), reaches_(Y, Z, [Y|Seen]).

in_list(X, [X|_]).
in_list(X, [_|T]) :- in_list(X, T).

check(graph) :- violation(V), lp_take(V), fail.
check(graph).

% --- Indexing ------------------------------------------------------------
% One pass that hands the whole graph to Pop-11 at startup, so the TUI and
% the tests can work without a Prolog call per lookup.  Failure-driven,
% because Poplog Prolog has no findall over a Pop-11 predicate worth using
% here and this is simpler to read.

index :- item(I, K, L, Lv, S), lp_item(I, K, L, Lv, S), fail.
index :- form(I, Sc, T), lp_form(I, Sc, T), fail.
index :- gloss(I, Lg, T), lp_gloss(I, Lg, T), fail.
index :- confusable(A, B, W), lp_conf(A, B, W), fail.
index :- ladder(Lang, N, Level), lp_ladder(Lang, N, Level), fail.
index :- exit(Lang, Level, C, Th, Ms), lp_exit(Lang, Level, C, Th, Ms), fail.
index :- resource(R, Lang, Kind, Target, Url, Checked),
         lp_resource(R, Lang, Kind, Target, Url, Checked), fail.
index :- generated(S, Lang, Level, N, Date), N > 0,
         lp_generated(S, Lang, Level, N, Date), fail.
index :- rank(I, Scale, N), I \== none, lp_rank(I, Scale, N), fail.
index.

% The prerequisite edges, which index/0 deliberately does not collect: the
% tutor never needs the whole DAG, only ready/4's one-level check, so the
% overlay would carry 200 pairs nothing reads.  The exporters do need them
% (dump.p), and they ask for them once.
edges :- requires(I, Pre), lp_take(requires(I, Pre)), fail.
edges.

% Which items a level's exit criterion is measured over.  A criterion that
% is a count (vocabulary(N), coverage(Axis, Fraction)) has no item set and
% is answered by the driver instead.
criterion_item(recognise(Script), I) :- kana(I, Script, _, _, _).
criterion_item(skill(S), S).
criterion_item(Named, I) :- atom(Named), requires(Named, I).

% The ladder rungs that hold nothing, for the --check report.
empties :- level_empty(Lang, Level), lp_take(empty(Lang, Level)), fail.
empties.

criteria(Lang, Level) :- exit(Lang, Level, C, Th, Ms), lp_take(crit(C, Th, Ms)), fail.
criteria(_, _).

criterion_items(C) :- criterion_item(C, I), lp_take(I), fail.
criterion_items(_).
