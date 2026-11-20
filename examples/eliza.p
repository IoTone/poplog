/* examples/eliza.p -- ELIZA (Weizenbaum's DOCTOR), the real algorithm, in Pop-11.

   Joseph Weizenbaum's ELIZA (MIT, 1966) is the original conversational program.
   This is a faithful implementation of its *technology* -- not the thin
   teaching pattern-matcher often shown for Pop-11, but the genuine engine:

     * keyword RANKING            -- the highest-ranked keyword in the sentence
                                     picks which transformation rules to use;
     * DECOMPOSITION rules        -- patterns with `*` wildcards (and `@synonym`
                                     classes) that break the sentence apart;
     * REASSEMBLY rules           -- response templates that reference the
                                     decomposed pieces by number, cycled
                                     round-robin so the same input varies;
     * REFLECTION                 -- echoed fragments are flipped to the second
                                     person (I->you, my->your, am->are, ...);
     * equivalence + redirection  -- `goto <key>` hands off to another keyword;
     * MEMORY                     -- mentioning "my X" is stashed and brought
                                     back later when nothing else matches.

   Pop-11 is an unusually good host for this: its list machinery and recursion
   make the decomposition matcher a dozen lines, and Weizenbaum's script/engine
   separation maps onto a data file (examples/doctor.txt) read at startup.

   The DOCTOR script lives in examples/doctor.txt (credited there).  ELIZA was
   J. Weizenbaum, CACM 9(1), Jan 1966.

   Run it (console; no graphics build needed):
       ./poplog ./target/pop/basepop11 examples/eliza.p
   or, with a front-end on PATH:
       pop11 examples/eliza.p
   or:
       tools/eliza.sh
   Type at it; `bye`, `goodbye` or `quit` (or end-of-file) leaves.
*/

;;; ---------------------------------------------------------------------------
;;; script data (filled by the parser) + small global state
;;; ---------------------------------------------------------------------------

vars
    eliza_initials, eliza_finals, eliza_quits, eliza_keylist,
    eliza_key_rec, eliza_pre, eliza_post, eliza_synon,
    eliza_mem = [],
    eliza_dir = sys_fname_path(popfilename),   ;;; directory of this source file
    eliza_no_repl;                              ;;; set true to load without starting

;;; Not initialised in the declaration above: that would overwrite a value the
;;; loader set beforehand, and the engine-only load described at the end of
;;; this file would start the session anyway.
if isundef(eliza_no_repl) then false -> eliza_no_repl endif;

;;; parser state (used only while reading the script)
vars p_ckw, p_crank, p_cdecs, p_cmem, p_cpat, p_creas, p_have_dec;

;;; ---------------------------------------------------------------------------
;;; tiny string helpers
;;; ---------------------------------------------------------------------------

define lc(s) -> r;                              ;;; lower-case a string (copy)
    lvars i, c;
    copy(s) -> r;
    for i from 1 to length(s) do
        subscrs(i, s) -> c;
        if c >= `A` and c <= `Z` then c - `A` + `a` -> subscrs(i, r) endif;
    endfor;
enddefine;

define lstrip(s) -> r;                          ;;; drop leading blanks/tabs
    lvars i = 1, n = length(s);
    while i <= n and (subscrs(i,s) == `\s` or subscrs(i,s) == `\t`) do i + 1 -> i endwhile;
    if i > n then '' -> r else substring(i, n - i + 1, s) -> r endif;
enddefine;

define split_ws(s) -> toks;                     ;;; split a string on whitespace
    lvars i = 1, j, n = length(s), toks = [];
    while i <= n do
        while i <= n and (subscrs(i,s) == `\s` or subscrs(i,s) == `\t`) do i + 1 -> i endwhile;
        quitif(i > n);
        i -> j;
        while j <= n and not(subscrs(j,s) == `\s` or subscrs(j,s) == `\t`) do j + 1 -> j endwhile;
        substring(i, j - i, s) :: toks -> toks;
        j -> i;
    endwhile;
    ncrev(toks) -> toks;
enddefine;

define nthl(n, l);                              ;;; n-th element of a list (1-based)
    until n == 1 do tl(l) -> l; n - 1 -> n enduntil;
    hd(l)
enddefine;

define split_at(k, l) -> (pre, suf);           ;;; first k items / the rest
    lvars i, pre = [];
    l -> suf;
    for i from 1 to k do
        hd(suf) :: pre -> pre;
        tl(suf) -> suf;
    endfor;
    ncrev(pre) -> pre;
enddefine;

;;; ---------------------------------------------------------------------------
;;; parsing the DOCTOR script (the Hayden line format)
;;; ---------------------------------------------------------------------------

define parse_line(line) -> (dir, rest);         ;;; "directive: value" -> (dir, value)
    lvars t = lstrip(line), p, n;
    '' -> dir; '' -> rest;
    if t = '' or subscrs(1, t) == `#` then return endif;
    length(t) -> n; 1 -> p;
    while p <= n and subscrs(p, t) /== `:` do p + 1 -> p endwhile;
    if p > n then return endif;
    substring(1, p - 1, t) -> dir;
    lstrip(substring(p + 1, n - p, t)) -> rest;
enddefine;

define parse_pat_tok(s);                         ;;; a decomposition token
    if s = '*' then "*"
    elseif subscrs(1, s) == `@` then
        {% "synon", consword(lc(substring(2, length(s) - 1, s))) %}
    else
        consword(lc(s))
    endif
enddefine;

define parse_reasmb(rest);                        ;;; a reassembly template, or a goto
    lvars toks = split_ws(rest), inner, num;
    if toks /== [] and hd(toks) = 'goto' then
        {% "goto", consword(lc(hd(tl(toks)))) %}
    else
        maplist(toks, procedure(s) -> out;
            if length(s) >= 3 and subscrs(1,s) == `(` and subscrs(length(s),s) == `)` then
                substring(2, length(s) - 2, s) -> inner;
                strnumber(inner) -> num;
                if num then num else s endif -> out;
            else
                s -> out
            endif
        endprocedure)
    endif
enddefine;

define read_lines(fname) -> lines;                ;;; file -> list of strings
    lvars dev, c, n, lines = [];
    discin(fname) -> dev;
    repeat
        0 -> n;
        repeat
            dev() -> c;
            if c == termin or c == `\n` then quitloop endif;
            c;                                    ;;; push char on stack
            n + 1 -> n;
        endrepeat;
        if c == termin and n == 0 then quitloop endif;
        consstring(n) :: lines -> lines;
        if c == termin then quitloop endif;
    endrepeat;
    ncrev(lines) -> lines;
enddefine;

define finish_dec();                              ;;; commit the current decomposition
    if p_have_dec then
        {% p_cmem, p_cpat, ncrev(p_creas), 0 %} :: p_cdecs -> p_cdecs;
        false -> p_have_dec;
    endif;
enddefine;

define finish_key();                              ;;; commit the current keyword
    finish_dec();
    if p_ckw then
        {% p_ckw, p_crank, ncrev(p_cdecs) %} -> eliza_key_rec(p_ckw);
        p_ckw :: eliza_keylist -> eliza_keylist;
    endif;
    false -> p_ckw; 0 -> p_crank; [] -> p_cdecs;
enddefine;

define build_doctor(fname);
    lvars line, dir, rest, toks;
    [] -> eliza_initials; [] -> eliza_finals; [] -> eliza_quits; [] -> eliza_keylist;
    newproperty([], 64, false, "perm") -> eliza_key_rec;
    newproperty([], 64, false, "perm") -> eliza_pre;
    newproperty([], 32, false, "perm") -> eliza_post;
    newproperty([], 32, false, "perm") -> eliza_synon;
    false -> p_ckw; 0 -> p_crank; [] -> p_cdecs; false -> p_have_dec;

    for line in read_lines(fname) do
        parse_line(line) -> (dir, rest);
        if dir = '' then
            nextloop
        elseif dir = 'initial' then
            eliza_initials <> [^rest] -> eliza_initials
        elseif dir = 'final' then
            eliza_finals <> [^rest] -> eliza_finals
        elseif dir = 'quit' then
            consword(lc(rest)) :: eliza_quits -> eliza_quits
        elseif dir = 'pre' then
            split_ws(rest) -> toks;
            maplist(tl(toks), procedure(s); consword(lc(s)) endprocedure)
                -> eliza_pre(consword(lc(hd(toks))))
        elseif dir = 'post' then                  ;;; key matched lower-case; value keeps
            split_ws(rest) -> toks;                ;;; its case (so you -> "I", not "i")
            maplist(tl(toks), procedure(s); consword(s) endprocedure)
                -> eliza_post(consword(lc(hd(toks))))
        elseif dir = 'synon' then
            split_ws(rest) -> toks;
            maplist(toks, procedure(s); consword(lc(s)) endprocedure)
                -> eliza_synon(consword(lc(hd(toks))))      ;;; set includes the name
        elseif dir = 'key' then
            finish_key();
            split_ws(rest) -> toks;
            consword(lc(hd(toks))) -> p_ckw;
            if tl(toks) /== [] and strnumber(hd(tl(toks))) then
                strnumber(hd(tl(toks))) -> p_crank
            else 0 -> p_crank endif;
            [] -> p_cdecs
        elseif dir = 'decomp' then
            finish_dec();
            split_ws(rest) -> toks;
            false -> p_cmem;
            if toks /== [] and hd(toks) = '$' then true -> p_cmem; tl(toks) -> toks endif;
            maplist(toks, parse_pat_tok) -> p_cpat;
            [] -> p_creas; true -> p_have_dec
        elseif dir = 'reasmb' then
            parse_reasmb(rest) :: p_creas -> p_creas
        endif;
    endfor;
    finish_key();
    ncrev(eliza_keylist) -> eliza_keylist;
enddefine;

;;; ---------------------------------------------------------------------------
;;; the decomposition matcher: input x pattern -> list of captured groups | false
;;;   pattern tokens:  "*"  (a run of 0+ words),  {synon X} (one word of class X),
;;;                    or a literal word.  Only `*` and `@` produce numbered groups.
;;; ---------------------------------------------------------------------------

define dmatch(input, pat) -> res;
    lvars w, g, k, pre, suf;
    if null(pat) then
        if null(input) then [] else false endif -> res;
        return;
    endif;
    hd(pat) -> w;
    if isvector(w) then                           ;;; @synonym -- one matching word
        if null(input) then false -> res; return endif;
        if member(hd(input), eliza_synon(subscrv(2, w))) then
            dmatch(tl(input), tl(pat)) -> g;
            if g then [ [^(hd(input))] ^^g ] -> res else false -> res endif
        else false -> res endif;
    elseif w == "*" then                          ;;; wildcard -- 0+ words, leftmost
        0 -> k;
        repeat
            split_at(k, input) -> (pre, suf);
            dmatch(suf, tl(pat)) -> g;
            if g then [^pre ^^g] -> res; return endif;
            quitif(k >= length(input));
            k + 1 -> k;
        endrepeat;
        false -> res;
    else                                          ;;; literal -- must match, no group
        if null(input) then false -> res
        elseif hd(input) == w then dmatch(tl(input), tl(pat)) -> res
        else false -> res endif;
    endif;
enddefine;

;;; ---------------------------------------------------------------------------
;;; reflection + reassembly
;;; ---------------------------------------------------------------------------

define reflect(group) -> out;                     ;;; flip person on echoed words
    lvars w, r, out = [];
    for w in group do
        eliza_post(w) -> r;
        if r then out <> r else out <> [^w] endif -> out;
    endfor;
enddefine;

define join(items) -> str;                        ;;; words/strings -> one string
    lvars it, s, str = '';
    for it in items do
        it >< '' -> s;
        if str = '' then s -> str
        elseif length(s) == 1 and member(subscrs(1,s), [`?` `.` `,` `!` `;` `:`]) then
            str <> s -> str
        else str >< ' ' >< s -> str endif;
    endfor;
    if str = '' then 'Hmm.' -> str endif;
enddefine;

define fill_reasmb(template, groups) -> str;      ;;; (n) -> reflected group n
    lvars t, pieces = [];
    for t in template do
        if isinteger(t) then
            if t <= length(groups) then pieces <> reflect(nthl(t, groups)) -> pieces endif
        else
            pieces <> [^t] -> pieces
        endif;
    endfor;
    join(pieces) -> str;
enddefine;

;;; ---------------------------------------------------------------------------
;;; memory (FIFO, small)
;;; ---------------------------------------------------------------------------

define eliza_remember(str);
    eliza_mem <> [^str] -> eliza_mem;
    if length(eliza_mem) > 5 then tl(eliza_mem) -> eliza_mem endif;
enddefine;

define eliza_recall() -> str;
    if eliza_mem == [] then false -> str
    else hd(eliza_mem) -> str; tl(eliza_mem) -> eliza_mem endif;
enddefine;

;;; ---------------------------------------------------------------------------
;;; assembling a reply from one keyword's rules
;;; ---------------------------------------------------------------------------

define assemble(keyrec, words, depth) -> reply;
    lvars decs, d, groups, reas, r, n, idx, gkey;
    false -> reply;
    if depth > 8 then return endif;               ;;; guard against goto loops
    subscrv(3, keyrec) -> decs;
    for d in decs do
        dmatch(words, subscrv(2, d)) -> groups;
        if groups then
            subscrv(3, d) -> reas;
            length(reas) -> n;
            subscrv(4, d) -> idx;
            nthl((idx rem n) + 1, reas) -> r;     ;;; cycle the reassembly rules
            idx + 1 -> subscrv(4, d);
            if subscrv(1, d) then                 ;;; $ memory rule: stash, keep looking
                unless isvector(r) then eliza_remember(fill_reasmb(r, groups)) endunless;
                nextloop
            elseif isvector(r) and subscrv(1, r) == "goto" then
                subscrv(2, r) -> gkey;
                if eliza_key_rec(gkey) then assemble(eliza_key_rec(gkey), words, depth + 1) -> reply endif;
                return
            else
                fill_reasmb(r, groups) -> reply;
                return
            endif;
        endif;
    endfor;
enddefine;

;;; ---------------------------------------------------------------------------
;;; turning a line into a reply
;;; ---------------------------------------------------------------------------

define presub(words) -> out;                      ;;; apply pre: rewrites
    lvars w, r, out = [];
    for w in words do
        eliza_pre(w) -> r;
        if r then out <> r else out <> [^w] endif -> out;
    endfor;
enddefine;

define phrase_rank(words) -> best;                ;;; best keyword rank in a phrase
    lvars w, kr;
    -1000 -> best;
    for w in words do
        eliza_key_rec(w) -> kr;
        if kr and subscrv(2, kr) > best then subscrv(2, kr) -> best endif;
    endfor;
enddefine;

define build_keystack(words) -> stack;            ;;; keys present, highest rank first
    lvars w, kr, seen = [], items = [], i = 0;    ;;; ties keep first-occurrence order
    for w in words do
        i + 1 -> i;
        eliza_key_rec(w) -> kr;
        if kr and not(member(w, seen)) then
            w :: seen -> seen;
            {% subscrv(2, kr), i, kr %} :: items -> items;
        endif;
    endfor;
    syssort(items, procedure(a, b);
        subscrv(1,a) > subscrv(1,b)
        or (subscrv(1,a) == subscrv(1,b) and subscrv(2,a) < subscrv(2,b))
    endprocedure) -> items;
    maplist(items, procedure(x); subscrv(3, x) endprocedure) -> stack;
enddefine;

define respond(phrases) -> reply;
    lvars ph, r, words, kstack, kr, best = false, bestrank = -1000, m;
    for ph in phrases do                          ;;; pick the clause with the best keyword
        presub(ph) -> ph;
        phrase_rank(ph) -> r;
        if not(best) or r > bestrank then r -> bestrank; ph -> best endif;
    endfor;
    if not(best) then [] -> best endif;
    best -> words;
    build_keystack(words) -> kstack;
    false -> reply;
    for kr in kstack do
        assemble(kr, words, 0) -> reply;
        if reply then return endif;
    endfor;
    eliza_recall() -> m;                          ;;; nothing keyed -> a memory, or NONE
    if m then m -> reply; return endif;
    assemble(eliza_key_rec("xnone"), words, 0) -> reply;
    if not(reply) then 'Please go on.' -> reply endif;
enddefine;

;;; ---------------------------------------------------------------------------
;;; the read-eval-print loop
;;; ---------------------------------------------------------------------------

define tokenize(line) -> phrases;                 ;;; line -> list of phrases (word lists)
    lvars i, c, n = length(line), nc = 0, cur = [], phrases = [];
    for i from 1 to n + 1 do
        if i <= n then subscrs(i, line) -> c else `\s` -> c endif;
        if i <= n and ((c >= `a` and c <= `z`) or (c >= `A` and c <= `Z`)
                       or (c >= `0` and c <= `9`) or c == `'`) then
            if c >= `A` and c <= `Z` then c - `A` + `a` else c endif;   ;;; push lc char
            nc + 1 -> nc;
        else
            if nc > 0 then consword(consstring(nc)) :: cur -> cur; 0 -> nc endif;
            if i <= n and (c == `.` or c == `,` or c == `;` or c == `?` or c == `!`) then
                if cur /== [] then ncrev(cur) :: phrases -> phrases; [] -> cur endif;
            endif;
        endif;
    endfor;
    if cur /== [] then ncrev(cur) :: phrases -> phrases endif;
    ncrev(phrases) -> phrases;
enddefine;

define read_line_str() -> line;                   ;;; a raw line of input, or termin at EOF
    lvars c, n = 0;
    repeat
        charin() -> c;
        if c == termin then
            if n == 0 then termin -> line; return endif;
            quitloop
        endif;
        quitif(c == `\n`);
        c; n + 1 -> n;
    endrepeat;
    consstring(n) -> line;
enddefine;

define is_quit(line);
    lvars phr = tokenize(line);
    phr /== [] and hd(phr) /== [] and member(hd(hd(phr)), eliza_quits)
enddefine;

define say(s); pr(s); pr(newline); enddefine;

define find_script() -> f;
    lvars c;
    for c in [% eliza_dir <> 'doctor.txt', 'examples/doctor.txt', 'doctor.txt' %] do
        if sys_file_exists(c) then c -> f; return endif;
    endfor;
    eliza_dir <> 'doctor.txt' -> f;               ;;; default (errors helpfully if absent)
enddefine;

define eliza_main();
    lvars line;
    build_doctor(find_script());
    [] -> eliza_mem;
    say(hd(eliza_initials));
    repeat
        read_line_str() -> line;
        if line == termin or is_quit(line) then say(hd(eliza_finals)); quitloop endif;
        say(respond(tokenize(line)));
    endrepeat;
enddefine;

;;; Start talking when this file is run as a program (the default).  To load the
;;; engine without entering the loop:  true -> eliza_no_repl;  before loading.
unless eliza_no_repl then eliza_main() endunless;
