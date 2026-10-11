#!/usr/bin/env bats
# Resolver coverage for installed source checkouts and both linked-worktree shapes.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
PRE_PUSH="$REPO_ROOT/core-rules/githooks/pre-push"
HUSKY_PRE_PUSH="$REPO_ROOT/core-rules/husky/pre-push"
PR_GATE="$REPO_ROOT/core-rules/hooks/pr-gate-shiftleft.sh"
CODEX_PR_GATE="$REPO_ROOT/core-rules/codex/hooks/pr-gate-shiftleft.sh"

setup() {
  FIXTURE="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/fixture"
  MAIN="$FIXTURE/main"
  WORKTREE="$FIXTURE/worktree"
  CAPTURE="$FIXTURE/runner.log"
  mkdir -p "$MAIN"
  export TRELLIS_HOME="$FIXTURE/trellis-home"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email resolver@test.invalid
  git -C "$MAIN" config user.name resolver-test
  printf 'seed\n' > "$MAIN/README.md"
}

write_runner() {
  local runner="$1"
  mkdir -p "$(dirname "$runner")"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$0" "$*" > "$PROCESS_GATE_CAPTURE"
printf '## process-gate verdict (mode=push)\n\nOverall: MERGEABLE\n'
exit 0
SH
  chmod +x "$runner"
}

commit_main() {
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -qm fixture
}

add_worktree() {
  git -C "$MAIN" worktree add -q -b fixture "$WORKTREE"
}

install_claude_source_link() {
  mkdir -p "$MAIN/.claude/skills"
  ln -s ../../core-rules/skills/process-gate "$MAIN/.claude/skills/process-gate"
}

run_pre_push() {
  local checkout="$1"
  run env PROCESS_GATE_CAPTURE="$CAPTURE" sh -c 'cd "$1" && sh "$2" </dev/null' _ "$checkout" "$PRE_PUSH"
}

run_husky_pre_push() {
  local checkout="$1"
  run env PROCESS_GATE_CAPTURE="$CAPTURE" sh -c 'cd "$1" && sh "$2" </dev/null' _ "$checkout" "$HUSKY_PRE_PUSH"
}

run_pr_gate() {
  local checkout="$1"
  run bash -c '
    unset CODEX_PROJECT_DIR
    export CLAUDE_PROJECT_DIR="$1"
    export PROCESS_GATE_CAPTURE="$2"
    printf "%s\n" '\''{"tool_name":"Bash","tool_input":{"command":"gh pr create --base main --fill"}}'\'' | bash "$3"
  ' _ "$checkout" "$CAPTURE" "$PR_GATE"
}

run_codex_pr_gate() {
  local checkout="$1"
  run bash -c '
    unset CLAUDE_PROJECT_DIR
    export CODEX_PROJECT_DIR="$1"
    export PROCESS_GATE_CAPTURE="$2"
    printf "%s\n" '\''{"tool_name":"Bash","tool_input":{"command":"gh pr create --base main --fill"}}'\'' | bash "$3"
  ' _ "$checkout" "$CAPTURE" "$CODEX_PR_GATE"
}

assert_runner() {
  local expected_path="$1" expected_args="$2" actual
  [ -f "$CAPTURE" ]
  actual="$(cat "$CAPTURE")"
  [ "$actual" = "$expected_path|$expected_args" ] || {
    printf 'expected runner: %s|%s\nactual runner:   %s\n' "$expected_path" "$expected_args" "$actual"
    false
  }
}

# pr-gate-shiftleft records the PR base only (B2/C03): it must not run the
# runner the carriers resolve. The literal --base in run_pr_gate is the input
# the pre-B2 hook handed straight to the runner. Truncate the capture first.
assert_runner_not_run() {
  [ ! -s "$CAPTURE" ] || {
    printf 'pr-gate-shiftleft ran the runner: %s\n' "$(cat "$CAPTURE")"
    false
  }
}

# Exercise the real aggregator and bypass checker without running other gates
# or attach/sync: their fixture validators are explicit pass stubs. The sidecar
# has the same location and payload value used by the managed dispatcher.
install_managed_release_fixture() {
  umask 077
  commit_main
  TRELLIS_FIXTURE_HOME="$FIXTURE/trellis-home"
  PAYLOAD="$TRELLIS_FIXTURE_HOME/releases/current/payload"
  PREVIOUS_PAYLOAD="$TRELLIS_FIXTURE_HOME/releases/previous/payload"
  local scripts="$PAYLOAD/core-rules/skills/process-gate/scripts"
  local previous_scripts="$PREVIOUS_PAYLOAD/core-rules/skills/process-gate/scripts"
  local common checkout worktree owner digest validator
  common="$(cd "$MAIN/.git" && pwd -P)"
  checkout="$(printf '%s' "$common" | shasum -a 256 | awk '{print $1}')"
  worktree="$(printf '%s' "$MAIN" | shasum -a 256 | awk '{print $1}')"
  MANAGED_HOOKS="$TRELLIS_FIXTURE_HOME/state/git-hooks/$checkout"
  owner="$TRELLIS_FIXTURE_HOME/state/attachments/$checkout/$worktree.json"
  mkdir -p "$scripts/lib" "$previous_scripts" "$MANAGED_HOOKS" "$(dirname "$owner")" \
    "$MAIN/.trellis" "$MAIN/.agents/skills" "$MAIN/.codex"
  cp "$REPO_ROOT/core-rules/skills/process-gate/scripts/run-all.sh" \
    "$REPO_ROOT/core-rules/skills/process-gate/scripts/check-bypass.sh" "$scripts/"
  cp "$REPO_ROOT/core-rules/skills/process-gate/scripts/lib/common.sh" "$scripts/lib/"
  cp "$REPO_ROOT/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$scripts/lib/" || return 1
  for validator in pr secrets tests docs security-diff analyze slop; do
    printf '#!/bin/bash\nprintf "pass fixture-only validator\\n"\nexit 0\n' > "$scripts/check-$validator.sh"
  done
  printf '#!/bin/bash\nprintf "PREVIOUS_RELEASE_RUNNER\\n"\nexit 0\n' > "$previous_scripts/run-all.sh"
  printf '{}\n' > "$PAYLOAD/trellis.config.json"
  printf '{}\n' > "$PREVIOUS_PAYLOAD/trellis.config.json"
  ln -s "$PAYLOAD" "$MAIN/.trellis/runtime"
  ln -s '../../.trellis/runtime/core-rules/skills/process-gate' "$MAIN/.agents/skills/process-gate"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"trellis-stop"}]}]}}\n' \
    > "$MAIN/.codex/hooks.json"
  digest="$(shasum -a 256 "$MAIN/.codex/hooks.json" | awk '{print $1}')"
  jq -n --arg root "$MAIN" --arg checkout "$checkout" --arg worktree "$worktree" \
    --arg payload "$PAYLOAD" --arg digest "$digest" --arg managed "$MANAGED_HOOKS" '
    {schema_version:1,status:"committed",worktree_root:$root,checkout_id:$checkout,
     worktree_id:$worktree,artifacts:[
       {path:".trellis/runtime",kind:"symlink",target:$payload},
       {path:".codex/hooks.json",kind:"file",sha256:$digest}],
     git_hooks:{enabled:true,managed_hooks_path:$managed}}
  ' > "$owner"
  printf '%s\n' "$PAYLOAD" > "$MANAGED_HOOKS/release-payload"
  chmod 600 "$owner" "$MANAGED_HOOKS/release-payload"
  git -C "$MAIN" config core.hooksPath "$MANAGED_HOOKS"
}

run_managed_carrier() {
  run env TRELLIS_HOME="$TRELLIS_FIXTURE_HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    CLAUDE_PROJECT_DIR="$MAIN" CODEX_PROJECT_DIR="$MAIN" \
    /bin/bash --noprofile --norc -c 'cd "$1" && /bin/bash --noprofile --norc "$2" < "$3"' \
    _ "$MAIN" "$1" "${2:-/dev/null}"
}

# No real install or network: model pnpm's auto-install/prepare side effect,
# then model its native "error" mode for stale dependencies.
install_husky_prepare_fixture() {
  install_managed_release_fixture
  mkdir -p "$MAIN/.husky" "$MAIN/node_modules" "$FIXTURE/bin"
  printf '{"scripts":{"prepare":"husky","verify":"true"}}\n' > "$MAIN/package.json"
  printf 'stale fixture modules\n' > "$MAIN/node_modules/.modules.yaml"
  cat > "$FIXTURE/bin/pnpm" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${HUSKY:-<unset>}" \
  "${npm_config_verify_deps_before_run:-<unset>}" \
  "${pnpm_config_verify_deps_before_run:-<unset>}" > "$PNPM_CAPTURE"
if [ "${PNPM_STALE:-0}" = 1 ] && [ "${pnpm_config_verify_deps_before_run:-}" = error ]; then
  echo 'fixture pnpm: stale dependencies; run pnpm install outside the hook' >&2
  exit 1
fi
if [ "${PNPM_RESET:-0}" = 1 ] ||
   { [ "${PNPM_STALE:-0}" = 1 ] && [ "${pnpm_config_verify_deps_before_run:-}" != error ] && [ "${HUSKY:-}" != 0 ]; }; then
  if [ "${PNPM_WORKTREE_RESET:-0}" = 1 ]; then
    git config --worktree core.hooksPath .husky/_
  else
    git config core.hooksPath .husky/_
  fi
fi
exit "${PNPM_EXIT:-0}"
SH
  chmod +x "$FIXTURE/bin/pnpm"
  printf '#!/bin/bash\npnpm run verify && printf "## process-gate verdict (mode=push)\\n\\nOverall: MERGEABLE\\n"\n' > "$PAYLOAD/core-rules/skills/process-gate/scripts/run-all.sh"
  export PATH="$FIXTURE/bin:$PATH" PNPM_CAPTURE="$FIXTURE/pnpm.log"
  unset HUSKY npm_config_verify_deps_before_run pnpm_config_verify_deps_before_run
  unset PNPM_RESET PNPM_WORKTREE_RESET PNPM_STALE PNPM_EXIT
}

assert_hook_authority_failure() {
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath"* ]]
  [[ "$output" == *"restore with: $(printf 'git config --replace-all core.hooksPath %q' "$MANAGED_HOOKS")"* ]] || {
    echo "$output"; false;
  }
  # A failure reports drift; it never silently re-asserts the managed path.
  [ "$(git -C "$MAIN" config --get core.hooksPath)" = "${1:-.husky/_}" ]
}

@test "item8 r2b: real pnpm 11 error guard rejects stale state without an offline install" {
  local pnpm version guard_env corepack_home home="$FIXTURE/pnpm-home"
  pnpm="$(command -v pnpm)" || skip 'pnpm is absent'
  version="$(COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_PROJECT_SPEC=0 COREPACK_DEFAULT_TO_LATEST=0 "$pnpm" --version)" || skip 'pnpm version unavailable offline'
  [[ "$version" = 11.* ]] || skip "pnpm major is not 11 ($version)"
  printf '# real pnpm %s: offline local dependency integration\n' "$version" >&3
  corepack_home="${COREPACK_HOME:-${XDG_CACHE_HOME:-${LOCALAPPDATA:-$HOME/.cache}}/node/corepack}"
  # Read the actual carrier assignment so a wrong name/value in production
  # breaks this integration, not just an assertion against a pnpm-shaped stub.
  guard_env="$(awk '$1 == "export" && $2 ~ /^pnpm_config_/ {print $2}' "$PRE_PUSH")"
  [ -n "$guard_env" ]
  local real_env=(PATH="$PATH" HOME="$home" TMPDIR="$TMPDIR" LC_ALL=C
    COREPACK_HOME="$corepack_home" COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_PROJECT_SPEC=0
    COREPACK_DEFAULT_TO_LATEST=0 NODE_COMPILE_CACHE="$home/compile-cache"
    XDG_CONFIG_HOME="$home/config" XDG_CACHE_HOME="$home/cache" XDG_DATA_HOME="$home/data"
    npm_config_userconfig=/dev/null pnpm_config_offline=true pnpm_config_frozen_lockfile=false
    pnpm_config_update_notifier=false GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
  mkdir -p "$home" "$FIXTURE/managed-hooks"
  printf 'offline: true\nverifyDepsBeforeRun: install\n' > "$MAIN/pnpm-workspace.yaml"
  printf '%s\n' '{"name":"offline-item8","version":"1.0.0","private":true,"scripts":{"prepare":"node prepare.cjs","verify":"node verify.cjs"}}' > "$MAIN/package.json"
  printf '%s\n' 'require("fs").writeFileSync("prepare-ran", "yes"); require("child_process").execFileSync("git", ["config", "core.hooksPath", ".husky/_"]);' > "$MAIN/prepare.cjs"
  printf '%s\n' 'require("fs").writeFileSync("verify-ran", "yes");' > "$MAIN/verify.cjs"
  run env -i "${real_env[@]}" "$pnpm" --dir "$MAIN" install --offline
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MAIN/node_modules/.pnpm-workspace-state-v1.json" ]
  run env -i "${real_env[@]}" "$guard_env" "$pnpm" --dir "$MAIN" run verify
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  rm "$MAIN/prepare-ran" "$MAIN/verify-ran"
  git -C "$MAIN" config core.hooksPath "$FIXTURE/managed-hooks"
  mkdir -p "$MAIN/dep"
  printf '%s\n' '{"name":"offline-dep","version":"1.0.0"}' > "$MAIN/dep/package.json"
  # pnpm 11.23.0 checks manifests against the lockfile/workspace state. Add a
  # local file dependency AFTER the recorded install: no registry is needed.
  python3 -I - "$MAIN/package.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data['dependencies'] = {'offline-dep': 'file:./dep'}
path.write_text(json.dumps(data) + '\n')
PY
  cp "$MAIN/pnpm-lock.yaml" "$FIXTURE/lock-before"
  cp "$MAIN/node_modules/.pnpm-workspace-state-v1.json" "$FIXTURE/state-before"
  run env -i "${real_env[@]}" "$guard_env" "$pnpm" --dir "$MAIN" run verify
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *ERR_PNPM_VERIFY_DEPS_BEFORE_RUN* ]] || { echo "$output"; false; }
  [ ! -e "$MAIN/prepare-ran" ]
  [ ! -e "$MAIN/verify-ran" ]
  [ ! -e "$MAIN/node_modules/offline-dep" ]
  cmp "$FIXTURE/lock-before" "$MAIN/pnpm-lock.yaml"
  cmp "$FIXTURE/state-before" "$MAIN/node_modules/.pnpm-workspace-state-v1.json"
  [ "$(git -C "$MAIN" config --get core.hooksPath)" = "$FIXTURE/managed-hooks" ]
  # env -i leaves the guard unset. The real default auto-installs offline,
  # runs prepare (rewriting hooksPath), then executes the requested script.
  run env -i "${real_env[@]}" "$pnpm" --dir "$MAIN" run verify
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MAIN/prepare-ran" ]
  [ -f "$MAIN/verify-ran" ]
  [ -e "$MAIN/node_modules/offline-dep" ]
  [ "$(git -C "$MAIN" config --get core.hooksPath)" = .husky/_ ]
}

@test "item8 r3: real pnpm integration skips when the offline version probe fails" {
  mkdir -p "$FIXTURE/unavailable-pnpm"
  printf '#!/bin/sh\nprintf "version probe ran\\n" > "$PNPM_VERSION_WITNESS"\nexit 1\n' > "$FIXTURE/unavailable-pnpm/pnpm"
  chmod +x "$FIXTURE/unavailable-pnpm/pnpm"
  run env PATH="$FIXTURE/unavailable-pnpm:$PATH" PNPM_VERSION_WITNESS="$FIXTURE/version-probe" \
    bats --tap --filter 'item8 r2b: real pnpm 11' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$FIXTURE/version-probe" ]
  [[ "$output" == *"# skip pnpm version unavailable offline"* ]] || { echo "$output"; false; }
}

@test "item8 r2b: worktree override diagnostic gives commands that restore effective authority" {
  install_husky_prepare_fixture
  git -C "$MAIN" config extensions.worktreeConfig true
  local restore clear
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    git -C "$MAIN" config --worktree core.hooksPath .husky/_
    run_managed_carrier "$hook"
    assert_hook_authority_failure
    restore="$(printf '%s\n' "$output" | awk '/restore with: / {sub(/^.*restore with: /, ""); print; exit}')"
    clear="$(printf '%s\n' "$output" | awk '/clear worktree override with: / {sub(/^.*clear worktree override with: /, ""); print; exit}')"
    [ "$clear" = 'git config --worktree --unset core.hooksPath' ] || { echo "$output"; false; }
    [ "$(git -C "$MAIN" config --local --get core.hooksPath)" = "$MANAGED_HOOKS" ]
    run bash -c 'cd "$1" && eval "$2" && eval "$3"' _ "$MAIN" "$clear" "$restore"
    [ "$status" -eq 0 ]
    run_managed_carrier "$hook"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(git -C "$MAIN" config --get core.hooksPath)" = "$MANAGED_HOOKS" ]
  done
}

@test "item8 r2b: HUP INT TERM carrier exits check drift and retain signal status" {
  install_managed_release_fixture
  cat > "$PAYLOAD/core-rules/skills/process-gate/scripts/run-all.sh" <<'SH'
#!/bin/bash
git config core.hooksPath .husky/_
kill -"$CARRIER_SIGNAL" "$PPID"
exit 0
SH
  local expected
  for signal in HUP INT TERM; do
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    export CARRIER_SIGNAL="$signal"
    for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
      git -C "$MAIN" config core.hooksPath "$MANAGED_HOOKS"
      run_managed_carrier "$hook"
      [ "$status" -eq "$expected" ] || { echo "signal=$signal status=$status"; echo "$output"; false; }
      [[ "$output" == *"restore with: $(printf 'git config --replace-all core.hooksPath %q' "$MANAGED_HOOKS")"* ]]
      [ "$(git -C "$MAIN" config --get core.hooksPath)" = .husky/_ ]
    done
  done
}

@test "item8 r3: direct carrier canonicalizes trailing slash and symlinked homes" {
  install_husky_prepare_fixture
  local canonical_home="$TRELLIS_FIXTURE_HOME" restore
  ln -s "$canonical_home" "$FIXTURE/home-alias"
  for home in "$canonical_home/" "$FIXTURE/home-alias"; do
    TRELLIS_FIXTURE_HOME="$home"
    for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
      git -C "$MAIN" config core.hooksPath .husky/_
      run_managed_carrier "$hook"
      assert_hook_authority_failure
      restore="$(printf '%s\n' "$output" | awk '/restore with: / {sub(/^.*restore with: /, ""); print; exit}')"
      [ "$restore" = "$(printf 'git config --replace-all core.hooksPath %q' "$MANAGED_HOOKS")" ]
      run bash -c 'cd "$1" && eval "$2"' _ "$MAIN" "$restore"
      [ "$status" -eq 0 ]
      [ "$(git -C "$MAIN" config --local --get core.hooksPath)" = "$MANAGED_HOOKS" ]
      run_managed_carrier "$hook"
      [ "$status" -eq 0 ] || { echo "$output"; false; }
    done
  done
}

@test "item8 r3: sh carrier TERM trap reports drift and blocks the push" {
  install_managed_release_fixture
  cat > "$PAYLOAD/core-rules/skills/process-gate/scripts/run-all.sh" <<'SH'
#!/bin/bash
git config core.hooksPath .husky/_
kill -TERM "$PPID"
exit 0
SH
  # macOS /bin/sh is Bash 3.2 in POSIX mode; invoke sh, not the dispatcher bash.
  # A 143 exit alone could be the default signal action: require trap output.
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    git -C "$MAIN" config core.hooksPath "$MANAGED_HOOKS"
    run env TRELLIS_HOME="$TRELLIS_FIXTURE_HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      sh -c 'cd "$1" && sh "$2" </dev/null' _ "$MAIN" "$hook"
    [ "$status" -eq 143 ] || { echo "$output"; false; }
    [[ "$output" == *"restore with: $(printf 'git config --replace-all core.hooksPath %q' "$MANAGED_HOOKS")"* ]] || { echo "$output"; false; }
    [ "$(git -C "$MAIN" config --get core.hooksPath)" = .husky/_ ]
  done
}

@test "item8 r2b: managed carrier refuses relative TRELLIS_HOME before verification" {
  install_husky_prepare_fixture
  TRELLIS_FIXTURE_HOME=../trellis-home
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    run_managed_carrier "$hook"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"TRELLIS_HOME must be an absolute path for managed attachments"* ]]
    [[ "$output" != *"Trellis verification starting"* ]]
    [[ "$output" != *"core.hooksPath:"* ]]
    [ ! -e "$FIXTURE/pnpm.log" ]
  done
}

@test "item8: guarded verification prevents husky prepare and fails on stale deps" {
  install_husky_prepare_fixture
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    for stale in 1 0; do
      export PNPM_STALE="$stale"
      run_managed_carrier "$hook"
      [ "$status" -eq "$stale" ] || { echo "$output"; false; }
      [ "$(git -C "$MAIN" config --get core.hooksPath)" = "$MANAGED_HOOKS" ]
      [ "$(cat "$PNPM_CAPTURE")" = '0|<unset>|error' ]
      if [ "$stale" = 1 ]; then
        [[ "$output" == *"stale dependencies"* ]]
      fi
    done
  done
}

@test "item8: removing prevention exports resets authority but post-check blocks" {
  install_husky_prepare_fixture
  local mutant="$FIXTURE/unprotected-pre-push"
  export PNPM_STALE=1
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    python3 -I - "$hook" "$mutant" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
for line in ("export HUSKY=0\n", "export pnpm_config_verify_deps_before_run=error\n"):
    text = text.replace(line, "")
pathlib.Path(sys.argv[2]).write_text(text)
PY
    git -C "$MAIN" config core.hooksPath "$MANAGED_HOOKS"
    run_managed_carrier "$mutant"
    assert_hook_authority_failure
    [ "$(cat "$PNPM_CAPTURE")" = '<unset>|<unset>|<unset>' ]
  done
}

@test "item8: forced prepare reset fails hard for pass warn failure and crash" {
  install_husky_prepare_fixture
  export PNPM_RESET=1
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    for gate_rc in 0 2 1 42; do
      export PNPM_EXIT="$gate_rc"
      git -C "$MAIN" config core.hooksPath "$MANAGED_HOOKS"
      run_managed_carrier "$hook"
      assert_hook_authority_failure
      [ "$(cat "$PNPM_CAPTURE")" = '0|<unset>|error' ]
    done
  done
}

@test "item8: post-check reads effective worktree config not only shared local config" {
  install_husky_prepare_fixture
  git -C "$MAIN" config extensions.worktreeConfig true
  export PNPM_RESET=1 PNPM_WORKTREE_RESET=1
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    git -C "$MAIN" config --worktree core.hooksPath "$MANAGED_HOOKS"
    run_managed_carrier "$hook"
    assert_hook_authority_failure
    [ "$(git -C "$MAIN" config --local --get core.hooksPath)" = "$MANAGED_HOOKS" ]
  done
}

@test "item8: early spec-gate failure still checks authority and prints restore" {
  install_husky_prepare_fixture
  mkdir -p "$MAIN/.claude/hooks"
  printf '#!/bin/bash\npnpm run verify\n' > "$MAIN/.claude/hooks/spec-gate.sh"
  export PNPM_RESET=1 PNPM_EXIT=1
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    git -C "$MAIN" config core.hooksPath "$MANAGED_HOOKS"
    run_managed_carrier "$hook"
    assert_hook_authority_failure
    [[ "$output" == *"spec-gate blocked this push"* ]]
    [ "$(cat "$PNPM_CAPTURE")" = '0|<unset>|error' ]
  done
}

@test "item8 r2: shared hooksPath drift fails even when worktree authority matches" {
  install_husky_prepare_fixture
  git -C "$MAIN" config extensions.worktreeConfig true
  git -C "$MAIN" config --worktree core.hooksPath "$MANAGED_HOOKS"
  export PNPM_RESET=1
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    git -C "$MAIN" config --local core.hooksPath "$MANAGED_HOOKS"
    run_managed_carrier "$hook"
    assert_hook_authority_failure "$MANAGED_HOOKS"
    [ "$(git -C "$MAIN" config --local --get core.hooksPath)" = .husky/_ ]
    [[ "$output" == *"core.hooksPath: local path"* ]]
  done
}

@test "item8 r2: duplicate local hooksPath values fail including trailing empty values" {
  install_husky_prepare_fixture
  local restore
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    for extra in "$MANAGED_HOOKS" ''; do
      git -C "$MAIN" config --local --unset-all core.hooksPath
      git -C "$MAIN" config --local --add core.hooksPath "$MANAGED_HOOKS"
      git -C "$MAIN" config --local --add core.hooksPath "$extra"
      run_managed_carrier "$hook"
      [ "$status" -eq 1 ] || { echo "$output"; false; }
      restore="$(printf '%s\n' "$output" | awk '/restore with: / {sub(/^.*restore with: /, ""); print; exit}')"
      [ "$restore" = "$(printf 'git config --replace-all core.hooksPath %q' "$MANAGED_HOOKS")" ]
      [ "$(git -C "$MAIN" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" -eq 2 ]
      run bash -c 'cd "$1" && eval "$2"' _ "$MAIN" "$restore"
      [ "$status" -eq 0 ] || { echo "$output"; false; }
      run_managed_carrier "$hook"
      [ "$status" -eq 0 ] || { echo "$output"; false; }
      [ "$(git -C "$MAIN" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" -eq 1 ]
      [ "$(git -C "$MAIN" config --get core.hooksPath)" = "$MANAGED_HOOKS" ]
    done
  done
}

@test "item8 r2: blocked main carrier still reports authority drift" {
  install_husky_prepare_fixture
  printf 'refs/heads/main deadbeef refs/heads/main abcdef\n' > "$FIXTURE/refs"
  git -C "$MAIN" config core.hooksPath .husky/_
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    run_managed_carrier "$hook" "$FIXTURE/refs"
    assert_hook_authority_failure
    [[ "$output" == *"Direct push to refs/heads/main blocked"* ]]
    [ ! -e "$PNPM_CAPTURE" ]
  done
}

@test "item8 r2: corrupt runtime no hash tool and invalid sidecar still report drift" {
  install_husky_prepare_fixture
  local shim="$FIXTURE/no-hash" diagnostic
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 127\n' > "$shim/shasum"
  cp "$shim/shasum" "$shim/sha256sum"
  chmod +x "$shim/shasum" "$shim/sha256sum"
  for failure in runtime hash sidecar; do
    case "$failure" in
      runtime)
        rm "$MAIN/.trellis/runtime"
        ln -s "$FIXTURE/missing-runtime" "$MAIN/.trellis/runtime"
        diagnostic='attached Trellis runtime is corrupt' ;;
      hash) diagnostic='cannot hash Git common directory' ;;
      sidecar)
        printf 'invalid-sidecar\n' > "$MANAGED_HOOKS/release-payload"
        diagnostic='managed release-payload sidecar is unavailable or invalid' ;;
    esac
    git -C "$MAIN" config core.hooksPath .husky/_
    for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
      if [ "$failure" = hash ]; then
        PATH="$shim:$PATH" run_managed_carrier "$hook"
      else
        run_managed_carrier "$hook"
      fi
      assert_hook_authority_failure
      [[ "$output" == *"$diagnostic"* ]] || { echo "$output"; false; }
      [ ! -e "$PNPM_CAPTURE" ]
    done
    if [ "$failure" = runtime ]; then
      rm "$MAIN/.trellis/runtime"
      ln -s "$PAYLOAD" "$MAIN/.trellis/runtime"
    fi
    printf '%s\n' "$PAYLOAD" > "$MANAGED_HOOKS/release-payload"
  done
}

@test "R4: pre-push twins remain byte-identical" {
  run cmp "$PRE_PUSH" "$HUSKY_PRE_PUSH"
  [ "$status" -eq 0 ]
}

@test "R5: raw pre-push twins resolve the runner without python3" {
  local runner="$MAIN/core-rules/skills/process-gate/scripts/run-all.sh"
  local shim="$FIXTURE/no-python" marker="$FIXTURE/python-ran"
  write_runner "$runner"
  commit_main
  mkdir "$shim"
  printf '#!/bin/sh\nprintf "called\\n" >> "$PYTHON_CAPTURE"\nexit 127\n' > "$shim/python3"
  chmod +x "$shim/python3"
  export PATH="$shim:$PATH" PYTHON_CAPTURE="$marker"
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    run env PROCESS_GATE_CAPTURE="$CAPTURE" \
      sh -c 'cd "$1" && sh "$2" </dev/null' _ "$MAIN" "$hook"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    assert_runner "$runner" "--mode=push"
    [ ! -e "$marker" ]
  done
}

@test "R4: managed pre-push passes with the owner-recorded runtime anchor" {
  install_managed_release_fixture
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    run_managed_carrier "$hook"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"Overall: MERGEABLE"* ]]
    [[ "$output" != *"PREVIOUS_RELEASE_RUNNER"* ]]
  done
}

@test "R4: managed pre-push rejects a runtime retarget to a previous installed payload" {
  install_managed_release_fixture
  rm "$MAIN/.trellis/runtime"
  ln -s "$PREVIOUS_PAYLOAD" "$MAIN/.trellis/runtime"
  [ -f "$MAIN/.trellis/runtime/trellis.config.json" ]
  [ -f "$MAIN/.agents/skills/process-gate/scripts/run-all.sh" ]
  for hook in "$PRE_PUSH" "$HUSKY_PRE_PUSH"; do
    run_managed_carrier "$hook"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *".trellis/runtime: runtime anchor missing or does not match owner"* ]]
    [[ "$output" == *"Overall: BLOCKED"* ]]
    [[ "$output" != *"PREVIOUS_RELEASE_RUNNER"* ]]
  done
}

@test "source checkout keeps the installed skill path ahead of the tracked fallback" {
  local tracked="$MAIN/core-rules/skills/process-gate/scripts/run-all.sh"
  local installed="$MAIN/.claude/skills/process-gate/scripts/run-all.sh"
  write_runner "$tracked"
  commit_main
  install_claude_source_link

  run_pre_push "$MAIN"
  [ "$status" -eq 0 ]
  assert_runner "$installed" "--mode=push"

  : > "$CAPTURE"
  run_pr_gate "$MAIN"
  [ "$status" -eq 0 ]
  assert_runner_not_run
}

@test "source worktree resolves the tracked in-repository runner" {
  local tracked="$MAIN/core-rules/skills/process-gate/scripts/run-all.sh"
  local worktree_runner="$WORKTREE/core-rules/skills/process-gate/scripts/run-all.sh"
  write_runner "$tracked"
  commit_main
  install_claude_source_link
  add_worktree

  run_pre_push "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$worktree_runner" "--mode=push"

  : > "$CAPTURE"
  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner_not_run
}

@test "attached-project worktree resolves the runner through the main checkout common dir" {
  local main_runner="$MAIN/.claude/skills/process-gate/scripts/run-all.sh"
  commit_main
  add_worktree
  write_runner "$main_runner"

  run_pre_push "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$main_runner" "--mode=push"

  : > "$CAPTURE"
  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner_not_run
}

@test "attached-project worktree resolves the Codex runner through the main checkout common dir" {
  local main_runner="$MAIN/.agents/skills/process-gate/scripts/run-all.sh"
  commit_main
  add_worktree
  write_runner "$main_runner"
  [ ! -e "$MAIN/.claude/skills/process-gate/scripts/run-all.sh" ]

  run_pre_push "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$main_runner" "--mode=push"

  : > "$CAPTURE"
  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner_not_run

  run_codex_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner_not_run
}

@test "missing runner fails pre-push closed and reports every candidate miss" {
  commit_main
  add_worktree
  mkdir -p "$WORKTREE/.claude/skills"
  ln -s ../../missing-process-gate "$WORKTREE/.claude/skills/process-gate"
  mkdir -p "$WORKTREE/.agents/skills/process-gate/scripts/run-all.sh"

  run_pre_push "$WORKTREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing push because the gate produced no safety verdict"* ]]
  [[ "$output" == *"$WORKTREE/.claude/skills/process-gate/scripts/run-all.sh: process-gate skill symlink target is unavailable"* ]]
  [[ "$output" == *"$WORKTREE/.agents/skills/process-gate/scripts/run-all.sh: exists but is not a regular file"* ]]
  [[ "$output" == *"$WORKTREE/core-rules/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.claude/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.agents/skills/process-gate/scripts/run-all.sh: not found"* ]]

  run_husky_pre_push "$WORKTREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing push because the gate produced no safety verdict"* ]]
  [[ "$output" == *"$WORKTREE/.claude/skills/process-gate/scripts/run-all.sh: process-gate skill symlink target is unavailable"* ]]
  [[ "$output" == *"$WORKTREE/.agents/skills/process-gate/scripts/run-all.sh: exists but is not a regular file"* ]]
  [[ "$output" == *"$WORKTREE/core-rules/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.claude/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.agents/skills/process-gate/scripts/run-all.sh: not found"* ]]

  # Candidate reporting is the carriers' job; shiftleft resolves no runner.
  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Candidates tried:"* ]]
  assert_runner_not_run

  run_codex_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Candidates tried:"* ]]
  assert_runner_not_run
}

