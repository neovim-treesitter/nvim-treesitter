-- plugin/nvim-treesitter.lua
--
-- Entry point for the nvim-treesitter plugin.
-- Defines all user-facing commands and wires them to the new modular
-- install.lua API.
--
-- Requires:
--   neovim-treesitter/treesitter-parser-registry  (HTTP + host adapters)
--   curl binary  (used by treesitter-registry.http for all HTTP downloads)
--
-- Commands:
--   :TSInstall[!] {lang...}    install; bang = force reinstall
--   :TSUpdate[!] [{lang...}]   update installed; bang = bypass version cache
--   :TSUninstall {lang...}     remove parser + queries
--   :TSStatus                  open a status buffer with per-lang info
--   :TSLog                     show the nvim-treesitter log

if vim.g.loaded_nvim_treesitter then
  return
end
vim.g.loaded_nvim_treesitter = true

-- ── dependency check ──────────────────────────────────────────────────────────
local ok, _ = pcall(require, 'treesitter-registry.http')
if not ok then
  vim.notify(
    '[nvim-treesitter] Missing required dependency: neovim-treesitter/treesitter-parser-registry\n'
      .. "Add it to your plugin manager, e.g.:\n"
      .. "  dependencies = { 'neovim-treesitter/treesitter-parser-registry' }",
    vim.log.levels.ERROR
  )
end

local api = vim.api

-- ── completion helpers ────────────────────────────────────────────────────────

local function complete_available_parsers(arglead)
  return vim.tbl_filter(
    ---@param v string
    function(v)
      return v:find(arglead, 1, true) ~= nil
    end,
    require('nvim-treesitter.config').get_available()
  )
end

local function complete_installed_parsers(arglead)
  return vim.tbl_filter(
    ---@param v string
    function(v)
      return v:find(arglead, 1, true) ~= nil
    end,
    require('nvim-treesitter.config').get_installed()
  )
end

-- ── :TSInstall[!] {lang...} ───────────────────────────────────────────────────
-- Without bang : install (skip if already up to date)
-- With bang    : force reinstall

api.nvim_create_user_command('TSInstall', function(args)
  local fargs = args.fargs
  local bang = args.bang
  vim.schedule(function()
    require('nvim-treesitter.install').install(fargs, {
      force = bang,
      summary = true,
    })
  end)
end, {
  nargs = '+',
  bang = true,
  bar = true,
  complete = complete_available_parsers,
  desc = 'Install treesitter parsers',
})

-- ── :TSUpdate[!] [{lang...}] ──────────────────────────────────────────────────
-- Without bang : update installed parsers (uses version cache)
-- With bang    : force re-fetch version info before updating

api.nvim_create_user_command('TSUpdate', function(args)
  local langs = #args.fargs > 0 and args.fargs or nil
  local bang = args.bang
  vim.schedule(function()
    require('nvim-treesitter.install').update(langs, {
      force = bang,
      summary = true,
    })
  end)
end, {
  nargs = '*',
  bang = true,
  bar = true,
  complete = complete_installed_parsers,
  desc = 'Update installed treesitter parsers',
})

-- ── :TSUninstall {lang...} ────────────────────────────────────────────────────

api.nvim_create_user_command('TSUninstall', function(args)
  local fargs = args.fargs
  vim.schedule(function()
    require('nvim-treesitter.install').uninstall(fargs, { summary = true })
  end)
end, {
  nargs = '+',
  bar = true,
  complete = complete_installed_parsers,
  desc = 'Uninstall treesitter parsers',
})

-- ── :TSStatus ─────────────────────────────────────────────────────────────────
-- Opens a scratch buffer with a formatted status table.

api.nvim_create_user_command('TSStatus', function()
  local status = require('nvim-treesitter.install').status()

  -- Sort languages alphabetically
  local langs = vim.tbl_keys(status)
  table.sort(langs)

  local lines = {
    string.format(
      '%-20s  %-8s  %-12s  %-12s  %-12s  %-12s  %s',
      'Language',
      'Installed',
      'Parser',
      'Latest P',
      'Queries',
      'Latest Q',
      'Needs Update'
    ),
    string.rep('-', 100),
  }

  for _, lang in ipairs(langs) do
    local s = status[lang]
    lines[#lines + 1] = string.format(
      '%-20s  %-8s  %-12s  %-12s  %-12s  %-12s  %s',
      lang,
      s.installed and 'yes' or 'no',
      s.parser_version or '-',
      s.latest_parser or '-',
      s.queries_version or '-',
      s.latest_queries or '-',
      s.needs_update and 'YES' or ''
    )
  end

  -- Create (or reuse) a scratch buffer
  local buf = vim.fn.bufnr('nvim-treesitter-status')
  if buf == -1 or not api.nvim_buf_is_valid(buf) then
    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, 'nvim-treesitter-status')
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'tsinstall'

  -- Open in a split if not already visible
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd('split')
    api.nvim_win_set_buf(0, buf)
  else
    api.nvim_set_current_win(win)
  end
end, {
  desc = 'Show treesitter parser status',
})

-- ── :TSLog ────────────────────────────────────────────────────────────────────

api.nvim_create_user_command('TSLog', function()
  require('nvim-treesitter.log').show()
end, {
  desc = 'View nvim-treesitter log messages',
})

-- ── :TSCacheClear ─────────────────────────────────────────────────────────────
-- Clear the version cache so the next :TSInstall or :TSUpdate will re-fetch
-- version info from GitHub.  The registry itself is read from the locally
-- installed plugin — update it via your package manager.

api.nvim_create_user_command('TSCacheClear', function()
  vim.schedule(function()
    local cache = require('nvim-treesitter.cache')
    local cleared = cache.clear()
    if cleared then
      vim.notify('[nvim-treesitter] Version cache cleared', vim.log.levels.INFO)
    else
      vim.notify('[nvim-treesitter] No cache file to clear', vim.log.levels.INFO)
    end
  end)
end, {
  desc = 'Clear the nvim-treesitter version cache',
})
