#!/usr/bin/env bats
# Regression coverage for the diff-mode verdict wiring of the ShellCheck stage.
#
# The verdict loop dispatched on `tool` and knew only semgrep/osv/gitleaks, so
# ShellCheck findings were printed under "New findings vs baseline" and then
# updated no row: a brand-new high-severity shell defect returned MERGEABLE and
# exit 0 on the repository that is ~19k lines of Bash. These tests pin both
# halves of the contract — high ⇒ BLOCKED/1, medium ⇒ NEEDS CHANGES/2 — through
# the real script end to end, so a future dispatch rewrite cannot silently drop
# shell out of the SAST row again.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT" "$BIN"

  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "trellis test"

  mkdir -p "$PROJECT/audits"
  cat > "$PROJECT/audits/2026-01-01-baseline-project.json" <<'JSON'
{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}
JSON
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "seed"

  # Semgrep and gitleaks stay silent so the only thing that can move a row is
  # the ShellCheck stage. osv never runs — no manifest is in the diff.
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "1.157.0"; else echo '{"results":[],"errors":[],"paths":{"scanned":[]}}'; fi
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then echo "8.30.1"; exit 0; fi
report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$report" ] && printf '[]' > "$report"
exit 0
SH
  chmod +x "$BIN/semgrep" "$BIN/gitleaks"

  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# $1 = ShellCheck `level` the stub reports for the changed file.
stub_shellcheck() {
  cat > "$BIN/shellcheck" <<SH
#!/usr/bin/env bash
target=""
for a in "\$@"; do case "\$a" in --*) ;; *) target="\$a" ;; esac; done
printf '[{"file":"%s","line":2,"column":1,"level":"%s","code":1072,"message":"stubbed shell defect"}]' "\$target" "$1"
exit 1
SH
  chmod +x "$BIN/shellcheck"
}

commit_shell_change() {
  printf '#!/usr/bin/env bash\ntrue\n' > "$PROJECT/changed.sh"
  git -C "$PROJECT" add changed.sh
  git -C "$PROJECT" commit -qm "add changed.sh"
}

commit_eval_seed_change() {
  mkdir -p "$PROJECT/core-rules/evals/example/seed"
  printf '#!/usr/bin/env bash\ntrue\n' > "$PROJECT/core-rules/evals/example/seed/hook.sh"
  git -C "$PROJECT" add core-rules
  git -C "$PROJECT" commit -qm "add eval seed"
}

# An extensionless script, committed executable, exactly as `pre-push`,
# `commit-msg` and a CLI entrypoint are committed in a real tree.
# $1 = repo-relative path, $2 = shebang line.
commit_extensionless_change() {
  mkdir -p "$PROJECT/$(dirname "$1")"
  printf '%s\ntrue\n' "$2" > "$PROJECT/$1"
  chmod +x "$PROJECT/$1"
  git -C "$PROJECT" add "$1"
  git -C "$PROJECT" commit -qm "add $1"
}

# Extra environment assignments are passed as "NAME=value" arguments.
run_diff() {
  run env PATH="$BIN:$PATH" \
    SECURITY_GATE_STACK_PROFILE=shell-tooling \
    SECURITY_GATE_PROJECT_NAME=project \
    "$@" \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --range=HEAD~1..HEAD --no-llm
}

@test "a new high-severity ShellCheck finding fails SAST and blocks the push" {
  stub_shellcheck error
  commit_shell_change
  run_diff

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"shellcheck/SC1072"* ]] || { echo "$output"; false; }
  [[ "$output" == *"SAST:"*"❌ fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "a new medium-severity ShellCheck finding warns SAST rather than passing" {
  stub_shellcheck warning
  commit_shell_change
  run_diff

  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"shellcheck/SC1072"* ]] || { echo "$output"; false; }
  [[ "$output" == *"SAST:"*"⚠️  warn"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]] || { echo "$output"; false; }
}

# The carve-out is a project config value, not a path baked into a skill that
# every registered project inherits. A project points it at whatever its own
# lint gate excludes; since the baseline engine never runs ShellCheck, a finding
# on a file no lint run may clean could never be deduped away and would block
# the push forever.
@test "a configured exclude glob takes a path out of the ShellCheck scope" {
  stub_shellcheck error
  commit_eval_seed_change
  run_diff SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS='core-rules/evals/*'

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"shellcheck/"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
}

# The negative half: without the config the same file IS scanned. Without this
# case the one above passes whether the glob is honoured or the whole stage is
# broken.
@test "the same path is scanned when no exclude glob is configured" {
  stub_shellcheck error
  commit_eval_seed_change
  run_diff

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"shellcheck/SC1072"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

# The scope filter matched on suffix only, so every extensionless script was
# outside the semgrep scope AND the ShellCheck scope at once — including the
# pre-push hook that invokes this very gate, both commit-msg hooks, and the
# `trellis` CLI entrypoint. A canary reproduced it end to end: `bad.sh` with a
# defect blocked, `hooks/pre-push` with the identical defect produced zero
# findings. Classification is by shebang now.
@test "an extensionless shell hook is scanned like any other shell file" {
  stub_shellcheck error
  commit_extensionless_change "hooks/pre-push" "#!/usr/bin/env bash"
  run_diff

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"shellcheck/SC1072"* ]] || { echo "$output"; false; }
  [[ "$output" == *"hooks/pre-push"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

# `env` is resolved through to the interpreter it launches, so the dispatch must
# read past it rather than stopping at `/usr/bin/env`.
@test "a bare-path shebang is classified the same as an env shebang" {
  stub_shellcheck error
  commit_extensionless_change "bin/trellis" "#!/bin/sh"
  run_diff

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"bin/trellis"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

# The other direction: shebang classification must not sweep every extensionless
# file into a linter that reports "not a shell script" as a high finding. Only
# sh/bash/dash/ksh count.
@test "an extensionless non-shell script stays out of the ShellCheck scope" {
  stub_shellcheck error
  commit_extensionless_change "bin/report" "#!/usr/bin/env python3"
  run_diff

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"shellcheck/"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
}

# The stage is opt-in per project: the baseline engine does not run ShellCheck,
# so a tree whose shell has never been linted would block every push on findings
# with no baseline entry to dedupe against.
@test "the ShellCheck stage stays off for a project that has not opted in" {
  stub_shellcheck error
  commit_shell_change
  run_diff SECURITY_GATE_SHELLCHECK=0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"shellcheck/"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
}

# ...and opting in is enough on its own, without adopting the shell-tooling
# profile, which is what made the arm inert for every other project.
@test "an opted-in non-shell-tooling project still gets the ShellCheck stage" {
  stub_shellcheck error
  commit_shell_change
  run_diff SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_SHELLCHECK=1

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"shellcheck/SC1072"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

# 1.5.1 perf: ShellCheck runs once per file, at most four at a time, started
# before semgrep. One file per run must still report every file, in the order
# the files were given, and keep the single-run verdict rules.
stub_shellcheck_per_file() {
  cat > "$BIN/shellcheck" <<SH
#!/usr/bin/env bash
files=()
for a in "\$@"; do case "\$a" in --*) ;; *) files+=("\$a") ;; esac; done
printf '%s\n' "\${#files[@]} \${files[*]}" >> "$TEST_ROOT/shellcheck.calls"
mkdir -p "$TEST_ROOT/running"
: > "$TEST_ROOT/running/\$\$"
sleep 0.3
ls "$TEST_ROOT/running" | wc -l | tr -d ' ' >> "$TEST_ROOT/shellcheck.concurrency"
rm -f "$TEST_ROOT/running/\$\$"
out='['
sep=''
for f in "\${files[@]}"; do
  case "\${f##*/}" in crash.sh) exit 2 ;; esac
  out="\$out\$sep{\"file\":\"\$f\",\"line\":2,\"column\":1,\"level\":\"$1\",\"code\":1072,\"message\":\"stubbed shell defect\"}"
  sep=','
done
printf '%s]' "\$out"
exit 1
SH
  chmod +x "$BIN/shellcheck"
}

commit_shell_files() {
  local name
  for name in "$@"; do
    printf '#!/usr/bin/env bash\ntrue\n' > "$PROJECT/$name"
  done
  git -C "$PROJECT" add "$@"
  git -C "$PROJECT" commit -qm "add shell files"
}

@test "ShellCheck checks each file in its own run, at most four at once, and reports every file" {
  stub_shellcheck_per_file error
  commit_shell_files a1.sh a2.sh a3.sh a4.sh a5.sh a6.sh
  run_diff

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [ "$(wc -l < "$TEST_ROOT/shellcheck.calls" | tr -d ' ')" -eq 6 ] || { cat "$TEST_ROOT/shellcheck.calls"; false; }
  ! grep -qv '^1 ' "$TEST_ROOT/shellcheck.calls" || { cat "$TEST_ROOT/shellcheck.calls"; false; }
  [ "$(sort -n "$TEST_ROOT/shellcheck.concurrency" | tail -n 1)" -le 4 ] || { cat "$TEST_ROOT/shellcheck.concurrency"; false; }
  echo "# max concurrent ShellCheck runs: $(sort -n "$TEST_ROOT/shellcheck.concurrency" | tail -n 1)" >&3
  local name previous=0 at
  for name in a1.sh a2.sh a3.sh a4.sh a5.sh a6.sh; do
    [[ "$output" == *"shellcheck/SC1072"*"$name"* ]] || { echo "missing $name"; echo "$output"; false; }
    at="$(printf '%s\n' "$output" | grep -n "shellcheck/SC1072.*$name" | head -n 1 | cut -d: -f1)"
    [ "$at" -gt "$previous" ] || { echo "out of order at $name"; echo "$output"; false; }
    previous="$at"
  done
  [[ "$output" == *"shellcheck: ran=1 exit=1 parsed=1 scanned=6"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "a ShellCheck crash on one file of several blocks SAST as incomplete" {
  stub_shellcheck_per_file warning
  commit_shell_files a1.sh crash.sh a3.sh
  run_diff

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"shellcheck: ran=1 exit=2 parsed=0 scanned=0"* ]] && [[ "$output" == *"shellcheck did not complete: scanner exit 2"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "diff mode transfers span-only Semgrep PartialParsing on shell files when ShellCheck runs" {
  cat > "$BIN/shellcheck" <<'SH'
#!/usr/bin/env bash
printf '[]'
exit 0
SH
  cat > "$BIN/semgrep" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then echo "1.157.0"; exit 0; fi
printf '{"results":[],"errors":[{"code":3,"level":"warn","type":["PartialParsing",[{"path":"%s/changed.sh","start":{"line":1,"col":1},"end":{"line":2,"col":1}}]],"message":"Syntax error"}],"paths":{"scanned":["%s/changed.sh"]}}\n' "$PROJECT" "$PROJECT"
SH
  chmod +x "$BIN/shellcheck" "$BIN/semgrep"
  commit_shell_change

  run_diff SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_SHELLCHECK=1
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"semgrep: 1 shell parse errors not counted (shellcheck is the shell SAST)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }

  # Without ShellCheck opted in, the same span-only PartialParsing still blocks.
  run_diff SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_SHELLCHECK=0
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"JSON errors non-empty (PartialParsing)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}
