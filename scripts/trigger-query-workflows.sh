#!/usr/bin/env bash
# trigger-query-workflows.sh — trigger validate workflows on all query repos
#
# Usage:
#   ./scripts/trigger-query-workflows.sh [--workflow validate|bump] [--dry-run] <org> [lang ...]
#
# Triggers the workflow_dispatch event on each nvim-treesitter-queries-<lang>
# repo under <org>.  Defaults to the "validate.yml" workflow.
#
# Options:
#   --workflow <name>   Which workflow to trigger: "validate" (default) or "bump"
#   --dry-run           Print what would be triggered without actually doing it
#   --max-concurrent N  Maximum concurrent dispatches (default: 10)
#
# If specific languages are given, only those repos are triggered.
# Otherwise all repos matching nvim-treesitter-queries-* under the org are triggered.
#
# Requires: gh (GitHub CLI, authenticated)
#
# Token handling:
#   Uses whatever GH_TOKEN / gh auth is active in your shell.
#   To use a separate token:
#     NVIM_TS_GH_TOKEN="github_pat_..." ./scripts/trigger-query-workflows.sh neovim-treesitter

set -euo pipefail

workflow="validate.yml"
dry_run=false
max_concurrent=10
org=""
langs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow)
      shift
      case "$1" in
        validate) workflow="validate.yml" ;;
        bump)     workflow="bump.yml" ;;
        *)        echo "Unknown workflow: $1 (expected validate or bump)" >&2; exit 1 ;;
      esac
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --max-concurrent)
      shift
      max_concurrent="$1"
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2; exit 1
      ;;
    *)
      if [[ -z "$org" ]]; then
        org="$1"
      else
        langs+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ -z "$org" ]]; then
  echo "Usage: $0 [--workflow validate|bump] [--dry-run] <org> [lang ...]" >&2
  exit 1
fi

# If a separate token was provided, export it for gh
if [[ -n "${NVIM_TS_GH_TOKEN:-}" ]]; then
  export GH_TOKEN="$NVIM_TS_GH_TOKEN"
fi

# Build list of repos to trigger
repos=()
if [[ ${#langs[@]} -gt 0 ]]; then
  for lang in "${langs[@]}"; do
    repos+=("$org/nvim-treesitter-queries-$lang")
  done
else
  echo "Discovering query repos under $org..."
  while IFS= read -r repo; do
    repos+=("$repo")
  done < <(gh repo list "$org" --limit 500 --json nameWithOwner,name \
    --jq '.[] | select(.name | startswith("nvim-treesitter-queries-")) | .nameWithOwner')
fi

total=${#repos[@]}
echo "Found $total query repos. Triggering $workflow..."

triggered=0
failed=0
skipped=0
active=0

for repo in "${repos[@]}"; do
  lang="${repo##*-queries-}"

  if $dry_run; then
    echo "[dry-run] Would trigger $workflow on $repo"
    ((triggered++))
    continue
  fi

  # Throttle concurrent dispatches
  if (( active >= max_concurrent )); then
    wait -n 2>/dev/null || true
    ((active--))
  fi

  (
    if gh workflow run "$workflow" --repo "$repo" --ref main 2>/dev/null; then
      echo "[ok]   $lang"
    else
      echo "[FAIL] $lang — could not trigger $workflow" >&2
    fi
  ) &
  ((active++))
  ((triggered++))
done

# Wait for all background jobs
wait

echo ""
echo "Done. Triggered $workflow on $triggered/$total repos."
if $dry_run; then
  echo "(dry-run mode — nothing was actually dispatched)"
fi
