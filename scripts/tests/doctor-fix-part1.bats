#!/usr/bin/env bats
# Split from doctor-fix.bats: part 1 of 4.
load doctor-fix-common

@test "portable doctor --help keeps the user surface report-only" {
  run env -u TRELLIS_CONFIG HOME="$FIXTURE_HOME" TRELLIS_HOME="$FIXTURE_TRELLIS_HOME" \
    bash "$DOCTOR" --home "$FIXTURE_TRELLIS_HOME" --help

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"--fix repairs only safe project attachment rows through attach/relink/recover;"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"the user-surface row is report-only and prints an attach/relink remedy."* ]] ||
    { echo "$output"; false; }
}

@test "--dry-run without --fix is rejected (exit 2)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"--dry-run is only valid with --fix"* ]] || { echo "$output"; false; }
}

@test "--fix --dry-run on a drifted fixture: prints the migration plan AND leaves the fixture byte/link-identical" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Stale/wrong-target rules symlink (incident #1 shape).
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"

  local before after
  before="$(snapshot_project "$PROJECTS/healthy")"

  run_doctor --fix --dry-run
  [ "$status" -eq 0 ]
  # The plan names the broken surface and the migration that owns it.
  [[ "$output" == *"[manual] stale/wrong rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" == *"nothing applied"* ]] || { echo "$output"; false; }
  # The removed writers must not be advertised in any spelling.
  [[ "$output" != *"[auto]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"onboard-project.sh"* ]] || { echo "$output"; false; }

  after="$(snapshot_project "$PROJECTS/healthy")"
  # READ-ONLY oracle: byte-for-byte + symlink-target identical before vs after.
  [ "$before" = "$after" ]
  # The bad symlink in particular was NOT touched.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" ]
}

@test "--fix diagnoses inheritance without proposing registering reconciling or changing shared allocations" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  local before
  before="$(sha_of "$SHARED/projects.yaml")"

  run_doctor --fix
  # The missing rules symlink is now an unrepaired ERROR, so the run is non-zero.
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [ "$(sha_of "$SHARED/projects.yaml")" = "$before" ]
  # Doctor did NOT re-seed it — that is the migration's job now.
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  grep -q '^doctor ' "$SHARED/calls.log"
  [ ! -e "$PROJECTS/healthy/scripts/local-infra-preflight.sh" ]
  [[ "$output" == *"[manual] missing rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
  run grep -Eq '^(propose|register|reconcile|preflight) ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
}

@test "shared infrastructure drift stays an ERROR and does not suppress unrelated inheritance diagnosis" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"
  printf 'deliberate drift\n' > "$SHARED/drift"
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  local before
  before="$(sha_of "$SHARED/projects.yaml")"

  run_doctor --fix
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ shared-infra doctor: read-only checks failed"* ]] || { echo "$output"; false; }
  # A failing shared-infra row must not swallow the per-project diagnosis: the
  # unrelated broken symlink is still classified and still names its migration.
  [[ "$output" == *"[manual] missing rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ "$(sha_of "$SHARED/projects.yaml")" = "$before" ]
  run grep -Eq '^(propose|register|reconcile|preflight) ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
}

@test "--fix on a MISSING rules symlink: nothing is re-seeded; the row stays ERROR and names its migration" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]

  run_doctor --fix
  # Unrepaired ERROR — the cutover removed every writer that could seed this.
  [ "$status" -ne 0 ]
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [[ "$output" == *"legacy direct-link repair was removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis attach --fleet NAME \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  # The AFTER-pass re-check still runs and still surfaces the row as broken.
  [[ "$output" == *"re-checking healthy after fixes"* ]] || { echo "$output"; false; }
  [[ "${output##*re-checking healthy after fixes}" == *"rules:"* ]] || { echo "$output"; false; }
  [[ "${output##*re-checking healthy after fixes}" != *"✓ rules: trellis.md resolves to canonical"* ]] \
    || { echo "$output"; false; }
}

@test "--fix on a STALE/wrong-target rules symlink: the bad link is never rm'd, and the migration is reported" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"
  # Pre-condition: the bad link does NOT resolve.
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]

  run_doctor --fix
  [ "$status" -ne 0 ]
  # No rm is planned or performed, in any spelling.
  [[ "$output" != *"[auto] rm "* ]] || { echo "$output"; false; }
  # The known-bad link is byte-identical — still pointing cross-machine.
  [ -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" ]
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [[ "$output" == *"[manual] stale/wrong rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
}

@test "the reported migration quotes a project path containing spaces as one argument" {
  local spaced_root="$SANDBOX/root with spaces"
  CANON="$spaced_root/canonical"
  PROJECTS="$spaced_root/projects"
  CFG="$spaced_root/trellis.config.json"
  export TRELLIS_CONFIG="$CFG"
  mkdir -p "$CANON" "$PROJECTS"

  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/nonexistent/wrong-target.md" \
    "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor --fix

  [ "$status" -ne 0 ] || { echo "$output"; false; }
  # The migration command an operator would paste must survive the spaces.
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis attach --fleet NAME \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  # And the wrong-target link is left exactly as found.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/nonexistent/wrong-target.md" ]
}

@test "hook drift on a legacy project is reported [manual] with the attach remedy; neither --fix nor --fix-hooks delegates to sync-hooks.sh, and the after-pass still surfaces the drift" {
  build_canonical_tree
  add_canonical_hooks            # canonical hooks == worktree hooks
  git_init_canonical_main        # commit AFTER hooks so canonical stays clean
  build_healthy_project
  seed_project_hooks_from_canonical
  write_config

  local bell="$PROJECTS/healthy/.claude/hooks/session-context.sh"
  # Drift exactly one top-level hook so hc_hook_freshness WARNs on it.
  printf '\n# DRIFT MARKER\n' >> "$bell"
  local stale_sha canon_sha
  stale_sha="$(sha_of "$bell")"
  canon_sha="$(sha_of "$CANON/core-rules/hooks/session-context.sh")"
  [ "$stale_sha" != "$canon_sha" ]   # precondition: it really is drifted

  # Also break the rules symlink. Before the cutover this made onboard run, so
  # the case proved onboard never-clobbered the hook. Since the cutover it makes
  # the point more directly: doctor repairs NEITHER surface, and says so.
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"

  # --- plain --fix ---
  run_doctor --fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  # The honest remedy, naming the flow that CAN own hook reconciliation.
  [[ "$output" == *"[manual] Claude hook copies drift from canonical — no engine repairs a legacy direct-link project's hooks; attach it (scripts/attach-project.sh attach \"$PROJECTS/healthy\")"* ]] \
    || { echo "$output"; false; }
  # No [hooks] class, and no promise of a sync-hooks repair, in any spelling.
  [[ "$output" != *"[hooks]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"sync-hooks.sh --yes"* ]] || { echo "$output"; false; }
  [[ "$output" != *"run with --fix-hooks"* ]] || { echo "$output"; false; }
  # The rules symlink was NOT re-seeded...
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  # ...and the drifted hook is byte-for-byte UNCHANGED.
  [ "$(sha_of "$bell")" = "$stale_sha" ]
  [ "$(sha_of "$bell")" != "$canon_sha" ]
  # And the AFTER-pass re-check still surfaces the drift — a [manual] row is
  # reported, never quietly resolved.
  [[ "$output" == *"-- re-checking healthy after fixes --"* ]] || { echo "$output"; false; }
  [[ "${output##*-- re-checking healthy after fixes --}" == *"hooks: drift vs canonical —stale: session-context.sh"* ]] \
    || { echo "$output"; false; }

  # --- --fix --fix-hooks: the flag is accepted and says it is inert. It must
  # NOT resurrect the delegation, and must not touch the hook.
  run_doctor --fix --fix-hooks
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[manual] --fix-hooks is inert:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[hooks]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"sync-hooks.sh --yes"* ]] || { echo "$output"; false; }
  [ "$(sha_of "$bell")" = "$stale_sha" ]
  [ "$(sha_of "$bell")" != "$canon_sha" ]
  [[ "${output##*-- re-checking healthy after fixes --}" == *"hooks: drift vs canonical —stale: session-context.sh"* ]] \
    || { echo "$output"; false; }
}

@test "sync-hooks.sh refuses a legacy direct-link project outright: no local registry to reconcile through, hook bytes untouched" {
  build_canonical_tree
  add_canonical_hooks
  git_init_canonical_main
  build_healthy_project
  seed_project_hooks_from_canonical
  write_config

  local bell="$PROJECTS/healthy/.claude/hooks/session-context.sh"
  printf '\n# DRIFT MARKER\n' >> "$bell"
  local stale_sha
  stale_sha="$(sha_of "$bell")"

  run env -u SHARED_INFRA_ROOT HOME="$FIXTURE_HOME" TRELLIS_HOME="$FIXTURE_TRELLIS_HOME" \
    bash "$REPO_ROOT/scripts/sync-hooks.sh" --yes healthy
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # The specific refusal: there is no registry row to reconcile through,
  # because a legacy direct-link project was never registered/attached at all.
  [[ "$output" == *"sync-hooks.sh: project not in local registry fleet personal: healthy"* ]] \
    || { echo "$output"; false; }
  # Refusal, not partial work: the drifted hook is byte-identical.
  [ "$(sha_of "$bell")" = "$stale_sha" ]
}

@test "--fix on a dead @-import: CLAUDE.md is byte-identical, reported [manual], import still ERROR (non-zero exit)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Dead cross-machine @-import (incident #1's literal shape).
  printf '# Healthy project\n\n@/Users/helios/claude/se-core-template/core-rules/CLAUDE.md\n' \
    > "$PROJECTS/healthy/CLAUDE.md"
  local cm="$PROJECTS/healthy/CLAUDE.md"
  local before_sha
  before_sha="$(sha_of "$cm")"
  # Also break the rules symlink so onboard genuinely runs alongside.
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor --fix
  # Dead @-import is an ERROR and is NOT auto-fixed → the run is non-zero even
  # though the symlink was repaired.
  [ "$status" -ne 0 ]
  # Reported as a [manual] action (never auto-edited).
  [[ "$output" == *"[manual]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"@-import"* ]] || { echo "$output"; false; }
  # Nothing was re-seeded...
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  # ...and the user-owned CLAUDE.md is byte-for-byte UNCHANGED.
  [ "$(sha_of "$cm")" = "$before_sha" ]
  [[ "$output" == *"/Users/helios/"* ]] || { echo "$output"; false; }
  # The import row is still ✗ in the after-pass re-check.
  [[ "$output" == *"✗ import:"* ]] || { echo "$output"; false; }
}

@test "--fix under a Tier-0 ERROR: Tier-0 is reported, the bad symlink is left as-is, non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Break the rules symlink (an [auto]-fixable condition)...
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"
  # ...then push the canonical OFF main so Tier-0 ERRORs.
  ( cd "$CANON" && git checkout -q -b feat/poison )

  run_doctor --fix
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tier-0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Tier-0 is report-only"* ]] || { echo "$output"; false; }
  # The known-bad symlink was NOT touched — still pointing cross-machine.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" ]
}

@test "isolation: --fix --dry-run reports the FIXTURE canonical, never the live clone" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor --fix --dry-run
  [[ "$output" == *"canonical clone: $CANON"* ]] || { echo "$output"; false; }
  [[ -z "$LIVE_CANON" || "$output" != *"$LIVE_CANON"* ]] || { echo "$output"; false; }
}

@test "worktree-inheritance DETECTION: linked worktree missing symlinks => WARN (read-only doctor)" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "missing-wt"

  # Pre-condition: the worktree exists but has no .claude/ directory.
  [ -d "$WT_PATH" ]
  [ ! -d "$WT_PATH/.claude" ]

  run_doctor
  # Doctor WARNs about the missing-inheritance worktree.
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ worktree-inheritance:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"missing inheritance symlinks"* ]] || { echo "$output"; false; }
}

@test "worktree-inheritance DETECTION: all linked worktrees healthy => no WARN" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "healthy-wt"

  # Seed the worktree by hand. The legacy mirror command that used to do this
  # was removed at v1.0.0-rc.25, and its replacement needs local registration
  # this legacy-config fixture deliberately does not have — so the fixture
  # builds the healthy end state directly, by copying every managed link the
  # main checkout carries. Only the DETECTION is under test.
  local wt_link wt_dest
  while IFS= read -r wt_link; do
    [ -n "$wt_link" ] || continue
    wt_dest="$WT_PATH/${wt_link#"$PROJECTS/healthy/"}"
    mkdir -p "$(dirname "$wt_dest")"
    ln -sfn "$(readlink "$wt_link")" "$wt_dest"
  done < <(find "$PROJECTS/healthy/.claude" "$PROJECTS/healthy/.agents" \
    -maxdepth 2 -type l 2>/dev/null)

  run_doctor
  # The worktree is healthy — no worktree-inheritance WARN.
  [ "$status" -eq 0 ]
  [[ "$output" != *"⚠ worktree-inheritance:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ worktree-inheritance:"* ]] || { echo "$output"; false; }
}
