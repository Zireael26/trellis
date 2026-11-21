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
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agy-opencode-compat.XXXXXX")"
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
  printf '{"schema_version":1,"project_id":"agy-compat-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm initial
  LAUNCHER="$HOME/.local/bin/trellis"
  PAYLOAD="$TRELLIS_HOME/releases/9.9.9/payload"
}

wait_for_attach_postjobs() {
  python3 - "$TRELLIS_HOME" "$PAYLOAD/scripts/lib/attach-postjob.sh" "$PROJECT" <<'PY'
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
  wait_for_attach_postjobs || true
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

owner_file() {
  find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print | head -1
}

registry_harnesses() {
  jq -c '.projects["personal/agy-compat-fixture"].checkouts | to_entries[0].value.harnesses' "$TRELLIS_HOME/registry.json"
}

@test "antigravity solo attach materializes AGY surface, preserves root AGENTS.md, and passes bypass/doctor/seeder" {
  printf '# Project-owned instructions\n' > "$PROJECT/AGENTS.md"
  git -C "$PROJECT" add AGENTS.md
  git -C "$PROJECT" commit -qm "add project AGENTS.md"

  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["antigravity"]' ]

  local owner
  owner="$(owner_file)"
  jq -e '.schema_version == 2 and .harnesses == ["antigravity"] and .render_context != null' "$owner" >/dev/null
  [ -f "$PROJECT/AGENTS.md" ] && [ ! -L "$PROJECT/AGENTS.md" ]
  [ "$(cat "$PROJECT/AGENTS.md")" = '# Project-owned instructions' ]
  [ -L "$PROJECT/.agents/AGENTS.md" ]
  [ "$(readlink "$PROJECT/.agents/AGENTS.md")" = "../.trellis/runtime/core-rules/AGENTS.md" ]
  [ -L "$PROJECT/.agents/workflows/explore.md" ]
  [ -L "$PROJECT/.agents/skills/process-gate" ]
  [ -f "$PROJECT/.agents/primers/INDEX.md" ]
  [ -f "$PROJECT/.agents/hooks.json" ] && [ ! -L "$PROJECT/.agents/hooks.json" ]
  [ ! -e "$PROJECT/.agents/rules/trellis.md" ]
  [ ! -e "$PROJECT/.agents/commands" ]
  [ ! -e "$PROJECT/.agents/agents" ]
  [ ! -e "$PROJECT/.pi" ]
  [ ! -e "$PROJECT/.opencode" ]
  grep -Fxq '/.agents/hooks.json' "$PROJECT/.git/info/exclude"
  [ -z "$(git -C "$PROJECT" status --porcelain)" ]

  run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$REPO_ROOT/core-rules/skills/process-gate/scripts/check-bypass.sh" --range=HEAD..HEAD
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project agy-compat-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"harness-capability: antigravity installation=verified"* ]] || { echo "$output"; false; }

  run bash "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" --target "$PROJECT" --verify-only
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$PROJECT/.agents/hooks.json" ]
  [ ! -e "$PROJECT/.agents/AGENTS.md" ]
  [ -f "$PROJECT/AGENTS.md" ]
  [ "$(cat "$PROJECT/AGENTS.md")" = '# Project-owned instructions' ]
}

@test "antigravity .agents/hooks.json renders Option B native companion adapter and preserves unrelated named hooks" {
  local native_src="$SANDBOX/native-release" target_arch
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target_arch="aarch64-apple-darwin" ;;
    Linux:x86_64) target_arch="x86_64-unknown-linux-musl" ;;
    Linux:aarch64) target_arch="aarch64-unknown-linux-musl" ;;
    *) skip "unsupported test architecture" ;;
  esac

  mkdir -p "$native_src"
  cp -R "$REPO_ROOT/core-rules" "$REPO_ROOT/scripts" "$native_src/"
  printf '9.9.10\n' > "$native_src/core-rules/VERSION"

  local mock_bin="$SANDBOX/mock-trellis-hooks"
  cat > "$mock_bin" <<'SH'
#!/bin/sh
[ "$1" = "event" ] && [ "$2" = "antigravity" ] || exit 99
mode="allow"
if [ -f "$HOME/mock-mode" ]; then
  mode="$(cat "$HOME/mock-mode")"
fi
case "$mode" in
  allow)
    if [ "$3" = "PreToolUse" ]; then
      printf '{}\n'
    elif [ "$3" = "SessionStart" ]; then
      printf '{"injectSteps":[{"systemMessage":{"systemMessage":"ready"}}]}\n'
    else
      printf '{}\n'
    fi
    exit 11
    ;;
  noop)
    exit 10
    ;;
  deny)
    if [ "$3" = "PreToolUse" ]; then
      printf '{"decision":"deny","reason":"blocked by guard"}\n'
    elif [ "$3" = "Stop" ]; then
      printf '{"decision":"continue","reason":"missing receipt"}\n'
    else
      printf '{}\n'
    fi
    exit 11
    ;;
  crash)
    exit 12
    ;;
esac
SH
  chmod 500 "$mock_bin"
  local bin_sha bin_size adapter_sha adapter_size
  bin_sha="$(shasum -a 256 "$mock_bin" | awk '{print $1}')"
  bin_size="$(wc -c < "$mock_bin" | tr -d ' ')"
  adapter_sha="$(shasum -a 256 "$native_src/core-rules/native/hook-adapter.sh" | awk '{print $1}')"
  adapter_size="$(wc -c < "$native_src/core-rules/native/hook-adapter.sh" | tr -d ' ')"
  jq -n --arg ver "9.9.10" --arg arch "$target_arch" --arg sha "$bin_sha" --argjson size "$bin_size" \
    --arg asha "$adapter_sha" --argjson asize "$adapter_size" '{
      schema_version: 1,
      version: $ver,
      adapter: {path: "core-rules/native/hook-adapter.sh", sha256: $asha, size: $asize},
      assets: {($arch): {sha256: $sha, size: $size}}
    }' > "$native_src/core-rules/native/artifacts.json"
  mkdir -p "$TRELLIS_HOME/bin/native/9.9.10/$target_arch/$bin_sha"
  cp "$mock_bin" "$TRELLIS_HOME/bin/native/9.9.10/$target_arch/$bin_sha/trellis-hooks"
  chmod 500 "$TRELLIS_HOME/bin/native/9.9.10/$target_arch/$bin_sha/trellis-hooks"

  release_fixture_install "$HOME" "$TRELLIS_HOME" 9.9.10 "$native_src"

  mkdir -p "$PROJECT/.agents"
  printf '{"custom_suite":{"SessionStart":[{"command":"echo custom","timeout":15,"type":"command"}]}}\n' > "$PROJECT/.agents/hooks.json"
  chmod 640 "$PROJECT/.agents/hooks.json"

  run "$LAUNCHER" attach --fleet personal --release 9.9.10 --harness antigravity "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  jq -e '.custom_suite.SessionStart[0].command == "echo custom"' "$PROJECT/.agents/hooks.json" >/dev/null
  local pre_cmd stop_cmd inv_cmd start_cmd
  pre_cmd="$(jq -r '.trellis.PreToolUse[0].hooks[0].command' "$PROJECT/.agents/hooks.json")"
  stop_cmd="$(jq -r '.trellis.Stop[0].command' "$PROJECT/.agents/hooks.json")"
  inv_cmd="$(jq -r '.trellis.PreInvocation[0].command' "$PROJECT/.agents/hooks.json")"
  start_cmd="$(jq -r '.trellis.SessionStart[0].command' "$PROJECT/.agents/hooks.json")"
  [[ "$pre_cmd" == *"/bin/native/9.9.10/$target_arch/$bin_sha/trellis-hooks"* ]] || { echo "$pre_cmd"; false; }

  # Exit 11 neutral pass-through -> exit 0 with {}
  printf 'allow' > "$HOME/mock-mode"
  run /bin/sh -c "$pre_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]

  run /bin/sh -c "$start_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = '{"injectSteps":[{"systemMessage":{"systemMessage":"ready"}}]}' ]

  # Exit 10 -> explicit allow for PreToolUse, neutral {} for Stop, exit 0
  printf 'noop' > "$HOME/mock-mode"
  run /bin/sh -c "$pre_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = '{"decision":"allow"}' ]
  run /bin/sh -c "$stop_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]

  # Exit 12 -> fail-closed AGY JSON with exit 0
  printf 'crash' > "$HOME/mock-mode"
  run /bin/sh -c "$pre_cmd"
  [ "$status" -eq 0 ]
  jq -e '.decision == "deny" and (.reason | contains("status 12"))' <<< "$output" >/dev/null

  run /bin/sh -c "$stop_cmd"
  [ "$status" -eq 0 ]
  jq -e '.decision == "continue" and (.reason | contains("status 12"))' <<< "$output" >/dev/null

  run /bin/sh -c "$inv_cmd"
  [ "$status" -eq 0 ]
  jq -e '(has("terminationBehavior") | not) and (.injectSteps[0].errorMessage.userMessage | contains("status 12")) and (.systemMessage | contains("status 12"))' <<< "$output" >/dev/null

  PAYLOAD="$TRELLIS_HOME/releases/9.9.10/payload" wait_for_attach_postjobs
  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '(keys | sort) == ["custom_suite"] and .custom_suite.SessionStart[0].command == "echo custom"' "$PROJECT/.agents/hooks.json" >/dev/null
}

@test "opencode attach merges .opencode/opencode.json, allows root opencode.jsonc, and refuses sibling .opencode/opencode.jsonc" {
  printf '// root jsonc allowed\n{"theme":"dark"}\n' > "$PROJECT/opencode.jsonc"
  git -C "$PROJECT" add opencode.jsonc
  git -C "$PROJECT" commit -qm "add root opencode.jsonc"

  # Pre-existing sibling JSONC (regular and dangling symlink) refused before attach
  mkdir -p "$PROJECT/.opencode"
  printf '{"instructions":[]}\n' > "$PROJECT/.opencode/opencode.jsonc"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness opencode "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *".opencode/opencode.jsonc"* ]] || { echo "$output"; false; }

  rm -f "$PROJECT/.opencode/opencode.jsonc"
  ln -s "missing-target.jsonc" "$PROJECT/.opencode/opencode.jsonc"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness opencode "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *".opencode/opencode.jsonc"* ]] || { echo "$output"; false; }
  rm -f "$PROJECT/.opencode/opencode.jsonc"

  # Conflicting project-owned instructions key refused
  printf '{"instructions":["custom.md"]}\n' > "$PROJECT/.opencode/opencode.json"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness opencode "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"overlaps project-owned keys"* ]] || { echo "$output"; false; }

  # Non-overlapping project keys preserved and merged without launcher context
  printf '{"model":"google/gemini-2.5-pro"}\n' > "$PROJECT/.opencode/opencode.json"
  chmod 644 "$PROJECT/.opencode/opencode.json"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local owner
  owner="$(owner_file)"
  jq -e '.schema_version == 2 and .harnesses == ["opencode"] and .render_context == null' "$owner" >/dev/null
  jq -e '.model == "google/gemini-2.5-pro" and .instructions == [".agents/AGENTS.md"]' "$PROJECT/.opencode/opencode.json" >/dev/null
  [ ! -e "$PROJECT/.agents/workflows" ]
  [ ! -e "$PROJECT/.agents/hooks.json" ]
  [ -L "$PROJECT/.agents/AGENTS.md" ]

  # Post-attach dangling sibling .opencode/opencode.jsonc fails doctor, show-config, check-bypass, and seeder
  ln -s "nowhere.jsonc" "$PROJECT/.opencode/opencode.jsonc"
  run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project agy-compat-fixture
  [ "$status" -ne 0 ]
  run "$LAUNCHER" show-config --project agy-compat-fixture
  [ "$status" -ne 0 ]
  run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$REPO_ROOT/core-rules/skills/process-gate/scripts/check-bypass.sh" --range=HEAD..HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *".opencode/opencode.jsonc"* ]] || { echo "$output"; false; }
  run bash "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" --target "$PROJECT" --verify-only
  [ "$status" -ne 0 ]
  run bash "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" --target "$PROJECT"
  [ "$status" -eq 3 ]

  rm -f "$PROJECT/.opencode/opencode.jsonc"
  run bash "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project agy-compat-fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '. == {"model":"google/gemini-2.5-pro"}' "$PROJECT/.opencode/opencode.json" >/dev/null
}

@test "non-deferrable .agents/AGENTS.md refuses pre-existing authored file, symlink, and refresh-artifacts takeover" {
  mkdir -p "$PROJECT/.agents"
  printf '# authored nested agents\n' > "$PROJECT/.agents/AGENTS.md"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *".agents/AGENTS.md"* ]] || { echo "$output"; false; }

  rm -f "$PROJECT/.agents/AGENTS.md"
  ln -s "../.trellis/runtime/core-rules/AGENTS.md" "$PROJECT/.agents/AGENTS.md"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness opencode "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *".agents/AGENTS.md"* ]] || { echo "$output"; false; }
  rm -f "$PROJECT/.agents/AGENTS.md"

  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wait_for_attach_postjobs

  rm -f "$PROJECT/.agents/AGENTS.md"
  printf '# attempted tracked takeover\n' > "$PROJECT/.agents/AGENTS.md"
  git -C "$PROJECT" add -f .agents/AGENTS.md
  git -C "$PROJECT" commit -qm "attempt takeover"
  run "$LAUNCHER" attach --refresh-artifacts "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *".agents/AGENTS.md"* ]] || { echo "$output"; false; }
}

@test "legacy unowned Pi roster in .agents/agents is refused while project-authored AGY agents are allowed" {
  mkdir -p "$PROJECT/.agents/agents"
  printf '# Custom AGY subagent\n' > "$PROJECT/.agents/agents/custom-reviewer.md"
  git -C "$PROJECT" add .agents/agents/custom-reviewer.md
  git -C "$PROJECT" commit -qm "add custom agy agent"

  cp "$PAYLOAD/core-rules/pi/agents/sol-rw.md" "$PROJECT/.agents/agents/sol-rw.md"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *".agents/agents/sol-rw.md"* ]] || { echo "$output"; false; }

  rm -f "$PROJECT/.agents/agents/sol-rw.md"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PROJECT/.agents/agents/custom-reviewer.md" ]
  [ -L "$PROJECT/.pi/agents/sol-rw.md" ]
  [ ! -e "$PROJECT/.agents/agents/sol-rw.md" ]
}

@test "onboard-project.sh supports antigravity and opencode selectors, rejects agy alias, and preserves project AGENTS.md" {
  local fresh="$SANDBOX/fresh-onboard"
  mkdir -p "$fresh"
  git -C "$fresh" init -q
  git -C "$fresh" config user.email fixture@example.invalid
  git -C "$fresh" config user.name Fixture
  printf '# Fresh project AGENTS.md\n' > "$fresh/AGENTS.md"
  git -C "$fresh" add AGENTS.md
  git -C "$fresh" commit -qm init

  run bash "$REPO_ROOT/scripts/onboard-project.sh" --home "$TRELLIS_HOME" --fleet personal --release 9.9.9 --harness agy "$fresh"
  [ "$status" -eq 2 ]

  run bash "$REPO_ROOT/scripts/onboard-project.sh" --home "$TRELLIS_HOME" --fleet personal --release 9.9.9 \
    --harness antigravity --harness opencode --project-id fresh-onboard "$fresh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$fresh/.trellis.json" ]
  [ -f "$fresh/AGENTS.md" ] && [ ! -L "$fresh/AGENTS.md" ]
  [ -L "$fresh/.agents/AGENTS.md" ]
  [ -f "$fresh/.agents/hooks.json" ]
  [ -f "$fresh/.opencode/opencode.json" ]
  PROJECT="$fresh" wait_for_attach_postjobs
}

@test "hc_agy_version and hc_opencode_version enforce 1.5.9 and 2.0.25 floors" {
  local fake_bin="$SANDBOX/fake-clis"
  mkdir -p "$fake_bin"

  # Unselected + absent -> HC_INFO (3)
  run env PATH="/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_agy_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 3 ]
  run env PATH="/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_opencode_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 3 ]

  # Selected + absent -> HC_WARN (2)
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness antigravity --harness opencode "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env PATH="/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_agy_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 2 ]
  run env PATH="/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_opencode_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 2 ]

  # Below floor -> HC_WARN (2)
  printf '#!/bin/sh\necho "agy 1.5.8"\n' > "$fake_bin/agy"
  printf '#!/bin/sh\necho "2.0.24"\n' > "$fake_bin/opencode"
  chmod +x "$fake_bin/agy" "$fake_bin/opencode"
  run env PATH="$fake_bin:/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_agy_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 2 ]
  run env PATH="$fake_bin:/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_opencode_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 2 ]

  # At or above floor -> HC_OK (0)
  printf '#!/bin/sh\necho "agy 1.5.10"\n' > "$fake_bin/agy"
  printf '#!/bin/sh\necho "2.0.25"\n' > "$fake_bin/opencode"
  run env PATH="$fake_bin:/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_agy_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 0 ]
  run env PATH="$fake_bin:/usr/bin:/bin" bash -c '. "$1/scripts/lib/health-checks.sh"; hc_opencode_version "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/registry.json"
  [ "$status" -eq 0 ]
}
