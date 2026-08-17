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
scripts/trellis scripts/cmux-trellis-teams"
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
    # prose explaining the history does not match itself.
    run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/$consumer' | grep -nE \"find .*-name '..\\\\.sh'\""
    [ "$status" -ne 0 ] || { echo "$consumer grew its own find again: $output"; false; }
  done
}
