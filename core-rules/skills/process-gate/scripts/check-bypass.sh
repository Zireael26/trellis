#!/usr/bin/env bash
# Gate 3: Bypass markers — --no-verify, force-push, override env vars, hook tampering.
# Usage: check-bypass.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

worst="pass"
findings=()

# 1. SE_CORE_ALLOW_MAIN_PUSH=1 in commit trailers within range -> warn (must be justified)
if git log --format='%B' "$RANGE" 2>/dev/null | grep -qE 'SE_CORE_ALLOW_MAIN_PUSH=1'; then
  findings+=("commit-trailer: SE_CORE_ALLOW_MAIN_PUSH=1 found — must be justified in gotchas.md")
  [ "$worst" = "pass" ] && worst="warn"
fi

# 2. .husky/* tampering: short-circuit at top
if [ -d "$PROJECT_DIR/.husky" ]; then
  while IFS= read -r hook; do
    [ -z "$hook" ] && continue
    [ -f "$hook" ] || continue
    # First non-empty, non-shebang, non-comment line
    first="$(awk 'NR>1 && !/^#/ && !/^[[:space:]]*$/ {print; exit}' "$hook" 2>/dev/null || true)"
    case "$first" in
      "exit 0"|"true"|":") findings+=("${hook#"$PROJECT_DIR"/}: short-circuit (first effective line: $first)"); worst="fail" ;;
    esac
  done < <(find "$PROJECT_DIR/.husky" -maxdepth 1 -type f \( -name 'pre-*' -o -name 'commit-msg' -o -name 'post-*' \) 2>/dev/null)
fi

# 3. Native-githooks projects: core.hooksPath set?
if [ ! -f "$PROJECT_DIR/package.json" ]; then
  hp="$(git -C "$PROJECT_DIR" config --get core.hooksPath 2>/dev/null || true)"
  if [ -z "$hp" ]; then
    # Only flag if .githooks/ exists in the tree (project intends to use it)
    if [ -d "$PROJECT_DIR/.githooks" ]; then
      findings+=("git-config: core.hooksPath unset but .githooks/ present — hooks will not run")
      worst="fail"
    fi
  fi
fi

# 4. .claude/settings.json hooks block: present?
if [ -f "$PROJECT_DIR/.claude/settings.json" ]; then
  if ! grep -q '"hooks"' "$PROJECT_DIR/.claude/settings.json" 2>/dev/null; then
    findings+=(".claude/settings.json: no \"hooks\" key found — Tier 1+2 hooks not registered")
    worst="fail"
  fi
fi

# 5. Range commits with --no-verify in reflog (best-effort; reflog is local)
# If we have access to the reflog and any commit in the range matches a no-verify entry by sha, flag.
if [ -d "$PROJECT_DIR/.git" ] && git -C "$PROJECT_DIR" reflog show HEAD --grep-reflog='no-verify' >/dev/null 2>&1; then
  # Best-effort. Reflog is not always populated, especially for fresh clones / CI.
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    if git -C "$PROJECT_DIR" reflog show HEAD --format='%H %gs' 2>/dev/null | grep -E "^$sha .*no-verify" >/dev/null 2>&1; then
      findings+=("commit:$sha — committed with --no-verify (reflog evidence)")
      worst="fail"
    fi
  done < <(git -C "$PROJECT_DIR" log --format='%H' "$RANGE" 2>/dev/null)
fi

case "$worst" in
  pass) pg_log pass "Bypass markers (range=$RANGE)" ;;
  warn) pg_log warn "Bypass markers (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "Bypass markers (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
