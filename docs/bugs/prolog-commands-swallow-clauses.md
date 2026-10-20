# Prolog command words swallow clauses in a consulted file

Found 2026-10-19 while building a language knowledge graph
(`examples/langpop/`): a graph file holding a `source/2` relation for
per-fact provenance failed to load, with an error naming a predicate
nobody had written.  **Fixed** 2026-10-19 (see "Fix" below); verified from
both the compile-from-source path and a rebuilt `prolog.psv`.
Pre-existing — this is 1993 code, unchanged in the fork until now.

## Symptom

A Prolog data file contains an ordinary fact whose functor happens to be
`help`:

    ok(1).
    help(a).
    ok(2).

Consulting it does not define `help/1`.  It tries to open a Poplog HELP
file:

    ;;; HELP (A). not found - try HELP HELPFILES
    ;;; FILE     :  .../w.pl
    ;;;   LINE NUMBER:  3
    ;;; PRINT DOING
    ;;; DOING    :  popvedcommand prolog_load prolog_syscompile trycompile

The load then continues, so `ok/1` gets both clauses and the file appears
to have worked.  Nothing says a clause was eaten.  With `source/2` the
message is stranger still, because the arguments are read as the command's
argument text:

    ;;; MISHAP - No such predicate: (ladder(ja),jlpt_faq(no content list ...)).

which names a goal the file does not contain, and sends you looking for a
missing predicate rather than a swallowed clause.

## The words

Twelve, from `prolog_command` in `pop/plog/src/commands.p`:

    ved  help  teach  ref  showlib  im  source  cd  pwd  pop11  bye

plus the escape character.  Seven are Ved editor commands, which is the
point: these are an interactive convenience for someone sitting at the
`?-` prompt, not syntax.  But `help`, `source`, `ref`, `cd` and `im` are
all plausible relation names — `help/1` especially so for anything that
teaches, which is how this was found.

## Cause

`Readterm` in `pop/plog/src/parse.p` consults the command table on every
term it reads:

    if testdef prolog_read_command and weakref prolog_read_command() ->> cmd
    then
        return(cmd);
    endif;

`prolog_read_command` reads one name, looks it up in `prolog_command`, and
if it hits, runs the command and returns — the term is never parsed as a
clause.  That is correct at the top level and wrong while reading a file,
and `Readterm` cannot tell the two apart.

Three callers already knew this and switched the hook off locally:
`prolog_read/0` and `read/1` in `pop/plog/src/iopreds.p`, and
`prolog_readterm/0` in `parse.p` ("ignore commands").  The file compiler
was simply never given the same treatment.

## Fix

`pop/plog/src/prolog_compile.p`, in `prolog_syscompile`, which already
receives the mode it was called with:

    unless mode == "query" then
        dlocal weakref prolog_read_command = #_< identfn(%false%) >_#;
    endunless;

`prolog_toplevel_compile` passes `"query"` — that is the interactive top
level, where the commands belong and still work.  `prolog_compile` passes
`default_compile_mode` (`consult`/`reconsult`), which is every file, every
`?- ['file.pl'].`, and every `prolog_compile(stringin(...))` from Pop-11.

Nothing shipped relies on the old behaviour: no `.pl` or `.tch` file under
`pop/` or `examples/` has a top-level command in it.

## Verifying

    tools/test-libs.sh tools/tests/test_prolog_consult.p

The suite consults a file whose clause heads are five of the command words
and asserts that each predicate exists with the right argument, and that a
normal predicate on either side of them keeps both its clauses.

Interactively, the commands must still work, and do:

    $ ./poplog basepop11 -target/psv/prolog.psv
    pwd
    /Users/dkords/dev/projects/iotone/poplog
    ?- ['/tmp/w.pl'].
    /tmp/w.pl consulted
    yes
    ?- help(X).
    X = a

A source rebuild is enough for anything that does `uses prolog`, because
that compiles `pop/plog/src/` at run time.  The saved image needs

    make stamp_plog

## What got this past the tests

There were no tests for the Prolog subsystem at all — `tools/tests/`
covered the libraries this fork added and the engine defects it found, and
Prolog was inherited as working. `test_prolog_consult.p` is the first, and
it is deliberately about the compiler's contract (what a consulted file
means) rather than about Prolog the language, which upstream tested in
1993 and which this fork has no reason to doubt.
