/* tools/gen-docs.p -- generate a static HTML documentation site (and
   llms.txt) from the HELP / TEACH / REF corpus.

   Run via tools/gen-docs.sh; output lands in dist/docs/.

   This is 2030plan item 1.1 (first cut), written in Pop-11 on the
   Tier-2 stdlib (fileutils, strutils, shell): the corpus becomes
   ~900 HTML pages with cross-references (`HELP * JSON`,
   `REF * REGEXP`, `LIB * FOO`...) turned into links, one index page,
   and an llms.txt manifest so AI assistants can find the docs too.
*/

uses fileutils;
uses strutils;
uses shell;

vars outdir = 'dist/docs';
vars site_base = 'https://iotone.github.io/poplog';

;;; --- collect the corpus -------------------------------------------------

;;; sections: {srcdir outsubdir LABEL}
lconstant sections =
    [{'pop/help'  'help'  'HELP'}
     {'pop/teach' 'teach' 'TEACH'}
     {'pop/ref'   'ref'   'REF'}];

define lconstant docname_ok(name);
    ;;; skip generated indexes and oddities
    lvars i, c;
    returnif(name = nullstring or issubstring('index', 1, name))(false);
    for i from 1 to length(name) do
        subscrs(i, name) -> c;
        unless (c >= `a` and c <= `z`) or (c >= `0` and c <= `9`)
        or c == `_` or c == `-` or c == `.` then
            return(false)
        endunless;
    endfor;
    true
enddefine;

;;; known('help/json') -> true for every page we will emit
vars known = newmapping([], 512, false, true);
vars corpus = [];   ;;; list of {subdir name path title desc}

define lconstant firstline_info(path) -> (title, desc);
    lvars s = file_to_string(path), lines, parts;
    str_lines(s) -> lines;
    if lines == [] then nullstring ->> title -> desc; return endif;
    str_trim(hd(lines)) -> title;
    ;;; description = title minus its first two tokens (TYPE NAME)
    str_split(title, `\s`) -> parts;
    if length(parts) > 2 then
        str_trim(str_join(tl(tl(parts)), ' ')) -> desc;
    else
        nullstring -> desc;
    endif;
enddefine;

define lconstant collect();
    lvars sec, srcdir, sub, path, name, title, desc, n = 0;
    for sec in sections do
        explode(sec) -> (srcdir, sub, );
        [% for path in dir_files(srcdir <> '/*') do
               last(str_split(path, `/`)) -> name;
               nextunless(docname_ok(name));
               nextif(sysisdirectory(path));
               firstline_info(path) -> (title, desc);
               true -> known(sub <> '/' <> name);
               {% sub, name, path, title, desc %};
               n + 1 -> n;
           endfor %] <> corpus -> corpus;
    endfor;
enddefine;

;;; --- HTML rendering -----------------------------------------------------

define lconstant escape(s) -> r;
    lvars i, c, n = 0;
    for i from 1 to length(s) do
        subscrs(i, s) -> c;
        if c == `&` then appdata('&amp;', identfn); n + 5 -> n;
        elseif c == `<` then appdata('&lt;', identfn); n + 4 -> n;
        elseif c == `>` then appdata('&gt;', identfn); n + 4 -> n;
        else c; n + 1 -> n;
        endif;
    endfor;
    consstring(n) -> r;
enddefine;

lconstant typedirs = newmapping(
    [['HELP' 'help'] ['TEACH' 'teach'] ['REF' 'ref'] ['LIB' 'help']],
    8, false, true);

define lconstant namechar(c);
    (c >= `A` and c <= `Z`) or (c >= `a` and c <= `z`)
    or (c >= `0` and c <= `9`) or c == `_`
enddefine;

define lconstant ghchar(c);
    namechar(c) or c == `-`
enddefine;

;;; does s contain a 19xx/20xx year?  Classic docs carry their credit in
;;; the title line ("A.Sloman Nov 1986"); new ones carry a description
;;; there instead, so a year is what tells the two apart.
define lconstant has_year(s);
    lvars i, c;
    for i from 1 to length(s) - 3 do
        subscrs(i, s) -> c;
        if (c == `1` and subscrs(i + 1, s) == `9`)
        or (c == `2` and subscrs(i + 1, s) == `0`) then
            if subscrs(i + 2, s) >= `0` and subscrs(i + 2, s) <= `9`
            and subscrs(i + 3, s) >= `0` and subscrs(i + 3, s) <= `9` then
                return(true)
            endif;
        endif;
    endfor;
    false
enddefine;

lconstant months =
    ['jan' 'feb' 'mar' 'apr' 'may' 'jun' 'jul' 'aug' 'sep' 'oct' 'nov' 'dec'];

define lconstant count_char(c, s) -> n;
    lvars i;
    0 -> n;
    for i from 1 to length(s) do
        if subscrs(i, s) == c then n + 1 -> n endif;
    endfor;
enddefine;

define lconstant has_digit(s);
    lvars i, c;
    for i from 1 to length(s) do
        subscrs(i, s) -> c;
        if c >= `0` and c <= `9` then return(true) endif;
    endfor;
    false
enddefine;

;;; a full year, or a month name next to some digits ("July 85", and even
;;; the odd upstream typo "July 985") -- a description rarely has both
define lconstant looks_like_credit(s);
    lvars m, low;
    returnif(has_year(s))(true);
    unless has_digit(s) then return(false) endunless;
    str_lower(s) -> low;
    for m in months do
        if issubstring(m, 1, low) then return(true) endif;
    endfor;
    false
enddefine;

;;; link @handle to the GitHub profile
define lconstant handlelink(s) -> out;
    lvars i = 1, j, k, pieces;
    [% repeat
        locchar(`@`, i, s) -> j;
        quitunless(j);
        j + 1 -> k;
        while k <= length(s) and ghchar(subscrs(k, s)) do k + 1 -> k endwhile;
        substring(i, j - i, s);
        if k > j + 1 then
            '<a href="https://github.com/' <> substring(j + 1, k - j - 1, s) <> '">';
            substring(j, k - j, s);
            '</a>';
        else
            substring(j, k - j, s);
        endif;
        k -> i;
    endrepeat;
    substring(i, length(s) - i + 1, s);
    %] -> pieces;
    str_join(pieces, '') -> out;
enddefine;

;;; turn `HELP * JSON` style cross-references in an escaped line into
;;; links (relative to a page one directory below the site root)
define lconstant linkify(line) -> out;
    lvars i = 1, j, b, e, ns, ne, typ, dir, name, pieces = [];
    [% repeat
        issubstring(' * ', i, line) -> j;
        quitunless(j);
        ;;; the word ending just before j.  Skip any padding first: the
        ;;; house style for a Further reading block aligns the names
        ;;; into a column (HELP  * JSON), and without this the extra
        ;;; spaces stop the scan before it reaches the word -- which
        ;;; silently unlinked the see-also list of every TEACH file.
        j - 1 -> e;
        while e >= 1 and subscrs(e, line) == `\s` do e - 1 -> e endwhile;
        e -> b;
        while b >= 1 and subscrs(b, line) >= `A` and subscrs(b, line) <= `Z` do
            b - 1 -> b;
        endwhile;
        b + 1 -> b;
        ;;; the name starting after ' * ', padding skipped likewise
        j + 3 -> ns;
        while ns <= length(line) and subscrs(ns, line) == `\s` do
            ns + 1 -> ns;
        endwhile;
        ns -> ne;
        while ne <= length(line) and namechar(subscrs(ne, line)) do
            ne + 1 -> ne;
        endwhile;
        ne - 1 -> ne;
        if e >= b
        and (typedirs(substring(b, e - b + 1, line)) ->> dir)
        and ne >= ns
        and (str_lower(substring(ns, ne - ns + 1, line)) ->> name)
        and known(dir <> '/' <> name) then
            substring(i, b - i, line);
            '<a href="../' <> dir <> '/' <> name <> '.html">';
            substring(b, ne - b + 1, line);
            '</a>';
            ne + 1 -> i;
        else
            substring(i, j + 2 - i + 1, line);
            j + 3 -> i;
        endif;
    endrepeat;
    substring(i, length(line) - i + 1, line);
    %] -> pieces;
    str_join(pieces, '') -> out;
enddefine;

lconstant css =
'body{margin:0;background:#FAFAF7;color:#1E2420;font-family:ui-monospace,Menlo,Consolas,monospace}'
<> '@media(prefers-color-scheme:dark){body{background:#141815;color:#E6EBE7}'
<> 'a{color:#4CC69F}.crumb a{color:#4CC69F}}'
<> 'main{max-width:60rem;margin:0 auto;padding:2rem 1rem}'
<> 'pre{white-space:pre-wrap;word-wrap:break-word;line-height:1.45;font-size:14px}'
<> 'a{color:#157A63}h1{font-size:1.2rem}'
<> '.crumb{font-size:0.8rem;margin-bottom:1rem}'
<> '.auth{margin-top:1.5rem;padding-top:0.6rem;font-size:0.85rem;opacity:0.75;'
<> 'border-top:1px solid rgba(128,128,128,0.35)}'
<> 'ul{line-height:1.7;padding-left:1.2rem;list-style:none}'
<> '.d{opacity:0.65;font-size:0.85em}';

define lconstant page(title, crumb, body) -> html;
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    <> '<title>' <> escape(title) <> ' — Poplog</title>'
    <> '<style>' <> css <> '</style>'
    <> '<main><div class="crumb">' <> crumb <> '</div>'
    <> body <> '</main>' -> html;
enddefine;

define lconstant render_doc(entry);
    lvars sub, name, path, title, desc, line, body, author = false, foot = '';
    explode(entry) -> (sub, name, path, title, desc);
    [% for line in str_lines(file_to_string(path)) do
           ;;; '--- Author: ...' is metadata, not body text: lift it out
           ;;; and render it as the page's credit footer
           if str_starts('--- Author:', line) then
               str_trim(substring(12, length(line) - 11, line)) -> author;
           else
               linkify(escape(line));
           endif;
       endfor %] -> body;
    unless author then
        if looks_like_credit(desc) then desc -> author endif;   ;;; classic style
    endunless;
    if author then
        '<div class="auth">'
            <> (if count_char(`@`, author) >= 2 then 'Authors: '
                else 'Author: ' endif)
            <> handlelink(escape(author)) <> '</div>' -> foot;
    endif;
    string_to_file(
        page(title,
             '<a href="../index.html">poplog docs</a> / ' <> sub,
             '<pre>' <> str_join(body, '\n') <> '</pre>' <> foot),
        outdir <> '/' <> sub <> '/' <> name <> '.html');
enddefine;

;;; --- index + llms.txt ---------------------------------------------------

define lconstant gen_index();
    lvars sec, sub, label, entry, items, body = '';
    for sec in sections do
        explode(sec) -> (, sub, label);
        [% for entry in corpus do
               if subscrv(1, entry) = sub then
                   '<li><a href="' <> sub <> '/' <> subscrv(2, entry)
                   <> '.html">' <> escape(subscrv(2, entry)) <> '</a>'
                   <> ' <span class="d">' <> escape(subscrv(5, entry))
                   <> '</span></li>'
               endif;
           endfor %] -> items;
        body <> '<h1>' <> label <> ' (' >< length(items) >< ')</h1><ul>'
             <> str_join(items, '\n') <> '</ul>' -> body;
    endfor;
    string_to_file(
        page('Poplog documentation',
             'poplog docs',
             '<pre>Poplog / Pop-11 documentation — generated from the in-tree\n'
             <> 'HELP, TEACH and REF corpus by tools/gen-docs.sh (a Pop-11\n'
             <> 'program).  Start points: '
             <> '<a href="help/json.html">HELP JSON</a>, '
             <> '<a href="teach/json.html">TEACH JSON</a>, '
             <> '<a href="ref/regexp.html">REF REGEXP</a>.</pre>' <> body),
        outdir <> '/index.html');
enddefine;

define lconstant gen_llms();
    lvars sec, sub, label, entry, out;
    [% '# Poplog documentation';
       '';
       '> Documentation for Poplog / Pop-11 (multi-language incremental-';
       '> compiler system: Pop-11, Prolog, Common Lisp, Standard ML, Forth),';
       '> generated from the in-tree HELP/TEACH/REF corpus.';
       '';
       for sec in sections do
           explode(sec) -> (, sub, label);
           '## ' <> label;
           '';
           for entry in corpus do
               if subscrv(1, entry) = sub then
                   '- [' <> subscrv(2, entry) <> '](' <> sub <> '/'
                   <> subscrv(2, entry) <> '.html): ' <> subscrv(5, entry)
               endif;
           endfor;
           '';
       endfor;
    %] -> out;
    string_to_file(str_join(out, '\n') <> '\n', outdir <> '/llms.txt');
enddefine;

;;; sitemap.xml + robots.txt: the site is useless to search engines it has
;;; never been introduced to.  One <url> per page, no lastmod (the corpus
;;; carries no per-file dates worth asserting).
define lconstant gen_sitemap();
    lvars entry, out;
    [% '<?xml version="1.0" encoding="UTF-8"?>';
       '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
       '  <url><loc>' <> site_base <> '/</loc></url>';
       for entry in corpus do
           '  <url><loc>' <> site_base <> '/' <> subscrv(1, entry) <> '/'
           <> escape(subscrv(2, entry)) <> '.html</loc></url>'
       endfor;
       '</urlset>';
    %] -> out;
    string_to_file(str_join(out, '\n') <> '\n', outdir <> '/sitemap.xml');
enddefine;

define lconstant gen_robots();
    string_to_file(
        'User-agent: *\nAllow: /\n\nSitemap: ' <> site_base
            <> '/sitemap.xml\n',
        outdir <> '/robots.txt');
enddefine;

;;; --- main ---------------------------------------------------------------

vars entry, npages = 0, out, st;
shell_run('mkdir -p ' <> outdir <> '/help ' <> outdir <> '/teach '
          <> outdir <> '/ref') -> (out, st);
collect();
for entry in corpus do
    render_doc(entry);
    npages + 1 -> npages;
endfor;
gen_index();
gen_llms();
gen_sitemap();
gen_robots();
'gen-docs: ' >< npages >< ' pages + index + llms.txt + sitemap -> ' >< outdir =>
