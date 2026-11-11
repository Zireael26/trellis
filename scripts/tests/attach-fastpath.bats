#!/usr/bin/env bats
# A5B: private release/home only; no hook bypasses, no live fleet operations.
REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture
load helpers/native-render-fixture

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/a5b.fixture.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1
  # The A4 job is stubbed below, so no verdict job ever starts: say so as
  # scripts/run-tests.sh does, instead of depending on the caller's runner.
  export TRELLIS_ATTACH_POSTJOB=off
  # Only unit fixtures stub A4; production requires the frozen dependency.
  trellis_attach_postjob_spawn() { :; }
  export -f trellis_attach_postjob_spawn
  mkdir -p "$HOME" "$TRELLIS_HOME" "$SANDBOX/source/core-rules/templates" "$SANDBOX/source/core-rules/githooks" "$SANDBOX/source/scripts"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  mkdir -p "$SANDBOX/source/core-rules/legacy-hooks"
  cp -R "$REPO_ROOT/core-rules/legacy-hooks/." "$SANDBOX/source/core-rules/legacy-hooks/"
  # Legacy-shaped templates keep the substitution route covered; the T34B
  # native cases render native registrations (T34 option B).
  cp "$REPO_ROOT/core-rules/legacy-hooks/claude-settings.local.json" "$SANDBOX/source/core-rules/templates/"
  cp "$REPO_ROOT/core-rules/legacy-hooks/codex-hooks.local.json" "$SANDBOX/source/core-rules/templates/"
  if [[ "$BATS_TEST_DESCRIPTION" == 'T34B native'* ]]; then
    native_render_fixture_source "$SANDBOX/source"
  fi
  printf '# fixture policy\n' > "$SANDBOX/source/core-rules/CLAUDE.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/source/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/source/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$SANDBOX/source/core-rules/githooks/pre-push" "$SANDBOX/source/scripts/seed-inheritance-symlinks.sh"
  if [[ "$BATS_TEST_DESCRIPTION" == 'T2A seed'* ]]; then
    cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$SANDBOX/source/scripts/seed-inheritance-symlinks.sh"
  fi
  printf '1.2.3\n' > "$SANDBOX/source/core-rules/VERSION"
  # Post-checkout hash-checks every payload file its reconcile runs and refuses
  # a release that lacks one (A1). The stub seed stays the reconcile; these
  # copies only satisfy that check.
  local path
  while IFS= read -r path; do
    [ "$path" != scripts/seed-inheritance-symlinks.sh ] || continue
    mkdir -p "$SANDBOX/source/${path%/*}"
    cp "$REPO_ROOT/$path" "$SANDBOX/source/$path"
  done < <(sed -n '/^  local -a paths=($/,/^  )$/p' "$REPO_ROOT/scripts/lib/attachment.sh" | sed '1d;$d;s/^ *//')
  printf '%s\n' '{"schema_version":1,"harnesses":{"claude":{"links":[{"source":"core-rules/CLAUDE.md","destination":".claude/rules/trellis.md"}],"render":[{"template":"core-rules/templates/claude-settings.local.json","destination":".claude/settings.local.json","merge":"explicit-json","mode":"0600","required":true}]},"codex":{"links":[{"source":"core-rules/CLAUDE.md","destination":".agents/rules/trellis.md"}],"render":[{"template":"core-rules/templates/codex-hooks.local.json","destination":".codex/hooks.json","merge":"explicit-json","mode":"0600","required":true}]}}}' > "$SANDBOX/source/core-rules/inheritance-manifest.json"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 1.2.3 "$SANDBOX/source"
  PROJECT="$SANDBOX/project"
  git init -q "$PROJECT"
  printf '{"schema_version":1,"project_id":"a5b-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$PROJECT"
  DONOR="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  TARGET="$SANDBOX/target"
  git -C "$PROJECT" worktree add -q -b fast-fixture "$TARGET"
}

teardown() {
  /usr/bin/python3 - "$SANDBOX" <<'PY'
import os, shutil, sys
for root, dirs, files in os.walk(sys.argv[1]):
    os.chmod(root, 0o700)
    for name in files:
        path = os.path.join(root, name)
        if not os.path.islink(path):
            os.chmod(path, 0o600)
shutil.rmtree(sys.argv[1])
PY
}

@test "L2 exact current attach skips full sibling reconcile but keeps target guards" {
  fast_attach
  [ "$status" -eq 0 ]
  printf 'unrelated sibling drift\n' >> "$PROJECT/.claude/settings.local.json"
  run bash -c '
    . "$1"
    attach_reconcile_verify_group() { echo full-sibling-reconcile >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' incremental "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'already attached:'* ]]
  printf 'drift\n' >> "$TARGET/.claude/settings.local.json"
  run "$ATTACH" attach --home "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 3 ]
}

@test "L2 exact current attach keeps registry postconditions under its locks" {
  cp "$DONOR" "$SANDBOX/owner-before"
  run bash -c '
    . "$1"
    definition="$(declare -f _attach_reconcile_verify_owners)"
    eval "${definition/_attach_reconcile_verify_owners /real_verify_owners }"
    _attach_reconcile_verify_owners() {
      real_verify_owners "$@" || return "$?"
      jq '\''.projects["personal/a5b-fixture"].checkouts[] .release = "8.8.8"'\'' "$1/registry.json" > "$1/registry.race"
      chmod 600 "$1/registry.race"
      mv "$1/registry.race" "$1/registry.json"
    }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' incremental "$ATTACH" "$TRELLIS_HOME" "$PROJECT"
  printf '%s\n' "$output"
  [ "$status" -eq 3 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
}

@test "L2 shared exclude checks ownership not unrelated sibling artifacts" {
  printf 'drift\n' >> "$PROJECT/.claude/settings.local.json"
  run bash -c '
    . "$1"
    block="$4/block"; before="$4/before"; after="$4/after"
    attach_decode_base64 "$(jq -r .exclude.managed_block_base64 "$3")" > "$block"
    common="$(jq -r .exclude.git_common_dir "$3")"
    : > "$before"
    attach_shared_exclude_state "$2" "$(jq -r .checkout_id "$3")" "$common" "$block" "$before" "$after"
  ' incremental "$ATTACH" "$TRELLIS_HOME" "$DONOR" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "L2 healthy donor permits attach despite another sibling artifact drift" {
  fast_attach
  [ "$status" -eq 0 ]
  printf 'drift\n' >> "$PROJECT/.claude/settings.local.json"
  NEW_TARGET="$SANDBOX/third"
  git -C "$PROJECT" worktree add -q -b third "$NEW_TARGET"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$NEW_TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
  NEW_TARGET="$SANDBOX/fourth"
  git -C "$PROJECT" worktree add -q -b fourth "$NEW_TARGET"
  mkdir -p "$NEW_TARGET/.claude"
  printf '{"project_note":"keep"}\n' > "$NEW_TARGET/.claude/settings.local.json"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$NEW_TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *'donor fast path'* ]]
  [ "$(jq -r .project_note "$NEW_TARGET/.claude/settings.local.json")" = keep ]
}

@test "F2 tampered shared dispatcher refuses full attach before any publication" {
  local checkout owner_dir
  checkout="$(jq -r .checkout_id "$DONOR")"
  owner_dir="$TRELLIS_HOME/state/attachments/$checkout"
  cp -R "$owner_dir" "$SANDBOX/owners-before"
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
  mkdir -p "$TARGET/.claude"
  printf '{"project_note":"keep"}\n' > "$TARGET/.claude/settings.local.json"
  cp "$TARGET/.claude/settings.local.json" "$SANDBOX/guard-before"
  printf '# tampered\n' >> "$TRELLIS_HOME/state/git-hooks/$checkout/post-checkout"
  fast_attach
  [ "$status" -eq 3 ]
  diff -r "$SANDBOX/owners-before" "$owner_dir"
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
  cmp "$SANDBOX/guard-before" "$TARGET/.claude/settings.local.json"
  [ ! -e "$TARGET/.trellis/runtime" ]
  [ ! -L "$TARGET/.trellis/runtime" ]
  [ ! -e "$TARGET/.agents" ]
  [[ "$output" == *"shared exclude managed hooks verification failed for owner $DONOR"* ]]
  # Adoption owns hook validation/repair at its own boundary, not this helper.
  run bash -c '
    . "$1"
    attach_decode_base64 "$(jq -r .exclude.managed_block_base64 "$3")" > "$4/block"
    : > "$4/before"
    attach_shared_exclude_state "$2" "$(jq -r .checkout_id "$3")" "$(jq -r .exclude.git_common_dir "$3")" "$4/block" "$4/before" "$4/after" adoption
  ' f2 "$ATTACH" "$TRELLIS_HOME" "$DONOR" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "F2 shared exclude owner binding refusal names the record" {
  local checkout
  checkout="$(jq -r .checkout_id "$DONOR")"
  jq '.checkout_id = ("0" * 64)' "$DONOR" > "$SANDBOX/changed"
  chmod 600 "$SANDBOX/changed"
  mv "$SANDBOX/changed" "$DONOR"
  run bash -c '
    . "$1"
    attach_decode_base64 "$(jq -r .exclude.managed_block_base64 "$3")" > "$4/block"
    : > "$4/before"
    attach_shared_exclude_state "$2" "$5" "$(jq -r .exclude.git_common_dir "$3")" "$4/block" "$4/before" "$4/after"
  ' f2 "$ATTACH" "$TRELLIS_HOME" "$DONOR" "$SANDBOX" "$checkout"
  [ "$status" -eq 3 ]
  [[ "$output" == *"shared exclude owner binding mismatch for owner $DONOR"* ]]
}

@test "F2 current-owner sibling hook refusal names the record" {
  fast_attach
  [ "$status" -eq 0 ]
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
  printf '# tampered\n' >> "$TRELLIS_HOME/state/git-hooks/$(jq -r .checkout_id "$DONOR")/post-checkout"
  fast_attach
  [ "$status" -eq 3 ]
  [[ "$output" == *"managed hooks verification failed for owner $DONOR"* ]]
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
}

@test "F2 current-owner snapshot refusal names the record" {
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
  run bash -c '
    . "$1"
    definition="$(declare -f _attach_reconcile_verify_owners)"
    eval "${definition/_attach_reconcile_verify_owners /real_verify_owners }"
    _attach_reconcile_verify_owners() {
      real_verify_owners "$@" || return "$?"
      jq '\''.toolchain_path += ["/f2-snapshot-race"]'\'' "$2" > "$2.race"
      chmod 600 "$2.race"
      mv "$2.race" "$2"
    }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' f2 "$ATTACH" "$TRELLIS_HOME" "$PROJECT"
  printf '%s\n' "$output"
  [ "$status" -eq 3 ]
  [[ "$output" == *"owner snapshot conflict at $DONOR"* ]]
  cmp "$SANDBOX/registry-before" "$TRELLIS_HOME/registry.json"
}

@test "F2 donor selection skips a refreshed first candidate" {
  local first root
  fast_attach
  [ "$status" -eq 0 ]
  first="$(printf '%s\n' "$TRELLIS_HOME"/state/attachments/*/*.json | LC_ALL=C sort | head -1)"
  root="$(jq -r .worktree_root "$first")"
  rm "$root/.agents/rules/trellis.md"
  printf '# project-authored replacement\n' > "$root/.agents/rules/trellis.md"
  git -C "$root" add -f .agents/rules/trellis.md
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$root"
  [ "$status" -eq 0 ]
  cp "$first" "$SANDBOX/refreshed-before"
  NEW_TARGET="$SANDBOX/third"
  git -C "$PROJECT" worktree add -q -b third "$NEW_TARGET"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$NEW_TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
  cmp "$SANDBOX/refreshed-before" "$first"
}

@test "F2 doctor repair hint quotes the checkout and selects its home" {
  local root owner worktree hint
  root="$SANDBOX/doctor target ' quoted"
  git -C "$PROJECT" worktree add -q -b doctor-quoted "$root"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$root"
  [ "$status" -eq 0 ]
  worktree="$(jq -r --arg root "$root" 'select(.worktree_root == $root) | .worktree_id' "$TRELLIS_HOME"/state/attachments/*/*.json)"
  owner="$TRELLIS_HOME/state/attachments/$(jq -r .checkout_id "$DONOR")/$worktree.json"
  printf 'drift\n' >> "$root/.claude/settings.local.json"
  run bash -c '
    . "$1"; . "$2"
    hc_portable_owner "$3" "$4" "$5" personal a5b-fixture "$(jq -r .checkout_id "$4")" "$(jq -r .worktree_id "$4")" "$(jq -r .attachment_id "$4")" 1.2.3 2>/dev/null
  ' f2 "$ATTACH" "$REPO_ROOT/scripts/lib/health-checks.sh" "$TRELLIS_HOME" "$owner" "$root"
  [ "$status" -ne 0 ]
  LC_ALL=C printf -v hint 'trellis attach --refresh-artifacts --home %q %q' "$TRELLIS_HOME" "$root"
  [[ "$output" == *"$hint"* ]]
}

@test "L2 exclude refusal diagnoses invalid ownership rather than claiming no owner" {
  jq '.exclude.managed_block_sha256 = ("0" * 64) | .exclude_block_hash = ("0" * 64)' "$DONOR" > "$SANDBOX/changed"
  chmod 600 "$SANDBOX/changed"
  mv "$SANDBOX/changed" "$DONOR"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 3 ]
  [[ "$output" == *'shared exclude block hash mismatch for owner'* ]]
  [[ "$output" != *'managed exclude block has no matching committed checkout ownership'* ]]
}

@test "L2 refresh artifacts retires only tracked native takeovers without changing shared state" {
  local leaf="$PROJECT/.agents/rules/trellis.md"
  cp "$DONOR" "$SANDBOX/owner-before"
  cp "$PROJECT/.git/info/exclude" "$SANDBOX/exclude-before"
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
  rm "$leaf"
  printf '# project-owned policy\n' > "$leaf"
  git -C "$PROJECT" add -f .agents/rules/trellis.md
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(< "$leaf")" = '# project-owned policy' ]
  cmp "$SANDBOX/exclude-before" "$PROJECT/.git/info/exclude"
  jq -e '.pre_existing | any(.[]; .path == ".agents/rules/trellis.md" and .reason == "project-authored-file")' "$DONOR"
  [ "$(jq -cS 'del(.artifacts,.pre_existing)' "$DONOR")" = "$(jq -cS 'del(.artifacts,.pre_existing)' "$SANDBOX/owner-before")" ]
  run "$ATTACH" attach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ]
}

@test "L2 refresh artifacts refuses untracked replacements and modified guards" {
  cp "$DONOR" "$SANDBOX/owner-before"
  rm "$PROJECT/.agents/rules/trellis.md"
  printf 'untracked replacement\n' > "$PROJECT/.agents/rules/trellis.md"
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
  git -C "$PROJECT" add -f .agents/rules/trellis.md
  : > "$PROJECT/.agents/rules/trellis.md"
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
  cp "$TRELLIS_HOME/releases/1.2.3/payload/core-rules/CLAUDE.md" "$PROJECT/.agents/rules/trellis.md"
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
  printf '# project-authored replacement\n' > "$PROJECT/.agents/rules/trellis.md"
  printf 'drift\n' >> "$PROJECT/.claude/settings.local.json"
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
}

@test "L2 refresh artifacts preserves pending-operation and binding refusals" {
  cp "$DONOR" "$SANDBOX/owner-before"
  local journal="$TRELLIS_HOME/state/attachment-journals/reconcile-$(jq -r .attachment_id "$DONOR").json"
  printf '{}\n' > "$journal"
  chmod 600 "$journal"
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *'pending journal:'* ]]
  cmp "$SANDBOX/owner-before" "$DONOR"
  rm "$journal"
  printf '{"schema_version":1,"project_id":"foreign-project"}\n' > "$PROJECT/.trellis.json"
  run "$ATTACH" attach --refresh-artifacts --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
  run "$ATTACH" attach --refresh-artifacts --release 1.2.3 --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 2 ]
  cmp "$SANDBOX/owner-before" "$DONOR"
}

@test "L2 doctor names drifted rendered path in its report" {
  printf 'drift\n' >> "$PROJECT/.claude/settings.local.json"
  run bash -c '
    . "$1"; . "$2"
    hc_portable_owner "$3" "$4" "$5" personal a5b-fixture "$(jq -r .checkout_id "$4")" "$(jq -r .worktree_id "$4")" "$(jq -r .attachment_id "$4")" 1.2.3 2>/dev/null
  ' incremental "$ATTACH" "$REPO_ROOT/scripts/lib/health-checks.sh" "$TRELLIS_HOME" "$DONOR" "$PROJECT"
  printf '%s\n' "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PROJECT/.claude/settings.local.json"* ]]
  [[ "$output" == *'--refresh-artifacts'* ]]
}

@test "L2 checkout lock waits beyond a twelve minute attach and remains bounded" {
  run bash -c '
    . "$1"
    attempts=0
    attachment_checkout_lock_reclaim() { return 0; }
    attachment_checkout_lock_acquire() { attempts=$((attempts + 1)); [ "$attempts" -gt 3000 ] || return 3; }
    sleep() { :; }
    attachment_checkout_lock_wait unused checkout common
    [ "$?" -eq 0 ] && [ "$attempts" -eq 3001 ] || exit 1
    attachment_checkout_lock_reclaim() { return 4; }
    attachment_checkout_lock_wait unused checkout common
    [ "$?" -eq 4 ] || exit 1
    attachment_checkout_lock_reclaim() { return 3; }
    waits=0
    sleep() { waits=$((waits + 1)); [ "$waits" -le 3600 ] || exit 1; }
    attachment_checkout_lock_wait unused checkout common
    [ "$?" -eq 3 ] && [ "$waits" -eq 3600 ]
  ' incremental "$REPO_ROOT/scripts/lib/attachment.sh"
  [ "$status" -eq 0 ]
}

@test "L2 benchmark exact current attach with ten siblings" {
  [ -n "${L2_BENCH_REPORT:-}" ] || skip 'set L2_BENCH_REPORT for the serial timing fixture'
  run /usr/bin/python3 -I "$BATS_TEST_DIRNAME/helpers/bench-attach-incremental.py" "$ATTACH" "$TRELLIS_HOME" "$PROJECT" "$SANDBOX" "$L2_BENCH_REPORT" "${L2_BENCH_BASELINE:-2f101f0d}"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r .baseline "$L2_BENCH_REPORT")" = "$(git -C "$REPO_ROOT" rev-parse --verify "${L2_BENCH_BASELINE:-2f101f0d}^{commit}")" ]
  [ "$(jq -r .baseline_ref "$L2_BENCH_REPORT")" = "${L2_BENCH_BASELINE:-2f101f0d}" ]
}

fast_attach() {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  printf '%s\n' "$output"
}

@test "T13 donor preflight captures one canonical registry state while all transaction locks are held" {
  local trace="$SANDBOX/t13-registry-captures"
  run bash -c '
    . "$1"
    TEST_CAPTURE_LOG="$5"
    eval "$(declare -f local_registry_read_diagnostic_state | sed "1s/local_registry_read_diagnostic_state/t13_original_registry_read/")"
    local_registry_read_diagnostic_state() {
      [ -L "${_ATTACHMENT_CHECKOUT_LOCK_LINK:-}" ] && [ -d "${_ATTACHMENT_CHECKOUT_LOCK_HOLDER:-}" ] || return 99
      [ -L "${_ATTACHMENT_LOCK_LINK:-}" ] && [ -d "${_ATTACHMENT_LOCK_HOLDER:-}" ] || return 99
      [ -d "${_TRELLIS_HOME_LOCK_DIR:-}" ] && [ ! -L "$_TRELLIS_HOME_LOCK_DIR" ] || return 99
      printf "capture\n" >> "$TEST_CAPTURE_LOG"
      t13_original_registry_read "$@"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$PROJECT" "$trace"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  [ "$(wc -l < "$trace" | tr -d ' ')" = 1 ] || { echo 'expected one lock-held diagnostic capture'; return 1; }
}

t13_owner_validation_wrapper() {
  local mini="$1"
  mkdir -p "$mini/lib"
  cp "$REPO_ROOT/scripts/lib/attach-fastpath.py" "$REPO_ROOT/scripts/lib/release-executed.py" "$mini/lib/"
  cat > "$mini/attach-project.sh" <<'BASH'
. "$T13_REAL_ATTACH" || exit 1
eval "$(declare -f _attachment_owner_json_valid | sed '1s/_attachment_owner_json_valid/t13_original_owner_valid/')"
_attachment_owner_json_valid() {
  printf '%s\n' "$1" >> "$T13_OWNER_VALIDATION_TRACE"
  t13_original_owner_valid "$@"
}
eval "$(declare -f attach_exclude_verify_state | sed '1s/attach_exclude_verify_state/t13_original_exclude_verify/')"
attach_exclude_verify_state() {
  if [ -n "${T13_EXCLUDE_VALIDATION_TRACE:-}" ]; then printf '%s\n' "$1" >> "$T13_EXCLUDE_VALIDATION_TRACE"; fi
  t13_original_exclude_verify "$@"
}
BASH
}

@test "T13 canonical donor preflight validates the selected owner schema once" {
  local mini="$SANDBOX/t13-owner-count" trace="$SANDBOX/t13-owner-count.log"
  t13_owner_validation_wrapper "$mini"
  run bash -c '
    . "$1"
    SCRIPT_DIR="$4"
    export T13_REAL_ATTACH="$1" T13_OWNER_VALIDATION_TRACE="$5"
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$mini" "$trace"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  [ "$(grep -Fxc "$DONOR" "$trace")" -eq 1 ] || { echo "selected owner schema was validated more than once"; return 1; }
}

@test "T13 malformed selected owner still misses before any publication" {
  local mini="$SANDBOX/t13-owner-invalid" trace="$SANDBOX/t13-owner-invalid.log"
  t13_owner_validation_wrapper "$mini"
  jq '.git_hooks.previous_hooks_path = ""' "$DONOR" > "$SANDBOX/invalid-owner.json"
  chmod 600 "$SANDBOX/invalid-owner.json"
  mv "$SANDBOX/invalid-owner.json" "$DONOR"
  run bash -c '
    . "$1"
    SCRIPT_DIR="$4"
    export T13_REAL_ATTACH="$1" T13_OWNER_VALIDATION_TRACE="$5"
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "full-path\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$mini" "$trace"
  [ "$status" -eq 5 ] || { echo "$output"; return 1; }
  [[ "$output" == *'full-path'* ]] || { echo "$output"; return 1; }
  grep -Fx "$DONOR" "$trace" >/dev/null || { echo 'canonical owner validation was not reached'; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'invalid owner published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ]
}

@test "T13 canonical preflight validates each owner once with multiple donors" {
  local mini="$SANDBOX/t13-owner-many" trace="$SANDBOX/t13-owner-many.log" third="$SANDBOX/third"
  local owner owner_list="$SANDBOX/t13-owners-before"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' > "$owner_list"
  git -C "$PROJECT" worktree add -q -b t13-third "$third"
  t13_owner_validation_wrapper "$mini"
  run bash -c '
    . "$1"
    SCRIPT_DIR="$4"
    export T13_REAL_ATTACH="$1" T13_OWNER_VALIDATION_TRACE="$5"
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$third" "$mini" "$trace"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  while IFS= read -r owner; do
    [ "$(grep -Fxc "$owner" "$trace")" -eq 1 ] || { echo "wrong validation count for $owner"; return 1; }
  done < "$owner_list"
  [ "$(wc -l < "$trace" | tr -d ' ')" -eq 2 ] || { echo 'expected both original owners once'; return 1; }
}

@test "T13 malformed unselected owner still misses before any publication" {
  local mini="$SANDBOX/t13-owner-sibling" trace="$SANDBOX/t13-owner-sibling.log" third="$SANDBOX/third" sibling
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  sibling="$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' | LC_ALL=C sort | tail -1)"
  jq '.git_hooks.previous_hooks_path = ""' "$sibling" > "$SANDBOX/invalid-sibling.json"
  chmod 600 "$SANDBOX/invalid-sibling.json"
  mv "$SANDBOX/invalid-sibling.json" "$sibling"
  git -C "$PROJECT" worktree add -q -b t13-third "$third"
  t13_owner_validation_wrapper "$mini"
  run bash -c '
    . "$1"
    SCRIPT_DIR="$4"
    export T13_REAL_ATTACH="$1" T13_OWNER_VALIDATION_TRACE="$5"
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "full-path\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$third" "$mini" "$trace"
  [ "$status" -eq 5 ] && [[ "$output" == *'full-path'* ]] || { echo "$output"; return 1; }
  grep -Fx "$sibling" "$trace" >/dev/null || { echo 'canonical sibling validation was not reached'; return 1; }
  [ ! -e "$third/.trellis/runtime" ] || { echo 'invalid sibling published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ]
}

@test "T13 identical sibling excludes share one canonical check per exact value" {
  local mini="$SANDBOX/t13-exclude-count" trace="$SANDBOX/t13-exclude-count.log" owners="$SANDBOX/t13-exclude-owners.log"
  local third="$SANDBOX/third" fourth="$SANDBOX/fourth" owner distinct
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  git -C "$PROJECT" worktree add -q -b t13-third "$third"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$third"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  distinct="$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -exec jq -cS .exclude {} \; | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  [ "$distinct" -lt 3 ] || { echo 'fixture has no repeated exact excludes'; return 1; }
  git -C "$PROJECT" worktree add -q -b t13-fourth "$fourth"
  t13_owner_validation_wrapper "$mini"
  run bash -c '
    . "$1"
    SCRIPT_DIR="$4"
    export T13_REAL_ATTACH="$1" T13_OWNER_VALIDATION_TRACE="$5" T13_EXCLUDE_VALIDATION_TRACE="$6"
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$fourth" "$mini" "$owners" "$trace"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  [ "$(wc -l < "$trace" | tr -d ' ')" -eq "$distinct" ] || { echo 'repeated exact excludes were reverified'; return 1; }
  [ "$(LC_ALL=C sort -u "$trace" | wc -l | tr -d ' ')" -eq "$distinct" ] || { echo 'traced exclude values differ from fixture owners'; return 1; }
}

@test "T13 malformed sibling exclude block still misses before publication" {
  local third="$SANDBOX/third" owner sibling=""
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  while IFS= read -r owner; do
    if jq -e '.git_hooks.enabled == false' "$owner" >/dev/null; then sibling="$owner"; fi
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json')
  [ -n "$sibling" ] || { echo 'missing non-authority owner'; return 1; }
  jq '.exclude.managed_block_base64 = "YQ=="' "$sibling" > "$SANDBOX/invalid-exclude.json"
  chmod 600 "$SANDBOX/invalid-exclude.json"
  mv "$SANDBOX/invalid-exclude.json" "$sibling"
  git -C "$PROJECT" worktree add -q -b t13-third "$third"
  run bash -c '
    . "$1"
    export TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "full-path\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$third"
  [ "$status" -eq 5 ] && [[ "$output" == *'full-path'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'invalid exclude owner'* ]] || { echo "$output"; return 1; }
  [ ! -e "$third/.trellis/runtime" ] || { echo 'invalid sibling exclude published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ]
}

@test "T13 sibling exclude record naming another file misses before publication" {
  local third="$SANDBOX/third" owner sibling=""
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  while IFS= read -r owner; do
    if jq -e '.git_hooks.enabled == false' "$owner" >/dev/null; then sibling="$owner"; fi
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json')
  [ -n "$sibling" ] || { echo 'missing non-authority owner'; return 1; }
  # Reusing the shared capture is sound only for records naming that file.
  # The canonical owner schema binds the path to the record's common dir and
  # the donor binds that to the pinned one; this proves the refusal survives.
  : > "$SANDBOX/foreign-exclude"
  jq --arg path "$SANDBOX/foreign-exclude" '.exclude.path = $path' "$sibling" > "$SANDBOX/foreign-exclude.json"
  chmod 600 "$SANDBOX/foreign-exclude.json"
  mv "$SANDBOX/foreign-exclude.json" "$sibling"
  git -C "$PROJECT" worktree add -q -b t13-third "$third"
  run bash -c '
    . "$1"
    export TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "full-path\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$third"
  [ "$status" -eq 5 ] && [[ "$output" == *'full-path'* ]] || { echo "$output"; return 1; }
  # Selected donor or sibling: both refusals come from the canonical schema.
  [[ "$output" == *'preflight refused: invalid owner'* || "$output" == *'preflight refused: non-exact donor owner'* ]] ||
    { echo "$output"; return 1; }
  [ ! -e "$third/.trellis/runtime" ] || { echo 'foreign sibling exclude published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ]
}

@test "T13 ignored registry namespace blocks donor publication" {
  jq --arg target "$TARGET" '.discovery_ignores = (.discovery_ignores // {})
      | .discovery_ignores.personal = [{"path":$target,"reason":"project-reserved"}]' \
    "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-with-ignore.json"
  chmod 600 "$SANDBOX/registry-with-ignore.json"
  mv "$SANDBOX/registry-with-ignore.json" "$TRELLIS_HOME/registry.json"
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
  run bash -c '
    . "$1"
    export TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "canonical-fallback\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  cmp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'ignored root published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ] || { echo 'ignored root published a journal'; echo "$output"; return 1; }
  [ "$status" -eq 5 ] && [[ "$output" == *'canonical-fallback'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'identity or path collision'* ]] || { echo "$output"; return 1; }
}

@test "T13 modified managed hook still misses before publication" {
  local managed="$TRELLIS_HOME/state/git-hooks/$(jq -r .checkout_id "$DONOR")/post-checkout"
  printf '# t13-hook-drift\n' >> "$managed"
  run bash -c '
    . "$1"
    export TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "canonical-fallback\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 5 ] && [[ "$output" == *'canonical-fallback'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'invalid managed hooks'* ]] || { echo "$output"; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'hook drift published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ]
}

@test "T13 hardlinked donor artifact misses and falls back to canonical attach" {
  local donor_file="$PROJECT/.claude/settings.local.json"
  ln "$donor_file" "$SANDBOX/donor-hardlink"
  run bash -c '
    . "$1"
    export TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "canonical-fallback\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 5 ] && [[ "$output" == *'canonical-fallback'* ]] || { echo "$output"; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'fast miss published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ]
  run env TRELLIS_FASTPATH_TRACE=1 "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'donor fast-path miss:'* ]] || { echo 'the complete attach did not demonstrate a fast-path miss'; echo "$output"; return 1; }
  [[ "$output" != *'donor fast path'* ]] || { echo 'hardlinked donor used the fast path'; return 1; }
  [ -L "$TARGET/.trellis/runtime" ] && [ -f "$TARGET/.claude/settings.local.json" ]
  [ "$donor_file" -ef "$SANDBOX/donor-hardlink" ] || { echo 'donor hardlink was changed'; return 1; }
}

@test "T13 project-appended donor hooks remain unowned through canonical fallback" {
  local donor_file="$PROJECT/.claude/settings.local.json"
  jq '.hooks.PreToolUse[0].hooks += [{"type":"command","command":"t13-project-hook"}]
      | .hooks.PreToolUse += [{"matcher":"t13-project-block","hooks":[{"type":"command","command":"t13-project-block-hook"}]}]' \
    "$donor_file" > "$SANDBOX/donor-with-project-hooks.json"
  chmod 600 "$SANDBOX/donor-with-project-hooks.json"
  mv "$SANDBOX/donor-with-project-hooks.json" "$donor_file"
  run bash -c '. "$1"; _attachment_verify_owner_artifacts_impl "$2" "$3"' t13 \
    "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$DONOR"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash -c '
    . "$1"
    export TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "canonical-fallback\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 5 ] && [[ "$output" == *'canonical-fallback'* ]] || { echo "$output"; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'fast miss published an artifact'; return 1; }
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *'donor fast path'* ]] || { echo 'modified project hooks used the fast path'; return 1; }
  jq -e 'any(.hooks.PreToolUse[0].hooks[]; .command == "t13-project-hook")
      and any(.hooks.PreToolUse[]; .matcher == "t13-project-block")' "$donor_file" >/dev/null
  jq -e 'all(.hooks.PreToolUse[0].hooks[]; .command != "t13-project-hook")
      and all(.hooks.PreToolUse[]; .matcher != "t13-project-block")' "$TARGET/.claude/settings.local.json" >/dev/null
}

@test "T13 donor render with recorded project hook is a read-only miss" {
  local donor_file="$PROJECT/.claude/settings.local.json"
  /usr/bin/python3 -I - "$donor_file" "$DONOR" <<'PY'
import base64, hashlib, json, os, sys
path, owner_path = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    guard = json.load(stream)
guard['hooks']['PreToolUse'][0]['hooks'].append({'type': 'command', 'command': 't13-recorded-project-hook'})
data = (json.dumps(guard, sort_keys=True) + '\n').encode()
with open(path, 'wb') as stream:
    stream.write(data)
os.chmod(path, 0o600)
with open(owner_path, encoding='utf-8') as stream:
    owner = json.load(stream)
for artifact in owner['artifacts']:
    if artifact['path'] == '.claude/settings.local.json':
        artifact['sha256'] = hashlib.sha256(data).hexdigest()
for render in owner['renders']:
    if render['path'] == '.claude/settings.local.json':
        render['after_sha256'] = hashlib.sha256(data).hexdigest()
        render['after_base64'] = base64.b64encode(data).decode()
with open(owner_path, 'w', encoding='utf-8') as stream:
    json.dump(owner, stream, sort_keys=True)
    stream.write('\n')
os.chmod(owner_path, 0o600)
PY
  run bash -c '. "$1"; _attachment_verify_owner_artifacts_impl "$2" "$3"' t13 \
    "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$DONOR"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash -c '
    . "$1"
    export TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "canonical-fallback\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  if [ -e "$TARGET/.trellis/runtime" ] || [ -L "$TARGET/.trellis/runtime" ]; then
    if jq -e 'any(.hooks.PreToolUse[0].hooks[]; .command == "t13-recorded-project-hook")' \
      "$TARGET/.claude/settings.local.json" >/dev/null 2>&1; then echo 'project hook copied into target'; fi
    echo 'recorded project hook was published'; return 1
  fi
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ]
  [ "$status" -eq 5 ] && [[ "$output" == *'canonical-fallback'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'guard template differs'* ]] || { echo "$output"; return 1; }
}

@test "T13 holds three lock descriptors during capture and closes them before registry publication" {
  local trace="$SANDBOX/t13-fd-stages"
  run bash -c '
    . "$1"
    TEST_FD_LOG="$4"
    export TRELLIS_FASTPATH_TRACE=1
    eval "$(declare -f local_registry_read_diagnostic_state | sed "1s/local_registry_read_diagnostic_state/t13_original_registry_read/")"
    eval "$(declare -f local_registry_write_locked_bound_rows | sed "1s/local_registry_write_locked_bound_rows/t13_original_registry_write/")"
    local_registry_read_diagnostic_state() {
      { : <&31; } 2>/dev/null && { : <&32; } 2>/dev/null && { : <&33; } 2>/dev/null || { echo "lock fd missing at capture" >&2; return 99; }
      printf "open\n" >> "$TEST_FD_LOG"
      t13_original_registry_read "$@"
    }
    local_registry_write_locked_bound_rows() {
      if { : <&31; } 2>/dev/null || { : <&32; } 2>/dev/null || { : <&33; } 2>/dev/null; then
        echo "lock fd leaked past post-journal check" >&2
        return 99
      fi
      printf "closed\n" >> "$TEST_FD_LOG"
      t13_original_registry_write "$@"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$trace"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  [ "$(< "$trace")" = $'open\nclosed' ] || { echo "wrong fd stages"; return 1; }
}

@test "T13 pin checks keep their verdicts and launch uname at most once per process" {
  local trace="$SANDBOX/t13-uname-unit"
  mkdir -p "$SANDBOX/t13-pin-a" "$SANDBOX/t13-pin-b"
  : > "$trace"
  run bash -c '
    . "$1"
    # A function stands in for the binary, so PATH (and the caller toolchain
    # the donor proof compares) is unchanged; it counts each launch request.
    uname() { [ "$T13_IN_PIN" != 1 ] || printf "uname\n" >> "$T13_UNAME_TRACE"; command uname "$@"; }
    T13_UNAME_TRACE="$3" T13_IN_PIN=1
    exec 40<"$4"
    for check in 1 2 3 4; do attach_t13_pin_matches 40 "$4" || { echo "check $check missed" >&2; exit 1; }; done
    attach_t13_pin_matches 40 "$5" && { echo "a different holder matched" >&2; exit 1; }
    exec 40<&-
    exit 0
  ' t13 "$ATTACH" unused "$trace" "$SANDBOX/t13-pin-a" "$SANDBOX/t13-pin-b"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$trace" | tr -d ' ')" -le 1 ] || { echo "uname launched $(wc -l < "$trace" | tr -d ' ') times for five checks"; return 1; }
}

@test "T13 donor attach pin checks launch no uname after the checkout pin opens" {
  local trace="$SANDBOX/t13-uname-attach" checks="$SANDBOX/t13-pin-checks"
  : > "$trace"
  run bash -c '
    . "$1"
    uname() { [ "$T13_IN_PIN" != 1 ] || printf "uname\n" >> "$T13_UNAME_TRACE"; command uname "$@"; }
    T13_UNAME_TRACE="$3" T13_PIN_CHECKS="$4" T13_IN_PIN=0
    eval "$(declare -f attach_t13_pin_matches | sed "1s/attach_t13_pin_matches/t13_original_pin_matches/")"
    attach_t13_pin_matches() {
      local rc=0
      printf "check %s\n" "$1" >> "$T13_PIN_CHECKS"
      T13_IN_PIN=1
      t13_original_pin_matches "$@" || rc=$?
      T13_IN_PIN=0
      return "$rc"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$5" --fleet personal --release 1.2.3 "$6"
  ' t13 "$ATTACH" unused "$trace" "$checks" "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  [ "$(wc -l < "$checks" | tr -d ' ')" -eq 4 ] || { echo "expected four pin checks:"; cat "$checks"; return 1; }
  [ ! -s "$trace" ] || { echo "pin checks launched uname $(wc -l < "$trace" | tr -d ' ') times"; return 1; }
}

@test "T13 unrelated fd 3 and 4 do not break donor attach or the calling shell" {
  run bash -c '
    exec 3<"$4" 4<"$4"
    . "$1"
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3" || exit $?
    { : <&3; } && { : <&4; } || { echo "caller fds were closed" >&2; exit 99; }
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$PROJECT/.trellis.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
}

@test "T13 occupied private fd numbers fall back without clobbering the caller" {
  local fd target result_file="$SANDBOX/t13-caller-fd"
  printf 'caller-owned-descriptor\n' > "$result_file"
  for fd in 31 32 33; do
    target="$SANDBOX/fd-$fd"
    git -C "$PROJECT" worktree add -q -b "t13-fd-$fd" "$target"
    run bash -c '
      case "$4" in
        31) exec 31<"$5" ;;
        32) exec 32<"$5" ;;
        33) exec 33<"$5" ;;
        *) exit 99 ;;
      esac
      . "$1"
      trellis_attach_postjob_spawn() { :; }
      attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3" || exit $?
      case "$4" in
        31) IFS= read -r value <&31 ;;
        32) IFS= read -r value <&32 ;;
        33) IFS= read -r value <&33 ;;
      esac
      [ "$value" = caller-owned-descriptor ] || { echo "caller descriptor changed" >&2; exit 99; }
    ' t13 "$ATTACH" "$TRELLIS_HOME" "$target" "$fd" "$result_file"
    [ "$status" -eq 0 ] || { echo "fd $fd: $output"; return 1; }
    [[ "$output" != *'donor fast path'* ]] || { echo "occupied fd $fd used donor fastpath"; return 1; }
    [ -L "$target/.trellis/runtime" ] || { echo "fd $fd canonical fallback not ready"; return 1; }
  done
}

@test "T13 fsmonitor spawned by a Python Git child cannot inherit lock descriptors" {
  local hook="$SANDBOX/t13-fsmonitor" witness="$SANDBOX/t13-fsmonitor-called"
  cat > "$hook" <<'PY'
#!/usr/bin/python3
import json, os, subprocess, sys
opened = []
for fd in (31, 32, 33):
    try:
        os.fstat(fd)
        opened.append(fd)
    except OSError:
        pass
ancestry = []
pid = os.getppid()
for _ in range(4):
    try:
        row = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'ppid=', '-o', 'command='], text=True).strip()
        parent, command = row.split(None, 1)
        ancestry.append({'pid': pid, 'command': command})
        pid = int(parent)
        if pid <= 1:
            break
    except (OSError, subprocess.CalledProcessError, ValueError):
        break
with open(os.environ['T13_FS_LOG'], 'a', encoding='utf-8') as out:
    out.write('hook ' + json.dumps({'pid': os.getpid(), 'ppid': os.getppid(), 'pins': opened, 'argv': sys.argv[1:], 'ancestry': ancestry}) + '\n')
sys.stdout.buffer.write(b'0\0')
PY
  chmod 700 "$hook"
  git -C "$TARGET" config --local core.fsmonitor "$hook"
  run bash -c '
    . "$1"
    export T13_FS_LOG="$4"
    git() {
      local pins=""
      { : <&31; } 2>/dev/null && pins="$pins 31"
      { : <&32; } 2>/dev/null && pins="$pins 32"
      { : <&33; } 2>/dev/null && pins="$pins 33"
      printf "git %s pins=%s\n" "$*" "$pins" >> "$T13_FS_LOG"
      command git "$@"
    }
    eval "$(declare -f local_registry_read_diagnostic_state | sed "1s/local_registry_read_diagnostic_state/t13_original_registry_read/")"
    local_registry_read_diagnostic_state() { printf "capture\n" >> "$T13_FS_LOG"; t13_original_registry_read "$@"; }
    eval "$(declare -f local_registry_write_locked_bound_rows | sed "1s/local_registry_write_locked_bound_rows/t13_original_registry_write/")"
    local_registry_write_locked_bound_rows() { printf "postjournal\n" >> "$T13_FS_LOG"; t13_original_registry_write "$@"; }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$witness"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
  run /usr/bin/python3 -I - "$witness" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
hooks = [(index, json.loads(line[5:])) for index, line in enumerate(lines) if line.startswith('hook ')]
assert hooks, 'configured fsmonitor hook did not run in this fixture'
for index, hook in hooks:
    assert hook['pins'] == [], hook
    assert 'capture' in lines[:index] and 'postjournal' in lines[index + 1:], lines
    assert any('attach-fastpath.py' in item['command'] for item in hook['ancestry']), hook
PY
  [ "$status" -eq 0 ] || { echo "$output"; grep -E '^(hook |capture|postjournal|git )' "$witness"; return 1; }
}

@test "T13 Bash 3.2 TERM closes every pinned fd before releasing locks" {
  local pidfile="$SANDBOX/t13-term-pid" trace="$SANDBOX/t13-term-trace" log="$SANDBOX/t13-term.log"
  local runner pid tries=0 rc=0
  /bin/bash -c '
    . "$1"
    TEST_PIDFILE="$4" TEST_TRACE="$5"
    eval "$(declare -f local_registry_read_diagnostic_state | sed "1s/local_registry_read_diagnostic_state/t13_original_registry_read/")"
    eval "$(declare -f _attachment_lock_release | sed "1s/_attachment_lock_release/t13_original_attachment_release/")"
    eval "$(declare -f _attachment_checkout_lock_release | sed "1s/_attachment_checkout_lock_release/t13_original_checkout_release/")"
    local_registry_read_diagnostic_state() {
      { : <&31; } 2>/dev/null && { : <&32; } 2>/dev/null && { : <&33; } 2>/dev/null || return 99
      printf "%s\n" "$_ATTACHMENT_PROCESS_PID" > "$TEST_PIDFILE"
      /bin/sleep 3
      t13_original_registry_read "$@"
    }
    _attachment_lock_release() {
      if { : <&31; } 2>/dev/null || { : <&32; } 2>/dev/null || { : <&33; } 2>/dev/null; then
        printf "fast-open\n" >> "$TEST_TRACE"
      else printf "fast-closed\n" >> "$TEST_TRACE"; fi
      t13_original_attachment_release "$@"
    }
    _attachment_checkout_lock_release() {
      if { : <&31; } 2>/dev/null; then printf "checkout-open\n" >> "$TEST_TRACE"
      else printf "checkout-closed\n" >> "$TEST_TRACE"; fi
      t13_original_checkout_release "$@"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$pidfile" "$trace" > "$log" 2>&1 &
  runner=$!
  while [ ! -s "$pidfile" ] && kill -0 "$runner" 2>/dev/null && [ "$tries" -lt 300 ]; do
    /bin/sleep 0.1
    tries=$((tries + 1))
  done
  if [ ! -s "$pidfile" ]; then
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    echo 'lock-fd signal seam was not reached'; return 1
  fi
  pid="$(< "$pidfile")"
  kill -TERM "$pid" || return 1
  wait "$runner" || rc=$?
  [ "$rc" -ne 0 ] || { echo 'TERM reported successful attach'; return 1; }
  grep -Fx 'fast-closed' "$trace" >/dev/null || { echo 'fast lock fd not closed before release'; return 1; }
  grep -Fx 'checkout-closed' "$trace" >/dev/null || { echo 'checkout fd not closed before release'; return 1; }
  ! grep -E '^(fast|checkout)-open$' "$trace" >/dev/null || { echo 'a pinned fd leaked into release'; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'TERM left a published artifact'; return 1; }
}

t13_assert_equal_token_lock_replacement() {
  local kind="$1" trace="$SANDBOX/t13-replaced-$1"
  run bash -c '
    . "$1"
    TEST_HOLDER_LOG="$4" TEST_HOLDER_KIND="$5"
    eval "$(declare -f local_registry_read_diagnostic_state | sed "1s/local_registry_read_diagnostic_state/t13_original_registry_read/")"
    local_registry_read_diagnostic_state() {
      local holder token=owner.json
      case "$TEST_HOLDER_KIND" in
        checkout) holder="$_ATTACHMENT_CHECKOUT_LOCK_HOLDER" ;;
        attachment) holder="$_ATTACHMENT_LOCK_HOLDER" ;;
        registry) holder="$_TRELLIS_HOME_LOCK_DIR"; token=pid ;;
        *) return 99 ;;
      esac
      printf "%s\n" "$holder" > "$TEST_HOLDER_LOG"
      mv "$holder" "$holder.original" || return 99
      mkdir -m 700 "$holder" || return 99
      cp "$holder.original/$token" "$holder/$token" || return 99
      chmod 600 "$holder/$token" || return 99
      t13_original_registry_read "$@"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$trace" "$kind"
  [ -s "$trace" ] || { echo 'replacement seam was not reached'; return 1; }
  [ "$status" -ne 0 ] || { echo 'replacement lock authorized an attach'; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'artifact published after lock replacement'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 0 ] || { echo 'journal published after lock replacement'; return 1; }
  [ -d "$(< "$trace")" ] || { echo 'unknown replacement lock was deleted'; return 1; }
}

@test "T13 equal-token checkout lock replacement before Python refuses and is retained" {
  t13_assert_equal_token_lock_replacement checkout
}

@test "T13 equal-token attachment lock replacement before Python refuses and is retained" {
  t13_assert_equal_token_lock_replacement attachment
}

@test "T13 equal-token registry lock replacement before Python refuses and is retained" {
  t13_assert_equal_token_lock_replacement registry
}

# qp H3: the same equal-token replacement after --begin, at the registry write.
# The journal exists, so the refusal is recoverable; the replacement holder is
# evidence and must survive cleanup.
t13_assert_post_begin_lock_replacement() {
  local kind="$1" trace="$SANDBOX/t13-post-begin-$1"
  run bash -c '
    . "$1"
    TEST_HOLDER_LOG="$4" TEST_HOLDER_KIND="$5"
    eval "$(declare -f local_registry_write_locked_bound_rows | sed "1s/local_registry_write_locked_bound_rows/t13_original_bound_write/")"
    local_registry_write_locked_bound_rows() {
      local holder token=owner.json
      case "$TEST_HOLDER_KIND" in
        checkout) holder="$_ATTACHMENT_CHECKOUT_LOCK_HOLDER" ;;
        attachment) holder="$_ATTACHMENT_LOCK_HOLDER" ;;
        registry) holder="$_TRELLIS_HOME_LOCK_DIR"; token=pid ;;
        *) return 99 ;;
      esac
      printf "%s\n" "$holder" > "$TEST_HOLDER_LOG"
      mv "$holder" "$holder.original" || return 99
      mkdir -m 700 "$holder" || return 99
      cp "$holder.original/$token" "$holder/$token" || return 99
      chmod 600 "$holder/$token" || return 99
      t13_original_bound_write "$@"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$trace" "$kind"
  [ -s "$trace" ] || { echo 'post-begin replacement seam was not reached'; return 1; }
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" == *'run trellis recover'* ]] || { echo "$output"; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'artifact published after lock replacement'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" = 1 ] || { echo 'journal not retained for recovery'; return 1; }
  [ -d "$(< "$trace")" ] || { echo 'unknown replacement lock was deleted'; return 1; }
}

@test "T13 qp-H3 equal-token checkout lock replacement after begin stops publication and is retained" {
  t13_assert_post_begin_lock_replacement checkout
}

@test "T13 qp-H3 equal-token attachment lock replacement after begin stops publication and is retained" {
  t13_assert_post_begin_lock_replacement attachment
}

@test "T13 qp-H3 equal-token registry lock replacement after begin stops publication and is retained" {
  t13_assert_post_begin_lock_replacement registry
}

@test "T13 qp-H3 the registry write and finish keep the pins in the parent, never in children" {
  local trace="$SANDBOX/t13-finish-pins"
  run bash -c '
    . "$1"
    TEST_FD_LOG="$4"
    eval "$(declare -f local_registry_write_locked_bound_rows | sed "1s/local_registry_write_locked_bound_rows/t13_original_bound_write/")"
    local_registry_write_locked_bound_rows() {
      /bin/bash -c "for fd in 31 32 33; do { : <&\$fd; } 2>/dev/null && echo child-open-\$fd; done; exit 0" >> "$TEST_FD_LOG"
      t13_original_bound_write "$@" || return
      printf "written\n" >> "$TEST_FD_LOG"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3" || exit
    [ "$(< "$TEST_FD_LOG")" = written ] || exit 98
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$trace"
  [ "$status" -eq 0 ] || { echo "$output"; cat "$trace"; return 1; }
  [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; return 1; }
}

@test "A5B takes fast path and invokes the async hook after ownership" {
  run bash -c '
    . "$1"
    trellis_attach_postjob_spawn() {
      owner="$(attach_existing_owner "$1" "$(local_registry_identity_for_root "$2")")" || return 1
      jq -e --arg root "$2" '\'' .status == "committed" and .worktree_root == $root '\'' "$owner" >/dev/null || return 1
      printf "postjob:%s\n" "$2"
    }
    attach_cmd_attach --home "$3" --fleet personal --release 1.2.3 "$4"
  ' a5b "$ATTACH" "$PROJECT" "$TRELLIS_HOME" "$TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
  [[ "$output" == *'postjob:'* ]]
  run bash -c '. "$1"; attachment_verify "$2" "$3"' a5b "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' ! -path "$DONOR")"
  [ "$status" -eq 0 ]
  if [ -n "${A5B_BENCH_REPORT:-}" ]; then
    run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bench-attach-fastpath.py" "$ATTACH" "$TRELLIS_HOME" "$PROJECT" "$SANDBOX" "$A5B_BENCH_REPORT"
    [ "$status" -eq 0 ]
  fi
}

@test "A5B existing project guard falls back to the full renderer" {
  mkdir -p "$TARGET/.claude"
  printf '{"project_note":"keep me"}\n' > "$TARGET/.claude/settings.local.json"
  fast_attach
  [ "$status" -eq 0 ]
  [[ "$output" != *'donor fast path'* ]]
  [ "$(jq -r .project_note "$TARGET/.claude/settings.local.json")" = 'keep me' ]
}

@test "A5B every eligibility failure enters the existing full path" {
  # A slow-path sentinel proves dispatch, without mistaking a refusal for fallback.
  cp "$DONOR" "$SANDBOX/donor-before"
  cp "$PROJECT/.claude/settings.local.json" "$SANDBOX/guard-before"
  cp "$TRELLIS_HOME/releases/1.2.3/release.json" "$SANDBOX/release-before"
  cp "$TRELLIS_HOME/releases/1.2.3/payload/scripts/seed-inheritance-symlinks.sh" "$SANDBOX/seeder-before"
  for failure in release harness donor-file donor-mode render-pairing guard-symlink parent-symlink hooks journal manifest release-pin executed-file toolchain pre-existing; do
    run bash -c '
      . "$1"
      release_store_locate() { printf "full-path\n" >&2; return 5; }
      donor="$6"
      args=()
      case "$5" in
        release|pre-existing|toolchain|render-pairing)
          case "$5" in
            release) filter=".release = \"8.8.8\"" ;;
            pre-existing) filter=".pre_existing = [{kind:\"file\",path:\"note\",reason:\"project-authored-render\",target:null}]" ;;
            toolchain) filter=".toolchain_path = [\"/does-not-exist-a5b\"]" ;;
            render-pairing) filter="(.renders[] | select(.path == \".claude/settings.local.json\") | .after_sha256) = (\"0\" * 64)" ;;
          esac
          jq "$filter" "$donor" > "$donor.next" && mv "$donor.next" "$donor" && chmod 600 "$donor" ;;
        harness) args=(--harness claude) ;;
        donor-file) printf "tampered\n" >> "$2/.claude/settings.local.json" ;;
        donor-mode) chmod 644 "$donor" ;;
        guard-symlink) mkdir -p "$4/.claude"; ln -s "$2/.claude/settings.local.json" "$4/.claude/settings.local.json" ;;
        parent-symlink) ln -s "$2/.claude" "$4/.claude" ;;
        hooks) git -C "$4" config --local core.hooksPath "$7/other-hooks" ;;
        journal) printf "{}\n" > "$3/state/attachment-journals/pending.json"; chmod 600 "$3/state/attachment-journals/pending.json" ;;
        manifest) printf "{\"schema_version\":1,\"project_id\":\"other-project\"}\n" > "$4/.trellis.json" ;;
        release-pin) chmod u+w "$3/releases/1.2.3/release.json"; printf " \n" >> "$3/releases/1.2.3/release.json"; chmod a-w "$3/releases/1.2.3/release.json" ;;
        executed-file) chmod u+w "$3/releases/1.2.3/payload/scripts/seed-inheritance-symlinks.sh"; printf "# tampered\n" >> "$3/releases/1.2.3/payload/scripts/seed-inheritance-symlinks.sh"; chmod a-w "$3/releases/1.2.3/payload/scripts/seed-inheritance-symlinks.sh" ;;
      esac
      attach_cmd_attach --home "$3" --fleet personal --release 1.2.3 "${args[@]+"${args[@]}"}" "$4"
    ' a5b "$ATTACH" "$PROJECT" "$TRELLIS_HOME" "$TARGET" "$failure" "$DONOR" "$SANDBOX"
    [ "$status" -eq 5 ]
    [[ "$output" == *'full-path'* ]]
    [ ! -e "$TARGET/.trellis/runtime" ]
    /usr/bin/python3 - "$SANDBOX" "$DONOR" "$PROJECT" "$TARGET" "$TRELLIS_HOME" <<'PY'
import os, shutil, sys
sandbox, donor, project, target, home = sys.argv[1:]
for src, dst, mode in [('donor-before', donor, 0o600), ('guard-before', project+'/.claude/settings.local.json', 0o600), ('release-before', home+'/releases/1.2.3/release.json', 0o444), ('seeder-before', home+'/releases/1.2.3/payload/scripts/seed-inheritance-symlinks.sh', 0o555)]:
    os.chmod(dst, 0o600)
    shutil.copyfile(sandbox+'/'+src, dst)
    os.chmod(dst, mode)
path = target+'/.claude'
if os.path.islink(path):
    os.unlink(path)
elif os.path.isdir(path):
    shutil.rmtree(path)
path = home+'/state/attachment-journals/pending.json'
if os.path.exists(path):
    os.unlink(path)
shutil.copyfile(project+'/.trellis.json', target+'/.trellis.json')
PY
    git -C "$TARGET" config --local core.hooksPath "$TRELLIS_HOME/state/git-hooks/$(jq -r .checkout_id "$DONOR")"
  done
}

@test "A5B unreadable or unimportable helpers miss before publication" {
  mkdir -p "$SANDBOX/mini/lib"
  cp "$REPO_ROOT/scripts/lib/attach-fastpath.py" "$SANDBOX/mini/lib/"
  cp "$REPO_ROOT/scripts/lib/release-executed.py" "$SANDBOX/mini/lib/"
  for broken in attach-fastpath.py release-executed.py; do
    chmod 000 "$SANDBOX/mini/lib/$broken"
    run bash -c '
      . "$1"
      SCRIPT_DIR="$4"
      release_store_locate() { printf "full-path\n" >&2; return 5; }
      attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
    ' a5b "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$SANDBOX/mini"
    [ "$status" -eq 5 ]
    [[ "$output" == *'full-path'* ]]
    [ ! -e "$TARGET/.trellis/runtime" ]
    chmod 600 "$SANDBOX/mini/lib/$broken"
  done
  printf 'invalid Python\n' > "$SANDBOX/mini/lib/release-executed.py"
  run bash -c '
    . "$1"
    SCRIPT_DIR="$4"
    release_store_locate() { printf "full-path\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' a5b "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$SANDBOX/mini"
  [ "$status" -eq 5 ]
  [[ "$output" == *'full-path'* ]]
  [ ! -e "$TARGET/.trellis/runtime" ]
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "A5B valid expected donor binding retains the fast path" {
  run bash -c '
    . "$1"
    target="$3"; donor="$4"
    identity="$(local_registry_identity_for_root "$target")"
    checkout="$(printf "%s\n" "$identity" | jq -r .checkout_id)"
    worktree="$(printf "%s\n" "$identity" | jq -r .worktree_id)"
    donor_root="$(jq -r .worktree_root "$donor")"
    donor_worktree="$(jq -r .worktree_id "$donor")"
    donor_id="$(jq -r .attachment_id "$donor")"
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 \
      --expected-fleet personal --expected-project-id a5b-fixture \
      --expected-root "$target" --expected-checkout-id "$checkout" \
      --expected-worktree-id "$worktree" --expected-attachment-id "" \
      --expected-release 1.2.3 --expected-harnesses-json '\''["claude","codex"]'\'' \
      --expected-donor-root "$donor_root" --expected-donor-checkout-id "$checkout" \
      --expected-donor-worktree-id "$donor_worktree" --expected-donor-attachment-id "$donor_id" \
      --expected-donor-release 1.2.3 --expected-donor-harnesses-json '\''["claude","codex"]'\'' \
      "$target"
  ' a5b "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$DONOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
}

@test "A5B repair selection mismatch refuses without publication" {
  for mismatch in fleet forced-verify fast-selection; do
    run bash -c '
      . "$1"
      target="$3"; donor="$4"; mismatch="$5"
      identity="$(local_registry_identity_for_root "$target")"
      checkout="$(printf "%s\n" "$identity" | jq -r .checkout_id)"
      worktree="$(printf "%s\n" "$identity" | jq -r .worktree_id)"
      fleet=personal
      if [ "$mismatch" = fleet ]; then fleet=other; fi
      if [ "$mismatch" = forced-verify ]; then
        attach_expected_binding_verify() { printf "binding-verify-refused\n" >&2; return 3; }
      elif [ "$mismatch" = fast-selection ]; then
        attach_expected_binding_matches_selection() { printf "fast-selection-refused\n" >&2; return 3; }
      fi
      attach_cmd_attach --home "$2" --fleet "$fleet" --release 1.2.3 \
        --expected-fleet personal --expected-project-id a5b-fixture \
        --expected-root "$target" --expected-checkout-id "$checkout" \
        --expected-worktree-id "$worktree" --expected-attachment-id "" \
        --expected-release 1.2.3 --expected-harnesses-json '\''["claude","codex"]'\'' \
        --expected-donor-root "$(jq -r .worktree_root "$donor")" --expected-donor-checkout-id "$checkout" \
        --expected-donor-worktree-id "$(jq -r .worktree_id "$donor")" \
        --expected-donor-attachment-id "$(jq -r .attachment_id "$donor")" \
        --expected-donor-release 1.2.3 --expected-donor-harnesses-json '\''["claude","codex"]'\'' \
        "$target"
    ' a5b "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$DONOR" "$mismatch"
    [ "$status" -eq 3 ]
    if [ "$mismatch" = fast-selection ]; then [[ "$output" == *'fast-selection-refused'* ]]; fi
    [ ! -e "$TARGET/.trellis/runtime" ]
    [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  done
}

@test "T13 donor binding changed after the early check refuses under the transaction locks" {
  local trace="$SANDBOX/t13-binding-trace"
  # No seam on the binding check: a concurrent registry writer moves the
  # checkout row's root to a reachable non-worktree between the unlocked early
  # check and the donor transaction. The donor proof binds checkout and worktree
  # IDs but never the checkout row's root, so the canonical binding verifier,
  # run on the lock-held capture, is what refuses.
  run bash -c '
    . "$1"
    target="$3"; donor="$4"; trace="$5"
    eval "$(declare -f attach_expected_binding_verify | sed "1s/attach_expected_binding_verify/t13_original_binding_verify/")"
    attach_expected_binding_verify() {
      local rc=0
      t13_original_binding_verify "$@" || rc=$?
      printf "verify args=%s rc=%s\n" "$#" "$rc" >> "$T13_BINDING_TRACE"
      return "$rc"
    }
    eval "$(declare -f trellis_home_resolve_release | sed "1s/trellis_home_resolve_release/t13_original_resolve_release/")"
    trellis_home_resolve_release() {
      local registry="$T13_HOME/registry.json"
      jq --arg root "$T13_HOME" ".projects |= with_entries(.value.checkouts |= with_entries(.value.root = \$root))" \
        "$registry" > "$registry.t13" && chmod 600 "$registry.t13" && mv "$registry.t13" "$registry" || return 99
      cp "$registry" "$T13_BINDING_TRACE.registry" || return 99
      printf "registry raced\n" >> "$T13_BINDING_TRACE"
      t13_original_resolve_release "$@"
    }
    export T13_BINDING_TRACE="$trace" T13_HOME="$2" T13_DONOR_ROOT="$(jq -r .worktree_root "$donor")"
    identity="$(local_registry_identity_for_root "$target")"
    checkout="$(printf "%s\n" "$identity" | jq -r .checkout_id)"
    worktree="$(printf "%s\n" "$identity" | jq -r .worktree_id)"
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 \
      --expected-fleet personal --expected-project-id a5b-fixture \
      --expected-root "$target" --expected-checkout-id "$checkout" \
      --expected-worktree-id "$worktree" --expected-attachment-id "" \
      --expected-release 1.2.3 --expected-harnesses-json '\''["claude","codex"]'\'' \
      --expected-donor-root "$T13_DONOR_ROOT" --expected-donor-checkout-id "$checkout" \
      --expected-donor-worktree-id "$(jq -r .worktree_id "$donor")" \
      --expected-donor-attachment-id "$(jq -r .attachment_id "$donor")" \
      --expected-donor-release 1.2.3 --expected-donor-harnesses-json '\''["claude","codex"]'\'' \
      "$target"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$DONOR" "$trace"
  printf '%s\n' "$(cat "$trace")"
  [ "$(sed -n 1p "$trace")" = 'verify args=5 rc=0' ] || { echo 'early binding check did not pass first'; return 1; }
  [ "$(sed -n 2p "$trace")" = 'registry raced' ] || { echo 'race was not between the checks'; return 1; }
  [ "$status" -eq 4 ] || { echo "status $status: $output"; return 1; }
  [ "$(sed -n 3p "$trace")" = 'verify args=6 rc=4' ] || { echo 'lock-held binding check did not refuse'; return 1; }
  [[ "$output" == *'target row failed strict local registry identity validation'* ]] || { echo "$output"; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'moved checkout row published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  cmp "$TRELLIS_HOME/registry.json" "$trace.registry" || { echo 'refused binding changed the registry'; return 1; }
}

@test "A5B registry publication must use the locked registry API" {
  run bash -c '
    . "$1"
    local_registry_write_locked_bound_rows() { printf "registry-api-called\n" >&2; return 4; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' a5b "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  [ "$status" -ne 0 ]
  [[ "$output" == *'registry-api-called'* ]]
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 0 ]
}

assert_fast_slow_parity() {
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
  fast_attach
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
  FAST_OWNER="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' ! -path "$DONOR")"
  cp "$FAST_OWNER" "$SANDBOX/fast-owner"
  /usr/bin/python3 - "$TARGET" "$SANDBOX/fast-owner" "$SANDBOX/artifact-bytes.json" <<'PY'
import base64, json, os, sys
root, owner, result = sys.argv[1:]
record = json.load(open(owner))
leaves = {a['path']: (os.readlink(root+'/'+a['path']) if a['kind']=='symlink' else base64.b64encode(open(root+'/'+a['path'],'rb').read()).decode()) for a in record['artifacts'] if a['kind'] in ('file','symlink')}
json.dump(leaves, open(result, 'w'), sort_keys=True)
PY
  run "$ATTACH" detach --home "$TRELLIS_HOME" "$TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  # Detach preserves empty parents. Restore the original target namespace so
  # both attaches own exactly the same parent directories.
  /usr/bin/python3 - "$TARGET" <<'PY'
import os, sys
root = sys.argv[1]
for path in ('.agents/rules', '.claude/rules', '.agents', '.claude', '.codex', '.trellis'):
    os.rmdir(os.path.join(root, path))
PY
  # Force a genuine slow-path miss using a function seam, not a security bypass.
  run bash -c '. "$1"; attach_try_donor_fastpath() { return 10; }; attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"' a5b "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  SLOW_OWNER="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' ! -path "$DONOR")"
  run /usr/bin/python3 - "$TARGET" "$SANDBOX/fast-owner" "$SLOW_OWNER" "$SANDBOX/artifact-bytes.json" <<'PY'
import base64, json, os, sys
root, fast, slow, snapshot = sys.argv[1:]
f, s = json.load(open(fast)), json.load(open(slow))
f.pop('attachment_id'); s.pop('attachment_id')
differences = {key: {'fast': f.get(key), 'slow': s.get(key)} for key in sorted(set(f) | set(s)) if f.get(key) != s.get(key)}
assert not differences, json.dumps(differences, indent=2, sort_keys=True)
actual = {a['path']: (os.readlink(root+'/'+a['path']) if a['kind']=='symlink' else base64.b64encode(open(root+'/'+a['path'],'rb').read()).decode()) for a in s['artifacts'] if a['kind'] in ('file','symlink')}
assert actual == json.load(open(snapshot))
PY
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "A5B owned artifact and owner metadata parity with the slow path" {
  assert_fast_slow_parity
}

@test "T13 unknown and historical owner or registry shapes are read-only misses" {
  local shape filter file owner_before="$SANDBOX/t13-shape-owner" registry_before="$SANDBOX/t13-shape-registry"
  cp "$DONOR" "$owner_before"
  cp "$TRELLIS_HOME/registry.json" "$registry_before"
  # Historical owners (no toolchain or exclude record) are still valid for the
  # canonical schema; unknown versions and keys are not. Either way the donor
  # transaction must leave everything as it found it and defer to canonical.
  for shape in owner-schema-2 owner-unknown-key owner-no-toolchain owner-no-exclude registry-schema-2 registry-unknown-key; do
    case "$shape" in
      owner-schema-2) filter='.schema_version = 2'; file="$DONOR" ;;
      owner-unknown-key) filter='.t13_future = true'; file="$DONOR" ;;
      owner-no-toolchain) filter='del(.toolchain_path)'; file="$DONOR" ;;
      owner-no-exclude) filter='del(.exclude, .exclude_block_hash)'; file="$DONOR" ;;
      registry-schema-2) filter='.schema_version = 2'; file="$TRELLIS_HOME/registry.json" ;;
      registry-unknown-key) filter='.t13_future = {}'; file="$TRELLIS_HOME/registry.json" ;;
    esac
    jq "$filter" "$file" > "$SANDBOX/t13-shape.json" && chmod 600 "$SANDBOX/t13-shape.json" && mv "$SANDBOX/t13-shape.json" "$file"
    cp "$DONOR" "$SANDBOX/t13-shape-owner-now"
    cp "$TRELLIS_HOME/registry.json" "$SANDBOX/t13-shape-registry-now"
    run bash -c '
      . "$1"
      export TRELLIS_FASTPATH_TRACE=1
      trellis_attach_postjob_spawn() { :; }
      release_store_locate() { printf "canonical-fallback\n" >&2; return 5; }
      attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
    ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET"
    [ "$status" -eq 5 ] && [[ "$output" == *'canonical-fallback'* ]] || { echo "$shape: status $status: $output"; return 1; }
    [ ! -e "$TARGET/.trellis/runtime" ] && [ ! -L "$TARGET/.trellis/runtime" ] || { echo "$shape published an artifact"; return 1; }
    [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ] || { echo "$shape left a journal"; return 1; }
    [ "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || { echo "$shape published an owner"; return 1; }
    cmp "$DONOR" "$SANDBOX/t13-shape-owner-now" || { echo "$shape changed the donor owner"; return 1; }
    cmp "$TRELLIS_HOME/registry.json" "$SANDBOX/t13-shape-registry-now" || { echo "$shape changed the registry"; return 1; }
    cp "$owner_before" "$DONOR"
    cp "$registry_before" "$TRELLIS_HOME/registry.json"
  done
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] && [[ "$output" == *'attached (donor fast path):'* ]] || { echo "restored fixture: $output"; return 1; }
}

@test "T13 proposal forged after begin makes finish refuse and recover restores state" {
  run bash -c '
    . "$1"
    eval "$(declare -f local_registry_write_locked_bound_rows | sed "1s/local_registry_write_locked_bound_rows/t13_original_bound_write/")"
    # Models a workspace swap between --begin and the Bash write: the writer
    # and any later path-based reader see the same forged proposal.
    local_registry_write_locked_bound_rows() {
      jq ".projects |= with_entries(.value.metadata.t13_forged = true)" "$2" > "$2.forged" && mv "$2.forged" "$2" || return 99
      t13_original_bound_write "$@"
    }
    trellis_attach_postjob_spawn() { :; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t13 "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" == *'run trellis recover'* ]] || { echo "$output"; return 1; }
  jq -e '[.projects[].metadata.t13_forged] | any' "$TRELLIS_HOME/registry.json" >/dev/null ||
    { echo 'fixture did not reach the registry write'; return 1; }
  [ ! -e "$TARGET/.trellis/runtime" ] || { echo 'forged proposal published an artifact'; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ]
  [ ! -e "$TARGET/.trellis/runtime" ]
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -L "$TARGET/.trellis/runtime" ]
}

@test "A5B interrupted batch remains recoverable with the existing journal" {
  run env ATTACHMENT_FAULT_PHASE=fast-published "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -ne 0 ]
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET/.trellis/runtime" ]
}

# T34 option B: native renders name the project root and this host's
# companion. The donor is verified against the canonical render for its own
# root and the target gets the canonical render for the target root.
@test "T34B native donor takes the fast path with the target's own render" {
  native_render_fixture_strings "$PROJECT/.claude/settings.local.json" | grep -qF "$NATIVE_COMPANION"
  native_render_fixture_strings "$PROJECT/.claude/settings.local.json" | grep -qF "$PROJECT"
  native_render_fixture_strings "$PROJECT/.codex/hooks.json" | grep -qF "$PROJECT"
  assert_fast_slow_parity
  [[ "$output" != *'donor not reused'* ]]
  for file in .claude/settings.local.json .codex/hooks.json; do
    native_render_fixture_strings "$TARGET/$file" | grep -qF "$NATIVE_COMPANION"
    native_render_fixture_strings "$TARGET/$file" | grep -qF "$TARGET"
    ! native_render_fixture_strings "$TARGET/$file" | grep -qF "$PROJECT"
  done
}

@test "T34B native tampered, mismatched, other-arch or unverifiable donors run the full attach with a labelled status" {
  local case label digest other_digest
  digest="$(jq -r --arg t "$NATIVE_TARGET" '.assets[$t].sha256' "$REPO_ROOT/core-rules/native/artifacts.json")"
  other_digest="$(jq -r --arg t "$NATIVE_OTHER_TARGET" '.assets[$t].sha256' "$REPO_ROOT/core-rules/native/artifacts.json")"
  cp "$DONOR" "$SANDBOX/donor-before"
  cp "$PROJECT/.claude/settings.local.json" "$SANDBOX/guard-before"
  for case in tampered other-root other-arch legacy-render missing-companion; do
    case "$case" in
      tampered)
        native_render_fixture_rewrite "$DONOR" "$PROJECT" .claude/settings.local.json timeout
        label='donor render differs from its own root render' ;;
      other-root)
        native_render_fixture_rewrite "$DONOR" "$PROJECT" .claude/settings.local.json replace "$PROJECT" "$SANDBOX/elsewhere"
        label='donor render differs from its own root render' ;;
      other-arch)
        native_render_fixture_rewrite "$DONOR" "$PROJECT" .claude/settings.local.json replace "/$NATIVE_TARGET/$digest/" "/$NATIVE_OTHER_TARGET/$other_digest/"
        label='donor render is for another host target' ;;
      legacy-render)
        native_render_fixture_rewrite "$DONOR" "$PROJECT" .claude/settings.local.json legacy
        label='legacy donor render; this host renders native' ;;
      missing-companion)
        chmod 700 "${NATIVE_COMPANION%/*}"
        mv "$NATIVE_COMPANION" "$SANDBOX/companion-aside"
        label='canonical render refused' ;;
    esac
    run bash -c '
      . "$1"
      release_store_locate() { printf "full-path\n" >&2; return 5; }
      attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
    ' t34b "$ATTACH" "$TRELLIS_HOME" "$TARGET"
    printf '%s: %s\n' "$case" "$output"
    [ "$status" -eq 5 ]
    [[ "$output" == *'full-path'* ]]
    [[ "$output" == *"trellis attach: donor not reused ($label"* ]]
    [[ "$output" != *'attached (donor fast path)'* ]]
    [ ! -e "$TARGET/.trellis/runtime" ] && [ ! -L "$TARGET/.trellis/runtime" ]
    [ ! -e "$TARGET/.claude" ]
    [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ]
    if [ "$case" = missing-companion ]; then
      mv "$SANDBOX/companion-aside" "$NATIVE_COMPANION"
      chmod 500 "${NATIVE_COMPANION%/*}"
    fi
    chmod 600 "$DONOR" "$PROJECT/.claude/settings.local.json"
    cp "$SANDBOX/donor-before" "$DONOR"
    cp "$SANDBOX/guard-before" "$PROJECT/.claude/settings.local.json"
  done
  # Restored, the same donor takes the fast path: every miss above was the render check.
  fast_attach
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
}

@test "T34B native donor with drifted, unrecorded bytes falls back without reuse" {
  printf ' \n' >> "$PROJECT/.claude/settings.local.json"
  run bash -c '
    . "$1"
    release_store_locate() { printf "full-path\n" >&2; return 5; }
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"
  ' t34b "$ATTACH" "$TRELLIS_HOME" "$TARGET"
  printf '%s\n' "$output"
  [ "$status" -eq 5 ]
  [[ "$output" == *'full-path'* ]]
  [[ "$output" != *'attached (donor fast path)'* ]]
  [ ! -e "$TARGET/.trellis/runtime" ] && [ ! -L "$TARGET/.trellis/runtime" ]
}

@test "T34B native expected donor binding retains the fast path" {
  run bash -c '
    . "$1"
    target="$3"; donor="$4"
    identity="$(local_registry_identity_for_root "$target")"
    checkout="$(printf "%s\n" "$identity" | jq -r .checkout_id)"
    worktree="$(printf "%s\n" "$identity" | jq -r .worktree_id)"
    attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 \
      --expected-fleet personal --expected-project-id a5b-fixture \
      --expected-root "$target" --expected-checkout-id "$checkout" \
      --expected-worktree-id "$worktree" --expected-attachment-id "" \
      --expected-release 1.2.3 --expected-harnesses-json '\''["claude","codex"]'\'' \
      --expected-donor-root "$(jq -r .worktree_root "$donor")" --expected-donor-checkout-id "$checkout" \
      --expected-donor-worktree-id "$(jq -r .worktree_id "$donor")" --expected-donor-attachment-id "$(jq -r .attachment_id "$donor")" \
      --expected-donor-release 1.2.3 --expected-donor-harnesses-json '\''["claude","codex"]'\'' \
      "$target"
  ' t34b "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$DONOR"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
  native_render_fixture_strings "$TARGET/.claude/settings.local.json" | grep -qF "$TARGET"
}

# Spec 074 T2a: the seed's canonical donor verify (attachment_verify_donor) is
# shared with the fast path's PREFLIGHT, which then skips only its per-artifact
# leaf loop, and only for the identical owner bytes at this release.
t2a_leaf_wrapper() {
  local mini="$1"
  mkdir -p "$mini/lib"
  cp "$REPO_ROOT/scripts/lib/attach-fastpath.py" "$REPO_ROOT/scripts/lib/release-executed.py" "$mini/lib/"
  cat > "$mini/attach-project.sh" <<'BASH'
. "$T2A_REAL_ATTACH" || exit 1
eval "$(declare -f _attachment_verify_owner_artifacts | sed '1s/_attachment_verify_owner_artifacts/t2a_original_owner_artifacts/')"
_attachment_verify_owner_artifacts() {
  printf '%s %s\n' "$1" "${3:-all}" >> "$T2A_LEAF_TRACE"
  [ "${T2A_STOP:-0}" != 1 ] || return 3
  t2a_original_owner_artifacts "$@"
}
BASH
}

# Runs attach with the expected donor binding the seed passes, after the
# caller-provided proof setup ($6, evaluated in the attach shell).
t2a_attach() {
  run bash -c '
    . "$1"
    SCRIPT_DIR="$4"
    export T2A_REAL_ATTACH="$1" T2A_LEAF_TRACE="$5" TRELLIS_FASTPATH_TRACE=1
    trellis_attach_postjob_spawn() { :; }
    release_store_locate() { printf "full-path\n" >&2; return 5; }
    home="$2"; target="$3"; donor="$7"
    identity="$(local_registry_identity_for_root "$target")"
    checkout="$(printf "%s\n" "$identity" | jq -r .checkout_id)"
    worktree="$(printf "%s\n" "$identity" | jq -r .worktree_id)"
    digest="$(shasum -a 256 "$donor" | cut -d " " -f 1)"
    tab=$(printf "\t")
    eval "$6"
    attach_cmd_attach --home "$home" --fleet personal --release 1.2.3 \
      --expected-fleet personal --expected-project-id a5b-fixture \
      --expected-root "$target" --expected-checkout-id "$checkout" \
      --expected-worktree-id "$worktree" --expected-attachment-id "" \
      --expected-release 1.2.3 --expected-harnesses-json '\''["claude","codex"]'\'' \
      --expected-donor-root "$(jq -r .worktree_root "$donor")" --expected-donor-checkout-id "$checkout" \
      --expected-donor-worktree-id "$(jq -r .worktree_id "$donor")" --expected-donor-attachment-id "$(jq -r .attachment_id "$donor")" \
      --expected-donor-release 1.2.3 --expected-donor-harnesses-json '\''["claude","codex"]'\'' \
      "$target"
  ' t2a "$ATTACH" "$TRELLIS_HOME" "$TARGET" "$T2A_MINI" "$T2A_TRACE" "$1" "$DONOR"
  printf '%s\n' "$output"
}

@test "T2A a seed donor proof skips only the PREFLIGHT leaf loop for the same owner bytes" {
  T2A_MINI="$SANDBOX/t2a-mini" T2A_TRACE="$SANDBOX/t2a-shared.log"
  t2a_leaf_wrapper "$T2A_MINI"
  # As the seed does: a canonical attachment_verify of exactly these bytes.
  t2a_attach 'attachment_verify "$home" "$donor" || exit 9
    _ATTACHMENT_DONOR_PROOF="$$"${tab}"$donor"${tab}"$digest"${tab}1.2.3'
  [ "$status" -eq 0 ]
  [[ "$output" == *'attached (donor fast path):'* ]]
  [[ "$output" == *'donor proof shared'* ]]
  [ "$(grep -Fxc "$DONOR proven-leaves" "$T2A_TRACE")" -eq 1 ]
  [ "$(grep -Fxc "$DONOR all" "$T2A_TRACE")" -eq 0 ]
}

@test "T2A proofs for other bytes, another release, another process or an inherited value are not shared" {
  local case proof
  T2A_MINI="$SANDBOX/t2a-mini" T2A_TRACE="$SANDBOX/t2a-refused.log"
  t2a_leaf_wrapper "$T2A_MINI"
  for case in other-bytes other-release other-process inherited-preflight inherited-python; do
    case "$case" in
      other-bytes) proof='_ATTACHMENT_DONOR_PROOF="$$"${tab}"$donor"${tab}"$(printf "%064d" 0)"${tab}1.2.3' ;;
      other-release) proof='_ATTACHMENT_DONOR_PROOF="$$"${tab}"$donor"${tab}"$digest"${tab}9.9.9' ;;
      other-process) proof='_ATTACHMENT_DONOR_PROOF="1"${tab}"$donor"${tab}"$digest"${tab}1.2.3' ;;
      inherited-preflight) proof='export _TRELLIS_PREFLIGHT_DONOR_PROVEN="$donor"${tab}"$digest"' ;;
      inherited-python) proof='export TRELLIS_FASTPATH_DONOR_PROOF="$donor"${tab}"$digest"${tab}1.2.3' ;;
    esac
    : > "$T2A_TRACE"
    T2A_STOP=1 t2a_attach "$proof"
    printf '%s: %s\n' "$case" "$(cat "$T2A_TRACE")"
    [ "$status" -eq 5 ]
    [[ "$output" == *'donor proof not shared'* ]]
    [ "$(grep -Fxc "$DONOR all" "$T2A_TRACE")" -eq 1 ]
    [ "$(grep -Fxc "$DONOR proven-leaves" "$T2A_TRACE")" -eq 0 ]
    [ ! -e "$TARGET/.trellis/runtime" ] && [ ! -L "$TARGET/.trellis/runtime" ]
  done
}

@test "T2A seed shares its canonical donor verify with the fast path" {
  local wt="$SANDBOX/t2a-seed-target"
  # The fixture's seed is a stub; this case runs the installed real one on a
  # worktree added without the post-checkout reconcile.
  git -C "$PROJECT" -c core.hooksPath=/dev/null worktree add -q -b t2a-seed "$wt"
  run env TRELLIS_ATTACH_POSTJOB=off TRELLIS_FASTPATH_TRACE=1 \
    bash "$TRELLIS_HOME/releases/1.2.3/payload/scripts/seed-inheritance-symlinks.sh" --target "$wt"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'donor proof shared'* ]]
  [[ "$output" == *'attached (donor fast path):'* ]]
}
