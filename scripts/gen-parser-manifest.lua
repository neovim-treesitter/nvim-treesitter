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
    lang           = lang,
    url            = vim.NIL,
    semver         = vim.NIL,
    parser_version = vim.NIL,
    location       = vim.NIL,
    queries_only   = true,
  }
else
  local semver = is_semver(install.revision)
  manifest = {
    lang           = lang,
    url            = install.url,
    semver         = semver,
    -- parser_version: exact git tag or SHA of the parser repo these queries
    -- are tested against.  Used as the install target; overrides version
    -- discovery.  Set to the current revision when it is a semver tag,
    -- otherwise leave nil for the maintainer to fill in.
    parser_version = install.revision or vim.NIL,
    location       = install.location or vim.NIL,
    -- generate: set true when the parser repo does not ship a pre-built
    -- src/parser.c and requires `tree-sitter generate` before compiling.
    -- generate_from_json: true = use src/grammar.json (faster, no JS runtime),
    --                     false = use grammar.js (requires a JS runtime).
    -- Omit both fields (nil) when generate is not needed.
    generate          = install.generate or vim.NIL,
    generate_from_json = install.generate_from_json ~= nil
                          and install.generate_from_json or vim.NIL,
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
