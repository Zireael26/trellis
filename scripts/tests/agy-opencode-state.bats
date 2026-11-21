#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
# shellcheck source=helpers/release-fixture.bash
. "$REPO_ROOT/scripts/tests/helpers/release-fixture.bash"

setup_file() {
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/prototype"
  mkdir -p "$RELEASE_FIXTURE_PROTOTYPE"
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$RELEASE_FIXTURE_PROTOTYPE")"
  export RELEASE_FIXTURE_PROTOTYPE
  release_fixture_prototype_build "$RELEASE_FIXTURE_PROTOTYPE"
}

teardown_file() {
  chmod -R u+w "$RELEASE_FIXTURE_PROTOTYPE" 2>/dev/null || true
  rm -rf "$RELEASE_FIXTURE_PROTOTYPE"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agy-opencode-state.XXXXXX")"
  SANDBOX="$(release_fixture_canonical_dir "$SANDBOX")"
  HOME="$SANDBOX/user"
  TRELLIS_HOME="$SANDBOX/trellis"
  RELEASE_SOURCE="$SANDBOX/release"
  PROJECT="$SANDBOX/project"
  export HOME TRELLIS_HOME
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
  cp "$REPO_ROOT/trellis.config.json" "$SANDBOX/bootstrap release source/trellis.config.json"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  printf '{"schema_version":1,"project_id":"agy-state-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm initial
  LAUNCHER="$HOME/.local/bin/trellis"
  PAYLOAD="$TRELLIS_HOME/releases/9.9.9/payload"
}

wait_for_attach_postjobs_at() {
  local target_project="$1" target_payload="${2:-$PAYLOAD}"
  python3 - "$TRELLIS_HOME" "$target_payload/scripts/lib/attach-postjob.sh" "$target_project" <<'PY'
import errno, os, select, subprocess, sys
from pathlib import Path
home, postjob, project = sys.argv[1:]
pids = set()
for record in Path(home, "state/attachment-status").glob("*/*.job/pid"):
    try:
        fields = record.read_text().split()
        if fields:
            pids.add(int(fields[0]))
    except FileNotFoundError:
        pass
for line in subprocess.check_output(["ps", "-axww", "-o", "pid=,command="],
                                    text=True, errors="surrogateescape").splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and postjob in fields[1] and project in fields[1]:
        pids.add(int(fields[0]))
def still_our_job(pid):
    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                             stdout=subprocess.PIPE, text=True, errors="surrogateescape").stdout
    return postjob in command and project in command
for pid in pids - {os.getpid()}:
    try:
        if hasattr(os, "pidfd_open"):
            with os.fdopen(os.pidfd_open(pid), "rb") as process:
                if not still_our_job(pid):
                    continue
                poller = select.poll()
                poller.register(process, select.POLLIN)
                if not poller.poll(300000):
                    raise TimeoutError(f"attachment postjob {pid} did not exit")
        else:
            queue = select.kqueue()
            try:
                event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                      flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                      fflags=select.KQ_NOTE_EXIT)
                queue.control([event], 0, 0)
                if not still_our_job(pid):
                    continue
                if not queue.control(None, 1, 300):
                    raise TimeoutError(f"attachment postjob {pid} did not exit")
            finally:
                queue.close()
    except OSError as error:
        if error.errno != errno.ESRCH:
            raise
PY
}

teardown() {
  wait_for_attach_postjobs_at "$PROJECT" || true
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

owner_file() {
  find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print | head -1
}

registry_harnesses() {
  jq -c '.projects["personal/agy-state-fixture"].checkouts | to_entries[0].value.harnesses' "$TRELLIS_HOME/registry.json"
}

@test "partial detach across antigravity and opencode in both orders rewrites exclude, keeps doctor green, and restores exclude on final detach" {
  # Order A: detach opencode first, keep antigravity
  printf '# pre-attach user rule\n*.scratch\n' > "$PROJECT/.git/info/exclude"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attach_postjobs_at "$PROJECT"
  printf '# post-attach user tail\n' >> "$PROJECT/.git/info/exclude"

  run "$LAUNCHER" detach --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["antigravity"]' ]
  local owner
  owner="$(owner_file)"
  jq -e '.schema_version == 2 and .harnesses == ["antigravity"] and .render_context != null' "$owner" >/dev/null
  [ ! -e "$PROJECT/.opencode/opencode.json" ]
  [ -L "$PROJECT/.agents/AGENTS.md" ]
  [ -L "$PROJECT/.agents/workflows/explore.md" ]
  [ -f "$PROJECT/.agents/hooks.json" ]
  ! grep -Fxq '/.opencode/opencode.json' "$PROJECT/.git/info/exclude"
  grep -Fxq '/.agents/hooks.json' "$PROJECT/.git/info/exclude"
  grep -Fxq '# pre-attach user rule' "$PROJECT/.git/info/exclude"
  grep -Fxq '# post-attach user tail' "$PROJECT/.git/info/exclude"

  run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project agy-state-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Idempotent re-attach of surviving selection
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"already attached"* ]] || { echo "$output"; false; }
  wait_for_attach_postjobs_at "$PROJECT"

  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$PROJECT/.agents/AGENTS.md" ]
  [ ! -e "$PROJECT/.agents/hooks.json" ]
  ! grep -Fq 'Trellis local attachment exclude block' "$PROJECT/.git/info/exclude"
  grep -Fxq '# pre-attach user rule' "$PROJECT/.git/info/exclude"
  grep -Fxq '# post-attach user tail' "$PROJECT/.git/info/exclude"

  # Order B: detach antigravity first, keep opencode (render_context cleared to null)
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attach_postjobs_at "$PROJECT"

  run "$LAUNCHER" detach --harness antigravity "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["opencode"]' ]
  owner="$(owner_file)"
  jq -e '.schema_version == 2 and .harnesses == ["opencode"] and .render_context == null' "$owner" >/dev/null
  [ ! -e "$PROJECT/.agents/hooks.json" ]
  [ ! -e "$PROJECT/.agents/workflows/explore.md" ]
  [ -L "$PROJECT/.agents/AGENTS.md" ]
  [ -L "$PROJECT/.agents/skills/process-gate" ]
  [ -f "$PROJECT/.opencode/opencode.json" ]
  ! grep -Fxq '/.agents/hooks.json' "$PROJECT/.git/info/exclude"
  grep -Fxq '/.opencode/opencode.json' "$PROJECT/.git/info/exclude"

  run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project agy-state-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$PROJECT/.opencode/opencode.json" ]
  [ ! -e "$PROJECT/.agents/AGENTS.md" ]
}

@test "partial detach exclude_rewrite recovers cleanly from detach-exclude-before and detach-exclude-after faults" {
  local fault
  for fault in detach-exclude-before detach-exclude-after; do
    run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity --harness opencode "$PROJECT"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    wait_for_attach_postjobs_at "$PROJECT"

    run env ATTACHMENT_FAULT_PHASE="$fault" bash "$REPO_ROOT/scripts/attach-project.sh" detach --home "$TRELLIS_HOME" --harness opencode "$PROJECT"
    [ "$status" -ne 0 ]
    # Pending detach journal exists and validates in both shell and native verifiers
    local journal
    journal="$(find "$TRELLIS_HOME/state/attachment-journals" -name 'detach-*.json' -print | head -1)"
    [ -f "$journal" ]
    run bash -c '. "$1/scripts/lib/attachment.sh"; _attachment_detach_journal_valid "$2"' _ "$REPO_ROOT" "$journal"
    [ "$status" -eq 0 ] || { echo "$fault shell journal invalid: $output"; false; }
    run bash -c '. "$1/scripts/lib/attachment.sh"; _attachment_detach_python_filters journal-valid "$2"' _ "$REPO_ROOT" "$journal"
    [ "$status" -eq 0 ] || { echo "$fault native journal invalid: $output"; false; }

    # Recovery finishes cleanly
    run "$LAUNCHER" detach --harness opencode "$PROJECT"
    [ "$status" -eq 0 ] || { echo "$fault recovery failed: $output"; false; }
    [ -z "$(find "$TRELLIS_HOME/state/attachment-journals" -name 'detach-*.json' -print)" ]
    [ "$(registry_harnesses)" = '["antigravity"]' ]
    run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project agy-state-fixture
    [ "$status" -eq 0 ] || { echo "$fault doctor failed: $output"; false; }

    run "$LAUNCHER" detach "$PROJECT"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "refresh-toolchain succeeds on schema-2 primary and linked worktrees with surrounding exclude user lines" {
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attach_postjobs_at "$PROJECT"

  printf '# extra user exclude entry\n*.tmp-local\n' >> "$PROJECT/.git/info/exclude"

  local linked="$SANDBOX/linked-wt"
  git -C "$PROJECT" worktree add -q -b linked-branch "$linked"
  wait_for_attach_postjobs_at "$linked"

  # Linked worktree seeded via slow path (fast-path cleanly misses schema-3 manifest)
  [ -L "$linked/.agents/AGENTS.md" ]
  [ -f "$linked/.agents/hooks.json" ]
  [ -f "$linked/.opencode/opencode.json" ]

  local extra_bin="$SANDBOX/extra-toolchain-bin"
  mkdir -p "$extra_bin"

  # Refresh toolchain on primary worktree
  run env PATH="$extra_bin:/usr/bin:/bin" "$LAUNCHER" attach --refresh-toolchain "$PROJECT"
  [ "$status" -eq 0 ] || { echo "primary refresh-toolchain failed: $output"; false; }

  # Refresh toolchain on linked worktree (git_hooks.enabled == false)
  run env PATH="$extra_bin:/usr/bin:/bin" "$LAUNCHER" attach --refresh-toolchain "$linked"
  [ "$status" -eq 0 ] || { echo "linked refresh-toolchain failed: $output"; false; }

  local linked_id checkout_id linked_owner
  checkout_id="$(jq -r '.projects["personal/agy-state-fixture"].checkouts | keys[0]' "$TRELLIS_HOME/registry.json")"
  linked_id="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$linked")"
  linked_owner="$TRELLIS_HOME/state/attachments/$checkout_id/$linked_id.json"
  jq -e --arg bin "$extra_bin" '.git_hooks.enabled == false and (.toolchain_path | index($bin) != null)' "$linked_owner" >/dev/null
}

@test "release adopt preserves schema-2 owners, refuses sibling .opencode/opencode.jsonc, and refuses legacy Pi .agents/agents relocation" {
  local next_src="$SANDBOX/release-10"
  mkdir -p "$next_src"
  cp -R "$REPO_ROOT/core-rules" "$REPO_ROOT/scripts" "$next_src/"
  rm -rf "$next_src/core-rules/native"
  printf '10.0.0\n' > "$next_src/core-rules/VERSION"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 10.0.0 "$next_src"

  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attach_postjobs_at "$PROJECT"

  # Sibling JSONC blocks adopt
  printf '{}\n' > "$PROJECT/.opencode/opencode.jsonc"
  run "$LAUNCHER" release adopt 10.0.0 --project agy-state-fixture
  [ "$status" -eq 3 ]
  [[ "$output" == *".opencode/opencode.jsonc"* ]] || { echo "$output"; false; }
  rm -f "$PROJECT/.opencode/opencode.jsonc"

  # Clean adopt preserves schema_version == 2 and harnesses
  run "$LAUNCHER" release adopt 10.0.0 --project agy-state-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local owner
  owner="$(owner_file)"
  jq -e '.schema_version == 2 and .release == "10.0.0" and .harnesses == ["antigravity","opencode"]' "$owner" >/dev/null
  PAYLOAD="$TRELLIS_HOME/releases/10.0.0/payload" wait_for_attach_postjobs_at "$PROJECT" "$TRELLIS_HOME/releases/10.0.0/payload"
  run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project agy-state-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Legacy Pi owner with .agents/agents/* symlink is refused by release adopt with explicit detach+attach guidance
  local legacy_src="$SANDBOX/release-9-8-0" legacy_proj="$SANDBOX/legacy-pi-project"
  mkdir -p "$legacy_src" "$legacy_proj"
  cp -R "$REPO_ROOT/core-rules" "$REPO_ROOT/scripts" "$legacy_src/"
  rm -rf "$legacy_src/core-rules/native"
  printf '9.8.0\n' > "$legacy_src/core-rules/VERSION"
  jq '
    .schema_version = 2
    | del(.harnesses.antigravity, .harnesses.opencode)
    | .harnesses.shared_agents.links |= (
        map(select((has("consumers") | not) or (.consumers | index("pi") != null)) | del(.consumers, .deferrable))
        + [{source_children:"core-rules/pi/agents",destination_dir:".agents/agents",entry_type:"file",suffix:".md"}]
      )
    | .harnesses.shared_agents.render |= map(del(.consumers))
    | .harnesses.pi.links |= map(select((.destination_dir // "") != ".pi/agents"))
  ' "$REPO_ROOT/core-rules/inheritance-manifest.json" > "$legacy_src/core-rules/inheritance-manifest.json"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 9.8.0 "$legacy_src"

  git -C "$legacy_proj" init -q
  git -C "$legacy_proj" config user.email fixture@example.invalid
  git -C "$legacy_proj" config user.name Fixture
  printf '{"schema_version":1,"project_id":"legacy-pi-fixture"}\n' > "$legacy_proj/.trellis.json"
  git -C "$legacy_proj" add .trellis.json
  git -C "$legacy_proj" commit -qm init

  run "$LAUNCHER" attach --fleet personal --release 9.8.0 --harness pi "$legacy_proj"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attach_postjobs_at "$legacy_proj" "$TRELLIS_HOME/releases/9.8.0/payload"
  [ -L "$legacy_proj/.agents/agents/sol-rw.md" ]

  run "$LAUNCHER" release adopt 10.0.0 --project legacy-pi-fixture
  [ "$status" -eq 3 ]
  [[ "$output" == *"relocates the Pi roster from .agents/agents to .pi/agents"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis detach"* ]] || { echo "$output"; false; }

  # Multi-worktree 1.5.2 (CLAUDE.md fallback target) -> 10.0.0 (AGENTS.md fallback target) retargets cleanly and passes doctor
  local prev_src="$SANDBOX/release-9-7-0" retarget_proj="$SANDBOX/retarget-proj" retarget_wt="$SANDBOX/retarget-wt"
  mkdir -p "$prev_src" "$retarget_proj"
  cp -R "$REPO_ROOT/core-rules" "$REPO_ROOT/scripts" "$prev_src/"
  rm -rf "$prev_src/core-rules/native"
  printf '9.7.0\n' > "$prev_src/core-rules/VERSION"
  jq '
    .schema_version = 2
    | del(.harnesses.antigravity, .harnesses.opencode)
    | .harnesses.claude.links |= map(if .source == "core-rules/AGENTS.md" then .source = "core-rules/CLAUDE.md" else . end)
    | .harnesses.shared_agents.links |= (
        map(select(.destination != ".agents/AGENTS.md")
            | del(.consumers, .deferrable)
            | if .source == "core-rules/AGENTS.md" then .source = "core-rules/CLAUDE.md" else . end
            | if .fallback_source == "core-rules/AGENTS.md" then .fallback_source = "core-rules/CLAUDE.md" else . end)
      )
    | .harnesses.shared_agents.render |= map(del(.consumers))
  ' "$REPO_ROOT/core-rules/inheritance-manifest.json" > "$prev_src/core-rules/inheritance-manifest.json"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 9.7.0 "$prev_src"

  git -C "$retarget_proj" init -q
  git -C "$retarget_proj" config user.email fixture@example.invalid
  git -C "$retarget_proj" config user.name Fixture
  printf '{"schema_version":1,"project_id":"retarget-fixture"}\n' > "$retarget_proj/.trellis.json"
  git -C "$retarget_proj" add .trellis.json
  git -C "$retarget_proj" commit -qm init

  run "$LAUNCHER" attach --fleet personal --release 9.7.0 --harness claude --harness codex "$retarget_proj"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attach_postjobs_at "$retarget_proj" "$TRELLIS_HOME/releases/9.7.0/payload"
  git -C "$retarget_proj" worktree add -q -b wt-retarget "$retarget_wt"
  wait_for_attach_postjobs_at "$retarget_wt" "$TRELLIS_HOME/releases/9.7.0/payload"

  [ "$(readlink "$retarget_proj/AGENTS.md")" = ".trellis/runtime/core-rules/CLAUDE.md" ]
  [ "$(readlink "$retarget_proj/.claude/rules/trellis.md")" = "../../.trellis/runtime/core-rules/CLAUDE.md" ]
  [ "$(readlink "$retarget_wt/.agents/rules/trellis.md")" = "../../.trellis/runtime/core-rules/CLAUDE.md" ]

  run "$LAUNCHER" release adopt 10.0.0 --project retarget-fixture
  [ "$status" -eq 0 ] || { echo "retarget adopt failed: $output"; false; }
  [ "$(readlink "$retarget_proj/AGENTS.md")" = ".trellis/runtime/core-rules/AGENTS.md" ]
  [ "$(readlink "$retarget_proj/.claude/rules/trellis.md")" = "../../.trellis/runtime/core-rules/AGENTS.md" ]
  [ "$(readlink "$retarget_proj/.agents/rules/trellis.md")" = "../../.trellis/runtime/core-rules/AGENTS.md" ]
  [ "$(readlink "$retarget_wt/AGENTS.md")" = ".trellis/runtime/core-rules/AGENTS.md" ]
  [ "$(readlink "$retarget_wt/.claude/rules/trellis.md")" = "../../.trellis/runtime/core-rules/AGENTS.md" ]
  [ "$(readlink "$retarget_wt/.agents/rules/trellis.md")" = "../../.trellis/runtime/core-rules/AGENTS.md" ]

  run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project retarget-fixture
  [ "$status" -eq 0 ] || { echo "retarget doctor failed: $output"; false; }
}
