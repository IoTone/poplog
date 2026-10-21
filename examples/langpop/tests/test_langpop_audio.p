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
lp_audio_name("hi_a") -> (path, why);
check('a name needs a voice to name the file after', why, 'no_voice');
lp_audio_path("hi_a") -> (path, why);
check('and so does a lookup', why, 'no_voice');
lp_audio_make("hi_a") -> (path, made, why);
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

lvars callfile = tmpdir <> 'calls';
lvars stub = 'echo x >> ' <> callfile <> '; cp %i %o';

conf(stub, 'jf_alpha', 'stub-1');
check_true('a voice is configured now', lp_audio_ready("ja"));

lvars n1, n2, n3, n4;
lp_audio_name("hi_a") -> (n1, why);
check_true('a name is produced', why == false);
lp_audio_name("hi_a") -> (n2, why);
check('the same question gives the same name', n2, n1);
check_true('the voice is in the name, so two voices do not collide',
           has('jf_alpha', n1));
check_true('and the language is in the path', has('/ja/', n1));

conf(stub, 'jf_beta', 'stub-1');
lp_audio_name("hi_a") -> (n3, why);
check_true('a different voice is a different file', n3 /= n1);

conf(stub, 'jf_alpha', 'stub-2');
lp_audio_name("hi_a") -> (n4, why);
check_true('a different model is a different file', n4 /= n1);
check_true('even with the voice unchanged', has('jf_alpha', n4));

;;; The text is the fourth part of the key, and it is the one that moves
;;; when a curator corrects a form.  Two items with different text must
;;; not land on one file.
conf(stub, 'jf_alpha', 'stub-1');
lvars na, ni;
lp_audio_name("hi_a") -> (na, why);
lp_audio_name("hi_i") -> (ni, why);
check_true('two items are two files', na /= ni);

;;; ------------------------------------------------------- rendering once
lp_audio_path("hi_a") -> (path, why);
check('nothing is cached yet', why, 'not_generated');
check_true('and asking did NOT run the voice',
           lp_read_file(callfile) == false);

lp_audio_make("hi_a") -> (path, made, why);
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

lp_audio_make("hi_a") -> (path, made, why);
check_true('a second ask is not a second render', not(made));
check_true('and no error', why == false);
check('the voice still ran only once', length(lp_read_file(callfile)), 2);

lp_audio_path("hi_a") -> (path, why);
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
lp_audio_level("preschool") -> (m, c, sk);
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

lp_audio_level("preschool") -> (m, c, sk);
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
lp_audio_make("hi_u") -> (path, made, why);
check('a voice that writes nothing is a failure', why, 'voice_failed');
check_true('and no path is offered', path == false);

;;; A command that does not exist is the same answer, not a crash.
conf('nosuchcommand-langpop', 'jf_alpha', 'stub-4');
lp_audio_make("hi_u") -> (path, made, why);
check('a voice that is not installed is the same answer', why, 'voice_failed');

sysobey('rm -rf ' <> tmpdir);
test_summary();
