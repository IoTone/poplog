# Pop-11 for Neovim

Filetype detection and tree-sitter highlighting for Pop-11 (`.p`,
`.pop11`, `.ph`). `.p` files are content-sniffed so Pascal and Gnuplot
files keep their own filetypes.

## Install

With lazy.nvim, point a plugin spec at this directory of the Poplog
checkout:

```lua
{
  dir = '~/path/to/poplog/editors/nvim',
  name = 'pop11',
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
}
```

then install the grammar (registered automatically from
[IoTone/tree-sitter-pop11](https://github.com/IoTone/tree-sitter-pop11),
pinned to the same commit the Zed extension uses so both editors parse
identically):

```vim
:TSInstall pop11
```

### nvim-treesitter must be the `master` branch

`main` is now what a fresh `git clone` of nvim-treesitter gives you, and
`:TSInstall pop11` fails there with

```
[nvim-treesitter] warning: skipping unsupported language: pop11
```

Not for want of registering: `install.lua` clears
`package.loaded['nvim-treesitter.parsers']` before installing, which throws
away any parser added at run time, so no third-party grammar registered this
way can survive. The plugin registers in both the `master` and `main` formats
already; until that reload changes, pin the branch:

```lua
{ 'nvim-treesitter/nvim-treesitter', branch = 'master' }
```

Verified on Neovim 0.12.5 with nvim-treesitter master: the parser compiles,
and the highlight query returns the expected captures (`@comment` on
`line_comment`, `@keyword` on `define`, `@function` on the definition name).

The `queries/pop11/` directory here is vendored from the grammar repo
(its `queries/` are the source of truth); it rides Neovim's runtimepath
so highlights work as soon as the parser is installed.

## What you get

- filetype + `;;; ` commentstring
- highlighting, folds (`define`/blocks/comments), textobjects
  (`af`/`if` on definitions with nvim-treesitter-textobjects)

LSP wiring (`poplog-lsp`) lands with phase P2 of
`poplog-language-binding-plugins.md`.

## Language server

The checkout also ships a Pop-11 LSP server (`pop/lsp/pop11_lsp.p`, run
via `tools/pop11-lsp`) — diagnostics from the real Poplog compiler
(`pop_syntax_only`, so nothing in your buffer executes), HELP/REF hover,
and dictionary completion. The plugin starts it automatically for
`pop11` buffers when it can find the launcher (this plugin living
inside a poplog checkout). To point at a different tree:

```lua
vim.g.pop11_lsp_cmd = '/path/to/poplog/tools/pop11-lsp'
```

It needs a built engine (`target/pop/basepop11`) resolved the same way
the pop11 skill resolves one: `$POPLOG_ROOT`, then
`~/.cache/pop11-skill/config.json`, then `$usepop`.
