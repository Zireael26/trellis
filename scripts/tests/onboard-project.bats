#!/usr/bin/env bats
# Tests for scripts/onboard-project.sh — the portable attachment surface.
#
# FULLY ISOLATED from the live registry and real projects, in the same shape as
# doctor-fix.bats / shared-infra.bats: every test stands up its own fixture in
# a fresh `mktemp` dir and exports $TRELLIS_CONFIG so config-load.sh resolves
# the FIXTURE config, never the worktree's real one.
#
#   <sandbox>/canonical            — the fixture TRELLIS_ROOT
#   <sandbox>/projects             — the fixture PROJECTS_ROOT
#   <sandbox>/projects/<name>      — a real git repo (onboard needs $PROJECT/.git)
#   <sandbox>/trellis.config.json  — trellis_root/projects_root point at the above
#
# Why real onboarding is safe here (same reasoning as doctor-fix.bats):
# onboard reads canonical rules, skills, commands, and agents from
# $TRELLIS_ROOT (the fixture canonical) and the target PROJECT from
# $PROJECTS_ROOT, both from the fixture config, so onboard mutates ONLY inside
# the sandbox. Hook scripts + the Claude settings template are copied from the
# script's own SOURCE_ROOT (the real worktree's core-rules/) INTO the fixture
# project — never written back to the worktree.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
ONBOARD="$REPO_ROOT/scripts/onboard-project.sh"
load helpers/portable-config

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through real path so /var vs /private/var cannot diverge
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  CFG="$SANDBOX/trellis.config.json"
  LOCAL_HOME="$SANDBOX/.trellis"
  SHARED_INFRA="$SANDBOX/shared-infra"
  mkdir -p "$CANON" "$PROJECTS" "$LOCAL_HOME" "$SHARED_INFRA"
  chmod 700 "$LOCAL_HOME"
  export TRELLIS_CONFIG="$CFG"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# Lay down the fixture canonical. onboard REQUIRES: canonical CLAUDE.md,
# skills/, commands/ (+ templates/primer-index-template.md), and agents/.
# The canonical agents dir is deliberately empty (all legacy custom agents were
# removed; the surface is the live whole-directory link for future
# harness-neutral agents).
build_canonical_tree() {
  mkdir -p \
    "$CANON/core-rules/skills/process-gate" \
    "$CANON/core-rules/skills/security-gate" \
    "$CANON/core-rules/skills/aeo-gate" \
    "$CANON/core-rules/commands/templates" \
    "$CANON/core-rules/agents"
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  printf 'x\n' > "$CANON/core-rules/skills/process-gate/SKILL.md"
  printf 'x\n' > "$CANON/core-rules/skills/security-gate/SKILL.md"
  printf 'x\n' > "$CANON/core-rules/skills/aeo-gate/SKILL.md"
  printf 'x\n' > "$CANON/core-rules/commands/primer.md"
  printf 'x\n' > "$CANON/core-rules/commands/primer-refresh.md"
  printf 'x\n' > "$CANON/core-rules/commands/primer-check.md"
  printf 'x\n' > "$CANON/core-rules/commands/explore.md"
  printf 'x\n' > "$CANON/core-rules/commands/autonomy.md"
  printf 'x\n' > "$CANON/core-rules/commands/surgical.md"
  printf '# primer index template\n' \
    > "$CANON/core-rules/commands/templates/primer-index-template.md"
}

# git init the canonical on `main` and commit (needed only when onboarding the
# control-plane clone itself — onboard requires $PROJECT/.git).
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

# Build a real git repo project carrying its own overlay. Onboard requires
# $PROJECT/.git.
build_healthy_project() {
  local hp="$PROJECTS/healthy"
  mkdir -p "$hp"
  cat > "$hp/CLAUDE.md" <<EOF
# Healthy project

@$CANON/core-rules/CLAUDE.md
EOF
  (
    cd "$hp"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
  )
}

# The sanctioned Spec 036 pair (tracked policy + machine state) lives in
# helpers/portable-config.bash so shared-infra.bats models the same shape
# rather than a second copy of the schema.
write_config() {
  portable_config_write "$CFG" "$CANON" "$LOCAL_HOME/config.json" \
    "$PROJECTS" "$SHARED_INFRA" "${1:-\"claude\",\"codex\"}"
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Emit each root-scoped local-runtime ignore pattern with a descendant or file
# fixture that proves its behavior through git's ignore engine.
runtime_ignore_fixtures() {
  cat <<'EOF'
/context-log.md|context-log.md
/.claude/worktrees/|.claude/worktrees/fixture/state
/.claude/settings.local.json|.claude/settings.local.json
/.claude/checkpoints/|.claude/checkpoints/checkpoint.json
/.claude/mailbox/|.claude/mailbox/message.json
/.claude/agent-registry.json|.claude/agent-registry.json
/.claude/agent-memory-local|.claude/agent-memory-local
/.claude/first-run|.claude/first-run
/.claude/assistant-daemon-state.json|.claude/assistant-daemon-state.json
/.claude/routines/.state/|.claude/routines/.state/current
/.claude/scheduled_tasks.lock|.claude/scheduled_tasks.lock
/.claude/scheduled_tasks.json|.claude/scheduled_tasks.json
/.claude/session-autonomy|.claude/session-autonomy
/.claude/session-surgical|.claude/session-surgical
/.claude/spec-gate-audit.log|.claude/spec-gate-audit.log
/.claude/.fail-counter|.claude/.fail-counter
/.codex/.fail-counter|.codex/.fail-counter
/.claude/.reread-state/|.claude/.reread-state/current
/.codex/.reread-state/|.codex/.reread-state/current
/.claude/.review-done-*|.claude/.review-done-fixture
/.codex/.review-done-*|.codex/.review-done-fixture
/.claude/screenshots/|.claude/screenshots/capture.png
/.codex/screenshots/|.codex/screenshots/capture.png
/.claude/codex-thread-pool.json|.claude/codex-thread-pool.json
EOF
}

seed_standalone_runtime_ignores() {
  local hp="$1" pattern fixture
  printf 'project-owned.log\n' > "$hp/.gitignore"
  while IFS='|' read -r pattern fixture; do
    printf '%s\n' "$pattern" >> "$hp/.gitignore"
  done < <(runtime_ignore_fixtures)
}

assert_local_runtime_ignores() {
  local hp="$1" pattern fixture
  while IFS='|' read -r pattern fixture; do
    mkdir -p "$(dirname "$hp/$fixture")"
    : > "$hp/$fixture"
    [ "$(grep -Fxc -- "$pattern" "$hp/.gitignore")" = "1" ] ||
      { echo "missing or duplicate local-runtime pattern: $pattern"; false; }
    run git -C "$hp" check-ignore --no-index -q -- "$fixture"
    [ "$status" -eq 0 ] ||
      { echo "local-runtime fixture is visible: $fixture"; false; }
  done < <(runtime_ignore_fixtures)
}

# ===========================================================================
# 1. Cutover (v1.0.0-rc.25): the legacy direct-link writer is REMOVED.
#
#    Sections 1–9 of this file used to prove what `--legacy` seeded: managed
#    links, the ignore block, idempotence, never-clobber, broken-link
#    replacement, live directory links, harness gating, the control-plane
#    special case, and obsolete-agent cleanup. None of that code exists any
#    more, so none of those cases can pass or fail meaningfully. The equivalent
#    guarantees for the layout that replaced it are proven against the
#    attachment transaction in attach-project.bats, detach-project.bats,
#    surface-plan.bats, and non-trellis-inert.bats.
#
#    What is left to pin here is the removal itself: every spelling that used to
#    select the writer refuses with the usage class, names the migration, and —
#    the assertion that matters — writes nothing into the project.
# ===========================================================================

run_removed_mode() {
  run env HOME="$SANDBOX" TRELLIS_HOME="$LOCAL_HOME" TRELLIS_CONFIG="$CFG" \
    TRELLIS_SKIP_INFRA=1 TRELLIS_SKIP_SECURITY_BASELINE=1 \
    bash "$ONBOARD" "$@"
}

assert_project_untouched() {
  local hp="$1"
  [ ! -e "$hp/.claude/rules/trellis.md" ]
  [ ! -L "$hp/.claude/rules/trellis.md" ]
  [ ! -e "$hp/.claude/skills/process-gate" ]
  [ ! -e "$hp/.trellis.json" ]
  [ ! -e "$hp/gotchas.md" ]
  if [ -f "$hp/.gitignore" ]; then
    ! grep -Fq 'Trellis inheritance symlinks' "$hp/.gitignore"
  fi
}

@test "--legacy refuses with exit 2 and writes nothing into the project" {
  build_canonical_tree
  build_healthy_project
  write_config

  run_removed_mode --legacy "$PROJECTS/healthy"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis attach --fleet NAME"* ]] || { echo "$output"; false; }

  assert_project_untouched "$PROJECTS/healthy"
}

@test "--compatibility, --legacy-relative, and --infra-entry all refuse identically" {
  build_canonical_tree
  build_healthy_project
  write_config

  local mode
  for mode in --compatibility --legacy-relative --infra-entry; do
    run_removed_mode "$mode" "$PROJECTS/healthy"
    [ "$status" -eq 2 ] || { echo "$mode: $output"; false; }
    [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$mode: $output"; false; }
    assert_project_untouched "$PROJECTS/healthy"
  done

  # The `=`-joined spelling must refuse before it consumes its value, so a
  # scripted `--infra-entry=<file>` cannot fall through to portable onboarding
  # and be read as a project path.
  run_removed_mode --infra-entry="$SANDBOX/entry.yml" "$PROJECTS/healthy"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  assert_project_untouched "$PROJECTS/healthy"
}

@test "the refusal is a usage error, not a portable onboarding attempt" {
  build_canonical_tree
  build_healthy_project
  write_config

  # Exit 2 is the usage class. A conflict (3) or state (4) class would mean the
  # portable path ran and formed an opinion about the project, which is exactly
  # what the dispatcher must prevent for a removed mode.
  run_removed_mode --legacy --fleet personal "$PROJECTS/healthy"
  [ "$status" -eq 2 ]
  [[ "$output" != *"created tracked manifest"* ]] || { echo "$output"; false; }
  assert_project_untouched "$PROJECTS/healthy"
}

# ===========================================================================
# 10. Portable default: one inert manifest, then local attachment delegation.
# ===========================================================================

build_portable_onboard_fixture() {
  PORTABLE_BIN="$SANDBOX/portable-bin"
  PORTABLE_ONBOARD="$PORTABLE_BIN/onboard-project.sh"
  ATTACH_LOG="$SANDBOX/attach.argv"
  PORTABLE_PROJECT="$SANDBOX/project with spaces"
  mkdir -p "$PORTABLE_BIN/lib" "$PORTABLE_PROJECT"
  cp "$ONBOARD" "$PORTABLE_ONBOARD"
  cp "$REPO_ROOT/scripts/lib/trellis-home.sh" "$PORTABLE_BIN/lib/trellis-home.sh"
  cp "$REPO_ROOT/scripts/lib/local-registry.sh" "$PORTABLE_BIN/lib/local-registry.sh"
  cat > "$PORTABLE_BIN/attach-project.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ATTACH_LOG"
EOF
  chmod +x "$PORTABLE_ONBOARD" "$PORTABLE_BIN/attach-project.sh"
  (
    cd "$PORTABLE_PROJECT"
    git init -q -b main
    git config user.email test@example.com
    git config user.name test
    printf 'seed\n' > README.md
    git add README.md
    git commit -qm init
  )
}

run_portable_onboard() {
  run env ATTACH_LOG="$ATTACH_LOG" TRELLIS_CONFIG="$SANDBOX/missing-legacy-config.json" \
    bash "$PORTABLE_ONBOARD" "$@"
}

@test "portable onboarding writes only the inert manifest and forwards local selectors" {
  build_portable_onboard_fixture

  run_portable_onboard --fleet personal --home "$SANDBOX/home" --release 1.2.3 \
    --harness claude --harness codex --project-id portable-project "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"created tracked manifest:"* ]] || { echo "$output"; false; }
  jq -e '
    keys == ["$schema", "project_id", "schema_version"]
    and ."$schema" == "https://trellis.local/schemas/trellis.project.schema.json"
    and .schema_version == 1
    and .project_id == "portable-project"
  ' "$PORTABLE_PROJECT/.trellis.json"
  [ "$(grep -cF "$SANDBOX" "$PORTABLE_PROJECT/.trellis.json")" -eq 0 ] || { cat "$PORTABLE_PROJECT/.trellis.json"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" status --short)" = "?? .trellis.json" ]
  [ "$(sed -n '1p' "$ATTACH_LOG")" = attach ]
  [ "$(sed -n '2p' "$ATTACH_LOG")" = --home ]
  [ "$(sed -n '3p' "$ATTACH_LOG")" = "$SANDBOX/home" ]
  [ "$(sed -n '4p' "$ATTACH_LOG")" = --fleet ]
  [ "$(sed -n '5p' "$ATTACH_LOG")" = personal ]
  [ "$(sed -n '6p' "$ATTACH_LOG")" = --release ]
  [ "$(sed -n '7p' "$ATTACH_LOG")" = 1.2.3 ]
  [ "$(sed -n '8p' "$ATTACH_LOG")" = --harness ]
  [ "$(sed -n '9p' "$ATTACH_LOG")" = claude ]
  [ "$(sed -n '10p' "$ATTACH_LOG")" = --harness ]
  [ "$(sed -n '11p' "$ATTACH_LOG")" = codex ]
  [ "$(sed -n '12p' "$ATTACH_LOG")" = "$PORTABLE_PROJECT" ]
}

@test "portable onboarding is idempotent for an existing valid manifest" {
  build_portable_onboard_fixture
  run_portable_onboard --fleet personal --project-id portable-project "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ]
  local before
  before="$(sha_of "$PORTABLE_PROJECT/.trellis.json")"

  run_portable_onboard --fleet personal "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"created tracked manifest:"* ]] || { echo "$output"; false; }
  [ "$(sha_of "$PORTABLE_PROJECT/.trellis.json")" = "$before" ]
  [ "$(sed -n '1p' "$ATTACH_LOG")" = attach ]
}

@test "portable onboarding rejects a legacy preset beside an existing manifest" {
  build_portable_onboard_fixture
  cat > "$PORTABLE_PROJECT/.trellis.json" <<'JSON'
{"$schema":"https://trellis.local/schemas/trellis.project.schema.json","project_id":"portable-project","schema_version":1}
JSON
  mkdir -p "$PORTABLE_PROJECT/.claude/rules"
  ln -s "$SANDBOX/legacy-preset.md" "$PORTABLE_PROJECT/.claude/rules/preset-legacy.md"

  run_portable_onboard --fleet personal "$PORTABLE_PROJECT"

  [ "$status" -eq 3 ]
  [ -L "$PORTABLE_PROJECT/.claude/rules/preset-legacy.md" ]
  [ ! -e "$ATTACH_LOG" ]
}

@test "portable onboarding never overwrites an invalid project manifest" {
  build_portable_onboard_fixture
  printf 'project owned\n' > "$PORTABLE_PROJECT/.trellis.json"
  local before
  before="$(sha_of "$PORTABLE_PROJECT/.trellis.json")"

  run_portable_onboard --fleet personal "$PORTABLE_PROJECT"
  [ "$status" -eq 3 ]
  [ "$(sha_of "$PORTABLE_PROJECT/.trellis.json")" = "$before" ]
  [ ! -e "$ATTACH_LOG" ]
}

@test "portable onboarding requires an explicit valid fleet" {
  build_portable_onboard_fixture
  run_portable_onboard "$PORTABLE_PROJECT"
  [ "$status" -eq 2 ]
  [ ! -e "$PORTABLE_PROJECT/.trellis.json" ]

  run_portable_onboard --fleet '../personal' "$PORTABLE_PROJECT"
  [ "$status" -eq 2 ]
  [ ! -e "$PORTABLE_PROJECT/.trellis.json" ]
}

@test "portable onboarding rejects a legacy layout before creating a manifest" {
  build_portable_onboard_fixture
  printf '{"presets":["legacy"]}\n' > "$PORTABLE_PROJECT/.trellis.config.json"
  local before
  before="$(sha_of "$PORTABLE_PROJECT/.trellis.config.json")"

  run_portable_onboard --fleet personal "$PORTABLE_PROJECT"

  [ "$status" -eq 3 ]
  [[ "$output" == *"trellis migrate --prepare"* ]] || { echo "$output"; false; }
  # The refusal must not offer the removed writer as an escape hatch.
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [ "$(sha_of "$PORTABLE_PROJECT/.trellis.config.json")" = "$before" ]
  [ ! -e "$PORTABLE_PROJECT/.trellis.json" ]
  [ ! -L "$PORTABLE_PROJECT/.trellis.json" ]
  [ ! -e "$ATTACH_LOG" ]
}

@test "portable onboarding rejects mixed legacy surfaces without changing bytes" {
  build_portable_onboard_fixture
  cat > "$PORTABLE_PROJECT/.trellis.json" <<'JSON'
{"$schema":"https://trellis.local/schemas/trellis.project.schema.json","project_id":"portable-project","schema_version":1}
JSON
  cat > "$PORTABLE_PROJECT/.gitignore" <<'EOF'
project-owned.log
# --- Trellis inheritance symlinks (per-machine; regenerated by onboard-project.sh) ---
EOF
  local manifest_before ignore_before
  manifest_before="$(sha_of "$PORTABLE_PROJECT/.trellis.json")"
  ignore_before="$(sha_of "$PORTABLE_PROJECT/.gitignore")"

  run_portable_onboard --fleet personal "$PORTABLE_PROJECT"

  [ "$status" -eq 3 ]
  [[ "$output" == *"trellis migrate --prepare"* ]] || { echo "$output"; false; }
  [ "$(sha_of "$PORTABLE_PROJECT/.trellis.json")" = "$manifest_before" ]
  [ "$(sha_of "$PORTABLE_PROJECT/.gitignore")" = "$ignore_before" ]
  [ ! -e "$ATTACH_LOG" ]
}

@test "portable onboarding leaves a precreated hostile manifest temp untouched" {
  build_portable_onboard_fixture
  local victim hostile_tmp fake_bin real_mktemp
  victim="$SANDBOX/attacker-owned.txt"
  hostile_tmp="$PORTABLE_PROJECT/.trellis.json.tmp.precreated"
  fake_bin="$SANDBOX/fake-bin"
  real_mktemp="$(command -v mktemp)"
  printf 'attacker bytes\n' > "$victim"
  ln -s "$victim" "$hostile_tmp"
  mkdir "$fake_bin"
  cat > "$fake_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  */.trellis.json.tmp.XXXXXX) printf '%s\n' "$HOSTILE_TMP" ;;
  *) exec "$REAL_MKTEMP" "$@" ;;
esac
EOF
  chmod +x "$fake_bin/mktemp"
  export HOSTILE_TMP="$hostile_tmp"
  export REAL_MKTEMP="$real_mktemp"
  export PATH="$fake_bin:$PATH"

  run_portable_onboard --fleet personal --project-id portable-project "$PORTABLE_PROJECT"

  [ "$status" -eq 3 ]
  [ "$(cat "$victim")" = "attacker bytes" ]
  [ -L "$hostile_tmp" ]
  [ "$(readlink "$hostile_tmp")" = "$victim" ]
  [ ! -e "$PORTABLE_PROJECT/.trellis.json" ]
  [ ! -L "$PORTABLE_PROJECT/.trellis.json" ]
  [ ! -e "$ATTACH_LOG" ]
}
