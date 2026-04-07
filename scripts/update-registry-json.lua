#!/usr/bin/env -S nvim -l
-- scripts/update-registry-json.lua
-- Reads parsers.lua and registry.json, checks which nvim-treesitter-queries-<lang>
-- repos exist in the neovim-treesitter org, and adds missing entries to registry.json.
--
-- Only adds entries — never removes or modifies existing ones.
-- Safe to re-run; already-present langs are skipped.
--
-- Usage (from nvim-treesitter repo root):
--   nvim --headless -l scripts/update-registry-json.lua [lang ...]
--
-- Requires: gh (GitHub CLI, authenticated), nvim, python3
-- NVIM_TS_GH_TOKEN env var overrides GH_TOKEN if set.

vim.o.rtp = vim.o.rtp .. ',.'

local ORG = 'neovim-treesitter'
local _info = debug.getinfo(1, 'S')
---@cast _info {source?:string}
local REPO_ROOT = vim.fn.fnamemodify((_info.source or ''):sub(2), ':p:h:h')
local REGISTRY_PATH = REPO_ROOT .. '/../treesitter-parser-registry/registry.json'

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function is_semver(rev)
  return rev ~= nil and rev:match('^v%d+%.%d+') ~= nil
end

--- Run a shell command and return trimmed stdout, or nil on failure.
local function sh(cmd)
  local result = vim.system(vim.split(cmd, '%s+'), { text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout or '')
end

--- Check if a GitHub repo exists and is non-empty.
local function repo_exists(full_repo)
  local result = vim
    .system({ 'gh', 'repo', 'view', full_repo, '--json', 'isEmpty' }, { text = true })
    :wait()
  if result.code ~= 0 then
    return false
  end
  local ok, data = pcall(vim.json.decode, result.stdout or '')
  if not ok or type(data) ~= 'table' then
    return false
  end
  ---@cast data table
  -- isEmpty = true means it was created but has no content yet — treat as missing
  return data.isEmpty == false
end

--- Pretty-print JSON via python3.
local function pretty_json(tbl)
  local ok, encoded = pcall(vim.json.encode, tbl)
  if not ok then
    return nil, 'JSON encode failed: ' .. tostring(encoded)
  end
  local fmt = vim
    .system(
      { 'python3', '-m', 'json.tool', '--indent', '2', '--sort-keys' },
      { stdin = encoded, text = true }
    )
    :wait()
  if fmt.code == 0 then
    return assert(fmt.stdout), nil
  end
  return encoded .. '\n', nil
end

-- ---------------------------------------------------------------------------
-- Load parsers
-- ---------------------------------------------------------------------------

local parsers = require('nvim-treesitter.parsers')

-- ---------------------------------------------------------------------------
-- Load existing registry.json
-- ---------------------------------------------------------------------------

local reg_file = io.open(REGISTRY_PATH, 'r')
if not reg_file then
  io.stderr:write('ERROR: Could not open ' .. REGISTRY_PATH .. '\n')
  os.exit(1)
end
---@cast reg_file file*
local reg_raw = reg_file:read('*a')
reg_file:close()

local ok, registry = pcall(vim.json.decode, reg_raw)
if not ok or type(registry) ~= 'table' then
  io.stderr:write('ERROR: Failed to parse registry.json: ' .. tostring(registry) .. '\n')
  os.exit(1)
end
---@cast registry table

-- ---------------------------------------------------------------------------
-- Determine which langs to process
-- ---------------------------------------------------------------------------

local langs_to_check = {}
if _G.arg and #_G.arg > 0 then
  for _, lang in ipairs(_G.arg) do
    langs_to_check[#langs_to_check + 1] = lang
  end
else
  -- All langs in parsers.lua, sorted
  local all = {}
  for lang in pairs(parsers) do
    all[#all + 1] = lang
  end
  table.sort(all)
  langs_to_check = all
end

-- ---------------------------------------------------------------------------
-- Process each lang
-- ---------------------------------------------------------------------------

local count_added = 0
local count_skipped = 0
local count_no_repo = 0
local count_exists = 0
local added_langs = {}
local no_repo_langs = {}

for _, lang in ipairs(langs_to_check) do
  -- Skip if already in registry
  if registry[lang] then
    count_exists = count_exists + 1
    goto continue
  end

  local repo_name = 'nvim-treesitter-queries-' .. lang
  local full_repo = ORG .. '/' .. repo_name

  io.write(string.format('==> %-30s ', lang))
  io.flush()

  -- Check repo exists and is populated
  if not repo_exists(full_repo) then
    io.write('NO REPO\n')
    count_no_repo = count_no_repo + 1
    no_repo_langs[#no_repo_langs + 1] = lang
    goto continue
  end

  -- Build registry entry from parsers.lua
  local info = parsers[lang]
  local install = info and info.install_info
  local entry ---@type table

  if not install then
    -- queries_only: no parser binary, queries live in the query repo
    entry = {
      source = {
        type = 'queries_only',
        url = 'https://github.com/' .. ORG .. '/' .. repo_name,
        semver = true,
      },
    }
  else
    local semver = is_semver(install.revision)
    entry = {
      source = {
        type = 'external_queries',
        parser_url = install.url,
        parser_semver = semver,
        queries_url = 'https://github.com/' .. ORG .. '/' .. repo_name,
        queries_semver = true,
      },
    }
    if install.location then
      entry.source.parser_location = install.location
    end
  end

  if info and info.requires and #info.requires > 0 then
    entry.requires = info.requires
  end

  -- filetypes: default to { lang } unless it's an abstract/shared lang
  entry.filetypes = { lang }

  registry[lang] = entry
  count_added = count_added + 1
  added_langs[#added_langs + 1] = lang
  io.write('ADDED\n')

  ::continue::
end

-- ---------------------------------------------------------------------------
-- Write updated registry.json
-- ---------------------------------------------------------------------------

if count_added > 0 then
  -- Preserve $schema key at top
  local schema = registry['$schema']
  registry['$schema'] = nil

  local out_tbl = { ['$schema'] = schema }
  -- Merge sorted entries
  local sorted_keys = {}
  for k in pairs(registry) do
    if k ~= '$schema' then
      sorted_keys[#sorted_keys + 1] = k
    end
  end
  table.sort(sorted_keys)
  for _, k in ipairs(sorted_keys) do
    out_tbl[k] = registry[k]
  end
  out_tbl['$schema'] = schema

  local json_out, err = pretty_json(out_tbl)
  if err then
    io.stderr:write('ERROR: ' .. err .. '\n')
    os.exit(1)
  end

  local f = io.open(REGISTRY_PATH, 'w')
  if not f then
    io.stderr:write('ERROR: Could not write ' .. REGISTRY_PATH .. '\n')
    os.exit(1)
  end
  ---@cast f file*
  f:write(assert(json_out))
  f:close()
  io.write('\nWrote ' .. REGISTRY_PATH .. '\n')
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

io.write('\n')
io.write('========================================\n')
io.write('Summary\n')
io.write('========================================\n')
io.write(string.format('  Already in registry : %d\n', count_exists))
io.write(string.format('  Added               : %d\n', count_added))
io.write(string.format('  No repo (skipped)   : %d\n', count_no_repo))
if #added_langs > 0 then
  io.write('  Added langs:\n')
  for _, l in ipairs(added_langs) do
    io.write('    + ' .. l .. '\n')
  end
end
if #no_repo_langs > 0 then
  io.write('  Missing repos:\n')
  for _, l in ipairs(no_repo_langs) do
    io.write('    - ' .. l .. '\n')
  end
end
io.write('========================================\n')

os.exit(0)
