# Poplog language bindings: editor plugins for Neovim, Zed, and VS Code

**Status: design proposal (2026-08).**  Goal: modern editor support for
Pop-11 — syntax highlighting, completion, docs-on-hover, diagnostics —
delivered to Neovim, Zed, and VS Code from a shared foundation, so each
editor gets a thin client instead of three parallel implementations.

Related: roadmap items 1.2 (editor support) and 1.3 (Jupyter kernel);
`TEACH JSON` (the library pattern the server reuses); the pop11 skill's
`popsession` runtime (the execution backend).

## 1. Goals and non-goals

Goals (v1):

* Syntax highlighting for Pop-11 in every supported editor, and on GitHub.
* Completion (identifiers, library names), hover documentation drawn
  from the real HELP/REF/TEACH corpus, document outline, and
  compile-check diagnostics.
* One place to fix bugs: a single grammar and a single language server.
* `.p` filetype detection that coexists with Pascal/Prolog defaults.

Non-goals (v1):

* The other subsystem languages (Prolog, Lisp, ML, Forth files) — the
  architecture leaves room, but v1 is Pop-11 only.
* Semantic rename/refactoring, debugger integration (DAP), formatting.
* Replacing ved.  This meets users in their editors; ved remains the
  in-system environment.

## 2. Architecture: one grammar, one server, three thin clients

```
                 tree-sitter-pop11          poplog-lsp
                 (standalone repo)          (in-tree, written in Pop-11)
                    |       |                   |
       +------------+       +-----+             |
       |                          |             |
   Neovim                        Zed         all three editors
   (nvim-treesitter          (native            (LSP client)
    + built-in LSP)           tree-sitter
                              + LSP config)
   VS Code: TextMate grammar (derived subset) + LSP client extension
```

Two build-once components:

* **`tree-sitter-pop11`** — the parser/highlighting grammar.  Neovim
  and Zed consume tree-sitter natively.  GitHub syntax highlighting
  (linguist) also requires a standalone tree-sitter grammar repo, so
  this one component covers three surfaces.
* **`poplog-lsp`** — a Language Server Protocol server **written in
  Pop-11**, running on the Poplog engine itself.  Every editor
  speak LSP; each needs only launch-and-attach glue.

VS Code is the one editor that does not consume tree-sitter for
highlighting; it gets a hand-maintained TextMate grammar covering the
same scopes (section 5.3).

## 3. Component A: `tree-sitter-pop11`

**Repo:** `github.com/IoTone/tree-sitter-pop11` (standalone — required
by both linguist and Zed's grammar loading; the main repo references it
by revision).

### Scope — parse the stable core

Pop-11's surface syntax is unusually regular in exactly the way
tree-sitter likes: every opener has a matching `end…` closer
(`define/enddefine`, `if/endif`, `for/endfor`, `procedure/endprocedure`,
`section/endsection`, …).  The v1 grammar covers:

* Comments: `;;; …` line comments and `/* … */` (nesting).
* Literals: strings `'…'` with escapes, words `"w"`, character codes
  `` `c` ``, numbers incl. radix (`16:FF`), decimals, exponents.
* Declarations: `define` headers (name, args, `-> result`, updaterdef),
  `vars`/`lvars`/`dlocal`/`constant`/`lconstant` statements, `uses`.
* The closed set of core syntax words and their block structure.
* Lists/vectors: `[ … ]`, `{ … }`, `[% … %]`, pattern elements
  (`?x`, `??x`, `=`), section pathnames (`$-json$-foo`).
* Compile-time directives: `#_IF` / `#_ELSE` / `#_ENDIF` /
  `#_TERMIN_IF` (parsed as directives, condition as expression).

**The known hard problem: user-extensible syntax.**  Pop-11 code can
define new syntax words at compile time, so no static grammar is
complete.  Strategy: parse the core faithfully and let unknown
constructs degrade to generic expression/identifier nodes — tree-sitter
recovers well, and highlighting a novel syntax word as "identifier" is
acceptable.  This is the same trade-off every extensible language
(Racket, Forth) accepts in editors.

### Deliverables in the grammar repo

* `grammar.js`, generated parser, and corpus tests built from real
  tree files (`pop/lib/lib/json.p` and `pop/forth/src/forth.p` are
  good stress cases — both are modern, idiomatic, and heavy on
  distinct constructs).
* Query files consumed by editors: `highlights.scm`, `indents.scm`,
  `folds.scm` (`define…enddefine`, section blocks), `injections.scm`
  (reserved for future embedded-language handling), `textobjects.scm`
  (function/parameter objects for Neovim).

### Filetype detection — the `.p` collision

`.p` is claimed by Pascal (Vim's default), and by Gnuplot/OpenEdge in
GitHub's linguist heuristics.  Plan:

* Content heuristics, in every client and in a linguist PR: a file is
  Pop-11 if it matches any of `;;;`, `^\s*define\b.*;`, `enddefine`,
  `^\s*(l)?vars\b`, `compile_mode`.  These are near-unambiguous
  against Pascal and Gnuplot.
* Additionally register unambiguous extensions going forward: `.p` stays
  primary (the corpus uses it), but the tooling also recognises `.pop11`
  for greenfield code that wants zero ambiguity.
* Linguist PR adds Pop-11 as a language (color, grammar pointer,
  heuristics) — this is what turns GitHub's rendering of the whole
  repository from plain text into code.

## 4. Component B: `poplog-lsp` — the server, in Pop-11

Writing the server in Pop-11 is both the practical and the strategic
choice: practical because the pieces exist (below), strategic because
"Poplog's language server is a Poplog program" is the dogfooding proof
that the system does modern work.

### What it stands on (all in-tree today)

| Need | Already exists |
| --- | --- |
| JSON parse/generate | `lib json` (2026-08, 43-case suite) |
| stdio byte I/O for `Content-Length` framing | `charin`/`charout` and raw device I/O |
| Documentation corpus for hover | HELP/REF/TEACH files + `vedhelplist`/`vedreflist` search-list machinery |
| Identifier inventory for completion | doc indexes, `popautolist`/`popuseslist` contents, `sys_file_match` |
| Compile-check for diagnostics | the incremental compiler; mishap trapping via the `prmishap`/`exitto` pattern (proven in the test suites) |
| Crash-safe long-running process | `dlocal` + mishap traps (popsession has run this pattern in production) |
| Fast startup | saved images — build `lsp.psv` once, restore in milliseconds |

### Capability roadmap

**v0.1 — read-only intelligence**

* `initialize`, full-document sync, shutdown.
* `textDocument/documentSymbol`: scan for `define` headers and
  `section` boundaries — gives outline + breadcrumbs in all editors.
* `textDocument/completion`: identifier dictionary built at startup
  from the doc indexes plus autoloadable/`uses` library names;
  document-local `define`/`vars` names added incrementally.
* `textDocument/hover`: **the flagship**.  Resolve the word under the
  cursor through the HELP → REF → TEACH search lists and render the
  matching entry.  Forty years of documentation appears under the
  cursor in a modern editor; no other step in this design produces as
  much wow per line of code.

**v0.2 — feedback**

* `textDocument/publishDiagnostics`: on save (then on change,
  debounced), compile the buffer in a scratch process with the mishap
  trap; report mishap message + position.  The compiler's positions are
  byte offsets — the server maps them to LSP line/character.
* `textDocument/definition`: document-local defines first; then
  library resolution through `popuseslist`/`popautolist` (jump into
  `pop/lib/...` sources).

**v0.3 — polish**

* Workspace symbols (whole-tree define index), signature help mined
  from REF entries, semantic tokens for the cases the static grammar
  cannot know (user syntax words the compiler has actually loaded).

### Packaging

* Source lives in-tree at `pop/lsp/` (mirroring `pop/forth/` subsystem
  layout), with `tools/poplog-lsp` as the launcher script (engine
  discovery copied from the skill's `install.sh`; `setarch -R` handling
  on riscv64 as in the test suites).
* `make lsp.psv` builds the saved image; the launcher restores it for
  instant startup.  Release tarballs (the skill-tarball packager
  generalises) ship engine + image so editors can point at one binary
  path with no build step.

## 5. Component C: the editor clients

### 5.1 Neovim

Thinnest possible plugin, `editors/nvim/` in the main repo, plus
upstream PRs:

* **Highlighting:** upstream `tree-sitter-pop11` + its queries to
  `nvim-treesitter`.  Until merged, the plugin registers the grammar
  locally (`parser_config.pop11`).
* **Filetype:** `ftdetect` Lua using `vim.filetype.add` with a
  content-heuristic fallback for `.p` (heuristics from section 3).
* **LSP:** an `lspconfig` registration (`poplog_lsp`) pointing at
  `tools/poplog-lsp`; completion then works through the built-in LSP
  client and any completion frontend (nvim-cmp, blink).  Upstream the
  config to `nvim-lspconfig` once the server is stable.
* **Optional REPL niceties:** `:PopRun` (send buffer/region to a
  `popsession` terminal split), `K` already covered by LSP hover.

### 5.2 Zed

The thinnest client of all — Zed extensions are declarative
(`extension.toml` + optional WASM) and consume tree-sitter grammars
natively:

* `editors/zed/` holds the extension: language declaration (name,
  `.p`/`.pop11` + first-line heuristics, comment/bracket config),
  grammar reference pinned to a `tree-sitter-pop11` revision, and the
  LSP launch command (`tools/poplog-lsp`).
* Publish to the Zed extension registry (their process is a PR to
  `zed-industries/extensions`).

### 5.3 VS Code

* `editors/vscode/` — a standard extension:
  * **TextMate grammar** (`pop11.tmLanguage.json`): hand-maintained,
    scoped to the same core as the tree-sitter grammar (comments,
    strings, numbers, `define` headers, syntax keywords, sections).
    Kept intentionally simpler than tree-sitter; a scope-coverage test
    over the same corpus files keeps the two from drifting.
  * `language-configuration.json`: `;;;` line comments, `/* */`
    blocks, bracket pairs incl. `[% %]`, auto-closing, indent rules
    for `define`/`end…` pairs.
  * **LSP client** (TypeScript, `vscode-languageclient`) launching
    `tools/poplog-lsp`, with a setting for the Poplog root.
  * Commands: "Pop-11: Run buffer", "Pop-11: Open REPL" (integrated
    terminal running `popsession`).
* Publish under an IoTone publisher ID on the Marketplace and OpenVSX
  (the latter covers Cursor/VSCodium users).
* Later tie-in: the Jupyter kernel (roadmap 1.3) makes `.ipynb`
  Pop-11 notebooks work inside VS Code with zero extra effort here.

### 5.4 Emacs

* `editors/emacs/` — two files, no build step:
  * `pop11-mode.el`: syntax table plus a `syntax-propertize-function`
    for the two constructs a table cannot express — `;;;` (a
    three-character comment opener, where a lone `;` is the statement
    separator) and the quote character literal `` `'` `` (which would
    otherwise open a string and swallow the line). Font-lock,
    `define`-aware indentation and motion, imenu, and the same `.p`
    content heuristic as §3.
  * `inferior-pop11.el`: a comint REPL on a **pty** — mandatory, not
    cosmetic, since Poplog prints no prompt on a pipe and
    `setpop_reset` calls `sysexit()` when a mishap arrives with stdin
    not a terminal. Plus the VED `ENTER` command set on Emacs keys
    (`l1`/`lmr`/`lcp`/`load`/`im`/`showlib`/`help`/`teach`/`ref`), a
    structural precheck before anything reaches the itemiser, and
    HELP/TEACH/REF lookup straight out of the tree.
  * `pop11-swank.el`: a client for `pop/lib/lib/swank.p` (LIB * SWANK),
    which serves a live session over TCP on the same LIB * JSONRPC
    transport as the other two servers. With a connection the send
    commands go to the session rather than to a terminal: output
    streams as the code runs, a mishap opens a backtrace buffer with
    real frames, `C-c C-i` inspects a value and drills in by handle,
    `M-.` and completion read the running heap, and `C-c C-a`
    interrupts by signalling the pid from the handshake.
* Not yet wired: `eglot` registration for `tools/pop11-lsp` (documented
  as a two-line manual recipe meanwhile).
* Tests: `emacs -Q --batch -l tools/emacs/test-e2e.el` — 31 ERT tests
  including a live listener driven over a pty.

## 6. Repository layout

```
IoTone/tree-sitter-pop11        (new, standalone — linguist/Zed requirement)
IoTone/poplog                   (this repo)
  pop/lsp/                      LSP server source (Pop-11)
  tools/poplog-lsp              launcher (engine discovery, setarch -R)
  editors/nvim/                 ftdetect + parser registration + lspconfig
  editors/zed/                  extension.toml + language config
  editors/vscode/               TextMate grammar + LSP client extension
  editors/emacs/                major mode + comint REPL (VED ENTER keys)
```

Everything except the grammar lives in the main tree so server and
clients version together with the engine.

## 7. Phasing

| Phase | Contents | Effort |
| --- | --- | --- |
| **P1** | tree-sitter grammar core + corpus tests; Neovim highlighting + ftdetect; VS Code TextMate grammar + language config (no LSP yet) — **shipped 2026-08**: [tree-sitter-pop11](https://github.com/IoTone/tree-sitter-pop11) (95.2 % clean parse over the full 1,805-file tree), `editors/nvim/` (heuristic ftdetect, parser registration, vendored queries), `editors/vscode/` (TextMate grammar + language config) | 1–2 weeks |
| **P2** | poplog-lsp v0.1 (symbols, completion, hover); wire the clients; Zed extension | 2–3 weeks |
| **P3** | Diagnostics + definition (v0.2); linguist PR; Marketplace/OpenVSX/Zed-registry/nvim upstream submissions; saved-image packaging | ~2 weeks |

P1 alone already changes how the project reads on GitHub and in
editors; each phase ships value on its own.

## 8. Open questions

1. **`.pop11` extension**: adopt as the recommended greenfield
   extension alongside `.p`, or keep `.p` only and rely on heuristics?
2. **Publisher accounts**: Marketplace/OpenVSX/Zed registry need an
   IoTone org identity — who owns these?
3. **LSP distribution**: is "requires a built Poplog tree" acceptable
   for v1, or should the P3 tarball (engine + `lsp.psv`) gate the
   marketplace submissions?
4. **Other subsystems**: when Prolog/Lisp/ML files enter scope, do they
   get their own grammars or injection into this one?  (Design leans:
   own grammars, shared server.)
```

## Appendix: calling Pop-11 from C/C++ today

(Context for the embedding question that prompted this doc.)

* **C/C++ calling into Pop-11 — supported now**, when Poplog owns the
  process: `exfunc_export` wraps any Pop-11 procedure as a genuine C
  function pointer that external code can call (live in-tree example:
  `pop/x/pop/lib/fast_xt_action.p`, which hands Pop-11 procedures to
  the Xt widget toolkit as C callbacks).  The C-side API is
  `pop/extern/lib/callback.h` + `c_callback.c`, documented in
  `REF EXTERNAL` ("External Callback").
* **C/C++ as the main program embedding Poplog (`libpoplog`) — not yet**:
  Poplog must currently be the process host.  That gap is roadmap item
  3.4 and is untouched by this document.
