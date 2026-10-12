#!/usr/bin/env bats
# Gate-config approval (B0-4). A range that changes gate config is BLOCKED at
# merge unless the repo OWNER has posted `gate-config-approved: <head sha>` in
# a comment or non-dismissed review on the one open PR whose head is that SHA.
# The PR search must be complete, and the PR is re-checked (open, same head)
# when its bodies are read. A push that targets main/master is BLOCKED on a
# gate-config change whatever the approval. gh serves raw JSON (see
# config-fixture.bash), so run-all's own filters decide every case here.

load config-fixture

setup() {
  config_fixture_setup
}

# approval_fixture: base has no config; the feature branch adds a data config.
# HEAD_SHA is the gated head.
approval_fixture() {
  feature
  put "$CFG" $'PROCESS_GATE_PR_SIZE_LIMIT=900\n'
  commit_all 'raise the size limit' || return 1
  HEAD_SHA="$(head_sha)"
}

# approve <number> <state> <head-in-view> <author> <sha> [review-state]: one
# open-PR view whose body (a comment, or a review in review-state) carries
# the approval line.
approve() {
  local body
  body="$(printf 'Reviewed.\r\ngate-config-approved: %s\r\n' "$5")"
  if [ -n "${6:-}" ]; then
    gh_view "$1" "$2" "$3" '[]' "[$(review "$4" "$body" "$6")]"
  else
    gh_view "$1" "$2" "$3" "[$(comment some-agent LGTM),$(comment "$4" "$body")]"
  fi
}

@test "merge with the owner's approval for the head SHA proceeds and quotes it" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gate config approved on PR #42 by repo-owner (owner permission): \"gate-config-approved: $HEAD_SHA\""* ]] || { echo "$output"; false; }
}

@test "merge with the owner's approval for the wrong SHA is BLOCKED" {
  approval_fixture || return 1
  local base
  base="$(git -C "$PROJECT_DIR" rev-parse main)"
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$base"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 has an approval by repo-owner for another SHA: \"gate-config-approved: $base\""* ]] || { echo "$output"; false; }
  grep -q -- "--search $HEAD_SHA" "$GH_LOG" || { cat "$GH_LOG"; false; }
}

@test "merge with a non-owner's approval is BLOCKED" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" some-agent "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 has an approval by some-agent (not the repo owner repo-owner): \"gate-config-approved: $HEAD_SHA\""* ]] || { echo "$output"; false; }
}

@test "an owner approval in a dismissed review does not count; an approved review does" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA" DISMISSED
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 carries no approval line"* ]] || { echo "$output"; false; }

  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA" APPROVED
  run_gate merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "two open PRs at the gated head are BLOCKED" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA"),$(pr_row 43 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"
  approve 43 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"no single open PR has head $HEAD_SHA"* ]] || { echo "$output"; false; }
}

@test "search hits at other heads are ignored" {
  approval_fixture || return 1
  local near="${HEAD_SHA%?}0"
  [ "$near" != "$HEAD_SHA" ] || near="${HEAD_SHA%?}1"
  gh_prs "[$(pr_row 7 0000000000000000000000000000000000000007),$(pr_row 42 "$HEAD_SHA"),$(pr_row 9 "$near")]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gate config approved on PR #42 by repo-owner"* ]] || { echo "$output"; false; }
}

@test "a listed PR that is not OPEN is not the approval PR" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA" CLOSED)]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"no single open PR has head $HEAD_SHA"* ]] || { echo "$output"; false; }
}

@test "the approval PR is re-checked when its bodies are read" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 CLOSED "$HEAD_SHA" repo-owner "$HEAD_SHA"
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 is no longer open at head $HEAD_SHA"* ]] || { echo "$output"; false; }

  approve 42 OPEN 0000000000000000000000000000000000000042 repo-owner "$HEAD_SHA"
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 is no longer open at head $HEAD_SHA"* ]] || { echo "$output"; false; }
}

@test "a possibly truncated open-PR search is BLOCKED" {
  approval_fixture || return 1
  jq -n --arg h "$HEAD_SHA" \
    '[{number: 42, headRefOid: $h, state: "OPEN"}] + [range(1000) | {number: (. + 100), headRefOid: "0000", state: "OPEN"}]' \
    > "$GH_STUB_DIR/prs.json"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"may be truncated"* ]] || { echo "$output"; false; }
}

@test "an exported wc function cannot fake a single PR for the approval" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA"),$(pr_row 43 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"

  run bash -c "wc() { echo 1; }; export -f wc; cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"no single open PR has head $HEAD_SHA"* ]] || { echo "$output"; false; }
}

# A single-rev range is judged from that rev to the working tree; its approval
# binds to the rev, not to whatever HEAD the checkout is on.
@test "a single-rev merge run needs approval for that rev, not HEAD" {
  approval_fixture || return 1
  local rev="$HEAD_SHA" main_sha
  git -C "$PROJECT_DIR" checkout -q main
  main_sha="$(head_sha)"
  gh_prs "[$(pr_row 42 "$rev")]"
  approve 42 OPEN "$rev" repo-owner "$rev"

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=$rev"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"merge requires gate-config-approved: $rev"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gate config approved on PR #42 by repo-owner (owner permission): \"gate-config-approved: $rev\""* ]] || { echo "$output"; false; }
  ! grep -q -- "--search $main_sha" "$GH_LOG" || { cat "$GH_LOG"; false; }
}

@test "a direct main push that changes gate config with no PR is BLOCKED" {
  put "$CFG" $'PROCESS_GATE_PR_SIZE_LIMIT=900\n'
  commit_all 'config straight on main' || return 1
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"no single open PR has head $(head_sha)"* ]] || { echo "$output"; false; }
}

@test "--target=main BLOCKS a gate-config change even with a valid owner approval" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" repo-owner "$HEAD_SHA"

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD --target=main"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"a push that targets main/master cannot change gate config, approved or not"* ]] || { echo "$output"; false; }
}

# The carrier: a main-targeting push on the owner break-glass path, of a
# commit that is the head of an open PR the owner approved, is still refused.
@test "pre-push refuses a main-targeting gate-config push despite an approved open PR" {
  local hook new old
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.claude/skills"
  cp -R "$STUB" "$REPO/.claude/skills/process-gate"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email pre-push@test.invalid
  git -C "$REPO" config user.name pre-push-test
  git -C "$REPO" config commit.gpgsign false
  printf '/.claude/skills/process-gate/\n' > "$REPO/.git/info/exclude"
  git -C "$REPO" commit --allow-empty -qm base
  old="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.claude/skills/process-gate-local"
  printf 'PROCESS_GATE_PR_SIZE_LIMIT=900\n' > "$REPO/$CFG"
  git -C "$REPO" add "$CFG"
  git -C "$REPO" commit -qm 'gate config'
  new="$(git -C "$REPO" rev-parse HEAD)"
  gh_prs "[$(pr_row 42 "$new")]"
  approve 42 OPEN "$new" repo-owner "$new"

  # Control: the approval is valid for an ordinary merge-mode run.
  run bash -c "cd '$REPO' && CLAUDE_PROJECT_DIR='$REPO' '$REPO/.claude/skills/process-gate/scripts/run-all.sh' --mode=merge --range=$old..$new"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  printf 'refs/heads/main %s refs/heads/main %s\n' "$new" "$old" > "$BATS_TEST_TMPDIR/refs"
  for hook in "$REPO_ROOT/core-rules/githooks/pre-push" "$REPO_ROOT/core-rules/husky/pre-push"; do
    run_prepush "$hook" TRELLIS_ALLOW_MAIN_PUSH=1 CLAUDE_PROJECT_DIR="$REPO"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    [[ "$output" == *"a push that targets main/master cannot change gate config, approved or not"* ]] || { echo "$output"; false; }
  done
}

# .pi/** is gate config (B0-6): notice at push, BLOCKED at merge without the
# owner's approval, refused under --target=main.
# pi_case <display path>: the range on `feature` has already been committed.
pi_case() {
  local head
  head="$(head_sha)"
  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"gate config changed in range: gated with BASE config; merge requires gate-config-approved: $head"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"changed: $1"* || "$output" == *"changed: $(printf '%q' "$1")"* ]] || { echo "$output"; return 1; }

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"no single open PR has head $head"* ]] || { echo "$output"; return 1; }

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD --target=main"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"cannot change gate config, approved or not"* ]] || { echo "$output"; return 1; }
}

@test "adding .pi/subagents.json is a gate-config change" {
  feature
  put .pi/subagents.json $'{"agents":[]}\n'
  commit_all 'add pi subagents' || return 1
  pi_case .pi/subagents.json
}

@test "modifying .pi/extensions/x.ts is a gate-config change" {
  put .pi/extensions/x.ts $'export const x = 1;\n'
  commit_all 'pi extension' || return 1
  feature
  put .pi/extensions/x.ts $'export const x = 2;\n'
  commit_all 'change pi extension' || return 1
  pi_case .pi/extensions/x.ts
}

@test "deleting .pi/agents/a.md is a gate-config change" {
  put .pi/agents/a.md $'# agent a\n'
  commit_all 'pi agent' || return 1
  feature
  git -C "$PROJECT_DIR" rm -q .pi/agents/a.md
  commit_all 'drop pi agent' || return 1
  pi_case .pi/agents/a.md
}

@test "an unusually named file under .pi/ is a gate-config change" {
  feature
  put '.pi/agents/ré "q" x.md' $'# odd\n'
  commit_all 'odd pi file' || return 1
  pi_case '.pi/agents/ré "q" x.md'
}

@test "replacing .pi with a symlink is a gate-config change" {
  put .pi/agents/a.md $'# agent a\n'
  put elsewhere/agents/a.md $'# other a\n'
  commit_all 'pi agent and a lookalike' || return 1
  feature
  git -C "$PROJECT_DIR" rm -rq .pi
  ln -s elsewhere "$PROJECT_DIR/.pi"
  commit_all 'pi becomes a symlink' || return 1
  pi_case .pi
}

# Parity with the security gate's reserved namespace (is_security_config_path):
# its root scanner config and audits baselines are gate config here too, and
# the match is case-insensitive.
@test "security-gate config files and case variants are gate-config changes" {
  local path
  for path in .gitleaks.toml .gitleaksignore .semgrepignore osv-scanner.toml \
    audits/2026-01-01-baseline-x.json .PI/agents/a.md .Claude/skills/process-gate-local/x.sh \
    .agents/skills/security-gate-local/local.config.sh; do
    git -C "$PROJECT_DIR" checkout -q -B feature main
    put "$path" $'changed\n'
    commit_all "change $path" || return 1
    pi_case "$path" || { echo "path: $path"; return 1; }
  done
}

# The gate-local directories themselves (not only their descendants), in any
# case: a branch that adds one as a symlink changes nothing beneath it in Git.
# The link is written to the index directly, so the recorded path keeps its
# case on a case-insensitive filesystem.
@test "a gate-local directory added as a symlink is a gate-config change" {
  local path blob
  put elsewhere/local.config.sh $'PROCESS_GATE_PR_SIZE_LIMIT=1\n'
  commit_all 'a lookalike tree' || return 1
  blob="$(printf '../../elsewhere' | git -C "$PROJECT_DIR" hash-object -w --stdin)"
  for path in .claude/skills/security-gate-local .agents/skills/security-gate-local \
    .claude/skills/process-gate-local .agents/skills/process-gate-local \
    .Claude/Skills/Security-Gate-Local .CLAUDE/SKILLS/PROCESS-GATE-LOCAL; do
    git -C "$PROJECT_DIR" reset -q --hard main
    git -C "$PROJECT_DIR" checkout -q -B feature main
    git -C "$PROJECT_DIR" update-index --add --cacheinfo "120000,$blob,$path" || return 1
    git -C "$PROJECT_DIR" commit -qm "link $path" || return 1
    [ "$(git -C "$PROJECT_DIR" diff --name-only main HEAD)" = "$path" ] || return 1
    pi_case "$path" || { echo "path: $path"; return 1; }
  done
}

# B0-6 loader paths: pi and pi-subagents load these and pi can start in a
# subdirectory, so they are gate config at any depth; .trellis/ at the root.
@test "a nested sub/.pi/ file is a gate-config change" {
  feature
  put sub/.pi/x $'nested pi\n'
  commit_all 'nested pi' || return 1
  pi_case sub/.pi/x
}

@test ".agents/agents/ at any depth is gate config" {
  local path
  for path in .agents/agents/a.md sub/.agents/agents/a.md; do
    git -C "$PROJECT_DIR" checkout -q -B feature main
    put "$path" $'# agent\n'
    commit_all "add $path" || return 1
    pi_case "$path" || { echo "path: $path"; return 1; }
  done
}

@test ".agents/workflows/ at any depth is gate config" {
  local path
  for path in .agents/workflows/w.yml sub/.agents/workflows/w.yml; do
    git -C "$PROJECT_DIR" checkout -q -B feature main
    put "$path" $'steps: []\n'
    commit_all "add $path" || return 1
    pi_case "$path" || { echo "path: $path"; return 1; }
  done
}

@test ".agents/skills/ at any depth is gate config" {
  local path
  for path in .agents/skills/y/SKILL.md sub/.agents/skills/y/SKILL.md; do
    git -C "$PROJECT_DIR" checkout -q -B feature main
    put "$path" $'# skill\n'
    commit_all "add $path" || return 1
    pi_case "$path" || { echo "path: $path"; return 1; }
  done
}

@test "a branch-committed .trellis/ runtime anchor is gate config" {
  feature
  put .trellis/runtime/trellis.config.json $'{}\n'
  commit_all 'fake runtime anchor' || return 1
  pi_case .trellis/runtime/trellis.config.json
}

# Approval controls: a root scanner file and an upper-case .PI path merge with
# the owner's approval at the head and are BLOCKED without it.
approval_control() {
  local head
  feature
  put "$1" $'changed\n'
  commit_all "change $1" || return 1
  head="$(head_sha)"
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"changed: $1"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"no single open PR has head $head"* ]] || { echo "$output"; return 1; }

  gh_prs "[$(pr_row 42 "$head")]"
  approve 42 OPEN "$head" repo-owner "$head"
  run_gate merge
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"gate config approved on PR #42 by repo-owner (owner permission): \"gate-config-approved: $head\""* ]] || { echo "$output"; return 1; }
}

@test "a root scanner config change merges only with the owner's approval" {
  approval_control .semgrepignore
}

@test "an upper-case .PI change merges only with the owner's approval" {
  approval_control .PI/agents/a.md
}

# .envrc and .env* (any depth, any case) can set HOME, TRELLIS_HOME,
# PI_CODING_AGENT_DIR or PATH for the pi launchers: gate config by path only.
# Their contents are never read.
@test "a nested sub/.envrc is a gate-config change" {
  feature
  put sub/.envrc $'export FIXTURE=1\n'
  commit_all 'nested envrc' || return 1
  pi_case sub/.envrc
}

@test "a root .env.local is a gate-config change" {
  feature
  put .env.local $'FIXTURE=1\n'
  commit_all 'root env file' || return 1
  pi_case .env.local
}

# Each failure branch of the approval lookup, pinned by its own reason, so
# deleting any one of them turns a test red.
@test "merge without gh on PATH is BLOCKED" {
  approval_fixture || return 1
  local tb="$BATS_TEST_TMPDIR/toolbox" tool
  mkdir -p "$tb"
  for tool in bash env git mktemp rm mkdir sed cat dirname chmod tr; do
    ln -s "$(type -P "$tool")" "$tb/$tool"
  done
  # The interpreter itself: a version-manager shim needs its own PATH.
  ln -s "$(python3 -I -c 'import sys; print(sys.executable)')" "$tb/python3"
  run env PATH="$tb" bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"; gh is unavailable"* ]] || { echo "$output"; false; }
}

# jq -r prints a missing login as the string "null"; a null owner must not
# match a null-author (deleted account) approval.
@test "an unreadable repo owner is BLOCKED, even against a null-author approval" {
  approval_fixture || return 1
  printf '{}\n' > "$GH_STUB_DIR/repo.json"
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  gh_view 42 OPEN "$HEAD_SHA" "[{\"author\":null,\"body\":\"gate-config-approved: $HEAD_SHA\"}]"
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"; gh could not read the repo owner"* ]] || { echo "$output"; false; }
}

@test "a null-author approval never matches a readable owner" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  gh_view 42 OPEN "$HEAD_SHA" "[{\"author\":null,\"body\":\"gate-config-approved: $HEAD_SHA\"}]"
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"approval by (deleted) (not the repo owner repo-owner)"* ]] || { echo "$output"; false; }
}

@test "an unparseable open-PR list is BLOCKED" {
  approval_fixture || return 1
  printf 'not json\n' > "$GH_STUB_DIR/prs.json"
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"; gh could not list open PRs"* ]] || { echo "$output"; false; }
}

@test "an unreadable approval PR is BLOCKED" {
  approval_fixture || return 1
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"; gh could not read PR #42"* ]] || { echo "$output"; false; }
}

# BGSEC-C: a case-insensitive filesystem folds more than nocasematch does.
# index_case <path>: on a fresh feature branch, commit one file at exactly
# <path> through the index (no filesystem name folding, no NFC
# precomposition of the argument), then pi_case it.
index_case() {
  local blob
  git -C "$PROJECT_DIR" reset -q --hard main
  git -C "$PROJECT_DIR" checkout -q -B feature main
  blob="$(printf 'loaded\n' | git -C "$PROJECT_DIR" hash-object -w --stdin)"
  git -C "$PROJECT_DIR" -c core.precomposeunicode=false update-index --add --cacheinfo "100644,$blob,$1" || return 1
  git -C "$PROJECT_DIR" commit -qm "add $1" || return 1
  [ "$(git -C "$PROJECT_DIR" -c core.quotePath=false -c core.precomposeunicode=false diff --name-only main HEAD)" = "$1" ] || return 1
  pi_case "$1"
}

@test "a long-s alias of a reserved directory is gate config" {
  local path
  for path in '.agents/ſkills/evil/SKILL.md' '.agentſ/agents/x.md' '.trelliſ/runtime'; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

# Outside dot directories too.
@test "a long-s alias outside dot directories is gate config" {
  local path
  for path in 'auditſ/2026-01-01-baseline-x.json' 'sub/secrets-allowliſt.txt'; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

@test "a Kelvin-sign (U+212A) alias is gate config under LC_ALL=C" {
  export LC_ALL=C
  local path
  for path in '.agents/sKills/x' 'sub/.agents/sKills/x'; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

@test "fullwidth and compatibility forms of a reserved directory are gate config" {
  local path
  for path in '.ｐｉ/x' 'sub/.ｐｉ/x' '．pi/x' 'sub/．pi/x' '.agents/ｓｋｉｌｌｓ/y/SKILL.md'; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

@test "a Cyrillic look-alike in or under a dot segment is gate config" {
  local path
  for path in '.аgents/skills/x' '.рi/x' '.agents/ѕkills/x' 'sub/.agents/ѕkills/y'; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

# Release-owner ruling: a non-ASCII byte anywhere makes a path gate config:
# long s, fullwidth, Kelvin sign, Cyrillic, one dot leader, zero-width space,
# BOM, variation selector, combining acute and Hangul filler.
@test "a path with any non-ASCII byte, anywhere, is gate config" {
  local path
  for path in 'docs/ſ.md' 'docs/ｘ.md' 'docs/K.md' 'docs/а.md' \
    '․pi/x' 'docs/​x.md' '﻿.agents/skills/x' 'docs/x️.md' \
    'docs/é.md' 'docs/ㅤx.md'; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

@test "a Cyrillic look-alike merges only with the owner's approval" {
  approval_control '.аgents/skills/x/SKILL.md'
}

# Control: an ASCII path outside the protected set is not gate config.
@test "an ASCII path outside the protected set is not gate config" {
  feature
  put docs/cafe.md $'notes\n'
  put src/agents/skills.txt $'notes\n'
  commit_all 'ascii docs' || return 1
  run_gate merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"gate config changed"* ]] || { echo "$output"; false; }
}

# .trellis.json's template.branch steers the diff base.
@test "the root .trellis.json is gate config" {
  put .trellis.json $'{}\n'
  commit_all 'trellis config' || return 1
  feature
  put .trellis.json $'{"template":{"branch":"HEAD"}}\n'
  commit_all 'steer the diff base' || return 1
  pi_case .trellis.json
}

# .trellis.json and .trellis/ at any depth, after the same fold.
@test ".trellis.json and .trellis/ at any depth, any case or width, are gate config" {
  local path
  for path in sub/.trellis.json .TRELLIS.json '．trellis.json' 'sub/．trellis.json' sub/.trellis/runtime; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

# BGSEC-B: baselines in the security gate's configured audit dir.
@test "a baseline in the base-configured SECURITY_GATE_AUDIT_DIR is gate config" {
  put .claude/skills/security-gate-local/local.config.sh $'SECURITY_GATE_AUDIT_DIR="security/audits/"\n'
  put security/audits/2026-01-01-baseline-x.json $'{"findings":[]}\n'
  commit_all 'custom audit dir' || return 1
  feature
  put security/audits/2026-01-01-baseline-x.json $'{"findings":[{"id":"predeclared"}]}\n'
  commit_all 'predeclare a finding' || return 1
  pi_case security/audits/2026-01-01-baseline-x.json
}

# audit_dir_case <config-line> <baseline-path>...: the base security-gate
# config holds <config-line>; each path, committed alone on a fresh feature
# branch, is gate config.
audit_dir_case() {
  local line="$1" path
  shift
  put .claude/skills/security-gate-local/local.config.sh "$line"$'\n'
  commit_all 'security-gate config' || return 1
  for path in "$@"; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

# The audit dir is read with the security gate's own data grammar
# (parse_config_data): what it reads, this reads.
@test "a quoted SECURITY_GATE_AUDIT_DIR is read as the security gate reads it" {
  audit_dir_case 'SECURITY_GATE_AUDIT_DIR="sec/audits"' sec/audits/2026-01-01-baseline-x.json
}

@test "a single-quoted SECURITY_GATE_AUDIT_DIR with a trailing comment is read" {
  audit_dir_case "SECURITY_GATE_AUDIT_DIR='sec/audits'  # moved" sec/audits/2026-01-01-baseline-x.json
}

@test "a default-preserving SECURITY_GATE_AUDIT_DIR is read" {
  audit_dir_case 'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR:-sec/audits}"' \
    sec/audits/2026-01-01-baseline-x.json
}

# Not data for the security gate: every *-baseline-*.json at any depth is gate
# config.
@test "an export-form SECURITY_GATE_AUDIT_DIR makes every baseline gate config" {
  audit_dir_case 'export SECURITY_GATE_AUDIT_DIR=sec/audits' \
    sec/audits/2026-01-01-baseline-x.json deep/er/2026-01-01-baseline-y.json
}

@test "an unparsable SECURITY_GATE_AUDIT_DIR makes every baseline gate config" {
  audit_dir_case 'SECURITY_GATE_AUDIT_DIR=$(pwd)/audits' \
    audits/2026-01-01-baseline-x.json deep/er/2026-01-01-baseline-y.json
}

@test "another line that is not data makes every baseline gate config" {
  audit_dir_case $'SECURITY_GATE_AUDIT_DIR=sec/audits\nSECURITY_GATE_X=${HOME}' \
    deep/er/2026-01-01-baseline-y.json
}

@test "a case or Unicode variant of a configured baseline path is gate config" {
  audit_dir_case 'SECURITY_GATE_AUDIT_DIR=sec/audits' \
    'SEC/Audits/2026-01-01-BASELINE-x.JSON' 'ſec/audits/2026-01-01-baseline-x.json'
}

# The configured dir is folded too, as run-diff folds it: a case-insensitive
# checkout reads `ſec/` through `sec/`, so an ASCII baseline there counts.
@test "a long-s or fullwidth configured audit dir covers its ASCII fold" {
  audit_dir_case 'SECURITY_GATE_AUDIT_DIR="ſec/ａudits"' sec/audits/2026-01-01-baseline-x.json
}

# A default naming another key is not data for the security gate.
@test "a default naming another key makes every baseline gate config" {
  audit_dir_case 'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_OTHER:-sec/audits}"' \
    deep/er/2026-01-01-baseline-y.json
}

# Control: a data config names its dirs and nothing more.
@test "a quoted audit dir leaves baselines elsewhere alone" {
  put .claude/skills/security-gate-local/local.config.sh 'SECURITY_GATE_AUDIT_DIR="sec/audits"'$'\n'
  commit_all 'security-gate config' || return 1
  feature
  put deep/er/2026-01-01-baseline-y.json $'{}\n'
  commit_all 'unrelated baseline' || return 1
  run_gate merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"gate config changed"* ]] || { echo "$output"; false; }
}

# check-secrets still reads the deprecated .claude/skills/process-gate/ copy,
# which only the any-depth arm covers.
@test "a secrets-allowlist.txt anywhere is gate config" {
  local path
  for path in .claude/skills/process-gate/secrets-allowlist.txt secrets-allowlist.txt sub/secrets-allowlist.txt; do
    index_case "$path" || { echo "path: $path"; return 1; }
  done
}

# The environment can add an audit dir (run-diff honours it) but never remove
# one: the base config's dir and audits/ stay covered, and the env value is
# normalised like the config's.
@test "an environment SECURITY_GATE_AUDIT_DIR adds coverage and removes none" {
  export SECURITY_GATE_AUDIT_DIR=./other/
  audit_dir_case 'SECURITY_GATE_AUDIT_DIR=sec/audits' \
    other/2026-01-01-baseline-x.json sec/audits/2026-01-01-baseline-x.json \
    audits/2026-01-01-baseline-x.json
}

# run-diff refuses its own gate-config changes on a main-target push, so the
# security row must see --target=main.
@test "the security row receives --target=main exactly when run-all does" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\n' "$BATS_TEST_TMPDIR/sec-args" \
    > "$STUB/scripts/check-security-diff.sh"
  feature
  git -C "$PROJECT_DIR" commit --allow-empty -qm change
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD --target=main"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$BATS_TEST_TMPDIR/sec-args")" = "--range=main..HEAD --target=main" ] || { cat "$BATS_TEST_TMPDIR/sec-args"; false; }
  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$BATS_TEST_TMPDIR/sec-args")" = "--range=main..HEAD" ] || { cat "$BATS_TEST_TMPDIR/sec-args"; false; }
}

# The fold is load-bearing: without python3 the change list is refused, never
# matched unfolded.
@test "a run without python3 to fold the changed paths is BLOCKED" {
  feature
  put .pi/x $'pi\n'
  commit_all 'pi config' || return 1
  local tb="$BATS_TEST_TMPDIR/toolbox" tool
  mkdir -p "$tb"
  for tool in bash env git mktemp rm mkdir sed cat dirname chmod tr gh jq; do
    ln -s "$(type -P "$tool")" "$tb/$tool"
  done
  run env PATH="$tb" bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"cannot list (or, with python3, fold) the files changed"* ]] || { echo "$output"; false; }
}

# Organization-owned repos (e.g. example-org/example-repo): the owner login can
# never author a comment, so an admin's approval line counts instead. The
# permission comes from gh, never from the PR body; anything but admin, or
# any lookup failure, fails closed.

@test "org repo: an admin's approval for the head SHA proceeds and quotes permission" {
  approval_fixture || return 1
  gh_org example-org example-repo
  gh_perm team-lead admin
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" team-lead "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gate config approved on PR #42 by team-lead (admin permission): \"gate-config-approved: $HEAD_SHA\""* ]] || { echo "$output"; false; }
  grep -q -- "api repos/example-org/example-repo/collaborators/team-lead/permission" "$GH_LOG" || { cat "$GH_LOG"; false; }
}

@test "org repo: a non-admin's approval is BLOCKED and names the permission" {
  approval_fixture || return 1
  gh_org example-org example-repo
  gh_perm contributor push
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" contributor "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 has an approval by contributor (permission push, need admin): \"gate-config-approved: $HEAD_SHA\""* ]] || { echo "$output"; false; }
}

@test "org repo: a failed permission lookup fails closed" {
  approval_fixture || return 1
  gh_org example-org example-repo
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" team-lead "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 has an approval by team-lead (permission lookup failed): \"gate-config-approved: $HEAD_SHA\""* ]] || { echo "$output"; false; }
}

@test "user repo: a non-owner's line stays BLOCKED without any permission lookup" {
  approval_fixture || return 1
  gh_perm some-agent admin
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" some-agent "$HEAD_SHA"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 has an approval by some-agent (not the repo owner repo-owner): \"gate-config-approved: $HEAD_SHA\""* ]] || { echo "$output"; false; }
  grep -q -- "api repos" "$GH_LOG" && { cat "$GH_LOG"; false; } || true
}

@test "org repo: an admin's approval for the wrong SHA is BLOCKED" {
  approval_fixture || return 1
  local base
  base="$(git -C "$PROJECT_DIR" rev-parse main)"
  gh_org example-org example-repo
  gh_perm team-lead admin
  gh_prs "[$(pr_row 42 "$HEAD_SHA")]"
  approve 42 OPEN "$HEAD_SHA" team-lead "$base"

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #42 has an approval by team-lead for another SHA: \"gate-config-approved: $base\""* ]] || { echo "$output"; false; }
}
