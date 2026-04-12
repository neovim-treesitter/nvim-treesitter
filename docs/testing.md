# Testing Setup

## Overview

Tests run headlessly under Neovim using [plentest.nvim](https://github.com/nvim-treesitter/plentest.nvim)
as the test runner. All test dependencies are managed by the `Makefile` and downloaded into `.test-deps/`.

---

## Quick Start

```bash
# Download all test deps (nvim, parsers, tooling)
make nvim hlassert plentest tsqueryls

# Run all tests
make tests

# Run a specific suite
make tests TESTS=query
make tests TESTS=indent
make tests TESTS=install
```

---

## Test Dependencies

All deps land in `.test-deps/` (git-ignored). The `Makefile` downloads and extracts
each one automatically.

| Dep | Makefile target | What it is |
|-----|-----------------|------------|
| `nvim-{arch}/` | `make nvim` | Neovim nightly binary used for all headless runs |
| `hlassert-{arch}/` | `make hlassert` | [highlight-assertions](https://github.com/nvim-treesitter/highlight-assertions) CLI — parses `; <- @capture` comments in test files |
| `plentest.nvim/` | `make plentest` | plentest test runner (git-cloned) |
| `ts_query_ls-{arch}/` | `make tsqueryls` | ts_query_ls LSP binary for query lint/format/check |
| `stylua-{arch}/` | `make stylua` | StyLua formatter |
| `emmylua_check-{arch}/` | `make emmyluals` | EmmyLua static analyser |

**Note:** nvim-treesitter no longer depends on plenary.nvim. It uses Neovim's built-in
`vim.net.request()` (available in Neovim 0.12+) for HTTP operations.

---

## `scripts/minimal_init.lua`

This is the `-u` init script passed to every headless run. It:

1. Prepends `$PLENTEST` (set by Makefile to `.test-deps/plentest.nvim`) to `rtp`
2. Prepends `stdpath('data') .. '/site'` to `rtp` (so any site-installed parsers are visible)
3. Loads `plugin/query_predicates.lua` and `plugin/filetypes.lua` via `:runtime!`
4. Adds `conf → hocon` and `w → wing` filetype mappings
5. Disables swapfile
6. Sets up a `FileType` autocmd that starts treesitter and sets `indentexpr`

If a test suite needs additional plugins, add them to the rtp either in
`minimal_init.lua` or at the top of the spec file.

---

## How Tests Are Run

The Makefile invokes:

```bash
HLASSERT=.test-deps/hlassert-{arch}/highlight-assertions \
PLENTEST=.test-deps/plentest.nvim \
  .test-deps/nvim-{arch}/bin/nvim \
    --headless --clean \
    -u scripts/minimal_init.lua \
    -c "lua require('plentest').test_directory('tests/$(TESTS)', { minimal_init = './scripts/minimal_init.lua' })"
```

`TESTS` defaults to empty (runs all of `tests/`). Pass `TESTS=query` etc. to scope to a
subdirectory.

---

## Test Suites

### `tests/query/` — Query validation

- `highlights_spec.lua` — loads highlight test files from `tests/query/highlights/**/*.*`,
  runs the `highlight-assertions` CLI to parse `; <- @capture` annotations, then checks
  each expected capture against the actual tree-sitter captures.
- `injection_spec.lua` — similar for injection queries.

These tests require installed parsers (`.so` files) for every language under test. Run
`make tests TESTS=query` after installing parsers.

### `tests/indent/` — Indentation

Tests `v:lua.require"nvim-treesitter".indentexpr()` for each language under `tests/indent/`.

### `tests/install/` — Installer unit + integration

`install_spec.lua` covers `lua/nvim-treesitter/install.lua`:

- **Unit:** `semver_gt`, `tarball_url` (pure Lua, no I/O)
- **Integration with stubs:** install, update, uninstall, status — all HTTP and build
  calls are replaced with in-process stubs so tests run fast and offline.

**Mocking strategy:**

```
vim.net.request → package.loaded['vim.net.request'] stub (placed before any require)
vim.system      → per-test replacement; creates parser.so, simulates tar extraction
registry.load   → wraps to call callback via vim.schedule
version.refresh_all → injects versions into cache table, calls on_done via vim.schedule
queries_resolver.resolve → no-op stub calling cb via vim.schedule
```

The `vim.net.request` stub must be set in `package.loaded` **before** any module that
uses HTTP is first `require`d. The spec file does this at the very top.

---

## Writing New Specs

1. Create `tests/<suite>/<name>_spec.lua`
2. Use the plenltest API: `describe`, `it`, `before_each`, `after_each`
3. Use `assert.True`, `assert.Falsy`, `assert.are.equal`, `assert.is.number`, etc.
   (luassert, bundled with plenltest)
4. For async code, use `vim.wait` with a done flag.
5. Run with `make tests TESTS=<suite>`

Example skeleton:

```lua
describe('my module', function()
  local M

  before_each(function()
    package.loaded['my.module'] = nil
    M = require('my.module')
  end)

  it('does the thing', function()
    assert.True(M.do_thing())
  end)
end)
```

---

## CI

The GitHub Actions workflow (`.github/workflows/`) runs `make tests` on push/PR.
Parsers are pre-built and cached. The `tree-sitter/setup-action` action installs the
tree-sitter CLI and configures parser directories.
