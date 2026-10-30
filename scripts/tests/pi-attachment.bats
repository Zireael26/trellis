#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
# shellcheck source=helpers/release-fixture.bash
. "$REPO_ROOT/scripts/tests/helpers/release-fixture.bash"

setup_file() {
  # ONE bootstrapped machine with release 9.9.9 installed, built once per Bats
  # file. BATS_FILE_TMPDIR is created fresh for this invocation and removed with
  # the run, so the prototype cannot be reused across runs and has no staleness
  # window: full source input identity still holds every run.
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/prototype"
  mkdir -p "$RELEASE_FIXTURE_PROTOTYPE"
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$RELEASE_FIXTURE_PROTOTYPE")"
  export RELEASE_FIXTURE_PROTOTYPE
  release_fixture_prototype_build "$RELEASE_FIXTURE_PROTOTYPE"
}

teardown_file() {
  # The prototype carries the same sealed a-w tree a sandbox carries, so it
  # needs the same sweep before it can be removed.
  chmod -R u+w "$RELEASE_FIXTURE_PROTOTYPE" 2>/dev/null || true
  rm -rf "$RELEASE_FIXTURE_PROTOTYPE"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pi-attachment.XXXXXX")"
  SANDBOX="$(release_fixture_canonical_dir "$SANDBOX")"
  HOME="$SANDBOX/user"
  TRELLIS_HOME="$SANDBOX/trellis"
  RELEASE_SOURCE="$SANDBOX/release"
  PROJECT="$SANDBOX/project"
  export HOME TRELLIS_HOME
  # Isolate signing policy as well as HOME: the runner exports a global config
  # with commit.gpgSign=false, which makes a healthy bypass check WARN (exit 2).
  # Keep the exact pass/fail assertions; this suite tests Pi, not signing policy.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  # Independent PHYSICAL copy of the prototype: this case gets its own user
  # home, TRELLIS_HOME, release source and bootstrap source, and every absolute
  # path the prototype recorded is rewritten to this sandbox.
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
  # Doctor validates the configured management source, not just installed
  # releases. The minimal bootstrap source lacks this policy-checkout marker.
  cp "$REPO_ROOT/trellis.config.json" "$SANDBOX/bootstrap release source/trellis.config.json"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  printf '{"schema_version":1,"project_id":"pi-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm initial
  LAUNCHER="$HOME/.local/bin/trellis"
  PAYLOAD="$TRELLIS_HOME/releases/9.9.9/payload"
}

wait_for_attach_postjobs() {
  # These are detached grandchildren, so shell wait cannot reap them. Wait for
  # process exit, not lock removal: the EXIT trap removes scratch after the lock.
  python3 - "$TRELLIS_HOME" "$PAYLOAD/scripts/lib/attach-postjob.sh" "$PROJECT" <<'PY'
import errno
import os
from pathlib import Path
import select
import subprocess
import sys

home, postjob, project = sys.argv[1:]
pids = set()
for record in Path(home, "state/attachment-status").glob("*/*.job/pid"):
    try:
        fields = record.read_text().split()
        if fields:
            pids.add(int(fields[0]))
    except FileNotFoundError:
        pass  # The job finished while its lock was being inspected.
# Spawn returns before the child necessarily publishes its lock. The detached
# Perl child already exists then, and its argv includes these same exact paths.
for line in subprocess.check_output(["ps", "-axww", "-o", "pid=,command="], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and postjob in fields[1] and project in fields[1]:
        pids.add(int(fields[0]))

def still_our_job(pid):
    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                             stdout=subprocess.PIPE, text=True).stdout
    return postjob in command and project in command

for pid in pids - {os.getpid()}:
    try:
        if hasattr(os, "pidfd_open"):
            with os.fdopen(os.pidfd_open(pid), "rb") as process:
                if not still_our_job(pid):
                    continue  # A stale lock must not wait for an unrelated PID.
                poller = select.poll()
                poller.register(process, select.POLLIN)
                if not poller.poll(300000):
                    raise TimeoutError(f"attachment postjob {pid} did not exit")
        else:
            # select.kqueue is not a context manager, so close it explicitly.
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
  wait_for_attach_postjobs || return 1
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

owner_file() {
  find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print | head -1
}

registry_harnesses() {
  jq -c '.projects["personal/pi-fixture"].checkouts | to_entries[0].value.harnesses' "$TRELLIS_HOME/registry.json"
}

@test "release prototype copies isolate every regular inode and rebind each machine path" {
  local peer="$SANDBOX/peer"
  mkdir -p "$peer"
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$peer"
  run python3 - "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX" "$peer" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

prototype, first, second = map(Path, sys.argv[1:])
roots = ("user", "trellis", "release", "bootstrap release source")

def snapshot(root):
    rows = {}
    for name in roots:
        for path in (root / name).rglob("*"):
            relative = str(path.relative_to(root))
            mode = path.lstat().st_mode
            value = os.readlink(path) if stat.S_ISLNK(mode) else (
                hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(mode) else None
            )
            rows[relative] = (mode, value)
    return rows

baseline = snapshot(prototype)
peer_before = snapshot(second)
for relative in baseline:
    paths = [root / relative for root in (prototype, first, second)]
    infos = [path.lstat() for path in paths]
    if stat.S_ISREG(infos[0].st_mode):
        assert len({(info.st_dev, info.st_ino) for info in infos}) == 3, relative
for root in (first, second):
    config = json.loads((root / "trellis/config.json").read_bytes())
    assert config["source_root"] == str(root / "bootstrap release source")
    assert config["fleets"]["personal"]["discovery_roots"] == [str(root)]
    for version, source in (("0.0.0", "bootstrap release source"), ("9.9.9", "release")):
        record = json.loads((root / "trellis/releases" / version / "release.json").read_bytes())
        assert record["remote"] == str(root / source)
    for relative in baseline:
        path = root / relative
        if path.is_symlink():
            assert not os.readlink(path).startswith(str(prototype)), relative
        elif path.is_file():
            assert os.fsencode(prototype) not in path.read_bytes(), relative
victim = first / "trellis/releases/9.9.9/payload/core-rules/VERSION"
victim.chmod(victim.stat().st_mode | stat.S_IWUSR)
victim.write_text("corrupted copy\n")
assert snapshot(prototype) == baseline
assert snapshot(second) == peer_before
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$LAUNCHER" release verify 9.9.9
  [ "$status" -ne 0 ]
  run env HOME="$peer/user" TRELLIS_HOME="$peer/trellis" "$peer/user/.local/bin/trellis" release verify 9.9.9
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "pi-only attach registers pi and default detach removes every owned Pi and shared surface" {
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness pi "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(registry_harnesses)" = '["pi"]' ]
  [ -L "$PROJECT/.pi/extensions/trellis.ts" ]
  # Pi reserves .pi/hooks: attach renders nothing there.
  [ ! -e "$PROJECT/.pi/hooks" ]
  [ ! -L "$PROJECT/.pi/hooks" ]
  [ -L "$PROJECT/.agents/agents/sol-rw.md" ]

  local leaf
  jq -r '.artifacts[] | select(.kind != "parent" and .kind != "directory") | .path' \
    "$(owner_file)" > "$SANDBOX/pi-owned-leaves.before"
  [ -s "$SANDBOX/pi-owned-leaves.before" ]
  grep -Fxq .pi/extensions/trellis.ts "$SANDBOX/pi-owned-leaves.before"
  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/.pi/hooks" ]
  [ ! -L "$PROJECT/.pi/hooks" ]
  [ ! -e "$PROJECT/.pi/extensions/trellis.ts" ]
  [ ! -L "$PROJECT/.pi/extensions/trellis.ts" ]
  while IFS= read -r leaf; do
    [ ! -e "$PROJECT/$leaf" ]
    [ ! -L "$PROJECT/$leaf" ]
  done < "$SANDBOX/pi-owned-leaves.before"
  # Detach retains structural parents, not managed files or links.
  [ ! -L "$PROJECT/.pi" ]
  if [ -d "$PROJECT/.pi" ]; then
    [ -z "$(find "$PROJECT/.pi" \( -type l -o -type f \) -print)" ]
  fi
  [ ! -e "$PROJECT/.agents/agents/sol-rw.md" ]
  [ ! -L "$PROJECT/.agents/agents/sol-rw.md" ]
  [ ! -e "$PROJECT/.agents/rules/trellis.md" ]
  [ ! -L "$PROJECT/.agents/rules/trellis.md" ]
  [ ! -e "$PROJECT/AGENTS.md" ]
  [ ! -L "$PROJECT/AGENTS.md" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ ! -L "$PROJECT/.trellis/runtime" ]
  jq -e '[.. | objects | .attachment_id? // empty] | length == 0' "$TRELLIS_HOME/registry.json" >/dev/null
  jq -e '[.projects[].checkouts[].worktrees[]] | length == 1' "$TRELLIS_HOME/registry.json" >/dev/null
}

@test "mixed Codex and Pi attachment retains a project-authored shared policy as pre-existing" {
  mkdir -p "$PROJECT/.agents/rules"
  printf '# project-owned shared policy\n' > "$PROJECT/.agents/rules/trellis.md"

  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness codex --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["codex","pi"]' ]
  owner="$(owner_file)"
  jq -e '[.pre_existing[] | select(.path == ".agents/rules/trellis.md")] | length == 1' "$owner" >/dev/null
  [ "$(cat "$PROJECT/.agents/rules/trellis.md")" = '# project-owned shared policy' ]

  run "$LAUNCHER" detach --harness codex "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["pi"]' ]
  jq -e '[.pre_existing[] | select(.path == ".agents/rules/trellis.md")] | length == 1' "$owner" >/dev/null
  [ -L "$PROJECT/.pi/extensions/trellis.ts" ]

  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.agents/rules/trellis.md" ]
  [ ! -L "$PROJECT/.agents/rules/trellis.md" ]
  [ "$(cat "$PROJECT/.agents/rules/trellis.md")" = '# project-owned shared policy' ]
}

@test "three-harness detach of Codex retains Claude Pi and shared surfaces with registry agreement" {
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness claude --harness codex --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["claude","codex","pi"]' ]
  owner="$(owner_file)"
  jq 'del(.projects["personal/pi-fixture"].checkouts[].harnesses)' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-before.json"

  run "$LAUNCHER" detach --harness codex "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(registry_harnesses)" = '["claude","pi"]' ]
  jq 'del(.projects["personal/pi-fixture"].checkouts[].harnesses)' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-after.json"
  cmp "$SANDBOX/registry-before.json" "$SANDBOX/registry-after.json"
  [ "$(owner_file)" = "$owner" ]
  jq -e --slurpfile owner "$owner" '
    .projects["personal/pi-fixture"].checkouts[$owner[0].checkout_id]
    | .release == $owner[0].release
      and .worktrees[$owner[0].worktree_id].attachment_id == $owner[0].attachment_id
  ' "$TRELLIS_HOME/registry.json" >/dev/null
  jq -e 'all(.artifacts[], .pre_existing[]?; (.path | startswith(".codex/")) | not)' "$owner" >/dev/null
  jq -e '[.artifacts[].path]
    | any(startswith(".claude/")) and any(startswith(".pi/")) and any(. == "AGENTS.md")' "$owner" >/dev/null
  [ -L "$PROJECT/.claude/rules/trellis.md" ]
  [ -L "$PROJECT/.pi/extensions/trellis.ts" ]
  [ ! -e "$PROJECT/.pi/hooks" ]
  [ ! -L "$PROJECT/.pi/hooks" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  [ -L "$PROJECT/.agents/agents/sol-rw.md" ]
  [ -L "$PROJECT/AGENTS.md" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ ! -e "$PROJECT/.codex/hooks/lib/action-normalize.sh" ]
  [ ! -L "$PROJECT/.codex/hooks/lib/action-normalize.sh" ]
  [ ! -e "$PROJECT/.codex/hooks.json" ]
  [ ! -L "$PROJECT/.codex/hooks.json" ]
}

@test "single-owner partial Pi detach retains Codex and shared owned surfaces with registry agreement" {
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness codex --harness pi "$PROJECT"
  [ "$status" -eq 0 ]
  owner="$(owner_file)"
  jq 'del(.projects["personal/pi-fixture"].checkouts[].harnesses)' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-before.json"

  run "$LAUNCHER" detach --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["codex"]' ]
  jq 'del(.projects["personal/pi-fixture"].checkouts[].harnesses)' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-after.json"
  cmp "$SANDBOX/registry-before.json" "$SANDBOX/registry-after.json"
  jq -e 'all(.artifacts[], .pre_existing[]?; (.path | startswith(".pi/")) | not)' "$owner" >/dev/null
  [ -L "$PROJECT/.codex/hooks/lib/action-normalize.sh" ]
  [ ! -L "$PROJECT/.pi/extensions/trellis.ts" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  [ -L "$PROJECT/.trellis/runtime" ]
}

# These checks run the real standalone bypass and doctor readers, never the
# dispatcher: runtime denial is distinct from registration detection.
pi_aux_verdict() {
  local expected="$1" path="${2:-}" reason="${3:-}" bash_bin="/bin/bash"
  [ -x "$bash_bin" ] || bash_bin="bash"
  run env CODEX_PROJECT_DIR="$PROJECT" CLAUDE_PROJECT_DIR="$PROJECT" \
    "$bash_bin" "$REPO_ROOT/core-rules/skills/process-gate/scripts/check-bypass.sh" --range=HEAD..HEAD
  [ "$status" -eq "$expected" ] || { echo "$output"; false; }
  if [ "$expected" -ne 0 ]; then
    [[ "$output" == *"$path: native Pi hook artifact"*"$reason"* ]] || { echo "$output"; false; }
    [[ "$output" != *$'\n.pi/'* ]] || { echo "unindented Pi finding: $output"; false; }
  fi
  run "$bash_bin" "$REPO_ROOT/scripts/doctor.sh" --home "$TRELLIS_HOME" --project pi-fixture
  if [ "$expected" -eq 0 ]; then
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"owned artifacts, and managed hooks match"* ]]
  else
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    [[ "$output" == *"$path"*"$reason"* ]] || { echo "$output"; false; }
    if [ "$path" = .pi/extensions ] && [ -z "$reason" ]; then
      # A missing child must not mask missing/type-redirected literal parents.
      [[ "$output" == *"$path (recorded parent)"* || "$output" == *"$path: native Pi hook artifact"* ]]
    fi
  fi
}

pi_aux_attach() {
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  pi_aux_verdict 0
}

pi_aux_leaf_control() {
  local relative="$1" source
  pi_aux_attach
  jq -e --arg path "$relative" 'any(.artifacts[]; .path == $path and .kind == "symlink")' "$(owner_file)" >/dev/null
  source="$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PROJECT/$relative")"
  cp -p "$source" "$SANDBOX/aux-backup"
  chmod u+w "$source"
  printf '\n# hash mismatch: still nonempty\n' >> "$source"
  chmod a-w "$source"
  pi_aux_verdict 1 "$relative" 'payload content hash'
  chmod u+w "$source"
  cp -p "$SANDBOX/aux-backup" "$source"
  rm "$PROJECT/$relative"
  pi_aux_verdict 1 "$relative"
}

@test "Pi healthy attachment including literal parents passes bypass and doctor" {
  pi_aux_attach
  jq -e 'any(.artifacts[]; .path == ".pi/extensions" and .kind == "parent")' "$(owner_file)" >/dev/null
  local mode parent
  while IFS= read -r parent; do
    chgrp "$(id -g)" "$PROJECT/$parent"
  done < <(jq -r '.artifacts[] | select(.kind == "parent" and (.path | startswith(".pi/"))) | .path' "$(owner_file)")
  for mode in 0700 0755 2755; do
    while IFS= read -r parent; do
      chmod "$mode" "$PROJECT/$parent"
      [ "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o7777))' "$PROJECT/$parent")" = "0o${mode#0}" ] \
        || { echo "mode $mode did not stick on $parent"; false; }
    done < <(jq -r '.artifacts[] | select(.kind == "parent" and (.path | startswith(".pi/"))) | .path' "$(owner_file)")
    pi_aux_verdict 0
  done
}

pi_aux_deferred_fixture() {
  mkdir -p "$PROJECT/.pi/extensions"
  printf '// project-owned extension\n' > "$PROJECT/.pi/extensions/trellis.ts"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  pi_aux_verdict 1 .pi/extensions/trellis.ts 'deferred to project file — '
  jq -e 'any(.pre_existing[]; .path == ".pi/extensions/trellis.ts" and .kind == "symlink" and .reason == "project-authored-file")
    and (any(.artifacts[]; .path == ".pi/extensions/trellis.ts") | not)' "$(owner_file)" >/dev/null
  grep -Fxq '// project-owned extension' "$PROJECT/.pi/extensions/trellis.ts"
}

@test "Pi project-authored deferral fails both readers with a repair hint" {
  pi_aux_deferred_fixture
  printf '// edited project-owned extension\n' > "$PROJECT/.pi/extensions/trellis.ts"
  pi_aux_verdict 1 .pi/extensions/trellis.ts 'deferred to project file — symlink differs from owner; move the project file aside, then detach and attach again'
}

@test "Pi project-authored deferral repair via detach and attach passes both readers" {
  pi_aux_deferred_fixture
  mv "$PROJECT/.pi/extensions/trellis.ts" "$SANDBOX/project-trellis.ts"
  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e 'any(.artifacts[]; .path == ".pi/extensions/trellis.ts" and .kind == "symlink")
    and (any(.pre_existing[]; .path == ".pi/extensions/trellis.ts") | not)' "$(owner_file)" >/dev/null
  pi_aux_verdict 0
}

@test "Pi absent project-authored deferral has a distinct diagnostic in both readers" {
  pi_aux_deferred_fixture
  rm "$PROJECT/.pi/extensions/trellis.ts"
  pi_aux_verdict 1 .pi/extensions/trellis.ts 'deferred to project file — '
  : > "$PROJECT/.pi/extensions/trellis.ts"
  pi_aux_verdict 1 .pi/extensions/trellis.ts 'deferred to project file — '
  rm "$PROJECT/.pi/extensions/trellis.ts"
  ln -s "$PAYLOAD/core-rules/pi/extensions/trellis.ts" "$PROJECT/.pi/extensions/trellis.ts"
  pi_aux_verdict 1 .pi/extensions/trellis.ts 'deferred to project file — '
}

@test "Pi native registrations cannot defer to project-authored regular files" {
  mkdir -p "$PROJECT/.pi/extensions"
  printf 'project-authored native registration\n' > "$PROJECT/.pi/extensions/trellis.ts"
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e 'any(.pre_existing[]; .path == ".pi/extensions/trellis.ts" and .reason == "project-authored-file")' "$(owner_file)" >/dev/null
  pi_aux_verdict 1 .pi/extensions/trellis.ts 'deferred to project file — symlink differs from owner; move the project file aside, then detach and attach again'
}

@test "Pi extension removal and hash mismatch fail both readers" {
  pi_aux_leaf_control .pi/extensions/trellis.ts
}

@test "Pi literal parent removal fails both readers" {
  pi_aux_attach
  mv "$PROJECT/.pi/extensions" "$SANDBOX/saved-extensions"
  pi_aux_verdict 1 .pi/extensions
}

@test "Pi literal parent replaced by a file fails both readers" {
  pi_aux_attach
  mv "$PROJECT/.pi/extensions" "$SANDBOX/saved-extensions"
  printf 'not a directory\n' > "$PROJECT/.pi/extensions"
  pi_aux_verdict 1 .pi/extensions
}

@test "Pi literal parent unsafe mode fails both readers" {
  pi_aux_attach
  chmod 0777 "$PROJECT/.pi/extensions"
  pi_aux_verdict 1 .pi/extensions 'safe mode'
}

@test "Pi redirected parent fails despite intact linked extension bytes" {
  pi_aux_attach
  mkdir -p "$SANDBOX/decoy/.pi" "$SANDBOX/decoy/.trellis"
  ln -s "$PAYLOAD" "$SANDBOX/decoy/.trellis/runtime"
  mv "$PROJECT/.pi/extensions" "$SANDBOX/decoy/.pi/extensions"
  ln -s "$SANDBOX/decoy/.pi/extensions" "$PROJECT/.pi/extensions"
  [ -s "$PROJECT/.pi/extensions/trellis.ts" ]
  pi_aux_verdict 1 .pi/extensions
}
