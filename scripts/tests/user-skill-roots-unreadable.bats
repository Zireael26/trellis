#!/usr/bin/env bats
# Synthetic account and Trellis homes; never read the operator's skill roots.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/skill-roots.XXXXXX")"; SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"
  ROOT="$HOME/.claude/skills"
  mkdir -p "$ROOT/unowned" "$TRELLIS_HOME"
  chmod 700 "$HOME" "$TRELLIS_HOME" "$ROOT"
  printf '{}\n' > "$TRELLIS_HOME/config.json"; chmod 600 "$TRELLIS_HOME/config.json"
  export HOME TRELLIS_HOME
  . "$REPO_ROOT/scripts/lib/health-checks.sh"
}
teardown() { [ -z "${SANDBOX:-}" ] || { chmod -R u+rwX "$SANDBOX"; rm -rf "${SANDBOX:?}"; }; }

@test "unreadable skill root warns with its path; an accessible empty root is clean" {
  [ "$(id -u)" -ne 0 ] || skip 'root can read mode-000 directories'
  chmod 000 "$ROOT"
  run hc_user_skill_roots "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"could not check"*"$ROOT"* ]] || { echo "$output"; false; }
  [[ "$output" != *"harness skill roots clean"* ]] || { echo "$output"; false; }
  chmod 700 "$ROOT"
  mv "$ROOT/unowned" "$SANDBOX/aside"
  run hc_user_skill_roots "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq 0 ] && [[ "$output" == *"harness skill roots clean"* ]] || { echo "$output"; false; }
}
