;;; examples/langpop/tests/test_langpop.p -- suite for langpop (Proposal A).
;;;
;;;     ./poplog basepop11 examples/langpop/tests/test_langpop.p </dev/null
;;;
;;; Three things are worth testing here and the rest follows from them:
;;; the graph is sound, the prerequisite order is actually enforced, and
;;; the evidence tiers mean what the design says they mean.

uses poptest;
uses utf8;

vars langpop_lib = true;                ;;; no session, just the procedures
load 'examples/langpop/langpop.p';

find_dir() -> langpop_dir;
lp_load();
lp_index();

"student" -> lp_user;
"ja" -> lp_lang;
"preschool" -> lp_level;

;;; ------------------------------------------------------------- the graph
check_true('graph loaded', length(lp_items) > 150);
check('kana are graphemes', lp_kind("hi_a"), "grapheme");
check('kana are pre-school', lp_ilevel("hi_ka"), "preschool");
check('starter words are words', lp_kind("w_neko"), "word");
check('patterns are patterns', lp_kind("p_ni_ikimasu"), "pattern");
check('traps are English', lp_ilang("t_mansion"), "en");
check('contrasts are sounds', lp_kind("s_r_l"), "sound");

check('ja ladder', lp_levels("ja"), [preschool n5 n4 n3 n2 n1]);
check('en ladder', lp_levels("en"), [preschool a1 a2 b1 b2 c1]);

;;; Forms are derived from one table, so the glyph exists exactly once.
check('hiragana form', lp_form_of("hi_a", "hiragana") sys_>< '', 'あ');
check('katakana form', lp_form_of("ka_a", "katakana") sys_>< '', 'ア');
check('romaji form', lp_form_of("hi_shi", "romaji"), "shi");
check('one character, three bytes',
      utf8_length(lp_form_of("hi_a", "hiragana") sys_>< ''), 1);
check('kanji-free starter word',
      lp_form_of("w_gakkou", "hiragana") sys_>< '', 'がっこう');

;;; Confusables are stated once and read both ways.
check_true('confusable forwards',
           member("hi_o", [% lvars p; for p in lp_confs("hi_a") do hd(p) endfor %]));
check_true('confusable backwards',
           member("hi_a", [% lvars p; for p in lp_confs("hi_o") do hd(p) endfor %]));
check('diagnoses the usual mistake', lp_mistook("hi_a", 'o'), "hi_o");
check_false('does not invent a mistake', lp_mistook("hi_a", 'zzz'));

;;; --------------------------------------------------- prerequisite order
;;; Nothing is ready except the five vowels, because every other hiragana
;;; requires all five and every katakana requires its hiragana.
check('only the vowels are ready at the start',
      sort([% lvars i; for i in lp_plan() do i endfor %]),
      [hi_a hi_e hi_i hi_o hi_u]);

define mark_known(item);
    MASTERY -> lp_beliefs(lp_bkey(lp_user, item, lp_primary(item)));
enddefine;

mark_known("hi_a"); mark_known("hi_i"); mark_known("hi_u");
mark_known("hi_e"); mark_known("hi_o");

lvars plan2 = lp_plan();
check_true('katakana vowels unlock with their hiragana', member("ka_a", plan2));
check_true('consonant hiragana unlock after the vowel row', member("hi_ka", plan2));
check_false('a word does not unlock before the whole syllabary',
            member("w_neko", plan2));
check_false('katakana ka waits for hiragana ka', member("ka_ka", plan2));

;;; ------------------------------------------------------- evidence tiers
"drill" -> lp_user;                      ;;; a clean overlay for the arithmetic

lp_record("hi_ka", "read", 1, true, 500);
lp_record("hi_ka", "read", 1, true, 500);
check_false('two verified answers are not enough', lp_mastered("hi_ka"));
lp_record("hi_ka", "read", 1, true, 500);
check_true('three verified answers master an item', lp_mastered("hi_ka"));

check_true('a wrong answer costs more than a right one gains',
           lp_bel("hi_ka", "read") > 0.8
           and (lp_record("hi_ka", "read", 1, false, 500),
                lp_bel("hi_ka", "read") < 0.4));

;;; Tier 3 is compliance: "I did it".  Twenty of them must not add up to
;;; knowing something, and this is the test that says so.
"tier3" -> lp_user;
lvars n;
for n from 1 to 20 do lp_record("s_r_l", "hear", 3, true, 0) endfor;
check_true('compliance stays below its cap', lp_bel("s_r_l", "hear") <= 0.50);
check_false('compliance never reaches mastery', lp_mastered("s_r_l"));

;;; Tier 2 is a reported result.  It may carry an item to just below
;;; mastery, so one verified check is always what settles it.
"tier2" -> lp_user;
for n from 1 to 20 do lp_record("s_r_l", "hear", 2, true, 0) endfor;
check_true('a reported result gets close', lp_bel("s_r_l", "hear") > 0.70);
check_false('but not to mastery on its own', lp_mastered("s_r_l"));
check_true('one verified answer then settles it',
           (lp_record("s_r_l", "hear", 1, true, 500),
            lp_mastered("s_r_l")));

;;; Only verified evidence is measured against an exit criterion: a
;;; self-report moves a belief but must not move the level's score.
"measure" -> lp_user;
lp_record("hi_a", "read", 1, true, 1000);
lp_record("hi_i", "read", 1, false, 1000);
lp_record("hi_u", "read", 3, true, 0);
lvars (acc, fast, cnt) = lp_measure([hi_a hi_i hi_u], 2000);
check('accuracy over verified answers only', cnt, 2);
check('half right', acc, 0.5);
check('both inside the latency window', fast, 0.5);

;;; --------------------------------------------------------- the questions
check('a grapheme is typed',
      [% lvars sh; lp_question("hi_a") -> (sh, , , ); sh %], [type]);
check('a loanword trap is a choice',
      [% lvars sh; lp_question("t_mansion") -> (sh, , , ); sh %], [pick]);
check('a sound cannot be checked by typing',
      [% lvars sh; lp_question("s_r_l") -> (sh, , , ); sh %], [none]);
check_false('and so it is not drillable', lp_drillable("s_r_l"));
check_true('while a word is', lp_drillable("w_neko"));

;;; The two options of a trap are its two meanings, and the answer is
;;; whichever position the English one landed in.
lvars (sh2, pr2, ans2, opts2) = lp_question("t_service");
check('prompt is the English word', pr2, 'service');
check('two options', length(opts2), 2);
check('the answer points at the English meaning',
      opts2(strnumber(ans2)) sys_>< '', 'work done for a customer');

;;; -------------------------------------------------------- the catalogue
lvars r = lp_resource_for("s_r_l");
check_true('the catalogue points at a resource', r and hd(r) == "r_minimal_rl");
check('and records when it was last checked',
      hd(tl(tl(tl(tl(tl(r)))))) sys_>< '', '2026-10-19');

;;; ---------------------------------------------------------- integrity
;;; The real graph first.
check('the shipped graph has no violations', lp_check(), []);

;;; Then a graph that is wrong in seven ways, so the checks above are
;;; known not to be vacuous.  This replaces item/5, form/3 and requires/2.
prolog_compile(discin(langpop_dir <> 'tests/bad.pl'));
lvars bad = lp_check(), kinds = [], v, f;
for v in bad do
    prolog_functor(v) -> f;
    unless member(f, kinds) then conspair(f, kinds) -> kinds endunless;
endfor;
check('every integrity check fires on a broken graph',
      sort(kinds),
      [cycle item_without_form item_without_source level_not_on_ladder
       requires_crosses_language requires_from_above requires_unknown_item]);

test_summary();
