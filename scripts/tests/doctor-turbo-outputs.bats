#!/usr/bin/env bats
# Tests for the hc_turbo_outputs recurrence guard as wired into scripts/doctor.sh
# (the report-only Component-3 guard for the 148 GB/2-day build-cache blowup).
#
# Asserts the three classifications end to end through the real doctor:
#   * unscoped `.next/**` outputs glob -> WARN row + the one-line fix hint
#   * scoped glob (with !.next/cache/** negation) -> OK
#   * no turbo.json -> OK
# and the load-bearing safety property: turbo.json is BYTE-IDENTICAL after the
# run. turbo.json is a user-owned project file; doctor NEVER auto-edits it (same
# policy as the CLAUDE.md @-import) and must NOT add a --fix action for it.
#
# This suite reuses doctor.bats' fixture idiom verbatim — a fully healthy
# project plus a turbo.json — so the ONLY signal that changes between cases is
# the turbo check. The whole fixture lives under a fresh `mktemp -d`; the run
# CANNOT reach ~/projects (TRELLIS_CONFIG points at the fixture config whose
# trellis_root/projects_root are the sandbox).
#
# Paths resolve relative to this file (../.. = worktree root) — no hardcoded
# absolute paths (those leak into the public mirror).
#
# bash 3.2 / bats 1.x. `[[ ]]` is fine in bats (not shellcheck-gated).

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"

# Kept in lockstep with HC_CANONICAL_SKILLS / HC_CANONICAL_COMMANDS in
# health-checks.sh (same lists doctor.bats uses).
CANON_SKILLS="process-gate security-gate clarify spec plan tasks analyze"
CANON_COMMANDS="primer primer-refresh primer-check explore autonomy"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  CFG="$SANDBOX/trellis.config.json"
  mkdir -p "$CANON" "$PROJECTS"
  export TRELLIS_CONFIG="$CFG"
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders (cloned from doctor.bats so this suite stays self-contained).
# ---------------------------------------------------------------------------

build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands"
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  local s c
  for s in $CANON_SKILLS; do
    mkdir -p "$CANON/core-rules/skills/$s"
    printf 'x\n' > "$CANON/core-rules/skills/$s/SKILL.md"
  done
  for c in $CANON_COMMANDS; do
    printf 'x\n' > "$CANON/core-rules/commands/$c.md"
  done
  cat > "$CANON/registry.md" <<EOF
# Project registry

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| healthy | \`/personal/healthy\` | app | fixture |

---
EOF
  cat > "$CANON/blacklist.md" <<EOF
# Blacklist

## 1. Temporarily excluded (registered projects)

| Project | Reason | Added | Review after |
|---|---|---|---|
| — | — | — | — |

## 2. Permanently excluded from management

| Path | Reason |
|---|---|

## Semantics
EOF
}

git_init_canonical_main() {
  (
    cd "$CANON"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    git add -A
    git commit -q -m "init"
  )
}

write_config() {
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"]
}
EOF
}

build_healthy_project() {
  local hp="$PROJECTS/healthy"
  mkdir -p "$hp/.claude/rules" "$hp/.claude/skills" "$hp/.claude/commands"
  ln -s "$CANON/core-rules/CLAUDE.md" "$hp/.claude/rules/trellis.md"
  local s c
  for s in $CANON_SKILLS; do
    ln -s "$CANON/core-rules/skills/$s" "$hp/.claude/skills/$s"
  done
  for c in $CANON_COMMANDS; do
    ln -s "$CANON/core-rules/commands/$c.md" "$hp/.claude/commands/$c.md"
  done
  cat > "$hp/CLAUDE.md" <<EOF
# Healthy project

@$CANON/core-rules/CLAUDE.md
EOF
  printf '{ "hooks": {} }\n' > "$hp/.claude/settings.json"
}

# write_turbo <json-body> — drop a turbo.json into the healthy project.
write_turbo() {
  printf '%s\n' "$1" > "$PROJECTS/healthy/turbo.json"
}

# sha of the project's turbo.json (proves report-only / no mutation).
turbo_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum "$PROJECTS/healthy/turbo.json" | awk '{print $1}'
  else
    sha256sum "$PROJECTS/healthy/turbo.json" | awk '{print $1}'
  fi
}

run_doctor() { run bash "$DOCTOR" "$@"; }

# ===========================================================================
# Classifications
# ===========================================================================

@test "unscoped .next/** turbo outputs -> WARN row + the one-line fix hint, exit 0" {
  write_turbo '{ "tasks": { "build": { "outputs": [".next/**"] } } }'
  run_doctor
  [ "$status" -eq 0 ]
  # The check WARNs (⚠ glyph) for the unscoped glob.
  [[ "$output" == *"⚠"*"turbo-outputs:"*"unscoped"* ]]
  # The one-line fix hint surfaces (both negations named).
  [[ "$output" == *"!.next/cache/**"* ]]
  [[ "$output" == *"!.next/dev/**"* ]]
  # Degraded, not broken: no inheritance ERROR.
  [[ "$output" != *"✗ inheritance is broken"* ]]
}

@test "scoped turbo outputs (with !.next/cache/** negation) -> OK" {
  write_turbo '{ "tasks": { "build": { "outputs": [".next/**", "!.next/cache/**", "!.next/dev/**"] } } }'
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓"*"turbo-outputs:"*"scoped"* ]]
  # No unscoped WARN. (Check the WARN-specific phrase — the OK message itself
  # contains "no unscoped .next/** glob", so a bare "unscoped" substring collides.)
  [[ "$output" != *"has an unscoped .next/** outputs glob"* ]]
}

@test "no turbo.json -> OK (recurrence check skipped)" {
  # build_healthy_project lays down no turbo.json.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"turbo-outputs: no turbo.json"* ]]
}

@test "legacy v1 .pipeline schema with an unscoped glob also WARNs" {
  write_turbo '{ "pipeline": { "build": { "outputs": [".next/**"] } } }'
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠"*"turbo-outputs:"*"unscoped"* ]]
}

# ===========================================================================
# REPORT-ONLY safety: turbo.json must be byte-identical after the run.
# ===========================================================================

@test "doctor NEVER mutates turbo.json (byte-identical after the unscoped WARN run)" {
  write_turbo '{ "tasks": { "build": { "outputs": [".next/**"] } } }'
  local before after before_bytes after_bytes
  before="$(turbo_sha)"
  before_bytes="$(wc -c < "$PROJECTS/healthy/turbo.json" | tr -d ' ')"
  run_doctor
  [ "$status" -eq 0 ]
  after="$(turbo_sha)"
  after_bytes="$(wc -c < "$PROJECTS/healthy/turbo.json" | tr -d ' ')"
  # Same checksum AND same byte count -> not touched.
  [ "$before" = "$after" ]
  [ "$before_bytes" = "$after_bytes" ]
}

@test "doctor --fix does NOT touch turbo.json (no --fix action for the turbo guard)" {
  write_turbo '{ "tasks": { "build": { "outputs": [".next/**"] } } }'
  local before after
  before="$(turbo_sha)"
  # --fix runs the apply machinery for the auto-fixable checks; the turbo guard
  # is deliberately OUTSIDE it. turbo.json must remain byte-identical.
  run_doctor --fix
  after="$(turbo_sha)"
  [ "$before" = "$after" ]
}
