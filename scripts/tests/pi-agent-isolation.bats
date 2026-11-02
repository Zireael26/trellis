#!/usr/bin/env bats
# RW roster metadata leaves the isolation choice to the caller. No Pi runtime
# or worktree behavior is exercised here.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
AGENTS="$REPO_ROOT/core-rules/pi/agents"

frontmatter_value() {
  awk -v wanted="$2" '
    NR == 1 { if ($0 != "---") exit 1; active = 1; next }
    active && $0 == "---" { exit }
    active {
      line = $0
      colon = index(line, ":")
      if (colon > 0) {
        key = substr(line, 1, colon - 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        if (key == wanted) {
          value = substr(line, colon + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          print value
          found = 1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$1"
}

@test "RW roster agents leave isolation unspecified" {
  for name in general-purpose haiku haiku-xhigh luna sol-rw; do
    run frontmatter_value "$AGENTS/$name.md" isolation
    [ "$status" -eq 1 ] || {
      printf '%s.md unexpectedly declares isolation: %s\n' "$name" "$output" >&2
      false
    }
  done
}

@test "RW descriptions do not promise forced worktree isolation" {
  for name in general-purpose haiku haiku-xhigh luna sol-rw; do
    run frontmatter_value "$AGENTS/$name.md" description
    [ "$status" -eq 0 ]
    [[ "$output" != *'Worktree-isolated'* ]]
  done
}

@test "live isolation probes explicitly request worktrees instead of relying on roster defaults" {
  run python3 - "$REPO_ROOT/core-rules/skills/herdr-foreman/tests/test_isolation_paths.sh" <<'PY'
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text()
requests = [line for line in text.splitlines() if re.match(r'\s*(prompt=|export PI_PROBE_PROMPT=)', line) and 'Call Agent exactly once' in line]
assert len(requests) == 3, requests
assert all('isolation worktree' in line for line in requests), requests
assert 'assert args["isolation"] == "worktree"' in text
assert 'assert nested[0]["input"]["isolation"] == "worktree"' in text
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "read-only roster agents retain explicit isolation off" {
  for name in Explore Plan astra-ro gemini-ro haiku-ro security-reviewer sol-ro; do
    run frontmatter_value "$AGENTS/$name.md" isolation
    [ "$status" -eq 0 ] || { printf '%s.md is missing isolation metadata\n' "$name" >&2; false; }
    [ "$output" = off ] || { printf '%s.md isolation is %s, expected off\n' "$name" "$output" >&2; false; }
  done
}
