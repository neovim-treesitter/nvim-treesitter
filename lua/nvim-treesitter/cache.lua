-- lua/nvim-treesitter/cache.lua
-- Version cache with a 24-hour TTL.
--
-- Cache file: config.get_install_dir('registry')/registry-cache.lua
-- Written as a plain Lua literal (dofile-loadable, human-readable in diffs).
--
-- Cache schema (version = 2):
--   {
--     version  = 2,
--     ttl      = 86400,      -- seconds
--     parsers  = {
--       [lang] = {
--         latest_parser  = "v0.25.0",   -- latest known parser version
--         latest_queries = "v1.3.2",    -- latest known queries version
--         parser_manifest = { ... },    -- optional raw manifest table
--         checked_at     = 1712345678,  -- os.time() when last checked
--       }
--     }
--   }
--
-- Per-parser installation state:
--   config.get_install_dir('parser-info')/<lang>.lua
--   {
--     type            = "external_queries",  -- source.type from registry
--     version         = "v0.25.0",           -- installed combined version (legacy/simple)
--     parser_version  = "v0.25.0",           -- installed parser version
--     queries_version = "v1.3.2",            -- installed queries version
--   }

local config = require('nvim-treesitter.config')

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local CACHE_VERSION = 2
local DEFAULT_TTL = 86400 -- 24 hours

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Path to the version cache Lua file.
---@return string
local function cache_path()
  return vim.fs.joinpath(config.get_install_dir('registry'), 'registry-cache.lua')
end

--- Serialise a value to a Lua literal string (tables, strings, numbers, bools).
--- Intentionally minimal — only handles the types we actually store.
---@param val any
---@param indent string?
---@return string
local function to_lua_literal(val, indent)
  indent = indent or ''
  local t = type(val)
  if t == 'string' then
    return string.format('%q', val)
  elseif t == 'number' then
    return tostring(val)
  elseif t == 'boolean' then
    return tostring(val)
  elseif t == 'nil' then
    return 'nil'
  elseif t == 'table' then
    local inner = indent .. '  '
    local parts = {}
    -- Check if array-like
    local is_array = #val > 0
    if is_array then
      for _, v in ipairs(val) do
        parts[#parts + 1] = inner .. to_lua_literal(v, inner)
      end
    else
      -- Sort keys for deterministic output
      local keys = vim.tbl_keys(val)
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for _, k in ipairs(keys) do
        local key_str = type(k) == 'string' and string.format('[%q]', k)
          or ('[' .. tostring(k) .. ']')
        parts[#parts + 1] = inner .. key_str .. ' = ' .. to_lua_literal(val[k], inner)
      end
    end
    if #parts == 0 then
      return '{}'
    end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
  end
  error('to_lua_literal: unsupported type ' .. t)
end

-- ---------------------------------------------------------------------------
-- Public API — cache file I/O
-- ---------------------------------------------------------------------------

--- Load the version cache from disk.
--- Returns an empty but valid cache structure if the file is absent or corrupt.
---@return table  cache  { version, ttl, parsers }
function M.load()
  local cp = cache_path()
  local ok, data = pcall(dofile, cp)
  if ok and type(data) == 'table' and data.version == CACHE_VERSION then
    -- Ensure required fields exist even in older cache versions
    data.ttl = data.ttl or DEFAULT_TTL
    data.parsers = data.parsers or {}
    return data
  end
  return { version = CACHE_VERSION, ttl = DEFAULT_TTL, parsers = {} }
end

--- Persist the version cache to disk.
---@param cache table
function M.save(cache)
  local cp = cache_path()
  local content = 'return ' .. to_lua_literal(cache) .. '\n'
  local file, err = io.open(cp, 'w')
  if not file then
    vim.notify(
      'nvim-treesitter: could not write cache file ' .. cp .. ': ' .. tostring(err),
      vim.log.levels.WARN
    )
    return
  end
  file:write(content)
  file:close()
end

--- Delete the version cache file, forcing a full refresh on next load.
---@return boolean ok  true if file was removed or did not exist
function M.clear()
  local cp = cache_path()
  local stat = vim.uv.fs_stat(cp)
  if stat then
    local ok, err = os.remove(cp)
    if not ok then
      vim.notify(
        'nvim-treesitter: could not remove cache file ' .. cp .. ': ' .. tostring(err),
        vim.log.levels.WARN
      )
      return false
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Public API — staleness checks
-- ---------------------------------------------------------------------------

--- Return true if a cache entry is older than ttl seconds.
--- Uses cache.ttl when ttl is omitted.
---@param entry    table   single parsers[lang] entry
---@param ttl      number?  override TTL in seconds
---@return boolean
function M.is_stale(entry, ttl)
  if type(entry) ~= 'table' then
    return true
  end
  local max_age = ttl or DEFAULT_TTL
  return (os.time() - (entry.checked_at or 0)) >= max_age
end

--- Return the subset of langs whose cache entry is stale (or missing).
---@param cache  table     full cache table from M.load()
---@param langs  string[]  languages to check
---@return string[]
function M.stale_langs(cache, langs)
  local ttl = cache.ttl or DEFAULT_TTL
  local parsers = cache.parsers or {}
  local result = {}
  for _, lang in ipairs(langs) do
    if M.is_stale(parsers[lang], ttl) then
      result[#result + 1] = lang
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Public API — per-parser installation state
-- ---------------------------------------------------------------------------

--- Read the installation state for a language.
--- Returns nil if no state file exists.
---@param lang string
---@return { type: string, version: string?, parser_version: string?, queries_version: string? }?
function M.get_installed(lang)
  local info_dir = config.get_install_dir('parser-info')
  local path = vim.fs.joinpath(info_dir, lang .. '.lua')
  if not vim.uv.fs_stat(path) then
    return nil
  end
  local ok, data = pcall(dofile, path)
  if ok and type(data) == 'table' then
    return data
  end
  return nil
end

--- Write the installation state for a language.
---@class nvim-ts.InstalledState
---@field type             string
---@field version          string?
---@field parser_version   string?
---@field queries_version  string?

---@param lang  string
---@param state nvim-ts.InstalledState?
function M.set_installed(lang, state)
  local info_dir = config.get_install_dir('parser-info')
  local path = vim.fs.joinpath(info_dir, lang .. '.lua')
  local content = 'return ' .. to_lua_literal(state) .. '\n'
  local file, err = io.open(path, 'w')
  if not file then
    vim.notify(
      'nvim-treesitter: could not write parser info for ' .. lang .. ': ' .. tostring(err),
      vim.log.levels.WARN
    )
    return
  end
  file:write(content)
  file:close()
end

return M
