-- tests/install/local_parsers_spec.lua
-- Isolated tests for local_parsers (tests 11-14 from install_spec.lua).
-- Run these separately to avoid timing issues from the pre-existing failures
-- in tests 5-10.
--
-- Setup is identical to install_spec.lua.

do
  local repo_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
  vim.opt.rtp:prepend(repo_root .. '/.test-deps/plenary.nvim')
end

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

package.loaded['nvim-treesitter.registry'] = nil

local assert = require('luassert')
local eq = assert.are.same

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

local LANG = '_ts_test_lang_lp' -- distinct LANG for this file to avoid collisions

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

local function setup(ctx)
  ctx.base_dir = tmp_dir()
  mkdir_p(ctx.base_dir)
  local config = require('nvim-treesitter.config')
  ctx.orig_install_dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site')
  config.setup({ install_dir = ctx.base_dir })

  ctx.orig_system = vim.system
  vim.system = make_system_stub()

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

  local registry = require('nvim-treesitter.registry')
  ctx.orig_registry_loaded = registry.loaded
  ctx.orig_registry_load = registry.load
  if not registry.loaded then
    registry.loaded = {}
  end
  registry.loaded[LANG] = {
    source = {
      type = 'self_contained',
      url = 'https://github.com/tree-sitter/tree-sitter-' .. LANG,
    },
    filetypes = { LANG },
  }
  registry.load = function(cb)
    vim.schedule(function()
      cb(registry.loaded, nil)
    end)
  end

  local qr = require('nvim-treesitter.queries_resolver')
  ctx.orig_qr_resolve = qr.resolve
  qr.resolve = function(_lang, _dir, callback, _visited)
    vim.schedule(callback)
  end

  stub_versions('v1.0.0', 'q1.0.0')
end

local function teardown(ctx)
  vim.system = ctx.orig_system

  local registry = require('nvim-treesitter.registry')
  if registry.loaded then
    registry.loaded[LANG] = nil
  end
  registry.load = ctx.orig_registry_load
  registry.loaded = ctx.orig_registry_loaded

  local qr = require('nvim-treesitter.queries_resolver')
  qr.resolve = ctx.orig_qr_resolve

  local version_mod = require('nvim-treesitter.version')
  version_mod.refresh_all = nil

  local cache_mod = require('nvim-treesitter.cache')
  cache_mod.set_installed(LANG, nil)

  local config = require('nvim-treesitter.config')
  config.setup({ install_dir = ctx.orig_install_dir })

  rm_rf(ctx.base_dir)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- local_parsers test helpers
-- ─────────────────────────────────────────────────────────────────────────────

local LOCAL_LANG = '_ts_local_test_lang'
local LOCAL_LANG2 = '_ts_local_test_lang2'
local LOCAL_LANG3 = '_ts_local_test_lang3'
local LOCAL_LANG4 = '_ts_local_test_lang4'

-- ── 11. local_parsers (type=local) ──────────────────────────────────────────

describe('local_parsers type=local', function()
  local ctx = {}
  local local_src_dir ---@type string

  before_each(function()
    setup(ctx)
    local_src_dir = tmp_dir()
    mkdir_p(vim.fs.joinpath(local_src_dir, 'queries'))
    write_file(vim.fs.joinpath(local_src_dir, 'queries', 'highlights.scm'), '; fake highlights')
    mkdir_p(local_src_dir)
    local registry = require('nvim-treesitter.registry')
    registry.loaded[LOCAL_LANG] = {
      source = { type = 'local', path = local_src_dir, queries_path = 'queries' },
      filetypes = { LOCAL_LANG },
    }
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
    local config = require('nvim-treesitter.config')
    config.setup({ local_parsers = {} })
    local cache_mod = require('nvim-treesitter.cache')
    cache_mod.set_installed(LOCAL_LANG, nil)
    local registry = require('nvim-treesitter.registry')
    if registry.loaded then
      registry.loaded[LOCAL_LANG] = nil
    end
    rm_rf(local_src_dir)
    teardown(ctx)
  end)

  it('installs from local path and copies queries; never calls curl', function()
    local curl_calls = 0
    package.loaded['treesitter-registry.http'] = vim.tbl_extend('force', package.loaded['treesitter-registry.http'], {
      download = function(_url, output, _opts, callback)
        curl_calls = curl_calls + 1
        mkdir_p(vim.fn.fnamemodify(output, ':h'))
        write_file(output, 'fake tarball')
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
    })

    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        build_calls = build_calls + 1
        local cwd = (opts and opts.cwd) or local_src_dir
        write_file(vim.fs.joinpath(cwd, 'parser.so'), 'fake local parser')
      end
      return base_stub(cmd, opts, on_exit)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(LOCAL_LANG, { force = true }):wait(15000)

    assert.True(ok, 'install should return true for type=local')

    local config = require('nvim-treesitter.config')
    local parser_so = vim.fs.joinpath(config.get_install_dir('parser'), LOCAL_LANG) .. '.so'
    assert.is_not_nil(
      vim.uv.fs_stat(parser_so),
      'parser.so must exist in install_dir after local install'
    )

    local query_dir = vim.fs.joinpath(config.get_install_dir('queries'), LOCAL_LANG)
    local highlights = vim.fs.joinpath(query_dir, 'highlights.scm')
    assert.is_not_nil(
      vim.uv.fs_stat(highlights),
      'highlights.scm must be copied to queries dir for type=local'
    )

    assert.True(build_calls > 0, 'tree-sitter build must run for type=local')
    eq(0, curl_calls, 'http.download must not be called for type=local')
  end)
end)

-- ── 12. local_parsers (type=self_contained) ─────────────────────────────────

describe('local_parsers type=self_contained', function()
  local ctx = {}

  before_each(function()
    setup(ctx)
    local registry = require('nvim-treesitter.registry')
    registry.loaded[LOCAL_LANG2] = {
      source = {
        type = 'self_contained',
        url = 'https://github.com/fake/tree-sitter-' .. LOCAL_LANG2,
        queries_path = 'nvim-queries',
      },
      filetypes = { LOCAL_LANG2 },
    }
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
    local registry = require('nvim-treesitter.registry')
    if registry.loaded then
      registry.loaded[LOCAL_LANG2] = nil
    end
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
        mkdir_p(vim.fn.fnamemodify(output, ':h'))
        write_file(output, 'fake tarball')
        vim.schedule(function()
          callback({ status = 200, body = '' }, nil)
        end)
      end,
    }

    local build_calls = 0
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        build_calls = build_calls + 1
      end
      return base_stub(cmd, opts, on_exit)
    end

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

    local config = require('nvim-treesitter.config')
    local parser_so = vim.fs.joinpath(config.get_install_dir('parser'), LOCAL_LANG2) .. '.so'
    assert.is_not_nil(
      vim.uv.fs_stat(parser_so),
      'parser.so must exist in install_dir after self_contained install'
    )

    assert.True(curl_calls > 0, 'http.download must be called for type=self_contained')

    assert.True(build_calls > 0, 'tree-sitter build must run for type=self_contained')
  end)
end)

-- ── 13. local_parsers overrides registry ────────────────────────────────────

describe('local_parsers overrides registry', function()
  local ctx = {}
  local local_src_dir3 ---@type string

  before_each(function()
    setup(ctx)
    local_src_dir3 = tmp_dir()
    mkdir_p(local_src_dir3)
    local registry = require('nvim-treesitter.registry')
    registry.loaded[LOCAL_LANG3] = {
      source = {
        type = 'self_contained',
        url = 'https://github.com/registry/tree-sitter-' .. LOCAL_LANG3,
      },
      filetypes = { LOCAL_LANG3 },
    }
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
    rm_rf(local_src_dir3)
    teardown(ctx)
  end)

  it('uses the local path, not the registry URL', function()
    local system_calls = {} ---@type table[]
    local base_stub = make_system_stub()
    vim.system = function(cmd, opts, on_exit)
      system_calls[#system_calls + 1] = { cmd = cmd, cwd = opts and opts.cwd }
      if cmd[1] == 'tree-sitter' and cmd[2] == 'build' then
        write_file(vim.fs.joinpath(local_src_dir3, 'parser.so'), 'fake local parser3')
      end
      return base_stub(cmd, opts, on_exit)
    end

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

    local version_mod = require('nvim-treesitter.version')
    local orig_refresh = version_mod.refresh_all
    version_mod.refresh_all = function(_reg, langs, cache, on_done)
      cache.parsers = cache.parsers or {}
      for _, lang in ipairs(langs) do
        cache.parsers[lang] =
          { latest_parser = 'main', latest_queries = 'main', checked_at = os.time() }
      end
      vim.schedule(function()
        on_done(cache)
      end)
    end

    local install = require('nvim-treesitter.install')
    local ok = install.install(LOCAL_LANG3, { force = true }):wait(15000)

    version_mod.refresh_all = orig_refresh

    assert.True(ok, 'install should succeed when local_parsers overrides registry')

    eq(0, curl_calls, 'http.download must not be called when local_parsers entry is type=local')

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

-- ── 14. local_parsers lang in get_available() ───────────────────────────────

describe('local_parsers lang in get_available', function()
  local ctx = {}

  before_each(function()
    setup(ctx)
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
    teardown(ctx)
  end)

  it('includes local_parsers lang even when absent from the registry parsers table', function()
    local config = require('nvim-treesitter.config')
    local parsers_mod = require('nvim-treesitter.parsers')
    local saved = parsers_mod[LOCAL_LANG4]
    parsers_mod[LOCAL_LANG4] = nil

    local available = config.get_available()

    parsers_mod[LOCAL_LANG4] = saved

    assert.True(
      vim.list_contains(available, LOCAL_LANG4),
      "get_available() must include '" .. LOCAL_LANG4 .. "' when it is in local_parsers"
    )
  end)
end)
