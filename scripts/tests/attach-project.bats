#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
FIXTURES="$REPO_ROOT/scripts/tests/fixtures/local-fleets"

sha256_file() {
  local output
  output="$(shasum -a 256 "$1")" || return 1
  case "$output" in \\*) output=${output:1} ;; esac
  printf '%s\n' "${output%% *}"
}

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

# The BSD and GNU stat forms must be captured SEPARATELY: GNU `stat -f` is
# --file-system, so it prints a whole filesystem block on stdout before failing
# on the format operand, and a chained substitution hands that block back as the
# "identity". Shape-check the BSD result rather than trusting exit status alone.
fixture_dev_ino() {
  local path="$1" candidate
  candidate="$(/usr/bin/stat -f '%d:%i' "$path" 2>/dev/null)" || candidate=""
  case "$candidate" in
    *[!0-9:]*|*:*:*|:*|*:|'') candidate="" ;;
    *:*) ;;
    *) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(/usr/bin/stat -c '%d:%i' "$path" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

bootstrap_release_admin() {
  local bootstrap="$SANDBOX/bootstrap release source ${TRELLIS_HOME##*/}" config user_home trellis_home
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME" "$bootstrap/scripts"
  user_home="$(canonical_dir "$HOME")"
  trellis_home="$(canonical_dir "$TRELLIS_HOME")"
  HOME="$user_home"
  TRELLIS_HOME="$trellis_home"
  export HOME TRELLIS_HOME
  chmod 700 "$HOME" "$TRELLIS_HOME"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis"
  chmod 755 "$HOME/.local/bin/trellis"
  cp "$REPO_ROOT/scripts/trellis" "$bootstrap/scripts/trellis"
  cp "$REPO_ROOT/scripts/release.sh" "$bootstrap/scripts/release.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$bootstrap/scripts/lib"
  chmod 755 "$bootstrap/scripts/trellis" "$bootstrap/scripts/release.sh"
  mkdir -p "$bootstrap/core-rules"
  printf '0.0.0\n' > "$bootstrap/core-rules/VERSION"
  (
    cd "$bootstrap" || exit 1
    git init -q
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git config commit.gpgsign false
    git config tag.gpgSign false
    git add core-rules scripts
    git commit -qm bootstrap
    git tag -a v0.0.0 -m bootstrap
  )
  bootstrap="$(canonical_dir "$bootstrap")"
  TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    attach-release-bootstrap "$REPO_ROOT/scripts/lib/release-store.sh" 0.0.0 "$bootstrap"
  config="$TRELLIS_HOME/config.json"
  jq -n --arg source "$bootstrap" --arg root "$SANDBOX" '{
    schema_version:1,
    source_root:$source,
    release_remote:"fixture://bootstrap",
    active_cli_release:"0.0.0",
    default_fleet:"personal",
    fleets:{personal:{discovery_roots:[$root]}}
  }' > "$config"
  chmod 600 "$config"
}

make_release() {
  local release="$1" repo="$SANDBOX/release-source"
  mkdir -p "$repo/core-rules/husky" "$repo/core-rules/githooks" "$repo/scripts"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  cat > "$repo/core-rules/husky/pre-push" <<'SH'
#!/usr/bin/env bash
refs="$(cat)"
printf 'fixture husky carrier: %s\n' "$refs" >&2
status="$(git config --local --get trellis.fixture-carrier-status 2>/dev/null || printf 0)"
exit "$status"
SH
  cat > "$repo/core-rules/githooks/pre-push" <<'SH'
#!/usr/bin/env bash
refs="$(cat)"
printf 'fixture githooks carrier: %s\n' "$refs" >&2
status="$(git config --local --get trellis.fixture-carrier-status 2>/dev/null || printf 0)"
exit "$status"
SH
  cat > "$repo/scripts/seed-inheritance-symlinks.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 755 "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push" "$repo/scripts/seed-inheritance-symlinks.sh"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": []
    },
    "codex": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}
      ],
      "render": []
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
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git add core-rules scripts
    git commit -qm release
    git tag -a "v$release" -m release
  )
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$HOME/.local/bin/trellis" release install "$release" --remote "$repo"
  [ "$status" -eq 0 ]
}

prepare_contextual_machine() {
  CONTEXT_OS_HOME="$SANDBOX/operator home ' \$ & back\\slash"
  CONTEXT_TRELLIS_HOME="$SANDBOX/machine home ' \$ & back\\slash"
  CONTEXT_PAYLOAD_LOG="$SANDBOX/payload-hooks.log"
  CONTEXT_SAFE_PATH="$PATH"
  mkdir -p "$CONTEXT_OS_HOME" "$CONTEXT_TRELLIS_HOME"
  export HOME="$(canonical_dir "$CONTEXT_OS_HOME")"
  export TRELLIS_HOME="$(canonical_dir "$CONTEXT_TRELLIS_HOME")"
  CONTEXT_OS_HOME="$HOME"
  CONTEXT_TRELLIS_HOME="$TRELLIS_HOME"
  CONTEXT_LAUNCHER="$HOME/.local/bin/trellis"
  bootstrap_release_admin
}

make_contextual_release() {
  local release="$1" repo="$SANDBOX/contextual-release-source" hook
  CONTEXT_RELEASE_SOURCE="$repo"
  mkdir -p \
    "$repo/core-rules/templates" \
    "$repo/core-rules/hooks" \
    "$repo/core-rules/codex/hooks" \
    "$repo/core-rules/husky" \
    "$repo/core-rules/githooks" \
    "$repo/scripts"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$repo/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$repo/core-rules/templates/codex-hooks.local.json"
  cp "$REPO_ROOT/scripts/trellis" "$repo/scripts/trellis"
  for hook in \
    core-rules/hooks/session-context.sh \
    core-rules/hooks/post-compact-context.sh \
    core-rules/hooks/inject-primer-index.sh \
    core-rules/hooks/skill-size-preflight.sh \
    core-rules/codex/hooks/session-context.sh \
    core-rules/codex/hooks/post-compact-context.sh \
    core-rules/codex/hooks/inject-primer-index.sh; do
    cat > "$repo/$hook" <<SH
#!/bin/bash
printf '%s:%s:%s:%s\n' "\${CLAUDE_PROJECT_DIR:+claude}\${CODEX_PROJECT_DIR:+codex}" "\${CLAUDE_PROJECT_DIR:-\${CODEX_PROJECT_DIR:-}}" "\${HOME:-}" "\${TRELLIS_HOME:-}" >> "$CONTEXT_PAYLOAD_LOG"
SH
    chmod 755 "$repo/$hook"
  done
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  cat > "$repo/core-rules/husky/pre-push" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cp "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push"
  cat > "$repo/scripts/seed-inheritance-symlinks.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 755 "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push" \
    "$repo/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/trellis"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [],
      "render": [
        {"template": "core-rules/templates/claude-settings.local.json", "destination": ".claude/settings.local.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    },
    "codex": {
      "links": [],
      "render": [
        {"template": "core-rules/templates/codex-hooks.local.json", "destination": ".codex/hooks.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    },
    "omp": {"links": [], "render": []}
  }
}
JSON
  printf '%s\n' "$release" > "$repo/core-rules/VERSION"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git add core-rules scripts
    git commit -qm release
    git tag -a "v$release" -m release
  )
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$HOME/.local/bin/trellis" release install "$release" --remote "$repo"
  [ "$status" -eq 0 ]
  jq -n \
    --arg source "$CONTEXT_RELEASE_SOURCE" --arg release "$release" --arg root "$SANDBOX" \
    '{
      schema_version: 1,
      source_root: $source,
      release_remote: "fixture://contextual-release",
      active_cli_release: $release,
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$root]}}
    }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

make_contextual_project() {
  CONTEXT_PROJECT="$SANDBOX/context project ' \$ & back\\slash"
  mkdir -p "$CONTEXT_PROJECT"
  git init -q "$CONTEXT_PROJECT"
  printf '{"schema_version":1,"project_id":"contextual-fixture"}\n' > "$CONTEXT_PROJECT/.trellis.json"
  git -C "$CONTEXT_PROJECT" add .trellis.json
  git -C "$CONTEXT_PROJECT" -c user.name=fixture -c user.email=fixture commit -qm initial
}

poison_context_runtime() {
  local hook
  CONTEXT_ATTACKER_MARKER="$SANDBOX/attacker-ran"
  rm "$CONTEXT_PROJECT/.trellis/runtime"
  mkdir -p \
    "$CONTEXT_PROJECT/.trellis/runtime/core-rules/hooks" \
    "$CONTEXT_PROJECT/.trellis/runtime/core-rules/codex/hooks"
  for hook in \
    core-rules/hooks/session-context.sh \
    core-rules/hooks/post-compact-context.sh \
    core-rules/hooks/inject-primer-index.sh \
    core-rules/hooks/skill-size-preflight.sh \
    core-rules/codex/hooks/session-context.sh \
    core-rules/codex/hooks/post-compact-context.sh \
    core-rules/codex/hooks/inject-primer-index.sh; do
    cat > "$CONTEXT_PROJECT/.trellis/runtime/$hook" <<SH
#!/bin/bash
: > "$CONTEXT_ATTACKER_MARKER"
exit 99
SH
    chmod 755 "$CONTEXT_PROJECT/.trellis/runtime/$hook"
  done
}

run_contextual_session() {
  local harness="$1" settings="$2" commands command claude_project="" codex_project=""
  case "$harness" in
    claude) claude_project="$CONTEXT_PROJECT" ;;
    codex) codex_project="$CONTEXT_PROJECT" ;;
    *) return 1 ;;
  esac
  commands="$(jq -r '.hooks.SessionStart[].hooks[].command' "$settings")" || return 1
  [ -n "$commands" ] || return 1
  while IFS= read -r command || [ -n "$command" ]; do
    run /usr/bin/env -i \
      PATH="$CONTEXT_POISON_BIN:$CONTEXT_SAFE_PATH" \
      CONTEXT_ATTACKER_MARKER="$CONTEXT_ATTACKER_MARKER" \
      CONTEXT_BASH_ENV="$CONTEXT_BASH_ENV" \
      CONTEXT_ENV="$CONTEXT_ENV" \
      CONTEXT_HOSTILE_HOME="$CONTEXT_HOSTILE_HOME" \
      CONTEXT_HOSTILE_TRELLIS_HOME="$CONTEXT_HOSTILE_TRELLIS_HOME" \
      CLAUDE_PROJECT_DIR="$claude_project" \
      CODEX_PROJECT_DIR="$codex_project" \
      /bin/bash --noprofile --norc -c '
        cd() { : > "$CONTEXT_ATTACKER_MARKER"; builtin cd "$@"; }
        export -f cd
        export BASH_ENV="$CONTEXT_BASH_ENV"
        export ENV="$CONTEXT_ENV"
        export HOME="$CONTEXT_HOSTILE_HOME"
        export TRELLIS_HOME="$CONTEXT_HOSTILE_TRELLIS_HOME"
        eval "exec $1" < "$2"
      ' _ "$command" "$CONTEXT_HOOK_INPUT"
    [ "$status" -eq 0 ] || return "$status"
  done <<< "$commands"
}

make_project() {
  PROJECT="$SANDBOX/project with spaces"
  mkdir -p "$PROJECT"
  git init -q "$PROJECT"
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
}
make_separate_gitdir_project() {
  PROJECT_COMMON="$SANDBOX/project common"
  rm -rf "$PROJECT"
  mkdir -p "$PROJECT"
  git init -q --separate-git-dir "$PROJECT_COMMON" "$PROJECT"
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  PROJECT_COMMON="$(canonical_dir "$PROJECT_COMMON")"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/attach-project.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  export HOME="$SANDBOX/fixture user home"
  export TRELLIS_HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  export HOME="$(canonical_dir "$HOME")"
  export TRELLIS_HOME="$(canonical_dir "$TRELLIS_HOME")"
  bootstrap_release_admin
  make_release 1.2.3
  make_project
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

run_attach() {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$@" "$PROJECT"
}

managed_hooks_path() {
  git -C "$PROJECT" config --local --get core.hooksPath
}

make_previous_pre_push() {
  local previous="$PROJECT/.previous-hooks"
  mkdir -p "$previous"
  cat > "$previous/pre-push" <<'SH'
#!/usr/bin/env bash
refs="$(cat)"
printf 'fixture previous pre-push: %s\n' "$refs" >&2
status="$(git config --local --get trellis.fixture-prior-status 2>/dev/null || printf 0)"
exit "$status"
SH
  chmod 755 "$previous/pre-push"
  git -C "$PROJECT" config --local core.hooksPath .previous-hooks
}

run_managed_pre_push() {
  local managed="$1" refs="$2" prior_status="$3" carrier_status="$4"
  git -C "$PROJECT" config --local trellis.fixture-prior-status "$prior_status" || return 1
  git -C "$PROJECT" config --local trellis.fixture-carrier-status "$carrier_status" || return 1
  run bash -c 'cd "$1" && "$2" origin fixture < "$3"' _ "$PROJECT" "$managed/pre-push" "$refs"
}

@test "attach expands all three harnesses into absent local parent leaves and keeps tracked Git clean" {
  run_attach
  [ "$status" -eq 0 ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ -L "$PROJECT/.claude/rules/trellis.md" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  [ -L "$PROJECT/.omp/AGENTS.md" ]
  [ -f "$PROJECT/.git/info/exclude" ]
  grep -F '# --- Trellis local attachment exclude block ---' "$PROJECT/.git/info/exclude"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  [ -f "$owner" ]
  jq -e '.status == "committed" and (.exclude.managed_by_attachment == true) and ([.artifacts[].kind] | index("parent"))' "$owner"
}

@test "contextual SessionStart renders pin attach-time launcher and home under hostile runtime state" {
  local owner claude_settings codex_settings owner_copy encoded expected owner_hash claude_hash codex_hash
  prepare_contextual_machine
  make_contextual_release 2.3.4
  make_contextual_project

  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 2.3.4 --harness claude --harness codex "$CONTEXT_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  claude_settings="$CONTEXT_PROJECT/.claude/settings.local.json"
  codex_settings="$CONTEXT_PROJECT/.codex/hooks.json"
  [ -f "$claude_settings" ]
  [ -f "$codex_settings" ]
  jq -e --arg home "$TRELLIS_HOME" --arg user_home "$CONTEXT_OS_HOME" --arg launcher "$CONTEXT_LAUNCHER" '
    [.hooks.SessionStart[].hooks[].command] as $commands
    | ($commands | length) == 4
    and all($commands[];
      startswith("/usr/bin/env -i HOME=")
      and contains("TRELLIS_HOME=") and contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
      and contains("/bin/bash --noprofile --norc")
      and contains("$CLAUDE_PROJECT_DIR")
      and (contains("__TRELLIS_") | not)
      and (contains(".trellis/runtime") | not)
      and (contains("$HOME") | not)
      and (contains("$TRELLIS_HOME") | not)
      and (contains("$PATH") | not))
  ' "$claude_settings" >/dev/null || { jq -c '[.hooks.SessionStart[].hooks[].command]' "$claude_settings"; false; }
  jq -e --arg home "$TRELLIS_HOME" --arg user_home "$CONTEXT_OS_HOME" --arg launcher "$CONTEXT_LAUNCHER" '
    [.hooks.SessionStart[].hooks[].command] as $commands
    | ($commands | length) == 3
    and all($commands[];
      startswith("/usr/bin/env -i HOME=")
      and contains("TRELLIS_HOME=") and contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
      and contains("/bin/bash --noprofile --norc")
      and contains("$CODEX_PROJECT_DIR")
      and (contains("__TRELLIS_") | not)
      and (contains(".trellis/runtime") | not)
      and (contains("$HOME") | not)
      and (contains("$TRELLIS_HOME") | not)
      and (contains("$PATH") | not))
  ' "$codex_settings" >/dev/null
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  [ -f "$owner" ]
  jq -e --arg home "$TRELLIS_HOME" --arg user_home "$CONTEXT_OS_HOME" --arg launcher "$CONTEXT_LAUNCHER" '
    ([.renders[].path] | sort) == [".claude/settings.local.json", ".codex/hooks.json"]
    and .render_context.schema_version == 1
    and .render_context.user_home == $user_home
    and .render_context.trellis_home == $home
    and .render_context.launcher == $launcher
    and (.render_context.user_home_shell | startswith("\u0027") and endswith("\u0027"))
    and (.render_context.trellis_home_shell | startswith("\u0027") and endswith("\u0027"))
    and (.render_context.launcher_shell | startswith("\u0027") and endswith("\u0027"))
  ' "$owner" >/dev/null

  for owner_copy in "$SANDBOX/owner-claude.json" "$SANDBOX/owner-codex.json"; do
    case "$owner_copy" in
      *owner-claude.json) encoded="$(jq -r '.renders[] | select(.path == ".claude/settings.local.json") | .after_base64' "$owner")" ;;
      *) encoded="$(jq -r '.renders[] | select(.path == ".codex/hooks.json") | .after_base64' "$owner")" ;;
    esac
    if ! printf '%s' "$encoded" | base64 -D > "$owner_copy" 2>/dev/null; then
      printf '%s' "$encoded" | base64 -d > "$owner_copy"
    fi
  done
  cmp -s "$claude_settings" "$SANDBOX/owner-claude.json"
  cmp -s "$codex_settings" "$SANDBOX/owner-codex.json"

  owner_hash="$(sha256_file "$owner")"
  claude_hash="$(sha256_file "$claude_settings")"
  codex_hash="$(sha256_file "$codex_settings")"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 2.3.4 --harness claude --harness codex "$CONTEXT_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$owner")" = "$owner_hash" ]
  [ "$(sha256_file "$claude_settings")" = "$claude_hash" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_hash" ]

  poison_context_runtime
  CONTEXT_HOSTILE_HOME="$SANDBOX/hostile-home"
  CONTEXT_HOSTILE_TRELLIS_HOME="$SANDBOX/hostile-trellis-home"
  CONTEXT_POISON_BIN="$SANDBOX/poison-bin"
  mkdir -p "$CONTEXT_HOSTILE_HOME" "$CONTEXT_HOSTILE_TRELLIS_HOME" "$CONTEXT_POISON_BIN"
  cat > "$CONTEXT_POISON_BIN/trellis" <<SH
#!/bin/bash
: > "$CONTEXT_ATTACKER_MARKER"
exit 99
SH
  chmod 755 "$CONTEXT_POISON_BIN/trellis"
  CONTEXT_BASH_ENV="$SANDBOX/hostile-bash-env"
  CONTEXT_ENV="$SANDBOX/hostile-env"
  CONTEXT_HOOK_INPUT="$SANDBOX/hook-input.json"
  printf ': > "%s"\n' "$CONTEXT_ATTACKER_MARKER" > "$CONTEXT_BASH_ENV"
  printf ': > "%s"\n' "$CONTEXT_ATTACKER_MARKER" > "$CONTEXT_ENV"
  printf '{"source":"startup"}\n' > "$CONTEXT_HOOK_INPUT"
  rm -f "$CONTEXT_PAYLOAD_LOG" "$CONTEXT_ATTACKER_MARKER"

  run_contextual_session claude "$claude_settings"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_contextual_session codex "$codex_settings"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  expected="$(
    printf 'claude:%s:%s:%s\n' "$CONTEXT_PROJECT" "$CONTEXT_OS_HOME" "$TRELLIS_HOME"
    printf 'claude:%s:%s:%s\n' "$CONTEXT_PROJECT" "$CONTEXT_OS_HOME" "$TRELLIS_HOME"
    printf 'claude:%s:%s:%s\n' "$CONTEXT_PROJECT" "$CONTEXT_OS_HOME" "$TRELLIS_HOME"
    printf 'claude:%s:%s:%s\n' "$CONTEXT_PROJECT" "$CONTEXT_OS_HOME" "$TRELLIS_HOME"
    printf 'codex:%s:%s:%s\n' "$CONTEXT_PROJECT" "$CONTEXT_OS_HOME" "$TRELLIS_HOME"
    printf 'codex:%s:%s:%s\n' "$CONTEXT_PROJECT" "$CONTEXT_OS_HOME" "$TRELLIS_HOME"
    printf 'codex:%s:%s:%s\n' "$CONTEXT_PROJECT" "$CONTEXT_OS_HOME" "$TRELLIS_HOME"
  )"
  [ "$(cat "$CONTEXT_PAYLOAD_LOG")" = "$expected" ]
  [ ! -e "$CONTEXT_ATTACKER_MARKER" ]
}

@test "contextual renderer rejects malformed placeholders and unsafe stable launchers" {
  local payload root template record context launcher target alias
  export HOME="$SANDBOX/render-account"
  export TRELLIS_HOME="$SANDBOX/render-machine"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  launcher="$HOME/.local/bin/trellis"
  printf '#!/bin/bash\nexit 0\n' > "$launcher"
  chmod 755 "$launcher"
  # shellcheck disable=SC1090
  . "$ATTACH"
  context="$(attach_contextual_render_context "$TRELLIS_HOME")"
  payload="$SANDBOX/render-payload"
  root="$SANDBOX/render-project"
  template="$payload/core-rules/templates/claude-settings.local.json"
  mkdir -p "$(dirname "$template")" "$root"
  record="$(jq -cn \
    --arg template "core-rules/templates/claude-settings.local.json" \
    --arg destination ".claude/settings.local.json" \
    '{template:$template,destination:$destination,mode:"0600"}')"

  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$template"
  run attach_json_render_plan "$root" "$payload" "$record" "$context"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .artifact.content_base64 != null
    and .render.after_sha256 != null
  ' >/dev/null

  jq 'del(.hooks.SessionStart[0].hooks[0].command)' "$template" > "$template.tmp"
  mv "$template.tmp" "$template"
  run attach_json_render_plan "$root" "$payload" "$record" "$context"
  [ "$status" -eq 4 ]

  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$template"
  jq '.hooks.SessionStart[0].hooks[0].command += " __TRELLIS_HOME__"' "$template" > "$template.tmp"
  mv "$template.tmp" "$template"
  run attach_json_render_plan "$root" "$payload" "$record" "$context"
  [ "$status" -eq 4 ]

  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$template"
  jq '.unexpected_placeholder = "__TRELLIS_LAUNCHER__"' "$template" > "$template.tmp"
  mv "$template.tmp" "$template"
  run attach_json_render_plan "$root" "$payload" "$record" "$context"
  [ "$status" -eq 4 ]

  rm "$launcher"
  run attach_contextual_render_context "$TRELLIS_HOME"
  [ "$status" -eq 5 ]

  mkdir "$launcher"
  run attach_contextual_render_context "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  rmdir "$launcher"

  ln -s "$SANDBOX/launcher-target" "$launcher"
  run attach_contextual_render_context "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  rm "$launcher"

  printf '#!/bin/bash\nexit 0\n' > "$launcher"
  chmod 644 "$launcher"
  run attach_contextual_render_context "$TRELLIS_HOME"
  [ "$status" -eq 4 ]
  chmod 755 "$launcher"

  mv "$HOME/.local" "$SANDBOX/real-local"
  ln -s "$SANDBOX/real-local" "$HOME/.local"
  run attach_contextual_render_context "$TRELLIS_HOME"
  [ "$status" -eq 4 ]

  ln -s "$TRELLIS_HOME" "$SANDBOX/render-machine-alias"
  alias="$SANDBOX/render-machine-alias"
  run attach_contextual_render_context "$alias"
  [ "$status" -eq 4 ]
}

@test "second attach is byte-idempotent and retains exact project exclude bytes outside the block" {
  printf '# project exclusion\n*.project-local\n' > "$PROJECT/.git/info/exclude"
  before="$(sha256_file "$PROJECT/.git/info/exclude")"
  run_attach
  [ "$status" -eq 0 ]
  first_exclude="$(sha256_file "$PROJECT/.git/info/exclude")"
  first_owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  first_owner_hash="$(sha256_file "$first_owner")"

  run_attach
  [ "$status" -eq 0 ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$first_exclude" ]
  [ "$(sha256_file "$first_owner")" = "$first_owner_hash" ]
  grep -Fx '# project exclusion' "$PROJECT/.git/info/exclude"
  grep -Fx '*.project-local' "$PROJECT/.git/info/exclude"
  [ "$before" != "$first_exclude" ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "collision preflight leaves every destination and exclude byte untouched" {
  printf 'project-owned\n' > "$PROJECT/.claude"
  printf 'keep\n' > "$PROJECT/.git/info/exclude"
  exclude_before="$(sha256_file "$PROJECT/.git/info/exclude")"

  run_attach

  [ "$status" -eq 3 ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$exclude_before" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ ! -d "$TRELLIS_HOME/state/attachment-journals" ] || [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print)" ]
}

@test "managed exclude preserves preexisting bytes and refuses duplicate malformed blocks" {
  printf 'alpha\n\n# final-without-newline' > "$PROJECT/.git/info/exclude"
  run_attach
  [ "$status" -eq 0 ]
  grep -F 'alpha' "$PROJECT/.git/info/exclude"
  grep -F '# final-without-newline' "$PROJECT/.git/info/exclude"

  OTHER="$SANDBOX/other"
  mkdir "$OTHER"
  git init -q "$OTHER"
  printf '{"schema_version":1,"project_id":"other"}\n' > "$OTHER/.trellis.json"
  printf '%s\n%s\n%s\n%s\n' '# --- Trellis local attachment exclude block ---' '/.trellis/' '# --- end Trellis local attachment exclude block ---' '# --- Trellis local attachment exclude block ---' > "$OTHER/.git/info/exclude"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$OTHER"
  [ "$status" -eq 3 ]
}

@test "recover locates matching interrupted journal and restores exact exclude pre-state" {
  printf 'project-owned\n' > "$PROJECT/.git/info/exclude"
  ATTACHMENT_FAULT_PHASE=prepared run_attach
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print)"
  [ -f "$journal" ]
  grep -F '# --- Trellis local attachment exclude block ---' "$PROJECT/.git/info/exclude"

  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.git/info/exclude")" = 'project-owned' ]
  [ ! -e "$journal" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
}

@test "relink repairs a missing owned anchor but refuses wrong immutable release" {
  run_attach
  [ "$status" -eq 0 ]
  rm "$PROJECT/.trellis/runtime"
  run "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ]
  [ -L "$PROJECT/.trellis/runtime" ]

  rm "$PROJECT/.trellis/runtime"
  ln -s "$SANDBOX/wrong-release" "$PROJECT/.trellis/runtime"
  run "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 4 ]
}

@test "relink rejects a root replacement at the pinned runtime anchor sink" {
  local expected real_python python_dir barrier continue_file output_file relink_pid relink_status original_project
  run_attach
  [ "$status" -eq 0 ]
  expected="$(readlink "$PROJECT/.trellis/runtime")"
  real_python="$(command -v python3)"
  [ -n "$real_python" ]
  python_dir="$SANDBOX/pinned-python"
  barrier="$SANDBOX/pinned-runtime-anchor-entered"
  continue_file="$SANDBOX/pinned-runtime-anchor-continue"
  output_file="$SANDBOX/pinned-runtime-anchor-output"
  original_project="$SANDBOX/original-project"
  mkdir -p "$python_dir"
  cat > "$python_dir/python3" <<'SH'
#!/bin/sh
: > "$T14_PINNED_RUNTIME_BARRIER"
while [ ! -e "$T14_PINNED_RUNTIME_CONTINUE" ]; do
  /bin/sleep 0.01
done
exec "$T14_PINNED_RUNTIME_PYTHON" "$@"
SH
  chmod 755 "$python_dir/python3"

  T14_PINNED_RUNTIME_BARRIER="$barrier" \
    T14_PINNED_RUNTIME_CONTINUE="$continue_file" \
    T14_PINNED_RUNTIME_PYTHON="$real_python" \
    PATH="$python_dir:$PATH" \
    "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT" > "$output_file" 2>&1 &
  relink_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$barrier" ] && break
    /bin/sleep 0.01
  done
  if [ ! -e "$barrier" ]; then
    : > "$continue_file"
    wait "$relink_pid" || true
    cat "$output_file"
    false
  fi

  mv "$PROJECT" "$original_project"
  mkdir -p "$PROJECT/.trellis"
  ln -s "$expected" "$PROJECT/.trellis/runtime"
  : > "$continue_file"
  if wait "$relink_pid"; then
    relink_status=0
  else
    relink_status=$?
  fi

  [ "$relink_status" -eq 3 ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$expected" ]
  [[ "$(cat "$output_file")" == *"runtime anchor changed or its pinned identity no longer matches"* ]] || { cat "$output_file"; false; }
}

@test "relink rejects a Git identity replacement after checkout lock acquisition" {
  local common checkout lock real_git git_dir barrier continue_file output_file relink_pid relink_status original_project replacement_common
  run_attach
  [ "$status" -eq 0 ]
  common="$(git -C "$PROJECT" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$PROJECT/$common" ;;
  esac
  common="$(canonical_dir "$common")"
  checkout="$(printf '%s' "$common" | shasum -a 256 | cut -d ' ' -f1)"
  lock="$TRELLIS_HOME/state/locks/attachment-checkout-$checkout.lock"
  real_git="$(command -v git)"
  [ -n "$real_git" ]
  git_dir="$SANDBOX/identity-git"
  barrier="$SANDBOX/fresh-identity-entered"
  replacement_common="$SANDBOX/replacement-common"
  continue_file="$SANDBOX/fresh-identity-continue"
  output_file="$SANDBOX/fresh-identity-output"
  original_project="$SANDBOX/original-project"
  mkdir -p "$git_dir"
  cat > "$git_dir/git" <<'SH'
#!/bin/sh
if [ -L "$T15_FRESH_IDENTITY_LOCK" ] && [ ! -e "$T15_FRESH_IDENTITY_BARRIER" ]; then
  : > "$T15_FRESH_IDENTITY_BARRIER"
  while [ ! -e "$T15_FRESH_IDENTITY_CONTINUE" ]; do
    /bin/sleep 0.01
  done
fi
exec "$T15_FRESH_IDENTITY_GIT" "$@"
SH
  chmod 755 "$git_dir/git"

  T15_FRESH_IDENTITY_LOCK="$lock" \
    T15_FRESH_IDENTITY_BARRIER="$barrier" \
    T15_FRESH_IDENTITY_CONTINUE="$continue_file" \
    T15_FRESH_IDENTITY_GIT="$real_git" \
    PATH="$git_dir:$PATH" \
    "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT" > "$output_file" 2>&1 &
  relink_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$barrier" ] && break
    /bin/sleep 0.01
  done
  if [ ! -e "$barrier" ]; then
    : > "$continue_file"
    wait "$relink_pid" || true
    cat "$output_file"
    false
  fi

  mv "$PROJECT" "$original_project"
  cp -R "$original_project" "$PROJECT"
  rm -rf "$PROJECT/.git"
  "$real_git" init -q --separate-git-dir "$replacement_common" "$PROJECT"
  cp "$original_project/.git/info/exclude" "$replacement_common/info/exclude"
  rm "$PROJECT/.trellis/runtime"
  : > "$continue_file"
  if wait "$relink_pid"; then
    relink_status=0
  else
    relink_status=$?
  fi

  [ "$relink_status" -eq 3 ] || { cat "$output_file"; false; }
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ ! -L "$PROJECT/.trellis/runtime" ]
  [[ "$(cat "$output_file")" == *"Git worktree identity changed while holding the checkout lock"* ]] || { cat "$output_file"; false; }
}

@test "recover rejects a journal byte change after checkout lock acquisition" {
  local journal journal_sha rewritten_sha common checkout lock real_git git_dir barrier continue_file output_file recover_pid recover_status rewritten
  ATTACHMENT_FAULT_PHASE=prepared run_attach
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print)"
  [ -f "$journal" ]
  journal_sha="$(sha256_file "$journal")"
  common="$(git -C "$PROJECT" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$PROJECT/$common" ;;
  esac
  common="$(canonical_dir "$common")"
  checkout="$(printf '%s' "$common" | shasum -a 256 | cut -d ' ' -f1)"
  lock="$TRELLIS_HOME/state/locks/attachment-checkout-$checkout.lock"
  real_git="$(command -v git)"
  git_dir="$SANDBOX/journal-race-git"
  barrier="$SANDBOX/journal-race-entered"
  continue_file="$SANDBOX/journal-race-continue"
  output_file="$SANDBOX/journal-race-output"
  rewritten="$SANDBOX/journal-race-rewritten"
  mkdir -p "$git_dir"
  cat > "$git_dir/git" <<'SH'
#!/bin/sh
if [ -L "$T15_JOURNAL_LOCK" ] && [ ! -e "$T15_JOURNAL_BARRIER" ]; then
  : > "$T15_JOURNAL_BARRIER"
  while [ ! -e "$T15_JOURNAL_CONTINUE" ]; do
    /bin/sleep 0.01
  done
fi
exec "$T15_JOURNAL_GIT" "$@"
SH
  chmod 755 "$git_dir/git"

  T15_JOURNAL_LOCK="$lock" \
    T15_JOURNAL_BARRIER="$barrier" \
    T15_JOURNAL_CONTINUE="$continue_file" \
    T15_JOURNAL_GIT="$real_git" \
    PATH="$git_dir:$PATH" \
    "$ATTACH" recover --home "$TRELLIS_HOME" --expected-journal-sha256 "$journal_sha" "$PROJECT" > "$output_file" 2>&1 &
  recover_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$barrier" ] && break
    /bin/sleep 0.01
  done
  if [ ! -e "$barrier" ]; then
    : > "$continue_file"
    wait "$recover_pid" || true
    cat "$output_file"
    false
  fi

  cp "$journal" "$rewritten"
  printf '\n' >> "$rewritten"
  chmod 600 "$rewritten"
  mv -f "$rewritten" "$journal"
  rewritten_sha="$(sha256_file "$journal")"
  : > "$continue_file"
  if wait "$recover_pid"; then
    recover_status=0
  else
    recover_status=$?
  fi

  [ "$recover_status" -eq 3 ] || { cat "$output_file"; false; }
  [ "$(sha256_file "$journal")" = "$rewritten_sha" ]
  [ -f "$journal" ]
  [[ "$(cat "$output_file")" == *"expected attachment journal changed while waiting for delegated recovery"* ]] || { cat "$output_file"; false; }
}

@test "relink rejects a symlinked ownership parent after checkout lock acquisition" {
  local owner owner_parent owner_sha256 owner_parent_dev_ino expected common checkout lock real_git git_dir barrier continue_file output_file relink_pid relink_status original_parent
  run_attach
  [ "$status" -eq 0 ]
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  owner_parent="$(dirname "$owner")"
  owner_sha256="$(sha256_file "$owner")"
  owner_parent_dev_ino="$(fixture_dev_ino "$owner_parent")"
  expected="$(readlink "$PROJECT/.trellis/runtime")"
  common="$(git -C "$PROJECT" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$PROJECT/$common" ;;
  esac
  common="$(canonical_dir "$common")"
  checkout="$(printf '%s' "$common" | shasum -a 256 | cut -d ' ' -f1)"
  lock="$TRELLIS_HOME/state/locks/attachment-checkout-$checkout.lock"
  real_git="$(command -v git)"
  git_dir="$SANDBOX/owner-parent-race-git"
  barrier="$SANDBOX/owner-parent-race-entered"
  continue_file="$SANDBOX/owner-parent-race-continue"
  output_file="$SANDBOX/owner-parent-race-output"
  original_parent="$SANDBOX/original-owner-parent"
  mkdir -p "$git_dir"
  cat > "$git_dir/git" <<'SH'
#!/bin/sh
if [ -L "$T15_OWNER_PARENT_LOCK" ] && [ ! -e "$T15_OWNER_PARENT_BARRIER" ]; then
  : > "$T15_OWNER_PARENT_BARRIER"
  while [ ! -e "$T15_OWNER_PARENT_CONTINUE" ]; do
    /bin/sleep 0.01
  done
fi
exec "$T15_OWNER_PARENT_GIT" "$@"
SH
  chmod 755 "$git_dir/git"

  T15_OWNER_PARENT_LOCK="$lock" \
    T15_OWNER_PARENT_BARRIER="$barrier" \
    T15_OWNER_PARENT_CONTINUE="$continue_file" \
    T15_OWNER_PARENT_GIT="$real_git" \
    PATH="$git_dir:$PATH" \
    "$ATTACH" relink --home "$TRELLIS_HOME" \
      --expected-owner-sha256 "$owner_sha256" \
      --expected-owner-parent-dev-ino "$owner_parent_dev_ino" \
      "$PROJECT" > "$output_file" 2>&1 &
  relink_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$barrier" ] && break
    /bin/sleep 0.01
  done
  if [ ! -e "$barrier" ]; then
    : > "$continue_file"
    wait "$relink_pid" || true
    cat "$output_file"
    false
  fi

  mv "$owner_parent" "$original_parent"
  ln -s "$original_parent" "$owner_parent"
  : > "$continue_file"
  if wait "$relink_pid"; then
    relink_status=0
  else
    relink_status=$?
  fi

  [ "$relink_status" -eq 3 ] || { cat "$output_file"; false; }
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$expected" ]
  [[ "$(cat "$output_file")" == *"expected attachment owner changed while waiting for delegated repair"* ]] || { cat "$output_file"; false; }
  rm "$owner_parent"
  mv "$original_parent" "$owner_parent"
}

@test "relink rejects same-path root and common directory swaps after checkout lock acquisition" {
  local common checkout lock real_git git_dir barrier continue_file output_file relink_pid relink_status original_project original_common expected
  make_separate_gitdir_project
  run_attach
  [ "$status" -eq 0 ]
  common="$PROJECT_COMMON"
  checkout="$(printf '%s' "$common" | shasum -a 256 | cut -d ' ' -f1)"
  lock="$TRELLIS_HOME/state/locks/attachment-checkout-$checkout.lock"
  real_git="$(command -v git)"
  git_dir="$SANDBOX/root-common-race-git"
  barrier="$SANDBOX/root-common-race-entered"
  continue_file="$SANDBOX/root-common-race-continue"
  output_file="$SANDBOX/root-common-race-output"
  original_project="$SANDBOX/original-project"
  original_common="$SANDBOX/original-common"
  expected="$(readlink "$PROJECT/.trellis/runtime")"
  mkdir -p "$git_dir"
  cat > "$git_dir/git" <<'SH'
#!/bin/sh
if [ -L "$T15_ROOT_COMMON_LOCK" ] && [ ! -e "$T15_ROOT_COMMON_BARRIER" ]; then
  : > "$T15_ROOT_COMMON_BARRIER"
  while [ ! -e "$T15_ROOT_COMMON_CONTINUE" ]; do
    /bin/sleep 0.01
  done
fi
exec "$T15_ROOT_COMMON_GIT" "$@"
SH
  chmod 755 "$git_dir/git"

  T15_ROOT_COMMON_LOCK="$lock" \
    T15_ROOT_COMMON_BARRIER="$barrier" \
    T15_ROOT_COMMON_CONTINUE="$continue_file" \
    T15_ROOT_COMMON_GIT="$real_git" \
    PATH="$git_dir:$PATH" \
    "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT" > "$output_file" 2>&1 &
  relink_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$barrier" ] && break
    /bin/sleep 0.01
  done
  if [ ! -e "$barrier" ]; then
    : > "$continue_file"
    wait "$relink_pid" || true
    cat "$output_file"
    false
  fi

  mv "$PROJECT" "$original_project"
  cp -R "$original_project" "$PROJECT"
  rm "$PROJECT/.trellis/runtime"
  ln -s "$expected" "$PROJECT/.trellis/runtime"
  mv "$common" "$original_common"
  cp -R "$original_common" "$common"
  : > "$continue_file"
  if wait "$relink_pid"; then
    relink_status=0
  else
    relink_status=$?
  fi

  [ "$relink_status" -eq 3 ] || { cat "$output_file"; false; }
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$expected" ]
  [[ "$(cat "$output_file")" == *"Git worktree filesystem identity changed while holding the checkout lock"* ]] || { cat "$output_file"; false; }
}

@test "harness selector attaches only requested native surfaces" {
  run_attach --harness omp
  [ "$status" -eq 0 ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ -L "$PROJECT/.omp/AGENTS.md" ]
  [ ! -e "$PROJECT/.claude" ]
  [ ! -e "$PROJECT/.agents" ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "fault rollback preserves a preexisting empty harness parent" {
  mkdir "$PROJECT/.claude"
  exclude_before="$(sha256_file "$PROJECT/.git/info/exclude")"
  ATTACHMENT_FAULT_PHASE=4 run_attach
  [ "$status" -eq 5 ]
  [ -d "$PROJECT/.claude" ]
  [ ! -e "$PROJECT/.claude/rules" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$exclude_before" ]
}

@test "owner-published recovery keeps excludes and registers the committed attachment" {
  ATTACHMENT_FAULT_PHASE=owner-published run_attach
  [ "$status" -eq 5 ]
  journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print)"
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  [ -f "$journal" ]
  [ -f "$owner" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  grep -F '# --- Trellis local attachment exclude block ---' "$PROJECT/.git/info/exclude"

  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ]
  [ ! -e "$journal" ]
  [ -f "$owner" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  attachment_id="$(jq -r '.attachment_id' "$owner")"
  jq -e --arg attachment_id "$attachment_id" 'any(.. | objects; .attachment_id? == $attachment_id)' "$TRELLIS_HOME/registry.json"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "relink refuses a modified owned leaf before recreating the anchor" {
  run_attach
  [ "$status" -eq 0 ]
  rm "$PROJECT/.trellis/runtime"
  rm "$PROJECT/.omp/AGENTS.md"
  ln -s wrong-target "$PROJECT/.omp/AGENTS.md"

  run "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 3 ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
}

@test "linked worktrees reuse one exact committed common exclude block" {
  run_attach
  [ "$status" -eq 0 ]
  WORKTREE="$SANDBOX/linked worktree"
  git -C "$PROJECT" worktree add -qb fixture-linked "$WORKTREE"

  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$WORKTREE"
  [ "$status" -eq 0 ]
  [ -L "$WORKTREE/.trellis/runtime" ]
  [ -L "$WORKTREE/.omp/AGENTS.md" ]
  [ "$(grep -c '^# --- Trellis local attachment exclude block ---$' "$PROJECT/.git/info/exclude")" -eq 1 ]
  [ "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print | wc -l | tr -d ' ')" -eq 2 ]
  jq -s -e 'map(.exclude.managed_by_attachment) | sort == [false, true]' $(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
  [ -z "$(git -C "$WORKTREE" status --porcelain)" ]
}

@test "idempotent attach rejects harness and environment override drift" {
  run_attach --harness omp
  [ "$status" -eq 0 ]

  run_attach --harness claude
  [ "$status" -eq 3 ]
  run env TRELLIS_RELEASE=1.2.4 "$ATTACH" attach --home "$TRELLIS_HOME" --harness omp "$PROJECT"
  [ "$status" -eq 3 ]
  run env TRELLIS_FLEET=work "$ATTACH" attach --home "$TRELLIS_HOME" --harness omp "$PROJECT"
  [ "$status" -eq 3 ]
  run_attach --harness omp
  [ "$status" -eq 0 ]
}

@test "exclude publish failure rolls back its prepared journal without project writes" {
  exclude_before="$(sha256_file "$PROJECT/.git/info/exclude")"
  # shellcheck disable=SC1090
  . "$ATTACH"
  attach_exclude_publish() {
    return "$TRELLIS_EX_CONFLICT"
  }

  run attach_cmd_attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$PROJECT"
  [ "$status" -eq 3 ]
  [ "$(sha256_file "$PROJECT/.git/info/exclude")" = "$exclude_before" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -name '*.json' -print)" ]
  [ -z "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)" ]
}

@test "managed pre-push freezes the Husky carrier and is byte-idempotent" {
  mkdir "$PROJECT/.husky"

  run_attach

  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  [ "$(cat "$managed/pre-push-source")" = "core-rules/husky/pre-push" ]
  [ -x "$managed/pre-push" ]
  [ -x "$managed/post-checkout" ]
  [ ! -e "$PROJECT/.husky/pre-push" ]
  before_pre_push="$(sha256_file "$managed/pre-push")"
  before_post_checkout="$(sha256_file "$managed/post-checkout")"
  before_source="$(sha256_file "$managed/pre-push-source")"

  run_attach

  [ "$status" -eq 0 ]
  [ "$(sha256_file "$managed/pre-push")" = "$before_pre_push" ]
  [ "$(sha256_file "$managed/post-checkout")" = "$before_post_checkout" ]
  [ "$(sha256_file "$managed/pre-push-source")" = "$before_source" ]
  [ "$(cat "$managed/pre-push-source")" = "core-rules/husky/pre-push" ]
}

@test "staged pre-push dispatcher fault leaves no private hook state and retries cleanly" {
  ATTACHMENT_FAULT_PHASE=hooks-staged run_attach

  [ "$status" -eq 5 ]
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ ! -e "$managed" ]
  [ ! -L "$managed" ]

  run_attach

  [ "$status" -eq 0 ]
  [ -x "$managed/pre-push" ]
  [ -f "$managed/pre-push-source" ]
}

@test "managed pre-push replays refs and preserves prior hook failure precedence" {
  make_previous_pre_push
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  refs="$SANDBOX/pre-push-refs"
  printf 'refs/heads/feature deadbeef refs/heads/main abcdef\n' > "$refs"

  run_managed_pre_push "$managed" "$refs" 23 31

  [ "$status" -eq 23 ]
  [[ "$output" == *"fixture previous pre-push: refs/heads/feature deadbeef refs/heads/main abcdef"* ]] || { echo "$output"; false; }
  [[ "$output" == *"fixture githooks carrier: refs/heads/feature deadbeef refs/heads/main abcdef"* ]] || { echo "$output"; false; }
}

@test "managed pre-push propagates carrier failure after a successful prior hook" {
  make_previous_pre_push
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  refs="$SANDBOX/pre-push-refs"
  printf 'refs/heads/feature deadbeef refs/heads/main abcdef\n' > "$refs"

  run_managed_pre_push "$managed" "$refs" 0 31

  [ "$status" -eq 31 ]
  [[ "$output" == *"fixture previous pre-push: refs/heads/feature deadbeef refs/heads/main abcdef"* ]] || { echo "$output"; false; }
  [[ "$output" == *"fixture githooks carrier: refs/heads/feature deadbeef refs/heads/main abcdef"* ]] || { echo "$output"; false; }
}

@test "managed pre-push rejects a repointed payload sidecar without runtime fallback" {
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  printf '%s\n' "$PROJECT/.trellis/runtime" > "$managed/release-payload"
  refs="$SANDBOX/pre-push-refs"
  printf 'refs/heads/feature deadbeef refs/heads/main abcdef\n' > "$refs"

  run_managed_pre_push "$managed" "$refs" 0 0

  [ "$status" -eq 1 ]
  [[ "$output" == *"trellis pre-push: managed immutable release carrier is unavailable"* ]] || { echo "$output"; false; }
  [[ "$output" != *"fixture githooks carrier:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"fixture husky carrier:"* ]] || { echo "$output"; false; }
}

@test "managed pre-push refuses a tampered writable immutable carrier before execution" {
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  carrier="$TRELLIS_HOME/releases/1.2.3/payload/core-rules/githooks/pre-push"
  chmod u+w "$carrier"
  printf '#!/usr/bin/env bash\nprintf "tampered pre-push carrier\\n" >&2\nexit 0\n' > "$carrier"
  chmod 700 "$carrier"
  refs="$SANDBOX/pre-push-refs"
  printf 'refs/heads/feature deadbeef refs/heads/main abcdef\n' > "$refs"

  run_managed_pre_push "$managed" "$refs" 0 0

  [ "$status" -eq 1 ]
  [[ "$output" == *"trellis pre-push: managed immutable release carrier is unavailable"* ]] || { echo "$output"; false; }
  [[ "$output" != *"tampered pre-push carrier"* ]] || { echo "$output"; false; }
}

@test "managed post-checkout refuses a tampered writable immutable reconciler before execution" {
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  reconciler="$TRELLIS_HOME/releases/1.2.3/payload/scripts/seed-inheritance-symlinks.sh"
  chmod u+w "$reconciler"
  printf '#!/usr/bin/env bash\nprintf "tampered post-checkout reconciler\\n" >&2\nexit 0\n' > "$reconciler"
  chmod 700 "$reconciler"

  run bash -c 'cd "$1" && "$2" "$3" "$4" 1' _ "$PROJECT" "$managed/post-checkout" old new

  [ "$status" -eq 1 ]
  [[ "$output" == *"trellis post-checkout: attachment reconciliation failed"* ]] || { echo "$output"; false; }
  [[ "$output" != *"tampered post-checkout reconciler"* ]] || { echo "$output"; false; }
}

@test "relink recreates a missing managed pre-push dispatcher atomically" {
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  rm -rf "$managed"

  run "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 0 ]
  [ -x "$managed/post-checkout" ]
  [ -x "$managed/pre-push" ]
  [ -f "$managed/previous-hooks-path" ]
  [ -f "$managed/release-payload" ]
  [ -f "$managed/pre-push-source" ]
  [ "$(managed_hooks_path)" = "$managed" ]
}
@test "relink recreates an isolated missing managed dispatcher without replacing exact state" {
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  post_checkout_hash="$(sha256_file "$managed/post-checkout")"
  source_hash="$(sha256_file "$managed/pre-push-source")"
  rm "$managed/pre-push"
  git -C "$PROJECT" config --local --unset-all core.hooksPath
  [ "$?" -eq 0 ]

  run "$ATTACH" relink --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 0 ]
  [ -x "$managed/pre-push" ]
  [ "$(sha256_file "$managed/post-checkout")" = "$post_checkout_hash" ]
  [ "$(sha256_file "$managed/pre-push-source")" = "$source_hash" ]
  [ "$(managed_hooks_path)" = "$managed" ]
}

@test "relink preserves a foreign dispatcher appearing after missing-state validation" {
  run_attach
  [ "$status" -eq 0 ]
  managed="$(managed_hooks_path)"
  rm "$managed/pre-push"
  # attach-project.sh declares its own `managed` locals, and dynamic scoping
  # would resolve the stub's read to whichever unset one is on the stack under
  # `set -u`.  The trigger path therefore lives in its own fixture variable.
  FOREIGN_DISPATCHER_HOOKS_PATH="$managed"

  # shellcheck disable=SC1090
  . "$ATTACH"
  release_store_directory_identity() {
    local path="$1" identity
    if [ "$path" = "$FOREIGN_DISPATCHER_HOOKS_PATH" ]; then
      printf 'foreign dispatcher\n' > "$FOREIGN_DISPATCHER_HOOKS_PATH/pre-push"
      chmod 700 "$FOREIGN_DISPATCHER_HOOKS_PATH/pre-push"
    fi
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    identity="$(fixture_dev_ino "$path")" || return 1
    printf '%s\n' "$identity"
  }

  run attach_cmd_relink --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 3 ]
  [ "$(cat "$managed/pre-push")" = "foreign dispatcher" ]
}


@test "recover installs managed pre-push state after owner publication interruption" {
  ATTACHMENT_FAULT_PHASE=owner-published run_attach

  [ "$status" -eq 5 ]
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -print)"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ ! -e "$managed/pre-push" ]

  run "$ATTACH" recover --home "$TRELLIS_HOME" "$PROJECT"

  [ "$status" -eq 0 ]
  [ -x "$managed/post-checkout" ]
  [ -x "$managed/pre-push" ]
  [ "$(cat "$managed/pre-push-source")" = "core-rules/githooks/pre-push" ]
}

# --- project-owned leaf deferral (F1/F2) and exclude-effectiveness (F3) ---

make_deferral_release() {
  local release="$1" repo="$SANDBOX/deferral-release-source"
  DEFERRAL_RELEASE="$release"
  mkdir -p "$repo/core-rules/commands/templates" "$repo/core-rules/husky" "$repo/core-rules/githooks" "$repo/scripts"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '# generated primer index\n' > "$repo/core-rules/commands/templates/primer-index-template.md"
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
        {"template": "core-rules/commands/templates/primer-index-template.md", "destination": ".claude/primers/INDEX.md", "merge": "replace", "mode": "0644", "required": true, "render_if_absent": true}
      ]
    },
    "codex": {
      "links": [
        {"project_target": "CLAUDE.md", "fallback_source": "core-rules/CLAUDE.md", "destination": "AGENTS.md"}
      ],
      "render": []
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
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git add core-rules scripts
    git commit -qm release
    git tag -a "v$release" -m release
  )
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$HOME/.local/bin/trellis" release install "$release" --remote "$repo"
  [ "$status" -eq 0 ]
}

make_deferral_project() {
  PROJECT="$SANDBOX/deferral project"
  mkdir -p "$PROJECT"
  git init -q "$PROJECT"
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$PROJECT/.trellis.json"
  printf '# project policy\n' > "$PROJECT/CLAUDE.md"
  git -C "$PROJECT" add .trellis.json CLAUDE.md
}

commit_deferral_project() {
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
}

run_deferral_attach() {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release "$DEFERRAL_RELEASE" "$@" "$PROJECT"
}

deferral_owner() {
  find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print | head -1
}

@test "attach defers a tracked project-authored primer INDEX and detach leaves it committed" {
  local owner
  make_deferral_release 3.4.5
  make_deferral_project
  mkdir -p "$PROJECT/.claude/primers"
  printf '# authored index\n- primer: one\n' > "$PROJECT/.claude/primers/INDEX.md"
  git -C "$PROJECT" add .claude/primers/INDEX.md
  commit_deferral_project

  run_deferral_attach --harness claude
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(cat "$PROJECT/.claude/primers/INDEX.md")" = '# authored index
- primer: one' ]
  owner="$(deferral_owner)"
  jq -e '
    ([.pre_existing[] | select(.path == ".claude/primers/INDEX.md")]
      == [{path:".claude/primers/INDEX.md",kind:"file",target:null,reason:"project-authored-render"}])
    and ([.artifacts[] | select(.path == ".claude/primers/INDEX.md")] | length) == 0
  ' "$owner" || { jq -c '{pre_existing,artifacts:[.artifacts[].path]}' "$owner"; false; }
  run grep -F '/.claude/primers/INDEX.md' "$PROJECT/.git/info/exclude"
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]

  run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PROJECT/.claude/primers/INDEX.md" ]
  [ "$(cat "$PROJECT/.claude/primers/INDEX.md")" = '# authored index
- primer: one' ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "attach renders an absent primer INDEX, excludes it, and detach removes it" {
  local owner
  make_deferral_release 3.4.5
  make_deferral_project
  commit_deferral_project

  run_deferral_attach --harness claude
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ -f "$PROJECT/.claude/primers/INDEX.md" ]
  [ "$(cat "$PROJECT/.claude/primers/INDEX.md")" = '# generated primer index' ]
  owner="$(deferral_owner)"
  jq -e '
    (.pre_existing | length) == 0
    and ([.artifacts[] | select(.path == ".claude/primers/INDEX.md") | .kind] == ["file"])
  ' "$owner" || { jq -c '{pre_existing,artifacts:[.artifacts[].path]}' "$owner"; false; }
  grep -F '/.claude/primers/INDEX.md' "$PROJECT/.git/info/exclude"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]

  run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$PROJECT/.claude/primers/INDEX.md" ]
}

@test "attach accepts a committed AGENTS.md symlink identical to the planned leaf and detach preserves it" {
  local owner
  make_deferral_release 3.4.5
  make_deferral_project
  ln -s CLAUDE.md "$PROJECT/AGENTS.md"
  git -C "$PROJECT" add AGENTS.md
  commit_deferral_project

  run_deferral_attach --harness codex
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ -L "$PROJECT/AGENTS.md" ]
  [ "$(readlink "$PROJECT/AGENTS.md")" = CLAUDE.md ]
  owner="$(deferral_owner)"
  jq -e '
    ([.pre_existing[] | select(.path == "AGENTS.md")]
      == [{path:"AGENTS.md",kind:"symlink",target:"CLAUDE.md",reason:"pre-existing-symlink"}])
    and ([.artifacts[] | select(.path == "AGENTS.md")] | length) == 0
  ' "$owner" || { jq -c '{pre_existing,artifacts:[.artifacts[].path]}' "$owner"; false; }
  run grep -F '/AGENTS.md' "$PROJECT/.git/info/exclude"
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]

  run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$PROJECT/AGENTS.md" ]
  [ "$(readlink "$PROJECT/AGENTS.md")" = CLAUDE.md ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "attach refuses a committed AGENTS.md symlink pointing elsewhere and names the path" {
  make_deferral_release 3.4.5
  make_deferral_project
  printf '# readme\n' > "$PROJECT/README.md"
  ln -s README.md "$PROJECT/AGENTS.md"
  git -C "$PROJECT" add README.md AGENTS.md
  commit_deferral_project

  run_deferral_attach --harness codex

  [ "$status" -eq 3 ]
  [[ "$output" == *"attachment destination is project-owned: AGENTS.md"* ]] || { echo "$output"; false; }
  [ "$(readlink "$PROJECT/AGENTS.md")" = README.md ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
}

# The shape that made the codex harness unattachable for any project owning its
# own AGENTS.md: a tracked regular file at a symlink destination, with content
# of the project's own.  Deferral makes attachment succeed while the file stays
# exactly as committed — the whole point is that the project's file wins.
@test "attach defers a project-authored AGENTS.md regular file and detach preserves it byte for byte" {
  local owner before after
  make_deferral_release 3.4.5
  make_deferral_project
  printf '# AGENTS\n\nProject-authored codex directives.\n' > "$PROJECT/AGENTS.md"
  git -C "$PROJECT" add AGENTS.md
  commit_deferral_project
  before="$(shasum -a 256 "$PROJECT/AGENTS.md" | awk '{print $1}')"

  run_deferral_attach --harness codex
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ -f "$PROJECT/AGENTS.md" ] && [ ! -L "$PROJECT/AGENTS.md" ]
  owner="$(deferral_owner)"
  jq -e '
    ([.pre_existing[] | select(.path == "AGENTS.md")]
      == [{path:"AGENTS.md",kind:"symlink",target:"CLAUDE.md",reason:"project-authored-file"}])
    and ([.artifacts[] | select(.path == "AGENTS.md")] | length) == 0
  ' "$owner" || { jq -c '{pre_existing,artifacts:[.artifacts[].path]}' "$owner"; false; }
  # A deferred leaf is never covered by the managed block, so the tracked file
  # stays tracked and the checkout stays clean.
  run grep -F '/AGENTS.md' "$PROJECT/.git/info/exclude"
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]

  run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PROJECT/AGENTS.md" ] && [ ! -L "$PROJECT/AGENTS.md" ]
  after="$(shasum -a 256 "$PROJECT/AGENTS.md" | awk '{print $1}')"
  [ "$after" = "$before" ] || { echo "AGENTS.md changed: $before -> $after"; false; }
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

# A zero-byte destination is a leftover from an interrupted write, not authored
# content: deferring to it would leave codex pointed at nothing forever, so the
# named refusal stands.
@test "attach refuses an empty AGENTS.md at a symlink destination and names the path" {
  make_deferral_release 3.4.5
  make_deferral_project
  : > "$PROJECT/AGENTS.md"
  git -C "$PROJECT" add AGENTS.md
  commit_deferral_project

  run_deferral_attach --harness codex

  [ "$status" -eq 3 ]
  [[ "$output" == *"attachment destination is project-owned: AGENTS.md"* ]] || { echo "$output"; false; }
  [ ! -s "$PROJECT/AGENTS.md" ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
}

# A byte-for-byte copy of the file the planned link resolves to is a dropping
# from some earlier materialization, not something the project wrote.  Freezing
# it would silently pin the project to today's content forever.
@test "attach refuses an AGENTS.md byte-identical to the project CLAUDE.md it would link to" {
  make_deferral_release 3.4.5
  make_deferral_project
  cp "$PROJECT/CLAUDE.md" "$PROJECT/AGENTS.md"
  git -C "$PROJECT" add AGENTS.md
  commit_deferral_project

  run_deferral_attach --harness codex

  [ "$status" -eq 3 ]
  [[ "$output" == *"attachment destination is project-owned: AGENTS.md"* ]] || { echo "$output"; false; }
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
}

# Same rule against the OTHER canonical source.  This project has a CLAUDE.md
# so the plan targets it, but a copy of the payload fallback is just as much a
# dropping — which source it copies says nothing about intent.
@test "attach refuses an AGENTS.md byte-identical to the payload fallback source" {
  make_deferral_release 3.4.5
  make_deferral_project
  printf '# fixture policy\n' > "$PROJECT/AGENTS.md"
  git -C "$PROJECT" add AGENTS.md
  commit_deferral_project

  run_deferral_attach --harness codex

  [ "$status" -eq 3 ]
  [[ "$output" == *"attachment destination is project-owned: AGENTS.md"* ]] || { echo "$output"; false; }
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
}

@test "attach refuses when a tracked gitignore negation defeats the managed exclude" {
  make_deferral_release 3.4.5
  make_deferral_project
  printf '.claude/**\n!.claude/primers/\n!.claude/primers/*\n' > "$PROJECT/.gitignore"
  git -C "$PROJECT" add .gitignore
  commit_deferral_project

  run_deferral_attach --harness claude

  [ "$status" -eq 3 ]
  [[ "$output" == *".gitignore:3:!.claude/primers/*"* ]] || { echo "$output"; false; }
  [[ "$output" == *".claude/primers/INDEX.md"* ]] || { echo "$output"; false; }
  [ ! -e "$PROJECT/.claude/primers/INDEX.md" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

# Same tracked negation as the refusal above, but the leaf now exists and is
# deferred.  Deferral runs first, so the F3 check never sees the path — and must
# not: the managed block is derived from the same post-deferral surface set, so
# no managed exclude is written for it and the negation has nothing to defeat.
# Refusing here would reject attachment over a file the project committed.
@test "attach defers a project-owned INDEX.md that a tracked negation re-includes" {
  local owner
  make_deferral_release 3.4.5
  make_deferral_project
  printf '.claude/**\n!.claude/primers/\n!.claude/primers/*\n' > "$PROJECT/.gitignore"
  mkdir -p "$PROJECT/.claude/primers"
  printf '# authored index\n' > "$PROJECT/.claude/primers/INDEX.md"
  git -C "$PROJECT" add .gitignore
  git -C "$PROJECT" add -f .claude/primers/INDEX.md
  commit_deferral_project
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]

  run_deferral_attach --harness claude
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(cat "$PROJECT/.claude/primers/INDEX.md")" = '# authored index' ]
  owner="$(deferral_owner)"
  jq -e '
    ([.pre_existing[].path] == [".claude/primers/INDEX.md"])
    and ([.artifacts[] | select(.path == ".claude/primers/INDEX.md")] | length) == 0
  ' "$owner" || { jq -c '{pre_existing,artifacts:[.artifacts[].path]}' "$owner"; false; }
  # The deferred path is absent from the managed block, which is exactly why the
  # negation cannot make the checkout dirty.
  run grep -F '/.claude/primers/INDEX.md' "$PROJECT/.git/info/exclude"
  [ "$status" -ne 0 ]
  grep -F '/.claude/rules/trellis.md' "$PROJECT/.git/info/exclude"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]

  run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$PROJECT/.claude/primers/INDEX.md")" = '# authored index' ]
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]
}

@test "an unreadable surface set fails the exclude-effectiveness check closed" {
  make_deferral_project
  commit_deferral_project

  # shellcheck disable=SC1090
  . "$ATTACH"
  jq() {
    case "$*" in
      *'".trellis/runtime"'*) return 1 ;;
    esac
    command jq "$@"
  }

  run attach_exclude_effective_preflight "$PROJECT" '{"artifacts":[{"destination":".claude/rules/trellis.md"}]}'

  [ "$status" -eq 4 ]
}
