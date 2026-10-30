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

@test "live tracked files contain no retired Sol reference" {
  run git -C "$ROOT" grep -n "$(printf '%s%s' 'gpt-6' '-sol')" -- ':!specs' ':!docs/adr' ':!research' ':!CHANGELOG.md'
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "Sol catalog and shipped pi agents pin GPT-6.1 at their existing efforts" {
  run python3 - "$ROOT/core-rules/skills/herdr-foreman/roles.json" "$ROOT/core-rules/pi/agents" <<'PY'
import json
import re
import sys
from pathlib import Path

roles_path, agent_dir = map(Path, sys.argv[1:])
roles = json.loads(roles_path.read_text())["agents"]
for agent, effort in (("sol", "high"), ("sol-xhigh", "xhigh"), ("sol-max", "max")):
    assert roles[agent]["model"] == f"openai-codex/gpt-6.1-sol:{effort}", roles[agent]
for name in ("sol-ro", "sol-rw"):
    text = (agent_dir / f"{name}.md").read_text()
    assert re.search(r"(?m)^model: openai-codex/gpt-6\.1-sol$", text), name
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
