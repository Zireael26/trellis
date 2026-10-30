#!/usr/bin/env bats
# Required scanners must complete, independently of the normalized findings.
# An isolated PATH makes absence deterministic even on a scanner-equipped host.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT/audits" "$BIN"
  unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR SECURITY_GATE_SHELLCHECK
  unset SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS SECURITY_GATE_SKIP
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export SEMGREP_MODE=clean GITLEAKS_MODE=clean OSV_MODE=clean SHELLCHECK_MODE=clean
  export SCANNER_FIXTURES="$TEST_ROOT"

  # Only infrastructure commands are inherited; never a real scanner.
  for cmd in bash git basename dirname mktemp mkdir readlink ls sort tail rm head awk cat sed; do
    ln -s "$(command -v "$cmd")" "$BIN/$cmd"
  done
  ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$BIN/python3"

  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "trellis test"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/audits/2026-01-01-baseline-project.json"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "seed"

  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":["changed.ts"]}}' > "$TEST_ROOT/semgrep.json"
  printf '%s\n' '{"results":[]}' > "$TEST_ROOT/osv-scanner.json"
  printf '%s\n' '[]' > "$TEST_ROOT/gitleaks.json"
  printf '%s\n' '[]' > "$TEST_ROOT/shellcheck.json"
  cat > "$BIN/scanner" <<'SH'
#!/usr/bin/env bash
engine="$(basename "$0")"
case "$engine" in
  semgrep) mode="$SEMGREP_MODE" ;;
  gitleaks) mode="$GITLEAKS_MODE" ;;
  osv-scanner) mode="$OSV_MODE" ;;
  shellcheck) mode="$SHELLCHECK_MODE" ;;
esac
case "$mode" in
  crash) exit 2 ;;
  crash127) exit 127 ;;
  no-sources) exit 128 ;;
  missing) exit 0 ;;
esac
if [ "$engine" = osv-scanner ]; then
  root="${!#}"
  no_ignore=0
  for arg in "$@"; do [ "$arg" != --no-ignore ] || no_ignore=1; done
  if [ "$mode" = needs-config ]; then
    config=""; previous=""
    for arg in "$@"; do
      [ "$previous" != --config ] || config="$arg"
      previous="$arg"
    done
    [ "$config" = "$SCANNER_FIXTURES/empty.config" ] && [ "$no_ignore" -eq 1 ] || exit 2
  fi
  if [ "$mode" = unrelated ]; then
    printf 'Scanned %s/other/package-lock.json file and found 1 packages\n' "$root" >&2
  elif [ "$mode" = first-only ]; then
    printf 'Scanned %s/package-lock.json file and found 1 packages\n' "$root" >&2
  elif [ "$mode" = relative ]; then
    printf 'Scanned package-lock.json file and found 1 packages\n' >&2
  elif [ "$mode" != omitted ] && { [ "$mode" != needs-no-ignore ] || [ "$no_ignore" -eq 1 ]; }; then
    git -C "$root" ls-files -z --recurse-submodules | python3 -c '
import os, sys
root = sys.argv[1]
locks = {"package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "Cargo.lock", "go.mod", "poetry.lock", "uv.lock", "Pipfile.lock", "Gemfile.lock"}
for path in sys.stdin.buffer.read().split(b"\0"):
    name = os.path.basename(os.fsdecode(path))
    if name in locks or (name.startswith("requirements") and name.endswith(".txt")):
        print("Scanned " + os.path.join(root, os.fsdecode(path)) + " file and found 1 packages", file=sys.stderr)
' "$root"
  fi
  if [ "$mode" = local-findings ]; then
    printf 'Scanned %s/.claude/worktrees/other/package-lock.json file and found 1 packages\n' "$root" >&2
  fi
fi
report=""
if [ "$engine" = gitleaks ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report-path) report="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  exec > "$report"
fi
if [ "$mode" = malformed ]; then
  printf '%s\n' '{not-json'
else
  cat "$SCANNER_FIXTURES/$engine.json"
fi
case "$mode" in findings|local-findings) exit 1 ;; esac
[ "$mode" != valid-error ] || exit 2
exit 0
SH
  chmod +x "$BIN/scanner"
  for engine in semgrep gitleaks osv-scanner shellcheck; do
    ln -s scanner "$BIN/$engine"
  done
  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

commit_change() {
  case "${1:-ts}" in
    ts) printf '%s\n' 'export const changed = true;' > "$PROJECT/changed.ts" ;;
    deps) printf '%s\n' '{"dependencies":{}}' > "$PROJECT/package.json"
          printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$PROJECT/package-lock.json" ;;
    shell) printf '#!/usr/bin/env bash\ntrue\n' > "$PROJECT/changed.sh" ;;
    docs) printf '# changed\n' > "$PROJECT/README.md" ;;
  esac
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "change ${1:-ts}"
}

run_diff() {
  run env PATH="$BIN" SECURITY_GATE_STACK_PROFILE=web-next \
    SECURITY_GATE_PROJECT_NAME=project "$@" \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --range=HEAD~1..HEAD --no-llm
}

assert_blocked() {
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$1 did not complete:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$2:"*"❌ fail"* ]] || { echo "$output"; false; }
}

assert_mergeable() {
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
  [[ "$output" != *"did not complete:"* ]] || { echo "$output"; false; }
}

@test "semgrep absent with TypeScript in range blocks SAST" {
  rm "$BIN/semgrep"
  commit_change
  run_diff
  assert_blocked semgrep SAST
}

@test "semgrep exit 2 with no output blocks SAST" {
  commit_change
  run_diff SEMGREP_MODE=crash
  assert_blocked semgrep SAST
}

@test "semgrep malformed JSON blocks SAST" {
  commit_change
  run_diff SEMGREP_MODE=malformed
  assert_blocked semgrep SAST
}

@test "semgrep non-empty errors makes an otherwise valid scan partial" {
  printf '%s\n' '{"results":[],"errors":[{"message":"partial scan","type":"PartialParsing"}],"paths":{"scanned":["changed.ts"]}}' > "$TEST_ROOT/semgrep.json"
  commit_change
  run_diff
  assert_blocked semgrep SAST
  [[ "$output" == *"semgrep did not complete:"*"PartialParsing"* ]]
}

stub_semgrep_error() {
  python3 - "$1" "$2" "$TEST_ROOT/semgrep.json" <<'PY'
import json, sys
path, kind, out = sys.argv[1:]
if kind == 'PartialParsing':
    kind = ['PartialParsing', []]
with open(out, 'w') as fh:
    json.dump({'results': [], 'errors': [{'type': kind, 'path': path}],
               'paths': {'scanned': [path]}}, fh)
PY
}

@test "semgrep shell parse errors defer to ShellCheck with a visible count" {
  commit_change shell
  for kind in 'Syntax error' PartialParsing 'Lexical error'; do
    stub_semgrep_error changed.sh "$kind"
    run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling
    assert_mergeable
    [[ "$output" == *"semgrep: 1 shell parse errors not counted (shellcheck is the shell SAST)"* ]]
    [[ "$output" == *"shellcheck: ran=1 exit=0 parsed=1 scanned=1"* ]]
  done
}

@test "semgrep .bash and extensionless shell parse errors use exact shell scope" {
  for path in changed.bash pre-push; do
    printf '#!/usr/bin/env -S bash\ntrue\n' > "$PROJECT/$path"
    git -C "$PROJECT" add -A
    git -C "$PROJECT" commit -qm "shell target"
    stub_semgrep_error "$PROJECT/$path" PartialParsing
    run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling
    assert_mergeable
    [[ "$output" == *"semgrep: 1 shell parse errors not counted"* ]]
  done
}

@test "semgrep Python parse errors remain partial and BLOCKED" {
  commit_path changed.py
  for kind in 'Syntax error' PartialParsing 'Lexical error'; do
    stub_semgrep_error changed.py "$kind"
    run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling
    assert_blocked semgrep SAST
    [[ "$output" == *"JSON errors non-empty"* ]]
    [[ "$output" != *"shell parse errors not counted"* ]]
  done
}

@test "semgrep shell non-parse errors remain partial and BLOCKED" {
  commit_change shell
  for kind in Timeout 'Rule parse error' unknown; do
    stub_semgrep_error changed.sh "$kind"
    run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling
    assert_blocked semgrep SAST
    [[ "$output" == *"JSON errors non-empty"* ]]
    [[ "$output" != *"shell parse errors not counted"* ]]
  done
}

@test "semgrep shell parse exemption preserves non-shell errors in a mixed scan" {
  commit_change shell
  commit_path changed.py
  printf '%s\n' '{"results":[],"errors":[{"type":"Syntax error","path":"changed.sh"},{"type":"Syntax error","path":"changed.py"}],"paths":{"scanned":["changed.sh","changed.py"]}}' > "$TEST_ROOT/semgrep.json"
  run env PATH="$BIN" SECURITY_GATE_STACK_PROFILE=shell-tooling \
    SECURITY_GATE_PROJECT_NAME=project bash "$SCRIPT_ROOT/scripts/run-diff.sh" \
    "$PROJECT" --range=HEAD~2..HEAD --no-llm
  assert_blocked semgrep SAST
  [[ "$output" == *"semgrep: 1 shell parse errors not counted"* ]]
  [[ "$output" == *"JSON errors non-empty (Syntax error)"* ]]
}

@test "semgrep shell parse exemption does not excuse missing covered targets" {
  commit_change shell
  commit_path changed.py
  stub_semgrep_error changed.sh 'Syntax error'
  run env PATH="$BIN" SECURITY_GATE_STACK_PROFILE=shell-tooling \
    SECURITY_GATE_PROJECT_NAME=project bash "$SCRIPT_ROOT/scripts/run-diff.sh" \
    "$PROJECT" --range=HEAD~2..HEAD --no-llm
  assert_blocked semgrep SAST
  [[ "$output" == *"semgrep: 1 shell parse errors not counted"* ]]
  [[ "$output" == *"target not scanned"*"changed.py"* ]]
}

@test "semgrep excluded shell parse errors receive no ShellCheck exemption" {
  commit_change shell
  stub_semgrep_error changed.sh 'Syntax error'
  run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS='*.sh'
  assert_blocked semgrep SAST
  [[ "$output" != *"shell parse errors not counted"* ]]
}

@test "semgrep zsh parse errors receive no ShellCheck exemption" {
  commit_path changed.zsh
  stub_semgrep_error changed.zsh 'Lexical error'
  run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling
  assert_blocked semgrep SAST
  [[ "$output" != *"shell parse errors not counted"* ]]
}

@test "semgrep parse errors without a path remain fatal" {
  commit_change shell
  printf '%s\n' '{"results":[],"errors":[{"type":"Syntax error"}],"paths":{"scanned":["changed.sh"]}}' > "$TEST_ROOT/semgrep.json"
  run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling
  assert_blocked semgrep SAST
  [[ "$output" != *"shell parse errors not counted"* ]]
}

@test "semgrep missing JSON at exit 0 blocks SAST" {
  commit_change
  run_diff SEMGREP_MODE=missing
  assert_blocked semgrep SAST
}

@test "semgrep wrong JSON shape blocks SAST" {
  printf '%s\n' '{}' > "$TEST_ROOT/semgrep.json"
  commit_change
  run_diff
  assert_blocked semgrep SAST
}

@test "semgrep findings at exit 0 retain the existing medium verdict" {
  printf '%s\n' '{"results":[{"check_id":"fixture","path":"changed.ts","start":{"line":1},"extra":{"severity":"WARNING","message":"fixture warning"}}],"errors":[],"paths":{"scanned":["changed.ts"]}}' > "$TEST_ROOT/semgrep.json"
  commit_change
  run_diff
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
  [[ "$output" == *"semgrep/fixture"* ]]
  [[ "$output" != *"did not complete:"* ]]
}

# lib/semgrep.sh documents findings as exit 0 without --error. This invocation
# does not use --error, so exit 1 is not a findings-success code here.
@test "semgrep unexpected exit 1 is not confused with another tool's findings code" {
  commit_change
  run_diff SEMGREP_MODE=findings
  assert_blocked semgrep SAST
}

@test "gitleaks absent blocks Secrets" {
  rm "$BIN/gitleaks"
  commit_change
  run_diff
  assert_blocked gitleaks Secrets
}

@test "gitleaks exit 2 with no report blocks Secrets" {
  commit_change
  run_diff GITLEAKS_MODE=crash
  assert_blocked gitleaks Secrets
}

@test "gitleaks malformed report blocks Secrets" {
  commit_change
  run_diff GITLEAKS_MODE=malformed
  assert_blocked gitleaks Secrets
}

@test "gitleaks missing report at exit 0 blocks Secrets" {
  commit_change
  run_diff GITLEAKS_MODE=missing
  assert_blocked gitleaks Secrets
}

@test "gitleaks non-list report blocks Secrets" {
  printf '%s\n' '{"results":[]}' > "$TEST_ROOT/gitleaks.json"
  commit_change
  run_diff
  assert_blocked gitleaks Secrets
}

@test "osv-scanner absent with a changed manifest blocks Deps" {
  rm "$BIN/osv-scanner"
  commit_change deps
  run_diff
  assert_blocked osv-scanner Deps
}

@test "osv-scanner exit 127 blocks Deps" {
  commit_change deps
  run_diff OSV_MODE=crash127
  assert_blocked osv-scanner Deps
}

@test "osv-scanner exit 2 blocks Deps" {
  commit_change deps
  run_diff OSV_MODE=crash
  assert_blocked osv-scanner Deps
}

@test "osv-scanner malformed JSON blocks Deps" {
  commit_change deps
  run_diff OSV_MODE=malformed
  assert_blocked osv-scanner Deps
}

@test "osv-scanner missing JSON at exit 0 blocks Deps" {
  commit_change deps
  run_diff OSV_MODE=missing
  assert_blocked osv-scanner Deps
}

@test "osv-scanner wrong JSON shape blocks Deps" {
  printf '%s\n' '{}' > "$TEST_ROOT/osv-scanner.json"
  commit_change deps
  run_diff
  assert_blocked osv-scanner Deps
}

@test "enabled ShellCheck absent blocks SAST" {
  rm "$BIN/shellcheck"
  commit_change shell
  run_diff SECURITY_GATE_SHELLCHECK=1
  assert_blocked shellcheck SAST
}

@test "ShellCheck exit 2 in the shell-tooling profile blocks SAST" {
  commit_change shell
  run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling SHELLCHECK_MODE=crash
  assert_blocked shellcheck SAST
}

@test "enabled ShellCheck malformed JSON blocks SAST" {
  commit_change shell
  run_diff SECURITY_GATE_SHELLCHECK=1 SHELLCHECK_MODE=malformed
  assert_blocked shellcheck SAST
}

@test "enabled ShellCheck missing JSON at exit 0 blocks SAST" {
  commit_change shell
  run_diff SECURITY_GATE_SHELLCHECK=1 SHELLCHECK_MODE=missing
  assert_blocked shellcheck SAST
}

@test "CONTROL all required engines with valid empty JSON are MERGEABLE" {
  printf '#!/usr/bin/env bash\ntrue\n' > "$PROJECT/changed.sh"
  printf '%s\n' '{"dependencies":{}}' > "$PROJECT/package.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$PROJECT/package-lock.json"
  commit_change
  run_diff SECURITY_GATE_SHELLCHECK=1
  assert_mergeable
  [[ "$output" == *"semgrep: ran=1 exit=0 parsed=1 scanned=1"* ]]
  [[ "$output" == *"shellcheck: ran=1 exit=0 parsed=1 scanned=1"* ]]
  [[ "$output" == *"osv-scanner: ran=1 exit=0 parsed=1 scanned=1"* ]]
  [[ "$output" == *"gitleaks: ran=1 exit=0 parsed=1 scanned=range:HEAD~1..HEAD"* ]]
}

@test "CONTROL gitleaks exit 1 with a valid leak report retains findings verdict" {
  printf '%s\n' '[{"RuleID":"fixture-leak","Description":"fixture leak","File":"changed.ts","StartLine":1,"Commit":"abc12345"}]' > "$TEST_ROOT/gitleaks.json"
  commit_change
  run_diff GITLEAKS_MODE=findings
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]]
  [[ "$output" == *"gitleaks/fixture-leak"* ]]
  [[ "$output" != *"did not complete:"* ]]
}

@test "CONTROL no dependency changes do not require osv-scanner" {
  rm "$BIN/osv-scanner"
  commit_change
  run_diff
  assert_mergeable
}

@test "CONTROL disabled ShellCheck remains optional for shell files" {
  rm "$BIN/shellcheck"
  commit_change shell
  run_diff SECURITY_GATE_SHELLCHECK=0
  assert_mergeable
}

@test "CONTROL excluded shell paths do not require ShellCheck" {
  rm "$BIN/shellcheck"
  commit_change shell
  run_diff SECURITY_GATE_SHELLCHECK=1 SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS='*.sh'
  assert_mergeable
}

@test "CONTROL documentation-only changes do not require semgrep" {
  rm "$BIN/semgrep"
  commit_change docs
  run_diff
  assert_mergeable
}

@test "valid JSON does not excuse any engine's failure exit" {
  printf '#!/usr/bin/env bash\ntrue\n' > "$PROJECT/changed.sh"
  printf '%s\n' '{"dependencies":{}}' > "$PROJECT/package.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$PROJECT/package-lock.json"
  commit_change
  for engine in semgrep shellcheck osv-scanner gitleaks; do
    case "$engine" in
      semgrep) mode=SEMGREP_MODE; row=SAST ;;
      shellcheck) mode=SHELLCHECK_MODE; row=SAST ;;
      osv-scanner) mode=OSV_MODE; row=Deps ;;
      gitleaks) mode=GITLEAKS_MODE; row=Secrets ;;
    esac
    run_diff SECURITY_GATE_SHELLCHECK=1 "$mode=valid-error"
    assert_blocked "$engine" "$row"
  done
}

@test "gitleaks remains required for commits with no net file changes" {
  rm "$BIN/gitleaks"
  git -C "$PROJECT" commit --allow-empty -qm "empty change"
  run_diff
  assert_blocked gitleaks Secrets
}

@test "CONTROL an empty commit range requires no scanners" {
  rm "$BIN/semgrep" "$BIN/gitleaks" "$BIN/osv-scanner" "$BIN/shellcheck"
  run env PATH="$BIN" SECURITY_GATE_PROJECT_NAME=project \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --range=HEAD..HEAD --no-llm
  assert_mergeable
}

# Round 2: coverage receipts, literal paths, and type changes.
commit_path() {
  mkdir -p "$PROJECT/$(dirname "$1")"
  printf '%s\n' 'fixture change' > "$PROJECT/$1"
  git -C "$PROJECT" add -f -- "$1"
  git -C "$PROJECT" commit -qm "change path"
}

stub_semgrep_finding() {
  python3 - "$1" "$TEST_ROOT/semgrep.json" <<'PY'
import json, sys
path, out = sys.argv[1:]
with open(out, "w") as fh:
    json.dump({"results": [{"check_id": "literal-path", "path": path, "start": {"line": 1},
                           "extra": {"severity": "ERROR", "message": "fixture high"}}],
               "errors": [], "paths": {"scanned": [path]}}, fh)
PY
}

@test "semgrep missing paths.scanned is malformed rather than unknown coverage" {
  printf '%s\n' '{"results":[],"errors":[]}' > "$TEST_ROOT/semgrep.json"
  commit_change
  run_diff
  assert_blocked semgrep SAST
  [[ "$output" == *"semgrep: ran=1 exit=0 parsed=0"* ]]
}

@test "semgrep empty paths.scanned is partial for a covered TypeScript target" {
  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":[]}}' > "$TEST_ROOT/semgrep.json"
  commit_change
  run_diff
  assert_blocked semgrep SAST
  [[ "$output" == *"semgrep did not complete:"*"target not scanned"*"changed.ts"* ]]
}

@test "semgrep must cover each target, not merely return a nonzero scanned count" {
  commit_path other.ts
  commit_change
  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":["other.ts"]}}' > "$TEST_ROOT/semgrep.json"
  run_diff
  assert_blocked semgrep SAST
  [[ "$output" == *"target not scanned"*"changed.ts"* ]]
}

assert_missing_covered_target() {
  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":[]}}' > "$TEST_ROOT/semgrep.json"
  commit_change
  run_diff SECURITY_GATE_STACK_PROFILE="$1"
  assert_blocked semgrep SAST
  [[ "$output" == *"target not scanned"*"changed.ts"* ]]
}

@test "web-next blocks a covered scoped language missing from paths.scanned" {
  assert_missing_covered_target web-next
}

@test "web-static blocks a covered scoped language missing from paths.scanned" {
  assert_missing_covered_target web-static
}

@test "shell-tooling blocks a covered scoped language missing from paths.scanned" {
  assert_missing_covered_target shell-tooling
}

@test "default blocks a covered scoped language missing from paths.scanned" {
  assert_missing_covered_target default
}

@test "CONTROL web profiles do not demand coverage for Python or shell targets" {
  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":[]}}' > "$TEST_ROOT/semgrep.json"
  for path in changed.py changed.sh; do
    commit_path "$path"
    for profile in web-next web-static; do
      run_diff SECURITY_GATE_STACK_PROFILE="$profile"
      assert_mergeable
    done
  done
}

@test "default and shell-tooling profiles require coverage for Python targets" {
  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":[]}}' > "$TEST_ROOT/semgrep.json"
  commit_path changed.py
  for profile in default shell-tooling; do
    run_diff SECURITY_GATE_STACK_PROFILE="$profile"
    assert_blocked semgrep SAST
  done
}

@test "CONTROL semgrep absolute telemetry paths match the scoped target" {
  python3 - "$PROJECT/changed.ts" "$TEST_ROOT/semgrep.json" <<'PY'
import json, sys
with open(sys.argv[2], "w") as fh:
    json.dump({"results": [], "errors": [], "paths": {"scanned": [sys.argv[1]]}}, fh)
PY
  commit_change
  run_diff
  assert_mergeable
}

@test "OSV must report the changed lockfile even if another source was scanned" {
  commit_path package-lock.json
  run_diff OSV_MODE=unrelated
  assert_blocked osv-scanner Deps
  [[ "$output" == *"changed manifest not scanned: package-lock.json"* ]]
}

@test "OSV must report every changed lockfile" {
  printf '%s\n' 'fixture' > "$PROJECT/uv.lock"
  git -C "$PROJECT" add uv.lock
  commit_path package-lock.json
  run_diff OSV_MODE=first-only
  assert_blocked osv-scanner Deps
  [[ "$output" == *"changed manifest not scanned: uv.lock"* ]]
}

@test "OSV uses --no-ignore for a tracked manifest in a gitignored directory" {
  printf 'vendor/\n' > "$PROJECT/.gitignore"
  git -C "$PROJECT" add .gitignore
  git -C "$PROJECT" commit -qm "ignore vendor"
  commit_path vendor/requirements.txt
  run_diff OSV_MODE=needs-no-ignore
  assert_mergeable
  [[ "$output" == *"osv-scanner: ran=1 exit=0 parsed=1 scanned=1"* ]]
}

@test "OSV cannot treat a manifests-only change as covered by an unrelated lockfile" {
  for manifest in js/package.json rust/Cargo.toml python/pyproject.toml; do
    commit_path "$manifest"
    run_diff OSV_MODE=unrelated
    assert_blocked osv-scanner Deps
    [[ "$output" == *"no lockfile osv-scanner can read"*"$manifest"* ]]
  done
}

@test "CONTROL each project manifest accepts a scanned sibling lockfile" {
  for pair in js/package.json:package-lock.json rust/Cargo.toml:Cargo.lock python/pyproject.toml:uv.lock; do
    manifest="${pair%:*}"; lock="${pair#*:}"
    mkdir -p "$PROJECT/$(dirname "$manifest")"
    printf '%s\n' 'fixture' > "$PROJECT/$(dirname "$manifest")/$lock"
    git -C "$PROJECT" add -A
    git -C "$PROJECT" commit -qm "seed sibling lock"
    commit_path "$manifest"
    run_diff
    assert_mergeable
  done
}

@test "OSV exit 128 explains that there is no readable lockfile" {
  commit_path package.json
  run_diff OSV_MODE=no-sources
  assert_blocked osv-scanner Deps
  [[ "$output" == *"osv-scanner did not complete: no lockfile osv-scanner can read"* ]]
}

@test "a non-ASCII TypeScript filename reaches the detector" {
  stub_semgrep_finding évil.ts
  commit_path évil.ts
  run_diff
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"semgrep/literal-path"*"évil.ts"* ]]
  [[ "$output" != *"did not complete:"* ]]
}

@test "a non-ASCII dependency directory requires an OSV scan" {
  commit_path é/package-lock.json
  run_diff OSV_MODE=crash127
  assert_blocked osv-scanner Deps
}

@test "CONTROL non-ASCII dependency paths match the OSV coverage receipt" {
  commit_path é/package-lock.json
  run_diff
  assert_mergeable
  [[ "$output" == *"osv-scanner: ran=1 exit=0 parsed=1 scanned=1"* ]]
}

@test "a symlink to regular TypeScript file type change reaches the detector" {
  ln -s missing "$PROJECT/app.ts"
  git -C "$PROJECT" add app.ts
  git -C "$PROJECT" commit -qm "seed symlink"
  rm "$PROJECT/app.ts"
  stub_semgrep_finding app.ts
  commit_path app.ts
  run_diff
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"semgrep/literal-path"*"app.ts"* ]]
  [[ "$output" != *"did not complete:"* ]]
}

@test "literal quotes, tabs and newlines in source paths reach the detector" {
  for path in 'quote".ts' $'tab\t.ts' $'line\n.ts'; do
    stub_semgrep_finding "$path"
    commit_path "$path"
    run_diff
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"semgrep/literal-path"* ]]
    [[ "$output" != *"did not complete:"* ]]
  done
}

# Round 3: Git-visible dependencies, workspace locks and ambiguous names.
stub_osv_findings() {
  python3 - "$TEST_ROOT/osv-scanner.json" "$@" <<'PY'
import json, sys
results = []
for i, path in enumerate(sys.argv[2:], 1):
    results.append({"source": {"path": path}, "packages": [{
        "package": {"name": "fixture", "version": "1.0", "ecosystem": "npm"},
        "vulnerabilities": [{"id": f"fixture-vuln-{i}", "summary": "fixture high",
                             "database_specific": {"severity": "HIGH"}}], "groups": []}]})
with open(sys.argv[1], "w") as fh: json.dump({"results": results}, fh)
PY
}

seed_untracked_worktree_lock() {
  printf '.claude/worktrees/\n' > "$PROJECT/.gitignore"
  git -C "$PROJECT" add .gitignore
  git -C "$PROJECT" commit -qm "ignore local worktrees"
  mkdir -p "$PROJECT/.claude/worktrees/other"
  printf '%s\n' 'local fixture' > "$PROJECT/.claude/worktrees/other/package-lock.json"
}

@test "OSV ignores untracked ignored worktree findings and coverage receipts" {
  seed_untracked_worktree_lock
  commit_path package-lock.json
  stub_osv_findings "$PROJECT/.claude/worktrees/other/package-lock.json"
  run_diff OSV_MODE=local-findings
  assert_mergeable
  [[ "$output" == *"osv-scanner: ran=1 exit=1 parsed=1 scanned=1"* ]]
  [[ "$output" != *"fixture-vuln-1"* ]]
}

@test "OSV drops untracked findings without dropping tracked high findings" {
  seed_untracked_worktree_lock
  commit_path package-lock.json
  stub_osv_findings "$PROJECT/.claude/worktrees/other/package-lock.json" "$PROJECT/package-lock.json"
  run_diff OSV_MODE=local-findings
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]]
  [[ "$output" == *"osv/fixture-vuln-2"* ]]
  [[ "$output" != *"fixture-vuln-1"* ]]
  [[ "$output" != *"did not complete:"* ]]
}

@test "the two-argument OSV helper also drops untracked baseline findings" {
  seed_untracked_worktree_lock
  commit_path package-lock.json
  stub_osv_findings "$PROJECT/.claude/worktrees/other/package-lock.json"
  run env PATH="$BIN" OSV_MODE=local-findings \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run python3 -c 'import sys; assert not open(sys.argv[1]).read().strip()' "$TEST_ROOT/normalized.jsonl"
  [ "$status" -eq 0 ]
}

@test "OSV cannot silently drop a finding whose source path is malformed" {
  commit_path package-lock.json
  stub_osv_findings ""
  run_diff OSV_MODE=local-findings
  assert_blocked osv-scanner Deps
  [[ "$output" == *"missing or malformed JSON"* ]]
}

@test "an untracked lockfile receipt cannot cover a changed tracked manifest" {
  printf '%s\n' 'untracked lock' > "$PROJECT/package-lock.json"
  commit_path package.json
  run_diff OSV_MODE=first-only
  assert_blocked osv-scanner Deps
  [[ "$output" == *"no lockfile osv-scanner can read: package.json"* ]]
}

seed_workspace_lock() {
  local ecosystem="$1" member="${2:-member}" rel="members/component"
  [ "$member" = member ] || rel="members/other"
  WORKSPACE_MANIFEST=package.json
  case "$ecosystem" in
    npm)
      WORKSPACE_LOCK=package-lock.json
      printf '{"lockfileVersion":3,"packages":{"":{"name":"root"},"%s":{"name":"component"}},"description":"members/component"}\n' "$rel" > "$PROJECT/$WORKSPACE_LOCK"
      ;;
    pnpm)
      WORKSPACE_LOCK=pnpm-lock.yaml
      printf 'lockfileVersion: "9.0"\nimporters:\n  .: {}\n  "%s": {}\npackages:\n  "members/component": {}\n' "$rel" > "$PROJECT/$WORKSPACE_LOCK"
      ;;
    bun)
      WORKSPACE_LOCK=bun.lock
      # Bun's text lock is JSONC: comments/trailing commas must not hide a key.
      printf '{\n  // workspace lock\n  "lockfileVersion": 1,\n  "workspaces": {"": {"name": "root"}, "%s": {"name": "component"},},\n  "packages": {"members/component": []},\n}\n' "$rel" > "$PROJECT/$WORKSPACE_LOCK"
      ;;
    yarn)
      WORKSPACE_LOCK=yarn.lock
      printf '__metadata:\n  version: 8\n  cacheKey: "component@workspace:members/component"\n\n"component@workspace:%s":\n  version: 0.0.0-use.local\n  resolution: "component@workspace:%s"\n' "$rel" "$rel" > "$PROJECT/$WORKSPACE_LOCK"
      ;;
    uv)
      WORKSPACE_MANIFEST=pyproject.toml; WORKSPACE_LOCK=uv.lock
      printf 'version = 1\n[[package]]\nname = "component"\nversion = "1.0.0"\nsource = { editable = "%s" }\n' "$rel" > "$PROJECT/$WORKSPACE_LOCK"
      ;;
    cargo)
      WORKSPACE_MANIFEST=Cargo.toml; WORKSPACE_LOCK=Cargo.lock
      local name=component
      [ "$member" = member ] || name=other
      printf '[workspace]\nmembers = ["%s"]\n' "$rel" > "$PROJECT/Cargo.toml"
      git -C "$PROJECT" add -- Cargo.toml
      printf 'version = 3\n[[package]]\nname = "%s"\nversion = "1.0.0"\n[[package]]\nname = "component"\nversion = "2.0.0"\nsource = "registry+https://example.invalid/index"\n' "$name" > "$PROJECT/$WORKSPACE_LOCK"
      ;;
    *) return 1 ;;
  esac
  git -C "$PROJECT" add -- "$WORKSPACE_LOCK"
  git -C "$PROJECT" commit -qm "seed $ecosystem workspace lock"
}

commit_workspace_manifest() {
  mkdir -p "$PROJECT/members/component"
  case "$WORKSPACE_MANIFEST" in
    package.json) printf '%s\n' '{"name":"component","dependencies":{"minimist":"0.0.8"}}' > "$PROJECT/members/component/$WORKSPACE_MANIFEST" ;;
    Cargo.toml) printf '[package]\nname = "component"\nversion = "1.0.0"\n' > "$PROJECT/members/component/$WORKSPACE_MANIFEST" ;;
    pyproject.toml) printf '[project]\nname = "component"\nversion = "1.0.0"\n' > "$PROJECT/members/component/$WORKSPACE_MANIFEST" ;;
  esac
  git -C "$PROJECT" add -- "members/component/$WORKSPACE_MANIFEST"
  git -C "$PROJECT" commit -qm "change workspace manifest"
}

@test "CONTROL workspace members accept a scanned tracked root ecosystem lock" {
  for ecosystem in npm cargo uv; do
    seed_workspace_lock "$ecosystem" member
    commit_workspace_manifest
    run_diff
    assert_mergeable
  done
}

@test "workspace members block when their tracked root lock is not scanned" {
  for pair in package.json:package-lock.json Cargo.toml:Cargo.lock pyproject.toml:uv.lock; do
    manifest="${pair%:*}"; lock="${pair#*:}"
    commit_path "$lock"
    commit_path "members/component/$manifest"
    run_diff OSV_MODE=omitted
    assert_blocked osv-scanner Deps
    [[ "$output" == *"no lockfile osv-scanner can read"*"members/component/$manifest"* ]]
  done
}

@test "a scanned root lock cannot excuse an unscanned nearer tracked lock" {
  commit_path package-lock.json
  commit_path members/package-lock.json
  commit_path members/package.json
  run_diff OSV_MODE=first-only
  assert_blocked osv-scanner Deps
  [[ "$output" == *"no lockfile osv-scanner can read: members/package.json"* ]]
}

@test "suffix-only source filenames still require Semgrep coverage" {
  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":[]}}' > "$TEST_ROOT/semgrep.json"
  commit_path .ts
  run_diff
  assert_blocked semgrep SAST
  [[ "$output" == *"target not scanned"*".ts"* ]]
}

@test "CONTROL a suffix-only source filename with a valid receipt is mergeable" {
  printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":[".ts"]}}' > "$TEST_ROOT/semgrep.json"
  commit_path .ts
  run_diff
  assert_mergeable
}

@test "changed manifest paths with control characters or percent are blocked" {
  for path in 'bad%0Aname/package-lock.json' $'bad\tname/package-lock.json' \
    $'bad\nname/package-lock.json' $'bad\rname/package-lock.json' $'bad\177name/package-lock.json'; do
    commit_path "$path"
    run_diff
    assert_blocked osv-scanner Deps
    [[ "$output" == *"changed manifest path contains control character or %"* ]]
  done
}

@test "relative OSV receipts do not prove coverage of a tracked manifest" {
  commit_path package-lock.json
  run_diff OSV_MODE=relative
  assert_blocked osv-scanner Deps
  [[ "$output" == *"changed manifest not scanned: package-lock.json"* ]]
}

# Round 4: prove ancestor membership, retain submodule/directory sources,
# and separate optional helper inputs by name (including B0-3's config file).

assert_nonmember_blocked() {
  seed_workspace_lock "$1" nonmember
  commit_workspace_manifest
  run_diff
  assert_blocked osv-scanner Deps
  [[ "$output" == *"ancestor lockfile does not name member: members/component/$WORKSPACE_MANIFEST"* ]]
}

assert_member_covered() {
  seed_workspace_lock "$1" member
  commit_workspace_manifest
  run_diff
  assert_mergeable
}

@test "npm ancestor lock cannot cover a non-member package.json" {
  assert_nonmember_blocked npm
}

@test "pnpm ancestor lock cannot cover a non-member package.json" {
  assert_nonmember_blocked pnpm
}

@test "bun ancestor lock cannot cover a non-member package.json" {
  assert_nonmember_blocked bun
}

@test "yarn ancestor lock cannot cover a non-member package.json" {
  assert_nonmember_blocked yarn
}

@test "uv ancestor lock cannot cover a non-member pyproject.toml" {
  assert_nonmember_blocked uv
}

@test "Cargo ancestor lock cannot cover a registry package named like a non-member" {
  assert_nonmember_blocked cargo
}

@test "CONTROL npm packages entry proves ancestor workspace membership" {
  assert_member_covered npm
}

@test "CONTROL pnpm importers entry proves ancestor workspace membership" {
  assert_member_covered pnpm
}

@test "CONTROL bun JSONC workspaces entry proves ancestor workspace membership" {
  assert_member_covered bun
}

@test "CONTROL yarn workspace descriptor proves ancestor workspace membership" {
  assert_member_covered yarn
}

@test "CONTROL uv editable source proves ancestor workspace membership" {
  assert_member_covered uv
}

@test "CONTROL Cargo source-less package name proves ancestor workspace membership" {
  assert_member_covered cargo
}

@test "CONTROL uv virtual source also proves ancestor workspace membership" {
  seed_workspace_lock uv member
  printf 'version = 1\n[[package]]\nname = "component"\nversion = "1.0.0"\nsource = { virtual = "members/component" }\n' > "$PROJECT/uv.lock"
  git -C "$PROJECT" add uv.lock
  git -C "$PROJECT" commit -qm "virtual workspace member"
  commit_workspace_manifest
  run_diff
  assert_mergeable
}

@test "a pnpm importer string is not a workspace mapping" {
  seed_workspace_lock pnpm nonmember
  printf 'lockfileVersion: "9.0"\nimporters:\n  "members/component": "{}"\n' > "$PROJECT/pnpm-lock.yaml"
  git -C "$PROJECT" add pnpm-lock.yaml
  git -C "$PROJECT" commit -qm "scalar importer decoy"
  commit_workspace_manifest
  run_diff
  assert_blocked osv-scanner Deps
  [[ "$output" == *"ancestor lockfile does not name member"* ]]
}

@test "a yarn descriptor string is not a workspace package mapping" {
  seed_workspace_lock yarn nonmember
  printf '"component@workspace:members/component": "{}"\n' > "$PROJECT/yarn.lock"
  git -C "$PROJECT" add yarn.lock
  git -C "$PROJECT" commit -qm "scalar descriptor decoy"
  commit_workspace_manifest
  run_diff
  assert_blocked osv-scanner Deps
  [[ "$output" == *"ancestor lockfile does not name member"* ]]
}

@test "a malformed ancestor lock cannot prove workspace membership" {
  seed_workspace_lock npm member
  printf '%s\n' '{not-json members/component' > "$PROJECT/package-lock.json"
  git -C "$PROJECT" add package-lock.json
  git -C "$PROJECT" commit -qm "malformed workspace lock"
  commit_workspace_manifest
  run_diff
  assert_blocked osv-scanner Deps
  [[ "$output" == *"ancestor lockfile does not name member"* ]]
}

seed_submodule_lock() {
  local source="$TEST_ROOT/submodule-source"
  mkdir -p "$source"
  git -C "$source" init -q
  git -C "$source" config user.email "security-gate@trellis.test"
  git -C "$source" config user.name "trellis test"
  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$source/package-lock.json"
  git -C "$source" add package-lock.json
  git -C "$source" commit -qm "submodule lock"
  git -C "$PROJECT" -c protocol.file.allow=always submodule add -q "$source" vendor/deps
  git -C "$PROJECT" commit -qam "track dependency submodule"
}

assert_normalized_high() {
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run python3 -c 'import json, sys; rows = [json.loads(line) for line in open(sys.argv[1])]; assert len(rows) == 1; assert rows[0]["file"] == sys.argv[2]; assert rows[0]["severity"] == "high"' \
    "$TEST_ROOT/normalized.jsonl" "$1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "OSV baseline helper retains a tracked submodule lockfile finding" {
  seed_submodule_lock
  stub_osv_findings "$PROJECT/vendor/deps/package-lock.json"
  run env PATH="$BIN" OSV_MODE=findings \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl"
  assert_normalized_high vendor/deps/package-lock.json
}

@test "OSV diff helper's named tracked list includes submodule lockfiles" {
  seed_submodule_lock
  commit_path package-lock.json
  stub_osv_findings "$PROJECT/vendor/deps/package-lock.json"
  run_diff OSV_MODE=findings
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"osv/fixture-vuln-1"*"vendor/deps/package-lock.json"* ]]
  [[ "$output" != *"did not complete:"* ]]
}

@test "OSV retains a directory source containing tracked dependency files" {
  commit_path vendor/deps/package-lock.json
  stub_osv_findings "$PROJECT/vendor/deps"
  run env PATH="$BIN" OSV_MODE=findings \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl"
  assert_normalized_high vendor/deps
}

@test "OSV does not confuse a directory prefix with tracked descendants" {
  commit_path vendor/deps-other/package-lock.json
  stub_osv_findings "$PROJECT/vendor/deps"
  run env PATH="$BIN" OSV_MODE=findings \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run python3 -c 'import sys; assert not open(sys.argv[1]).read().strip()' "$TEST_ROOT/normalized.jsonl"
  [ "$status" -eq 0 ]
}

prepare_named_osv_inputs() {
  commit_path package-lock.json
  printf 'package-lock.json\0' > "$TEST_ROOT/changed.list"
  git -C "$PROJECT" ls-files -z --recurse-submodules > "$TEST_ROOT/tracked.list"
  : > "$TEST_ROOT/empty.config"
  # Against the old positional interface, named flags can become status paths.
  # Keep those intentionally failing-first artifacts inside the scratch repo.
  cd "$TEST_ROOT" || return 1
}

@test "an empty named config never disables changed-manifest coverage" {
  prepare_named_osv_inputs
  run env PATH="$BIN" OSV_MODE=omitted \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl" \
    --config "$TEST_ROOT/empty.config" --changed-manifests "$TEST_ROOT/changed.list" \
    --tracked "$TEST_ROOT/tracked.list" --status "$TEST_ROOT/helper.status"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"changed manifest not scanned: package-lock.json"* ]]
}

@test "CONTROL named optional files preserve tracked coverage and status" {
  prepare_named_osv_inputs
  run env PATH="$BIN" OSV_MODE=needs-config \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl" \
    --tracked "$TEST_ROOT/tracked.list" --status "$TEST_ROOT/helper.status" \
    --changed-manifests "$TEST_ROOT/changed.list" --config "$TEST_ROOT/empty.config"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run python3 -c 'import sys; assert open(sys.argv[1]).read().strip() == "osv-scanner: ran=1 exit=0 parsed=1 scanned=1"' "$TEST_ROOT/helper.status"
  [ "$status" -eq 0 ]
}

@test "missing named config cannot empty the changed-manifest list" {
  prepare_named_osv_inputs
  run env PATH="$BIN" \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl" \
    --config "$TEST_ROOT/missing.config" --changed-manifests "$TEST_ROOT/changed.list"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"config file is missing or unreadable"* ]]
}

@test "missing or empty named input files fail closed rather than disable coverage" {
  prepare_named_osv_inputs
  : > "$TEST_ROOT/empty.list"
  for flag in --changed-manifests --tracked; do
    args=()
    [ "$flag" != --tracked ] || args=(--changed-manifests "$TEST_ROOT/changed.list")
    for file in missing.list empty.list; do
      run env PATH="$BIN" \
        bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl" \
        "${args[@]+"${args[@]}"}" "$flag" "$TEST_ROOT/$file"
      [ "$status" -eq 2 ] || { echo "$output"; false; }
      [[ "$output" == *"osv-scanner did not complete:"* ]]
      [[ "$output" == *"$flag file is missing, unreadable or empty"* ]]
    done
  done
}

@test "legacy positional optional files cannot silently turn off coverage" {
  prepare_named_osv_inputs
  run env PATH="$BIN" \
    bash "$SCRIPT_ROOT/scripts/lib/osv.sh" "$PROJECT" "$TEST_ROOT/normalized.jsonl" \
    "$TEST_ROOT/helper.status" "$TEST_ROOT/empty.config" "$TEST_ROOT/tracked.list"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"unknown option or positional argument"* ]]
}

# Round 5: Cargo names establish identity, not workspace membership.
seed_cargo_membership_workspace() {
  mkdir -p "$PROJECT/core"
  printf '[workspace]\nmembers = %s\nexclude = %s\nresolver = "2"\n' "$1" "$2" > "$PROJECT/Cargo.toml"
  printf 'version = 4\n[[package]]\nname = "core-lib"\nversion = "0.1.0"\n' > "$PROJECT/Cargo.lock"
  printf '[package]\nname = "core-lib"\nversion = "0.1.0"\nedition = "2021"\n' > "$PROJECT/core/Cargo.toml"
  git -C "$PROJECT" add -- Cargo.toml Cargo.lock core/Cargo.toml
  git -C "$PROJECT" commit -qm "seed Cargo workspace membership"
}

commit_same_name_cargo_manifest() {
  mkdir -p "$PROJECT/$(dirname "$1")"
  printf '[package]\nname = "core-lib"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nsmallvec = "=0.6.9"\n' > "$PROJECT/$1"
  [ "${2:-}" != own-workspace ] || printf '[workspace]\n' >> "$PROJECT/$1"
  git -C "$PROJECT" add -- "$1"
  git -C "$PROJECT" commit -qm "change same-name Cargo manifest"
}

assert_cargo_membership_blocked() {
  run_diff
  assert_blocked osv-scanner Deps
  [[ "$output" == *"ancestor lockfile does not name member: $1"* ]]
}

@test "Cargo same-name excluded non-member with its own workspace blocks" {
  seed_cargo_membership_workspace '["core"]' '["fuzz"]'
  commit_same_name_cargo_manifest fuzz/Cargo.toml own-workspace
  assert_cargo_membership_blocked fuzz/Cargo.toml
}

@test "Cargo same-name non-member cannot borrow an ancestor lock without an exclude" {
  seed_cargo_membership_workspace '["core"]' '[]'
  commit_same_name_cargo_manifest fuzz/Cargo.toml
  assert_cargo_membership_blocked fuzz/Cargo.toml
}

@test "Cargo declared member with its own workspace cannot borrow an ancestor lock" {
  seed_cargo_membership_workspace '["members/*"]' '[]'
  commit_same_name_cargo_manifest members/component/Cargo.toml own-workspace
  assert_cargo_membership_blocked members/component/Cargo.toml
}

@test "Cargo exclude glob overrides a matching members glob for the same crate name" {
  seed_cargo_membership_workspace '["members/**"]' '["members/*"]'
  commit_same_name_cargo_manifest members/component/Cargo.toml
  assert_cargo_membership_blocked members/component/Cargo.toml
}

@test "Cargo single-component member glob cannot authorize a deeper same-name crate" {
  seed_cargo_membership_workspace '["members/*"]' '[]'
  commit_same_name_cargo_manifest members/group/component/Cargo.toml
  assert_cargo_membership_blocked members/group/component/Cargo.toml
}

@test "Cargo malformed exclude list cannot authorize a same-name workspace member" {
  seed_cargo_membership_workspace '["members/*"]' '"members/component"'
  commit_same_name_cargo_manifest members/component/Cargo.toml
  assert_cargo_membership_blocked members/component/Cargo.toml
}

@test "Cargo untracked root workspace cannot authorize a same-name crate" {
  printf 'version = 4\n[[package]]\nname = "core-lib"\nversion = "0.1.0"\n' > "$PROJECT/Cargo.lock"
  git -C "$PROJECT" add Cargo.lock
  git -C "$PROJECT" commit -qm "seed Cargo lock only"
  printf '[workspace]\nmembers = ["members/*"]\n' > "$PROJECT/Cargo.toml"
  commit_same_name_cargo_manifest members/component/Cargo.toml
  assert_cargo_membership_blocked members/component/Cargo.toml
}

@test "CONTROL Cargo root members glob authorizes a scanned ancestor lock" {
  seed_cargo_membership_workspace '["members/*"]' '[]'
  commit_same_name_cargo_manifest members/component/Cargo.toml
  run_diff
  assert_mergeable
  [[ "$output" == *"osv-scanner: ran=1 exit=0 parsed=1 scanned=1"* ]]
}

@test "CONTROL Cargo recursive members glob authorizes a nested member" {
  seed_cargo_membership_workspace '["members/**"]' '[]'
  commit_same_name_cargo_manifest members/group/component/Cargo.toml
  run_diff
  assert_mergeable
}

@test "CONTROL Cargo workspace-root change retains scanned sibling lock coverage" {
  seed_cargo_membership_workspace '["core"]' '["fuzz"]'
  printf '# changed root workspace\n' >> "$PROJECT/Cargo.toml"
  git -C "$PROJECT" add Cargo.toml
  git -C "$PROJECT" commit -qm "change workspace root"
  run_diff
  assert_mergeable
  [[ "$output" == *"osv-scanner: ran=1 exit=0 parsed=1 scanned=1"* ]]
}

# Round 6: literal Cargo excludes cover descendants, not same-prefix siblings.
@test "Cargo literal exclude prefix blocks a nested same-name workspace crate" {
  seed_cargo_membership_workspace '["crates/*/*"]' '["crates/old"]'
  commit_same_name_cargo_manifest crates/old/x/Cargo.toml
  assert_cargo_membership_blocked crates/old/x/Cargo.toml
}

@test "Cargo normalizes dot and trailing slash in literal exclude prefixes" {
  seed_cargo_membership_workspace '["crates/*/*"]' '["./crates/old/"]'
  commit_same_name_cargo_manifest crates/old/x/Cargo.toml
  assert_cargo_membership_blocked crates/old/x/Cargo.toml
}

@test "CONTROL Cargo literal exclude prefix does not exclude same-prefix siblings" {
  seed_cargo_membership_workspace '["crates/*/*"]' '["crates/old"]'
  commit_same_name_cargo_manifest crates/older/x/Cargo.toml
  run_diff
  assert_mergeable
  [[ "$output" == *"osv-scanner: ran=1 exit=0 parsed=1 scanned=1"* ]]
}

# Round 8: OSV receipts Go modules, not checksum files; all JS locks trigger it.
seed_go_module() {
  mkdir -p "$PROJECT/$1"
  printf 'module example.com/fixture\n\ngo 1.23\n' > "$PROJECT/$1/go.mod"
  git -C "$PROJECT" add -- "$1/go.mod"
  git -C "$PROJECT" commit -qm "seed Go module"
}

@test "a changed go.sum is covered by its scanned sibling go.mod" {
  seed_go_module g
  commit_path g/go.sum
  run_diff
  assert_mergeable
  [[ "$output" == *"osv-scanner: ran=1 exit=0 parsed=1 scanned=1"* ]]
}

@test "a changed go.sum blocks when its sibling go.mod has no receipt" {
  seed_go_module g
  commit_path g/go.sum
  run_diff OSV_MODE=omitted
  assert_blocked osv-scanner Deps
  [[ "$output" == *"changed manifest not scanned: g/go.sum"* ]]
}

@test "a go.mod receipt in another directory cannot cover a changed go.sum" {
  seed_go_module other
  commit_path g/go.sum
  run_diff
  assert_blocked osv-scanner Deps
  [[ "$output" == *"changed manifest not scanned: g/go.sum"* ]]
}

@test "Bun and npm shrinkwrap lockfile-only changes require osv-scanner" {
  mv "$BIN/osv-scanner" "$BIN/osv-scanner.disabled"
  for lock in bun.lock bun.lockb npm-shrinkwrap.json; do
    commit_path "$lock"
    run_diff
    assert_blocked osv-scanner Deps
    [[ "$output" == *"osv-scanner did not complete: binary not installed"* ]]
  done
}

@test "process-gate adapter surfaces the scanner failure reason and rc" {
  commit_change
  run env PATH="$BIN" CODEX_PROJECT_DIR="$PROJECT" CLAUDE_PROJECT_DIR="$PROJECT" \
    SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_PROJECT_NAME=project \
    SEMGREP_MODE=crash PG_MODE=push \
    bash "$SCRIPT_ROOT/../process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD
  assert_blocked semgrep SAST
}

record_semgrep_args() {
  rm "$BIN/semgrep"
  mkdir -p "$BIN/.inner"
  ln -s ../scanner "$BIN/.inner/semgrep"
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SCANNER_FIXTURES/semgrep.args"
exec "$(dirname "$0")/.inner/semgrep" "$@"
SH
  chmod +x "$BIN/semgrep"
}

semgrep_timeout_arg() {
  awk 'prev == "--timeout" { print; exit } { prev = $0 }' "$TEST_ROOT/semgrep.args"
}

@test "semgrep gets a per-file rule timeout, 30 s by default" {
  record_semgrep_args
  commit_change
  run_diff
  assert_mergeable
  [ "$(semgrep_timeout_arg)" = 30 ] || { cat "$TEST_ROOT/semgrep.args"; false; }
}

@test "SECURITY_GATE_SEMGREP_TIMEOUT sets the semgrep rule timeout" {
  record_semgrep_args
  commit_change
  run_diff SECURITY_GATE_SEMGREP_TIMEOUT=90
  assert_mergeable
  [ "$(semgrep_timeout_arg)" = 90 ]
}

@test "an invalid or zero semgrep timeout falls back to the default, never to no timeout" {
  record_semgrep_args
  commit_change
  for value in 0 abc 601 -5; do
    run_diff SECURITY_GATE_SEMGREP_TIMEOUT="$value"
    assert_mergeable
    [ "$(semgrep_timeout_arg)" = 30 ] || { echo "value=$value"; cat "$TEST_ROOT/semgrep.args"; false; }
    [[ "$output" == *"SECURITY_GATE_SEMGREP_TIMEOUT"* ]] || { echo "no warning for $value: $output"; false; }
  done
}

@test "a semgrep rule timeout still blocks SAST" {
  printf '%s\n' '{"results":[],"errors":[{"message":"Timeout","type":"Timeout","path":"changed.ts"}],"paths":{"scanned":["changed.ts"]}}' > "$TEST_ROOT/semgrep.json"
  commit_change
  run_diff SECURITY_GATE_SEMGREP_TIMEOUT=90
  assert_blocked semgrep SAST
}
