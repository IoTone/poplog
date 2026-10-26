;;; examples/langpop/tests/test_langpop_card.p -- suite for card.p.
;;;
;;;     ./poplog basepop11 examples/langpop/tests/test_langpop_card.p </dev/null
;;;
;;; A renderer is tested by reading what it wrote.  Three properties are
;;; worth the trouble and the rest follows from them: the right form is
;;; on the card, the text that reaches it is escaped, and the same item
;;; renders byte for byte the same twice -- because a card that is not
;;; deterministic cannot be diffed in CI, which was the whole argument
;;; for rendering it this way.

uses poptest;
uses utf8;

vars langpop_lib = true, langpop_card_lib = true;
load 'examples/langpop/langpop.p';
load 'examples/langpop/card.p';

find_dir() -> langpop_dir;
lp_load();
lp_index();

;;; Cards go to a temp dir, never a real person's home.
lvars tmpdir = '/tmp/langpop-card-test-' sys_>< sys_real_time() sys_>< '/';
tmpdir -> lp_home_dir;

define has(needle, hay);
    lvars needle, hay;
    issubstring(needle, hay) /== false;
enddefine;

;;; ------------------------------------------------- which form is the term
;;; The four item kinds want four different answers, and the rule that
;;; produces them is one ordered list plus a question about which entry
;;; it stopped at.
lvars term, reading;

lp_card_term("hi_a") -> (term, reading);
check('a kana grapheme shows the glyph', term sys_>< '', 'あ');
check('with its romaji above', reading sys_>< '', 'a');

lp_card_term("w_gakkou") -> (term, reading);
check('a word shows its hiragana', term sys_>< '', 'がっこう');
check('with its romaji above', reading sys_>< '', 'gakkou');

;;; A loanword trap is an ENGLISH item, so its face is the English word.
;;; This used to assert マンション as the term, which is how the card came
;;; out -- and meant `mansion`, the word the item exists to teach,
;;; appeared nowhere on it.  The katakana is the thing being contrasted
;;; with, so it belongs on the line above.
lp_card_term("t_mansion") -> (term, reading);
check('a loanword trap shows the English word', term sys_>< '', 'mansion');
check('with the katakana it is confused with above',
      reading sys_>< '', 'マンション');

;;; A sound contrast has an IPA form and nothing else, so the IPA is the
;;; term -- and the line above it is the JAPANESE gloss, because the
;;; learner reads Japanese and the point of the card is the distinction
;;; their own language does not make.
lp_card_term("s_r_l") -> (term, reading);
check('a sound contrast shows the IPA', term sys_>< '', '/r/ - /l/');
check('with the Japanese explanation above',
      reading sys_>< '', 'ラ行では区別されない');

;;; A skill has no written form at all, and nothing is better than a
;;; blank card.
lp_card_term("mora_count") -> (term, reading);
check('a skill has nothing to draw', term, false);

;;; ------------------------------------------------------------- the SVG
lvars svg = lp_card_svg("w_neko", "word");

check_true('it is an SVG document', has('<?xml version="1.0"', svg));
check_true('with the namespace', has('xmlns="http://www.w3.org/2000/svg"', svg));
check_true('and it closes', has('</svg>', svg));
check_true('the term is on it', has('ねこ', svg));
check_true('the reading is on it', has('>neko<', svg));
check_true('the gloss is on it', has('>cat<', svg));
check_true('and the provenance, which is why items carry a source',
           has('own(starter_list)', svg));
check_true('the font is named, because the glyphs come from it',
           has('Noto Sans JP', svg));

;;; A multi-word family name must be quoted or a strict renderer drops the
;;; whole list and the kana come out as boxes.
check_true('and each family is quoted', has('&apos;Noto Sans JP&apos;', svg));

;;; A kana grapheme's English gloss IS its romaji; printing both puts the
;;; same two letters on one card twice.
lvars asvg = lp_card_svg("hi_a", "word");
check('a gloss that only repeats the reading is dropped',
      length([% lvars j;
                 for j from 1 to length(asvg) - 2 do
                     if substring(j, 3, asvg) = '>a<' then j endif
                 endfor %]),
      1);

;;; ----------------------------------------------------------- escaping
;;; Nothing in the graph carries a < today, which is exactly why this is
;;; tested on text handed straight to the escaper rather than on an item:
;;; the day something does, the card must not become malformed XML.
check('ampersand', lp_card_esc('Tom & Jerry'), 'Tom &amp; Jerry');
check('angle brackets', lp_card_esc('<script>'), '&lt;script&gt;');
check('quotes', lp_card_esc('say "it\'s"'), 'say &quot;it&apos;s&quot;');
check('nothing to escape', lp_card_esc('plain'), 'plain');
check('UTF-8 passes through', lp_card_esc('ねこ'), 'ねこ');

;;; --------------------------------------------------------- fitting
;;; The card is a fixed size, so the term shrinks to fit rather than
;;; running off the edge.  マンション at the full 150pt is half again as
;;; wide as the card.
check_true('a CJK glyph is about one em',
           abs(lp_card_em_width('ねこ') - 2.0) < 0.01);
check_true('and Latin is narrower, per character',
           lp_card_em_width('ab') < lp_card_em_width('ねこ'));
check('a short term keeps the full size',
      lp_card_fit('あ', 150, 568), 150);
check_true('a long one is cut down', lp_card_fit('マンション', 150, 568) < 150);
check_true('far enough down to fit',
           lp_card_em_width('マンション') * lp_card_fit('マンション', 150, 568)
               <= 568);
check('an empty term does not divide by zero', lp_card_fit('', 34, 568), 34);

;;; --------------------------------------------------------- the file
lvars path, w, h, why;
lp_card_render("w_neko", "word") -> (path, w, h, why);
check('render reports no reason to fail', why, false);
check('width', w, 640);
check('height', h, 400);
check_true('the file is written', sys_file_exists(path));
check_true('under the cards directory', has('/cards/', path));
check_true('named for the item and the style', has('w_neko-word.svg', path));
check('and holds what lp_card_svg builds', lp_read_file(path), svg);

;;; Determinism is the property the whole approach was chosen for: a
;;; rendering regression has to show up as a failing diff.
lvars first = lp_read_file(path);
lp_card_render("w_neko", "word") -> (path, w, h, why);
check('the same item renders byte for byte the same', lp_read_file(path), first);

;;; ------------------------------------------------------ the glyph card
;;; The second canvas, and the reason it exists: this one is shown WHILE
;;; the question is being asked, so the two things the word card carries
;;; above and below the term -- the reading and the gloss -- are the two
;;; things it must not carry.  A bigger glyph that gives the answer away
;;; is not a bigger glyph, it is the answer.
lvars gpath, gw, gh, gwhy;
lp_card_render("k_56fd", "glyph") -> (gpath, gw, gh, gwhy);
check('the glyph style is built', gwhy, false);
check('and is square, because a kanji is', gw, gh);

lvars gsvg = lp_read_file(gpath);
check_true('the glyph is on it', has('国', gsvg));
check_false('its reading is NOT', has('くに', gsvg));
check_false('nor its gloss', has('country', gsvg));

;;; The contrast, stated rather than assumed: the word card carries both,
;;; which is exactly why it cannot be the one shown at a prompt.
lvars wpath, ww, wh, wwhy;
lp_card_render("k_56fd", "word") -> (wpath, ww, wh, wwhy);
lvars wsvg = lp_read_file(wpath);
check_true('the word card does carry the reading', has('くに', wsvg));
check_true('and the gloss', has('country', wsvg));

;;; Provenance survives, because it names the source and not the answer.
check_true('the glyph card still says where the item came from',
           has('kanjidic2', gsvg));

;;; Both canvases are reported, because term-image.py needs the aspect to
;;; claim the right number of terminal rows and a client needs it to lay
;;; the picture out at all.
lvars dw, dh;
lp_card_dims("glyph") -> (dw, dh);
check('the glyph canvas is square', dw, dh);
lp_card_dims("word") -> (dw, dh);
check_true('the word canvas is wider than tall', dw > dh);

;;; A two-kanji word on one square: the fitter is the word card's, so it
;;; shrinks to fit rather than running off the edge.
lp_card_render("w_denwa", "glyph") -> (gpath, gw, gh, gwhy);
check('a two-kanji word draws', gwhy, false);
check_true('with both characters', has('電話', lp_read_file(gpath)));
check_false('and still no reading', has('でんわ',
                                        lp_read_file(gpath)));

;;; ----------------------------------------------------------- refusals
lp_card_render("nonesuch", "word") -> (path, w, h, why);
check('an unknown item', why, 'no_such_item');
check('and no file', path, false);

lp_card_render("mora_count", "word") -> (path, w, h, why);
check('nothing to draw', why, 'no_written_form');

lp_card_render("hi_a", "hologram") -> (path, w, h, why);
check('a style that does not exist', why, 'no_such_style');

;;; stroke order and sentence-in-context are in the design and are not
;;; built; a client has to be able to tell that from a typo.
lp_card_render("hi_a", "stroke") -> (path, w, h, why);
check('a designed style that is not built', why, 'style_not_built');
lp_card_render("hi_a", "sentence") -> (path, w, h, why);
check('the other one', why, 'style_not_built');

sysobey('rm -rf ' <> tmpdir);
test_summary();
