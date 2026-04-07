#!/usr/bin/env bash
# create-query-repos.sh — extract nvim-treesitter query files into per-language GitHub repos
#
# Usage: ./scripts/create-query-repos.sh <org> [lang ...]
#
# Requires: gh (GitHub CLI, authenticated), git, nvim, jq
# Run from the nvim-treesitter repo root.
#
# Token handling:
#   By default uses whatever GH_TOKEN / gh auth is active in your shell.
#   To use a separate token for org operations without overriding your default:
#
#     NVIM_TS_GH_TOKEN="github_pat_..." ./scripts/create-query-repos.sh neovim-treesitter
#
#   Obtain an org-scoped token at github.com/settings/tokens (fine-grained,
#   resource owner: neovim-treesitter, permissions: Contents+Administration+Workflows read/write).

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <org> [lang ...]" >&2
  exit 1
fi

ORG="$1"
shift

# Use org-specific token if provided, without affecting the caller's GH_TOKEN
if [[ -n "${NVIM_TS_GH_TOKEN:-}" ]]; then
  export GH_TOKEN="$NVIM_TS_GH_TOKEN"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUERIES_DIR="$REPO_ROOT/runtime/queries"
VALIDATE_TEMPLATE="$REPO_ROOT/scripts/templates/query-validate.yml"
README_TEMPLATE="$REPO_ROOT/scripts/templates/query-repo-README.md"

# If no langs provided, discover all dirs under runtime/queries/
if [[ $# -eq 0 ]]; then
  LANGS=()
  while IFS= read -r _lang; do LANGS+=("$_lang"); done < <(find "$QUERIES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
else
  LANGS=("$@")
fi

if [[ ! -f "$VALIDATE_TEMPLATE" ]]; then
  echo "ERROR: validate.yml template not found at $VALIDATE_TEMPLATE" >&2
  echo "       Expected: scripts/templates/query-validate.yml" >&2
  exit 1
fi

if [[ ! -f "$README_TEMPLATE" ]]; then
  echo "ERROR: README template not found at $README_TEMPLATE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
COUNT_CREATED=0
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
  local LANG_QUERIES_DIR="${QUERIES_DIR}/${LANG}"

  echo ""
  echo "==> Processing: ${LANG}"

  # Working directory
  local TMPDIR
  TMPDIR="$(mktemp -d)"
  # Ensure cleanup on any exit from this function
  trap 'rm -rf "$TMPDIR"' RETURN

  # 1. Check repo state: populated → skip, empty → reuse, missing → create
  local _repo_json
  if ! _repo_json="$(gh repo view "${FULL_REPO}" --json isEmpty 2>/dev/null)"; then
    # Repo does not exist — create it
    echo "    creating repo: ${FULL_REPO}"
    gh repo create "${FULL_REPO}" \
      --public \
      --description "Neovim tree-sitter queries for ${LANG}"
  elif [[ "$(echo "$_repo_json" | jq -r '.isEmpty')" == "false" ]]; then
    echo "    skip: ${FULL_REPO} already populated"
    return 2  # sentinel for "skipped"
  else
    echo "    repo exists but is empty — will push content"
  fi

  # 2. Clone into tmpdir (works for both empty and newly created repos)
  git clone "https://github.com/${FULL_REPO}.git" "${TMPDIR}/repo"
  local REPO_DIR="${TMPDIR}/repo"

  # 3. Copy query files
  mkdir -p "${REPO_DIR}/queries"
  local SCM_FILES=()
  if [[ -d "$LANG_QUERIES_DIR" ]]; then
    while IFS= read -r _f; do SCM_FILES+=("$_f"); done < <(find "$LANG_QUERIES_DIR" -maxdepth 1 -name '*.scm' 2>/dev/null)
  fi

  if [[ ${#SCM_FILES[@]} -eq 0 ]]; then
    echo "    WARN: no .scm files found for ${LANG} — queries/ will be empty"
  else
    cp "${SCM_FILES[@]}" "${REPO_DIR}/queries/"
    echo "    copied ${#SCM_FILES[@]} query file(s)"
  fi

  # 4. Generate parser.json
  echo "    generating parser.json"
  if ! nvim --headless -l "${REPO_ROOT}/scripts/gen-parser-manifest.lua" "${LANG}" \
       > "${REPO_DIR}/parser.json" 2>/dev/null; then
    echo "    WARN: gen-parser-manifest.lua failed for ${LANG} — parser.json may be empty"
    # Write a minimal fallback so CI doesn't hard-fail
    echo '{}' > "${REPO_DIR}/parser.json"
  fi

  # 5. CI workflow
  mkdir -p "${REPO_DIR}/.github/workflows"
  cp "${VALIDATE_TEMPLATE}" "${REPO_DIR}/.github/workflows/validate.yml"

  # 6. README
  sed "s/{{LANG}}/${LANG}/g" "${README_TEMPLATE}" > "${REPO_DIR}/README.md"

  # 7. CODEOWNERS
  cat > "${REPO_DIR}/CODEOWNERS" <<'CODEOWNERS'
# CODEOWNERS
# Add yourself here to claim maintainership
# * @your-github-username
CODEOWNERS

  # 8-11. Commit, tag, push
  git -C "${REPO_DIR}" add -A
  git -C "${REPO_DIR}" commit -m "feat: initial extraction from nvim-treesitter"
  git -C "${REPO_DIR}" tag v0.1.0
  git -C "${REPO_DIR}" push --follow-tags

  # 12. Cleanup handled by trap RETURN

  echo "    done: https://github.com/${FULL_REPO}"
  return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
for LANG in "${LANGS[@]}"; do
  # Disable errexit inside the subshell so one failure doesn't kill the script
  set +e
  (
    set -e
    process_lang "$LANG"
  )
  EXIT_CODE=$?
  set -e

  case $EXIT_CODE in
    0)
      (( COUNT_CREATED++ )) || true
      ;;
    2)
      (( COUNT_SKIPPED++ )) || true
      ;;
    *)
      echo "    FAILED: ${LANG} (exit ${EXIT_CODE})"
      (( COUNT_FAILED++ )) || true
      FAILED_LANGS+=("$LANG")
      ;;
  esac

  # Rate-limit: be kind to the GitHub API
  sleep 1
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Summary"
echo "========================================"
printf "  Created : %d\n" "$COUNT_CREATED"
printf "  Skipped : %d (already exist)\n" "$COUNT_SKIPPED"
printf "  Failed  : %d\n" "$COUNT_FAILED"
if [[ ${#FAILED_LANGS[@]} -gt 0 ]]; then
  echo "  Failed langs:"
  for L in "${FAILED_LANGS[@]}"; do
    echo "    - $L"
  done
fi
echo "========================================"
