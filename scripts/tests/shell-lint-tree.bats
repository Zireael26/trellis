#!/usr/bin/env bats
# What counts as "the repository's shell tree".
#
# `scripts/run-tests.sh` and `.github/workflows/shellcheck.yml` each carried
# their own copy of a suffix-only `find`, so every extensionless script was
# unlinted in both — the pre-push hooks that invoke the gates, both commit-msg
# hooks, and the `trellis` CLI entrypoint. The security-gate diff scanner then
# scoped itself to "the same tree the lint gate owns" on the strength of a
# comment claiming the whole shell tree was linted at severity=warning. It was
# not, and the files it was wrong about were the ones with the most authority.
#
# These cases pin both halves: the classifier (shebang, not suffix) and the fact
# that the real tree's extensionless scripts are actually enumerated.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LINTER="$REPO_ROOT/scripts/lint-shell-tree.sh"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$SANDBOX/core-rules/githooks" "$SANDBOX/core-rules/evals/seed" \
    "$SANDBOX/scripts" "$SANDBOX/scheduled-tasks" "$SANDBOX/local" \
    "$SANDBOX/.claude" "$SANDBOX/specs"
  cp "$LINTER" "$SANDBOX/scripts/lint-shell-tree.sh"
  cp "$REPO_ROOT/scripts/lint-shell-assignments.py" "$SANDBOX/scripts/lint-shell-assignments.py"
  # The sandbox has its own shell-tree inventory and no grandfathered hits.
  # Copying the real tree's baseline would instead leave every entry stale.
  printf '%s\n' '{"schema_version":1,"entries":[]}' > "$SANDBOX/scripts/lint-shell-assignments-baseline.json"
}

# $1 = repo-relative path, $2 = first line
plant() {
  mkdir -p "$SANDBOX/$(dirname "$1")"
  printf '%s\ntrue\n' "$2" > "$SANDBOX/$1"
  chmod +x "$SANDBOX/$1"
}

sandbox_list() {
  run bash -c "cd '$SANDBOX' && bash scripts/lint-shell-tree.sh --list"
}

@test "an extensionless script with a shell shebang is in the tree" {
  plant "core-rules/githooks/pre-push" "#!/usr/bin/env bash"
  plant "scripts/trellis" "#!/bin/sh"
  sandbox_list

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core-rules/githooks/pre-push"* ]] || { echo "$output"; false; }
  [[ "$output" == *"scripts/trellis"* ]] || { echo "$output"; false; }
}

@test "CRLF shell shebangs are classified without admitting non-shell scripts" {
  printf '#!/usr/bin/env bash\r\ntrue\r\n' > "$SANDBOX/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env python3\r\npass\r\n' > "$SANDBOX/scripts/report"
  sandbox_list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'core-rules/githooks/pre-push'* ]] || { echo "$output"; false; }
  [[ "$output" != *'scripts/report'* ]] || { echo "$output"; false; }
}

@test "an extensionless binary is skipped under a UTF-8 locale" {
  # macOS awk aborts on invalid multibyte input outside the C locale; the
  # shipped core-rules/native/*/trellis-hooks Mach-O broke the whole stage.
  plant core-rules/githooks/pre-push '#!/usr/bin/env bash'
  mkdir -p "$SANDBOX/core-rules/native/aarch64-apple-darwin"
  printf '\317\372\355\376\014\000\000\001\000\000\000\000\002\000\000\000' \
    > "$SANDBOX/core-rules/native/aarch64-apple-darwin/trellis-hooks"
  run bash -c "cd '$SANDBOX' && LC_ALL=en_US.UTF-8 bash scripts/lint-shell-tree.sh --list"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'core-rules/githooks/pre-push'* ]] || { echo "$output"; false; }
  [[ "$output" != *'trellis-hooks'* ]] || { echo "$output"; false; }
}

@test "shebang read and parser errors fail the enumeration" {
  local tool real
  plant core-rules/githooks/pre-push '#!/usr/bin/env bash'
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for tool in head awk; do
    real="$(command -v "$tool")"
    printf '#!/bin/bash\nexit 7\n' > "$BATS_TEST_TMPDIR/bin/$tool"
    chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
    run bash -c "cd '$SANDBOX' && PATH='$BATS_TEST_TMPDIR/bin:$PATH' bash scripts/lint-shell-tree.sh --list"
    [ "$status" -ne 0 ] || { echo "$tool failure was ignored: $output"; false; }
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/bin/$tool"
  done
  run bash -c "cd '$SANDBOX' && PATH='$BATS_TEST_TMPDIR/bin:$PATH' bash scripts/lint-shell-tree.sh --list"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'core-rules/githooks/pre-push'* ]] || false
}

@test "both find traversals fail closed in list and shellcheck modes" {
  local mode pass
  plant core-rules/githooks/pre-push '#!/usr/bin/env bash'
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\n/usr/bin/find "$@"\nfor arg in "$@"; do\n  if [ "$arg" = "$FAIL_ON" ]; then exit 7; fi\ndone\n' > "$BATS_TEST_TMPDIR/bin/find"
  chmod +x "$BATS_TEST_TMPDIR/bin/find"
  for mode in --list lint; do
    for pass in '*.sh' '!'; do
      run bash -c "cd '$SANDBOX' && PATH='$BATS_TEST_TMPDIR/bin:$PATH' FAIL_ON='$pass' bash scripts/lint-shell-tree.sh $([ "$mode" = --list ] && printf %s --list)"
      [ "$status" -ne 0 ] || { echo "$mode ignored find failure $pass: $output"; false; }
    done
  done
  run bash -c "cd '$SANDBOX' && PATH='$BATS_TEST_TMPDIR/bin:$PATH' FAIL_ON=never bash scripts/lint-shell-tree.sh --list"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an extensionless script with a non-shell shebang is not in the tree" {
  plant "scripts/report" "#!/usr/bin/env python3"
  plant "scripts/probe" "#!/usr/bin/env bats"
  plant "scripts/notes" "no shebang at all"
  sandbox_list

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"scripts/report"* ]] || { echo "$output"; false; }
  [[ "$output" != *"scripts/probe"* ]] || { echo "$output"; false; }
  [[ "$output" != *"scripts/notes"* ]] || { echo "$output"; false; }
}

@test "suffixed shell files stay in the tree and eval seeds stay out of it" {
  plant "scripts/helper.sh" "#!/usr/bin/env bash"
  plant "scripts/helper.bash" "#!/usr/bin/env bash"
  plant "core-rules/evals/seed/drifted.sh" "#!/usr/bin/env bash"
  plant "core-rules/evals/seed/pre-push" "#!/usr/bin/env bash"
  sandbox_list

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"scripts/helper.sh"* ]] || { echo "$output"; false; }
  [[ "$output" == *"scripts/helper.bash"* ]] || { echo "$output"; false; }
  [[ "$output" != *"core-rules/evals/seed/drifted.sh"* ]] || { echo "$output"; false; }
  [[ "$output" != *"core-rules/evals/seed/pre-push"* ]] || { echo "$output"; false; }
}

@test ".claude/worktrees is excluded from the shell tree" {
  # Suffixed, extensionless, and nested paths under .claude/worktrees must all be excluded,
  # while .claude/skills remains in the tree (the carve-out is precise, not a wholesale .claude drop).
  plant ".claude/worktrees/wf_fake/scripts/bad.sh" "#!/usr/bin/env bash"
  plant ".claude/worktrees/wf_fake/scripts/bad.bash" "#!/usr/bin/env bash"
  plant ".claude/worktrees/wf_fake/hooks/bad" "#!/usr/bin/env bash"
  plant ".claude/skills/foo/scripts/keep.sh" "#!/usr/bin/env bash"
  sandbox_list

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *".claude/worktrees/wf_fake/scripts/bad.sh"* ]] || { echo "$output"; false; }
  [[ "$output" != *".claude/worktrees/wf_fake/scripts/bad.bash"* ]] || { echo "$output"; false; }
  [[ "$output" != *".claude/worktrees/wf_fake/hooks/bad"* ]] || { echo "$output"; false; }
  [[ "$output" == *".claude/skills/foo/scripts/keep.sh"* ]] || { echo "$output"; false; }

  # A defect under .claude/worktrees must not fail the lint run (even at warning severity).
  mkdir -p "$SANDBOX/.claude/worktrees/wf_fake/scripts"
  printf '#!/usr/bin/env bash\nunused_here="value"\ntrue\n' > "$SANDBOX/.claude/worktrees/wf_fake/scripts/bad.sh"
  chmod +x "$SANDBOX/.claude/worktrees/wf_fake/scripts/bad.sh"
  run bash -c "cd '$SANDBOX' && bash scripts/lint-shell-tree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"wf_fake"* ]] || { echo "$output"; false; }
}

@test "a defect in an extensionless script fails the lint run" {
  # SC2034 is warning severity, so it lands inside the gate's floor — SC2086 and
  # friends are `info` and would not. Under the old suffix-only find this file
  # was invisible and the run was green either way.
  mkdir -p "$SANDBOX/core-rules/githooks"
  printf '#!/usr/bin/env bash\nunused_here="value"\ntrue\n' > "$SANDBOX/core-rules/githooks/pre-push"
  chmod +x "$SANDBOX/core-rules/githooks/pre-push"
  run bash -c "cd '$SANDBOX' && bash scripts/lint-shell-tree.sh"

  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core-rules/githooks/pre-push"* ]] || { echo "$output"; false; }
}

# The sandbox cases prove the classifier. This one proves the roots list still
# reaches the files the classifier was written for — a `find` root quietly
# dropped from the list would pass every case above.
@test "the live repository tree enumerates its extensionless scripts" {
  local expected missing=""
  expected="core-rules/githooks/pre-push core-rules/githooks/commit-msg
core-rules/githooks/post-checkout core-rules/husky/pre-push
core-rules/husky/pre-commit core-rules/husky/commit-msg
scripts/trellis"
  run bash -c "cd '$REPO_ROOT' && bash scripts/lint-shell-tree.sh --list"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local path
  for path in $expected; do
    [ -f "$REPO_ROOT/$path" ] || continue
    printf '%s\n' "$output" | grep -Fxq -- "$path" || missing="$missing $path"
  done
  [ -z "$missing" ] || { echo "not enumerated:$missing"; false; }
}

# Both gates must read the same enumeration. A second hand-kept `find` in either
# place is how the first one drifted.
@test "every shell-lint consumer delegates to the linter instead of its own find" {
  local consumer
  for consumer in scripts/run-tests.sh .github/workflows/shellcheck.yml \
    .claude/skills/process-gate-local/local.config.sh; do
    run grep -F 'scripts/lint-shell-tree.sh' "$REPO_ROOT/$consumer"
    [ "$status" -eq 0 ] || { echo "$consumer no longer calls lint-shell-tree.sh"; false; }

    # There were three hand-kept copies of the same suffix-only `find`, and each
    # one silently defined its own shell tree. Comments are stripped so the
    # prose explaining the history does not match itself. Lines are joined
    # before matching so a multi-line find (find ... \ newline \( -name '*.sh'
    # ...) cannot evade a line-based pattern, and the pattern requires a
    # literal '*.sh' argument, not a two-character suffix. It also catches
    # the unquoted \*.sh spelling and the case-insensitive -iname form.
    run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/$consumer' | tr '\n' ' ' | grep -qE \"find[[:space:]][^;]*-i?name[[:space:]][^[:space:]]*[*]\\\\.sh\""
    [ "$status" -ne 0 ] || { echo "$consumer grew its own find again"; false; }
  done
}

# GNU `stat -f` is --file-system: it prints a filesystem block on stdout and
# then fails, so a fallback inside the same substitution appends its answer to
# that block and a mode check never matches on Linux (detach-native, tick.sh).
# The fixtures spell the BSD probe STATF and write it out as `stat -f`, so this
# file does not itself carry the shape the live-tree lint rejects.
plant_stat() {
  local path="$1"
  shift
  mkdir -p "$SANDBOX/$(dirname "$path")"
  printf '%s\n' "$@" | sed 's/STATF/stat -f/g' > "$SANDBOX/$path"
}

@test "a BSD-first stat fallback inside one substitution fails the lint run, in shell and Bats" {
  plant_stat core-rules/skills/x/tick.sh '#!/usr/bin/env bash' 'f="$1"' \
    'chmod "$(STATF '"'%Lp'"' "$f" 2>/dev/null || echo 644)" "$f"'
  plant_stat scripts/tests/probe.bats '#!/usr/bin/env bats' '@test "t" {' \
    '  [ "$(STATF %Lp "$BATS_TEST_TMPDIR" 2>/dev/null || stat -c %a "$BATS_TEST_TMPDIR")" = 700 ]' \
    '  mode="$(/usr/bin/STATF %Lp "$BATS_TEST_TMPDIR" 2>/dev/null ||' \
    '    stat -c %a "$BATS_TEST_TMPDIR")"' '}'
  run bash -c "cd '$SANDBOX' && bash scripts/lint-shell-tree.sh"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core-rules/skills/x/tick.sh:3:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"scripts/tests/probe.bats:3:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"scripts/tests/probe.bats:4:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"BSD-first stat -f fallback inside one command substitution"* ]] || { echo "$output"; false; }
}

@test "GNU-first and separate-assignment stat probes pass the lint run" {
  plant_stat scripts/probe.sh '#!/usr/bin/env bash' 'f="$1"' \
    'mode="$(stat -c %a "$f" 2>/dev/null || STATF %Lp "$f")"' \
    'mode="$(STATF %Lp "$f" 2>/dev/null)" || mode="$(stat -c %a "$f" 2>/dev/null)" || mode=644' \
    'if mode="$(STATF %Lp "$f" 2>/dev/null)"; then printf "%s\n" "$mode"; fi' \
    '# a comment may name $(STATF %Lp f || stat -c %a f)'
  plant_stat scripts/tests/probe.bats '#!/usr/bin/env bats' '@test "t" {' \
    '  [ "$(stat -c %a "$BATS_TEST_TMPDIR" 2>/dev/null || STATF %Lp "$BATS_TEST_TMPDIR")" = 700 ]' '}'
  run bash -c "cd '$SANDBOX' && bash scripts/lint-shell-tree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
