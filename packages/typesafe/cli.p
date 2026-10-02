/* cli.p -- the command-line front end behind ./ts-eval.
 *
 * Kept separate from typesafe.p so the library stays a library: nothing
 * here is needed to use it from Pop-11, and nothing in typesafe.p knows
 * about argv, stdin or how to print an answer for a human.
 */
extend_searchlist(sys_fname_path(popfilename), popuseslist) -> popuseslist;
uses typesafe;
uses strutils;

define lconstant usage();
    printf('ts-eval -- ask the TypeSafe API a typed question\n\n', []);
    printf('  ts-eval noul   "<question>" "<text>"\n', []);
    printf('  ts-eval choice "<question>" opt1,opt2,... "<text>"\n', []);
    printf('  ts-eval score  "<question>" low,...,high "<text>"\n\n', []);
    printf('Use - for <text> to read it from stdin.\n', []);
    printf('Needs TYPESAFE_API_KEY.\n\n', []);
    printf('  ts-eval noul "Is this a greeting?" "Hello there"\n', []);
    printf('  cat notes.txt | ts-eval score "How urgent?" low,medium,high -\n', []);
    sysexit();
enddefine;

;;; '-' means stdin, so the interesting case -- judging a file you already
;;; have -- does not need the text to survive shell quoting.
define lconstant text_of(arg) -> s;
    lvars rep, line, acc = '';
    if arg = '-' then
        line_repeater(popdevin, inits(4096)) -> rep;
        repeat
            rep() -> line;
            quitif(line == termin);
            acc <> line -> acc;
        endrepeat;
        acc -> s;
    else
        arg -> s;
    endif;
enddefine;

define lconstant show(ans);
    lvars t = ans('type');
    if t = 'noul' then
        printf('%p   (%p)\n',
               [% ans('noul'),
                  if ans('noul') >= 0.5 then 'yes' else 'no' endif %]);
    elseif t = 'choice' then
        printf('%p   (confidence %p)\n', [% ans('choice'), ans('confidence') %]);
    elseif t = 'score' then
        printf('%p   (confidence %p)\n', [% ans('score'), ans('confidence') %]);
    else
        printf('unexpected answer type %p\n', [% t %]);
    endif;
enddefine;

define lconstant main();
    lvars args = poparglist, mode, question, opts, body, q;
    if args == [] or length(args) < 3 then usage() endif;
    hd(args) -> mode;
    hd(tl(args)) -> question;

    unless ts_api_key then
        printf('ts-eval: TYPESAFE_API_KEY is not set\n', []);
        sysexit();
    endunless;

    if mode = 'noul' then
        text_of(hd(tl(tl(args)))) -> body;
        ts_noul(question, 'yes', 'no') -> q;
    elseif mode = 'choice' or mode = 'score' then
        if length(args) < 4 then usage() endif;
        str_split(hd(tl(tl(args))), `,`) -> opts;
        text_of(hd(tl(tl(tl(args))))) -> body;
        if mode = 'choice' then
            ;;; no per-option description from the command line; the option
            ;;; name is the description, which is what null means here
            ts_choice(question, [% lvars o;
                                   for o in opts do [% o, false %] endfor %]) -> q;
        else
            ts_score(question, opts) -> q;
        endif;
    else
        usage();
    endif;

    lvars answers = ts_eval(body, [[answer ^q]]);
    show(answers('answer'));
    printf(';;; %p, %p tokens in / %p out\n',
           [% ts_last_model, ts_last_usage('input_tokens'),
              ts_last_usage('output_tokens') %]);
enddefine;

main();
sysexit();
