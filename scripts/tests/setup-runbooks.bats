#!/usr/bin/env bats
# Executable fresh-machine coverage for the documented setup and onboarding
# runbooks: AGENT_SETUP.md, AGENT_ONBOARD_PROJECT.md, and README.md.
#
# Every case runs a block the runbooks tell an operator or agent to paste, in
# the documented order, against a temporary HOME and a temporary TRELLIS_HOME.
# The operator's real ~/.trellis and ~/.local/bin/trellis are never read or
# written: the runbooks' own rehearsal contract is what makes that possible, so
# honoring it here is part of the coverage.
#
# Fixture shape follows scripts/tests/trellis-launcher.bats: in-file builders
# plus a sealed immutable release. The release is not hand-assembled — it is
# installed by the real `release install` route from a fixture annotated tag,
# so the payload these blocks execute is a genuinely sealed immutable payload.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

RELEASE_VERSION=9.9.9
NEXT_RELEASE=9.9.10
UPGRADE_RELEASE=9.9.11
FLEET=personal
PROJECT_ID=t22-fixture-project

# Scripts the documented blocks reach through the dispatcher, plus the two
# sync engines `doctor --fix` may exec. Keeping the payload to what the
# runbooks exercise keeps each sealed-snapshot verification fast.
PAYLOAD_SCRIPTS=(
  trellis
  trellis-launcher.sh
  configure.sh
  release.sh
  upgrade.sh
  registry.sh
  attach-project.sh
  onboard-project.sh
  migrate-project.sh
  doctor.sh
  show-config.sh
  seed-inheritance-symlinks.sh
  sync-hooks.sh
  sync-codex-hooks.sh
)

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-runbooks.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"

  # AGENT_SETUP.md §1: new private state and an isolated user home for this
  # rehearsal. This shell never reads or mutates the operator's ~/.trellis or
  # ~/.local/bin/trellis.
  export TRELLIS_HOME="$SANDBOX/trellis home"
  export HOME="$SANDBOX/user home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  unset TRELLIS_ROOT TRELLIS_RELEASE TRELLIS_FLEET TRELLIS_CONFIG
  export GIT_CONFIG_NOSYSTEM=1

  PERSONAL_DISCOVERY_ROOT="$SANDBOX/personal projects"
  WORK_DISCOVERY_ROOT="$SANDBOX/work projects"
  mkdir -p "$PERSONAL_DISCOVERY_ROOT" "$WORK_DISCOVERY_ROOT"

  SOURCE_ROOT="$SANDBOX/policy source"
  RELEASE_REMOTE="$SOURCE_ROOT"
  make_policy_source_clone "$SOURCE_ROOT" "$RELEASE_VERSION"

  BOOTSTRAP_CONFIGURE="$SOURCE_ROOT/scripts/configure.sh"
  TRELLIS="$HOME/.local/bin/trellis"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

fixture_git() {
  git -c protocol.file.allow=always "$@"
}

fixture_commit_repo() {
  local repo="$1" message="$2"
  fixture_git -C "$repo" config user.email fixture@example.invalid
  fixture_git -C "$repo" config user.name 'Runbook Fixture'
  fixture_git -C "$repo" config commit.gpgsign false
  fixture_git -C "$repo" config tag.gpgSign false
  fixture_git -C "$repo" add -A
  fixture_git -C "$repo" -c core.hooksPath=/dev/null commit -qm "$message"
}

# A policy source clone shaped like the real one: the real scripts and the real
# contextual harness templates, a fixture inheritance manifest, and an
# annotated vVERSION tag whose core-rules/VERSION matches exactly.
make_policy_source_clone() {
  local root="$1" version="$2" script
  mkdir -p "$root/scripts" "$root/core-rules/templates"
  for script in "${PAYLOAD_SCRIPTS[@]}"; do
    cp "$REPO_ROOT/scripts/$script" "$root/scripts/$script"
    chmod 755 "$root/scripts/$script"
  done
  cp -R "$REPO_ROOT/scripts/lib" "$root/scripts/lib"
  cp "$REPO_ROOT/trellis.config.json" "$root/trellis.config.json"
  # The SessionStart render templates and the pre-push carrier are contract
  # surfaces the attachment engine validates by content, so they are the real
  # files rather than fixtures.
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$root/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$root/core-rules/templates/codex-hooks.local.json"
  cp -R "$REPO_ROOT/core-rules/githooks" "$root/core-rules/githooks"
  # show-config resolves the autonomy slider out of the selected payload.
  mkdir -p "$root/core-rules/hooks/lib"
  cp "$REPO_ROOT/core-rules/hooks/lib/autonomy.sh" "$root/core-rules/hooks/lib/autonomy.sh"
  printf '# fixture canonical policy\n' > "$root/core-rules/CLAUDE.md"
  printf '%s\n' "$version" > "$root/core-rules/VERSION"
  cat > "$root/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": [
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
  fixture_git init -q "$root"
  fixture_commit_repo "$root" "release $version"
  fixture_git -C "$root" tag -a "v$version" -m "release $version"
}

# Publish a further annotated release from an existing source clone.
publish_release() {
  local root="$1" version="$2"
  printf '%s\n' "$version" > "$root/core-rules/VERSION"
  fixture_commit_repo "$root" "release $version"
  fixture_git -C "$root" tag -a "v$version" -m "release $version"
}

# AGENT_SETUP.md §2 + §3, verbatim: the only block that runs a script from the
# source clone, then the launcher's one bootstrap-safe installation route.
run_setup_runbook() {
  "$BOOTSTRAP_CONFIGURE" configure \
    --source "$SOURCE_ROOT" \
    --home "$TRELLIS_HOME" \
    --default-fleet "$FLEET" \
    --discovery-root "$PERSONAL_DISCOVERY_ROOT" \
    --release "$RELEASE_VERSION" \
    --release-remote "$RELEASE_REMOTE" \
    --launcher-template "$SOURCE_ROOT/scripts/trellis-launcher.sh" || return "$?"
  "$BOOTSTRAP_CONFIGURE" fleet add work \
    --home "$TRELLIS_HOME" \
    --discovery-root "$WORK_DISCOVERY_ROOT" || return "$?"
  TRELLIS="$HOME/.local/bin/trellis"
  test -x "$TRELLIS" || return 1
  "$TRELLIS" release install "$RELEASE_VERSION" --remote "$RELEASE_REMOTE" || return "$?"
  "$TRELLIS" release verify "$RELEASE_VERSION" || return "$?"
}

make_project() {
  local root="$1"
  mkdir -p "$root"
  fixture_git init -q "$root"
  printf 'fixture project\n' > "$root/README.md"
  fixture_commit_repo "$root" 'fixture project'
  printf '%s\n' "$root"
}

# AGENT_SETUP.md §5 / AGENT_ONBOARD_PROJECT.md §3, verbatim.
run_onboard_runbook() {
  local root="$1"
  "$TRELLIS" onboard \
    --home "$TRELLIS_HOME" \
    --fleet "$FLEET" \
    --release "$RELEASE_VERSION" \
    --project-id "$PROJECT_ID" \
    --harness claude \
    --harness codex \
    --harness omp \
    "$root"
}

run_attach_runbook() {
  local root="$1" release="${2:-$RELEASE_VERSION}"
  "$TRELLIS" attach \
    --home "$TRELLIS_HOME" \
    --fleet "$FLEET" \
    --release "$release" \
    --harness claude \
    --harness codex \
    --harness omp \
    "$root"
}

# The documented owner step between onboarding and adoption: `.trellis.json` is
# reviewed and committed as a normal project change.
commit_portable_manifest() {
  local root="$1"
  fixture_git -C "$root" add .trellis.json
  fixture_git -C "$root" -c core.hooksPath=/dev/null commit -qm 'add portable Trellis manifest'
}

# A machine that has completed AGENT_SETUP.md §1–§5 with one attached project.
prepare_attached_machine() {
  run_setup_runbook >/dev/null || return "$?"
  PROJECT_ROOT="$(make_project "$PERSONAL_DISCOVERY_ROOT/project with spaces")" || return "$?"
  run_onboard_runbook "$PROJECT_ROOT" >/dev/null || return "$?"
}

payload_script() {
  printf '%s/releases/%s/payload/scripts/%s\n' "$TRELLIS_HOME" "${2:-$RELEASE_VERSION}" "$1"
}

assert_line_matches() {
  local needle="$1"
  case "$output" in
    *"$needle"*) return 0 ;;
  esac
  printf 'expected output to contain: %s\n%s\n' "$needle" "$output" >&2
  return 1
}

refute_line_matches() {
  local needle="$1"
  case "$output" in
    *"$needle"*)
      printf 'expected output NOT to contain: %s\n%s\n' "$needle" "$output" >&2
      return 1
      ;;
  esac
  return 0
}

@test "AGENT_SETUP 1-3 and README quick start: configure, second fleet, install and verify from a clean machine" {
  run run_setup_runbook
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # §2: private machine configuration with both fleet definitions, and the
  # fixed launcher atomically installed under the rehearsal HOME.
  [ -x "$HOME/.local/bin/trellis" ]
  [ ! -e "$HOME/.trellis" ]
  jq -e --arg source "$SOURCE_ROOT" --arg release "$RELEASE_VERSION" '
    .source_root == $source
    and .active_cli_release == $release
    and .default_fleet == "personal"
    and (.fleets | has("personal") and has("work"))
  ' "$TRELLIS_HOME/config.json" >/dev/null

  # §3: the installed payload is immutable and verifies through the launcher.
  [ -d "$TRELLIS_HOME/releases/$RELEASE_VERSION/payload" ]
  [ ! -w "$TRELLIS_HOME/releases/$RELEASE_VERSION/release.json" ]

  run "$TRELLIS" release verify "$RELEASE_VERSION"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "AGENT_ONBOARD_PROJECT 1-2: local contract and preflight blocks resolve the worktree and inspect the manifest" {
  run_setup_runbook >/dev/null
  PROJECT_ROOT="$(make_project "$PERSONAL_DISCOVERY_ROOT/contract project")"

  # §1, verbatim.
  TRELLIS_CLI="$HOME/.local/bin/trellis"
  test -x "$TRELLIS_CLI"
  PROJECT_INPUT="$PROJECT_ROOT"
  run fixture_git -C "$PROJECT_INPUT" rev-parse --show-toplevel
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT_ROOT" ]

  # §2, verbatim: verify the exact release before any project mutation.
  run "$TRELLIS_CLI" release verify "$RELEASE_VERSION"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # §2 manifest inspection, no-manifest branch.
  run bash -c '
    PROJECT_ROOT="$1"; PROJECT_ID="$2"
    if [ -L "$PROJECT_ROOT/.trellis.json" ]; then
      printf "%s\n" "Refuse: .trellis.json must be an ordinary file, never a symlink." >&2
      exit 3
    elif [ -f "$PROJECT_ROOT/.trellis.json" ]; then
      PROJECT_ID="$(jq -r ".project_id" "$PROJECT_ROOT/.trellis.json")"
      printf "portable manifest present for project ID: %s\n" "$PROJECT_ID"
    else
      : "${PROJECT_ID:?Choose and confirm a portable project ID before onboarding}"
      printf "no portable manifest; onboarding will create one for project ID: %s\n" "$PROJECT_ID"
    fi
  ' _ "$PROJECT_ROOT" "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "no portable manifest; onboarding will create one for project ID: $PROJECT_ID"

  run_onboard_runbook "$PROJECT_ROOT" >/dev/null

  # §2 manifest inspection, manifest-present branch.
  run bash -c '
    PROJECT_ROOT="$1"
    if [ -L "$PROJECT_ROOT/.trellis.json" ]; then
      printf "%s\n" "Refuse: .trellis.json must be an ordinary file, never a symlink." >&2
      exit 3
    elif [ -f "$PROJECT_ROOT/.trellis.json" ]; then
      PROJECT_ID="$(jq -r ".project_id" "$PROJECT_ROOT/.trellis.json")"
      printf "portable manifest present for project ID: %s\n" "$PROJECT_ID"
    fi
  ' _ "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "portable manifest present for project ID: $PROJECT_ID"
}

@test "AGENT_SETUP 5 and README quick start: onboard attaches three harnesses and leaves only the tracked manifest" {
  run_setup_runbook >/dev/null
  PROJECT_ROOT="$(make_project "$PERSONAL_DISCOVERY_ROOT/project with spaces")"

  run fixture_git -C "$PROJECT_ROOT" status --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run run_onboard_runbook "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches 'created tracked manifest'

  [ -L "$PROJECT_ROOT/.claude/rules/trellis.md" ]
  [ -L "$PROJECT_ROOT/.agents/rules/trellis.md" ]
  [ -L "$PROJECT_ROOT/.omp/AGENTS.md" ]
  # The runtime anchor is the immutable installed payload, never SOURCE_ROOT.
  [ "$(readlink "$PROJECT_ROOT/.trellis/runtime")" = "$TRELLIS_HOME/releases/$RELEASE_VERSION/payload" ]

  # "Before the project owner commits a newly created manifest, git status may
  # show that intentional tracked file." Nothing else may appear.
  run fixture_git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all
  [ "$status" -eq 0 ]
  [ "$output" = '?? .trellis.json' ] || { echo "$output"; false; }
}

@test "AGENT_SETUP 5 and AGENT_ONBOARD_PROJECT 3: a clean clone with a valid manifest attaches directly" {
  prepare_attached_machine
  commit_portable_manifest "$PROJECT_ROOT"

  local clone="$PERSONAL_DISCOVERY_ROOT/fresh manifest clone"
  run fixture_git clone -q "$PROJECT_ROOT" "$clone"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  clone="$(CDPATH= cd "$clone" && pwd -P)"

  run run_attach_runbook "$clone"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "attached: $clone"

  [ -L "$clone/.claude/rules/trellis.md" ]
  [ -L "$clone/.agents/rules/trellis.md" ]
  [ -L "$clone/.omp/AGENTS.md" ]

  # Attachment-owned local state must not dirty a committed-manifest checkout.
  run fixture_git -C "$clone" status --porcelain=v1 --untracked-files=all
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "AGENT_SETUP 7 and AGENT_ONBOARD_PROJECT 5: the verification block runs green and show-config resolves through the launcher" {
  prepare_attached_machine

  run "$TRELLIS" release verify "$RELEASE_VERSION"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" registry list --home "$TRELLIS_HOME" --fleet "$FLEET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "$PROJECT_ID"
  assert_line_matches "$PROJECT_ROOT"

  run "$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches '0 error(s)'

  # The substituted example: `trellis show-config [--home PATH] [--fleet NAME]`
  # executed from the project directory.
  run bash -c 'cd "$1" && "$2" show-config --home "$3" --fleet "$4"' \
    _ "$PROJECT_ROOT" "$TRELLIS" "$TRELLIS_HOME" "$FLEET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "selected fleet:        $FLEET"
  assert_line_matches "registry project:      $PROJECT_ID"
  assert_line_matches "$TRELLIS_HOME/releases/$RELEASE_VERSION/payload"
  # Immutable execution: the route reads its policy from the sealed private
  # snapshot the launcher executes, never from the mutable source clone.
  assert_line_matches "$TRELLIS_HOME/releases/.tmp.$RELEASE_VERSION.exec."
  refute_line_matches "policy file:          $SOURCE_ROOT"

  run fixture_git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all
  [ "$status" -eq 0 ]
  [ "$output" = '?? .trellis.json' ] || { echo "$output"; false; }
}

@test "README health block: every doctor variant and both show-config routes run through the fixed launcher" {
  prepare_attached_machine

  TRELLIS="$HOME/.local/bin/trellis"
  test -x "$TRELLIS"

  run "$TRELLIS" doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches '0 error(s)'

  run "$TRELLIS" doctor --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" doctor --fix --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" doctor --fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # `"$TRELLIS" show-config` — default local home and fleet.
  run "$TRELLIS" show-config
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches 'Tracked portable policy'
  assert_line_matches "selected fleet:        $FLEET"

  # `"$TRELLIS" show-config --home "$TRELLIS_HOME" --fleet FLEET`.
  run "$TRELLIS" show-config --home "$TRELLIS_HOME" --fleet "$FLEET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "configured fleets:     personal, work"
}

@test "AGENT_SETUP 8 and AGENT_ONBOARD_PROJECT 6: a moved policy source clone is reconfigured and relinked" {
  prepare_attached_machine

  NEW_SOURCE_ROOT="$SANDBOX/moved policy source"
  mv "$SOURCE_ROOT" "$NEW_SOURCE_ROOT"
  NEW_SOURCE_ROOT="$(CDPATH= cd "$NEW_SOURCE_ROOT" && pwd -P)"

  run "$TRELLIS" configure --source "$NEW_SOURCE_ROOT" --home "$TRELLIS_HOME" --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches 'Launcher: skipped'

  run "$TRELLIS" relink --home "$TRELLIS_HOME" --fleet "$FLEET" "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # The project runtime never followed the source clone.
  [ "$(readlink "$PROJECT_ROOT/.trellis/runtime")" = "$TRELLIS_HOME/releases/$RELEASE_VERSION/payload" ]

  run "$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches '0 error(s)'
}

@test "AGENT_SETUP 8 and AGENT_ONBOARD_PROJECT 6: a moved checkout detaches, moves, and reattaches at its new explicit path" {
  prepare_attached_machine
  NEW_PROJECT_ROOT="$PERSONAL_DISCOVERY_ROOT/relocated project"

  run "$TRELLIS" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "detached: $PROJECT_ROOT"

  # "Move the checkout with the operator's chosen filesystem operation."
  mv "$PROJECT_ROOT" "$NEW_PROJECT_ROOT"

  run run_attach_runbook "$NEW_PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "attached: $NEW_PROJECT_ROOT"

  run "$TRELLIS" registry list --home "$TRELLIS_HOME" --fleet "$FLEET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches "$NEW_PROJECT_ROOT"

  # "An unavailable local-registry row remains explicit; do not guess an
  # alternative path." The stale row stays visible and every other row is
  # still checked — report-only, per-row continuation, aggregate exit class.
  run "$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  assert_line_matches "unavailable: retained local registry row at $PROJECT_ROOT"
  assert_line_matches 'layout: portable-attached'
  assert_line_matches '2 local row(s) checked'
}

@test "AGENT_SETUP 8 and AGENT_ONBOARD_PROJECT 6: recovery completes an interrupted transaction, then detach opts out" {
  prepare_attached_machine

  # Precondition, not a documented block: interrupt a detach transaction so a
  # durable journal exists. The launcher scrubs the environment, so the fault
  # is injected by running the installed payload's engine directly.
  run env ATTACHMENT_FAULT_PHASE=detach-prepared \
    bash "$(payload_script attach-project.sh)" detach \
      --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [ -n "$(find "$TRELLIS_HOME/state/attachment-journals" -type f -name '*.json' -print)" ]

  # §8 "Recover interruption or opt out locally", verbatim.
  run "$TRELLIS" recover --home "$TRELLIS_HOME" "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Recovery finished the interrupted detach, so the row is now explicitly
  # detached: visible, report-only, and no automatic repair.
  run "$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; false; }
  assert_line_matches 'registry status: detached — automatic attachment repair is withheld'

  run run_attach_runbook "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Detach leaves the tracked portable manifest intact and inert.
  [ -f "$PROJECT_ROOT/.trellis.json" ]
  [ ! -e "$PROJECT_ROOT/.trellis/runtime" ]
  [ ! -e "$PROJECT_ROOT/.claude/rules/trellis.md" ]
  [ ! -e "$PROJECT_ROOT/.agents/rules/trellis.md" ]
  [ ! -e "$PROJECT_ROOT/.omp/AGENTS.md" ]
}

@test "AGENT_SETUP 9, AGENT_ONBOARD_PROJECT 6, README adopt: verified project-scoped adoption and rollback" {
  prepare_attached_machine
  commit_portable_manifest "$PROJECT_ROOT"

  publish_release "$SOURCE_ROOT" "$NEXT_RELEASE"
  run "$TRELLIS" release install "$NEXT_RELEASE" --remote "$RELEASE_REMOTE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  TARGET_RELEASE="$NEXT_RELEASE"
  run "$TRELLIS" release verify "$TARGET_RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" release adopt "$TARGET_RELEASE" --project "$PROJECT_ID" --fleet "$FLEET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$PROJECT_ROOT/.trellis/runtime")" = "$TRELLIS_HOME/releases/$TARGET_RELEASE/payload" ]

  run "$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches '0 error(s)'

  # Rollback is the same explicit operation with a previously installed and
  # verified version, never a source-checkout link.
  ROLLBACK_RELEASE="$RELEASE_VERSION"
  run "$TRELLIS" release verify "$ROLLBACK_RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" release adopt "$ROLLBACK_RELEASE" --project "$PROJECT_ID" --fleet "$FLEET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$PROJECT_ROOT/.trellis/runtime")" = "$TRELLIS_HOME/releases/$ROLLBACK_RELEASE/payload" ]

  run "$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches '0 error(s)'
}

@test "README day-to-day: trellis upgrade installs, verifies, and adopts one named release" {
  prepare_attached_machine
  commit_portable_manifest "$PROJECT_ROOT"
  publish_release "$SOURCE_ROOT" "$UPGRADE_RELEASE"

  run "$TRELLIS" upgrade "$UPGRADE_RELEASE" --project "$PROJECT_ID" --fleet "$FLEET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ -d "$TRELLIS_HOME/releases/$UPGRADE_RELEASE/payload" ]
  [ "$(readlink "$PROJECT_ROOT/.trellis/runtime")" = "$TRELLIS_HOME/releases/$UPGRADE_RELEASE/payload" ]

  run "$TRELLIS" doctor --home "$TRELLIS_HOME" --fleet "$FLEET" --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches '0 error(s)'
}

@test "AGENT_SETUP 6 and AGENT_ONBOARD_PROJECT 3: migrate --prepare emits a reversible snapshot and --rollback restores it" {
  run_setup_runbook >/dev/null

  # A legacy project policy plus the legacy gitignore fragment. Legacy
  # *symlink* families are deliberately not part of this fixture: their
  # removal has to be authorized by an executing or explicitly named
  # historical checkout, and the launcher executes a per-invocation sealed
  # snapshot, so that shape needs the compatibility `--legacy-root PATH` flag
  # the runbook does not use. Without it the command refuses explicitly
  # ("ambiguous legacy symlink"), which is the intended safe outcome.
  PROJECT_ROOT="$(make_project "$PERSONAL_DISCOVERY_ROOT/legacy project")"
  cat > "$PROJECT_ROOT/CLAUDE.md" <<EOF
# Project instructions remain.
Project-owned closing instruction.
EOF
  cat > "$PROJECT_ROOT/.gitignore" <<EOF
vendor/
# --- Trellis inheritance symlinks (per-machine; regenerated by onboard-project.sh) ---
# Generated local Trellis state.
.claude/rules/trellis.md
.agents/rules/trellis.md
.omp/skills

# --- Trellis local runtime state ---
/context-log.md
# --- end Trellis local runtime state ---
# --- end Trellis fragment ---
build/
EOF
  printf '{"presets":["web-app"],"autonomy":4}\n' > "$PROJECT_ROOT/.trellis.config.json"
  fixture_commit_repo "$PROJECT_ROOT" 'legacy Trellis layout'
  local before_head
  before_head="$(fixture_git -C "$PROJECT_ROOT" rev-parse HEAD)"

  run "$TRELLIS" migrate --prepare \
    --home "$TRELLIS_HOME" \
    --project-id "$PROJECT_ID" \
    "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_line_matches 'snapshot: '
  assert_line_matches 'rollback: '

  SNAPSHOT="$(printf '%s\n' "$output" | awk '/^snapshot: / { sub(/^snapshot: /, ""); print; exit }')"
  [ -n "$SNAPSHOT" ]
  [ -f "$PROJECT_ROOT/.trellis.json" ]
  [ ! -e "$PROJECT_ROOT/.trellis.config.json" ]
  # `--prepare` never stages or commits the project change.
  [ "$(fixture_git -C "$PROJECT_ROOT" rev-parse HEAD)" = "$before_head" ]

  # Attach the migrated project through the normal all-three-harness command.
  run run_attach_runbook "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" detach --home "$TRELLIS_HOME" --all-worktrees "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$TRELLIS" migrate --rollback "$SNAPSHOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PROJECT_ROOT/.trellis.config.json" ]
  grep -Fq 'Trellis inheritance symlinks' "$PROJECT_ROOT/.gitignore"
}

@test "README day-to-day: mirror publish to a public template checkout" {
  skip 'documented block needs a real public mirror checkout and remote; --push also prompts before commit/push'
}

@test "README day-to-day: fleet rollout scripts across registered projects" {
  skip 'documented blocks (sync-hooks.sh, rollout-*.sh, sync-merge-gate.sh) operate on attached local-registry fleet checkouts, which a temp-HOME fixture has none of'
}

@test "AGENT_SETUP 2: persistent setup against the operator real HOME" {
  skip 'documented follow-up deliberately installs at the operator real $HOME/.local/bin/trellis; the fixture contract forbids touching it'
}
