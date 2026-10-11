#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture
bats_require_minimum_version 1.5.0

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
  release_fixture_seal_executed_files "$repo" || return 1
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

# $schema is informational: both the attachment schema and the detach owner
# validator allow any nonempty string. Padding it does not change artifacts,
# renders, bindings or shared-exclude authority. Use files/stdin in the fixture
# too, so creating the regression cannot itself hit exec's argv limit.
make_large_checkout_group() {
  local large_renders="${1:-false}" index root owner temp count=0
  for ((index=0; index<13; index++)); do
    root="$PROJECT"
    if [ "$index" -gt 0 ]; then
      root="$SANDBOX/large worktree $index"
      git -C "$PROJECT" worktree add -q -b "fixture-large-$index" "$root" || return 1
    fi
    if [ "$large_renders" = true ]; then
      mkdir -p "$root/.claude" "$root/.codex" || return 1
      # Two valid pre-existing JSON documents produce >1 MiB of render
      # snapshots per owner (two before/after base64 pairs). Their unrelated
      # project-authored key must survive adoption unchanged.
      jq -n '{project_padding: ("x" * 210000)}' > "$root/.claude/settings.local.json" || return 1
      cp "$root/.claude/settings.local.json" "$root/.codex/hooks.json" || return 1
      chmod 600 "$root/.claude/settings.local.json" "$root/.codex/hooks.json" || return 1
    fi
    run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$root"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    temp="$owner.next"
    jq '."$schema" = ("https://example.invalid/" + ("x" * 110000))' "$owner" > "$temp" || return 1
    chmod 600 "$temp" || return 1
    mv "$temp" "$owner" || return 1
    [ "$(wc -c < "$owner")" -ge 100000 ] || return 1
    # Exercise the same schema/artifact preflight detach uses, not just a
    # permissive JSON parse. This also proves padding has not invalidated it.
    run bash -c '. "$1"; attachment_verify_detach "$2" "$3"' \
      large-owner "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$owner"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    count=$((count + 1))
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print)
  [ "$count" -eq 13 ]
}

# Inversion: after ten padded owners, --argjson current exceeds 1.1 MB even
# before the eleventh record and environment. The old owners argv loop exits
# 4 on macOS (E2BIG); Linux can fail earlier at its per-argument size limit.
@test "all-worktrees detach handles thirteen owners larger than 100 KB" {
  make_large_checkout_group

  run_detach --all-worktrees

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print)" ]
  [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  for ((index=1; index<13; index++)); do
    [ ! -e "$SANDBOX/large worktree $index/.trellis/runtime" ]
  done
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
}

# End-to-end large-render coverage, not an isolated adopt inversion: the old
# code fails during attach setup while accumulating >1 MiB of render snapshots,
# before adopt runs. Isolating adopt would require a separate valid owner/render
# seeder; keep the real attach fixture rather than forge its ownership records.
@test "adopt handles thirteen large owners and render snapshots over ARG_MAX" {
  make_large_checkout_group true
  make_release 1.2.4

  run_adopt 1.2.4

  [ "$status" -eq 0 ] || { echo "status $status: $output $stderr"; false; }
  count=0
  while IFS= read -r owner; do
    jq -e '.release == "1.2.4" and (."$schema" | length > 100000)
      and (.renders | tojson | length > 1048576)' "$owner"
    root="$(jq -r '.worktree_root' "$owner")"
    [ "$(readlink "$root/.trellis/runtime")" = "$TRELLIS_HOME/releases/1.2.4/payload" ]
    jq -e '.project_padding == ("x" * 210000)' "$root/.claude/settings.local.json"
    jq -e '.project_padding == ("x" * 210000)' "$root/.codex/hooks.json"
    count=$((count + 1))
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print)
  [ "$count" -eq 13 ]
  jq -e '.projects["personal/fixture-project"].checkouts[] |
    .release == "1.2.4" and (.worktrees | length == 13)' "$TRELLIS_HOME/registry.json"
}

# Inversion: one owner whose render snapshots alone exceed 1 MiB. Re-running
# attach reconciles it, and the bound-harness read passed the whole owner as
# `jq --argjson record`, which exits 4 with `Argument list too long` on macOS.
@test "attach reconciles an owner record larger than ARG_MAX" {
  mkdir -p "$PROJECT/.claude" "$PROJECT/.codex"
  jq -n '{project_padding: ("x" * 210000)}' > "$PROJECT/.claude/settings.local.json"
  cp "$PROJECT/.claude/settings.local.json" "$PROJECT/.codex/hooks.json"
  chmod 600 "$PROJECT/.claude/settings.local.json" "$PROJECT/.codex/hooks.json"
  run_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(owner_for_root "$PROJECT")"
  [ "$(wc -c < "$owner")" -gt 1048576 ]
  owner_hash="$(sha256_file "$owner")"

  run_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'Argument list too long'* ]] || { echo "$output"; false; }
  [ "$(sha256_file "$owner")" = "$owner_hash" ]
  jq -e '.project_padding == ("x" * 210000)' "$PROJECT/.claude/settings.local.json"
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

# Spec 053 Unit E: every refusal names itself on exactly one stderr line,
# `trellis <action>: refused (<code>): <path>`, and keeps its exit class.
run_detach_split() {
  run --separate-stderr "$ATTACH" detach --home "$TRELLIS_HOME" "$@" "$PROJECT"
}

assert_refusal() {
  local expected_status="$1" action="$2" code="$3" path="$4"
  [ "$status" -eq "$expected_status" ] || { echo "status $status, stderr: $stderr"; false; }
  [ "${#stderr_lines[@]}" -eq 1 ] || { echo "stderr: $stderr"; false; }
  [ "$stderr" = "trellis $action: refused ($code): $path" ] || { echo "stderr: $stderr"; false; }
}

# Adopt's per-project summary line predates spec 053 and is kept; the refusal
# line is the one new line ahead of it.
assert_adopt_refusal() {
  [ "$status" -eq 3 ] || { echo "status $status, stderr: $stderr"; false; }
  [ "${#stderr_lines[@]}" -eq 2 ] || { echo "stderr: $stderr"; false; }
  [ "${stderr_lines[0]}" = "trellis adopt: refused ($1): $2" ] || { echo "stderr: $stderr"; false; }
  [ "${stderr_lines[1]}" = "trellis release: attachment ownership/runtime preflight failed for personal/fixture-project" ]
}

replace_json() {
  local path="$1" filter="$2" mode
  mode="$(file_mode "$path")"
  jq "$filter" "$path" > "$path.next"
  chmod "$mode" "$path.next"
  mv "$path.next" "$path"
}

prepare_detach_journal() {
  run env ATTACHMENT_FAULT_PHASE=detach-prepared "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  JOURNAL="$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name 'detach-*.json' -print)"
  [ -f "$JOURNAL" ]
}

run_adopt() {
  run --separate-stderr env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" GIT_CONFIG_NOSYSTEM=1 \
    "$RELEASE_FIXTURE_LAUNCHER" release adopt "$1" --project fixture-project
}

attach_and_adopt() {
  run_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  OWNER="$(owner_for_root "$PROJECT")"
  OWNER_SNAPSHOT_BEFORE="$(jq -cS '{renders,artifacts:[.artifacts[] | select(.path != ".trellis/runtime")],exclude}' "$OWNER")"
  make_release 1.2.4
  run_adopt 1.2.4
  [ "$status" -eq 0 ] || { echo "status $status: $output $stderr"; false; }
  [ "$(jq -r '.release' "$OWNER")" = 1.2.4 ]
}
