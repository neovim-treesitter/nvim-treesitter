#!/usr/bin/env -S nvim -l
-- scripts/gen-parser-manifest.lua
-- Reads lua/nvim-treesitter/parsers.lua for a given lang and emits
-- a parser.json manifest to stdout suitable for a query repo root.
--
-- Usage (from repo root):
--   nvim --headless -l scripts/gen-parser-manifest.lua <lang> [existing-parser.json]
--
-- When an existing parser.json path is supplied the script merges: fields
-- derived from parsers.lua (url, semver, parser_version, location, generate,
-- generate_from_json, queries_only) overwrite the existing values, while
-- manually-maintained fields (inherits, and any unknown keys) are preserved.

local lang = _G.arg and _G.arg[1]
local existing_path = _G.arg and _G.arg[2]
if not lang then
  io.stderr:write(
    'Usage: nvim --headless -l scripts/gen-parser-manifest.lua <lang> [existing-parser.json]\n'
  )
  os.exit(1)
end

vim.o.rtp = vim.o.rtp .. ',.'
local parsers = require('nvim-treesitter.parsers')

local info = parsers[lang]
if not info then
  io.stderr:write('Unknown language: ' .. lang .. '\n')
  os.exit(1)
end
assert(info)
---@cast info ParserInfo

local install = info.install_info

local function is_semver(rev)
  return rev ~= nil and rev:match('^v%d+%.%d+') ~= nil
end

-- Load existing manifest if provided (preserves manually-set fields).
local base = {}
if existing_path then
  local f = io.open(existing_path, 'r')
  if f then
    local raw = f:read('*a')
    f:close()
    local ok, decoded = pcall(vim.json.decode, raw)
    if ok and type(decoded) == 'table' then
      base = decoded
    end
  end
end

-- Build the auto-generated fields (always overwrite from parsers.lua).
---@type table<string, unknown>
local generated = { lang = lang }
if not install then
  -- queries_only lang (e.g. ecma — no parser binary)
  generated.url = vim.NIL
  generated.semver = vim.NIL
  generated.parser_version = vim.NIL
  generated.location = vim.NIL
  generated.queries_only = true
else
  ---@cast install InstallInfo
  local semver = is_semver(install.revision)
  generated.url = install.url
  generated.semver = semver
  -- parser_version: exact git tag or SHA these queries are tested against.
  generated.parser_version = install.revision or vim.NIL
  generated.location = install.location or vim.NIL
  -- generate / generate_from_json: only emit when needed.
  if install.generate then
    generated.generate = true
    if install.generate_from_json ~= nil then
      generated.generate_from_json = install.generate_from_json
    end
  else
    -- Explicitly clear if parsers.lua no longer sets generate.
    generated.generate = nil
    generated.generate_from_json = nil
  end
end

-- Merge: start from existing, apply generated fields on top,
-- preserving manually-maintained fields (inherits, etc.).
local manifest = vim.tbl_extend('force', base, generated)

-- Remove vestigial / null fields that should not appear in the output.
-- min_version / max_version were replaced by parser_version.
-- generate / generate_from_json are omitted when not needed.
-- null location is omitted (means repo root).
manifest.min_version = nil
manifest.max_version = nil
if manifest.generate == nil or manifest.generate == vim.NIL or manifest.generate == false then
  manifest.generate = nil
  manifest.generate_from_json = nil
end
if manifest.location == vim.NIL then
  manifest.location = nil
end

local ok, encoded = pcall(vim.json.encode, manifest)
if not ok then
  io.stderr:write('JSON encode failed: ' .. tostring(encoded) .. '\n')
  os.exit(1)
end

-- Pretty-print: vim.json.encode produces compact JSON; run through a formatter
-- if python3 is available, otherwise emit compact.
local fmt = vim
  .system({ 'python3', '-m', 'json.tool', '--indent', '2' }, { stdin = encoded, text = true })
  :wait()

if fmt.code == 0 then
  io.write(assert(fmt.stdout))
else
  io.write(encoded .. '\n')
end

os.exit(0)
