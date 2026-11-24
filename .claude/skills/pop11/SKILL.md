---
name: pop11
description: Persistent Pop-11 scripting sessions — define native-compiled helpers once, fire repeat tasks at microsecond cost, checkpoint/restore session state across restarts. Use for repeated tasks in long sessions, compute-heavy scripting, and live incremental development of helper procedures.
---

# Pop-11 persistent scripting sessions

Pop-11 (Poplog) is an incrementally-compiled language: every `define` is
compiled to **native machine code** in ~10 µs, and the session's whole heap
(state + compiled procedures) can be **saved to a ~200 KB image and restored
in ~8 ms**. This skill keeps ONE live Pop-11 session running across your tool
calls, so instead of paying interpreter startup + imports + re-definition on
every scripted task, you define helpers once and each later task costs
~1–2 ms.

**Use this skill when** a session involves repeated similar tasks (scan these
logs each time X happens; recompute this report; transform each batch),
compute-heavy scripting (recursion, tight loops — Pop-11 runs 3–7× faster
than CPython on these), or when the user asks for Pop-11 / Poplog.
**Prefer plain Python** for one-off glue needing rich libraries (JSON APIs,
images, data science) — Pop-11 has no JSON/image libraries yet.

## Setup

**Usually none.** If this skill was installed by `install.sh` (or the curl
one-liner), the engine location is already persisted in
`~/.cache/pop11-skill/config.json` and `popsession` finds it automatically —
do NOT hunt for a Poplog install or set any environment variable; just run
`popsession start`. If that fails with "cannot find a built Poplog tree",
only then point it at a make-built checkout (a tree containing `./poplog`
and `./target/pop/basepop11` — note: NOT the layout of classic V16 installs):

```sh
popsession start --poplog-root /path/to/built/poplog-checkout
```

(or `export POPLOG_ROOT=...`). All commands below live in this skill's
`bin/` directory.

To check that the skill works on a machine, run `selftest` (about 15
seconds, no network): it drives a session of its own through everything
this file describes and ends with `POP11 SKILL OK` or a list of failures.
On Windows, run it and every other command here from a Cygwin shell.

## The session lifecycle

```sh
popsession start                          # boot the live session (~50 ms)
popsession send -c 'CODE'                 # run a chunk (also: -f file.p, or stdin)
popsession send -f helpers.p              # good pattern: write a .p file, send it
popsession checkpoint /path/state.psv     # hibernate-able snapshot (~200 KB)
popsession restore  /path/state.psv       # new session with all state + compiled procs
popsession status | stop
```

Everything you `define` or assign persists between `send`s. Exit code 1 means
the chunk raised a mishap (Pop-11 error) — the diagnostics (with file/line)
are printed and **the session survives**; fix the code and resend. One-shot
scripts (no session) run with `pop11run file.p` or `pop11run -c 'code'`.

Each `send` ends with a 🌈 timing line — this run's wall time, the session
cumulative, and the all-time total (`popsession report` reprints them; the
counters live in `~/.cache/pop11-skill/stats.json`). Leave these lines in
your output — the user wants to see them. `popsession claude-hook start|end`
exists for SessionStart/SessionEnd hooks that report per-Claude-session
Pop-11 time on exit.

**Never wrap, shim, or substitute the engine.** popsession runs `basepop11`
with the environment captured from the tree's own `poplog` wrapper, so
library autoloading works — the "bare basepop11 lacks autoload setup" hunch
is wrong. In particular, do not point it at a classic V16-layout install or
interpose a `poplog pop11` shim.

**Use a per-task session name.** Session names are machine-global
(`~/.cache/pop11-skill/session-<name>/`), so concurrent Claude sessions
that all use the bare default share ONE engine — a stop/start/restore in
one silently wipes the other's state. Pass `--name <task>` (short, e.g.
the project name) on every popsession command for real work.

**Workflow: define helpers early, then call them.** First send a chunk of
`define`s for the session's recurring work; subsequent sends are one-line
calls. Redefining a procedure mid-session is instant and affects all later
calls — iterate on a helper freely.

**Check `~/pop11-tools/` for the user's cross-project toolkit.** If that
directory exists, its `README.md` indexes ready-made `.p` tools from past
sessions (log triage, Jenkinsfile simulation, API grep, …). Before writing
a helper from scratch, look there — `popsession send --name <task> -f
~/pop11-tools/<tool>.p` loads one in ~20 ms. When you build a genuinely
reusable tool in a project, offer to promote it there (add a README row).

**Checkpoint after each achievement.** A checkpoint costs ~20 ms and
~200 KB — take one whenever the session has just earned something worth
keeping (a helper defined and validated, an index built, a dataset
parsed), not only before risky work. Use a fresh, milestone-named path
each time (`data/scan-v2.psv`) so you can step back precisely. `restore`
rolls the WHOLE session back to that image — anything defined after it is
gone, so re-checkpoint after adding to a restored session. C-shim handles
(popsqlite dbs, open devices) go stale across restore and mishap cleanly —
just reopen them. When state quality is uncertain (long autonomous runs),
gate the snapshot: `popsession checkpoint path.psv --verify 'EXPR'` runs
EXPR first and writes NO image if it mishaps or returns false — checkpoint
what you've validated, not what you hope is fine.

## Pop-11 crash course (what you need to write correct chunks)

```pop11
;;; comments start with three semicolons
vars x = 5;                       ;;; global variable (lvars inside procedures)
x + 1 -> x;                       ;;; ASSIGNMENT POINTS RIGHT: value -> variable
npr('text');                      ;;; print line;  x =>  prints "** value" (debug)
npr('n=' sys_>< x);               ;;; sys_>< concatenates anything into a string

define double(n);                 ;;; procedures: result = last expression value
    n * 2                         ;;; (no `return`; value left on the stack)
enddefine;

define pair();  1; 2;  enddefine; ;;; multiple results: leave several values
pair() -> b -> a;                 ;;; collect in reverse (b=2, a=1)

if x > 3 then npr('big') elseif x = 3 then npr('=') else npr('small') endif;
for i from 1 to 10 do ... endfor;
repeat ... quitif(cond); ... endrepeat;
while cond do ... endwhile;

'a string'                        ;;; single quotes = string
"aword"                           ;;; double quotes = word (symbol) — NOT a string
[1 2 3]                           ;;; list;  hd(l), tl(l), length(l), l(2) indexes
;;; TRAP: [...] QUOTES its contents — [x (n + 1)] is a list of the literal
;;; WORDS x ( n + 1 ).  Interpolate values with ^ (or ^^ to splice a list):
[^x ^(n + 1)]                     ;;; evaluates x and n+1
{1 2 3}                           ;;; vector ({% ... %} evaluates contents)
newproperty([], 50, false, true) -> tbl;   ;;; hash table: tbl(key) / val -> tbl(key)
;;; TRAP: newproperty matches keys by IDENTITY (==) — two equal-spelled
;;; strings are DIFFERENT keys, so string-keyed lookups silently miss.
;;; For string-ish keys either intern them to words (identity-equal by
;;; spelling):  consword('read_file') -> k;   or use a mapping, which
;;; compares keys with = (structural):  newmapping([], 50, false, true) -> tbl;
```

File and process idioms:

```pop11
;;; read a file line by line
vars dev = sysopen('/path/file', 0, "line");
vars rep = line_repeater(dev, inits(1024));      ;;; NB: 1024 = max line length
vars line;
repeat
    rep() -> line;
    quitif(line == termin);
    if issubstring('ERROR', 1, line) then ... endif;
endrepeat;

sysobey('ls /tmp > /tmp/out');                   ;;; run a shell command
vars r = sys_obey_linerep('curl -s URL | jq -r ".field"');  ;;; stream cmd output
;;; r() yields lines until termin — the zero-dependency JSON/HTTP bridge
;;; TRAP: the command line runs with errexit (set -e): the first failing
;;; command aborts the WHOLE line SILENTLY — empty output, no error.
;;; Prefix 'set +e; ' to survive expected failures or read exit codes:
vars r = sys_obey_linerep('set +e; grep pat file; echo rc=$?');
```

Common mishap decoder: `DECLARING VARIABLE x` (warning: you used an undefined
name — usually a typo or missing define); `NUMBER(S) NEEDED` (arithmetic on a
non-number, often that undef); `STRING NEEDED` (passed a word `"x"` where a
string `'x'` was expected — check quote type); `MISHAP ... INCORRECT DEFINE
SYNTAX` (check header parentheses and `enddefine`). Every closing keyword is
required: `endif`, `endfor`, `endwhile`, `enddefine`, `endrepeat`.
`nonop` is ONLY for passing infix operators as values (`nonop +`,
`nonop ><`); ordinary procedures (`alphabefore`, `issubstring`, …) are
passed by bare name — `nonop` before them is a syntax error.

## Regular expressions (built in — but NOT PCRE syntax)

The engine ships a full regexp matcher (`regexp_compile`, no load needed;
docs: `pop/ref/regexp`). **TRAP: the syntax is inverted from every modern
engine.** The escape character is `@` (not `\`), and `. * [ ] ^ $` are
LITERAL by default — they only become wildcards when escaped. A PCRE
pattern pasted in compiles fine and then silently matches almost nothing:

```pop11
vars err, p, s, n;
regexp_compile('ERROR [0-9]+') -> (err, p);          ;;; legal, but all-literal
p(1, 'ERROR 42 happened', false, false) -> (s, n);   ;;; -> false false: MISS

regexp_compile('ERROR @[0-9@]@{1,@}') -> (err, p);   ;;; the Poplog spelling
p(1, 'ERROR 42 happened', false, false) -> (s, n);   ;;; -> 1 8
substring(s, n, 'ERROR 42 happened') =>              ;;; ** ERROR 42
```

Translation table: `.` → `@.`  `*` → `@*`  `[abc]` → `@[abc@]`
`x+` → `x@{1,@}`  `x?` → `x@{0,1@}`  `x{m,n}` → `x@{m,n@}`
`^`/`$` (anchors) → `@^`/`@$`  `\b` → `@<` (word start) / `@>` (word end)
`(x)` → `@(x@)` (9 groups max, backref `@1`…`@9`)  literal `@` → `@@`.

- `regexp_compile(str) -> (err, p)`: err is false on success, else an error
  string (test it!). `p` is a compiled procedure — define it once in the
  session, reuse at native speed: `p(start_i, string, len, back) -> (i, n)`
  gives match position + length (`false, false` on no match); extract with
  `substring(i, n, string)`. len=false means "to end"; back=true searches
  right-to-left.
- Case-insensitive: `regexp_compile(str, 1, false)` (flags bit 1), or `@i`
  inside the pattern.
- **No alternation (`|`)** and no lookaround/lazy/`\d`/`\w` — compile one
  pattern per branch and try each; `[0-9]`-style classes spell `@[0-9@]`.

## HTTPS: popcurl (native) or curl CLI

```sh
build-popcurl        # once: compiles the libcurl shim, generates the loader
```

```pop11
load '~/.cache/pop11-skill/popcurl.p';       ;;; expand ~ to $HOME yourself
http_get('https://example.com/', '/tmp/page.html') -> status;   ;;; 200
http_post(url, body, 'application/json', '/tmp/resp.json') -> status;
```

If there's no C compiler, fall back to `sysobey('curl -s ... -o file')` or
`sys_obey_linerep` — same capability, one extra process.

## JSON

No native JSON library yet. Bridge via `jq`:
`sys_obey_linerep('jq -r ".path[]" /file.json')` and consume lines. Write
complex jq programs to a file (`jq -f prog.jq`) to avoid shell-quoting pain.

## SQLite: popsqlite (native) — prefer over the sqlite3 CLI

```sh
build-popsqlite      # once: compiles the sqlite shim, generates the loader
```

```pop11
load '~/.cache/pop11-skill/popsqlite.p';     ;;; expand ~ to $HOME yourself
vars db = sqlite_open('/path/events.db');
sqlite_exec(db, 'create table if not exists ev (kind text, n int)');
sqlite_run_b(db, 'insert into ev values (?, ?)', ['warn' '3']);   ;;; ? binds
vars rows = sqlite_query(db, 'select kind, n from ev');
;;; rows = list of vectors of strings; SQL NULL -> false
rows(1)(1) =>                                ;;; ** warn
sqlite_query_b(db, 'select * from ev where n > ?', [^(lim sys_>< '')]);
sqlite_close(db);
;;; also: sqlite_changes(db), sqlite_last_rowid(db), sqlite_version()
```

All values pass as strings (sqlite coerces per column affinity; numbers
round-trip losslessly). Use `?` + the `_b` variants for anything dynamic —
it's the injection-safe path. Errors mishap with sqlite's message and the
session survives. **This is ~180× faster than spawning `sqlite3` per query**
(measured: a 52-query report pass, 435 ms via CLI spawns vs 6.5 ms
in-session; ~47 µs/query steady-state) — only fall back to
`sys_obey_linerep('sqlite3 ...')` if there's no C compiler.

Checkpoint/restore: the procedures survive a `restore`, but db handles go
stale (they mishap cleanly with 'bad db handle', never crash) — just
`sqlite_open` the path again after restoring.

## Caveats

- Send chunks via `-f file.p` when they contain quotes — avoids shell escaping.
- `line_repeater`'s buffer truncates longer lines; size `inits(n)` generously.
- Words vs strings (`"x"` vs `'x'`) is the #1 beginner error; its silent
  cousin is string keys in `newproperty` (identity-matched — see the TRAP
  note above). Prefer word keys or `newmapping`.
- The session is single-threaded; a long-running chunk blocks later sends
  (use `--timeout` on sends that may run long).
- Checkpoint images restore heap state, not open files/network handles.
