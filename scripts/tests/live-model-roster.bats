#!/usr/bin/env bats
# Offline guard: dead free-tier routes and retired Sol pins cannot ship.

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

@test "shipped pi agents and foreman routes never pin free-tier models" {
  run python3 - "$ROOT/core-rules/pi/agents" "$ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import json
import re
import sys
from pathlib import Path

agent_dir, roles_file = map(Path, sys.argv[1:])
for path in sorted(agent_dir.rglob("*")):
    if not path.is_file():
        continue
    text = path.read_text()
    assert "-free" not in text, f"{path}: dead free-tier reference"
    match = re.search(r"(?m)^model:\s*(\S+)", text)
    assert match, f"{path}: missing model pin"
for name, details in json.loads(roles_file.read_text())["agents"].items():
    assert "-free" not in details["model"], f"{name}: {details['model']}"
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# sol_hits <repo>: tracked live lines naming the retired Sol model. A
# qualification run.json records a historical tree inventory, research paths
# included, so it is a record like research/ itself, never a live pin.
sol_hits() {
  git -C "$1" grep -n -E "$(printf '%s%s|%s%s' 'gpt-6' '-sol' 'gpt-6\.1' '-sol')" -- ':!specs' ':!docs/adr' ':!docs/plans' ':!docs/specs' ':!research' ':!CHANGELOG.md' ':!decisions-log.md' ':!follow-ups.md' ':!HANDOFF*' \
    ':!scripts/tests/fixtures/qualification/*/run.json'
}

@test "live tracked files contain no retired Sol reference" {
  run sol_hits "$ROOT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "a recorded tree inventory is not a live Sol reference, and a live pin still is" {
  local repo="$BATS_TEST_TMPDIR/repo" sol sol61
  sol="$(printf '%s%s' 'gpt-6' '-sol')"
  sol61="$(printf '%s%s' 'gpt-6.1' '-sol')"
  git init -q "$repo"
  mkdir -p "$repo/scripts/tests/fixtures/qualification/pinned-before" "$repo/core-rules/pi/agents"
  printf '{"path": "research/reports/%s.md"}\n' "$sol" > "$repo/scripts/tests/fixtures/qualification/pinned-before/run.json"
  printf 'model: openai-codex/gpt-6.2-sol\n' > "$repo/core-rules/pi/agents/sol-ro.md"
  git -C "$repo" add -A
  run sol_hits "$repo"
  [ "$status" -eq 1 ] || { echo "$output"; false; }

  for retired in "$sol" "$sol61"; do
    printf 'model: openai-codex/%s\n' "$retired" > "$repo/core-rules/pi/agents/sol-ro.md"
    git -C "$repo" add -A
    run sol_hits "$repo"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$output" = "core-rules/pi/agents/sol-ro.md:1:model: openai-codex/$retired" ] || { echo "$output"; false; }
  done
}

@test "Sol and Astra catalog and shipped pi agents pin GPT-6.2 at their existing efforts" {
  run python3 - "$ROOT/core-rules/skills/herdr-foreman/roles.json" "$ROOT/core-rules/pi/agents" <<'PY'
import json
import re
import sys
from pathlib import Path

roles_path, agent_dir = map(Path, sys.argv[1:])
roles = json.loads(roles_path.read_text())["agents"]
for agent, effort in (("sol-low", "low"), ("sol-medium", "medium"), ("sol", "high"), ("sol-xhigh", "xhigh")):
    assert roles[agent]["model"] == f"openai-codex/gpt-6.2-sol:{effort}", roles[agent]
assert "sol-max" not in roles
assert roles["astra"]["model"] == "openai-codex/gpt-6.2-astra:high", roles["astra"]
assert roles["astra-medium"]["model"] == "openai-codex/gpt-6.2-astra:medium", roles["astra-medium"]
for name in ("sol-ro", "sol-rw", "security-reviewer"):
    text = (agent_dir / f"{name}.md").read_text()
    assert re.search(r"(?m)^model: openai-codex/gpt-6\.2-sol$", text), name
astra_text = (agent_dir / "astra-ro.md").read_text()
assert re.search(r"(?m)^model: openai-codex/gpt-6\.2-astra$", astra_text), "astra-ro"
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
