#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/skill-size.sh"
CHECK="$REPO_ROOT/scripts/check-skill-sizes.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TMPDIR/skill-size.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  PROJECT="$SANDBOX/project with spaces"
  USER_HOME="$SANDBOX/user home"
  mkdir -p "$PROJECT" "$USER_HOME"
  # shellcheck disable=SC1090
  . "$LIB"
}

teardown() {
  rm -rf "${SANDBOX:?}"
}

make_skill() {
  local root="$1" bytes="${2:-1}"
  mkdir -p "$root"
  python3 - "$root/SKILL.md" "$bytes" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"a" * int(sys.argv[2]))
PY
}

make_named_skill() {
  local root="$1" name="$2"
  mkdir -p "$root"
  printf '%s\n' '---' "name: $name" '---' > "$root/SKILL.md"
}

@test "manifest check accepts under and exact budget, rejects one byte over" {
  make_skill "$SANDBOX/under" 65535
  make_skill "$SANDBOX/exact" 65536
  make_skill "$SANDBOX/over" 65537

  run skill_size_check_root "$SANDBOX/under"
  [ "$status" -eq 0 ]
  run skill_size_check_root "$SANDBOX/exact"
  [ "$status" -eq 0 ]
  run skill_size_check_root "$SANDBOX/over"
  [ "$status" -eq 1 ]
  [[ "$output" == *"65537 bytes; budget is 65536 bytes"* ]] || { echo "$output"; false; }
}

@test "over-budget manifests skip validation and custom budgets are honored in all copies" {
  make_skill "$SANDBOX/large" 25000000
  make_skill "$SANDBOX/custom" 65537
  printf '\377' | dd of="$SANDBOX/custom/SKILL.md" bs=1 seek=65536 conv=notrunc 2>/dev/null
  local lib
  for lib in "$LIB" "$REPO_ROOT/core-rules/hooks/lib/skill-size.sh" \
      "$REPO_ROOT/core-rules/codex/hooks/lib/skill-size.sh"; do
    # Fail if validation is invoked for an already-over-budget file, even if
    # a fast validator could scan it before the supervisor's deadline.
    run /bin/bash -c '
      . "$1"
      skill_size__valid_utf8() { echo "unexpected content scan" >&2; return 1; }
      skill_size_manifest_bytes "$2"
    ' _ "$lib" "$SANDBOX/large"
    [ "$status" -eq 0 ] || { echo "$lib scanned the large file: $output"; false; }
    [ "$output" = 25000000 ]
    run /bin/bash -c '. "$1"; skill_size_check_root "$2"' _ "$lib" "$SANDBOX/custom"
    [ "$status" -eq 1 ]
    [[ "$output" == *"65537 bytes; budget is 65536 bytes"* ]] || false
    run /bin/bash -c '. "$1"; skill_size_check_root "$2" 65537' _ "$lib" "$SANDBOX/custom"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not valid UTF-8"* ]] || false
    make_skill "$SANDBOX/custom" 65537
    run /bin/bash -c '. "$1"; skill_size_check_root "$2" 65537' _ "$lib" "$SANDBOX/custom"
    [ "$status" -eq 0 ]
    printf '\377' | dd of="$SANDBOX/custom/SKILL.md" bs=1 seek=65536 conv=notrunc 2>/dev/null
  done
}

@test "UTF-8 tools failing are refusals in all size copies" {
  make_skill "$SANDBOX/small" 32
  local lib tool
  for lib in "$LIB" "$REPO_ROOT/core-rules/hooks/lib/skill-size.sh" \
      "$REPO_ROOT/core-rules/codex/hooks/lib/skill-size.sh"; do
    for tool in iconv grep wc; do
      # The locale for external grep is now set by env after exec, so use an
      # executable PATH shim rather than an in-process shell-function override.
      mkdir -p "$SANDBOX/fail-bin"
      : > "$SANDBOX/fail.log"
      failure=1; [ "$tool" != grep ] || failure=2
      printf '#!/bin/sh\nprintf "%%s\\n" "$0" >> "$FAIL_LOG"\nexit %s\n' "$failure" > "$SANDBOX/fail-bin/$tool"
      chmod +x "$SANDBOX/fail-bin/$tool"
      run env PATH="$SANDBOX/fail-bin:$PATH" FAIL_LOG="$SANDBOX/fail.log" /bin/bash -c '
        . "$1"
        skill_size_manifest_bytes "$2"
      ' _ "$lib" "$SANDBOX/small"
      [ "$status" -eq 2 ] || { echo "$lib accepted failing $tool: $output"; false; }
      [ -s "$SANDBOX/fail.log" ] || { echo "$tool shim did not run"; false; }
      rm "$SANDBOX/fail-bin/$tool"
    done
  done
}

@test "manifest size counts UTF-8 bytes rather than characters" {
  mkdir -p "$SANDBOX/multibyte"
  python3 - "$SANDBOX/multibyte/SKILL.md" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text("é" * 32768, encoding="utf-8")
PY
  run skill_size_manifest_bytes "$SANDBOX/multibyte"
  [ "$status" -eq 0 ]
  [ "$output" = "65536" ]
}

@test "resolver discovers project, user, cache plugin, and marketplace plugin roots" {
  make_skill "$PROJECT/.claude/skills/project-skill"
  make_skill "$USER_HOME/.claude/skills/user-skill"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.2.3/skills/cache-skill"
  make_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/market/skills/market-skill"

  run skill_size_resolve_root project-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/project-skill" ]
  run skill_size_resolve_root user-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/skills/user-skill" ]
  run skill_size_resolve_root cache-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.2.3/skills/cache-skill" ]
  run skill_size_resolve_root market-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/market/skills/market-skill" ]
}

@test "resolver preserves spaces in roots and Skill names" {
  make_skill "$PROJECT/.claude/skills/skill with spaces"
  run skill_size_resolve_root "skill with spaces" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/skill with spaces" ]
}

@test "resolver applies project then user precedence" {
  make_skill "$PROJECT/.claude/skills/duplicate"
  make_skill "$USER_HOME/.claude/skills/duplicate"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/duplicate"
  make_skill "$USER_HOME/.claude/skills/user-wins"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/user-wins"
  run skill_size_resolve_root duplicate "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/duplicate" ]

  run skill_size_resolve_root user-wins "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/skills/user-wins" ]
}

@test "resolver fails closed for distinct duplicate Skill names at one precedence" {
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/duplicate"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/duplicate"
  run skill_size_resolve_root duplicate "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous Skill 'duplicate' (2 roots)"* ]] || { echo "$output"; false; }
}

@test "resolver deduplicates symlink aliases to the same physical Skill root" {
  make_skill "$USER_HOME/.claude/skills/shared"
  mkdir -p "$PROJECT/.claude/skills"
  ln -s "$USER_HOME/.claude/skills/shared" "$PROJECT/.claude/skills/shared"

  run skill_size_resolve_root shared "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/skills/shared" ]
}

@test "resolver matches declared frontmatter name and directory basename" {
  make_named_skill "$PROJECT/.claude/skills/directory-name" "declared-name"

  run skill_size_resolve_root declared-name "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/directory-name" ]

  run skill_size_resolve_root directory-name "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/directory-name" ]

  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/first-root" "declared-conflict"
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/second-root" "declared-conflict"
  run skill_size_resolve_root declared-conflict "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous Skill 'declared-conflict' (2 roots)"* ]] || { echo "$output"; false; }
}

@test "plugin-qualified resolution tries exact identity before final-colon suffix" {
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/first" "active-plugin:shared"
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/shared" "other-name"

  run skill_size_resolve_root "active-plugin:shared" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/first" ]

  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/three/1.0.0/skills/active-name" "plain-name"
  run skill_size_resolve_root "active-plugin:active-name" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/three/1.0.0/skills/active-name" ]
}

@test "cache wins over marketplace source while same-tier conflicts deny" {
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/shared"
  make_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/plugin/skills/shared"

  run skill_size_resolve_root shared "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/shared" ]

  make_skill "$USER_HOME/.claude/plugins/cache/other/plugin/1.0.0/skills/shared"
  run skill_size_resolve_root shared "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous Skill 'shared' (2 roots)"* ]] || { echo "$output"; false; }
}

@test "discovery excludes Cursor Windsurf and foreign nested skill trees" {
  make_skill "$USER_HOME/.cursor/skills/cursor-skill"
  make_skill "$USER_HOME/.windsurf/skills/windsurf-skill"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/foreign/.cursor/skills/nested-cursor"
  make_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/foreign/skills/nested-foreign"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/claude-skill"

  run skill_size_discover_roots "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/claude-skill"* ]] || { echo "$output"; false; }
  [[ "$output" != *"cursor-skill"* ]] || { echo "$output"; false; }
  [[ "$output" != *"windsurf-skill"* ]] || { echo "$output"; false; }
  [[ "$output" != *"nested-foreign"* ]] || { echo "$output"; false; }
}

@test "canonicalization rejects control-character roots without newline aliasing" {
  local plain="$SANDBOX/collision" newline_root="$SANDBOX/collision"$'\n'
  local tab_root="$SANDBOX/tab"$'\t'"root"
  make_skill "$plain"
  make_skill "$newline_root"
  make_skill "$tab_root"

  run skill_size__canonical_dir "$newline_root"
  [ "$status" -eq 1 ]
  run skill_size_check_root "$newline_root"
  [ "$status" -eq 2 ]
  run skill_size__canonical_dir "$tab_root"
  [ "$status" -eq 1 ]
  run skill_size__canonical_dir "$plain"
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]

  local control_project="$SANDBOX/control-project"$'\n'
  make_skill "$control_project/.claude/skills/anything"
  run skill_size_resolve_root anything "$control_project" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project directory"* ]] || { echo "$output"; false; }
}

@test "canonicalization and checker handle leading-dash roots literally" {
  local parent="$SANDBOX/dash-parent"
  mkdir -p "$parent"
  make_skill "$parent/-P/skill"

  run bash -c 'cd -- "$1" && . "$2" && skill_size__canonical_dir "-P"' _ "$parent" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "$parent/-P" ]

  run bash -c 'cd -- "$1" && "$2" "-P"' _ "$parent" "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK (1 Skill roots checked"* ]] || { echo "$output"; false; }
}

@test "library rejects missing roots, malformed names, invalid UTF-8, and invalid budgets" {
  run skill_size_check_root "$SANDBOX/missing"
  [ "$status" -eq 2 ]
  run skill_size_resolve_root "bad/name" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  make_skill "$SANDBOX/invalid-utf8"
  printf '\377' > "$SANDBOX/invalid-utf8/SKILL.md"
  run skill_size_check_root "$SANDBOX/invalid-utf8"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid UTF-8"* ]] || { echo "$output"; false; }
  run skill_size_check_root "$SANDBOX/invalid-utf8" nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"budget must be a positive integer"* ]] || { echo "$output"; false; }
}

@test "canonical checker passes bounded collections and hard-fails oversized Skills" {
  local collection="$SANDBOX/canonical skills"
  make_skill "$collection/ok" 65536
  run "$CHECK" "$collection"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK (1 Skill roots checked; budget 65536 bytes)"* ]] || { echo "$output"; false; }

  make_skill "$collection/too-large" 65537
  run "$CHECK" "$collection"
  [ "$status" -eq 1 ]
  [[ "$output" == *"too-large/SKILL.md is 65537 bytes"* ]] || { echo "$output"; false; }
  [[ "$output" == *"FAILED (2 Skill roots checked)"* ]] || { echo "$output"; false; }
}

@test "all size copies enforce Unicode scalar limits and exact-budget UTF-8" {
  make_skill "$SANDBOX/non-scalar" 1
  make_skill "$SANDBOX/non-scalar-after-nul" 1
  make_skill "$SANDBOX/obsolete-five-byte" 1
  make_skill "$SANDBOX/surrogate" 1
  make_skill "$SANDBOX/unicode-limits" 1
  make_skill "$SANDBOX/exact-invalid" 65536
  printf '\000\177\302\200\337\277\340\240\200\355\237\277\356\200\200\357\277\277\360\220\200\200\364\217\277\277' > "$SANDBOX/unicode-limits/SKILL.md"
  printf '\355\240\200' > "$SANDBOX/surrogate/SKILL.md"
  printf '\364\220\200\200' > "$SANDBOX/non-scalar/SKILL.md"
  printf '\000\364\277\277\277' > "$SANDBOX/non-scalar-after-nul/SKILL.md"
  printf '\370\210\200\200\200' > "$SANDBOX/obsolete-five-byte/SKILL.md"
  printf '\377' | dd of="$SANDBOX/exact-invalid/SKILL.md" bs=1 seek=65535 conv=notrunc 2>/dev/null
  local lib root
  for lib in "$LIB" "$REPO_ROOT/core-rules/hooks/lib/skill-size.sh" \
      "$REPO_ROOT/core-rules/codex/hooks/lib/skill-size.sh"; do
    run /bin/bash -c '. "$1"; skill_size_manifest_bytes "$2"' _ "$lib" "$SANDBOX/unicode-limits"
    [ "$status" -eq 0 ]
    [ "$output" = 26 ]
    for root in non-scalar non-scalar-after-nul obsolete-five-byte surrogate exact-invalid; do
      run /bin/bash -c '. "$1"; skill_size_manifest_bytes "$2"' _ "$lib" "$SANDBOX/$root"
      [ "$status" -eq 2 ] || { echo "$lib $root allowed: $output"; false; }
      [[ "$output" == *"not valid UTF-8"* ]] || false
    done
  done
}

@test "all size copies refuse when bash cannot create the root snapshot temp file" {
  [ "$(uname -s)" = Darwin ] || skip "macOS bash 3.2 temp-file regression"
  local profile='(version 1)(allow default)(deny file-write-create)' lib
  # Prove this process really cannot make a here-string, not just that the
  # guard refuses for some unrelated reason. Launch the sandbox only after
  # fixtures are written; Bats and its output capture remain outside it.
  run /usr/bin/sandbox-exec -p "$profile" /bin/bash -c 'cat <<< probe'
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot create temp file"* ]]
  make_skill "$PROJECT/.claude/skills/over" 65537
  for lib in "$LIB" "$REPO_ROOT/core-rules/hooks/lib/skill-size.sh" \
      "$REPO_ROOT/core-rules/codex/hooks/lib/skill-size.sh"; do
    run /usr/bin/sandbox-exec -p "$profile" /bin/bash -c \
      '. "$1"; skill_size_resolve_root over "$2" "$3"' _ "$lib" "$PROJECT" "$USER_HOME"
    [ "$status" -eq 2 ] || { echo "$lib did not refuse: $status $output"; false; }
  done
}

@test "canonical checker rejects a non-directory input" {
  printf 'not a directory\n' > "$SANDBOX/file"
  run "$CHECK" "$SANDBOX/file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a directory"* ]] || { echo "$output"; false; }
}

@test "all three size consumers discover once for qualified and missing names" {
  make_named_skill "$PROJECT/.claude/skills/target" target
  local lib name expected count
  for lib in "$LIB" "$REPO_ROOT/core-rules/hooks/lib/skill-size.sh" \
      "$REPO_ROOT/core-rules/codex/hooks/lib/skill-size.sh"; do
    for name in plugin:target plugin:missing; do
      : > "$SANDBOX/discoveries"
      run bash -c '
        . "$1"
        scan_log=$4; scan_root=$2
        skill_size__discover_ranked_roots() {
          printf "x\n" >> "$scan_log"
          printf "1\t%s\n" "$scan_root/.claude/skills/target"
        }
        skill_size_resolve_root "$5" "$2" "$3"
      ' _ "$lib" "$PROJECT" "$USER_HOME" "$SANDBOX/discoveries" "$name"
      if [ "$name" = plugin:target ]; then
        [ "$status" -eq 0 ]
        [ "$output" = "$PROJECT/.claude/skills/target" ]
      else
        [ "$status" -eq 1 ]
      fi
      count=$(wc -l < "$SANDBOX/discoveries" | tr -d ' ')
      [ "$count" -eq 1 ] || { echo "$lib $name scanned $count times"; false; }
    done
  done
}

@test "both preload consumers do not retry an already-resolved qualified miss" {
  local tree count
  for tree in hooks codex/hooks; do
    : > "$SANDBOX/lookups"
    run bash -c '
      . "$1/lib/skill-size.sh"
      . "$1/lib/skill-preload.sh"
      lookup_log=$4
      skill_size_resolve_root() { printf "x\n" >> "$lookup_log"; return 1; }
      skill_preload_check plugin:missing "$2" "$3"
    ' _ "$REPO_ROOT/core-rules/$tree" "$PROJECT" "$USER_HOME" "$SANDBOX/lookups"
    [ "$status" -eq 0 ]
    count=$(wc -l < "$SANDBOX/lookups" | tr -d ' ')
    [ "$count" -eq 1 ] || { echo "$tree made $count lookups"; false; }
  done
}

@test "three size copies and both preload consumers agree on names and budgets" {
  make_named_skill "$PROJECT/.claude/skills/first" shared
  make_named_skill "$USER_HOME/.claude/skills/first" shared
  make_named_skill "$USER_HOME/.claude/plugins/cache/v/a/1/skills/one" conflict
  make_named_skill "$USER_HOME/.claude/plugins/cache/v/b/1/skills/two" conflict
  make_skill "$PROJECT/.claude/skills/exact" 65536
  make_skill "$PROJECT/.claude/skills/over" 65537
  local lib tree name expected
  for lib in "$LIB" "$REPO_ROOT/core-rules/hooks/lib/skill-size.sh" \
      "$REPO_ROOT/core-rules/codex/hooks/lib/skill-size.sh"; do
    for name in shared plugin:shared unknown conflict plugin:conflict; do
      run bash -c '. "$1"; skill_size_resolve_root "$2" "$3" "$4"' _ "$lib" "$name" "$PROJECT" "$USER_HOME"
      case "$name" in
        shared|plugin:shared)
          [ "$status" -eq 0 ]
          [ "$output" = "$PROJECT/.claude/skills/first" ]
          ;;
        unknown) [ "$status" -eq 1 ] ;;
        conflict|plugin:conflict)
          [ "$status" -eq 2 ]
          run bash -c '. "$1"; skill_size_resolve_root "$2" "$3" "$4" detailed' _ "$lib" "$name" "$PROJECT" "$USER_HOME"
          [ "$status" -eq 3 ]
          ;;
      esac
    done
    run bash -c '. "$1"; skill_size_check_root "$2"' _ "$lib" "$PROJECT/.claude/skills/exact"
    [ "$status" -eq 0 ]
    run bash -c '. "$1"; skill_size_check_root "$2"' _ "$lib" "$PROJECT/.claude/skills/over"
    [ "$status" -eq 1 ]
  done
  for tree in hooks codex/hooks; do
    for name in shared plugin:shared unknown conflict plugin:conflict exact over; do
      run bash -c '. "$1/lib/skill-size.sh"; . "$1/lib/skill-preload.sh"; skill_preload_check "$2" "$3" "$4"' _ "$REPO_ROOT/core-rules/$tree" "$name" "$PROJECT" "$USER_HOME"
      case "$name" in
        conflict|plugin:conflict) [ "$status" -eq 2 ] ;;
        over) [ "$status" -eq 1 ] ;;
        *) [ "$status" -eq 0 ] ;;
      esac
    done
  done
}

# 1.5.1 / 1.5.0 known issue: Homebrew bash 5.3 under a Node parent (Pi) segfaults
# in a command substitution that pairs a temporary locale assignment with an
# input redirection, e.g. $(LC_ALL=C wc -c < file): about 7% of calls, each a
# spurious "could not measure" refusal. Product shell code must not use it.
@test "no product command substitution pairs a temporary LC_ assignment with an input redirection" {
  run python3 -I - "$REPO_ROOT" <<'PY'
import pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
names = subprocess.check_output(["git", "-C", str(root), "ls-files", "core-rules", "scripts"], text=True).split()
pattern = re.compile(r"\$\(\s*LC_[A-Z_]+=\S+\s[^)]*?(?<![<0-9])<(?![(<])")
bad = []
for name in names:
    if "/tests/" in name or not (name.endswith(".sh") or name.endswith(".bash")):
        continue
    for number, line in enumerate((root / name).read_text(errors="replace").splitlines(), 1):
        if not line.lstrip().startswith("#") and pattern.search(line):
            bad.append("%s:%d: %s" % (name, number, line.strip()))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the manifest measurement survives Homebrew bash 5.3 under a Node parent" {
  local brew_bash=/opt/homebrew/bin/bash node
  node="$(command -v node || true)"
  [ -x "$brew_bash" ] && [ -n "$node" ] || skip 'needs Homebrew bash and node (the Pi host shape)'
  make_skill "$PROJECT/.agents/skills/big" "$((SKILL_SIZE_BUDGET_BYTES + 1))"
  run "$node" -e '
const { spawnSync } = require("node:child_process");
const [bash, lib, dir] = process.argv.slice(1);
let fails = 0, sample = "";
for (let i = 0; i < 200; i++) {
  const r = spawnSync(bash, ["--noprofile", "--norc", "-c", "source \"$1\" && skill_size_manifest_bytes \"$2\"", "x", lib, dir],
    { encoding: "utf8", env: { PATH: "/usr/bin:/bin" } });
  if (r.status !== 0) { fails++; sample = `status=${r.status} ${r.stderr}`; }
}
console.log(`fails=${fails}/200 ${sample}`);
process.exit(fails ? 1 : 0);
' "$brew_bash" "$LIB" "$PROJECT/.agents/skills/big"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
