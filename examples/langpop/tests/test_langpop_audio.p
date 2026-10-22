;;; examples/langpop/tests/test_langpop_audio.p -- suite for audio.p.
;;;
;;;     ./poplog basepop11 examples/langpop/tests/test_langpop_audio.p </dev/null
;;;
;;; THE SUITE RUNS WITH NO MODEL INSTALLED, and that is the first thing
;;; it checks.  Kokoro is not a dependency of langpop; a voice is a
;;; command named in a config file, so the tutor has to work on a machine
;;; that has none -- which is every machine in CI and most machines a
;;; student has.  Half these checks are about the absent case.
;;;
;;; Where a voice IS wanted, the suite writes its own: `cp %i %o` is a
;;; perfectly good text-to-speech engine for testing everything except
;;; the sound, and the sound is the one thing a test cannot judge.  What
;;; can be tested is that the command was handed the text in a file, ran
;;; once per item, and did not run again for a cache hit.

uses poptest;
uses utf8;

vars langpop_lib = true, langpop_audio_lib = true;
load 'examples/langpop/langpop.p';
load 'examples/langpop/audio.p';

find_dir() -> langpop_dir;
lp_load();
lp_index();

;;; Audio goes to a temp dir, never a real person's home.
lvars tmpdir = '/tmp/langpop-audio-test-' sys_>< sys_real_time() sys_>< '/';
sysobey('mkdir -p ' <> tmpdir);
tmpdir -> lp_home_dir;

define has(needle, hay);
    lvars needle, hay;
    issubstring(needle, hay) /== false;
enddefine;

;;; -------------------------------------------------- with no voice at all
;;; Nothing is configured yet, so this is the state every fresh checkout
;;; is in.
lp_voices_load();
check_true('no voice is configured', not(lp_audio_ready("ja")));
check_true('nor for English', not(lp_audio_ready("en")));

lvars path, made, why;
lp_audio_name("hi_a", false) -> (path, why);
check('a name needs a voice to name the file after', why, 'no_voice');
lp_audio_path("hi_a", false) -> (path, why);
check('and so does a lookup', why, 'no_voice');
lp_audio_make("hi_a", false) -> (path, made, why);
check('making one says so plainly', why, 'no_voice');
check_true('and writes nothing', not(sys_file_exists(tmpdir <> 'audio')));

;;; ------------------------------------------------- what there is to say
;;; This half needs no voice: it is a question about the graph.
lvars text;
lp_audio_text("hi_a") -> (text, why);
check('a kana is said as its glyph', text, 'あ');
check_true('the form comes back as a STRING, not a word',
           isstring(text));

lp_audio_text("w_gakkou") -> (text, why);
check('a word is said as its kana', text, 'がっこう');

;;; Romaji is not Japanese text.  A voice handed `gakkou` reads English.
check_true('romaji exists on that item but is not what is said',
           lp_form_of("w_gakkou", "romaji") /== false);

;;; A pattern's form has a hole in it, and a voice would read the hole.
lp_audio_text("p_kore_wa_desu") -> (text, why);
check('a pattern with a blank is not said', why, 'has_blank');
check_true('and nothing is handed back to say', text == false);

;;; A skill is an abstraction; there is no utterance for `mora_count`.
lp_audio_text("mora_count") -> (text, why);
check('a skill has no spoken form', why, 'no_spoken_form');

lp_audio_text("no_such_thing_at_all") -> (text, why);
check('an unknown item is unknown', why, 'no_such_item');

;;; A sound contrast carries IPA and no word.  /l/ is a sound, not
;;; something a voice can be asked to pronounce on its own -- it is heard
;;; through the words that exercise it, which the graph already links.
lvars ipa_only = false, i;
for i in lp_items do
    if lp_ilang(i) == "en" and lp_form_of(i, "ipa")
       and not(lp_form_of(i, "latin")) then
        i -> ipa_only; quitloop;
    endif;
endfor;
if ipa_only then
    lp_audio_text(ipa_only) -> (text, why);
    check('IPA is a notation and is never read aloud', why, 'no_spoken_form');
endif;

;;; ------------------------------------------------------------- the key
;;; Same text, same voice, same model -> same name, or the cache never
;;; hits.  Change any one of the three and the name has to move, or the
;;; student hears the old reading of a corrected word.
define conf(cmd, voice, model);
    lvars cmd, voice, model;
    lp_write_file(lp_audio_conf_path(),
        '{"ja": {"cmd": "' <> cmd <> '", "voice": "' <> voice
        <> '", "model": "' <> model <> '"},'
        <> ' "en": {"cmd": "' <> cmd <> '", "voice": "' <> voice
        <> '", "model": "' <> model <> '"}}');
    lp_voices_load();
enddefine;

;;; The same, with rates declared.  Two configs rather than one argument
;;; because the point of several checks below is a voice that has NO rate
;;; control -- which is a config with no `rates` key, not an empty one.
define conf_rates(cmd, voice, model, rates);
    lvars cmd, voice, model, rates;
    lp_write_file(lp_audio_conf_path(),
        '{"ja": {"cmd": "' <> cmd <> '", "voice": "' <> voice
        <> '", "model": "' <> model <> '", "rates": ' <> rates <> '},'
        <> ' "en": {"cmd": "' <> cmd <> '", "voice": "' <> voice
        <> '", "model": "' <> model <> '", "rates": ' <> rates <> '}}');
    lp_voices_load();
enddefine;

lvars callfile = tmpdir <> 'calls';
lvars stub = 'echo x >> ' <> callfile <> '; cp %i %o';

conf(stub, 'jf_alpha', 'stub-1');
check_true('a voice is configured now', lp_audio_ready("ja"));

lvars n1, n2, n3, n4;
lp_audio_name("hi_a", false) -> (n1, why);
check_true('a name is produced', why == false);
lp_audio_name("hi_a", false) -> (n2, why);
check('the same question gives the same name', n2, n1);
check_true('the voice is in the name, so two voices do not collide',
           has('jf_alpha', n1));
check_true('and the language is in the path', has('/ja/', n1));

conf(stub, 'jf_beta', 'stub-1');
lp_audio_name("hi_a", false) -> (n3, why);
check_true('a different voice is a different file', n3 /= n1);

conf(stub, 'jf_alpha', 'stub-2');
lp_audio_name("hi_a", false) -> (n4, why);
check_true('a different model is a different file', n4 /= n1);
check_true('even with the voice unchanged', has('jf_alpha', n4));

;;; The text is the fourth part of the key, and it is the one that moves
;;; when a curator corrects a form.  Two items with different text must
;;; not land on one file.
conf(stub, 'jf_alpha', 'stub-1');
lvars na, ni;
lp_audio_name("hi_a", false) -> (na, why);
lp_audio_name("hi_i", false) -> (ni, why);
check_true('two items are two files', na /= ni);

;;; ------------------------------------------------------- rendering once
lp_audio_path("hi_a", false) -> (path, why);
check('nothing is cached yet', why, 'not_generated');
check_true('and asking did NOT run the voice',
           lp_read_file(callfile) == false);

lp_audio_make("hi_a", false) -> (path, made, why);
check_true('rendering succeeds', why == false);
check_true('and says it rendered', made);
check_true('the file is on disk', sys_file_exists(path));
check_true('with bytes in it', sysfilesize(path) > 0);
check('the voice ran exactly once', length(lp_read_file(callfile)), 2);

;;; The text reached the command THROUGH A FILE.  The stub copies that
;;; file to the output, so the output is the text -- which is how this
;;; suite knows the kana arrived intact rather than as whatever the shell
;;; made of them.
check('the text arrived as bytes, unmangled', lp_read_file(path), 'あ');

lp_audio_make("hi_a", false) -> (path, made, why);
check_true('a second ask is not a second render', not(made));
check_true('and no error', why == false);
check('the voice still ran only once', length(lp_read_file(callfile)), 2);

lp_audio_path("hi_a", false) -> (path, why);
check_true('and now the lookup finds it', why == false);

;;; The scratch file holding the text is not left behind: a cache
;;; directory full of .wav.txt is clutter in somebody's home.
check_true('the text file is cleaned up',
           not(sys_file_exists(path <> '.txt')));

;;; ---------------------------------------------------------- provenance
;;; A sidecar per file, so a cached wav can always answer what made it.
lvars side = lp_read_file(substring(1, length(path) - 4, path) <> '.json'),
     prov = json_parse(side);
check_true('a sidecar is written', side /== false);
check('it names the item', prov('item'), 'hi_a');
check('the text that was said', prov('text'), 'あ');
check('the voice', prov('voice'), 'jf_alpha');
check('and the model, which the engine cannot detect and so records',
      prov('model'), 'stub-1');
check_true('and the command, so a bad render can be reproduced',
           has('cp %i %o', prov('command')));

;;; ---------------------------------------------------------- a whole level
;;; Ahead of time: the reason --audio exists.
lvars m, c, sk;
lp_audio_level("preschool", false) -> (m, c, sk);
check_true('most of the level renders', m > 100);
check('and the one already cached is counted as cached', c, 1);
check_true('and the rest is reported, not silently dropped', length(sk) > 0);

;;; Everything skipped is skipped for a NAMED reason, and the reasons are
;;; the ones above -- a skill or a blank, never a failure.
lvars e, reasons = [];
for e in sk do
    unless member(hd(tl(e)), reasons) then
        conspair(hd(tl(e)), reasons) -> reasons;
    endunless;
endfor;
lvars odd = false, r;
for r in reasons do
    unless r == "no_spoken_form" or r == "has_blank" then true -> odd endunless;
endfor;
check_true('reasons were given at all', reasons /== []);
check_true('and the only reasons are the graph\'s own', not(odd));

lp_audio_level("preschool", false) -> (m, c, sk);
check('a second pass renders nothing', m, 0);
check_true('because it is all cached', c > 100);

;;; ------------------------------------------------- the listening page
;;; The one part of Stage 0 that is not wiring is a judgement, and a
;;; judgement wants every file on one page.
lvars page, pwhy;
lp_audio_index("preschool") -> (page, pwhy);
check_true('the page is written', pwhy == false);
lvars html = lp_read_file(page);
check_true('it is a document', has('<!doctype html>', html));
check_true('with a charset, because the labels are Japanese',
           has('<meta charset="utf-8">', html));
check_true('a glyph reaches the page', has('あ', html));
check_true('and an audio element to play it', has('<audio controls', html));
;;; A relative src, because the page sits in the directory the wavs are
;;; in.  An absolute path works until the directory moves.
check_true('the src is a bare filename, not a path',
           not(has('src="/', html)));
check_true('the voice and model are named on the page, since that is '
           <> 'what is being judged',
           has('jf_alpha', html) and has('stub-1', html));

;;; ------------------------------------------------------- a broken voice
;;; A command can exit 0 and write nothing.  That is not a render, and a
;;; student must not be handed a zero-byte file as though it were a word.
conf('true', 'jf_alpha', 'stub-3');
lp_audio_make("hi_u", false) -> (path, made, why);
check('a voice that writes nothing is a failure', why, 'voice_failed');
check_true('and no path is offered', path == false);

;;; A command that does not exist is the same answer, not a crash.
conf('nosuchcommand-langpop', 'jf_alpha', 'stub-4');
lp_audio_make("hi_u", false) -> (path, made, why);
check('a voice that is not installed is the same answer', why, 'voice_failed');

;;; ------------------------------------------------------------- the rate
;;; A learner asks for slower, not for 0.7.  The engine's scale lives in
;;; the engine's config and langpop uses the three names.

;;; A voice with no rate control at all -- which is most of the ways a
;;; command can be wired up, and the state the checks above ran in.
conf(stub, 'jf_alpha', 'stub-1');
check('a voice with no rates offers exactly one',
      lp_audio_rates("ja"), [normal]);
lp_audio_make("hi_a", "slow") -> (path, made, why);
check('and does not pretend to go slow', why, 'no_such_rate');
check_true('nothing is written for a rate that does not exist',
           path == false);

lvars val, ok;
lp_audio_rate_value("ja", "normal") -> (val, ok);
check_true('normal is a rate it does have', ok);
check_true('with nothing to substitute, which is the point', val == false);

;;; Declared out of order on purpose: the config is an object and
;;; json_parse gives a property, so declaration order is not preserved.
;;; The order the student is offered has to come from us.
conf_rates(stub, 'jf_alpha', 'stub-1',
           '{"fast": "1.3", "slow": "0.7", "normal": "1.0"}');
check('the rates are offered slowest first, not in config order',
      lp_audio_rates("ja"), [slow normal fast]);

;;; A name outside the three is dropped rather than honoured: see the
;;; header of audio.p.  A dial is not what a tutor needs.
conf_rates(stub, 'jf_alpha', 'stub-1',
           '{"slow": "0.7", "glacial": "0.2"}');
check('an unrecognised name is not offered',
      lp_audio_rates("ja"), [slow normal]);
check_true('and normal is supplied even when the config forgot it',
           member("normal", lp_audio_rates("ja")) /== false);
lp_audio_rate_value("ja", "normal") -> (val, ok);
check_true('as a rate with no value, so the command is left alone',
           ok and val == false);

;;; --------------------------------------------- the rate is part of the key
conf_rates(stub, 'jf_alpha', 'stub-1',
           '{"slow": "0.7", "normal": "1.0", "fast": "1.3"}');
lvars slowp, normp, fastp;
lp_audio_name("hi_a", "slow") -> (slowp, why);
lp_audio_name("hi_a", "normal") -> (normp, why);
lp_audio_name("hi_a", "fast") -> (fastp, why);
check_true('three rates are three files', slowp /= normp and normp /= fastp);
check_true('and the rate is in the name, so a directory can be read',
           has('-slow-', slowp) and has('-normal-', normp));

;;; The VALUE goes through the hash: a config that redefines slow from
;;; 0.7 to 0.8 has to invalidate what 0.7 produced, or the student goes
;;; on hearing the old speed under the new name.
lvars slow07 = slowp;
conf_rates(stub, 'jf_alpha', 'stub-1',
           '{"slow": "0.8", "normal": "1.0", "fast": "1.3"}');
lp_audio_name("hi_a", "slow") -> (slowp, why);
check_true('redefining a rate invalidates its cache', slowp /= slow07);
check_true('and the name still says slow', has('-slow-', slowp));

;;; ------------------------------------------------- %r reaches the command
lvars ratefile = tmpdir <> 'rates';
conf_rates('echo %r >> ' <> ratefile <> '; cp %i %o',
           'jf_alpha', 'stub-1',
           '{"slow": "0.7", "normal": "1.0", "fast": "1.3"}');
lp_audio_make("hi_ka", "slow") -> (path, made, why);
check_true('a slow render succeeds', why == false and made);
check_true('the engine was handed ITS number, not our name',
           has('0.7', lp_read_file(ratefile)));
check_true('and not the name we call it by',
           not(has('slow', lp_read_file(ratefile))));

lp_audio_make("hi_ka", "fast") -> (path, made, why);
check_true('and a fast one is a separate render', made);
check_true('with the other number',
           has('1.3', lp_read_file(ratefile)));

;;; --------------------------------------------------- the student's rate
;;; `false` means "whatever they are listening at", which is what every
;;; call that does not care about rate passes.
"slow" -> lp_rate;
lvars deflt;
lp_audio_name("hi_a", false) -> (deflt, why);
lp_audio_name("hi_a", "slow") -> (slowp, why);
check('a false rate is the student\'s rate', deflt, slowp);
"normal" -> lp_rate;
lp_audio_name("hi_a", false) -> (deflt, why);
check_true('and it moves when they change it', deflt /= slowp);

;;; ------------------------------------------- rhythm is not rate-neutral
;;; Japanese length is contrastive: きて and きって differ by a beat of
;;; silence.  Every engine stretches those durations under a rate change
;;; and none promises to stretch a closure by the same factor as the
;;; vowel beside it -- so the tutor says which items that applies to.
check_true('a geminate carries contrastive length',
           lp_audio_timing("w_gakkou"));
check_true('and a plain kana does not', not(lp_audio_timing("hi_a")));

lvars long_v = false, moraic = false;
for i in lp_items do
    nextunless(lp_ilang(i) == "ja");
    if not(long_v) and issubstring('ー', lp_form_of(i, "katakana") sys_>< '')
    then i -> long_v endif;
    if not(moraic) and issubstring('ん', lp_form_of(i, "hiragana") sys_>< '')
    then i -> moraic endif;
endfor;
if long_v then
    check_true('a long vowel mark counts too', lp_audio_timing(long_v));
endif;
if moraic then
    check_true('and a moraic n', lp_audio_timing(moraic));
endif;

;;; A skill has no text, so the question does not arise -- and must not
;;; raise either.
check_true('an item with nothing to say is not timing sensitive',
           not(lp_audio_timing("mora_count")));

;;; ---------------------------------------- provenance records the rate
lp_audio_make("w_gakkou", "slow") -> (path, made, why);
check_true('a word renders slow', why == false);
lvars side2 = lp_read_file(substring(1, length(path) - 4, path) <> '.json'),
     prov2 = json_parse(side2);
check('the sidecar names the rate', prov2('rate'), 'slow');
check('and the number the engine was given', prov2('rate_value'), '0.7');
check_true('and that this one is timing sensitive, which is why it matters',
           prov2('timing_sensitive'));

;;; ------------------------------------------- the page gets a column each
;;; One column per rate something was rendered at -- not per rate the
;;; config declares, because an empty `fast` column reads as a voice that
;;; cannot go fast.
lp_audio_level("preschool", "normal") -> (m, c, sk);
lp_audio_index("preschool") -> (page, pwhy);
check_true('the page is written', pwhy == false);
lp_read_file(page) -> html;
check_true('with a column for the rate that was rendered',
           has('<th>normal</th>', html));
;;; `fast` is here because ONE item was rendered fast above, which is the
;;; rule working rather than a stray: a column appears when anything has
;;; that rate, and the items that do not get an empty cell rather than a
;;; missing column or a broken player.
check_true('a rate one item has gives a column', has('<th>fast</th>', html));
check_true('and an item without it has an empty cell there',
           has('</audio></td><td></td>', html));
check_true('the timing mark is on the page, with its explanation',
           has('&#9834;', html) and has('contrastive length', html));

lp_audio_level("preschool", "slow") -> (m, c, sk);
lp_audio_index("preschool") -> (page, pwhy);
lp_read_file(page) -> html;
check_true('now there are two columns',
           has('<th>slow</th>', html) and has('<th>normal</th>', html));

;;; ------------------------------------------------ the listening question
;;; Stage 0.5.  `hear` was parked behind a microphone with `produce`,
;;; when hearing needs a SPEAKER: play the word, the student types what
;;; they heard, and the grading is exact match exactly as it is for
;;; reading.  These checks are mostly about the conditions, because
;;; getting those wrong is how a tutor comes to ask a question it cannot
;;; play or score a channel it cannot test.

;;; --- with no voice, nothing has changed about anything
lp_write_file(lp_audio_conf_path(), '{}');
lp_voices_load();
check_true('with no voice, hearing is not verifiable',
           not(lp_verifiable("hear")));
check_true('and lp_can_hear says so', not(lp_can_hear()));
lvars hsh, hpr, hans, hopt;
lp_question("w_neko", "hear") -> (hsh, hpr, hans, hopt);
check('no voice, no listening question', hsh, "none");
check_true('and the pool is empty', lp_hear_plan() == []);
check_true('so the audit still reports needs_audio, not a score of zero',
           not(lp_probeable("w_neko", "hear")));

;;; Reading is untouched by all of this, which is the property that
;;; matters most: installing or not installing a voice must not change
;;; what a reading question is.
lp_question("w_neko", "read") -> (hsh, hpr, hans, hopt);
check('a reading question is unaffected', hsh, "type");

;;; --- a voice, but nothing rendered yet
;;; An n5 word, because every pre-school word was rendered by the level
;;; pass above -- and an item nobody has rendered is exactly the case
;;; this pair of checks is about.
lvars unsaid = false, ui;
for ui in lp_items do
    if lp_ilang(ui) == "ja" and lp_kind(ui) == "word"
    and lp_ilevel(ui) == "n5" then ui -> unsaid; quitloop endif;
endfor;
check_true('there is an n5 word to test with', unsaid /== false);

conf_rates('cp %i %o', 'jf_alpha', 'stub-1',
           '{"slow": "0.7", "normal": "1.0"}');
check_true('a voice makes hearing verifiable in principle',
           lp_verifiable("hear"));
lp_question(unsaid, "hear") -> (hsh, hpr, hans, hopt);
check('but an unrendered item cannot be asked', hsh, "none");
lvars upath, uwhy;
lp_audio_path(unsaid, "normal") -> (upath, uwhy);
check('because nothing is cached, and asking must never synthesise',
      uwhy, 'not_generated');

;;; --- rendered at the normal rate
lp_audio_make("w_neko", "normal") -> (path, made, why);
check_true('the word renders', why == false);
lp_question("w_neko", "hear") -> (hsh, hpr, hans, hopt);
check('now it is a listening question', hsh, "listen");
check('and the prompt is the SOUND, not the glyph', hpr, path);
check_true('the glyph is nowhere in the prompt',
           not(has('ねこ', hpr)));

;;; The answer key is the reading question's, unchanged.  That is the
;;; whole design: one stimulus swapped, nothing else.
lvars rsh, rpr, rans, ropt;
lp_question("w_neko", "read") -> (rsh, rpr, rans, ropt);
check('the answer key is the reading question\'s', hans, rans);
check_true('which is the romaji', member('neko', hans));

;;; --- rate: a listening question is asked at the normal rate only
lp_audio_make(unsaid, "slow") -> (path, made, why);
check_true('a slow render succeeds', why == false);
lp_question(unsaid, "hear") -> (hsh, hpr, hans, hopt);
check('slow audio alone does not make a listening question', hsh, "none");
check_true('because a slowed voice is an easier exposure, and for the '
           <> 'geminates a rhythm the language does not have',
           lp_audio_timing("w_gakkou"));
lp_audio_make(unsaid, "normal") -> (path, made, why);
lp_question(unsaid, "hear") -> (hsh, hpr, hans, hopt);
check('at normal rate it can be asked', hsh, "listen");

;;; --- the pool: words already read-mastered, not yet heard
"hearer" -> lp_user;
check_true('a word not yet read is not in the listening pool',
           member("w_neko", lp_hear_plan()) == false);
MASTERY -> lp_beliefs(lp_bkey(lp_user, "w_neko", "read"));
check_true('once read, it is', member("w_neko", lp_hear_plan()) /== false);
MASTERY -> lp_beliefs(lp_bkey(lp_user, "w_neko", "hear"));
check_true('once heard, it leaves', member("w_neko", lp_hear_plan()) == false);
0.0 -> lp_beliefs(lp_bkey(lp_user, "w_neko", "hear"));

;;; A kana is not in it at all: a grapheme is read, not heard.
check_true('a grapheme has no hear channel',
           member("hear", lp_channels("hi_a")) == false);
check_true('so it is never in the pool',
           member("hi_a", lp_hear_plan()) == false);

;;; --- the audit can measure it now
check_true('a rendered, read-mastered word is probeable on hear',
           lp_probeable("w_neko", "hear"));

;;; --- a contrast still cannot be asked, and MUST NOT lock the ladder
;;; The twelve English contrasts are sound items whose gate channel is
;;; `hear`.  Making `hear` verifiable took away the exemption that kept
;;; them from locking everything built on them -- which is the defect
;;; 570849c fixed, and this is the check that it stays fixed.
lvars encfg = lp_read_file(lp_audio_conf_path());
lp_write_file(lp_audio_conf_path(),
    '{"en": {"cmd": "cp %i %o", "voice": "af", "model": "stub-1"}}');
lp_voices_load();
"en" -> lp_lang;
check_true('with an English voice, hearing is verifiable', lp_can_hear());
lp_question("s_r_l", "hear") -> (hsh, hpr, hans, hopt);
check('a contrast with no audio rendered cannot be asked', hsh, "none");
check_true('so nothing can gate on it yet', lp_ungateable("s_r_l"));
check_true('and the English rung still has something ready',
           lp_plan() /== []);

;;; ------------------------------------------------ the confusion pairs
;;; WHICH WORD DID YOU HEAR.  A contrast has no written form -- it is not
;;; a word -- so there was nothing for the listening question to swap the
;;; stimulus of, and all twelve were reported needs_audio.  It was never
;;; the microphone that was missing; it was a pair.
check('four pairs separate /r/ from /l/',
      length(lp_pairs_of("s_r_l")), 4);
check('and they are words, not ids',
      hd(lp_pairs_of("s_r_l")), [right light]);
check('a contrast with no pair has none', lp_pairs_of("s_final"), []);
check('breadth is one question per pair', lp_probe_breadth("s_r_l"), 4);

;;; Render the pair words.  They are NOT items, which is the whole
;;; reason lp_audio_make_of exists: making them items to get them spoken
;;; would have inflated every English vocabulary criterion with words
;;; whose only job is a drill.
define say_pairs(c);
    lvars c, pr, w;
    for pr in lp_pairs_of(c) do
        for w in pr do
            lp_audio_make_of(lp_pair_word_name(w), w, "en", "normal", false)
                -> (, , );
        endfor;
    endfor;
enddefine;
say_pairs("s_r_l");

lp_question("s_r_l", "hear") -> (hsh, hpr, hans, hopt);
check('now a contrast can be asked', hsh, "listen_pick");
check('with two words to choose between', length(hopt), 2);
check_true('and a sound to judge', sys_file_exists(hpr));

;;; THE ANSWER MUST POINT AT THE WORD THAT WAS PLAYED.  The path carries
;;; the slug of the word in it, so this can be checked from the outside
;;; rather than by trusting the builder -- and an off-by-one here would
;;; mark every right answer wrong.
define played_is_answer(sh, pr, ans, opt) -> ok;
    lvars sh, pr, ans, opt, said = opt(strnumber(hd(ans)));
    has(lp_audio_slug(said sys_>< ''), pr) -> ok;
enddefine;
check_true('the answer is the word that was played',
           played_is_answer(hsh, hpr, hans, hopt));

;;; Both the word played and the position it is offered in turn over.
;;; Otherwise the answer is always 1, or always the first word of the
;;; pair, and the student learns the pattern instead of the contrast.
;;; Answers are recorded between builds, because that is what advances
;;; lp_asked and so the rotation -- eight builds in a row with nothing
;;; answered is the same question eight times, which is correct and
;;; tests nothing.
lvars saids = [], answers = [], pairs_seen = [], k;
"rotator" -> lp_user;
for k from 1 to 8 do
    lp_question("s_r_l", "hear") -> (hsh, hpr, hans, hopt);
    check_true('every rotation is internally consistent',
               played_is_answer(hsh, hpr, hans, hopt));
    unless member(hd(hans), answers) then
        answers <> [% hd(hans) %] -> answers;
    endunless;
    lvars w2;
    for w2 in hopt do
        if has(lp_audio_slug(w2 sys_>< ''), hpr)
        and not(member(w2, saids)) then saids <> [^w2] -> saids endif;
    endfor;
    unless member(sort([% explode(hopt) %]), pairs_seen) then
        pairs_seen <> [% sort([% explode(hopt) %]) %] -> pairs_seen;
    endunless;
    lp_record("s_r_l", "hear", 1, "right", 1000);
endfor;
check('all four pairs come round in eight questions',
      length(pairs_seen), 4);
check_true('the answer is not always the same option',
           length(answers) == 2);
check_true('and both sides of a pair get played across two cycles',
           length(saids) >= 5);

;;; One file per word, shared between the contrasts that use it: `berry`
;;; separates /r/-/l/ from belly and /v/-/b/ from very.
lvars bp1, bp2, bw;
lp_pair_audio('berry', "normal") -> (bp1, bw);
check_true('a shared word renders once', bw == false);
lp_pair_audio('berry', "normal") -> (bp2, bw);
check('and is one file for both contrasts', bp2, bp1);

;;; The audit can measure the family now, and says which part of it it
;;; cannot reach: four contrasts have no pair.
check_true('a contrast with a pair is probeable', lp_probeable("s_r_l", "hear"));
check_true('one without is not', not(lp_probeable("s_final", "hear")));

;;; AND THE GATE.  s_th_v requires s_th_un, and with pairs that edge is
;;; a real gate for the first time -- which is what `requires` means.
;;; The contrasts that still have no pair must stay exempt, or they lock
;;; everything built on them all over again.
say_pairs("s_th_un");
check_true('a contrast that can be asked is gateable now',
           not(lp_ungateable("s_th_un")));
check_true('and one that cannot is still exempt',
           lp_ungateable("s_final"));
check_true('so the rung still has something ready', lp_plan() /== []);

;;; An English trap is a pick question, and listening keeps it one.
lp_audio_make("t_mansion", "normal") -> (path, made, why);
check_true('an English word renders', why == false);
lp_question("t_mansion", "hear") -> (hsh, hpr, hans, hopt);
check('a pick question heard is still a pick', hsh, "listen_pick");
check_true('with its options intact', length(hopt) == 2);
;;; NOT the same answer as a second call: a pick question flips its
;;; options every time it is built, so the answer is 1 or 2 by turns.
;;; (Which also means lp_drillable_on advances that flip, as
;;; lp_drillable always did.)  What has to hold is that the listening
;;; question is internally consistent.
check_true('the answer is one of the two options it offered',
           member(hd(hans), ['1' '2']) /== false);
check_true('and the gloss pair is what it offers',
           member(lp_gloss_of("t_mansion", "en") sys_>< '',
                  [% lvars oo; for oo in hopt do oo sys_>< '' endfor %])
           /== false);
"ja" -> lp_lang;
lp_write_file(lp_audio_conf_path(), encfg);
lp_voices_load();

;;; --- the queue remembers the channel
;;; Without this a listening question put off came back as a reading
;;; question, so the belief the student was working on never moved.
lp_queue_reset();
lp_later_on("w_neko", "hear");
check('one waiting', length(lp_pending), 1);
check('and it is waiting on hear', lp_due_ch("w_neko"), "hear");
lp_queue_reset();
lp_requeue("w_neko");
check('a plain requeue is the gate channel', lp_due_ch("w_neko"), "read");
lp_queue_reset();

;;; --- the interleave is one rule, shared with the protocol
check('one question in four is by ear', lp_hear_every(), 4);

;;; ------------------------------------------------------- the microphone
;;; Stage A: the seam, with no model behind it.  The recorder and the
;;; scorer are commands named in the config, on exactly the terms the
;;; voice is on -- so the first thing to check is that their absence is
;;; an answer and not a crash.
conf_rates('cp %i %o', 'jf_alpha', 'stub-1', '{"normal": "1.0"}');
check_true('no recorder and no scorer means no speaking',
           not(lp_can_speak()));
lvars spath, swhy;
lp_audio_capture("w_kitte") -> (spath, swhy);
check('and recording says so plainly', swhy, 'no_recorder');
lvars o2, c2, d2, w2;
lp_pronounced("w_kitte", false, "sokuon", 3) -> (o2, c2, d2, w2);
check('as does scoring', w2, 'no_scorer');

;;; --- which geminates can be timed at all
;;; っ before し is a lengthened [ʃ] with energy all the way through, so
;;; there is no gap and no threshold that finds one.  The graph knows
;;; the following kana, so the tutor declines to ASK.
check_true('a geminate stop can be timed', lp_sokuon_detectable("w_kitte"));
check_true('and so can a geminate p', lp_sokuon_detectable("w_ippai"));
check_true('a geminate fricative cannot',
           not(lp_sokuon_detectable("w_issho")));
check_true('and a word with no geminate has nothing to time',
           not(lp_sokuon_detectable("w_neko")));

;;; --- a wav this suite makes itself
;;; Sixteen-bit mono PCM, written byte by byte, so the threshold has a
;;; regression guard that needs no recording, no voice and no fixture
;;; checked into the repo.  A Pop-11 string holds bytes, which is the
;;; only reason this is possible.
define wav_le(n, bytes) -> s;
    lvars n, bytes, s = '', i;
    for i from 1 to bytes do
        s <> consstring(n mod 256, 1) -> s;
        n div 256 -> n;
    endfor;
enddefine;

;;; segs is [[ms amplitude] ...]: amplitude 0 is silence.
define wav_write(path, rate, segs);
    lvars path, rate, segs, seg, data = '', n, i, amp, hi, lo;
    dlocal pop_file_versions = false;
    for seg in segs do
        hd(tl(seg)) -> amp;
        (rate * hd(seg)) div 1000 -> n;
        ;;; A square wave at a quarter the sample rate: RMS is the
        ;;; amplitude, which is all the envelope looks at.
        for i from 1 to n do
            ;;; wav_le(0, 2) and NOT '\s\s': \s is a SPACE, 0x20, so a
            ;;; "silence" written that way came out at amplitude 8224 --
            ;;; as loud as the tone beside it -- and the scorer correctly
            ;;; found no gap in a file that had none.
            if amp == 0 then wav_le(0, 2) -> lo
            elseif i mod 4 < 2 then wav_le(amp, 2) -> lo
            else wav_le(65536 - amp, 2) -> lo
            endif;
            data <> lo -> data;
        endfor;
    endfor;
    'RIFF' <> wav_le(36 + length(data), 4) <> 'WAVEfmt ' <> wav_le(16, 4)
      <> wav_le(1, 2) <> wav_le(1, 2) <> wav_le(rate, 4)
      <> wav_le(rate * 2, 4) <> wav_le(2, 2) <> wav_le(16, 2)
      <> 'data' <> wav_le(length(data), 4) <> data -> data;
    lp_write_file(path, data);
enddefine;

;;; A three-mora word at 130ms a mora, with a 200ms held beat in the
;;; middle: き っ て, which is the shape きって has.
lvars held = tmpdir <> 'held.wav', flat = tmpdir <> 'flat.wav';
wav_write(held, 16000, [[130 8000] [200 0] [130 8000]]);
;;; The same word with the beat left out, which is what a learner who
;;; says きて instead of きって produces.
wav_write(flat, 16000, [[130 8000] [60 0] [130 8000]]);
check_true('the suite wrote a wav', sysfilesize(held) > 1000);

;;; The real scorer, as a command, exactly as the engine runs it.
lp_write_file(lp_audio_conf_path(),
    '{"ja": {"cmd": "cp %i %o", "voice": "v", "model": "m"},'
    <> ' "record":  {"cmd": "cp ' <> held <> ' %o", "seconds": "3"},'
    <> ' "verdict": {"cmd": "python3 -I ' <> langpop_dir
    <> 'tools/score-morae.py --request %q --out %v"}}');
lp_voices_load();
check_true('a recorder and a scorer means speaking is possible',
           lp_can_speak());

lp_audio_capture("w_kitte") -> (spath, swhy);
check_true('the recorder produced a sample', swhy == false);
check_true('and it is on disk', sys_file_exists(spath));

lp_pronounced("w_kitte", spath, "sokuon", 3) -> (o2, c2, d2, w2);
check_true('the scorer answered', w2 == false);
check('and heard the held beat', o2, "right");
check_true('with a reason a learner can act on',
           has('silence', d2) and has('mora', d2));
check_true('and a confidence', c2 > 0.0);

;;; The same question, a recording with no held beat in it.
lp_pronounced("w_kitte", flat, "sokuon", 3) -> (o2, c2, d2, w2);
check('a missing beat is wrong, not unknown', o2, "wrong");
check_true('and it says what was missing', has('missing', d2));

;;; An item whose geminate is a fricative: the scorer is told, and
;;; declines rather than inventing a verdict.
lp_pronounced("w_issho", held, "sokuon", 3) -> (o2, c2, d2, w2);
check('a fricative geminate cannot be timed', o2, "near");
check('and says why', c2, 0.0);

;;; A scorer that answers something the engine does not know is refused
;;; before it reaches lp_record, which mishaps on an unknown outcome.
lp_write_file(tmpdir <> 'bad.json', '{"outcome": "magnificent"}');
lp_write_file(lp_audio_conf_path(),
    '{"ja": {"cmd": "cp %i %o", "voice": "v", "model": "m"},'
    <> ' "record":  {"cmd": "cp ' <> held <> ' %o", "seconds": "3"},'
    <> ' "verdict": {"cmd": "cp ' <> tmpdir <> 'bad.json %v"}}');
lp_voices_load();
lp_pronounced("w_kitte", held, "sokuon", 3) -> (o2, c2, d2, w2);
check('an outcome the engine does not know is refused', w2, 'bad_verdict');

;;; And a scorer that writes nothing at all.
lp_write_file(lp_audio_conf_path(),
    '{"ja": {"cmd": "cp %i %o", "voice": "v", "model": "m"},'
    <> ' "record":  {"cmd": "cp ' <> held <> ' %o", "seconds": "3"},'
    <> ' "verdict": {"cmd": "true"}}');
lp_voices_load();
lp_pronounced("w_kitte", held, "sokuon", 3) -> (o2, c2, d2, w2);
check('a scorer that writes nothing is a failure, not a verdict',
      w2, 'scorer_failed');

;;; The request and verdict scratch files do not survive the call: a
;;; recording of somebody's voice is the most sensitive thing here, and
;;; what the engine writes beside it goes with it.
check_true('no scratch json is left behind',
           not(sys_file_exists(spath <> '.req.json'))
           and not(sys_file_exists(spath <> '.verdict.json')));

sysobey('rm -rf ' <> tmpdir);
test_summary();
