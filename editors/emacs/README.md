# Pop-11 for Emacs

Editing and evaluation support for Pop-11, the core language of Poplog.
`pop11-mode` covers syntax, font-lock, `define`-aware indentation and
motion, and imenu; `inferior-pop11` runs a live Poplog listener in a
comint buffer and gives the editing buffer the VED `ENTER` commands that
drive it. `.pop11` and `.ph` are claimed outright; `.p` is sniffed (see
below).

This is the interactive half of what SLIME gives Common Lisp: one
persistent, natively-compiled session you develop *into*, rather than a
compile-and-restart loop. The deeper half — streamed output, an
interactive mishap handler with a real frame list, a live-image
inspector, `M-.` into procedures you defined at the prompt — needs a
socket server inside the image. That server now exists
(`pop/lib/lib/swank.p`, `HELP * SWANK`); this package does not talk to
it yet, and will in the next phase.

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

Not wired up yet. `pop/lsp/pop11_lsp.p` (launched by `tools/pop11-lsp`)
speaks LSP over stdio and gives real-compiler diagnostics, HELP/REF
hover and dictionary completion; point `eglot` at it by hand:

```elisp
(add-to-list 'eglot-server-programs
             '(pop11-mode . ("/path/to/poplog/tools/pop11-lsp")))
```

Automatic registration lands alongside the socket server, when the
question of which of the two answers a given request has an answer.

## Tests

```sh
emacs -Q --batch -l tools/emacs/test-e2e.el
```

31 tests: syntax, indentation against the real corpus, motion, the `.p`
heuristic, the structural precheck, and a live end-to-end run that
starts a real listener over a pty, sends it a procedure from a source
buffer, calls it, kills it with a mishap and checks that it comes back.
The live test skips itself when no engine can be found.
