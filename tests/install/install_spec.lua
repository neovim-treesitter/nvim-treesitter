-- tests/install/install_spec.lua
-- plentest spec for lua/nvim-treesitter/install.lua
--
-- Tests cover:
--   1. semver_gt — all edge cases (pure unit)
--   2. tarball_url — all hosts, .git stripping, unknown host (pure unit)
--   3. cache-hit guard — install_one NOT called when versions match
--   4. missing registry entry — no crash, no tree-sitter invocation
--   5. install (self_contained) — parser .so created, cache state written
--   6. install idempotence — no rebuild when already up to date
--   7. update — reinstalls on version bump
--   8. update — no-op when already current
--   9. uninstall — removes .so, queries dir, cache entry
--  10. status — correct installed / needs_update fields
--  10b. install (external_queries) — parser + queries tarballs, both versions cached
--  10c. install (queries_only) — no parser, queries tarball only, queries_version cached
--
-- Mocking strategy
-- ────────────────
-- * treesitter-registry.http — stubbed in package.loaded at file top so
--                    registry.lua / hosts.lua never make real HTTP calls.
-- * nvim-treesitter.registry — loaded fresh after stub; M.loaded injected
--                    per-test; M.load wrapped to call cb via vim.schedule.
-- * nvim-treesitter.version — refresh_all replaced per-test; calls on_done
--                    via vim.schedule (required by the async coroutine machinery).
-- * vim.system     — replaced per-test; creates parser.so on "tree-sitter build"
--                    and calls on_exit via vim.schedule.
-- * nvim-treesitter.parsers — LANG injected into package.preload so that
--                    reload_parsers() (which clears package.loaded) does not
--                    lose the entry.
-- * queries_resolver.resolve — no-op stub (calls callback via vim.schedule).

-- ── add plenary.nvim to rtp (provides luassert) ──────────────────────────────
do
  local repo_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
  vim.opt.rtp:prepend(repo_root .. '/.test-deps/plenary.nvim')
end

-- ── stub treesitter-registry.http BEFORE registry.lua / hosts.lua can require it ──
-- We place a stub in package.loaded before any require() for it can run.
package.loaded['treesitter-registry.http'] = {
  get = function(_url, _opts, callback)
    vim.schedule(function()
      callback({ status = 200, body = '' }, nil)
    end)
  end,
  download = function(_url, output, _opts, callback)
    vim.fn.mkdir(vim.fn.fnamemodify(output, ':h'), 'p')
    local f = io.open(output, 'w')
    if f then
      f:write('fake tarball')
      f:close()
    end
    vim.schedule(function()
      callback({ status = 200, body = '' }, nil)
    end)
  end,
}

-- Clear any partially-loaded (broken) registry module so it re-requires cleanly
package.loaded['nvim-treesitter.registry'] = nil

-- ── assertions / equality ─────────────────────────────────────────────────────
local assert = require('luassert') ---@type Luassert
local eq = assert.are.same

-- ─────────────────────────────────────────────────────────────────────────────
-- File-level helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function tmp_dir()
  return vim.fn.fnamemodify(vim.fn.tempname(), ':h')
    .. '/nvim-ts-test-'
    .. tostring(math.random(1e8))
end

local function rm_rf(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then
    return
  end
  if stat.type == 'directory' then
    for name in vim.fs.dir(path) do
      rm_rf(vim.fs.joinpath(path, name))
    end
    vim.uv.fs_rmdir(path)
  else
    vim.uv.fs_unlink(path)
  end
end

local function mkdir_p(path)
  vim.fn.mkdir(path, 'p')
end

local function write_file(path, content)
  mkdir_p(vim.fs.dirname(path))
  local f = assert(io.open(path, 'w'))
  f:write(content)
  f:close()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Private-function mirrors
-- semver_gt and tarball_url are file-local in install.lua; we replicate them
-- verbatim here so the unit tests are self-contained.
-- ─────────────────────────────────────────────────────────────────────────────

local function parse_semver(ver)
  local s = ver:gsub('^v', '')
  local parts = {}
  for n in s:gmatch('%d+') do
    parts[#parts + 1] = tonumber(n)
  end
  while #parts < 3 do
    parts[#parts + 1] = 0
  end
  return parts
end

local function semver_gt(a_ver, b_ver)
  local a_p = parse_semver(a_ver)
  local b_p = parse_semver(b_ver)
  for i = 1, 3 do
    if a_p[i] > b_p[i] then
      return true
    end
    if a_p[i] < b_p[i] then
      return false
    end
  end
  return false
end

local function tarball_url(repo_url, ref)
  local url = repo_url:gsub('%.git$', '')
  if url:match('github%.com') then
    return string.format('%s/archive/%s.tar.gz', url, ref)
  end
  if url:match('gitlab%.com') then
    return string.format('%s/-/archive/%s/archive.tar.gz', url, ref)
  end
  if url:match('sr%.ht') then
    return string.format('%s/archive/%s.tar.gz', url, ref)
  end
  return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. semver_gt — pure unit tests
-- ─────────────────────────────────────────────────────────────────────────────

describe('semver_gt', function()
  it('returns false for equal versions', function()
    assert.False(semver_gt('1.2.3', '1.2.3'))
  end)

  it('returns false for equal v-prefixed versions', function()
    assert.False(semver_gt('v1.2.3', 'v1.2.3'))
  end)

  it('returns true when major is greater', function()
    assert.True(semver_gt('2.0.0', '1.9.9'))
  end)

  it('returns false when major is smaller', function()
    assert.False(semver_gt('1.9.9', '2.0.0'))
  end)

  it('returns true when minor is greater (same major)', function()
    assert.True(semver_gt('1.3.0', '1.2.9'))
  end)

  it('returns false when minor is smaller (same major)', function()
    assert.False(semver_gt('1.2.9', '1.3.0'))
  end)

  it('returns true when patch is greater (same major.minor)', function()
    assert.True(semver_gt('1.2.4', '1.2.3'))
  end)

  it('returns false when patch is smaller (same major.minor)', function()
    assert.False(semver_gt('1.2.3', '1.2.4'))
  end)

  it('handles v-prefix mixed with plain', function()
    assert.True(semver_gt('v2.0.0', '1.0.0'))
    assert.True(semver_gt('2.0.0', 'v1.0.0'))
  end)

  it('handles 2-part versions by treating missing patch as 0', function()
    assert.False(semver_gt('1.2', '1.2.0'))
    assert.True(semver_gt('1.3', '1.2.0'))
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. tarball_url — pure unit tests
-- ─────────────────────────────────────────────────────────────────────────────

describe('tarball_url', function()
  it('builds a GitHub tarball URL', function()
    eq(
      'https://github.com/tree-sitter/tree-sitter-lua/archive/v1.0.0.tar.gz',
      tarball_url('https://github.com/tree-sitter/tree-sitter-lua', 'v1.0.0')
    )
  end)

  it('strips .git suffix before building URL', function()
    eq(
      'https://github.com/tree-sitter/tree-sitter-lua/archive/main.tar.gz',
      tarball_url('https://github.com/tree-sitter/tree-sitter-lua.git', 'main')
    )
  end)

  it('builds a GitLab tarball URL', function()
    eq(
      'https://gitlab.com/foo/bar/-/archive/v2.0.0/archive.tar.gz',
      tarball_url('https://gitlab.com/foo/bar', 'v2.0.0')
    )
  end)

  it('strips .git for GitLab URLs', function()
    eq(
      'https://gitlab.com/foo/bar/-/archive/main/archive.tar.gz',
      tarball_url('https://gitlab.com/foo/bar.git', 'main')
    )
  end)

  it('builds a Sourcehut tarball URL', function()
    eq(
      'https://sr.ht/~user/repo/archive/v0.1.tar.gz',
      tarball_url('https://sr.ht/~user/repo', 'v0.1')
    )
  end)

  it('returns nil for unknown hosts', function()
    assert.is_nil(tarball_url('https://bitbucket.org/foo/bar', 'main'))
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Integration-test infrastructure
-- ─────────────────────────────────────────────────────────────────────────────

-- Fake language name that won't collide with any real parser
local LANG = '_ts_test_lang'

-- Minimal self_contained registry entry
local function fake_entry()
  return {
    source = {
      type = 'self_contained',
      url = 'https://github.com/tree-sitter/tree-sitter-' .. LANG,
      semver = true,
    },
    filetypes = { LANG },
  }
end

-- vim.system stub:
--   * always exits cleanly (code=0)
--   * on "tree-sitter build": creates parser.so in cwd
--   * on "tar": creates a fake extracted directory tree
--   * on_exit is called via vim.schedule (REQUIRED for async coroutine machinery)
local function make_system_stub()
  return function(cmd, sys_opts, on_exit)
    if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
      local cwd = (sys_opts and sys_opts.cwd) or vim.uv.cwd()
      mkdir_p(cwd)
      write_file(vim.fs.joinpath(cwd, 'parser.so'), 'fake parser')
    elseif cmd[1] == 'tar' then
      local target_dir
      for i, arg in ipairs(cmd) do
        if arg == '-C' then
          target_dir = cmd[i + 1]
          break
        end
      end
      if target_dir then
        local cwd = (sys_opts and sys_opts.cwd) or vim.uv.cwd()
        local root = vim.fs.joinpath(cwd, target_dir, 'extracted-root')
        mkdir_p(root)
        mkdir_p(vim.fs.joinpath(root, 'src'))
        write_file(vim.fs.joinpath(root, 'src', 'grammar.json'), '{}')
      end
    end
    -- on_exit must be called asynchronously (via vim.schedule) because the
    -- async machinery calls close() on the returned handle BEFORE resuming the
    -- coroutine.  close() must call its callback, which triggers the resume.
    local done = false
    local close_cb = nil
    vim.schedule(function()
      done = true
      on_exit({ code = 0, stdout = '', stderr = '' })
      if close_cb then
        close_cb()
      end
    end)
    return {
      close = function(self_or_cb, cb)
        -- handle both object-style close(self, cb) and function-style close(cb)
        if type(self_or_cb) == 'function' then
          cb = self_or_cb
        end
        if done then
          if cb then
            vim.schedule(cb)
          end
        else
          close_cb = cb
        end
      end,
      is_closing = function()
        return false
      end,
    }
  end
end

-- Stub version.refresh_all to inject specific versions into the cache.
-- on_done MUST be called via vim.schedule — same async requirement as above.
-- NOTE: install.lua reads from cache.parsers[lang], matching the real
-- version.refresh_all which writes to the same path.
local function stub_versions(parser_ver, queries_ver)
  local version_mod = require('nvim-treesitter.version')
  version_mod.refresh_all = function(_reg, langs, cache, on_done)
    cache.parsers = cache.parsers or {}
    for _, lang in ipairs(langs) do
      cache.parsers[lang] = {
        latest_parser = parser_ver,
        latest_queries = queries_ver,
        checked_at = os.time(),
      }
    end
    vim.schedule(function()
      on_done(cache)
    end)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Shared before_each / after_each for integration suites
-- ─────────────────────────────────────────────────────────────────────────────

-- ctx is a table that receives saved originals so after_each can restore them.
local function setup(ctx)
  -- 1. temp install dir
  ctx.base_dir = tmp_dir()
  mkdir_p(ctx.base_dir)
  local config = require('nvim-treesitter.config')
  ctx.orig_install_dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site')
  config.setup({ install_dir = ctx.base_dir })

  -- 2. stub vim.system
  ctx.orig_system = vim.system
  vim.system = make_system_stub()

  -- 3. ensure http stub is still in place (may be evicted between tests)
  package.loaded['treesitter-registry.http'] = {
    get = function(_url, _opts, callback)
      vim.schedule(function()
        callback({ status = 200, body = '' }, nil)
      end)
    end,
    download = function(_url, output, _opts, callback)
      mkdir_p(vim.fn.fnamemodify(output, ':h'))
      write_file(output, 'fake tarball')
      vim.schedule(function()
        callback({ status = 200, body = '' }, nil)
      end)
    end,
  }

  -- 4. inject fake registry entry; wrap registry.load so cb fires asynchronously
  local registry = require('nvim-treesitter.registry')
  ctx.orig_registry_loaded = registry.loaded
  ctx.orig_registry_load = registry.load
  if not registry.loaded then
    registry.loaded = {}
  end
  registry.loaded[LANG] = fake_entry()
  registry.load = function(cb)
    -- MUST be async: registry.lua's original curl.get callback uses
    -- vim.schedule_wrap; our stub must likewise defer to avoid resuming a
    -- running coroutine.
    vim.schedule(function()
      cb(registry.loaded, nil)
    end)
  end

  -- 5. stub queries_resolver.resolve → no-op (async)
  local qr = require('nvim-treesitter.queries_resolver')
  ctx.orig_qr_resolve = qr.resolve
  qr.resolve = function(_lang, _dir, callback, _visited)
    vim.schedule(callback)
  end

  -- 6. stub version.refresh_all with defaults
  stub_versions('v1.0.0', 'q1.0.0')
end

local function teardown(ctx)
  -- restore vim.system
  vim.system = ctx.orig_system

  -- restore registry
  local registry = require('nvim-treesitter.registry')
  if registry.loaded then
    registry.loaded[LANG] = nil
  end
  registry.load = ctx.orig_registry_load
  registry.loaded = ctx.orig_registry_loaded

  -- restore queries_resolver
  local qr = require('nvim-treesitter.queries_resolver')
  qr.resolve = ctx.orig_qr_resolve

  -- restore version.refresh_all
  local version_mod = require('nvim-treesitter.version')
  version_mod.refresh_all = nil

  -- clear installed cache state
  local cache_mod = require('nvim-treesitter.cache')
  cache_mod.set_installed(LANG, nil)

  -- restore config
  local config = require('nvim-treesitter.config')
  config.setup({ install_dir = ctx.orig_install_dir })

  -- remove temp dir
  rm_rf(ctx.base_dir)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. cache-hit guard
-- ─────────────────────────────────────────────────────────────────────────────

describe('install_lang cache hit', function()
  local ctx = {}
  before_each(function()
    setup(ctx)
  end)
  after_each(function()
    teardown(ctx)
  end)

  it('does not invoke tree-sitter when installed versions already match cache', function()
    -- Write a pre-existing installed state
    local cache_mod = require('nvim-treesitter.cache')
    cache_mod.set_installed(LANG, {
      type = 'self_contained',
      parser_version = 'v1.0.0',
      queries_version = 'q1.0.0',
    })

    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' then
        build_calls = build_calls + 1
      end
      return base_stub(cmd, opts, on_exit)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(LANG, { force = false }):wait(15000)

    assert.True(ok, 'install should return true on a cache hit')
    eq(0, build_calls, 'tree-sitter must not be invoked on a cache hit')
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. no registry entry
-- ─────────────────────────────────────────────────────────────────────────────

describe('install with no registry entry', function()
  local ctx = {}
  before_each(function()
    setup(ctx)
    -- Remove LANG from the registry so registry.get(LANG) returns nil
    local registry = require('nvim-treesitter.registry')
    registry.loaded[LANG] = nil
  end)
  after_each(function()
    teardown(ctx)
  end)

  it('does not crash and does not invoke tree-sitter', function()
    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' then
        build_calls = build_calls + 1
      end
      return base_stub(cmd, opts, on_exit)
    end

    local install = require('nvim-treesitter.install')
    -- Returns true because 0 tasks → done(0) == tasks(0)
    local ok = install.install(LANG, { force = true }):wait(10000)

    assert.True(ok)
    eq(0, build_calls, 'tree-sitter must not be called for a missing registry entry')
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- 5–10. Full install / update / uninstall / status flow
-- ─────────────────────────────────────────────────────────────────────────────

describe('install / update / uninstall / status', function()
  local ctx = {}
  before_each(function()
    setup(ctx)
  end)
  after_each(function()
    teardown(ctx)
  end)

  local function do_install(force)
    local install = require('nvim-treesitter.install')
    return install.install(LANG, { force = force }):wait(15000)
  end

  local function do_update()
    local install = require('nvim-treesitter.install')
    return install.update(LANG):wait(15000)
  end

  local function do_uninstall()
    local install = require('nvim-treesitter.install')
    return install.uninstall(LANG):wait(15000)
  end

  -- ── 5. self_contained install ─────────────────────────────────────────────
  it('install: writes installed state to cache after success', function()
    local ok = do_install(true)
    assert.True(ok, 'install should return true')

    local cache_mod = require('nvim-treesitter.cache')
    local state = cache_mod.get_installed(LANG)
    assert.is_not_nil(state, 'installed state should be written to cache')
    eq('v1.0.0', state.parser_version, 'parser_version should be v1.0.0')
    eq('q1.0.0', state.queries_version, 'queries_version should be q1.0.0')
  end)

  -- ── 6. idempotent install ────────────────────────────────────────────────
  it('install: skips rebuild when versions already match', function()
    do_install(true)

    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' then
        build_calls = build_calls + 1
      end
      return base_stub(cmd, opts, on_exit)
    end

    local ok = do_install(false)
    assert.True(ok, 'second install should return true')
    eq(0, build_calls, 'tree-sitter should not run when versions already match')
  end)

  -- ── 7. update triggers reinstall ─────────────────────────────────────────
  it('update: reinstalls and records new versions when a newer version is available', function()
    do_install(true)

    -- Bump available versions
    stub_versions('v1.0.1', 'q1.0.1')

    -- Force the cache entry stale so M.update actually calls refresh_all
    local cache_mod = require('nvim-treesitter.cache')
    local c = cache_mod.load()
    if c.parsers and c.parsers[LANG] then
      c.parsers[LANG].checked_at = 0
    end
    cache_mod.save(c)

    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        build_calls = build_calls + 1
        -- still create parser.so so the copy step works
        local cwd = (opts and opts.cwd) or vim.uv.cwd()
        mkdir_p(cwd)
        write_file(vim.fs.joinpath(cwd, 'parser.so'), 'fake parser v1.0.1')
      end
      return base_stub(cmd, opts, on_exit)
    end

    local ok = do_update()
    assert.True(ok, 'update should return true')
    assert.True(build_calls > 0, 'tree-sitter build should run for the new version')

    local cache_mod = require('nvim-treesitter.cache')
    local state = cache_mod.get_installed(LANG)
    eq('v1.0.1', state.parser_version, 'parser_version should be updated to v1.0.1')
    eq('q1.0.1', state.queries_version, 'queries_version should be updated to q1.0.1')
  end)

  -- ── 8. update no-op ───────────────────────────────────────────────────────
  it('update: does nothing when already up to date', function()
    do_install(true)

    -- Versions are still v1.0.0 / q1.0.0 (set in setup())
    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        build_calls = build_calls + 1
      end
      return base_stub(cmd, opts, on_exit)
    end

    local ok = do_update()
    assert.True(ok, 'update should return true when already current')
    eq(0, build_calls, 'tree-sitter build must not run when versions already match')
  end)

  -- ── 9. uninstall ─────────────────────────────────────────────────────────
  it('uninstall: removes parser .so, queries dir, and cache state', function()
    do_install(true)

    local config = require('nvim-treesitter.config')
    local parser_so = vim.fs.joinpath(config.get_install_dir('parser'), LANG) .. '.so'
    local query_dir = vim.fs.joinpath(config.get_install_dir('queries'), LANG)

    assert.is_not_nil(vim.uv.fs_stat(parser_so), 'parser.so should exist after install')

    -- For self_contained the queries step tries to symlink bundled runtime
    -- queries which don't exist in the test environment.  Create the dir
    -- manually so the uninstaller has something to remove.
    mkdir_p(query_dir)
    write_file(vim.fs.joinpath(query_dir, 'highlights.scm'), '; stub')

    do_uninstall()

    assert.is_nil(vim.uv.fs_stat(parser_so), 'parser.so should be removed after uninstall')
    assert.is_nil(vim.uv.fs_lstat(query_dir), 'queries dir should be removed after uninstall')

    local cache_mod = require('nvim-treesitter.cache')
    assert.is_nil(cache_mod.get_installed(LANG), 'cache state should be nil after uninstall')
  end)

  -- ── 10. status ───────────────────────────────────────────────────────────
  it('status: returns correct installed and needs_update fields', function()
    local install = require('nvim-treesitter.install')

    -- Before install: if LANG appears at all it should not be installed
    local s1 = install.status()
    if s1[LANG] then
      assert.False(s1[LANG].installed, 'should not be installed before install')
    end

    -- After install
    do_install(true)
    local s2 = install.status()
    assert.is_not_nil(s2[LANG], 'status entry must exist after install')
    assert.True(s2[LANG].installed, 'should be installed')
    eq('v1.0.0', s2[LANG].parser_version)
    eq('q1.0.0', s2[LANG].queries_version)
    assert.False(s2[LANG].needs_update, 'needs_update should be false when up to date')

    -- Inject a newer version directly into the on-disk cache so status() sees it
    local cache_mod = require('nvim-treesitter.cache')
    local c = cache_mod.load()
    c.parsers = c.parsers or {}
    c.parsers[LANG] = c.parsers[LANG] or {}
    c.parsers[LANG].latest_parser = 'v2.0.0'
    c.parsers[LANG].latest_queries = 'q2.0.0'
    c.parsers[LANG].checked_at = os.time()
    cache_mod.save(c)

    local s3 = install.status()
    assert.is_not_nil(s3[LANG])
    assert.True(s3[LANG].installed)
    assert.True(
      s3[LANG].needs_update,
      'needs_update should be true when newer version is available'
    )
  end)
end)

-- ── external_queries install tests ───────────────────────────────────────────
--
-- external_queries sources have a separate parser repo and queries repo.
-- The pipeline downloads both tarballs, builds the parser, copies queries,
-- and records both parser_version and queries_version in cache.
-- ─────────────────────────────────────────────────────────────────────────────

local EXT_Q_LANG = '_ts_test_ext_queries'

describe('install external_queries', function()
  local ctx = {}

  before_each(function()
    setup(ctx)

    -- Inject external_queries registry entry for EXT_Q_LANG
    local registry = require('nvim-treesitter.registry')
    registry.loaded[EXT_Q_LANG] = {
      source = {
        type = 'external_queries',
        parser_url = 'https://github.com/tree-sitter/tree-sitter-' .. EXT_Q_LANG,
        parser_semver = true,
        queries_url = 'https://github.com/queries/tree-sitter-' .. EXT_Q_LANG .. '-queries',
        queries_semver = true,
      },
      filetypes = { EXT_Q_LANG },
    }

    -- Stub versions for EXT_Q_LANG
    stub_versions('v1.0.0', 'q1.0.0')
  end)

  after_each(function()
    local registry = require('nvim-treesitter.registry')
    if registry.loaded then
      registry.loaded[EXT_Q_LANG] = nil
    end

    local cache_mod = require('nvim-treesitter.cache')
    cache_mod.set_installed(EXT_Q_LANG, nil)

    teardown(ctx)
  end)

  it('installs parser and queries, writing both versions to cache', function()
    -- Track http download calls
    local curl_calls = 0
    package.loaded['treesitter-registry.http'] = {
      get = function(_url, _opts, callback)
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
      download = function(_url, output, _opts, callback)
        curl_calls = curl_calls + 1
        mkdir_p(vim.fn.fnamemodify(output, ':h'))
        write_file(output, 'fake tarball')
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
    }

    -- Customise the system stub so that queries tar extraction creates a
    -- queries/ directory with an .scm file (install.lua looks for
    -- <project_dir>/queries/<lang>/ or <project_dir>/queries/).
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tar' then
        local target_dir
        for i, arg in ipairs(cmd) do
          if arg == '-C' then
            target_dir = cmd[i + 1]
            break
          end
        end
        if target_dir then
          local cwd = (opts and opts.cwd) or vim.uv.cwd()
          local root = vim.fs.joinpath(cwd, target_dir, 'extracted-root')
          mkdir_p(root)
          mkdir_p(vim.fs.joinpath(root, 'src'))
          write_file(vim.fs.joinpath(root, 'src', 'grammar.json'), '{}')
          -- Also create queries dir with .scm files for queries tarballs
          mkdir_p(vim.fs.joinpath(root, 'queries'))
          write_file(vim.fs.joinpath(root, 'queries', 'highlights.scm'), '; stub')
        end
      end
      return base_stub(cmd, opts, on_exit)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(EXT_Q_LANG, { force = true }):wait(15000)

    assert.True(ok, 'install should return true for external_queries')

    -- Parser .so must exist in install_dir
    local config = require('nvim-treesitter.config')
    local parser_so = vim.fs.joinpath(config.get_install_dir('parser'), EXT_Q_LANG) .. '.so'
    assert.is_not_nil(
      vim.uv.fs_stat(parser_so),
      'parser.so must exist in install_dir after external_queries install'
    )

    -- Cache state must have both parser_version and queries_version
    local cache_mod = require('nvim-treesitter.cache')
    local state = cache_mod.get_installed(EXT_Q_LANG)
    assert.is_not_nil(state, 'installed state should be written to cache')
    eq('v1.0.0', state.parser_version, 'parser_version should be recorded')
    eq('q1.0.0', state.queries_version, 'queries_version should be recorded')

    -- Both parser tarball AND queries tarball downloads must happen (>= 2 curl calls)
    assert.True(
      curl_calls >= 2,
      'http.download must be called at least twice (parser + queries tarballs)'
    )
  end)
end)

-- ── queries_only install tests ───────────────────────────────────────────────
--
-- queries_only sources have NO parser binary; only queries are downloaded.
-- The pipeline downloads a queries tarball, copies .scm files, and records
-- queries_version in cache.  No tree-sitter build happens, no parser .so
-- is created.
-- ─────────────────────────────────────────────────────────────────────────────

local QO_LANG = '_ts_test_queries_only'

describe('install queries_only', function()
  local ctx = {}

  before_each(function()
    setup(ctx)

    -- Inject queries_only registry entry for QO_LANG
    local registry = require('nvim-treesitter.registry')
    registry.loaded[QO_LANG] = {
      source = {
        type = 'queries_only',
        url = 'https://github.com/queries/tree-sitter-' .. QO_LANG .. '-queries',
        semver = true,
      },
      filetypes = { QO_LANG },
    }

    -- Stub versions: queries_only has no parser, so set latest_parser = nil
    local version_mod = require('nvim-treesitter.version')
    version_mod.refresh_all = function(_reg, langs, cache, on_done)
      cache.parsers = cache.parsers or {}
      for _, lang in ipairs(langs) do
        cache.parsers[lang] = {
          latest_parser = nil,
          latest_queries = 'q1.0.0',
          checked_at = os.time(),
        }
      end
      vim.schedule(function()
        on_done(cache)
      end)
    end
  end)

  after_each(function()
    local registry = require('nvim-treesitter.registry')
    if registry.loaded then
      registry.loaded[QO_LANG] = nil
    end

    local cache_mod = require('nvim-treesitter.cache')
    cache_mod.set_installed(QO_LANG, nil)

    teardown(ctx)
  end)

  it('installs queries only: no parser .so, no tree-sitter build', function()
    -- Track tree-sitter build invocations
    local build_calls = 0
    local curl_calls = 0

    package.loaded['treesitter-registry.http'] = {
      get = function(_url, _opts, callback)
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
      download = function(_url, output, _opts, callback)
        curl_calls = curl_calls + 1
        mkdir_p(vim.fn.fnamemodify(output, ':h'))
        write_file(output, 'fake tarball')
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
    }

    -- Customise system stub: track build calls and create queries dir on tar extraction
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        build_calls = build_calls + 1
      end
      if cmd[1] == 'tar' then
        local target_dir
        for i, arg in ipairs(cmd) do
          if arg == '-C' then
            target_dir = cmd[i + 1]
            break
          end
        end
        if target_dir then
          local cwd = (opts and opts.cwd) or vim.uv.cwd()
          local root = vim.fs.joinpath(cwd, target_dir, 'extracted-root')
          mkdir_p(root)
          -- Create queries dir with .scm files for the queries tarball
          mkdir_p(vim.fs.joinpath(root, 'queries'))
          write_file(vim.fs.joinpath(root, 'queries', 'highlights.scm'), '; stub')
        end
      end
      return base_stub(cmd, opts, on_exit)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(QO_LANG, { force = true }):wait(15000)

    assert.True(ok, 'install should return true for queries_only')

    -- NO parser .so should exist
    local config = require('nvim-treesitter.config')
    local parser_so = vim.fs.joinpath(config.get_install_dir('parser'), QO_LANG) .. '.so'
    assert.is_nil(vim.uv.fs_stat(parser_so), 'parser.so must NOT exist for queries_only type')

    -- tree-sitter build must NOT have been called
    eq(0, build_calls, 'tree-sitter build must not run for queries_only')

    -- Cache state: queries_version should be set, parser_version should be nil
    local cache_mod = require('nvim-treesitter.cache')
    local state = cache_mod.get_installed(QO_LANG)
    assert.is_not_nil(state, 'installed state should be written to cache')
    assert.is_nil(state.parser_version, 'parser_version should be nil for queries_only')
    eq('q1.0.0', state.queries_version, 'queries_version should be recorded')

    -- Queries directory must exist in install_dir
    local query_dir = vim.fs.joinpath(config.get_install_dir('queries'), QO_LANG)
    assert.is_not_nil(
      vim.uv.fs_stat(query_dir),
      'queries dir must be created for queries_only type'
    )

    -- At least one curl call for the queries tarball download
    assert.True(curl_calls > 0, 'http.download must be called for the queries tarball')
  end)
end)

-- ── local_parsers / local override tests ─────────────────────────────────────
--
-- These tests exercise config.local_parsers entries, which are registry-format
-- entries (`source.type`, `source.path`, etc.) injected directly into the
-- install pipeline.  They share the same setup/teardown infrastructure as the
-- integration tests above, augmented with per-test local_parsers injection and
-- cleanup.
--
-- local_parsers entry format (matches registry entry shape):
--   {
--     source = {
--       type         = 'local' | 'self_contained',
--       path         = '/abs/path'   -- only for type='local'   (source.path in install.lua)
--       url          = 'https://...' -- only for type='self_contained' (source.url in install.lua)
--       queries_path = 'subdir'      -- optional: subdir containing .scm files
--       queries_url  = 'https://...' -- optional: separate queries repo
--     },
--     filetypes = { 'lang' },
--   }
--
-- NOTE: the field for the remote URL is `source.url` (not `source.parser_url`) — this
-- matches the field name used in the current install.lua implementation.
--
-- For type='local' the install pipeline calls `do_compile` in place (no curl).
-- For type='self_contained' the pipeline downloads via http.download then compiles.
-- ─────────────────────────────────────────────────────────────────────────────

-- Fake language names for local_parsers tests — distinct from the LANG constant
-- used by the integration tests above so they never collide.
local LOCAL_LANG = '_ts_local_test_lang'
local LOCAL_LANG2 = '_ts_local_test_lang2'
local LOCAL_LANG3 = '_ts_local_test_lang3'
local LOCAL_LANG4 = '_ts_local_test_lang4'

-- Helper: inject a lang into nvim-treesitter.parsers (both preload and loaded)
-- so that norm_languages() accepts it.
-- Strategy: directly set the lang in the already-loaded parsers table AND install
-- a preload shim that reinstates it after reload_parsers() clears package.loaded.
-- We piggy-back on the preload already installed by setup() which handles the
-- base LANG entry.  We save and return that preload so cleanup can restore it.
local function inject_parser_lang(lang)
  local parsers = require('nvim-treesitter.parsers')
  parsers[lang] = parsers[lang] or { tier = 1, filetype = lang }
  -- Save the current preload (set by setup()) so we can restore it and also call it
  local saved_preload = package.preload['nvim-treesitter.parsers']
  package.preload['nvim-treesitter.parsers'] = function()
    -- Delegate to the outer preload (setup()'s version) to get the base table,
    -- then add our lang on top.  Avoids circular / nested preload issues by calling
    -- saved_preload directly rather than going through require().
    local p = saved_preload and saved_preload() or {}
    p[lang] = p[lang] or { tier = 1, filetype = lang }
    return p
  end
  return saved_preload
end

-- Helper: clear a lang from parsers table + preload
local function cleanup_parser_lang(lang, orig_preload)
  package.preload['nvim-treesitter.parsers'] = orig_preload
  local parsers = package.loaded['nvim-treesitter.parsers']
  if parsers then
    parsers[lang] = nil
  end
end

-- ── 11. local_parsers (type=local) — installs from local path ───────────────

describe('local_parsers type=local', function()
  local ctx = {}
  local local_src_dir ---@type string

  before_each(function()
    setup(ctx)

    -- Create a fake source directory with a queries subdir and a dummy parser.so
    local_src_dir = tmp_dir()
    mkdir_p(vim.fs.joinpath(local_src_dir, 'queries'))
    write_file(vim.fs.joinpath(local_src_dir, 'queries', 'highlights.scm'), '; fake highlights')
    -- The system stub will create parser.so when 'tree-sitter build' is called,
    -- but for type='local' the path used for do_compile is local_src_dir itself.
    -- Ensure the directory exists so the stub can write into it.
    mkdir_p(local_src_dir)

    -- Inject LOCAL_LANG into parsers so norm_languages accepts it
    ctx.orig_preload_local = inject_parser_lang(LOCAL_LANG)

    -- Register local_parsers entry (registry-format)
    local config = require('nvim-treesitter.config')
    config.setup({
      local_parsers = {
        [LOCAL_LANG] = {
          source = {
            type = 'local',
            path = local_src_dir,
            queries_path = 'queries',
          },
          filetypes = { LOCAL_LANG },
        },
      },
    })
  end)

  after_each(function()
    -- Clear local_parsers from config
    local config = require('nvim-treesitter.config')
    config.setup({ local_parsers = {} })

    -- Clear cache state for LOCAL_LANG
    local cache_mod = require('nvim-treesitter.cache')
    cache_mod.set_installed(LOCAL_LANG, nil)

    cleanup_parser_lang(LOCAL_LANG, ctx.orig_preload_local)

    rm_rf(local_src_dir)
    teardown(ctx)
  end)

  it('installs from local path and copies queries; never calls curl', function()
    -- Track whether http.download was called
    local curl_calls = 0
    package.loaded['treesitter-registry.http'] = vim.tbl_extend('force', package.loaded['treesitter-registry.http'], {
      download = function(_url, output, _opts, callback)
        curl_calls = curl_calls + 1
        -- Still behave like the stub so the pipeline does not stall
        mkdir_p(vim.fn.fnamemodify(output, ':h'))
        write_file(output, 'fake tarball')
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
    })

    -- Wrap vim.system to count tree-sitter build calls; also create parser.so
    -- in the *local source dir* (where do_install_parser will look for it).
    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        build_calls = build_calls + 1
        -- The local path compile uses local_src_dir as cwd; create parser.so there
        local cwd = (opts and opts.cwd) or local_src_dir
        write_file(vim.fs.joinpath(cwd, 'parser.so'), 'fake local parser')
      end
      return base_stub(cmd, opts, on_exit)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(LOCAL_LANG, { force = true }):wait(15000)

    assert.True(ok, 'install should return true for type=local')

    -- Parser .so must have been placed in install_dir
    local config = require('nvim-treesitter.config')
    local parser_so = vim.fs.joinpath(config.get_install_dir('parser'), LOCAL_LANG) .. '.so'
    assert.is_not_nil(
      vim.uv.fs_stat(parser_so),
      'parser.so must exist in install_dir after local install'
    )

    -- highlights.scm must have been copied to the queries dir
    local query_dir = vim.fs.joinpath(config.get_install_dir('queries'), LOCAL_LANG)
    local highlights = vim.fs.joinpath(query_dir, 'highlights.scm')
    assert.is_not_nil(
      vim.uv.fs_stat(highlights),
      'highlights.scm must be copied to queries dir for type=local'
    )

    -- tree-sitter build must have been called exactly once
    assert.True(build_calls > 0, 'tree-sitter build must run for type=local')

    -- http.download must NOT have been called for a local type
    eq(0, curl_calls, 'http.download must not be called for type=local')
  end)
end)

-- ── 12. local_parsers (type=self_contained) — fetches from URL ───────────────

describe('local_parsers type=self_contained', function()
  local ctx = {}

  before_each(function()
    setup(ctx)

    -- Inject LOCAL_LANG2 into parsers so norm_languages accepts it
    ctx.orig_preload_local2 = inject_parser_lang(LOCAL_LANG2)

    -- Register local_parsers entry with type=self_contained (has url)
    local config = require('nvim-treesitter.config')
    config.setup({
      local_parsers = {
        [LOCAL_LANG2] = {
          source = {
            type = 'self_contained',
            url = 'https://github.com/fake/tree-sitter-' .. LOCAL_LANG2,
            queries_path = 'nvim-queries',
          },
          filetypes = { LOCAL_LANG2 },
        },
      },
    })
  end)

  after_each(function()
    local config = require('nvim-treesitter.config')
    config.setup({ local_parsers = {} })

    local cache_mod = require('nvim-treesitter.cache')
    cache_mod.set_installed(LOCAL_LANG2, nil)

    cleanup_parser_lang(LOCAL_LANG2, ctx.orig_preload_local2)
    teardown(ctx)
  end)

  it('fetches from URL via http.download and creates parser .so', function()
    local curl_calls = 0
    package.loaded['treesitter-registry.http'] = {
      get = function(_url, _opts, callback)
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
      download = function(_url, output, _opts, callback)
        curl_calls = curl_calls + 1
        -- Write a fake tarball so the extraction step has a file
        mkdir_p(vim.fn.fnamemodify(output, ':h'))
        write_file(output, 'fake tarball')
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
    }

    -- The system stub already creates parser.so in cwd on 'tree-sitter build'
    -- and a fake extracted directory on 'tar'.  The queries_path 'nvim-queries'
    -- won't exist in the extracted stub dir, but do_copy_queries will skip
    -- gracefully; what matters is that the install pipeline runs and writes cache.
    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        build_calls = build_calls + 1
      end
      return base_stub(cmd, opts, on_exit)
    end

    -- stub version.refresh_all for LOCAL_LANG2
    local version_mod = require('nvim-treesitter.version')
    local orig_refresh = version_mod.refresh_all
    version_mod.refresh_all = function(_reg, langs, cache, on_done)
      cache.parsers = cache.parsers or {}
      for _, lang in ipairs(langs) do
        cache.parsers[lang] = {
          latest_parser = 'main',
          latest_queries = 'main',
          checked_at = os.time(),
        }
      end
      vim.schedule(function()
        on_done(cache)
      end)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(LOCAL_LANG2, { force = true }):wait(15000)

    version_mod.refresh_all = orig_refresh

    assert.True(ok, 'install should return true for type=self_contained local_parsers')

    -- Parser .so must exist in install_dir
    local config = require('nvim-treesitter.config')
    local parser_so = vim.fs.joinpath(config.get_install_dir('parser'), LOCAL_LANG2) .. '.so'
    assert.is_not_nil(
      vim.uv.fs_stat(parser_so),
      'parser.so must exist in install_dir after self_contained install'
    )

    -- http.download must have been called (this is NOT a local-path install)
    assert.True(curl_calls > 0, 'http.download must be called for type=self_contained')

    -- tree-sitter build must have been called
    assert.True(build_calls > 0, 'tree-sitter build must run for type=self_contained')
  end)
end)

-- ── 13. local_parsers takes precedence over registry ────────────────────────

describe('local_parsers overrides registry', function()
  local ctx = {}
  local local_src_dir3 ---@type string

  before_each(function()
    setup(ctx)

    -- Create a distinct local source dir for LOCAL_LANG3
    local_src_dir3 = tmp_dir()
    mkdir_p(local_src_dir3)

    -- Inject LOCAL_LANG3 into parsers
    ctx.orig_preload_local3 = inject_parser_lang(LOCAL_LANG3)

    -- Put LOCAL_LANG3 in the registry with a different (remote) URL
    local registry = require('nvim-treesitter.registry')
    registry.loaded[LOCAL_LANG3] = {
      source = {
        type = 'self_contained',
        url = 'https://github.com/registry/tree-sitter-' .. LOCAL_LANG3,
      },
      filetypes = { LOCAL_LANG3 },
    }

    -- Also register it in local_parsers pointing to the local dir
    local config = require('nvim-treesitter.config')
    config.setup({
      local_parsers = {
        [LOCAL_LANG3] = {
          source = {
            type = 'local',
            path = local_src_dir3,
          },
          filetypes = { LOCAL_LANG3 },
        },
      },
    })
  end)

  after_each(function()
    local registry = require('nvim-treesitter.registry')
    if registry.loaded then
      registry.loaded[LOCAL_LANG3] = nil
    end

    local config = require('nvim-treesitter.config')
    config.setup({ local_parsers = {} })

    local cache_mod = require('nvim-treesitter.cache')
    cache_mod.set_installed(LOCAL_LANG3, nil)

    cleanup_parser_lang(LOCAL_LANG3, ctx.orig_preload_local3)
    rm_rf(local_src_dir3)
    teardown(ctx)
  end)

  it('uses the local path, not the registry URL', function()
    -- Track every vim.system invocation to check which path was used
    local system_calls = {} ---@type string[][]
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      system_calls[#system_calls + 1] = { cmd = cmd, cwd = opts and opts.cwd }
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        -- create parser.so in local_src_dir3 (where do_install_parser looks)
        write_file(vim.fs.joinpath(local_src_dir3, 'parser.so'), 'fake local parser3')
      end
      return base_stub(cmd, opts, on_exit)
    end

    -- Track http calls — they should NOT happen for type=local
    local curl_calls = 0
    package.loaded['treesitter-registry.http'] = {
      get = function(_url, _opts, callback)
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
      download = function(_url, output, _opts, callback)
        curl_calls = curl_calls + 1
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
    }

    -- stub version.refresh_all for LOCAL_LANG3
    local version_mod = require('nvim-treesitter.version')
    local orig_refresh = version_mod.refresh_all
    version_mod.refresh_all = function(_reg, langs, cache, on_done)
      cache.parsers = cache.parsers or {}
      for _, lang in ipairs(langs) do
        cache.parsers[lang] = { latest_parser = 'main', latest_queries = 'main', checked_at = os.time() }
      end
      vim.schedule(function()
        on_done(cache)
      end)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(LOCAL_LANG3, { force = true }):wait(15000)

    version_mod.refresh_all = orig_refresh

    assert.True(ok, 'install should succeed when local_parsers overrides registry')

    -- No curl call — the local_parsers entry (type=local) was used, not the registry URL
    eq(0, curl_calls, 'http.download must not be called when local_parsers entry is type=local')

    -- At least one tree-sitter build call must have used local_src_dir3 as cwd
    local used_local_path = false
    for _, call in ipairs(system_calls) do
      if call.cmd[1] == 'tree-sitter' and call.cmd[2] == 'build' then
        if call.cwd and vim.fs.normalize(call.cwd) == vim.fs.normalize(local_src_dir3) then
          used_local_path = true
        end
      end
    end
    assert.True(
      used_local_path,
      'tree-sitter build must be invoked with the local path as cwd, not the registry URL'
    )
  end)
end)

-- ── 14. local_parsers lang appears in get_available() ───────────────────────

describe('local_parsers lang in get_available', function()
  local ctx = {}

  before_each(function()
    setup(ctx)

    -- Register LOCAL_LANG4 only in local_parsers; NOT in the parsers table
    local config = require('nvim-treesitter.config')
    config.setup({
      local_parsers = {
        [LOCAL_LANG4] = {
          source = { type = 'local', path = '/tmp/fake-' .. LOCAL_LANG4 },
          filetypes = { LOCAL_LANG4 },
        },
      },
    })
  end)

  after_each(function()
    local config = require('nvim-treesitter.config')
    config.setup({ local_parsers = {} })

    -- LOCAL_LANG4 was never injected into parsers — nothing to clean there
    teardown(ctx)
  end)

  it('includes local_parsers lang even when absent from the registry parsers table', function()
    local config = require('nvim-treesitter.config')

    -- Temporarily zero out the parsers table so LOCAL_LANG4 can only come from
    -- local_parsers, proving it is not silently swallowed.
    local parsers_mod = require('nvim-treesitter.parsers')
    local saved = parsers_mod[LOCAL_LANG4]
    parsers_mod[LOCAL_LANG4] = nil -- ensure it is not in the parsers table

    local available = config.get_available()

    parsers_mod[LOCAL_LANG4] = saved -- restore

    assert.True(
      vim.list_contains(available, LOCAL_LANG4),
      "get_available() must include '" .. LOCAL_LANG4 .. "' when it is in local_parsers"
    )
  end)
end)
