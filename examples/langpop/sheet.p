;;; examples/langpop/sheet.p -- printable sheets, generated from the graph.
;;;
;;;     ./poplog basepop11 examples/langpop/langpop.p --chart hiragana
;;;     ./poplog basepop11 examples/langpop/langpop.p --sheet --user bob
;;;
;;; and `:chart katakana` / `:sheet` inside a session.
;;;
;;; Two things a learner can take away from the screen and put on a desk:
;;; a syllabary chart, and the day's work.  Both are SVG at A4, both are
;;; GENERATED FROM THE GRAPH rather than fetched, and that is the point
;;; rather than a convenience.
;;;
;;; Why generated.  A kana chart downloaded from somewhere is a picture
;;; of somebody else's table: it can disagree with ours and nothing would
;;; notice, it carries whatever licence it carries, and it goes stale the
;;; moment the graph changes -- as it just did, when the 46 voiced kana
;;; arrived.  A chart drawn from kana/5 cannot disagree with the tutor,
;;; because it is the same 138 facts the tutor reads.  It is the same
;;; argument import.p makes about content: the repo holds the curation
;;; and derives the rest.
;;;
;;; And the grid is derived too, not laid out by hand.  A cell's COLUMN
;;; is the last vowel letter of its romaji -- ka -> a, shi -> i, tsu -> u
;;; -- and its ROW is the row named in the fact.  So a row with a gap has
;;; a gap on the sheet: the d row prints だ・で・ど with two holes, which
;;; is exactly the truth about the table (see kana.pl on ぢ and づ) and
;;; would have been papered over by a hand-placed grid.

;;; A library, like card.p and unlike dump.p: langpop.p compiles it on
;;; demand, so a session that never prints a sheet pays nothing for it
;;; and the TUI works unchanged if the file is absent.  Which is why
;;; there is no `load` here -- the engine is already compiled by the time
;;; this is.
uses utf8;
uses datetime;                          ;;; dt_iso, for the date on a sheet

;;; A4 portrait, in tenths of a millimetre, so the numbers are integers
;;; and the page prints at its true size.  width/height in mm and a
;;; viewBox in the same units is what makes a browser's "print" land on
;;; real paper rather than on a 96dpi guess.
lconstant
    PAGE_W = 2100, PAGE_H = 2970, PAGE_M = 150,
    SHEET_STYLES = [hiragana katakana youon];

;;; Where in a list, or 0.  Defined here because the grid builder and the
;;; youon sheet both want it and Pop-11 wants it defined first.
define lp_pos_in(x, l) -> n;
    lvars x, l, i = 0, y;
    0 -> n;
    for y in l do i + 1 -> i; if y == x then i -> n; return endif endfor;
enddefine;

lconstant SHEET_FONT =
    '&apos;Noto Sans JP&apos;, &apos;Hiragino Sans&apos;, '
    <> '&apos;Yu Gothic&apos;, Meiryo, sans-serif';

;;; The gojuon order, named here because it is a TEACHING order and not a
;;; property of the glyphs: kana/5 carries the row, and this says which
;;; row comes first.  The voiced rows follow the plain ones, which is how
;;; every chart a learner will meet elsewhere is laid out.
lconstant ROW_ORDER =
    [vowel k s t n_row h m y r w moraic g z d b p];

lconstant VOWELS = [a i u e o];

vars sheet_out = false, sheet_style = "hiragana", sheet_user = false,
     sheet_lang = "ja";

;;; ------------------------------------------------------------ escaping
;;; The same five characters card.p escapes, and for the same reason: a
;;; gloss is human-written and a provenance term is printed by
;;; lp_term_str, which nothing stops holding a quote.
define sheet_esc(s) -> out;
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

;;; `fill` cannot be the parameter name: it is a Pop-11 syntax word, as
;;; `on`, `from`, `to`, `step` and `back` have each turned out to be.
define sheet_text(x, y, size, ink, anchor, s) -> out;
    lvars x, y, size, ink, anchor, s, out;
    sprintf('    <text x="%p" y="%p" font-size="%p" fill="%p" '
            <> 'text-anchor="%p">%p</text>\n',
            [% x, y, size, ink, anchor, sheet_esc(s) %]) -> out;
enddefine;

define sheet_head(title, sub) -> out;
    lvars title, sub, out;
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    <> sprintf('<svg xmlns="http://www.w3.org/2000/svg" '
               <> 'width="210mm" height="297mm" viewBox="0 0 %p %p" '
               <> 'role="img" aria-label="%p">\n',
               [% PAGE_W, PAGE_H, sheet_esc(title) %])
    <> sprintf('  <title>%p</title>\n', [% sheet_esc(title) %])
    <> '  <rect width="100%" height="100%" fill="#ffffff"/>\n'
    <> sprintf('  <g font-family="%p">\n', [% SHEET_FONT %])
    <> sheet_text(PAGE_M, 220, 64, '#1b1a17', 'start', title)
    <> sheet_text(PAGE_W - PAGE_M, 220, 36, '#8a8275', 'end', sub)
    <> sprintf('    <line x1="%p" y1="260" x2="%p" y2="260" '
               <> 'stroke="#d9d5cc" stroke-width="3"/>\n',
               [% PAGE_M, PAGE_W - PAGE_M %]) -> out;
enddefine;

define sheet_foot(note) -> out;
    lvars note, out;
    sprintf('    <line x1="%p" y1="%p" x2="%p" y2="%p" '
            <> 'stroke="#e2ded4" stroke-width="2"/>\n',
            [% PAGE_M, PAGE_H - 190, PAGE_W - PAGE_M, PAGE_H - 190 %])
    <> sheet_text(PAGE_M, PAGE_H - 130, 28, '#8a8275', 'start', note)
    <> '  </g>\n</svg>\n' -> out;
enddefine;

;;; -------------------------------------------------------- the chart
;;; Which column a kana sits in: the last vowel letter of its romaji.
;;; This is the one rule that makes the grid fall out of the table --
;;; shi lands under i, tsu under u, fu under u -- rather than being
;;; placed by hand and able to disagree with the fact it is drawing.
;;; The moraic n has no vowel and gets the first column.
define sheet_col(rom) -> n;
    lvars rom, s = rom sys_>< '', i, c, n = 0;
    for i from length(s) by -1 to 1 do
        s(i) -> c;
        if c == `a` then 1 -> n; return
        elseif c == `i` then 2 -> n; return
        elseif c == `u` then 3 -> n; return
        elseif c == `e` then 4 -> n; return
        elseif c == `o` then 5 -> n; return
        endif;
    endfor;
    1 -> n;                             ;;; ん
enddefine;

;;; The table as a grid: grid(row, col) -> [glyph romaji] or false.
;;;
;;; Read straight off kana/5 through `kana_table` in schema.pl, rather
;;; than reassembled from the item index.  Two reasons, and the second is
;;; the one that matters: the ROW is in the fact and nowhere else -- the
;;; index does not carry it, because nothing else has ever needed it --
;;; and asking the graph means a chart cannot show a glyph the tutor
;;; would not ask about, which is the whole claim a generated chart
;;; makes.
define sheet_grid(script) -> (grid, rows);
    lvars script, t, r, c, rom, g, sc, grid, rows = [], ri, nr;
    length(ROW_ORDER) -> nr;
    newarray([% 1, nr, 1, 5 %], false) -> grid;
    for t in lp_ask("kana_table", 0) do
        prolog_deref(prolog_arg(2, t)) -> sc;
        nextunless(sc == script);
        prolog_full_deref(prolog_arg(3, t)) -> g;
        prolog_deref(prolog_arg(4, t)) -> rom;
        prolog_deref(prolog_arg(5, t)) -> r;
        lp_pos_in(r, ROW_ORDER) -> ri;
        nextunless(ri > 0);
        sheet_col(rom) -> c;
        [% g sys_>< '', rom sys_>< '' %] -> grid(ri, c);
        unless member(ri, rows) then rows <> [^ri] -> rows endunless;
    endfor;
    sort(rows) -> rows;
enddefine;

;;; A chart cell: the glyph, and its romaji under it.  Both, always --
;;; a chart with only glyphs is a test, and this is a reference.
;;;
;;; Sized from the row height rather than fixed, because the number of
;;; rows is not fixed: the sheet was laid out at 11 rows and the voiced
;;; kana made it 16, which ran a page and a quarter.  Deriving the
;;; geometry from what is actually in the table is the same discipline as
;;; deriving the grid from it.
define sheet_cell(x, y, w, rh, glyph, rom) -> out;
    lvars x, y, w, rh, glyph, rom, out, gs = (rh * 62) div 100;
    sheet_text(x + w / 2, y + gs, gs, '#1b1a17', 'middle', glyph)
    <> sheet_text(x + w / 2, y + rh - 14, (rh * 21) div 100,
                  '#6b6457', 'middle', rom) -> out;
enddefine;

lconstant GRID_TOP = 400, GRID_BOT = 260, ROW_LABEL = 160;

define sheet_chart(script) -> svg;
    lvars script, grid, rows, ri, r, c, cell, y, x, rh,
          cw = (PAGE_W - 2 * PAGE_M - ROW_LABEL) div 5, svg, n = 0;
    sheet_grid(script) -> (grid, rows);
    ;;; one page, by arithmetic rather than by hope
    (PAGE_H - GRID_TOP - GRID_BOT) div length(rows) -> rh;
    sheet_head(if script == "hiragana" then 'ひらがな  hiragana'
               else 'カタカナ  katakana' endif,
               'langpop') -> svg;

    ;;; the vowel heading, so a learner can read the chart as the system
    ;;; it is rather than as 69 separate pictures
    for c from 1 to 5 do
        PAGE_M + ROW_LABEL + (c - 1) * cw -> x;
        svg <> sheet_text(x + cw / 2, GRID_TOP - 40, 36, '#8a8275', 'middle',
                          VOWELS(c) sys_>< '') -> svg;
    endfor;

    GRID_TOP -> y;
    for ri in rows do
        ROW_ORDER(ri) -> r;
        ;;; the row label, which is the consonant the row IS
        svg <> sheet_text(PAGE_M, y + (rh * 55) div 100, 36, '#8a8275', 'start',
                          if r == "vowel" then '-'
                          elseif r == "n_row" then 'n'
                          elseif r == "moraic" then ''
                          else r sys_>< '' endif) -> svg;
        for c from 1 to 5 do
            grid(ri, c) -> cell;
            nextunless(cell);
            n + 1 -> n;
            PAGE_M + ROW_LABEL + (c - 1) * cw -> x;
            svg <> sheet_cell(x, y, cw, rh, hd(cell), hd(tl(cell))) -> svg;
        endfor;
        y + rh -> y;
    endfor;

    svg <> sheet_foot(
        (n sys_>< '') <> ' kana, drawn from graph/ja/kana.pl.  '
        <> 'The gaps in the d row are real: ぢ and づ are spellings of '
        <> 'じ and ず, not sounds of their own.') -> svg;
enddefine;

;;; ------------------------------------------------- the youon sheet
;;; Youon are not glyphs, they are COMBINATIONS -- き plus a small ゃ --
;;; which is why the graph holds `youon` as a skill and not as 33 items.
;;; So the sheet derives them: every kana whose romaji ends in i, bar い
;;; itself, crossed with the three small kana.  The romaji comes from
;;; lp_romaji, which already knows that き+ゃ is kya while し+ゃ is sha.
lconstant SMALL = [[16:3083 a] [16:3085 u] [16:3087 o]];

define sheet_youon_rows(script) -> rows;
    lvars script, t, g, rom, sc, rows = [];
    for t in lp_ask("kana_table", 0) do
        prolog_deref(prolog_arg(2, t)) -> sc;
        nextunless(sc == script);
        (prolog_deref(prolog_arg(4, t)) sys_>< '') -> rom;
        ;;; a kana whose romaji ends in i, and not い itself.  That rule
        ;;; picks up じ as well as き, which is right: じゃ is a youon and
        ;;; the sheet should say so.
        nextunless(length(rom) > 1 and rom(length(rom)) == `i`);
        prolog_full_deref(prolog_arg(3, t)) -> g;
        rows <> [[% g sys_>< '', rom %]] -> rows;
    endfor;
enddefine;

define sheet_youon(script) -> svg;
    lvars script, rows, r, s, y, x, svg, combo, rom, rh,
          cw = (PAGE_W - 2 * PAGE_M - ROW_LABEL) div 3, n = 0, delta;
    if script == "hiragana" then 0 else 16:60 endif -> delta;
    sheet_youon_rows(script) -> rows;
    (PAGE_H - GRID_TOP - GRID_BOT) div length(rows) -> rh;
    sheet_head('ようおん  youon', 'langpop') -> svg;
    for s in SMALL do
        PAGE_M + ROW_LABEL + (lp_pos_in(s, SMALL) - 1) * cw -> x;
        svg <> sheet_text(x + cw / 2, GRID_TOP - 40, 36, '#8a8275', 'middle',
                          consutf8(#| hd(s) + delta |#)) -> svg;
    endfor;
    GRID_TOP -> y;
    for r in rows do
        svg <> sheet_text(PAGE_M, y + (rh * 55) div 100, 44, '#8a8275', 'start',
                          hd(r)) -> svg;
        for s in SMALL do
            PAGE_M + ROW_LABEL + (lp_pos_in(s, SMALL) - 1) * cw -> x;
            hd(r) <> consutf8(#| hd(s) + delta |#) -> combo;
            lp_romaji(combo) -> rom;
            nextunless(rom);
            n + 1 -> n;
            svg <> sheet_cell(x, y, cw, rh, combo, rom) -> svg;
        endfor;
        y + rh -> y;
    endfor;
    svg <> sheet_foot(
        (n sys_>< '') <> ' combinations, derived rather than listed: '
        <> 'a kana ending in i, plus a small ゃゅょ.  '
        <> 'One beat each, not two -- which is skill(youon).') -> svg;
enddefine;

;;; ------------------------------------------------- the day's sheet
;;; What a student did today, to take away from the screen.
;;;
;;; Read off the JOURNAL and not off the beliefs, because the journal is
;;; what happened and the belief is what the tutor concluded.  A sheet
;;; that printed beliefs would show the same thing every day with the
;;; numbers slightly different; a sheet that prints the journal shows the
;;; session.
lconstant DAY_MS = 86400000;

define sheet_today(since_ms) -> rows;
    lvars since_ms, e, rows = [], seen = newproperty([], 64, false, "perm");
    for e in lp_journal do
        nextunless(e(3) == 1);              ;;; checks only
        nextunless(e(6) >= since_ms);
        nextif(seen(e(1)));
        ;;; lp_journal is most-recent-first, so the FIRST entry for an
        ;;; item is the outcome that stands at the end of the day -- an
        ;;; item got wrong and then got right should not print twice, and
        ;;; should not print as wrong.
        true -> seen(e(1));
        ;;; built by consing onto the front, which turns the walk back
        ;;; into a list in the order the questions were ASKED.  A sheet
        ;;; is a record of a session and reads forwards.
        conspair({% e(1), e(4), e(5) %}, rows) -> rows;
    endfor;
    [% lvars x; for x in rows do x endfor %] -> rows;
enddefine;

define sheet_mark(outcome) -> s;
    lvars outcome, s;
    if     outcome == "right" then '+'
    elseif outcome == "near"  then '~'
    elseif outcome == "skip"  then '?'
    else                           'x'
    endif -> s;
enddefine;

define sheet_day_svg(display, rows, plan) -> svg;
    lvars display, rows, plan, r, i, y, svg, g, rd, n = 0, again = [], item;
    sheet_head(if display then 'Today, ' <> (display sys_>< '')
               else 'Today' endif,
               ;;; the date, not the instant: this is going on paper
               substring(1, 10, dt_iso(sys_real_time()))) -> svg;

    if rows == [] then
        svg <> sheet_text(PAGE_M, 460, 40, '#6b6457', 'start',
                          'Nothing recorded yet today.')
            <> sheet_foot('langpop') -> svg;
        return;
    endif;

    svg <> sheet_text(PAGE_M, 380, 40, '#1b1a17', 'start',
                      'What you worked on') -> svg;
    440 -> y;
    for r in rows do
        n + 1 -> n;
        quitif(n > 24);                     ;;; one page, by construction
        r(1) -> item;
        lp_any_form(item) -> g;
        lp_form_of(item, "romaji") -> rd;
        unless rd then lp_gloss_of(item, "en") -> rd endunless;
        svg <> sheet_text(PAGE_M, y, 44, '#8a8275', 'start',
                          sheet_mark(r(2)))
            <> sheet_text(PAGE_M + 90, y, 48, '#1b1a17', 'start',
                          g sys_>< '')
            <> sheet_text(PAGE_M + 520, y, 34, '#6b6457', 'start',
                          if rd then rd sys_>< '' else '' endif)
            <> sheet_text(PAGE_W - PAGE_M, y, 30, '#8a8275', 'end',
                          (r(3) sys_>< '') <> ' ms') -> svg;
        unless r(2) == "right" then again <> [^item] -> again endunless;
        y + 72 -> y;
    endfor;

    ;;; The ones to look at again, named rather than counted.  A number
    ;;; is a grade; a list is something to do.
    if again /== [] then
        y + 60 -> y;
        svg <> sheet_text(PAGE_M, y, 40, '#1b1a17', 'start',
                          'Worth another look') -> svg;
        y + 70 -> y;
        lvars line = '';
        for item in again do
            if length(line) > 40 then
                svg <> sheet_text(PAGE_M, y, 44, '#2f4a7a', 'start', line) -> svg;
                y + 68 -> y; '' -> line;
            endif;
            line <> (lp_any_form(item) sys_>< '') <> '   ' -> line;
        endfor;
        if line /= '' then
            svg <> sheet_text(PAGE_M, y, 44, '#2f4a7a', 'start', line) -> svg;
            y + 68 -> y;
        endif;
    endif;

    if plan /== [] then
        y + 60 -> y;
        svg <> sheet_text(PAGE_M, y, 40, '#1b1a17', 'start',
                          'Next time') -> svg;
        y + 70 -> y;
        lvars k = 0;
        for item in plan do
            k + 1 -> k; quitif(k > 6);
            svg <> sheet_text(PAGE_M, y, 44, '#1b1a17', 'start',
                              lp_any_form(item) sys_>< '') -> svg;
            y + 68 -> y;
        endfor;
    endif;

    svg <> sheet_foot('+ right   ~ near miss   ? did not know   x wrong.  '
                      <> 'Drawn from your own answers, on this machine.') -> svg;
enddefine;


;;; ===================================================== the zine
;;; An eight-page booklet from one sheet of A4: a study plan the student
;;; can fold up and carry.  Printable at any time, because the plan is a
;;; function of the beliefs and the beliefs are always current.
;;;
;;; WHY NOTHING IS VENDORED.  The obvious way to do this is to take one
;;; of the free zine templates and fill it in.  The one we looked at
;;; (taylorsmithdesigns.co.uk/free-zine-pdf) says "the template itself
;;; must not be sold commercially, but feel free to share" under a
;;; footer reading "All Rights Reserved" -- a permission note rather
;;; than a licence: no named licence, no version, and two clauses that
;;; disagree.  That is the same reason NGSL was turned down for the
;;; English word list, and the answer is the same: do not put it in the
;;; repo.  It is also 37 MB of somebody else's PSD and PDF, which the
;;; whole graph/<lang>/generated/ arrangement exists to avoid.
;;;
;;; And we do not need it.  What a template gives you is the
;;; IMPOSITION -- which panel holds which page, and which half of the
;;; sheet is upside down -- and that is not a creative work.  It is a
;;; consequence of folding a sheet in half three times and cutting the
;;; middle: every zine template shows the same arrangement because the
;;; paper leaves no choice.  So it is derived here, from the fold, and
;;; the derivation is written down below so the next person can check it
;;; rather than trust it.
;;;
;;; WHY NOT TeX.  It was offered, and it would work, but it would add a
;;; toolchain this project does not otherwise need.  SVG already draws
;;; the cards and the sheets, and rotating half the page is one
;;; transform attribute.  A dependency bought for one rotation is a bad
;;; trade.

;;; The fold, which decides the layout:
;;;
;;;   1. A4 landscape.  Fold in half left-to-right, again, and again:
;;;      eight panels, four columns by two rows.
;;;   2. Unfold.  Fold in half top-to-bottom and cut the centre fold
;;;      across the middle two columns only.
;;;   3. Open, fold lengthwise, push the ends together so the cut opens,
;;;      and collapse into a stack.
;;;
;;; Follow a panel through that and the arrangement falls out:
;;;
;;;        top row, upside down:   5   4   3   2
;;;        bottom row, upright:    6   7   8   1
;;;
;;; with 1 the front cover and 8 the back.  The top row is inverted
;;; because the lengthwise fold turns it over; nothing else in the
;;; layout is a choice.
;;;
;;; {page, column (0-3), row (0 top / 1 bottom), rotation}
lconstant ZINE_PANELS = [
    {5 0 0 180} {4 1 0 180} {3 2 0 180} {2 3 0 180}
    {6 0 1 0}   {7 1 1 0}   {8 2 1 0}   {1 3 1 0}
];

;;; A4 LANDSCAPE in twentieths of a millimetre.  Tenths, which the other
;;; sheets use, would put a panel at 742.5 units wide -- and a layout
;;; that lands on a half unit is a layout that will be rounded somewhere
;;; it should not be.  At 1/20 mm every edge of every panel is an
;;; integer, which is the only reason the unit differs from sheet.p's.
lconstant
    ZW = 5940, ZH = 4200,              ;;; 297mm x 210mm
    PW = 1485, PH = 2100,              ;;; 74.25mm x 105mm, exactly
    ZPAD = 120;

;;; Type sizes in the SAME unit, which is the trap this unit sets: at
;;; 1/20 mm a size of 36 is 1.8mm, about five point, and the first draft
;;; of this page was unreadable because the numbers were carried over
;;; from sheet.p where 36 means 3.6mm.  Named here, in points, so the
;;; next person does the arithmetic once.
;;;
;;;     1 pt = 0.353 mm = 7.06 units
lconstant
    Z_TITLE = 140,                     ;;; 20pt
    Z_HEAD  = 85,                      ;;; 12pt
    Z_BODY  = 64,                      ;;; 9pt
    Z_SMALL = 50,                      ;;; 7pt
    Z_TINY  = 42,                      ;;; 6pt
    Z_GLYPH = 130;                     ;;; 18pt, for a kana or a kanji

define zine_panel(n) -> (x, y, rot);
    lvars n, p;
    (false, false, 0) -> (x, y, rot);
    for p in ZINE_PANELS do
        if p(1) == n then
            p(2) * PW -> x; p(3) * PH -> y; p(4) -> rot; return;
        endif;
    endfor;
enddefine;

;;; A panel's contents are drawn at the origin, in panel coordinates, and
;;; then placed.  An upside-down panel is translated to its far corner
;;; and rotated about it, which is the same thing as drawing it the right
;;; way up on a sheet somebody turned round.
define zine_place(n, body) -> out;
    lvars n, body, x, y, rot, out;
    zine_panel(n) -> (x, y, rot);
    if rot == 180 then
        sprintf('  <g transform="translate(%p,%p) rotate(180)">\n',
                [% x + PW, y + PH %])
    else
        sprintf('  <g transform="translate(%p,%p)">\n', [% x, y %])
    endif <> body <> '  </g>\n' -> out;
enddefine;

;;; ------------------------------------------------------ the guides
;;; Fold lines light, the cut line dashed and only where it is cut --
;;; across the middle two columns, on the centre fold.  Printing a cut
;;; line the whole width would be an instruction to cut the booklet in
;;; half, which is the one mistake that cannot be undone.
define zine_guides() -> out;
    lvars i, out = '';
    for i from 1 to 3 do
        out <> sprintf('  <line x1="%p" y1="0" x2="%p" y2="%p" '
                       <> 'stroke="#e8e4db" stroke-width="2"/>\n',
                       [% i * PW, i * PW, ZH %]) -> out;
    endfor;
    out <> sprintf('  <line x1="0" y1="%p" x2="%p" y2="%p" '
                   <> 'stroke="#e8e4db" stroke-width="2"/>\n',
                   [% PH, PW, PH %])
        <> sprintf('  <line x1="%p" y1="%p" x2="%p" y2="%p" '
                   <> 'stroke="#e8e4db" stroke-width="2"/>\n',
                   [% 3 * PW, PH, ZW, PH %])
        ;;; the cut
        <> sprintf('  <line x1="%p" y1="%p" x2="%p" y2="%p" '
                   <> 'stroke="#b9b2a4" stroke-width="4" '
                   <> 'stroke-dasharray="30 22"/>\n',
                   [% PW, PH, 3 * PW, PH %])
        <> sheet_text(2 * PW, PH - 30, 46, '#b9b2a4', 'middle',
                      'cut along here') -> out;
enddefine;

;;; ------------------------------------------------- panel furniture
define zine_title(s, sub) -> out;
    lvars s, sub, out;
    sheet_text(ZPAD, 250, Z_TITLE, '#1b1a17', 'start', s)
    <> sprintf('    <line x1="%p" y1="310" x2="%p" y2="310" '
               <> 'stroke="#d9d5cc" stroke-width="3"/>\n',
               [% ZPAD, PW - ZPAD %]) -> out;
    if sub then
        out <> sheet_text(ZPAD, 400, Z_SMALL, '#8a8275', 'start', sub) -> out;
    endif;
enddefine;

define zine_num(n) -> out;
    lvars n, out;
    sheet_text(PW div 2, PH - 70, Z_TINY, '#b9b2a4', 'middle',
               n sys_>< '') -> out;
enddefine;

;;; Break a line at spaces so it fits a 74mm panel.  Crude on purpose:
;;; the prose on a zine page is two sentences, and a hyphenating
;;; paragraph engine would be more machinery than the problem has.
define zine_words(s) -> ws;
    lvars s, i, j, n, ws = [];
    s sys_>< '' -> s; length(s) -> n; 1 -> i;
    until i > n do
        while i <= n and s(i) == ` ` do i + 1 -> i endwhile;
        quitif(i > n);
        i -> j;
        while j <= n and s(j) /== ` ` do j + 1 -> j endwhile;
        ws <> [% substring(i, j - i, s) %] -> ws;
        j -> i;
    enduntil;
enddefine;

define zine_wrap(s, cols) -> lines;
    lvars s, cols, w, line = '', lines = [];
    for w in zine_words(s) do
        if length(line) + length(w) + 1 > cols and line /= '' then
            lines <> [^line] -> lines; '' -> line;
        endif;
        if line = '' then w else line <> ' ' <> w endif -> line;
    endfor;
    if line /= '' then lines <> [^line] -> lines endif;
enddefine;

define zine_para(y, size, ink, s, cols) -> out;
    lvars y, size, ink, s, cols, l, out = '';
    for l in zine_wrap(s, cols) do
        out <> sheet_text(ZPAD, y, size, ink, 'start', l) -> out;
        y + (size * 130) div 100 -> y;
    endfor;
enddefine;

;;; ---------------------------------------------------- the pages
define zine_cover(display) -> out;
    lvars display, out;
    sprintf('    <rect x="%p" y="%p" width="%p" height="%p" fill="none" '
            <> 'stroke="#d9d5cc" stroke-width="3"/>\n',
            [% 70, 70, PW - 140, PH - 140 %])
    <> sheet_text(PW div 2, 640, 165, '#1b1a17', 'middle', 'Study plan')
    <> sheet_text(PW div 2, 760, Z_HEAD, '#8a8275', 'middle',
                  display or (lp_user sys_>< ''))
    ;;; Sized to the PANEL, not to taste: five kana at 290 units each
    ;;; overran 1485 and broke out of the cover frame.
    <> sheet_text(PW div 2, 1250, 215, '#1b1a17', 'middle',
                  if lp_lang == "ja" then 'がんばって' else 'one page' endif)
    <> sheet_text(PW div 2, 1760, Z_BODY, '#8a8275', 'middle',
                  (lp_lang sys_>< '') <> '  ·  ' <> (lp_level sys_>< ''))
    <> sheet_text(PW div 2, 1860, Z_SMALL, '#b9b2a4', 'middle',
                  substring(1, 10, dt_iso(sys_real_time()))) -> out;
enddefine;

;;; The summary page: where the student stands, by the tutor's own
;;; reckoning.  The placement report when there is one, because it says
;;; something a count cannot -- that katakana is below the ladder while
;;; kanji is at n5 is the fact a single level would hide.
define zine_where() -> out;
    lvars out, r, y = 560, n = 0, placed;
    zine_title('Where you are', 'working at ' <> (lp_level sys_>< ''))
        -> out;
    for r in lp_place_report() do
        n + 1 -> n; quitif(n > 10);
        r(2) -> placed;
        ;;; lp_place_says, not the raw `why`: the report's word is
        ;;; `askable`, which means "I asked and you did not pass" and
        ;;; reads to a student as nothing at all.
        out <> sheet_text(ZPAD, y, Z_BODY, '#1b1a17', 'start',
                          r(1) sys_>< '') -> out;
        if placed then
            out <> sheet_text(PW - ZPAD, y, Z_BODY, '#2f4a7a', 'end',
                              placed sys_>< '') -> out;
            y + 140 -> y;
        else
            out <> zine_para(y + 70, Z_SMALL, '#8a8275',
                             lp_place_says(r), 30) -> out;
            y + 70 + 65 * length(zine_wrap(lp_place_says(r), 30)) + 30 -> y;
        endif;
    endfor;
    if n == 0 then
        out <> zine_para(y, Z_BODY, '#6b6457',
                         'Nothing placed yet. Run :place and this page '
                         <> 'will say where each part of the language '
                         <> 'stands on its own.', 26) -> out;
    endif;
    out <> zine_num(2) -> out;
enddefine;

define zine_doing() -> out;
    lvars out, r, y = 500, n = 0, off, wrapped;
    zine_title('How it is going', false) -> out;
    for r in lp_status_rows() do
        ;;; Stop when the page is full rather than when a count says so:
        ;;; a criterion's text wraps to one line or to three, and a fixed
        ;;; row limit would either overflow or waste half the panel.
        quitif(y > PH - 420);
        n + 1 -> n;
        out <> sheet_text(ZPAD, y, Z_BODY, '#1b1a17', 'start', r(1)) -> out;
        y + 80 -> y;
        zine_wrap(r(2), 32) -> wrapped;
        out <> zine_para(y, Z_SMALL, '#6b6457', r(2), 32) -> out;
        y + 65 * length(wrapped) + 40 -> y;
    endfor;
    out <> sheet_text(ZPAD, PH - 280, Z_BODY, '#8a8275', 'start',
                      (length(lp_plan()) sys_>< '') <> ' ready to learn now')
        -> out;
    ;;; A number read without this is a number of unknown strictness.
    [% lvars a; for a in lp_aid_names() do
           unless lp_aid(a) then a endunless endfor %] -> off;
    if off /== [] then
        out <> sheet_text(ZPAD, PH - 190, Z_SMALL, '#8a8275', 'start',
                          'switched off: ' <> (off sys_>< '')) -> out;
    endif;
    out <> zine_num(3) -> out;
enddefine;

;;; The plan itself, over three pages.  Weakest belief first, which is
;;; the order the tutor would ask them in, so the booklet and the
;;; session agree about what comes next.
define zine_plan_page(items, skip, page, title) -> out;
    lvars items, skip, page, title, i, out, y = 520, n = 0, g, rd;
    zine_title(title, false) -> out;
    for i in items do
        n + 1 -> n;
        nextif(n <= skip);
        quitif(n > skip + 9);
        lp_any_form(i) -> g;
        lp_form_of(i, "romaji") -> rd;
        unless rd then lp_gloss_of(i, "en") -> rd endunless;
        out <> sheet_text(ZPAD, y, Z_GLYPH, '#1b1a17', 'start', g sys_>< '')
            -> out;
        if rd then
            out <> sheet_text(PW - ZPAD, y, Z_SMALL, '#6b6457', 'end',
                              rd sys_>< '') -> out;
        endif;
        y + 165 -> y;
    endfor;
    if n <= skip then
        out <> zine_para(y, Z_BODY, '#6b6457',
                         'Nothing more is ready yet. These unlock as the '
                         <> 'ones before them are learned.', 26) -> out;
    endif;
    out <> zine_num(page) -> out;
enddefine;

define zine_again(rows) -> out;
    lvars rows, r, out, y = 520, n = 0, g, rd;
    zine_title('Worth another look', false) -> out;
    for r in rows do
        nextif(r(2) == "right");
        n + 1 -> n; quitif(n > 9);
        lp_any_form(r(1)) -> g;
        lp_form_of(r(1), "romaji") -> rd;
        out <> sheet_text(ZPAD, y, Z_BODY, '#8a8275', 'start',
                          sheet_mark(r(2)))
            <> sheet_text(ZPAD + 110, y, Z_GLYPH, '#2f4a7a', 'start',
                          g sys_>< '') -> out;
        if rd then
            out <> sheet_text(PW - ZPAD, y, Z_SMALL, '#8a8275', 'end',
                              rd sys_>< '') -> out;
        endif;
        y + 165 -> y;
    endfor;
    if n == 0 then
        out <> zine_para(y, Z_BODY, '#6b6457',
                         'Nothing missed lately. That is either very good '
                         <> 'or a sign the questions are too easy.',
                         26) -> out;
    endif;
    out <> zine_num(7) -> out;
enddefine;

;;; The ladder, with a mark where the student is.  This page exists
;;; because the plan is often shorter than three pages -- five items are
;;; ready at pre-school -- and three pages of "nothing more is ready" is
;;; a booklet that wasted a third of itself.  It is also the thing a
;;; mini guide should carry: not only what is next, but what next is
;;; part of.
define zine_ladder() -> out;
    lvars out, l, y = 540, here = false;
    zine_title('The ladder', (lp_lang sys_>< '') <> ', all of it') -> out;
    for l in lp_levels(lp_lang) do
        (l == lp_level) -> here;
        out <> sheet_text(ZPAD, y, Z_BODY, if here then '#1b1a17'
                                           else '#8a8275' endif,
                          'start', l sys_>< '') -> out;
        if here then
            out <> sheet_text(PW - ZPAD, y, Z_SMALL, '#2f4a7a', 'end',
                              'you are here') -> out;
        endif;
        y + 150 -> y;
    endfor;
    out <> zine_para(y + 60, Z_SMALL, '#8a8275',
        'A rung opens when the one below it is met, not when a date '
        <> 'passes.', 32)
        <> zine_num(6) -> out;
enddefine;

define zine_back() -> out;
    lvars out, y;
    zine_title('Fold it', false) -> out;
    460 -> y;
    out <> zine_para(y, Z_SMALL, '#6b6457',
        'Print one sided. Fold in half the short way, three times, then '
        <> 'open it out. Fold in half the long way and cut the dashed '
        <> 'line. Open, fold the long way again, push the ends together '
        <> 'until the cut opens, and flatten it into a booklet.', 32)
        -> out;
    1240 -> y;
    ;;; Separated by a dot and not by spaces: SVG collapses runs of
    ;;; whitespace, so the columns I lined up in the source arrived on
    ;;; paper as "? did not know x wrong".
    out <> sheet_text(ZPAD, y, Z_BODY, '#1b1a17', 'start', 'On page 7')
        <> sheet_text(ZPAD, y + 95, Z_SMALL, '#6b6457', 'start',
                      '+ right · ~ near miss')
        <> sheet_text(ZPAD, y + 165, Z_SMALL, '#6b6457', 'start',
                      '? did not know · x wrong')
        -> out;
    out <> zine_para(1620, Z_TINY, '#8a8275',
        'Drawn from your own answers, on this machine. Nothing here was '
        <> 'downloaded and nothing was sent anywhere.', 38)
        <> sheet_text(ZPAD, PH - 150, Z_TINY, '#b9b2a4', 'start', 'langpop')
        <> zine_num(8) -> out;
enddefine;

;;; ------------------------------------------------------- the sheet
define zine_svg(display) -> svg;
    lvars display, svg, plan = lp_plan(), rows = sheet_today(0);
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    <> sprintf('<svg xmlns="http://www.w3.org/2000/svg" '
               <> 'width="297mm" height="210mm" viewBox="0 0 %p %p" '
               <> 'role="img" aria-label="study plan">\n', [% ZW, ZH %])
    <> '  <title>langpop study plan</title>\n'
    <> '  <rect width="100%" height="100%" fill="#ffffff"/>\n'
    <> zine_guides()
    <> sprintf('  <g font-family="%p">\n', [% SHEET_FONT %])
    <> zine_place(1, zine_cover(display))
    <> zine_place(2, zine_where())
    <> zine_place(3, zine_doing())
    <> zine_place(4, zine_plan_page(plan, 0, 4, 'Next'))
    <> zine_place(5, zine_plan_page(plan, 9, 5, 'Then'))
    <> zine_place(6, zine_ladder())
    <> zine_place(7, zine_again(rows))
    <> zine_place(8, zine_back())
    <> '  </g>\n</svg>\n' -> svg;
enddefine;

;;; ---------------------------------------------------------- the method
define sheet_dir() -> d;
    lvars d = lp_home() <> 'sheets/';
enddefine;

define lp_sheet_render(style, user) -> (path, why);
    lvars style, user, path = false, why = false, svg, rows, name;
    dlocal pop_file_versions = false;
    if member(style, SHEET_STYLES) then
        if     style == "youon" then sheet_youon("hiragana")
        else                         sheet_chart(style)
        endif -> svg;
        style sys_>< '' -> name;
    elseif style == "today" or style == "zine" then
        unless user and lp_user == user then
            'no_such_student' -> why; return;
        endunless;
        if style == "zine" then
            zine_svg(lp_display) -> svg;
            'zine-' <> (user sys_>< '') -> name;
        else
            sheet_today(lp_now_ms() - DAY_MS) -> rows;
            sheet_day_svg(lp_display, rows, lp_plan()) -> svg;
            'today-' <> (user sys_>< '') -> name;
        endif;
    else
        'no_such_style' -> why; return;
    endif;
    unless sys_file_exists(sheet_dir()) then
        sysobey('mkdir -p ' <> sheet_dir());
    endunless;
    sheet_dir() <> name <> '.svg' -> path;
    lp_write_file(path, svg);
enddefine;
