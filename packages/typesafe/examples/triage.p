/* triage.p -- several questions about one thing, in a single call.
 *
 *     TYPESAFE_API_KEY=$(cat ~/.typesafe-key) \
 *         ./poplog basepop11 packages/typesafe/examples/triage.p
 *
 * The CLI asks one question at a time, which is fine for a one-off and
 * wasteful in a loop: the state is re-sent and re-read for every question.
 * The API takes a MAP of questions, so triaging on four axes costs one
 * request and one reading of the text, not four.
 *
 * Point it at your own text by passing a file:
 *     ... triage.p /path/to/message.txt
 */
extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
uses typesafe;

lconstant DEFAULT =
    'Hi -- the nightly export job has failed three times since Friday and '
 <> 'finance are asking where the numbers are. I have not touched the '
 <> 'credentials. Can someone take a look before month end?';

define lconstant slurp(path) -> s;
    lvars dev = sysopen(path, 0, "line");
    lvars rep = line_repeater(dev, inits(4096)), line, acc = '';
    repeat
        rep() -> line;
        quitif(line == termin);
        acc <> line -> acc;
    endrepeat;
    acc -> s;
enddefine;

lvars args = poparglist;
lvars body = if args /== [] then slurp(hd(args)) else DEFAULT endif;

unless ts_api_key then
    printf('set TYPESAFE_API_KEY first\n', []); sysexit();
endunless;

;;; Four axes, one request.  Each question is independent -- they do not
;;; see each other's answers -- so this is parallel classification, not a
;;; chain of reasoning.
lvars answers = ts_eval(body, [
    [urgency   ^(ts_score('How soon does this need a human?',
                          ['whenever' 'this week' 'today' 'right now']))]
    [area      ^(ts_choice('Which team should own this?',
                           [[infra 'pipelines, jobs, servers']
                            [billing 'invoices, finance reporting']
                            [security 'credentials, access, breaches']]))]
    [blocked   ^(ts_noul('Is the sender blocked on someone else?',
                         'they are waiting on another person',
                         'they can proceed alone'))]
    [escalate  ^(ts_noul('Does this mention a deadline?',
                         'a date or deadline is referred to',
                         'no deadline is mentioned'))]
]);

printf('\n%p\n\n', [% body %]);
printf('  urgency  : %p / 3   (confidence %p)\n',
       [% answers('urgency')('score'), answers('urgency')('confidence') %]);
printf('  area     : %p       (confidence %p)\n',
       [% answers('area')('choice'), answers('area')('confidence') %]);
printf('  blocked  : %p\n', [% answers('blocked')('noul') %]);
printf('  deadline : %p\n', [% answers('escalate')('noul') %]);
printf('\n  %p, %p tokens in / %p out -- for four questions\n',
       [% ts_last_model, ts_last_usage('input_tokens'),
          ts_last_usage('output_tokens') %]);
sysexit();
