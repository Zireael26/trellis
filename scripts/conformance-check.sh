#!/usr/bin/env bash
# conformance-check.sh — verify that file paths cited by Trellis spec docs
# actually exist in the repo. Plan task P3.6 (audit §3.10 / doc-drift table).
#
# Scope (intentionally narrow for the first cut):
#   - inline-code refs of the form `path/to/file` where path/to looks like
#     an Trellis directory we control (core-rules/, scheduled-tasks/, scripts/,
#     docs/, audits/, .claude/, .github/, recon.md, engineering-process.md).
#   - emits one finding per missing reference: source doc, line, broken ref.
#   - exits non-zero if any miss is found.
#
# Out of scope (deferred to follow-up):
#   - env-var existence (would need bash AST or shellcheck-style parsing)
#   - function-name existence (same)
#   - cross-doc URL refs
#
# Usage:
#   scripts/conformance-check.sh [--quiet]
#
# Designed to be cheap (~1s) so it can run on every PR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true

# Spec docs to scan (prioritized to the audit's named set).
SPEC_DOCS=(
  "$ROOT/core-rules/CLAUDE.md"
  "$ROOT/core-rules/hooks.md"
  "$ROOT/core-rules/inheritance.md"
  "$ROOT/core-rules/skills/process-gate/SKILL.md"
  "$ROOT/engineering-process.md"
  "$ROOT/recon.md"
  "$ROOT/registry.md"
  "$ROOT/scheduled-tasks/README.md"
  "$ROOT/docs/UPGRADING.md"
  "$ROOT/core-rules/commands/doctor.md"
  "$ROOT/scheduled-tasks/cross-project-process-audit/prompt.md"
)

# Add references/*.md under process-gate
while IFS= read -r f; do SPEC_DOCS+=("$f"); done < <(find "$ROOT/core-rules/skills/process-gate/references" -name '*.md' -type f 2>/dev/null)

# Roots we consider "ours" — refs starting with these are repo-rooted and
# should resolve to a real file at the repo root. Project-relative paths
# (.claude/, .codex/, .husky/, .agents/, AGENTS.md, gotchas.md,
# context-log.md, project-side CLAUDE.md) are NOT in this set — they live
# inside registered projects, not at the Trellis canonical root.
PREFIXES=(
  "core-rules/"
  "scheduled-tasks/"
  "scripts/"
  "docs/"
  "audits/"
  ".github/"
)

# Single-file refs (not directory-prefixed) — repo-root files only.
SINGLE_FILES=(
  "recon.md"
  "engineering-process.md"
  "registry.md"
  "blacklist.md"
  "CHANGELOG.md"
  "trellis.config.json"
  "security-gate-plan.md"
)

is_ours() {
  local path="$1"
  for p in "${PREFIXES[@]}"; do
    case "$path" in "$p"*) return 0 ;; esac
  done
  for f in "${SINGLE_FILES[@]}"; do
    [ "$path" = "$f" ] && return 0
  done
  return 1
}

# Strip a path of trailing markdown punctuation, line-numbers, anchors,
# fragments. Returns the bare path.
clean_path() {
  local p="$1"
  # Drop trailing :NN line refs (most common)
  p="${p%%:[0-9]*}"
  # Drop trailing anchors
  p="${p%%#*}"
  # Drop wildcards (we don't try to glob-resolve)
  case "$p" in
    *\**) return 1 ;;
  esac
  # Drop trailing punctuation
  p="${p%%[],.;:]}"
  printf '%s' "$p"
}

miss_count=0
ref_count=0
checked_files=0

for doc in "${SPEC_DOCS[@]}"; do
  [ -f "$doc" ] || continue
  checked_files=$((checked_files + 1))
  rel_doc="${doc#"$ROOT"/}"

  # Extract `inline-code` spans, one per line. Match content between
  # backticks. Then for each, decide if it's a path we want to check.
  while IFS= read -r line; do
    line_num="${line%%:*}"
    line_body="${line#*:}"
    # Find all `...` spans on this line. Use a portable awk loop.
    spans_tmp=$(mktemp)
    printf '%s' "$line_body" | awk '
      {
        n = length($0); i = 1
        while (i <= n) {
          a = index(substr($0, i), "`")
          if (a == 0) break
          a += i - 1
          rest = substr($0, a+1)
          b = index(rest, "`")
          if (b == 0) break
          span = substr($0, a+1, b-1)
          print span
          i = a + b + 1
        }
      }
    ' > "$spans_tmp"
    while IFS= read -r span; do
      # Strip leading `__TRELLIS_PATH__/` if present
      span="${span#__TRELLIS_PATH__/}"
      span="${span#./}"
      # Skip if not ours
      is_ours "$span" || continue
      # Clean path
      cleaned=$(clean_path "$span") || continue
      [ -z "$cleaned" ] && continue
      # Skip pure command lines (contain spaces) — only file paths
      case "$cleaned" in *\ *) continue ;; esac
      # Skip obvious commands like `npx eslint`
      case "$cleaned" in
        */) continue ;;  # trailing slash patterns are often globs
      esac
      # Skip template patterns (NNNN, YYYY-MM-DD, <name>, etc.)
      case "$cleaned" in
        *\<*|*\>*|*NNNN*|*YYYY*|*XXXX*) continue ;;
      esac
      # Allowlisted: refs that genuinely describe project-local paths
      # (not Trellis canonical repo-root paths). Add here when a spec doc legitimately
      # cites a path that exists only inside a registered project.
      case "$rel_doc:$cleaned" in
        "core-rules/skills/process-gate/references/docs.md:docs/EPM.md") continue ;;
      esac
      ref_count=$((ref_count + 1))
      # Try repo-root resolution first; fall back to doc-relative for
      # skill-internal refs like `scripts/check-pr.sh` inside SKILL.md.
      if [ -e "$ROOT/$cleaned" ]; then
        continue
      fi
      doc_dir="$(dirname "$doc")"
      if [ -e "$doc_dir/$cleaned" ]; then
        continue
      fi
      echo "MISS: $rel_doc:$line_num — \`$cleaned\`"
      miss_count=$((miss_count + 1))
    done < "$spans_tmp"
    rm -f "$spans_tmp"
  done < <(grep -n '`' "$doc" 2>/dev/null || true)
done

if [ "$miss_count" -gt 0 ]; then
  echo
  echo "conformance-check: $miss_count missing references across $checked_files spec docs ($ref_count refs scanned)" >&2
  exit 1
fi

if ! $QUIET; then
  echo "conformance-check: clean ($checked_files spec docs, $ref_count refs scanned)"
fi
