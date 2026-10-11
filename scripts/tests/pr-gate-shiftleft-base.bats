#!/usr/bin/env bats
# Spec 067 T12/T12b: literal PR flags and head-worktree base recording.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
HOOKS=("$REPO_ROOT/core-rules/hooks/pr-gate-shiftleft.sh"
       "$REPO_ROOT/core-rules/codex/hooks/pr-gate-shiftleft.sh")
DIFF_BASE="$REPO_ROOT/core-rules/skills/process-gate/scripts/lib/diff-base.sh"

fixture() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/session" "$dir/bin"
  dir="$(cd "$dir" && pwd -P)"
  SESSION="$dir/session"
  WT="$dir/pr"
  POISON="$dir/gh-called"
  git -C "$SESSION" init -q
  git -C "$SESSION" config user.email test@trellis.test
  git -C "$SESSION" config user.name 'Trellis test'
  git -C "$SESSION" commit --allow-empty -qm init
  git -C "$SESSION" branch -M main
  git -C "$SESSION" remote add origin https://github.com/current/repo.git
  git -C "$SESSION" checkout -qb feature/a
  git -C "$SESSION" commit --allow-empty -qm parent
  git -C "$SESSION" checkout -qb session
  git -C "$SESSION" commit --allow-empty -qm session
  git -C "$SESSION" -c core.hooksPath=/dev/null worktree add -q -b pr "$WT" feature/a
  printf 'change\n' > "$WT/pr-change"
  git -C "$WT" add pr-change
  git -C "$WT" commit -qm pr-change
  git -C "$SESSION" branch object-only pr
  # A raw "$X" really names a tree, so dropping literalness goes RED.
  git -C "$SESSION" -c core.hooksPath=/dev/null worktree add -q -b '$X' "$SESSION/\$X" pr
  mkdir -p "$WT/sub"
  cat > "$dir/bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'unexpected gh invocation\n' > "$PR_GATE_TEST_POISON"
exit 99
GH
  chmod +x "$dir/bin/gh"
  export PATH="$dir/bin:$PATH"
  export PR_GATE_TEST_POISON="$POISON"
  export CODEX_PROJECT_DIR="$SESSION" CLAUDE_PROJECT_DIR="$SESSION"
  unset PROCESS_GATE_RUNNER PR_GATE_SHIFTLEFT_RUNNER PR_GATE_SHIFTLEFT_RANGE
}

invoke() {
  local input
  input="$(jq -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run bash "$1" <<< "$input"
}

# What diff-base.sh resolves in the PR worktree from the recorded base.
resolved_from_head() {
  (cd "$WT" && . "$DIFF_BASE" && db_resolve --mode push && printf '%s %s' "$DB_SOURCE" "$DB_BASE_REF")
}

base_table() {
  local assertion="$1" hook command expected actual n=0
  for hook in "${HOOKS[@]}"; do
    while IFS='|' read -r command expected; do
      n=$((n + 1))
      fixture "base-$assertion-$n"
      invoke "$hook" "$command"
      case "$assertion" in
        record)
          actual="$(git -C "$SESSION" config --get branch.session.trellisPrBase || true)"
          [ "$actual" = "$expected" ] || return 1
          ;;
        network)
          [ ! -e "$POISON" ] || return 1
          ;;
      esac
    done <<'TABLE'
gh pr create --base feature/a|feature/a
gh pr create --base=feature/a|feature/a
gh pr create -B feature/a|feature/a
gh pr create -Bfeature/a|feature/a
gh pr create --draft --base feature/a --fill|feature/a
gh pr create --title hello --base feature/a --body text|feature/a
gh pr create --base "feature/a"|feature/a
gh pr create --fill && echo --base feature/a|
gh pr create --fill|
gh pr create --base "$X"|
gh pr create --title '--base' --body feature/a|
TABLE
  done
}

@test "T12: both tokenizers record only the same command's literal base" {
  base_table record || return 1
}

@test "T12: neither hook calls PATH-poisoned gh" {
  base_table network || return 1
}

head_table() {
  local outcome="$1" hook command actual n=0
  for hook in "${HOOKS[@]}"; do
    while IFS= read -r command; do
      n=$((n + 1))
      fixture "head-$outcome-$n"
      command="${command//WT/$WT}"
      invoke "$hook" "$command"
      case "$outcome" in
        recorded)
          [ "$(git -C "$WT" config --get branch.pr.trellisPrBase || true)" = feature/a ] || return 1
          [ -z "$(git -C "$SESSION" config --get branch.session.trellisPrBase || true)" ] || return 1
          [ "$(resolved_from_head)" = 'pr-cache feature/a' ] || return 1
          ;;
        skipped)
          actual="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
          [ "$actual" = 'pr-gate-shiftleft: cannot resolve the PR head; advisory skipped' ] || return 1
          ;;
      esac
    done <<< "$2"
  done
}

@test "T12b: leading cd records on the PR head, not the clean session" {
  head_table recorded $'cd WT && gh pr create --base feature/a\ncd ../pr && gh pr create --base feature/a\ncd "WT" && gh pr create --base feature/a' || return 1
}

@test "T12b: --head/-H record on the checked-out branch's worktree" {
  head_table recorded $'gh pr create --head pr --base feature/a\ngh pr create --head=pr --base feature/a\ngh pr create -H pr --base feature/a\ngh pr create -Hpr --base feature/a' || return 1
}

@test "T12b: leaked CLAUDE_PROJECT_DIR cannot redirect the recorded head" {
  head_table recorded 'cd WT && gh pr create --base feature/a' || return 1
}

@test "T12b: a subdirectory cd records on the worktree top level" {
  head_table recorded 'cd WT/sub && gh pr create --base feature/a' || return 1
}

@test "T12b: unreadable cd, object-only head and git -C cannot resolve" {
  head_table skipped $'cd "$X" && gh pr create\ngh pr create --head object-only\ngh pr create --head "$X"\ngit -C WT push && gh pr create' || return 1
}

@test "T12b: chained, later and subshell cd cannot resolve" {
  head_table skipped $'cd WT && cd WT/sub && gh pr create\ntrue && cd WT && gh pr create\n(cd WT && gh pr create)' || return 1
}

@test "T12b: another repository or fork head cannot resolve" {
  head_table skipped $'gh pr create -R other/repo\ngh pr create --repo=other/repo\ngh pr create --head fork:pr' || return 1
}

@test "T12b: git -C with an explicit checked-out head records on that head" {
  head_table recorded 'git -C WT push && gh pr create --head pr --base feature/a' || return 1
}

@test "T12b: --repo matching origin still records on the head" {
  head_table recorded 'gh pr create --head pr --repo current/repo --base feature/a' || return 1
}

@test "T12b: detached command directory without --head cannot resolve" {
  local hook actual n=0
  for hook in "${HOOKS[@]}"; do
    n=$((n + 1))
    fixture "detached-$n"
    git -C "$WT" -c core.hooksPath=/dev/null checkout -q --detach
    invoke "$hook" "cd $WT && gh pr create"
    actual="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [ "$actual" = 'pr-gate-shiftleft: cannot resolve the PR head; advisory skipped' ] || return 1
  done
}

@test "T12b: PR-base cache belongs to the resolved head branch" {
  local hook n=0
  for hook in "${HOOKS[@]}"; do
    n=$((n + 1))
    fixture "head-cache-$n"
    invoke "$hook" 'gh pr create --head pr --base feature/a'
    [ "$(git -C "$WT" config --get branch.pr.trellisPrBase)" = feature/a ] || return 1
  done
}
