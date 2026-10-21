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
    lvars note, out, l, y = PAGE_H - 130;
    sprintf('    <line x1="%p" y1="%p" x2="%p" y2="%p" '
            <> 'stroke="#e2ded4" stroke-width="2"/>\n',
            [% PAGE_M, PAGE_H - 190, PAGE_W - PAGE_M, PAGE_H - 190 %])
        -> out;
    ;;; Wrapped.  A footer is one line until somebody writes a long one,
    ;;; and then it is one line that runs off the right-hand edge --
    ;;; which it did, the moment the modifier strip needed explaining.
    for l in zine_wrap(note, 118) do
        out <> sheet_text(PAGE_M, y, 28, '#8a8275', 'start', l) -> out;
        y + 38 -> y;
    endfor;
    out <> '  </g>\n</svg>\n' -> out;
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

lconstant GRID_TOP = 400, GRID_BOT = 440, ROW_LABEL = 160;

;;; The full-size kana a small one is the small form OF, so the strip
;;; can show the pair.  By codepoint, because that is the relationship:
;;; every small kana sits one or two below its full twin in the block.
define sheet_twin(g) -> t;
    lvars g, cp = hd([% utf8_explode(g sys_>< '') %]), t = '';
    if cp == 16:3063 or cp == 16:30C3 then consutf8(#| cp + 1 |#)    ;;; っ -> つ
    elseif cp >= 16:3083 and cp <= 16:3087 then consutf8(#| cp + 1 |#)
    elseif cp >= 16:30E3 and cp <= 16:30E7 then consutf8(#| cp + 1 |#)
    elseif cp == 16:308E or cp == 16:30EE then consutf8(#| cp + 1 |#)
    elseif cp >= 16:3041 and cp <= 16:3049 then consutf8(#| cp + 1 |#)
    elseif cp >= 16:30A1 and cp <= 16:30A9 then consutf8(#| cp + 1 |#)
    else ''
    endif -> t;
enddefine;

;;; The characters that are not syllables, along the foot of the chart.
;;;
;;; They are not cells of the grid -- a gojuon table has no place for
;;; them, which is exactly why they are not in kana/5 -- but a learner
;;; meets っ in がっこう on day three, and a reference sheet that leaves
;;; them off is a reference with a hole in it.  So: a strip, separated
;;; from the grid, labelled with what each one does rather than with a
;;; reading, because they have no reading.
define sheet_modifiers(script) -> out;
    lvars script, m, g, why, x, out = '', n = 0, y = PAGE_H - 330;
    out <> sprintf('    <line x1="%p" y1="%p" x2="%p" y2="%p" '
                   <> 'stroke="#e2ded4" stroke-width="2"/>\n',
                   [% PAGE_M, y - 90, PAGE_W - PAGE_M, y - 90 %]) -> out;
    for m in lp_ask("modifiers", 0) do
        prolog_deref(prolog_arg(2, m)) -> why;
        nextunless(why == script);
        prolog_full_deref(prolog_arg(1, m)) -> g;
        prolog_deref(prolog_arg(3, m)) -> why;
        ;;; the small vowels are declared ahead of need and would fill
        ;;; the strip with characters no item uses yet
        nextunless(member(g sys_>< '',
                          ['ゃ' 'ゅ' 'ょ' 'っ'
                           'ャ' 'ュ' 'ョ' 'ッ' 'ー']));
        n + 1 -> n;
        PAGE_M + (n - 1) * 360 -> x;
        ;;; Shown BESIDE its full-size twin, because the difference is
        ;;; the size and nothing else: ゃ drawn on its own at chart size
        ;;; is indistinguishable from や, which is exactly the confusion
        ;;; the strip is supposed to prevent.  ー has no twin.
        out <> sheet_text(x, y, 95, '#b9b2a4', 'start', sheet_twin(g))
            <> sheet_text(x + 130, y, 95, '#1b1a17', 'start', g sys_>< '')
            <> sheet_text(x, y + 56, 26, '#6b6457', 'start',
                          if why == "youon" then 'joins the one before'
                          elseif why == "mora_sokuon" then 'a beat of silence'
                          else 'lengthens the vowel' endif) -> out;
    endfor;
enddefine;

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

    svg <> sheet_modifiers(script)
        <> sheet_foot(
        (n sys_>< '') <> ' kana, drawn from graph/ja/kana.pl.  '
        <> 'The gaps in the d row are real: ぢ and づ are spellings of '
        <> 'じ and ず, not sounds of their own.  The row along the foot '
        <> 'is not syllables: those characters have no reading of their '
        <> 'own.') -> svg;
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

;;; ------------------------------------------- the booklet's own words
;;; A study booklet has to be readable by the person studying, and the
;;; one language they cannot be assumed to read is the one they are
;;; learning.  The first draft of this page had every heading in English
;;; -- fine for a English speaker learning Japanese, useless for the
;;; Japanese speaker learning English, who is the harder half of the
;;; problem this project exists for.  Printing it and looking at it is
;;; what showed that.
;;;
;;; So the chrome is in lp_learner_lang(), which is the OTHER language
;;; from the ladder being climbed.  Each entry is {key, en, ja}.
;;;
;;; This is not a persona file.  A persona is what a teacher SAYS, and
;;; varies by teacher; these are the labels on a page, and vary only by
;;; who is reading.  Two different things, kept apart.
lconstant ZINE_WORDS = [
    {cover      'Study plan'           '学習プラン'}
    ;;; The motto is the ONE phrase on the booklet in the language
    ;;; being learned rather than the one being read -- see
    ;;; zine_say_target.  So its columns are the other way round from
    ;;; every other row here: the English column is what an English
    ;;; learner meets, the Japanese column what a Japanese learner does.
    {motto      'you can do this'      'がんばって'}
    {where      'Where you are'        'いまの実力'}
    {working    'working at'           'いまのレベル'}
    {doing      'How it is going'      'とちゅう経過'}
    {ready      'ready to learn now'   '学べる項目'}
    {switched   'switched off'         'オフにした補助'}
    {next       'Next'                 'つぎ'}
    {then       'Then'                 'そのつぎ'}
    {ladder     'The ladder'           'レベル表'}
    {allofit    'all of it'            '全レベル'}
    {youhere    'you are here'         'いまここ'}
    {rung       'A rung opens when the one below it is met, not when a date passes.'
                'つぎのレベルは、まえのレベルを満たしたときに開きます。日付ではありません。'}
    {again      'Worth another look'   'もう一度'}
    {nomiss     'Nothing missed lately. That is either very good or a sign the questions are too easy.'
                'さいきん間違いはありません。とても良いか、問題がやさしすぎるかのどちらかです。'}
    {nomore     'Nothing more is ready yet. These unlock as the ones before them are learned.'
                'いまは、これ以上ありません。まえの項目を覚えると開きます。'}
    {noplace    'Nothing placed yet. Run :place and this page will say where each part of the language stands on its own.'
                'まだ判定していません。:place を実行すると、分野ごとの実力がここに出ます。'}
    {fold       'Fold it'              'おりかた'}
    {howto      'Print one sided. Fold in half the short way, three times, then open it out. Fold in half the long way and cut the dashed line. Open, fold the long way again, push the ends together until the cut opens, and flatten it into a booklet.'
                '片面印刷。みじかい辺で半分に三回おって、ひらきます。ながい辺で半分におり、点線を切ります。ひらいて、もう一度ながい辺でおり、両はしを押して切れ目をひらき、平らにして本にします。'}
    {onp7       'On page 7'            '7ページの記号'}
    {legend1    '+ right · ~ near miss'    '+ 正解 · ~ おしい'}
    {legend2    '? did not know · x wrong' '? わからない · x 間違い'}
    {privacy    'Drawn from your own answers, on this machine. Nothing here was downloaded and nothing was sent anywhere.'
                'あなたの答えから、このパソコンの中だけで作りました。ダウンロードも送信もしていません。'}
    {cut        'cut along here'       'ここを切る'}
];

define zine_word(key, ja) -> s;
    lvars key, ja, e, s = key sys_>< '';
    for e in ZINE_WORDS do
        if e(1) == key then
            (if ja then e(3) else e(2) endif) sys_>< '' -> s;
            return;
        endif;
    endfor;
enddefine;

;;; What the booklet says to its reader: in the language they can
;;; already read, which is the other one from the ladder.
define zine_say(key) -> s;
    lvars key, s = zine_word(key, lp_learner_lang() == "ja");
enddefine;

;;; And the one exception, on the cover.  A booklet carrying a single
;;; phrase of encouragement in the language being LEARNED is a flourish
;;; the student will meet soon and can be proud of reading; a booklet
;;; whose navigation is in that language is one they cannot use.  The
;;; difference is the whole of this distinction, so it gets its own
;;; procedure rather than a flag.
define zine_say_target(key) -> s;
    lvars key, s = zine_word(key, lp_lang == "ja");
enddefine;

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
                      zine_say("cut")) -> out;
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
;;; How wide one character is, in columns.  A kana or a kanji occupies
;;; the width of two latin letters in every face this page will be set
;;; in, so counting characters rather than columns made a Japanese line
;;; twice as long as the panel it was supposed to fit in.
define zine_cw(cp) -> w;
    lvars cp, w = 1;
    if cp >= 16:1100 then 2 -> w endif;
enddefine;

;;; Japanese has no spaces, so a space-splitting wrap put a whole
;;; sentence on one line and ran it off the sheet and across the three
;;; panels beside it.  Printing an English-ladder booklet is what showed
;;; that: every Japanese paragraph on it escaped its panel.
;;;
;;; So: break at a space when there is one, and between characters when
;;; there is not, which is how Japanese is set anyway.
;;;
;;; The one typographic rule worth keeping is kinsoku: a line may not
;;; BEGIN with closing punctuation.  Without it a sentence breaks before
;;; its own full stop and the next line opens with a lone 。
lconstant NO_LINE_START = '。、）」』！？・ー,.)]}';

define zine_nostart(cp) -> yes;
    lvars cp, c, yes = false;
    for c in [% utf8_explode(NO_LINE_START) %] do
        if c == cp then true -> yes; return endif;
    endfor;
enddefine;

define zine_wrap(s, cols) -> lines;
    lvars s, cols, cps, cp, i, n, line = '', w = 0, lines = [],
          sp = false, spw = 0;
    [% utf8_explode(s sys_>< '') %] -> cps;
    length(cps) -> n;
    for i from 1 to n do
        cps(i) -> cp;
        ;;; a leading space on a fresh line is dropped rather than drawn
        if cp == ` ` and line = '' then nextloop endif;
        ;;; Break between characters only where that is how the script
        ;;; is set.  Japanese breaks anywhere; English does not, and a
        ;;; wrap that split `supercalifragilistic` across two lines
        ;;; without a hyphen would be worse than one that let it hang
        ;;; over the edge.  So a mid-word break needs a wide character.
        if w + zine_cw(cp) > cols and line /= ''
        and not(zine_nostart(cp))
        and (sp or zine_cw(cp) == 2) then
            ;;; prefer the last space, so English still breaks at words
            if sp and sp > 1 then
                lines <> [% substring(1, sp - 1, line) %] -> lines;
                substring(sp + 1, length(line) - sp, line) -> line;
                w - spw - 1 -> w;
            else
                lines <> [^line] -> lines; '' -> line; 0 -> w;
            endif;
            false -> sp;
        endif;
        if cp == ` ` then length(line) + 1 -> sp; w -> spw endif;
        line <> consutf8(#| cp |#) -> line;
        w + zine_cw(cp) -> w;
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
    <> sheet_text(PW div 2, 640, 165, '#1b1a17', 'middle', zine_say("cover"))
    <> sheet_text(PW div 2, 760, Z_HEAD, '#8a8275', 'middle',
                  display or (lp_user sys_>< ''))
    ;;; Sized to the PANEL, not to taste: five kana at 290 units each
    ;;; overran 1485 and broke out of the cover frame.
    <> sheet_text(PW div 2, 1250, 215, '#1b1a17', 'middle',
                  zine_say_target("motto"))
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
    zine_title(zine_say("where"),
               zine_say("working") <> ' ' <> (lp_level sys_>< '')) -> out;
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
        out <> zine_para(y, Z_BODY, '#6b6457', zine_say("noplace"), 26) -> out;
    endif;
    out <> zine_num(2) -> out;
enddefine;

;;; The same numbers as :status, worded for whoever is holding the page.
;;; lp_status_rows carries the numbers and nothing else, exactly so that
;;; this can exist without being a second measurement.
define zine_status_text(r) -> txt;
    lvars r, txt;
    returnif(lp_learner_lang() /== "ja")(lp_status_text(r) -> txt);
    if     r(2) == "counted" then
        sprintf('%p / %p 習得（グラフに %p）', [% r(3), r(4), r(5) %])
    elseif r(2) == "audio" then
        sprintf('ここでは測れません。音声が必要です（グラフに %p）', [% r(5) %])
    elseif r(2) == "unbuilt" then
        'コンテンツ未生成のため、まだ測っていません'
    else
        sprintf('正解 %p%%・%pms 以内 %p%%・%p 問（必要 %p%%）',
                [% r(3), r(5), r(4), r(6), r(7) %])
    endif -> txt;
enddefine;

define zine_doing() -> out;
    lvars out, r, y = 500, n = 0, off, wrapped, txt;
    zine_title(zine_say("doing"), false) -> out;
    for r in lp_status_rows() do
        ;;; Stop when the page is full rather than when a count says so:
        ;;; a criterion's text wraps to one line or to three, and a fixed
        ;;; row limit would either overflow or waste half the panel.
        quitif(y > PH - 420);
        n + 1 -> n;
        out <> sheet_text(ZPAD, y, Z_BODY, '#1b1a17', 'start', r(1)) -> out;
        y + 80 -> y;
        zine_status_text(r) -> txt;
        zine_wrap(txt, 32) -> wrapped;
        out <> zine_para(y, Z_SMALL, '#6b6457', txt, 32) -> out;
        y + 65 * length(wrapped) + 40 -> y;
    endfor;
    out <> sheet_text(ZPAD, PH - 280, Z_BODY, '#8a8275', 'start',
                      (length(lp_plan()) sys_>< '') <> ' '
                      <> zine_say("ready"))
        -> out;
    ;;; A number read without this is a number of unknown strictness.
    [% lvars a; for a in lp_aid_names() do
           unless lp_aid(a) then a endunless endfor %] -> off;
    if off /== [] then
        out <> sheet_text(ZPAD, PH - 190, Z_SMALL, '#8a8275', 'start',
                          zine_say("switched") <> ': '
                          <> (off sys_>< '')) -> out;
    endif;
    out <> zine_num(3) -> out;
enddefine;

;;; The plan itself, over three pages.  Weakest belief first, which is
;;; the order the tutor would ask them in, so the booklet and the
;;; session agree about what comes next.
;;; What to print under an item: its reading if it has one, else the
;;; gloss IN THE LANGUAGE THE STUDENT READS.
;;;
;;; And cut to length.  A romaji reading is four characters; a gloss
;;; imported from a dictionary is "a very large and rather grand house,
;;; in American usage an apartment building" -- which, set as one line
;;; anchored to the right edge, ran clean across the sheet and over the
;;; three panels beside it.  Nothing in SVG clips by default, so a line
;;; that does not fit does not wrap, it escapes.
define zine_hint(i, cols) -> h;
    lvars i, cols, h = lp_form_of(i, "romaji"), ls;
    unless h then
        lp_gloss_of(i, lp_learner_lang()) or lp_gloss_of(i, lp_ilang(i))
            -> h;
    endunless;
    returnunless(h);
    h sys_>< '' -> h;
    ;;; one line, and an ellipsis rather than a silent cut, so a reader
    ;;; can tell a short gloss from a trimmed one
    if length(h) > cols then
        zine_wrap(h, cols) -> ls;
        hd(ls) <> (if length(ls) > 1 then ' ...' else '' endif) -> h;
    endif;
enddefine;

define zine_plan_page(items, skip, page, title) -> out;
    lvars items, skip, page, title, i, out, y = 520, n = 0, g, rd;
    zine_title(title, false) -> out;
    for i in items do
        n + 1 -> n;
        nextif(n <= skip);
        quitif(n > skip + 8);
        lp_any_form(i) -> g;
        zine_hint(i, 34) -> rd;
        ;;; the term, then the hint UNDER it rather than beside it: an
        ;;; English item's term is a word and not a glyph, so the two
        ;;; would collide in the middle of the panel
        out <> sheet_text(ZPAD, y, Z_GLYPH, '#1b1a17', 'start', g sys_>< '')
            -> out;
        if rd then
            out <> sheet_text(ZPAD, y + 62, Z_TINY, '#6b6457', 'start', rd)
                -> out;
        endif;
        y + 185 -> y;
    endfor;
    if n <= skip then
        out <> zine_para(y, Z_BODY, '#6b6457', zine_say("nomore"), 26) -> out;
    endif;
    out <> zine_num(page) -> out;
enddefine;

define zine_again(rows) -> out;
    lvars rows, r, out, y = 520, n = 0, g, rd;
    zine_title(zine_say("again"), false) -> out;
    for r in rows do
        nextif(r(2) == "right");
        n + 1 -> n; quitif(n > 9);
        lp_any_form(r(1)) -> g;
        zine_hint(r(1), 30) -> rd;
        out <> sheet_text(ZPAD, y, Z_BODY, '#8a8275', 'start',
                          sheet_mark(r(2)))
            <> sheet_text(ZPAD + 110, y, Z_GLYPH, '#2f4a7a', 'start',
                          g sys_>< '') -> out;
        if rd then
            out <> sheet_text(ZPAD + 110, y + 62, Z_TINY, '#8a8275', 'start',
                              rd) -> out;
        endif;
        y + 185 -> y;
    endfor;
    if n == 0 then
        out <> zine_para(y, Z_BODY, '#6b6457', zine_say("nomiss"), 26) -> out;
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
    zine_title(zine_say("ladder"),
               (lp_lang sys_>< '') <> ', ' <> zine_say("allofit")) -> out;
    for l in lp_levels(lp_lang) do
        (l == lp_level) -> here;
        out <> sheet_text(ZPAD, y, Z_BODY, if here then '#1b1a17'
                                           else '#8a8275' endif,
                          'start', l sys_>< '') -> out;
        if here then
            out <> sheet_text(PW - ZPAD, y, Z_SMALL, '#2f4a7a', 'end',
                              zine_say("youhere")) -> out;
        endif;
        y + 150 -> y;
    endfor;
    out <> zine_para(y + 60, Z_SMALL, '#8a8275', zine_say("rung"), 32)
        <> zine_num(6) -> out;
enddefine;

define zine_back() -> out;
    lvars out, y;
    zine_title(zine_say("fold"), false) -> out;
    460 -> y;
    out <> zine_para(y, Z_SMALL, '#6b6457', zine_say("howto"), 32) -> out;
    1240 -> y;
    ;;; Separated by a dot and not by spaces: SVG collapses runs of
    ;;; whitespace, so the columns I lined up in the source arrived on
    ;;; paper as "? did not know x wrong".
    out <> sheet_text(ZPAD, y, Z_BODY, '#1b1a17', 'start', zine_say("onp7"))
        <> sheet_text(ZPAD, y + 95, Z_SMALL, '#6b6457', 'start',
                      zine_say("legend1"))
        <> sheet_text(ZPAD, y + 165, Z_SMALL, '#6b6457', 'start',
                      zine_say("legend2"))
        -> out;
    out <> zine_para(1620, Z_TINY, '#8a8275', zine_say("privacy"), 38)
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
    <> zine_place(4, zine_plan_page(plan, 0, 4, zine_say("next")))
    <> zine_place(5, zine_plan_page(plan, 9, 5, zine_say("then")))
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
