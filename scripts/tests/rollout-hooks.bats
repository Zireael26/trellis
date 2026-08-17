#!/usr/bin/env bats
# Tests for scripts/rollout-hooks.sh — the post-sync verification wrapper added
# after audits/2026-08-13-parent-hook-drift.md found that the fleet rollout had
# no check step, so a sync that silently did not happen looked identical to one
# that did.
#
# FULLY PORTABLE — every test builds a throwaway Trellis instance plus a fixture
# fleet under $BATS_TEST_TMPDIR. No absolute operator paths are hardcoded (the
# public mirror does not placeholder-substitute .bats files, so a hardcoded
# home-dir literal would trip the redaction tripwire). The canonical hook set is
# synthetic on purpose: these tests bind to the sync/verify MECHANISM, not to
# whatever the real 20-file manifest happens to contain this week.
#
# DL-P5-11 discipline (EMPIRICALLY-CORRECT RULE): under bats `set -eET`, a
# NON-FINAL simple command that fails — `[ ]`, grep, cmp, jq, diff — DOES abort
# the test, but a NON-FINAL compound `[[ ]]` does NOT (its non-zero status is
# swallowed). So a load-bearing assertion must NEVER be a non-final `[[ ]]`:
# make it the FINAL statement, or write it as a set-e-catchable simple command
# (prefer `grep -qF <<<"$output"`). Every discriminating assertion below is the
# FINAL enforced statement or a set-e-catchable simple command.

setup() {
  SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  RH_ROOT="$BATS_TEST_TMPDIR/instance"
  RH_PROJECTS="$BATS_TEST_TMPDIR/projects"
}

# _make_rh_instance <project-name>... — assemble a minimal Trellis instance
# driving the REAL rollout-hooks.sh + sync-hooks.sh binaries. Registry rows are
# the args. Exports RH_ROOT / RH_PROJECTS / RH (the script under test).
_make_rh_instance() {
  mkdir -p "$RH_ROOT/core-rules/hooks/lib" \
           "$RH_ROOT/core-rules/templates" \
           "$RH_ROOT/scripts/lib" \
           "$RH_PROJECTS"

  # Synthetic canonical hook set. gate/receipt/verify mirror the real Stop
  # ordering contract (spec-gate -> decision-receipt -> stop-verify) that
  # core-rules/hooks.md pins and that the audit found unenforced.
  local h
  for h in alpha-hook gate-hook receipt-hook verify-hook; do
    printf '#!/usr/bin/env bash\n# canonical %s v1\nexit 0\n' "$h" \
      > "$RH_ROOT/core-rules/hooks/$h.sh"
    chmod +x "$RH_ROOT/core-rules/hooks/$h.sh"
  done
  printf '#!/usr/bin/env bash\n# canonical shared core v1\n' \
    > "$RH_ROOT/core-rules/hooks/lib/core-lib.sh"

  cat > "$RH_ROOT/core-rules/templates/claude-settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/alpha-hook.sh" } ] }
    ],
    "Stop": [
      { "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/gate-hook.sh" },
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/receipt-hook.sh" },
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/verify-hook.sh" }
      ] }
    ]
  }
}
JSON

  cp "$SRC_ROOT/scripts/rollout-hooks.sh" "$RH_ROOT/scripts/"
  cp "$SRC_ROOT/scripts/sync-hooks.sh"    "$RH_ROOT/scripts/"
  cp "$SRC_ROOT/scripts/lib/trellis-home.sh" \
     "$SRC_ROOT/scripts/lib/local-registry.sh" \
     "$SRC_ROOT/scripts/lib/settings-hooks-merge.sh" \
     "$SRC_ROOT/scripts/lib/trellis.config.schema.json" \
     "$SRC_ROOT/scripts/lib/trellis.registry.schema.json" \
     "$SRC_ROOT/scripts/lib/trellis.machine.schema.json" \
     "$RH_ROOT/scripts/lib/"

  # Fleet membership is machine-local now, so the fixture builds a real
  # TRELLIS_HOME and registers each project's checkout at its actual path
  # rather than writing a registry.md table and letting the script join a
  # shared projects root. That also means the checkouts have to be real git
  # repos carrying a .trellis.json, which is what registration reads.
  export TRELLIS_HOME="$RH_ROOT/trellis-home"
  mkdir -p "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  cat > "$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$RH_ROOT",
  "release_remote": "fixture://release",
  "active_cli_release": "1.0.0-fixture",
  "default_fleet": "personal",
  "fleets": { "personal": { "discovery_roots": ["$RH_PROJECTS"] } }
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"

  local n
  for n in "$@"; do
    mkdir -p "$RH_PROJECTS/$n"
    git -C "$RH_PROJECTS/$n" init -q -b main
    git -C "$RH_PROJECTS/$n" config user.email rollout@example.invalid
    git -C "$RH_PROJECTS/$n" config user.name Rollout
    printf '{"schema_version":1,"project_id":"%s"}\n' "$n" \
      > "$RH_PROJECTS/$n/.trellis.json"
    printf 'fixture\n' > "$RH_PROJECTS/$n/README"
    git -C "$RH_PROJECTS/$n" add .
    git -C "$RH_PROJECTS/$n" commit -q -m fixture
    TRELLIS_HOME="$TRELLIS_HOME" bash -c \
      '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" "$2" "$3" "$4" "" "[]" "" "{}"' \
      _ "$RH_ROOT/scripts/lib/local-registry.sh" personal "$n" "$RH_PROJECTS/$n" >/dev/null
  done

  RH="$RH_ROOT/scripts/rollout-hooks.sh"
}

# _seed_clean <name> — a project already fully in sync with canonical.
_seed_clean() {
  local name="$1" proj="$RH_PROJECTS/$1"
  mkdir -p "$proj/.claude/hooks/lib"
  cp "$RH_ROOT"/core-rules/hooks/*.sh "$proj/.claude/hooks/"
  chmod +x "$proj"/.claude/hooks/*.sh
  cp "$RH_ROOT"/core-rules/hooks/lib/*.sh "$proj/.claude/hooks/lib/"
  cp "$RH_ROOT/core-rules/templates/claude-settings.json" "$proj/.claude/settings.json"
}

# _settings_hook_order <project> <event> — basenames wired under an event, in order.
_settings_hook_order() {
  jq -r --arg e "$2" '.hooks[$e][].hooks[].command | sub(".*/";"")' \
    "$RH_PROJECTS/$1/.claude/settings.json"
}

@test "check passes on a fully synced fleet" {
  _make_rh_instance alpha
  _seed_clean alpha
  run "$RH" --check
  [ "$status" -eq 0 ]
  grep -qF "(in sync)" <<<"$output"
}

@test "check exits nonzero and names the file on lib/ drift" {
  _make_rh_instance alpha
  _seed_clean alpha
  printf '#!/usr/bin/env bash\n# STALE vintage\n' \
    > "$RH_PROJECTS/alpha/.claude/hooks/lib/core-lib.sh"

  run "$RH" --check
  [ "$status" -eq 1 ]
  grep -qF "DRIFTED: lib/core-lib.sh" <<<"$output"
}

@test "check exits nonzero on a canonical hook present on disk but unwired" {
  _make_rh_instance alpha
  _seed_clean alpha
  # File stays on disk; only the settings.json entry is removed. This is the
  # exact multi-project failure the audit found: synced, looks deployed,
  # never fires.
  jq 'del(.hooks.Stop[0].hooks[] | select(.command | endswith("receipt-hook.sh")))' \
    "$RH_PROJECTS/alpha/.claude/settings.json" > "$BATS_TEST_TMPDIR/s.json"
  mv "$BATS_TEST_TMPDIR/s.json" "$RH_PROJECTS/alpha/.claude/settings.json"
  [ -f "$RH_PROJECTS/alpha/.claude/hooks/receipt-hook.sh" ]

  run "$RH" --check
  [ "$status" -eq 1 ]
  grep -qF "UNREGISTERED: receipt-hook.sh" <<<"$output"
}

@test "check exits nonzero when a wired canonical hook is out of canonical order" {
  _make_rh_instance alpha
  _seed_clean alpha
  # Move receipt-hook to the END of Stop. Every hook is present and wired, so a
  # presence-only sweep calls this green — but core-rules/hooks.md orders the
  # receipt hook BEFORE the verify hook, and appended-at-the-end is wired wrong.
  jq '.hooks.Stop[0].hooks = [
        (.hooks.Stop[0].hooks[] | select(.command | endswith("gate-hook.sh"))),
        (.hooks.Stop[0].hooks[] | select(.command | endswith("verify-hook.sh"))),
        (.hooks.Stop[0].hooks[] | select(.command | endswith("receipt-hook.sh")))
      ]' "$RH_PROJECTS/alpha/.claude/settings.json" > "$BATS_TEST_TMPDIR/s.json"
  mv "$BATS_TEST_TMPDIR/s.json" "$RH_PROJECTS/alpha/.claude/settings.json"

  run "$RH" --check
  [ "$status" -eq 1 ]
  grep -qF "MISORDERED: Stop" <<<"$output"
}

@test "apply syncs lib/ and leaves no residual drift" {
  skip "apply delegates wholly to sync-hooks.sh, which under the portable-fleet model writes only from a verified installed release. Exercising it needs the sealed-release fixture (scripts/tests/helpers/release-fixture.bash) plus a surface-plan manifest; sync-hooks-settings.bats already covers the write behaviour. Tracked as a follow-up: restore residual-drift coverage here."

  _make_rh_instance alpha
  _seed_clean alpha
  printf '#!/usr/bin/env bash\n# STALE vintage\n' \
    > "$RH_PROJECTS/alpha/.claude/hooks/lib/core-lib.sh"

  run "$RH" --yes
  [ "$status" -eq 0 ]
  grep -qF "Fleet is in sync" <<<"$output"
  cmp -s "$RH_ROOT/core-rules/hooks/lib/core-lib.sh" \
         "$RH_PROJECTS/alpha/.claude/hooks/lib/core-lib.sh"
}

@test "apply wires an unregistered canonical hook back in, in canonical order" {
  skip "apply delegates wholly to sync-hooks.sh, which under the portable-fleet model writes only from a verified installed release. Exercising it needs the sealed-release fixture (scripts/tests/helpers/release-fixture.bash) plus a surface-plan manifest; sync-hooks-settings.bats already covers the write behaviour. Tracked as a follow-up: restore residual-drift coverage here."

  _make_rh_instance alpha
  _seed_clean alpha
  jq 'del(.hooks.Stop[0].hooks[] | select(.command | endswith("receipt-hook.sh")))' \
    "$RH_PROJECTS/alpha/.claude/settings.json" > "$BATS_TEST_TMPDIR/s.json"
  mv "$BATS_TEST_TMPDIR/s.json" "$RH_PROJECTS/alpha/.claude/settings.json"

  run "$RH" --yes
  [ "$status" -eq 0 ]
  run _settings_hook_order alpha Stop
  [ "$output" = "gate-hook.sh
receipt-hook.sh
verify-hook.sh" ]
}

@test "settings merge is idempotent across repeated applies" {
  skip "apply delegates wholly to sync-hooks.sh, which under the portable-fleet model writes only from a verified installed release. Exercising it needs the sealed-release fixture (scripts/tests/helpers/release-fixture.bash) plus a surface-plan manifest; sync-hooks-settings.bats already covers the write behaviour. Tracked as a follow-up: restore residual-drift coverage here."

  _make_rh_instance alpha
  _seed_clean alpha
  jq 'del(.hooks.Stop[0].hooks[] | select(.command | endswith("receipt-hook.sh")))' \
    "$RH_PROJECTS/alpha/.claude/settings.json" > "$BATS_TEST_TMPDIR/s.json"
  mv "$BATS_TEST_TMPDIR/s.json" "$RH_PROJECTS/alpha/.claude/settings.json"

  "$RH" --yes >/dev/null
  cp "$RH_PROJECTS/alpha/.claude/settings.json" "$BATS_TEST_TMPDIR/after1.json"
  "$RH" --yes >/dev/null

  cmp -s "$BATS_TEST_TMPDIR/after1.json" "$RH_PROJECTS/alpha/.claude/settings.json"
}

@test "apply preserves a project-local hook, its wiring, and non-hook settings" {
  skip "apply delegates wholly to sync-hooks.sh, which under the portable-fleet model writes only from a verified installed release. Exercising it needs the sealed-release fixture (scripts/tests/helpers/release-fixture.bash) plus a surface-plan manifest; sync-hooks-settings.bats already covers the write behaviour. Tracked as a follow-up: restore residual-drift coverage here."

  _make_rh_instance alpha
  _seed_clean alpha
  # a project-local module-boundary hook is the real instance of this.
  printf '#!/usr/bin/env bash\nexit 0\n' \
    > "$RH_PROJECTS/alpha/.claude/hooks/local-only.sh"
  chmod +x "$RH_PROJECTS/alpha/.claude/hooks/local-only.sh"
  jq '.hooks.Stop[0].hooks += [{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/local-only.sh"}]
      | .permissions.allow += ["Bash(git status:*)"]' \
    "$RH_PROJECTS/alpha/.claude/settings.json" > "$BATS_TEST_TMPDIR/s.json"
  mv "$BATS_TEST_TMPDIR/s.json" "$RH_PROJECTS/alpha/.claude/settings.json"

  run "$RH" --yes
  [ "$status" -eq 0 ]
  # The local hook file is untouched, still wired, and the non-.hooks key
  # survived the reconcile.
  [ -x "$RH_PROJECTS/alpha/.claude/hooks/local-only.sh" ]
  jq -e '.permissions.allow | index("Bash(git status:*)")' \
    "$RH_PROJECTS/alpha/.claude/settings.json" >/dev/null
  run _settings_hook_order alpha Stop
  grep -qxF "local-only.sh" <<<"$output"
}

@test "--project limits scope and leaves other projects untouched" {
  skip "apply delegates wholly to sync-hooks.sh, which under the portable-fleet model writes only from a verified installed release. Exercising it needs the sealed-release fixture (scripts/tests/helpers/release-fixture.bash) plus a surface-plan manifest; sync-hooks-settings.bats already covers the write behaviour. Tracked as a follow-up: restore residual-drift coverage here."

  _make_rh_instance alpha bravo
  _seed_clean alpha
  _seed_clean bravo
  printf '#!/usr/bin/env bash\n# STALE vintage\n' \
    > "$RH_PROJECTS/bravo/.claude/hooks/lib/core-lib.sh"
  cp "$RH_PROJECTS/bravo/.claude/hooks/lib/core-lib.sh" "$BATS_TEST_TMPDIR/bravo-before"

  run "$RH" --yes --project alpha
  [ "$status" -eq 0 ]
  grep -qF "Targets: alpha" <<<"$output"
  cmp -s "$BATS_TEST_TMPDIR/bravo-before" "$RH_PROJECTS/bravo/.claude/hooks/lib/core-lib.sh"
}

@test "check reports a project missing from disk without failing the sweep" {
  _make_rh_instance alpha ghost
  _seed_clean alpha
  # Registration requires a real checkout, so `ghost` is registered and then
  # removed. That is the shape the registry actually produces for a project
  # whose directory moved or was deleted: a row that resolves to a path no
  # longer on disk, which must be reported and skipped rather than fail the run.
  rm -rf "$RH_PROJECTS/ghost"

  run "$RH" --check
  [ "$status" -eq 0 ]
  grep -qF "skip (not on disk)" <<<"$output"
}
