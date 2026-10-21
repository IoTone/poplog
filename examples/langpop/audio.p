/* examples/langpop/audio.p -- Stage 0 of the audio plan: say(Item).

   The first compounding factor in docs/projects/langpop-pronunciation.md
   is not a measurement problem at all: a learner who has never heard the
   target cannot fairly be asked to produce it.  So the first audio that
   ships is OUTPUT -- the student hears a correct model of the item --
   and it carries no verdict, no microphone and no model of the student.

   WHAT THIS IS NOT.  It does not make `hear` verifiable.  Playing a
   sound and checking that somebody heard it are different claims, and
   the ladder goes on saying `cannot be checked here` until something
   checks.  Nothing in this file touches a belief.

   THE VOICE IS A COMMAND, NOT A LIBRARY.  Kokoro is the chosen model
   (82M, Apache-licensed weights, CPU, Japanese among its voices) but
   nothing here knows that: the engine shells out to a command named in
   ~/.langpop/audio.conf, the way card.p shells out to open(1).  Poplog
   is not going to load ONNX, and a tutor that cannot be run without a
   model is worse than one that says it has no voice today.

       {"ja": {"cmd":   "kokoro --voice %v --text-file %i --out %o",
               "voice": "jf_alpha",
               "model": "kokoro-82m-v1.0"},
        "en": {"cmd":   "kokoro --voice %v --text-file %i --out %o",
               "voice": "af_heart",
               "model": "kokoro-82m-v1.0"}}

   %i is a file holding the text, %o the wav to write, %v the voice.  The
   TEXT GOES THROUGH A FILE and never onto the command line: the words
   are Japanese, the shell is not, and a quoting bug in a tutor would be
   a quoting bug in whatever the shell made of ひらがな.

   `model` is declared rather than detected, because an external command
   cannot be asked what weights it loaded.  It is part of the cache key,
   so a line edited in the config is a cache invalidated -- which is the
   honest behaviour: we cache what the config SAID, and when the claim
   changes the audio is made again.

   NOTHING IS SYNTHESISED INSIDE A QUESTION.  lp_audio_path/1 answers
   from the cache and never runs a model; lp_audio_make/1 is the one that
   does, and the tutor calls it from --audio <level>, ahead of time.  A
   student waiting on a model load mid-question is a tutor that feels
   broken.

   Loaded on top of langpop.p; used by server.p (langpop/audio.say) and
   by the TUI's :say command.
*/

;;; The spoken form, in preference order.  Japanese is read from KANA:
;;; romaji is not Japanese text and a voice handed `neko` would read it
;;; as English.  English is read from the latin form and never from the
;;; IPA, which is a notation and not a word -- a voice handed /wɜrld/
;;; says something, and it is not `world`.
lconstant SPOKEN_JA = [hiragana katakana kanji];
lconstant SPOKEN_EN = [latin];

;;; Whatever is on the machine.  Same approach as lp_card_open: the first
;;; one that exists wins, and none of them existing is an answer too.
lconstant PLAYERS = ['/usr/bin/afplay' '/usr/bin/aplay' '/usr/bin/paplay'
                     '/opt/homebrew/bin/play' '/usr/bin/play'];

;;; ------------------------------------------------------- where it lives
define lp_audio_dir() -> d;
    lvars d = lp_home() <> 'audio/';
enddefine;

define lp_audio_lang_dir(lang) -> d;
    lvars lang, d = lp_audio_dir() <> (lang sys_>< '') <> '/';
enddefine;

define lp_audio_conf_path() -> p;
    lvars p = lp_home() <> 'audio.conf';
enddefine;

;;; ------------------------------------------------------ the voice table
;;; lang -> {cmd, voice, model}.  Loaded once, and reloadable: a session
;;; that has just been told how to say things should not need restarting.
vars lp_voices = newproperty([], 8, false, "perm"), lp_voices_ready = false;

define lp_voices_load();
    lvars s, o, lang, cfg;
    newproperty([], 8, false, "perm") -> lp_voices;
    true -> lp_voices_ready;
    lp_read_file(lp_audio_conf_path()) -> s;
    returnunless(s);
    ;;; json_parse builds a PROPERTY, not a json_object, unless
    ;;; json_ordered_objects is set -- so the guard is the one server.p
    ;;; uses, and isjson_object alone silently rejects every config.
    json_parse(s) -> o;
    returnunless(o and (isproperty(o) or isjson_object(o)));
    for lang in ['ja' 'en'] do
        o(lang) -> cfg;
        if cfg and (isproperty(cfg) or isjson_object(cfg)) and cfg('cmd') then
            {% cfg('cmd'),
               cfg('voice') or 'default',
               cfg('model') or 'unnamed' %} -> lp_voices(consword(lang));
        endif;
    endfor;
enddefine;

define lp_voice(lang) -> cfg;
    lvars lang, cfg;
    unless lp_voices_ready then lp_voices_load() endunless;
    lp_voices(if isstring(lang) then consword(lang) else lang endif) -> cfg;
enddefine;

;;; Is there a voice for this language at all?  Everything below answers
;;; `no_voice` rather than failing when there is not, and the six test
;;; suites run on a machine with no models installed.
define lp_audio_ready(lang) -> yes;
    lvars lang, yes = lp_voice(lang) /== false;
enddefine;

;;; ------------------------------------------------------- what to say
;;; A pattern's form carries a BLANK -- これは___です -- and a voice
;;; reading it aloud would say the underscores or swallow them silently.
;;; Either way the student hears a sentence that is not the item, so the
;;; honest answer is that there is nothing here to say yet.
define lp_audio_text(item) -> (text, why);
    lvars item, text = false, why = false, sc, order;
    unless lp_kind(item) then 'no_such_item' -> why; return endunless;
    if lp_ilang(item) == "en" then SPOKEN_EN else SPOKEN_JA endif -> order;
    for sc in order do
        lp_form_of(item, sc) -> text;
        if text then quitloop endif;
    endfor;
    unless text then 'no_spoken_form' -> why; return endunless;
    ;;; A form arrives from Prolog as a WORD, and a word is not a string:
    ;;; `あ <> '\n'` is a mishap, not a concatenation.  Everything below
    ;;; -- the hash, the text file, the page -- wants characters.
    (text sys_>< '') -> text;
    if issubstring('_', text) then
        false -> text; 'has_blank' -> why;
    endif;
enddefine;

;;; ---------------------------------------------------------- the key
;;; djb2 over the bytes, modulo 2^24.  The key is {item, voice, model,
;;; text} and three of the four are in the filename in full, so the hash
;;; only has to separate one item's old text from its new: a collision
;;; needs the SAME item to be re-spelled into a string that hashes the
;;; same, at odds of one in sixteen million, not a birthday problem over
;;; the graph.
define lp_audio_hash(s) -> n;
    lvars s, c;
    5381 -> n;
    for c in_string s do ((n * 33) + c) mod 16777216 -> n endfor;
enddefine;

;;; The cache key IS the filename, so there is no index to keep in step
;;; with the directory: a changed form writes a new name and the old file
;;; stops being reachable rather than being quietly served.
define lp_audio_name(item) -> (path, why);
    lvars item, path = false, why = false, text, cfg, lang;
    lp_audio_text(item) -> (text, why);
    returnif(why);
    lp_ilang(item) -> lang;
    lp_voice(lang) -> cfg;
    unless cfg then 'no_voice' -> why; return endunless;
    lp_audio_lang_dir(lang)
        <> (item sys_>< '') <> '-' <> cfg(2) <> '-'
        <> (lp_audio_hash(text <> '\n' <> cfg(3)) sys_>< '') <> '.wav' -> path;
enddefine;

;;; ---------------------------------------------------- the cached answer
;;; Never synthesises.  This is what a question asks.
define lp_audio_path(item) -> (path, why);
    lvars item, path, why;
    lp_audio_name(item) -> (path, why);
    returnif(why);
    unless sys_file_exists(path) then
        false -> path; 'not_generated' -> why;
    endunless;
enddefine;

;;; --------------------------------------------------------- provenance
;;; A sidecar per file rather than one manifest: no read-modify-write, so
;;; two renders cannot race a shared file, and a stale wav's provenance
;;; goes stale with it instead of outliving it in an index.
define lp_audio_note(path, item, text);
    lvars path, item, text, o = newmapping([], 8, false, true),
          cfg = lp_voice(lp_ilang(item));
    dlocal pop_file_versions = false;
    (item sys_>< '') -> o('item');
    (lp_ilang(item) sys_>< '') -> o('lang');
    text -> o('text');
    cfg(2) -> o('voice');
    cfg(3) -> o('model');
    cfg(1) -> o('command');
    sysdaytime() -> o('made');
    lp_write_file(substring(1, length(path) - 4, path) <> '.json',
                  json_generate(o));
enddefine;

;;; ------------------------------------------------------- the renderer
;;; One substitution at a time, and the values are quoted: the paths are
;;; ours (under lp_home, named after a graph item) but a cache directory
;;; is a path somebody chose with --data, and a space in it should not
;;; become two arguments.
define lp_audio_subst(tmpl, key, val) -> s;
    lvars tmpl, key, val, at, s = tmpl;
    repeat
        issubstring(key, s) -> at;
        quitunless(at);
        substring(1, at - 1, s) <> '\'' <> val <> '\''
            <> substring(at + length(key), length(s) - at - length(key) + 1, s)
            -> s;
    endrepeat;
enddefine;

define lp_audio_make(item) -> (path, made, why);
    lvars item, path = false, made = false, why = false,
          text, cfg, cmd, tf, ok;
    dlocal pop_file_versions = false;
    lp_audio_name(item) -> (path, why);
    returnif(why);
    ;;; A cache hit is not a render, and the caller is told which it got
    ;;; -- `--audio` reporting 46 made on every run would be a lie about
    ;;; what the machine just did.
    returnif(sys_file_exists(path));

    lp_audio_text(item) -> (text, why);
    returnif(why);
    lp_voice(lp_ilang(item)) -> cfg;
    unless cfg then 'no_voice' -> why; false -> path; return endunless;

    unless sys_file_exists(lp_audio_lang_dir(lp_ilang(item))) then
        sysobey('mkdir -p ' <> lp_audio_lang_dir(lp_ilang(item)));
    endunless;

    ;;; The text through a file, never through the command line.
    path <> '.txt' -> tf;
    lp_write_file(tf, text);
    cfg(1) -> cmd;
    lp_audio_subst(cmd, '%i', tf) -> cmd;
    lp_audio_subst(cmd, '%o', path) -> cmd;
    lp_audio_subst(cmd, '%v', cfg(2)) -> cmd;
    sysobey(cmd);

    ;;; An exit status is not evidence.  A command can succeed and write
    ;;; nothing, or write a zero-byte file, and either way the student
    ;;; would be handed silence as though it were a reading.
    if sys_file_exists(path) and sysfilesize(path) > 0 then
        true -> made;
        lp_audio_note(path, item, text);
    else
        false -> path; 'voice_failed' -> why;
    endif;
    if sys_file_exists(tf) then sysdelete(tf) endif;
enddefine;

;;; ------------------------------------------------------------ playing
define lp_audio_play(path) -> ok;
    lvars path, ok = false, player;
    returnunless(path and sys_file_exists(path));
    for player in PLAYERS do
        if sys_file_exists(player) then
            sysobey(player <> ' \'' <> path <> '\'');
            true -> ok; return;
        endif;
    endfor;
enddefine;

;;; -------------------------------------------------------- a whole level
;;; Ahead of time, which is the point: see the file header.
define lp_audio_level(level) -> (made, cached, skipped);
    lvars level, made = 0, cached = 0, skipped = [], i, path, did, why;
    for i in lp_items do
        nextunless(lp_ilevel(i) == level and lp_ilang(i) == lp_lang);
        lp_audio_make(i) -> (path, did, why);
        if why then
            skipped <> [[% i, consword(why) %]] -> skipped;
        elseif did then made + 1 -> made;
        else cached + 1 -> cached;
        endif;
    endfor;
enddefine;

;;; ------------------------------------------------- the listening test
;;; The one part of Stage 0 that is not wiring: whether the Japanese is
;;; good enough to teach pronunciation with is a question for an ear, and
;;; an ear wants every file on one page rather than 46 shell commands.
define lp_audio_esc(s) -> t;
    lvars s, t = '', c;
    (s sys_>< '') -> s;             ;;; a gloss is a word, not a string
    for c in_string s do
        if c == `&` then t <> '&amp;' -> t
        elseif c == `<` then t <> '&lt;' -> t
        elseif c == `>` then t <> '&gt;' -> t
        elseif c == `"` then t <> '&quot;' -> t
        else t <> consstring(c, 1) -> t
        endif;
    endfor;
enddefine;

;;; The last path component.  No library procedure for this, and the
;;; page needs it twice over.
define lp_audio_base(path) -> b;
    lvars path, b = path, k;
    for k from length(path) by -1 to 1 do
        if path(k) == `/` then
            substring(k + 1, length(path) - k, path) -> b; return;
        endif;
    endfor;
enddefine;

define lp_audio_index(level) -> (path, why);
    lvars level, path = false, why = false, i, h, apath, awhy, n = 0,
          text, twhy, cfg = lp_voice(lp_lang);
    dlocal pop_file_versions = false;
    unless cfg then 'no_voice' -> why; return endunless;
    '<!doctype html>\n<html><head><meta charset="utf-8">\n'
      <> '<title>langpop: listen to ' <> (lp_lang sys_>< '') <> ' '
      <> (level sys_>< '') <> '</title>\n'
      <> '<style>body{font:16px/1.5 system-ui,sans-serif;margin:3em auto;'
      <> 'max-width:46em}td{padding:.3em .8em;border-bottom:1px solid #eee}'
      <> '.g{font-size:2em}</style>\n</head><body>\n'
      <> '<h1>' <> (lp_lang sys_>< '') <> ' &middot; '
      <> (level sys_>< '') <> '</h1>\n'
      <> '<p>Voice <b>' <> lp_audio_esc(cfg(2)) <> '</b>, model <b>'
      <> lp_audio_esc(cfg(3)) <> '</b>. Does it sound like a person '
      <> 'reading, and would you learn to say it this way?</p>\n'
      <> '<table>\n' -> h;
    for i in lp_items do
        nextunless(lp_ilevel(i) == level and lp_ilang(i) == lp_lang);
        lp_audio_path(i) -> (apath, awhy);
        nextif(awhy);
        lp_audio_text(i) -> (text, twhy);
        n + 1 -> n;
        ;;; src is the BASENAME: the page sits in the directory the wavs
        ;;; are in, and an absolute path in a src attribute is a path a
        ;;; browser will not follow once the file is moved or served.
        h <> '<tr><td class="g">' <> lp_audio_esc(text)
          <> '</td><td>' <> lp_audio_esc(lp_gloss_of(i, lp_learner_lang())
                                         or lp_gloss_of(i, "en") or '')
          <> '</td><td><audio controls src="'
          <> lp_audio_esc(lp_audio_base(apath)) <> '"></audio></td></tr>\n' -> h;
    endfor;
    if n == 0 then 'not_generated' -> why; return endif;
    h <> '</table>\n<p>' <> (n sys_>< '')
      <> ' items.</p>\n</body></html>\n' -> h;
    lp_audio_lang_dir(lp_lang) <> 'listen-'
      <> (level sys_>< '') <> '.html' -> path;
    lp_write_file(path, h);
enddefine;

;;; ------------------------------------------------------ the CLI report
;;; Says what it did and, for everything it did not do, why -- a level
;;; where half the items have no spoken form is a fact about the graph.
define lp_audio_show(level);
    lvars level, made, cached, skipped, e, path, why, tot,
          counts = newproperty([], 8, 0, "perm"), k;
    unless lp_audio_ready(lp_lang) then
        printf('audio: no voice for %p.  Name one in %p -- see the '
               <> 'header of examples/langpop/audio.p for the shape.\n',
               [% lp_lang, lp_audio_conf_path() %]);
        return;
    endunless;
    unless member(level, lp_levels(lp_lang)) then
        printf('audio: no such level: %p (levels for %p: %p)\n',
               [% level, lp_lang, lp_levels(lp_lang) %]);
        return;
    endunless;
    lp_audio_level(level) -> (made, cached, skipped);
    printf('audio: %p made, %p already cached in %p\n',
           [% made, cached, lp_audio_lang_dir(lp_lang) %]);
    for e in skipped do
        counts(hd(tl(e))) + 1 -> counts(hd(tl(e)));
    endfor;
    appproperty(counts,
        procedure(k, n);
            lvars k, n;
            printf('  %p not said: %p\n', [% n, k %]);
        endprocedure);
    lp_audio_index(level) -> (path, why);
    if why then printf('audio: no page (%p)\n', [^why])
    else printf('audio: listen at %p\n', [^path]) endif;
enddefine;
