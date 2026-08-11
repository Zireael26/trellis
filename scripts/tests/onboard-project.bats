#!/usr/bin/env bats
# Tests for scripts/onboard-project.sh — the OMP native surface.
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
# onboard reads canonical rules/skills/commands/agents/omp-hooks from
# $TRELLIS_ROOT (the fixture canonical) and the target PROJECT from
# $PROJECTS_ROOT, both from the fixture config, so onboard mutates ONLY inside
# the sandbox. Hook scripts + the Claude settings template are copied from the
# script's own SOURCE_ROOT (the real worktree's core-rules/) INTO the fixture
# project — never written back to the worktree.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
ONBOARD="$REPO_ROOT/scripts/onboard-project.sh"

RUNTIME_IGNORE_PATTERNS=(
  "/context-log.md"
  "/.claude/worktrees/"
  "/.claude/settings.local.json"
  "/.claude/checkpoints/"
  "/.claude/mailbox/"
  "/.claude/agent-registry.json"
  "/.claude/agent-memory-local"
  "/.claude/first-run"
  "/.claude/assistant-daemon-state.json"
  "/.claude/routines/.state/"
  "/.claude/scheduled_tasks.lock"
  "/.claude/scheduled_tasks.json"
  "/.claude/session-autonomy"
  "/.claude/session-surgical"
  "/.claude/spec-gate-audit.log"
  "/.claude/.fail-counter"
  "/.codex/.fail-counter"
  "/.claude/.reread-state/"
  "/.codex/.reread-state/"
  "/.claude/.review-done-*"
  "/.codex/.review-done-*"
  "/.claude/screenshots/"
  "/.codex/screenshots/"
  "/.claude/codex-thread-pool.json"
)

assert_runtime_ignore_contract() {
  local project="$1"
  local pattern fixture matches root_scoped_count

  for pattern in "${RUNTIME_IGNORE_PATTERNS[@]}"; do
    matches="$(grep -Fxc -- "$pattern" "$project/.gitignore" || true)"
    [ "$matches" -eq 1 ] || {
      echo "runtime ignore pattern must appear exactly once: $pattern"
      return 1
    }

    fixture="${pattern#/}"
    case "$fixture" in
      */) fixture="${fixture}runtime-state" ;;
      *\*) fixture="${fixture%\*}runtime-state" ;;
    esac
    mkdir -p "$(dirname "$project/$fixture")"
    : > "$project/$fixture"
    git -C "$project" check-ignore --no-index -q -- "$fixture" || {
      echo "runtime state is not ignored: $fixture"
      return 1
    }
  done

  root_scoped_count="$(grep -Ec '^/' "$project/.gitignore" || true)"
  [ "$root_scoped_count" -eq "${#RUNTIME_IGNORE_PATTERNS[@]}" ] || {
    echo "unexpected root-scoped runtime ignore inventory"
    return 1
  }
}

seed_standalone_runtime_policy() {
  local project="$1"
  printf 'project-owned.log\n' > "$project/.gitignore"
  printf '%s\n' "${RUNTIME_IGNORE_PATTERNS[@]}" >> "$project/.gitignore"
}

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through real path so /var vs /private/var cannot diverge
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  CFG="$SANDBOX/trellis.config.json"
  mkdir -p "$CANON" "$PROJECTS"
  export TRELLIS_CONFIG="$CFG"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# Lay down the fixture canonical. onboard REQUIRES: canonical CLAUDE.md,
# skills/, commands/ (+ templates/primer-index-template.md), agents/, and the
# OMP hooks dir (core-rules/omp/hooks — the .omp/hooks link target). The
# canonical agents dir is deliberately empty (all legacy custom agents were
# removed; the surface is the live whole-directory link for future
# harness-neutral agents).
build_canonical_tree() {
  mkdir -p \
    "$CANON/core-rules/skills/process-gate" \
    "$CANON/core-rules/skills/security-gate" \
    "$CANON/core-rules/commands/templates" \
    "$CANON/core-rules/agents" \
    "$CANON/core-rules/omp/hooks"
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  printf 'x\n' > "$CANON/core-rules/skills/process-gate/SKILL.md"
  printf 'x\n' > "$CANON/core-rules/skills/security-gate/SKILL.md"
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

# Build a real git repo project carrying its own overlay (the .omp/AGENTS.md
# target). onboard requires $PROJECT/.git.
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

write_config() {
  local harnesses_json="${1:-\"claude\",\"omp\"}"
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": [$harnesses_json]
}
EOF
}

run_onboard() {
  run env TRELLIS_CONFIG="$CFG" TRELLIS_SKIP_SECURITY_BASELINE=1 \
    bash "$ONBOARD" "$@"
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# ===========================================================================
# 1. The five OMP links: exact absolute targets, resolving, nothing extra.
# ===========================================================================

@test "onboard seeds the five OMP links with exact absolute targets" {
  build_canonical_tree
  build_healthy_project
  write_config

  run_onboard "$PROJECTS/healthy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local hp="$PROJECTS/healthy"
  # .omp/AGENTS.md → the project's own CLAUDE.md (absolute machine-local link)
  [ -L "$hp/.omp/AGENTS.md" ]
  [ "$(readlink "$hp/.omp/AGENTS.md")" = "$hp/CLAUDE.md" ]
  # Four whole-directory links → canonical core-rules
  [ -L "$hp/.omp/skills" ]
  [ "$(readlink "$hp/.omp/skills")" = "$CANON/core-rules/skills" ]
  [ -L "$hp/.omp/commands" ]
  [ "$(readlink "$hp/.omp/commands")" = "$CANON/core-rules/commands" ]
  [ -L "$hp/.omp/agents" ]
  [ "$(readlink "$hp/.omp/agents")" = "$CANON/core-rules/agents" ]
  [ -L "$hp/.omp/hooks" ]
  [ "$(readlink "$hp/.omp/hooks")" = "$CANON/core-rules/omp/hooks" ]

  # Every link resolves (directory links resolve to dirs; AGENTS.md resolves
  # through the project overlay).
  [ -e "$hp/.omp/AGENTS.md" ]
  [ -d "$hp/.omp/skills" ]
  [ -d "$hp/.omp/commands" ]
  [ -d "$hp/.omp/agents" ]
  [ -d "$hp/.omp/hooks" ]

  # User-owned OMP config files are never generated (operator-owned).
  [ ! -e "$hp/.omp/config.yml" ]
  [ ! -e "$hp/.omp/mcp.json" ]

  # No individual custom agents are seeded anywhere (legacy agents were
  # removed; the agents surface is the whole-directory link only).
  [ ! -e "$hp/.claude/agents" ]

  # Output shows the links being created.
  [[ "$output" == *"linked: .omp/AGENTS.md"* ]]
  [[ "$output" == *"linked: .omp/skills"* ]]
  [[ "$output" == *"linked: .omp/hooks"* ]]
}

# ===========================================================================
# 2. Managed ignore: the five OMP links plus root-only runtime state.
# ===========================================================================

@test "managed ignore protects runtime state without hiding tracked surfaces" {
  build_canonical_tree
  build_healthy_project
  write_config
  local hp="$PROJECTS/healthy"
  seed_standalone_runtime_policy "$hp"
  run_onboard "$hp"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_runtime_ignore_contract "$hp"
  grep -Fxq -- "project-owned.log" "$hp/.gitignore" ||
    { echo "project-authored ignore line was removed"; false; }

  mkdir -p "$hp/nested"
  : > "$hp/nested/context-log.md"
  run git -C "$hp" check-ignore --no-index -q -- "nested/context-log.md"
  [ "$status" -eq 1 ] || { echo "nested context-log.md is unexpectedly ignored"; false; }

  # Tracked onboarding surfaces remain visible.
  local rel
  for rel in ".claude/settings.json" ".claude/primers/INDEX.md"; do
    [ -f "$hp/$rel" ] || { echo "missing tracked onboarding surface: $rel"; false; }
    run git -C "$hp" check-ignore --no-index -q -- "$rel"
    [ "$status" -eq 1 ] || { echo "tracked onboarding surface is ignored: $rel"; false; }
  done

  # The managed .gitignore block lists all five exact machine-local links.
  for rel in ".omp/AGENTS.md" ".omp/skills" ".omp/commands" ".omp/agents" ".omp/hooks"; do
    grep -q "^$rel\$" "$hp/.gitignore" || { echo "missing from .gitignore: $rel"; false; }
    git -C "$hp" check-ignore -q "$rel" || { echo "not ignored: $rel"; false; }
  done
  # They never appear in git status (untracked + ignored).
  run git -C "$hp" status --porcelain
  [[ "$output" != *".omp"* ]]
}

# ===========================================================================
# 3. Idempotence: second run skips the OMP links, .gitignore stays stable.
# ===========================================================================

@test "idempotent: second run skips correct OMP links and leaves .gitignore stable" {
  build_canonical_tree
  build_healthy_project
  write_config
  local hp="$PROJECTS/healthy"
  seed_standalone_runtime_policy "$hp"
  run_onboard "$hp"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_runtime_ignore_contract "$hp"

  local before
  before="$(sha_of "$hp/.gitignore")"

  run_onboard "$PROJECTS/healthy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [[ "$output" == *"skip (correct symlink): .omp/AGENTS.md"* ]]
  [[ "$output" == *"skip (correct symlink): .omp/skills"* ]]
  [[ "$output" == *"skip (correct symlink): .omp/hooks"* ]]
  [[ "$output" != *"linked: .omp/"* ]]
  [ "$(readlink "$hp/.omp/AGENTS.md")" = "$hp/CLAUDE.md" ]
  [ "$(readlink "$hp/.omp/hooks")" = "$CANON/core-rules/omp/hooks" ]
  assert_runtime_ignore_contract "$hp"
  [ "$(sha_of "$hp/.gitignore")" = "$before" ]
}

# ===========================================================================
# 4. Never-clobber: user-owned OMP paths are refused, WARNed, left intact.
# ===========================================================================

@test "user-owned OMP paths are never clobbered" {
  build_canonical_tree
  build_healthy_project
  write_config

  local hp="$PROJECTS/healthy"
  mkdir -p "$hp/.omp"
  # User-owned regular file where .omp/AGENTS.md belongs.
  printf 'user overlay\n' > "$hp/.omp/AGENTS.md"
  # User-owned real directory where .omp/skills belongs.
  mkdir -p "$hp/.omp/skills"
  printf 'user content\n' > "$hp/.omp/skills/local.md"
  # User-owned symlink elsewhere where .omp/commands belongs.
  ln -s "$SANDBOX/user-commands" "$hp/.omp/commands"
  # User-owned OMP config.
  printf 'model: user\n' > "$hp/.omp/config.yml"

  run_onboard "$hp"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # The user file is untouched (WARN, not clobbered).
  [ -f "$hp/.omp/AGENTS.md" ] && [ ! -L "$hp/.omp/AGENTS.md" ]
  [ "$(cat "$hp/.omp/AGENTS.md")" = "user overlay" ]
  [[ "$output" == *"exists and is not a symlink"* ]]
  # The user directory is untouched.
  [ -d "$hp/.omp/skills" ] && [ ! -L "$hp/.omp/skills" ]
  [ "$(cat "$hp/.omp/skills/local.md")" = "user content" ]
  # The user symlink is untouched (wrong-target WARN).
  [ -L "$hp/.omp/commands" ]
  [ "$(readlink "$hp/.omp/commands")" = "$SANDBOX/user-commands" ]
  [[ "$output" == *"leaving as-is"* ]]
  # User config is untouched.
  [ -f "$hp/.omp/config.yml" ]
  [ "$(cat "$hp/.omp/config.yml")" = "model: user" ]
}

# ===========================================================================
# 5. Broken-link replacement where existing policy permits: onboard alone
#    never clobbers a broken link; after the link is rm'd (doctor --fix's
#    rm-then-reseed policy), onboard re-creates the exact OMP link.
# ===========================================================================

@test "broken OMP link: never-clobbered by onboard alone, re-seeded after rm" {
  build_canonical_tree
  build_healthy_project
  write_config
  run_onboard "$PROJECTS/healthy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local hp="$PROJECTS/healthy"
  # Simulate a broken link — dangling, pointing at an old machine path.
  rm -f "$hp/.omp/skills"
  ln -s "/opt/old-machine/trellis/core-rules/skills" "$hp/.omp/skills"

  run_onboard "$hp"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # onboard alone never clobbers: the broken link is left, with a WARN.
  [ "$(readlink "$hp/.omp/skills")" = "/opt/old-machine/trellis/core-rules/skills" ]
  [[ "$output" == *"leaving as-is"* ]]

  # Existing repair policy (doctor --fix): rm the broken link, then onboard
  # re-seeds the exact OMP link.
  rm -f "$hp/.omp/skills"
  run_onboard "$hp"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$hp/.omp/skills" ]
  [ "$(readlink "$hp/.omp/skills")" = "$CANON/core-rules/skills" ]
  [ -d "$hp/.omp/skills" ]
}

# ===========================================================================
# 6. Whole-directory links are live: new canonical entries appear through them
#    without re-running onboarding.
# ===========================================================================

@test "new canonical entries appear through the OMP directory links without re-onboarding" {
  build_canonical_tree
  build_healthy_project
  write_config
  run_onboard "$PROJECTS/healthy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local hp="$PROJECTS/healthy"
  # Add a new canonical skill, command, agent, and adapter AFTER onboarding.
  mkdir -p "$CANON/core-rules/skills/new-skill"
  printf 'name: new-skill\ndescription: fixture\n' \
    > "$CANON/core-rules/skills/new-skill/SKILL.md"
  printf 'x\n' > "$CANON/core-rules/commands/new-command.md"
  printf -- '---\nname: new-agent\ndescription: fixture\n---\n' \
    > "$CANON/core-rules/agents/new-agent.md"
  mkdir -p "$CANON/core-rules/omp/hooks/pre"
  printf 'export default {};\n' > "$CANON/core-rules/omp/hooks/pre/trellis.ts"

  # Visible through the directory links — no re-onboarding, no new symlinks.
  [ -f "$hp/.omp/skills/new-skill/SKILL.md" ]
  [ -f "$hp/.omp/commands/new-command.md" ]
  [ -f "$hp/.omp/agents/new-agent.md" ]
  [ -f "$hp/.omp/hooks/pre/trellis.ts" ]

  # The .omp surface is still exactly five symlinks (nothing re-seeded).
  [ "$(find "$hp/.omp" -maxdepth 1 -type l | wc -l | tr -d ' ')" = "5" ]
}

# ===========================================================================
# 7. OMP is Trellis's third harness: enabled explicitly, isolated otherwise.
# ===========================================================================

@test "OMP surface is gated by the omp harness without changing Claude or Codex" {
  build_canonical_tree
  build_healthy_project
  rm -rf "$CANON/core-rules/agents" "$CANON/core-rules/omp"
  write_config '"claude","codex"'

  run_onboard "$PROJECTS/healthy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local hp="$PROJECTS/healthy"
  [ ! -e "$hp/.omp" ]

  # Both established harnesses retain their normal inheritance surfaces even
  # when the OMP-only canonical directories do not exist.
  [ -L "$hp/.claude/rules/trellis.md" ]
  [ -L "$hp/.claude/skills/process-gate" ]
  [ -f "$hp/.claude/settings.json" ]
  [ -L "$hp/AGENTS.md" ]
  [ -L "$hp/.agents/rules/trellis.md" ]
  [ -d "$hp/.codex/hooks" ]
}

@test "OMP-enabled onboarding seeds its five native harness links" {
  build_canonical_tree
  build_healthy_project
  write_config '"omp"'

  run_onboard "$PROJECTS/healthy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local hp="$PROJECTS/healthy"
  [ -L "$hp/.omp/AGENTS.md" ]
  [ "$(readlink "$hp/.omp/AGENTS.md")" = "$hp/CLAUDE.md" ]
  [ -L "$hp/.omp/skills" ]
  [ -L "$hp/.omp/commands" ]
  [ -L "$hp/.omp/agents" ]
  [ -L "$hp/.omp/hooks" ]
}

# ===========================================================================
# 8. Control plane: when PROJECT IS the canonical clone and the root CLAUDE.md
#    is absent, .omp/AGENTS.md targets core-rules/CLAUDE.md. A project that
#    carries its own root CLAUDE.md (the public-mirror shape: onboarded from
#    the private clone) keeps <project>/CLAUDE.md while the other four links
#    still point at the canonical core-rules — covered by test 1.
# ===========================================================================

@test "control-plane: canonical clone without root CLAUDE.md targets core-rules/CLAUDE.md" {
  build_canonical_tree
  git_init_canonical_main
  write_config

  # Precondition: the canonical clone has no root CLAUDE.md (rules live in
  # core-rules/CLAUDE.md).
  [ ! -f "$CANON/CLAUDE.md" ]

  run_onboard "$CANON"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ -L "$CANON/.omp/AGENTS.md" ]
  [ "$(readlink "$CANON/.omp/AGENTS.md")" = "$CANON/core-rules/CLAUDE.md" ]
  [ -e "$CANON/.omp/AGENTS.md" ]
  # The other four links still target canonical core-rules.
  [ "$(readlink "$CANON/.omp/skills")" = "$CANON/core-rules/skills" ]
  [ "$(readlink "$CANON/.omp/commands")" = "$CANON/core-rules/commands" ]
  [ "$(readlink "$CANON/.omp/agents")" = "$CANON/core-rules/agents" ]
  [ "$(readlink "$CANON/.omp/hooks")" = "$CANON/core-rules/omp/hooks" ]
}

# ===========================================================================
# 9. Obsolete custom-agent cleanup: symlinks (incl. dangling) and byte-
#    identical legacy copies are removed; divergent regular files are left
#    with a WARN. Nothing is re-seeded.
# ===========================================================================

@test "obsolete agent artifacts: symlinks + byte-identical copies removed, divergent user files left with WARN" {
  build_canonical_tree
  build_healthy_project
  write_config

  local hp="$PROJECTS/healthy"
  mkdir -p "$hp/.claude/agents" "$hp/.omp/agents"

  # (a) Trellis-owned legacy symlinks — dangling old-machine targets included.
  ln -s "/opt/old-machine/trellis/core-rules/agents/codex-worker.md" \
    "$hp/.claude/agents/codex-worker.md"
  ln -s "/opt/old-machine/trellis/core-rules/agents/lane-worker.md" \
    "$hp/.omp/agents/lane-worker.md"
  # (b) byte-identical legacy copy — the pre-purge canonical file still exists
  # in the fixture canonical, so the cmp-based removal branch is exercised.
  mkdir -p "$CANON/core-rules/agents"
  printf '# legacy trellis agent\n' > "$CANON/core-rules/agents/fable-advisor.md"
  cp "$CANON/core-rules/agents/fable-advisor.md" "$hp/.claude/agents/fable-advisor.md"
  # (c) divergent regular file — user content, must be left with a WARN.
  printf '# user-owned divergent agent\n' > "$hp/.claude/agents/opus-advisor.md"

  run_onboard "$hp"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Symlinks removed (from both surfaces).
  [ ! -e "$hp/.claude/agents/codex-worker.md" ]
  [ ! -L "$hp/.claude/agents/codex-worker.md" ]
  [ ! -e "$hp/.omp/agents/lane-worker.md" ]
  # Byte-identical copy removed; the canonical source is untouched.
  [ ! -e "$hp/.claude/agents/fable-advisor.md" ]
  [ -f "$CANON/core-rules/agents/fable-advisor.md" ]
  # Divergent user file left byte-identical, with a WARN.
  [ -f "$hp/.claude/agents/opus-advisor.md" ]
  [ "$(cat "$hp/.claude/agents/opus-advisor.md")" = "# user-owned divergent agent" ]
  [[ "$output" == *"removed (obsolete agent"* ]]
  [[ "$output" == *"leaving as-is"* ]]
  # Nothing was re-seeded: only the explicitly preserved divergent user file
  # remains under .claude/agents; .omp/agents has no regular files.
  [ "$(find "$hp/.claude/agents" -type f 2>/dev/null | wc -l | tr -d ' ')" = "1" ]
  [ -f "$hp/.claude/agents/opus-advisor.md" ]
  [ "$(find "$hp/.omp/agents" -type f 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}
