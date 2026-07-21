#!/usr/bin/env bats
# Tests for scripts/lib/mirror-lint.sh — lint_mirror — and the DELIST_PRUNE
# git-rm mechanic used by sync-to-template.sh (Workstream D, RC.5).
#
# FULLY ISOLATED — every test builds its own mirror fixture in a mktemp dir.
# Path-leak tokens passed to lint_mirror are FAKE sentinels, never real config
# values, so nothing real leaks into the public mirror via this test.

# shellcheck source=../lib/mirror-lint.sh
source "$BATS_TEST_DIRNAME/../lib/mirror-lint.sh"

# Fake sentinel path tokens (stand in for trellis_root / projects_root /
# user_home). Not real paths — just unique fixed strings the lint greps for.
TR="/SENTINEL/instance/root"
PR="/SENTINEL/projects/root"
UH="/SENTINEL/home"

setup() {
  M="$(mktemp -d)"
  M="$(cd "$M" && pwd -P)"
}

teardown() {
  [ -n "${M:-}" ] && [ -d "$M" ] && rm -rf "$M"
}

# --------------------------------------------------------------------------
@test "clean mirror: rc 0, no output" {
  printf 'Trellis public template. Maintained by a human.\n' > "$M/README.md"
  mkdir -p "$M/docs/adr"
  printf 'ADR: antigravity was the third harness, now superseded.\n' > "$M/docs/adr/0001-x.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "only the public ledger bootstrap is allowed in the audits namespace" {
  mkdir -p "$M/audits"
  printf '{"schema_version":1,"audit_date":"2026-07-21","source_reports":[],"findings":[]}\n' > "$M/audits/fleet-remediation-ledger.json"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf 'private finding\n' > "$M/audits/report.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"audits/report.md: private namespace must not publish"* ]]
}

@test "public operator docs cannot claim a de-listed scheduled-task fleet" {
  printf 'Includes a fleet of 16 scheduled audits under scheduled-tasks/.\n' > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md: claims de-listed scheduled-task content"* ]]
}

@test "public architecture visual cannot claim a numbered scheduled-task fleet" {
  mkdir -p "$M/docs"
  printf '<text>Scheduled Audit Fleet — 16 running + 2 drafted</text>\n' > "$M/docs/architecture.svg"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/architecture.svg: claims de-listed scheduled-task content"* ]]
}

@test "synced current manuals cannot link the private scheduled-task subtree" {
  printf 'Run the shipped job from scheduled-tasks/example/prompt.md.\n' > "$M/engineering-process.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"engineering-process.md: claims de-listed scheduled-task content"* ]]
}

@test "public operator surfaces cannot promise an unshipped audit cadence" {
  printf 'Enforced by hooks. Audited weekly.\n' > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md: claims de-listed scheduled-task content"* ]]
}

@test "public operator surfaces cannot claim a numbered running audit registry" {
  printf '18 audits are registered and running.\n' > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md: claims de-listed scheduled-task content"* ]]
}

@test "every current public onboarding and config surface rejects the private scheduler MCP" {
  local rel
  for rel in \
    AGENT_ONBOARD_PROJECT.md registry.md blacklist.md docs/PROVENANCE.md \
    examples/README.md core-rules/templates/trellis.config.json.example \
    core-rules/commands/doctor.md core-rules/commands/disk-janitor.md \
    scripts/lib/trellis.config.schema.json; do
    mkdir -p "$M/$(dirname "$rel")"
    printf 'Invoke mcp__scheduled-tasks__create_scheduled_task.\n' > "$M/$rel"
    run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$rel: claims de-listed scheduled-task content"* ]]
    rm -f "$M/$rel"
  done
}

@test "absolute-path leak in README: flagged, rc 1" {
  printf 'clone from %s and go\n' "$TR" > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md: absolute-path leak"* ]]
}

@test "user-home leak anywhere: flagged" {
  mkdir -p "$M/docs"
  printf 'path %s/foo\n' "$UH" > "$M/docs/SETUP.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/SETUP.md: absolute-path leak"* ]]
}

@test "antigravity in operator surface (README): flagged, rc 1" {
  printf 'Enable antigravity mode to start.\n' > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md: stale 'antigravity'"* ]]
}

@test "antigravity in docs/adr (historical): NOT flagged" {
  mkdir -p "$M/docs/adr"
  printf 'The antigravity harness (superseded).\n' > "$M/docs/adr/0002-antigravity.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "antigravity in CHANGELOG (historical): NOT flagged" {
  printf '## [rc.4]\n- Removed: AntiGravity harness support.\n' > "$M/CHANGELOG.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 0 ]
}

@test "antigravity in the removal tooling files (exact allowlist): NOT flagged" {
  mkdir -p "$M/scripts/lib"
  printf 'DELIST_PRUNE=( docs/antigravity-steering.md )\n' > "$M/scripts/sync-to-template.sh"
  printf '# lint names antigravity\n' > "$M/scripts/lib/mirror-lint.sh"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 0 ]
}

@test "antigravity in a synced OPERATOR script (onboard): flagged (narrowed exemption)" {
  mkdir -p "$M/scripts"
  printf 'echo "enable antigravity harness"\n' > "$M/scripts/onboard-project.sh"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/onboard-project.sh: stale 'antigravity'"* ]]
}

@test "symlink target leaking an absolute path: flagged" {
  mkdir -p "$M/core-rules"
  ln -s "$TR/core-rules/CLAUDE.md" "$M/core-rules/CLAUDE.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink target leaks absolute path"* ]]
}

@test "absolute home path for an unknown operator is flagged" {
  mkdir -p "$M/docs"
  printf '/%s/%s/private/project\n' Users leaked-operator > "$M/docs/setup.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/setup.md: unrecognized absolute home path"* ]]
}

@test "generic and cross-machine regression users remain valid public fixtures" {
  printf 'Examples: /Users/jane/project /Users/me/project /Users/helios/old /home/jane/project\n' > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allowed example does not hide an unknown home path on the same line" {
  local leaked_path leaked_user
  leaked_user="leaked-operator"
  # Assemble forbidden fixtures at runtime so this public regression test does
  # not itself contain a literal operator home path that mirror-lint must flag.
  for leaked_path in "/Users/${leaked_user}/private" "/home/${leaked_user}/private"; do
    printf 'Example: /Users/jane/project; leaked checkout: %s\n' "$leaked_path" > "$M/README.md"
    run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"README.md: unrecognized absolute home path"* ]]
  done
}

@test "antigravity in a live core-rules doc: flagged (operator surface)" {
  mkdir -p "$M/core-rules/skills/foo"
  printf 'Use the antigravity harness for X.\n' > "$M/core-rules/skills/foo/SKILL.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"core-rules/skills/foo/SKILL.md: stale 'antigravity'"* ]]
}

@test "attribution + clone URLs are NOT denylisted (legit public content)" {
  # lint_mirror has no maintainer/github token — arbitrary attribution and
  # clone-URL text must pass. Fake names on purpose: real config values in a
  # synced .bats trip the sync's own leak guard (they must be placeholders in
  # synced files; only unsynced public-only files may carry the real values).
  printf 'Maintained by Jane Maintainer. Clone github.com/example-user/trellis.\n' > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "case-insensitive: AntiGravity in README flagged" {
  printf 'AntiGravity is great.\n' > "$M/README.md"
  run lint_mirror "$M" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 1 ]
}

@test "not a directory: rc 2" {
  run lint_mirror "$M/nope" "$TR" "$TR" "$PR" "$UH"
  [ "$status" -eq 2 ]
}

# --- DELIST_PRUNE mechanic (D2) -------------------------------------------
# Replicates the sync-to-template.sh prune step: git rm --ignore-unmatch a
# de-listed path while preserving legit public-only files (README).
@test "DELIST_PRUNE: git rm removes listed path, preserves README" {
  git -C "$M" init -q
  git -C "$M" config user.email t@t.io
  git -C "$M" config user.name t
  mkdir -p "$M/docs"
  printf 'stale steering\n' > "$M/docs/antigravity-steering.md"
  printf 'real readme\n' > "$M/README.md"
  git -C "$M" add -A && git -C "$M" commit -qm seed

  git -C "$M" rm -rf --ignore-unmatch --quiet -- "docs/antigravity-steering.md"
  [ ! -e "$M/docs/antigravity-steering.md" ]
  [ -e "$M/README.md" ]
}

@test "DELIST_PRUNE: --ignore-unmatch is a no-op on an already-absent path" {
  git -C "$M" init -q
  git -C "$M" config user.email t@t.io
  git -C "$M" config user.name t
  printf 'x\n' > "$M/README.md"
  git -C "$M" add -A && git -C "$M" commit -qm seed
  run git -C "$M" rm -rf --ignore-unmatch --quiet -- "docs/gone.md"
  [ "$status" -eq 0 ]
  [ -e "$M/README.md" ]
}

@test "prune path-safety: the deny-case rejects unsafe entries, allows real paths" {
  # Mirrors the guard in sync-to-template.sh so a typo'd DELIST_PRUNE entry can
  # never reach the destructive rm (empty / . / .. / absolute / ~ / any ..).
  is_unsafe() { case "$1" in ""|"."|".."|/*|"~"*|*..*) return 0 ;; *) return 1 ;; esac; }
  local bad
  for bad in "" "." ".." "/etc/passwd" "~/x" "a/../b" "../x" "x/.."; do
    is_unsafe "$bad" || { echo "should be UNSAFE but passed: '$bad'"; false; }
  done
  local ok
  for ok in "docs/antigravity-steering.md" "docs/gpt-5.5-steering.md" "a/b/c.md"; do
    ! is_unsafe "$ok" || { echo "should be SAFE but rejected: '$ok'"; false; }
  done
}
