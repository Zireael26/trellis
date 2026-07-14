#!/usr/bin/env bats
# Tests for the settings.json .hooks reconcile (Gap A) — the load-bearing merge
# in scripts/lib/settings-hooks-merge.sh (reconcile_settings_hooks), plus the
# sync-hooks.sh integration (missing-settings skip + change-detection write).
#
# FULLY PORTABLE — every test builds its inputs in $BATS_TEST_TMPDIR via mktemp.
# No absolute operator paths are hardcoded (those would leak into the public
# mirror and trip the redaction tripwire; the sync skips .bats substitution).
# The canonical template is the real core-rules/templates/claude-settings.json,
# resolved relative to $BATS_TEST_DIRNAME; the project fixtures are the copied
# neev/akaushik settings under fixtures/ (hook commands use $CLAUDE_PROJECT_DIR
# placeholders, already generic).
#
# DL-P5-11 discipline (EMPIRICALLY-CORRECT RULE): under bats `set -eET`, a
# NON-FINAL simple command that fails — `[ ]`, grep, cmp, jq, diff — DOES abort
# the test, but a NON-FINAL compound `[[ ]]` does NOT (its non-zero status is
# swallowed). So a load-bearing assertion must NEVER be a non-final `[[ ]]`:
# either make it the FINAL statement, or write it as a set-e-catchable simple
# command (prefer `grep -qF <<<"$output"` over `[[ "$output" == *...* ]]`).
# Every load-bearing (post-state) assertion below is the FINAL enforced
# statement or a set-e-catchable simple command.

# shellcheck source=../lib/settings-hooks-merge.sh
source "$BATS_TEST_DIRNAME/../lib/settings-hooks-merge.sh"

setup() {
  CANON="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/core-rules/templates/claude-settings.json"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  SANDBOX="$BATS_TEST_TMPDIR/work"
  mkdir -p "$SANDBOX"
}

# _make_instance — assemble a minimal Trellis instance under $SANDBOX/instance
# with PROJECTS_ROOT at $SANDBOX/projects, exporting ROOT/PROJECTS for the test.
# Copies the real canonical tree + the real script + libs so tests drive the
# ACTUAL sync-hooks.sh binary (the shipping sync_one path), not just the lib.
# Registry rows are passed as args (each "name" -> one Active-projects row).
_make_instance() {
  ROOT="$SANDBOX/instance"
  PROJECTS="$SANDBOX/projects"
  local SRC_ROOT
  SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$ROOT/core-rules/hooks/lib" "$ROOT/core-rules/templates" "$ROOT/scripts/lib" "$PROJECTS"
  cp "$CANON" "$ROOT/core-rules/templates/claude-settings.json"
  cp "$SRC_ROOT"/core-rules/hooks/*.sh "$ROOT/core-rules/hooks/" 2>/dev/null || true
  [ -d "$SRC_ROOT/core-rules/hooks/lib" ] && cp "$SRC_ROOT"/core-rules/hooks/lib/*.sh "$ROOT/core-rules/hooks/lib/" 2>/dev/null || true
  cp "$SRC_ROOT/scripts/sync-hooks.sh" "$ROOT/scripts/sync-hooks.sh"
  cp "$SRC_ROOT/scripts/lib/blacklist-parser.sh" "$ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/config-load.sh" "$ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/settings-hooks-merge.sh" "$ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/trellis.config.schema.json" "$ROOT/scripts/lib/"
  # registry.md Active-projects table, one row per arg.
  {
    printf '%s\n' '## Active projects' '' '| Project | Path | Class | Notes |' '|---|---|---|---|'
    local n
    for n in "$@"; do printf '| %s | `/personal/%s` | x | y |\n' "$n" "$n"; done
    printf '%s\n' '' '---'
  } > "$ROOT/registry.md"
  cat > "$ROOT/trellis.config.json" <<EOF
{
  "trellis_root": "$ROOT",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "testuser",
  "harnesses": ["claude"]
}
EOF
}

# _seed_project <name> <settings-fixture-path|"">  — create a project on disk
# with .claude/hooks/ (+lib) populated from canonical and an optional settings.json.
_seed_project() {
  local name="$1" settings_src="${2:-}"
  mkdir -p "$PROJECTS/$name/.claude/hooks/lib"
  cp "$ROOT"/core-rules/hooks/*.sh "$PROJECTS/$name/.claude/hooks/" 2>/dev/null || true
  [ -d "$ROOT/core-rules/hooks/lib" ] && cp "$ROOT"/core-rules/hooks/lib/*.sh "$PROJECTS/$name/.claude/hooks/lib/" 2>/dev/null || true
  [ -n "$settings_src" ] && cp "$settings_src" "$PROJECTS/$name/.claude/settings.json"
  return 0
}

# ---------------------------------------------------------------------------
# GREENFIELD-N/A: settings.json missing -> sync-hooks reconcile step skips
# with the note, exits 0, and does NOT create settings.json.
# Drives the real sync-hooks.sh on a single project assembled in the sandbox.
# ---------------------------------------------------------------------------
@test "missing settings.json: reconcile skipped with note, file stays absent" {
  # Build a minimal trellis instance: config + registry + canonical tree, and a
  # project that has .claude/hooks/ but NO settings.json.
  ROOT="$SANDBOX/instance"
  PROJECTS="$SANDBOX/projects"
  mkdir -p "$ROOT/core-rules/hooks/lib" "$ROOT/core-rules/templates" "$ROOT/scripts/lib"
  mkdir -p "$PROJECTS/demo/.claude/hooks"

  # Canonical hooks + settings template (copied from the real repo).
  cp "$CANON" "$ROOT/core-rules/templates/claude-settings.json"
  SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cp "$SRC_ROOT"/core-rules/hooks/*.sh "$ROOT/core-rules/hooks/" 2>/dev/null || true
  [ -d "$SRC_ROOT/core-rules/hooks/lib" ] && cp "$SRC_ROOT"/core-rules/hooks/lib/*.sh "$ROOT/core-rules/hooks/lib/" 2>/dev/null || true

  # The script + its libs.
  cp "$SRC_ROOT/scripts/sync-hooks.sh" "$ROOT/scripts/sync-hooks.sh"
  cp "$SRC_ROOT/scripts/lib/blacklist-parser.sh" "$ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/config-load.sh" "$ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/settings-hooks-merge.sh" "$ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/trellis.config.schema.json" "$ROOT/scripts/lib/"

  # registry.md (Active projects table) — one project: demo.
  printf '%s\n' '## Active projects' '' '| Project | Path | Class | Notes |' '|---|---|---|---|' '| demo | `/personal/demo` | x | y |' '' '---' > "$ROOT/registry.md"

  # trellis.config.json pointing at our sandbox roots.
  cat > "$ROOT/trellis.config.json" <<EOF
{
  "trellis_root": "$ROOT",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "testuser",
  "harnesses": ["claude"]
}
EOF

  run env TRELLIS_CONFIG="$ROOT/trellis.config.json" bash "$ROOT/scripts/sync-hooks.sh" --yes demo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # set-e-catchable simple command (NOT a non-final [[ ]], which would not gate).
  grep -qF "settings.json missing" <<<"$output"
  # FINAL load-bearing assertion: settings.json was NOT created.
  [ ! -f "$PROJECTS/demo/.claude/settings.json" ]
}

# ---------------------------------------------------------------------------
# PURE-STALE (akaushik-like): no project-specific hooks -> merged .hooks equals
# canonical .hooks exactly; the 4 new wirings present; permissions.deny
# preserved byte-identical; Stop order == canonical order.
# Each broken out so the discriminating check is the FINAL statement.
# ---------------------------------------------------------------------------
@test "pure-stale: merged .hooks == canonical .hooks (covers 4 wirings + Stop order)" {
  out="$SANDBOX/pure.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/akaushik-settings.json" > "$out"
  # FINAL: a byte-identical (canonicalized) match of .hooks proves every
  # canonical wiring (incl. the 4 added) and the exact Stop order are present.
  diff <(jq -S '.hooks' "$out") <(jq -S '.hooks' "$CANON")
}

@test "pure-stale: the 4 added wirings are present by basename" {
  out="$SANDBOX/pure.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/akaushik-settings.json" > "$out"
  # reread-guard in PreToolUse, track-read in PostToolUse, propose-rules +
  # stamp-turn in Stop — &&-chain ends on stamp-turn (the discriminator).
  jq -e '.hooks.PreToolUse[]|.hooks[].command|select(endswith("reread-guard.sh"))' "$out" >/dev/null \
    && jq -e '.hooks.PostToolUse[]|.hooks[].command|select(endswith("track-read.sh"))' "$out" >/dev/null \
    && jq -e '.hooks.Stop[]|.hooks[].command|select(endswith("propose-rules.sh"))' "$out" >/dev/null \
    && jq -e '.hooks.Stop[]|.hooks[].command|select(endswith("stamp-turn.sh"))' "$out" >/dev/null
}

@test "pure-stale: permissions.deny preserved byte-identical" {
  out="$SANDBOX/pure.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/akaushik-settings.json" > "$out"
  # FINAL: deny array unchanged vs the source fixture.
  diff <(jq -S '.permissions.deny' "$out") <(jq -S '.permissions.deny' "$FIXTURES/akaushik-settings.json")
}

@test "pure-stale: Stop chain order == canonical Stop order" {
  out="$SANDBOX/pure.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/akaushik-settings.json" > "$out"
  # FINAL: ordered list of Stop command basenames equals canonical's.
  diff <(jq -r '.hooks.Stop[].hooks[].command|sub(".*/";"")' "$out") \
       <(jq -r '.hooks.Stop[].hooks[].command|sub(".*/";"")' "$CANON")
}

# ---------------------------------------------------------------------------
# PRESERVING (neev): project-specific PreToolUse block (check-module-boundary,
# matcher Edit|Write) must survive; canonical blocks laid down once.
# RED-GREEN: this is the suite the mutation in Verify must flip RED.
#   * Removing the whole `select(...|not)` clause -> PreToolUse becomes 4 blocks
#     with block-destructive DUPLICATED -> the count==3 assertion flips RED.
#   * Removing only `| not` -> length stays 3 but check-module-boundary is
#     DROPPED -> the "check-module-boundary present" assertion flips RED.
# Both assertions are kept so EITHER mutation is caught.
# ---------------------------------------------------------------------------
@test "preserving: PreToolUse has exactly 3 blocks, no duplicate canonical block" {
  out="$SANDBOX/preserve.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/neev-settings.json" > "$out"
  # block-destructive (canonical Bash block) must appear exactly once.
  bd_count="$(jq '[.hooks.PreToolUse[]|select(.hooks[].command|endswith("block-destructive.sh"))]|length' "$out")"
  total="$(jq '.hooks.PreToolUse|length' "$out")"
  # FINAL &&-chain: total==3 AND block-destructive not duplicated.
  [ "$total" -eq 3 ] && [ "$bd_count" -eq 1 ]
}

@test "preserving: check-module-boundary present with matcher Edit|Write" {
  out="$SANDBOX/preserve.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/neev-settings.json" > "$out"
  # FINAL: the preserved block exists AND carries its original matcher.
  jq -e '.hooks.PreToolUse[]
          | select(.hooks[].command|endswith("check-module-boundary.sh"))
          | select(.matcher=="Edit|Write")' "$out" >/dev/null
}

@test "preserving: canonical reread-guard block present alongside preserved block" {
  out="$SANDBOX/preserve.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/neev-settings.json" > "$out"
  # FINAL: reread-guard (canonical Edit|MultiEdit|Write) wired in.
  jq -e '.hooks.PreToolUse[]
          | select(.hooks[].command|endswith("reread-guard.sh"))
          | select(.matcher=="Edit|MultiEdit|Write")' "$out" >/dev/null
}

@test "preserving: Stop chain == canonical Stop order" {
  out="$SANDBOX/preserve.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/neev-settings.json" > "$out"
  # FINAL: neev's project Stop blocks are all canonical commands -> dropped &
  # replaced by canonical Stop verbatim, in canonical order.
  diff <(jq -r '.hooks.Stop[].hooks[].command|sub(".*/";"")' "$out") \
       <(jq -r '.hooks.Stop[].hooks[].command|sub(".*/";"")' "$CANON")
}

@test "preserving: non-.hooks keys (permissions.deny) untouched" {
  out="$SANDBOX/preserve.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/neev-settings.json" > "$out"
  # FINAL: deny array unchanged vs the neev source fixture.
  diff <(jq -S '.permissions.deny' "$out") <(jq -S '.permissions.deny' "$FIXTURES/neev-settings.json")
}

# ---------------------------------------------------------------------------
# IDEMPOTENT: running the merge twice (2nd run on the 1st output) is a no-op.
# ---------------------------------------------------------------------------
@test "idempotent (neev): 2nd run is byte-identical (canonicalized)" {
  r1="$SANDBOX/r1.json"; r2="$SANDBOX/r2.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/neev-settings.json" > "$r1"
  reconcile_settings_hooks "$CANON" "$r1" > "$r2"
  # FINAL: 2nd run produced no change.
  diff <(jq -S . "$r1") <(jq -S . "$r2")
}

@test "idempotent (neev): 2nd run does not duplicate the preserved block" {
  r1="$SANDBOX/r1.json"; r2="$SANDBOX/r2.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/neev-settings.json" > "$r1"
  reconcile_settings_hooks "$CANON" "$r1" > "$r2"
  cmb="$(jq '[.hooks.PreToolUse[]|select(.hooks[].command|endswith("check-module-boundary.sh"))]|length' "$r2")"
  total="$(jq '.hooks.PreToolUse|length' "$r2")"
  # FINAL: still exactly 3 blocks, check-module-boundary present exactly once.
  [ "$total" -eq 3 ] && [ "$cmb" -eq 1 ]
}

@test "idempotent (akaushik): 2nd run is byte-identical (canonicalized)" {
  r1="$SANDBOX/a1.json"; r2="$SANDBOX/a2.json"
  reconcile_settings_hooks "$CANON" "$FIXTURES/akaushik-settings.json" > "$r1"
  reconcile_settings_hooks "$CANON" "$r1" > "$r2"
  # FINAL.
  diff <(jq -S . "$r1") <(jq -S . "$r2")
}

# ---------------------------------------------------------------------------
# MIXED-BLOCK (Pattern A — entry granularity): a single block carrying BOTH a
# canonical entry (stop-verify) AND a novel entry (my-custom.sh). The block-
# level classifier would drop the whole block (losing my-custom). Entry-level
# must drop only stop-verify (canonical baseline carries it) and KEEP my-custom,
# appended after the canonical Stop block, with NO canonical duplicate.
# RED-GREEN: revert the lib to block-granularity -> my-custom is dropped ->
# the "my-custom present" assertion flips RED.
# ---------------------------------------------------------------------------
@test "mixed-block: novel entry in a canonical Stop block is preserved, no canonical dup" {
  mixed="$SANDBOX/mixed.json"
  cat > "$mixed" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-verify.sh", "timeout": 300 },
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/my-custom.sh", "timeout": 30 }
        ]
      }
    ]
  },
  "permissions": { "deny": [] }
}
JSON
  out="$SANDBOX/mixed-out.json"
  reconcile_settings_hooks "$CANON" "$mixed" > "$out"
  mc="$(jq '[.hooks.Stop[].hooks[].command|select(endswith("my-custom.sh"))]|length' "$out")"
  sv="$(jq '[.hooks.Stop[].hooks[].command|select(endswith("stop-verify.sh"))]|length' "$out")"
  # FINAL &&-chain: my-custom survives exactly once AND stop-verify is not duplicated.
  [ "$mc" -eq 1 ] && [ "$sv" -eq 1 ]
}

@test "mixed-block: canonical Stop entries keep their canonical order (custom appended last)" {
  mixed="$SANDBOX/mixed.json"
  cat > "$mixed" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-verify.sh" },
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/my-custom.sh" }
] } ] } }
JSON
  out="$SANDBOX/mixed-out.json"
  reconcile_settings_hooks "$CANON" "$mixed" > "$out"
  # FINAL: the leading Stop basenames (everything before the appended custom block)
  # equal canonical's Stop order exactly.
  canon_n="$(jq '[.hooks.Stop[].hooks[].command]|length' "$CANON")"
  diff <(jq -r '.hooks.Stop[].hooks[].command|sub(".*/";"")' "$out" | head -n "$canon_n") \
       <(jq -r '.hooks.Stop[].hooks[].command|sub(".*/";"")' "$CANON")
}

@test "mixed-block: idempotent (2nd run on a mixed-block output is byte-identical)" {
  # The mixed case is structurally distinct from neev/akaushik: run 2 reduces a
  # different shape (pruned-canonical block + a separate surviving-novel block).
  # Explicitly on the task's verify list ("...idempotent").
  mixed="$SANDBOX/mixed.json"
  cat > "$mixed" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-verify.sh" },
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/my-custom.sh" }
] } ] }, "permissions": { "deny": [] } }
JSON
  m1="$SANDBOX/m1.json"; m2="$SANDBOX/m2.json"
  reconcile_settings_hooks "$CANON" "$mixed" > "$m1"
  reconcile_settings_hooks "$CANON" "$m1" > "$m2"
  # FINAL: 2nd run changed nothing (novel entry not re-appended, canonical not dup'd).
  diff <(jq -S . "$m1") <(jq -S . "$m2")
}

# ---------------------------------------------------------------------------
# MALFORMED BLOCK missing the .hooks key (Pattern B layer 1): the lib's
# `(.hooks // [])` guard degrades the block to empty (which the
# select((.hooks|length)>0) then prunes) — it must NOT abort and must NOT warn
# (it is a graceful drop, not a hard failure; the WARN path is the binary test
# below for genuinely-unparseable JSON).
# ---------------------------------------------------------------------------
@test "malformed block missing .hooks key: degrades gracefully (no abort), block dropped" {
  bad="$SANDBOX/nohooks.json"
  cat > "$bad" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash" } ] }, "permissions": { "deny": [] } }
JSON
  out="$SANDBOX/nohooks-out.json"
  # reconcile must succeed (exit 0) — capture status as a set-e-catchable command.
  reconcile_settings_hooks "$CANON" "$bad" > "$out"
  # FINAL: PreToolUse equals canonical (the keyless project block contributed
  # nothing — it was dropped, not errored).
  diff <(jq -S '.hooks.PreToolUse' "$out") <(jq -S '.hooks.PreToolUse' "$CANON")
}

# ---------------------------------------------------------------------------
# BINARY / NON-FATAL (Pattern B layer 2): drive the REAL sync-hooks.sh on a
# multi-project instance where the FIRST project's settings.json is genuinely
# unparseable (.hooks is an array -> jq to_entries errors). The run must NOT
# abort: exit 0, WARN on the bad project, and the LATER valid-but-stale project
# is STILL reconciled (the discriminator: reread-guard wired in). Also proves
# the bad project's settings is left untouched (not clobbered).
# ---------------------------------------------------------------------------
@test "binary non-fatal: malformed project warns + run continues + valid project reconciled" {
  _make_instance badproj goodproj
  _seed_project badproj ""
  printf '%s\n' '{ "hooks": [ "broken" ], "permissions": { "deny": [] } }' > "$PROJECTS/badproj/.claude/settings.json"
  _seed_project goodproj "$FIXTURES/akaushik-settings.json"

  run env TRELLIS_CONFIG="$ROOT/trellis.config.json" bash "$ROOT/scripts/sync-hooks.sh" --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "settings reconcile failed" <<<"$output"
  # bad project's settings must be untouched (still the broken array).
  [ "$(jq -c '.hooks' "$PROJECTS/badproj/.claude/settings.json")" = '["broken"]' ]
  # FINAL: the valid project WAS reconciled (reread-guard wired in) — proves the
  # run continued past the malformed project.
  jq -e '.hooks.PreToolUse[]|.hooks[].command|select(endswith("reread-guard.sh"))' "$PROJECTS/goodproj/.claude/settings.json" >/dev/null
}

# ---------------------------------------------------------------------------
# BINARY / REAL WRITE PATH: drive the REAL sync-hooks.sh sync_one settings-
# reconcile WRITE branch (not the lib) on a single stale project, and confirm it
# writes the merged settings back, preserving a mixed-block novel entry.
# ---------------------------------------------------------------------------
@test "binary write path: sync_one reconciles + writes stale settings (mixed novel entry survives)" {
  _make_instance demo
  _seed_project demo ""
  # demo's settings: a mixed Stop block (canonical stop-verify + novel custom.sh).
  cat > "$PROJECTS/demo/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-verify.sh", "timeout": 300 },
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/custom-stop.sh", "timeout": 10 }
        ]
      }
    ]
  },
  "permissions": { "deny": [] }
}
JSON
  run env TRELLIS_CONFIG="$ROOT/trellis.config.json" bash "$ROOT/scripts/sync-hooks.sh" --yes demo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "updating settings.json .hooks" <<<"$output"
  # the canonical PreToolUse baseline was written (reread-guard wired)…
  jq -e '.hooks.PreToolUse[]|.hooks[].command|select(endswith("reread-guard.sh"))' "$PROJECTS/demo/.claude/settings.json" >/dev/null
  # FINAL: …and the mixed-block novel entry survived the real write path.
  jq -e '.hooks.Stop[].hooks[].command|select(endswith("custom-stop.sh"))' "$PROJECTS/demo/.claude/settings.json" >/dev/null
}

# ---------------------------------------------------------------------------
# BINARY / DRY-RUN reaches ALL projects (Pattern C): two stale projects; under
# --dry-run the FIRST one's settings diff returns non-zero, which without the
# `|| true` would abort pipefail+set -e before the second project. Assert the
# run reaches BOTH and writes nothing.
# ---------------------------------------------------------------------------
@test "binary dry-run: multi-project --dry-run reaches all projects, writes nothing" {
  _make_instance one two
  _seed_project one "$FIXTURES/akaushik-settings.json"
  _seed_project two "$FIXTURES/akaushik-settings.json"
  one_before="$(shasum -a 256 "$PROJECTS/one/.claude/settings.json" | awk '{print $1}')"

  run env TRELLIS_CONFIG="$ROOT/trellis.config.json" bash "$ROOT/scripts/sync-hooks.sh" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "== one ==" <<<"$output"
  grep -qF "== two ==" <<<"$output"
  one_after="$(shasum -a 256 "$PROJECTS/one/.claude/settings.json" | awk '{print $1}')"
  # FINAL: dry-run reached both AND wrote nothing (first project unchanged).
  [ "$one_before" = "$one_after" ]
}
