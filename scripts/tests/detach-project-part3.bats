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
  diagnostic="core.hooksPath is $current_display in $root_display; the Trellis managed dispatcher is $managed_display; run trellis doctor --fix"
  [[ "$output" == *"trellis attach: refusing detach: $diagnostic"* ]] || { echo "$output"; false; }
  # Spec 055 R4.6: the remedy is the guarded repair, never a bare config write.
  [[ "$output" != *"config core.hooksPath"* ]] || { echo "$output"; false; }
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

@test "detach names owned file drift" {
  run_attach
  [ "$status" -eq 0 ]
  printf 'edited\n' >> "$PROJECT/.claude/primers/INDEX.md"
  run_detach_split
  assert_refusal 3 detach owned-file-drift "$PROJECT/.claude/primers/INDEX.md"
}

@test "detach names owned symlink drift, first in sorted path order" {
  run_attach
  [ "$status" -eq 0 ]
  ln -sfn wrong-target "$PROJECT/.claude/rules/trellis.md"
  ln -sfn wrong-target "$PROJECT/.agents/rules/trellis.md"
  run_detach_split
  assert_refusal 3 detach owned-symlink-drift "$PROJECT/.agents/rules/trellis.md"
}

@test "adopt names owned file drift" {
  run_attach
  [ "$status" -eq 0 ]
  make_release 1.2.4
  printf 'edited\n' >> "$PROJECT/.claude/primers/INDEX.md"
  run_adopt 1.2.4
  assert_adopt_refusal owned-file-drift "$PROJECT/.claude/primers/INDEX.md"
}

@test "adopt names owned symlink drift" {
  run_attach
  [ "$status" -eq 0 ]
  make_release 1.2.4
  ln -sfn wrong-target "$PROJECT/.claude/rules/trellis.md"
  run_adopt 1.2.4
  assert_adopt_refusal owned-symlink-drift "$PROJECT/.claude/rules/trellis.md"
}

@test "detach names an invalid owner record" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  replace_json "$owner" 'del(.artifacts)'
  run_detach_split
  assert_refusal 4 detach owner-record-invalid "$owner"
}

@test "detach names a mislocated owner record" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  moved="$(dirname "$owner")/0000000000000000000000000000000000000000000000000000000000000000.json"
  mv "$owner" "$moved"
  run_detach_split
  assert_refusal 4 detach owner-path-mislocated "$moved"
}
