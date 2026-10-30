;;; examples/langpop/tests/test_langpop_sheet.p -- the printable sheets.
;;;
;;;     ./poplog basepop11 examples/langpop/tests/test_langpop_sheet.p </dev/null
;;;
;;; Two claims are worth testing and the rest follows from them: a chart
;;; is DERIVED FROM THE GRAPH rather than drawn, so it cannot disagree
;;; with the tutor; and it fits one page, which is not something a reader
;;; can check by looking at the source.

uses poptest;
uses utf8;

vars langpop_lib = true, langpop_card_lib = true;
lconstant HERE = sys_fname_path(popfilename);
pop11_compile(HERE <> '../langpop.p');
pop11_compile(HERE <> '../sheet.p');

find_dir() -> langpop_dir;
lp_load();
lp_index();

"sheeter" -> lp_user;
"ja" -> lp_lang;
"preschool" -> lp_level;
lvars tmpdir = '/tmp/langpop-sheet-test-' sys_>< sys_real_time() sys_>< '/';
tmpdir -> lp_home_dir;

;;; ------------------------------------------------------- the grid
;;; A cell's column is the LAST VOWEL LETTER of its romaji.  That one
;;; rule is what makes the grid fall out of kana/5 instead of being
;;; placed by hand -- and a hand-placed grid is a second copy of the
;;; table, free to disagree with the first.
check('ka is in the a column', sheet_col("ka"), 1);
check('shi is in the i column, not the s row', sheet_col("shi"), 2);
check('tsu is in the u column', sheet_col("tsu"), 3);
check('fu is in the u column, where hu would be', sheet_col("fu"), 3);
check('ji is in the i column', sheet_col("ji"), 2);
check('zu is in the u column', sheet_col("zu"), 3);
check('the moraic n has no vowel and takes the first', sheet_col("n"), 1);

lvars (grid, rows) = sheet_grid("hiragana");
check_true('every row of the chart is a row of the table', rows /== []);
check('あ is the vowel row, first column',
      hd(grid(1, 1)), 'あ');
check('か is the k row, first column',
      hd(grid(lp_pos_in("k", [vowel k s t n_row h m y r w moraic g z d b p]), 1)),
      'か');

;;; The d row has holes, and they are the truth about the table rather
;;; than a bug in the chart: ぢ and づ are spellings of じ and ず, not
;;; sounds of their own, so kana.pl does not hold them.  A hand-placed
;;; grid would have quietly filled them in.
lvars dr = lp_pos_in("d", [vowel k s t n_row h m y r w moraic g z d b p]);
check('だ is there', hd(grid(dr, 1)), 'だ');
check_false('ぢ is not', grid(dr, 2));
check_false('づ is not', grid(dr, 3));
check('で is there', hd(grid(dr, 4)), 'で');
check('ど is there', hd(grid(dr, 5)), 'ど');

;;; Katakana is the same table, one script along.
lvars (kgrid, krows) = sheet_grid("katakana");
check('katakana has the same rows', length(krows), length(rows));
check('ア is the vowel row, first column', hd(kgrid(1, 1)), 'ア');

;;; ------------------------------------------------------ the pages
;;; Fits on A4, which is the one property a reader cannot check by
;;; reading the source -- and the first version did not: it was laid out
;;; at 11 rows and the voiced kana made it 16, which ran a page and a
;;; quarter.
define sheet_maxy(svg) -> m;
    lvars svg, i, j, n, m = 0, s = svg sys_>< '';
    1 -> i;
    repeat
        issubstring_lim('y="', i, false, false, s) -> j;
        quitunless(j);
        j + 3 -> j; j -> n;
        while n <= length(s) and s(n) /== `"` do n + 1 -> n endwhile;
        lvars v = strnumber(substring(j, n - j, s));
        if v and v > m then v -> m endif;
        n -> i;
    endrepeat;
enddefine;

lvars hira = sheet_chart("hiragana");
check_true('the hiragana sheet fits the page', sheet_maxy(hira) < 2970);
check_true('and uses most of it', sheet_maxy(hira) > 2000);
check_true('it is an A4 svg', issubstring('width="210mm"', hira) /== false);
check_true('with a viewBox in the same units',
           issubstring('viewBox="0 0 2100 2970"', hira) /== false);

;;; Every glyph in the table reaches the page.  A chart that silently
;;; dropped one would be worse than no chart: it is a reference, and a
;;; reference with a hole teaches the hole.
define sheet_count(svg) -> n;
    lvars svg, t, n = 0, sc, g;
    for t in lp_ask("kana_table", 0) do
        prolog_deref(prolog_arg(2, t)) -> sc;
        nextunless(sc == "hiragana");
        prolog_full_deref(prolog_arg(3, t)) -> g;
        if issubstring('>' <> (g sys_>< '') <> '<', svg) then n + 1 -> n endif;
    endfor;
enddefine;
check('69 hiragana, and all of them on the sheet', sheet_count(hira), 69);

lvars kata = sheet_chart("katakana");
check_true('the katakana sheet fits too', sheet_maxy(kata) < 2970);
check_true('and names itself in katakana',
           issubstring('カタカナ', kata) /== false);

;;; The footnote is not decoration: a reader who notices the holes in the
;;; d row deserves to be told why they are there.
check_true('the sheet explains the gaps', issubstring('ぢ', hira) /== false);

;;; The characters that are not syllables, along the foot.  They are not
;;; cells of the grid and never will be, but a learner meets っ in
;;; がっこう on day three and a reference that leaves them off is a
;;; reference with a hole in it.
check_true('っ is on the chart', issubstring('>っ<', hira) /== false);
check_true('and ゃゅょ', issubstring('>ゃ<', hira) /== false);
check_true('with what it does, not a reading it does not have',
           issubstring('a beat of silence', hira) /== false);
check_true('the katakana sheet carries ー too',
           issubstring('>ー<', kata) /== false);

;;; Each is drawn BESIDE its full-size twin, because the difference is
;;; the size and nothing else: ゃ on its own at chart size is
;;; indistinguishable from や, which is the confusion the strip exists
;;; to prevent.
check('っ is the small つ', sheet_twin('っ'), 'つ');
check('ゃ the small や', sheet_twin('ゃ'), 'や');
check('ョ the small ヨ', sheet_twin('ョ'), 'ヨ');
check('ァ the small ア', sheet_twin('ァ'), 'ア');
check('and ー has no twin', sheet_twin('ー'), '');

;;; A footer is one line until somebody writes a long one, and then it
;;; is one line that runs off the right-hand edge -- which it did, the
;;; moment the strip needed explaining.
check_true('the footer wraps rather than overrunning',
           length(zine_wrap(
               '69 kana, drawn from graph/ja/kana.pl.  The gaps in the d '
               <> 'row are real: ぢ and づ are spellings of じ and ず, not '
               <> 'sounds of their own.  The row along the foot is not '
               <> 'syllables: those characters have no reading of their '
               <> 'own.', 118)) > 1);

;;; ------------------------------------------------------- the youon
;;; Youon are COMBINATIONS, not glyphs, which is why the graph holds
;;; `youon` as a skill and not as 33 items -- so the sheet derives them,
;;; and takes the romaji from lp_romaji rather than spelling them again.
lvars yrows = sheet_youon_rows("hiragana");
check_true('every youon base ends in i',
           [% lvars r; for r in yrows do
                  unless hd(tl(r))(length(hd(tl(r)))) == `i` then r endunless
              endfor %] == []);
check_false('い itself is not a base',
            [% lvars r; for r in yrows do
                   if hd(tl(r)) = 'i' then r endif endfor %] /== []);
check_true('じ is a base, so じゃ is on the sheet',
           [% lvars r; for r in yrows do
                  if hd(tl(r)) = 'ji' then r endif endfor %] /== []);

lvars yo = sheet_youon("hiragana");
check_true('the youon sheet fits the page', sheet_maxy(yo) < 2970);
;;; The engine's own rule, not a second spelling of it: き+ゃ is kya
;;; while し+ゃ is sha, and getting that wrong is how the first version
;;; of lp_romaji turned きょ into ko.
check_true('kya', issubstring('>kya<', yo) /== false);
check_true('sha, not shya', issubstring('>sha<', yo) /== false);
check_false('and never shya', issubstring('>shya<', yo) /== false);
check_true('cha', issubstring('>cha<', yo) /== false);
check_true('ja, not jya', issubstring('>ja<', yo) /== false);
check_false('and never jya', issubstring('>jya<', yo) /== false);
check_true('pyo, from a handakuten base', issubstring('>pyo<', yo) /== false);

;;; -------------------------------------------------------- the day
;;; Read off the JOURNAL and not off the beliefs: the journal is what
;;; happened, the belief is what the tutor concluded.  A sheet of beliefs
;;; would look the same every day.
[] -> lp_journal;
check('nothing yet', length(sheet_today(0)), 0);

lp_record("hi_a", "read", 1, "right", 900);
lp_record("hi_i", "read", 1, "wrong", 3000);
lp_record("hi_u", "read", 1, "skip", 5000);
check('three answers, three rows', length(sheet_today(0)), 3);

;;; In the order they were ASKED.  A sheet is a record of a session and
;;; reads forwards, although the journal is stored most-recent-first.
lvars drows = sheet_today(0);
check('the first question is first', hd(drows)(1), "hi_a");
check('and the last is last', drows(3)(1), "hi_u");

;;; One row per item, carrying the outcome that STANDS: an item got wrong
;;; and then got right should not print twice, and should not print as
;;; wrong.
lp_record("hi_i", "read", 1, "right", 800);
check('still three rows', length(sheet_today(0)), 3);
;;; `=` and not `==`: two lists holding the same word are equal and are
;;; not identical, which is the Pop-11 trap this project has paid for
;;; before with strings as property keys.
check_true('and the corrected one reads right',
           [% lvars r; for r in sheet_today(0) do
                  if r(1) == "hi_i" then r(2) endif endfor %] = [right]);

;;; The cutoff is a cutoff, not decoration.
check('nothing from before the window',
      length(sheet_today(lp_now_ms() + 1000)), 0);

;;; An inference is not something the student did, so it is not on the
;;; sheet of what they did.
check('tier 4 is not on the sheet',
      length(sheet_today(0)), 3);

check('right is a plus', sheet_mark("right"), '+');
check('near is a tilde', sheet_mark("near"), '~');
check('a freeze is a question mark, not a cross', sheet_mark("skip"), '?');
check('wrong is a cross', sheet_mark("wrong"), 'x');

lvars day = sheet_day_svg('Tester', sheet_today(0), lp_plan());
check_true('the day sheet is A4 too', issubstring('width="210mm"', day) /== false);
check_true('it fits', sheet_maxy(day) < 2970);
check_true('it names the student', issubstring('Tester', day) /== false);
check_true('and says what the marks mean',
           issubstring('did not know', day) /== false);

;;; An empty day says so rather than printing a blank page under
;;; somebody's name.
check_true('an empty day is said, not drawn',
           issubstring('Nothing recorded yet', sheet_day_svg('Tester', [], []))
           /== false);


;;; ------------------------------------------------- kanji are bigger
;;; ONE SIZE FOR BOTH SCRIPTS IS THE MISTAKE THE TERMINAL MAKES, and the
;;; booklet was making it too: a kana is a few strokes in the em box and
;;; 18pt renders it, while 語 is fourteen strokes in the same box and the
;;; print closes the gaps up.
check_true('a kanji is ideographic', sheet_ideographic('国'));
check_true('and so is a word made of them', sheet_ideographic('電話'));
check_false('a kana is not -- it was never the problem',
            sheet_ideographic('あ'));
check_false('nor is katakana', sheet_ideographic('マン'));
check_false('nor a latin word', sheet_ideographic('water'));

;;; Mixed is ideographic, because the hard character is the one that
;;; decides: 高い is 高 plus a kana tail.
check_true('a kanji with a kana tail counts',
           sheet_ideographic('高い'));

check('an ideograph is one em', sheet_em('国'), 1.0);
check('two are two', sheet_em('電話'), 2.0);
check_true('latin is narrower', sheet_em('ab') < 2.0);

;;; THE HINT MOVES, which is what pays for the bigger size.  Under the
;;; glyph the pitch has to carry 1.36 * size; beside it, only 0.88 --
;;; so the page keeps its eight rows at 24pt instead of losing four of
;;; them.
lvars gsize, ghx, ghy;
zine_glyph_box('国', 120, 1000) -> (gsize, ghx, ghy);
check('an ideograph is set at 24pt', gsize, 170);
check('with its hint on the same baseline', ghy, 1000);
check_true('and beside it rather than under', ghx > 120);

zine_glyph_box('あ', 120, 1000) -> (gsize, ghx, ghy);
check('a kana keeps 18pt', gsize, 130);

;;; BUT ITS HINT MOVES BESIDE ANYWAY, which is not about the kana.  A
;;; kana row with the hint 62 under, followed by a kanji row at 24pt,
;;; put the kanji's top above the hint's baseline -- `neko` printed
;;; inside 日.  A page mixes the two freely, so both go beside.
check('and its hint goes beside it too', ghy, 1000);
check_true('clear of the glyph', ghx > 120);

;;; A latin term is a word and not a glyph: the hint stays underneath,
;;; which is the arrangement the page was built with and is right for
;;; the case it was built for.
zine_glyph_box('water', 120, 1000) -> (gsize, ghx, ghy);
check('a latin term keeps 18pt', gsize, 130);
check('with its hint under', ghy, 1062);
check('at the same left edge', ghx, 120);

;;; The hint is measured against the room the glyph leaves, rather than
;;; truncated at a number that was right for the old layout.
check_true('a hint beside a glyph gets fewer characters',
           zine_hint_cols(600) < zine_hint_cols(200));

;;; END TO END, on the page itself, because the two checks above would
;;; both pass with the constant wired to nothing.
lvars kpage = zine_plan_page([% "w_denwa", "hi_a" %], 0, 3, 'Next');
check_true('the page sets the kanji word at 24pt',
           issubstring('font-size="170"', kpage) /== false);
check_true('and the kana beside it at 18pt',
           issubstring('font-size="130"', kpage) /== false);
check_true('both glyphs are on it',
           issubstring('電話', kpage) /== false
           and issubstring('あ', kpage) /== false);

;;; --------------------------------------------------------- the zine
;;; Eight pages from one sheet.  The imposition is not a creative work
;;; and is not copied from anywhere: it is what folding a sheet in half
;;; three times and cutting the middle leaves you with, which is why
;;; every zine template shows the same arrangement.  These checks are
;;; the derivation, written down so it can be verified rather than
;;; trusted.

;;; Eight panels, each page exactly once.  Asked through zine_panel
;;; rather than off the table: the table is an lconstant and so is local
;;; to sheet.p, which is the right scope for it -- what a test is
;;; entitled to is the procedure, not the data behind it.
check_true('every page from 1 to 8 has a panel',
           [% lvars n; for n from 1 to 8 do
                  lvars (x, y, r) = zine_panel(n);
                  unless isinteger(x) then n endunless;
              endfor %] == []);
lvars (nx, ny, nr) = zine_panel(9);
check_false('and a ninth page does not', nx);

;;; Four columns by two rows, and no two pages share a panel.
check_true('no two pages share a panel',
           [% lvars n, m; for n from 1 to 8 do
                  for m from n + 1 to 8 do
                      lvars (xn, yn, rn) = zine_panel(n);
                      lvars (xm, ym, rm) = zine_panel(m);
                      if xn == xm and yn == ym then n endif;
                  endfor;
              endfor %] == []);

;;; The cover is bottom right and upright, because the lengthwise fold
;;; puts that panel on the outside the right way up.  If this moves, the
;;; booklet opens at the back.
lvars (cx, cy, cr) = zine_panel(1);
check('the cover is in the last column', cx, 3 * 1485);
check('on the bottom row', cy, 2100);
check('the right way up', cr, 0);

;;; The back cover sits beside it, so the two covers are adjacent on the
;;; sheet and wrap round each other once folded.
;;; `by` cannot be a variable name: it is a Pop-11 syntax word, as
;;; `fill`, `on`, `from`, `to`, `step` and `back` have each turned out
;;; to be.  Seven now.
lvars (bx, brow, br) = zine_panel(8);
check('the back cover is next to the front', bx, 2 * 1485);
check('on the same row', brow, cy);

;;; The top row is inverted and the bottom row is not.  This is the one
;;; thing a reader cannot check by looking at the source of a template,
;;; and the one thing that makes the difference between a booklet and
;;; eight panels of upside-down text.
check_true('pages 2 to 5 are on the top row, upside down',
           [% lvars n; for n from 2 to 5 do
                  lvars (x, y, r) = zine_panel(n);
                  unless y == 0 and r == 180 then n endunless;
              endfor %] == []);
check_true('pages 6, 7, 8 and 1 are on the bottom row, upright',
           [% lvars n; for n in [6 7 8 1] do
                  lvars (x, y, r) = zine_panel(n);
                  unless y == 2100 and r == 0 then n endunless;
              endfor %] == []);

;;; Reading order along each row: the top row runs 5 4 3 2 left to
;;; right BECAUSE it is upside down -- turn the sheet and it reads
;;; 2 3 4 5.
check_true('the top row descends left to right',
           [% lvars n; for n from 2 to 4 do
                  lvars (xa, ya, ra) = zine_panel(n);
                  lvars (xb, yb, rb) = zine_panel(n + 1);
                  unless xb < xa then n endunless;
              endfor %] == []);

;;; ------------------------------------------------------ the layout
lvars zs = zine_svg('Tester');
check_true('it is a landscape A4 svg',
           issubstring('width="297mm" height="210mm"', zs) /== false);
check_true('with a viewBox in the same units',
           issubstring('viewBox="0 0 5940 4200"', zs) /== false);

;;; Everything stays on the sheet.  The first draft of the cover put
;;; がんばって at 290 units a glyph, which is 1450 across a 1485 panel,
;;; and it broke out of the frame.
check_true('nothing is drawn off the sheet', sheet_maxy(zs) <= 4200);

;;; Four panels wide, so three fold lines -- and ONE cut line, spanning
;;; the middle two columns only.  A dashed line the full width would be
;;; an instruction to cut the booklet in half, which is the one mistake
;;; that cannot be undone.
lvars guides = zine_guides();
check_true('the cut line is dashed', issubstring('stroke-dasharray', guides) /== false);
check('and there is exactly one of them',
      length([% lvars i = 1, j;
                 repeat
                     issubstring_lim('stroke-dasharray', i, false, false, guides) -> j;
                     quitunless(j); j; j + 1 -> i;
                 endrepeat %]), 1);
check_true('it starts at the first fold',
           issubstring('x1="1485" y1="2100" x2="4455"', guides) /== false);
check_true('and it is labelled, because an unlabelled dashed line is a guess',
           issubstring('cut along here', guides) /== false);

;;; ----------------------------------------------------- the content
check_true('the cover carries the name', issubstring('Tester', zs) /== false);
check_true('and the level', issubstring('preschool', zs) /== false);
check_true('page 2 is where they stand',
           issubstring('Where you are', zs) /== false);
check_true('page 3 is the criteria, measured',
           issubstring('How it is going', zs) /== false);
check_true('page 6 is the ladder, which always has something on it',
           issubstring('The ladder', zs) /== false);
check_true('and says where they are on it',
           issubstring('you are here', zs) /== false);
check_true('page 8 says how to fold it',
           issubstring('Fold it', zs) /== false);
check_true('and what the marks on page 7 mean',
           issubstring('did not know', zs) /== false);

;;; The status page and :status read the same numbers.  Two renderings
;;; of one measurement is one too many -- the paper would drift from the
;;; screen and nobody would notice which was right.
lvars srows = lp_status_rows();
check_true('there are criteria to print', srows /== []);
check_true('and the first one is on the page',
           issubstring(sheet_esc(hd(srows)(1)), zs) /== false);

;;; A zine is one student's standing, so it needs a student -- unlike a
;;; kana chart, which is a picture of the graph.
lvars (zp, zw) = lp_sheet_render("zine", false);
check('a zine without a student is refused', zw, 'no_such_student');
lvars (zp2, zw2) = lp_sheet_render("zine", "sheeter");
check_false('with one it draws', zw2);
check_true('and lands on disk', sys_file_exists(zp2));

;;; ---------------------------------------------------------- wrapping
;;; Crude on purpose: the prose on a zine page is two sentences.
check('a short line is one line', length(zine_wrap('one two', 20)), 1);
check('a long one breaks at a space', length(zine_wrap('aaaa bbbb cccc dddd', 10)), 2);
check('and never mid-word',
      hd(zine_wrap('aaaa bbbb cccc', 6)), 'aaaa');
check('an empty string is no lines', length(zine_wrap('', 20)), 0);
;;; English does not break mid-word -- a wrap that split a long word
;;; across two lines without a hyphen would be worse than one that let
;;; it hang over the edge.
check('a word longer than the column still comes out whole',
      length(zine_wrap('supercalifragilistic', 5)), 1);

;;; Japanese does, because Japanese has no spaces to break at and is set
;;; that way anyway.  Printing an English-ladder booklet is what found
;;; this: every Japanese paragraph on it ran off its panel and across
;;; the three beside it.
check_true('Japanese breaks between characters',
           length(zine_wrap('いまのレベルはこれです', 6)) > 1);
;;; A kana is two columns wide, so six columns is three kana.
check('three kana to a six-column line',
      utf8_length(hd(zine_wrap('あいうえおかきくけこ', 6))), 3);

;;; Kinsoku, the one typographic rule worth keeping: a line may not
;;; BEGIN with closing punctuation, or a sentence breaks before its own
;;; full stop and the next line opens with a lone 。
check_true('a line does not start with a full stop',
           [% lvars l; for l in zine_wrap('あいう。えお。かきく。', 6) do
                  if utf8_length(l) > 0
                  and issubstring_lim('。', 1, 1, 1, l) then l endif;
              endfor %] == []);


;;; ------------------------------------------ the language it speaks
;;; A study booklet has to be readable by the person studying, and the
;;; one language they cannot be assumed to read is the one they are
;;; learning.  The first draft had every heading in English: fine for an
;;; English speaker learning Japanese, useless for the Japanese speaker
;;; learning English -- who is the harder half of the problem this
;;; project exists for.  Printing one and looking at it is what showed
;;; that, which is the third time this session that has been true.
"ja" -> lp_lang;
check('a Japanese ladder is read by an English speaker',
      lp_learner_lang(), "en");
check('its headings are English', zine_say("where"), 'Where you are');

"en" -> lp_lang;
check('an English ladder is read by a Japanese speaker',
      lp_learner_lang(), "ja");
check('and its headings are Japanese', zine_say("where"), 'いまの実力');
check('including the long ones',
      issubstring('片面印刷', zine_say("howto")), 1);

;;; The cover motto is the one exception, and it goes the other way: a
;;; single phrase in the language being LEARNED is a flourish the
;;; student will meet soon, where navigation in that language is a
;;; booklet they cannot use.
check('the motto is in the language being learned',
      zine_say_target("motto"), 'you can do this');
"ja" -> lp_lang;
check('and so it changes with the ladder, not the reader',
      zine_say_target("motto"), 'がんばって');
check('while everything else follows the reader',
      zine_say("motto"), 'you can do this');

;;; An unknown key gives back the key rather than an empty string: a
;;; missing heading should be visible on the page, not invisible.
check('an unknown key is its own name', zine_say("nosuchkey"), 'nosuchkey');

;;; A whole English-ladder booklet, checked for the defect rather than
;;; for one string.
"en" -> lp_lang; "preschool" -> lp_level;
lvars enz = zine_svg('Kenji');
check_true('the English booklet is in Japanese',
           issubstring('学習プラン', enz) /== false);
check_true('its ladder page too', issubstring('レベル表', enz) /== false);
check_false('and none of it is in English headings',
            issubstring('Where you are', enz) /== false);
check_false('nor the fold instructions',
            issubstring('Print one sided', enz) /== false);
check_true('the measured criteria are worded for the reader too',
           issubstring('正解', enz) /== false);
check_false('and not twice, in English as well',
            issubstring('% right,', enz) /== false);

;;; Which is only honest if the numbers are the SAME numbers: the page
;;; and the screen read one measurement, worded twice.
lvars sr = lp_status_rows();
check_true('there are criteria', sr /== []);
check_true('every row carries a kind the booklet can word',
           [% lvars r; for r in sr do
                  unless member(r(2), [counted audio unbuilt measured])
                  then r(2) endunless endfor %] == []);
check_true('the English wording still exists for the TUI',
           length(lp_status_text(hd(sr))) > 0);

;;; A dictionary gloss runs to a sentence.  Set as one line anchored to
;;; the right edge it ran clean across the sheet and over the three
;;; panels beside it -- nothing in SVG clips, so a line that does not
;;; fit does not wrap, it escapes.
check_true('a short gloss is left alone',
           issubstring('...', zine_hint("t_mansion", 20)) == false);
check('and is the one the READER can read', zine_hint("t_mansion", 20),
      '大邸宅');
"ja" -> lp_lang;
if lp_ilang("k_4f1a") then
    ;;; an imported kanji has no romaji and a dictionary gloss
    check_true('a long gloss is cut to the panel',
               length(zine_hint("k_4f1a", 14)) < 40);
    check_true('and says it was cut, rather than stopping mid-word',
               issubstring('...', zine_hint("k_4f1a", 14)) /== false);
else
    printf(';;; imported content not built -- gloss truncation not checked\n');
endif;
"en" -> lp_lang;
check_true('nothing escapes the English booklet', sheet_maxy(enz) <= 4200);

"ja" -> lp_lang; "preschool" -> lp_level;

;;; --------------------------------------------------------- escaping
;;; A gloss is human-written text; nothing stops one holding a quote or
;;; an angle bracket, and an SVG that swallowed one would be malformed.
check('ampersand', sheet_esc('a & b'), 'a &amp; b');
check('angle brackets', sheet_esc('<script>'), '&lt;script&gt;');
check('a quote', sheet_esc('it\'s'), 'it&apos;s');
check('kana are left alone', sheet_esc('あ'), 'あ');

;;; ----------------------------------------------------------- render
lvars (path, why) = lp_sheet_render("hiragana", false);
check_false('a chart needs no student', why);
check_true('and lands on disk', sys_file_exists(path));
check_true('under the data directory', issubstring(tmpdir, path) /== false);

lvars (p2, w2) = lp_sheet_render("klingon", false);
check('an unknown sheet is named as one', w2, 'no_such_style');
check_false('and nothing is written', p2);

;;; today needs a student, and says so rather than drawing an empty page
lvars (p3, w3) = lp_sheet_render("today", false);
check('today without a student is refused', w3, 'no_such_student');

sysobey('rm -rf ' <> tmpdir);
false -> lp_home_dir;

test_summary();
