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

;;; ----------------------------------------------------------- channels
;;; A word you can only READ is the vocabulary-book pathology, and it used
;;; to be the engine's definition of knowing a word: one channel decided.
;;; Now an item is judged on a list, and the gate is only its head.
"channels" -> lp_user;

check('a character is read', lp_channels("hi_a"), [read]);
check('a word is read AND heard', lp_channels("w_neko"), [read hear]);
check('a sound contrast is heard, or it is nothing', lp_channels("s_r_l"), [hear]);
check('a pattern is produced', lp_channels("p_kore_wa_desu"), [produce]);
check('the gate is the head of the list', lp_primary("w_neko"), "read");

;;; The split that matters: reading a word is not hearing it.
lp_record("w_neko", "read", 1, true, 500);
lp_record("w_neko", "read", 1, true, 500);
lp_record("w_neko", "read", 1, true, 500);
lp_record("w_neko", "read", 1, true, 500);
check_true('four verified reads master it on read', lp_mastered_on("w_neko", "read"));
check_false('and not on hear', lp_mastered_on("w_neko", "hear"));
check_true('the gate opens, because reading unlocks reading',
           lp_mastered("w_neko"));
check('so it counts toward the reading criterion',
      lp_count_mastered("word", "read"), 1);
check('and not toward the listening one',
      lp_count_mastered("word", "hear"), 0);

;;; Unlocking and passing are different questions and must not be merged.
;;; If the gate demanded every channel then, with no way to check `hear`,
;;; nothing would ever unlock and the ladder could not be climbed.
check_true('read can be checked here', lp_verifiable("read"));
check_false('hear cannot -- there is no audio', lp_verifiable("hear"));

;;; A self-report cannot buy a listening score either: tier 2 is capped
;;; below MASTERY by arithmetic, so an unverifiable channel stays
;;; unverified however much the student claims.
lp_record("w_mizu", "hear", 2, true, 0);
lp_record("w_mizu", "hear", 2, true, 0);
lp_record("w_mizu", "hear", 2, true, 0);
lp_record("w_mizu", "hear", 2, true, 0);
lp_record("w_mizu", "hear", 2, true, 0);
check_true('a self-report moves the listening belief',
           lp_bel("w_mizu", "hear") > 0.5);
check_false('but cannot reach mastery on it',
            lp_mastered_on("w_mizu", "hear"));

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

;;; ------------------------------------------------------- persistence
;;; Assignments are the one thing that MUST outlive a session: the work
;;; is done between sessions and reported next time.  They were being
;;; written to the profile and never read back, so ":report 1" answered
;;; "No assignment 1." the following day.
lvars tmpdir = '/tmp/langpop-test-' sys_>< sys_real_time() sys_>< '/';
tmpdir -> lp_home_dir;

"saver" -> lp_user;
'Saver' -> lp_display;
"en" -> lp_lang;
[] -> lp_journal;
[{% 1, "s_r_l", "r_minimal_rl", 1700000000000, 'open' %}] -> lp_assigns;
lp_record("s_r_l", "hear", 3, true, 0);
lp_save();

[] -> lp_assigns;
[] -> lp_journal;
false -> lp_display;
check_true('a profile reloads', lp_load_profile("saver"));
check('display name survives', lp_display, 'Saver');
check('one assignment survives', length(lp_assigns), 1);
check('its item survives as a word', lp_assigns(1)(2), "s_r_l");
check('its resource survives', lp_assigns(1)(3), "r_minimal_rl");
check('its status survives', lp_assigns(1)(5), 'open');
check_true('and it can be found by id', lp_find_assign(1) and true);
check('the journal survives', length(lp_journal), 1);
check('tier survives the round trip', lp_journal(1)(3), 3);

;;; ------------------------------------------------------- recognition
;;; The teacher is allowed to MISremember.  Offering the nearest name and
;;; being corrected is how a person recognises somebody, and the
;;; correction is kept so the same wrong guess is never made twice.

check('an exact match is no distance at all', lp_edit('cat', 'cat'), 0);
check('a substitution is one', lp_edit('cat', 'cot'), 1);
check('an insertion is one', lp_edit('dkords', 'dkordss'), 1);
check('a deletion is one', lp_edit('dkords', 'dkord'), 1);
check('the textbook case', lp_edit('kitten', 'sitting'), 3);
check('an empty string costs the whole of the other', lp_edit('', 'ab'), 2);

;;; A transposition is ONE typo.  Plain Levenshtein charges two, which put
;;; the commonest slip a returning student makes outside the tolerance for
;;; any short name -- so this is load-bearing, not a nicety.
check('a transposition is one edit, not two', lp_edit('bsmith', 'bsmiht'), 1);
check('even at the start', lp_edit('ab', 'ba'), 1);
check_true('and the tolerance for a six-letter name admits exactly one',
           lp_edit('bsmith', 'bsmiht') <= lp_edit_tol(6));

check('tolerance is proportional', lp_edit_tol(11), 2);
check('but never zero', lp_edit_tol(2), 1);

;;; A NAME is not a string.  "Bob Smith" against "Bob White" is three
;;; edits apart and so outside any sane tolerance -- yet it is the exact
;;; confusion a person makes, because the two share a given name.
check('a shared given name is close', lp_name_dist('bob smith', 'bob white'), 1);
check('two unrelated names are not',
      lp_name_dist('bob smith', 'robert jones'), 5);
;;; Strings, not words.  They print identically, which is the third time
;;; that distinction has cost something in this tree.
check('a name splits on whitespace',
      lp_split_name('bob smith'), ['bob' 'smith']);

;;; The guess itself, against a roll on disk.
'Bob Smith' -> lp_display;
lp_roll_add("bsmith", 'Bob Smith');
lp_roll_add("yuki", 'Yuki Tanaka');
[] -> lp_corrections;

lvars (g1, d1, w1) = lp_roll_guess_full("bwhite", 'Bob White');
check('a new person is offered the near name', g1, "bsmith");
check('with the name it would call them', d1, 'Bob Smith');
check('and says what it matched on', w1, 'the name');

lvars (g2, d2, w2) = lp_roll_guess_full("bsmiht", false);
check('a typo in a username is recognised', g2, "bsmith");
check('on the username this time', w2, 'the username');

lvars (g3, d3, w3) = lp_roll_guess_full("carlos", 'Carlos Ruiz');
check('somebody unrelated is not guessed at', g3, false);

;;; Once refused, never offered again -- which is the difference between
;;; remembering somebody and guessing at them.
'Bob White' -> lp_display;
lp_refuse_guess('Bob Smith');
lvars (g4, d4, w4) = lp_roll_guess_full("bwhite", 'Bob White');
check('a refused guess is not repeated', g4, false);

;;; The same keystrokes must produce the same guess.  The old matcher kept
;;; whichever candidate a property walk happened to reach first, so with
;;; two students on the roll it guessed by hash order -- a teacher who
;;; asks "Bob Smith?" on Monday and "Yuki Tanaka?" on Tuesday from the
;;; same input is not remembering, it is rolling dice.
[] -> lp_corrections;
lp_roll_add("bsmitx", 'Bob Smithx');
lvars i, first = false, stable = true;
for i from 1 to 8 do
    lvars (ga, da, wa) = lp_roll_guess_full("bsmit", false);
    unless first then ga -> first endunless;
    unless ga == first then false -> stable endunless;
endfor;
check_true('the same input gives the same guess every time', stable);

;;; A failed load must leave nothing of the last student behind.  In the
;;; one-shot TUI that never showed; the server is long-lived and serves
;;; whoever asks, so binding to a student who does not exist used to
;;; leave the previous one's journal and refusals in the globals.
"someone" -> lp_user;
[{% 1, "s_r_l", "r_minimal_rl", 1700000000000, 'open' %}] -> lp_assigns;
lp_refuse_guess('Somebody');
check_false('loading a student who does not exist fails',
            lp_load_profile("nobody_at_all"));
check('and leaves no assignments behind', length(lp_assigns), 0);
check('nor any refused guesses', length(lp_corrections), 0);

sysobey('rm -rf ' <> tmpdir);
false -> lp_home_dir;

test_summary();
