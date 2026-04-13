-- lua/nvim-treesitter/version.lua
-- Version discovery for parser and query repositories.
--
-- Uses the vendored hosts adapter at:
--   lua/nvim-treesitter/hosts.lua
-- which itself uses treesitter-registry/http.lua (vim.system + curl) for all HTTP traffic.
--
-- Public API:
--   M.latest_parser(lang, source, callback)
--   M.latest_queries(lang, source, callback)
--   M.refresh_all(registry, langs, cache, on_done)

local hosts = require('treesitter-registry.hosts')

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Choose between semver tag lookup and HEAD SHA lookup based on the
--- `*_semver` flag in the registry source entry.
---
--- When use_semver is true but the repo has no semver tags yet (e.g. a new
--- query repo that hasn't been released), falls back to latest_head so the
--- install can proceed using the HEAD SHA.
---
---@param url         string
---@param use_semver  boolean   true  → latest_tag (with HEAD fallback); false → latest_head
---@param branch      string?   branch hint for HEAD lookup
---@param callback    fun(version: string?, err: string?)
local function resolve_version(url, use_semver, branch, callback)
  local adapter = hosts.for_url(url)
  if use_semver then
    adapter.latest_tag(url, function(tag, err)
      if tag then
        return callback(tag, nil)
      end
      -- No semver tags found (e.g. repo not yet released) — fall back to HEAD.
      adapter.latest_head(url, branch, callback)
    end)
  else
    adapter.latest_head(url, branch, callback)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Discover the latest parser version for a registry source entry.
---
---@param lang     string   language name (used only in error messages)
---@param source   table    registry source entry with parser_url / parser_semver
---@param callback fun(version: string?, err: string?)
function M.latest_parser(lang, source, callback)
  -- external_queries uses source.parser_url; self_contained uses source.url
  local url = source and (source.parser_url or source.url)
  if not url then
    return callback(nil, 'no parser_url for ' .. lang)
  end
  local use_semver = (source.parser_semver == true) or (source.semver == true)
  resolve_version(
    url,
    use_semver,
    source.parser_branch, -- optional hint; nil → default branch
    callback
  )
end

--- Discover the latest queries version for a registry source entry.
--- Falls back to the parser_url when no separate queries_url is provided.
---
---@param lang     string
---@param source   table    registry source entry with queries_url / queries_semver
---@param callback fun(version: string?, err: string?)
function M.latest_queries(lang, source, callback)
  if not source then
    return callback(nil, 'no source for ' .. lang)
  end
  -- external_queries: queries_url, self_contained/queries_only: url, fallback to parser_url
  local url = source.queries_url or source.url or source.parser_url
  local use_semver = source.queries_semver == true or source.semver == true
  local branch = source.queries_branch or source.parser_branch
  if not url then
    return callback(nil, 'no queries_url or parser_url for ' .. lang)
  end
  resolve_version(url, use_semver, branch, callback)
end

-- ---------------------------------------------------------------------------
-- Bulk refresh with bounded concurrency
-- ---------------------------------------------------------------------------

--- Semaphore: allows at most `limit` concurrent operations.
---
---@param limit integer
---@return { acquire: fun(cb: fun()), release: fun() }
local function semaphore(limit)
  local count = 0
  local queue = {}

  local function release()
    count = count - 1
    if #queue > 0 then
      local next_cb = table.remove(queue, 1)
      count = count + 1
      vim.schedule(next_cb) -- run in next event-loop tick to avoid deep stacks
    end
  end

  local function acquire(cb)
    if count < limit then
      count = count + 1
      vim.schedule(cb)
    else
      queue[#queue + 1] = cb
    end
  end

  return { acquire = acquire, release = release }
end

--- Refresh stale cache entries for a list of languages.
---
--- Fires up to `max_concurrency` (default 10) parallel host requests.
--- When all refreshes complete (or fail), calls `on_done(updated_cache)`.
---
--- The cache table is mutated in-place and also returned via on_done so
--- callers can save it immediately.
---
---@param registry        table     full registry table from registry.loaded
---@param langs           string[]  languages to refresh
---@param cache           table     cache table from cache.load()
---@param on_done         fun(cache: table)
---@param max_concurrency integer?  defaults to 10
function M.refresh_all(registry, langs, cache, on_done, max_concurrency)
  local limit = max_concurrency or 10
  local sem = semaphore(limit)
  local pending = #langs
  local parsers = cache.parsers or {}
  cache.parsers = parsers

  if pending == 0 then
    return vim.schedule(function()
      on_done(cache)
    end)
  end

  local function finish()
    pending = pending - 1
    if pending == 0 then
      vim.schedule(function()
        on_done(cache)
      end)
    end
  end

  for _, lang in ipairs(langs) do
    local entry = registry[lang]
    if not entry or not entry.source then
      -- Nothing in the registry for this lang — mark checked to avoid retrying
      parsers[lang] = vim.tbl_extend('force', parsers[lang] or {}, {
        checked_at = os.time(),
      })
      finish()
    else
      local source = entry.source

      -- We need two async lookups (parser + queries); coordinate with a small
      -- inner counter so we only call finish() once per lang.
      local inner_done = 0
      local parser_ver = nil ---@type string?
      local queries_ver = nil ---@type string?

      local function inner_finish()
        inner_done = inner_done + 1
        if inner_done == 2 then
          -- Only update checked_at when at least one version was resolved.
          -- If both are nil (e.g. transient network error or rate-limit)
          -- leave the entry stale so the next install retries the lookup.
          if parser_ver or queries_ver then
            -- Build update table with only non-nil versions so that a
            -- partial success (one resolved, one failed) does not overwrite
            -- a previously cached value with nil.
            local update = { checked_at = os.time() }
            if parser_ver then
              update.latest_parser = parser_ver
            end
            if queries_ver then
              update.latest_queries = queries_ver
            end
            parsers[lang] = vim.tbl_extend('force', parsers[lang] or {}, update)
          end
          sem.release()
          finish()
        end
      end

      sem.acquire(function()
        -- For self_contained parsers the parser and queries live in the same
        -- repo (same URL, same semver flag, same branch).  Avoid making two
        -- identical API calls — resolve once and use the result for both.
        local same_repo = source.type == 'self_contained'
          or (source.parser_url or source.url)
            == (source.queries_url or source.url or source.parser_url)

        M.latest_parser(lang, source, function(ver, err)
          if not ver and err then
            io.stderr:write(
              string.format(
                '[nvim-treesitter/version] %s: parser version lookup failed: %s\n',
                lang,
                err
              )
            )
          end
          parser_ver = ver
          if same_repo then
            queries_ver = ver
            inner_finish()
          end
          inner_finish()
        end)

        if not same_repo then
          M.latest_queries(lang, source, function(ver, err)
            if not ver and err then
              io.stderr:write(
                string.format(
                  '[nvim-treesitter/version] %s: queries version lookup failed: %s\n',
                  lang,
                  err
                )
              )
            end
            queries_ver = ver
            inner_finish()
          end)
        end
      end)
    end
  end
end

return M
