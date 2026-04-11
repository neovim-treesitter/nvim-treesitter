#!/usr/bin/env bash
# compare-upstream-queries.sh
#
# Compares every .scm file in runtime/queries/ against the upstream
# nvim-treesitter/nvim-treesitter commit (stored as upstream/master).
#
# Also keeps the sibling query-repos/ directory in sync:
#   ../query-repos/nvim-treesitter-queries-<lang>/queries/<file>.scm
#
# Usage:
#   ./scripts/compare-upstream-queries.sh                          # show summary
#   ./scripts/compare-upstream-queries.sh --fix                    # restore all diffs to upstream
#                                                                   # and sync into query-repos/
#   ./scripts/compare-upstream-queries.sh --diff                   # show full diffs
#   ./scripts/compare-upstream-queries.sh --fix --query-repos PATH # explicit query-repos location
#
# The query-repos directory can also be set via the QUERY_REPOS_DIR env var.
# Default: the 'query-repos' sibling directory next to this repo.
#
# Upstream stores queries at queries/<lang>/<file>.scm (no runtime/ prefix).
# Local  stores queries at runtime/queries/<lang>/<file>.scm
# Repos  stores queries at <query-repos-dir>/nvim-treesitter-queries-<lang>/queries/<file>.scm

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REF="${UPSTREAM_REF:-upstream/master}"
LOCAL_QUERIES="$REPO_ROOT/runtime/queries"

MODE="summary"
QUERY_REPOS_DIR="${QUERY_REPOS_DIR:-$(dirname "$REPO_ROOT")/query-repos}"

# Parse args
while [[ $# -gt 0 ]]; do
  case "${1}" in
    --fix)        MODE="fix";  shift ;;
    --diff)       MODE="diff"; shift ;;
    --query-repos)
      shift
      QUERY_REPOS_DIR="${1:?--query-repos requires a path argument}"
      shift
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Resolve upstream commit SHA once
UPSTREAM_SHA=$(git -C "$REPO_ROOT" rev-parse "$UPSTREAM_REF" 2>/dev/null) || {
  echo "ERROR: Cannot resolve $UPSTREAM_REF. Run: git fetch upstream" >&2
  exit 1
}
echo "Upstream ref:  $UPSTREAM_REF ($UPSTREAM_SHA)"
echo "Local queries: $LOCAL_QUERIES"
echo "Query repos:   $QUERY_REPOS_DIR"
echo "Mode:          $MODE"
echo ""

# Write content to both runtime/queries/ and query-repos/ (if it exists)
sync_file() {
  local lang_file="$1"   # e.g. ecma/highlights.scm
  local content="$2"
  local lang="${lang_file%%/*}"
  local file="${lang_file#*/}"
  local local_abs="$LOCAL_QUERIES/$lang_file"
  local repo_queries="$QUERY_REPOS_DIR/nvim-treesitter-queries-${lang}/queries"

  # Write to runtime/queries/
  mkdir -p "$(dirname "$local_abs")"
  printf '%s\n' "$content" > "$local_abs"

  # Write to query-repos/ if that repo exists locally
  if [[ -d "$repo_queries" ]]; then
    printf '%s\n' "$content" > "$repo_queries/$file"
    echo "  FIXED (runtime + query-repo): $lang_file"
  else
    echo "  FIXED (runtime only):         $lang_file  [no local query-repo]"
  fi
}

# Collect all .scm paths that exist in upstream under queries/
UPSTREAM_FILES=$(git -C "$REPO_ROOT" ls-tree -r --name-only "$UPSTREAM_SHA" \
  | grep '^queries/.*\.scm$' | sort)

# Collect all .scm paths that exist locally under runtime/queries/
LOCAL_FILES=$(find "$LOCAL_QUERIES" -name '*.scm' \
  | sed "s|$LOCAL_QUERIES/||" | sort)

ONLY_UPSTREAM=()
ONLY_LOCAL=()
DIFFERENT=()
SAME=0
QUERY_REPOS_SYNCED=0

# --- check upstream files against local ---
while IFS= read -r up_path; do
  lang_file="${up_path#queries/}"          # e.g. ecma/highlights.scm
  local_abs="$LOCAL_QUERIES/$lang_file"

  upstream_content=$(git -C "$REPO_ROOT" show "$UPSTREAM_SHA:$up_path" 2>/dev/null) || {
    ONLY_LOCAL+=("$lang_file (upstream read error)")
    continue
  }

  if [[ ! -f "$local_abs" ]]; then
    ONLY_UPSTREAM+=("$lang_file")

    if [[ "$MODE" == "fix" ]]; then
      sync_file "$lang_file" "$upstream_content"
      ((QUERY_REPOS_SYNCED++)) || true
    fi
    continue
  fi

  local_content=$(cat "$local_abs")

  if [[ "$upstream_content" != "$local_content" ]]; then
    DIFFERENT+=("$lang_file")

    if [[ "$MODE" == "diff" ]]; then
      echo "=== DIFF: $lang_file ==="
      diff <(printf '%s\n' "$upstream_content") <(printf '%s\n' "$local_content") || true
      echo ""
    fi

    if [[ "$MODE" == "fix" ]]; then
      sync_file "$lang_file" "$upstream_content"
      ((QUERY_REPOS_SYNCED++)) || true
    fi
  else
    # runtime/queries is correct — still sync query-repo if it's stale
    if [[ "$MODE" == "fix" ]]; then
      _lang="${lang_file%%/*}"
      _file="${lang_file#*/}"
      _repo_queries="$QUERY_REPOS_DIR/nvim-treesitter-queries-${_lang}/queries"
      if [[ -d "$_repo_queries" ]]; then
        repo_content=$(cat "$_repo_queries/$_file" 2>/dev/null || echo "")
        if [[ "$upstream_content" != "$repo_content" ]]; then
          printf '%s\n' "$upstream_content" > "$_repo_queries/$_file"
          echo "  SYNCED query-repo only:       $lang_file"
          ((QUERY_REPOS_SYNCED++)) || true
        fi
      fi
    fi
    ((SAME++)) || true
  fi
done <<< "$UPSTREAM_FILES"

# --- check local-only files ---
while IFS= read -r local_path; do
  up_path="queries/$local_path"
  if ! git -C "$REPO_ROOT" cat-file -e "$UPSTREAM_SHA:$up_path" 2>/dev/null; then
    ONLY_LOCAL+=("$local_path")

    # Still sync local-only files into query-repos/ even if not in upstream
    if [[ "$MODE" == "fix" ]]; then
      _lang="${local_path%%/*}"
      _file="${local_path#*/}"
      _repo_queries="$QUERY_REPOS_DIR/nvim-treesitter-queries-${_lang}/queries"
      if [[ -d "$_repo_queries" ]]; then
        repo_content=$(cat "$_repo_queries/$_file" 2>/dev/null || echo "")
        local_content=$(cat "$LOCAL_QUERIES/$local_path")
        if [[ "$local_content" != "$repo_content" ]]; then
          printf '%s\n' "$local_content" > "$_repo_queries/$_file"
          echo "  SYNCED query-repo (local-only): $local_path"
          ((QUERY_REPOS_SYNCED++)) || true
        fi
      fi
    fi
  fi
done <<< "$LOCAL_FILES"

# --- report ---
echo ""
echo "===== SUMMARY ====="
echo "  Identical:      $SAME"
echo "  Different:      ${#DIFFERENT[@]}"
echo "  Only upstream:  ${#ONLY_UPSTREAM[@]}"
echo "  Only local:     ${#ONLY_LOCAL[@]}"
if [[ "$MODE" == "fix" ]]; then
  echo "  Query-repos synced: $QUERY_REPOS_SYNCED"
fi
echo ""

if [[ ${#DIFFERENT[@]} -gt 0 ]]; then
  echo "--- FILES THAT DIFFER FROM UPSTREAM ---"
  for f in "${DIFFERENT[@]}"; do echo "  $f"; done
  echo ""
fi

if [[ ${#ONLY_UPSTREAM[@]} -gt 0 ]]; then
  echo "--- FILES ONLY IN UPSTREAM (missing locally) ---"
  for f in "${ONLY_UPSTREAM[@]}"; do echo "  $f"; done
  echo ""
fi

if [[ ${#ONLY_LOCAL[@]} -gt 0 ]]; then
  echo "--- FILES ONLY LOCAL (not in upstream) ---"
  for f in "${ONLY_LOCAL[@]}"; do echo "  $f"; done
  echo ""
fi

if [[ "$MODE" == "fix" ]]; then
  echo "Fixed ${#DIFFERENT[@]} divergent file(s), added ${#ONLY_UPSTREAM[@]} upstream-only file(s)."
  echo "Synced $QUERY_REPOS_SYNCED file(s) into query-repos/."
  echo "NOTE: Local-only query-repos without a matching dir were NOT created."
fi

if [[ "$MODE" == "summary" && (${#DIFFERENT[@]} -gt 0 || ${#ONLY_UPSTREAM[@]} -gt 0) ]]; then
  echo "Run with --diff to see full diffs, or --fix to restore all divergent files to upstream"
  echo "and sync into query-repos/."
fi
