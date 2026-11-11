#!/usr/bin/env bats
# Only fixture Git worktrees and stubbed host commands are inspected.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-pi-parent.XXXXXX")"; SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"; STUB_BIN="$SANDBOX/bin"; MAIN="$SANDBOX/main"; WT="$HOME/.pi-worktrees/pi-agent-fixture"
  local fenced_git
  fenced_git="$(command -v git)"
  mkdir -p "$HOME/.pi-worktrees" "$TRELLIS_HOME" "$STUB_BIN"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  printf '#!/bin/bash\nexec %q "$@"\n' "$fenced_git" > "$STUB_BIN/git"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/gh"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/launchctl"
  chmod 700 "$STUB_BIN/git" "$STUB_BIN/gh" "$STUB_BIN/launchctl"
  PATH="$STUB_BIN:$PATH"; export HOME TRELLIS_HOME PATH
  git init -q -b main "$MAIN"; git -C "$MAIN" config user.name fixture; git -C "$MAIN" config user.email fixture@example.invalid
  printf 'seed\n' > "$MAIN/tracked"; git -C "$MAIN" add tracked; git -C "$MAIN" commit -qm fixture
  git -C "$MAIN" worktree add -q -b pi-agent-fixture "$WT"
  : > "$SANDBOX/owners"; printf 'ok\n' > "$SANDBOX/lsof"
  . "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh"
}
teardown() { [ -z "${SANDBOX:-}" ] || { chmod -R u+rwX "$SANDBOX"; rm -rf "${SANDBOX:?}"; }; }

@test "unreachable parent is a could-not-check candidate, not a reclaimable orphan" {
  local missing="$SANDBOX/unmounted/.git"
  run dj_pi_entry_verdict "$WT" 7 "$SANDBOX/owners" "$SANDBOX/lsof" 7 100000
  [[ "$output" == skip$'\t'*'registered with its parent repository'* ]] || { echo "$output"; false; }
  mv "$WT/.git" "$SANDBOX/git-aside"
  printf 'gitdir: %s/worktrees/fixture\n' "$missing" > "$WT/.git"
  touch -t 202001010000 "$WT/.git" "$WT/tracked" "$WT"
  run dj_pi_entry_verdict "$WT" 7 "$SANDBOX/owners" "$SANDBOX/lsof" 7 100000
  [[ "$output" == candidate$'\t'*"could not be checked"*"$missing"* ]] || { echo "$output"; false; }
  [[ "$output" != reclaimable$'\t'* ]] || { echo "$output"; false; }

  # The orchestrator's dry-run must preserve the candidate classification.
  mkdir -p "$SANDBOX/canonical/audits"
  printf '%s\n' '{"schema_version":2,"maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude"]}' > "$SANDBOX/canonical/trellis.config.json"
  printf '{"schema_version":1,"source_root":"%s","release_remote":"%s","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["%s"]}}}\n' "$SANDBOX/canonical" "$SANDBOX/canonical" "$SANDBOX" > "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/config.json" "$TRELLIS_HOME/registry.json"
  run env TRELLIS_CONFIG="$SANDBOX/canonical/trellis.config.json" TRELLIS_WORKTREE_ROOT="$SANDBOX/worktrees" \
    DJ_BUILD_ACTIVE_OVERRIDE=0 bash "$REPO_ROOT/scripts/disk-janitor.sh" --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[candidate] $WT"*"could not be checked"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $WT"* ]] || { echo "$output"; false; }

  # A positively absent parent under a searchable directory is an orphan,
  # whereas an unsearchable directory cannot establish absence.
  mkdir -p "$SANDBOX/gone-parent" "$SANDBOX/blocked-parent"
  printf 'gitdir: %s/.git/worktrees/fixture\n' "$SANDBOX/gone-parent" > "$WT/.git"
  touch -t 202001010000 "$WT/.git" "$WT"
  run dj_pi_entry_verdict "$WT" 7 "$SANDBOX/owners" "$SANDBOX/lsof" 7 100000
  [[ "$output" == reclaimable$'\t'*"no repository registers it"* ]] || { echo "$output"; false; }
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$SANDBOX/blocked-parent"
    printf 'gitdir: %s/.git/worktrees/fixture\n' "$SANDBOX/blocked-parent" > "$WT/.git"
    touch -t 202001010000 "$WT/.git" "$WT"
    run dj_pi_entry_verdict "$WT" 7 "$SANDBOX/owners" "$SANDBOX/lsof" 7 100000
    chmod 700 "$SANDBOX/blocked-parent"
    [[ "$output" == candidate$'\t'*"could not be checked"*"$SANDBOX/blocked-parent/.git"* ]] || { echo "$output"; false; }
  fi

  # A reachable repository that actually answers "not listed" is distinct.
  mkdir -p "$SANDBOX/unlisted"
  printf 'gitdir: %s/.git/worktrees/unlisted\n' "$MAIN" > "$SANDBOX/unlisted/.git"
  touch -t 202001010000 "$SANDBOX/unlisted/.git" "$SANDBOX/unlisted"
  run dj_pi_entry_verdict "$SANDBOX/unlisted" 7 "$SANDBOX/owners" "$SANDBOX/lsof" 7 100000
  [[ "$output" == reclaimable$'\t'*"no repository registers it"* ]] || { echo "$output"; false; }
}
