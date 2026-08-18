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

# 1. TRELLIS_ALLOW_MAIN_PUSH=1 in commit trailers within range -> warn (must be justified)
if git log --format='%B' "$RANGE" 2>/dev/null | grep -qE 'TRELLIS_ALLOW_MAIN_PUSH=1'; then
  findings+=("commit-trailer: TRELLIS_ALLOW_MAIN_PUSH=1 found — must be justified in gotchas.md")
  [ "$worst" = "pass" ] && worst="warn"
fi

# 1a. PROCESS_GATE_SKIP=1 in commit trailers within range -> warn (must be justified)
if git log --format='%B' "$RANGE" 2>/dev/null | grep -qE 'PROCESS_GATE_SKIP=1'; then
  findings+=("commit-trailer: PROCESS_GATE_SKIP=1 found — must be justified in gotchas.md")
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

# 3a. core.hooksPath actively disabled: persistent config pointing hooks to /dev/null.
# Distinguish "key set" from "key unset" via exit code — `git config --get` returns 1 when unset.
if git -C "$PROJECT_DIR" config --get core.hooksPath >/dev/null 2>&1; then
  hp_active="$(git -C "$PROJECT_DIR" config --get core.hooksPath 2>/dev/null || true)"
  case "$hp_active" in
    /dev/null|/dev/zero|"")
      display="$hp_active"
      [ -z "$display" ] && display="<empty>"
      findings+=("core.hooksPath: actively set to disable hooks (value: $display)")
      worst="fail"
      ;;
  esac
fi

# 3b. commit.gpgsign actively disabled via persistent config.
# Policy-level — many projects legitimately disable signing; warn rather than fail.
if git -C "$PROJECT_DIR" config --get commit.gpgsign >/dev/null 2>&1; then
  gp="$(git -C "$PROJECT_DIR" config --get commit.gpgsign 2>/dev/null || true)"
  if [ "$gp" = "false" ]; then
    findings+=("commit.gpgsign: actively disabled via persistent config")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

# Undetectable bypasses (no trace post-hoc):
#   - `git -c commit.gpgsign=false commit ...` (one-shot config override)
#   - `git commit --no-gpg-sign ...` (flag does not appear in reflog)
# These can only be caught by either pre-commit-hook trapping or by
# tracking expected-signed-commit policy via branch protection. Out of
# scope for this gate — flagging here so future readers don't reinvent
# an undetectable check.

# 4. Claude hooks block: present in either settings file?
# Registration counts from the tracked settings.json or the machine-local
# settings.local.json — portable attachment keeps settings.json free of
# machine paths and registers the hooks in the local file.
# Stated assumption: `hooks` is a JSON object of event keys, as the Claude Code
# schema defines it. An array-, null-, or false-valued `hooks`, and JSONC with
# comments inside the block, all read as unregistered rather than being parsed.
settings_seen=""
hooks_registered=""
for s in "$PROJECT_DIR/.claude/settings.json" "$PROJECT_DIR/.claude/settings.local.json"; do
  [ -f "$s" ] || continue
  settings_seen="yes"
  # Whitespace-squashed via command substitution (not a pipe — `grep -q` would
  # SIGPIPE `tr` and trip pipefail on a match). The pattern demands an event key
  # AND a command entry after it, so neither `"hooks": {}` nor an event key
  # stripped back to `"PreToolUse": []` counts as registered — stripping the
  # entries and leaving the keys is the tampering shape this gate exists for.
  squashed="$(tr -d '[:space:]' < "$s" 2>/dev/null || true)"
  case "$squashed" in
    *'"hooks":{"'*'"type":"command"'*) hooks_registered="yes" ;;
  esac
done
if [ -z "$hooks_registered" ]; then
  if [ -n "$settings_seen" ]; then
    findings+=(".claude/settings.json / .claude/settings.local.json: no \"hooks\" event with a command entry in either — Tier 1+2 hooks not registered")
    worst="fail"
  elif [ -f "$PROJECT_DIR/.trellis.json" ]; then
    # Deleting the settings pair is otherwise the cheapest bypass, so on a
    # project the gate knows is attached, absence fails like an emptied block.
    findings+=(".claude/settings.json / .claude/settings.local.json: neither file exists in a Trellis-attached project — Tier 1+2 hooks not registered")
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
