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
    imp_outpath = false, imp_check = false;

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
        else
            mishap(a, 1, 'import: unknown argument (--source S --file F '
                         <> '--level L --lang L --jlpt N --picks F --out F --check)')
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
;;; Prolog quoting is NOT Pop-11 quoting: a quote inside a quoted atom is
;;; doubled, there is no backslash escape to reach for, and a gloss like
;;; "one's own" would otherwise end the atom in the middle and leave the
;;; rest of the line as syntax.  Every piece of upstream text goes through
;;; imp_atom.
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
        if c == `'` then `'`; `'`; n fi_+ 2 -> n
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
;;;   {id  kind  prov  forms  gloss  reqs}
;;; with forms a list of [script text], prov the provenance term as the
;;; text that will be written, and reqs a list of prerequisite ids.
define imp_entry(id, kind, prov, forms, gloss, reqs) -> e;
    lvars id, kind, prov, forms, gloss, reqs, e;
    {% id, kind, prov, forms, gloss, reqs %} -> e;
enddefine;

define imp_e_id(e);     lvars e; e(1) enddefine;
define imp_e_kind(e);   lvars e; e(2) enddefine;
define imp_e_prov(e);   lvars e; e(3) enddefine;
define imp_e_forms(e);  lvars e; e(4) enddefine;
define imp_e_gloss(e);  lvars e; e(5) enddefine;
define imp_e_reqs(e);   lvars e; e(6) enddefine;

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
          rmg = 0, ons = [], kuns = [], means = [],
          hdr_file = false, hdr_db = false, hdr_date = false, seen = 0;

    xml_scan(path,
        procedure(n, a);
            lvars n, a;
            n -> nm; a -> at;
            if n == "character" then
                seen fi_+ 1 -> seen;
                false -> lit; false -> ucs; false -> jlpt;
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
            es <> [% imp_entry(consword('k_' <> uppertolower(ucs)),
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
                               [hiragana_all]) %] -> es;
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
 'KANJIDIC2'
   ['KANJIDIC2 is the property of the Electronic Dictionary Research and'
    'Development Group (EDRDG) and is used in conformance with the'
    'Group\'s licence: Creative Commons Attribution-ShareAlike 4.0.'
    'See https://www.edrdg.org/edrdg/licence.html .']
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
              if srcname = 'JMdict' then 'jmdict' else 'kanjidic2' endif,
              imp_lang, imp_level, length(es), imp_atom(dt_iso(sys_real_time())) %]);

    for e in es do
        imp_pr('item(%p, %p, %p, %p, %p).\n',
               [% imp_e_id(e), imp_e_kind(e), imp_lang, imp_level, imp_e_prov(e) %]);
        for f in imp_e_forms(e) do
            imp_pr('form(%p, %p, %p).\n',
                   [% imp_e_id(e), hd(f), imp_atom(hd(tl(f))) %]);
        endfor;
        unless imp_e_gloss(e) = '' then
            imp_pr('gloss(%p, en, %p).\n', [% imp_e_id(e), imp_atom(imp_e_gloss(e)) %]);
        endunless;
        for r in imp_e_reqs(e) do
            imp_pr('requires(%p, %p).\n', [% imp_e_id(e), r %]);
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
        if lp_ilang(imp_e_id(e)) then
            bad <> [[% imp_e_id(e), lp_ilevel(imp_e_id(e)) %]] -> bad
        endif;
    endfor;
enddefine;

;;; ------------------------------------------------------------------ main
define imp_default_out() -> p;
    lvars p;
    'graph/' <> (imp_lang sys_>< '') <> '/generated/'
        <> (imp_level sys_>< '') <> '-'
        <> (if imp_source == "kanjidic" then 'kanji' else 'words' endif)
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
    lp_load_except(out);
    lp_index();

    if imp_source == "kanjidic" then
        unless imp_jlpt then mishap(0, 'import: --source kanjidic needs --jlpt N') endunless;
        'KANJIDIC2' -> srcname;
        imp_kanjidic(imp_file, imp_jlpt) -> es;
    elseif imp_source == "jmdict" then
        'JMdict' -> srcname;
        imp_jmdict(imp_file, picks, imp_load_pick_reqs()) -> (es, unresolved);
    else
        mishap(imp_source, 1, 'import: unknown source (kanjidic, jmdict)')
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
enddefine;

unless isdefined("langpop_import_lib") then imp_main() endunless;
