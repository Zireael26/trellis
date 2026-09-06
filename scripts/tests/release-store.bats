#!/usr/bin/env bats
# Focused hostile probes for the T4 immutable release store.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SOURCE_RELEASE="$REPO_ROOT/scripts/release.sh"
RELEASE="$SOURCE_RELEASE"
RELEASE_STORE_LIB="$REPO_ROOT/scripts/lib/release-store.sh"
LOCAL_FLEET_FIXTURES="$REPO_ROOT/scripts/tests/fixtures/local-fleets"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"
# release.sh admits a TMPDIR candidate only when it is a private mode-0700
# `.cmd.*` child of THAT home's command scratch root, the shape the stable
# launcher builds. This suite drives the installed payload by pathname, so it
# inherits the Git fence's own TMPDIR; without a launcher-shaped directory per
# fixture home every release command exits 4 before it starts.
provision_command_scratch() {
  local home="$1" scratch="$1/state/scratch/.cmd.release-store"
  mkdir -p "$scratch"
  chmod 700 "$home" "$home/state" "$home/state/scratch" "$scratch"
  export TMPDIR="$scratch"
}

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  TRELLIS_HOME_FIX="$SANDBOX/trellis-home"
  mkdir -p "$TRELLIS_HOME_FIX"
  provision_command_scratch "$TRELLIS_HOME_FIX"
  # attach derives its trusted local SessionStart render context from the
  # operator launcher at $HOME/.local/bin/trellis, and the isolated gate hands
  # every suite an empty private HOME. Install the launcher the way the sibling
  # attachment suites do, or every render-bearing manifest fails to attach.
  OPERATOR_HOME="$SANDBOX/operator-home"
  mkdir -p "$OPERATOR_HOME/.local/bin"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$OPERATOR_HOME/.local/bin/trellis"
  chmod 755 "$OPERATOR_HOME/.local/bin/trellis"
  export HOME="$OPERATOR_HOME"
  RELEASE_TEST_STORE_BARRIER="$SANDBOX/release-store-barrier"
  RELEASE_TEST_ADOPTION_BARRIER="$SANDBOX/adoption-barrier"
  RELEASE_TEST_HOOK_BARRIER="$SANDBOX/hook-swap-barrier"
  bootstrap_repo="$(build_release_repo "0.0.0" annotated "0.0.0" bootstrap-fixture)"
  TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    release-store-bootstrap "$RELEASE_STORE_LIB" "0.0.0" "$bootstrap_repo" || {
      echo 'could not install test bootstrap release'
      false
    }
  RELEASE="$TRELLIS_HOME_FIX/releases/0.0.0/payload/scripts/release.sh"
  export TRELLIS_VERIFIED_PAYLOAD="$TRELLIS_HOME_FIX/releases/0.0.0/payload"
  export TRELLIS_VERIFIED_RELEASE_VERSION="0.0.0"
  export TRELLIS_VERIFIED_SSH_AUTH_SOCK=""
  RELEASE_PROCESS_PID_A=""
  RELEASE_PROCESS_PID_B=""
  RELEASE_PROCESS_STATUS=""
}

teardown() {
  local background_pid
  for background_pid in "${RELEASE_PROCESS_PID_A:-}" "${RELEASE_PROCESS_PID_B:-}"; do
    [ -n "$background_pid" ] || continue
    kill "$background_pid" 2>/dev/null || true
    wait "$background_pid" 2>/dev/null || true
  done
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

install_release_test_fixture() {
  local repo="$1" store_barrier="$2" adoption_barrier="$3" hook_barrier="$4"
  local fixture quoted_store quoted_adoption quoted_hook
  quoted_store="$(printf '%q' "$store_barrier")"
  quoted_adoption="$(printf '%q' "$adoption_barrier")"
  quoted_hook="$(printf '%q' "$hook_barrier")"
  fixture="$repo/scripts/lib/release-test-fixture.sh"

  {
    cat <<'EOF'
# This file is injected only into the signed bootstrap fixture; production
# releases never source it.
release_fixture_wait() {
  local root="$1" phase="$2" ticks=0
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  : > "$root/$phase.ready" || return 5
  while [ ! -f "$root/$phase.release" ]; do
    [ "$ticks" -lt 300 ] || return 5
    sleep 0.1
    ticks=$((ticks + 1))
  done
}

# The pid of the shell that is running THIS function. Bash 3.2 (the macOS system
# bash this suite runs under) has no BASHPID, and `$$` is fixed at the original
# shell's pid even inside a forked subshell -- so `${BASHPID:-$$}` names the
# parent adopt process, not the hook transaction subshell. `exec` in a command
# substitution replaces exactly one forked child, whose PPID is therefore the
# current shell.
release_fixture_self_pid() {
  exec sh -c 'echo $PPID'
}
EOF
    printf 'release_fixture_store_barrier=%s\n' "$quoted_store"
    printf 'release_fixture_adoption_barrier=%s\n' "$quoted_adoption"
    printf 'release_fixture_hook_barrier=%s\n' "$quoted_hook"
    cat <<'EOF'
release_fixture_hooks_root="$TRELLIS_HOME/state/git-hooks"

release_store_test_barrier() {
  local phase="${1:-}"
  case "$phase" in
    install-before-publish|adopt-before-publish) ;;
    *) return 5 ;;
  esac
  release_fixture_wait "$release_fixture_store_barrier" "$phase"
}

eval "$(declare -f plan_matches_old | /usr/bin/sed '1s/^plan_matches_old /release_fixture_original_plan_matches_old /')"
release_fixture_plan_matches_old_seen=false
plan_matches_old() {
  local rc
  release_fixture_original_plan_matches_old "$@"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "$release_fixture_plan_matches_old_seen" = false ]; then
    release_fixture_plan_matches_old_seen=true
    release_fixture_wait "$release_fixture_adoption_barrier" after-plan-validation || return "$?"
  fi
}

eval "$(declare -f release_store_rename_swap | /usr/bin/sed '1s/^release_store_rename_swap /release_fixture_original_rename_swap /')"
release_store_rename_swap() {
  local rc destination="${2:-}" ticks=0
  release_fixture_original_rename_swap "$@"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case "$destination" in
    "$release_fixture_hooks_root"/*)
      if [ -d "$release_fixture_hook_barrier" ] && [ ! -L "$release_fixture_hook_barrier" ] &&
        [ ! -e "$release_fixture_hook_barrier/.exchanged" ]; then
        : > "$release_fixture_hook_barrier/.exchanged" || return 5
        printf '%s\n' "$(release_fixture_self_pid)" > "$release_fixture_hook_barrier/hook-swap-after-exchange.pid" || return 5
        : > "$release_fixture_hook_barrier/hook-swap-after-exchange.ready" || return 5
        while [ "$ticks" -lt 300 ]; do
          sleep 0.1
          ticks=$((ticks + 1))
        done
        return 5
      fi
      ;;
  esac
}
EOF
  } > "$fixture" || return 1
  chmod 600 "$fixture" || return 1
  python3 - "$repo/scripts/release.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = "release_requires_verified_payload || {"
if source.count(needle) != 1:
    raise SystemExit("could not install release fixture")
path.write_text(source.replace(needle, '. "$SCRIPT_DIR/lib/release-test-fixture.sh"\n\n' + needle))
PY
}

build_release_repo() {
  local version="$1" tag_kind="${2:-annotated}" version_file repo fixture
  version_file="${3:-$version}"
  repo="$SANDBOX/repo-$version"
  mkdir -p "$repo/core-rules/githooks" "$repo/docs" "$repo/scripts"
  printf '%s\n' "$version_file" > "$repo/core-rules/VERSION"
  printf '# rules %s\n' "$version" > "$repo/core-rules/CLAUDE.md"
  printf '# docs\n' > "$repo/docs/readme.md"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [{"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}],
      "render": []
    },
    "codex": {
      "links": [{"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}],
      "render": []
    }
  }
}
JSON
  cat > "$repo/core-rules/githooks/pre-push" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$repo/scripts/seed-inheritance-symlinks.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 755 "$repo/core-rules/githooks/pre-push" "$repo/scripts/seed-inheritance-symlinks.sh"
  cp "$REPO_ROOT/scripts/release.sh" "$repo/scripts/release.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  fixture="${4:-}"
  case "$fixture" in
    bootstrap-fixture)
      install_release_test_fixture "$repo" "$RELEASE_TEST_STORE_BARRIER" \
        "$RELEASE_TEST_ADOPTION_BARRIER" "$RELEASE_TEST_HOOK_BARRIER" || return 1
      ;;
    '') ;;
    *) return 1 ;;
  esac
  ln -s core-rules/CLAUDE.md "$repo/AGENTS.md"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git config user.email "release-store@example.invalid"
    git config user.name "Release Store"
    git config core.autocrlf false
    git config commit.gpgsign false
    git config tag.gpgSign false
    git add -A
    git commit -q -m "release $version"
    case "$tag_kind" in
      annotated) git tag -a "v$version" -m "release $version" ;;
      lightweight) git tag "v$version" ;;
    esac
  )
  printf '%s\n' "$repo"
}

retag_release_repo() {
  local repo="$1" version="$2"
  (
    cd "$repo" || exit 1
    git add -A
    git commit -q --amend --no-edit
    git tag -d "v$version" >/dev/null
    git tag -a "v$version" -m "release $version"
  )
}

wait_for_release_barrier() {
  local ready_file="$1" tries=0
  while [ ! -f "$ready_file" ] && [ "$tries" -lt 200 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -f "$ready_file" ]
}

wait_for_release_process() {
  local process_id="$1"
  if wait "$process_id"; then
    RELEASE_PROCESS_STATUS=0
  else
    RELEASE_PROCESS_STATUS=$?
  fi
}

directory_inode() {
  case "$(uname -s)" in
    Darwin) stat -f '%i' "$1" ;;
    *) stat -c '%i' "$1" ;;
  esac
}

runtime_validate_release_record() {
  local record="$1"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_json_valid "$2"' \
    release-store-validator "$RELEASE_STORE_LIB" "$record"
}

install_release() {
  local version="$1" repo="$2"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "$version" --remote "$repo"
  [ "$status" -eq 0 ]
  RELEASE_DIR="$output"
}

rewrite_release_json() {
  local filter="$1" tmp
  chmod u+w "$RELEASE_DIR" "$RELEASE_DIR/release.json"
  tmp="$RELEASE_DIR/release.json.tmp"
  jq "$filter" "$RELEASE_DIR/release.json" > "$tmp"
  mv "$tmp" "$RELEASE_DIR/release.json"
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"
}
make_portable_project() {
  local root="$1" project_id="$2"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" config user.email release-adoption@example.invalid
  git -C "$root" config user.name 'Release Adoption'
  printf '{"schema_version":1,"project_id":"%s"}\n' "$project_id" > "$root/.trellis.json"
  printf 'fixture\n' > "$root/README.md"
  git -C "$root" add .trellis.json README.md
  git -C "$root" commit -q -m fixture
}

attach_portable_project() {
  local root="$1" fleet="$2" version="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet "$fleet" --release "$version" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

owner_for_root() {
  local root="$1" owner
  for owner in "$TRELLIS_HOME_FIX"/state/attachments/*/*.json; do
    [ -f "$owner" ] && [ ! -L "$owner" ] || continue
    [ "$(jq -r '.worktree_root' "$owner")" = "$root" ] || continue
    printf '%s\n' "$owner"
    return 0
  done
  return 1
}

registry_release_for_root() {
  local root="$1"
  jq -r --arg root "$root" '
    .projects | to_entries[] | .value.checkouts | to_entries[] as $checkout
    | $checkout.value.worktrees | to_entries[]
    | select(.value.root == $root) | $checkout.value.release
  ' "$TRELLIS_HOME_FIX/registry.json"
}

record_unavailable_root() {
  local fleet="$1" project_id="$2" root="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    . "$1"
    local_registry_record_unavailable_root "$2" "$3" "$4" "$5" "{}"
  ' release-store-unavailable "$REGISTRY_LIB" "$TRELLIS_HOME_FIX" "$fleet" "$project_id" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

hook_state_listing() {
  local managed="$1" file mode
  for file in post-checkout pre-push previous-hooks-path release-payload pre-push-source; do
    [ -f "$managed/$file" ] && [ ! -L "$managed/$file" ] || return 1
    case "$(uname -s)" in
      Darwin) mode="$(stat -f '%Lp' "$managed/$file")" ;;
      *) mode="$(stat -c '%a' "$managed/$file")" ;;
    esac
    printf '%s %s %s\n' "$file" "$mode" "$(shasum -a 256 "$managed/$file" | awk '{print $1}')"
  done
}

install_adoption_releases() {
  local repo
  ADOPTION_VERSION_A=1.6.0
  ADOPTION_VERSION_B=1.6.1
  repo="$(build_release_repo "$ADOPTION_VERSION_A")"
  install_release "$ADOPTION_VERSION_A" "$repo"
  ADOPTION_PAYLOAD_A="$RELEASE_DIR/payload"
  repo="$(build_release_repo "$ADOPTION_VERSION_B")"
  install_release "$ADOPTION_VERSION_B" "$repo"
  ADOPTION_PAYLOAD_B="$RELEASE_DIR/payload"
}
build_explicit_json_release_repo() {
  local version="$1" effort="$2" repo manifest tmp
  repo="$(build_release_repo "$version")" || return 1
  mkdir -p "$repo/core-rules/templates" || return 1
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$repo/core-rules/templates/claude-settings.local.json" || return 1
  jq --arg effort "$effort" '.effortLevel = $effort' "$repo/core-rules/templates/claude-settings.local.json" > "$repo/core-rules/templates/claude-settings.local.json.next" || return 1
  mv "$repo/core-rules/templates/claude-settings.local.json.next" "$repo/core-rules/templates/claude-settings.local.json" || return 1
  manifest="$repo/core-rules/inheritance-manifest.json"
  tmp="$manifest.tmp"
  jq '.harnesses.claude.render = [
    {
      "template": "core-rules/templates/claude-settings.local.json",
      "destination": ".claude/settings.local.json",
      "merge": "explicit-json",
      "mode": "0600",
      "required": true
    }
  ]' "$manifest" > "$tmp" || return 1
  mv "$tmp" "$manifest" || return 1
  retag_release_repo "$repo" "$version" || return 1
  printf '%s\n' "$repo"
}

assert_malformed_hook_adoption_preserves_current_release() {
  local kind="$1" repo project owner managed before_state before_owner before_registry before_inode
  repo="$(build_release_repo 1.8.0)"
  install_release 1.8.0 "$repo"
  project="$SANDBOX/malformed-target"
  make_portable_project "$project" malformed-target
  attach_portable_project "$project" personal 1.8.0
  owner="$(owner_for_root "$project")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  before_state="$(hook_state_listing "$managed")"
  before_inode="$(directory_inode "$managed")"
  before_owner="$(cat "$owner")"
  before_registry="$(cat "$TRELLIS_HOME_FIX/registry.json")"

  repo="$(build_release_repo 1.8.1)"
  case "$kind" in
    failure) rm "$repo/scripts/trellis-launcher.sh" ;;
    empty)
      cat > "$repo/scripts/lib/attachment.sh" <<'GENERATOR'
_attachment_hooks_post_checkout_dispatcher_body() { return 0; }
_attachment_hooks_pre_push_dispatcher_body() { return 0; }
GENERATOR
      ;;
    *) return 1 ;;
  esac
  retag_release_repo "$repo" 1.8.1
  install_release 1.8.1 "$repo"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.8.1 --project malformed-target
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'managed hook generation failed'* ]] || { echo "$output"; false; }
  [[ "$output" != *'adopted:'* ]]
  [ "$(hook_state_listing "$managed")" = "$before_state" ]
  [ "$(directory_inode "$managed")" = "$before_inode" ]
  [ "$(cat "$owner")" = "$before_owner" ]
  [ "$(cat "$TRELLIS_HOME_FIX/registry.json")" = "$before_registry" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$TRELLIS_HOME_FIX/releases/1.8.0/payload" ]
  [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]
  [ -z "$(find "$TRELLIS_HOME_FIX/state/git-hooks" -name '*.release-adopt.*' -print)" ]
}

@test "adoption preserves current hooks when target hook generation fails" {
  assert_malformed_hook_adoption_preserves_current_release failure
}

@test "adoption preserves current hooks when target hook generation succeeds empty" {
  assert_malformed_hook_adoption_preserves_current_release empty
}

@test "explicit-json adoption preserves unrelated destination keys" {
  local version_a=1.6.2 version_b=1.6.3 repo project destination owner mode
  local payload_a payload_b

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"
  payload_b="$RELEASE_DIR/payload"

  project="$SANDBOX/explicit-json-project"
  make_portable_project "$project" explicit-json-project
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  jq '.unrelated = "keep-me"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"
  owner="$(owner_for_root "$project")"

  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(jq -r '.release' "$owner")" = "$version_a" ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-project
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/explicit-json-project"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$(jq -r '.release' "$owner")" = "$version_b" ]
  [ "$(registry_release_for_root "$project")" = "$version_b" ]
  jq -e '.effortLevel == "medium" and .unrelated == "keep-me"' "$destination" >/dev/null
  case "$(uname -s)" in
    Darwin) mode="$(stat -f '%Lp' "$destination")" ;;
    *) mode="$(stat -c '%a' "$destination")" ;;
  esac
  [ "$mode" = 600 ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null
}
@test "explicit-json adoption re-renders missing and changed owned keys" {
  local version_a=1.6.4 version_b=1.6.5 repo project destination owner mode
  local payload_a payload_b

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"
  payload_b="$RELEASE_DIR/payload"

  project="$SANDBOX/explicit-json-rerender"
  make_portable_project "$project" explicit-json-rerender
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  jq 'del(.effortLevel) | .unrelated = "keep-me"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"
  owner="$(owner_for_root "$project")"

  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(jq -r '.release' "$owner")" = "$version_a" ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-rerender
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'re-rendered owned JSON key: .claude/settings.local.json ["effortLevel"] (missing)'* ]] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/explicit-json-rerender"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$(jq -r '.release' "$owner")" = "$version_b" ]
  [ "$(registry_release_for_root "$project")" = "$version_b" ]
  jq -e '.effortLevel == "medium" and .unrelated == "keep-me"' "$destination" >/dev/null
  case "$(uname -s)" in
    Darwin) mode="$(stat -f '%Lp' "$destination")" ;;
    *) mode="$(stat -c '%a' "$destination")" ;;
  esac
  [ "$mode" = 600 ]
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json" and any(.owned_keys[]; .path == ["effortLevel"] and .value == "medium"))' "$owner" >/dev/null
  jq -e 'any(.artifacts[]; .path == ".claude/settings.local.json" and (.sha256 | test("^[a-f0-9]{64}$")))' "$owner" >/dev/null

  project="$SANDBOX/explicit-json-changed"
  make_portable_project "$project" explicit-json-changed
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  jq '.effortLevel = "low" | .unrelated = "still-local"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"
  chmod 600 "$destination"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-changed

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'re-rendered owned JSON key: .claude/settings.local.json ["effortLevel"] (changed)'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/explicit-json-changed"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$(registry_release_for_root "$project")" = "$version_b" ]
  jq -e '.effortLevel == "medium" and .unrelated == "still-local"' "$destination" >/dev/null
}

@test "explicit-json adoption names an absent render target and changes nothing" {
  local version_a=1.6.6 version_b=1.6.7 repo project destination owner owner_before
  local payload_a

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"

  project="$SANDBOX/explicit-json-absent"
  make_portable_project "$project" explicit-json-absent
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  rm "$destination"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-absent

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"explicit-json render target is absent: .claude/settings.local.json"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"adopted:"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$version_a" ]
  [ ! -e "$destination" ]
}

@test "explicit-json adoption names invalid JSON and changes nothing" {
  local version_a=1.6.8 version_b=1.6.9 repo project destination owner owner_before
  local payload_a invalid_before

  repo="$(build_explicit_json_release_repo "$version_a" medium)"
  install_release "$version_a" "$repo"
  payload_a="$RELEASE_DIR/payload"
  repo="$(build_explicit_json_release_repo "$version_b" high)"
  install_release "$version_b" "$repo"

  project="$SANDBOX/explicit-json-invalid"
  make_portable_project "$project" explicit-json-invalid
  attach_portable_project "$project" personal "$version_a"
  destination="$project/.claude/settings.local.json"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  printf '{"effortLevel":\n' > "$destination"
  chmod 600 "$destination"
  invalid_before="$(cat "$destination")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$version_b" --project explicit-json-invalid

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"explicit-json render target is invalid JSON: .claude/settings.local.json"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"adopted:"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$version_a" ]
  [ "$(cat "$destination")" = "$invalid_before" ]
}


@test "annotated tag install uses release.json plus immutable payload and adoption points to payload" {
  repo="$(build_release_repo "1.2.3-rc.1")"
  install_release "1.2.3-rc.1" "$repo"

  [ -f "$RELEASE_DIR/release.json" ]
  [ -d "$RELEASE_DIR/payload/core-rules" ]
  [ ! -e "$RELEASE_DIR/core-rules" ]
  commit="$(git -C "$repo" rev-parse "v1.2.3-rc.1^{commit}")"
  [ "$(jq -r '.version' "$RELEASE_DIR/release.json")" = "1.2.3-rc.1" ]
  [ "$(jq -r '.tag' "$RELEASE_DIR/release.json")" = "v1.2.3-rc.1" ]
  [ "$(jq -r '.commit' "$RELEASE_DIR/release.json")" = "$commit" ]
  [ "$(jq -r '.tree[] | select(.path == "core-rules/VERSION") | .oid' "$RELEASE_DIR/release.json")" = "$(git -C "$repo" rev-parse "$commit:core-rules/VERSION")" ]

  perms="$(LC_ALL=C ls -ld "$RELEASE_DIR/release.json" | awk '{print $1}')"
  [ "$(printf '%s' "$perms" | awk '{print substr($0,3,1) substr($0,6,1) substr($0,9,1)}')" = "---" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.3-rc.1"
  [ "$status" -eq 0 ]

  project="$SANDBOX/project with spaces"
  mkdir -p "$project/.trellis"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.2.3-rc.1" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$(cd "$RELEASE_DIR/payload" && pwd -P)" ]
}

@test "release rejects source execution outside the verified installed payload" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$SOURCE_RELEASE" list
  [ "$status" -eq 2 ]
  [[ "$output" == *"direct source execution is unsupported"* ]] || { echo "$output"; false; }
}

@test "installed releases honor project selection and never switch implicitly" {
  install_adoption_releases
  project="$SANDBOX/project-selector"
  make_portable_project "$project" project-selector
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"adopt requires --project"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project project-selector
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}

@test "managed adoption ignores hostile inherited Git environment" {
  install_adoption_releases
  project="$SANDBOX/git-env-project"
  make_portable_project "$project" git-env-project
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  hostile_git_dir="$SANDBOX/hostile-git-dir"
  hostile_config="$SANDBOX/hostile.gitconfig"
  mkdir "$hostile_git_dir"
  printf '[core]\n\thooksPath = /nonexistent/hostile-hooks\n\tfsmonitor = /nonexistent/hostile-fsmonitor\n' > "$hostile_config"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    GIT_DIR="$hostile_git_dir" \
    GIT_WORK_TREE="$SANDBOX/hostile-worktree" \
    GIT_CONFIG_GLOBAL="$hostile_config" \
    GIT_CONFIG_NOSYSTEM=0 \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project git-env-project
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}

@test "installed releases honor fleet selection across every selected worktree" {
  install_adoption_releases
  first="$SANDBOX/fleet-one"
  second="$SANDBOX/fleet-two"
  make_portable_project "$first" fleet-one
  make_portable_project "$second" fleet-two
  attach_portable_project "$first" personal "$ADOPTION_VERSION_A"
  attach_portable_project "$second" personal "$ADOPTION_VERSION_A"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$first/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(readlink "$second/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$first")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$second")" = "$ADOPTION_VERSION_B" ]
}

@test "installed releases honor all selection across fleets" {
  install_adoption_releases
  personal="$SANDBOX/all-personal"
  work="$SANDBOX/all-work"
  make_portable_project "$personal" all-personal
  make_portable_project "$work" all-work
  attach_portable_project "$personal" personal "$ADOPTION_VERSION_A"
  attach_portable_project "$work" work "$ADOPTION_VERSION_A"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$personal/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(readlink "$work/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$personal")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$work")" = "$ADOPTION_VERSION_B" ]
}

@test "managed adoption re-resolves current manifest identity under checkout lock before mutation" {
  install_adoption_releases
  project="$SANDBOX/identity-drift"
  make_portable_project "$project" identity-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  adopt_log="$SANDBOX/identity-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project identity-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready"
  jq '.project_id = "other-project"' "$project/.trellis.json" > "$project/.trellis.json.next"
  mv "$project/.trellis.json.next" "$project/.trellis.json"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"current project manifest ID does not match"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}

@test "managed adoption rejects registry binding drift under checkout lock before mutation" {
  install_adoption_releases
  project="$SANDBOX/registry-drift"
  make_portable_project "$project" registry-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  registry="$TRELLIS_HOME_FIX/registry.json"
  project_key="personal/registry-drift"
  checkout="$(jq -r --arg project "$project_key" --arg root "$project" '
    .projects[$project].checkouts | to_entries[]
    | select([.value.worktrees[].root] | index($root))
    | .key
  ' "$registry")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  adopt_log="$SANDBOX/registry-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project registry-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready"
  jq --arg project "$project_key" --arg checkout "$checkout" '
    .projects[$project].checkouts[$checkout].harnesses = ["claude"]
  ' "$registry" > "$registry.next"
  mv "$registry.next" "$registry"
  chmod 600 "$registry"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"selected registry row changed before release adoption"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
  jq -e --arg project "$project_key" --arg checkout "$checkout" '
    .projects[$project].checkouts[$checkout].harnesses == ["claude"]
  ' "$registry" >/dev/null
}

@test "managed adoption rejects attachment owner project identity drift under checkout lock before mutation" {
  install_adoption_releases
  project="$SANDBOX/owner-drift"
  make_portable_project "$project" owner-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  adopt_log="$SANDBOX/owner-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project owner-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready"
  jq '.project_id = "other-project"' "$owner" > "$owner.next"
  chmod 600 "$owner.next"
  mv "$owner.next" "$owner"
  owner_drifted="$(cat "$owner")"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"attachment owner no longer exactly matches the selected registry row"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_drifted" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}

@test "managed adoption rejects a replacement .trellis namespace after lock-time verification" {
  install_adoption_releases
  project="$SANDBOX/namespace-drift"
  make_portable_project "$project" namespace-drift
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  barrier="$RELEASE_TEST_ADOPTION_BARRIER"
  original_trellis="$SANDBOX/original-trellis"
  adopt_log="$SANDBOX/namespace-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project namespace-drift > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/after-plan-validation.ready"
  mv "$project/.trellis" "$original_trellis"
  mkdir "$project/.trellis"
  ln -s "$ADOPTION_PAYLOAD_A" "$project/.trellis/runtime"
  : > "$barrier/after-plan-validation.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [[ "$(cat "$adopt_log")" == *"release adoption target drifted after plan validation"* ]] || { cat "$adopt_log"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}

@test "managed adoption rejects malformed, schema-invalid, untracked, and symlinked portable manifests before mutation" {
  install_adoption_releases
  project="$SANDBOX/manifest-boundary"
  make_portable_project "$project" manifest-boundary
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  printf '{not-json\n' > "$project/.trellis.json"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 4 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  printf '{"schema_version":1,"project_id":"manifest-boundary","unexpected":true}\n' > "$project/.trellis.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 4 ]
  [[ "$output" == *"project manifest failed schema-aware validation"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  printf '{"schema_version":1,"project_id":"manifest-boundary"}\n' > "$project/.trellis.json"
  git -C "$project" rm --cached -f -q .trellis.json
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 3 ]
  [[ "$output" == *"project manifest must be tracked"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]

  manifest="$SANDBOX/regular-manifest"
  printf '{"schema_version":1,"project_id":"manifest-boundary"}\n' > "$manifest"
  rm "$project/.trellis.json"
  ln -s "$manifest" "$project/.trellis.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project manifest-boundary
  [ "$status" -eq 4 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
}

@test "hook release adoption exchanges the managed directory and restores it on interruption" {
  install_adoption_releases
  project="$SANDBOX/hook-interruption"
  make_portable_project "$project" hook-interruption
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ -d "$managed" ] && [ ! -L "$managed" ]
  [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]
  managed_inode_before="$(directory_inode "$managed")"
  managed_state_before="$(hook_state_listing "$managed")"
  barrier="$RELEASE_TEST_HOOK_BARRIER"
  adopt_log="$SANDBOX/hook-adopt.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --project hook-interruption > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/hook-swap-after-exchange.ready"
  for _ in {1..50}; do
    [ -d "$managed" ] && [ ! -L "$managed" ]
    [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]
    [ "$(cat "$managed/release-payload")" = "$ADOPTION_PAYLOAD_B" ]
    sleep 0.01
  done
  hook_swap_pid="$(cat "$barrier/hook-swap-after-exchange.pid")"
  kill -TERM "$hook_swap_pid"

  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 4 ] || { cat "$adopt_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [ -d "$managed" ] && [ ! -L "$managed" ]
  [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]
  [ "$(directory_inode "$managed")" = "$managed_inode_before" ]
  [ "$(hook_state_listing "$managed")" = "$managed_state_before" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
}
@test "adoption reports recorded operator-owned hook authority without repairing it" {
  install_adoption_releases
  project="$SANDBOX/hook-operator-owned"
  make_portable_project "$project" hook-operator-owned
  git -C "$project" config --local core.hooksPath .husky/_

  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  jq -e --arg managed "$managed" '
    .status == "committed"
    and .git_hooks.enabled == true
    and .git_hooks.managed_hooks_path == $managed
    and .git_hooks.previous_hooks_path == ".husky/_"
  ' "$owner" >/dev/null
  [ "$(git -C "$project" config --local --get core.hooksPath)" = "$managed" ]

  git -C "$project" config --local core.hooksPath .husky/_
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project hook-operator-owned
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"hook authority: operator-owned; core.hooksPath was left unchanged"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/hook-operator-owned"* ]] || { echo "$output"; false; }
  [ "$(git -C "$project" config --local --get core.hooksPath)" = ".husky/_" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_B" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = ".husky/_" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
  [ "$(cat "$managed/release-payload")" = "$ADOPTION_PAYLOAD_B" ]
}


@test "partial bulk adoption updates available targets and reports unavailable selectors" {
  install_adoption_releases
  project="$SANDBOX/partial-available"
  make_portable_project "$project" partial-available
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  record_unavailable_root personal partial-unavailable "$SANDBOX/missing-checkout"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable adoption target remains explicit: personal/partial-unavailable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/partial-available"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$(owner_for_root "$project")")" = "$ADOPTION_VERSION_B" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}
@test "eligible failures outrank unavailable rows - managed anchor preflight dominates unavailable" {
  install_adoption_releases
  project="$SANDBOX/eligible-outrank"
  make_portable_project "$project" eligible-outrank
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  owner_before="$(cat "$owner")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  # Make the eligible project's managed runtime state fail ownership/runtime
  # preflight without making its registry row unavailable. The unavailable
  # sibling remains report-only, so the eligible target's class 3 failure must
  # determine the command status. Corrupting the runtime anchor itself would
  # also fail preflight but would break the "runtime remains on A" invariant.
  [ -n "$managed" ] && [ -f "$managed/release-payload" ]
  printf 'corrupted-payload\n' > "$managed/release-payload"
  chmod 600 "$managed/release-payload"
  record_unavailable_root personal unavailable-outrank "$SANDBOX/missing-unavailable-outrank"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/eligible-outrank"* ]] || { echo "$output"; false; }
  [[ "$output" == *"unavailable adoption target remains explicit: personal/unavailable-outrank"* ]] || { echo "$output"; false; }
  [ "$(grep -c "adopted:" <<<"$output")" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_A" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_A" ]
}

@test "bulk adoption commits a healthy target while an eligible sibling fails" {
  local failed healthy failed_owner failed_owner_before failed_managed healthy_owner
  install_adoption_releases

  # The failing project sorts first, proving a class-3 row does not suppress a
  # later eligible success. The final-state assertions also forbid batch-wide
  # rollback after the healthy row commits.
  failed="$SANDBOX/bulk-a-failed"
  make_portable_project "$failed" bulk-a-failed
  attach_portable_project "$failed" personal "$ADOPTION_VERSION_A"
  failed_owner="$(owner_for_root "$failed")"
  failed_owner_before="$(cat "$failed_owner")"
  failed_managed="$(jq -r '.git_hooks.managed_hooks_path' "$failed_owner")"
  [ -n "$failed_managed" ] && [ -f "$failed_managed/release-payload" ]
  printf 'corrupted-payload\n' > "$failed_managed/release-payload"
  chmod 600 "$failed_managed/release-payload"

  healthy="$SANDBOX/bulk-z-healthy"
  make_portable_project "$healthy" bulk-z-healthy
  attach_portable_project "$healthy" personal "$ADOPTION_VERSION_A"
  healthy_owner="$(owner_for_root "$healthy")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --all

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/bulk-a-failed"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/bulk-z-healthy"* ]] || { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/bulk-a-failed"*"adopted: personal/bulk-z-healthy"* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"adopted: personal/bulk-a-failed"* ]] || { echo "$output"; false; }

  [ "$(readlink "$healthy/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$healthy")" = "$ADOPTION_VERSION_B" ]
  [ "$(jq -r '.release' "$healthy_owner")" = "$ADOPTION_VERSION_B" ]

  [ "$(readlink "$failed/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
  [ "$(registry_release_for_root "$failed")" = "$ADOPTION_VERSION_A" ]
  [ "$(cat "$failed_owner")" = "$failed_owner_before" ]
}

@test "project-scoped unavailable rows stay report-only beside an eligible worktree" {
  local healthy failed managed owner owner_before
  install_adoption_releases

  healthy="$SANDBOX/project-mixed-healthy"
  make_portable_project "$healthy" project-mixed-healthy
  attach_portable_project "$healthy" personal "$ADOPTION_VERSION_A"
  record_unavailable_root personal project-mixed-healthy "$SANDBOX/missing-project-mixed-healthy"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project project-mixed-healthy

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"unavailable adoption target remains explicit: personal/project-mixed-healthy"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/project-mixed-healthy"* ]] || { echo "$output"; false; }
  [ "$(readlink "$healthy/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]

  failed="$SANDBOX/project-mixed-failed"
  make_portable_project "$failed" project-mixed-failed
  attach_portable_project "$failed" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$failed")"
  owner_before="$(cat "$owner")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  printf 'corrupted-payload\n' > "$managed/release-payload"
  chmod 600 "$managed/release-payload"
  record_unavailable_root personal project-mixed-failed "$SANDBOX/missing-project-mixed-failed"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project project-mixed-failed

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"unavailable adoption target remains explicit: personal/project-mixed-failed"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"attachment ownership/runtime preflight failed for personal/project-mixed-failed"* ]] ||
    { echo "$output"; false; }
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(readlink "$failed/.trellis/runtime")" = "$ADOPTION_PAYLOAD_A" ]
}


registry_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
  else
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  fi
}

# A registered sibling whose recorded root is present but is not a Git worktree.
# Its stored hashes still verify, so the row is an identity_error (class 4)
# rather than a merely unavailable root — the shape the whole-file identity
# validator used to abort the entire adoption on.
add_broken_registry_sibling() {
  local fleet="$1" project_id="$2" version="$3" sibling="$SANDBOX/broken sibling checkout"
  local registry="$TRELLIS_HOME_FIX/registry.json" checkout_id worktree_id
  mkdir -p "$sibling"
  checkout_id="$(registry_sha256_text "$sibling/.git")"
  worktree_id="$(registry_sha256_text "$sibling")"
  jq --arg key "$fleet/$project_id" --arg fleet "$fleet" --arg project_id "$project_id" \
    --arg root "$sibling" --arg common "$sibling/.git" --arg release "$version" \
    --arg checkout "$checkout_id" --arg worktree "$worktree_id" '
      .projects[$key] = {
        fleet: $fleet, project_id: $project_id, status: "active", metadata: {},
        checkouts: {
          ($checkout): {
            root: $root, git_common_dir: $common, harnesses: ["claude"],
            release: $release,
            worktrees: {($worktree): {root: $root}}
          }
        }
      }' "$registry" > "$registry.next"
  mv -f "$registry.next" "$registry"
  chmod 600 "$registry"
  printf '%s\n' "$sibling"
}

@test "a broken sibling row is refused while a healthy target adopts without rollback churn" {
  install_adoption_releases
  project="$SANDBOX/broken-sibling-healthy"
  make_portable_project "$project" broken-sibling-healthy
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  owner="$(owner_for_root "$project")"
  sibling="$(add_broken_registry_sibling personal broken-sibling "$ADOPTION_VERSION_A")"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal

  # Highest exit class: the broken row is a per-row state error, reported and
  # skipped, never adopted onto.
  [ "$status" -eq 4 ]
  [[ "$output" == *"adoption target failed local registry identity validation: personal/broken-sibling"* ]] || { echo "$output"; false; }
  [ "$(registry_release_for_root "$sibling")" = "$ADOPTION_VERSION_A" ]
  [ ! -e "$sibling/.trellis/runtime" ]

  # The healthy target committed and was never touched-then-restored. `adopted:`
  # is emitted only after update_group_registry succeeded; every rollback path
  # runs before that line and restores the anchor, the owner journal, and the
  # recorded release to version A. All three are on B.
  [[ "$output" == *"adopted: personal/broken-sibling-healthy"* ]] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(jq -r '.release' "$owner")" = "$ADOPTION_VERSION_B" ]
  [ "$(jq -r '.status' "$owner")" = "committed" ]
  [ "$(registry_release_for_root "$project")" = "$ADOPTION_VERSION_B" ]
}

# A registered checkout that currently holds no worktree row. Its own identity
# validates, so the listing emits it as a `kind: "checkout"` VISIBILITY row —
# inventory, not an adoption target.
add_empty_worktrees_checkout() {
  local fleet="$1" project_id="$2" version="$3" checkout="$SANDBOX/empty worktrees checkout"
  local registry="$TRELLIS_HOME_FIX/registry.json"
  make_portable_project "$checkout" "$project_id"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$2" "$3" "$4" "$5" "$6" "[\"claude\"]" "" "{}"' \
    _ "$REGISTRY_LIB" "$TRELLIS_HOME_FIX" "$fleet" "$project_id" "$checkout" "$version"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  jq --arg key "$fleet/$project_id" \
    '.projects[$key].checkouts |= with_entries(.value.worktrees = {})' \
    "$registry" > "$registry.next" || return 1
  mv -f "$registry.next" "$registry"
  chmod 600 "$registry"
  printf '%s\n' "$checkout"
}

@test "bulk adoption skips a checkout inventory row instead of failing a healthy registry" {
  install_adoption_releases
  project="$SANDBOX/bulk-checkout-healthy"
  make_portable_project "$project" bulk-checkout-healthy
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  empty="$(add_empty_worktrees_checkout personal bulk-empty-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]

  # A bulk selector sweeps the whole machine or the whole fleet. Handing the
  # inventory row to the explicit-target loop made `adopt --all` fail class 5 on
  # a registry with nothing wrong with it — one empty-worktrees checkout was
  # enough to block every adoption on the machine.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'skipping checkout inventory row with no registered worktree: personal/bulk-empty-checkout' <<<"$output"
  grep -qF 'adopted: personal/bulk-checkout-healthy' <<<"$output"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ ! -e "$empty/.trellis/runtime" ]

  # Explicitly naming the checkout-only project stays an honest refusal: there
  # is no worktree to adopt onto.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project bulk-empty-checkout
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'unavailable adoption target remains explicit: personal/bulk-empty-checkout' <<<"$output"
}

@test "a bulk selection of nothing but checkout inventory rows adopts nothing and exits 5" {
  install_adoption_releases
  empty="$(add_empty_worktrees_checkout personal only-empty-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]

  # Skipping the inventory row is right; reporting SUCCESS for a run that
  # adopted nothing is not. The skip branch sets no status and the empty-groups
  # fallback (`${rc:-...}`) could never fire because `rc` is always set, so this
  # exited 0 over a selection with no adoptable target in it.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'skipping checkout inventory row with no registered worktree: personal/only-empty-checkout' <<<"$output"
  grep -qF 'no adoptable registered worktree matched the requested adoption selector' <<<"$output"
  [ "$(grep -cF 'adopted:' <<<"$output")" -eq 0 ]
  [ ! -e "$empty/.trellis/runtime" ]

  # Same verdict through the fleet selector, which shares the skip branch.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --fleet personal
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'no adoptable registered worktree matched the requested adoption selector' <<<"$output"
}

@test "a bulk unavailable checkout inventory row is reported without failing a healthy target" {
  install_adoption_releases
  project="$SANDBOX/bulk-checkout-guarded"
  make_portable_project "$project" bulk-checkout-guarded
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  empty="$(add_empty_worktrees_checkout personal bulk-unavailable-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]
  # Present and correctly hashed, but not traversable: the row classifies
  # class-5 `unavailable`, exactly like the worktree case.
  chmod 600 "$empty"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  chmod 700 "$empty"

  # Bulk unavailable rows are reported but do not contribute class 5; the
  # healthy target still adopts and the run succeeds.
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'unavailable checkout inventory row swept by the adoption selector: personal/bulk-unavailable-checkout' <<<"$output"
  # Per-row continuation: the healthy target still adopts.
  grep -qF 'adopted: personal/bulk-checkout-guarded' <<<"$output"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
}

@test "a project-scoped adoption still reports a drifted row outside the selection" {
  install_adoption_releases
  project="$SANDBOX/scoped-adopt-healthy"
  make_portable_project "$project" scoped-adopt-healthy
  attach_portable_project "$project" personal "$ADOPTION_VERSION_A"
  sibling="$(add_broken_registry_sibling personal scoped-adopt-broken "$ADOPTION_VERSION_A")"

  # The adoption selector decides what is ADOPTED, never what counts toward the
  # exit class: a scoped adopt over a healthy project used to succeed with
  # exit 0 over a registry it had just listed as corrupt.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --project scoped-adopt-healthy
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'registry row outside the adoption selector failed local registry identity validation: personal/scoped-adopt-broken' <<<"$output"
  # Selection still limits PROCESSING: the healthy target adopted, the drifted
  # row was never touched.
  grep -qF 'adopted: personal/scoped-adopt-healthy' <<<"$output"
  [ "$(readlink "$project/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$sibling")" = "$ADOPTION_VERSION_A" ]
}

@test "an unreadable registered root stays a class-5 unavailable row without failing healthy bulk adoption" {
  install_adoption_releases
  healthy="$SANDBOX/class5-healthy"
  blocked="$SANDBOX/class5-blocked"
  make_portable_project "$healthy" class5-healthy
  make_portable_project "$blocked" class5-blocked
  attach_portable_project "$healthy" personal "$ADOPTION_VERSION_A"
  attach_portable_project "$blocked" personal "$ADOPTION_VERSION_A"
  # Present and correctly hashed, but not traversable: canonicalizing the root
  # fails with the environment class (5). That must classify the row unavailable
  # — the class-5 word in the availability vocabulary — and never collapse into
  # identity_error, which is the class-4 word for registry corruption.
  chmod 600 "$blocked"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "$ADOPTION_VERSION_B" --fleet personal
  chmod 700 "$blocked"

  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable adoption target remains explicit: personal/class5-blocked"* ]] || { echo "$output"; false; }
  [[ "$output" != *"identity validation: personal/class5-blocked"* ]] || { echo "$output"; false; }
  [[ "$output" == *"adopted: personal/class5-healthy"* ]] || { echo "$output"; false; }
  [ "$(readlink "$healthy/.trellis/runtime")" = "$ADOPTION_PAYLOAD_B" ]
  [ "$(registry_release_for_root "$healthy")" = "$ADOPTION_VERSION_B" ]
}

@test "version-derived paths reject malformed semver before touching the store" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "../1.2.3"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid semver version: ../1.2.3"* ]] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases/0.0.0" ]
  [ ! -e "$TRELLIS_HOME_FIX/1.2.3" ]
}

@test "install rejects a lightweight release tag" {
  repo="$(build_release_repo "1.2.4" lightweight)"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.2.4" --remote "$repo"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release ref is not an annotated tag: v1.2.4"* ]] || { echo "$output"; false; }
}

@test "install rejects tag and core-rules VERSION mismatch" {
  repo="$(build_release_repo "1.2.5" annotated "9.9.9")"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.2.5" --remote "$repo"
  [ "$status" -eq 4 ]
  [[ "$output" == *"core-rules/VERSION mismatch for v1.2.5: expected exact bytes for 1.2.5"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects extra root keys" {
  repo="$(build_release_repo "1.2.6")"
  install_release "1.2.6" "$repo"
  rewrite_release_json '. + {extra: true}'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.6"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects extra tree keys" {
  repo="$(build_release_repo "1.2.7")"
  install_release "1.2.7" "$repo"
  rewrite_release_json '.tree[0].extra = true'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.7"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects leading-zero semver and tag mismatch" {
  repo="$(build_release_repo "1.2.8")"
  install_release "1.2.8" "$repo"
  rewrite_release_json '.version = "01.2.8" | .tag = "v01.2.8"'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.8"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }

  chmod u+w "$SANDBOX" 2>/dev/null
  TRELLIS_HOME_FIX="$SANDBOX/trellis-home-tag"
  mkdir -p "$TRELLIS_HOME_FIX"
  provision_command_scratch "$TRELLIS_HOME_FIX"
  bootstrap_repo="$(build_release_repo "0.0.1" annotated "0.0.1" bootstrap-fixture)"
  TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    release-store-bootstrap "$RELEASE_STORE_LIB" "0.0.1" "$bootstrap_repo" || {
      echo 'could not install secondary test bootstrap release'
      false
    }
  RELEASE="$TRELLIS_HOME_FIX/releases/0.0.1/payload/scripts/release.sh"
  export TRELLIS_VERIFIED_PAYLOAD="$TRELLIS_HOME_FIX/releases/0.0.1/payload"
  export TRELLIS_VERIFIED_RELEASE_VERSION="0.0.1"
  repo="$(build_release_repo "1.2.9")"
  install_release "1.2.9" "$repo"
  rewrite_release_json '.tag = "v1.2.10"'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.2.9"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "release JSON validator rejects unsafe relative paths" {
  repo="$(build_release_repo "1.3.0")"
  install_release "1.3.0" "$repo"
  rewrite_release_json '.tree[0].path = "../evil"'

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing or invalid"* ]] || { echo "$output"; false; }
}

@test "verify rejects changed payload content" {
  repo="$(build_release_repo "1.3.1")"
  install_release "1.3.1" "$repo"
  chmod u+w "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  printf '# tampered\n' > "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  chmod a-w "$RELEASE_DIR/payload/core-rules/CLAUDE.md"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"changed release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "verify rejects added payload content" {
  repo="$(build_release_repo "1.3.2")"
  install_release "1.3.2" "$repo"
  chmod u+w "$RELEASE_DIR/payload" "$RELEASE_DIR/payload/core-rules"
  printf 'extra\n' > "$RELEASE_DIR/payload/core-rules/extra.md"
  chmod a-w "$RELEASE_DIR/payload/core-rules/extra.md" "$RELEASE_DIR/payload/core-rules" "$RELEASE_DIR/payload"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.2"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release payload has missing or added paths"* ]] || { echo "$output"; false; }
}

@test "verify rejects unexpected release top-level siblings" {
  repo="$(build_release_repo "1.3.3")"
  install_release "1.3.3" "$repo"
  chmod u+w "$RELEASE_DIR"
  printf 'x\n' > "$RELEASE_DIR/extra"
  chmod a-w "$RELEASE_DIR/extra" "$RELEASE_DIR"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.3"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unexpected release top-level entry: extra"* ]] || { echo "$output"; false; }
}

@test "verify rejects writable release records and payload files" {
  repo="$(build_release_repo "1.3.4")"
  install_release "1.3.4" "$repo"
  chmod u+w "$RELEASE_DIR/release.json"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.4"
  [ "$status" -eq 4 ]
  [[ "$output" == *"writable release record: release.json"* ]] || { echo "$output"; false; }

  chmod a-w "$RELEASE_DIR/release.json"
  chmod u+w "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.4"
  [ "$status" -eq 4 ]
  [[ "$output" == *"writable release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "verify rejects release directory symlink store escape" {
  repo="$(build_release_repo "1.3.5")"
  install_release "1.3.5" "$repo"
  outside="$SANDBOX/outside"
  mkdir -p "$outside"
  chmod u+w "$RELEASE_DIR"
  mv "$RELEASE_DIR" "$outside/1.3.5"
  ln -s "$outside/1.3.5" "$RELEASE_DIR"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.3.5"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release directory is a symlink"* ]] || { echo "$output"; false; }
}

@test "adoption rejects relative traversal symlinked parent and non-symlink anchors" {
  repo="$(build_release_repo "1.3.6")"
  install_release "1.3.6" "$repo"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "project/.trellis/runtime"
  [ "$status" -eq 2 ]
  [[ "$output" == *"runtime anchor must be an absolute path ending in /.trellis/runtime without traversal"* ]] || { echo "$output"; false; }

  project="$SANDBOX/project"
  mkdir -p "$project/.trellis"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "$project/../project/.trellis/runtime"
  [ "$status" -eq 2 ]
  [[ "$output" == *"runtime anchor must be an absolute path ending in /.trellis/runtime without traversal"* ]] || { echo "$output"; false; }

  real_project="$SANDBOX/real-project"
  mkdir -p "$real_project/.trellis"
  ln -s "$real_project" "$SANDBOX/link-project"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "$SANDBOX/link-project/.trellis/runtime"
  [ "$status" -eq 3 ]
  [[ "$output" == *"runtime anchor parent contains a symlink component"* ]] || { echo "$output"; false; }

  touch "$project/.trellis/runtime"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.3.6" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 3 ]
  [[ "$output" == *"runtime anchor exists but is not a symlink"* ]] || { echo "$output"; false; }
}

@test "list and locate return only contained verified releases" {
  repo_a="$(build_release_repo "1.4.0")"
  install_release "1.4.0" "$repo_a"
  release_a="$RELEASE_DIR"
  repo_b="$(build_release_repo "1.4.1")"
  install_release "1.4.1" "$repo_b"
  release_b="$RELEASE_DIR"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" list
  [ "$status" -eq 0 ]
  [ "$output" = $'0.0.0\n1.4.0\n1.4.1' ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "1.4.0"
  [ "$status" -eq 0 ]
  [ "$output" = "$release_a" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "1.4.1"
  [ "$status" -eq 0 ]
  [ "$output" = "$release_b" ]

  outside="$SANDBOX/outside-release"
  mkdir -p "$outside"
  chmod u+w "$release_a"
  mv "$release_a" "$outside/1.4.0"
  ln -s "$outside/1.4.0" "$release_a"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "1.4.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release directory is a symlink"* ]] || { echo "$output"; false; }
}

@test "install requires VERSION bytes to equal one canonical version line" {
  for version in "1.4.2" "1.4.3" "1.4.4" "1.4.5"; do
    repo="$(build_release_repo "$version")"
    case "$version" in
      "1.4.2") printf '1.4.2' > "$repo/core-rules/VERSION" ;;
      "1.4.3") printf '1.4.3\n\n' > "$repo/core-rules/VERSION" ;;
      "1.4.4") printf '1.4.4\r\n' > "$repo/core-rules/VERSION" ;;
      "1.4.5") printf '1.4.5\npoison\n' > "$repo/core-rules/VERSION" ;;
    esac
    retag_release_repo "$repo" "$version"

    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "$version" --remote "$repo"
    [ "$status" -eq 4 ]
    [[ "$output" == *"core-rules/VERSION mismatch for v$version"* ]] || { echo "$output"; false; }
    [ ! -e "$TRELLIS_HOME_FIX/releases/$version" ]
    [ ! -e "$TRELLIS_HOME_FIX/releases/$version.lock" ]
  done
}

@test "version normalization rejects double tag prefixes without creating a store" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" locate "vv1.4.3"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid semver version: vv1.4.3"* ]] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases/0.0.0" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/vv1.4.3" ]
}

@test "verify rejects missing payload files and executable mode drift" {
  missing_repo="$(build_release_repo "1.4.4")"
  install_release "1.4.4" "$missing_repo"
  chmod u+w "$RELEASE_DIR/payload" "$RELEASE_DIR/payload/docs"
  rm "$RELEASE_DIR/payload/docs/readme.md"
  chmod a-w "$RELEASE_DIR/payload/docs" "$RELEASE_DIR/payload"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.4"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release payload has missing or added paths"* ]] || { echo "$output"; false; }

  mode_repo="$(build_release_repo "1.4.5")"
  install_release "1.4.5" "$mode_repo"
  chmod u+x "$RELEASE_DIR/payload/core-rules/CLAUDE.md"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.5"
  [ "$status" -eq 4 ]
  [[ "$output" == *"wrong mode for core-rules/CLAUDE.md: expected 100644, found 100755"* ]] || { echo "$output"; false; }
}

@test "verify rejects unexpected empty directories and escaping payload symlinks" {
  directory_repo="$(build_release_repo "1.4.6")"
  install_release "1.4.6" "$directory_repo"
  chmod u+w "$RELEASE_DIR/payload"
  mkdir "$RELEASE_DIR/payload/untracked-empty"
  chmod a-w "$RELEASE_DIR/payload/untracked-empty" "$RELEASE_DIR/payload"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.6"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release payload has missing or added directories"* ]] || { echo "$output"; false; }

  link_repo="$(build_release_repo "1.4.7")"
  install_release "1.4.7" "$link_repo"
  chmod u+w "$RELEASE_DIR/payload"
  rm "$RELEASE_DIR/payload/AGENTS.md"
  ln -s "/etc/passwd" "$RELEASE_DIR/payload/AGENTS.md"
  chmod a-w "$RELEASE_DIR/payload"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.7"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unsafe release symlink target: AGENTS.md"* ]] || { echo "$output"; false; }
}

@test "unsafe archive symlinks fail before an immutable version is published" {
  repo="$(build_release_repo "1.4.8")"
  ln -s "/etc/passwd" "$repo/escape"
  retag_release_repo "$repo" "1.4.8"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.4.8" --remote "$repo"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unsafe release symlink target: escape"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.8" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.8.lock" ]
}

@test "existing versions remain immutable when their source tag is rewritten" {
  repo="$(build_release_repo "1.4.9")"
  install_release "1.4.9" "$repo"
  original_payload="$(cat "$RELEASE_DIR/payload/core-rules/CLAUDE.md")"

  printf '# poisoned source\n' > "$repo/core-rules/CLAUDE.md"
  retag_release_repo "$repo" "1.4.9"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.4.9" --remote "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"release already installed, refusing overwrite: 1.4.9"* ]] || { echo "$output"; false; }
  [ "$(cat "$RELEASE_DIR/payload/core-rules/CLAUDE.md")" = "$original_payload" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.9.lock" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.9"
  [ "$status" -eq 0 ]
}

@test "installed runtime remains isolated when the source is poisoned and moved" {
  repo="$(build_release_repo "1.4.10")"
  install_release "1.4.10" "$repo"
  release_dir="$RELEASE_DIR"
  project="$SANDBOX/project"
  mkdir -p "$project/.trellis"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.10" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  payload_hash="$(git hash-object "$release_dir/payload/core-rules/CLAUDE.md")"

  (
    cd "$repo" || exit 1
    git checkout -q -b poisoned-source
    printf '# poisoned source\n' > core-rules/CLAUDE.md
    git add core-rules/CLAUDE.md
    git commit -q -m "poison source checkout"
  )
  mv "$repo" "$SANDBOX/moved-source"

  [ "$(readlink "$project/.trellis/runtime")" = "$release_dir/payload" ]
  [ "$(git hash-object "$release_dir/payload/core-rules/CLAUDE.md")" = "$payload_hash" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.4.10"
  [ "$status" -eq 0 ]
}

@test "runtime anchor stays on A until explicit adoption switches it to B" {
  repo_a="$(build_release_repo "1.4.11")"
  install_release "1.4.11" "$repo_a"
  release_a="$RELEASE_DIR"
  repo_b="$(build_release_repo "1.4.12")"
  install_release "1.4.12" "$repo_b"
  release_b="$RELEASE_DIR"
  project="$SANDBOX/project"
  mkdir -p "$project/.trellis"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.11" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a/payload" ]
  [ -d "$release_b/payload" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a/payload" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.12" --runtime-anchor "$project/.trellis/runtime"
  [ "$status" -eq 0 ]
  [ "$(readlink "$project/.trellis/runtime")" = "$release_b/payload" ]
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

file_inode() {
  case "$(uname -s)" in
    Darwin) stat -f '%i' "$1" ;;
    *) stat -c '%i' "$1" ;;
  esac
}

# Every managed symlink under a checkout as `path -> target -> inode`, sorted.
# The inode column is what turns "the target string is still right" into "this
# link object was never rewritten".
managed_link_map() {
  local root="$1" link
  find "$root" -type l -not -path "$root/.git/*" | LC_ALL=C sort | while read -r link; do
    printf '%s -> %s -> %s\n' "${link#$root/}" "$(readlink "$link")" "$(file_inode "$link")"
  done
}

# The policy an attached harness surface actually resolves to, per harness leaf.
resolved_policy_markers() {
  local root="$1" leaf
  for leaf in .claude/rules/trellis.md .agents/rules/trellis.md; do
    [ -L "$root/$leaf" ] || return 1
    printf '%s\t%s\n' "$leaf" "$(sha256_file "$root/$leaf")"
  done
}

# GAP (plan section 6, "Immutable runtime isolation"): the existing poisoning
# case adopts a bare compatibility --runtime-anchor and only re-checks the
# payload blob. Nothing proved that a REGISTERED, ATTACHED checkout keeps its
# resolved policy markers when the source checkout is dirtied, moved to a new
# branch, advanced by a commit, AND relocated on disk.
@test "an attached checkout keeps its runtime and policy markers when the source is dirtied, rebranched, and moved" {
  local repo payload project anchor_before links_before markers_before tracked_before
  local record_before version_before exclude_before moved

  repo="$(build_release_repo "1.7.0")"
  install_release "1.7.0" "$repo"
  payload="$RELEASE_DIR/payload"
  project="$SANDBOX/source-poisoning"
  make_portable_project "$project" source-poisoning
  attach_portable_project "$project" personal "1.7.0"

  anchor_before="$(readlink "$project/.trellis/runtime")"
  [ "$anchor_before" = "$payload" ]
  links_before="$(managed_link_map "$project")"
  markers_before="$(resolved_policy_markers "$project")"
  [ -n "$markers_before" ]
  tracked_before="$(git -C "$project" ls-files -s)"
  record_before="$(sha256_file "$RELEASE_DIR/release.json")"
  version_before="$(cat "$payload/core-rules/VERSION")"
  exclude_before="$(sha256_file "$project/.git/info/exclude")"
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.0" ]

  # Poison the mutable source three ways at once: a new branch, a committed
  # policy rewrite, and an uncommitted dirty edit on top of it.
  (
    cd "$repo" || exit 1
    git checkout -q -b poisoned-source
    printf '# poisoned policy\n' > core-rules/CLAUDE.md
    printf '9.9.9\n' > core-rules/VERSION
    git add core-rules/CLAUDE.md core-rules/VERSION
    git commit -q -m "poison the source checkout"
  )
  printf '# uncommitted poison\n' >> "$repo/core-rules/CLAUDE.md"
  moved="$SANDBOX/moved poisoned source"
  mv "$repo" "$moved"
  [ ! -e "$repo" ]

  [ "$(readlink "$project/.trellis/runtime")" = "$anchor_before" ]
  [ "$(managed_link_map "$project")" = "$links_before" ]
  [ "$(resolved_policy_markers "$project")" = "$markers_before" ]
  [ "$(cat "$payload/core-rules/VERSION")" = "$version_before" ]
  [ "$(sha256_file "$RELEASE_DIR/release.json")" = "$record_before" ]
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
  [ "$(sha256_file "$project/.git/info/exclude")" = "$exclude_before" ]
  [ -z "$(git -C "$project" status --porcelain)" ]

  # The poison never reached the resolved policy the harness reads.
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.0" ]
  case "$(cat "$project/.claude/rules/trellis.md")" in
    *poison*)
      printf 'poisoned source bytes reached the attached runtime\n'
      false
      ;;
  esac

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.7.0"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# GAP (plan section 6, "Explicit release adoption"): the existing two-tag case
# uses a bare compatibility --runtime-anchor, and every managed-adoption case
# installs both releases BEFORE attaching. Nothing proved that installing B into
# a live store leaves an already attached checkout on A, nor that the later
# adoption moves exactly one anchor and rewrites no harness leaf.
@test "installing a second release leaves an attached checkout on A until adoption swaps exactly one anchor" {
  local repo_a repo_b payload_a payload_b project owner
  local anchor_before links_before markers_before tracked_before owner_before exclude_before
  local links_after leaf_links_before leaf_links_after managed hook_payload_before

  repo_a="$(build_release_repo "1.7.1")"
  install_release "1.7.1" "$repo_a"
  payload_a="$RELEASE_DIR/payload"
  project="$SANDBOX/explicit-adoption"
  make_portable_project "$project" explicit-adoption
  attach_portable_project "$project" personal "1.7.1"
  owner="$(owner_for_root "$project")"

  anchor_before="$(readlink "$project/.trellis/runtime")"
  [ "$anchor_before" = "$payload_a" ]
  links_before="$(managed_link_map "$project")"
  leaf_links_before="$(printf '%s\n' "$links_before" | grep -v '^\.trellis/runtime ->')"
  [ -n "$leaf_links_before" ]
  markers_before="$(resolved_policy_markers "$project")"
  tracked_before="$(git -C "$project" ls-files -s)"
  owner_before="$(cat "$owner")"
  exclude_before="$(sha256_file "$project/.git/info/exclude")"
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  hook_payload_before="$(cat "$managed/release-payload")"
  [ "$hook_payload_before" = "$payload_a" ]

  # Installing B is a store operation, not an adoption.
  repo_b="$(build_release_repo "1.7.2")"
  install_release "1.7.2" "$repo_b"
  payload_b="$RELEASE_DIR/payload"
  [ -d "$payload_b" ]
  [ "$payload_a" != "$payload_b" ]

  [ "$(readlink "$project/.trellis/runtime")" = "$anchor_before" ]
  [ "$(managed_link_map "$project")" = "$links_before" ]
  [ "$(resolved_policy_markers "$project")" = "$markers_before" ]
  [ "$(cat "$owner")" = "$owner_before" ]
  [ "$(registry_release_for_root "$project")" = "1.7.1" ]
  [ "$(cat "$managed/release-payload")" = "$hook_payload_before" ]
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.1" ]

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "1.7.2" --project explicit-adoption
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Exactly one anchor moved: the leaf links keep both their targets AND their
  # inodes, so no harness surface was rewritten to reach release B.
  links_after="$(managed_link_map "$project")"
  leaf_links_after="$(printf '%s\n' "$links_after" | grep -v '^\.trellis/runtime ->')"
  [ "$leaf_links_after" = "$leaf_links_before" ]
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_b" ]
  [ "$links_after" != "$links_before" ]

  # The single anchor move is what re-points every harness surface.
  [ "$(cat "$project/.claude/rules/trellis.md")" = "# rules 1.7.2" ]
  [ "$(resolved_policy_markers "$project")" != "$markers_before" ]
  [ "$(jq -r '.release' "$owner")" = "1.7.2" ]
  [ "$(registry_release_for_root "$project")" = "1.7.2" ]
  [ "$(cat "$managed/release-payload")" = "$payload_b" ]

  # Nothing tracked and no managed exclude line changed.
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
  [ "$(sha256_file "$project/.git/info/exclude")" = "$exclude_before" ]
  [ -z "$(git -C "$project" status --porcelain)" ]

  # Release A stays installed and verifiable, so adoption is reversible.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "1.7.1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" \
    adopt "1.7.1" --project explicit-adoption
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$project/.trellis/runtime")" = "$payload_a" ]
  [ "$(resolved_policy_markers "$project")" = "$markers_before" ]
  [ "$(git -C "$project" ls-files -s)" = "$tracked_before" ]
}

@test "unavailable install, verify, and compatibility-anchor paths return documented exit classes" {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "1.4.13" --remote "$SANDBOX/unavailable-remote"
  [ "$status" -eq 5 ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.13" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.4.13.lock" ]
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" verify "9.9.9"
  [ "$status" -eq 5 ]

  repo="$(build_release_repo "1.4.14")"
  install_release "1.4.14" "$repo"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "1.4.14" --runtime-anchor "$SANDBOX/missing/.trellis/runtime"
  [ "$status" -eq 5 ]
}

@test "runtime record validator accepts the T2 fixture and rejects semantic identity corruption" {
  valid_record="$LOCAL_FLEET_FIXTURES/valid-release-record.json"
  runtime_validate_release_record "$valid_record"
  [ "$status" -eq 0 ]

  tag_mismatch="$SANDBOX/tag-mismatch.json"
  jq '.tag = "v1.0.0-rc.25"' "$valid_record" > "$tag_mismatch"
  runtime_validate_release_record "$tag_mismatch"
  [ "$status" -eq 1 ]

  duplicate_path="$SANDBOX/duplicate-path.json"
  jq '.tree += [(.tree[0] | .mode = "100755" | .oid = "ffffffffffffffffffffffffffffffffffffffff")]' \
    "$valid_record" > "$duplicate_path"
  runtime_validate_release_record "$duplicate_path"
  [ "$status" -eq 1 ]

  invalid_record="$LOCAL_FLEET_FIXTURES/invalid-release-corrupt-record.json"
  runtime_validate_release_record "$invalid_record"
  [ "$status" -eq 1 ]
  invalid_without_schema="$SANDBOX/invalid-release-without-schema.json"
  jq 'del(."$schema")' "$invalid_record" > "$invalid_without_schema"
  runtime_validate_release_record "$invalid_without_schema"
  [ "$status" -eq 1 ]
}

@test "install preserves a foreign version created after preflight" {
  repo="$(build_release_repo "1.5.0")"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  install_log="$SANDBOX/install.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" install "1.5.0" --remote "$repo" > "$install_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/install-before-publish.ready"

  foreign_release="$TRELLIS_HOME_FIX/releases/1.5.0"
  mkdir "$foreign_release"
  foreign_inode="$(directory_inode "$foreign_release")"
  : > "$barrier/install-before-publish.release"

  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_A=""
  [ "$(directory_inode "$foreign_release")" = "$foreign_inode" ]
  [[ "$(cat "$install_log")" == *"release appeared during install, refusing overwrite: 1.5.0"* ]] || { cat "$install_log"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.5.0.lock" ]
}

@test "concurrent installs serialize with a class-3 loser" {
  repo="$(build_release_repo "1.5.4")"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  first_log="$SANDBOX/first-install.log"
  second_log="$SANDBOX/second-install.log"
  mkdir "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" install "1.5.4" --remote "$repo" > "$first_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/install-before-publish.ready"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" install "1.5.4" --remote "$repo" > "$second_log" 2>&1 &
  RELEASE_PROCESS_PID_B=$!
  wait_for_release_process "$RELEASE_PROCESS_PID_B"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_B=""
  [[ "$(cat "$second_log")" == *"release install is locked or already in progress: 1.5.4"* ]] || { cat "$second_log"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases/1.5.4.lock" ]

  : > "$barrier/install-before-publish.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 0 ] || { cat "$first_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [ -d "$TRELLIS_HOME_FIX/releases/1.5.4/payload" ]
  [ ! -e "$TRELLIS_HOME_FIX/releases/1.5.4.lock" ]
}

@test "runtime adoption preserves a foreign anchor created after preflight" {
  repo="$(build_release_repo "1.5.1")"
  install_release "1.5.1" "$repo"
  project="$SANDBOX/project"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  adopt_log="$SANDBOX/adopt.log"
  mkdir -p "$project/.trellis" "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "1.5.1" --runtime-anchor "$project/.trellis/runtime" > "$adopt_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/adopt-before-publish.ready"

  printf 'project-owned runtime\n' > "$project/.trellis/runtime"
  : > "$barrier/adopt-before-publish.release"

  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_A=""
  [ ! -L "$project/.trellis/runtime" ]
  [ "$(cat "$project/.trellis/runtime")" = "project-owned runtime" ]
  [[ "$(cat "$adopt_log")" == *"runtime anchor appeared during adoption, refusing overwrite"* ]] || { cat "$adopt_log"; false; }
  [ ! -e "$project/.trellis/.runtime.lock" ]
}

@test "concurrent runtime adoptions serialize with a class-3 loser" {
  repo_a="$(build_release_repo "1.5.2")"
  install_release "1.5.2" "$repo_a"
  release_a="$RELEASE_DIR"
  repo_b="$(build_release_repo "1.5.3")"
  install_release "1.5.3" "$repo_b"
  project="$SANDBOX/project"
  barrier="$RELEASE_TEST_STORE_BARRIER"
  first_log="$SANDBOX/first-adopt.log"
  second_log="$SANDBOX/second-adopt.log"
  mkdir -p "$project/.trellis" "$barrier"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "1.5.2" --runtime-anchor "$project/.trellis/runtime" > "$first_log" 2>&1 &
  RELEASE_PROCESS_PID_A=$!
  wait_for_release_barrier "$barrier/adopt-before-publish.ready"

  env TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    bash "$RELEASE" adopt "1.5.3" --runtime-anchor "$project/.trellis/runtime" > "$second_log" 2>&1 &
  RELEASE_PROCESS_PID_B=$!
  wait_for_release_process "$RELEASE_PROCESS_PID_B"
  [ "$RELEASE_PROCESS_STATUS" -eq 3 ]
  RELEASE_PROCESS_PID_B=""
  [[ "$(cat "$second_log")" == *"runtime anchor adoption is locked or already in progress"* ]] || { cat "$second_log"; false; }

  : > "$barrier/adopt-before-publish.release"
  wait_for_release_process "$RELEASE_PROCESS_PID_A"
  [ "$RELEASE_PROCESS_STATUS" -eq 0 ] || { cat "$first_log"; false; }
  RELEASE_PROCESS_PID_A=""
  [ "$(readlink "$project/.trellis/runtime")" = "$release_a/payload" ]
  [ ! -e "$project/.trellis/.runtime.lock" ]
}

@test "a detached or excluded checkout inventory row is reported, not silently skipped" {
  install_adoption_releases
  empty="$(add_empty_worktrees_checkout personal status-empty-checkout "$ADOPTION_VERSION_A")"
  [ -n "$empty" ]
  registry="$TRELLIS_HOME_FIX/registry.json"

  # DETACHED. The row is reachable and correctly hashed, so its availability is
  # `available` and only its STATUS disqualifies it. The worktree branch refuses
  # exactly this triple — availability, status, exclusion — but the checkout
  # branch tested `status = unavailable` alone, so a detached empty checkout
  # swept by `--all` was announced as a benign skip carrying no class at all.
  jq '.projects["personal/status-empty-checkout"].status = "detached"' \
    "$registry" > "$registry.next"
  mv -f "$registry.next" "$registry"
  chmod 600 "$registry"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'unavailable checkout inventory row swept by the adoption selector: personal/status-empty-checkout' <<<"$output"
  [ "$(grep -cF 'skipping checkout inventory row' <<<"$output")" -eq 0 ]

  # EXCLUDED, active again: the other half of the same predicate, and the other
  # word the old guard could not see.
  jq '.projects["personal/status-empty-checkout"] |= (.status = "active" | .metadata.legacy.blacklisted = true)' \
    "$registry" > "$registry.next"
  mv -f "$registry.next" "$registry"
  chmod 600 "$registry"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt "$ADOPTION_VERSION_B" --all
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'unavailable checkout inventory row swept by the adoption selector: personal/status-empty-checkout' <<<"$output"
  [ "$(grep -cF 'skipping checkout inventory row' <<<"$output")" -eq 0 ]
  [ ! -e "$empty/.trellis/runtime" ]
}

# The version-bound gate inside the copier itself, at its CALL SITE. The name
# predicate is pinned and exercised in isolation by release-snapshot-predicate
# .bats; nothing proved that `release_store_copy_snapshot_no_follow` actually
# consults it, so replacing the call with the bare `.tmp.*.exec.*` glob it used
# to carry would have left every suite green. The copier is the cheapest
# reachable caller: its gate runs before python3 is ever spawned, so no snapshot
# has to exist for the refusal path — and the accept path is proved by the fact
# that a same-version name reaches a LATER, different failure.
copy_snapshot() {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_copy_snapshot_no_follow "$2" "$3" "$4" "$5"' \
    _ "$RELEASE_STORE_LIB" "$TRELLIS_HOME_FIX/releases" "$1" "$2" \
    0000000000000000000000000000000000000000000000000000000000000000
}

@test "the snapshot copier refuses a foreign-version snapshot base at its own call site" {
  # THE GREEDY HOLE, reaching the copier. `.tmp.0.0.0.exec.9.exec.Ab3xY9` is
  # release 0.0.0.exec.9's snapshot; the copier resolves its SOURCE from
  # $version, so accepting this name under 0.0.0 makes the two halves of one
  # copy disagree about which release is being snapshotted.
  copy_snapshot 0.0.0 .tmp.0.0.0.exec.9.exec.Ab3xY9
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ "$(grep -cF 'release snapshot destination is unsafe: .tmp.0.0.0.exec.9.exec.Ab3xY9' <<<"$output")" -eq 1 ] ||
    { echo "$output"; false; }

  # An unrelated release's snapshot, refused by the same gate.
  copy_snapshot 0.0.0 .tmp.9.9.9.exec.Ab3xY9
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ "$(grep -cF 'release snapshot destination is unsafe: .tmp.9.9.9.exec.Ab3xY9' <<<"$output")" -eq 1 ] ||
    { echo "$output"; false; }

  # POSITIVE CONTROL, without which both refusals above would be satisfied by a
  # gate that rejects everything: a well-formed same-version name is past the
  # name gate and fails later, on the snapshot directory that does not exist —
  # a different fault, never this gate's class-2 refusal.
  copy_snapshot 0.0.0 .tmp.0.0.0.exec.Ab3xY9
  [ "$status" -ne 2 ] || { echo "$output"; false; }
  [ "$(grep -cF 'release snapshot destination is unsafe' <<<"$output")" -eq 0 ] ||
    { echo "$output"; false; }
}

@test "snapshot executor cleans its directory when post-creation owner capture fails" {
  local fake_bin="$SANDBOX/failing-ps-bin" leftover real_path real_python
  real_path="$PATH"
  real_python="$(command -v python3)"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ps" <<'EOF'
#!/bin/sh
# The executor has already created its private snapshot when it asks for the
# owner birth record. Failing this probe exercises that post-creation error
# handoff, rather than the ordinary successful payload-exit cleanup.
exit 77
EOF
  chmod 755 "$fake_bin/ps"
  # Darwin reads the birth token through libproc in a private python3 program
  # rather than through ps, so the ps stub alone would leave the probe healthy
  # and the case vacuous. Fail exactly that program -- identified by the
  # libproc flavour constant only it carries -- and pass every other python3
  # call in the snapshot path through to the real interpreter.
  {
    printf '#!/bin/sh\n'
    printf 'for arg in "$@"; do\n'
    printf '  case "$arg" in *PROC_PIDTBSDINFO*) exit 77 ;; esac\n'
    printf 'done\n'
    printf 'exec %q "$@"\n' "$real_python"
  } > "$fake_bin/python3"
  chmod 755 "$fake_bin/python3"

  PATH="$fake_bin:$real_path" run env \
    TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    PATH="$fake_bin:$real_path" \
    bash -c '. "$1"; release_store_snapshot_verified_release 0.0.0' \
    release-snapshot-owner-failure "$RELEASE_STORE_LIB"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not determine snapshot owner process birth"* ]] ||
    { echo "$output"; false; }
  [ -d "$TRELLIS_HOME_FIX/releases" ]
  leftover="$(find "$TRELLIS_HOME_FIX/releases" -maxdepth 1 \
    \( -name '.tmp.*.exec.*' -o -name '.tmp.*.exec.*.owner.json' \) \
    -print 2>&1)"
  [ -z "$leftover" ] || { echo "post-creation snapshot leaked: $leftover"; false; }
}
