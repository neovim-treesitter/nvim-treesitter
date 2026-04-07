#!/usr/bin/env bash
# update-query-repo-workflows.sh — update all nvim-treesitter-queries-* repos to use
# the neovim-treesitter/.github reusable workflow instead of an inline validate.yml
#
# Usage: ./scripts/update-query-repo-workflows.sh [lang ...]
#
# Requires: gh (GitHub CLI, authenticated), git
# Run from the nvim-treesitter repo root.
#
# By default updates all nvim-treesitter-queries-* repos in the neovim-treesitter org.
# Pass one or more lang names to update only those repos.
#
# Repos are cloned into the parent directory of this repo (i.e. alongside nvim-treesitter).
# If a clone already exists there it is reused (git pull + branch reset).

set -euo pipefail

ORG="neovim-treesitter"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT_DIR="$(dirname "$REPO_ROOT")"
VALIDATE_TEMPLATE="${REPO_ROOT}/scripts/templates/query-validate.yml"

if [[ ! -f "$VALIDATE_TEMPLATE" ]]; then
  echo "ERROR: template not found at $VALIDATE_TEMPLATE" >&2
  exit 1
fi

# Use org-specific token if provided
if [[ -n "${NVIM_TS_GH_TOKEN:-}" ]]; then
  export GH_TOKEN="$NVIM_TS_GH_TOKEN"
fi

# ---------------------------------------------------------------------------
# Determine list of langs to process
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
  LANGS=("$@")
else
  LANGS=()
  while IFS= read -r repo; do
    LANGS+=("${repo#nvim-treesitter-queries-}")
  done < <(gh repo list "$ORG" --limit 500 --json name --jq '.[].name' \
    | grep '^nvim-treesitter-queries-' | sort)
fi

echo "Updating ${#LANGS[@]} repos in ${ORG}..."
echo ""

COUNT_UPDATED=0
COUNT_SKIPPED=0
COUNT_FAILED=0
FAILED_LANGS=()

# ---------------------------------------------------------------------------
# Per-language processing
# ---------------------------------------------------------------------------
process_lang() {
  local LANG="$1"
  local REPO_NAME="nvim-treesitter-queries-${LANG}"
  local FULL_REPO="${ORG}/${REPO_NAME}"
  local REPO_DIR="${PARENT_DIR}/${REPO_NAME}"

  echo "==> ${LANG}"

  # Clone or update local copy
  if [[ -d "${REPO_DIR}/.git" ]]; then
    echo "    reusing existing clone at ${REPO_DIR}"
    git -C "$REPO_DIR" fetch --quiet origin
    git -C "$REPO_DIR" checkout --quiet main 2>/dev/null || git -C "$REPO_DIR" checkout --quiet -b main origin/main
    git -C "$REPO_DIR" reset --quiet --hard origin/main
  else
    echo "    cloning into ${REPO_DIR}"
    git clone --quiet "git@github.com:${FULL_REPO}.git" "$REPO_DIR"
  fi

  # Check current workflow content — skip if already matches the template exactly
  local WORKFLOW_FILE="${REPO_DIR}/.github/workflows/validate.yml"
  if [[ -f "$WORKFLOW_FILE" ]] && cmp -s "$VALIDATE_TEMPLATE" "$WORKFLOW_FILE"; then
    echo "    skip: already up to date"
    return 2
  fi

  # Write from template
  mkdir -p "${REPO_DIR}/.github/workflows"
  cp "$VALIDATE_TEMPLATE" "$WORKFLOW_FILE"

  # Commit and push
  git -C "$REPO_DIR" add ".github/workflows/validate.yml"
  git -C "$REPO_DIR" commit --quiet -m "ci: sync validate.yml from nvim-treesitter template"
  git -C "$REPO_DIR" push --quiet origin main

  echo "    done"
  return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
for LANG in "${LANGS[@]}"; do
  set +e
  (
    set -e
    process_lang "$LANG"
  )
  EXIT_CODE=$?
  set -e

  case $EXIT_CODE in
    0)  (( COUNT_UPDATED++ )) || true ;;
    2)  (( COUNT_SKIPPED++ )) || true ;;
    *)
      echo "    FAILED: ${LANG} (exit ${EXIT_CODE})"
      (( COUNT_FAILED++ )) || true
      FAILED_LANGS+=("$LANG")
      ;;
  esac

  sleep 0.5
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Summary"
echo "========================================"
printf "  Updated : %d\n" "$COUNT_UPDATED"
printf "  Skipped : %d (already up to date)\n" "$COUNT_SKIPPED"
printf "  Failed  : %d\n" "$COUNT_FAILED"
if [[ ${#FAILED_LANGS[@]} -gt 0 ]]; then
  echo "  Failed langs:"
  for L in "${FAILED_LANGS[@]}"; do
    echo "    - $L"
  done
fi
echo "========================================"
