#!/usr/bin/env bash
# create-query-repos.sh — extract nvim-treesitter query files into per-language GitHub repos
#
# Usage:
#   ./scripts/create-query-repos.sh [--update] [--local-dir <path>] <org> [lang ...]
#
# Modes:
#   (default)  Create new repos only. Skip repos that already exist and are populated.
#   --update   Update existing repos: regenerate parser.json, sync query .scm files,
#              sync highlight/injection tests, and sync CI workflows. Commits and pushes
#              if anything changed. Does not recreate repos or overwrite README/CODEOWNERS.
#
# Options:
#   --local-dir <path>   Mirror each repo into <path>/nvim-treesitter-queries-<lang>/.
#                        Clones if missing, pulls after push if already present.
#                        Default: none (GH-only).
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
UPDATE_MODE=false
LOCAL_DIR=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --update)
      UPDATE_MODE=true
      shift
      ;;
    --local-dir)
      shift
      LOCAL_DIR="${1:?--local-dir requires a path argument}"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--update] [--local-dir <path>] <org> [lang ...]" >&2
  exit 1
fi

ORG="$1"
shift

# Resolve LOCAL_DIR to absolute path
if [[ -n "$LOCAL_DIR" ]]; then
  mkdir -p "$LOCAL_DIR"
  LOCAL_DIR="$(cd "$LOCAL_DIR" && pwd)"
fi

# Use org-specific token if provided, without affecting the caller's GH_TOKEN
if [[ -n "${NVIM_TS_GH_TOKEN:-}" ]]; then
  export GH_TOKEN="$NVIM_TS_GH_TOKEN"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUERIES_DIR="$REPO_ROOT/runtime/queries"
VALIDATE_TEMPLATE="$REPO_ROOT/scripts/templates/query-validate.yml"
BUMP_TEMPLATE="$REPO_ROOT/scripts/templates/query-bump.yml"
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
# Local mirror helper
# ---------------------------------------------------------------------------
mirror_to_local() {
  local FULL_REPO="$1"
  local REPO_NAME="$2"
  [[ -z "$LOCAL_DIR" ]] && return 0
  local LOCAL_REPO="${LOCAL_DIR}/${REPO_NAME}"
  if [[ -d "${LOCAL_REPO}/.git" ]]; then
    echo "    local: pulling ${LOCAL_REPO}"
    git -C "$LOCAL_REPO" pull --ff-only 2>/dev/null || git -C "$LOCAL_REPO" reset --hard origin/main 2>/dev/null || true
  else
    echo "    local: cloning into ${LOCAL_REPO}"
    gh repo clone "${FULL_REPO}" "$LOCAL_REPO" -- --depth 1 2>/dev/null
  fi
}

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
  trap 'rm -rf "$TMPDIR"' RETURN

  # ── UPDATE MODE ──────────────────────────────────────────────────────────
  if [[ "$UPDATE_MODE" == true ]]; then
    # Repo must already exist and be populated
    if ! gh repo view "${FULL_REPO}" --json name >/dev/null 2>&1; then
      echo "    skip: ${FULL_REPO} does not exist (run without --update to create)"
      return 2
    fi

    gh repo clone "${FULL_REPO}" "${TMPDIR}/repo" -- --depth 1 2>/dev/null
    local REPO_DIR="${TMPDIR}/repo"
    local CHANGED=false

    # ── 1. Regenerate parser.json ──
    # Merges with existing to preserve manually-set fields like `inherits`.
    # gen-parser-manifest.lua strips vestigial min_version/max_version.
    local NEW_MANIFEST
    NEW_MANIFEST="$(mktemp)"
    local EXISTING_MANIFEST="${REPO_DIR}/parser.json"
    local MERGE_ARG=""
    if [[ -f "$EXISTING_MANIFEST" ]]; then
      MERGE_ARG="$EXISTING_MANIFEST"
    fi
    if ! nvim --headless -l "${REPO_ROOT}/scripts/gen-parser-manifest.lua" "${LANG}" ${MERGE_ARG:+"$MERGE_ARG"} \
         > "$NEW_MANIFEST" 2>/dev/null; then
      echo "    WARN: gen-parser-manifest.lua failed for ${LANG} — skipping"
      return 3
    fi

    if ! cmp -s "$NEW_MANIFEST" "${REPO_DIR}/parser.json" 2>/dev/null; then
      cp "$NEW_MANIFEST" "${REPO_DIR}/parser.json"
      CHANGED=true
      echo "    updated: parser.json"
    fi

    # ── 2. Copy query files ──
    if [[ -d "$LANG_QUERIES_DIR" ]]; then
      mkdir -p "${REPO_DIR}/queries"
      local SCM_FILES=()
      while IFS= read -r _f; do SCM_FILES+=("$_f"); done < <(find "$LANG_QUERIES_DIR" -maxdepth 1 -name '*.scm' 2>/dev/null)
      if [[ ${#SCM_FILES[@]} -gt 0 ]]; then
        cp "${SCM_FILES[@]}" "${REPO_DIR}/queries/"
        echo "    synced ${#SCM_FILES[@]} query file(s)"
        CHANGED=true
      fi
    fi

    # ── 3. Copy highlight tests ──
    local HL_SRC="${REPO_ROOT}/tests/query/highlights/${LANG}"
    if [[ -d "$HL_SRC" ]]; then
      mkdir -p "${REPO_DIR}/tests/highlights"
      cp "$HL_SRC"/* "${REPO_DIR}/tests/highlights/" 2>/dev/null || true
      local HL_COUNT
      HL_COUNT=$(find "${REPO_DIR}/tests/highlights" -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "    copied ${HL_COUNT} highlight test file(s)"
      CHANGED=true
    fi

    # ── 4. Copy injection tests ──
    local INJ_SRC="${REPO_ROOT}/tests/query/injections/${LANG}"
    if [[ -d "$INJ_SRC" ]]; then
      mkdir -p "${REPO_DIR}/tests/injections"
      cp "$INJ_SRC"/* "${REPO_DIR}/tests/injections/" 2>/dev/null || true
      local INJ_COUNT
      INJ_COUNT=$(find "${REPO_DIR}/tests/injections" -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "    copied ${INJ_COUNT} injection test file(s)"
      CHANGED=true
    fi

    # ── 5. Sync CI workflows ──
    mkdir -p "${REPO_DIR}/.github/workflows"
    local WF_CHANGED=false
    if [[ -f "$VALIDATE_TEMPLATE" ]]; then
      if ! cmp -s "$VALIDATE_TEMPLATE" "${REPO_DIR}/.github/workflows/validate.yml" 2>/dev/null; then
        cp "$VALIDATE_TEMPLATE" "${REPO_DIR}/.github/workflows/validate.yml"
        WF_CHANGED=true
      fi
    fi
    if [[ -f "$BUMP_TEMPLATE" ]]; then
      if ! cmp -s "$BUMP_TEMPLATE" "${REPO_DIR}/.github/workflows/bump.yml" 2>/dev/null; then
        cp "$BUMP_TEMPLATE" "${REPO_DIR}/.github/workflows/bump.yml"
        WF_CHANGED=true
      fi
    fi
    if [[ "$WF_CHANGED" == true ]]; then
      CHANGED=true
      echo "    synced CI workflows"
    fi

    # ── 6. Commit and push if anything changed ──
    git -C "${REPO_DIR}" add -A
    if git -C "${REPO_DIR}" diff --cached --quiet; then
      echo "    skip: nothing changed"
      mirror_to_local "${FULL_REPO}" "${REPO_NAME}"
      return 2
    fi
    git -C "${REPO_DIR}" commit -m \
      "fix: update parser.json, queries, and tests from nvim-treesitter"
    git -C "${REPO_DIR}" push
    echo "    pushed: https://github.com/${FULL_REPO}"
    mirror_to_local "${FULL_REPO}" "${REPO_NAME}"
    return 0
  fi

  # ── CREATE MODE ──────────────────────────────────────────────────────────

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
  cp "${BUMP_TEMPLATE}" "${REPO_DIR}/.github/workflows/bump.yml"

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

  echo "    done: https://github.com/${FULL_REPO}"
  mirror_to_local "${FULL_REPO}" "${REPO_NAME}"
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
echo "Summary${UPDATE_MODE:+ (--update mode)}"
echo "========================================"
if [[ "$UPDATE_MODE" == true ]]; then
  printf "  Updated : %d\n" "$COUNT_CREATED"
  printf "  Skipped : %d (unchanged or missing)\n" "$COUNT_SKIPPED"
else
  printf "  Created : %d\n" "$COUNT_CREATED"
  printf "  Skipped : %d (already exist)\n" "$COUNT_SKIPPED"
fi
printf "  Failed  : %d\n" "$COUNT_FAILED"
if [[ ${#FAILED_LANGS[@]} -gt 0 ]]; then
  echo "  Failed langs:"
  for L in "${FAILED_LANGS[@]}"; do
    echo "    - $L"
  done
fi
echo "========================================"
