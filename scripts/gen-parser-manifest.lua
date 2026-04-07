#!/usr/bin/env -S nvim -l
-- scripts/gen-parser-manifest.lua
-- Reads lua/nvim-treesitter/parsers.lua for a given lang and emits
-- a parser.json manifest to stdout suitable for a query repo root.
--
-- Usage (from repo root):
--   nvim --headless -l scripts/gen-parser-manifest.lua <lang>

local lang = _G.arg and _G.arg[1]
if not lang then
  io.stderr:write("Usage: nvim --headless -l scripts/gen-parser-manifest.lua <lang>\n")
  os.exit(1)
end

vim.o.rtp = vim.o.rtp .. ",."
local parsers = require("nvim-treesitter.parsers")

local info = parsers[lang]
if not info then
  io.stderr:write("Unknown language: " .. lang .. "\n")
  os.exit(1)
end

local install = info.install_info

local function is_semver(rev)
  return rev ~= nil and rev:match("^v%d+%.%d+") ~= nil
end

local manifest
if not install then
  -- queries_only lang (e.g. ecma — no parser binary)
  manifest = {
    lang         = lang,
    url          = vim.NIL,
    semver       = vim.NIL,
    min_version  = vim.NIL,
    max_version  = vim.NIL,
    location     = vim.NIL,
    queries_only = true,
  }
else
  local semver = is_semver(install.revision)
  manifest = {
    lang        = lang,
    url         = install.url,
    semver      = semver,
    -- min_version: set to current revision if it's a semver tag,
    -- otherwise nil (maintainer must set manually after first semver release).
    min_version = semver and install.revision or vim.NIL,
    max_version = vim.NIL,
    location    = install.location or vim.NIL,
  }
end

local ok, encoded = pcall(vim.json.encode, manifest)
if not ok then
  io.stderr:write("JSON encode failed: " .. tostring(encoded) .. "\n")
  os.exit(1)
end

-- Pretty-print: vim.json.encode produces compact JSON; run through a formatter
-- if python3 is available, otherwise emit compact.
local fmt = vim.system(
  { "python3", "-m", "json.tool", "--indent", "2" },
  { stdin = encoded, text = true }
):wait()

if fmt.code == 0 then
  io.write(fmt.stdout)
else
  io.write(encoded .. "\n")
end

os.exit(0)
