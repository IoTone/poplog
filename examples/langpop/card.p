/* examples/langpop/card.p -- langpop/card.render: the item as a picture.

   A terminal can print あ.  It cannot print あ at 160 points with its
   reading in furigana position above it, which is the one view that
   teaches a glyph rather than merely naming it.  So the design has a
   render method rather than a TUI feature: the TUI shells out to open(1)
   like anybody else, and a non-Pop-11 caller gets the identical picture
   by the identical route.

   V1 RENDERS SVG, NOT A RASTER, and that is a deliberate departure from
   the design, which specified gfx_text over a Noto Sans JP atlas drawn
   headless.  The reason is that the headless path does not exist yet in a
   form Pop-11 can drive: tools/validate-gfx-headless.sh runs a standalone
   C++ harness (pop/extern/lib/imgui_headless.cpp) that draws one
   hard-coded scene, and the Pop-11 gfx_* surface needs pop_gfx_init,
   which opens a window.  Turning that into a renderer langpop can call
   means new C exports, a build flag and a PPM-to-PNG step, on Linux only
   -- which is a graphics-backend change, not a langpop change.

   SVG keeps every property card.render was asked for and costs none of
   that.  The text is still drawn from the font, by the viewer, named as a
   family rather than rasterised here; the output is deterministic and
   diffable in CI, which a GPU rasterisation is not; it opens on all four
   platforms with no graphics build; and it carries its own provenance.
   The design's rule survives intact: if the output contains text the
   student is asked to read, it came from the font.

   What SVG genuinely cannot do is the other two styles -- stroke order
   wants line drawing frame by frame, and both of those want the gfx path.
   They answer with a typed error rather than nothing, so a client learns
   the method exists and the style does not yet.

   Loaded on top of langpop.p; used by server.p (langpop/card.render) and
   by the TUI's :card command.
*/

;;; The term is measured in codepoints and width classes, not bytes.
uses utf8;

;;; ---------------------------------------------------------- the canvas
;;; Fixed geometry, because the output has to be diffable: a card whose
;;; size depended on the text would change shape when a gloss was edited
;;; and every card would differ from every other.
lconstant
    CARD_W       = 640,
    CARD_H       = 400,
    CARD_PAD     = 36,
    TERM_SIZE    = 150,       ;;; the glyph, which is the whole point
    READ_SIZE    = 34,        ;;; furigana position, above the term
    GLOSS_SIZE   = 30,
    FOOT_SIZE    = 17,
;

;;; ---------------------------------------------------- the glyph canvas
;;; A SECOND, SQUARE CANVAS, for the view that is shown WHILE a question
;;; is being asked.  The word card cannot do that job: it carries the
;;; reading in furigana position and the gloss below, which are the two
;;; things the student is being asked for.  Showing it at the prompt
;;; would not be a bigger glyph, it would be the answer.
;;;
;;; So the glyph style is the term and nothing else, on a square because
;;; a kanji is square and the empty width of a 8:5 card is where the
;;; glyph could have been.  300 units of 420 is the ideograph at 71% of
;;; the canvas, which is roughly where a kanji sits on a flashcard.
lconstant
    GLYPH_W      = 420,
    GLYPH_H      = 420,
    GLYPH_PAD    = 30,
    GLYPH_SIZE   = 300,
;

;;; The family NAME, not a file: the viewer resolves it, and naming the
;;; static Regular face keeps it off the variable font whose default
;;; instance renders a stop too light (docs/bugs/imgui-atlas-ascii-only.md
;;; has the measurements).
;;; Quoted, each of them: an unquoted multi-word family name is not valid
;;; CSS and a strict renderer drops the whole list, which lands the card on
;;; the default face -- with the kana showing as boxes.
lconstant CARD_FONT =
    '&apos;Noto Sans JP&apos;, &apos;Hiragino Sans&apos;, '
    <> '&apos;Yu Gothic&apos;, Meiryo, sans-serif';

;;; `glyph` is built and is the second one that is; stroke order and
;;; sentence-in-context still want the gfx path.
lconstant CARD_STYLES = [word glyph stroke sentence];

;;; Per style, because there are two canvases now and both callers -- the
;;; protocol, which puts them in the reply, and term-image.py, which
;;; needs the aspect to claim the right number of terminal rows -- have
;;; to be told which one they got.
define lp_card_dims(style) -> (w, h);
    lvars style, w, h;
    if style == "glyph" then (GLYPH_W, GLYPH_H) else (CARD_W, CARD_H) endif
        -> (w, h);
enddefine;

;;; -------------------------------------------------------------- escaping
;;; Five characters, and all five matter: a gloss is human-written text
;;; and an item id is an atom, but the provenance line carries a term
;;; printed by lp_term_str and nothing stops that holding a quote.
define lp_card_esc(s) -> out;
    lvars s, c, out = '';
    for c in_string (s sys_>< '') do
        if     c == `&` then out <> '&amp;'  -> out
        elseif c == `<` then out <> '&lt;'   -> out
        elseif c == `>` then out <> '&gt;'   -> out
        elseif c == `"` then out <> '&quot;' -> out
        elseif c == `'` then out <> '&apos;' -> out
        else                 out <> consstring(c, 1) -> out
        endif;
    endfor;
enddefine;

;;; lp_jkey lives in server.p, which card.p must not depend on -- the TUI
;;; loads one and not the other.
define lp_jkey_or(x) -> s;
    lvars x;
    if x == false or isundef(x) then '?' else x sys_>< '' endif -> s;
enddefine;

;;; ------------------------------------------------------- what to show
;;; The term is the form the student has to RECOGNISE, and what goes in
;;; the furigana slot above it is whatever helps them get there.  Which
;;; form that is depends on the item, and the four kinds in the graph want
;;; four different answers:
;;;
;;;   a kana grapheme      あ          with romaji above          a / あ
;;;   a starter word       ねこ        with romaji above           neko / ねこ
;;;   a loanword trap      マンション   with romaji above
;;;   an English contrast  /r/ - /l/   with the JAPANESE gloss above,
;;;                                    because the learner reads Japanese
;;;                                    and the point of the card is the
;;;                                    thing their language does not do
;;;
;;; So the term is the first form that exists in recognition order, and
;;; the line above it is chosen from which form that turned out to be.
;;; A sound contrast has an ipa form and nothing else, which is why the
;;; ipa is a term here and not only a pronunciation guide.
;;; The term is the form in the item's OWN language, and so the order
;;; depends on it.  Two stale orders were fixed here in turn: a flat
;;; hiragana-first list made the card for 山 come out as a card reading
;;; やま with no reading line at all, and putting kanji first then made a
;;; loanword trap come out as マンション with the English word nowhere on
;;; it.  A card for 山 is 山 over やま; a card for `mansion` is `mansion`
;;; over マンション.
lconstant TERM_ORDER_JA = [kanji hiragana katakana latin ipa];
lconstant TERM_ORDER_EN = [latin ipa katakana hiragana kanji];

define lp_card_term(i) -> (term, reading);
    lvars i, term = false, reading = false, sc, found = false;
    for sc in (if lp_ilang(i) == "en" then TERM_ORDER_EN
               else TERM_ORDER_JA endif) do
        lp_form_of(i, sc) -> term;
        if term then sc -> found; quitloop endif;
    endfor;
    returnunless(found);
    if found == "ipa" then
        ;;; a sound contrast: the line above is the Japanese gloss,
        ;;; because the point of the card is what their language does not
        ;;; do
        lp_gloss_of(i, "ja") -> reading;
    elseif found == "latin" then
        ;;; The KATAKANA first where there is one, and the pronunciation
        ;;; otherwise.  That is the whole item on one card: `mansion`
        ;;; over マンション over 大邸宅.
        ;;;
        ;;; The order was the other way round, and it was right until the
        ;;; traps were enriched from CMUdict -- at which point every trap
        ;;; card quietly swapped マンション for /mˈænʃən/ and stopped
        ;;; showing the thing the item exists to contrast.  A katakana
        ;;; form on an English item means the word is a loanword trap;
        ;;; the IPA is a pronunciation guide, and the trap is the point.
        lp_form_of(i, "katakana") or lp_form_of(i, "ipa") -> reading;
    elseif found == "kanji" then
        ;;; The reading of a character or a kanji-written word is its
        ;;; kana, which is the one thing it has and the romaji is not.
        ;;; Either syllabary: an on-reading is conventionally katakana.
        lp_form_of(i, "hiragana") or lp_form_of(i, "katakana") -> reading;
    else
        lp_form_of(i, "romaji") -> reading;
    endif;
enddefine;

lconstant NARROW_EM = 0.58;

define lp_card_em_width(s) -> em;
    lvars s, cp, em = 0.0;
    utf8_appcodes(s sys_>< '',
        procedure(cp);
            lvars cp;
            if cp >= 16:2E80 then em + 1.0 -> em      ;;; CJK, kana, fullwidth
            else                  em + NARROW_EM -> em
            endif;
        endprocedure);
enddefine;

define lp_card_fit(s, max_size, avail) -> size;
    lvars s, max_size, avail, em = lp_card_em_width(s), size = max_size;
    ;;; intof and not round: rounding UP is how a fitted term still
    ;;; overflows, by a point or two, which is the bug this exists to stop.
    if em > 0.0 and em * max_size > avail then
        intof(avail / em) -> size;
    endif;
enddefine;

;;; ------------------------------------------------------------ the SVG
;;; The gloss a LEARNER needs, which is the one in their own language.
;;;
;;; This used to be lp_gloss_of(i, "en") flat, which is right for a
;;; Japanese item read by an English speaker and exactly backwards for an
;;; English item read by a Japanese one: the card for `water` printed
;;; "the liquid we drink" while 水 sat in the graph, hand-written, and
;;; never appeared on anything.
;;;
;;; The graph teaches two languages to each other's speakers, so the
;;; language being studied is lp_ilang(item) and the learner's own is the
;;; other one.  That is a two-language assumption and it is stated here
;;; rather than assumed silently; a third language would need the
;;; student's L1 on the profile instead.
;;; Keyed off the ITEM's language rather than off lp_lang, because a
;;; card can be drawn for an item from either ladder; lp_learner_lang
;;; answers the same question for the session as a whole.
define lp_card_gloss(i) -> g;
    lvars i, g, mine = lp_ilang(i), theirs;
    if mine == "ja" then "en" else "ja" endif -> theirs;
    ;;; falling back to the item's own language, because an imported
    ;;; Japanese word carries an English gloss and nothing else
    lp_gloss_of(i, theirs) or lp_gloss_of(i, mine) -> g;
enddefine;

;;; the line the provenance asks for.  own(...) is ours to publish;
;;; anything else names where the fact came from, which is the whole
;;; reason every item carries a source in the first place.
;;;
;;; On the glyph card too, and deliberately: it names the kind, the
;;; language, the rung and the source, and not one of those is the
;;; answer to the question being asked over the top of it.
define lp_card_foot(i) -> foot;
    lvars i, foot;
    (lp_jkey_or(lp_kind(i)) <> ' · ' <> lp_jkey_or(lp_ilang(i))
     <> ' ' <> lp_jkey_or(lp_ilevel(i))
     <> '   ' <> lp_term_str(lp_isrc(i))) -> foot;
enddefine;

;;; The term, as big as the square will take, and nothing that answers
;;; anything.  lp_card_fit is the same fitter the word card uses, so a
;;; two-kanji word shrinks to fit rather than running off the edge.
define lp_glyph_svg(i) -> svg;
    lvars i, svg, term, reading, mid = GLYPH_W / 2,
          avail = GLYPH_W - 2 * GLYPH_PAD, tsize;
    lp_card_term(i) -> (term, reading);
    lp_card_fit(term, GLYPH_SIZE, avail) -> tsize;

    '<?xml version="1.0" encoding="UTF-8"?>\n'
    <> sprintf('<svg xmlns="http://www.w3.org/2000/svg" width="%p" '
               <> 'height="%p" viewBox="0 0 %p %p" role="img" '
               <> 'aria-label="%p">\n',
               [% GLYPH_W, GLYPH_H, GLYPH_W, GLYPH_H,
                  lp_card_esc(i sys_>< '') %])
    <> sprintf('  <title>%p</title>\n', [% lp_card_esc(i sys_>< '') %])
    <> '  <rect width="100%" height="100%" fill="#faf9f6"/>\n'
    <> sprintf('  <g font-family="%p" text-anchor="middle">\n',
               [% CARD_FONT %])
    ;;; Centred on the square rather than sitting on a baseline a third
    ;;; of the way up: dominant-baseline is honoured by every renderer
    ;;; that can draw this font at all.
    <> sprintf('    <text x="%p" y="%p" font-size="%p" fill="#1b1a17" '
               <> 'font-weight="500" dominant-baseline="central">%p</text>\n',
               [% mid, (GLYPH_H - 34) / 2, tsize, lp_card_esc(term) %])
    <> sprintf('    <text x="%p" y="%p" font-size="%p" fill="#8a8275">'
               <> '%p</text>\n',
               [% mid, GLYPH_H - 18, FOOT_SIZE,
                  lp_card_esc(lp_card_foot(i)) %])
    <> '  </g>\n</svg>\n' -> svg;
enddefine;

define lp_card_svg(i, style) -> svg;
    lvars i, style, svg, term, reading, gloss, foot, mid = CARD_W / 2,
          avail = CARD_W - 2 * CARD_PAD, tsize, rsize;
    lp_card_term(i) -> (term, reading);
    lp_card_gloss(i) -> gloss;

    ;;; A kana grapheme's English gloss IS its romaji, so printing both
    ;;; puts "a" twice on one card and says nothing the second time.
    if gloss and reading and lp_lower(gloss sys_>< '') = lp_lower(reading sys_>< '')
    then false -> gloss endif;

    lp_card_fit(term, TERM_SIZE, avail) -> tsize;
    lp_card_fit(if reading then reading else '' endif, READ_SIZE, avail) -> rsize;

    lp_card_foot(i) -> foot;

    '<?xml version="1.0" encoding="UTF-8"?>\n'
    <> sprintf('<svg xmlns="http://www.w3.org/2000/svg" width="%p" height="%p" '
               <> 'viewBox="0 0 %p %p" role="img" aria-label="%p">\n',
               [% CARD_W, CARD_H, CARD_W, CARD_H,
                  lp_card_esc(i sys_>< '') %])
    <> sprintf('  <title>%p</title>\n', [% lp_card_esc(i sys_>< '') %])
    <> '  <rect width="100%" height="100%" fill="#faf9f6"/>\n'
    <> sprintf('  <rect x="%p" y="%p" width="%p" height="%p" fill="none" '
               <> 'stroke="#d9d5cc" stroke-width="2" rx="10"/>\n',
               [% 14, 14, CARD_W - 28, CARD_H - 28 %])
    <> sprintf('  <g font-family="%p" text-anchor="middle">\n', [% CARD_FONT %])
       -> svg;

    ;;; the reading sits above the term, where furigana go
    if reading then
        svg <> sprintf('    <text x="%p" y="%p" font-size="%p" fill="#6b6457">'
                       <> '%p</text>\n',
                       [% mid, CARD_PAD + READ_SIZE, rsize,
                          lp_card_esc(reading) %]) -> svg;
    endif;

    svg <> sprintf('    <text x="%p" y="%p" font-size="%p" fill="#1b1a17" '
                   <> 'font-weight="500">%p</text>\n',
                   [% mid, CARD_PAD + READ_SIZE + TERM_SIZE, tsize,
                      lp_card_esc(term) %]) -> svg;

    if gloss then
        svg <> sprintf('    <text x="%p" y="%p" font-size="%p" fill="#2f4a7a">'
                       <> '%p</text>\n',
                       [% mid, CARD_PAD + READ_SIZE + TERM_SIZE + GLOSS_SIZE + 26,
                          GLOSS_SIZE, lp_card_esc(gloss) %]) -> svg;
    endif;

    svg <> sprintf('    <line x1="%p" y1="%p" x2="%p" y2="%p" '
                   <> 'stroke="#e2ded4" stroke-width="1"/>\n',
                   [% CARD_PAD, CARD_H - 56, CARD_W - CARD_PAD, CARD_H - 56 %])
        <> sprintf('    <text x="%p" y="%p" font-size="%p" fill="#8a8275">'
                   <> '%p</text>\n',
                   [% mid, CARD_H - 30, FOOT_SIZE, lp_card_esc(foot) %])
        <> '  </g>\n</svg>\n' -> svg;
enddefine;

;;; --------------------------------------------------------- the method
;;; Returns a path, a size and WHY, where why is false on success and a
;;; reason word otherwise, so both callers (the protocol, which turns it
;;; into a typed error, and the TUI, which prints it) read the same
;;; answer rather than each deciding what counts as a failure.
define lp_card_dir() -> d;
    lvars d = lp_home() <> 'cards/';
enddefine;

;;; No back versions.  syscreate keeps pop_file_versions of a file by
;;; renaming the old one with a trailing `-` (REF * SYSIO), so every
;;; re-render left a stale w_yama-word.svg- beside the card -- clutter in
;;; somebody's home directory, and of a file that is regenerated from the
;;; graph on demand.
define lp_card_render(i, style) -> (path, w, h, why);
    lvars i, style, path = false, w = CARD_W, h = CARD_H, why = false,
          term, reading;
    dlocal pop_file_versions = false;
    unless lp_kind(i) then 'no_such_item' -> why; return endunless;
    unless member(style, CARD_STYLES) then
        'no_such_style' -> why; return;
    endunless;
    unless style == "word" or style == "glyph" then
        ;;; stroke order and sentence-in-context both want line drawing
        ;;; frame by frame, which is the gfx path and not this one.
        'style_not_built' -> why; return;
    endunless;
    lp_card_dims(style) -> (w, h);
    lp_card_term(i) -> (term, reading);
    unless term then 'no_written_form' -> why; return endunless;

    unless sys_file_exists(lp_card_dir()) then
        sysobey('mkdir -p ' <> lp_card_dir());
    endunless;
    lp_card_dir() <> (i sys_>< '') <> '-' <> (style sys_>< '') <> '.svg' -> path;
    lp_write_file(path,
                  if style == "glyph" then lp_glyph_svg(i)
                  else lp_card_svg(i, style) endif);
enddefine;

;;; The system viewer, which is the whole of the graphics requirement:
;;; "a system call to run an external program is probably good enough".
;;; --------------------------------------------------- in the terminal
;;; The viewer opens a window, which is right for :card and wrong in the
;;; middle of a question: it takes the focus off the thing the student is
;;; being asked to read.  A terminal that can draw a picture should draw
;;; it where the question is.
;;;
;;; Two protocols, one converter and three escape dialects' worth of
;;; base64 live in tools/term-image.py, for the same reason the mora
;;; scorer and the level meter do: Pop-11 names the command and reads
;;; the status.  THE STATUS IS THE INTERFACE --
;;;
;;;     0  drawn        2  no image protocol here
;;;     3  no SVG converter installed    4  the file is unreadable
;;;
;;; -- and the caller needs the difference, because `2` is a terminal to
;;; be named in a one-line hint and `3` is a machine missing
;;; rsvg-convert.  Returning a plain false would have made those the
;;; same thing and the hint would have been wrong half the time.
define lp_card_inline(path, cols) -> why;
    lvars path, cols, why = false, st;
    ;;; Pop-11's own buffer first: the escape sequence is written by a
    ;;; child process straight to the shared descriptor, so anything
    ;;; still sitting in popdevout would land AFTER the picture.
    sysflush(popdevout);
    sysobey('python3 -I ' <> langpop_dir <> 'tools/term-image.py \''
            <> path <> '\' --cols ' <> (cols sys_>< '') <> ' 2>/dev/null');
    ;;; POP_STATUS IS THE WAIT STATUS, not the exit code: a child that
    ;;; exits 2 leaves 512 here.  Everything else in the tree compares it
    ;;; with 0, where the two readings agree, and this is the first
    ;;; caller that needs to tell 2 from 3 -- so it shifts, and says why.
    (pop_status div 256) -> st;
    if      st == 0 then false
    elseif  st == 2 then 'no_protocol'
    elseif  st == 3 then 'no_converter'
    else                 'no_picture'
    endif -> why;
enddefine;

define lp_card_open(path) -> ok;
    lvars path, ok = false, opener;
    for opener in ['/usr/bin/open' '/usr/bin/xdg-open' '/usr/bin/see'] do
        if sys_file_exists(opener) then
            sysobey(opener <> ' ' <> path);
            true -> ok; return;
        endif;
    endfor;
enddefine;
