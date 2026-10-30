#!/usr/bin/env bats
# A5B: private release/home only; no hook bypasses, no live fleet operations.
REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/a5b.fixture.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1
  # Only unit fixtures stub A4; production requires the frozen dependency.
  trellis_attach_postjob_spawn() { :; }
  export -f trellis_attach_postjob_spawn
  mkdir -p "$HOME" "$TRELLIS_HOME" "$SANDBOX/source/core-rules/templates" "$SANDBOX/source/core-rules/githooks" "$SANDBOX/source/scripts"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$SANDBOX/source/core-rules/templates/"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" "$SANDBOX/source/core-rules/templates/"
  printf '# fixture policy\n' > "$SANDBOX/source/core-rules/CLAUDE.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/source/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/source/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$SANDBOX/source/core-rules/githooks/pre-push" "$SANDBOX/source/scripts/seed-inheritance-symlinks.sh"
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

@test "A5B owned artifact and owner metadata parity with the slow path" {
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before"
  fast_attach
  [ "$status" -eq 0 ]
  [[ "$output" == *'donor fast path'* ]]
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

@test "A5B interrupted batch remains recoverable with the existing journal" {
  run env ATTACHMENT_FAULT_PHASE=fast-published "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -ne 0 ]
  [ "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$TARGET"
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET/.trellis/runtime" ]
}
