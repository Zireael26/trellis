#!/usr/bin/env bats
# Each fenced bash/sh block in a prompt file must parse on its own. Joining the
# blocks would let a later block close an earlier one and hide a broken snippet.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LINT="$REPO_ROOT/scripts/lint-prompt-shell-blocks.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/prompt-lint.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

@test "two blocks that only parse when joined are reported separately" {
  cat > "$SANDBOX/split.md" <<'MD'
```bash
if true; then
  echo a
```

later prose

```bash
fi
```
MD
  run bash "$LINT" "$SANDBOX/split.md"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"fail:"* ]] || { echo "$output"; false; }
}

@test "a single valid block passes" {
  cat > "$SANDBOX/valid.md" <<'MD'
```bash
if true; then
  echo a
fi
```
MD
  run bash "$LINT" "$SANDBOX/valid.md"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"1 bash/sh blocks scanned"* ]] || { echo "$output"; false; }
}
