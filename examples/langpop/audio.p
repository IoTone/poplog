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

       {"ja": {"cmd":   "kokoro --voice %v --speed %r --text-file %i --out %o",
               "voice": "jf_alpha",
               "model": "kokoro-82m-v1.0",
               "rates": {"slow": "0.7", "normal": "1.0", "fast": "1.3"}},
        "en": {"cmd":   "kokoro --voice %v --speed %r --text-file %i --out %o",
               "voice": "af_heart",
               "model": "kokoro-82m-v1.0",
               "rates": {"slow": "0.7", "normal": "1.0", "fast": "1.3"}}}

   %i is a file holding the text, %o the wav to write, %v the voice, %r
   the rate.  The TEXT GOES THROUGH A FILE and never onto the command
   line: the words are Japanese, the shell is not, and a quoting bug in a
   tutor would be a quoting bug in whatever the shell made of ひらがな.

   THE RATE SCALE BELONGS TO THE ENGINE, THE NAME BELONGS TO US.  Kokoro
   takes a multiplier where 1.0 is normal; say(1) takes words per minute
   where 175 is normal; a hypothetical third takes a percentage.  There
   is no portable number, so the config maps a NAME to whatever that
   engine wants and %r substitutes it:

       "rates": {"slow": "110", "normal": "175", "fast": "220"}

   The three names are the three a learner asks for, and they are the
   only ones recognised: a tutor needs slower and faster, not an
   arbitrary dial.  A config that declares none gets `normal` with
   nothing substituted, which is what an engine with no rate control
   wants -- so %r simply does not appear in its template.

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
;;; The rates a learner asks for, slowest first -- which is also the order
;;; they are reported and rendered in.
lconstant RATE_ORDER = [slow normal fast];
lconstant RATE_DEFAULT = "normal";

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

;;; lp_audio_conf_path is in langpop.p, beside lp_home: the engine has to
;;; be able to ask whether a voice is configured BEFORE deciding to load
;;; this file.

;;; ------------------------------------------------------ the voice table
;;; lang -> {cmd, voice, model}.  Loaded once, and reloadable: a session
;;; that has just been told how to say things should not need restarting.
vars lp_voices = newproperty([], 8, false, "perm"), lp_voices_ready = false;

;;; [[name value] ...] in RATE_ORDER, from the config's `rates` object.
;;; A name outside RATE_ORDER is dropped rather than honoured: see the
;;; header.  No `rates` at all is not an error -- it is an engine with no
;;; rate control, and `normal` substitutes nothing.
define lp_rates_of(o) -> rs;
    lvars o, rs = [], r, v;
    unless o and (isproperty(o) or isjson_object(o)) then
        [[normal ^false]] -> rs; return;
    endunless;
    ;;; One pass over RATE_ORDER, so the result is in RATE_ORDER -- and
    ;;; `normal` is included whether or not the config declared it,
    ;;; because every call that does not ask for a rate wants it.  Adding
    ;;; it afterwards put it first and broke the slowest-first order the
    ;;; student is offered.
    for r in RATE_ORDER do
        o(r sys_>< '') -> v;
        if v then rs <> [[% r, (v sys_>< '') %]] -> rs
        elseif r == RATE_DEFAULT then rs <> [[% r, false %]] -> rs
        endif;
    endfor;
enddefine;


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
               cfg('model') or 'unnamed',
               lp_rates_of(cfg('rates')) %} -> lp_voices(consword(lang));
        endif;
    endfor;
    ;;; The microphone and the scorer are not per-language: see the
    ;;; comment on lp_recorder.  They live in the same table because it
    ;;; is the same config file and the same "named or absent" rule.
    for lang in ['record' 'verdict' 'meter'] do
        o(lang) -> cfg;
        if cfg and (isproperty(cfg) or isjson_object(cfg)) and cfg('cmd') then
            {% cfg('cmd'), (cfg('seconds') or '3') %}
                -> lp_voices(consword(lang));
        endif;
    endfor;
enddefine;

;;; The rate the student is listening at.  Persisted with the profile
;;; beside the aids, because a beginner who has asked for slow should not
;;; have to ask again tomorrow.
vars lp_rate = RATE_DEFAULT;

define lp_rate_names() -> l;
    lvars l = RATE_ORDER;
enddefine;

;;; What this language's voice can actually do, which is a fact about the
;;; config and not about langpop: an engine with no rate control offers
;;; `normal` alone, and :rate says so rather than pretending.
define lp_audio_rates(lang) -> names;
    lvars lang, names = [], cfg = lp_voice(lang), r;
    returnunless(cfg);
    [% for r in cfg(4) do hd(r) endfor %] -> names;
enddefine;

;;; (value, ok): the string to substitute for %r, and whether this voice
;;; knows the name at all.  A value of false is a known rate with nothing
;;; to substitute -- `normal` on an engine with no rate control.
define lp_audio_rate_value(lang, rate) -> (val, ok);
    lvars lang, rate, val = false, ok = false, cfg = lp_voice(lang), r;
    returnunless(cfg);
    for r in cfg(4) do
        if hd(r) == rate then
            hd(tl(r)) -> val; true -> ok; return;
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

;;; ---------------------------------------------------- rate and rhythm
;;; A SLOWED VOICE IS NOT A SLOWED LANGUAGE, and for one family of items
;;; that matters.  Japanese length is contrastive: きて and きって differ
;;; by a beat of silence, and the mora skills exist to teach exactly
;;; that.  Every TTS engine stretches those durations under a rate
;;; change, and none of them promises to stretch a geminate closure by
;;; the same factor as the vowel beside it -- so at 0.7 the student may
;;; hear a ratio the language does not have.
;;;
;;; Slow is still the right setting for finding the segments in a word.
;;; It is the wrong one for learning its rhythm, and those are different
;;; lessons on the same item.  So this is reported, never refused: the
;;; tutor says which it is and the student decides.
lconstant TIMING_MARKS = ['っ' 'ッ' 'ー' 'ん' 'ン'];

define lp_audio_timing(item) -> yes;
    lvars item, yes = false, text, why, m;
    lp_audio_text(item) -> (text, why);
    returnif(why);
    ;;; Byte search is safe here: UTF-8 is self-synchronising, so a
    ;;; three-byte sequence cannot match across a character boundary.
    for m in TIMING_MARKS do
        if issubstring(m, text) then true -> yes; return endif;
    endfor;
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
;;; `rate` is false for "whatever the student is listening at", a name
;;; for an explicit one.  It lands in the filename beside the voice, and
;;; its VALUE goes through the hash with the model: a config that
;;; redefines slow from 0.7 to 0.8 has to invalidate what 0.7 produced.
define lp_audio_rate_of(rate) -> r;
    lvars rate, r = rate;
    unless r then lp_rate -> r endunless;
    unless r then RATE_DEFAULT -> r endunless;
enddefine;

;;; A filesystem-safe stem for text that is not an item id.  The pair
;;; words are words, and a word can carry a hyphen or an apostrophe.
define lp_audio_slug(text) -> t;
    lvars text, t = '', c;
    for c in_string (text sys_>< '') do
        if (c >= `a` and c <= `z`) or (c >= `A` and c <= `Z`)
        or (c >= `0` and c <= `9`) then t <> consstring(c, 1) -> t
        else t <> '_' -> t
        endif;
    endfor;
enddefine;

;;; THE CACHE KNOWS NOTHING ABOUT ITEMS.  It was written for them, and
;;; the confusion pairs are the case that showed why that was too
;;; narrow: `right` and `light` are teaching material belonging to a
;;; contrast, not vocabulary items, and making them items to get them
;;; spoken would have inflated every vocabulary criterion with words
;;; whose only job is a drill.
;;;
;;; So the key is {name, voice, rate, model, text} -- a name the caller
;;; chooses, and the text to say.  An item's name is its id; a pair
;;; word's is a slug of the word.  Everything else below is unchanged.
define lp_audio_name_of(name, text, lang, rate) -> (path, why);
    lvars name, text, lang, rate, path = false, why = false, cfg, val, ok;
    lp_voice(lang) -> cfg;
    unless cfg then 'no_voice' -> why; return endunless;
    lp_audio_rate_of(rate) -> rate;
    lp_audio_rate_value(lang, rate) -> (val, ok);
    unless ok then 'no_such_rate' -> why; return endunless;
    lp_audio_lang_dir(lang)
        <> (name sys_>< '') <> '-' <> cfg(2) <> '-' <> (rate sys_>< '') <> '-'
        <> (lp_audio_hash((text sys_>< '') <> '\n' <> cfg(3) <> '\n'
                          <> (val or '')) sys_>< '') <> '.wav' -> path;
enddefine;

define lp_audio_name(item, rate) -> (path, why);
    lvars item, rate, path = false, why = false, text;
    lp_audio_text(item) -> (text, why);
    returnif(why);
    lp_audio_name_of(item, text, lp_ilang(item), rate) -> (path, why);
enddefine;

;;; ---------------------------------------------------- the cached answer
;;; Never synthesises.  This is what a question asks.
define lp_audio_path_of(name, text, lang, rate) -> (path, why);
    lvars name, text, lang, rate, path, why;
    lp_audio_name_of(name, text, lang, rate) -> (path, why);
    returnif(why);
    unless sys_file_exists(path) then
        false -> path; 'not_generated' -> why;
    endunless;
enddefine;

define lp_audio_path(item, rate) -> (path, why);
    lvars item, rate, path, why;
    lp_audio_name(item, rate) -> (path, why);
    returnif(why);
    unless sys_file_exists(path) then
        false -> path; 'not_generated' -> why;
    endunless;
enddefine;

;;; --------------------------------------------------------- provenance
;;; A sidecar per file rather than one manifest: no read-modify-write, so
;;; two renders cannot race a shared file, and a stale wav's provenance
;;; goes stale with it instead of outliving it in an index.
define lp_audio_note(path, name, text, lang, rate, item);
    lvars path, name, text, lang, rate, item,
          o = newmapping([], 8, false, true),
          cfg = lp_voice(lang), val, ok;
    dlocal pop_file_versions = false;
    lp_audio_rate_value(lang, rate) -> (val, ok);
    (rate sys_>< '') -> o('rate');
    if val then val -> o('rate_value') endif;
    ;;; An item answers whether its length is contrastive; a bare word
    ;;; from a confusion pair has no item to ask, and the question does
    ;;; not arise for English anyway.
    if item then lp_audio_timing(item) -> o('timing_sensitive') endif;
    (name sys_>< '') -> o('name');
    if item then (item sys_>< '') -> o('item') endif;
    (lang sys_>< '') -> o('lang');
    (text sys_>< '') -> o('text');
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

define lp_audio_make_of(name, text, lang, rate, item) -> (path, made, why);
    lvars name, text, lang, rate, item,
          path = false, made = false, why = false, cfg, cmd, tf, ok, val;
    dlocal pop_file_versions = false;
    lp_audio_name_of(name, text, lang, rate) -> (path, why);
    returnif(why);
    lp_audio_rate_of(rate) -> rate;
    ;;; A cache hit is not a render, and the caller is told which it got
    ;;; -- `--audio` reporting 46 made on every run would be a lie about
    ;;; what the machine just did.
    returnif(sys_file_exists(path));

    lp_voice(lang) -> cfg;
    unless cfg then 'no_voice' -> why; false -> path; return endunless;

    unless sys_file_exists(lp_audio_lang_dir(lang)) then
        sysobey('mkdir -p ' <> lp_audio_lang_dir(lang));
    endunless;

    ;;; The text through a file, never through the command line.
    path <> '.txt' -> tf;
    lp_write_file(tf, text sys_>< '');
    cfg(1) -> cmd;
    lp_audio_subst(cmd, '%i', tf) -> cmd;
    lp_audio_subst(cmd, '%o', path) -> cmd;
    lp_audio_subst(cmd, '%v', cfg(2)) -> cmd;
    ;;; A rate with no value is `normal` on an engine with no rate
    ;;; control.  Substituting an empty string would hand that engine a
    ;;; bare flag with no argument, which is a command-line error rather
    ;;; than a default, so %r is left alone and a template that mentions
    ;;; it had better have a rate to put there.
    lp_audio_rate_value(lang, rate) -> (val, ok);
    if val then lp_audio_subst(cmd, '%r', val) -> cmd endif;
    sysobey(cmd);

    ;;; An exit status is not evidence.  A command can succeed and write
    ;;; nothing, or write a zero-byte file, and either way the student
    ;;; would be handed silence as though it were a reading.
    if sys_file_exists(path) and sysfilesize(path) > 0 then
        true -> made;
        lp_audio_note(path, name, text, lang, rate, item);
    else
        false -> path; 'voice_failed' -> why;
    endif;
    if sys_file_exists(tf) then sysdelete(tf) endif;
enddefine;

define lp_audio_make(item, rate) -> (path, made, why);
    lvars item, rate, path = false, made = false, why = false, text;
    lp_audio_text(item) -> (text, why);
    returnif(why);
    lp_audio_make_of(item, text, lp_ilang(item), rate, item)
        -> (path, made, why);
enddefine;

;;; ------------------------------------------------- the microphone side
;;; Stage A of docs/projects/langpop-audio.md: the seam, before any
;;; model.  Two more commands in audio.conf, on exactly the terms the
;;; voice is on -- named by the config, absent without consequence:
;;;
;;;     "record":  {"cmd": "rec -S -r 16000 -c 1 -b 16 %o trim 0 %s",
;;;                 "seconds": "2"}
;;;     "verdict": {"cmd": "python3 examples/langpop/tools/score-morae.py
;;;                         --request %q --out %v"}
;;;     "meter":   optional; defaults to tools/mic-level.py
;;;
;;; `-S` AND NOT `-q`, which is the difference between a tutor you can
;;; trust and one you cannot: sox's -S draws a live VU bar and a clip
;;; counter while it records, so the student can see they are being
;;; heard AS THEY SPEAK.  The meter afterwards says what the scorer saw;
;;; the bar during says whether anything arrived at all.  ffmpeg does
;;; the same job -- "ffmpeg -f avfoundation -i :0 -t %s -ar 16000 -ac 1
;;; -y %o" -- and prints its own level line.
;;;
;;; THE PLAN SAID A JSON-RPC SIDE-CAR and this is a command, which is a
;;; deliberate departure.  The argument for a persistent process was
;;; model load time -- and the scorer that exists loads no model, so the
;;; latency that justified it is not there to measure.  The contract is
;;; the same either way (a request object in, a verdict object out), so
;;; the day a model makes startup hurt, the transport changes inside
;;; lp_pronounced and nothing above it moves.  Measured, not assumed.
;;;
;;; `record` and `verdict` are NOT per-language.  A microphone is a
;;; microphone, and the scorer is told the language in the request.
define lp_recorder() -> cfg;
    lvars cfg;
    unless lp_voices_ready then lp_voices_load() endunless;
    lp_voices("record") -> cfg;
enddefine;

define lp_scorer() -> cfg;
    lvars cfg;
    unless lp_voices_ready then lp_voices_load() endunless;
    lp_voices("verdict") -> cfg;
enddefine;

;;; The level meter.  Optional in the config, because unlike the voice
;;; and the scorer it is OURS -- there is no third-party choice to make
;;; -- so an absent key falls back to the tool in the tree rather than
;;; disabling the feature.  Configure it to use a different interpreter,
;;; or to point at something better.
define lp_meter() -> cmd;
    lvars cmd, cfg;
    unless lp_voices_ready then lp_voices_load() endunless;
    lp_voices("meter") -> cfg;
    if cfg then cfg(1) -> cmd
    else 'python3 -I ' <> langpop_dir <> 'tools/mic-level.py %o' -> cmd
    endif;
enddefine;

;;; Straight to the terminal.  The meter's whole job is to be LOOKED AT,
;;; so its output is not captured and reprinted -- sysobey hands the
;;; child the same terminal, exactly as the audio player gets it.
define lp_mic_meter(sample) -> ok;
    lvars sample, ok = false, cmd;
    returnunless(sample and sys_file_exists(sample));
    lp_audio_subst(lp_meter(), '%o', sample) -> cmd;
    sysobey(cmd);
    pop_status == 0 -> ok;
enddefine;

define lp_can_speak() -> yes;
    lvars yes = (lp_recorder() and lp_scorer()) and true;
enddefine;

;;; A RECORDING OF SOMEBODY'S VOICE IS THE MOST SENSITIVE THING THIS
;;; PROJECT TOUCHES, so the sample is scratch: written under the data
;;; directory, scored, and deleted.  Nothing keeps it, nothing uploads
;;; it, and the only reason it is a file at all is that the scorer is a
;;; separate process.
define lp_sample_path(item) -> path;
    lvars item, path = lp_home() <> 'samples/';
    unless sys_file_exists(path) then sysobey('mkdir -p ' <> path) endunless;
    path <> (item sys_>< '') <> '-' <> (lp_now_ms() sys_>< '') <> '.wav'
        -> path;
enddefine;

define lp_audio_capture(item) -> (path, why);
    lvars item, path = false, why = false, cfg = lp_recorder(), cmd;
    dlocal pop_file_versions = false;
    unless cfg then 'no_recorder' -> why; return endunless;
    lp_sample_path(item) -> path;
    cfg(1) -> cmd;
    lp_audio_subst(cmd, '%o', path) -> cmd;
    lp_audio_subst(cmd, '%s', cfg(2)) -> cmd;
    sysobey(cmd);
    ;;; Same rule as the voice: an exit status is not evidence.  A
    ;;; recorder that writes nothing has not recorded the student, and
    ;;; scoring silence would blame them for it.
    unless sys_file_exists(path) and sysfilesize(path) > 0 then
        false -> path; 'no_sample' -> why;
    endunless;
enddefine;

;;; っ BEFORE A FRICATIVE IS NOT A SILENCE.  いっしょ is [iʃːo]: the mora
;;; is a lengthened [ʃ] with energy all the way through, so there is no
;;; gap to time and no threshold that finds one.  The graph knows the
;;; following kana, so the tutor declines to ASK rather than asking and
;;; abstaining -- which is the difference between a question with no
;;; answer and a question that was never fair.
lconstant SOKUON_FRICATIVES = ['っさ' 'っし' 'っす' 'っせ' 'っそ' 'っふ'
                               'ッサ' 'ッシ' 'ッス' 'ッセ' 'ッソ' 'ッフ'];

define lp_sokuon_detectable(item) -> yes;
    lvars item, yes = false, text, why, f;
    lp_audio_text(item) -> (text, why);
    returnif(why);
    returnunless(issubstring('っ', text) or issubstring('ッ', text));
    true -> yes;
    for f in SOKUON_FRICATIVES do
        if issubstring(f, text) then false -> yes; return endif;
    endfor;
enddefine;

;;; pronounced(Item, Sample) -> (outcome, confidence, detail).  The one
;;; call the whole microphone side is behind: a request object out, a
;;; verdict object back, and the engine knows nothing about how it was
;;; arrived at.
define lp_pronounced(item, sample, task, expect)
        -> (outcome, confidence, detail, why);
    lvars item, sample, task, expect,
          outcome = false, confidence = 0.0, detail = false, why = false,
          cfg = lp_scorer(), req, vpath, cmd, o, s, text, twhy;
    dlocal pop_file_versions = false;
    unless cfg then 'no_scorer' -> why; return endunless;
    unless sample and sys_file_exists(sample) then
        'no_sample' -> why; return;
    endunless;
    lp_audio_text(item) -> (text, twhy);
    newmapping([], 8, false, true) -> req;
    (item sys_>< '') -> req('item');
    (lp_ilang(item) sys_>< '') -> req('lang');
    sample -> req('sample');
    (task sys_>< '') -> req('task');
    expect -> req('expect');
    if text then text -> req('text') endif;
    ;;; A STRING AND NOT A BOOLEAN.  json_generate drops a false, so
    ;;; `detectable: false` left the key out altogether -- and a scorer
    ;;; reading an absent key as its default duly measured a gap in a
    ;;; word that has none and called it right.  The same trap the aids
    ;;; hit (`aids_off` stores names) and the exporter hit before that:
    ;;; an absent field and a false field are the same thing once
    ;;; parsed, so the fact is carried positively.
    (if lp_sokuon_detectable(item) then 'yes' else 'no' endif)
        -> req('detectable');
    sample <> '.req.json' -> s;
    sample <> '.verdict.json' -> vpath;
    lp_write_file(s, json_generate(req));
    cfg(1) -> cmd;
    lp_audio_subst(cmd, '%q', s) -> cmd;
    lp_audio_subst(cmd, '%v', vpath) -> cmd;
    sysobey(cmd);
    if sys_file_exists(vpath) then
        json_parse(lp_read_file(vpath)) -> o;
    else
        false -> o;
    endif;
    if sys_file_exists(s) then sysdelete(s) endif;
    if sys_file_exists(vpath) then sysdelete(vpath) endif;
    unless o and (isproperty(o) or isjson_object(o)) then
        'scorer_failed' -> why; return;
    endunless;
    ;;; An outcome the engine does not know is not an outcome.  A scorer
    ;;; is somebody else's program, and lp_record mishaps on a word that
    ;;; is not in OUTCOMES -- which would be a tutor crashing because a
    ;;; model said something unexpected.
    unless o('outcome')
    and member(consword(o('outcome') sys_>< ''), lp_outcomes())
    then 'bad_verdict' -> why; return endunless;
    consword(o('outcome') sys_>< '') -> outcome;
    (o('confidence') or 0.0) -> confidence;
    o('detail') -> detail;
enddefine;

;;; ------------------------------------------------------------ playing
;;; THE EXIT STATUS, not merely the existence of a player.  A player
;;; that is installed and fails is the common case -- a truncated file, a
;;; format it will not open, no audio device -- and reporting it as
;;; played is how a listening question gets asked of a student who heard
;;; nothing.  pop_status carries the child's status (REF * SYSUTIL).
;;;
;;; stderr goes to /dev/null because the player's complaint arrives in
;;; the middle of a question: the session transcript read
;;;
;;;     聞いてください。What did you hear?
;;;     Error: AudioFileOpen failed ('typ?')
;;;     ->
;;;
;;; which tells the student nothing and the tutor nothing either.  The
;;; status is what the tutor needs, and it says so in its own words.
define lp_audio_play(path) -> ok;
    lvars path, ok = false, player;
    returnunless(path and sys_file_exists(path));
    for player in PLAYERS do
        if sys_file_exists(player) then
            sysobey(player <> ' \'' <> path <> '\' 2>/dev/null');
            pop_status == 0 -> ok;
            return;
        endif;
    endfor;
enddefine;

;;; -------------------------------------------------------- a whole level
;;; Ahead of time, which is the point: see the file header.
define lp_audio_level(level, rate) -> (made, cached, skipped);
    lvars level, rate, made = 0, cached = 0, skipped = [], i, path, did, why,
          pr, w, words = [];
    for i in lp_items do
        nextunless(lp_ilevel(i) == level and lp_ilang(i) == lp_lang);
        lp_audio_make(i, rate) -> (path, did, why);
        if why then
            skipped <> [[% i, consword(why) %]] -> skipped;
        elseif did then made + 1 -> made;
        else cached + 1 -> cached;
        endif;
        ;;; The words of a confusion pair are not items -- they are drill
        ;;; material belonging to a contrast -- so walking lp_items would
        ;;; never reach them, and the contrast would stay unaskable with
        ;;; the voice installed and the level rendered.  Collected first
        ;;; and deduplicated, because `berry` separates two contrasts and
        ;;; wants one file.
        if lp_kind(i) == "sound" then
            for pr in lp_pairs_of(i) do
                for w in pr do
                    unless member(w, words) then words <> [^w] -> words
                    endunless;
                endfor;
            endfor;
        endif;
    endfor;
    for w in words do
        lp_audio_make_of(lp_pair_word_name(w), w, "en", rate, false)
            -> (path, did, why);
        if why then
            skipped <> [[% consword(lp_pair_word_name(w)), consword(why) %]]
                -> skipped;
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
          text, twhy, cfg = lp_voice(lp_lang), rates = [], r, cell, any;
    dlocal pop_file_versions = false;
    unless cfg then 'no_voice' -> why; return endunless;

    ;;; A column per rate that something was actually rendered at, not
    ;;; per rate the config declares: a page with an empty `fast` column
    ;;; says the voice cannot go fast, which is not what it means.
    for r in lp_audio_rates(lp_lang) do
        false -> any;
        for i in lp_items do
            nextunless(lp_ilevel(i) == level and lp_ilang(i) == lp_lang);
            lp_audio_path(i, r) -> (apath, awhy);
            unless awhy then true -> any; quitloop endunless;
        endfor;
        if any then rates <> [^r] -> rates endif;
    endfor;
    if rates == [] then 'not_generated' -> why; return endif;

    '<!doctype html>\n<html><head><meta charset="utf-8">\n'
      <> '<title>langpop: listen to ' <> (lp_lang sys_>< '') <> ' '
      <> (level sys_>< '') <> '</title>\n'
      <> '<style>body{font:16px/1.5 system-ui,sans-serif;margin:3em auto;'
      <> 'max-width:60em}td,th{padding:.3em .8em;border-bottom:1px solid #eee;'
      <> 'text-align:left}.g{font-size:2em}audio{height:2em}'
      <> '.t{color:#8a6d3b}</style>\n</head><body>\n'
      <> '<h1>' <> (lp_lang sys_>< '') <> ' &middot; '
      <> (level sys_>< '') <> '</h1>\n'
      <> '<p>Voice <b>' <> lp_audio_esc(cfg(2)) <> '</b>, model <b>'
      <> lp_audio_esc(cfg(3)) <> '</b>. Does it sound like a person '
      <> 'reading, and would you learn to say it this way?</p>\n'
      <> '<p class="t">A row marked &#9834; carries contrastive length '
      <> '(&#12387;, &#12540;, &#12435;). Judge its RHYTHM at the normal '
      <> 'rate only: every engine stretches those durations under a rate '
      <> 'change and none promises to stretch a closure by the same '
      <> 'factor as the vowel beside it.</p>\n'
      <> '<table>\n<tr><th></th><th></th>' -> h;
    for r in rates do
        h <> '<th>' <> lp_audio_esc(r sys_>< '') <> '</th>' -> h;
    endfor;
    h <> '</tr>\n' -> h;

    for i in lp_items do
        nextunless(lp_ilevel(i) == level and lp_ilang(i) == lp_lang);
        lp_audio_text(i) -> (text, twhy);
        nextif(twhy);
        ;;; Only rows with something to play.  An item rendered at no
        ;;; rate at all is not a row with empty cells.
        false -> any;
        for r in rates do
            lp_audio_path(i, r) -> (apath, awhy);
            unless awhy then true -> any; quitloop endunless;
        endfor;
        nextunless(any);
        n + 1 -> n;
        h <> '<tr><td class="g">' <> lp_audio_esc(text)
          <> (if lp_audio_timing(i) then ' <span class="t">&#9834;</span>'
              else '' endif)
          <> '</td><td>' <> lp_audio_esc(lp_gloss_of(i, lp_learner_lang())
                                         or lp_gloss_of(i, "en") or '')
          <> '</td>' -> h;
        for r in rates do
            lp_audio_path(i, r) -> (apath, awhy);
            ;;; src is the BASENAME: the page sits in the directory the
            ;;; wavs are in, and an absolute path in a src attribute is a
            ;;; path a browser will not follow once the file is moved.
            if awhy then '' else
                '<audio controls src="' <> lp_audio_esc(lp_audio_base(apath))
                  <> '"></audio>' endif -> cell;
            h <> '<td>' <> cell <> '</td>' -> h;
        endfor;
        h <> '</tr>\n' -> h;
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
define lp_audio_show(level, rate);
    lvars level, rate, made, cached, skipped, e, path, why, r, which,
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
    ;;; --rate all renders every rate the voice declares, which is what
    ;;; the listening page wants a column of each for.
    if rate == "all" then lp_audio_rates(lp_lang) -> which
    else [% lp_audio_rate_of(rate) %] -> which
    endif;
    for r in which do
        unless member(r, lp_audio_rates(lp_lang)) then
            printf('audio: this voice has no %p rate (it has: %p)\n',
                   [% r, lp_audio_rates(lp_lang) %]);
            return;
        endunless;
    endfor;
    0 -> made; 0 -> cached;
    for r in which do
        lvars m2, c2, s2;
        lp_audio_level(level, r) -> (m2, c2, s2);
        made + m2 -> made; cached + c2 -> cached; s2 -> skipped;
        printf('audio: %p at %p made, %p already cached\n',
               [% m2, r, c2 %]);
    endfor;
    printf('audio: in %p\n', [% lp_audio_lang_dir(lp_lang) %]);
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

;;; ------------------------------------------------ the voice as student
;;; First-pass validation with nobody in the loop.  The configured voice
;;; says each scoreable word twice -- once as written, and once with the
;;; small っ dropped, which is EXACTLY the learner error the scorer exists
;;; to catch -- and the scorer must call the first `right` and the second
;;; `wrong`.  A verdict chain that cannot tell きって from きて when a machine
;;; says them has no business grading a person.
;;;
;;; What a pass proves: the render command, the scorer command, the
;;; request contract and the threshold agree with each other ON THIS
;;; INSTALLATION -- this voice, this python, this config.  What it cannot
;;; prove: that the threshold holds for human speech.  A TTS voice is
;;; nobody's student; the second pass needs ears.
;;;
;;; No microphone is involved anywhere below, deliberately: the renders
;;; stand in for the recordings, so this runs on a machine with no input
;;; device at all -- which is every machine in CI.

;;; The learner error, built mechanically: remove every small っ and ッ.
;;; The expectation handed to the scorer stays the FULL count, because
;;; that is the drill situation -- asked きって, said きて.
define lp_degeminate(text) -> (out, changed);
    lvars text, out = text sys_>< '', changed = false, m, at;
    for m in ['っ' 'ッ'] do
        repeat
            issubstring(m, out) -> at;
            quitunless(at);
            substring(1, at - 1, out)
                <> substring(at + length(m),
                             length(out) - at - length(m) + 1, out) -> out;
            true -> changed;
        endrepeat;
    endfor;
enddefine;

;;; One case: a render scored AS the item the student would have been
;;; asked, against the verdict the chain must produce.  The row says
;;; which pronunciation was played, so a disagreement reads as a fact
;;; about the chain and not a puzzle.
;;; A dropped beat that comes back `near` is NOT a failure.  The first
;;; run against a real voice showed why: Kyoko's natural gap between the
;;; morae of a degeminated word sits at 80-120 ms, right at the border of
;;; one beat, and the scorer abstaining there is the scorer doing what
;;; abstention is for.  The disaster this test exists to catch is a
;;; dropped beat CREDITED -- `right` -- and that stays a disagreement.
define lp_vt_score(item, path, said, expect, want, note) -> got;
    lvars item, path, said, expect, want, note, got = false,
          outcome, confv, detail, why, label;
    lp_pronounced(item, path, "sokuon", expect) -> (outcome, confv, detail, why);
    if why then
        printf('  %p  %p  (%p): no verdict -- %p\n', [% item, said, note, why %]);
        return;
    endif;
    outcome -> got;
    if outcome == want then 'ok'
    elseif want == "wrong" and outcome == "near" then 'abstained -- borderline'
    else '** DISAGREE **'
    endif -> label;
    printf('  %p  %p  (%p): want %p, got %p  %p\n',
           [% item, said, note, want, outcome, label %]);
    unless outcome == want then
        if detail then printf('      the scorer said: %p\n', [^detail]) endif;
    endunless;
enddefine;

define lp_voice_test(rate) -> (agree, disagree, abstain);
    lvars rate, agree = 0, disagree = 0, abstain = 0, i, text, why, expect,
          path, made, twin, changed, controls = 0, cfg, val, ok, got;
    dlocal pop_file_versions = false;
    unless lp_audio_ready(lp_lang) then
        printf('voicetest: no voice for %p in %p\n',
               [% lp_lang, lp_audio_conf_path() %]);
        return;
    endunless;
    unless lp_scorer() then
        printf('voicetest: no verdict command in %p, and the scorer is the\n',
               [% lp_audio_conf_path() %]);
        printf('voicetest: thing under test, so there is nothing to do.\n');
        return;
    endunless;
    lp_audio_rate_value(lp_lang, lp_audio_rate_of(rate)) -> (val, ok);
    unless ok then
        printf('voicetest: no such rate %p -- see :rate\n', [^rate]);
        return;
    endunless;
    lp_voice(lp_lang) -> cfg;
    printf('voicetest: %p (%p) against the scorer, rate %p, %p\n',
           [% cfg(2), cfg(3), lp_audio_rate_of(rate), lp_lang %]);
    for i in lp_items do
        nextunless(lp_ilang(i) == lp_lang);
        nextunless(member("speak", lp_channels(i)));
        lp_audio_text(i) -> (text, why);
        nextif(why);
        lp_morae(text) -> expect;
        nextunless(expect >= 2);
        if lp_sokuon_detectable(i) then
            ;;; The word as written must come back RIGHT.
            lp_audio_make(i, rate) -> (path, made, why);
            if why then
                printf('  %p  %p: could not render (%p)\n', [% i, text, why %]);
                disagree + 1 -> disagree;
            elseif lp_vt_score(i, path, text, expect, "right", 'as written')
                   == "right"
            then agree + 1 -> agree
            else disagree + 1 -> disagree
            endif;
            ;;; And the learner error must come back WRONG.
            lp_degeminate(text) -> (twin, changed);
            lp_audio_make_of((i sys_>< '') <> '-vt', twin, lp_lang, rate, false)
                -> (path, made, why);
            if why then
                printf('  %p  %p: could not render (%p)\n', [% i, twin, why %]);
                disagree + 1 -> disagree;
            else
                lp_vt_score(i, path, twin, expect, "wrong", 'beat dropped')
                    -> got;
                if got == "wrong" then agree + 1 -> agree
                elseif got == "near" then abstain + 1 -> abstain
                else disagree + 1 -> disagree
                endif;
                ;;; A render of a WRONG pronunciation has no business in
                ;;; the cache a student hears from.  It goes, and its
                ;;; provenance note goes with it.
                if sys_file_exists(path) then sysdelete(path) endif;
                substring(1, length(path) - 4, path) <> '.json' -> path;
                if sys_file_exists(path) then sysdelete(path) endif;
            endif;
        elseif issubstring('っ', text) or issubstring('ッ', text) then
            ;;; っ before a fricative: the whole chain must DECLINE, end
            ;;; to end, because a gap that is not there cannot be timed.
            lp_audio_make(i, rate) -> (path, made, why);
            if why then
                printf('  %p  %p: could not render (%p)\n', [% i, text, why %]);
                disagree + 1 -> disagree;
            elseif lp_vt_score(i, path, text, expect, "near",
                               'fricative: must decline') == "near"
            then agree + 1 -> agree
            else disagree + 1 -> disagree
            endif;
        elseif controls < 3 and lp_lang == "ja" then
            ;;; A few words with no held beat at all.  The chain must
            ;;; decline these too -- a regression here is a tutor asking
            ;;; a question nobody can mark.
            controls + 1 -> controls;
            lp_audio_make(i, rate) -> (path, made, why);
            if why then
                printf('  %p  %p: could not render (%p)\n', [% i, text, why %]);
                disagree + 1 -> disagree;
            elseif lp_vt_score(i, path, text, expect, "near",
                               'no beat: must decline') == "near"
            then agree + 1 -> agree
            else disagree + 1 -> disagree
            endif;
        endif;
    endfor;
    if agree + disagree + abstain == 0 then
        printf('voicetest: nothing to test for %p -- the only machine-scored\n',
               [% lp_lang %]);
        printf('voicetest: production task so far is the Japanese held beat.\n');
    elseif disagree == 0 then
        printf('voicetest: %p checks, %p agree, nothing credited that should not be.\n',
               [% agree + abstain, agree %]);
        if abstain > 0 then
            printf('voicetest: %p dropped-beat renders came back `near`: this voice\'s\n',
                   [^abstain]);
            printf('voicetest: natural gaps sit at the borderline.  An abstention never\n');
            printf('voicetest: credits the beat, so nothing is unsafe -- but those words\n');
            printf('voicetest: are where the threshold most wants human ears.\n');
        endif;
        printf('voicetest: this validates the machinery on this installation, not the\n');
        printf('voicetest: threshold against learner speech -- a TTS voice is nobody\'s\n');
        printf('voicetest: student.  The second pass needs ears.\n');
    else
        printf('voicetest: %p of %p checks DISAGREE.\n',
               [% disagree, agree + disagree + abstain %]);
    endif;
enddefine;

;;; Set HERE and not only by lp_load_audio, because lp_can_hear reads it
;;; to decide whether a listening question is possible -- and server.p
;;; and the test suites reach this file with a plain `load`, which the
;;; on-demand loader never sees.  A file that is loaded knows it is.
true -> lp_audio_loaded;
