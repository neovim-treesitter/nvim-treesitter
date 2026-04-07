-- plugin/nvim-treesitter.lua
--
-- Entry point for the nvim-treesitter plugin.
-- Defines all user-facing commands and wires them to the new modular
-- install.lua API.
--
-- Requires:
--   nvim-lua/plenary.nvim  (used by install.lua for HTTP via plenary.curl)
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

local api = vim.api

-- ── completion helpers ────────────────────────────────────────────────────────

local function complete_available_parsers(arglead)
  return vim.tbl_filter(
    ---@param v string
    function(v) return v:find(arglead, 1, true) ~= nil end,
    require('nvim-treesitter.config').get_available()
  )
end

local function complete_installed_parsers(arglead)
  return vim.tbl_filter(
    ---@param v string
    function(v) return v:find(arglead, 1, true) ~= nil end,
    require('nvim-treesitter.config').get_installed()
  )
end

-- ── :TSInstall[!] {lang...} ───────────────────────────────────────────────────
-- Without bang : install (skip if already up to date)
-- With bang    : force reinstall

api.nvim_create_user_command('TSInstall', function(args)
  require('nvim-treesitter.install').install(args.fargs, {
    force   = args.bang,
    summary = true,
  })
end, {
  nargs    = '+',
  bang     = true,
  bar      = true,
  complete = complete_available_parsers,
  desc     = 'Install treesitter parsers',
})

-- ── :TSUpdate[!] [{lang...}] ──────────────────────────────────────────────────
-- Without bang : update installed parsers (uses version cache)
-- With bang    : force re-fetch version info before updating

api.nvim_create_user_command('TSUpdate', function(args)
  -- no args → update all installed
  local langs = #args.fargs > 0 and args.fargs or nil
  require('nvim-treesitter.install').update(langs, {
    force   = args.bang,
    summary = true,
  })
end, {
  nargs    = '*',
  bang     = true,
  bar      = true,
  complete = complete_installed_parsers,
  desc     = 'Update installed treesitter parsers',
})

-- ── :TSUninstall {lang...} ────────────────────────────────────────────────────

api.nvim_create_user_command('TSUninstall', function(args)
  require('nvim-treesitter.install').uninstall(args.fargs, { summary = true })
end, {
  nargs    = '+',
  bar      = true,
  complete = complete_installed_parsers,
  desc     = 'Uninstall treesitter parsers',
})

-- ── :TSStatus ─────────────────────────────────────────────────────────────────
-- Opens a scratch buffer with a formatted status table.

api.nvim_create_user_command('TSStatus', function()
  local status = require('nvim-treesitter.install').status()

  -- Sort languages alphabetically
  local langs = vim.tbl_keys(status)
  table.sort(langs)

  local lines = {
    string.format('%-20s  %-8s  %-12s  %-12s  %-12s  %-12s  %s',
      'Language', 'Installed', 'Parser', 'Latest P', 'Queries', 'Latest Q', 'Needs Update'),
    string.rep('-', 100),
  }

  for _, lang in ipairs(langs) do
    local s = status[lang]
    lines[#lines + 1] = string.format(
      '%-20s  %-8s  %-12s  %-12s  %-12s  %-12s  %s',
      lang,
      s.installed        and 'yes'  or 'no',
      s.parser_version   or '-',
      s.latest_parser    or '-',
      s.queries_version  or '-',
      s.latest_queries   or '-',
      s.needs_update     and 'YES'  or ''
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
  vim.bo[buf].buftype    = 'nofile'
  vim.bo[buf].filetype   = 'tsinstall'

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
