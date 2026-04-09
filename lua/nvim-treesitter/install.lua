--- install.lua — modular rewrite using registry / version / cache / queries_resolver
---
--- Public API (unchanged shape):
---   M.install(langs, opts)    — install one or more languages
---   M.update(langs, opts)     — update installed languages
---   M.uninstall(langs)        — remove parser + queries
---   M.status()                — return per-lang status table
---
--- opts fields:
---   force   boolean  — reinstall / bypass cache
---   summary boolean  — print a summary notification when done
---   max_jobs integer — parallelism cap (default 100)
---
--- Dependencies (new modular modules, assumed present):
---   nvim-treesitter.registry        M.load(cb), M.get(lang), M.loaded
---   nvim-treesitter.version         M.latest_parser, M.latest_queries, M.refresh_all
---   nvim-treesitter.cache           M.load, M.save, M.is_stale, M.stale_langs,
---                                   M.get_installed, M.set_installed
---   nvim-treesitter.queries_resolver M.resolve(lang, install_dir, cb)
---
--- HTTP: plenary.curl (never raw curl / vim.system for HTTP)
--- Build: vim.system (tree-sitter CLI)

local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local a = require('nvim-treesitter.async')
local config = require('nvim-treesitter.config')
local log = require('nvim-treesitter.log')

-- ── async uv helpers ────────────────────────────────────────────────────────

---@type fun(path: string, new_path: string, flags?: table): string?
local uv_copyfile = a.awrap(4, uv.fs_copyfile)

---@type fun(path: string, mode: integer): string?
local uv_mkdir = a.awrap(3, uv.fs_mkdir)

---@type fun(path: string): string?
local uv_rmdir = a.awrap(2, uv.fs_rmdir)

---@type fun(path: string, new_path: string): string?
local uv_rename = a.awrap(3, uv.fs_rename)

---@type fun(path: string, new_path: string, flags?: table): string?
local uv_symlink = a.awrap(4, uv.fs_symlink)

---@type fun(path: string): string?
local uv_unlink = a.awrap(2, uv.fs_unlink)

-- ── fs helpers ───────────────────────────────────────────────────────────────

---@async
---@param path string
---@return string? err
local function mkpath(path)
  local parent = fs.dirname(path)
  if not parent:match('^[./]$') and not uv.fs_stat(parent) then
    mkpath(parent)
  end
  return uv_mkdir(path, 493) -- 0755
end

---@async
---@param path string
---@return string? err
local function rmpath(path)
  local stat = uv.fs_lstat(path)
  if not stat then
    return
  end
  if stat.type == 'directory' then
    for file in fs.dir(path) do
      rmpath(fs.joinpath(path, file))
    end
    return uv_rmdir(path)
  else
    return uv_unlink(path)
  end
end

-- ── concurrency helpers ──────────────────────────────────────────────────────

local MAX_JOBS = 100
local INSTALL_TIMEOUT = 60000

---@async
---@param max_jobs integer
---@param tasks async.TaskFun[]
local function join(max_jobs, tasks)
  if #tasks == 0 then
    return
  end
  max_jobs = math.min(max_jobs, #tasks)
  local remaining = { select(max_jobs + 1, unpack(tasks)) }
  local to_go = #tasks
  a.await(1, function(finish)
    local function cb()
      to_go = to_go - 1
      if to_go == 0 then
        finish()
      elseif #remaining > 0 then
        local next_task = table.remove(remaining)
        next_task():await(cb)
      end
    end
    for i = 1, max_jobs do
      if tasks[i] then
        tasks[i]():await(cb)
      end
    end
  end)
end

-- ── vim.system wrapper (build / git only) ───────────────────────────────────

---@async
---@param cmd string[]
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
local function system(cmd, opts)
  local cwd = opts and opts.cwd or uv.cwd()
  log.trace('running job: (cwd=%s) %s', cwd, table.concat(cmd, ' '))
  ---@param _cmd string[]
  ---@param _opts vim.SystemOpts
  ---@param on_exit fun(result: vim.SystemCompleted)
  ---@return vim.SystemObj?
  local function system_wrap(_cmd, _opts, on_exit)
    local ok, ret = pcall(vim.system, _cmd, _opts, on_exit)
    if not ok then
      on_exit({
        code = 125,
        signal = 0,
        stdout = '',
        stderr = ret --[[@as string]],
      })
      return nil
    end
    return ret --[[@as vim.SystemObj]]
  end
  local r = a.await(3, system_wrap, cmd, opts) --[[@as vim.SystemCompleted]]
  a.schedule()
  if r.stdout and r.stdout ~= '' then
    log.trace('stdout -> %s', r.stdout)
  end
  if r.stderr and r.stderr ~= '' then
    log.trace('stderr -> %s', r.stderr)
  end
  return r
end

-- ── plenary.curl wrapper ──────────────────────────────────────────────────────
-- All HTTP downloads go through here.  plenary.curl is callback-based so we
-- wrap it with a.awrap to make it await-able.

---@async
---@param url string
---@param output_path string
---@return { status: integer, body: string }? result, string? err
local function curl_download(url, output_path)
  log.trace('curl_download %s -> %s', url, output_path)
  local curl = require('plenary.curl')
  local result, err = a.await(1, function(cb)
    curl.get(url, {
      output = output_path,
      -- follow redirects, retry on transient failures
      raw = { '-L', '--retry', '3', '--fail', '--show-error' },
      callback = function(res)
        cb(res, nil)
      end,
      on_error = function(e)
        cb(nil, tostring(e))
      end,
    })
  end)
  return result, err
end

-- ── tarball download + extraction ────────────────────────────────────────────

---@async
---@param logger Logger
---@param tarball_url string
---@param project_name string
---@param cache_dir string
---@param output_dir string
---@return string? err
local function do_download_tarball(logger, tarball_url, project_name, cache_dir, output_dir)
  local tmp = output_dir .. '-tmp'
  rmpath(tmp)
  a.schedule()

  local tarball_path = fs.joinpath(cache_dir, project_name .. '.tar.gz')

  do -- Download via plenary.curl
    logger:info('Downloading %s...', project_name)
    local _, err = curl_download(tarball_url, tarball_path)
    if err then
      return logger:error('Error during download: %s', err)
    end
  end

  do -- Create tmp dir
    logger:debug('Creating temporary directory: %s', tmp)
    local err = mkpath(tmp)
    a.schedule()
    if err then
      return logger:error('Could not create %s-tmp: %s', project_name, err)
    end
  end

  do -- Extract tarball
    logger:debug('Extracting %s into %s...', tarball_path, tmp)
    local r = system(
      { 'tar', '-xzf', project_name .. '.tar.gz', '-C', project_name .. '-tmp' },
      { cwd = cache_dir }
    )
    if r.code > 0 then
      return logger:error('Error during tarball extraction: %s', r.stderr)
    end
  end

  do -- Remove tarball
    logger:debug('Removing %s...', tarball_path)
    local err = uv_unlink(tarball_path)
    a.schedule()
    if err then
      return logger:error('Could not remove tarball: %s', err)
    end
  end

  do -- Move the single extracted sub-directory to output_dir
    -- tarballs typically contain one top-level directory; find it.
    local extracted_root ---@type string?
    for entry in fs.dir(tmp) do
      extracted_root = fs.joinpath(tmp, entry)
      break
    end
    if not extracted_root then
      return logger:error('Tarball appears to be empty')
    end
    logger:debug('Moving %s to %s', extracted_root, output_dir)
    local err = uv_rename(extracted_root, output_dir)
    a.schedule()
    if err then
      return logger:error('Could not rename extracted dir: %s', err)
    end
  end

  rmpath(tmp)
  a.schedule()
end

-- ── git clone fallback ───────────────────────────────────────────────────────

---@async
---@param logger Logger
---@param url string
---@param ref string   branch or tag
---@param output_dir string
---@return string? err
local function do_git_clone(logger, url, ref, output_dir)
  logger:info('Cloning %s @ %s...', url, ref)
  rmpath(output_dir)
  a.schedule()
  local r = system({
    'git',
    'clone',
    '--depth',
    '1',
    '--branch',
    ref,
    url,
    output_dir,
  })
  if r.code > 0 then
    return logger:error('git clone failed: %s', r.stderr)
  end
end

-- ── parser build / install ───────────────────────────────────────────────────

---@async
---@param logger Logger
---@param repo { generate?: boolean, generate_from_json?: boolean }
---@param compile_location string
---@return string? err
local function do_generate(logger, repo, compile_location)
  local from_json = repo.generate_from_json ~= false
  logger:info('Generating parser.c from %s...', from_json and 'grammar.json' or 'grammar.js')
  local r = system({
    'tree-sitter',
    'generate',
    '--abi',
    tostring(vim.treesitter.language_version),
    from_json and 'src/grammar.json' or nil,
  }, { cwd = compile_location, env = { TREE_SITTER_JS_RUNTIME = 'native' } })
  if r.code > 0 then
    return logger:error('Error during "tree-sitter generate": %s', r.stderr)
  end
end

---@async
---@param logger Logger
---@param compile_location string
---@return string? err
local function do_compile(logger, compile_location)
  logger:info('Compiling parser...')
  local r = system({ 'tree-sitter', 'build', '-o', 'parser.so' }, { cwd = compile_location })
  if r.code > 0 then
    return logger:error('Error during "tree-sitter build": %s', r.stderr)
  end
end

---@async
---@param logger Logger
---@param compile_location string
---@param target_location string
---@return string? err
local function do_install_parser(logger, compile_location, target_location)
  logger:info('Installing parser...')
  local tempfile = target_location .. '.' .. tostring(uv.hrtime()) .. '.tmp'
  local err = uv_copyfile(compile_location, tempfile)
  if err then
    uv_unlink(tempfile)
    a.schedule()
    return logger:error('Error during parser installation: %s', err)
  end
  -- Atomic rename: replaces target in one syscall.
  err = uv_rename(tempfile, target_location)
  a.schedule()
  if err then
    uv_unlink(tempfile)
    return logger:error('Error during parser installation (rename): %s', err)
  end
end

-- ── queries helpers ───────────────────────────────────────────────────────────

---@async
---@param logger Logger
---@param query_src string
---@param query_dir string
---@return string? err
local function do_link_queries(logger, query_src, query_dir)
  uv_unlink(query_dir)
  local err = uv_symlink(query_src, query_dir, { dir = true, junction = true })
  a.schedule()
  if err then
    return logger:error(err)
  end
end

---@async
---@param logger Logger
---@param query_src string
---@param query_dir string
---@return string? err
local function do_copy_queries(logger, query_src, query_dir)
  rmpath(query_dir)
  local err = uv_mkdir(query_dir, 493)
  if err then
    return logger:error(err)
  end
  for f in fs.dir(query_src) do
    local copy_err = uv_copyfile(fs.joinpath(query_src, f), fs.joinpath(query_dir, f))
    if copy_err then
      a.schedule()
      return logger:error('Failed to copy query file %s: %s', f, copy_err)
    end
  end
  a.schedule()
end

-- ── semver comparison ─────────────────────────────────────────────────────────
-- Returns true if version `a` is strictly greater than version `b`.
-- Understands "vMAJOR.MINOR.PATCH" and plain "MAJOR.MINOR.PATCH".

---@param ver string
---@return integer[]
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

---@param a_ver string
---@param b_ver string
---@return boolean  true if a_ver > b_ver
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

-- ── hosts adapter shim ────────────────────────────────────────────────────────
-- Attempts to derive a tarball URL from a repository URL + ref.
-- Returns nil when the host is not recognised (caller should git-clone instead).

---@param repo_url string
---@param ref string
---@return string?
local function tarball_url(repo_url, ref)
  local url = repo_url:gsub('%.git$', '')
  -- GitHub
  if url:match('github%.com') then
    return string.format('%s/archive/%s.tar.gz', url, ref)
  end
  -- GitLab
  if url:match('gitlab%.com') then
    return string.format('%s/-/archive/%s/archive.tar.gz', url, ref)
  end
  -- Sourcehut
  if url:match('sr%.ht') then
    return string.format('%s/archive/%s.tar.gz', url, ref)
  end
  return nil
end

-- ── per-language install implementation ──────────────────────────────────────

-- URL-keyed download lock: maps a parser_url to the project_dir it was
-- downloaded into.  When two languages share the same parser_url (e.g.
-- markdown + markdown_inline both use tree-sitter-grammars/tree-sitter-markdown)
-- the second coroutine waits for the first to finish, then reuses the result.
local downloading = {} ---@type table<string, string|false|nil>
-- nil   = not started
-- false = in progress (another coroutine is downloading)
-- string = completed; value is the project_dir that was produced

---@async
---@param lang       string
---@param entry      table   registry entry  (source, filetypes, requires, …)
---@param versions   table   { parser_version, queries_version }
---@param install_dir string
---@param cache_dir  string
---@param _opts       InstallOptions
---@return string? err
local function install_one(lang, entry, versions, install_dir, cache_dir, _opts)
  local logger = log.new('install/' .. lang)
  local source = entry.source
  local stype = source.type -- "self_contained" | "external_queries" | "queries_only" | "local"

  local need_parser = (stype == 'self_contained' or stype == 'external_queries' or stype == 'local')
    and not versions.skip_parser
  local need_queries = (
    stype == 'self_contained'
    or stype == 'external_queries'
    or stype == 'queries_only'
    or stype == 'local'
  )

  -- Track the remote project_dir so the queries branch can reuse it when
  -- queries_path is set (we must not delete it until after queries are copied).
  local remote_project_dir ---@type string?

  -- ── download queries repo first (external_queries / queries_only) ─────────
  -- For external_queries the queries tarball is downloaded before the parser
  -- is compiled so that parser.json (which lives in the queries repo root) is
  -- available on disk when we need to decide whether to run `tree-sitter
  -- generate`.  We read it here and use it throughout the rest of install_one.
  local parser_manifest = entry.parser_manifest or {} ---@type table
  local queries_project_dir ---@type string?  -- kept alive for copy step below

  if need_queries and (stype == 'external_queries' or stype == 'queries_only') then
    local queries_ref = versions.latest_queries or 'main'
    local queries_url = source.queries_url or source.url
    local project_name = 'tree-sitter-queries-' .. lang
    local project_dir = fs.joinpath(cache_dir, project_name)

    rmpath(project_dir)
    a.schedule()

    local turl = tarball_url(queries_url, queries_ref)
    if turl then
      local err = do_download_tarball(logger, turl, project_name, cache_dir, project_dir)
      if err then
        return err
      end
    else
      local err = do_git_clone(logger, queries_url, queries_ref, project_dir)
      if err then
        return err
      end
    end

    -- Read parser.json from the queries repo root to get build metadata.
    local manifest_path = fs.joinpath(project_dir, 'parser.json')
    if uv.fs_stat(manifest_path) then
      local ok, data =
        pcall(fn.json_decode, table.concat(fn.readfile(manifest_path) --[[@as table]], '\n'))
      if ok and type(data) == 'table' then
        ---@cast data table
        -- Merge with any entry-level manifest (entry-level wins for version bounds).
        parser_manifest = vim.tbl_extend('keep', entry.parser_manifest or {}, data)
      end
    end

    queries_project_dir = project_dir
  end

  -- ── compatibility check (needs parser_manifest populated above) ───────────
  -- If parser_version is pinned, that is the install target — no need to
  -- compare against latest.  Only warn when using latest and it is beyond
  -- a declared ceiling (legacy max_version field, kept for back-compat).
  if
    not parser_manifest.parser_version
    and parser_manifest.max_version
    and versions.latest_parser
  then
    if semver_gt(versions.latest_parser, parser_manifest.max_version) then
      vim.notify(
        string.format(
          '[nvim-treesitter] %s: latest parser %s exceeds max_version %s — skipping parser update',
          lang,
          versions.latest_parser,
          parser_manifest.max_version
        ),
        vim.log.levels.WARN
      )
      versions = vim.tbl_extend('force', versions, { skip_parser = true })
      need_parser = false
    end
  end

  -- ── download + build parser ───────────────────────────────────────────────
  if need_parser then
    local project_name = 'tree-sitter-' .. lang
    -- parser_manifest.parser_version pins an exact tag/SHA that the queries
    -- maintainer has verified against; prefer it over whatever happens to be
    -- latest on the parser repo right now.
    local parser_ref = parser_manifest.parser_version or versions.latest_parser or 'main'
    -- self_contained uses source.url; external_queries uses source.parser_url
    local parser_url = source.parser_url or source.url
    local project_dir = fs.joinpath(cache_dir, project_name)

    if source.type == 'local' then
      -- local path: compile in place
      local compile_loc = fs.normalize(source.path or '')
      local location = source.parser_location or source.location
      if location then
        compile_loc = fs.joinpath(compile_loc, location)
      end
      if parser_manifest.generate or parser_manifest.generate_from_json ~= nil then
        local err = do_generate(logger, parser_manifest, compile_loc)
        if err then
          return err
        end
      end
      local err = do_compile(logger, compile_loc)
      if err then
        return err
      end
      local parser_lib = fs.joinpath(compile_loc, 'parser.so')
      local install_loc = fs.joinpath(install_dir, lang) .. '.so'
      err = do_install_parser(logger, parser_lib, install_loc)
      if err then
        return err
      end
    else
      -- remote: tarball or git clone.
      -- When multiple langs share the same parser_url (e.g. markdown monorepo),
      -- download once into a URL-keyed shared dir and let each lang compile
      -- its own parser_location subdirectory from it.
      local dl_key = parser_url .. '@' .. parser_ref
      -- Shared dir is keyed by URL+ref so it is neutral across langs.
      local shared_dir = fs.joinpath(cache_dir, 'shared-' .. fn.sha256(dl_key):sub(1, 12))

      if downloading[dl_key] == false then
        -- Another coroutine is downloading — wait for it.
        local ok = vim.wait(INSTALL_TIMEOUT, function()
          return downloading[dl_key] ~= false
        end)
        if not ok or not downloading[dl_key] then
          return logger:error('Timed out waiting for shared download of %s', parser_url)
        end
      elseif not downloading[dl_key] then
        -- First coroutine: claim lock, download into shared_dir.
        downloading[dl_key] = false
        rmpath(shared_dir)
        a.schedule()
        -- Also clean up the lang-specific dir from any previous run.
        rmpath(project_dir)
        a.schedule()
        local turl = tarball_url(parser_url, parser_ref)
        if turl then
          local err = do_download_tarball(
            logger,
            turl,
            'shared-' .. fn.sha256(dl_key):sub(1, 12),
            cache_dir,
            shared_dir
          )
          if err then
            downloading[dl_key] = nil
            return err
          end
        else
          local err = do_git_clone(logger, parser_url, parser_ref, shared_dir)
          if err then
            downloading[dl_key] = nil
            return err
          end
        end
        downloading[dl_key] = shared_dir -- signal completion with shared dir path
      end
      -- Use the shared dir (either we downloaded it or another coroutine did).
      project_dir = downloading[dl_key] --[[@as string]]

      local compile_loc = project_dir
      local location = source.parser_location or source.location
      if location then
        compile_loc = fs.joinpath(compile_loc, location)
      end

      -- generate parser.c from grammar.js / grammar.json if needed.
      -- For external_queries: flags come from parser.json (parser_manifest).
      -- For self_contained: flags come from the registry source entry directly.
      local gen_flags = parser_manifest.generate ~= nil and parser_manifest or source
      if gen_flags.generate or gen_flags.generate_from_json ~= nil then
        local err = do_generate(logger, gen_flags, compile_loc)
        if err then
          return err
        end
      end

      local err = do_compile(logger, compile_loc)
      if err then
        return err
      end

      local parser_lib = fs.joinpath(compile_loc, 'parser.so')
      local install_loc = fs.joinpath(install_dir, lang) .. '.so'
      err = do_install_parser(logger, parser_lib, install_loc)
      if err then
        return err
      end

      -- Shared downloads are never deleted here — other langs may still need them.
      if source.queries_path or source.queries_dir then
        remote_project_dir = project_dir
      end
    end
  end

  -- ── install queries ───────────────────────────────────────────────────────
  if need_queries then
    local query_dir = fs.joinpath(config.get_install_dir('queries'), lang)

    if stype == 'queries_only' or stype == 'external_queries' then
      -- queries_project_dir was downloaded above; extract the .scm files from it.
      if not queries_project_dir then
        return logger:error('queries_project_dir is nil for %s (source type: %s)', lang, stype)
      end
      local project_dir = queries_project_dir

      -- queries live in <repo>/queries/<lang>/ (or just <repo>/queries/)
      local query_src = fs.joinpath(project_dir, 'queries', lang)
      if not uv.fs_stat(query_src) then
        query_src = fs.joinpath(project_dir, 'queries')
      end

      local err = do_copy_queries(logger, query_src, query_dir)
      if err then
        return err
      end

      rmpath(project_dir)
      a.schedule()
    elseif source.queries_path or source.queries_dir then
      local base_dir ---@type string
      if source.type == 'local' then
        base_dir = fs.normalize(source.path or '')
      else
        base_dir = remote_project_dir or fs.joinpath(cache_dir, 'tree-sitter-' .. lang)
      end
      -- queries_dir: parent dir whose <lang>/ subdir holds the .scm files.
      -- queries_path: full path to the dir containing .scm files directly.
      local query_src = source.queries_dir and fs.joinpath(base_dir, source.queries_dir, lang)
        or fs.joinpath(base_dir, source.queries_path)
      logger:debug('Copying queries from %s', query_src)
      local err = do_copy_queries(logger, query_src, query_dir)
      if err then
        return err
      end

      if remote_project_dir then
        rmpath(remote_project_dir)
        a.schedule()
        remote_project_dir = nil
      end
    else
      -- self_contained: queries ship with parser repo
      local queries_src =
        fs.joinpath(require('nvim-treesitter.install').get_package_path('runtime', 'queries', lang))
      if uv.fs_stat(queries_src) then
        local err = do_link_queries(logger, queries_src, query_dir)
        if err then
          return err
        end
      end
    end

    -- ── inheritance resolution ──────────────────────────────────────────────
    a.await(1, function(cb)
      require('nvim-treesitter.queries_resolver').resolve(
        lang,
        config.get_install_dir('queries'),
        cb
      )
    end)
  end

  -- ── write installed state ────────────────────────────────────────────────
  local cache = require('nvim-treesitter.cache')
  cache.set_installed(lang, {
    type = stype,
    parser_version = (not versions.skip_parser) and versions.latest_parser or nil,
    queries_version = versions.latest_queries,
  })

  logger:info('Language installed')
end

-- ── installing state guard ────────────────────────────────────────────────────

local installing = {} ---@type table<string, boolean?>

---@async
---@param lang        string
---@param entry       table
---@param versions    table
---@param install_dir string
---@param cache_dir   string
---@param force       boolean?
---@param opts        InstallOptions
---@return boolean success
local function install_lang(lang, entry, versions, install_dir, cache_dir, force, opts)
  if not force then
    local cache = require('nvim-treesitter.cache')
    local state = cache.get_installed(lang)
    if
      state
      and state.parser_version == versions.latest_parser
      and state.queries_version == versions.latest_queries
    then
      return true
    end
  end

  if installing[lang] then
    local success = vim.wait(INSTALL_TIMEOUT, function()
      return not installing[lang]
    end)
    return success
  end

  installing[lang] = true
  local err = install_one(lang, entry, versions, install_dir, cache_dir, opts)
  installing[lang] = nil
  return not err
end

-- ── public module ─────────────────────────────────────────────────────────────

local M = {}

---@param ...string
---@return string
function M.get_package_path(...)
  local info = debug.getinfo(1, 'S')
  if not info then
    error('debug.getinfo unavailable')
  end
  return fs.joinpath(fn.fnamemodify(info.source:sub(2), ':p:h:h:h'), ...)
end

-- ── InstallOptions ───────────────────────────────────────────────────────────

---@class InstallOptions
---@field force?    boolean  reinstall even if up to date
---@field summary?  boolean  print completion notification
---@field max_jobs? integer  parallelism cap

-- ── M.install ────────────────────────────────────────────────────────────────

---Install one or more languages.
---@async
---@param languages string[]|string
---@param opts?     InstallOptions
---@return boolean  true when all installations succeeded
M.install = a.async(function(languages, opts)
  opts = opts or {}

  -- 1. Without force, skip languages already present on disk — no registry or
  --    network access needed for them.  This keeps startup installs cheap.
  ---@type string[]?
  local raw_languages
  if not opts.force then
    local installed = config.get_installed()
    if type(languages) == 'string' then
      raw_languages = { languages }
    else
      raw_languages = languages or {}
    end
    -- Expand 'all' without the registry by intersecting with installed list
    if vim.list_contains(raw_languages, 'all') then
      -- 'all' with install = install everything available; still need registry
      raw_languages = nil -- fall through to registry load below
    else
      languages = vim.tbl_filter(function(lang)
        return not vim.list_contains(installed, lang)
      end, raw_languages)
      if #languages == 0 then
        return true -- everything already installed
      end
    end
  end

  -- 2. Load registry — needed to resolve language names and get source info
  local registry = require('nvim-treesitter.registry')
  a.await(1, function(cb)
    registry.load(cb)
  end)

  languages = config.norm_languages(languages)

  if #languages == 0 then
    return true
  end

  -- 3. Load cache and refresh stale version info for missing languages only
  local cache_mod = require('nvim-treesitter.cache')
  local cache = cache_mod.load()

  local stale = cache_mod.stale_langs(cache, languages)
  if #stale > 0 then
    local version_mod = require('nvim-treesitter.version')
    a.await(1, function(cb)
      version_mod.refresh_all(registry, stale, cache, cb)
    end)
  end

  -- 4. Resolve dirs
  local cache_dir = fs.normalize(fn.stdpath('cache') --[[@as string]])
  local install_dir = config.get_install_dir('parser')
  if not uv.fs_stat(cache_dir) then
    fn.mkdir(cache_dir, 'p')
  end

  -- 5. Build tasks, respecting `requires` dependency ordering.
  --    Languages are grouped into topological levels so that dependencies
  --    (e.g. ecma, jsx) are fully installed before dependents (javascript).
  local done = 0
  local total = 0
  local local_parsers = config.get_local_parsers()
  local parsers = require('nvim-treesitter.parsers')

  -- Map each language to its entry and versions
  local lang_set = {} ---@type table<string, boolean>
  local entries = {} ---@type table<string, table>
  local version_map = {} ---@type table<string, table>
  for _, lang in ipairs(languages) do
    local entry = local_parsers[lang] or registry.get(lang)
    if not entry then
      log.warn('No registry entry for %s, skipping', lang)
    else
      lang_set[lang] = true
      entries[lang] = entry
      version_map[lang] = (cache.parsers and cache.parsers[lang]) or {}
    end
  end

  -- Topological sort into levels: level 0 = no in-set deps, level N = depends on level N-1
  local level_of = {} ---@type table<string, integer>
  local function get_level(lang, visiting)
    if level_of[lang] ~= nil then
      return level_of[lang]
    end
    visiting = visiting or {}
    if visiting[lang] then
      level_of[lang] = 0 -- break cycle
      return 0
    end
    visiting[lang] = true
    local max_dep = -1
    local info = parsers[lang]
    if info and info.requires then
      for _, dep in ipairs(info.requires) do
        if lang_set[dep] then
          max_dep = math.max(max_dep, get_level(dep, visiting))
        end
      end
    end
    level_of[lang] = max_dep + 1
    return level_of[lang]
  end

  local levels = {} ---@type table<integer, string[]>
  local max_level = 0
  for lang in pairs(entries) do
    local lvl = get_level(lang)
    max_level = math.max(max_level, lvl)
    if not levels[lvl] then
      levels[lvl] = {}
    end
    levels[lvl][#levels[lvl] + 1] = lang
  end

  -- Install each level in parallel, but wait for each level to complete
  -- before starting the next (ensures dependencies are on disk).
  for lvl = 0, max_level do
    local batch = levels[lvl]
    if batch then
      local tasks = {} ---@type async.TaskFun[]
      for _, lang in ipairs(batch) do
        total = total + 1
        tasks[#tasks + 1] = a.async(--[[@async]] function()
          a.schedule()
          local ok = install_lang(
            lang,
            entries[lang],
            version_map[lang],
            install_dir,
            cache_dir,
            opts.force,
            opts
          )
          if ok then
            done = done + 1
          end
        end)
      end
      join(opts.max_jobs or MAX_JOBS, tasks)
    end
  end

  -- 6. Save updated cache
  cache_mod.save(cache)

  if total > 0 then
    a.schedule()
    if opts.summary then
      log.info('Installed %d/%d languages', done, total)
    end
  end

  return done == total
end)

-- ── M.update ──────────────────────────────────────────────────────────────────

---Check for newer versions and install them.
---@async
---@param languages? string[]|string  nil / empty = update all installed
---@param opts?      InstallOptions
---@return boolean   true when all updates succeeded
M.update = a.async(function(languages, opts)
  opts = opts or {}

  if not languages or (type(languages) == 'table' and #languages == 0) then
    languages = 'all'
  end

  -- 1. Load registry (may require a network fetch — notify the user)
  local registry = require('nvim-treesitter.registry')
  if not registry.loaded then
    log.info('Fetching parser registry...')
    a.schedule()
  end
  a.await(1, function(cb)
    registry.load(cb)
  end)

  -- Only consider already-installed languages for updates
  languages = config.norm_languages(languages, { missing = true })

  if #languages == 0 then
    if opts.summary then
      log.info('No parsers installed')
    end
    return true
  end

  -- 2. Load cache and refresh stale version info
  local cache_mod = require('nvim-treesitter.cache')
  local cache = cache_mod.load()

  local version_mod = require('nvim-treesitter.version')
  local stale = opts.force and languages or cache_mod.stale_langs(cache, languages)
  if #stale > 0 then
    log.info('Checking versions for %d parser(s)...', #stale)
    a.schedule()
    a.await(1, function(cb)
      version_mod.refresh_all(registry, stale, cache, cb)
    end)
    log.info('Version check complete')
    a.schedule()
  end

  -- 3. Filter to languages that actually need an update
  local to_update = vim.tbl_filter(function(lang)
    local state = cache_mod.get_installed(lang)
    local versions = (cache.parsers and cache.parsers[lang]) or {}
    if not state then
      return true
    end -- not yet installed → install
    if versions.latest_parser and versions.latest_parser ~= state.parser_version then
      return true
    end
    if versions.latest_queries and versions.latest_queries ~= state.queries_version then
      return true
    end
    return false
  end, languages)

  if #to_update == 0 then
    if opts.summary then
      log.info('All parsers are up-to-date')
    end
    return true
  end

  log.info('Updating %d parser(s)...', #to_update)
  a.schedule()

  -- 4. Perform installs (force = true since we already decided updates are needed)
  local cache_dir = fs.normalize(fn.stdpath('cache') --[[@as string]])
  local install_dir = config.get_install_dir('parser')
  if not uv.fs_stat(cache_dir) then
    fn.mkdir(cache_dir, 'p')
  end

  local tasks = {} ---@type async.TaskFun[]
  local done = 0
  local finished = 0
  local total = #to_update
  local local_parsers_upd = config.get_local_parsers()
  for _, lang in ipairs(to_update) do
    -- local_parsers entries ARE registry entries — use them directly.
    local entry = local_parsers_upd[lang] or registry.get(lang)
    if entry then
      local versions = (cache.parsers and cache.parsers[lang]) or {}
      tasks[#tasks + 1] = a.async(--[[@async]] function()
        a.schedule()
        local ok = install_lang(lang, entry, versions, install_dir, cache_dir, true, opts)
        if ok then
          done = done + 1
        end
        finished = finished + 1
        log.info('[%d/%d] %s %s', finished, total, lang, ok and 'done' or 'FAILED')
      end)
    end
  end

  join(opts.max_jobs or MAX_JOBS, tasks)
  cache_mod.save(cache)

  a.schedule()
  if opts.summary then
    if #tasks > 0 then
      log.info('Updated %d/%d languages', done, #tasks)
    end
  end

  return done == #tasks
end)

-- ── M.uninstall ───────────────────────────────────────────────────────────────

---Remove installed parser and queries for one or more languages.
---@async
---@param languages string[]|string
---@param opts?     InstallOptions
M.uninstall = a.async(function(languages, opts)
  opts = opts or {}
  languages = config.norm_languages(languages or 'all', { missing = true })

  local parser_dir = config.get_install_dir('parser')
  local query_dir = config.get_install_dir('queries')
  local installed = config.get_installed()
  local cache_mod = require('nvim-treesitter.cache')

  local tasks = {} ---@type async.TaskFun[]
  local done = 0

  for _, lang in ipairs(languages) do
    local logger = log.new('uninstall/' .. lang)
    if not vim.list_contains(installed, lang) then
      log.warn('Parser for %s is not managed by nvim-treesitter', lang)
    else
      local parser = fs.joinpath(parser_dir, lang) .. '.so'
      local queries = fs.joinpath(query_dir, lang)

      tasks[#tasks + 1] = a.async(--[[@async]] function()
        local had_err = false

        -- Remove parser .so
        if fn.filereadable(parser) == 1 then
          logger:debug('Unlinking %s', parser)
          local err = uv_unlink(parser)
          a.schedule()
          if err then
            logger:error(err)
            had_err = true
          end
        end

        -- Remove queries dir / symlink
        local stat = uv.fs_lstat(queries)
        if stat then
          logger:debug('Unlinking %s', queries)
          local err
          if stat.type == 'link' then
            err = uv_unlink(queries)
          else
            err = rmpath(queries)
          end
          a.schedule()
          if err then
            logger:error(err)
            had_err = true
          end
        end

        -- Clear installed state
        cache_mod.set_installed(lang, nil)

        if not had_err then
          done = done + 1
          logger:info('Language uninstalled')
        end
      end)
    end
  end

  join(MAX_JOBS, tasks)
  if #tasks > 1 then
    a.schedule()
    if opts.summary then
      log.info('Uninstalled %d/%d languages', done, #tasks)
    end
  end
end)

-- ── M.status ─────────────────────────────────────────────────────────────────

---Return a per-language status table.
---@return table<string, { installed: boolean, parser_version: string?, queries_version: string?, latest_parser: string?, latest_queries: string?, needs_update: boolean }>
function M.status()
  local registry = require('nvim-treesitter.registry')
  local cache_mod = require('nvim-treesitter.cache')

  -- Best-effort synchronous snapshot; full async refresh happens in install/update.
  if not registry.loaded then
    -- Try to load synchronously via pcall; if unavailable, return empty.
    pcall(function()
      local done = false
      registry.load(function()
        done = true
      end)
      vim.wait(5000, function()
        return done
      end)
    end)
  end

  local cache = cache_mod.load()
  local result = {} ---@type table<string, any>

  -- Collect all known langs from both registry and installed state
  local all_langs = {} ---@type table<string, boolean>
  if registry.loaded then
    for lang in pairs(registry.loaded) do
      all_langs[lang] = true
    end
  end
  for _, lang in ipairs(config.get_installed()) do
    all_langs[lang] = true
  end

  for lang in pairs(all_langs) do
    local state = cache_mod.get_installed(lang)
    local versions = (cache.parsers and cache.parsers[lang]) or {}

    local installed = state ~= nil
    local pv = state and state.parser_version
    local qv = state and state.queries_version
    local lp = versions.latest_parser
    local lq = versions.latest_queries

    local needs = installed and ((lp and lp ~= pv) or (lq and lq ~= qv)) or false

    result[lang] = {
      installed = installed,
      parser_version = pv,
      queries_version = qv,
      latest_parser = lp,
      latest_queries = lq,
      needs_update = needs,
    }
  end

  return result
end

return M
