-- lua/nvim-treesitter/hosts.lua
-- Vendored host adapter for version discovery.
-- Originally derived from treesitter-parser-registry/lua/treesitter-registry/hosts.lua
--
-- Git host adapters: version-check APIs + tarball/raw-file URL construction.
--
-- Vendored copy of treesitter-registry/hosts.lua, uses vim.net.request for HTTP.
--
-- Version check strategy per host:
--   github.com  → GitHub REST API (releases/tags endpoints, no auth needed for
--                 public repos, generous rate limit vs git ls-remote)
--   gitlab.com  → GitLab REST API
--   others      → git ls-remote fallback (universal, no API token needed)

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Parse owner/repo from a git forge URL.
--- e.g. "https://github.com/tree-sitter/tree-sitter-rust" → "tree-sitter", "tree-sitter-rust"
---@param url string
---@return string?, string?
local function owner_repo(url)
  local owner, repo = url:match('^https?://[^/]+/([^/]+)/([^/]+)/*$')
  if repo then
    repo = repo:gsub('%.git$', '')
  end
  return owner, repo
end

--- HTTP GET via vim.net.request; calls callback(body, err).
---@param url      string
---@param headers  table<string,string>?  header key→value pairs
---@param callback fun(body: string?, err: string?)
local function http_get(url, headers, callback)
  vim.net.request(
    url,
    { headers = headers or {}, retry = 3 },
    vim.schedule_wrap(function(err, res)
      if err then
        callback(nil, err)
      elseif res and res.status >= 200 and res.status < 300 then
        callback(res.body, nil)
      else
        local status = res and res.status or 'unknown'
        local body = res and res.body or ''
        local http_err = 'HTTP ' .. tostring(status)
        if body and body ~= '' then
          http_err = http_err .. ': ' .. body
        end
        callback(nil, http_err)
      end
    end)
  )
end

--- Parse the latest semver tag from a list of tag objects.
--- Each object must have a `.name` field. Returns highest vX.Y.Z tag.
---@param tags any
---@return string?
local function latest_semver(tags)
  local best, best_parts
  for _, t in ipairs(tags) do
    local name = t.name or t.tag_name or ''
    local ma, mi, pa = name:match('^v?(%d+)%.(%d+)%.?(%d*)$')
    if ma then
      local parts = { tonumber(ma), tonumber(mi), tonumber(pa) or 0 }
      if
        not best_parts
        or parts[1] > best_parts[1]
        or (parts[1] == best_parts[1] and parts[2] > best_parts[2])
        or (parts[1] == best_parts[1] and parts[2] == best_parts[2] and parts[3] > best_parts[3])
      then
        best = name:match('^v') and name or ('v' .. name)
        best_parts = parts
      end
    end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- Host adapter interface
--
-- Each adapter implements:
--   latest_tag(url, callback)        → string? (latest semver tag e.g. "v0.25.0")
--   latest_head(url, branch, cb)     → string? (HEAD commit SHA or branch SHA)
--   tarball_url(url, ref)            → string? (nil = use git clone fallback)
--   raw_url(url, ref, path)          → string? (nil = use git archive fallback)
-- ---------------------------------------------------------------------------

---@class HostAdapter
---@field latest_tag   fun(url: string, callback: fun(tag: string?, err: string?)): any
---@field latest_head  fun(url: string, branch: string?, callback: fun(sha: string?, err: string?)): any
---@field tarball_url  fun(url: string, ref: string): string?
---@field raw_url      fun(url: string, ref: string, path: string): string?

-- ---------------------------------------------------------------------------
-- GitHub adapter
-- Uses REST API v3 — no auth required for public repos.
-- Rate limit: 60 req/hour unauthenticated, 5000/hour with GITHUB_TOKEN.
-- ---------------------------------------------------------------------------
local github = {}

function github.latest_tag(url, callback)
  local owner, repo = owner_repo(url)
  if not owner then
    callback(nil, 'could not parse owner/repo from: ' .. url)
    return
  end

  -- Try releases endpoint first (reflects official releases with semver tags)
  local api = string.format('https://api.github.com/repos/%s/%s/releases', owner, repo)
  local headers = {
    accept = 'application/vnd.github+json',
    ['x-github-api-version'] = '2022-11-28',
  }

  http_get(api, headers, function(body, err)
    if body then
      local ok, releases = pcall(vim.json.decode, body)
      if ok and type(releases) == 'table' and #releases > 0 then
        ---@cast releases table[]
        local tag = latest_semver(releases)
        if tag then
          callback(tag, nil)
          return
        end
      end
    end

    -- Fall back to tags endpoint
    local tags_api = string.format('https://api.github.com/repos/%s/%s/tags', owner, repo)
    http_get(tags_api, headers, function(tbody, terr)
      if not tbody then
        callback(nil, terr or err)
        return
      end
      local tok, tags = pcall(vim.json.decode, tbody)
      if not tok or type(tags) ~= 'table' then
        callback(nil, 'JSON decode failed')
        return
      end
      ---@cast tags table[]
      callback(latest_semver(tags), nil)
    end)
  end)
end

function github.latest_head(url, branch, callback)
  local owner, repo = owner_repo(url)
  if not owner then
    callback(nil, 'could not parse owner/repo from: ' .. url)
    return
  end

  local ref = branch or 'HEAD'
  local api = string.format('https://api.github.com/repos/%s/%s/commits/%s', owner, repo, ref)
  local headers = {
    accept = 'application/vnd.github+json',
    ['x-github-api-version'] = '2022-11-28',
  }

  http_get(api, headers, function(body, err)
    if not body then
      callback(nil, err)
      return
    end
    local ok, data = pcall(vim.json.decode, body)
    if ok and type(data) == 'table' and data.sha then
      ---@cast data table
      callback(data.sha, nil)
    else
      callback(nil, 'could not extract SHA from response')
    end
  end)
end

function github.tarball_url(url, ref)
  return url .. '/archive/' .. ref .. '.tar.gz'
end

function github.raw_url(url, ref, path)
  local raw = url:gsub('^https://github%.com/', 'https://raw.githubusercontent.com/')
  return raw .. '/' .. ref .. '/' .. path
end

-- ---------------------------------------------------------------------------
-- GitLab adapter
-- ---------------------------------------------------------------------------
local gitlab = {}

function gitlab.latest_tag(url, callback)
  local owner, repo = owner_repo(url)
  if not owner then
    callback(nil, 'could not parse: ' .. url)
    return
  end

  local encoded = vim.uri_encode and vim.uri_encode(owner .. '/' .. repo)
    or (owner .. '%2F' .. repo)
  local api = string.format('https://gitlab.com/api/v4/projects/%s/releases', encoded)

  http_get(api, { accept = 'application/json' }, function(body, err)
    if body then
      local ok, releases = pcall(vim.json.decode, body)
      if ok and type(releases) == 'table' and #releases > 0 then
        ---@cast releases table[]
        local tag = latest_semver(releases)
        if tag then
          callback(tag, nil)
          return
        end
      end
    end
    -- Fallback: tags API
    local tags_api = string.format(
      'https://gitlab.com/api/v4/projects/%s/repository/tags?order_by=version',
      encoded
    )
    http_get(tags_api, {}, function(tbody, terr)
      if not tbody then
        callback(nil, terr or err)
        return
      end
      local tok, tags = pcall(vim.json.decode, tbody)
      if not tok or type(tags) ~= 'table' then
        callback(nil, 'decode failed')
        return
      end
      ---@cast tags table[]
      callback(latest_semver(tags), nil)
    end)
  end)
end

function gitlab.latest_head(url, branch, callback)
  local owner, repo = owner_repo(url)
  if not owner then
    callback(nil, 'could not parse: ' .. url)
    return
  end
  local encoded = owner .. '%2F' .. repo
  local ref = branch or 'HEAD'
  local api =
    string.format('https://gitlab.com/api/v4/projects/%s/repository/commits/%s', encoded, ref)
  http_get(api, {}, function(body, err)
    if not body then
      callback(nil, err)
      return
    end
    local ok, data = pcall(vim.json.decode, body)
    if ok and type(data) == 'table' then
      ---@cast data table
      callback(data.id, nil)
    else
      callback(nil, 'decode failed')
    end
  end)
end

function gitlab.tarball_url(url, ref)
  local repo = url:match('/([^/]+)$')
  return url .. '/-/archive/' .. ref .. '/' .. repo .. '-' .. ref .. '.tar.gz'
end

function gitlab.raw_url(url, ref, path)
  return url .. '/-/raw/' .. ref .. '/' .. path
end

-- ---------------------------------------------------------------------------
-- Generic fallback adapter (git CLI, works for any host)
-- tarball_url / raw_url return nil → callers use git clone / git archive
-- ---------------------------------------------------------------------------
local generic = {}

function generic.latest_tag(url, callback)
  vim.system(
    {
      'git',
      '-c',
      'versionsort.suffix=-',
      'ls-remote',
      '--tags',
      '--refs',
      '--sort=v:refname',
      url,
    },
    { text = true, timeout = 10000 },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        return callback(nil, r.stderr)
      end
      local lines = vim.split(vim.trim(r.stdout), '\n')
      for i = #lines, 1, -1 do
        local tag = lines[i]:match('\trefs/tags/(v[%d%.]+)$')
        if tag then
          return callback(tag, nil)
        end
      end
      callback(nil, 'no semver tags found')
    end)
  )
end

function generic.latest_head(url, branch, callback)
  local cmd = { 'git', 'ls-remote', url }
  if branch then
    cmd[#cmd + 1] = 'refs/heads/' .. branch
  end
  vim.system(
    cmd,
    { text = true, timeout = 10000 },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        return callback(nil, r.stderr)
      end
      local lines = vim.split(vim.trim(r.stdout), '\n')
      local target = branch and ('refs/heads/' .. branch) or 'HEAD'
      for _, line in ipairs(lines) do
        local sha, ref = line:match('^(%x+)\t(.+)$')
        if sha and ref == target then
          return callback(sha, nil)
        end
      end
      -- last resort: first SHA on first line
      local sha = vim.split(lines[1] or '', '\t')[1]
      callback(sha ~= '' and sha or nil, sha == '' and 'empty response' or nil)
    end)
  )
end

function generic.tarball_url(_url, _ref)
  return nil
end
function generic.raw_url(_url, _ref, _path)
  return nil
end

-- ---------------------------------------------------------------------------
-- Adapter registry + resolver
-- ---------------------------------------------------------------------------

M._adapters = {
  ['github.com'] = github,
  ['gitlab.com'] = gitlab,
}

--- Return the adapter for a given repo URL.
---@param url string
---@return HostAdapter
function M.for_url(url)
  for host, adapter in pairs(M._adapters) do
    if url:find(host, 1, true) then
      return adapter
    end
  end
  return generic
end

--- Register a custom adapter for a git host.
--- Allows third-party installers to add Gitea/Forgejo/self-hosted support.
---@param hostname string  e.g. "codeberg.org"
---@param adapter  HostAdapter
function M.register(hostname, adapter)
  M._adapters[hostname] = adapter
end

-- Codeberg (Gitea) — same API shape as Gitea/Forgejo
M.register('codeberg.org', {
  latest_tag = function(url, cb)
    local owner, repo = owner_repo(url)
    if not owner then
      cb(nil, 'parse error')
      return
    end
    local api = string.format('https://codeberg.org/api/v1/repos/%s/%s/tags', owner, repo)
    http_get(api, {}, function(body, err)
      if not body then
        cb(nil, err)
        return
      end
      local ok, tags = pcall(vim.json.decode, body)
      if not ok or type(tags) ~= 'table' then
        cb(nil, nil)
        return
      end
      ---@cast tags table[]
      cb(latest_semver(tags), nil)
    end)
  end,
  latest_head = function(url, branch, cb)
    local owner, repo = owner_repo(url)
    if not owner then
      cb(nil, 'parse error')
      return
    end
    local ref = branch or 'HEAD'
    local api = string.format(
      'https://codeberg.org/api/v1/repos/%s/%s/commits?sha=%s&limit=1',
      owner,
      repo,
      ref
    )
    http_get(api, {}, function(body, err)
      if not body then
        cb(nil, err)
        return
      end
      local ok, data = pcall(vim.json.decode, body)
      if not ok or type(data) ~= 'table' then
        cb(nil, nil)
        return
      end
      ---@cast data table[]
      cb(data[1] and data[1].sha or nil, nil)
    end)
  end,
  tarball_url = function(url, ref)
    return url .. '/archive/' .. ref .. '.tar.gz'
  end,
  raw_url = function(url, ref, path)
    return url .. '/raw/branch/' .. ref .. '/' .. path
  end,
})

return M
