;;; examples/langpop/tests/test_langpop_dump.p -- suite for the exporter.
;;;
;;;     ./poplog basepop11 examples/langpop/tests/test_langpop_dump.p </dev/null
;;;
;;; An exporter is tested by reading its output back, not by reading its
;;; source: the JSON is parsed and the counts compared against the heap
;;; the tutor itself works from, so a relation dump.p forgets to walk
;;; shows up as a missing key rather than as a quieter page.
;;;
;;; The one thing a JSON round trip CANNOT check is the Japanese: the
;;; glyphs are UTF-8 bytes all the way through, so a mangled encoding
;;; parses perfectly and comes out wrong.  Those checks compare bytes.

uses poptest;
uses utf8;
uses json;

vars langpop_lib = true, langpop_dump_lib = true;
load 'examples/langpop/dump.p';

find_dir() -> langpop_dir;
lp_load();
lp_index();

;;; ------------------------------------------------ capture, not stdout
;;; dump_dev is the one seam: everything the exporter writes goes through
;;; it a character at a time, so a collector here is the whole harness.
vars dump_buf = [];

define dump_capture(proc) -> s;
    lvars proc, s;
    dlocal dump_dev = procedure(c); conspair(c, dump_buf) -> dump_buf endprocedure;
    [] -> dump_buf;
    proc();
    consstring(destlist(rev(dump_buf))) -> s;
enddefine;

;;; json_parse hands back a VECTOR for a JSON array and a property for an
;;; object, so everything read back here is indexed or exploded, never
;;; hd/tl'd.  dump_vl turns an array into a list so the rest reads normally.
define dump_vl(v) -> l;
    lvars v, l;
    [% explode(v) %] -> l;
enddefine;

;;; Pop-11 has applist but no `some`: one predicate over a list, here.
define dump_any(list, p) -> yes;
    lvars list, p, x;
    false -> yes;
    for x in list do if p(x) then true -> yes; return endif endfor;
enddefine;

;;; --------------------------------------------------------- the edges
lvars es = dump_edges();
check_true('prerequisite edges found', length(es) > 400);
check_true('katakana requires its hiragana',
           member([ka_a hi_a], es) /== false);
check_true('a starter word requires all of hiragana',
           member([w_neko hiragana_all], es) /== false);
check_true('a pattern requires its words',
           member([p_ni_ikimasu w_iku], es) /== false);
check_true('no item requires itself',
           not(dump_any(es, procedure(e); hd(e) == hd(tl(e)) endprocedure)));

;;; --------------------------------------------------------- the JSON
lvars js = dump_capture(dump_json), d = json_parse(js);

check('JSON scope is everything', d('scope'), 'all');
check('every item is exported', length(d('items')), length(lp_items));
check('every edge is exported', length(d('requires')), length(es));
check('confusables are exported once each', length(d('confusable')), 18);
check('the catalogue is exported', length(d('resources')), length(lp_rsrc));
check('both languages', length(d('languages')), 2);

;;; An item carries what a curator needs to judge it: what it is, where
;;; it sits, how it is written and where it came from.
define dump_find(items, id) -> it;
    lvars items, id, x;
    false -> it;
    for x in dump_vl(items) do
        if x('id') = id then x -> it; return endif;
    endfor;
enddefine;

lvars a = dump_find(d('items'), 'hi_a');
check_true('hi_a is in the dump', a /== false);
check('hi_a kind', a('kind'), 'grapheme');
check('hi_a lang', a('lang'), 'ja');
check('hi_a level', a('level'), 'preschool');
check('hi_a provenance survives as a term', a('provenance'), 'own(kana)');

;;; Bytes, not characters: json_parse would be just as happy with mojibake.
check('hi_a label is the glyph', a('label'), 'あ');
check('hi_a hiragana form', a('forms')('hiragana'), 'あ');
check('one character, three bytes', utf8_length(a('label')), 1);
check('hi_a gloss', a('glosses')('en'), 'a');

lvars w = dump_find(d('items'), 'w_gakkou');
check('a word with a geminate', w('forms')('hiragana'), 'がっこう');

;;; Exit criteria are Prolog TERMS -- the thing a naive exporter flattens
;;; to the functor and loses the argument of.
lvars ja = d('languages')(1), ex, pre = false;
check('first language is ja', ja('lang'), 'ja');
for ex in dump_vl(ja('exits')) do
    if ex('criterion') = 'recognise(hiragana)' then ex -> pre endif;
endfor;
check_true('a parameterised criterion survives', pre /== false);
check('with its threshold', pre('threshold'), 0.95);
check('and its latency budget', pre('ms'), 2000);

;;; ------------------------------------------------------- one language
;;; --lang narrows the scope, and an edge is kept only when BOTH ends
;;; survive it -- otherwise the viewer gets arrows into nothing.
define dump_relang(lang, proc) -> v;
    lvars lang, proc, v;
    dlocal dump_lang = lang;
    json_parse(dump_capture(proc)) -> v;
enddefine;

lvars en = dump_relang("en", dump_json);
check('en scope is recorded', en('scope'), 'en');
check_true('en is smaller', length(en('items')) < length(d('items')));
check_true('en has only English items',
           not(dump_any(dump_vl(en('items')),
                    procedure(x); x('lang') /= 'en' endprocedure)));
check_true('no edge dangles out of scope',
           not(dump_any(dump_vl(en('requires')),
                    procedure(e);
                        dump_find(en('items'), e(1)) == false
                        or dump_find(en('items'), e(2)) == false;
                    endprocedure)));

;;; The katakana traps are English items confused WITH Japanese kana, so
;;; narrowing to en must drop those pairs rather than half-emit them.
check_true('cross-language confusables are dropped with --lang',
           length(en('confusable')) < 18);

;;; ---------------------------------------------------------- graphviz
lvars dot = dump_capture(dump_dot);
check_true('dot opens a digraph', issubstring('digraph langpop {', dot) /== false);
check_true('dot closes', dot(length(dot)) == `\n` and dot(length(dot) - 1) == `}`);
check_true('one cluster per ladder rung',
           issubstring('cluster_ja_preschool', dot) /== false);
check_true('requires is a solid arrow',
           issubstring('"ka_a" -> "hi_a";', dot) /== false);
check_true('confusable is a dashed line, not an arrow',
           issubstring('[dir=none style=dashed', dot) /== false);
check_true('a glyph reaches the label', issubstring('あ', dot) /== false);
check_true('the font is named, because the labels are Japanese',
           issubstring('Noto Sans JP', dot) /== false);

;;; ------------------------------------------------------------ report
lvars txt = dump_capture(dump_text);
check_true('the report counts the items', issubstring('170 items', txt) /== false);
check_true('the report names a rung', issubstring('preschool', txt) /== false);
check_true('the report shows a criterion',
           issubstring('recognise(hiragana) >= 0.95', txt) /== false);

;;; ------------------------------------------------------- the viewer
;;; The standalone page is the one output a human opens directly, so what
;;; matters is that it is a WHOLE document with the data inside it: a page
;;; that still fetched graph.json would show an empty graph under file://,
;;; which is exactly where a curator opens it.
lvars html = dump_capture(dump_html);

check_true('the page is a document', issubstring('<!doctype html>', html) == 1);
check_true('it closes', issubstring('</html>', html) /== false);
check_true('with a charset, because the labels are Japanese',
           issubstring('<meta charset="utf-8">', html) /== false);
check_true('and a title', issubstring('<title>langpop graph</title>', html) /== false);
check_true('the fragment is not doubly wrapped',
           issubstring('<body', html) == false);

check_true('the marker is replaced, not left in',
           issubstring('langpop:embed', html) == false);
check_true('the data is inlined', issubstring('const EMBEDDED =', html) /== false);
check_true('a glyph survives into the page', issubstring('あ', html) /== false);
check_true('an item id survives into the page',
           issubstring('"id": "w_gakkou"', html) /== false);
check_true('the page is bigger than the data it carries',
           length(html) > length(js) + 10000);

;;; The embedded JSON must be the same dump the --json mode writes, not a
;;; second walk that can drift away from it.
lvars at = issubstring('const EMBEDDED =\n', html) + length('const EMBEDDED =\n');
check('the embedded dump is byte for byte the JSON dump',
      substring(at, length(js), html), js);

;;; ----------------------------------------------------------- arguments
check_mishaps('an unknown argument is refused',
              procedure;
                  dlocal poparglist = ['--pretty'];
                  dump_args();
              endprocedure);

test_summary();
