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
load 'examples/langpop/langpop.p';
load 'examples/langpop/sheet.p';

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
