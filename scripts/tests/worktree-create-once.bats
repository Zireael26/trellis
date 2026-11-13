#!/usr/bin/env bats
# Count complete donor verifications at the real create boundaries. The
# instrumented scripts are sealed into a private fixture release; the real Git
# post-checkout hook and attachment transaction remain enabled. If verification
# moves to a shared program, instrument that program too: both the canonical
# leaf loop and every complete alternative donor pass belong in the count.

bats_require_minimum_version 1.5.0
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/worktree-create-trace

# Count recorded attempts, not successful exit codes, for one boundary. The
# recorder also retains callers and canonicalized exclude records.
step_duplicates() {
  local boundary="$1" owner="$2" target="$3"
  awk -F '\t' -v boundary="$boundary" -v donor="$DONOR" -v target_owner="$owner" -v donor_root="$T14_PROJECT" -v target_root="$target" '
    $2 != boundary { next }
    ($2 == "pre" || $2 == "hook") && $1 == "schema" && $3 == donor { n[$1 FS $2 FS $3]++ }
    $2 == "post" && $1 == "schema" && $3 == target_owner { n[$1 FS $2 FS $3]++ }
    ($2 == "pre" || $2 == "hook") && $1 == "leaf" && index($3, donor_root "/") == 1 { n[$1 FS $2 FS $3]++ }
    $2 == "post" && $1 == "leaf" && index($3, target_root "/") == 1 { n[$1 FS $2 FS $3]++ }
    ($2 == "pre" || $2 == "hook") && $1 == "render" && index($3, donor_root "/") == 1 { n[$1 FS $2 FS $3 FS $4]++ }
    $2 == "post" && $1 == "render" && index($3, target_root "/") == 1 { n[$1 FS $2 FS $3 FS $4]++ }
    $1 == "exclude" { n[$1 FS $2 FS $4]++ }
    END { for (key in n) if (n[key] > 1) { print "duplicate", n[key], key; bad=1 } exit bad }
  ' "$STEPS"
}

step_create() {
  local name="$1" phase kind
  STEP_TARGET="$TRELLIS_WORKTREE_ROOT/fixture-project/$name"
  run bash -c 'cd "$1" && "$2" add "$3"' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh" "$name"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  STEP_OWNER="$(t14_owner_for_root "$STEP_TARGET")" || return 1
  # Every boundary must actually be observed, or a count of zero passes.
  for phase in pre hook; do
    for kind in schema leaf render exclude; do
      awk -F '\t' -v phase="$phase" -v kind="$kind" \
        '$1 == kind && $2 == phase { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
    done
  done
  for kind in schema leaf render; do
    awk -F '\t' -v kind="$kind" '$1 == kind && $2 == "post" { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
  done
}

@test "step-level pre-add schema, leaf, render and exclude checks are not duplicated" {
  step_create steps-pre || return 1
  step_duplicates pre "$STEP_OWNER" "$STEP_TARGET" || { summarize_steps; return 1; }
}

@test "step-level hook schema, leaf, render and exclude checks are not duplicated" {
  step_create steps-hook || return 1
  step_duplicates hook "$STEP_OWNER" "$STEP_TARGET" || { summarize_steps; return 1; }
}

@test "step-level post-Git target checks are not duplicated" {
  step_create steps-post || return 1
  step_duplicates post "$STEP_OWNER" "$STEP_TARGET" || { summarize_steps; return 1; }
}

@test "create verifies each donor once per boundary and proves target readiness" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/once" owner pre hook post
  run bash -c 'cd "$1" && "$2" add once' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  owner="$(t14_owner_for_root "$target")" || return 1
  [ -L "$target/.trellis/runtime" ] || return 1
  pre="$(count_verifications "$DONOR" pre)"
  hook="$(count_verifications "$DONOR" hook)"
  post="$(count_verifications "$owner" hook)"
  printf 'pre-add donor=%s hook donor=%s post-Git target=%s\n' "$pre" "$hook" "$post"
  [ "$pre" -eq 1 ] && [ "$hook" -eq 1 ] && [ "$post" -eq 1 ] || {
    echo "duplicate or missing verification:"; cat "$TRACE"; return 1
  }
  # A full-path fallback must not accidentally make the count look good.
  awk -F '\t' -v owner="$DONOR" '$1 == "fast" && $3 == owner { found=1 } END { exit !found }' "$TRACE"
}

@test "create can select a second donor when the first one's artifacts drift" {
  local peer="$TRELLIS_WORKTREE_ROOT/fixture-project/peer" target="$TRELLIS_WORKTREE_ROOT/fixture-project/second"
  local peer_owner bad_owner bad_root good_owner good_root
  run bash -c 'cd "$1" && "$2" add peer' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  peer_owner="$(t14_owner_for_root "$peer")" || return 1
  # The registry reader iterates owner IDs in byte order. Drift the first one,
  # regardless of which worktree happens to receive the smaller hash.
  if [[ "$DONOR" < "$peer_owner" ]]; then
    bad_owner="$DONOR"; bad_root="$T14_PROJECT"; good_owner="$peer_owner"; good_root="$peer"
  else
    bad_owner="$peer_owner"; bad_root="$peer"; good_owner="$DONOR"; good_root="$T14_PROJECT"
  fi
  rm "$bad_root/.claude/rules/trellis.md"
  ln -s unexpected "$bad_root/.claude/rules/trellis.md"
  : > "$TRACE"
  run bash -c 'cd "$1" && "$2" add second' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -L "$target/.trellis/runtime" ] && [ -f "$(t14_owner_for_root "$target")" ] || return 1
  [ "$(count_verifications "$bad_owner" pre)" -eq 1 ] || { cat "$TRACE"; return 1; }
  [ "$(count_verifications "$good_owner" pre)" -eq 1 ] || { cat "$TRACE"; return 1; }
  [ "$(count_verifications "$bad_owner" hook)" -eq 1 ] || { cat "$TRACE"; return 1; }
  [ "$(count_verifications "$good_owner" hook)" -eq 1 ] || { cat "$TRACE"; return 1; }
  [ "$(jq -r .worktree_root "$good_owner")" = "$good_root" ] || return 1
}

@test "historical payload without registry admission keeps the seed's donor verify" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/historical"
  run bash -c 'cd "$1" && "$2" add historical' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -L "$target/.trellis/runtime" ] && [ -f "$(t14_owner_for_root "$target")" ] || return 1
  # The pre-1.5.2 route, unchanged: the seed's complete verify plus the fast
  # path's own leaf pass. Counted, not claimed once-only.
  awk -F '\t' -v owner="$DONOR" '$1 == "canonical" && $2 != "1" && $3 == owner { found=1 } END { exit !found }' "$TRACE" || { cat "$TRACE"; return 1; }
  [ "$(count_verifications "$DONOR" hook)" -eq 2 ] || { cat "$TRACE"; return 1; }
}

@test "a fast miss after admission keeps the canonical continuation (counted exception)" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/fast-miss" hook
  # Project context the donor has and the target lacks: the coordinator
  # admits the donor, then misses before any journal; the canonical route
  # selects and attaches exactly as before stage A.
  printf '# donor-only project context\n' > "$T14_PROJECT/CLAUDE.md"
  run bash -c 'cd "$1" && "$2" add fast-miss' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *'donor fast path'* ]] || { echo "$output"; return 1; }
  [ -L "$target/.trellis/runtime" ] && [ -f "$(t14_owner_for_root "$target")" ] || return 1
  [ "$(count_verifications "$DONOR" pre)" -eq 1 ] || { cat "$TRACE"; return 1; }
  hook="$(count_verifications "$DONOR" hook)"
  awk -F '\t' -v owner="$DONOR" '$1 == "fast" && $3 == owner { found=1 } END { exit !found }' "$TRACE" || { cat "$TRACE"; return 1; }
  # Accepted stage-A exception (t38f, 2026-11-11), the same total as before:
  # admission 1 + canonical selection 1 + canonical attach's donor checks 2
  # (before: seed 1 + fast path 1 + canonical attach 2). Stage B removes it.
  [ "$hook" -eq 4 ] || { echo "fast-miss hook donor verifications: $hook"; cat "$TRACE"; return 1; }
}

@test "donor changed after pre-add is refused by the hook" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/race"
  # The invoking seed is an instrumented fixture copy, not the sealed release.
  # Tamper only after the real pre-add check has passed; Git's real managed
  # post-checkout must independently detect the change.
  python3 - "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" \
    "$T14_PROJECT/.claude/rules/trellis.md" <<'PY'
import pathlib
import shlex
import sys

seed, leaf = map(pathlib.Path, sys.argv[1:])
text = seed.read_text()
old = 'attachment_reconcile\nexit $?\n'
new = ("attachment_reconcile\nrc=$?\n"
       "if [ \"$PRE_ADD\" -eq 1 ] && [ \"$rc\" -eq 0 ]; then\n"
       "  rm -- " + shlex.quote(str(leaf)) + "\n"
       "  ln -s unexpected " + shlex.quote(str(leaf)) + "\n"
       "fi\nexit \"$rc\"\n")
assert text.count(old) == 1
seed.write_text(text.replace(old, new))
PY
  run bash -c 'cd "$1" && "$2" add race' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'trellis post-checkout: attachment reconciliation failed'* ]] || { echo "$output"; return 1; }
  [ ! -L "$target/.trellis/runtime" ] || return 1
  [ -z "$(t14_owner_for_root "$target" 2>/dev/null || true)" ] || return 1
  [ "$(count_verifications "$DONOR" pre)" -eq 1 ] || return 1
}

@test "a chmod-only owner change after the pre-add donor verify refuses before Git creates anything" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/chmod-only"
  # The invoking seed is an instrumented fixture copy. Its donor verify has
  # passed; the owner's bytes stay the same, so only its mode is stale.
  python3 - "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" <<'PY'
import pathlib
import sys

seed = pathlib.Path(sys.argv[1])
text = seed.read_text()
old = '    seed_exclude_diagnostic "$script_dir" "$donor_owner" "$payload" "$harnesses_json" \\\n'
assert text.count(old) == 1
seed.write_text(text.replace(old, '    chmod 666 "$donor_owner"\n' + old))
PY
  run bash -c 'cd "$1" && "$2" add chmod-only' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  # The diagnostic escapes the path; match its record name.
  [[ "$output" == *"shared exclude owner record is invalid: "*"/${DONOR##*/}"* ]] || { echo "$output"; return 1; }
  [ ! -e "$target" ] || { echo 'Git created the worktree'; return 1; }
  ! git -C "$T14_PROJECT" rev-parse --verify -q refs/heads/chmod-only >/dev/null || { echo 'Git created the branch'; return 1; }
  ! git -C "$T14_PROJECT" worktree list --porcelain | grep -qF "$target" || return 1
}

# Portable inode (BSD and GNU stat differ).
file_inode() {
  python3 -I -c 'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' "$1"
}

captured_donor_rewrite_refuses() {
  local point="$1" target="$TRELLIS_WORKTREE_ROOT/fixture-project/rewrite-$1" render="$T14_PROJECT/.claude/fixture-settings.json" inode
  [ -f "$render" ] || { echo 'fixture has no owned render'; return 1; }
  inode="$(file_inode "$render")"
  : > "$T14_SANDBOX/t152-mutate.$point"
  run bash -c 'cd "$1" && "$2" add "$3"' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh" "rewrite-$point"
  [ -e "$T14_SANDBOX/t152-mutate.$point.done" ] || { echo "the $point rewrite never ran: $output"; return 1; }
  [ "$(file_inode "$render")" = "$inode" ] || { echo 'the rewrite replaced the inode'; return 1; }
  # The fast path misses; the canonical continuation re-verifies the donor
  # and refuses it. Nothing was published or journaled.
  [ "$status" -ne 0 ] || { echo "rewritten donor was used: $output"; return 1; }
  [[ "$output" == *'invalid donor ownership'* ]] || { echo "$output"; return 1; }
  [ ! -L "$target/.trellis/runtime" ] || { echo 'runtime published from a rewritten donor'; return 1; }
  [ -z "$(t14_owner_for_root "$target" 2>/dev/null || true)" ] || return 1
  [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -type f 2>/dev/null)" ] || return 1
}

@test "captured donor render rewritten in place after admission misses to the canonical refusal" {
  captured_donor_rewrite_refuses admitted
}

@test "captured donor render rewritten in place during preflight misses to the canonical refusal" {
  captured_donor_rewrite_refuses preflight
}

@test "substituting both plan and journal cannot authorize a forged artifact" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/plan-substitution" marker="$T14_SANDBOX/substitution-ran"
  # Exercise the supported deferred checkout route, then invoke the real
  # attachment transaction. The hook is not disabled or replaced.
  run bash -c 'cd "$1" && "$2" add plan-substitution --no-checkout' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git -C "$target" reset --hard -q || return 1
  run bash -c '
    . "$1"
    t152_marker=$4
    definition="$(declare -f local_registry_write_locked_bound_rows)"
    eval "${definition/local_registry_write_locked_bound_rows /t152_original_registry_write }"
    local_registry_write_locked_bound_rows() {
      local plan="${2%/*}/plan.json" id journal
      [ -f "$plan" ] || return 91
      id="$(jq -r .attachment_id "$plan")" || return 92
      journal="$1/state/attachment-journals/$id.json"
      [ -f "$journal" ] || return 93
      jq '\''(.artifacts[] | select(.path == ".trellis/runtime").target) = "unexpected"'\'' "$plan" > "$plan.next" || return 94
      jq '\''(.artifacts[] | select(.path == ".trellis/runtime").target) = "unexpected"'\'' "$journal" > "$journal.next" || return 95
      chmod 600 "$plan.next" "$journal.next" && mv "$plan.next" "$plan" && mv "$journal.next" "$journal" || return 96
      : > "$t152_marker"
      t152_original_registry_write "$@"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' _ "$REPO_ROOT/scripts/attach-project.sh" "$TRELLIS_HOME" "$target" "$marker"
  [ -e "$marker" ] || { echo "substitution did not reach the publication boundary: $output"; return 1; }
  [ "$status" -ne 0 ] || { echo "forged plan was accepted: $output"; return 1; }
  [ ! -L "$target/.trellis/runtime" ] || { echo 'forged runtime was published'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -type f | wc -l | tr -d ' ')" -eq 1 ] || return 1
}

@test "registered callback sync verifies its donor once before printing the path" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/cc-once-callback" input count
  export PATH="$REPO_ROOT/scripts:$PATH" T152_TRACE_CALLBACK=1
  input="$(jq -cn --arg cwd "$T14_PROJECT" '{name:"once-callback",cwd:$cwd}')"
  run --separate-stderr bash "$REPO_ROOT/core-rules/hooks/trellis-worktree-create.sh" <<< "$input"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "$target" ] || { echo "unexpected callback stdout: $output"; return 1; }
  [ -f "$(t14_owner_for_root "$target")" ] && [ -L "$target/.trellis/runtime" ] || return 1
  count="$(count_verifications "$DONOR" hook)"
  [ "$count" -eq 1 ] || { echo "callback donor verifications: $count"; cat "$TRACE"; return 1; }
  awk -F '\t' -v owner="$DONOR" '$1 == "fast" && $3 == owner { found=1 } END { exit !found }' "$TRACE"
}
