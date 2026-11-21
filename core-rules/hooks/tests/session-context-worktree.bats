#!/usr/bin/env bats
# T14 SessionStart diagnosis is intentionally read-only and worktree-aware.

load helpers

HOOK="$HOOKS_DIR/session-context.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/session-context.sh"

session_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
  else
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  fi
}

session_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    sha256sum "$1" | cut -d ' ' -f 1
  fi
}

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

extract_ctx() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'
}

session_base64_file() {
  base64 < "$1" | tr -d '\n'
}

session_posix_shell_quote() {
  local value="$1" output="'" char index=0
  while [ "$index" -lt "${#value}" ]; do
    char="${value:$index:1}"
    if [ "$char" = "'" ]; then
      output="${output}'\\''"
    else
      output="${output}${char}"
    fi
    index=$((index + 1))
  done
  printf "%s'" "$output"
}

session_write_release() {
  local oid
  RELEASE_DIR="$TRELLIS_HOME/releases/1.2.3"
  RUNTIME="$RELEASE_DIR/payload"
  mkdir -p "$RUNTIME/core-rules"
  printf '# fixture policy\n' > "$RUNTIME/core-rules/CLAUDE.md"
  oid="$(git hash-object --no-filters "$RUNTIME/core-rules/CLAUDE.md")"
  jq -n --arg oid "$oid" '{
    schema_version: 1,
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "0000000000000000000000000000000000000000",
    remote: "fixture",
    tree: [{path:"core-rules/CLAUDE.md",mode:"100644",oid:$oid}]
  }' > "$RELEASE_DIR/release.json"
  session_add_release_helpers
  chmod -R a-w "$RELEASE_DIR"
}

# A real payload carries the stamp and full-verification helpers it executes.
session_add_release_helpers() {
  local file oid mode
  mkdir -p "$RUNTIME/scripts/lib"
  for file in release-stamp.sh release-store.sh release_stamp.py release_verify.py semver.sh; do
    cp "$HOOKS_DIR/../../scripts/lib/$file" "$RUNTIME/scripts/lib/$file"
    oid="$(git hash-object --no-filters "$RUNTIME/scripts/lib/$file")"
    mode="$(git -C "$HOOKS_DIR/../.." ls-files -s "scripts/lib/$file" | cut -d ' ' -f 1)"
    jq --arg path "scripts/lib/$file" --arg mode "$mode" --arg oid "$oid" \
      '.tree += [{path:$path,mode:$mode,oid:$oid}]' "$RELEASE_DIR/release.json" > "$SANDBOX/release.next.json"
    mv "$SANDBOX/release.next.json" "$RELEASE_DIR/release.json"
  done
}

session_write_owner() {
  local root="$1" worktree_id="$2" attachment="$3" owner render sha before_sha encoded hook_root
  local user_home_shell trellis_home_shell launcher_shell
  mkdir -p "$root/.trellis" "$root/.claude/rules"
  rm -f "$root/.trellis/runtime" "$root/.claude/rules/trellis.md"
  ln -s "$RUNTIME" "$root/.trellis/runtime"
  ln -s "$RUNTIME/core-rules/CLAUDE.md" "$root/.claude/rules/trellis.md"
  render="$root/.claude/settings.local.json"
  printf '%s\n' '{"rendered":true}' > "$render"
  chmod 600 "$render"
  sha="$(session_sha256_file "$render")"
  before_sha="$(session_sha256 '')"
  encoded="$(session_base64_file "$render")"
  hook_root="$TRELLIS_HOME/state/git-hooks/$CHECKOUT_ID"
  owner="$TRELLIS_HOME/state/attachments/$CHECKOUT_ID/$worktree_id.json"
  mkdir -p "$(dirname "$owner")"
  chmod 700 "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/attachments" "$(dirname "$owner")"
  user_home_shell="$(session_posix_shell_quote "$USER_HOME")"
  trellis_home_shell="$(session_posix_shell_quote "$TRELLIS_HOME")"
  launcher_shell="$(session_posix_shell_quote "$USER_LAUNCHER")"
  jq -n \
    --arg checkout "$CHECKOUT_ID" --arg worktree "$worktree_id" --arg attachment "$attachment" \
    --arg root "$root" --arg runtime "$RUNTIME" --arg sha "$sha" --arg before_sha "$before_sha" \
    --arg encoded "$encoded" --arg hook_root "$hook_root" --arg user_home "$USER_HOME" \
    --arg trellis_home "$TRELLIS_HOME" --arg launcher "$USER_LAUNCHER" \
    --arg user_home_shell "$user_home_shell" --arg trellis_home_shell "$trellis_home_shell" \
    --arg launcher_shell "$launcher_shell" '{
      schema_version:1,
      status:"committed",
      fleet:"personal",
      project_id:"fixture-project",
      checkout_id:$checkout,
      worktree_id:$worktree,
      attachment_id:$attachment,
      project_root:$root,
      worktree_root:$root,
      release:"1.2.3",
      artifacts:[
        {path:".trellis",kind:"parent"},
        {path:".trellis/runtime",kind:"symlink",target:$runtime},
        {path:".claude",kind:"parent"},
        {path:".claude/rules",kind:"parent"},
        {path:".claude/rules/trellis.md",kind:"symlink",target:($runtime + "/core-rules/CLAUDE.md")},
        {path:".claude/settings.local.json",kind:"file",sha256:$sha,mode:"0600"}
      ],
      renders:[{
        path:".claude/settings.local.json",
        merge:"explicit-json",
        mode:"0600",
        before_exists:false,
        before_sha256:$before_sha,
        before_base64:"",
        before_mode:null,
        after_sha256:$sha,
        after_base64:$encoded,
        after_mode:"0600",
        owned_keys:[{path:["rendered"],value:true}],
        created_paths:[["rendered"]]
      }],
      render_context:{
        schema_version:1,
        user_home:$user_home,
        trellis_home:$trellis_home,
        launcher:$launcher,
        user_home_shell:$user_home_shell,
        trellis_home_shell:$trellis_home_shell,
        launcher_shell:$launcher_shell
      },
      git_hooks:{
        enabled:true,
        managed_hooks_path:$hook_root,
        previous_hooks_path:null,
        pre_push_source:"core-rules/githooks/pre-push"
      }
    }' > "$owner"
  chmod 600 "$owner"
}

build_attachment_fixture() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/session-context-t14.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  export TRELLIS_HOME="$SANDBOX/trellis home"
  MAIN="$SANDBOX/main checkout"
  WT="$SANDBOX/linked worktree"
  POISON_RUNTIME="$SANDBOX/poison runtime"
  MARKER="$SANDBOX/runtime-executed"
  USER_HOME="$SANDBOX/session user home"
  USER_LAUNCHER="$USER_HOME/.local/bin/trellis"
  mkdir -p "$MAIN" "$TRELLIS_HOME/releases" "$POISON_RUNTIME/scripts" "$(dirname "$USER_LAUNCHER")"
  # TRELLIS_HOME is created 0700 by the product (scripts/lib/trellis-home.sh,
  # scripts/lib/attachment.sh), and the hook's diagnosis refuses a home that is
  # not private. `mkdir -p` leaves it umask-wide, so without this the fixture
  # tripped the privacy check and EVERY test in this file saw the missing
  # attachment warning — including the ones asserting it appears.
  chmod 700 "$TRELLIS_HOME"
  printf '#!/bin/sh\nexit 0\n' > "$USER_LAUNCHER"
  chmod 755 "$USER_LAUNCHER"
  cat > "$POISON_RUNTIME/scripts/seed-inheritance-symlinks.sh" <<EOF
#!/usr/bin/env bash
touch "$MARKER"
exit 0
EOF
  chmod +x "$POISON_RUNTIME/scripts/seed-inheritance-symlinks.sh"
  git init -q "$MAIN"
  git -C "$MAIN" config user.email fixture@example.invalid
  git -C "$MAIN" config user.name 'Session Fixture'
  git -C "$MAIN" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$MAIN/.trellis.json"
  printf 'fixture\n' > "$MAIN/README.md"
  git -C "$MAIN" add .trellis.json README.md
  git -C "$MAIN" commit -qm initial
  git -C "$MAIN" worktree add -q -b t14-session "$WT"

  common="$(git -C "$WT" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$WT/$common" ;;
  esac
  common="$(canonical_dir "$common")"
  main_root="$(canonical_dir "$MAIN")"
  wt_root="$(canonical_dir "$WT")"
  CHECKOUT_ID="$(session_sha256 "$common")"
  MAIN_ID="$(session_sha256 "$main_root")"
  WT_ID="$(session_sha256 "$wt_root")"
  MAIN_ATTACHMENT="11111111-1111-4111-8111-111111111111"
  WT_ATTACHMENT="22222222-2222-4222-8222-222222222222"
  session_write_release
  session_write_owner "$MAIN" "$MAIN_ID" "$MAIN_ATTACHMENT"
  session_write_owner "$WT" "$WT_ID" "$WT_ATTACHMENT"
  jq -n --arg checkout "$CHECKOUT_ID" --arg common "$common" --arg main "$main_root" --arg wt "$wt_root" \
    --arg main_id "$MAIN_ID" --arg wt_id "$WT_ID" --arg main_attachment "$MAIN_ATTACHMENT" \
    --arg wt_attachment "$WT_ATTACHMENT" '{
      schema_version:1,
      projects:{
        "personal/fixture-project":{
          fleet:"personal",
          project_id:"fixture-project",
          status:"active",
          metadata:{},
          checkouts:{
            ($checkout):{
              root:$main,
              git_common_dir:$common,
              release:"1.2.3",
              harnesses:["claude","codex"],
              worktrees:{
                ($main_id):{root:$main,attachment_id:$main_attachment},
                ($wt_id):{root:$wt,attachment_id:$wt_attachment}
              }
            }
          }
        }
      },
      discovery_ignores:{}
    }' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

destroy_attachment_fixture() {
  if [ -n "${MAIN:-}" ] && [ -n "${WT:-}" ] && [ -d "$MAIN" ] && [ -d "$WT" ]; then
    git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

run_session_context() {
  local candidate="$1" project_dir="$2"
  printf '%s' '{"source":"startup"}' | \
    TRELLIS_HOME="$TRELLIS_HOME" CLAUDE_PROJECT_DIR="$project_dir" CODEX_PROJECT_DIR="$project_dir" \
    TRELLIS_RUNTIME_ROOT="$POISON_RUNTIME" bash "$candidate"
}

teardown() {
  destroy_attachment_fixture
}

@test "Claude and Codex derive the active linked worktree toplevel without executing runtime input" {
  build_attachment_fixture
  mkdir -p "$WT/nested/session"

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT/nested/session")"
    printf '%s' "$out" | jq . >/dev/null
    ctx="$(extract_ctx "$out")"
    [[ "$ctx" != *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$ctx"; false; }
    [ ! -e "$MARKER" ]
  done
}

@test "a payload symlink like core-rules/AGENTS.md does not trip the missing-attachment warning" {
  build_attachment_fixture
  chmod -R u+w "$RELEASE_DIR"
  ln -s CLAUDE.md "$RUNTIME/core-rules/AGENTS.md"
  link_oid="$(printf '%s' CLAUDE.md | git hash-object --stdin)"
  jq --arg oid "$link_oid" '.tree += [{path:"core-rules/AGENTS.md",mode:"120000",oid:$oid}]' \
    "$RELEASE_DIR/release.json" > "$SANDBOX/release.json"
  mv "$SANDBOX/release.json" "$RELEASE_DIR/release.json"
  chmod -R a-w "$RELEASE_DIR"
  # BSD chmod -R also strips the link's own mode; a real install leaves it
  # writable (0700 under umask 077). Linux links always report 0777.
  chmod -h u+w "$RUNTIME/core-rules/AGENTS.md" 2>/dev/null || true

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    ctx="$(extract_ctx "$out")"
    [[ "$ctx" != *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$candidate: $ctx"; false; }
  done
}

@test "legacy discovery ignore path is accepted only when safe and does not suggest sync" {
  build_attachment_fixture
  for legacy in "$SANDBOX/previous location" /../unsafe relative; do
    jq --arg path "$SANDBOX/ignored" --arg legacy "$legacy" '
      .discovery_ignores.personal = [{path:$path,reason:"migrated",legacy_path:$legacy}]
    ' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry.next.json"
    mv "$SANDBOX/registry.next.json" "$TRELLIS_HOME/registry.json"
    chmod 600 "$TRELLIS_HOME/registry.json"
    out="$(run_session_context "$HOOK" "$WT")"
    ctx="$(extract_ctx "$out")"
    if [ "$legacy" = "$SANDBOX/previous location" ]; then
      [[ "$ctx" != *"Trellis attachment is missing"* ]] || { echo "$ctx"; return 1; }
    else
      [[ "$ctx" == *"Trellis attachment is missing"* ]] || { echo "unsafe legacy_path accepted: $legacy: $ctx"; return 1; }
      [[ "$ctx" == *"Report this finding to the operator"* ]] || { echo "$ctx"; return 1; }
    fi
    [[ "$ctx" != *"trellis worktree sync"* ]] || { echo "$ctx"; return 1; }
  done
}

@test "Pi-only and mixed harness selectors are valid through both session hooks" {
  build_attachment_fixture
  # Shared ownership proof only: this fixture does not load a native Pi extension.
  failures=0
  for harnesses in '["pi"]' '["claude","pi"]' '["codex","pi"]' '["claude","codex","pi"]'; do
    jq --arg checkout "$CHECKOUT_ID" --argjson harnesses "$harnesses" '
      .projects["personal/fixture-project"].checkouts[$checkout].harnesses = $harnesses
    ' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry.next.json"
    mv "$SANDBOX/registry.next.json" "$TRELLIS_HOME/registry.json"
    chmod 600 "$TRELLIS_HOME/registry.json"
    for candidate in "$HOOK" "$CODEX_HOOK"; do
      out="$(run_session_context "$candidate" "$WT")"
      printf '%s' "$out" | jq . >/dev/null
      ctx="$(extract_ctx "$out")"
      if [[ "$ctx" == *"Trellis attachment is missing"* ]]; then
        echo "$candidate $harnesses: $ctx"
        failures=$((failures + 1))
      fi
      [ ! -e "$MARKER" ]
    done
  done
  [ "$failures" -eq 0 ]
}

@test "unknown harness selector retains actionable warning through both session hooks" {
  build_attachment_fixture
  jq --arg checkout "$CHECKOUT_ID" '
    .projects["personal/fixture-project"].checkouts[$checkout].harnesses = ["pi", "unknown"]
  ' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry.next.json"
  mv "$SANDBOX/registry.next.json" "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    ctx="$(extract_ctx "$out")"
    [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$ctx"; false; }
    [[ "$ctx" == *"Report this finding to the operator"* ]] || { echo "$ctx"; false; }
    [[ "$ctx" != *"trellis worktree sync"* ]] || { echo "$ctx"; false; }
    [ ! -e "$MARKER" ]
  done
}

@test "Claude and Codex SessionStart never execute project or inherited fsmonitor commands" {
  build_attachment_fixture
  monitor="$SANDBOX/project-fsmonitor"
  cat > "$monitor" <<EOF
#!/usr/bin/env bash
touch "$MARKER"
printf '%s\n' token
EOF
  chmod +x "$monitor"
  git -C "$WT" config core.fsmonitor "$monitor"

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    printf '%s' "$out" | jq . >/dev/null
    [[ "$(extract_ctx "$out")" != *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
    [ ! -e "$MARKER" ]
  done

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="$monitor" \
      run_session_context "$candidate" "$WT")"
    printf '%s' "$out" | jq . >/dev/null
    [[ "$(extract_ctx "$out")" != *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
    [ ! -e "$MARKER" ]
  done
}

@test "missing owner or corrupt registry emits an actionable warning without runtime execution" {
  build_attachment_fixture
  rm "$TRELLIS_HOME/state/attachments/$CHECKOUT_ID/$WT_ID.json"

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    ctx="$(extract_ctx "$out")"
    [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$ctx"; false; }
    [ ! -e "$MARKER" ]
  done

  session_write_owner "$WT" "$WT_ID" "$WT_ATTACHMENT"

  printf '{broken\n' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    ctx="$(extract_ctx "$out")"
    [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$ctx"; false; }
    [ ! -e "$MARKER" ]
  done
}

@test "duplicate and colliding global registry state emits an actionable warning" {
  build_attachment_fixture
  clean_registry="$SANDBOX/registry.clean.json"
  duplicate_registry="$SANDBOX/registry.duplicate.json"
  cp "$TRELLIS_HOME/registry.json" "$clean_registry"

  jq '
    .projects["personal/duplicate-project"] =
      (.projects["personal/fixture-project"] | .project_id = "duplicate-project")
  ' "$clean_registry" > "$duplicate_registry"
  mv "$duplicate_registry" "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
    [ ! -e "$MARKER" ]
  done

  cp "$clean_registry" "$TRELLIS_HOME/registry.json"
  jq --arg wt "$WT" '
    .projects["personal/fixture-project"].unavailable_roots = [$wt]
  ' "$TRELLIS_HOME/registry.json" > "$duplicate_registry"
  mv "$duplicate_registry" "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
    [ ! -e "$MARKER" ]
  done
}

@test "removed or repointed owned paths and poisoned immutable payload warn without execution" {
  build_attachment_fixture
  rm "$WT/.claude/rules/trellis.md"

  out="$(run_session_context "$HOOK" "$WT")"
  [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
  [ ! -e "$MARKER" ]

  ln -s "$RUNTIME/core-rules/CLAUDE.md" "$WT/.claude/rules/trellis.md"
  rm "$WT/.trellis/runtime"
  ln -s "$POISON_RUNTIME" "$WT/.trellis/runtime"
  out="$(run_session_context "$CODEX_HOOK" "$WT")"
  [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
  [ ! -e "$MARKER" ]

  rm "$WT/.trellis/runtime"
  ln -s "$RUNTIME" "$WT/.trellis/runtime"
  printf '%s\n' '{"rendered":false}' > "$WT/.claude/settings.local.json"
  chmod 600 "$WT/.claude/settings.local.json"
  out="$(run_session_context "$HOOK" "$WT")"
  [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
  [ ! -e "$MARKER" ]

  chmod u+w "$RUNTIME/core-rules/CLAUDE.md"
  printf '# poisoned\n' > "$RUNTIME/core-rules/CLAUDE.md"
  out="$(run_session_context "$HOOK" "$WT")"
  [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
  [ ! -e "$MARKER" ]
}

@test "attached primary checkout remains outside the linked-worktree safety net" {
  build_attachment_fixture

  out="$(run_session_context "$HOOK" "$MAIN")"
  [[ "$(extract_ctx "$out")" != *"Trellis attachment is missing"* ]] || { echo "$out"; false; }
  [ ! -e "$MARKER" ]
}

@test "project owner optional shape is diagnosed without executing deferred paths or toolchain" {
  build_attachment_fixture
  owner="$TRELLIS_HOME/state/attachments/$CHECKOUT_ID/$WT_ID.json"
  clean_owner="$SANDBOX/owner.optional.json"
  mkdir -p "$WT/.agents/skills"
  ln -s "$POISON_RUNTIME/scripts" "$WT/.agents/skills/local"
  ln -s "$POISON_RUNTIME/scripts/seed-inheritance-symlinks.sh" "$WT/AGENTS.md"
  jq --arg toolchain "$POISON_RUNTIME/scripts" --arg target "$POISON_RUNTIME/scripts" '
    .surface = "project"
    | .toolchain_path = [$toolchain, "/usr/local/bin", "/usr/bin", "/bin"]
    | .pre_existing = [
        {kind:"symlink",path:".agents/skills/local",reason:"pre-existing-symlink",target:$target},
        {kind:"symlink",path:"AGENTS.md",reason:"project-authored-file",target:($target + "/seed-inheritance-symlinks.sh")}
      ]
  ' "$owner" > "$clean_owner"
  failures=0
  for mutation in '.' '.pre_existing += [{kind:"file",path:"local.json",reason:"project-authored-render",target:null}]' 'del(.surface, .toolchain_path) | .pre_existing = []'; do
    jq "$mutation" "$clean_owner" > "$owner"
    chmod 600 "$owner"
    for candidate in "$HOOK" "$CODEX_HOOK"; do
      out="$(run_session_context "$candidate" "$WT")"
      printf '%s' "$out" | jq . >/dev/null
      ctx="$(extract_ctx "$out")"
      if [[ "$ctx" == *"Trellis attachment is missing"* ]]; then
        echo "$candidate $mutation: $ctx"
        failures=$((failures + 1))
      fi
      [ ! -e "$MARKER" ]
    done
  done
  [ "$failures" -eq 0 ]
}

@test "malformed project owner optional shape warns without runtime execution through both hooks" {
  build_attachment_fixture
  owner="$TRELLIS_HOME/state/attachments/$CHECKOUT_ID/$WT_ID.json"
  clean_owner="$SANDBOX/owner.optional.json"
  jq --arg target "$POISON_RUNTIME/scripts" '
    .surface = "project" | .toolchain_path = [$target, "/usr/local/bin", "/usr/bin", "/bin"]
    | .pre_existing = [{kind:"symlink",path:"AGENTS.md",reason:"project-authored-file",target:$target}]
  ' "$owner" > "$clean_owner"
  for mutation in \
    '.pre_existing = null' '.pre_existing = {}' '.pre_existing = ["bad"]' \
    '.pre_existing[0].kind = "directory"' '.pre_existing[0].path = 1' \
    '.pre_existing[0].path = "../escape"' '.pre_existing[0].path = "/absolute"' \
    '.pre_existing[0].reason = "unknown"' '.pre_existing[0].reason = "project-authored-render"' \
    '.pre_existing[0].target = null' '.pre_existing[0].target = "bad\npath"' \
    '.pre_existing[0].extra = true' '.pre_existing += [.pre_existing[0]]' \
    '.pre_existing[0].path = ".trellis/runtime"' \
    '.pre_existing[0] = {kind:"file",path:"local.json",reason:"project-authored-render",target:"not-null"}' \
    '.surface = "user"' '.surface = null' '.surface = ["project"]' \
    '.toolchain_path = null' '.toolchain_path = "/usr/bin"' '.toolchain_path = []' \
    '.toolchain_path = [1]' '.toolchain_path = ["relative"]' '.toolchain_path = ["/"]' \
    '.toolchain_path = ["/usr/../bin"]' '.toolchain_path = ["/usr//bin"]' \
    '.toolchain_path = ["/usr/bin/"]' '.toolchain_path = ["/usr/bin\n"]' '.unknown = true'; do
    jq "$mutation" "$clean_owner" > "$owner"
    chmod 600 "$owner"
    for candidate in "$HOOK" "$CODEX_HOOK"; do
      out="$(run_session_context "$candidate" "$WT")"
      printf '%s' "$out" | jq . >/dev/null
      ctx="$(extract_ctx "$out")"
      [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$candidate $mutation: $ctx"; false; }
      [[ "$ctx" == *"Report this finding to the operator"* ]] || { echo "$ctx"; false; }
      [[ "$ctx" != *"trellis worktree sync"* ]] || { echo "$ctx"; false; }
      [ ! -e "$MARKER" ]
    done
  done
}

@test "compact SessionStart remains silent for an opted-in linked worktree" {
  build_attachment_fixture

  out="$(printf '%s' '{"source":"compact"}' | TRELLIS_HOME="$TRELLIS_HOME" CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")"
  [ -z "$out" ]
  [ ! -e "$MARKER" ]
}

# --- Release integrity chain (spec 072 U4): stamp -> full verify -> WARN. A
# post-attach verdict is never evidence on its own. The inline per-file verify
# is gone; these pin the order and that no leg ever passes silently. ---------

write_postjob_status() {
  local state="$1" owner_sha="${2:-}" dir="$TRELLIS_HOME/state/attachment-status/$CHECKOUT_ID"
  [ -n "$owner_sha" ] || owner_sha="$(session_sha256_file "$TRELLIS_HOME/state/attachments/$CHECKOUT_ID/$WT_ID.json")"
  mkdir -p "$dir"
  chmod 700 "$TRELLIS_HOME/state/attachment-status" "$dir"
  jq -n --arg state "$state" --arg checkout "$CHECKOUT_ID" --arg worktree "$WT_ID" \
    --arg attachment "$WT_ATTACHMENT" --arg sha "$owner_sha" '{
      schema_version:1,state:$state,checkout_id:$checkout,worktree_id:$worktree,
      attachment_id:$attachment,owner_sha256:$sha,updated_at:now,checks:[],failure:null}' > "$dir/$WT_ID.json"
  chmod 600 "$dir/$WT_ID.json"
}

# A copy of both hook trees under $LAYOUT/core-rules, so a test decides which
# release libraries the hooks can reach through $LAYOUT/scripts/lib.
copy_hook_layout() {
  LAYOUT="$SANDBOX/layout"
  mkdir -p "$LAYOUT/core-rules/codex"
  cp -R "$HOOKS_DIR" "$LAYOUT/core-rules/hooks"
  cp -R "$CODEX_HOOKS_DIR" "$LAYOUT/core-rules/codex/hooks"
}

# The real stamp library beside a release-store.sh whose verify only records
# that it ran and refuses, so a test can see whether the chain reached it.
fake_full_verify_layout() {
  copy_hook_layout
  FULL_VERIFY_MARKER="$SANDBOX/full-verify-ran"
  mkdir -p "$LAYOUT/scripts/lib"
  cp "$HOOKS_DIR/../../scripts/lib/release-stamp.sh" "$HOOKS_DIR/../../scripts/lib/release_stamp.py" "$LAYOUT/scripts/lib/"
  printf 'release_store_locate() { : > %q; return 1; }\n' "$FULL_VERIFY_MARKER" > "$LAYOUT/scripts/lib/release-store.sh"
}

stamp_count() {
  find "$TRELLIS_HOME/state/release-stamps" -type f -name '*.json' 2>/dev/null | wc -l | tr -d '[:space:]'
}

tamper_release() {
  chmod u+w "$RUNTIME/core-rules" "$RUNTIME/core-rules/CLAUDE.md"
  printf '# poisoned\n' > "$RUNTIME/core-rules/CLAUDE.md"
  chmod a-w "$RUNTIME/core-rules/CLAUDE.md" "$RUNTIME/core-rules"
}

tamper_manifest() {
  chmod u+w "$RELEASE_DIR" "$RELEASE_DIR/release.json"
  jq '.tree[0].oid = "1111111111111111111111111111111111111111"' "$RELEASE_DIR/release.json" > "$SANDBOX/release.next.json"
  cat "$SANDBOX/release.next.json" > "$RELEASE_DIR/release.json"
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"
}

# Review HIGH-1: the post-attach verdict binds the owner record, not today's
# release bytes, so it never stands in for the stamp or the verify.
@test "a post-attach ok verdict does not vouch for release payload bytes changed since" {
  build_attachment_fixture
  out="$(run_session_context "$HOOK" "$WT")"
  [ "$(stamp_count)" -eq 1 ]
  write_postjob_status ok
  tamper_release
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$candidate: $out"; false; }
  done
}

@test "a post-attach ok verdict does not vouch for a release manifest changed since" {
  build_attachment_fixture
  out="$(run_session_context "$HOOK" "$WT")"
  [ "$(stamp_count)" -eq 1 ]
  write_postjob_status ok
  tamper_manifest
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$candidate: $out"; false; }
  done
}

@test "postjob pending and no stamp runs the full verify, which stamps a good release and refuses a tampered one" {
  build_attachment_fixture
  write_postjob_status pending
  [ "$(stamp_count)" -eq 0 ]
  out="$(run_session_context "$HOOK" "$WT")"
  [[ "$(extract_ctx "$out")" != *"Trellis attachment is missing"* ]] || { echo "$out"; false; }
  [ "$(stamp_count)" -eq 1 ] || { echo "the full verify did not stamp the release"; false; }

  tamper_release
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    out="$(run_session_context "$candidate" "$WT")"
    [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$candidate: $out"; false; }
  done
}

@test "an unchanged release stamp confirms the release without a verify, a changed one does not" {
  build_attachment_fixture
  out="$(run_session_context "$HOOK" "$WT")"
  [ "$(stamp_count)" -eq 1 ]
  fake_full_verify_layout
  for candidate in "$LAYOUT/core-rules/hooks/session-context.sh" "$LAYOUT/core-rules/codex/hooks/session-context.sh"; do
    out="$(run_session_context "$candidate" "$WT")"
    [[ "$(extract_ctx "$out")" != *"Trellis attachment is missing"* ]] || { echo "$candidate: $out"; false; }
    [ ! -e "$FULL_VERIFY_MARKER" ] || { echo "$candidate ran the full verify past an unchanged stamp"; false; }
  done

  tamper_release
  for candidate in "$LAYOUT/core-rules/hooks/session-context.sh" "$LAYOUT/core-rules/codex/hooks/session-context.sh"; do
    rm -f "$FULL_VERIFY_MARKER"
    out="$(run_session_context "$candidate" "$WT")"
    [ -e "$FULL_VERIFY_MARKER" ] || { echo "$candidate trusted a changed release"; false; }
    [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
  done
}

# Exercise the shipped native Pi bundle by default; an explicit build may be
# supplied for red/green checks before the release assets are regenerated.
# The bundle sources whose shipped digests decide whether the asset is current.
L153_INPUTS="native/trellis-hooks/src/pi_lifecycle.rs core-rules/codex/hooks/session-context.sh
  scripts/lib/release-stamp.sh scripts/lib/release-store.sh scripts/lib/release_stamp.py
  scripts/lib/semver.sh scripts/lib/release_verify.py"

# Prints "ok <asset>" or "skip <cause>"; a broken asset or manifest fails.
l153_companion_state() {
  local native="$1" repo="$2" target="$3" manifest asset path stale=""
  manifest="$native/artifacts.json"
  jq -e --arg t "$target" '(.inputs | type) == "object" and (.assets[$t].path | type) == "string"
    and (.assets[$t].sha256 | type) == "string"' "$manifest" >/dev/null 2>&1 ||
    { echo "native manifest is unreadable or malformed: $manifest"; return 1; }
  asset="$native/$(jq -r --arg t "$target" '.assets[$t].path' "$manifest")"
  [ -f "$asset" ] && [ -x "$asset" ] || { echo "native asset is missing or not executable: $asset"; return 1; }
  [ "$(session_sha256_file "$asset")" = "$(jq -r --arg t "$target" '.assets[$t].sha256' "$manifest")" ] ||
    { echo "native asset does not match its manifest digest: $asset"; return 1; }
  for path in $L153_INPUTS; do
    [ "$(jq -r --arg path "$path" '.inputs[$path] // ""' "$manifest")" = "$(session_sha256_file "$repo/$path")" ] ||
      stale="$stale${stale:+, }$path"
  done
  if [ -n "$stale" ]; then echo "skip stale native inputs (rebuild the assets or set TRELLIS_HOOKS_TEST_BINARY): $stale"
  else echo "ok $asset"; fi
}

l153_require_binary() {
  local target state
  if [ -n "${TRELLIS_HOOKS_TEST_BINARY:-}" ]; then
    [ -x "$TRELLIS_HOOKS_TEST_BINARY" ] || { echo "TRELLIS_HOOKS_TEST_BINARY is not executable: $TRELLIS_HOOKS_TEST_BINARY"; return 1; }
    return 0
  fi
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    *) skip "unsupported host for the native companion: $(uname -s):$(uname -m)" ;;
  esac
  state="$(l153_companion_state "$HOOKS_DIR/../native" "$HOOKS_DIR/../.." "$target")" || { echo "$state"; return 1; }
  case "$state" in "skip "*) skip "${state#skip }" ;; esac
  TRELLIS_HOOKS_TEST_BINARY="${state#ok }"
}

l153_prepare_payload() {
  local digest snapshot
  jq -nc '{schema_version:1,source_root:"/src",release_remote:"fixture://x",active_cli_release:"1.2.3",default_fleet:"personal",fleets:{personal:{discovery_roots:["/projects"]}}}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  digest="$(session_sha256_file "$RELEASE_DIR/release.json")"
  snapshot="$TRELLIS_HOME/releases/.exec/1.2.3-$digest"
  mkdir -p "$TRELLIS_HOME/state/exec-stamps"
  chmod 700 "$TRELLIS_HOME/state/exec-stamps"
  jq -nc --arg digest "$digest" --arg snapshot "$snapshot" --arg version "1.2.3-$digest" \
    '{directories:[],entries:[],release_json_sha256:$digest,root:$snapshot,schema_version:2,version:$version}' \
    > "$TRELLIS_HOME/state/exec-stamps/1.2.3-$digest.json"
  chmod 600 "$TRELLIS_HOME/state/exec-stamps/1.2.3-$digest.json"
  TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/release-stamp.sh"; . "$1/release-store.sh"
    release_stamp_check "$TRELLIS_HOME" "$2" && exit 1
    release_store_locate 1.2.3 >/dev/null || exit 1
    release_stamp_write "$TRELLIS_HOME" "$2"
  ' _ "$RUNTIME/scripts/lib" "$RELEASE_DIR"
}

l153_pi_session() {
  local request
  request="$(jq -nc --arg cwd "$WT" '{schema_version:1,harness:"pi",phase:"session_start",cwd:$cwd,session_id:"l153-session",reason:"startup"}')"
  printf '%s' "$request" | env -i HOME="$USER_HOME" TRELLIS_HOME="$TRELLIS_HOME" TMPDIR="$SANDBOX" \
    PATH="$PATH" "$@" "$TRELLIS_HOOKS_TEST_BINARY" event pi session_start "$WT"
}

# The context of exactly one session-context row with a successful result.
l153_session_ctx() {
  printf '%s' "$1" | jq -er '[.batch.members[] | select(.member == "session-context")] |
    if length == 1 and .[0].result.status == "advice" and .[0].result.exit_code == 0 and .[0].result.error_class == null
    then .[0].result.context else error("session-context row: \(tojson)") end'
}

# Healthy: the session's own context, and neither attachment warning.
l153_healthy_ctx() {
  [[ "$1" == *"Branch: t14-session"* && "$1" != *"Trellis could not confirm the release integrity"* &&
    "$1" != *"Trellis attachment is missing"* ]] || { echo "$1"; false; }
}

# Record a copy of a payload directory in the release inventory, so that a
# symlink to it is the only thing wrong with the payload.
l153_record_copy() {
  local from="$1" to="$2" file oid
  chmod -R u+w "$RELEASE_DIR"
  mkdir -p "$RUNTIME/$to"
  for file in "$RUNTIME/$from"/*; do
    cp -p "$file" "$RUNTIME/$to/"
    oid="$(git hash-object --no-filters "$file")"
    jq --arg path "$to/${file##*/}" --arg from "$from/${file##*/}" --arg oid "$oid" \
      '.tree += [.tree[] | select(.path == $from) | .path = $path | .oid = $oid]' \
      "$RELEASE_DIR/release.json" > "$SANDBOX/release.next.json"
    mv "$SANDBOX/release.next.json" "$RELEASE_DIR/release.json"
  done
  chmod -R a-w "$RELEASE_DIR"
}

# Replace a payload directory with a symlink to its recorded copy, or put
# the directory back from that copy; nothing unrecorded is left behind.
l153_swap_symlink() {
  local dir="$1" copy="$2" parent
  parent="$RUNTIME"
  case "$dir" in */*) parent="$RUNTIME/${dir%/*}" ;; esac
  chmod -R u+w "$parent"
  if [ -L "$RUNTIME/$dir" ]; then
    rm "$RUNTIME/$dir"; cp -Rp "$RUNTIME/$copy" "$RUNTIME/$dir"
  else
    rm -rf "${RUNTIME:?}/$dir"; ln -s "${copy##*/}" "$RUNTIME/$dir"
  fi
  chmod -R a-w "$parent"
}

@test "l153 companion selection fails on a broken asset or manifest and skips only on stale inputs" {
  local repo="$BATS_TEST_TMPDIR/repo" native="$BATS_TEST_TMPDIR/native" path inputs
  inputs='{}'
  for path in $L153_INPUTS; do
    mkdir -p "$repo/${path%/*}"
    printf '%s\n' "$path" > "$repo/$path"
    inputs="$(jq -c --arg path "$path" --arg sha "$(session_sha256_file "$repo/$path")" '.[$path] = $sha' <<<"$inputs")"
  done
  mkdir -p "$native/t"
  printf '#!/bin/sh\n' > "$native/t/trellis-hooks"
  chmod 755 "$native/t/trellis-hooks"
  jq -n --argjson inputs "$inputs" --arg sha "$(session_sha256_file "$native/t/trellis-hooks")" \
    '{inputs:$inputs,assets:{t:{path:"t/trellis-hooks",sha256:$sha}}}' > "$native/artifacts.json"

  run l153_companion_state "$native" "$repo" t
  [ "$status" -eq 0 ] && [ "$output" = "ok $native/t/trellis-hooks" ] || { echo "$output"; false; }
  printf 'changed\n' >> "$repo/scripts/lib/semver.sh"
  printf 'changed\n' >> "$repo/core-rules/codex/hooks/session-context.sh"
  run l153_companion_state "$native" "$repo" t
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "skip stale native inputs "*": core-rules/codex/hooks/session-context.sh, scripts/lib/semver.sh" ]] || { echo "$output"; false; }

  printf 'x\n' >> "$native/t/trellis-hooks"
  run l153_companion_state "$native" "$repo" t
  [ "$status" -eq 1 ] && [ "$output" = "native asset does not match its manifest digest: $native/t/trellis-hooks" ] || { echo "$output"; false; }
  chmod 644 "$native/t/trellis-hooks"
  run l153_companion_state "$native" "$repo" t
  [ "$status" -eq 1 ] && [ "$output" = "native asset is missing or not executable: $native/t/trellis-hooks" ] || { echo "$output"; false; }
  mv "$native/t/trellis-hooks" "$native/t/gone"
  run l153_companion_state "$native" "$repo" t
  [ "$status" -eq 1 ] && [ "$output" = "native asset is missing or not executable: $native/t/trellis-hooks" ] || { echo "$output"; false; }
  for manifest in '{' '{"inputs":{}}' ''; do
    printf '%s' "$manifest" > "$native/artifacts.json"
    run l153_companion_state "$native" "$repo" t
    [ "$status" -eq 1 ] && [ "$output" = "native manifest is unreadable or malformed: $native/artifacts.json" ] || { echo "$manifest: $output"; false; }
  done
  chmod 000 "$native/artifacts.json"
  run l153_companion_state "$native" "$repo" t
  [ "$status" -eq 1 ] && [ "$output" = "native manifest is unreadable or malformed: $native/artifacts.json" ] || { echo "$output"; false; }
}

@test "l153 native Pi session uses the attached release stamp and preserves Claude status" {
  l153_require_binary || false
  build_attachment_fixture
  l153_prepare_payload
  out="$(l153_pi_session)"
  ctx="$(l153_session_ctx "$out")" || { echo "$out"; false; }
  l153_healthy_ctx "$ctx"
  out="$(run_session_context "$HOOK" "$WT")"
  l153_healthy_ctx "$(extract_ctx "$out")"

  # A missing stamp falls through to the real verifier and is re-stamped.
  rm -f "$TRELLIS_HOME/state/release-stamps/"*.json
  out="$(l153_pi_session)"
  ctx="$(l153_session_ctx "$out")" || { echo "$out"; false; }
  l153_healthy_ctx "$ctx"
  [ "$(stamp_count)" -eq 1 ]
  # A stale stamp plus a changed release is refused, not called current.
  tamper_release
  out="$(l153_pi_session)"
  ctx="$(l153_session_ctx "$out")" || { echo "$out"; false; }
  [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$ctx"; false; }
  out="$(run_session_context "$HOOK" "$WT")"
  [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
}

@test "l153 native Pi session refuses symlinked payload scripts and lib" {
  local dir copy refusal
  l153_require_binary || false
  build_attachment_fixture
  l153_record_copy scripts/lib scripts/lib-copy
  l153_record_copy scripts/lib scripts-copy/lib
  l153_record_copy scripts/lib-copy scripts-copy/lib-copy
  l153_prepare_payload
  # The recorded copies alone are a healthy payload.
  ctx="$(l153_session_ctx "$(l153_pi_session)")" || false
  l153_healthy_ctx "$ctx"
  for pair in scripts:scripts-copy scripts/lib:scripts/lib-copy; do
    dir="${pair%%:*}" copy="${pair#*:}"
    l153_swap_symlink "$dir" "$copy"
    out="$(l153_pi_session)"
    ctx="$(l153_session_ctx "$out")" || { echo "$out"; false; }
    [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$dir: $ctx"; false; }
    # The embedded helpers' own refusal is the symlinked parent, nothing else.
    refusal="$(TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1/release-stamp.sh"; . "$1/release-store.sh"; release_store_locate 1.2.3' \
      _ "$HOOKS_DIR/../../scripts/lib" 2>&1 >/dev/null)" && { echo "$dir: verifier accepted"; false; }
    [[ "$refusal" == *"symlinked release payload parent for $dir/"* ]] || { echo "$dir: $refusal"; false; }
    l153_swap_symlink "$dir" "$copy"
  done
}

@test "l153 native Pi session does not execute a tampered payload verifier" {
  l153_require_binary || false
  build_attachment_fixture
  l153_prepare_payload
  chmod u+w "$RUNTIME/scripts/lib/release-stamp.sh"
  printf ': > %q\nrelease_stamp_check() { return 0; }\n' "$MARKER" > "$RUNTIME/scripts/lib/release-stamp.sh"
  chmod a-w "$RUNTIME/scripts/lib/release-stamp.sh"
  out="$(l153_pi_session)"
  [ ! -e "$MARKER" ] || { echo 'tampered payload helper executed'; false; }
  ctx="$(l153_session_ctx "$out")" || { echo "$out"; false; }
  [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$ctx"; false; }
  out="$(run_session_context "$HOOK" "$WT")"
  [ ! -e "$MARKER" ] || { echo 'Claude executed tampered payload helper'; false; }
  [[ "$(extract_ctx "$out")" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$out"; false; }
}

@test "l153 native Pi session does not trust inherited release library paths" {
  l153_require_binary || false
  build_attachment_fixture
  l153_prepare_payload
  tamper_release
  mkdir -p "$POISON_RUNTIME/lib"
  printf ': > %q\n' "$MARKER" > "$POISON_RUNTIME/lib/release-stamp.sh"
  out="$(l153_pi_session 'TRELLIS_LIBS_PRELOADED=1' "_RELEASE_STORE_LIB_DIR=$POISON_RUNTIME/lib")"
  [ ! -e "$MARKER" ] || { echo 'inherited release library path executed'; false; }
  ctx="$(l153_session_ctx "$out")" || { echo "$out"; false; }
  [[ "$ctx" == *"Trellis attachment is missing in this opted-in worktree"* ]] || { echo "$ctx"; false; }
}

@test "no verdict, no stamp and no verify library warns, and the session still starts" {
  build_attachment_fixture
  copy_hook_layout
  write_postjob_status pending
  for candidate in "$LAYOUT/core-rules/hooks/session-context.sh" "$LAYOUT/core-rules/codex/hooks/session-context.sh"; do
    run run_session_context "$candidate" "$WT"
    [ "$status" -eq 0 ] || { echo "$candidate: $output"; false; }
    ctx="$(extract_ctx "$output")"
    [[ "$ctx" == *"Trellis could not confirm the release integrity of this opted-in worktree"* ]] || { echo "$candidate: $ctx"; false; }
    [[ "$ctx" == *"Report this finding to the operator"* ]] || { echo "$ctx"; false; }
    [[ "$ctx" == *"Branch: t14-session"* ]] || { echo "$candidate dropped the session context: $ctx"; false; }
  done
  [ "$(stamp_count)" -eq 0 ]
}
