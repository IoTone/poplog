/* examples/langpop/dump.p -- the graph, out of the heap and onto a page.

   langpop's graph is Prolog and its reader is a tutor, which means the
   only view of it is one item at a time, chosen for a student.  That is
   the right view for teaching and the wrong one for CURATING: a human
   adding a level cannot see the shape of what is already there, and a
   prerequisite edge that points somewhere silly looks exactly like one
   that does not.  check(graph) catches the seven things that are wrong
   by definition; everything else is a judgment, and judgment needs to
   see the thing.

       ./poplog basepop11 examples/langpop/dump.p                 # JSON
       ./poplog basepop11 examples/langpop/dump.p --dot           # graphviz
       ./poplog basepop11 examples/langpop/dump.p --text          # a report
       ./poplog basepop11 examples/langpop/dump.p --lang ja       # one language
       ./poplog basepop11 examples/langpop/dump.p --html --out g.html

   --html is the one to reach for: it inlines the JSON into viewer/page.html
   and writes ONE file that opens by double-clicking it.  That matters more
   than it sounds -- a browser refuses fetch() of a sibling file under
   file://, so a viewer that loaded its data separately would need a web
   server before it showed anybody anything.  The DOT feeds `dot -Tsvg`,
   for anyone who would rather have graphviz do the layout.

   This is a reader and nothing else.  It starts no session, registers no
   student and records no evidence, so the beliefs it reports are the
   empty ones a fresh profile has -- the shape of the graph, not anybody's
   progress.
*/

vars langpop_lib = true;                ;;; no session: just the procedures
load 'examples/langpop/langpop.p';
uses datetime;                          ;;; dt_iso, for the generated stamp

4000 -> poplinewidth; 4096 -> poplinemax;

;;; ------------------------------------------------------------ arguments
vars dump_format = 'json', dump_lang = false, dump_out = false;

define dump_args();
    lvars a, rest = poparglist;
    until null(rest) do
        hd(rest) -> a; tl(rest) -> rest;
        if     a = '--json' then 'json' -> dump_format
        elseif a = '--dot'  then 'dot'  -> dump_format
        elseif a = '--text' then 'text' -> dump_format
        elseif a = '--html' then 'html' -> dump_format
        elseif a = '--lang' and rest /== [] then
            consword(hd(rest)) -> dump_lang; tl(rest) -> rest
        elseif a = '--out' and rest /== [] then
            hd(rest) -> dump_out; tl(rest) -> rest
        else
            mishap(a, 1, 'dump: unknown argument (--json --dot --text --html --lang L --out F)')
        endif;
    enduntil;
enddefine;

;;; Which items are in scope.  No --lang means all of them, because the
;;; cross-language confusables (English katakana traps point at Japanese
;;; kana) are only visible when both languages are on the page.
define dump_in_scope(item);
    lvars item;
    not(dump_lang) or lp_ilang(item) == dump_lang;
enddefine;

;;; ----------------------------------------------------------- the edges
;;; requires/2 is the only relation index/0 does not collect, so ask for
;;; it here: a list of [item prerequisite] pairs, both ends as words.
define dump_edges() -> es;
    lvars t, es = [];
    for t in lp_ask("edges", 0) do
        es <> [[% prolog_full_deref(prolog_arg(1, t)),
                 prolog_full_deref(prolog_arg(2, t)) %]] -> es;
    endfor;
enddefine;

;;; -------------------------------------------------------- JSON by hand
;;; Not json_generate: this file's whole job is to be read by a human or
;;; a viewer, so key order and indentation are the output, and a property
;;; -backed object has neither (it is also what lost every `false` from
;;; the server's replies -- see server.p's lp_obj).  Prolog atoms arrive
;;; as WORDS, which json_generate rejects outright.
vars dump_dev = false;

define dump_out_str(s);
    lvars s, c;
    for c in_string s do dump_dev(c) endfor;
enddefine;

define dump_str(x);
    lvars x, c, s = if isword(x) or isstring(x) then x sys_>< '' else x sys_>< '' endif;
    dump_dev(`"`);
    for c in_string s do
        if     c == `"`  then dump_out_str('\\"')
        elseif c == `\\` then dump_out_str('\\\\')
        elseif c == `\n` then dump_out_str('\\n')
        elseif c == `\t` then dump_out_str('\\t')
        elseif c < 32    then dump_out_str(sprintf('\\u%04x', [^c]))
        else   dump_dev(c)                      ;;; UTF-8 passes straight through
        endif;
    endfor;
    dump_dev(`"`);
enddefine;

define dump_pr(fmt, args);
    lvars fmt, args;
    ;;; sprintf(STRING, ITEM_LIST) -- format first when the arguments come
    ;;; as a list (REF * PRINT); the other form takes them on the stack.
    dump_out_str(sprintf(fmt, args));
enddefine;

;;; one "script": "text" pair list, as a JSON object on one line
define dump_pairs(ps);
    lvars ps, p, first = true;
    dump_out_str('{');
    for p in ps do
        unless first then dump_out_str(', ') endunless; false -> first;
        dump_str(hd(p)); dump_out_str(': '); dump_str(hd(tl(p)));
    endfor;
    dump_out_str('}');
enddefine;

define dump_json();
    lvars i, e, p, l, x, r, first, es = dump_edges(), langs = [];

    ;;; the languages present, in ladder order
    for l in lp_ladders do
        unless member(hd(l), langs) then langs <> [% hd(l) %] -> langs endunless;
    endfor;

    dump_out_str('{\n  "generated": ');
    dump_str(dt_iso(sys_real_time()));
    dump_out_str(',\n  "scope": ');
    dump_str(if dump_lang then dump_lang else 'all' endif);

    ;;; --- ladders and their exit criteria
    dump_out_str(',\n  "languages": [');
    true -> first;
    for l in langs do
        nextunless(not(dump_lang) or l == dump_lang);
        unless first then dump_out_str(',') endunless; false -> first;
        dump_out_str('\n    {"lang": '); dump_str(l);
        dump_out_str(', "ladder": [');
        lvars f2 = true;
        for x in lp_ladders do
            nextunless(hd(x) == l);
            unless f2 then dump_out_str(', ') endunless; false -> f2;
            dump_pr('{"n": %p, "level": ', [% hd(tl(x)) %]);
            dump_str(hd(tl(tl(x)))); dump_out_str('}');
        endfor;
        dump_out_str('],\n     "exits": [');
        true -> f2;
        for x in lp_exits do
            nextunless(hd(x) == l);
            unless f2 then dump_out_str(',\n               ') endunless; false -> f2;
            dump_out_str('{"level": '); dump_str(hd(tl(x)));
            dump_out_str(', "criterion": '); dump_str(lp_term_str(hd(tl(tl(x)))));
            dump_pr(', "threshold": %p, "ms": %p}',
                    [% hd(tl(tl(tl(x)))), hd(tl(tl(tl(tl(x))))) %]);
        endfor;
        dump_out_str(']}');
    endfor;
    dump_out_str('\n  ]');

    ;;; --- the items
    dump_out_str(',\n  "items": [');
    true -> first;
    for i in lp_items do
        nextunless(dump_in_scope(i));
        unless first then dump_out_str(',') endunless; false -> first;
        dump_out_str('\n    {"id": '); dump_str(i);
        dump_out_str(', "kind": '); dump_str(lp_kind(i));
        dump_out_str(', "lang": '); dump_str(lp_ilang(i));
        dump_out_str(', "level": '); dump_str(lp_ilevel(i));
        dump_out_str(', "label": '); dump_str(lp_any_form(i));
        dump_out_str(', "forms": '); dump_pairs(lp_forms(i));
        dump_out_str(', "glosses": '); dump_pairs(lp_gl(i));
        dump_out_str(', "provenance": '); dump_str(lp_term_str(lp_isrc(i)));
        dump_out_str('}');
    endfor;
    dump_out_str('\n  ]');

    ;;; --- the prerequisite DAG
    dump_out_str(',\n  "requires": [');
    true -> first;
    for e in es do
        nextunless(dump_in_scope(hd(e)) and dump_in_scope(hd(tl(e))));
        unless first then dump_out_str(',') endunless; false -> first;
        dump_out_str('\n    ['); dump_str(hd(e));
        dump_out_str(', '); dump_str(hd(tl(e))); dump_out_str(']');
    endfor;
    dump_out_str('\n  ]');

    ;;; --- confusables.  lp_conf/3 files each pair BOTH ways round, so emit
    ;;; only the half where the first id sorts first, or every edge doubles.
    dump_out_str(',\n  "confusable": [');
    true -> first;
    for i in lp_items do
        nextunless(dump_in_scope(i));
        for p in lp_confs(i) do
            nextunless(dump_in_scope(hd(p)));
            nextunless(alphabefore(i, hd(p)));
            unless first then dump_out_str(',') endunless; false -> first;
            dump_out_str('\n    ['); dump_str(i); dump_out_str(', ');
            dump_str(hd(p)); dump_out_str(', ');
            dump_str(lp_term_str(hd(tl(p)))); dump_out_str(']');
        endfor;
    endfor;
    dump_out_str('\n  ]');

    ;;; --- the catalogue
    dump_out_str(',\n  "resources": [');
    true -> first;
    for r in lp_rsrc do
        nextunless(not(dump_lang) or hd(tl(r)) == dump_lang);
        unless first then dump_out_str(',') endunless; false -> first;
        dump_out_str('\n    {"id": '); dump_str(hd(r));
        dump_out_str(', "lang": '); dump_str(hd(tl(r)));
        dump_out_str(', "kind": '); dump_str(hd(tl(tl(r))));
        dump_out_str(', "target": '); dump_str(lp_term_str(hd(tl(tl(tl(r))))));
        dump_out_str(', "url": '); dump_str(hd(tl(tl(tl(tl(r))))));
        dump_out_str(', "checked": '); dump_str(hd(tl(tl(tl(tl(tl(r)))))));
        dump_out_str('}');
    endfor;
    dump_out_str('\n  ]\n}\n');
enddefine;

;;; ------------------------------------------------------------ graphviz
;;; One cluster per level so the layers are visible, solid arrows for
;;; requires/2 and dashed undirected ones for confusable/3 -- the two
;;; edge kinds mean opposite things (teach after / do not teach together)
;;; and a viewer that drew them alike would be worse than no viewer.
lconstant LEVEL_FILL = [[preschool  '#fde68a'] [n5 '#bbf7d0'] [n4 '#a7f3d0']
                        [a1 '#bfdbfe'] [a2 '#c7d2fe'] [b1 '#ddd6fe']
                        [b2 '#e9d5ff']];

define dump_fill(level) -> c;
    lvars level, p;
    '#e5e7eb' -> c;
    for p in LEVEL_FILL do
        if hd(p) == level then hd(tl(p)) -> c; return endif;
    endfor;
enddefine;

define dump_dot();
    lvars i, e, p, lv, lang, l, es = dump_edges(), seen = [];
    dump_out_str('digraph langpop {\n  rankdir=BT;\n  node [shape=box style=filled '
                 <> 'fontname="Noto Sans JP" fontsize=11];\n'
                 <> '  edge [color="#475569"];\n\n');
    for l in lp_ladders do
        hd(l) -> lang; hd(tl(tl(l))) -> lv;
        nextunless(not(dump_lang) or lang == dump_lang);
        dump_pr('  subgraph "cluster_%p_%p" {\n    label="%p %p";\n'
                <> '    style=rounded; color="#94a3b8";\n', [^lang ^lv ^lang ^lv]);
        for i in lp_items do
            nextunless(dump_in_scope(i));
            nextunless(lp_ilang(i) == lang and lp_ilevel(i) == lv);
            dump_pr('    "%p" [label="%p\\n%p" fillcolor="%p"];\n',
                    [% i, lp_any_form(i), i, dump_fill(lv) %]);
            conspair(i, seen) -> seen;
        endfor;
        dump_out_str('  }\n');
    endfor;
    ;;; anything whose level is not on a ladder still needs a node
    for i in lp_items do
        nextunless(dump_in_scope(i));
        nextunless(member(i, seen) == false);
        dump_pr('  "%p" [label="%p\\n%p" fillcolor="%p"];\n',
                [% i, lp_any_form(i), i, dump_fill(lp_ilevel(i)) %]);
    endfor;
    dump_out_str('\n');
    for e in es do
        nextunless(dump_in_scope(hd(e)) and dump_in_scope(hd(tl(e))));
        dump_pr('  "%p" -> "%p";\n', [% hd(e), hd(tl(e)) %]);
    endfor;
    dump_out_str('\n');
    for i in lp_items do
        nextunless(dump_in_scope(i));
        for p in lp_confs(i) do
            nextunless(dump_in_scope(hd(p)) and alphabefore(i, hd(p)));
            dump_pr('  "%p" -> "%p" [dir=none style=dashed color="#dc2626"];\n',
                    [% i, hd(p) %]);
        endfor;
    endfor;
    dump_out_str('}\n');
enddefine;

;;; --------------------------------------------------------------- report
define dump_text();
    lvars i, e, p, lang, lv, l, n, es = dump_edges(), langs = [];
    for l in lp_ladders do
        unless member(hd(l), langs) then langs <> [% hd(l) %] -> langs endunless;
    endfor;
    dump_pr('langpop graph -- %p items, %p prerequisite edges\n\n',
            [% listlength(lp_items), listlength(es) %]);
    for lang in langs do
        nextunless(not(dump_lang) or lang == dump_lang);
        dump_pr('%p\n', [^lang]);
        for l in lp_ladders do
            nextunless(hd(l) == lang);
            hd(tl(tl(l))) -> lv;
            0 -> n;
            for i in lp_items do
                if lp_ilang(i) == lang and lp_ilevel(i) == lv then n + 1 -> n endif;
            endfor;
            dump_pr('  %p. %p  (%p items)\n', [% hd(tl(l)), lv, n %]);
            for e in lp_exits do
                nextunless(hd(e) == lang and hd(tl(e)) == lv);
                dump_pr('       exit: %p >= %p', [% lp_term_str(hd(tl(tl(e)))),
                                                   hd(tl(tl(tl(e)))) %]);
                if hd(tl(tl(tl(tl(e))))) then
                    dump_pr(' within %pms', [% hd(tl(tl(tl(tl(e))))) %])
                endif;
                dump_out_str('\n');
            endfor;
        endfor;
        dump_out_str('\n');
    endfor;
    dump_pr('confusable pairs: %p\n',
            [% listlength([% for i in lp_items do
                                 for p in lp_confs(i) do
                                     if dump_in_scope(i) and dump_in_scope(hd(p))
                                     and alphabefore(i, hd(p)) then i endif;
                                 endfor;
                             endfor %]) %]);
    dump_pr('resources:        %p\n', [% listlength(lp_rsrc) %]);
enddefine;


;;; ------------------------------------------------------------ the viewer
;;; viewer/page.html is a FRAGMENT -- it starts at <title> and has no
;;; doctype -- because it has two hosts: the artifact host wraps it in its
;;; own document skeleton, and this writes the skeleton for the standalone
;;; file.  One copy of the page either way, which is the point: a viewer
;;; forked into a local version and a shared version drifts within a week.
lconstant VIEWER_HEAD =
    '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
    <> '<meta name="viewport" content="width=device-width, initial-scale=1, '
    <> 'viewport-fit=cover">\n'
    <> '<style>:root{color-scheme:light;'
    <> 'padding-top:env(safe-area-inset-top,0px);'
    <> 'padding-bottom:env(safe-area-inset-bottom,0px)}'
    <> 'body{margin:0;font:14px system-ui,sans-serif}'
    <> 'img{max-width:100%}[hidden]{display:none!important}</style>\n';

lconstant EMBED_MARK = 'const EMBEDDED = null; /* langpop:embed */';

define dump_html();
    lvars page, at, json, dev = dump_dev;
    lp_read_file(langpop_dir <> 'viewer/page.html') -> page;
    unless page then
        mishap(langpop_dir <> 'viewer/page.html', 1,
               'dump: the viewer page is missing')
    endunless;
    ;;; the JSON, captured rather than written: it has to go inside the page
    lvars buf = [];
    procedure(c); conspair(c, buf) -> buf endprocedure -> dump_dev;
    dump_json();
    dev -> dump_dev;
    consstring(destlist(rev(buf))) -> json;

    issubstring(EMBED_MARK, page) -> at;
    unless at then
        mishap(EMBED_MARK, 1, 'dump: viewer/page.html has no embed marker')
    endunless;

    dump_out_str(VIEWER_HEAD);
    dump_out_str(substring(1, at - 1, page));
    dump_out_str('const EMBEDDED =\n');
    dump_out_str(json);
    dump_out_str(';\n');
    dump_out_str(substring(at + length(EMBED_MARK),
                           length(page) - (at + length(EMBED_MARK)) + 1, page));
    dump_out_str('\n</html>\n');
enddefine;

;;; ------------------------------------------------------------------ main
define dump_main();
    dump_args();
    find_dir() -> langpop_dir;
    lp_load();
    lp_index();
    if dump_out then discout(dump_out) else cucharout endif -> dump_dev;
    if     dump_format = 'dot'  then dump_dot()
    elseif dump_format = 'text' then dump_text()
    elseif dump_format = 'html' then dump_html()
    else                             dump_json()
    endif;
    if dump_out then
        dump_dev(termin);
        printf('dump: wrote %p (%p)\n', [% dump_out, dump_format %]);
    endif;
enddefine;

unless isdefined("langpop_dump_lib") then dump_main() endunless;
