<h1 align="center">
  <img src="https://github.com/nvim-treesitter/nvim-treesitter/assets/2361214/0513b223-c902-4f12-92ee-8ac4d8d6f41f" alt="nvim-treesitter">
</h1>

`nvim-treesitter` installs tree-sitter parsers and the Neovim query files that
go with them (highlights, injections, folds, indents, locals). Parsers and
queries are discovered from a [community registry][registry] rather than
pinned inside this repo, so each language's queries are maintained by the
people who use that language.

This is a fork of [nvim-treesitter/nvim-treesitter][upstream] that replaces
the monolithic query collection with a distributed model: per-language query
repos, a shared parser registry, and CI infrastructure for validating queries.
See the [neovim-treesitter org][org] for the full ecosystem.

> [!CAUTION]
> This is a full, incompatible rewrite. Treat it as a new plugin and set it up
> from scratch following the instructions below. If you need the previous
> version, use the [`master` branch][master] (locked, no new features).

[registry]: https://github.com/neovim-treesitter/treesitter-parser-registry
[upstream]: https://github.com/nvim-treesitter/nvim-treesitter
[org]: https://github.com/neovim-treesitter
[master]: https://github.com/nvim-treesitter/nvim-treesitter/blob/master/README.md

---

## Requirements

| Requirement | Version |
|-------------|---------|
| Neovim | 0.12.0 or later |
| [`tree-sitter` CLI][ts-cli] | 0.26.1 or later — install via your system package manager, **not npm** |
| C compiler | see [cc requirements][cc] |

[ts-cli]: https://github.com/tree-sitter/tree-sitter/blob/master/crates/cli/README.md
[cc]: https://docs.rs/cc/latest/cc/#compile-time-requirements

> [!IMPORTANT]
> Neovim support tracks the latest **stable release** and the latest
> **nightly prerelease** only. Other versions may work but are not tested.

---

## Installation

### lazy.nvim

```lua
{
  'nvim-treesitter/nvim-treesitter',
  lazy = false,
  build = ':TSUpdate',
}
```

> [!IMPORTANT]
> This plugin does not support lazy-loading.

### Other plugin managers

Add `:TSUpdate` as a post-install / post-update build step.

---

## Quick start

You do not need to call `setup` unless you want to change the install
directory.

```lua
-- optional — only needed to override the default install_dir
require('nvim-treesitter').setup {
  -- parsers and queries are installed here (prepended to runtimepath)
  install_dir = vim.fn.stdpath('data') .. '/site',
}
```

Install parsers and their queries:

```lua
require('nvim-treesitter').install { 'rust', 'python', 'typescript' }
```

Then enable features per language. Features are **not** enabled automatically.

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'rust', 'python', 'typescript' },
  callback = function()
    vim.treesitter.start()                                    -- highlighting
    vim.wo.foldexpr = 'v:lua.vim.treesitter.foldexpr()'     -- folds
    vim.wo.foldmethod = 'expr'
    vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()" -- indentation
  end,
})
```

---

## Commands

| Command | Description |
|---------|-------------|
| `:TSInstall {lang...}` | Install parsers and queries. No-op if already installed. |
| `:TSInstall! {lang...}` | Force reinstall (useful after upgrading the plugin). |
| `:TSUpdate [{lang...}]` | Update installed parsers and queries to latest release. Omit languages to update all. |
| `:TSUpdate! [{lang...}]` | Update, bypassing the per-parser version cache (24h TTL). |
| `:TSUninstall {lang...}` | Remove parsers and queries for the specified languages. |
| `:TSRegistryUpdate` | Force-refresh the registry from GitHub, bypassing the 7-day cache. |
| `:TSStatus` | Open a status buffer showing installed version vs. latest for each language. |
| `:TSLog` | Show log from the last install/update/uninstall run. |

---

## Supported languages and features

Languages are discovered from the [neovim-treesitter registry][registry]. Any
language in the registry can be installed; there are no tiers.

### Registry and version caching

Two caches avoid unnecessary network requests:

1. **Registry cache** (7-day TTL) — the full `registry.json` is fetched from
   GitHub on first use and stored at `<stdpath('data')>/site/registry/`.
   Subsequent loads within 7 days use the cached copy. If a fetch fails, the
   stale cache is used as a fallback.

2. **Per-parser version cache** (24-hour TTL) — for each installed language,
   the latest known parser and query versions are cached so `:TSUpdate` doesn't
   hit the network for every language on every run.

To refresh each cache independently:

```vim
" Force re-fetch the registry (e.g. after a new language is added)
:TSRegistryUpdate

" Force re-check per-parser versions (bypasses the 24h cache)
:TSUpdate!
```

### What is installed

For each language, `nvim-treesitter` installs:

- **Parser** — a compiled `.so` fetched from the upstream grammar repository
- **Queries** — `.scm` files sourced from whichever location the registry designates:
  - A community query repo (`nvim-treesitter-queries-<lang>` under the
    [neovim-treesitter][org] GitHub org) for `external_queries` languages
  - The parser repo itself for `self_contained` languages (where the parser
    author ships Neovim queries alongside the grammar)

The source type is transparent to users — `:TSInstall` handles both.

### Supported query types

| Query file | Feature | How to enable |
|------------|---------|---------------|
| `highlights.scm` | Syntax highlighting | `vim.treesitter.start()` |
| `injections.scm` | Multi-language documents | automatic after `start()` |
| `folds.scm` | Treesitter-based folds | `vim.wo.foldmethod = 'expr'` |
| `indents.scm` | Treesitter-based indentation | `vim.bo.indentexpr = ...` |
| `locals.scm` | Scope/definition lookup | used by other plugins |

---

## Local overrides

### Override queries for a language

Query files in your Neovim config's `runtimepath` take precedence over
installed queries. Place a file at:

```
~/.config/nvim/queries/<lang>/<type>.scm
```

To **extend** (not replace) the installed queries, add this as the first line:

```scheme
; extends
```

To **replace** them entirely, omit that line.

See `:h treesitter-query-modelines` for details.

### Use a local parser checkout

Point `install_dir` at a directory you manage, then place your compiled parser
and queries there directly:

```
<install_dir>/
  parser/
    <lang>.so          ← compiled parser binary
  queries/
    <lang>/
      highlights.scm   ← query files
```

```lua
require('nvim-treesitter').setup {
  install_dir = '/path/to/my/parsers',
}
```

Neovim will use parsers and queries from `install_dir` as long as it is on
`runtimepath`, which `setup` ensures. You can still use `:TSInstall` for other
languages alongside your local overrides.

---

## Local parsers

To install a parser that is not in the registry, or to use your own fork of a
parser, add it to `local_parsers` in `setup()`. Each value is a **registry
entry** — the same shape used in `registry.json` — with a `source` field:

```lua
-- Local directory checkout (no network fetch)
require('nvim-treesitter').setup {
  local_parsers = {
    zsh = {
      source = {
        type         = 'local',
        path         = '~/Development/tree-sitter-zsh',
        queries_path = 'nvim-queries/zsh',  -- subdir containing .scm files
      },
      filetypes = { 'zsh' },
    },
  },
}

-- Remote URL not in the registry (self_contained = ships its own queries)
require('nvim-treesitter').setup {
  local_parsers = {
    zsh = {
      source = {
        type         = 'self_contained',
        url          = 'https://github.com/georgeharker/tree-sitter-zsh',
        semver       = false,
        queries_path = 'nvim-queries/zsh',
      },
      filetypes = { 'zsh' },
    },
  },
}
```

Then: `:TSInstall zsh`

If Neovim does not detect your language's filetype by default, register the
parser name manually:

```lua
vim.treesitter.language.register('mylang', { 'ml' })
```

---

## Contributing

### Fixing or improving queries for an existing language

Each language's queries live in their own repository under the
[neovim-treesitter][org] GitHub org:

```
https://github.com/neovim-treesitter/nvim-treesitter-queries-<lang>
```

Open a pull request there. CI will validate your changes automatically. See
the [contributing guide][contributing] for the full workflow.

[org]: https://github.com/neovim-treesitter
[contributing]: https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/contributing.md

### Adding a new language

1. Open a pull request adding an entry to
   [`registry.json`][registry-json] in the registry repo
2. Create the `nvim-treesitter-queries-<lang>` repository following the
   [query repo setup guide][setup-guide]

Alternatively, if you maintain the parser itself you can ship queries
directly from your parser repo using the **self-contained** model — see the
[self-contained migration guide][sc-guide].

[registry-json]: https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/registry.json
[setup-guide]: https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/contributing.md#creating-a-query-repo
[sc-guide]: https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/self-contained-migration.md

### Claiming maintainership of a language repo

Add yourself to the `CODEOWNERS` file in the language's query repo and open
a PR. See the [governance guide][governance] for details.

[governance]: https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/contributing.md#governance-and-ownership

---

## Migrating from the previous version

The previous version of `nvim-treesitter` pinned specific parser revisions
inside the plugin and used a tiered system (stable/unstable/unmaintained).
The new version:

- Discovers languages and their latest versions from the community registry
- Fetches queries from per-language repos maintained by language communities
- Has no tiers — if a language is in the registry it can be installed
- No longer uses `parsers.lua` — per-language config via `parsers.<lang> = {}`
  is not supported in this version
- Removes `:TSInstallFromGrammar` — parser generation from grammar source is
  not part of the installer's scope

### Plugin manager build step

Replace any reference to tiers in your build step:

```lua
-- before (no longer valid)
build = ':TSUpdate stable'

-- after
build = ':TSUpdate'
```

### Custom parser entries

The old pattern using a `User TSUpdate` autocmd no longer works:

```lua
-- OLD — no longer supported
vim.api.nvim_create_autocmd('User', {
  pattern = 'TSUpdate',
  callback = function()
    require('nvim-treesitter.parsers').zsh = {
      install_info = {
        url = 'https://github.com/georgeharker/tree-sitter-zsh',
        queries = 'nvim-queries/zsh',
      },
      tier = 1,
    }
  end,
})
```

Use `local_parsers` in `setup()` instead:

```lua
-- NEW — remote URL (self_contained: ships its own queries)
require('nvim-treesitter').setup {
  local_parsers = {
    zsh = {
      source = {
        type         = 'self_contained',
        url          = 'https://github.com/georgeharker/tree-sitter-zsh',
        queries_path = 'nvim-queries/zsh',
      },
      filetypes = { 'zsh' },
    },
  },
}
```

For a local directory checkout instead of a remote URL:

```lua
require('nvim-treesitter').setup {
  local_parsers = {
    zsh = {
      source = {
        type         = 'local',
        path         = '~/Development/tree-sitter-zsh',
        queries_path = 'nvim-queries/zsh',
      },
      filetypes = { 'zsh' },
    },
  },
}
```

Then install as normal: `:TSInstall zsh`.

| Old field | New field | Notes |
|-----------|-----------|-------|
| `url = '...'` | `source.url = '...'` | moved under `source` |
| `path = '...'` | `source.path = '...'` | moved under `source`, implies `type = 'local'` |
| `location = '...'` | `source.location = '...'` | monorepo subdir, moved under `source` |
| `queries = 'subdir'` | `source.queries_path = 'subdir'` | renamed and moved under `source` |
| `semver = false` | `source.semver = false` | moved under `source` |
| `revision` / `min_version` | _(removed)_ | version managed by the registry |
| `tier` | _(removed)_ | no tiers in new system |
| `generate` / `generate_from_json` | _(removed)_ | parser generation not supported |

---

## Health check

Run `:checkhealth nvim-treesitter` to verify the installation.
