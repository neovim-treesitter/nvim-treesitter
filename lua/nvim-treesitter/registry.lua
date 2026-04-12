-- lua/nvim-treesitter/registry.lua
-- Loads the treesitter-parser-registry JSON from the locally installed
-- registry plugin (on rtp) and exposes a simple get/load API.
--
-- The registry plugin (neovim-treesitter/treesitter-parser-registry) must be
-- installed as a hard dependency.  Its registry.json is read directly from the
-- filesystem — no HTTP fetch, no cache, no TTL.  To update the registry data
-- the user simply updates the registry plugin via their package manager.
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

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Locate registry.json on the rtp (provided by the registry plugin).
---@return string?
local function find_registry_json()
    local found = vim.api.nvim_get_runtime_file('registry.json', false)
    if found and #found > 0 then
        return found[1]
    end
    return nil
end

--- Decode a file path as JSON.  Strips the `$schema` key (JSON Schema
--- metadata, not a language entry).
---@param path string
---@return table?  data
---@return string? err
local function decode_registry(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or #lines == 0 then
        return nil, 'could not read ' .. path
    end
    local dok, data = pcall(vim.json.decode, table.concat(lines, '\n'))
    if not dok or type(data) ~= 'table' then
        return nil, 'JSON decode failed for ' .. path
    end
    ---@cast data table
    data['$schema'] = nil
    return data, nil
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

--- Load the registry from disk and invoke the callback with the result.
---
--- Reads registry.json from the locally installed registry plugin on the rtp.
--- This is a synchronous filesystem read — no network, no cache.
---
---@param callback  fun(registry: table?, err: string?)
---@param opts      table?   unused, reserved for future options
function M.load(callback, opts)
    _ = opts

    local path = find_registry_json()
    if not path then
        return callback(
            nil,
            'nvim-treesitter: registry.json not found on rtp.\n'
                .. 'Install the registry plugin: neovim-treesitter/treesitter-parser-registry'
        )
    end

    local data, err = decode_registry(path)
    if not data then
        return callback(nil, 'nvim-treesitter: ' .. (err or 'unknown error loading registry'))
    end

    M.loaded = data
    callback(data, nil)
end

return M
