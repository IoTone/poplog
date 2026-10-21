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


;;; --------------------------------------------------- the voiced kana
;;; These exist because --audit found that skill(dakuten) could not be
;;; met: it required one item, hi_ka, and the table held base kana only,
;;; so passing it demonstrated reading か -- which says nothing whatever
;;; about か/が.  The criterion named a contrast the graph did not hold.

;;; Generated from the base codepoint, so a glyph cannot be subtly wrong:
;;; dakuten is +1 and handakuten is +2.
check('dakuten is the base plus one',
      lp_form_of("hi_ga", "hiragana") sys_>< '', 'が');
check('handakuten is the base plus two',
      lp_form_of("hi_pa", "hiragana") sys_>< '', 'ぱ');
check('and katakana is still plus 0x60',
      lp_form_of("ka_ga", "katakana") sys_>< '', 'ガ');
check('ふ voices to ぶ, not to ふ゛',
      lp_form_of("hi_bu", "hiragana") sys_>< '', 'ぶ');
check('one character, three bytes',
      utf8_length(lp_form_of("hi_pe", "hiragana") sys_>< ''), 1);

;;; 23 per script: the 20 dakuten less ぢ and づ, plus 5 handakuten, so
;;; 46 base hiragana become 69.  Counted off the glyphs rather than the
;;; ids, because the ids are what the generator could get wrong.
check('69 hiragana, one glyph each',
      length([% lvars i; for i in lp_items do
                  ;;; by the id, because a kanji has a hiragana READING
                  ;;; and 28 of the imported ones are a single character
                  ;;; -- 日 is ひ, which is not a kana item
                  if issubstring('hi_', i sys_>< '') == 1
                  and utf8_length(lp_form_of(i, "hiragana") sys_>< '') == 1
                  then i endif endfor %]), 69);
check_true('every one of the 23 voiced hiragana is there',
           [% lvars r; for r in [ga gi gu ge go za ji zu ze zo da de do
                                 ba bi bu be bo pa pi pu pe po] do
                  unless lp_kind(consword('hi_' <> (r sys_>< '')))
                  then r endunless endfor %] == []);

;;; ぢ and づ are deliberately absent: they are not a third and fourth
;;; sound but alternative spellings of じ and ず, and Hepburn spells each
;;; pair identically BECAUSE they are the same sound.  Had they been
;;; included, the katakana-after-hiragana rule -- which joins on the
;;; romaji -- would have made ジ require ぢ.
check_false('there is no separate di', lp_kind("hi_di"));
check_false('nor du', lp_kind("hi_du"));
check('so the romaji ji belongs to exactly one kana',
      length([% lvars i; for i in lp_items do
                  if lp_form_of(i, "hiragana")
                  and lp_form_of(i, "romaji") == "ji" then i endif
              endfor %]), 1);

;;; が after か, and nothing else new.  One mark is one thing to notice.
check_true('a voiced kana requires its base',
           member("hi_ka", lp_edges_of("hi_ga")));
check_true('and ぱ requires は', member("hi_ha", lp_edges_of("hi_pa")));
check_true('katakana still requires its hiragana',
           member("hi_ga", lp_edges_of("ka_ga")));
check_true('and its own base, in its own script',
           member("ka_ka", lp_edges_of("ka_ga")));

;;; The pair is confusable, because one mark apart is exactly how a
;;; beginner misreads it: か for が is the mark going unseen, not a guess.
;;; So it is diagnosed as `near` rather than `wrong`.
check('typing ka for が is the declared confusion',
      lp_mistook("hi_ga", 'ka'), "hi_ka");
check('and the other way round', lp_mistook("hi_ka", 'ga'), "hi_ga");
check('は is confused with ぱ as well as ば',
      lp_mistook("hi_pa", 'ha'), "hi_ha");
check_true('the mark is named in the reason',
           [% lvars p; for p in lp_confs("hi_ga") do
                  if hd(p) == "hi_ka" then lp_term_str(hd(tl(p))) endif
              endfor %] = ['mark(dakuten)']);

;;; And it can be asked, which is the whole point.
lvars (vsh, vpr, vans, vopt) = lp_question("hi_ga");
check('が can be asked by typing', vsh, "type");
check('the prompt is the glyph', vpr sys_>< '', 'が');
check_true('and ga is accepted', member('ga', vans));

;;; The aggregates fan out by rule, so the voiced kana joined them with
;;; no edit.  Which matters: がっこう needs が, and until now the starter
;;; words required a hiragana_all that did not contain it.
check_true('hiragana_all now covers が',
           member("hi_ga", lp_edges_of("hiragana_all")));
check_true('and katakana_all covers ガ',
           member("ka_ga", lp_edges_of("katakana_all")));

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

lp_record("hi_ka", "read", 1, "right", 500);
lp_record("hi_ka", "read", 1, "right", 500);
check_false('two verified answers are not enough', lp_mastered("hi_ka"));
lp_record("hi_ka", "read", 1, "right", 500);
check_true('three verified answers master an item', lp_mastered("hi_ka"));

check_true('a wrong answer costs more than a right one gains',
           lp_bel("hi_ka", "read") > 0.8
           and (lp_record("hi_ka", "read", 1, "wrong", 500),
                lp_bel("hi_ka", "read") < 0.4));

;;; Tier 3 is compliance: "I did it".  Twenty of them must not add up to
;;; knowing something, and this is the test that says so.
"tier3" -> lp_user;
lvars n;
for n from 1 to 20 do lp_record("s_r_l", "hear", 3, "right", 0) endfor;
check_true('compliance stays below its cap', lp_bel("s_r_l", "hear") <= 0.50);
check_false('compliance never reaches mastery', lp_mastered("s_r_l"));

;;; Tier 2 is a reported result.  It may carry an item to just below
;;; mastery, so one verified check is always what settles it.
"tier2" -> lp_user;
for n from 1 to 20 do lp_record("s_r_l", "hear", 2, "right", 0) endfor;
check_true('a reported result gets close', lp_bel("s_r_l", "hear") > 0.70);
check_false('but not to mastery on its own', lp_mastered("s_r_l"));
check_true('one verified answer then settles it',
           (lp_record("s_r_l", "hear", 1, "right", 500),
            lp_mastered("s_r_l")));

;;; ----------------------------------------------------------- outcomes
;;; A boolean threw away the most useful thing a wrong answer carries.
;;; Freezing is not the same as guessing wrong, and guessing the partner
;;; of a declared confusable pair is not the same as either.
"outcomes" -> lp_user;

lp_record("hi_ya", "read", 1, "right", 400);
lvars b_right = lp_bel("hi_ya", "read");
lp_record("hi_yu", "read", 1, "near", 400);
lvars b_near = lp_bel("hi_yu", "read");
lp_record("hi_yo", "read", 1, "wrong", 400);
lvars b_wrong = lp_bel("hi_yo", "read");
lp_record("hi_ra", "read", 1, "skip", 400);
lvars b_skip = lp_bel("hi_ra", "read");

check_true('right raises the belief', b_right > 0.0);
check('a near miss on an unknown item cannot raise it either', b_near, 0.0);

;;; From a belief that is already up, the four separate properly.
lvars x;
for x in [hi_re hi_ro hi_wa] do
    lp_record(x, "read", 1, "right", 400);
    lp_record(x, "read", 1, "right", 400);
    lp_record(x, "read", 1, "right", 400);
endfor;
lvars before = lp_bel("hi_re", "read");
lp_record("hi_re", "read", 1, "near", 400);
lp_record("hi_ro", "read", 1, "wrong", 400);
lp_record("hi_wa", "read", 1, "skip", 400);
check_true('a near miss costs least of the three',
           lp_bel("hi_re", "read") > lp_bel("hi_ro", "read"));
check_true('and a freeze costs most',
           lp_bel("hi_ro", "read") > lp_bel("hi_wa", "read"));
check_true('all three cost something', lp_bel("hi_re", "read") < before);

;;; Only "right" counts toward a criterion, and a skip still counts in
;;; the denominator -- otherwise a student could raise their accuracy by
;;; answering only what they knew.
;;; lp_journal is global, not per student, so a block that measures has
;;; to start from an empty one or it counts whatever ran before it.
"measure2" -> lp_user;
[] -> lp_journal;
lp_record("hi_a", "read", 1, "right", 1000);
lp_record("hi_i", "read", 1, "skip", 1000);
lvars (acc2, fast2, cnt2) = lp_measure([hi_a hi_i], 2000);
check('a skip is measured', cnt2, 2);
check('and is not right', acc2, 0.5);

;;; A boolean still works, because older call sites and older profiles
;;; hold one.
"legacy" -> lp_user;
lp_record("hi_ka", "read", 1, true, 500);
check('true still means right', lp_journal(1)(4), "right");
lp_record("hi_ki", "read", 1, false, 500);
check('and false still means wrong', lp_journal(1)(4), "wrong");

;;; The partner of a confusable pair, typed in any of its forms.  Romaji
;;; was enough while the answer space was romaji; a student who types お
;;; for あ has made exactly the confusion the pair records.
check('the partner typed as romaji', lp_mistook("hi_a", 'o'), "hi_o");
check('the partner typed as the glyph itself', lp_mistook("hi_a", 'お'), "hi_o");
check('and something unrelated is not a confusion',
      lp_mistook("hi_a", 'zzz'), false);

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
lp_record("w_neko", "read", 1, "right", 500);
lp_record("w_neko", "read", 1, "right", 500);
lp_record("w_neko", "read", 1, "right", 500);
lp_record("w_neko", "read", 1, "right", 500);
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
lp_record("w_mizu", "hear", 2, "right", 0);
lp_record("w_mizu", "hear", 2, "right", 0);
lp_record("w_mizu", "hear", 2, "right", 0);
lp_record("w_mizu", "hear", 2, "right", 0);
lp_record("w_mizu", "hear", 2, "right", 0);
check_true('a self-report moves the listening belief',
           lp_bel("w_mizu", "hear") > 0.5);
check_false('but cannot reach mastery on it',
            lp_mastered_on("w_mizu", "hear"));

;;; Only verified evidence is measured against an exit criterion: a
;;; self-report moves a belief but must not move the level's score.
"measure" -> lp_user;
[] -> lp_journal;
lp_record("hi_a", "read", 1, "right", 1000);
lp_record("hi_i", "read", 1, "wrong", 1000);
lp_record("hi_u", "read", 3, "right", 0);
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
;;; Against the graph's own gloss, not against a copy of its text: the
;;; trap glosses were rewritten to carry the contrast, and an assertion
;;; holding a literal fails for a reason that has nothing to do with what
;;; it was checking.
check('the answer points at the English meaning',
      opts2(strnumber(hd(ans2))) sys_>< '',
      lp_gloss_of("t_service", "en") sys_>< '');

;;; ------------------------------------------------ kana into romaji
;;; This exists because every imported Japanese item was UNASKABLE.
;;; lp_question could only build a probe for an item carrying a romaji
;;; form, and the importer emits kanji, hiragana and katakana forms and
;;; no romaji -- so 251 of 521 items returned shape "none" and the tutor
;;; said nothing could be checked by typing.  It failed silently: no
;;; violation, because nothing checked that an item could be answered.

check('a base kana', lp_romaji('やま'), 'yama');
check('a voiced kana, which the graph does not carry', lp_romaji('みず'), 'mizu');
check('a small tsu doubles the next consonant', lp_romaji('がっこう'), 'gakkou');
check('the moraic n', lp_romaji('せんせい'), 'sensei');
check('a katakana long mark lengthens the vowel', lp_romaji('コーヒー'), 'koohii');

;;; The youon row, which is where a one-line rule gets it wrong.  Dropping
;;; the trailing i and adding the small kana's vowel gives ko for きょ; the
;;; stem needs y unless it already palatalises.
check('ki plus small yo is kyo', lp_romaji('きょう'), 'kyou');
check('shi plus small ya is sha, not shya', lp_romaji('しゃしん'), 'shashin');
check('chi plus small ya is cha', lp_romaji('ちゃ'), 'cha');
check('ji plus small ya is ja', lp_romaji('じゃ'), 'ja');
;;; and the one that separates sh/ch from the h of hi
check('hi plus small ya is hya, not ha', lp_romaji('ひゃく'), 'hyaku');
check('ni plus small ya is nya', lp_romaji('にゃ'), 'nya');

check('a reading with no kana at all gives nothing', lp_romaji('山'), false);

check('katakana folds to hiragana', lp_kata_to_hira('イチ'), 'いち');
check('and a long mark is left alone', lp_kata_to_hira('コーヒー'), 'こーひー');

;;; The spellings a learner might type.  Generous on purpose: the probe
;;; asks whether they know the reading, not whether they can spell
;;; Hepburn.
check_true('a long vowel may be written once',
           member('gakko', lp_romaji_variants('がっこう')));
check_true('Kunrei is accepted, because a Japanese school teaches it',
           member('tukue', lp_romaji_variants('つくえ')));
check_true('including the youon rows -- densya for でんしゃ',
           member('densya', lp_romaji_variants('でんしゃ')));
check_true('and Hepburn remains the canonical spelling',
           hd(lp_romaji_variants('でんしゃ')) = 'densha');



;;; ------------------------------------------------------ typing slips
;;; A Japanese learner is typing romaji, or fighting an input method
;;; they do not know well.  A slip of the fingers recorded as "wrong"
;;; costs them 0.70 of a belief and teaches the tutor something false --
;;; the probe ends up measuring typing rather than reading.

;;; Proportional, and with NO FLOOR, which is the opposite of the
;;; tolerance used for names.  For a two-character answer any edit is a
;;; different answer.
check('a two-letter answer gets no tolerance at all', lp_typo_tol(2), 0);
check('nor does a three-letter one', lp_typo_tol(3), 0);
check('four letters allow one slip', lp_typo_tol(4), 1);
check('and eleven allow two', lp_typo_tol(11), 2);

check_true('a dropped letter is a slip', lp_slip('yma', ['yama']));
check_true('a doubled one is too', lp_slip('yamma', ['yama']));
check_true('and a transposition', lp_slip('ginkuo', ['ginkou']));
check_false('but a different short answer is a mistake, not a slip',
            lp_slip('ke', ['ka']));
check_false('which is what keeps ke from being told it was close',
            lp_slip('ko', ['ka']));
check_false('and nonsense is a mistake', lp_slip('zzz', ['yama']));
check_false('an empty answer is a skip, not a slip', lp_slip('', ['yama']));

;;; ---------------------------------------------------------- undo
;;; One answer deep and only within the session, for what the slip
;;; detector cannot catch: an input method that ate the line, or enter
;;; hit a word early.  It has to restore every belief the answer moved,
;;; which is more than one -- a correct check also credits whatever it
;;; contained.
if lp_ilang("k_65e5") then
    "undoer" -> lp_user; [] -> lp_journal;
    lp_undo_start("w_tanjoubi");
    lp_record("w_tanjoubi", "read", 1, "right", 900);
    lp_undo_stop();
    check_true('the answer moved the word', lp_bel("w_tanjoubi", "read") > 0.0);
    check_true('and what it contains', lp_bel("k_65e5", "read") > 0.0);
    check('three journal entries, one answer and two inferences',
          length(lp_journal), 3);

    check('undo names the item to ask again', lp_undo_last(), "w_tanjoubi");
    check('the belief is back', lp_bel("w_tanjoubi", "read"), 0.0);
    check('including the inferred one', lp_bel("k_65e5", "read"), 0.0);
    check('and so is the journal', length(lp_journal), 0);
    check('a second undo is refused', lp_undo_last(), false);
else
    printf(';;; imported content not built -- undo not checked\n');
endif;


;;; ------------------------------------------------- putting it off
;;; A question put off, or taken back, has to come BACK -- and not
;;; immediately.  :oops is used after the tutor has already said what the
;;; answer was, so re-asking at once would be a free correct answer for
;;; anything got wrong.
lp_queue_reset();
check('the queue starts empty', length(lp_pending), 0);
check_false('and nothing is due', lp_due());

lp_requeue("hi_a");
check('one waiting', length(lp_pending), 1);
check_false('but not yet -- the gap has not elapsed', lp_due());

;;; The gap is counted in questions ANSWERED, not prompts printed.
lp_answered("hi_i"); lp_answered("hi_u");
check_false('two is not enough', lp_due());
lp_answered("hi_e");
check('three questions later it comes round', lp_due(), "hi_a");

;;; Still due until it is actually answered: reading the queue does not
;;; empty it, or a dropped connection would lose what was owed.
check('and stays due until it is answered', lp_due(), "hi_a");
lp_answered("hi_a");
check_false('answered, so no longer waiting', lp_due());
check('and gone from the queue', length(lp_pending), 0);

;;; Requeued twice is still one item, at the later gap.
lp_queue_reset();
lp_requeue("hi_a"); lp_answered("hi_i"); lp_requeue("hi_a");
check('requeuing twice leaves one copy', length(lp_pending), 1);
lp_answered("hi_u"); lp_answered("hi_e");
check_false('and the second gap is the one that counts', lp_due());
lp_answered("hi_o");
check('now', lp_due(), "hi_a");

;;; Twice, and then it has to be answered.  Without a limit "later" is a
;;; way never to be wrong about anything.
lp_queue_reset();
check_true('a question can be put off', lp_can_later("hi_a"));
lp_later("hi_a");
check_true('and again', lp_can_later("hi_a"));
lp_later("hi_a");
check_false('but not a third time', lp_can_later("hi_a"));
check('two deferrals counted', lp_later_n, 2);
check_true('a different item is unaffected', lp_can_later("hi_i"));

;;; Placement does not offer it at all: a freeze is the signal the
;;; descent runs on, so a student who could defer every hard question
;;; would never be placed.
lp_queue_reset();
false -> lp_allow_later;
check_false('not during a placement', lp_can_later("hi_a"));
true -> lp_allow_later;
check_true('offered again afterwards', lp_can_later("hi_a"));

;;; ------------------------------------------------------- the aids
;;; Each can be switched off, which is for the student rather than the
;;; tutor: an aid that cannot be refused is indistinguishable from a
;;; lower standard.
lp_aids_reset();
check('three of them', length(lp_aid_names()), 3);
check_true('all on to begin with',
           lp_aid("slip") and lp_aid("oops") and lp_aid("later"));
check('nothing logged yet', length(lp_aid_log), 0);

check_true('later goes off', lp_aid_set("later", false));
check_false('and is off', lp_aid("later"));
check('the change is logged', length(lp_aid_log), 1);
check('with the aid it was', hd(lp_aid_log)(1), "later");
check_false('and what it was set to', hd(lp_aid_log)(2));
check_true('and when', hd(lp_aid_log)(3) > 0);

;;; Setting it to what it already is is not a change, so the log stays a
;;; log of decisions rather than of keystrokes.
lp_aid_set("later", false).erase;
check('setting it twice logs once', length(lp_aid_log), 1);
lp_aid_set("later", true).erase;
check('and switching back logs again', length(lp_aid_log), 2);

check_false('there is no such aid as cheat', lp_aid_set("cheat", true));
check('and nothing was logged for it', length(lp_aid_log), 2);

;;; Switched off, the aid is not merely hidden -- lp_can_later says no,
;;; which is what the drill loop and the server both read.
lp_aid_set("later", false).erase;
lp_queue_reset();
check_false('off means off, not hidden', lp_can_later("hi_a"));
lp_aids_reset();

;;; ------------------------------------------------------- placement
;;; "Go ahead and introduce yourself."  A beginner freezes; one who
;;; answers gets another question, harder, until they stop.  The point
;;; is that the teacher starts ABOVE where they expect and lets failure
;;; locate the student -- per axis, because a learner who knows 500
;;; kanji and forgets katakana is not "at" any single level.
"placer" -> lp_user; "ja" -> lp_lang; [] -> lp_journal;

lvars axes = lp_place_axes(), ax, nm;
define ax_named(nm) -> a;
    lvars nm, a = false, x;
    for x in lp_place_axes() do if x(1) = nm then x -> a; return endif endfor;
enddefine;

check_true('the exit criteria give the axes', length(axes) > 3);
check_true('recognise is one', ax_named('recognise katakana') /== false);
check_true('and so is the kanji count', ax_named('kanji') /== false);
check_false('a coverage criterion is not -- there is nothing to probe',
            ax_named('coverage') /== false);

;;; The order is the teacher's: hardest first.
;;; An axis with nothing askable anywhere sorts last and has no level
;;; at all, so compare the two that do.
lvars withlv = [% for ax in axes do
                      if lp_place_levels(ax) /== [] then ax endif endfor %];
check_true('the hardest axis comes first',
           lp_level_index(hd(lp_place_levels(hd(withlv))))
           >= lp_level_index(hd(lp_place_levels(last(withlv)))));

;;; recognise(hiragana) means the KANA, not everything carrying a
;;; hiragana form.  An imported kanji has one -- its kun reading -- so a
;;; form scan pulled all 103 into the syllabary axis.  The schema
;;; already answers this through criterion_item/2, which is why the axis
;;; asks it rather than guessing.
if lp_ilang("k_65e5") then
    lvars hira = lp_place_items(ax_named('recognise hiragana'), "preschool");
    check_false('a kanji is not a hiragana probe', member("k_65e5", hira));
    check_true('but the kana are', member("hi_a", hira));
    check('and the syllabary axis lives only at pre-school',
          lp_place_levels(ax_named('recognise hiragana')), [preschool]);
    check('while vocabulary is searched from the top down',
          lp_place_levels(ax_named('vocabulary')), [n5 preschool]);

    ;;; Sampling spreads across a real difficulty scale where there is
    ;;; one -- four probes along a frequency rank instead of 103.
    lvars ks = lp_place_sample(lp_place_items(ax_named('kanji'), "n5"), 4);
    check('four probes, not a hundred and three', length(ks), 4);
    check_true('spread across the scale rather than bunched',
               lp_rank_of(last(ks), "freq") - lp_rank_of(hd(ks), "freq") > 200);
else
    printf(';;; imported content not built -- kanji axis not checked\n');
endif;

;;; Where there is no scale, the confusable ones come first.  A katakana
;;; test made of ア and ヲ certifies everybody.
lvars kat = lp_place_sample(lp_place_items(ax_named('recognise katakana'),
                                           "preschool"), 4), k;
check('four katakana probes', length(kat), 4);
lvars allconf = true;
for k in kat do unless lp_confs(k) /== [] then false -> allconf endunless endfor;
check_true('every one of them is half of a confusable pair', allconf);

;;; An axis settles once the sample is in -- or once everything there is
;;; has been asked.  skill(mora_count) has exactly one askable item, and
;;; a driver looping on lp_place_next would otherwise ask about it
;;; forever.
lvars small = ax_named('skill mora_count');
if small and lp_place_items(small, "preschool") /== [] then
    lvars i;
    for i in lp_place_items(small, "preschool") do
        lp_record(i, lp_primary(i), 1, "right", 500);
    endfor;
    lvars (st0, , , ) = lp_place_state(small, "preschool");
    check('an axis smaller than the sample still settles', st0, "passed");
endif;

;;; A freeze ends an axis, which is the behaviour the whole thing is
;;; modelled on.
"placer2" -> lp_user; [] -> lp_journal;
lvars kats = lp_place_items(ax_named('recognise katakana'), "preschool");
lp_record(hd(kats), "read", 1, "skip", 900);
lvars (st1, , , f1) = lp_place_state(ax_named('recognise katakana'), "preschool");
check('one freeze is not yet a verdict', st1, "untested");
lp_record(hd(tl(kats)), "read", 1, "skip", 900);
lvars (st2, , , f2) = lp_place_state(ax_named('recognise katakana'), "preschool");
check('two freezes end it', st2, "failed");
check('and it is the freezes that did it', f2, 2);

;;; The descent, and the thing that makes it cheap: passing high means
;;; nothing below gets asked.
if lp_ilang("k_65e5") then
    "placer3" -> lp_user; [] -> lp_journal;
    lvars vs = lp_place_sample(lp_place_items(ax_named('vocabulary'), "n5"), 4);
    for k in vs do lp_record(k, lp_primary(k), 1, "right", 800) endfor;
    lvars (stv, , , ) = lp_place_state(ax_named('vocabulary'), "n5");
    check('passing at the top settles the axis', stv, "passed");
    lvars r, found = false;
    for r in lp_place_report() do
        if r(1) = 'vocabulary' then r -> found endif;
    endfor;
    check('and it is placed there', found(2), "n5");
endif;

;;; lp_place_next never offers the same item twice: sampling the whole
;;; set each time returns the same head every time.
"placer4" -> lp_user; [] -> lp_journal;
lvars seen = [], a2, l2, its2, n2;
for n2 from 1 to 6 do
    lp_place_next() -> (a2, l2, its2);
    quitunless(a2);
    quitif(its2 == []);
    check_false('an item is never offered twice', member(hd(its2), seen));
    seen <> [% hd(its2) %] -> seen;
    lp_record(hd(its2), lp_primary(hd(its2)), 1, "right", 700);
endfor;

;;; And the level is DERIVED: the lowest rung with something unsettled.
check_true('a fresh student is placed at the bottom',
           lp_place_level() == "preschool" or lp_place_level() == false);

;;; ------------------------------------------------- inferred evidence
;;; Reading 誕生日 says something about 日 without the student ever being
;;; asked about 日.  The DAG is what makes that free -- and the cap is
;;; what keeps it honest, because the inference is sometimes false:
;;; 大人 is おとな and decomposes into neither 大 nor 人.

;;; Which edges carry an inference at all.  requires/2 does not
;;; distinguish its three uses, so containment is decided from the forms.
if lp_ilang("k_65e5") then
    check_true('a kanji written inside a word is contained',
               lp_contains("w_tanjoubi", "k_65e5"));
    check_false('an antonym is not contained',
                lp_contains("w_mijikai", "w_nagai"));
    check_false('and neither is a skill with no written form',
                lp_contains("w_tanjoubi", "hiragana_all"));

    "inferrer" -> lp_user;
    [] -> lp_journal;
    lp_record("w_tanjoubi", "read", 1, "right", 900);
    check_true('reading the word moves the kanji it contains',
               lp_bel("k_65e5", "read") > 0.0);
    check('by as much as a check would',
          lp_bel("k_65e5", "read"), lp_bel("w_tanjoubi", "read"));
    check('but not the roll-up it also requires',
          lp_bel("hiragana_all", "read"), 0.0);
    check('and it is recorded as inferred, not as a check',
          lp_journal(1)(3), 4);

    ;;; It never reaches mastery, so the item is confirmed once on
    ;;; contact rather than taught from scratch.  That is exactly what a
    ;;; learner who already knows 500 kanji needs.
    lvars n;
    for n from 1 to 8 do lp_record("w_tanjoubi", "read", 1, "right", 900) endfor;
    check_true('the word itself masters', lp_mastered("w_tanjoubi"));
    check('the inferred kanji stops at the cap',
          lp_bel("k_65e5", "read"), INFERRED_CAP);
    check_false('so it is never treated as known', lp_mastered("k_65e5"));

    ;;; One level only: inferring transitively would compound an
    ;;; inference that is already sometimes wrong.
    check('an inference does not infer again',
          lp_bel("hiragana_all", "read"), 0.0);

    ;;; And only a CHECK infers.  A self-report must not propagate.
    "inferrer2" -> lp_user;
    lp_record("w_tanjoubi", "read", 2, "right", 0);
    check('a reported result infers nothing', lp_bel("k_65e5", "read"), 0.0);

    ;;; Nor does a wrong answer, in either direction.
    "inferrer3" -> lp_user;
    lp_record("w_tanjoubi", "read", 1, "wrong", 900);
    check('a wrong answer infers nothing', lp_bel("k_65e5", "read"), 0.0);
else
    printf(';;; imported content not built -- inference not checked\n');
endif;

;;; The caps are the evidence policy and belong in one place.
check_true('inferred evidence cannot reach mastery', INFERRED_CAP < MASTERY);
check_true('and outranks a self-reported result', INFERRED_CAP < MASTERY
           and TIER2_CAP < MASTERY);

;;; ----------------------------------------------------- difficulty
;;; rank/3 is an ordinal difficulty proxy on a named scale.  Placement is
;;; what wants it: probing 103 kanji one at a time to find out whether
;;; somebody reads kanji is absurd, and four probes spread along a
;;; frequency rank locate them.
check('an item with no rank says so', lp_rank_of("hi_a", "freq"), false);
check('and so does an unknown scale', lp_rank_of("hi_a", "nonesuch"), false);

if lp_ilang("k_65e5") then
    check('KANJIDIC ranks 日 the commonest character',
          lp_rank_of("k_65e5", "freq"), 1);
    check('and puts it in the first school grade',
          lp_rank_of("k_65e5", "grade"), 1);
    check('with its stroke count', lp_rank_of("k_65e5", "strokes"), 4);
    check_true('a rarer character ranks higher',
               lp_rank_of("k_8033", "freq") > lp_rank_of("k_65e5", "freq"));
    ;;; the whole point: the scale orders the level
    lvars i, lo = false, hi = false;
    for i in lp_items do
        nextunless(lp_kind(i) == "grapheme" and lp_ilevel(i) == "n5");
        lvars r = lp_rank_of(i, "freq");
        nextunless(r);
        unless lo and lp_rank_of(lo, "freq") <= r then i -> lo endunless;
        unless hi and lp_rank_of(hi, "freq") >= r then i -> hi endunless;
    endfor;
    check_true('the level spans a wide range of the scale',
               lp_rank_of(hi, "freq") - lp_rank_of(lo, "freq") > 1000);
else
    printf(';;; imported content not built -- ranks not checked\n');
endif;

;;; -------------------------------------------------- probing the import
;;; The imported content is a build product, so a fresh checkout has no
;;; kanji items at all.  These run when it is there and say so when it is
;;; not; the invariant at the end of this section holds either way, and
;;; it is the one that would have caught the original bug.
if lp_ilang("k_65e5") then
    lvars (ksh, kpr, kans, kopt) = lp_question("k_65e5");
    check('an imported kanji can be asked', ksh, "type");
    check('the prompt is the character', kpr, '日');
    check_true('its kun reading answers', member('ひ', kans));
    check_true('and so does the romaji of it', member('hi', kans));
    check_true('and its on reading, folded to hiragana', member('にち', kans));
    check_true('and the romaji of that', member('nichi', kans));

    lvars (wsh, wpr, wans, wopt) = lp_question("w_tanjoubi");
    check('an imported word can be asked', wsh, "type");
    check('the prompt is the kanji, not the kana', wpr, '誕生日');
    check('the canonical answer is the kana', hd(wans), 'たんじょうび');
    check_true('romaji answers too', member('tanjoubi', wans));
    check_true('and so does the shorter spelling', member('tanjobi', wans));
else
    printf(';;; imported content not built -- import probes not checked\n');
endif;

;;; Two skills, two strictnesses, and the difference is deliberate: がっこう
;;; at pre-school is a reading-the-kana exercise so the う counts, while
;;; 学校 at N5 is a reading-the-kanji exercise where it does not.
lvars (psh, ppr, pans, popt) = lp_question("w_gakkou");
check('a starter word is prompted as kana', ppr, 'がっこう');
check('and accepts exactly one spelling', length(pans), 1);
check_false('so a skipped vowel is wrong there', member('gakko', pans));

;;; THE INVARIANT THE BUG BROKE.  Anything a student is expected to type
;;; must be askable; what is left over must be left over for a reason --
;;; a skill is a roll-up, a pattern is produced, a sound contrast needs
;;; audio.  A count would have gone stale; this says which kinds.
lvars i, wrong = [], sh0;
for i in lp_items do
    lp_question(i) -> (sh0, , , );
    nextunless(sh0 == "none");
    unless member(lp_kind(i), [skill pattern sound]) then
        wrong <> [^i] -> wrong
    endunless;
endfor;
check('every item that cannot be typed is a skill, a pattern or a sound',
      wrong, []);

;;; -------------------------------------------------------- the catalogue
lvars r = lp_resource_for("s_r_l");
check_true('the catalogue points at a resource', r and hd(r) == "r_minimal_rl");
check('and records when it was last checked',
      hd(tl(tl(tl(tl(tl(r)))))) sys_>< '', '2026-10-19');




;;; --------------------------------- characters that are not syllables
;;; kana/5 holds the kana that stand for a mora ON THEIR OWN.  It does
;;; not hold っ, ゃ, ゅ, ょ, the small vowels or ー -- and
;;; recognise(hiragana) is measured over kana/5, so a criterion named
;;; "recognise hiragana" has been quietly measuring "recognise the
;;; syllabary" since the file was written.
;;;
;;; They do not belong in the table: a gojuon grid has no cell for them,
;;; they have no reading of their own, and `type the romaji` cannot ask
;;; about ゃ because ゃ and や are both `ya`.  What was missing is the
;;; declaration -- and now the check.
check('ゃ is declared, and says which skill covers it',
      lp_modifier_of('ゃ'), "youon");
check('ょ too', lp_modifier_of('ょ'), "youon");
check('and the katakana twins', lp_modifier_of('ョ'), "youon");
check('っ is a beat of silence, so mora_sokuon covers it',
      lp_modifier_of('っ'), "mora_sokuon");
check('ー is a beat of the vowel before it',
      lp_modifier_of('ー'), "mora_long_vowel");

;;; Declared although nothing uses one yet, because the first katakana
;;; loanword with a ファ in it should not be the thing that breaks the
;;; check.
check('the small vowels are declared ahead of need',
      lp_modifier_of('ァ'), "youon");

;;; A full-size kana is not a modifier -- it is in the table.
check_false('や is not a modifier', lp_modifier_of('や'));
check_false('nor is あ', lp_modifier_of('あ'));
check_false('and neither is something that is not kana at all',
            lp_modifier_of('Z'));

;;; Not a character of the script at all: the blank in a sentence
;;; pattern.  form(p_kore_wa_desu, hiragana, 'これは___です') -- a
;;; pattern's form is a TEMPLATE and not a word, and the check reported
;;; its underscores as unknown kana, which is how this one was found.
check('the pattern placeholder is declared', lp_modifier_of('_'),
      "placeholder");

;;; Every character of every written form is either a kana the graph
;;; holds or a modifier it declares.
check('the graph is clean', lp_undeclared_kana(), []);

;;; And the check FIRES.  A test that only ever sees a clean graph is a
;;; test of nothing -- so put a character in a form that nothing teaches
;;; and nothing checks, and watch it come back.
;;; Prepended, not appended: lp_form_of returns the FIRST pair with a
;;; matching script, so a second hiragana form on the end is a form
;;; nothing ever reads -- which is how the first version of this test
;;; managed to inject a bad character and still see a clean graph.
[[% "hiragana", 'ゐねこ' %]] <> lp_forms("w_neko") -> lp_forms("w_neko");
lvars dirty = lp_undeclared_kana();
check('an undeclared kana is reported', length(dirty), 1);
check_true('and the report names the character',
           issubstring('ゐ', hd(dirty)) /== false);
check_true('and the item it is in',
           issubstring('w_neko', hd(dirty)) /== false);
lp_index();                             ;;; put the graph back
check('clean again', lp_undeclared_kana(), []);

;;; lp_check returns both: check(graph) proves the SHAPE of the graph and
;;; this proves the CONTENT of its forms.
check('and lp_check carries both', lp_check(), []);

;;; ------------------------------------------------------------ morae
;;; A mora is a unit of TIME, and --audit called skill(mora_count) and
;;; skill(mora_sokuon) `thin` over a set of one item -- あ -- which
;;; cannot demonstrate beat counting whatever a student does with it.
;;; The obvious reading was "timing needs audio".  It does not:
;;; PRODUCING correct timing needs a microphone, but KNOWING how many
;;; beats a word has is a reading question with a number for an answer.

;;; The two rules that make the question worth asking.  きょう looks like
;;; three characters and is two beats; きって looks like three and is
;;; three.  A student who gets both right has the thing the criterion is
;;; named for.
check('きょう is two beats, not three', lp_morae('きょう'), 2);
check('きって is three, not two', lp_morae('きって'), 3);
check('がっこう is four', lp_morae('がっこう'), 4);
check('ちょっと is three', lp_morae('ちょっと'), 3);
check('ほん is two, because ん is its own beat', lp_morae('ほん'), 2);
check('コーヒー is four, because ー is a beat', lp_morae('コーヒー'), 4);
check('みず is two', lp_morae('みず'), 2);
check('a single kana is one', lp_morae('あ'), 1);
check('and nothing is none', lp_morae(''), 0);

;;; Small ゃゅょ join the kana before them and add no beat.  Small っ is
;;; NOT one of them -- it is a beat, of silence, and that is the whole of
;;; skill(mora_sokuon).
check_true('small ゃ combines', lp_small_kana(16:3083));
check_true('and small ぃ', lp_small_kana(16:3043));
check_true('and their katakana twins', lp_small_kana(16:30E3));
check_false('small っ does not -- it is a beat', lp_small_kana(16:3063));
check_false('nor does a full-size や', lp_small_kana(16:3084));

;;; ---------------------------------------------- what exercises what
check_true('がっこう has a sokuon', lp_kana_feature('がっこう', "sokuon"));
check_false('みず does not', lp_kana_feature('みず', "sokuon"));
check_true('きょう has a youon', lp_kana_feature('きょう', "youon"));
check_false('きって does not', lp_kana_feature('きって', "youon"));
check_true('ほん has a moraic n', lp_kana_feature('ほん', "moraic_n"));
check_false('ひと does not', lp_kana_feature('ひと', "moraic_n"));

;;; The long-vowel test is the one that went wrong.  いえ is `ie`: two
;;; vowels, and two DIFFERENT ones -- い then え, two beats of two
;;; sounds, no length anywhere.  The first version took any adjacent
;;; pair and duly offered いえ as a long-vowel exercise.
check_false('いえ is not a long vowel', lp_kana_feature('いえ', "long_vowel"));
check_true('おおきい is', lp_kana_feature('おおきい', "long_vowel"));
check_true('and がっこう, spelled おう', lp_kana_feature('がっこう', "long_vowel"));
check_true('and せんせい, spelled えい', lp_kana_feature('せんせい', "long_vowel"));
check_true('and コーヒー, spelled with ー', lp_kana_feature('コーヒー', "long_vowel"));

;;; `any` is two beats or more, because "how many beats" asked of a
;;; one-beat word is not a question.
check_true('ひと is material', lp_kana_feature('ひと', "any"));
check_false('あ is not', lp_kana_feature('あ', "any"));

;;; -------------------------------------------------- the question
;;; A skill with a probe is measured over ITSELF: the answers accumulate
;;; against the skill and the material varies every time.  A skill
;;; without one is measured over what it rolls up over.
check_true('mora_count carries a probe', lp_probe_of("mora_count"));
check_false('dakuten does not -- reading the voiced kana IS the evidence',
            lp_probe_of("dakuten"));
;;; The criterion as a TERM, off the ladder.  lp_ask takes a Prolog
;;; term and not the word that prints like one, which is a distinction
;;; this suite has tripped over twice now.
define crit_named(name) -> c;
    lvars name, e, c = false;
    for e in lp_exits do
        if lp_term_str(hd(tl(tl(e)))) = name then
            hd(tl(tl(e))) -> c; return
        endif;
    endfor;
enddefine;

check('so mora_count is measured over itself',
      lp_ask(crit_named('skill(mora_count)'), "criterion_items", 1),
      [mora_count]);
check_true('while dakuten is measured over the voiced kana',
           length(lp_ask(crit_named('skill(dakuten)'),
                         "criterion_items", 1)) >= 46);

lvars (msh, mpr, man, mop) = lp_question("mora_count");
check('it can be asked', msh, "count");
check_true('with a word for a prompt', length(mpr) > 0);
check('and a number for an answer', length(man), 1);
check_true('which is the beats of that word',
           hd(man) = (lp_morae(mpr) sys_>< ''));
check_true('and the skill is drillable, which it never was before',
           lp_drillable("mora_count"));

;;; The material is drawn from the graph, so a content build that adds a
;;; thousand words adds a thousand questions.
check_true('there is material', length(lp_mora_material("mora_count")) > 20);
check_true('sokuon material is narrower',
           length(lp_mora_material("mora_sokuon"))
           < length(lp_mora_material("mora_count")));
check_true('and every piece of it has a sokuon in it',
           [% lvars i; for i in lp_mora_material("mora_sokuon") do
                  unless lp_kana_feature(lp_form_of(i, "hiragana"), "sokuon")
                  then i endunless endfor %] == []);

;;; At this level or below.  The question is about beats and not about
;;; meaning, but it is still asked in kana, and showing a pre-school
;;; student an N5 word is showing them characters they have not met.
check_true('nothing above the level is used as material',
           [% lvars i; for i in lp_mora_material("mora_count") do
                  unless lp_level_index(lp_ilevel(i)) <= 0 then i endunless;
              endfor %] == []);

;;; Rotated by how often the SKILL has been asked, so a student meets a
;;; different word each time and the tutor remembers nothing -- the
;;; journal already knows.
"morauser" -> lp_user; [] -> lp_journal;
lvars first = lp_mora_item("mora_count");
lp_record("mora_count", "read", 1, "right", 900);
check_true('the next asking uses different material',
           lp_mora_item("mora_count") /== first);

;;; ------------------------------------------------- what it unblocked
;;; One item, many questions.  Counting the item would call the
;;; criterion thin when it is not -- and the reverse matters more: when
;;; the material runs to one word, the criterion IS thin.
check('a kana is one question', lp_probe_breadth("hi_a"), 1);
check_true('a probed skill is as many as there is material',
           lp_probe_breadth("mora_count") > 20);

;;; ------------------------------------------------------- the audit
;;; --check proves the graph is CONSISTENT; it says nothing about
;;; whether the ladder can be climbed.  exit(ja, n1, kanji(2230, read))
;;; is perfectly consistent against 103 kanji and simply unreachable.
lvars arows = lp_audit();
check('one row per exit criterion', length(arows), length(lp_exits));

define arow(lang, level, name) -> r;
    lvars lang, level, name, e;
    false -> r;
    for e in arows do
        if e(1) == lang and e(2) == level
        and lp_term_str(e(3)) = name then e -> r; return endif;
    endfor;
enddefine;

;;; Every hiragana is askable, so the criterion over them is real.  The
;;; count is taken from the graph rather than written here: it was 46
;;; until the voiced kana arrived, and a literal would have made that a
;;; test failure rather than a fact.
lvars ah = arow("ja", "preschool", 'recognise(hiragana)');
check_true('hiragana is a criterion that exists', ah);
check('every hiragana in the set can be asked', ah(6), ah(5));
check_true('which is more than the 46 base kana', ah(5) > 46);
check('so it is reachable', ah(4), "ok");

;;; A skill is measured over WHAT IT ROLLS UP OVER, not over itself.
;;; Answering with the skill item gave a set of one unaskable thing, so
;;; three of the five Japanese pre-school criteria reported 0% over 0
;;; answers for ever and could not be met.  No row may say no_probe.
lvars ad = arow("ja", "preschool", 'skill(dakuten)');
check_true('the dakuten skill expands to something askable', ad(6) > 0);
check_false('and is no longer a criterion with no probe', ad(4) == "no_probe");

;;; mora_sokuon requires mora_count, which is itself a skill -- so one
;;; level of expansion would swap one unaskable item for another.
lvars asok = arow("ja", "preschool", 'skill(mora_sokuon)');
check_true('a skill of a skill expands all the way down', asok(6) > 0);

check_false('nothing anywhere is a criterion with no probe',
            [% lvars e; for e in arows do
                   if e(4) == "no_probe" then lp_term_str(e(3)) endif
               endfor %] /== []);

;;; The dakuten skill is now measured over every voiced kana rather than
;;; over か, which could not demonstrate the contrast it is named for.
check('dakuten is reachable', ad(4), "ok");
check_true('over every voiced pair, both scripts', ad(6) >= 46);

;;; Thin is not a bug and not an ok: it is a percentage over so few
;;; DISTINCT QUESTIONS that passing says very little.  skill(mora_count)
;;; was thin, over a set of one item -- あ -- that could not demonstrate
;;; beat counting at all; it now carries a generated probe and is asked
;;; about every word in the graph with two beats or more.
lvars amc = arow("ja", "preschool", 'skill(mora_count)');
check('a skill with a probe is one item', amc(5), 1);
check_true('and many questions', amc(6) > 20);
check('so it is reachable', amc(4), "ok");

;;; Which is the whole of what `thin` now counts: questions, not items.
;;; The reverse is what matters -- when the material runs to one word the
;;; criterion IS thin, and nothing else would say so.
check_true('a thin verdict needs few QUESTIONS, not few items',
           [% lvars e; for e in arows do
                  if e(4) == "thin" and e(6) >= AUDIT_THIN then e endif;
              endfor %] == []);

;;; A count criterion reports the shortfall rather than a percentage of
;;; a student who has never been shown the content.
lvars an1 = arow("ja", "n1", 'kanji(2230, read)');
check('N1 kanji is short, not failed', an1(4), "short");
check('and says how short', an1(7), 2230);
check_true('against what the graph actually holds', an1(6) < 2230);

;;; Counts are cumulative: kanji(2230) at N1 means every kanji through
;;; N1, so the pool is this level and below rather than this level only.
lvars a50 = arow("ja", "preschool", 'vocabulary(50, read)'),
      a800 = arow("ja", "n5", 'vocabulary(800, read)');
check_true('the N5 word pool includes the pre-school words',
           a800(6) >= a50(6));

;;; A listening criterion is not a failing reading criterion.  lp_question
;;; asks on the gate channel only, so a word's `hear` belief can never be
;;; moved by a probe -- which is the limit of the build, not of the
;;; student.
lvars ahear = arow("ja", "preschool", 'vocabulary(50, hear)');
check('a hear criterion needs audio', ahear(4), "needs_audio");
check('nothing on it can be asked', ahear(6), 0);
check_true('although the words are there', ahear(5) > 0);
check_true('probeable agrees', lp_probeable("w_neko", "read"));
check_false('and refuses the channel nothing can check',
            lp_probeable("w_neko", "hear"));

;;; The twelve sound contrasts are not a missing probe either -- the
;;; probe is not missing, the microphone is.  Reported as a bug the first
;;; time this ran, which was wrong.
lvars asc = arow("en", "preschool", 'sound_contrasts');
check('sound contrasts need audio', asc(4), "needs_audio");
check('all twelve are in the graph', asc(5), 12);

;;; coverage/2 has no measure at all, and says so rather than reporting a
;;; student at 0%.
lvars acov = arow("en", "b1", 'coverage(reading, 0.95)');
check('coverage is unmeasured', acov(4), "unmeasured");
check('with no item set', acov(5), 0);
check_false('and no target to be short of', acov(7));

;;; Every verdict is one of the six, so a client can switch on it.
check_false('no verdict is outside the set',
            [% lvars e; for e in arows do
                   unless member(e(4), [ok thin short no_probe needs_audio
                                        unmeasured])
                   then e(4) endunless
               endfor %] /== []);

;;; The audit must not disturb the globals it borrows: it walks every
;;; language and level, and a student is bound to one.
"ja" -> lp_lang; "preschool" -> lp_level;
lp_audit().erase;
check('the language survives the audit', lp_lang, "ja");
check('and the level', lp_level, "preschool");

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

;;; The switches survive the profile, and so does the log.  A setting a
;;; student had to remember to set again every session would be the one
;;; they stopped bothering with.
"switcher" -> lp_user;
[] -> lp_journal;
lp_aid_set("slip", false).erase;
lp_aid_set("oops", false).erase;
lp_save();
lp_aids_reset();
check_true('reset turns them back on', lp_aid("slip"));
check_true('loading the profile finds them', lp_load_profile("switcher"));
check_false('slip is still off', lp_aid("slip"));
check_false('and oops', lp_aid("oops"));
check_true('later was never touched', lp_aid("later"));
check('both changes came back', length(lp_aid_log), 2);

;;; A profile written before any of this existed has no aids_off field,
;;; and an absent field must not read as "all off" -- which is why the
;;; names are stored rather than a map of booleans.
lvars prof = lp_read_file(lp_profile_path("switcher"));
lp_write_file(lp_profile_path("switcher"),
    '{"user":"switcher","display":"Switcher","lang":"ja","level":"preschool"}');
check_true('an old profile loads', lp_load_profile("switcher"));
check_true('with every aid on', lp_aid("slip") and lp_aid("oops"));
check('and no change log', length(lp_aid_log), 0);
lp_write_file(lp_profile_path("switcher"), prof);

;;; Loading a student empties the queue: "it comes back in the same
;;; session" cannot mean the session before last.
lp_requeue("hi_a"); lp_later("hi_i");
lp_load_profile("switcher").erase;
check('a new student starts with an empty queue', length(lp_pending), 0);
check('and nothing put off', lp_later_n, 0);
lp_aids_reset();


"saver" -> lp_user;
'Saver' -> lp_display;
"en" -> lp_lang;
[] -> lp_journal;
[{% 1, "s_r_l", "r_minimal_rl", 1700000000000, 'open' %}] -> lp_assigns;
lp_record("s_r_l", "hear", 3, "right", 0);
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
