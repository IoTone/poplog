# Pop-11 for VS Code

Syntax highlighting and editing basics for Pop-11 (Poplog) — `.p`,
`.pop11` and `.ph` files.

The TextMate grammar covers the same stable core as
[IoTone/tree-sitter-pop11](https://github.com/IoTone/tree-sitter-pop11)
(comments including nested `/* */`, all string/word/character literal
forms, radix numbers, `define` headers with the name scoped as a
function, the block syntax-word set, sections, `#_` directives), kept
intentionally simpler; the tree-sitter grammar is the source of truth
when they disagree.

Note `.p` is also used by Pascal: VS Code applies this language via the
`firstLine` heuristic, or pick "Pop-11" manually / add a workspace
`files.associations` entry.

## Install

Prebuilt: download `pop11-vscode-<v>.vsix` from the
[releases](https://github.com/IoTone/poplog/releases), then either
`code --install-extension pop11-vscode-<v>.vsix` or the
"Extensions: Install from VSIX…" command.

From a checkout: `tools/package-editors.sh` builds the same artifact
into `dist/`.

LSP integration (`poplog-lsp`), run-buffer commands and a REPL terminal
land with phase P2 of `poplog-language-binding-plugins.md`; Marketplace
and OpenVSX publication with P3.
