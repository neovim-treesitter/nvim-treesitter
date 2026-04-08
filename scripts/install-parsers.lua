#!/usr/bin/env -S nvim -l
vim.o.rtp = vim.o.rtp .. ',.'

-- Use the same isolated install dir as minimal_init.lua so parsers land in a
-- disposable location (default: <repo>/.test-deps/parsers).
local ts_install_dir = os.getenv('TS_INSTALL_DIR')
  or vim.fs.joinpath(vim.fn.getcwd(), '.test-deps', 'parsers')
require('nvim-treesitter').setup({ install_dir = ts_install_dir })

local generate = false
local update = false
local max_jobs = nil ---@type number?
local parsers = {}
for i = 1, #_G.arg do
  if _G.arg[i] == '--generate' then
    generate = true
  elseif _G.arg[i] == '--update' then
    update = true
  elseif _G.arg[i]:find('^%-%-max%-jobs') then
    max_jobs = tonumber(_G.arg[i]:match('=(%d+)'))
  elseif _G.arg[i] == '--' then
    -- ignore separator
  else
    parsers[#parsers + 1] = _G.arg[i] ---@type string
  end
end

---@type async.Task
local task = update and require('nvim-treesitter').update('all', { summary = true })
  or require('nvim-treesitter').install(
    #parsers > 0 and parsers or 'all',
    { force = true, summary = true, generate = generate, max_jobs = max_jobs }
  )

local ok, err_or_ok = task:pwait(1800000) -- wait max. 30 minutes
if not ok then
  print('ERROR: ', err_or_ok)
  vim.cmd.cq()
elseif not err_or_ok then
  vim.cmd.cq()
end
