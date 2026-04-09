# Contributing to `nvim-treesitter`

`nvim-treesitter` is the installer plugin. Parser and query content is managed externally:

- **Parsers** are registered in the [treesitter-parser-registry][registry]
- **Queries** live either in the parser repo itself (`self_contained`) or in
  per-language repos (`nvim-treesitter-queries-<lang>`) under the
  [neovim-treesitter][org] GitHub org

For the full contributing workflow — adding languages, maintaining query repos,
shipping queries from your parser repo, CI/CD, governance — see the
**[registry contributing guide][registry-contributing]**.

If you maintain a tree-sitter parser and want to ship Neovim queries directly
from your repo, see the **[self-contained migration guide][sc-guide]**.

[registry]: https://github.com/neovim-treesitter/treesitter-parser-registry
[org]: https://github.com/neovim-treesitter
[registry-contributing]: https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/contributing.md
[sc-guide]: https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/self-contained-migration.md

---

## Bugs and features in the installer itself

For issues with the `nvim-treesitter` plugin code (installation, commands,
indentation logic, etc.) — as opposed to query content — open an issue or PR
in this repo.

Some useful references:
- [Neovim treesitter docs](https://neovim.io/doc/user/treesitter.html#treesitter)
- [tree-sitter docs](https://tree-sitter.github.io/tree-sitter/)
- Matrix: [#nvim-treesitter](https://matrix.to/#/#nvim-treesitter:matrix.org),
  [#tree-sitter](https://matrix.to/#/#tree-sitter-chat:matrix.org)
