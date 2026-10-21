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
    elseif style == "today" then
        unless user and lp_user == user then
            'no_such_student' -> why; return;
        endunless;
        sheet_today(lp_now_ms() - DAY_MS) -> rows;
        sheet_day_svg(lp_display, rows, lp_plan()) -> svg;
        'today-' <> (user sys_>< '') -> name;
    else
        'no_such_style' -> why; return;
    endif;
    unless sys_file_exists(sheet_dir()) then
        sysobey('mkdir -p ' <> sheet_dir());
    endunless;
    sheet_dir() <> name <> '.svg' -> path;
    lp_write_file(path, svg);
enddefine;
