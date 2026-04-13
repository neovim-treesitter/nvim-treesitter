-- lua/nvim-treesitter/queries_resolver.lua
-- Resolves `; inherits:` directives in tree-sitter query files.
--
-- Named `queries_resolver` (not `query` or `queries`) to avoid shadowing the
-- built-in `vim.treesitter.query` namespace.
--
-- Directive syntax (first line of a .scm file):
--   ; inherits: <lang>[, <lang2>, ...]
--   ; inherits: <lang>?            -- optional (missing parent is silently skipped)
--
-- Algorithm for M.resolve(lang, install_dir, callback, _visited):
--   1. Read all .scm files for `lang` under install_dir/queries/<lang>/
--   2. For each file that has a `; inherits:` directive, record that file
--      name → parent lang mapping.
--   3. For each parent lang, recursively call M.resolve() (cycle-safe via
--      _visited set), then call M._merge(child_lang, parent_lang, install_dir,
--      inheriting_files) — only merging into files that actually declared
--      `; inherits:` for that parent.
--   4. When all parents for all files are done, call callback().
--
-- M._merge(child_lang, parent_lang, install_dir, inheriting_files):
--   Only processes .scm files from the parent that have a corresponding child
--   file which declared `; inherits: <parent_lang>`:
--     - Prepend parent content (minus the `; inherits:` line) before the child
--       content (minus its own `; inherits:` line).
--   This is idempotent only if called once per install; the install pipeline
--   must call M.resolve after a fresh copy is in place, not after a previous
--   merge.

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

--- Matches:  "; inherits: foo, bar?, baz"
--- Captures the comma-separated list after the colon.
local INHERITS_PATTERN = '^%s*;%s+inherits%s*:%s*(.+)%s*$'

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Read an entire file as a string. Returns nil on error.
---@param path string
---@return string?
local function read_file(path)
  local f, err = io.open(path, 'r')
  if not f then
    vim.notify(
      'nvim-treesitter/queries_resolver: cannot read ' .. path .. ': ' .. tostring(err),
      vim.log.levels.DEBUG
    )
    return nil
  end
  local content = f:read('*a')
  f:close()
  return content
end

--- Write content to a file, creating or overwriting it.
---@param path    string
---@param content string
---@return boolean ok
local function write_file(path, content)
  local f, err = io.open(path, 'w')
  if not f then
    vim.notify(
      'nvim-treesitter/queries_resolver: cannot write ' .. path .. ': ' .. tostring(err),
      vim.log.levels.WARN
    )
    return false
  end
  f:write(content)
  f:close()
  return true
end

--- Return a list of .scm files in a query directory.
---@param query_dir string
---@return string[]  absolute paths
local function scm_files(query_dir)
  local result = {}
  if not vim.uv.fs_stat(query_dir) then
    return result
  end
  for name in vim.fs.dir(query_dir) do
    if name:match('%.scm$') then
      result[#result + 1] = vim.fs.joinpath(query_dir, name)
    end
  end
  table.sort(result) -- deterministic order
  return result
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Parse a `; inherits:` directive from the first line of a .scm file.
---
--- Returns an array of `{ lang: string, optional: boolean }` objects.
--- Returns an empty table if the directive is absent or the file cannot be read.
---
---@param scm_path string  absolute path to the .scm file
---@return { lang: string, optional: boolean }[]
function M.parse_inherits(scm_path)
  local result = {}
  local content = read_file(scm_path)
  if not content then
    return result
  end

  -- Only inspect the very first non-empty line
  local first_line = content:match('^([^\n]*)')
  if not first_line then
    return result
  end

  local list_str = first_line:match(INHERITS_PATTERN)
  if not list_str then
    return result
  end

  for item in list_str:gmatch('[^,%s]+') do
    local optional = item:sub(-1) == '?'
    local lang = optional and item:sub(1, -2) or item
    if lang ~= '' then
      result[#result + 1] = { lang = lang, optional = optional }
    end
  end
  return result
end

--- Merge parent query files into child query files.
---
--- Only merges into child files listed in `inheriting_files` — i.e. files that
--- actually declared `; inherits: <parent_lang>`.  Other child files that did
--- not request inheritance from this parent are left untouched.
---
---@param child_lang       string
---@param parent_lang      string
---@param install_dir      string          base queries directory  (install_dir/queries/<lang>/)
---@param inheriting_files table<string, boolean>  set of basenames (e.g. "highlights.scm") to merge
function M._merge(child_lang, parent_lang, install_dir, inheriting_files)
  local parent_dir = vim.fs.joinpath(install_dir, parent_lang)
  local child_dir = vim.fs.joinpath(install_dir, child_lang)

  local parent_files = scm_files(parent_dir)
  if #parent_files == 0 then
    return
  end

  -- Ensure the child queries directory exists
  if not vim.uv.fs_stat(child_dir) then
    vim.fn.mkdir(child_dir, 'p')
  end

  for _, pfile in ipairs(parent_files) do
    local fname = vim.fs.basename(pfile)

    -- Only merge into files that declared `; inherits: <parent_lang>`
    if not inheriting_files[fname] then
      goto continue
    end

    local cfile = vim.fs.joinpath(child_dir, fname)

    local p_content = read_file(pfile)
    if not p_content then
      goto continue
    end

    -- Strip any leading `; inherits:` line from the parent content so that
    -- the merged file does not carry a stale directive.
    local p_clean
    do
      local first_line, rest = p_content:match('^([^\n]*)\n(.*)')
      if first_line and first_line:match(INHERITS_PATTERN) then
        p_clean = rest or ''
      else
        p_clean = p_content
      end
    end

    local child_content = read_file(cfile) -- nil if child file doesn't exist yet
    local merged

    if child_content then
      -- Strip child's leading `; inherits:` line (already resolved)
      local c_clean
      local first_line, rest = child_content:match('^([^\n]*)\n(.*)')
      if first_line and first_line:match(INHERITS_PATTERN) then
        c_clean = rest or ''
      else
        c_clean = child_content
      end

      merged = p_clean
      -- Ensure a single blank line between parent and child blocks
      if not p_clean:match('\n%s*$') then
        merged = merged .. '\n'
      end
      merged = merged .. '\n' .. c_clean
    else
      merged = p_clean
    end

    write_file(cfile, merged)

    ::continue::
  end
end

--- Resolve `; inherits:` directives for `lang` recursively.
---
--- After queries have been installed into `install_dir/queries/<lang>/`, call
--- this function to process all inheritance directives.  Parent languages are
--- resolved first (depth-first), and their content is merged into the child
--- via M._merge().
---
--- Cycle detection is handled via the `_visited` set (a `{ [lang]=true }` table
--- passed through recursive calls).  Optional parents that are not installed
--- are silently skipped.
---
---@param lang        string
---@param install_dir string   path to the queries root  (…/queries/)
---@param callback    fun()    called when resolution is complete
---@param _visited    table?   internal — do not pass from outside
function M.resolve(lang, install_dir, callback, _visited)
  _visited = _visited or {}

  -- Guard against cycles (e.g. ecma → javascript → ecma)
  if _visited[lang] then
    return vim.schedule(callback)
  end
  _visited[lang] = true

  local lang_dir = vim.fs.joinpath(install_dir, lang)
  local files = scm_files(lang_dir)

  -- Track which files declared inheritance from which parents.
  -- parents_info[parent_lang] = {
  --   optional = bool,
  --   files = { ["highlights.scm"] = true, ... }
  -- }
  local parents_info = {} ---@type table<string, { optional: boolean, files: table<string, boolean> }>
  local parents_order = {} ---@type string[]  insertion-ordered unique parent langs

  for _, scm_path in ipairs(files) do
    local fname = vim.fs.basename(scm_path)
    for _, directive in ipairs(M.parse_inherits(scm_path)) do
      local info = parents_info[directive.lang]
      if not info then
        info = { optional = directive.optional, files = {} }
        parents_info[directive.lang] = info
        parents_order[#parents_order + 1] = directive.lang
      end
      -- If any file makes the parent non-optional, keep it non-optional
      if not directive.optional then
        info.optional = false
      end
      info.files[fname] = true
    end
  end

  if #parents_order == 0 then
    return vim.schedule(callback)
  end

  -- Process parents sequentially (depth-first) to keep merge order
  -- deterministic.  Concurrent merges into the same file would race.
  local idx = 0

  local function next_parent()
    idx = idx + 1
    if idx > #parents_order then
      return callback()
    end

    local parent_lang = parents_order[idx]
    local info = parents_info[parent_lang]
    if not info then
      return callback()
    end

    -- Check whether the parent's query dir actually exists
    local parent_dir = vim.fs.joinpath(install_dir, parent_lang)
    if not vim.uv.fs_stat(parent_dir) then
      if info.optional then
        -- Skip silently
        return next_parent()
      else
        vim.notify(
          string.format(
            'nvim-treesitter/queries_resolver: %s inherits from %s, but %s queries are not installed',
            lang,
            parent_lang,
            parent_lang
          ),
          vim.log.levels.WARN
        )
        return next_parent()
      end
    end

    -- Recursively resolve the parent first, then merge only into files
    -- that declared `; inherits: <parent_lang>`.
    M.resolve(parent_lang, install_dir, function()
      M._merge(lang, parent_lang, install_dir, info.files)
      next_parent()
    end, _visited)
  end

  next_parent()
end

return M
