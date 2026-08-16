#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture

sha256_file() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

file_mode() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
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

wait_for_checkout_lock() {
  local path attempt
  path="$(checkout_lock_path)"
  attempt=0
  while [ "$attempt" -lt 200 ]; do
    [ -L "$path" ] && return 0
    sleep 0.01
    attempt=$((attempt + 1))
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
    },
    "omp": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".omp/AGENTS.md"}
      ],
      "render": []
    }
  }
}
JSON
  printf '%s\n' "$release" > "$repo/core-rules/VERSION"
  # scripts/release.sh refuses pathname execution, so the fixture release is
  # sealed and installed through the bootstrap launcher instead.
  release_fixture_install "$HOME" "$TRELLIS_HOME" "$release" "$repo"
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
  [ ! -e "$PROJECT/.omp/AGENTS.md" ]
  [ ! -e "$owner" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
  jq -e '[.. | objects | .attachment_id? // empty] | length == 0' "$TRELLIS_HOME/registry.json"
  jq -e '[.projects[].checkouts[].worktrees[]] | length == 1' "$TRELLIS_HOME/registry.json"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "checkout lock rejects concurrent detach without common-state drift and releases on signal" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  owner_hash="$(sha256_file "$owner")"
  exclude_hash="$(sha256_file "$PROJECT/.git/info/exclude")"
  registry_hash="$(sha256_file "$TRELLIS_HOME/registry.json")"

  ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK=10 "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT" >"$SANDBOX/held-detach.log" 2>&1 &
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
    run env ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK=10 "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
    [ "$status" -eq 5 ]
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
    and all(.[]; contains("$CODEX_PROJECT_DIR") and (contains("__TRELLIS_") | not))' \
    "$PROJECT/.codex/hooks.json"
  [ -L "$PROJECT/.omp/AGENTS.md" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  owner="$(owner_for_root "$PROJECT")"
  jq -e '[.artifacts[].path | if . == "AGENTS.md" or startswith(".agents/") or startswith(".codex/") then "codex" elif startswith(".omp/") then "omp" else empty end] | unique | sort == ["codex","omp"]' "$owner"
}

@test "modified owned artifact blocks detach before any mutation" {
  run_attach
  [ "$status" -eq 0 ]
  owner="$(owner_for_root "$PROJECT")"
  exclude_attached="$(sha256_file "$PROJECT/.git/info/exclude")"
  rm "$PROJECT/.omp/AGENTS.md"
  ln -s wrong-target "$PROJECT/.omp/AGENTS.md"

  run_detach

  [ "$status" -eq 3 ]
  [ -f "$owner" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ -L "$PROJECT/.claude/rules/trellis.md" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  [ "$(readlink "$PROJECT/.omp/AGENTS.md")" = wrong-target ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$exclude_attached" ]
}

@test "detaching the exclude manager transfers ownership until the final worktree leaves" {
  mkdir -p "$PROJECT/.husky/_"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_attach
  [ "$status" -eq 0 ]
  WORKTREE="$SANDBOX/linked worktree"
  git -C "$PROJECT" worktree add -qb fixture-linked "$WORKTREE"
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
  git -C "$PROJECT" worktree add -qb fixture-all "$WORKTREE"
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
  git -C "$PROJECT" worktree add -qb fixture-partial "$WORKTREE"
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
  grep -F '# --- Trellis local attachment exclude block ---' "$PROJECT/.git/info/exclude"

  run_detach

  [ "$status" -eq 0 ]
  [ ! -e "$journal" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ -d "$PROJECT/.claude" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$EXCLUDE_HASH" ]
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
  git -C "$PROJECT" config --local core.hooksPath other-manager
  run_detach
  [ "$status" -eq 3 ]
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
