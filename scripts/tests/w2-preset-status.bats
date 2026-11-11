#!/usr/bin/env bats
# Exercise the real rollout function with a controlled prior-release verifier.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-preset.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  PROJECT="$SANDBOX/project" PRESETS="$SANDBOX/new-presets" EXTRACT="$SANDBOX/functions.sh"
  mkdir -p "$PROJECT/.claude/rules" "$PRESETS"
  printf 'new preset\n' > "$PRESETS/code-review.md"
  python3 -I - "$REPO_ROOT/scripts/rollout-presets.sh" "$EXTRACT" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
a = source.index('verified_release_preset_target() {')
b = source.index('\n\nenter_preset_rules_dir()', a)
c = source.index('install_preset_symlink() (')
d = source.index('\n\nprune_stale_presets()', c)
Path(sys.argv[2]).write_text(source[a:b] + '\n' + source[c:d] + '\n')
PY
}

run_install() {
  run bash -c '
    . "$1"
    TRELLIS_EX_STATE=4 TRELLIS_EX_CONFLICT=3 TRELLIS_EX_UNAVAILABLE=5 DRY_RUN=true
    release_store_releases_dir() { printf "%s/releases\n" "$TRELLIS_HOME"; }
    release_store_locate() { printf "%s/releases/%s\n" "$TRELLIS_HOME" "$1"; }
    enter_preset_rules_dir() { cd "$1/$2/rules"; }
    install_preset_symlink "$2" .claude code-review "$3"
  ' _ "$EXTRACT" "$PROJECT" "$PRESETS"
}

@test "unverifiable previous release is an error rather than success" {
  old="$TRELLIS_HOME/releases/1.3.0/payload/core-rules/presets/code-review.md"
  ln -s "$old" "$PROJECT/.claude/rules/preset-code-review.md"
  run_install
  [ "$status" -eq 4 ] || { echo "verification error returned success: $output"; false; }
  [ "$(readlink "$PROJECT/.claude/rules/preset-code-review.md")" = "$old" ]
}

@test "foreign preset link remains an unchanged warning" {
  ln -s "$SANDBOX/foreign.md" "$PROJECT/.claude/rules/preset-code-review.md"
  run_install
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'WARN:'* ]] || { echo "$output"; false; }
  [ "$(readlink "$PROJECT/.claude/rules/preset-code-review.md")" = "$SANDBOX/foreign.md" ]
}
