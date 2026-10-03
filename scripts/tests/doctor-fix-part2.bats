#!/usr/bin/env bats
# Split from doctor-fix.bats: part 2 of 4.
load doctor-fix-common

@test "worktree-inheritance FIX --dry-run: reports the clone migration and every offending worktree, changes nothing" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "dryrun-wt"

  # Pre-condition: worktree missing .claude/
  [ ! -d "$WT_PATH/.claude" ]
  local before
  before="$(ls "$WT_PATH" 2>/dev/null | sort)"

  run_doctor --fix --dry-run
  [ "$status" -eq 0 ]
  # The plan names the offending worktree and the clone migration that covers
  # it — never the removed per-worktree mirror command.
  [[ "$output" == *"[manual] linked worktree missing inheritance: $WT_PATH"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" != *"--legacy-mirror"* ]] || { echo "$output"; false; }
  [[ "$output" == *"nothing applied"* ]] || { echo "$output"; false; }

  # Filesystem is unchanged (dry-run = no mutation).
  local after
  after="$(ls "$WT_PATH" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
  [ ! -d "$WT_PATH/.claude" ]
}

@test "worktree-inheritance FIX: --fix seeds nothing; the worktree stays un-seeded and the WARN persists" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "fix-wt"

  # Pre-condition: worktree missing .claude/
  [ ! -d "$WT_PATH/.claude" ]

  run_doctor --fix
  # Worktree inheritance is a WARN, so a run with nothing else broken still
  # exits 0 — but nothing was seeded and the WARN is still reported after.
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-checking healthy after fixes"* ]] || { echo "$output"; false; }
  [[ "${output##*re-checking healthy after fixes}" == *"⚠ worktree-inheritance:"* ]] || { echo "$output"; false; }
  [ ! -d "$WT_PATH/.claude" ]
}

@test "worktree-inheritance FIX: an off-main canonical changes nothing — the worktree was never going to be seeded" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "gate-wt"

  # Push canonical off main so Tier-0 ERRORs.
  ( cd "$CANON" && git checkout -q -b feat/poison )

  run_doctor --fix
  # Tier-0 is in error → non-zero exit.
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tier-0"* ]] || { echo "$output"; false; }
  # The worktree remains un-seeded — the same outcome as a clean canonical,
  # because there is no seeding path left to gate.
  [ ! -d "$WT_PATH/.claude" ]
}

@test "portable doctor --fix --dry-run withholds attach when the recorded release is unavailable" {
  build_portable_doctor_fix_home
  before="$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')"

  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash "$DOCTOR" --fix --dry-run

  [ "$status" -eq 5 ]
  [[ "$output" == *"repair boundary: attach/relink is withheld until recorded immutable release 1.2.3 validates"* ]] || { echo "$output"; false; }
  [[ "$output" == *"user attachment is report-only; remedy: trellis attach --user"* ]] || { echo "$output"; false; }
  [ ! -e "$PORTABLE_PROJECT/.trellis/runtime" ]
  [ "$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')" = "$before" ]
}

@test "portable doctor --fix --dry-run preserves harnesses and quotes attachment arguments" {
  build_portable_doctor_fix_home
  install_portable_doctor_release

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"[auto] trellis attach"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--harness claude"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--harness codex"* ]] || { echo "$output"; false; }
  [[ "$output" == *"portable\\ project"* ]] || { echo "$output"; false; }
  [[ "$output" == *"safe repair through trellis attach is planned but was not applied"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses a dry-run attach with an empty registry harness set" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  jq '.projects["personal/portable-fixture"].checkouts |= with_entries(.value.harnesses = [])' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"registry harness selection is empty or invalid; attach cannot choose native surfaces"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor never reattaches detached or excluded rows" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  jq '.projects["personal/portable-fixture"].status = "detached"' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"registry status: detached"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }

  jq '.projects["personal/portable-fixture"].status = "active"
      | .projects["personal/portable-fixture"].metadata = {legacy:{blacklisted:true}}' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"registry exclusion: automatic attachment repair is withheld"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses unsafe attachment journal entries instead of recovering or attaching" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  mkdir -p "$PORTABLE_HOME/state/attachment-journals"
  chmod 700 "$PORTABLE_HOME/state" "$PORTABLE_HOME/state/attachment-journals"
  ln -s "$SANDBOX/untrusted-journal" "$PORTABLE_HOME/state/attachment-journals/corrupt.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"attachment journal entry is a symlink or non-regular file"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses an unexpected attachment journal node instead of treating it as absent" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  mkdir -p "$PORTABLE_HOME/state/attachment-journals"
  chmod 700 "$PORTABLE_HOME/state" "$PORTABLE_HOME/state/attachment-journals"
  ln -s "$SANDBOX/untrusted-journal" "$PORTABLE_HOME/state/attachment-journals/unexpected-node"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"attachment journal directory has an unexpected entry"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses a valid-shaped journal for a different registry row" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" ATTACHMENT_FAULT_PHASE=prepared \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 --harness claude "$PORTABLE_PROJECT"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  journal="$(find "$PORTABLE_HOME/state/attachment-journals" -type f -name '*.json' -print)"
  [ -f "$journal" ]
  jq '.project_id = "different-project"' "$journal" > "$journal.next"
  mv "$journal.next" "$journal"
  chmod 600 "$journal"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 3 ]
  [[ "$output" == *"attachment journal does not exactly match this registry row"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor withholds even an exact journal and continues later rows" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" ATTACHMENT_FAULT_PHASE=prepared \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 --harness claude "$PORTABLE_PROJECT"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  journal="$(find "$PORTABLE_HOME/state/attachment-journals" -type f -name '*.json' -print)"
  [ -f "$journal" ]
  journal_before="$(shasum -a 256 "$journal" | awk '{print $1}')"
  project_before="$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')"

  visible_root="$SANDBOX/z-visible"
  build_portable_fixture_project "$visible_root" z-visible
  visible_identity="$(portable_identity_for_root "$visible_root")"
  visible_checkout="$(printf '%s\n' "$visible_identity" | jq -r '.checkout_id')"
  visible_worktree="$(printf '%s\n' "$visible_identity" | jq -r '.worktree_id')"
  visible_common="$(printf '%s\n' "$visible_identity" | jq -r '.git_common_dir')"
  jq --arg checkout "$visible_checkout" --arg common "$visible_common" \
    --arg root "$visible_root" --arg worktree "$visible_worktree" '
      .projects["personal/z-visible"] = {
        fleet: "personal", project_id: "z-visible", status: "active", metadata: {},
        checkouts: {
          ($checkout): {
            root: $root, git_common_dir: $common, release: "1.2.3", harnesses: ["claude"],
            worktrees: {($worktree): {root: $root}}
          }
        }
      }
    ' "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"attachment journal at $journal (state=prepared) requires manual recovery"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis recover --home"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "${output#*portable-fixture (worktree)}" == *"z-visible (worktree)"* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$journal" | awk '{print $1}')" = "$journal_before" ]
  [ "$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')" = "$project_before" ]
  [ ! -e "$PORTABLE_PROJECT/.trellis/runtime" ]
}

@test "portable doctor dry-run remains nonzero for an unavailable row" {
  build_portable_doctor_fix_home
  jq '.projects["personal/portable-fixture"].status = "unavailable"' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 5 ]
  [[ "$output" == *"unavailable: retained local registry row at $PORTABLE_PROJECT"* ]] || { echo "$output"; false; }
}

@test "portable doctor treats a corrupt recorded release as a row error" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  corrupt_file="$PORTABLE_HOME/releases/1.2.3/payload/trellis.config.json"
  chmod u+w "$corrupt_file"
  printf '\n# corrupted after verification\n' >> "$corrupt_file"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"immutable release: 1.2.3 is corrupt or unsafe"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor relinks a missing runtime with unrelated explicit-json keys" {
  build_portable_doctor_fix_home
  attach_portable_doctor_project

  local settings settings_mode mode
  settings="$PORTABLE_PROJECT/.claude/settings.local.json"
  case "$(uname -s)" in
    Darwin) settings_mode="$(stat -f '%Lp' "$settings")" ;;
    *) settings_mode="$(stat -c '%a' "$settings")" ;;
  esac
  [ "$settings_mode" = 600 ]
  jq '.unrelated = "keep-me"' "$settings" > "$settings.next"
  chmod "$settings_mode" "$settings.next"
  mv "$settings.next" "$settings"
  rm "$PORTABLE_PROJECT/.trellis/runtime"

  run_portable_doctor_fix --fix

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"safe repair delegated through trellis relink and passed strict post-repair verification"* ]] \
    || { echo "$output"; false; }
  [ -L "$PORTABLE_PROJECT/.trellis/runtime" ]
  [ "$(jq -r '.unrelated' "$settings")" = "keep-me" ]
  case "$(uname -s)" in
    Darwin) mode="$(stat -f '%Lp' "$settings")" ;;
    *) mode="$(stat -c '%a' "$settings")" ;;
  esac
  [ "$mode" = "$settings_mode" ]
  [ "$mode" = 600 ]
}

@test "portable doctor never relinks when enabled hook authority drifts" {
  local owner expected current current_display root_display expected_display diagnostic
  build_portable_doctor_fix_home
  current=".husky/_"
  git -C "$PORTABLE_PROJECT" config --local core.hooksPath "$current"
  attach_portable_doctor_project

  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  expected="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = "$current" ]

  git -C "$PORTABLE_PROJECT" config --local core.hooksPath "$current"
  rm "$PORTABLE_PROJECT/.trellis/runtime"

  run_portable_doctor_fix --fix

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  current_display="$(printf '%q' "$current")"
  root_display="$(printf '%q' "$PORTABLE_PROJECT")"
  expected_display="$(printf '%q' "$expected")"
  diagnostic="core.hooksPath is $current_display in $root_display; the Trellis managed dispatcher is $expected_display; run trellis doctor --fix"
  [[ "$output" == *"git hook authority: $diagnostic"* ]] || { echo "$output"; false; }
  [[ "$output" != *"config core.hooksPath"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis relink"* ]] || { echo "$output"; false; }
  [[ "$output" != *"safe repair delegated through trellis relink and passed strict post-repair verification"* ]] \
    || { echo "$output"; false; }
  [ ! -e "$PORTABLE_PROJECT/.trellis/runtime" ]
  [ ! -L "$PORTABLE_PROJECT/.trellis/runtime" ]
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get core.hooksPath)" = "$current" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = "$current" ]
}
