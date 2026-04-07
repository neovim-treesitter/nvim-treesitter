# nvim-treesitter-queries-{{LANG}}

[![Validate Queries](https://github.com/neovim-treesitter/nvim-treesitter-queries-{{LANG}}/actions/workflows/validate.yml/badge.svg)](https://github.com/neovim-treesitter/nvim-treesitter-queries-{{LANG}}/actions/workflows/validate.yml)

Neovim tree-sitter queries for **{{LANG}}**, part of the
[neovim-treesitter](https://github.com/neovim-treesitter) ecosystem.

These query files were originally extracted from
[nvim-treesitter/nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
and are now maintained independently, enabling per-language versioning and
community ownership.

---

## Contents

| File | Purpose | Required? |
|------|---------|-----------|
| `queries/highlights.scm` | Syntax highlighting | Recommended |
| `queries/injections.scm` | Embedded language injections | Optional |
| `queries/folds.scm` | Code folding ranges | Optional |
| `queries/indents.scm` | Indentation rules | Optional |
| `queries/locals.scm` | Scope / locals (used by refactor plugins) | Optional |

Not every language needs all five files. Only `highlights.scm` is expected for
most languages; the rest are added when the grammar supports them.

---

## `parser.json`

`parser.json` describes the tree-sitter grammar this query set targets. It is
read by the CI workflow and by compatible plugin managers to fetch the correct
parser version.

```jsonc
{
  // URL of the upstream grammar repository
  "url": "https://github.com/tree-sitter/tree-sitter-{{LANG}}",

  // Exact git ref (tag or SHA) of the parser repo these queries are tested
  // against.  The installer uses this as the checkout target — omit (null)
  // to fall back to the latest tag or HEAD on the parser repo.
  "parser_version": "v0.23.0",

  // Optional: subdirectory inside the grammar repo that contains the
  // parser source (only needed for multi-language grammar repos).
  "location": null,

  // Set true when the grammar is pre-built and no compile step is needed.
  "queries_only": false,

  // Set true when the parser repo does not ship a pre-generated src/parser.c
  // and requires running `tree-sitter generate` before compilation.
  // Omit (or set false) when src/parser.c is already present in the repo.
  "generate": false,

  // Controls the input to `tree-sitter generate` when generate is true:
  //   true  — use src/grammar.json  (faster; no JS runtime required)
  //   false — use grammar.js        (requires a JS runtime)
  // Omit when generate is false.
  "generate_from_json": false
}
```

Fields are consumed by `.github/workflows/validate.yml` at CI time and by
plugin managers (e.g. [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter))
at install time.

---

## Contributing

Contributions — query improvements, new query types, parser.json updates — are
welcome.

Please read the contribution guide before opening a PR:
<https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/contributing.md>

Quick checklist:

- [ ] Queries pass the CI `validate.yml` workflow locally
  (`ts-query-ls check --parser <parser.so> queries/`)
- [ ] Changes are scoped to `{{LANG}}` — do not include files for other languages
- [ ] `parser.json` is updated if the pinned parser version changes

---

## Maintainers

This repository is governed by `CODEOWNERS`. Anyone listed there receives review
requests for all pull requests and is considered the active maintainer(s) of the
`{{LANG}}` queries.

**Claiming maintainership**: open a PR that adds your GitHub username to
`CODEOWNERS`. See the registry documentation for the full process:
<https://github.com/neovim-treesitter/treesitter-parser-registry/blob/main/docs/contributing.md>

If `CODEOWNERS` is empty this language is unmaintained — contributions and
maintainership claims are especially welcome.

---

## License

MIT — see [LICENSE](LICENSE).

> Query files were originally contributed to
> [nvim-treesitter/nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
> under the MIT license by the nvim-treesitter contributors.
