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
  chmod -R a-w "$RELEASE_DIR"
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
  git -C "$MAIN" worktree add -qb t14-session "$WT"

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
              harnesses:["claude","codex","omp"],
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

@test "compact SessionStart remains silent for an opted-in linked worktree" {
  build_attachment_fixture

  out="$(printf '%s' '{"source":"compact"}' | TRELLIS_HOME="$TRELLIS_HOME" CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")"
  [ -z "$out" ]
  [ ! -e "$MARKER" ]
}
