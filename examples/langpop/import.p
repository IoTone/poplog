/* examples/langpop/import.p -- upstream content into graph facts.

   The graph has one rung.  170 items sit at pre-school and every level
   above it is empty, while both ladders declare exit criteria -- N5's
   kanji(100), A2's vocabulary(1000) -- that nothing in the graph can
   satisfy.  Filling those rungs by hand is thousands of lines of typing
   and, worse, thousands of chances to get a glyph subtly wrong.

   So this reads upstream reference data and emits graph facts.  Two
   things make that safe to do, and they are the whole design:

   1. THE REPO HOLDS CURATION, NEVER CONTENT.  JMdict and KANJIDIC2 are
      CC BY-SA 4.0 (EDRDG).  Share-alike on a dictionary is fine for a
      dictionary and poison for a tutor -- it is exactly why the project
      decided "importer in the tree, decks never".  What this file emits
      is therefore a BUILD PRODUCT: graph/<lang>/generated/ is ignored by git,
      regenerated from upstream, and carries upstream's notice in its own
      header.  What IS committed is graph/<lang>/picks/<level>.pl -- which entries,
      at which level, under which identity -- because that is the
      teaching judgment, and it is ours.

   2. AN IDENTITY IS NEVER GENERATED.  hi_a is the identity and 'あ' is
      one of its forms (graph/schema.pl), so an id minted from upstream
      would change when upstream renumbered, and every belief a student
      had recorded against it would quietly detach.  Word ids are written
      by the curator in the pick file.  The one exception is kanji, whose
      id is k_<codepoint>: a codepoint is not upstream's opinion.

   Two import modes, because the two sources differ in what they know:

       # KANJIDIC2 carries the level, so the selection is a RULE
       ./poplog basepop11 examples/langpop/import.p --source kanjidic \
            --file <dir>/kanjidic2.xml --level n5 --jlpt 4

       # JMdict does not, so the selection is a PICK LIST
       ./poplog basepop11 examples/langpop/import.p --source jmdict \
            --file <dir>/JMdict_e --picks graph/ja/picks/n5.pl

       --check     resolve and report, write nothing
       --out F     where to write (default graph/<lang>/generated/...)

   And one REPORT, which writes nothing at all: the gap between what the
   frequency list says people actually say and what the graph teaches,
   ranked by what each missing word would buy.  Filling a level is
   curation, so the output is a queue for a person, never facts:

       ./poplog basepop11 examples/langpop/import.p --source frequency \
            --gap --file <dir>/en_50k.txt --lang en [--top 40]

   tools/fetch-upstream.sh downloads and unpacks both files.  Neither is
   small (JMdict_e is 63MB of XML) and neither belongs in the repo.

   The XML reader below is a deliberate subset -- enough for these two
   files and no more.  If anything else in the tree ever needs XML it
   should graduate to a lib/xml.p next to lib/csv.p and lib/json.p
   rather than being copied out of here.
*/

vars langpop_lib = true;                ;;; no session: just the procedures
load 'examples/langpop/langpop.p';
uses datetime;                          ;;; dt_iso, for the generated stamp
uses utf8;                              ;;; consutf8, for numeric char refs

4000 -> poplinewidth; 4096 -> poplinemax;

;;; ------------------------------------------------------------ arguments
vars imp_source = false, imp_file = false, imp_level = false,
    imp_lang = "ja", imp_jlpt = false, imp_picks = false,
    imp_outpath = false, imp_check = false, imp_gap_want = false,
    imp_top = 40;

define imp_args();
    lvars a, rest = poparglist;
    until null(rest) do
        hd(rest) -> a; tl(rest) -> rest;
        if a = '--source' and rest /== [] then
            consword(hd(rest)) -> imp_source; tl(rest) -> rest
        elseif a = '--file' and rest /== [] then
            hd(rest) -> imp_file; tl(rest) -> rest
        elseif a = '--level' and rest /== [] then
            consword(hd(rest)) -> imp_level; tl(rest) -> rest
        elseif a = '--lang' and rest /== [] then
            consword(hd(rest)) -> imp_lang; tl(rest) -> rest
        elseif a = '--jlpt' and rest /== [] then
            strnumber(hd(rest)) -> imp_jlpt; tl(rest) -> rest
        elseif a = '--picks' and rest /== [] then
            hd(rest) -> imp_picks; tl(rest) -> rest
        elseif a = '--out' and rest /== [] then
            hd(rest) -> imp_outpath; tl(rest) -> rest
        elseif a = '--check' then true -> imp_check
        elseif a = '--gap' then true -> imp_gap_want
        elseif a = '--top' and rest /== [] then
            strnumber(hd(rest)) -> imp_top; tl(rest) -> rest
        else
            mishap(a, 1, 'import: unknown argument (--source S --file F '
                         <> '--level L --lang L --jlpt N --picks F --out F '
                         <> '--check --gap --top N)')
        endif;
    enduntil;
enddefine;

;;; ------------------------------------------------- an XML reader, subset
;;; Handles: elements, attributes, empty elements, character data, the
;;; five predefined entities, numeric character references, comments,
;;; processing instructions, and a DOCTYPE with an internal subset.
;;;
;;; Does NOT handle: CDATA sections, namespaces as anything but part of
;;; the name, or entity declarations.  JMdict declares its part-of-speech
;;; tags as entities (<pos>&adv;</pos>), and an undeclared entity is left
;;; LITERAL -- the text comes back as '&adv;', which is what imp_entity
;;; below wants anyway.  A real CDATA section raises rather than being
;;; silently mangled; neither of these files has one.
;;;
;;; Everything here works in BYTES.  The files are UTF-8 and so is the
;;; output, so the multibyte sequences pass through untouched as long as
;;; nothing interprets a byte above 127 -- and nothing here does.

lconstant XML_BUF = 262144;

vars xml_dev = false, xml_buf = false, xml_n = 0, xml_i = 0,
    xml_eof = false, xml_put = false, xml_line = 1, xml_what = false;

define xml_err(msg);
    lvars msg;
    mishap(xml_what, xml_line, 2, 'import: ' <> msg <> ' (file, line)');
enddefine;

define xml_get() -> c;
    lvars c;
    ;;; xml_put holds a pushed-back character.  A character code is never
    ;;; false, so false is a safe "nothing pushed back".
    if xml_put then
        xml_put -> c; false -> xml_put; return
    endif;
    if xml_i >= xml_n then
        if xml_eof then termin -> c; return endif;
        sysread(xml_dev, xml_buf, XML_BUF) -> xml_n;
        0 -> xml_i;
        if xml_n == 0 then true -> xml_eof; termin -> c; return endif;
    endif;
    xml_i fi_+ 1 -> xml_i;
    fast_subscrs(xml_i, xml_buf) -> c;
    if c == `\n` then xml_line fi_+ 1 -> xml_line endif;
enddefine;

define xml_unget(c); lvars c; c -> xml_put; enddefine;

define xml_space(c); lvars c;
    c == `\s` or c == `\t` or c == `\n` or c == `\r`
enddefine;

define xml_skip_space() -> c;
    lvars c;
    repeat
        xml_get() -> c;
        returnunless(xml_space(c));
    endrepeat;
enddefine;

;;; A name: element or attribute.  Colons are kept, so a namespaced name
;;; arrives whole -- these files have xml:lang and nothing else.
define xml_name() -> w;
    lvars c, n = 0, w;
    repeat
        xml_get() -> c;
        quitif(c == termin or xml_space(c) or c == `>` or c == `/`
               or c == `=` or c == `"` or c == `'`);
        c; n fi_+ 1 -> n;
    endrepeat;
    xml_unget(c);
    if n == 0 then xml_err('expected a name') endif;
    consword(consstring(n)) -> w;
enddefine;

;;; An entity or character reference, having just read the `&`.  Pushes
;;; its expansion onto the stack and returns how many characters that is,
;;; because an expansion is not always one character and the callers are
;;; counting.
define imp_entity() -> n;
    lvars c, n = 0, k = 0, code, s, i, raw;
    ;;; Read up to the `;`, keeping the raw text in case the entity turns
    ;;; out to be one this reader does not know.  The characters go into a
    ;;; LIST and not onto the stack: the stack is where this procedure's
    ;;; own result is being built up, and consstring cannot be reached
    ;;; past a mark that is still accumulating.
    [% repeat
          xml_get() -> c;
          quitif(c == termin or c == `;`);
          c; k fi_+ 1 -> k;
          if k > 24 then xml_err('runaway entity reference') endif;
       endrepeat %] -> raw;
    if c == termin then xml_err('unterminated entity reference') endif;
    consstring(destlist(raw)) -> s;
    if     s = 'lt'   then `<`; 1 -> n
    elseif s = 'gt'   then `>`; 1 -> n
    elseif s = 'amp'  then `&`; 1 -> n
    elseif s = 'quot' then `"`; 1 -> n
    elseif s = 'apos' then `'`; 1 -> n
    elseif length(s) >= 2 and subscrs(1, s) == `#` then
        ;;; Parsed digit by digit rather than through strnumber: Poplog's
        ;;; radix literal is 16:FF and strnumber will not read 16:e9, so
        ;;; every lowercase hex reference came back false.
        lvars base = 10, dstart = 2, d;
        if subscrs(2, s) == `x` or subscrs(2, s) == `X` then 16 -> base; 3 -> dstart endif;
        0 -> code;
        if dstart > length(s) then xml_err('empty character reference') endif;
        for i from dstart to length(s) do
            subscrs(i, s) -> d;
            if     d >= `0` and d <= `9` then d - `0`
            elseif base == 16 and d >= `a` and d <= `f` then d - `a` + 10
            elseif base == 16 and d >= `A` and d <= `F` then d - `A` + 10
            else xml_err('bad character reference')
            endif -> d;
            code * base + d -> code;
        endfor;
        unless isinteger(code) then xml_err('bad character reference') endunless;
        code; consutf8(1) -> s;
        for i from 1 to length(s) do subscrs(i, s) endfor;
        length(s) -> n;
    else
        ;;; unknown: hand back the source text, &name; and all.  JMdict's
        ;;; &adv; and friends are declared in its internal subset, which
        ;;; this reader skips on purpose.
        `&`; 1 -> n;
        for i from 1 to length(s) do subscrs(i, s); n fi_+ 1 -> n endfor;
        `;`; n fi_+ 1 -> n;
    endif;
enddefine;

;;; An attribute value, quoted either way.
define xml_attval() -> s;
    lvars c, q, n = 0;
    xml_skip_space() -> q;
    unless q == `"` or q == `'` then xml_err('expected a quoted attribute value') endunless;
    repeat
        xml_get() -> c;
        if c == termin then xml_err('unterminated attribute value') endif;
        quitif(c == q);
        if c == `&` then imp_entity() + n -> n else c; n fi_+ 1 -> n endif;
    endrepeat;
    consstring(n) -> s;
enddefine;

;;; Having read `<!`, skip the construct: a comment, or a declaration
;;; whose internal subset may itself hold declarations and comments.
;;; DOCTYPE is where both of these files keep their DTD, and JMdict's is
;;; 500 lines of it, so getting the nesting right is not optional.
;;; A comment is reported rather than merely skipped, because JMdict keeps
;;; the one thing a generated file must record -- which day's data this is
;;; -- in a comment and not in an element: <!-- JMdict created: 2026-10-20 -->.
;;; The hook is a variable and not another xml_scan argument so that a
;;; reader which does not care says nothing at all.
vars xml_on_comment = erase;

;;; Having read `<!--`, skip to the matching `-->`.
define xml_skip_comment();
    lvars c, h1 = 0, h2 = 0, n = 0;
    repeat
        xml_get() -> c;
        if c == termin then xml_err('unterminated comment') endif;
        quitif(c == `>` and h1 == `-` and h2 == `-`);
        c; n fi_+ 1 -> n;
        h1 -> h2; c -> h1;
    endrepeat;
    ;;; The `--` of the terminator was pushed before the loop noticed the
    ;;; `>`, and it is on TOP, so it comes off before the string is built.
    if n >= 2 then
        erase(); erase();
        xml_on_comment(consstring(n fi_- 2));
    else
        xml_on_comment(consstring(n));
    endif;
enddefine;

define xml_skip_decl();
    lvars c, depth = 0, h1 = 0, h2 = 0, h3 = 0, q = false, incom = false;
    xml_get() -> c;
    if c == `-` then
        xml_get() -> c;
        unless c == `-` then xml_err('expected a comment') endunless;
        xml_skip_comment();
        return;
    endif;
    if c == `[` then xml_err('CDATA sections are not supported') endif;
    xml_unget(c);
    ;;; A declaration, scanned to its own `>`.  The bracket depth is for
    ;;; the internal subset, and the two other modes are not decoration:
    ;;; a DTD comment may contain `]]` or `>` and an ENTITY's replacement
    ;;; text may contain either, so a scanner that counted brackets alone
    ;;; runs off the end of the file -- which is how this was found.
    repeat
        xml_get() -> c;
        if c == termin then xml_err('unterminated declaration') endif;
        if incom then
            if c == `>` and h1 == `-` and h2 == `-` then false -> incom endif
        elseif q then
            if c == q then false -> q endif
        elseif c == `"` or c == `'` then c -> q
        elseif c == `-` and h1 == `-` and h2 == `!` and h3 == `<` then true -> incom
        elseif c == `[` then depth fi_+ 1 -> depth
        elseif c == `]` then depth fi_- 1 -> depth
        elseif c == `>` and depth == 0 then return
        endif;
        h2 -> h3; h1 -> h2; c -> h1;
    endrepeat;
enddefine;

;;; The scan.  on_open(name, attrs) with attrs a list of [name value],
;;; on_text(string) for each non-empty run of character data, and
;;; on_close(name).  An empty element reports both open and close.
define xml_scan(path, on_open, on_text, on_close);
    lvars path, on_open, on_text, on_close, c, nm, nat, av, s, n;
    dlocal xml_dev, xml_buf, xml_n = 0, xml_i = 0, xml_eof = false,
           xml_put = false, xml_line = 1, xml_what = path;
    sysopen(path, 0, true) -> xml_dev;
    unless xml_dev then mishap(path, 1, 'import: cannot read source file') endunless;
    inits(XML_BUF) -> xml_buf;
    repeat
        ;;; character data up to the next `<`
        0 -> n;
        repeat
            xml_get() -> c;
            quitif(c == termin or c == `<`);
            if c == `&` then imp_entity() + n -> n else c; n fi_+ 1 -> n endif;
        endrepeat;
        consstring(n) -> s;
        ;;; Whitespace between elements is layout, not content.  Both of
        ;;; these files put every element on its own line, so without this
        ;;; every leaf would be handed a newline before its real text.
        if n > 0 then
            lvars j, blank = true;
            for j from 1 to n do
                unless xml_space(subscrs(j, s)) then false -> blank; quitloop endunless;
            endfor;
            unless blank then on_text(s) endunless;
        endif;
        quitif(c == termin);

        ;;; a tag
        xml_get() -> c;
        if c == `!` then
            xml_skip_decl();
        elseif c == `?` then
            lvars prev = 0;
            repeat
                xml_get() -> c;
                if c == termin then xml_err('unterminated processing instruction') endif;
                quitif(c == `>` and prev == `?`);
                c -> prev;
            endrepeat;
        elseif c == `/` then
            xml_name() -> nm;
            xml_skip_space() -> c;
            unless c == `>` then xml_err('expected > closing an end tag') endunless;
            on_close(nm);
        else
            xml_unget(c);
            xml_name() -> nm;
            ;;; attributes
            0 -> nat;
            repeat
                xml_skip_space() -> c;
                quitif(c == `>` or c == `/` or c == termin);
                xml_unget(c);
                [% xml_name();
                   xml_skip_space() -> c;
                   unless c == `=` then xml_err('expected = in an attribute') endunless;
                   xml_attval() %];
                nat fi_+ 1 -> nat;
            endrepeat;
            if c == termin then xml_err('unterminated start tag') endif;
            ;;; The list is built BEFORE nm reaches the stack.  conslist(n)
            ;;; takes the top n items, and the attribute lists were pushed
            ;;; before the name was, so building it inside the call would
            ;;; hand conslist the name and the attributes to on_open.
            conslist(nat) -> av;
            on_open(nm, av);
            if c == `/` then
                xml_get() -> c;
                unless c == `>` then xml_err('expected > closing an empty element') endunless;
                on_close(nm);
            endif;
        endif;
    endrepeat;
    sysclose(xml_dev);
enddefine;

;;; ------------------------------------------------------- writing Prolog
;;; Quoting, which is the one thing in this file that MUST be right: a
;;; gloss like "one's own" would otherwise end the atom in the middle and
;;; leave the rest of the line as syntax.  Every piece of upstream text
;;; goes through imp_atom.
;;;
;;; The escape is a BACKSLASH, not a doubled quote.  Standard Prolog
;;; doubles it, Poplog Prolog does not accept that, and the way it says so
;;; is the problem:
;;;
;;;     d1('doubled''quote').     ;;; FOUND : 'quote'  -- clause DROPPED
;;;     d2('backslash\'quote').   ;;; ok
;;;
;;; A syntax error in a consulted file is not fatal.  Prolog reports it,
;;; skips that clause and carries on, so the first version of this file
;;; emitted three glosses containing an apostrophe that silently never
;;; reached the graph -- and check(graph) passed, because there is no
;;; integrity rule saying an item must have a gloss.  imp_verify below is
;;; the answer to that, and it is why it exists.
vars imp_dev = false;

define imp_out(s);
    lvars s, c;
    for c in_string s do imp_dev(c) endfor;
enddefine;

define imp_pr(fmt, args);
    lvars fmt, args;
    ;;; sprintf(STRING, ITEM_LIST) -- format first when the arguments come
    ;;; as a list (REF * PRINT); the other form takes them on the stack.
    imp_out(sprintf(fmt, args));
enddefine;

;;; A quoted Prolog atom.  Control characters are dropped rather than
;;; escaped: upstream has no business putting a newline in a gloss, and a
;;; fact that spans lines is a fact no diff can read.
define imp_atom(x) -> s;
    lvars x, c, n = 0, s = x sys_>< '';
    `'`; 1 -> n;
    for c in_string s do
        if c == `'` then `\\`; `'`; n fi_+ 2 -> n
        elseif c == `\\` then `\\`; `\\`; n fi_+ 2 -> n
        elseif c < 32 or c == 127 then                  ;;; dropped, see above
        else c; n fi_+ 1 -> n
        endif;
    endfor;
    `'`; n fi_+ 1 -> n;
    consstring(n) -> s;
enddefine;

;;; Trim and squash the whitespace out of an upstream string.
define imp_trim(s) -> t;
    lvars s, c, n = 0, sp = false, started = false;
    for c in_string s do
        if xml_space(c) then
            if started then true -> sp endif;
        else
            if sp then `\s`; n fi_+ 1 -> n endif;
            false -> sp; true -> started;
            c; n fi_+ 1 -> n;
        endif;
    endfor;
    consstring(n) -> t;
enddefine;

;;; ---------------------------------------------------------- the entries
;;; One upstream entry, whichever source it came from, reduced to what a
;;; graph fact needs.  A vector and not a record because this file hands
;;; them straight to the emitter and nothing else ever sees one:
;;;   {id  kind  prov  forms  gloss  reqs  ranks}
;;; with forms a list of [script text], prov the provenance term as the
;;; text that will be written, reqs a list of prerequisite ids, and ranks
;;; a list of [scale n].
define imp_entry(id, kind, prov, forms, gloss, reqs) -> e;
    lvars id, kind, prov, forms, gloss, reqs, e;
    {% id, kind, prov, forms, gloss, reqs, [] %} -> e;
enddefine;

;;; The same with a place on one or more difficulty scales.
define imp_entry_ranked(id, kind, prov, forms, gloss, reqs, ranks) -> e;
    lvars id, kind, prov, forms, gloss, reqs, ranks, e;
    {% id, kind, prov, forms, gloss, reqs, ranks %} -> e;
enddefine;

define imp_e_id(e);     lvars e; e(1) enddefine;
define imp_e_kind(e);   lvars e; e(2) enddefine;
define imp_e_prov(e);   lvars e; e(3) enddefine;
define imp_e_forms(e);  lvars e; e(4) enddefine;
define imp_e_gloss(e);  lvars e; e(5) enddefine;
define imp_e_reqs(e);   lvars e; e(6) enddefine;
define imp_e_ranks(e);  lvars e; e(7) enddefine;

;;; Lines printed once, after the generated/5 stamp: a fact about the
;;; IMPORT rather than about any one item.  The frequency source needs
;;; one -- a count means nothing without the total it is a count out of.
vars imp_extra = [];

;;; An attribute's value, or false.
define imp_attr(attrs, name) -> v;
    lvars attrs, name, a, v = false;
    for a in attrs do
        if hd(a) == name then hd(tl(a)) -> v; return endif;
    endfor;
enddefine;

;;; Lowercase hex, because printf has no conversion for it.  REF * PRINT
;;; lists p P s S c M and %% and then says of b, d, i and x that they are
;;; "reserved for system use" -- and %x duly prints the raw tagged machine
;;; word, so sprintf('%x', [23665]) came out as 00000000000171C7 rather
;;; than 5c71 and every kanji id was minted wrong.  Nothing warns: the
;;; word is a perfectly good hex number, just not of the integer.
define imp_hex(n) -> s;
    lvars n, s, d, k = 0;
    if n == 0 then '0' -> s; return endif;
    until n == 0 do
        n fi_&& 15 -> d;
        if d < 10 then d fi_+ `0` else d fi_- 10 fi_+ `a` endif;
        n fi_>> 4 -> n;
        k fi_+ 1 -> k;
    enduntil;
    ;;; the digits came off least-significant first
    consstring(k) -> s;
    lvars i, t = inits(k);
    for i from 1 to k do subscrs(k fi_- i fi_+ 1, s) -> subscrs(i, t) endfor;
    t -> s;
enddefine;

;;; Split on whitespace: CMUdict is a line of a word and its phonemes.
define imp_split(str) -> l;
    lvars str, c, n = 0, l = [], start = 0, i, len = length(str);
    [% for i from 1 to len fi_+ 1 do
           if i > len or xml_space(subscrs(i, str)) then
               if start > 0 then substring(start, i fi_- start, str) endif;
               0 -> start;
           elseif start == 0 then i -> start;
           endif;
       endfor %] -> l;
enddefine;

;;; The first n of a list, or all of it.
define imp_first(l, n) -> r;
    lvars l, n, r = [], k = 0;
    until l == [] or k >= n do
        r <> [% hd(l) %] -> r; tl(l) -> l; k fi_+ 1 -> k;
    enduntil;
enddefine;

;;; Join strings with a separator.
define imp_join(l, sep) -> s;
    lvars l, sep, x, s = '', first = true;
    for x in l do
        unless first then s <> sep -> s endunless; false -> first;
        s <> (x sys_>< '') -> s;
    endfor;
enddefine;

;;; The upstream stamp both readers fill in, for the generated header.
vars imp_upstream = false;

;;; ------------------------------------------------------------- KANJIDIC2
;;; KANJIDIC2 carries a level, which is why the kanji import needs no pick
;;; list: <jlpt> is the pre-2010 four-level JLPT, and old level 4 is the
;;; one that became N5.  That mapping is official and exact at this end of
;;; the ladder -- it is old level 3 splitting into N4 and N3 that has no
;;; clean answer -- so N5 kanji can be taken from upstream wholesale while
;;; N4's cannot.  The count that comes out is 103 against the ladder's
;;; kanji(100), which is as close as a withdrawn syllabus gets.
;;;
;;; The identity is k_<codepoint>.  This is the one place the importer
;;; mints an id, and it is safe for the reason mkkana.py gives for
;;; generating the kana from codepoints: a codepoint is not an opinion
;;; upstream can revise.
;;; A KANJIDIC2 kun reading, as Japanese rather than as KANJIDIC notation.
;;; Upstream writes 安 as やす.い and 一 as ひと-, where the dot marks where
;;; the character's own reading stops and the okurigana begins, and the
;;; hyphen marks a prefix or suffix position.  The reading of the KANJI is
;;; the part before the dot: 安い is a word and やす is what 安 says in it.
;;; Emitting the notation raw would put a full stop in the middle of a
;;; flashcard, which is how this was noticed.
define imp_kun(s) -> t;
    lvars s, c, n = 0;
    for c in_string s do
        quitif(c == `.`);
        nextif(c == `-`);
        c; n fi_+ 1 -> n;
    endfor;
    consstring(n) -> t;
enddefine;

define imp_kanjidic(path, want_jlpt) -> es;
    lvars path, want_jlpt, es = [],
          nm = false, at = [],
          lit = false, ucs = false, jlpt = false,
          freq = false, grade = false, strokes = false,
          rmg = 0, ons = [], kuns = [], means = [],
          hdr_file = false, hdr_db = false, hdr_date = false, seen = 0;

    xml_scan(path,
        procedure(n, a);
            lvars n, a;
            n -> nm; a -> at;
            if n == "character" then
                seen fi_+ 1 -> seen;
                false -> lit; false -> ucs; false -> jlpt;
                false -> freq; false -> grade; false -> strokes;
                0 -> rmg; [] -> ons; [] -> kuns; [] -> means;
            elseif n == "rmgroup" then
                ;;; Only the first reading-meaning group is taken.  A
                ;;; second rmgroup is a different sense of the character
                ;;; with its own readings, and splicing the two together
                ;;; would pair a reading with a meaning it does not have.
                rmg fi_+ 1 -> rmg
            endif;
        endprocedure,

        procedure(s);
            lvars s, t = imp_trim(s);
            if     nm == "literal"          then t -> lit
            elseif nm == "file_version"     then t -> hdr_file
            elseif nm == "database_version" then t -> hdr_db
            elseif nm == "date_of_creation" then t -> hdr_date
            elseif nm == "jlpt"             then strnumber(t) -> jlpt
            ;;; The difficulty scales.  A frequency rank is the useful
            ;;; one -- KANJIDIC ranks exactly the top 2,501 characters by
            ;;; corpus frequency -- and the school grade and the stroke
            ;;; count come free beside it.  Only the FIRST stroke_count
            ;;; is taken: a character with variant forms lists one per
            ;;; variant, and the first is the standard one.
            elseif nm == "freq"             then strnumber(t) -> freq
            elseif nm == "grade"            then strnumber(t) -> grade
            elseif nm == "stroke_count" and not(strokes) then
                strnumber(t) -> strokes
            elseif nm == "cp_value" and imp_attr(at, "cp_type") = 'ucs' then t -> ucs
            elseif nm == "reading" and rmg == 1 then
                ;;; ja_on is written in katakana and ja_kun in hiragana,
                ;;; which is a fact about the data and also the right
                ;;; script for the form -- so each reading goes to form/3
                ;;; under the script it is actually written in.
                if     imp_attr(at, "r_type") = 'ja_on'  then ons  <> [^t] -> ons
                elseif imp_attr(at, "r_type") = 'ja_kun' then
                    lvars k = imp_kun(t);
                    unless k = '' then kuns <> [^k] -> kuns endunless
                endif
            elseif nm == "meaning" and rmg == 1 and not(imp_attr(at, "m_lang")) then
                ;;; no m_lang means English; es, fr and pt say so
                means <> [^t] -> means
            endif;
        endprocedure,

        procedure(n);
            lvars n, forms, g;
            returnunless(n == "character");
            returnunless(jlpt == want_jlpt and lit and ucs);
            ;;; One form per script, the first reading of each: a kanji
            ;;; with nine on-readings is not nine forms, and every reader
            ;;; of form/3 asks for one script and takes what it gets.
            [[kanji ^lit]] -> forms;
            unless kuns == [] then forms <> [[hiragana ^(hd(kuns))]] -> forms endunless;
            unless ons  == [] then forms <> [[katakana ^(hd(ons))]]  -> forms endunless;
            imp_join(imp_first(means, 4), ', ') -> g;
            es <> [% imp_entry_ranked(consword('k_' <> uppertolower(ucs)),
                               "grapheme",
                               'kanjidic2(ucs(' <> imp_atom(ucs) <> '), jlpt('
                                   <> (want_jlpt sys_>< '') <> '))',
                               forms, g,
                               ;;; Every kanji needs the kana, because its
                               ;;; reading is written in them.  Radical and
                               ;;; stroke data would support a deeper
                               ;;; prerequisite order and KANJIDIC2 has
                               ;;; both, but which radicals must be learned
                               ;;; before which kanji is a teaching claim
                               ;;; upstream does not make, and inventing it
                               ;;; here would put 100 edges in the graph
                               ;;; that nobody chose.
                               [hiragana_all],
                               [% if freq then [freq ^freq] endif;
                                  if grade then [grade ^grade] endif;
                                  if strokes then [strokes ^strokes] endif %])
                     %] -> es;
        endprocedure);

    ;;; Sorted by id, which for kanji is the codepoint.  Upstream's own
    ;;; order is JIS code order and stable enough in practice, but a
    ;;; generated file is read by diffing it against the last one, and
    ;;; that is only worth anything if the order is ours.
    syssort(es, false, procedure(a, b); lvars a, b;
        alphabefore(imp_e_id(a), imp_e_id(b)) endprocedure) -> es;

    'KANJIDIC2 file_version ' <> (hdr_file or '?')
        <> ', database_version ' <> (hdr_db or '?')
        <> ', created ' <> (hdr_date or '?')
        <> ' (' <> (seen sys_>< '') <> ' characters read)' -> imp_upstream;
enddefine;

;;; ---------------------------------------------------------------- JMdict
;;; JMdict has no level marking of any kind, and no amount of reading it
;;; will produce one: JLPT's content specifications were withdrawn in 2010
;;; (graph/ja/ladder.pl says so at more length).  So the selection cannot
;;; come from upstream, and it comes from a pick file instead -- which is
;;; the right place for it anyway, because "which 800 words are N5" is a
;;; teaching claim and the project's decision was that a human makes it.
;;;
;;; A pick names an entry one of three ways:
;;;
;;;     pick(w_neko, ja, n5, word, jmdict_kana('ねこ')).
;;;     pick(w_hon,  ja, n5, word, jmdict_kanji('本')).
;;;     pick(w_hashi, ja, n5, word, jmdict('1518850')).
;;;
;;; The first two are what a curator can actually write; the third is the
;;; escape hatch, because はし is 橋 and 箸 and 端 and a reading that names
;;; three entries names none of them.  An ambiguous key is an ERROR with
;;; the candidates listed, not a guess -- a tutor that silently taught
;;; "chopsticks" for a pick meaning "bridge" would be wrong in a way
;;; nothing downstream could detect.

;;; Which script a kana reading is written in.  A loanword's reading is
;;; katakana and a native word's is hiragana, and emitting both as
;;; hiragana would make コーヒー a hiragana word.
define imp_kana_script(s) -> script;
    lvars s, script = "hiragana";
    if length(s) > 0 and utf8_code(1, s) >= 16:30A0 then "katakana" -> script endif;
enddefine;

;;; The kanji items a written form contains, for those already in the
;;; graph.  This is the one place an edge comes out of upstream data
;;; rather than a human: 本 is in 日本, so a student who cannot read 本
;;; cannot read 日本, and that is not an opinion.  A kanji NOT in the
;;; graph adds no edge -- the word is then taught in kana, which is what
;;; a learner does anyway before they meet the character.
define imp_kanji_reqs(s) -> reqs;
    lvars s, reqs = [], code, id;
    returnif(not(s)) ([] -> reqs);
    utf8_appcodes(s, procedure(code);
        lvars code, id;
        ;;; CJK Unified Ideographs, plus the extension A block below it
        returnunless(code >= 16:3400 and code <= 16:9FFF);
        consword('k_' <> imp_hex(code)) -> id;
        if lp_ilang(id) and not(member(id, reqs)) then
            reqs <> [^id] -> reqs
        endif;
    endprocedure);
enddefine;

;;; A cheap signature for the pre-filter above: the length and the first
;;; byte, which is enough to throw away almost every entry without
;;; interning its headword.  Integers are compared by value in a property
;;; even though strings are not.
define imp_sig(s) -> n;
    lvars s, n;
    if s = '' then 0 -> n else length(s) fi_* 256 fi_+ subscrs(1, s) -> n endif;
enddefine;

define imp_jmdict(path, picks, preqs) -> (es, unresolved);
    lvars path, picks, preqs, es = [], unresolved = [], p,
          ;;; Keyed by WORDS and not by strings.  A Pop-11 property
          ;;; compares its keys with == , so two equal strings are two
          ;;; different keys and every single lookup missed -- which read
          ;;; as "matches no entry" for all 148 picks.  Words are
          ;;; interned, so equal words are the same word.
          ;;;
          ;;; Default [] and not false: every one of these is read and
          ;;; appended to in one breath, and a property whose default is
          ;;; false hands back false the first time.
          by_seq = newproperty([], 64, [], "perm"),
          by_keb = newproperty([], 64, [], "perm"),
          by_reb = newproperty([], 64, [], "perm"),
          cands  = newproperty([], 64, [], "perm"),
          want_sig = newproperty([], 512, false, "perm"),
          nm = false, at = [], seq = false, kebs = [], rebs = [],
          sense = 0, glosses = [], plain = [], created = false, seen = 0;

    dlocal xml_on_comment = procedure(s);
        lvars s, i;
        ;;; <!-- JMdict created: 2026-10-20 -->
        if issubstring('JMdict created:', s) ->> i then
            imp_trim(allbutfirst(i + 14, s)) -> created
        endif;
    endprocedure;

    ;;; the wanted keys, each mapping to the picks that asked for it
    for p in picks do
        lvars kk = p(5), kv = p(6), m;
        if     kk == "jmdict"       then by_seq
        elseif kk == "jmdict_kanji" then by_keb
        elseif kk == "jmdict_kana"  then by_reb
        else mishap(kk, 1, 'import: a pick key must be jmdict(..), '
                           <> 'jmdict_kanji(..) or jmdict_kana(..)')
        endif -> m;
        m(consword(kv)) <> [^p] -> m(consword(kv));
        true -> want_sig(imp_sig(kv));
    endfor;

    xml_scan(path,
        procedure(n, a);
            lvars n, a;
            n -> nm; a -> at;
            if n == "entry" then
                seen fi_+ 1 -> seen;
                false -> seq; [] -> kebs; [] -> rebs;
                0 -> sense; [] -> glosses; [] -> plain;
            elseif n == "sense" then
                sense fi_+ 1 -> sense
            endif;
        endprocedure,

        procedure(s);
            lvars s, t = imp_trim(s);
            if     nm == "ent_seq" then t -> seq
            elseif nm == "keb"     then kebs <> [^t] -> kebs
            elseif nm == "reb"     then rebs <> [^t] -> rebs
            elseif nm == "gloss" and sense == 1 then
                glosses <> [^t] -> glosses;
                ;;; A gloss with no g_type is a translation; g_type="expl"
                ;;; is an explanation and g_type="lit" a literal reading,
                ;;; and a card wants the translation if there is one.
                unless imp_attr(at, "g_type") then plain <> [^t] -> plain endunless
            endif;
        endprocedure,

        procedure(n);
            lvars n, matched = [], p, k;
            returnunless(n == "entry");
            returnunless(seq);
            ;;; consword interns, and interning every headword of 219k
            ;;; entries would put three quarters of a million words in the
            ;;; dictionary to look up 148.  So the length and first byte
            ;;; are checked first, against a set the picks built, and the
            ;;; vast majority of entries never reach consword at all.
            if want_sig(imp_sig(seq)) then by_seq(consword(seq)) -> matched endif;
            for k in kebs do
                if want_sig(imp_sig(k)) then matched <> by_keb(consword(k)) -> matched endif
            endfor;
            for k in rebs do
                if want_sig(imp_sig(k)) then matched <> by_reb(consword(k)) -> matched endif
            endfor;
            returnif(matched == []);
            ;;; One candidate per (pick, entry).  The entry is kept whole
            ;;; because the ambiguity report names the glosses, which is
            ;;; the only thing that tells a curator which はし they meant.
            for p in matched do
                cands(p(1)) <> [% {% seq, kebs, rebs,
                                    if plain == [] then glosses else plain endif %} %]
                    -> cands(p(1));
            endfor;
        endprocedure);

    'JMdict, created ' <> (created or '?')
        <> ' (' <> (seen sys_>< '') <> ' entries read)' -> imp_upstream;

    ;;; Resolved in pick-file order, which is the curator's order and the
    ;;; only one that makes a diff of this file readable alongside a diff
    ;;; of the picks.
    for p in picks do
        lvars cs = cands(p(1)), e, forms, g, reqs;
        if cs == [] then
            unresolved <> [[^p not_found]] -> unresolved;
            nextloop;
        endif;
        if length(cs) > 1 then
            unresolved <> [[^p ambiguous ^cs]] -> unresolved;
            nextloop;
        endif;
        hd(cs) -> e;
        ;;; One form per script and the first of each, as for kanji.  A
        ;;; word with three spellings is one item: 1518850 is はし whether
        ;;; it is written 橋 or 梁, and a student learns a word, not a
        ;;; spelling table.
        [] -> forms;
        unless e(2) == [] then forms <> [[kanji ^(hd(e(2)))]] -> forms endunless;
        unless e(3) == [] then
            forms <> [[% imp_kana_script(hd(e(3))), hd(e(3)) %]] -> forms
        endunless;
        imp_join(imp_first(e(4), 3), ', ') -> g;
        ;;; Every imported word needs the kana, because its reading is
        ;;; written in them; then the kanji it contains that the graph
        ;;; already has; then whatever the pick file said by hand.
        [hiragana_all] -> reqs;
        lvars kr, pr;
        unless e(2) == [] then
            for kr in imp_kanji_reqs(hd(e(2))) do
                unless member(kr, reqs) then reqs <> [^kr] -> reqs endunless;
            endfor;
        endunless;
        for pr in preqs do
            if hd(pr) == p(1) and not(member(hd(tl(pr)), reqs)) then
                reqs <> [% hd(tl(pr)) %] -> reqs
            endif;
        endfor;
        es <> [% imp_entry(p(1), p(4),
                           'jmdict(' <> imp_atom(e(1)) <> ')',
                           forms, g, reqs) %] -> es;
    endfor;
enddefine;

;;; ------------------------------------------------------------ pick files
;;; The pick file is Prolog, so it is READ by Prolog rather than by a
;;; parser written here.  It is compiled on top of the graph, which is
;;; safe because pick/5 and pick_requires/2 appear nowhere in the graph --
;;; prolog_compile's reconsult semantics replace a predicate's clauses,
;;; and these two have none to replace.
define imp_load_picks(path) -> ps;
    lvars path, src = lp_read_file(path), ps = [], t, k, extra;
    unless src then mishap(path, 1, 'import: cannot read pick file') endunless;
    ;;; A guard clause for each relation the collectors below call.  Under
    ;;; schema.pl's unknown(_, error) a predicate with no clauses RAISES,
    ;;; so a pick file that declared no prerequisites would abort the
    ;;; import rather than simply having none.
    '\npick(none, none, none, none, none).\n'
      <> 'pick_requires(none, none).\n'
      <> 'all_picks :- pick(I, L, Lv, K, Key), Key \\== none,\n'
      <> '    lp_take(p(I, L, Lv, K, Key)), fail.\n'
      <> 'all_picks.\n'
      <> 'all_pick_reqs :- pick_requires(I, P), P \\== none,\n'
      <> '    lp_take(r(I, P)), fail.\n'
      <> 'all_pick_reqs.\n' -> extra;
    prolog_compile(stringin(src <> extra));
    for t in lp_ask("all_picks", 0) do
        prolog_full_deref(prolog_arg(5, t)) -> k;
        unless prolog_complexterm(k) and prolog_arity(k) == 1 then
            mishap(prolog_full_deref(prolog_arg(1, t)), 1,
                   'import: pick key must be jmdict(..), jmdict_kanji(..) '
                   <> 'or jmdict_kana(..)')
        endunless;
        ps <> [% {% prolog_deref(prolog_arg(1, t)),      ;;; id
                    prolog_deref(prolog_arg(2, t)),      ;;; lang
                    prolog_deref(prolog_arg(3, t)),      ;;; level
                    prolog_deref(prolog_arg(4, t)),      ;;; kind
                    prolog_functor(k),                   ;;; key kind
                    prolog_full_deref(prolog_arg(1, k)) sys_>< ''  ;;; key
                 %} %] -> ps;
    endfor;
enddefine;

;;; The hand-written prerequisites from the same file, as [item pre] pairs.
define imp_load_pick_reqs() -> rs;
    lvars rs = [], t;
    for t in lp_ask("all_pick_reqs", 0) do
        rs <> [[% prolog_deref(prolog_arg(1, t)),
                  prolog_deref(prolog_arg(2, t)) %]] -> rs;
    endfor;
enddefine;

;;; --------------------------------------------------------- the generated
;;; What comes out is a graph file like any other, except that it says so
;;; in its first line and carries upstream's licence notice.  It is never
;;; committed: graph/<lang>/generated/.gitignore keeps the whole directory
;;; out, and langpop.p's GRAPH_GENERATED treats a missing one as a level
;;; with no content rather than an error.

lconstant NOTICE = [
 'JMdict'
   ['JMdict is the property of the Electronic Dictionary Research and'
    'Development Group (EDRDG) and is used in conformance with the'
    'Group\'s licence: Creative Commons Attribution-ShareAlike 4.0.'
    'See https://www.edrdg.org/edrdg/licence.html .']
 'CMUdict'
   ['The CMU Pronouncing Dictionary is Copyright (C) 1993-2015 Carnegie'
    'Mellon University; all rights reserved.  Redistributed under its'
    'two-clause BSD licence, which requires that the copyright notice,'
    'the list of conditions and the disclaimer be retained.  See'
    'cmudict.LICENSE beside the source file for the full text.']
 'KANJIDIC2'
   ['KANJIDIC2 is the property of the Electronic Dictionary Research and'
    'Development Group (EDRDG) and is used in conformance with the'
    'Group\'s licence: Creative Commons Attribution-ShareAlike 4.0.'
    'See https://www.edrdg.org/edrdg/licence.html .']
 'FrequencyWords'
   ['Frequency counts from hermitdave/FrequencyWords, whose README states'
    '"MIT License for code.  CC-by-sa-4.0 for content." -- two named'
    'licences partitioning the repository rather than contradicting each'
    'other, which is why this source was taken and NGSL was not.  The'
    'counts derive from the OpenSubtitles corpus (opus.nlpl.eu), which'
    'asks for attribution.  Share-alike stays on upstream\'s layer by the'
    'same arrangement as JMdict: this file is a build product and is'
    'never committed.'
    ''
    'NOTE ON FIT: OpenSubtitles is DIALOGUE.  Its frequency profile is'
    'a good basis for coverage(listening, _) and a proxy for'
    'coverage(reading, _), whose published thresholds come from written'
    'corpora.  The scale is named in every fact so the difference is'
    'visible rather than averaged away.']
];

define imp_notice(src) -> l;
    lvars src, l = [], n = NOTICE;
    until n == [] do
        if hd(n) = src then hd(tl(n)) -> l; return endif;
        tl(tl(n)) -> n;
    enduntil;
enddefine;

define imp_emit(es, srcname, path);
    lvars es, srcname, path, e, f, r, line;
    imp_pr('%% %p -- GENERATED.  Do not edit; edit the pick list instead.\n',
           [^path]);
    imp_out('%\n');
    for line in imp_notice(srcname) do imp_pr('%% %p\n', [^line]) endfor;
    imp_out('%\n');
    imp_pr('%% Written by examples/langpop/import.p on %p\n', [% dt_iso(sys_real_time()) %]);
    imp_pr('%% from %p.\n', [% imp_upstream or 'an unrecorded source' %]);
    imp_out('%\n');
    imp_pr('%% Nothing in this file is committed.  It is a build product, so\n'
           <> '%% that upstream\'s share-alike stays on upstream\'s layer and\n'
           <> '%% reaches nothing else the project ships -- which is the whole\n'
           <> '%% reason the importer exists.  Regenerate it with:\n'
           <> '%%     tools/fetch-upstream.sh && see examples/langpop/import.p\n', []);
    imp_out('\n');

    ;;; The stamp.  A level with no content and a level whose content was
    ;;; never built look identical to ready/4 -- both have no items -- and
    ;;; they are not the same thing to tell a student.  This is what
    ;;; content_built/2 reads.
    imp_pr('generated(%p, %p, %p, %p, %p).\n\n',
           [% ;;; = and not == : two equal strings are two objects, and
              ;;; == put kanjidic2 in the header of the words file.
              if     srcname = 'JMdict'   then 'jmdict'
              elseif srcname = 'CMUdict'  then 'cmudict'
              elseif srcname = 'FrequencyWords' then 'frequency'
              else   'kanjidic2' endif,
              imp_lang, imp_level, length(es), imp_atom(dt_iso(sys_real_time())) %]);
    for line in imp_extra do imp_pr('%p\n', [^line]) endfor;
    unless imp_extra == [] then imp_out('\n') endunless;

    for e in es do
        ;;; An entry with no kind declares no item.  That is the cmudict
        ;;; mode: it adds a form and some edges to an item a committed
        ;;; graph file already declared, rather than bringing a new one
        ;;; into existence.  Prolog does not mind -- the whole graph is
        ;;; concatenated and compiled once -- and neither does the schema.
        if imp_e_kind(e) then
            imp_pr('item(%p, %p, %p, %p, %p).\n',
                   [% imp_e_id(e), imp_e_kind(e), imp_lang, imp_level,
                      imp_e_prov(e) %]);
        endif;
        for f in imp_e_forms(e) do
            imp_pr('form(%p, %p, %p).\n',
                   [% imp_e_id(e), hd(f), imp_atom(hd(tl(f))) %]);
        endfor;
        unless not(imp_e_gloss(e)) or imp_e_gloss(e) = '' then
            imp_pr('gloss(%p, en, %p).\n', [% imp_e_id(e), imp_atom(imp_e_gloss(e)) %]);
        endunless;
        for r in imp_e_reqs(e) do
            imp_pr('requires(%p, %p).\n', [% imp_e_id(e), r %]);
        endfor;
        for r in imp_e_ranks(e) do
            imp_pr('rank(%p, %p, %p).\n',
                   [% imp_e_id(e), hd(r), hd(tl(r)) %]);
            ;;; A rank entry may carry a third element, the raw count.
            ;;; Coverage is a share of running text and a rank cannot
            ;;; give one: `the` and the 50,000th word are one rank apart
            ;;; from their neighbours and four orders of magnitude apart
            ;;; in how much text they account for.
            unless tl(tl(r)) == [] then
                imp_pr('freq(%p, %p, %p).\n',
                       [% imp_e_id(e), hd(r), hd(tl(tl(r))) %]);
            endunless;
        endfor;
        imp_out('\n');
    endfor;
enddefine;

;;; ------------------------------------------------------------- reporting
;;; An unresolved pick is reported in full and the import still writes the
;;; picks that did resolve, because a curator fixing twenty keys wants to
;;; see all twenty, not the first one.  The exit status says whether
;;; anything was left over, so a build can still refuse to go on.
define imp_report(unresolved);
    lvars unresolved, u, c, n = 0;
    for u in unresolved do
        lvars p = hd(u), why = hd(tl(u));
        n fi_+ 1 -> n;
        if why == "not_found" then
            printf('UNRESOLVED %p: %p(%p) matches no entry\n',
                   [% p(1), p(5), p(6) %]);
        else
            printf('AMBIGUOUS %p: %p(%p) matches %p entries --\n',
                   [% p(1), p(5), p(6), length(hd(tl(tl(u)))) %]);
            for c in hd(tl(tl(u))) do
                printf('    jmdict(\'%p\')  %p  %p  %p\n',
                       [% c(1), imp_join(c(2), '/'), imp_join(c(3), '/'),
                          imp_join(imp_first(c(4), 3), ', ') %]);
            endfor;
            printf('    -- say which, with pick(%p, ..., jmdict(\'NNNNNNN\')).\n', [% p(1) %]);
        endif;
    endfor;
    unless n == 0 then
        printf('\n%p pick(s) unresolved.  Nothing was written for them.\n', [^n]);
    endunless;
enddefine;


;;; A pick whose id is already an item is refused.  An id is an identity,
;;; and two items sharing one would merge a student's beliefs about two
;;; different words -- silently, since the overlay is keyed by id alone.
define imp_collisions(es) -> bad;
    lvars es, e, bad = [];
    for e in es do
        ;;; An enrichment entry is SUPPOSED to name an existing item --
        ;;; that is the whole point of it -- so only an entry that
        ;;; declares one can collide.
        nextunless(imp_e_kind(e));
        if lp_ilang(imp_e_id(e)) then
            bad <> [[% imp_e_id(e), lp_ilevel(imp_e_id(e)) %]] -> bad
        endif;
    endfor;
enddefine;

;;; --------------------------------------------------------- verification
;;; Read back what was just written and check it arrived.  Not paranoia: a
;;; Prolog syntax error in a consulted file is non-fatal, so a badly
;;; quoted atom costs exactly one clause and says so only in a line of
;;; loading noise.  This compares what the emitter MEANT to write against
;;; what the graph actually holds afterwards, which catches that and any
;;; other emission bug by the same route.
;;; The prerequisite edges, as a property from item to its list.  index/0
;;; deliberately does not collect requires/2 (the tutor only ever needs
;;; ready/4's one-level check), so they are asked for once -- the same
;;; route dump.p takes.
define imp_edge_map() -> m;
    lvars t, m = newproperty([], 512, [], "perm"), a, b;
    for t in lp_ask("edges", 0) do
        prolog_full_deref(prolog_arg(1, t)) -> a;
        prolog_full_deref(prolog_arg(2, t)) -> b;
        m(a) <> [^b] -> m(a);
    endfor;
enddefine;

define imp_verify(es, out) -> bad;
    lvars es, out, e, f, r, bad = [], id, edges;
    lp_load_except(false);              ;;; everything, including `out`
    lp_index();
    imp_edge_map() -> edges;
    for e in es do
        imp_e_id(e) -> id;
        if imp_e_kind(e) and not(lp_ilang(id)) then
            bad <> [[^id 'item missing']] -> bad; nextloop
        endif;
        ;;; Compared AS STRINGS.  A Prolog quoted atom derefs to a Pop-11
        ;;; word, and a word is never = to a string with the same
        ;;; characters, so the first version of this check reported all
        ;;; 444 facts missing -- which at least proved it was looking.
        for f in imp_e_forms(e) do
            unless (lp_form_of(id, hd(f)) sys_>< '') = (hd(tl(f)) sys_>< '') then
                bad <> [[% id, 'form ' <> (hd(f) sys_>< '') <> ' missing or wrong' %]]
                    -> bad;
            endunless;
        endfor;
        if imp_e_gloss(e) and imp_e_gloss(e) /= ''
        and (lp_gloss_of(id, "en") sys_>< '') /= (imp_e_gloss(e) sys_>< '') then
            bad <> [[% id, 'gloss missing or wrong' %]] -> bad;
        endif;
        for r in imp_e_reqs(e) do
            unless member(r, edges(id)) then
                bad <> [[% id, 'requires ' <> (r sys_>< '') <> ' missing' %]] -> bad;
            endunless;
        endfor;
    endfor;
enddefine;

;;; ------------------------------------------------------------------ main
define imp_default_out() -> p;
    lvars p;
    'graph/' <> (imp_lang sys_>< '') <> '/generated/'
        <> (imp_level sys_>< '') <> '-'
        <> (if     imp_source == "kanjidic"  then 'kanji'
            elseif imp_source == "cmudict"   then 'sounds'
            elseif imp_source == "frequency" then 'frequency'
            else   'words' endif)
        <> '.pl' -> p;
enddefine;

define imp_main();
    lvars es = [], unresolved = [], picks = [], srcname, out, dev, bad, b;
    ;;; No back versions.  syscreate keeps pop_file_versions of a file by
    ;;; renaming the old one with a trailing `-` (REF * SYSIO), so every
    ;;; re-import left an n5-words.pl- beside its output -- a stale copy
    ;;; of a build product, which is the one kind of file that has no
    ;;; business being backed up, and which the *.pl ignore did not match.
    dlocal imp_dev, pop_file_versions = false;
    find_dir() -> langpop_dir;
    imp_args();

    unless imp_source then
        mishap(0, 'import: --source kanjidic or --source jmdict needed')
    endunless;
    unless imp_file and sys_file_exists(imp_file) then
        mishap(imp_file or 'none', 1,
               'import: --file needed (tools/fetch-upstream.sh downloads it)')
    endunless;

    ;;; The gap report inverts the import and leaves nothing behind: it
    ;;; needs the whole graph (every level -- a word taught at N4 is not
    ;;; a gap) and no --level, no pick file, no output path.
    if imp_gap_want then
        unless imp_source == "frequency" then
            mishap(imp_source, 1, 'import: --gap belongs to --source frequency')
        endunless;
        lp_load();
        lp_index();
        imp_gap_run(imp_file, imp_top);
        return;
    endif;

    ;;; The pick file is read BEFORE the graph, because it is what says
    ;;; which level is being imported, and that is what names the output
    ;;; file -- which in turn is the one file the graph must be loaded
    ;;; WITHOUT, so that re-running an import does not collide with its
    ;;; own previous output.  Compiling it first is safe: pick/5 appears
    ;;; nowhere in the graph, and prolog_compile only replaces the
    ;;; clauses of predicates the compiled text defines.
    if imp_source == "jmdict" then
        unless imp_picks then mishap(0, 'import: --source jmdict needs --picks F') endunless;
        imp_load_picks(if sys_file_exists(imp_picks) then imp_picks
                       else langpop_dir <> imp_picks endif) -> picks;
        unless imp_level or picks == [] then hd(picks)(3) -> imp_level endunless;
    endif;
    unless imp_level then mishap(0, 'import: --level needed') endunless;

    ;;; The graph as it stands: for the collision check, and for the kanji
    ;;; edges a word import draws against the characters already in it.
    imp_outpath or imp_default_out() -> out;
    ;;; Refuse to write a file the engine will not read.  GRAPH_GENERATED
    ;;; is hand listed, so a new level needs an entry there -- and
    ;;; without this check the symptom was imp_verify reporting every
    ;;; fact it had just written as LOST, which is true, alarming, and
    ;;; says nothing about the cause.
    unless imp_outpath or member(out, lp_generated_files()) then
        mishap(out, 1, 'import: the engine does not load that file -- add it '
                       <> 'to GRAPH_GENERATED in langpop.p, or pass --out')
    endunless;
    lp_load_except(out);
    lp_index();

    if imp_source == "kanjidic" then
        unless imp_jlpt then mishap(0, 'import: --source kanjidic needs --jlpt N') endunless;
        'KANJIDIC2' -> srcname;
        imp_kanjidic(imp_file, imp_jlpt) -> es;
    elseif imp_source == "jmdict" then
        'JMdict' -> srcname;
        imp_jmdict(imp_file, picks, imp_load_pick_reqs()) -> (es, unresolved);
    elseif imp_source == "frequency" then
        'FrequencyWords' -> srcname;
        lvars fwant = imp_en_forms();
        if fwant == [] then
            mishap(imp_level, 1, 'import: no items with a latin form at that '
                                 <> 'level (frequency enriches items the '
                                 <> 'graph already has)')
        endif;
        imp_frequency(imp_file, fwant) -> (es, unresolved);
    elseif imp_source == "cmudict" then
        'CMUdict' -> srcname;
        lvars want = imp_en_words();
        if want == [] then
            mishap(imp_level, 1, 'import: no items with a latin form at that level '
                                 <> '(cmudict enriches items the graph already has)')
        endif;
        imp_cmudict(imp_file, want) -> (es, unresolved);
        imp_unexercised(es);
    else
        mishap(imp_source, 1, 'import: unknown source '
                              <> '(kanjidic, jmdict, cmudict, frequency)')
    endif;

    printf('%p: %p entries from %p\n', [% imp_source, length(es), imp_upstream %]);
    imp_report(unresolved);

    imp_collisions(es) -> bad;
    unless bad == [] then
        for b in bad do
            printf('COLLISION %p is already an item at level %p\n', [% hd(b), hd(tl(b)) %]);
        endfor;
        mishap(length(bad), 1, 'import: pick ids already in the graph');
    endunless;

    if imp_check then
        printf('--check: nothing written (would have been %p)\n', [^out]);
        return;
    endif;

    ;;; The output directory is committed even though its contents are
    ;;; not -- it holds the .gitignore that keeps them out -- so a missing
    ;;; one means a checkout problem and not something to paper over.
    ;;; Poplog has no directory-creation primitive and this does not need
    ;;; to be the file that reaches for a shell to get one.
    unless sys_file_exists(langpop_dir <> 'graph/' <> (imp_lang sys_>< '')
                           <> '/generated') then
        mishap('graph/' <> (imp_lang sys_>< '') <> '/generated', 1,
               'import: output directory missing')
    endunless;

    discout(langpop_dir <> out) -> dev;
    dev -> imp_dev;
    imp_emit(es, srcname, out);
    dev(termin);
    printf('wrote %p\n', [% langpop_dir <> out %]);

    ;;; and read it back
    lvars wrong = imp_verify(es, out), x;
    unless wrong == [] then
        for x in wrong do printf('LOST %p: %p\n', [% hd(x), hd(tl(x)) %]) endfor;
        mishap(length(wrong), 1,
               'import: facts written but not in the graph (quoting? syntax?)');
    endunless;
    printf('verified %p entries back out of the graph\n', [% length(es) %]);
enddefine;


;;; ---------------------------------------------------------------- CMUdict
;;; The third import mode, and a different KIND of import.  kanjidic
;;; creates items from a rule and jmdict creates them from a pick list;
;;; this one creates nothing and ENRICHES items the graph already has,
;;; with the two things about an English word that no person should type a
;;; hundred times and no human judgment improves: how it is pronounced,
;;; and which of the pre-school sound contrasts that pronunciation makes
;;; the learner practise.
;;;
;;; That second one is the same move the word import makes for kanji -- 本
;;; is in 日本, so a student who cannot read 本 cannot read 日本 -- applied
;;; to sounds instead of characters.  'library' contains an R and an L, so
;;; it IS the /r/-/l/ exercise, and that is a fact about the word rather
;;; than an opinion about teaching.
;;;
;;; CMUdict is 2-clause BSD (not CC BY-SA, unlike JMdict and KANJIDIC2),
;;; so unlike those two its derived content could be committed.  It is
;;; kept a build product anyway: a reader of graph/en/generated/ should
;;; not have to check which upstream a file came from to know whether it
;;; is in the repository.

;;; ARPAbet to IPA, broad.  Two deliberate choices: R is r and not ɹ,
;;; matching the /r/ - /l/ the pre-school contrasts are already written
;;; with; and AH is ʌ when stressed but ə when not, because CMUdict uses
;;; one symbol for both and the unstressed one is the schwa that s_schwa
;;; is about.
lconstant ARPA_IPA = [
    AA 'ɑ'   AE 'æ'   AH 'ʌ'   AO 'ɔ'   AW 'aʊ'  AY 'aɪ'
    B  'b'   CH 'tʃ'  D  'd'   DH 'ð'   EH 'ɛ'   ER 'ɜr'
    EY 'eɪ'  F  'f'   G  'ɡ'   HH 'h'   IH 'ɪ'   IY 'i'
    JH 'dʒ'  K  'k'   L  'l'   M  'm'   N  'n'   NG 'ŋ'
    OW 'oʊ'  OY 'ɔɪ'  P  'p'   R  'r'   S  's'   SH 'ʃ'
    T  't'   TH 'θ'   UH 'ʊ'   UW 'u'   V  'v'   W  'w'
    Y  'j'   Z  'z'   ZH 'ʒ'
];

lconstant ARPA_VOWELS = [AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW];

;;; The contrasts imp_contrasts can decide from a pronunciation.  The
;;; three that are not here are not oversights: s_final ("ends in a
;;; consonant") is true of two words in three and an edge that common
;;; carries no information; s_stress needs the stress-shifting PAIR and
;;; one CMUdict entry cannot show it; s_rhythm is a property of a
;;; sentence.  Naming them here is what lets the report say "no rule
;;; derives this" instead of blaming the word list for it.
lconstant DERIVABLE = [s_r_l s_v_b s_f_h s_th_un s_th_v s_si_shi
                       s_cluster s_ae_uh s_schwa];

define imp_ipa_of(sym) -> s;
    lvars sym, l = ARPA_IPA, s = false;
    until l == [] do
        if hd(l) == sym then hd(tl(l)) -> s; return endif;
        tl(tl(l)) -> l;
    enduntil;
enddefine;

;;; A phoneme as CMUdict writes it is a symbol plus, for a vowel, a stress
;;; digit: AO1, ER0, T.  Split into (symbol, stress) with stress false for
;;; a consonant.
define imp_arpa(p) -> (sym, stress);
    lvars p, sym, stress = false, n = length(p), c;
    if n > 1 then
        subscrs(n, p) -> c;
        if c >= `0` and c <= `2` then
            c fi_- `0` -> stress;
            substring(1, n fi_- 1, p) -> p;
        endif;
    endif;
    consword(p) -> sym;
enddefine;

;;; The IPA for a whole pronunciation.  The stress mark goes immediately
;;; before the stressed VOWEL rather than at the start of its syllable,
;;; which is a simplification -- proper syllabification is a separate job
;;; and CMUdict does not carry syllable boundaries.  Said here because the
;;; output looks like a claim about syllables and is not one.
define imp_ipa(ps) -> s;
    lvars ps, p, sym, stress, s = '', nsyl = 0, ipa;
    for p in ps do
        imp_arpa(p) -> (sym, stress);
        if stress then nsyl fi_+ 1 -> nsyl endif;
    endfor;
    for p in ps do
        imp_arpa(p) -> (sym, stress);
        imp_ipa_of(sym) -> ipa;
        nextunless(ipa);
        ;;; a one-syllable word needs no stress mark: there is nothing to
        ;;; distinguish it from
        if nsyl > 1 then
            if     stress == 1 then s <> 'ˈ' -> s
            elseif stress == 2 then s <> 'ˌ' -> s
            endif;
        endif;
        if sym == "AH" and stress == 0 then s <> 'ə' -> s
        elseif sym == "ER" and stress == 0 then s <> 'ər' -> s
        else s <> ipa -> s
        endif;
    endfor;
enddefine;

define imp_is_vowel(sym); lvars sym; member(sym, ARPA_VOWELS) enddefine;

define imp_has(syms, x); lvars syms, x; member(x, syms) enddefine;

;;; The longest run of consonants anywhere in the word.
define imp_cons_run(syms) -> mx;
    lvars syms, sym, run = 0, mx = 0;
    for sym in syms do
        if imp_is_vowel(sym) then 0 -> run
        else run fi_+ 1 -> run; if run > mx then run -> mx endif
        endif;
    endfor;
enddefine;

;;; Which pre-school contrasts a pronunciation exercises.
;;;
;;; SELECTIVE ON PURPOSE, and this was measured before it was settled.  A
;;; rule for s_final -- "ends in a consonant", the contrast about not
;;; adding a vowel after it -- is true of 67 of these 100 words, and an
;;; edge that two items in three carry tells a reader nothing and a
;;; planner nothing either.  It is left out, and so are s_stress (which
;;; needs the stress-shifting PAIR, and one CMUdict entry cannot show it)
;;; and s_rhythm (a property of a sentence, not a word).  What is left
;;; fires on 2% to 14% of the list, which is what makes an edge worth
;;; having.
;;;
;;; The minimal-pair contrasts want BOTH phonemes present: a word with an
;;; R and no L is not the /r/-/l/ exercise, it is just a word with an R
;;; in it.  ER counts as carrying the R, because it is a rhotic vowel and
;;; `world` (W ER1 L D) is one of the hardest words on this list for a
;;; Japanese speaker -- leaving it out on a technicality would be the
;;; rule serving itself.
define imp_contrasts(ps) -> cs;
    lvars ps, p, sym, stress, syms = [], raw = [], cs = [], i, n;
    for p in ps do
        imp_arpa(p) -> (sym, stress);
        syms <> [^sym] -> syms;
        raw <> [% if sym == "AH" and stress == 0 then "AH0" else sym endif %] -> raw;
    endfor;
    length(syms) -> n;

    lvars rhotic = imp_has(syms, "R") or imp_has(syms, "ER");
    if rhotic and imp_has(syms, "L") then cs <> [s_r_l] -> cs endif;
    if imp_has(syms, "V") and imp_has(syms, "B") then cs <> [s_v_b] -> cs endif;
    if imp_has(syms, "F") and imp_has(syms, "HH") then cs <> [s_f_h] -> cs endif;
    if imp_has(syms, "TH") then cs <> [s_th_un] -> cs endif;
    if imp_has(syms, "DH") then cs <> [s_th_v] -> cs endif;
    ;;; "see and she": the /sh/ itself, or an S straight before an /i/,
    ;;; which is the half of the pair Japanese does not keep separate
    if imp_has(syms, "SH") then cs <> [s_si_shi] -> cs
    else
        for i from 1 to n fi_- 1 do
            if syms(i) == "S" and syms(i fi_+ 1) == "IY" then
                cs <> [s_si_shi] -> cs; quitloop
            endif;
        endfor;
    endif;
    if imp_cons_run(syms) >= 3 then cs <> [s_cluster] -> cs endif;
    if imp_has(syms, "AE") and imp_has(syms, "AH") then cs <> [s_ae_uh] -> cs endif;
    if imp_has(raw, "AH0") then cs <> [s_schwa] -> cs endif;
enddefine;

;;; The English items already in the graph, at the level being enriched,
;;; as [id word] pairs.  This is the mode's whole input: it adds nothing
;;; the graph does not already name.
define imp_en_words() -> ws;
    lvars i, w, ws = [];
    for i in lp_items do
        nextunless(lp_ilang(i) == imp_lang and lp_ilevel(i) == imp_level);
        lp_form_of(i, "latin") -> w;
        nextunless(w);
        ws <> [[% i, w %]] -> ws;
    endfor;
enddefine;

;;; EVERY latin form, and not the first one.
;;;
;;; imp_en_words takes lp_form_of, which is one form per item, and that
;;; is right for cmudict -- a pronunciation belongs to a spelling, so
;;; `be` and `was` want separate entries or neither is correct.
;;;
;;; It is wrong for frequency, and the English function-word tranche is
;;; where it shows: is/are/was/be is ONE verb and four tokens.  An item
;;; `e_be` carrying all four forms would have collected the count of
;;; `be` alone and silently dropped the 2.21% of the corpus the other
;;; three carry -- a coverage figure quietly short by a third of what
;;; the tranche was worth.  See docs/projects/langpop-function-words.md.
;;;
;;; So frequency reads every form and imp_frequency sums them, because
;;; coverage is a count of TOKENS on the page and all four tokens are on
;;; the page.  The item count is unaffected: one item, one vocabulary
;;; entry, four spellings of it.
define imp_en_forms() -> ws;
    lvars i, pr, ws = [];
    for i in lp_items do
        nextunless(lp_ilang(i) == imp_lang and lp_ilevel(i) == imp_level);
        for pr in lp_forms(i) do
            if hd(pr) == "latin" then ws <> [[% i, hd(tl(pr)) %]] -> ws endif;
        endfor;
    endfor;
enddefine;

;;; Which pre-school contrasts nothing at this level exercises.  This is
;;; curation feedback and not an error: it says what the word list is
;;; missing, which is the question a curator filling a level actually has.
;;; s_v_b and s_f_h came back empty on the first hundred words, so the
;;; list has no word pairing a /v/ with a /b/ or an /f/ with an /h/ --
;;; true, and worth being told.
define imp_unexercised(es);
    lvars es, e, c, i, used = [], miss = [], nodrv = [];
    for e in es do
        for c in imp_e_reqs(e) do
            unless member(c, used) then used <> [^c] -> used endunless;
        endfor;
    endfor;
    for i in lp_items do
        nextunless(lp_ilang(i) == imp_lang and lp_kind(i) == "sound");
        nextif(member(i, used));
        ;;; Two different answers, and telling them apart is the point.
        ;;; A contrast no RULE derives is not a gap in the word list and
        ;;; no amount of curation will fill it.
        if member(i, DERIVABLE) then miss <> [^i] -> miss
        else nodrv <> [^i] -> nodrv
        endif;
    endfor;
    printf('contrasts exercised at %p: %p of %p\n',
           [% imp_level, length(used),
              length(used) + length(miss) + length(nodrv) %]);
    unless miss == [] then
        printf('  no word at %p exercises these -- a gap in the word list:\n',
               [^imp_level]);
        for c in miss do
            printf('    %p  %p\n', [% c, lp_gloss_of(c, "en") or '' %]);
        endfor;
    endunless;
    unless nodrv == [] then
        printf('  not derivable from a pronunciation, so never emitted:\n');
        for c in nodrv do
            printf('    %p  %p\n', [% c, lp_gloss_of(c, "en") or '' %]);
        endfor;
    endunless;
enddefine;

;;; Line by line, buffered, and NOT lp_read_file.  That procedure pushes
;;; every character of the file onto the Pop-11 stack and calls consstring
;;; at the end, which is fine for a 25KB graph file and dies on CMUdict:
;;; 3.6 million stack entries is popmemlim.  A line is short, so the
;;; per-line consstring costs nothing.
define imp_lines(path, proc);
    lvars path, proc, c, n;
    dlocal xml_dev, xml_buf, xml_n = 0, xml_i = 0, xml_eof = false,
           xml_put = false, xml_line = 1, xml_what = path;
    sysopen(path, 0, true) -> xml_dev;
    unless xml_dev then mishap(path, 1, 'import: cannot read source file') endunless;
    inits(XML_BUF) -> xml_buf;
    repeat
        0 -> n;
        repeat
            xml_get() -> c;
            quitif(c == termin or c == `\n`);
            c; n fi_+ 1 -> n;
        endrepeat;
        if n fi_> 0 or c /== termin then proc(consstring(n)) endif;
        quitif(c == termin);
    endrepeat;
    sysclose(xml_dev);
enddefine;

;;; ------------------------------------------------------- frequency
;;; How much of running text a word accounts for.
;;;
;;; This is what coverage/2 needs and rank/3 cannot give: `the` and the
;;; fifty-thousandth word are one rank apart from their neighbours and
;;; four orders of magnitude apart in how much text they cover.  So the
;;; count comes across with the rank, and the corpus total comes across
;;; once, and the engine divides.
;;;
;;; Enrichment, like cmudict: it declares no item, it says something
;;; about items the graph already holds.  A word not in the list is
;;; reported unresolved rather than given a zero -- absent from the top
;;; fifty thousand is a fact about the corpus and not a frequency of
;;; nought.
define imp_frequency(path, want) -> (es, unresolved);
    lvars path, want, es = [], unresolved = [], pair, id, w, word,
          wanted = newproperty([], 512, false, "perm"),
          count  = newproperty([], 512, false, "perm"),
          place  = newproperty([], 512, false, "perm"),
          nlines = 0, total = 0;

    ;;; Keyed by WORD and not by string: a property compares keys with ==
    ;;; and two equal strings are two keys, which cost this project four
    ;;; hours once already.
    for pair in want do
        true -> wanted(consword(uppertolower(hd(tl(pair)) sys_>< '')));
    endfor;

    imp_lines(path, procedure(line);
        lvars line, k, word, n;
        imp_trim(line) -> line;
        returnif(line = '');
        locchar(`\s`, 1, line) -> k;
        returnunless(k);
        strnumber(allbutfirst(k, line)) -> n;
        returnunless(isinteger(n));
        nlines fi_+ 1 -> nlines;
        ;;; EVERY line counts toward the total, not only the wanted ones:
        ;;; the denominator is the corpus, and a coverage figure computed
        ;;; against the words we happen to teach would be a number that
        ;;; only ever goes up.
        total fi_+ n -> total;
        substring(1, k fi_- 1, line) -> word;
        consword(word) -> word;
        returnunless(wanted(word));
        returnif(count(word));              ;;; the first, which is the highest
        n -> count(word);
        nlines -> place(word);
    endprocedure);

    ;;; Sum across the forms of one item, and take the BEST rank of them,
    ;;; because a rank is a position in the list and the highest-placed
    ;;; form is where the item first appears.  One entry per item, so
    ;;; lp_freqs -- a property, last write wins -- cannot end up holding
    ;;; whichever form happened to come last.
    lvars sum = newproperty([], 512, false, "perm"),
          best = newproperty([], 512, false, "perm"),
          ids  = [];
    for pair in want do
        hd(pair) -> id; hd(tl(pair)) -> w;
        consword(uppertolower(w sys_>< '')) -> word;
        unless member(id, ids) then ids <> [^id] -> ids endunless;
        nextunless(count(word));
        (sum(id) or 0) + count(word) -> sum(id);
        unless best(id) and best(id) <= place(word) then
            place(word) -> best(id);
        endunless;
    endfor;

    for id in ids do
        unless sum(id) then
            ;;; Not one of its forms is in the list.  Absent from the top
            ;;; fifty thousand is a fact about the corpus, not a
            ;;; frequency of nought -- see the header.
            unresolved <> [[^id not_in_list]] -> unresolved;
            nextloop;
        endunless;
        es <> [% imp_entry_ranked(id, false, false, [], false, [],
                                  [[% imp_scale(), best(id), sum(id) %]])
               %] -> es;
    endfor;

    [% 'corpus(' <> (imp_scale() sys_>< '') <> ', '
       <> (nlines sys_>< '') <> ', ' <> (total sys_>< '') <> ').' %]
        -> imp_extra;
    'FrequencyWords (' <> (nlines sys_>< '') <> ' entries, '
        <> (total sys_>< '') <> ' tokens)' -> imp_upstream;
enddefine;

;;; The scale's name carries the corpus, because the corpus is the whole
;;; of what the number means.  Coverage of subtitle dialogue is not
;;; coverage of a newspaper, and a scale called `frequency` would hide
;;; that.
define imp_scale() -> s;
    lvars s = consword('opensubtitles_' <> (imp_lang sys_>< ''));
enddefine;

;;; ------------------------------------------------------- the gap report
;;; The inverse of imp_frequency: instead of enriching the words the
;;; graph holds, say which words it does NOT hold, ranked by how much of
;;; running text each one accounts for.  "The graph is short 1,800 words"
;;; is true and useless; "here are the forty words that buy the most
;;; coverage per item added" is a queue a curator can work.
;;;
;;; A REPORT AND NOT AN IMPORT, deliberately.  Adding a word is curation
;;; -- an identity, a level, a gloss, and (for Japanese) the kanji it
;;; rests on -- and the one time this project tried to derive those
;;; mechanically it got water -> 水分 (see graph/en/a1.pl's header).  So
;;; nothing here mints an id and nothing here writes a file the engine
;;; reads: the output is for a person.

;;; Every form of every item in the language, at EVERY level.  The gap is
;;; against the whole graph: a word taught two rungs up is not missing,
;;; it is just not next.
;;; WORDS ONLY, because the criteria this report feeds -- vocabulary/2,
;;; coverage/2 -- count words.  The graph also teaches あ as a grapheme,
;;; and letting hi_a answer for the interjection あ would inflate the
;;; held figure with items that are not vocabulary at all.
;;; Where the last character of a UTF-8 string begins.
;;;
;;; A continuation byte is 10xxxxxx, so 0x80..0xBF, so `div 64 == 2`.
;;; Walking back from the end over those lands on the lead byte.  Written
;;; with div rather than a mask because the arithmetic is obvious and the
;;; strings here are short.
define imp_utf8_last(s) -> k;
    lvars s, k = length(s);
    while k > 1 and (s(k) div 64) == 2 do k - 1 -> k endwhile;
enddefine;

;;; The STEM of a Japanese dictionary form, or false.
;;;
;;; This is not a nicety.  The Japanese frequency list is tokenised so
;;; that a verb arrives without its ending: 話す appears as 話, 分かる as
;;; 分か, 知る as 知.  The graph holds the dictionary form, so NOTHING
;;; matched, and --gap reported the stem of every verb the graph already
;;; teaches as a gap -- 5.16% of the corpus, against the 3.90% it
;;; credited.  More than half of what the graph covers in Japanese was
;;; invisible, and the top of the queue was words a curator would pick
;;; and the importer would then refuse as already taken.
;;;
;;; The rule: strip the final character when the form ends in kana AND
;;; contains something that is not kana.  Japanese inflects on the last
;;; mora of the dictionary form -- godan, ichidan and i-adjectives alike
;;; -- so the form minus that mora IS the token the corpus holds.
;;;
;;; THE SECOND CONDITION IS LOAD-BEARING.  Without it はなす would yield
;;; はな, which is 花 and 鼻 -- a real and different word -- so a
;;; kana-only form would start answering for its own truncations.  A stem
;;; is only recognisable as one when a kanji anchors it.
;;;
;;; Surface morphology, like imp_gap_infl, and it collides the same way:
;;; 行 is the stem of both 行く and 行う.  For a HELD figure that is
;;; harmless -- the student knows a word whose token this is -- and the
;;; first pick wins, which is the bargain imp_graph_words already makes
;;; for forms.
;;;
;;; Used by the gap report.  A Japanese coverage criterion would want the
;;; same rule in imp_frequency's `want` list; there is no ja frequency
;;; import yet, and when there is, this is the procedure it needs.
define imp_ja_stem(t) -> stem;
    lvars t, s = (t sys_>< ''), k, c, nonkana = false, stem = false;
    returnunless(imp_lang == "ja");
    returnunless(length(s) > 3);            ;;; one character has no stem
    utf8_appcodes(s, procedure(c);
        lvars c;
        unless (c >= 16:3040 and c <= 16:30FF) then true -> nonkana endunless;
    endprocedure);
    returnunless(nonkana);
    imp_utf8_last(s) -> k;
    returnunless(length(s) - k == 2);       ;;; kana is three bytes
    ((s(k) - 16:E0) * 4096) + ((s(k + 1) - 16:80) * 64)
        + (s(k + 2) - 16:80) -> c;
    returnunless(c >= 16:3040 and c <= 16:30FF);
    consword(substring(1, k - 1, s)) -> stem;
enddefine;

define imp_graph_words() -> gw;
    lvars gw = newproperty([], 2048, false, "perm"), i, p, t, st;
    for i in lp_items do
        nextunless(lp_ilang(i) == imp_lang and lp_kind(i) == "word");
        for p in lp_forms(i) do
            hd(tl(p)) -> t;
            nextunless(isstring(t) or isword(t));
            consword(if imp_lang == "en" then uppertolower(t sys_>< '')
                     else t sys_>< '' endif) -> t;
            unless gw(t) then i -> gw(t) endunless;
            ;;; and its stem, because that is what the corpus holds
            imp_ja_stem(t) -> st;
            if st and not(gw(st)) then i -> gw(st) endif;
        endfor;
    endfor;
enddefine;

;;; Is this token even a candidate word?  The lists are raw tokeniser
;;; output: the Japanese one opens with 、 and 。, the English one has
;;; digit runs.  Punctuation is counted in the denominator -- it is the
;;; corpus -- but it is not a gap, because it is not a word.
define imp_gap_wordish(word) -> yes;
    lvars word, yes = false, c;
    if imp_lang == "ja" then
        utf8_appcodes(word sys_>< '', procedure(c);
            lvars c;
            if (c >= 16:3040 and c <= 16:30FF)          ;;; kana + ー
            or (c >= 16:3400 and c <= 16:9FFF) then     ;;; ideographs
                true -> yes;
            endif;
        endprocedure);
    else
        for c from 1 to length(word) do
            if (word(c) >= `a` and word(c) <= `z`)
            or (word(c) >= `A` and word(c) <= `Z`) then
                true -> yes; return;
            endif;
        endfor;
    endif;
enddefine;

;;; A token that is half of a word, and so can never be curated.
;;;
;;; OpenSubtitles is tokenised, and the tokeniser splits contractions.
;;; So `don't` arrives as `don` + `'t`, and the English list's top fifty
;;; contains six fragments carrying 5.43% of the corpus between them.
;;; They sat at the top of every gap report, above the real queue,
;;; permanently: there is nothing to teach, so nothing can ever move
;;; them, so they are noise with a high rank.
;;;
;;; CLOSED LISTS, both halves, and the first attempt at this was wrong
;;; in a way worth recording.  The rule was "a leading apostrophe", on
;;; the reasoning that no English word starts with one.  It found 315
;;; tokens and 6.47% of the corpus, and the list it printed was:
;;;
;;;     'brien  'neill  'malley  'connor     -- Irish names, split
;;;     'cause  'em  'bout  'til  'scuse     -- clipped words, which are
;;;                                             real spoken English
;;;     'etat  'amour  'est-ce               -- French
;;;     'ight  'ciock  'aii                  -- OCR damage
;;;
;;; None of those is half of a contraction.  `'em` and `'cause` are
;;; words a curator might well want, at a rank a curator should see, and
;;; hiding them under "nothing to teach" would have been the report
;;; deciding a curation question by itself -- the one thing --gap exists
;;; not to do.  A structural rule looked cheaper than a list and was
;;; simply a different, wronger claim.
;;;
;;; So: enumerate.  Seven tails and sixteen stems, closed, and anything
;;; else with an apostrophe stays in the queue where a person sees it.
;;;
;;; The stems are a judgement and the report says so.  `don` and `haven`
;;; are real English words; their rank in film dialogue is not about
;;; dons or havens.  That is a claim about THIS corpus, which is why the
;;; list is short enough to read and the note is printed under it.
;;;
;;; consword and not a word literal: `'s` in Pop-11 source opens a
;;; string, so the list is built at compile time from strings.
lconstant SHARD_TAILS = [% consword('\'s'), consword('\'t'),
                            consword('\'m'), consword('\'re'),
                            consword('\'ll'), consword('\'ve'),
                            consword('\'d') %],
          SHARD_STEMS = [doesn didn isn wasn aren weren couldn wouldn
                         shouldn hasn hadn haven mustn needn ain don];

define imp_gap_shard(word) -> yes;
    lvars word, w, yes = false;
    returnunless(imp_lang == "en");
    consword(uppertolower(word)) -> w;
    if member(w, SHARD_TAILS) or member(w, SHARD_STEMS) then
        true -> yes
    endif;
enddefine;

;;; One pass.  Same reading discipline as imp_frequency: every line
;;; counts toward the total, because the denominator is the corpus.
;;; The missing list keeps arrival order, which IS frequency order --
;;; the upstream file is sorted, and imp_frequency already relies on it
;;; ("the first, which is the highest").
;;;
;;; Shards are counted apart and reported under the table.  They stay in
;;; `total`, because the denominator is the corpus whatever the corpus
;;; happens to contain -- dropping them would raise every coverage
;;; figure by five points for free, which is the one thing a coverage
;;; denominator must never do.
define imp_gap_scan(path, topn)
        -> (nlines, total, held, nheld, missing, shard, shards);
    lvars path, topn, nlines = 0, total = 0, held = 0, nheld = 0,
          nmiss = 0, missing = [], shard = 0, shards = [],
          gw = imp_graph_words();
    imp_lines(path, procedure(line);
        lvars line, k, n, word, w;
        imp_trim(line) -> line;
        returnif(line = '');
        locchar(`\s`, 1, line) -> k;
        returnunless(k);
        strnumber(allbutfirst(k, line)) -> n;
        returnunless(isinteger(n));
        nlines + 1 -> nlines;
        total + n -> total;
        substring(1, k - 1, line) -> word;
        consword(if imp_lang == "en" then uppertolower(word)
                 else word endif) -> w;
        if gw(w) then
            held + n -> held; nheld + 1 -> nheld;
        elseif imp_gap_shard(word) then
            shard + n -> shard;
            shards <> [{% nlines, word, n %}] -> shards;
        elseif nmiss < topn and imp_gap_wordish(word) then
            missing <> [{% nlines, word, n %}] -> missing;
            nmiss + 1 -> nmiss;
        endif;
    endprocedure);
enddefine;

;;; Basis points, printed as a percentage.  Integer arithmetic throughout
;;; because the counts are large and exact and a float would print as
;;; 0.414159... in a column meant to be read.
define imp_pct(n, total) -> s;
    lvars n, total, bp, s;
    if total == 0 then '-' -> s; return endif;
    ((n * 10000) + (total div 2)) div total -> bp;
    ((bp div 100) sys_>< '.')
        <> (if bp mod 100 < 10 then '0' else '' endif)
        <> ((bp mod 100) sys_>< '%') -> s;
enddefine;

;;; A GUESS, and labelled as one in the report.  OpenSubtitles is raw
;;; tokens, so `going` appears as itself; a curator deciding whether
;;; `going` is a gap wants to know the graph already teaches `go`.
;;; Surface morphology only -- strip a suffix, try the base, try the
;;; base plus e (making -> make), try undoubling (running -> run) -- and
;;; anything cleverer than that belongs to a lemmatiser, not here.
lconstant GAP_SUFFIXES = ['\'s' '\'re' '\'ll' '\'ve' 'n\'t' 'ing' 'ed' 'es' 's'];

define imp_gap_infl(word, gw) -> id;
    lvars word, gw, id = false, suf, base, w, bl;
    uppertolower(word sys_>< '') -> w;
    for suf in GAP_SUFFIXES do
        nextunless(length(w) > length(suf) + 1);
        nextunless(substring(length(w) - length(suf) + 1, length(suf), w) = suf);
        substring(1, length(w) - length(suf), w) -> base;
        if gw(consword(base)) then gw(consword(base)) -> id; return endif;
        if (suf = 'ing' or suf = 'ed' or suf = 'es')
        and gw(consword(base <> 'e')) then
            gw(consword(base <> 'e')) -> id; return;
        endif;
        length(base) -> bl;
        if (suf = 'ing' or suf = 'ed') and bl >= 2
        and base(bl) == base(bl - 1)
        and gw(consword(substring(1, bl - 1, base))) then
            gw(consword(substring(1, bl - 1, base))) -> id; return;
        endif;
    endfor;
enddefine;

;;; What a Japanese word costs beyond itself: the kanji it is written
;;; with.  A word whose kanji are all in the graph is ready to pick; a
;;; word that needs characters the graph has not imported is a bigger
;;; purchase, and the curator should see the price on the ticket.
define imp_gap_kanji(word) -> note;
    lvars word, note = false, have = 0, lack = 0;
    utf8_appcodes(word sys_>< '', procedure(code);
        lvars code;
        returnunless(code >= 16:3400 and code <= 16:9FFF);
        if lp_ilang(consword('k_' <> imp_hex(code))) then have + 1 -> have
        else lack + 1 -> lack
        endif;
    endprocedure);
    if lack > 0 then
        'needs ' <> (lack sys_>< ' kanji not in the graph') -> note
    elseif have > 0 then
        'kanji all in the graph' -> note
    endif;
enddefine;

define imp_gap_run(path, topn);
    lvars nlines, total, held, nheld, missing, m, cum, gw, id, note,
          shard, shards;
    imp_gap_scan(path, topn)
        -> (nlines, total, held, nheld, missing, shard, shards);
    printf('gap: %p -- %p entries, %p tokens\n',
           [% imp_scale(), nlines, total %]);
    if total == 0 then
        printf('gap: nothing legible in %p\n', [^path]);
        return;
    endif;
    printf('gap: the graph answers %p of the list\'s words, and they carry\n',
           [^nheld]);
    printf('gap: %p of the corpus\n', [% imp_pct(held, total) %]);
    printf('\nmissing, ranked by what each word buys:\n\n');
    printf('   rank  share   if-added  word\n');
    held -> cum;
    imp_graph_words() -> gw;
    for m in missing do
        cum + m(3) -> cum;
        false -> note;
        if imp_lang == "en" then
            ;;; No shard branch here: imp_gap_scan takes them out before
            ;;; the queue, so a row that reaches this point is a word.
            imp_gap_infl(m(2), gw) -> id;
            if id then 'may be a form of ' <> (id sys_>< '') -> note endif;
        elseif imp_lang == "ja" then
            imp_gap_kanji(m(2)) -> note;
        endif;
        printf('  %p\t%p\t%p\t%p%p\n',
               [% m(1), imp_pct(m(3), total), imp_pct(cum, total), m(2),
                  if note then '    (' <> note <> ')' else '' endif %]);
    endfor;
    unless shards == [] then
        printf('\nnot in the queue, because there is nothing to teach:\n');
        printf('  %p tokeniser shards, %p of the corpus --',
               [% length(shards), imp_pct(shard, total) %]);
        for m in shards do printf(' %p', [% m(2) %]) endfor;
        printf('\n  the tokeniser split a contraction and these are the\n');
        printf('  halves.  Counted in the denominator, never curatable.\n');
        printf('  A clipped word (\'em, \'cause) is NOT one of these and\n');
        printf('  stays in the queue -- that is a curation question.\n');
    endunless;
    printf('\nwhat adding these moves: vocabulary(N, read)%p\n',
           [% if imp_lang == "en" then ' and coverage(reading, _) together'
              else '' endif %]);
    if imp_lang == "ja" then
        printf('the tokeniser splits verbs from their endings, so 言 here is\n');
        printf('the stem of 言う -- read a bare stem as the verb it starts.\n');
    endif;
    printf('NOTE ON FIT: OpenSubtitles is DIALOGUE -- spoken, informal.  Its\n');
    printf('ranks suit coverage(listening, _) and are a proxy for reading.\n');
    printf('a token is not a word: names, contractions and inflections\n');
    printf('appear as themselves, which is why this is a queue for a\n');
    printf('curator and not an import.  Nothing was written.\n');
enddefine;

define imp_cmudict(path, want) -> (es, unresolved);
    lvars path, want, es = [], unresolved = [], src, i, c, cs,
          wanted = newproperty([], 512, false, "perm"),
          pron   = newproperty([], 512, false, "perm"),
          pair, id, w, word, line, nlines = 0;

    ;;; The wanted words, keyed by word because a property compares keys
    ;;; with == and two equal strings are two keys.  CMUdict is lowercase
    ;;; throughout, so the lookup key is too.
    for pair in want do
        true -> wanted(consword(uppertolower(hd(tl(pair)) sys_>< '')));
    endfor;

    imp_lines(path, procedure(line);
        lvars line, cut, k, word, ps;
        ;;; a trailing "# place, danish" is a comment, not a phoneme
        locchar(`#`, 1, line) -> cut;
        if cut then substring(1, cut fi_- 1, line) -> line endif;
        imp_trim(line) -> line;
        returnif(line = '');
        locchar(`\s`, 1, line) -> k;
        returnunless(k);
        nlines fi_+ 1 -> nlines;
        substring(1, k fi_- 1, line) -> word;
        ;;; "read(2)" is a second pronunciation of a word whose first is
        ;;; on its own line.  One form per item, so the variants are
        ;;; skipped -- skipped rather than preferred, because which
        ;;; variant a learner should be taught is a judgment CMUdict does
        ;;; not make and this file will not invent.
        returnif(locchar(`(`, 1, word));
        consword(word) -> word;
        returnunless(wanted(word));
        returnif(pron(word));               ;;; the first spelling wins
        imp_split(allbutfirst(k, line)) -> ps;
        returnif(ps == []);
        ps -> pron(word);
    endprocedure);

    for pair in want do
        hd(pair) -> id; hd(tl(pair)) -> w;
        consword(uppertolower(w sys_>< '')) -> word;
        unless pron(word) then
            unresolved <> [[^id not_found]] -> unresolved;
            nextloop;
        endunless;
        ;;; Only a contrast that IS an item in the graph becomes an edge,
        ;;; exactly as for kanji: the rule describes the word, the graph
        ;;; decides whether there is anything to point at.
        [% for c in imp_contrasts(pron(word)) do
               if lp_ilang(c) then c endif;
           endfor %] -> cs;
        ;;; kind and gloss are false: this mode DECLARES no item, it adds
        ;;; facts about one the graph already has, so imp_emit writes the
        ;;; form and the edges and no item/5 line at all.
        es <> [% imp_entry(id, false, false,
                           [[% "ipa", '/' <> imp_ipa(pron(word)) <> '/' %]],
                           false, cs) %] -> es;
    endfor;

    'CMUdict (' <> (nlines sys_>< '') <> ' lines read)' -> imp_upstream;
enddefine;

;;; Last line of the file, so that every reader above is compiled before
;;; the arguments are looked at.
unless isdefined("langpop_import_lib") then imp_main() endunless;
