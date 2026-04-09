local M = {}

---@class TSConfig
---@field install_dir string
---@field local_parsers? table<string, {source: table, filetypes?: string[], requires?: string[]}>

---@type TSConfig
local config = {
  install_dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site'),
  local_parsers = {},
}

---Setup call for users to override configuration configurations.
---@param user_data TSConfig? user configuration table
function M.setup(user_data)
  if user_data then
    if user_data.install_dir then
      user_data.install_dir = vim.fs.normalize(user_data.install_dir)
      vim.o.rtp = user_data.install_dir .. ',' .. vim.o.rtp
    end
    config = vim.tbl_deep_extend('force', config, user_data)
  end
end

-- Returns the install path for parsers, parser info, and queries.
-- If the specified directory does not exist, it is created.
---@param dir_name string
---@return string
function M.get_install_dir(dir_name)
  local dir = vim.fs.joinpath(config.install_dir, dir_name)

  if not vim.uv.fs_stat(dir) then
    local ok, err = pcall(vim.fn.mkdir, dir, 'p', '0755')
    if not ok then
      local log = require('nvim-treesitter.log')
      log.error(err --[[@as string]])
    end
  end
  return dir
end

--- Return the local_parsers table from setup().
---@return table<string, table>
function M.get_local_parsers()
  return config.local_parsers or {}
end

---@param kind 'queries'|'parsers'?
---@return string[]
function M.get_installed(kind)
  local installed = {} --- @type table<string, boolean>
  if not (kind and kind == 'parsers') then
    for f in vim.fs.dir(M.get_install_dir('queries')) do
      installed[f] = true
    end
  end
  if not (kind and kind == 'queries') then
    for f in vim.fs.dir(M.get_install_dir('parser')) do
      installed[vim.fn.fnamemodify(f, ':r')] = true
    end
  end
  return vim.tbl_keys(installed)
end

--- Get a list of all available languages.
--- Source of truth is the registry (registry.loaded) plus any local_parsers overrides.
---@return string[]
function M.get_available()
  local registry = require('nvim-treesitter.registry')
  local languages = registry.loaded and vim.tbl_keys(registry.loaded) or {}

  for lang in pairs(M.get_local_parsers()) do
    if not vim.list_contains(languages, lang) then
      languages[#languages + 1] = lang
    end
  end

  table.sort(languages)
  return languages
end

---Normalize languages
---@param languages? string[]|string
---@param skip? { missing: boolean?, installed: boolean? }
---@return string[]
function M.norm_languages(languages, skip)
  if not languages then
    return {}
  elseif type(languages) == 'string' then
    languages = { languages }
  end

  if vim.list_contains(languages, 'all') then
    if skip and skip.missing then
      return M.get_installed()
    end
    languages = M.get_available()
  end

  if skip and skip.installed then
    local installed = M.get_installed()
    languages = vim.tbl_filter(
      --- @param v string
      function(v)
        return not vim.list_contains(installed, v)
      end,
      languages
    )
  end

  if skip and skip.missing then
    local installed = M.get_installed()
    languages = vim.tbl_filter(
      --- @param v string
      function(v)
        return vim.list_contains(installed, v)
      end,
      languages
    )
  end

  -- Deduplicate while preserving order (vim.list.unique is nightly-only).
  local seen = {} ---@type table<string, boolean>
  local unique = {} ---@type string[]
  for _, lang in ipairs(languages) do
    if not seen[lang] then
      seen[lang] = true
      unique[#unique + 1] = lang
    end
  end
  return unique
end

return M
