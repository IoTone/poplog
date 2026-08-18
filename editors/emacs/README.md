# Pop-11 for Emacs

Editing and evaluation support for Pop-11, the core language of Poplog.
`pop11-mode` covers syntax, font-lock, `define`-aware indentation and
motion, and imenu; `inferior-pop11` runs a live Poplog listener in a
comint buffer and gives the editing buffer the VED `ENTER` commands that
drive it. `.pop11` and `.ph` are claimed outright; `.p` is sniffed (see
below).

This is what SLIME gives Common Lisp: one persistent, natively-compiled
session you develop *into*, rather than a compile-and-restart loop.

There are two ways to reach a session, and they are genuinely different.
`M-x run-pop11` opens a **terminal** on a fresh engine — comint, a
prompt, everything it knows it learned by reading text off the wire.
`M-x pop11-swank` opens a **connection to the session itself** over a
socket, and from then on the same editing commands go there instead:

|  | `run-pop11` | `pop11-swank` |
| --- | --- | --- |
| output | when the chunk finishes | *while the code runs* |
| a mishap | a block of text | a backtrace buffer with real frames |
| `M-.` | grep the library | ask the running heap |
| completion | LSP, over text | the live dictionary |
| a runaway loop | `C-c C-c`, hope | `C-c C-a`, which signals the pid |
| inspecting a value | — | `C-c C-i`, and drill in by handle |

Use the terminal when you want to type at Pop-11, the connection when
you want to develop against it. Both can be up at once; the send
commands prefer the connection.

## Install

From a checkout:

```elisp
(add-to-list 'load-path "/path/to/poplog/editors/emacs")
(require 'inferior-pop11)          ; pulls in pop11-mode
```

Or with `use-package` and a release tarball unpacked anywhere:

```elisp
(use-package pop11-mode
  :load-path "~/.emacs.d/pop11-emacs"
  :commands (pop11-mode run-pop11))
```

`M-x run-pop11` starts a listener. Emacs finds Poplog by looking, in
order, at `pop11-root`, `$POPLOG_ROOT`, a Poplog tree enclosing the
current buffer, the checkout this package was loaded from, the root
recorded by the pop11 skill installer in `~/.cache/pop11-skill/config.json`,
and `$usepop`. Editing inside a checkout wins deliberately: a checkout
has the full `pop11` startup image and the sources you are reading.

## The VED commands, on Emacs keys

VED's `ENTER` commands are the reason Poplog development felt live in
1985. They map onto Emacs almost one-for-one, because a marked range is
a region and a "current procedure" is a defun:

| VED | Emacs | What it does |
| --- | --- | --- |
| `ENTER l1` | `C-x C-e` | compile the current line |
| `ENTER lmr` | `C-c C-r` | compile the region — VED's "load marked range" |
| `ENTER lcp` | `C-M-x`, `C-c C-c` | compile the enclosing `define` |
| — | `C-c C-b` | compile the whole buffer, unsaved |
| `ENTER load` | `C-c C-k` | compile the file on disk |
| `ENTER im` | `C-c C-z` | switch to the listener |
| — | `C-c C-t` | toggle `trace` on the word at point |
| `ENTER showlib` | `M-.` | visit a library definition |
| `ENTER help` | `C-c C-d h` | HELP page |
| `ENTER teach` | `C-c C-d t` | TEACH file |
| `ENTER ref` | `C-c C-d r` | REF page |
| — | `C-c C-d d` | documentation for the word at point, any section |

`C-c C-b` and `C-c C-k` differ in a way worth knowing: only the latter
compiles a real file, so only its mishaps carry a filename and line
number.

With a connection there are three more, which have nothing to
correspond to in VED because VED had no notion of a session you could
interrogate from outside:

| Emacs | What it does |
| --- | --- |
| `C-c C-i` | inspect a value; `RET` on a part drills in, `l` goes back |
| `C-c C-s` | describe a name as the *session* has it |
| `C-c C-a` | interrupt a running evaluation |

## The live session

`M-x pop11-swank` starts a server (`tools/pop11-swank`) and connects.
`*pop11-swank*` is then a REPL you can type at — `RET` evaluates, `M-p`
and `M-n` walk the history, `TAB` completes from the live dictionary.

To hand over a session you are **already** using, with everything in it,
start the server from inside that session instead and attach with `M-x
pop11-swank-connect`:

```pop11
uses swank;
swank_serve(4005);
```

That session then belongs to the editor: `swank_serve` blocks, so it
stops being a terminal you can type at. That is the trade, and it is
usually the right one — you get the whole heap you had built up.

Two details are worth knowing because they explain the shape of things.

**Interrupting works by signal, not by message.** Nothing can arrive on
the socket while the session is inside your loop: Pop-11 is
single-threaded and the server is *in* that loop. So `C-c C-a` sends
SIGINT to the pid the handshake handed over, and the engine notices at
the next `I_CHECK` planted in the running code. That check was an empty
stub on arm64 and riscv64 until August 2026, which is why runaway loops
used to be unkillable on those ports.

**`M-.` on something you just compiled works because Emacs remembers,
not because the session knows.** A procedure defined inside a file
leaves no trail back to it — Poplog records `pdprops`, not a source
location. The session can find an *autoloadable* library, where the file
is named after the identifier (VED's `ENTER showlib` relies on the same
thing), and for everything else this package keeps a map of what it
compiled and where it came from.

## The `.p` extension

`.p` is contested — Emacs has no default for it, but the wider world
uses it for Pascal, Gnuplot and OpenEdge. A `.p` file is opened in
`pop11-mode` only when its first 80 lines look like Pop-11 (a `;;;`
comment, a `define ... ;`, an `enddefine`, a leading `vars`/`lvars`, or
`compile_mode`) — the same heuristic the Neovim plugin uses. Otherwise
`pop11-dot-p-fallback-mode` runs, which is `pascal-mode` when available.
Set `pop11-claim-dot-p` to `t` to claim `.p` unconditionally, or `nil`
never to claim it.

Files under `pop/lib/auto`, `pop/lib/lib` and `pop/lib/ved` are claimed
regardless: the Poplog library carries no extension at all.

## Indentation

Deliberately conservative. Pop-11 statements run across lines with no
continuation marker, and the corpus is full of hand-aligned data —
`l_typespec` blocks, section export lists, argument tables. So the rule
is: indent what is structurally understood, and leave a continuation
line exactly where its author put it. Reindenting the first 120 files of
`pop/lib/lib` leaves 65 of them byte-for-byte unchanged and touches 8%
of lines overall, and a second pass over any of them changes nothing.

Two conventions are taken from the tree rather than from the grammar:
`section` bodies are flush-left, and `#_IF`/`#_ELSE`/`#_ENDIF` are left
exactly where they are, because the corpus indents them both ways.

## Why a pty

The inferior process runs on a pty, not a pipe, and that is not
cosmetic. Poplog prints its prompt with a raw `write(2)` on the input
device's own descriptor and gates both prompt and banner on that device
being a terminal (`pop/src/devio.p`). Worse, a mishap chains to
`setpop`, and `setpop_reset` calls `sysexit()` outright when stdin is
not a terminal (`pop/src/setpop_reset.p`) — one typo would end the
session. On a pty the same mishap flushes pending input, prints
`Setpop`, and returns to the prompt.

That input flush is also why code is checked before it is sent: an
unterminated string, comment or bracket would leave the itemiser
mid-token and every later chunk would be read as part of it. An
unfinished `define` is fine and is allowed through — the listener simply
waits for the rest, which is how one builds a procedure interactively.

## Language server

`pop/lsp/pop11_lsp.p` (launched by `tools/pop11-lsp`) speaks LSP over
stdio and gives real-compiler diagnostics, HELP/REF hover and dictionary
completion. It registers itself with Eglot when Eglot loads, resolving
the launcher under the same Poplog root everything else uses — so `M-x
eglot` in a `pop11-mode` buffer just works.

Starting one per project automatically is opt-in:

```elisp
(setq pop11-lsp-autostart t)
```

Override the command with `pop11-lsp-program` if your launcher lives
somewhere unusual.

Which of the two servers answers a given request is not arbitrary. The
LSP server reads your **buffer** — so it works on a file you have not
compiled, and its diagnostics point at text you have not run. The swank
server reads the **session** — so it knows about `sq` that you defined
at the prompt, which is in no file at all. Completion is the clearest
case: with a connection you get both, and the live dictionary is the one
that knows what you just wrote.

## Understanding what it is talking to

`TEACH * SWANK` walks through the session server from the outside in --
connecting by hand, watching output stream, taking a mishap apart,
interrupting a runaway loop, inspecting a live value -- before any
editor is involved. Worth an hour if you want to know what these keys
are actually doing:

```sh
./poplog target/pop/basepop11 -c "teach swank"     # or, in Emacs:
```
`C-c C-d t` and answer `swank`.

## Tests

```sh
emacs -Q --batch -l tools/emacs/test-e2e.el
```

32 tests: syntax, indentation against the real corpus, motion, the `.p`
heuristic, the structural precheck, and two live end-to-end runs. The
first starts a real listener over a pty, sends it a procedure from a
source buffer, calls it, kills it with a mishap and checks that it comes
back. The second starts a real swank server and drives the whole client
against it — eval, streamed output, the source map, completion,
describe, the backtrace buffer, the inspector drilling in and back,
tracing, and interrupting a runaway loop. Both skip themselves when no
engine can be found.
