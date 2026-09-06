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
  # Independent PHYSICAL copy of the prototype: this case gets its own user
  # home, TRELLIS_HOME, release source and bootstrap source, and every absolute
  # path the prototype recorded is rewritten to this sandbox.
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
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

teardown() {
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
  [ -L "$PROJECT/.pi/hooks/lib/action-normalize.sh" ]
  [ -L "$PROJECT/.agents/agents/sol-rw.md" ]

  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/.pi/extensions/trellis.ts" ] && [ ! -L "$PROJECT/.pi/extensions/trellis.ts" ]
  [ ! -e "$PROJECT/.pi/hooks/dispatch.sh" ] && [ ! -L "$PROJECT/.pi/hooks/dispatch.sh" ]
  [ ! -e "$PROJECT/.agents/agents/sol-rw.md" ] && [ ! -L "$PROJECT/.agents/agents/sol-rw.md" ]
  [ ! -e "$PROJECT/.agents/rules/trellis.md" ] && [ ! -L "$PROJECT/.agents/rules/trellis.md" ]
  [ ! -e "$PROJECT/AGENTS.md" ] && [ ! -L "$PROJECT/AGENTS.md" ]
  [ ! -e "$PROJECT/.trellis/runtime" ] && [ ! -L "$PROJECT/.trellis/runtime" ]
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
  [ -L "$PROJECT/.pi/hooks/lib/action-normalize.sh" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  [ -L "$PROJECT/.agents/agents/sol-rw.md" ]
  [ -L "$PROJECT/AGENTS.md" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ ! -e "$PROJECT/.codex/hooks/lib/action-normalize.sh" ] && [ ! -L "$PROJECT/.codex/hooks/lib/action-normalize.sh" ]
  [ ! -e "$PROJECT/.codex/hooks.json" ] && [ ! -L "$PROJECT/.codex/hooks.json" ]
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
