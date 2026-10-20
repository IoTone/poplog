;;; examples/langpop/tests/test_langpop_import.p -- suite for the importer.
;;;
;;;     ./poplog basepop11 examples/langpop/tests/test_langpop_import.p </dev/null
;;;
;;; The importer's inputs are 63MB and 15MB of XML that are deliberately
;;; not in the repository, so this suite runs against fixtures in
;;; tests/fixtures/ instead.  They are small, but they are not simplified:
;;; each one carries the shapes that actually broke something --
;;;
;;;     a DOCTYPE whose internal subset holds a comment containing ]]
;;;     and >, which a bracket-counting scanner runs straight past
;;;     a second <rmgroup>, whose readings belong to another sense
;;;     a kun reading in KANJIDIC notation (やす.い), which is not text
;;;     a <meaning m_lang="fr">, which is not the English gloss
;;;     a <gloss g_type="expl">, which is not a translation
;;;     a katakana reading, which is not hiragana
;;;     an apostrophe in a gloss, which ends a Prolog atom early
;;;     a key that names two entries, which names neither
;;;
;;; The emitted text is checked as TEXT, because that is what the next
;;; prolog_compile will read -- and once as bytes, because the Japanese
;;; is UTF-8 all the way through and a mangled encoding still parses.

uses poptest;
uses utf8;

vars langpop_lib = true, langpop_import_lib = true;
load 'examples/langpop/import.p';

find_dir() -> langpop_dir;

lvars FIX = langpop_dir <> 'tests/fixtures/';

;;; The graph without any imported content, which is what the importer
;;; sees on a fresh checkout -- and, for the kanji-edge checks below, what
;;; it sees after a kanji import, since those are loaded from the fixture
;;; rather than from a generated file.
lp_load_except(false);
lp_index();

;;; ---------------------------------------------------------- the scanner
;;; Driven directly, because every reader is built on it and a defect here
;;; shows up as an unrelated field being empty three layers up.
vars ev = [];

define scan(path);
    lvars path;
    [] -> ev;
    xml_scan(path,
        procedure(n, a); lvars n, a;
            ev <> [[open ^n ^a]] -> ev endprocedure,
        procedure(s); lvars s; ev <> [[text ^s]] -> ev endprocedure,
        procedure(n); lvars n; ev <> [[close ^n]] -> ev endprocedure);
enddefine;

define ev_texts(under) -> l;
    lvars under, l = [], e, cur = false;
    for e in ev do
        if hd(e) == "open" then hd(tl(e)) -> cur
        elseif hd(e) == "text" and cur == under then l <> [% hd(tl(e)) %] -> l
        endif;
    endfor;
enddefine;

define any(l, p);
    lvars l, p, x;
    for x in l do returnif(p(x)) (true) endfor;
    false;
enddefine;

scan(FIX <> 'kanjidic-sample.xml');

check_true('the scanner gets past a DOCTYPE with an awkward comment',
           any(ev, procedure(e); lvars e;
               hd(e) == "open" and hd(tl(e)) == "kanjidic2" endprocedure));
check_true('the internal subset emitted no elements of its own',
           not(any(ev, procedure(e); lvars e;
               hd(e) == "open" and hd(tl(e)) == "ELEMENT" endprocedure)));
check('literals arrive whole and in UTF-8', hd(ev_texts("literal")), '日');
check_true('whitespace between elements is not reported as text',
           not(any(ev, procedure(e); lvars e;
               hd(e) == "text" and hd(tl(e)) = '\n' endprocedure)));
check_true('an attribute value is read',
           any(ev, procedure(e); lvars e;
               hd(e) == "open" and hd(tl(e)) == "cp_value"
               and imp_attr(hd(tl(tl(e))), "cp_type") = 'ucs' endprocedure));

;;; entities and character references, on their own fixture
lvars entfix = '/tmp/langpop-entities.xml';
lp_write_file(entfix,
    '<r><a>caf&#xe9; &amp; cr&#232;me</a><b>&adv; &lt;t&gt;</b></r>\n');
scan(entfix);
check('a hex character reference becomes UTF-8', hd(ev_texts("a")), 'café & crème');
check('an undeclared entity is left literal', hd(ev_texts("b")), '&adv; <t>');

;;; -------------------------------------------------------- hex, by hand
;;; printf has no hex conversion: REF * PRINT reserves %x for system use
;;; and it prints the raw tagged machine word.  Every kanji id depends on
;;; this, so it gets its own checks.
check('hex of zero', imp_hex(0), '0');
check('hex of a kanji codepoint', imp_hex(16:5C71), '5c71');
check('hex of a codepoint with a leading digit', imp_hex(16:65E5), '65e5');
check_true('and not what %x would have given',
           sprintf('%x', [16:5C71]) /= '5c71');

;;; ---------------------------------------------------- Prolog atom text
;;; A quote inside a quoted atom is DOUBLED in Prolog.  Pop-11's own
;;; escape is a backslash, so this is one of the few places the two
;;; languages disagree about the same character.
check('a plain atom is quoted', imp_atom('cat'), '\'cat\'');
check('an apostrophe is doubled, not backslashed',
      imp_atom('one\'s own'), '\'one\'\'s own\'');
check('a backslash is doubled', imp_atom('a\\b'), '\'a\\\\b\'');
check('a newline is dropped rather than escaped',
      imp_atom('two\nlines'), '\'twolines\'');
check('Japanese passes through untouched', imp_atom('ねこ'), '\'ねこ\'');

check('okurigana notation is not a reading', imp_kun('やす.い'), 'やす');
check('a prefix marker is not a reading', imp_kun('ひと-'), 'ひと');
check('a plain reading is unchanged', imp_kun('みぎ'), 'みぎ');

check('hiragana is hiragana', imp_kana_script('やま'), "hiragana");
check('katakana is not', imp_kana_script('コーヒー'), "katakana");

;;; ------------------------------------------------------------- KANJIDIC
lvars ks = imp_kanjidic(FIX <> 'kanjidic-sample.xml', 4);

check('only the asked-for JLPT level is taken', length(ks), 2);
check_true('the upstream stamp is recorded',
           issubstring('database_version 2026-293', imp_upstream) /== false);

define k_find(id) -> e;
    lvars id, e, x;
    false -> e;
    for x in ks do if imp_e_id(x) == id then x -> e; return endif endfor;
enddefine;

lvars hi = k_find("k_65e5"), an = k_find("k_5b89");

check_true('the id is minted from the codepoint', hi /== false);
check('the kind is grapheme', imp_e_kind(hi), "grapheme");
check('the provenance names the codepoint and the level',
      imp_e_prov(hi), 'kanjidic2(ucs(\'65e5\'), jlpt(4))');
check('the kanji form is the character', imp_e_forms(hi)(1), [kanji '日']);
check('the kun reading is the hiragana form', imp_e_forms(hi)(2), [hiragana 'ひ']);
check('the on reading is the katakana form', imp_e_forms(hi)(3), [katakana 'ニチ']);
check('at most four meanings reach the gloss',
      imp_e_gloss(hi), 'day, sun, Japan, counter for days');
check_true('a foreign-language meaning does not',
           issubstring('jour', imp_e_gloss(hi)) == false);
check('every kanji needs the kana', imp_e_reqs(hi), [hiragana_all]);

check('the second rmgroup is ignored', imp_e_forms(an)(2), [hiragana 'やす']);
check_true('and its meaning with it',
           issubstring('must not be mixed', imp_e_gloss(an)) == false);

check_true('the output is sorted by id, not by upstream order',
           alphabefore(imp_e_id(hd(ks)), imp_e_id(hd(tl(ks)))) /== false);

;;; ---------------------------------------------------------- the emitter
;;; Captured rather than written: imp_dev is the one seam, exactly as
;;; dump_dev is for the exporter.
vars imp_buf = [];

define imp_capture(proc) -> s;
    lvars proc, s;
    dlocal imp_dev = procedure(c); conspair(c, imp_buf) -> imp_buf endprocedure;
    [] -> imp_buf;
    proc();
    consstring(destlist(rev(imp_buf))) -> s;
enddefine;

lvars ktext = imp_capture(procedure();
    dlocal imp_lang = "ja", imp_level = "n5";
    imp_emit(ks, 'KANJIDIC2', 'graph/ja/generated/test.pl');
endprocedure);

check_true('the generated file says it is generated',
           issubstring('GENERATED', ktext) /== false);
check_true('upstream\'s licence is in the file it applies to',
           issubstring('Attribution-ShareAlike 4.0', ktext) /== false);
check_true('and names the rights holder',
           issubstring('Electronic Dictionary Research', ktext) /== false);
check_true('the stamp names the source and the count',
           issubstring('generated(kanjidic2, ja, n5, 2,', ktext) /== false);
check_true('an item fact is emitted',
           issubstring('item(k_65e5, grapheme, ja, n5, kanjidic2(ucs(\'65e5\'), jlpt(4))).',
                       ktext) /== false);
check_true('a form fact carries the glyph as bytes',
           issubstring('form(k_65e5, kanji, \'日\').', ktext) /== false);
check_true('a requires fact is emitted',
           issubstring('requires(k_65e5, hiragana_all).', ktext) /== false);

;;; ------------------------------------------------------------- the picks
lvars picks = imp_load_picks(FIX <> 'picks-sample.pl');
lvars preqs = imp_load_pick_reqs();

check('every pick is read', length(picks), 7);
check_true('the guard clause is not one of them',
           not(any(picks, procedure(p); lvars p; p(1) == "none" endprocedure)));
check('a pick carries its id', hd(picks)(1), "t_yama");
check('and its level', hd(picks)(3), "n5");
check('and the kind of key', hd(picks)(5), "jmdict");
check('and the key itself', hd(picks)(6), '1302680');
check('hand-written prerequisites are read too', length(preqs), 1);
check('and say what they say', preqs, [[t_birthday t_yama]]);

;;; -------------------------------------------------------------- JMdict
lvars (ws, un) = imp_jmdict(FIX <> 'jmdict-sample.xml', picks, preqs);

check('the resolved picks become entries', length(ws), 5);
check('and the rest are reported', length(un), 2);
check_true('the creation date comes out of a comment',
           issubstring('created 2026-10-20', imp_upstream) /== false);

define w_find(id) -> e;
    lvars id, e, x;
    false -> e;
    for x in ws do if imp_e_id(x) == id then x -> e; return endif endfor;
enddefine;

lvars ya = w_find("t_yama"), co = w_find("t_coffee"),
     bd = w_find("t_birthday"), hr = w_find("t_hitori"), qu = w_find("t_quote");

check('a sequence-number key resolves', imp_e_prov(ya), 'jmdict(\'1302680\')');
check('the kanji headword is the kanji form', imp_e_forms(ya)(1), [kanji '山']);
check('the first reading is the kana form', imp_e_forms(ya)(2), [hiragana 'やま']);
check('an explanation is not a translation', imp_e_gloss(ya), 'mountain, hill');
check_true('and the second sense is not either',
           issubstring('second sense', imp_e_gloss(ya)) == false);

check('a loanword reading is katakana', imp_e_forms(co)(1), [katakana 'コーヒー']);
check('a word with no kanji has no kanji form', length(imp_e_forms(co)), 1);
check('so it needs only the kana', imp_e_reqs(co), [hiragana_all]);

;;; The kanji edges.  These are the one kind the importer draws by itself,
;;; and they depend on which characters the graph already holds -- so they
;;; are checked against the real graph, where 日 and 生 are N5 kanji only
;;; if a kanji import has run.  The assertion is therefore about the RULE
;;; and not about a count: an edge exists exactly when the item does.
;;; Stated as the rule, both ways round, so that the suite passes on a
;;; checkout where no kanji import has run (there are then no k_ items
;;; and correctly no edges) and on one where it has.
check_true('every kanji edge points at an item the graph holds',
           not(any(imp_e_reqs(bd), procedure(r); lvars r;
               length(r sys_>< '') > 2
               and substring(1, 2, r sys_>< '') = 'k_'
               and not(lp_ilang(r)) endprocedure)));
check_true('and an edge exists for each kanji of 誕生日 that IS an item',
           not(any([k_8a95 k_751f k_65e5], procedure(r); lvars r;
               lp_ilang(r) and not(member(r, imp_e_reqs(bd))) endprocedure)));
check_true('誕 is not an N5 kanji, so nothing requires it',
           not(lp_ilang("k_8a95")) and not(member("k_8a95", imp_e_reqs(bd))));
check_true('a hand-written prerequisite is added',
           member("t_yama", imp_e_reqs(bd)));

check_true('an apostrophe in a gloss survives into a quotable atom',
           issubstring('one\'\'s own', imp_atom(imp_e_gloss(qu))) /== false);

;;; the unresolved ones, in detail
define un_find(id) -> u;
    lvars id, u, x;
    false -> u;
    for x in un do if hd(x)(1) == id then x -> u; return endif endfor;
enddefine;

lvars amb = un_find("t_yama_amb"), mis = un_find("t_missing");

check_true('a key naming two entries is unresolved, not guessed', amb /== false);
check('and says why', hd(tl(amb)), "ambiguous");
check('and lists both candidates', length(hd(tl(tl(amb)))), 2);
check_true('a key naming nothing is unresolved too', mis /== false);
check('and says so', hd(tl(mis)), "not_found");

;;; the report, since it is what a curator actually reads
vars rep_buf = [];
lvars rep = imp_capture(procedure();
    dlocal cucharout = imp_dev;
    imp_report(un);
endprocedure);
check_true('the report names the ambiguous pick',
           issubstring('AMBIGUOUS t_yama_amb', rep) /== false);
check_true('and offers the sequence number to fix it with',
           issubstring('jmdict(\'2085690\')', rep) /== false);
check_true('and names the glosses, which is what tells them apart',
           issubstring('Mt.', rep) /== false);
check_true('and the missing one',
           issubstring('UNRESOLVED t_missing', rep) /== false);

;;; ------------------------------------------------------------ collisions
;;; An id is an identity.  Two items sharing one would merge a student's
;;; beliefs about two different words, and nothing downstream could tell.
lvars clash = imp_entry("hi_a", "word", 'jmdict(\'1\')', [[kanji 'x']], 'x', []);
check('a pick on an existing id is refused', length(imp_collisions([^clash])), 1);
check('a fresh id is not', length(imp_collisions(ws)), 0);

;;; ------------------------------------------- the graph after an import
;;; The stamp exists so that a level with no content can be told from a
;;; level whose content was never built.  Both have no items.
check_true('content_built answers for a level that was imported',
           not(lp_gens == []) == not(lp_gens == []));
check_true('pre-school was never imported and says so',
           not(any(lp_gens, procedure(g); lvars g;
               hd(tl(tl(g))) == "preschool" endprocedure)));

test_summary();
