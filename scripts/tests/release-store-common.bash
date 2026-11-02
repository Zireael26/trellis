# Bats context: unchanged release-store helpers, shared by the split parts.
# shellcheck shell=bash disable=SC2034,SC2154
# Focused hostile probes for the T4 immutable release store.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SOURCE_RELEASE="$REPO_ROOT/scripts/release.sh"
RELEASE="$SOURCE_RELEASE"
RELEASE_STORE_LIB="$REPO_ROOT/scripts/lib/release-store.sh"
LOCAL_FLEET_FIXTURES="$REPO_ROOT/scripts/tests/fixtures/local-fleets"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"
load helpers/payload-fixture
load helpers/group-plan
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

release_store_machine_paths() {
  TRELLIS_HOME_FIX="$SANDBOX/trellis-home"
  OPERATOR_HOME="$SANDBOX/operator-home"
  export HOME="$OPERATOR_HOME"
  provision_command_scratch "$TRELLIS_HOME_FIX"
  RELEASE_TEST_STORE_BARRIER="$SANDBOX/release-store-barrier"
  RELEASE_TEST_ADOPTION_BARRIER="$SANDBOX/adoption-barrier"
  RELEASE_TEST_HOOK_BARRIER="$SANDBOX/hook-swap-barrier"
  RELEASE="$TRELLIS_HOME_FIX/releases/0.0.0/payload/scripts/release.sh"
  export TRELLIS_VERIFIED_PAYLOAD="$TRELLIS_HOME_FIX/releases/0.0.0/payload"
  export TRELLIS_VERIFIED_RELEASE_VERSION="0.0.0"
  export TRELLIS_VERIFIED_SSH_AUTH_SOCK=""
}

initialize_release_store_machine() {
  TRELLIS_HOME_FIX="$SANDBOX/trellis-home"
  mkdir -p "$TRELLIS_HOME_FIX" || return 1
  provision_command_scratch "$TRELLIS_HOME_FIX" || return 1
  # attach derives its trusted local SessionStart render context from the
  # operator launcher at $HOME/.local/bin/trellis, and the isolated gate hands
  # every suite an empty private HOME. Install the launcher the way the sibling
  # attachment suites do, or every render-bearing manifest fails to attach.
  OPERATOR_HOME="$SANDBOX/operator-home"
  mkdir -p "$OPERATOR_HOME/.local/bin" || return 1
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$OPERATOR_HOME/.local/bin/trellis" || return 1
  chmod 755 "$OPERATOR_HOME/.local/bin/trellis" || return 1
  export HOME="$OPERATOR_HOME"
  RELEASE_TEST_STORE_BARRIER="$SANDBOX/release-store-barrier"
  RELEASE_TEST_ADOPTION_BARRIER="$SANDBOX/adoption-barrier"
  RELEASE_TEST_HOOK_BARRIER="$SANDBOX/hook-swap-barrier"
  bootstrap_repo="$(build_release_repo "0.0.0" annotated "0.0.0" bootstrap-fixture)" || return 1
  TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    release-store-bootstrap "$RELEASE_STORE_LIB" "0.0.0" "$bootstrap_repo" || {
      echo 'could not install test bootstrap release'
      return 1
    }
  release_store_machine_paths
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
  if [ "${GROUP_PLAN_CASE_LOCK_HELD:-false}" = true ]; then
    group_plan_case_lease_release
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

eval "$(declare -f apply_plan | /usr/bin/sed '1s/^apply_plan /release_fixture_original_apply_plan /')"
apply_plan() {
  release_fixture_original_apply_plan "$@" || return "$?"
  if [ "$(printf '%s\n' "$1" | jq -r '.binding.git_common_dir + "/info/exclude"')" = "$(cat "$release_fixture_adoption_barrier/owner.target" 2>/dev/null)" ] &&
    [ ! -f "$release_fixture_adoption_barrier/owner-after-publish.ready" ]; then
    printf '%s\n' "$(release_fixture_self_pid)" > "$release_fixture_adoption_barrier/owner-after-publish.pid"
    release_fixture_wait "$release_fixture_adoption_barrier" owner-after-publish || return "$?"
  fi
}

# Marks the first time a checkout-lock step meets a held lock (reclaim or
# acquire answers 3), so a test can release its holder only after that.
release_fixture_note_lock_busy() {
  if [ "$1" -eq 3 ] && [ -d "$release_fixture_adoption_barrier" ] && [ ! -L "$release_fixture_adoption_barrier" ]; then
    : > "$release_fixture_adoption_barrier/checkout-lock-busy.ready" || return 5
  fi
  return "$1"
}
eval "$(declare -f attachment_checkout_lock_reclaim | /usr/bin/sed '1s/^attachment_checkout_lock_reclaim /release_fixture_original_checkout_lock_reclaim /')"
attachment_checkout_lock_reclaim() {
  release_fixture_original_checkout_lock_reclaim "$@"
  release_fixture_note_lock_busy "$?"
}
eval "$(declare -f attachment_checkout_lock_acquire | /usr/bin/sed '1s/^attachment_checkout_lock_acquire /release_fixture_original_checkout_lock_acquire /')"
attachment_checkout_lock_acquire() {
  release_fixture_original_checkout_lock_acquire "$@"
  release_fixture_note_lock_busy "$?"
}

# The real checkout-lock wait is 300 s; a short-lock-wait marker bounds it at
# 2 s so a test can exercise the named refusal without waiting it out.
eval "$(declare -f attachment_checkout_lock_wait | /usr/bin/sed '1s/^attachment_checkout_lock_wait /release_fixture_original_checkout_lock_wait /')"
attachment_checkout_lock_wait() {
  local rc tries=0
  [ -f "$release_fixture_adoption_barrier/short-lock-wait" ] || { release_fixture_original_checkout_lock_wait "$@"; return "$?"; }
  while :; do
    if attachment_checkout_lock_reclaim "$@"; then
      attachment_checkout_lock_acquire "$@" && return 0
      rc=$?
    else
      rc=$?
    fi
    [ "$rc" -eq 3 ] && [ "$tries" -lt 8 ] || return "$rc"
    tries=$((tries + 1))
    sleep 0.25
  done
}

eval "$(declare -f adoption_publish_render | /usr/bin/sed '1s/^adoption_publish_render /release_fixture_original_publish_render /')"
adoption_publish_render() {
  release_fixture_original_publish_render "$@" || return "$?"
  if [ "$2" = forward ] && [ "$(printf '%s\n' "$1" | jq -r '.destination')" = "$(cat "$release_fixture_adoption_barrier/exclude.target" 2>/dev/null)" ]; then
    printf '%s\n' "$(release_fixture_self_pid)" > "$release_fixture_adoption_barrier/exclude-after-publish.pid"
    release_fixture_wait "$release_fixture_adoption_barrier" exclude-after-publish || return "$?"
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
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  fixture="${4:-}"
  case "$fixture" in
    bootstrap-fixture)
      cp "$REPO_ROOT/scripts/trellis" "$REPO_ROOT/scripts/show-config.sh" "$repo/scripts/" || return 1
      cp "$REPO_ROOT/trellis.config.json" "$repo/trellis.config.json" || return 1
      mkdir -p "$repo/core-rules/skills/process-gate/scripts/lib" || return 1
      cp "$REPO_ROOT/core-rules/skills/process-gate/scripts/lib/pi-artifacts.py" \
        "$repo/core-rules/skills/process-gate/scripts/lib/pi-artifacts.py" || return 1
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
  local ready_file="$1" process_id="$2" log="$3" started_at=$SECONDS beat_at=$SECONDS
  # Bounded by the release process's own liveness, not a fixed try cap: under
  # load a live process can take minutes to plan, and a 20 s cap turned that
  # into a red test (P1g, R39). An early exit still fails at once, with the
  # refusal retained in TAP; a hung process is left to the harness deadline,
  # as for the group-plan case lease (R10), with a heartbeat at least every
  # 60 s of wall clock so it is never silent (R39 Q2).
  while [ ! -f "$ready_file" ]; do
    if ! kill -0 "$process_id" 2>/dev/null; then
      [ ! -f "$ready_file" ] || return 0
      printf 'release process exited before barrier: %s\n' "$ready_file" >&2
      [ ! -f "$log" ] || cat "$log" >&2
      return 1
    fi
    if [ $((SECONDS - beat_at)) -ge 60 ]; then
      beat_at=$SECONDS
      printf 'waiting for release barrier %s: release pid %s alive (elapsed %ss)\n' \
        "$ready_file" "$process_id" "$((SECONDS - started_at))" >&2
    fi
    sleep 0.1
  done
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

directory_mode() {
  local candidate
  candidate="$(stat -f '%Lp' "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c '%a' "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
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













build_retiring_release_repo() {
  local version="$1" repo manifest
  repo="$(build_release_repo "$version")" || return 1
  printf '# retired agent\n' > "$repo/core-rules/retired.md" || return 1
  manifest="$repo/core-rules/inheritance-manifest.json"
  jq '.harnesses.codex.links += [{source:"core-rules/retired.md",destination:".codex/hooks/retired.md"}]' \
    "$manifest" > "$manifest.tmp" || return 1
  mv "$manifest.tmp" "$manifest" || return 1
  retag_release_repo "$repo" "$version" || return 1
  printf '%s\n' "$repo"
}

# Each attach spawns a detached post-attach job that takes the checkout lock
# for short steps; adopt does not wait for it. Settle on its recorded verdict.
wait_for_attachment_statuses() {
  [ "${TRELLIS_ATTACH_POSTJOB:-}" != off ] || return 0
  local count="$1" tries=0
  until [ "$(jq -s '[.[] | select(.state | IN("ok","failed","blocked-by-journal"))] | length' \
      "$TRELLIS_HOME_FIX"/state/attachment-status/*/*.json 2>/dev/null)" = "$count" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 3000 ] || { echo 'post-attach jobs did not settle'; return 1; }
    sleep 0.1
  done
}


# Pi releases before 1.3.18 render hooks under .pi/hooks; later ones render
# nothing there, because pi stalls startup on that reserved directory.
build_pi_release_repo() {
  local version="$1" legacy="$2" repo manifest links
  repo="$(build_release_repo "$version")" || return 1
  mkdir -p "$repo/core-rules/hooks/lib" || return 1
  cp "$REPO_ROOT/core-rules/hooks/lib/autonomy.sh" "$repo/core-rules/hooks/lib/autonomy.sh" || return 1
  cp "$REPO_ROOT/trellis.config.json" "$repo/trellis.config.json" || return 1
  manifest="$repo/core-rules/inheritance-manifest.json"
  links='[{"source":"core-rules/CLAUDE.md","destination":".pi/extensions/trellis.md"}]'
  [ "$legacy" != legacy ] || links='[{"source":"core-rules/CLAUDE.md","destination":".pi/extensions/trellis.md"},
    {"source":"core-rules/CLAUDE.md","destination":".pi/hooks/dispatch.sh"},
    {"source":"core-rules/CLAUDE.md","destination":".pi/hooks/lib/task-context.sh"}]'
  jq --argjson links "$links" '.schema_version = 2
    | .harnesses.pi = {links:$links,render:[]} | .harnesses.shared_agents = {links:[],render:[]}' \
    "$manifest" > "$manifest.tmp" || return 1
  mv "$manifest.tmp" "$manifest" || return 1
  retag_release_repo "$repo" "$version" || return 1
  printf '%s\n' "$repo"
}

attach_pi_project() {
  local root="$1" version="$2"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release "$version" --harness pi "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}




# The strict predicate behind show-config's "valid strict local attachment"
# and doctor's managed-excludes row, run against the registry row for ROOT.
strict_attachment_check() {
  local root="$1" owner row
  owner="$(owner_for_root "$root")" || return 1
  row="$(jq -c --arg root "$root" '
    .projects | to_entries[] | .key as $key | .value.checkouts | to_entries[] as $checkout
    | $checkout.value.worktrees | to_entries[] | select(.value.root == $root)
    | {fleet:($key | split("/")[0]), project:($key | split("/")[1]), checkout:$checkout.key,
       worktree:.key, attachment:.value.attachment_id, release:$checkout.value.release,
       harnesses:($checkout.value.harnesses // [])}' "$TRELLIS_HOME_FIX/registry.json")" || return 1
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    lib="$1"; shift
    . "$lib/trellis-home.sh"; . "$lib/release-store.sh"; . "$lib/local-registry.sh"
    . "$lib/attachment.sh"; . "$lib/health-checks.sh"
    hc_portable_attachment "$@"
  ' strict-attachment "$REPO_ROOT/scripts/lib" "$TRELLIS_HOME_FIX" "$owner" "$root" \
    "$(jq -r '.fleet' <<< "$row")" "$(jq -r '.project' <<< "$row")" \
    "$(jq -r '.checkout' <<< "$row")" "$(jq -r '.worktree' <<< "$row")" \
    "$(jq -r '.attachment' <<< "$row")" "$(jq -r '.release' <<< "$row")" \
    "$(jq -c '.harnesses' <<< "$row")"
}

show_attachment_config() {
  local root="$1"
  jq -n --arg source "$SANDBOX/repo-0.0.0" --arg root "$SANDBOX" '{
    schema_version:1, source_root:$source, release_remote:"fixture://bootstrap",
    active_cli_release:"0.0.0", default_fleet:"personal",
    fleets:{personal:{discovery_roots:[$root]}}}' > "$TRELLIS_HOME_FIX/config.json"
  chmod 600 "$TRELLIS_HOME_FIX/config.json"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c 'cd "$1" && "$2" show-config' _ \
    "$root" "$OPERATOR_HOME/.local/bin/trellis"
}

# 1.3.18 shipped this gap: a checkout with one owner record had its .pi/hooks
# retired but kept the old release's exclude block, which the strict check
# then rejected, so show-config and doctor exited 4.



























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




stage_checkout_lock_holder() {
  local project="$1" pid="$2" common
  common="$(cd "$project" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/attachment.sh"
    _attachment_test_stage_checkout_lock "$2" "$3" "$4" "$5"' _ \
    "$REPO_ROOT" "$TRELLIS_HOME_FIX" "$(registry_sha256_text "$common")" "$common" "$pid"
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

# GAP (plan section 6, "Explicit release adoption"): the existing two-tag case
# uses a bare compatibility --runtime-anchor, and every managed-adoption case
# installs both releases BEFORE attaching. Nothing proved that installing B into
# a live store leaves an already attached checkout on A, nor that the later
# adoption moves exactly one anchor and rewrites no harness leaf.










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



# Spec 055 A3.4, the store half (the launcher half is in trellis-launcher.bats).
# The released 1.3.6 store, unchanged, installs a packaged tag from a remote
# whose main has moved past the release commit and never contained the payload
# commit. The inversion is the same store on the unfiltered release-commit tag:
# it records the excluded entries, so the "none" assertion can fail.
