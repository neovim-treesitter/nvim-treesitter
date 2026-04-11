#!/usr/bin/env bash
# manage-query-repos.sh — manage per-language GitHub repos for nvim-treesitter queries
#
# Usage:
#   ./scripts/manage-query-repos.sh [SOURCE] ACTION <org> [lang ...]
#
# Source (controls where the language list comes from):
#   --registry   Fetch lang list from treesitter-parser-registry (default)
#   --bootstrap  Read lang list from parsers.lua via gen-parser-manifest.lua
#                (requires nvim; use when registry is not yet updated)
#
# Action (controls what is done):
#   --create            Create new repos. Skip repos that already exist and
#                       are populated.
#   --update            Full update: regenerate parser.json, sync query .scm
#                       files, sync highlight/injection tests, sync CI
#                       workflows. Requires nvim.
#   --update-workflows  Sync CI workflow files only (validate.yml + bump.yml).
#                       No manifest or query changes. Fast, no nvim required.
#
# Options:
#   --local-dir <path>  Mirror each repo into <path>/nvim-treesitter-queries-<lang>/.
#                       Clones if missing, pulls after push if already present.
#                       Only applies to --create and --update.
#
# Requires: gh (GitHub CLI, authenticated), git, jq
#           nvim is additionally required for --create and --update
# Run from the nvim-treesitter repo root.
#
# Token handling:
#   By default uses whatever GH_TOKEN / gh auth is active in your shell.
#   To use a separate token for org operations without overriding your default:
#
#     NVIM_TS_GH_TOKEN="github_pat_..." ./scripts/manage-query-repos.sh ...
#
#   Obtain an org-scoped token at github.com/settings/tokens (fine-grained,
#   resource owner: neovim-treesitter,
#   permissions: Contents+Administration+Workflows read/write).

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
SOURCE="registry"   # default
ACTION=""
LOCAL_DIR=""

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --registry)   SOURCE="registry";   shift ;;
    --bootstrap)  SOURCE="bootstrap";  shift ;;
    --create)              ACTION="create";             shift ;;
    --update)              ACTION="update";             shift ;;
    --update-workflows)    ACTION="update-workflows";   shift ;;
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

if [[ -z "$ACTION" ]]; then
  echo "Usage: $0 [--registry|--bootstrap] --create|--update|--update-workflows [--local-dir <path>] <org> [lang ...]" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--registry|--bootstrap] --create|--update|--update-workflows [--local-dir <path>] <org> [lang ...]" >&2
  exit 1
fi

ORG="$1"
shift
EXPLICIT_LANGS=("$@")

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
SELF_CONTAINED_TEMPLATE="$REPO_ROOT/scripts/templates/self-contained-validate.yml"
BUMP_TEMPLATE="$REPO_ROOT/scripts/templates/query-bump.yml"
README_TEMPLATE="$REPO_ROOT/scripts/templates/query-repo-README.md"

for _tpl in "$VALIDATE_TEMPLATE" "$SELF_CONTAINED_TEMPLATE" "$BUMP_TEMPLATE"; do
  if [[ ! -f "$_tpl" ]]; then
    echo "ERROR: template not found: $_tpl" >&2
    exit 1
  fi
done
if [[ "$ACTION" != "update-workflows" && ! -f "$README_TEMPLATE" ]]; then
  echo "ERROR: README template not found: $README_TEMPLATE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Registry setup (always fetched — needed for self_contained detection)
# ---------------------------------------------------------------------------
REGISTRY_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$REGISTRY_TMPDIR"' EXIT
REGISTRY_JSON="$REGISTRY_TMPDIR/registry.json"
echo "Fetching treesitter-parser-registry..."
gh api repos/neovim-treesitter/treesitter-parser-registry/contents/registry.json \
  --jq '.content' | base64 -d > "$REGISTRY_JSON"

registry_source_type() {
  jq -r --arg lang "$1" '.[$lang].source.type // "external_queries"' "$REGISTRY_JSON"
}

registry_queries_dir() {
  jq -r --arg lang "$1" '.[$lang].source.queries_dir // "queries"' "$REGISTRY_JSON"
}

# ---------------------------------------------------------------------------
# Language list discovery
# ---------------------------------------------------------------------------
LANGS=()

if [[ ${#EXPLICIT_LANGS[@]} -gt 0 ]]; then
  # Explicit list always wins regardless of source flag
  LANGS=("${EXPLICIT_LANGS[@]}")

elif [[ "$SOURCE" == "registry" ]]; then
  echo "Using registry as lang source..."
  while IFS= read -r lang; do
    LANGS+=("$lang")
  done < <(jq -r 'to_entries[] | select(.key != "$schema") | .key' "$REGISTRY_JSON" | sort)

else
  # bootstrap: read from parsers.lua via directory listing (nvim not needed just for list)
  echo "Using parsers.lua (runtime/queries dirs) as lang source..."
  while IFS= read -r _lang; do
    LANGS+=("$_lang")
  done < <(find "$QUERIES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
fi

EFFECTIVE_SOURCE="${SOURCE}"
echo "Processing ${#LANGS[@]} languages (lang-source: ${EFFECTIVE_SOURCE}, action: ${ACTION})..."
echo ""

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
COUNT_OK=0
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
    git -C "$LOCAL_REPO" pull --ff-only 2>/dev/null \
      || git -C "$LOCAL_REPO" reset --hard origin/main 2>/dev/null || true
  else
    echo "    local: cloning into ${LOCAL_REPO}"
    gh repo clone "${FULL_REPO}" "$LOCAL_REPO" -- --depth 1 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Shared: sync CI workflows into REPO_DIR for LANG
# Sets WF_CHANGED=true if any file changed (caller must declare local WF_CHANGED)
# ---------------------------------------------------------------------------
sync_workflows() {
  local LANG="$1"
  local REPO_DIR="$2"
  local SRC_TYPE
  SRC_TYPE="$(registry_source_type "$LANG")"

  mkdir -p "${REPO_DIR}/.github/workflows"

  if [[ "$SRC_TYPE" == "self_contained" ]]; then
    # Parser + queries live in one repo: self-contained-validate only, no bump
    local QUERIES_DIR_IN_REPO
    QUERIES_DIR_IN_REPO="$(registry_queries_dir "$LANG")"
    local SC_RENDERED="$REGISTRY_TMPDIR/sc-validate-${LANG}.yml"
    sed "s/{{LANG}}/${LANG}/g; s|{{QUERIES_DIR}}|${QUERIES_DIR_IN_REPO}|g" \
      "$SELF_CONTAINED_TEMPLATE" > "$SC_RENDERED"
    if ! cmp -s "$SC_RENDERED" "${REPO_DIR}/.github/workflows/validate.yml" 2>/dev/null; then
      cp "$SC_RENDERED" "${REPO_DIR}/.github/workflows/validate.yml"
      WF_CHANGED=true
    fi
    if [[ -f "${REPO_DIR}/.github/workflows/bump.yml" ]]; then
      rm "${REPO_DIR}/.github/workflows/bump.yml"
      WF_CHANGED=true
    fi
  else
    if ! cmp -s "$VALIDATE_TEMPLATE" "${REPO_DIR}/.github/workflows/validate.yml" 2>/dev/null; then
      cp "$VALIDATE_TEMPLATE" "${REPO_DIR}/.github/workflows/validate.yml"
      WF_CHANGED=true
    fi
    if ! cmp -s "$BUMP_TEMPLATE" "${REPO_DIR}/.github/workflows/bump.yml" 2>/dev/null; then
      cp "$BUMP_TEMPLATE" "${REPO_DIR}/.github/workflows/bump.yml"
      WF_CHANGED=true
    fi
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

  local TMPDIR
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' RETURN
  local REPO_DIR="${TMPDIR}/repo"

  # ── UPDATE-WORKFLOWS MODE ─────────────────────────────────────────────────
  if [[ "$ACTION" == "update-workflows" ]]; then
    if ! gh repo view "${FULL_REPO}" --json name >/dev/null 2>&1; then
      echo "    skip: ${FULL_REPO} does not exist"
      return 2
    fi

    gh repo clone "${FULL_REPO}" "$REPO_DIR" -- --depth 1 2>/dev/null

    local WF_CHANGED=false
    sync_workflows "$LANG" "$REPO_DIR"

    if [[ "$WF_CHANGED" == false ]]; then
      echo "    skip: workflows already up to date"
      return 2
    fi

    git -C "$REPO_DIR" add -A
    git -C "$REPO_DIR" commit -m "ci: sync workflows from nvim-treesitter templates"
    git -C "$REPO_DIR" push
    echo "    pushed: https://github.com/${FULL_REPO}"
    return 0
  fi

  # ── UPDATE MODE ───────────────────────────────────────────────────────────
  if [[ "$ACTION" == "update" ]]; then
    if ! gh repo view "${FULL_REPO}" --json name >/dev/null 2>&1; then
      echo "    skip: ${FULL_REPO} does not exist (use --create to create)"
      return 2
    fi

    gh repo clone "${FULL_REPO}" "$REPO_DIR" -- --depth 1 2>/dev/null
    local CHANGED=false

    # 1. Regenerate parser.json
    local NEW_MANIFEST
    NEW_MANIFEST="$(mktemp)"
    local MERGE_ARG=""
    [[ -f "${REPO_DIR}/parser.json" ]] && MERGE_ARG="${REPO_DIR}/parser.json"
    if ! nvim --headless -l "${REPO_ROOT}/scripts/gen-parser-manifest.lua" "${LANG}" \
         ${MERGE_ARG:+"$MERGE_ARG"} > "$NEW_MANIFEST" 2>/dev/null; then
      echo "    WARN: gen-parser-manifest.lua failed for ${LANG} — skipping"
      return 3
    fi
    if ! cmp -s "$NEW_MANIFEST" "${REPO_DIR}/parser.json" 2>/dev/null; then
      cp "$NEW_MANIFEST" "${REPO_DIR}/parser.json"
      CHANGED=true
      echo "    updated: parser.json"
    fi
    if jq -e '.queries_only == true and (.host_parser == null or .host_parser == {})' \
         "${REPO_DIR}/parser.json" >/dev/null 2>&1; then
      echo "    WARN: ${LANG} is queries_only but has no host_parser"
    fi

    # 2. Copy query files
    if [[ -d "$LANG_QUERIES_DIR" ]]; then
      mkdir -p "${REPO_DIR}/queries"
      local SCM_FILES=()
      while IFS= read -r _f; do SCM_FILES+=("$_f"); done \
        < <(find "$LANG_QUERIES_DIR" -maxdepth 1 -name '*.scm' 2>/dev/null)
      if [[ ${#SCM_FILES[@]} -gt 0 ]]; then
        cp "${SCM_FILES[@]}" "${REPO_DIR}/queries/"
        echo "    synced ${#SCM_FILES[@]} query file(s)"
        CHANGED=true
      fi
    fi

    # 3. Copy highlight tests
    local HL_SRC="${REPO_ROOT}/tests/query/highlights/${LANG}"
    if [[ -d "$HL_SRC" ]]; then
      mkdir -p "${REPO_DIR}/tests/highlights"
      cp "$HL_SRC"/* "${REPO_DIR}/tests/highlights/" 2>/dev/null || true
      CHANGED=true
      echo "    copied highlight test file(s)"
    fi

    # 4. Copy injection tests
    local INJ_SRC="${REPO_ROOT}/tests/query/injections/${LANG}"
    if [[ -d "$INJ_SRC" ]]; then
      mkdir -p "${REPO_DIR}/tests/injections"
      cp "$INJ_SRC"/* "${REPO_DIR}/tests/injections/" 2>/dev/null || true
      CHANGED=true
      echo "    copied injection test file(s)"
    fi

    # 5. Sync workflows
    local WF_CHANGED=false
    sync_workflows "$LANG" "$REPO_DIR"
    [[ "$WF_CHANGED" == true ]] && { CHANGED=true; echo "    synced CI workflows"; }

    # 6. Commit and push
    git -C "$REPO_DIR" add -A
    if git -C "$REPO_DIR" diff --cached --quiet; then
      echo "    skip: nothing changed"
      mirror_to_local "${FULL_REPO}" "${REPO_NAME}"
      return 2
    fi
    git -C "$REPO_DIR" commit -m \
      "fix: update parser.json, queries, and tests from nvim-treesitter"
    git -C "$REPO_DIR" push
    echo "    pushed: https://github.com/${FULL_REPO}"
    mirror_to_local "${FULL_REPO}" "${REPO_NAME}"
    return 0
  fi

  # ── CREATE MODE ───────────────────────────────────────────────────────────
  local _repo_json
  if ! _repo_json="$(gh repo view "${FULL_REPO}" --json isEmpty 2>/dev/null)"; then
    echo "    creating repo: ${FULL_REPO}"
    gh repo create "${FULL_REPO}" \
      --public \
      --description "Neovim tree-sitter queries for ${LANG}"
  elif [[ "$(echo "$_repo_json" | jq -r '.isEmpty')" == "false" ]]; then
    echo "    skip: ${FULL_REPO} already populated"
    return 2
  else
    echo "    repo exists but is empty — will push content"
  fi

  git clone "https://github.com/${FULL_REPO}.git" "$REPO_DIR"

  # 1. Copy query files
  mkdir -p "${REPO_DIR}/queries"
  local SCM_FILES=()
  if [[ -d "$LANG_QUERIES_DIR" ]]; then
    while IFS= read -r _f; do SCM_FILES+=("$_f"); done \
      < <(find "$LANG_QUERIES_DIR" -maxdepth 1 -name '*.scm' 2>/dev/null)
  fi
  if [[ ${#SCM_FILES[@]} -eq 0 ]]; then
    echo "    WARN: no .scm files found for ${LANG} — queries/ will be empty"
  else
    cp "${SCM_FILES[@]}" "${REPO_DIR}/queries/"
    echo "    copied ${#SCM_FILES[@]} query file(s)"
  fi

  # 2. Generate parser.json
  echo "    generating parser.json"
  if ! nvim --headless -l "${REPO_ROOT}/scripts/gen-parser-manifest.lua" "${LANG}" \
       > "${REPO_DIR}/parser.json" 2>/dev/null; then
    echo "    WARN: gen-parser-manifest.lua failed for ${LANG}"
    echo '{}' > "${REPO_DIR}/parser.json"
  fi
  if jq -e '.queries_only == true and (.host_parser == null or .host_parser == {})' \
       "${REPO_DIR}/parser.json" >/dev/null 2>&1; then
    echo "    WARN: ${LANG} is queries_only but has no host_parser"
  fi

  # 3. CI workflows
  local WF_CHANGED=false
  sync_workflows "$LANG" "$REPO_DIR"

  # 4. README
  sed "s/{{LANG}}/${LANG}/g" "${README_TEMPLATE}" > "${REPO_DIR}/README.md"

  # 5. CODEOWNERS
  cat > "${REPO_DIR}/CODEOWNERS" <<'CODEOWNERS'
# CODEOWNERS
# Add yourself here to claim maintainership
# * @your-github-username
CODEOWNERS

  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -m "feat: initial extraction from nvim-treesitter"
  git -C "$REPO_DIR" tag v0.1.0
  git -C "$REPO_DIR" push --follow-tags

  echo "    done: https://github.com/${FULL_REPO}"
  mirror_to_local "${FULL_REPO}" "${REPO_NAME}"
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
    0)   (( COUNT_OK++ ))      || true ;;
    2)   (( COUNT_SKIPPED++ )) || true ;;
    *)
      echo "    FAILED: ${LANG} (exit ${EXIT_CODE})"
      (( COUNT_FAILED++ )) || true
      FAILED_LANGS+=("$LANG")
      ;;
  esac

  sleep 1
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Summary (source: ${SOURCE}, action: ${ACTION})"
echo "========================================"
case "$ACTION" in
  create)            printf "  Created : %d\n" "$COUNT_OK" ;;
  update)            printf "  Updated : %d\n" "$COUNT_OK" ;;
  update-workflows)  printf "  Updated : %d\n" "$COUNT_OK" ;;
esac
printf "  Skipped : %d\n" "$COUNT_SKIPPED"
printf "  Failed  : %d\n" "$COUNT_FAILED"
if [[ ${#FAILED_LANGS[@]} -gt 0 ]]; then
  echo "  Failed langs:"
  for L in "${FAILED_LANGS[@]}"; do
    echo "    - $L"
  done
fi
echo "========================================"
