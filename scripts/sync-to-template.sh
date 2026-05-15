#!/usr/bin/env bash
# Sync canonical content from this live Trellis clone to the public Trellis mirror.
#
# Reads trellis.config.json for paths.
# Substitutes user-specific values back to placeholders so the template
# remains shareable.
#
# Default mode: --dry-run (show diff, don't write).
# To actually write: --apply
# To commit + push: --push (requires gh CLI access to the template remote).
#
# Usage:
#   sync-to-template.sh                         # dry-run
#   sync-to-template.sh --apply                 # write to template working tree
#   sync-to-template.sh --apply --push          # also commit + push

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/sed-portable.sh
. "$SCRIPT_DIR/lib/sed-portable.sh"

# --- Args ------------------------------------------------------------------
APPLY=false
PUSH=false
TEMPLATE_DIR="${TRELLIS_TEMPLATE_DIR:-$USER_HOME/projects/trellis}"

for arg in "$@"; do
  case "$arg" in
    --apply)        APPLY=true ;;
    --push)         APPLY=true; PUSH=true ;;
    --template-dir=*) TEMPLATE_DIR="${arg#--template-dir=}" ;;
    --dry-run)      APPLY=false; PUSH=false ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

[ -e "$TEMPLATE_DIR/.git" ] || {
  echo "template repo not found at $TEMPLATE_DIR" >&2
  echo "set TRELLIS_TEMPLATE_DIR or pass --template-dir=<path>" >&2
  exit 1
}

# Files / dirs to sync from live → template
SYNC_PATHS=(
  "engineering-process.md"
  "AGENT_ONBOARD_PROJECT.md"
  "core-rules/CLAUDE.md"
  "core-rules/AGENTS.md"
  "core-rules/codex/"
  "core-rules/hooks.md"
  "core-rules/inheritance.md"
  "core-rules/deferred.md"
  "core-rules/hooks/"
  "core-rules/husky/"
  "core-rules/skills/"
  "core-rules/commands/"
  "core-rules/templates/"
  "docs/primers/"
  "scheduled-tasks/"
  "scripts/"
  "trellis.config.json"
)

# Files NEVER synced (private / instance-specific) — informational; the
# actual exclusion is implemented via SYNC_PATHS being a positive allowlist.
# shellcheck disable=SC2034  # documents intent; not consumed
NEVER_SYNC=(
  "registry.md"
  "blacklist.md"
  "audits/"
)

# Placeholder substitutions: live values → template placeholders
declare -a SUB_FROM=("$TRELLIS_ROOT" "$SOURCE_ROOT" "$PROJECTS_ROOT" "$USER_HOME" "$MAINTAINER_NAME" "$GITHUB_USER")
declare -a SUB_TO=("__TRELLIS_PATH__" "__TRELLIS_PATH__" "__PROJECTS_ROOT__" "__USER_HOME__" "__MAINTAINER_NAME__" "__GITHUB_USER__")

# --- Workspace -------------------------------------------------------------
TMP_STAGE="$(mktemp -d)"
trap 'rm -rf "$TMP_STAGE"' EXIT

echo "==> Staging in $TMP_STAGE"
for p in "${SYNC_PATHS[@]}"; do
  src="${SOURCE_ROOT}/${p%/}"
  if [ ! -e "$src" ]; then
    echo "skip (missing in live): $p"
    continue
  fi
  dst="${TMP_STAGE}/${p%/}"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    rsync -a --delete \
      --exclude='__pycache__/' --exclude='.DS_Store' --exclude='*.swp' \
      "${src}/" "${dst}/"
  else
    mkdir -p "$(dirname "$dst")"
    cp -P "$src" "$dst"
  fi
done

# Substitute placeholders in every text file we just staged
echo "==> Substituting placeholders"
find "$TMP_STAGE" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.toml' \) -print0 \
  | while IFS= read -r -d '' f; do
      for i in "${!SUB_FROM[@]}"; do
        from="${SUB_FROM[$i]}"
        to="${SUB_TO[$i]}"
        # Escape sed metacharacters in $from
        from_esc="$(printf '%s\n' "$from" | sed -e 's/[\/&]/\\&/g')"
        to_esc="$(printf '%s\n' "$to" | sed -e 's/[\/&]/\\&/g')"
        sed_inplace -e "s/$from_esc/$to_esc/g" "$f"
      done
    done

# Reset trellis.config.json to placeholder shape
if [ -f "$TMP_STAGE/trellis.config.json" ]; then
  cat > "$TMP_STAGE/trellis.config.json" <<'EOF'
{
  "$schema": "./scripts/lib/trellis.config.schema.json",
  "comment": "Edit this file after cloning. Replace placeholders with absolute paths and your details before invoking onboard-project.sh, sync-hooks.sh, sync-codex-hooks.sh, or sync-to-template.sh. Keep harnesses as [\"claude\"] for Claude-only installs; add \"codex\" when opting into Codex parity.",

  "trellis_root": "__TRELLIS_PATH__",
  "projects_root": "__PROJECTS_ROOT__",
  "user_home": "__USER_HOME__",

  "maintainer_name": "__MAINTAINER_NAME__",
  "github_user": "__GITHUB_USER__",

  "harnesses": ["claude"],

  "template": {
    "remote": "git@github.com:__GITHUB_USER__/trellis.git",
    "branch": "main",
    "redact_paths": [
      "audits/",
      "blacklist.md",
      "registry.md"
    ]
  },

  "sed_flavor": "auto"
}
EOF
fi

# Verify no live values leaked through
echo "==> Verifying no live values remain"
LEAK=0
for v in "${SUB_FROM[@]}"; do
  if grep -rq --binary-files=without-match "$v" "$TMP_STAGE" 2>/dev/null; then
    echo "  LEAK: '$v' still present in staged tree" >&2
    grep -rln "$v" "$TMP_STAGE" 2>/dev/null | head -5 | sed 's|^|    |'
    LEAK=1
  fi
done
[ "$LEAK" -eq 0 ] || { echo "redaction failed; aborting" >&2; exit 1; }
echo "  clean."

# --- Diff against template tree --------------------------------------------
echo "==> Diff vs $TEMPLATE_DIR"
DIFF_OUT="$(mktemp)"
{
  for p in "${SYNC_PATHS[@]}"; do
    src_stage="${TMP_STAGE}/${p%/}"
    dst_template="${TEMPLATE_DIR}/${p%/}"
    if [ -d "$src_stage" ] || [ -d "$dst_template" ]; then
      diff -urN --exclude='.git' "$dst_template" "$src_stage" 2>/dev/null || true
    elif [ -f "$src_stage" ] || [ -f "$dst_template" ]; then
      diff -uN "$dst_template" "$src_stage" 2>/dev/null || true
    fi
  done
} > "$DIFF_OUT"

if [ ! -s "$DIFF_OUT" ]; then
  echo "  no changes."
else
  echo "  $(wc -l <"$DIFF_OUT") diff lines"
  if ! $APPLY; then
    echo
    echo "===== DIFF (first 200 lines) ====="
    head -200 "$DIFF_OUT"
    echo "===== END DIFF ====="
    echo
    echo "Re-run with --apply to write to $TEMPLATE_DIR (no commit)."
    echo "Re-run with --apply --push to commit + push to template remote."
  fi
fi

# --- Apply -----------------------------------------------------------------
if $APPLY; then
  echo "==> Writing to $TEMPLATE_DIR"
  for p in "${SYNC_PATHS[@]}"; do
    src_stage="${TMP_STAGE}/${p%/}"
    dst_template="${TEMPLATE_DIR}/${p%/}"
    if [ ! -e "$src_stage" ]; then
      continue
    fi
    if [ -d "$src_stage" ]; then
      mkdir -p "$dst_template"
      rsync -a --delete "${src_stage}/" "${dst_template}/"
    else
      mkdir -p "$(dirname "$dst_template")"
      cp -P "$src_stage" "$dst_template"
    fi
  done
  echo "  applied."

  if $PUSH; then
    echo "==> Committing in template repo"
    cd "$TEMPLATE_DIR"
    git add -A
    if git diff --cached --quiet; then
      echo "  no staged changes — nothing to commit."
    else
      git status --short
      printf "Commit + push? [y/N] "
      read -r ans
      if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        git commit -m "chore: sync from live Trellis clone ($(date +%Y-%m-%d))"
        git push origin "$TEMPLATE_BRANCH"
      else
        echo "  aborted before commit."
      fi
    fi
  fi
fi

rm -f "$DIFF_OUT"
