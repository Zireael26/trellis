#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture

sha256_file() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

# BSD and GNU stat are probed in SEPARATE captures: GNU `stat -f` is
# --file-system and prints a filesystem block before failing, which a chained
# substitution would concatenate onto the mode.
file_mode() {
  local candidate
  candidate="$(stat -f %Lp "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %a "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

checkout_lock_path() {
  local common checkout
  common="$(git -C "$PROJECT" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$PROJECT/$common" ;;
  esac
  common="$(canonical_dir "$common")"
  checkout="$(printf '%s' "$common" | shasum -a 256 | cut -d ' ' -f 1)"
  printf '%s/state/locks/attachment-checkout-%s.lock\n' "$TRELLIS_HOME" "$checkout"
}

# The budget is a CONTENTION allowance, not a timing expectation: on an idle
# machine the lock appears in well under a second, so the happy path never
# spends it. The original 2 s was the whole reason the signal cases read as
# flaky — under a parallel full-battery run the detach process could not reach
# its lock write inside the window, the signaler exited 1, and the failure
# looked like a signal-handling defect rather than a starved test. Measured at
# this tip: 3/3 green quiescently (one full-suite run plus two targeted reruns),
# 2/2 red under load with the old budget.
#
# The budget is WALL CLOCK, and it has to be: the invariant it must satisfy is
# "expire before the holder lets go", and the holder's grip
# (`ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK`) is measured in seconds. Expressed as an
# iteration count it was not checkable — 1500 iterations of `sleep 0.01` is
# 15 s of sleeping plus 1500 process spawns, which measured 23.9 s under a load
# average of 6.45 against a 30 s hold, and a 2-core runner executing four shards
# is strictly worse. The margin that comment called comfortable was ~6 s and
# shrank with contention, in the direction the budget was widened to tolerate.
#
# Seconds, so the comparison against the hold is arithmetic a reader can do.
CHECKOUT_LOCK_HOLD_SECONDS=30
WAIT_FOR_CHECKOUT_LOCK_SECONDS=20

wait_for_checkout_lock() {
  local path deadline
  path="$(checkout_lock_path)"
  deadline=$((SECONDS + WAIT_FOR_CHECKOUT_LOCK_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -L "$path" ] && return 0
    sleep 0.01
  done
  return 1
}

checkout_lock_pid() {
  local path target
  path="$(checkout_lock_path)"
  target="$(readlink "$path")"
  jq -r '.pid' "$TRELLIS_HOME/state/locks/$target/owner.json"
}

stage_dead_checkout_lock() {
  local path common checkout locks holder
  path="$(checkout_lock_path)"
  common="$(git -C "$PROJECT" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$PROJECT/$common" ;;
  esac
  common="$(canonical_dir "$common")"
  checkout="$(printf '%s' "$common" | shasum -a 256 | cut -d ' ' -f 1)"
  locks="$TRELLIS_HOME/state/locks"
  holder="$(mktemp -d "$locks/.attachment-checkout-${checkout}.holder-2147483647.XXXXXX")"
  chmod 700 "$holder"
  jq -cn --arg checkout "$checkout" --arg common "$common" \
    '{checkout_id:$checkout,git_common_dir:$common,pid:2147483647,process_birth:"test-dead-process"}' > "$holder/owner.json"
  chmod 600 "$holder/owner.json"
  ln -s "$(basename "$holder")" "$path"
}

make_release() {
  local release="$1" repo="$SANDBOX/release-source"
  mkdir -p "$repo/core-rules/commands/templates" "$repo/core-rules/templates" \
    "$repo/core-rules/husky" "$repo/core-rules/githooks" "$repo/scripts"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '# generated primer index\n' > "$repo/core-rules/commands/templates/primer-index-template.md"
  # The contextual SessionStart renders are validated against the real shipped
  # templates by path, so the fixture release carries the real bytes.
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$repo/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$repo/core-rules/templates/codex-hooks.local.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/husky/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push" "$repo/scripts/seed-inheritance-symlinks.sh"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": [
        {"template": "core-rules/commands/templates/primer-index-template.md", "destination": ".claude/primers/INDEX.md", "merge": "replace", "mode": "0644", "required": true},
        {"template": "core-rules/templates/claude-settings.local.json", "destination": ".claude/settings.local.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    },
    "codex": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}
      ],
      "render": [
        {"template": "core-rules/templates/codex-hooks.local.json", "destination": ".codex/hooks.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    }
  }
}
JSON
  printf '%s\n' "$release" > "$repo/core-rules/VERSION"
  # scripts/release.sh refuses pathname execution, so the fixture release is
  # sealed and installed through the bootstrap launcher instead.
  release_fixture_install "$HOME" "$TRELLIS_HOME" "$release" "$repo"
}
make_copied_older_release() {
  local base="$TRELLIS_HOME/releases/1.2.3"
  local release="$TRELLIS_HOME/releases/1.2.2"
  local payload="$release/payload"
  local manifest="$SANDBOX/release-1.2.2.jsonl"

  cp -R "$base" "$release"
  chmod -R u+w "$release"
  mkdir -p "$payload/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/attachment.sh" "$payload/scripts/lib/attachment.sh"
  # The copied generator extracts command-scratch programs from its own launcher.
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$payload/scripts/trellis-launcher.sh"
  sed \
    -e '/^[[:space:]]*TRELLIS_ALLOW_MAIN_PUSH=.*$/d' \
    -e '/^[[:space:]]*SECURITY_GATE_SKIP=.*$/d' \
    -e '/^[[:space:]]*export TRELLIS_ALLOW_MAIN_PUSH SECURITY_GATE_SKIP$/d' \
    "$payload/scripts/lib/attachment.sh" > "$payload/scripts/lib/attachment.sh.tmp"
  mv "$payload/scripts/lib/attachment.sh.tmp" "$payload/scripts/lib/attachment.sh"
  printf '1.2.2\n' > "$payload/core-rules/VERSION"

  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$payload" > "$manifest"
  jq -n --arg version 1.2.2 --slurpfile tree "$manifest" '{
    schema_version:1,
    version:$version,
    tag:("v" + $version),
    commit:"0000000000000000000000000000000000000000",
    remote:"fixture://copied-older-release",
    tree:$tree
  }' > "$release/release.json"
  find "$payload" -type f -exec chmod a-w {} +
  find "$payload" -type d -exec chmod a-w {} +
  chmod a-w "$release/release.json" "$release"
}


make_project() {
  PROJECT="$SANDBOX/project with spaces"
  mkdir -p "$PROJECT"
  git init -q "$PROJECT"
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
}

owner_for_root() {
  local root="$1" owner
  while IFS= read -r owner; do
    [ "$(jq -r '.worktree_root' "$owner")" = "$root" ] && printf '%s\n' "$owner"
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print 2>/dev/null)
  return 0
}

rewrite_owner() {
  local owner="$1" filter="$2" temp="$owner.tmp"
  jq "$filter" "$owner" > "$temp" || return 1
  chmod 600 "$temp" || return 1
  mv "$temp" "$owner"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/detach-project.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  export HOME="$SANDBOX/fixture user home"
  export TRELLIS_HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  export HOME="$(canonical_dir "$HOME")"
  export TRELLIS_HOME="$(canonical_dir "$TRELLIS_HOME")"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  make_release 1.2.3
  make_project
  EXCLUDE_HASH="$(sha256_file "$PROJECT/.git/info/exclude")"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

run_attach() {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$@" "$PROJECT"
}

run_detach() {
  run "$ATTACH" detach --home "$TRELLIS_HOME" "$@" "$PROJECT"
}

@test "full detach removes exact owned surfaces and restores exclude and registry state" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]

  run_detach

  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ ! -e "$PROJECT/.claude/rules/trellis.md" ]
  [ ! -e "$PROJECT/.agents/rules/trellis.md" ]
  [ ! -e "$PROJECT/.codex/hooks.json" ]
  [ ! -e "$owner" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
  jq -e '[.. | objects | .attachment_id? // empty] | length == 0' "$TRELLIS_HOME/registry.json"
  jq -e '[.projects[].checkouts[].worktrees[]] | length == 1' "$TRELLIS_HOME/registry.json"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}
@test "detach preserves foreign exclude bytes and still refuses managed-block tampering" {
  local owner managed exclude before foreign_before foreign_after expected tampered_hash with_foreign duplicate_block
  exclude="$PROJECT/.git/info/exclude"
  before="$SANDBOX/exclude-before"
  cp "$exclude" "$before"
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  [ -f "$owner" ]
  foreign_before="$SANDBOX/foreign-exclude-before"
  foreign_after="$SANDBOX/foreign-exclude-after"
  printf 'foreign prefix embeds %s in arbitrary bytes\n' \
    '# --- Trellis local attachment exclude block ---' > "$foreign_before"
  printf 'foreign suffix embeds %s in arbitrary bytes\n' \
    '# --- end Trellis local attachment exclude block ---' > "$foreign_after"
  cat "$foreign_before" "$exclude" > "$exclude.tmp"
  mv "$exclude.tmp" "$exclude"
  cat "$exclude" "$foreign_after" > "$exclude.tmp"
  mv "$exclude.tmp" "$exclude"
  with_foreign="$SANDBOX/exclude-with-foreign"
  cp "$exclude" "$with_foreign"
  duplicate_block="$SANDBOX/duplicate-block"
  sed -n '/^# --- Trellis local attachment exclude block ---$/,/^# --- end Trellis local attachment exclude block ---$/p' \
    "$exclude" > "$duplicate_block"
  cat "$duplicate_block" >> "$exclude"
  run_detach
  [ "$status" -eq 3 ]
  cp "$with_foreign" "$exclude"
  expected="$SANDBOX/exclude-after-detach"
  cat "$foreign_before" "$before" "$foreign_after" > "$expected"

  run_detach

  [ "$status" -eq 0 ]
  [ ! -e "$owner" ]
  cmp -s "$exclude" "$expected"
  ! grep -Fxq '# --- Trellis local attachment exclude block ---' "$exclude"
  grep -Fq 'foreign prefix embeds' "$exclude"
  grep -Fq 'foreign suffix embeds' "$exclude"

  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  sed 's|^/\.trellis/runtime$|/.trellis/runtime-tampered|' "$exclude" > "$exclude.tmp"
  mv "$exclude.tmp" "$exclude"
  tampered_hash="$(sha256_file "$exclude")"

  run_detach

  [ "$status" -eq 3 ]
  [ -f "$owner" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ -e "$managed" ]
  [ "$(sha256_file "$exclude")" = "$tampered_hash" ]
  grep -Fq 'foreign prefix embeds' "$exclude"
  grep -Fq 'foreign suffix embeds' "$exclude"
}


@test "full detach accepts an authentic dispatcher from a copied older payload" {
  local old_release old_payload manifest owner managed legacy_post legacy_pre
  make_copied_older_release
  old_release="$TRELLIS_HOME/releases/1.2.2"
  old_payload="$old_release/payload"

  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.2 "$PROJECT"
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  manifest="$(sha256_file "$old_release/release.json")"
  legacy_post="$(
    TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$old_payload" \
      /bin/bash --noprofile --norc -c '
        source "$1"
        _attachment_hooks_post_checkout_dispatcher_body "$2" "$3"
      ' legacy-dispatcher "$old_payload/scripts/lib/attachment.sh" "$old_payload" "$manifest"
  )"
  legacy_pre="$(
    TRELLIS_LIBS_PRELOADED=1 TRELLIS_VERIFIED_PAYLOAD="$old_payload" \
      /bin/bash --noprofile --norc -c '
        source "$1"
        _attachment_hooks_pre_push_dispatcher_body "$2" "$3" "$4"
      ' legacy-dispatcher "$old_payload/scripts/lib/attachment.sh" "$old_payload" \
        core-rules/githooks/pre-push "$manifest"
  )"
  [ -n "$legacy_post" ]
  [ -n "$legacy_pre" ]
  [[ "$legacy_post" != *"TRELLIS_ALLOW_MAIN_PUSH"* ]]
  printf '%s\n' "$legacy_post" > "$managed/post-checkout"
  printf '%s\n' "$legacy_pre" > "$managed/pre-push"
  chmod 700 "$managed/post-checkout" "$managed/pre-push"

  run_detach

  [ "$status" -eq 0 ]
  [ ! -e "$managed" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ -z "$(owner_for_root "$PROJECT")" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
  jq -e '[.. | objects | .attachment_id? // empty] | length == 0' "$TRELLIS_HOME/registry.json"
}


@test "checkout lock rejects concurrent detach without common-state drift and releases on signal" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  owner_hash="$(sha256_file "$owner")"
  exclude_hash="$(sha256_file "$PROJECT/.git/info/exclude")"
  registry_hash="$(sha256_file "$TRELLIS_HOME/registry.json")"

  ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK="$CHECKOUT_LOCK_HOLD_SECONDS" "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT" >"$SANDBOX/held-detach.log" 2>&1 &
  background_pid=$!
  wait_for_checkout_lock
  holder_pid="$(checkout_lock_pid)"

  run_detach

  [ "$status" -eq 3 ]
  [ "$(sha256_file "$owner")" = "$owner_hash" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$exclude_hash" ]
  [ "$(sha256_file "$TRELLIS_HOME/registry.json")" = "$registry_hash" ]
  [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)" ]

  kill -TERM "$holder_pid"
  held_status=0
  wait "$background_pid" || held_status=$?
  [ "$held_status" -eq 5 ]
  [ ! -e "$(checkout_lock_path)" ]
  [ ! -L "$(checkout_lock_path)" ]

  run_detach

  [ "$status" -eq 0 ]
  [ -z "$(owner_for_root "$PROJECT")" ]
}

@test "checkout lock signals return interrupted after releasing the lock" {
  run_attach
  [ "$status" -eq 0 ]

  for signal in HUP INT TERM; do
    (
      wait_for_checkout_lock || exit 1
      kill -"$signal" "$(checkout_lock_pid)" || exit 1
    ) &
    signaler_pid=$!
    # Bats' within-file semaphore launches tests as asynchronous Bash jobs,
    # which inherit SIGINT ignored. Restore foreground-command disposition
    # before exec so the real detach process can install its own INT trap.
    run env ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK="$CHECKOUT_LOCK_HOLD_SECONDS" \
      python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
      "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 5 ] || { printf 'signal=%s status=%s\n%s\n' "$signal" "$status" "$output" >&2; false; }
    signaler_status=0
    wait "$signaler_pid" || signaler_status=$?
    [ "$signaler_status" -eq 0 ]
    [ ! -e "$(checkout_lock_path)" ]
    [ ! -L "$(checkout_lock_path)" ]
  done
}

@test "detach reclaims only a validated dead checkout lock" {
  run_attach
  [ "$status" -eq 0 ]
  stage_dead_checkout_lock
  [ -L "$(checkout_lock_path)" ]

  run_detach

  [ "$status" -eq 0 ]
  [ ! -e "$(checkout_lock_path)" ]
  [ ! -L "$(checkout_lock_path)" ]
  [ -z "$(owner_for_root "$PROJECT")" ]
}

@test "per-harness detach inverse-merges only selected render keys" {
  run_attach
  [ "$status" -eq 0 ]
  temp="$PROJECT/.claude/settings.local.json.tmp"
  jq '.project = "keep" | .later = {"value":1}' "$PROJECT/.claude/settings.local.json" > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$PROJECT/.claude/settings.local.json"

  run_detach --harness claude

  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/.claude/rules/trellis.md" ]
  [ ! -e "$PROJECT/.claude/primers/INDEX.md" ]
  jq -e '.project == "keep" and .later.value == 1
    and (has("hooks") | not) and (has("effortLevel") | not) and (has("permissions") | not)' \
    "$PROJECT/.claude/settings.local.json"
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  jq -e '[.hooks.SessionStart[].hooks[].command] | length == 3
    and all(.[]; contains("${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}") and (contains("__TRELLIS_") | not))' \
    "$PROJECT/.codex/hooks.json"
  [ -L "$PROJECT/.trellis/runtime" ]
  owner="$(owner_for_root "$PROJECT")"
  jq -e '[.artifacts[].path | if . == "AGENTS.md" or startswith(".agents/") or startswith(".codex/") then "codex" else empty end] | unique == ["codex"]' "$owner"
  jq -e --slurpfile owner "$owner" '
    .projects["personal/fixture-project"].checkouts[$owner[0].checkout_id]
    | .harnesses == ["codex"] and .release == $owner[0].release
      and .worktrees[$owner[0].worktree_id].attachment_id == $owner[0].attachment_id
  ' "$TRELLIS_HOME/registry.json"
}

# Contents, modes and link targets across managed and project state. Lock
# bookkeeping is intentionally excluded; it is acquired even on a refusal.
detach_state_snapshot() {
  python3 - "$PROJECT" "$TRELLIS_HOME/registry.json" "$TRELLIS_HOME/state/attachments" "$TRELLIS_HOME/state/attachment-journals" "$@" <<'PY'
import hashlib, json, os, stat, sys
rows = []
for root in sys.argv[1:]:
    paths = [root]
    if os.path.isdir(root):
        for directory, dirs, files in os.walk(root):
            paths.extend(os.path.join(directory, name) for name in dirs + files)
    for path in sorted(paths):
        if not os.path.lexists(path):
            continue
        mode = os.lstat(path).st_mode
        content = os.readlink(path) if stat.S_ISLNK(mode) else (
            hashlib.sha256(open(path, 'rb').read()).hexdigest() if stat.S_ISREG(mode) else None)
        rows.append([path, mode, content])
print(json.dumps(rows, sort_keys=True))
PY
}

@test "partial detach refuses multiple owners even all-worktrees with byte-identical state" {
  run_attach
  [ "$status" -eq 0 ]
  WORKTREE="$SANDBOX/linked partial"
  git -C "$PROJECT" worktree add -q -b partial-linked "$WORKTREE"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$WORKTREE"
  [ "$status" -eq 0 ]
  before="$(detach_state_snapshot)"
  for selector in single all; do
    if [ "$selector" = all ]; then run_detach --harness claude --all-worktrees
    else run_detach --harness claude; fi
    [ "$status" -eq 3 ] || { echo "$output"; false; }
    [[ "$output" == *"exactly one matching registry attachment binding"* ]]
    [ "$(detach_state_snapshot)" = "$before" ]
    [ -L "$WORKTREE/.claude/rules/trellis.md" ]
    [ -L "$WORKTREE/.agents/rules/trellis.md" ]
  done
}

# Real dependencies and owner planner: the helper oracle must not be masked by
# CLI owner verification or later durable-journal validation.
partial_registry_proposal() {
  bash -c '
    . "$1"
    original="$(jq -c . "$3")" || exit
    plan="$(attach_detach_owner_plan "$original" "[\"claude\"]")" || exit
    next="$(printf "%s\n" "$plan" | jq -c .next_owner)" || exit
    attach_detach_partial_registry "$2" "$original" "$next"
  ' _ "$ATTACH" "$TRELLIS_HOME" "$owner"
}

@test "partial detach refuses orphan owners pending journals and registry disagreement before mutation" {
  # Construct before attach installs post-checkout: this fixture does not test
  # generated dispatchers or their temporary-directory allocation.
  WORKTREE="$SANDBOX/linked refusal"
  git -C "$PROJECT" worktree add -q -b refusal-linked "$WORKTREE"
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-original.json"
  before="$(detach_state_snapshot "$WORKTREE")"
  expected_proposal="$(jq -cS '.projects[].checkouts[] | {expected:.,after:(. | .harnesses = ["codex"])}' "$TRELLIS_HOME/registry.json")"
  run partial_registry_proposal
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -cS .)" = "$expected_proposal" ]
  [ "$(detach_state_snapshot "$WORKTREE")" = "$before" ]
  for fault in registry pending; do
    case "$fault" in
      registry)
        jq '.projects[].checkouts[].harnesses = ["claude"]' "$SANDBOX/registry-original.json" > "$TRELLIS_HOME/registry.json"
        expect_status=3
        expect_message='committed owner no longer exactly matches the expected local registry binding' ;;
      pending)
        cp "$owner" "$TRELLIS_HOME/state/attachment-journals/pending.json"
        expect_status=3
        expect_message='partial harness detach conflicts with a pending checkout journal' ;;
    esac
    before="$(detach_state_snapshot "$WORKTREE")"
    run_detach --harness claude
    [ "$status" -eq "$expect_status" ] || { echo "$fault: $output"; false; }
    [[ "$output" == *"$expect_message"* ]]
    [ "$(detach_state_snapshot "$WORKTREE")" = "$before" ]
    cp "$SANDBOX/registry-original.json" "$TRELLIS_HOME/registry.json"
    rm -f "$TRELLIS_HOME/state/attachment-journals/pending.json"
  done

  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$WORKTREE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  linked_owner="$(owner_for_root "$WORKTREE")"
  for canonical_owner in "$owner" "$linked_owner"; do
    run bash -c '. "$1"; attachment_verify_detach "$2" "$3"' _ "$ATTACH" "$TRELLIS_HOME" "$canonical_owner"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
  jq -se 'map(select(.exclude.managed_by_attachment)) | length == 1' "$owner" "$linked_owner"
  jq -e '.exclude.managed_by_attachment == false' "$linked_owner"
  run bash -c '
    . "$1"
    state="$(local_registry_read_diagnostic_state "$2")" || exit
    for owner in "$3" "$4"; do
      local_registry_validate_bound_row_identity "$state" "$(jq -r .checkout_id "$owner")" "$(jq -r .worktree_id "$owner")" || exit
    done
  ' _ "$ATTACH" "$TRELLIS_HOME" "$owner" "$linked_owner"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-both.json"
  for fault in owner-without-binding binding-without-owner; do
    case "$fault" in
      owner-without-binding)
        jq --slurpfile linked "$linked_owner" 'del(.projects["personal/fixture-project"].checkouts[$linked[0].checkout_id].worktrees[$linked[0].worktree_id].attachment_id)' \
          "$SANDBOX/registry-both.json" > "$TRELLIS_HOME/registry.json"
        expect_message='partial harness detach requires exactly one committed owner; orphan or multiple owners found' ;;
      binding-without-owner)
        mv "$linked_owner" "$SANDBOX/linked-owner-backup.json"
        expect_message='partial harness detach requires exactly one matching registry attachment binding' ;;
    esac
    before="$(detach_state_snapshot "$WORKTREE")"
    expected_proposal="$(jq -cS '.projects[].checkouts[] | {expected:.,after:(. | .harnesses = ["codex"])}' "$TRELLIS_HOME/registry.json")"
    run partial_registry_proposal
    # A disposable source mutant must reach this business assertion with the
    # exact proposal, not fail setup or an unrelated preflight predicate.
    if [ "$status" -eq 0 ]; then
      [ "$(printf '%s\n' "$output" | jq -cS .)" = "$expected_proposal" ]
      [ "$(detach_state_snapshot "$WORKTREE")" = "$before" ]
      echo "MUTATION-ESCAPE $fault status=0 exact-expected-after-proposal state=unchanged: $output"
    fi
    [ "$status" -eq 3 ] || { echo "HELPER-REFUSAL $fault status=$status: $output"; false; }
    [ "$output" = "trellis attach: $expect_message" ]
    [ "$(detach_state_snapshot "$WORKTREE")" = "$before" ]
    run_detach --harness claude
    [ "$status" -eq 3 ] || { echo "$fault: $output"; false; }
    [[ "$output" == *"$expect_message"* ]]
    [ "$(detach_state_snapshot "$WORKTREE")" = "$before" ]
    cp "$SANDBOX/registry-both.json" "$TRELLIS_HOME/registry.json"
    if [ "$fault" = binding-without-owner ]; then
      mv "$SANDBOX/linked-owner-backup.json" "$linked_owner"
    fi
  done
  # Positive CLI control after restoring both independent corruptions.
  run "$ATTACH" detach --home "$TRELLIS_HOME" "$WORKTREE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_detach --harness claude
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -L "$PROJECT/.claude/rules/trellis.md" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  jq -e '.projects[].checkouts[].harnesses == ["codex"]' "$TRELLIS_HOME/registry.json"
}

@test "partial detach registry rename crashes recover before and after durable write" {
  WORKTREE="$SANDBOX/detached inventory"
  git -C "$PROJECT" worktree add -q -b detached-inventory "$WORKTREE"
  run bash -c '. "$1"; local_registry_register_worktree "$2" personal fixture-project "$3" "" "[]" "" "{}"' \
    _ "$REPO_ROOT/scripts/lib/local-registry.sh" "$TRELLIS_HOME" "$WORKTREE"
  [ "$status" -eq 0 ]
  for fault in detach-registry-before detach-registry-after; do
    run_attach
    [ "$status" -eq 0 ]
    inventory_before="$(jq -c '.projects[].checkouts[].worktrees' "$TRELLIS_HOME/registry.json")"
    run env ATTACHMENT_FAULT_PHASE="$fault" "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
    [ "$status" -eq 5 ] || { echo "$output"; false; }
    journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name 'detach-*.json')"
    jq -e '.owner_committed and .external.phase == 4 and .external.registry_update != null' "$journal"
    if [ "$fault" = detach-registry-before ]; then snapshot=expected; else snapshot=after; fi
    jq -e --slurpfile journal "$journal" --arg snapshot "$snapshot" '
      .projects["personal/fixture-project"].checkouts[$journal[0].checkout_id] == $journal[0].external.registry_update[$snapshot]
    ' "$TRELLIS_HOME/registry.json"
    run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$journal" ]
    [ "$(jq -c '.projects[].checkouts[].worktrees' "$TRELLIS_HOME/registry.json")" = "$inventory_before" ]
    jq -e '.projects[].checkouts[].harnesses == ["codex"]' "$TRELLIS_HOME/registry.json"
    [ ! -L "$PROJECT/.claude/rules/trellis.md" ]
    [ -L "$PROJECT/.agents/rules/trellis.md" ]
    run_detach
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "partial recovery rejects registry conflicts malformed snapshots and legacy journals without mutation" {
  run_attach
  [ "$status" -eq 0 ]
  run env ATTACHMENT_FAULT_PHASE=detach-prepared "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name 'detach-*.json')"
  cp "$journal" "$SANDBOX/journal-original.json"
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-original.json"
  jq '.projects[].checkouts[].release = "1.2.4"' "$SANDBOX/registry-original.json" > "$TRELLIS_HOME/registry.json"
  before="$(detach_state_snapshot)"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(detach_state_snapshot)" = "$before" ]
  cp "$SANDBOX/registry-original.json" "$TRELLIS_HOME/registry.json"
  # `del(.external.registry_update)` is the HISTORICAL legacy shape: a partial
  # detach journal written before the trusted registry snapshot existed. It is
  # kept deliberately — the field is absent, not null — because that older
  # journal is still recoverable-on-disk and must be refused, not replayed.
  # The forged parent covers ordered_subset: a next_owner artifact list may omit
  # original entries but may never gain a fabricated one.
  for filter in 'del(.external.registry_update)' '.external.registry_update.extra = true' \
    '.external.registry_update.after.release = "1.2.4"' \
    '.external.registry_update.expected.harnesses = ["claude"]' \
    '.external.registry_update.after.harnesses = ["pi"]' \
    '.external.registry_update.expected.worktrees = {} | .external.registry_update.after.worktrees = {}' \
    '.next_owner.artifacts += [{path:".claude/forged-parent",kind:"parent"}]' \
    '.external.clear_registry = true'; do
    jq "$filter" "$SANDBOX/journal-original.json" > "$journal"
    before="$(detach_state_snapshot)"
    run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 4 ] || { echo "$filter: $output"; false; }
    if [ "$filter" = 'del(.external.registry_update)' ]; then
      [[ "$output" == *"legacy partial detach journal lacks a trusted registry snapshot"* ]]
    fi
    [ "$(detach_state_snapshot)" = "$before" ]
  done
  cp "$SANDBOX/journal-original.json" "$journal"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "partial detach filters only removed harness pre-existing records" {
  mkdir -p "$PROJECT/.claude/rules" "$PROJECT/.agents/rules"
  printf '# local Claude\n' > "$PROJECT/.claude/rules/trellis.md"
  printf '# local shared\n' > "$PROJECT/.agents/rules/trellis.md"
  run_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(owner_for_root "$PROJECT")"
  jq -e '.pre_existing | length == 2' "$owner"
  run env ATTACHMENT_FAULT_PHASE=detach-prepared "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name 'detach-*.json')"
  cp "$journal" "$SANDBOX/deferred-original.json"
  jq '.next_owner.pre_existing = []' "$SANDBOX/deferred-original.json" > "$journal"
  before="$(detach_state_snapshot)"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ "$(detach_state_snapshot)" = "$before" ]
  cp "$SANDBOX/deferred-original.json" "$journal"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.pre_existing | length == 1 and .[0].path == ".agents/rules/trellis.md"' "$owner"
  [ "$(cat "$PROJECT/.claude/rules/trellis.md")" = '# local Claude' ]
  [ "$(cat "$PROJECT/.agents/rules/trellis.md")" = '# local shared' ]
}

@test "modified owned artifact blocks detach before any mutation" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  exclude_attached="$(sha256_file "$PROJECT/.git/info/exclude")"
  rm "$PROJECT/.agents/rules/trellis.md"
  ln -s wrong-target "$PROJECT/.agents/rules/trellis.md"

  run_detach

  [ "$status" -eq 3 ]
  [ -f "$owner" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ -L "$PROJECT/.claude/rules/trellis.md" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  [ "$(readlink "$PROJECT/.agents/rules/trellis.md")" = wrong-target ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$exclude_attached" ]
}

@test "detaching the exclude manager transfers ownership until the final worktree leaves" {
  mkdir -p "$PROJECT/.husky/_"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_attach
  [ "$status" -eq 0 ]
  WORKTREE="$SANDBOX/linked worktree"
  git -C "$PROJECT" worktree add -q -b fixture-linked "$WORKTREE"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$WORKTREE"
  [ "$status" -eq 0 ]
  manager_owner="$(owner_for_root "$PROJECT")"
  linked_owner="$(owner_for_root "$WORKTREE")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$manager_owner")"
  temp="$WORKTREE/.claude/settings.local.json.tmp"
  jq '.project = "keep"' "$WORKTREE/.claude/settings.local.json" > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$WORKTREE/.claude/settings.local.json"

  run_detach

  [ "$status" -eq 0 ]
  grep -F '# --- Trellis local attachment exclude block ---' "$PROJECT/.git/info/exclude"
  [ -z "$(owner_for_root "$PROJECT")" ]
  linked_owner="$(owner_for_root "$WORKTREE")"
  jq -e '.exclude.managed_by_attachment == true
    and .git_hooks.enabled == true
    and .git_hooks.previous_hooks_path == ".husky/_"' "$linked_owner"
  run "$ATTACH" detach --home "$TRELLIS_HOME" "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
  [ -z "$(owner_for_root "$WORKTREE")" ]
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = '.husky/_' ]
  jq -e '.project == "keep" and (has("hooks") | not)' "$WORKTREE/.claude/settings.local.json"
}

@test "all-worktrees detach removes every owner under one checkout" {
  run_attach
  [ "$status" -eq 0 ]
  WORKTREE="$SANDBOX/all linked worktrees"
  git -C "$PROJECT" worktree add -q -b fixture-all "$WORKTREE"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$WORKTREE"
  [ "$status" -eq 0 ]

  run_detach --all-worktrees

  [ "$status" -eq 0 ]
  [ -z "$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ ! -e "$WORKTREE/.trellis/runtime" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
}

@test "all-worktrees retry rebases a partial manager journal before shared restore" {
  mkdir -p "$PROJECT/.husky/_"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_attach
  [ "$status" -eq 0 ]
  WORKTREE="$SANDBOX/partial linked worktree"
  git -C "$PROJECT" worktree add -q -b fixture-partial "$WORKTREE"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$WORKTREE"
  [ "$status" -eq 0 ]
  manager_owner="$(owner_for_root "$PROJECT")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$manager_owner")"

  run env ATTACHMENT_FAULT_PHASE=detach-prepared "$ATTACH" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT"
  [ "$status" -eq 5 ]
  manager_journal=
  while IFS= read -r journal; do
    if jq -e '.original_owner.exclude.managed_by_attachment == true' "$journal" >/dev/null; then
      manager_journal="$journal"
    else
      rm "$journal"
    fi
  done < <(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)
  [ -f "$manager_journal" ]

  run env ATTACHMENT_FAULT_PHASE=detach-rebase-transfer-pending "$ATTACH" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT"
  [ "$status" -eq 5 ]
  jq -e '.external.phase == 0 and .external.exclude_action == "transfer" and .external.transfer != null' "$manager_journal"
  temp="$manager_journal.tmp"
  jq '.external.phase = 1' "$manager_journal" > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$manager_journal"

  run_detach --all-worktrees

  [ "$status" -eq 0 ]
  [ -z "$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print)" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = '.husky/_' ]
}

@test "detach retry finishes an interrupted durable journal" {
  run_attach
  [ "$status" -eq 0 ]

  run env ATTACHMENT_FAULT_PHASE=detach-committed "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)"
  [ -f "$journal" ]
  # Production full detach emits explicit null. Legacy full-detach journals may
  # omit the field; the phase-3 recovery case below preserves that coverage.
  jq -e '.external | has("registry_update") and .registry_update == null' "$journal" >/dev/null
  grep -F '# --- Trellis local attachment exclude block ---' "$PROJECT/.git/info/exclude"

  run_detach

  [ "$status" -eq 0 ]
  [ ! -e "$journal" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ -d "$PROJECT/.claude" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
  jq -e '[.. | objects | .attachment_id? // empty] | length == 0' "$TRELLIS_HOME/registry.json"
}

@test "recover finalizes a phase-3 restore journal and clears hooks and registry" {
  local journal owner managed before_exists before64 exclude temp render
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"

  run env ATTACHMENT_FAULT_PHASE=detach-committed "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)"
  [ -f "$journal" ]
  jq -e '
    .owner_committed == true
    and .external.phase == 0
    and .external.exclude_action == "restore"
    and .external.restore_hooks == true
    and .external.clear_registry == true
  ' "$journal"

  while IFS= read -r render; do
    [ -n "$render" ] || continue
    rm -f "$PROJECT/$render"
  done < <(jq -r '.external.renders[].path' "$journal")
  exclude="$PROJECT/.git/info/exclude"
  before_exists="$(jq -r '.original_owner.exclude.before_exists' "$journal")"
  if [ "$before_exists" = true ]; then
    before64="$(jq -r '.original_owner.exclude.before_base64' "$journal")"
    if ! printf '%s' "$before64" | base64 -D > "$exclude" 2>/dev/null; then
      printf '%s' "$before64" | base64 -d > "$exclude"
    fi
    chmod 600 "$exclude"
  else
    rm -f "$exclude"
  fi
  temp="$journal.tmp"
  jq '.external.phase = 3 | .external.render_phase = (.external.renders | length) | del(.external.registry_update)' \
    "$journal" > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$journal"
  jq -e '
    .owner_committed == true
    and .external.phase == 3
    and .external.exclude_action == "restore"
    and .external.restore_hooks == true
    and .external.clear_registry == true
  ' "$journal"

  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 0 ]
  [ ! -e "$journal" ]
  [ ! -e "$managed" ]
  [ -z "$(git -C "$PROJECT" config --local --get-all core.hooksPath 2>/dev/null || true)" ]
  [ "$(sha256_file "$exclude")" = "$EXCLUDE_HASH" ]
  jq -e '[.. | objects | .attachment_id? // empty] | length == 0' "$TRELLIS_HOME/registry.json"
}

@test "detach retains a preexisting empty harness parent" {
  mkdir "$PROJECT/.claude"
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"

  run_detach

  [ "$status" -eq 0 ]
  [ -d "$PROJECT/.claude" ]
  [ ! -e "$owner" ]
  [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ ! -e "$PROJECT/.claude/rules/trellis.md" ]
  [ ! -e "$PROJECT/.claude/settings.local.json" ]
}

@test "final detach restores the exact previous hooksPath and rejects drift" {
  local current diagnostic current_display root_display managed_display
  mkdir -p "$PROJECT/.husky/_"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"

  run_detach

  [ "$status" -eq 0 ]
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = '.husky/_' ]

  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  rewrite_owner "$owner" ".git_hooks = {\"enabled\":true,\"managed_hooks_path\":\"$managed\",\"previous_hooks_path\":\".husky/_\",\"pre_push_source\":\"core-rules/githooks/pre-push\"}"
  current=$'other manager\tpath'
  git -C "$PROJECT" config --local core.hooksPath "$current"
  run_detach
  [ "$status" -eq 3 ]
  current_display="$(printf '%q' "$current")"
  root_display="$(printf '%q' "$PROJECT")"
  managed_display="$(printf '%q' "$managed")"
  diagnostic="core.hooksPath is $current_display; the Trellis managed dispatcher is $managed_display; run git -C $root_display config core.hooksPath $managed_display"
  [[ "$output" == *"trellis attach: refusing detach: $diagnostic"* ]] || { echo "$output"; false; }
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = "$current" ]
  [ -f "$owner" ]
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "detach resumes a claimed merged JSON render without losing project keys" {
  run_attach
  [ "$status" -eq 0 ]
  temp="$PROJECT/.claude/settings.local.json.tmp"
  jq '.project = "keep" | .later = {"value":1}' "$PROJECT/.claude/settings.local.json" > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$PROJECT/.claude/settings.local.json"

  run env ATTACHMENT_FAULT_PHASE=detach-render-claimed "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)"
  [ -f "$journal" ]
  [ ! -e "$PROJECT/.claude/settings.local.json" ]

  run_detach --harness claude

  [ "$status" -eq 0 ]
  [ ! -e "$journal" ]
  jq -e '.project == "keep" and .later.value == 1 and (has("hooks") | not)' "$PROJECT/.claude/settings.local.json"
}

@test "detach resumes published render bytes exactly after a crash" {
  mkdir -p "$PROJECT/.claude"
  before="$SANDBOX/settings-before.json"
  printf '{\n  "project": "keep"\n}\n' > "$before"
  chmod 600 "$before"
  cp "$before" "$PROJECT/.claude/settings.local.json"
  chmod 600 "$PROJECT/.claude/settings.local.json"
  before_mode="$(file_mode "$before")"
  run_attach
  [ "$status" -eq 0 ]

  run env ATTACHMENT_FAULT_PHASE=detach-render-published "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)"
  [ -f "$journal" ]
  cmp -s "$before" "$PROJECT/.claude/settings.local.json"
  [ "$(file_mode "$PROJECT/.claude/settings.local.json")" = "$before_mode" ]

  run_detach --harness claude

  [ "$status" -eq 0 ]
  [ ! -e "$journal" ]
  cmp -s "$before" "$PROJECT/.claude/settings.local.json"
  [ "$(file_mode "$PROJECT/.claude/settings.local.json")" = "$before_mode" ]
}

@test "detach conflict preserves a replacement made after the render claim" {
  run_attach
  [ "$status" -eq 0 ]
  temp="$PROJECT/.claude/settings.local.json.tmp"
  jq '.project = "keep"' "$PROJECT/.claude/settings.local.json" > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$PROJECT/.claude/settings.local.json"

  run env ATTACHMENT_FAULT_PHASE=detach-render-claimed "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)"
  [ -f "$journal" ]
  replacement="$SANDBOX/replacement.json"
  printf '{"project":"replacement"}\n' > "$replacement"
  chmod 600 "$replacement"
  cp "$replacement" "$PROJECT/.claude/settings.local.json"
  chmod 600 "$PROJECT/.claude/settings.local.json"

  run_detach --harness claude

  [ "$status" -eq 3 ]
  [ -f "$journal" ]
  cmp -s "$replacement" "$PROJECT/.claude/settings.local.json"
}

@test "detach recovery rejects malformed durable render pending records" {
  run_attach
  [ "$status" -eq 0 ]
  run env ATTACHMENT_FAULT_PHASE=detach-render-claimed "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)"
  [ -f "$journal" ]
  original="$SANDBOX/journal-original.json"
  cp "$journal" "$original"

  jq 'del(.external.render_pending.source_identity)' "$original" > "$journal"
  chmod 600 "$journal"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 4 ]

  jq '.external.render_pending.unexpected = true' "$original" > "$journal"
  chmod 600 "$journal"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 4 ]

  jq '.external.render_pending.result_sha256 = "invalid"' "$original" > "$journal"
  chmod 600 "$journal"
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 4 ]
}

phase5_capture() {
  local label="$1"
  mkdir -p "$evidence/$label"
  cp "$TRELLIS_HOME/registry.json" "$evidence/$label/registry.json"
  cp "$owner" "$evidence/$label/owner.json"
  if [ -f "$journal" ]; then cp "$journal" "$evidence/$label/journal.json"; fi
  detach_state_snapshot > "$evidence/$label/state.json"
}

phase5_case() {
  local variant="$1" expected_status="$2"
  local evidence="${PHASE5_EVIDENCE:-$SANDBOX/evidence}/$variant" owner journal
  mkdir -p "$evidence"
  run_attach
  printf '%s\n' "$output" > "$evidence/attach.log"
  [ "$status" -eq 0 ] || return 1
  [ -x "$HOME/.local/bin/trellis" ] || return 1
  owner="$(owner_for_root "$PROJECT")"
  run env ATTACHMENT_FAULT_PHASE=detach-registry-after "$ATTACH" detach --home "$TRELLIS_HOME" --harness claude "$PROJECT"
  printf '%s\n' "$output" > "$evidence/fault.log"
  printf '%s\n' "$status" > "$evidence/fault.status"
  [ "$status" -eq 5 ] || return 1
  local journals=("$TRELLIS_HOME"/state/attachment-journals/detach-*.json)
  [ "${#journals[@]}" -eq 1 ] || return 1
  journal="${journals[0]}"
  phase5_capture phase4
  jq -e '.owner_committed == true and .external.phase == 4' "$journal" || return 1
  jq -e --slurpfile j "$journal" '.projects["personal/fixture-project"].checkouts[$j[0].checkout_id] == $j[0].external.registry_update.after' "$TRELLIS_HOME/registry.json" || return 1
  run bash -c '. "$1"; attachment_detach_mark_external_phase "$2" "$3" 5' _ "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$journal"
  printf '%s\n' "$output" > "$evidence/mark.log"
  printf '%s\n' "$status" > "$evidence/mark.status"
  [ "$status" -eq 0 ] || return 1
  jq -e '.owner_committed == true and .external.phase == 5' "$journal" || return 1
  phase5_capture marked
  if [ "$variant" != after ]; then
    jq --slurpfile j "$journal" --arg variant "$variant" '
      .projects["personal/fixture-project"].checkouts[$j[0].checkout_id] =
      (if $variant == "expected" then $j[0].external.registry_update.expected
       else ($j[0].external.registry_update.after | .harnesses = ["claude"]) end)
    ' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-new.json" || return 1
    cp "$SANDBOX/registry-new.json" "$TRELLIS_HOME/registry.json"
  fi
  phase5_capture before
  # All fixture and durable-marker checks passed; failures below are business assertions.
  printf 'business\n' > "$evidence/stage"
  if [ -n "${PHASE5_EVIDENCE:-}" ]; then rm -f "$PHASE5_EVIDENCE/setup-incomplete"; fi
  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  printf '%s\n' "$output" > "$evidence/recover.log"
  printf '%s\n' "$status" > "$evidence/recover.status"
  phase5_capture after
  echo "phase5 $variant actual_recover_status=$status expected=$expected_status evidence=$evidence"
  [ "$status" -eq "$expected_status" ]
  if [ "$variant" = after ]; then
    [ ! -e "$journal" ]
    cmp "$evidence/before/registry.json" "$evidence/after/registry.json"
    cmp "$evidence/before/owner.json" "$evidence/after/owner.json"
    jq -e --slurpfile owner "$owner" --slurpfile j "$evidence/before/journal.json" '
      .projects["personal/fixture-project"].checkouts[$owner[0].checkout_id] |
      . == $j[0].external.registry_update.after and $owner[0] == $j[0].next_owner and
      .harnesses == ["codex"] and .release == $owner[0].release and
      .worktrees[$owner[0].worktree_id].attachment_id == $owner[0].attachment_id
    ' "$TRELLIS_HOME/registry.json"
    [ ! -L "$PROJECT/.claude/rules/trellis.md" ]
    [ -L "$PROJECT/.agents/rules/trellis.md" ]
  else
    [ -f "$journal" ]
    cmp "$evidence/before/state.json" "$evidence/after/state.json"
  fi
}

@test "phase5 expected registry rollback must conflict without mutation" {
  phase5_case expected 3
}
@test "phase5 unchanged after snapshot recovers with registry owner agreement" {
  phase5_case after 0
}
@test "phase5 other valid harness drift conflicts without mutation" {
  phase5_case drift 3
}
