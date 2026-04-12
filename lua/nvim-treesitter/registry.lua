-- lua/nvim-treesitter/registry.lua
-- Loads the treesitter-parser-registry JSON and exposes a simple get/load API.
--
-- The registry fetch + cache logic from treesitter-registry.lua is vendored
-- inline so this module has no external runtime dependency beyond plenary.curl.
--
-- Registry JSON structure per entry:
--   {
--     "python": {
--       "source": {
--         "type": "external_queries",
--         "parser_url": "...",
--         "parser_semver": true,
--         "queries_url": "...",
--         "queries_semver": true
--       },
--       "filetypes": ["python", "py"]
--     }
--   }

local config = require('nvim-treesitter.config')

local M = {}

-- ---------------------------------------------------------------------------
-- Constants (vendored from treesitter-registry shim)
-- ---------------------------------------------------------------------------

-- Use the GitHub Contents API rather than raw.githubusercontent.com so that
-- GITHUB_TOKEN auth is honoured (raising rate limits from 60 to 5 000/hr).
-- The Accept header tells the API to return the raw file, not JSON metadata.
local REGISTRY_URL =
  'https://api.github.com/repos/neovim-treesitter/treesitter-parser-registry/contents/registry.json?ref=main'

-- 7-day TTL — registry is stable (new langs added rarely).
local REGISTRY_TTL = 604800

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return the registry sub-directory, creating it on first call.
---@return string
local function registry_dir()
  return config.get_install_dir('registry')
end

--- Full path to the cached registry JSON.
---@return string
local function reg_path()
  return vim.fs.joinpath(registry_dir(), 'treesitter-registry.json')
end

--- Full path to the registry metadata file (stores fetched_at timestamp).
---@return string
local function meta_path()
  return vim.fs.joinpath(registry_dir(), 'treesitter-registry-meta.lua')
end

--- Attempt to decode a list of lines as JSON. Returns table or nil.
--- Strips the `$schema` key which is JSON Schema metadata, not a language entry.
---@param lines string[]
---@return table?
local function decode_lines(lines)
  if #lines == 0 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not ok or type(data) ~= 'table' then
    return nil
  end
  ---@cast data table
  data['$schema'] = nil
  return data
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- The last-successfully-loaded registry table, or nil.
---@type table?
M.loaded = nil

--- Synchronous lookup in the last-loaded registry.
--- Returns nil if the registry has not been loaded yet.
---@param lang string
---@return table?
function M.get(lang)
  if not M.loaded then
    return nil
  end
  return M.loaded[lang]
end

--- Load the registry asynchronously.
---
--- Uses a local cache under `config.get_install_dir('registry')/` with a 7-day
--- TTL. Falls back to a stale cache if the network request fails.
---
---@param callback  fun(registry: table?, err: string?)
---@param opts      { force?: boolean }?
function M.load(callback, opts)
  opts = opts or {}
  local rp = reg_path()
  local mp = meta_path()

  -- ── Check freshness unless a force-refresh was requested ────────────────
  if not opts.force then
    local ok, meta = pcall(dofile, mp)
    if ok and type(meta) == 'table' then
      if (os.time() - (meta.fetched_at or 0)) < REGISTRY_TTL then
        local rok, lines = pcall(vim.fn.readfile, rp)
        if rok then
          local data = decode_lines(lines)
          if data then
            M.loaded = data
            return callback(data, nil)
          end
        end
      end
    end
  end

  -- ── Fetch a fresh copy ──────────────────────────────────────────────────
  local curl = require('plenary.curl')
  -- Request raw file content from the Contents API (not the JSON envelope).
  local headers = {
    accept = 'application/vnd.github.raw+json',
    ['x-github-api-version'] = '2022-11-28',
  }
  local token = vim.env.GITHUB_TOKEN
  if token and token ~= '' then
    headers['authorization'] = 'Bearer ' .. token
  end
  curl.get(REGISTRY_URL, {
    headers = headers,
    timeout = 15000,
    callback = vim.schedule_wrap(function(response)
      if response.status ~= 200 then
        -- Stale fallback — better than nothing
        local rok, lines = pcall(vim.fn.readfile, rp)
        local data = rok and decode_lines(lines) or nil
        if data then
          vim.notify(
            'nvim-treesitter: registry fetch failed (HTTP '
              .. tostring(response.status)
              .. '), using stale cache',
            vim.log.levels.WARN
          )
          M.loaded = data
          return callback(data, nil)
        end
        return callback(nil, 'nvim-treesitter: registry fetch failed and no cache available')
      end

      -- Persist fresh copy + metadata
      local dir = registry_dir()
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile(vim.split(response.body, '\n'), rp)
      vim.fn.writefile({ 'return { fetched_at = ' .. os.time() .. ' }' }, mp)

      local ok, data = pcall(vim.json.decode, response.body)
      if not ok or type(data) ~= 'table' then
        return callback(nil, 'nvim-treesitter: registry JSON decode failed')
      end

      ---@cast data table
      data['$schema'] = nil
      M.loaded = data
      callback(data, nil)
    end),
  })
end

return M
