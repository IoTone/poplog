-- Pop-11 filetype detection + tree-sitter grammar registration.
--
-- `.p` is contested (Vim defaults it to Pascal; linguist adds Gnuplot and
-- OpenEdge), so `.p` files are sniffed with the content heuristics from
-- poplog-language-binding-plugins.md §3 — near-unambiguous against both.
-- `.pop11` and `.ph` are claimed outright.

local function looks_like_pop11(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 80, false)
  for _, line in ipairs(lines) do
    if line:find(';;;', 1, true)
      or line:match('^%s*define%f[%W].*;')
      or line:find('enddefine', 1, true)
      or line:match('^%s*l?vars%f[%W]')
      or line:find('compile_mode', 1, true)
    then
      return true
    end
  end
  return false
end

-- `.pop11` and `.ph` are ours outright.
vim.filetype.add {
  extension = {
    pop11 = 'pop11',
    ph = 'pop11',
  },
}

-- `.p` is NOT claimed through vim.filetype.add.  An extension function
-- there that returns nil does not fall through to Neovim's own detection,
-- whatever one might hope: it means "no filetype at all", so registering
-- one broke Pascal.  Measured -- stock Neovim calls a Pascal .p `pascal`,
-- and with the extension function it came out empty.
--
-- Instead let Neovim detect first and only UPGRADE when the content is
-- recognisably Pop-11.  Pascal and Progress files keep the filetype
-- Neovim gave them; a .p that Neovim could not place is still considered.
vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
  pattern = '*.p',
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    -- never override a filetype the user set deliberately
    if ft == 'pop11' then return end
    if looks_like_pop11(args.buf) then
      vim.bo[args.buf].filetype = 'pop11'
    end
  end,
})

-- Register the grammar with nvim-treesitter until it is upstreamed.
-- After this loads:  :TSInstall pop11
--
-- nvim-treesitter has two incompatible APIs in the wild and `main` is now
-- the default branch you get from a fresh clone:
--
--   master  parsers.get_parser_configs()[lang] = { install_info = {url, files, branch} }
--   main    parsers[lang]                      = { install_info = {url, revision}, tier }
--
-- Registering only the master form meant `:TSInstall pop11` answered
-- "skipping unsupported language: pop11" on a current install -- and the
-- pcall guard hid it, so it failed silently rather than complaining.
local GRAMMAR_URL = 'https://github.com/IoTone/tree-sitter-pop11'
-- same commit the Zed extension pins, so both editors parse identically
local GRAMMAR_REV = 'cc2666a0d3162031dc63e634c3bf45afd00ee890'

local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
if ok and type(parsers) == 'table' then
  if type(parsers.get_parser_configs) == 'function' then
    local cfg = parsers.get_parser_configs()
    if not cfg.pop11 then
      cfg.pop11 = {
        install_info = {
          url = GRAMMAR_URL,
          files = { 'src/parser.c', 'src/scanner.c' },
          branch = 'main',
          -- pinned, like the Zed extension: an unpinned branch means two
          -- editors can end up parsing with different grammars, and the
          -- queries are only guaranteed against this one
          revision = GRAMMAR_REV,
        },
        filetype = 'pop11',
        maintainers = { '@IoTone' },
      }
    end
  elseif not parsers.pop11 then
    -- nvim-treesitter `main`.  This registration is correct but does not
    -- survive: install.lua clears package.loaded['nvim-treesitter.parsers']
    -- before installing, which discards anything registered at run time,
    -- so `:TSInstall pop11` still reports "skipping unsupported language".
    -- Left in place because it costs nothing and becomes correct the day
    -- that reload stops happening; use the master branch until then.
    parsers.pop11 = {
      install_info = { url = GRAMMAR_URL, revision = GRAMMAR_REV },
      tier = 2,
    }
  end
end

-- Comment string for commenting plugins / 'gc'
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'pop11',
  callback = function()
    vim.bo.commentstring = ';;; %s'
  end,
})

-- Language server: pop/lsp/pop11_lsp.p via tools/pop11-lsp.
-- Diagnostics (real compiler, pop_syntax_only so nothing executes),
-- HELP/REF hover, dictionary completion.  Started automatically when
-- the launcher can be found: set g:pop11_lsp_cmd, or rely on the
-- launcher living two directories above this plugin (a poplog checkout).
local function lsp_cmd()
  if vim.g.pop11_lsp_cmd then
    return { vim.g.pop11_lsp_cmd }
  end
  local here = debug.getinfo(1, 'S').source:sub(2)
  local launcher = vim.fn.fnamemodify(here, ':h:h:h:h') .. '/tools/pop11-lsp'
  if vim.fn.executable(launcher) == 1 then
    return { launcher }
  end
  return nil
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'pop11',
  callback = function(args)
    local cmd = lsp_cmd()
    if not cmd then return end
    vim.lsp.start {
      name = 'pop11',
      cmd = cmd,
      root_dir = vim.fs.root(args.buf, { '.git', 'poplog' }) or vim.fn.getcwd(),
    }
  end,
})
