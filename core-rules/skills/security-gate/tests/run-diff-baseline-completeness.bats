#!/usr/bin/env bats
# A baseline that says it is incomplete cannot carry a diff to MERGEABLE: its
# empty findings do not show the rest of the tree is clean. Diff mode reports
# the baseline's completeness in its verdict and BLOCKS on an incomplete one,
# on every path that can return a verdict. A baseline older than 1.4.2 has no
# completion fields; it keeps its old behaviour, and the verdict says its
# completeness is unknown. Red-team mode surfaces the same state.

setup() {
  REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)"
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/run-diff-baseline-completeness.XXXXXX")"
  PROJECT="$SANDBOX/project"
  BIN="$SANDBOX/bin"
  PROJECT_NAME="${PROJECT##*/}"
  mkdir -p "$PROJECT/audits" "$BIN"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "security gate test"
  cat > "$BIN/semgrep" <<'SH'
#!/bin/bash
printf '%s\n' '{"results":[],"errors":[],"paths":{"scanned":[]}}'
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '[]\n' > "$report"
SH
  chmod 755 "$BIN/semgrep" "$BIN/gitleaks"
  printf 'export const app = 1;\n' > "$PROJECT/app.ts"
  SCRIPT_DIR="$REPO_ROOT/core-rules/skills/security-gate/scripts"
  PYTHON_DIR="$(dirname "$(command -v python3)")"
  BASELINE="$PROJECT/audits/2026-01-01-baseline-$PROJECT_NAME.json"
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    (CDPATH='' cd "${SANDBOX%/*}" && rm -rf "${SANDBOX##*/}")
  fi
}

# seed <baseline-json>: commits the baseline and source as the range base.
seed() {
  printf '%s\n' "$1" > "$BASELINE"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "seed base"
}

docs_change() {
  printf '# notes\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" commit -qm "docs only"
}

run_diff() {
  run env PATH="$BIN:$PYTHON_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    SECURITY_GATE_PROJECT_NAME="$PROJECT_NAME" \
    bash "$SCRIPT_DIR/run-diff.sh" "$PROJECT" --range="${1:-HEAD~1..HEAD}" --no-llm
}

INCOMPLETE='{"schema":"security-gate.baseline.v2","profile":"web-next","complete":false,"engines":{"semgrep":{"status":"failed","exit":2},"osv-scanner":{"status":"not_applicable","exit":3},"gitleaks":{"status":"ok","exit":0}},"findings":[],"historical_findings":[]}'

@test "an incomplete committed baseline plus a docs-only change is BLOCKED, never MERGEABLE" {
  # Inversion (review R3/F2): run-diff read only findings, so this returned
  # MERGEABLE/0 with every row green and no word about the baseline.
  seed "$INCOMPLETE"
  docs_change
  run_diff
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Baseline:          ❌ incomplete (semgrep failed)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"security-gate: baseline ${BASELINE##*/} is incomplete (semgrep failed)"* ]] || { echo "$output"; false; }
}

@test "an incomplete baseline also blocks the empty-range early return" {
  seed "$INCOMPLETE"
  run_diff HEAD..HEAD
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"incomplete (semgrep failed)"* ]] || { echo "$output"; false; }
}

@test "a baseline whose completion fields cannot be trusted blocks" {
  # complete:true contradicted by a failed engine, and a baseline that is not JSON.
  seed '{"profile":"web-next","complete":true,"engines":{"semgrep":{"status":"failed","exit":2},"osv-scanner":{"status":"ok","exit":0},"gitleaks":{"status":"ok","exit":0}},"findings":[]}'
  docs_change
  run_diff
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"❌ incomplete (semgrep failed)"* ]] || { echo "$output"; false; }

  printf '{not json\n' > "$BASELINE"
  git -C "$PROJECT" commit -qam "broken baseline"
  run_diff HEAD..HEAD
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Baseline:          ❌ unreadable"* ]] || { echo "$output"; false; }
}

@test "a complete baseline, with an engine not applicable, still allows MERGEABLE" {
  seed '{"schema":"security-gate.baseline.v2","profile":"web-next","complete":true,"engines":{"semgrep":{"status":"ok","exit":0},"osv-scanner":{"status":"not_applicable","exit":3},"gitleaks":{"status":"ok","exit":0}},"findings":[],"historical_findings":[]}'
  docs_change
  run_diff
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || false
  [[ "$output" == *"Baseline:          complete — ${BASELINE##*/}"* ]] || { echo "$output"; false; }
}

@test "a pre-1.4.2 baseline keeps its behaviour and says its completeness is unknown" {
  seed '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}'
  docs_change
  run_diff
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || false
  [[ "$output" == *"Baseline:          baseline completeness unknown (pre-1.4.2 baseline) — ${BASELINE##*/}"* ]] || { echo "$output"; false; }
}

@test "red-team mode surfaces an incomplete baseline instead of dropping it" {
  seed "$INCOMPLETE"
  run env PATH="$BIN:$PYTHON_DIR:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/run-redteam.sh" "$PROJECT" data-exfil --confirm --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"baseline completeness: incomplete (semgrep failed)"* ]] || { echo "$output"; false; }
  grep -Fq -- '- completeness: incomplete (semgrep failed)' "$PROJECT/audits/"*-redteam-"$PROJECT_NAME"-data-exfil.md
}

@test "red-team refuses a helper symlinked into the scanned project" {
  seed "$INCOMPLETE"
  mkdir -p "$PROJECT/.tools"
  printf '#!/bin/sh\n: > "%s"\nexec /bin/cat "$@"\n' "$SANDBOX/project-helper-ran" > "$PROJECT/.tools/cat"
  chmod +x "$PROJECT/.tools/cat"
  ln -s "$PROJECT/.tools/cat" "$BIN/cat"
  run env PATH="$BIN:$PYTHON_DIR:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/run-redteam.sh" "$PROJECT" data-exfil --confirm --no-llm
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"cat"*"$BIN/cat"* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/project-helper-ran" ]
}

@test "red-team never imports a module planted in the scanned project" {
  # Inversion (security review): its python3 heredocs ran without -I from the
  # cwd, so the scanned repo's json.py or re.py loaded first.
  seed "$INCOMPLETE"
  for mod in json re; do
    printf 'open(%s, "w").write("imported")\nraise SystemExit(0)\n' "'$SANDBOX/planted-$mod'" > "$PROJECT/$mod.py"
  done
  run env PATH="$BIN:$PYTHON_DIR:/usr/bin:/bin" \
    bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$SCRIPT_DIR/run-redteam.sh" "$PROJECT" data-exfil --confirm --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/planted-json" ] && [ ! -e "$SANDBOX/planted-re" ] || { echo "planted module imported"; false; }
  [[ "$output" == *"baseline completeness: incomplete (semgrep failed)"* ]] || { echo "$output"; false; }
}

@test "a complete:true baseline must match the schema to count as complete" {
  # Inversion (review r2 Astra N2): any ok/not_applicable status set passed,
  # whatever the exits, the engines the profile needs, or which engine may be
  # not applicable.
  local ok='"semgrep":{"status":"ok","exit":0},"osv-scanner":{"status":"ok","exit":0},"gitleaks":{"status":"ok","exit":0}'
  local bad
  for bad in \
    '"profile":"web-next","complete":true' \
    '"profile":"web-next","engines":{"semgrep":{"status":"failed","exit":2},"osv-scanner":{"status":"ok","exit":0},"gitleaks":{"status":"ok","exit":0}}' \
    '"profile":"web-next","complete":true,"engines":{"semgrep":{"status":"ok","exit":42},"osv-scanner":{"status":"ok","exit":0},"gitleaks":{"status":"ok","exit":0}}' \
    '"profile":"web-rag-llm","complete":true,"engines":{"semgrep":{"status":"ok","exit":0}}' \
    '"profile":"web-rag-llm","complete":true,"engines":{'"$ok"'}' \
    '"profile":"web-next","complete":true,"engines":{"semgrep":{"status":"not_applicable","exit":42},"osv-scanner":{"status":"not_applicable","exit":3},"gitleaks":{"status":"not_applicable","exit":42}}' \
    '"profile":"web-next","complete":false,"engines":{'"$ok"'}' \
    '"profile":"web-next","complete":"yes","engines":{'"$ok"'}' \
    '"complete":true,"engines":{'"$ok"'}' \
    '"profile":"web-next","complete":true,"engines":{'"$ok"',"extra":{"status":"ok","exit":0}}'; do
    rm -rf "$PROJECT/.git" "$BASELINE"
    git -C "$PROJECT" init -q
    git -C "$PROJECT" config user.email "security-gate@trellis.test"
    git -C "$PROJECT" config user.name "security gate test"
    rm -f "$PROJECT/README.md"
    seed "{$bad,\"findings\":[],\"historical_findings\":[]}"
    docs_change
    run_diff
    [ "$status" -eq 1 ] || { echo "$bad => rc=$status; $output"; false; }
    [[ "$output" == *"Baseline:          ❌ incomplete ("* ]] || { echo "$bad => $output"; false; }
  done

  # The schema's own positive case: web-rag-llm with its garak record.
  rm -rf "$PROJECT/.git" "$BASELINE" "$PROJECT/README.md"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "security gate test"
  seed '{"profile":"web-rag-llm","complete":true,"engines":{'"$ok"',"garak":{"status":"ok","exit":0}},"findings":[],"historical_findings":[]}'
  docs_change
  run_diff
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Baseline:          complete — "* ]] || { echo "$output"; false; }
}

@test "red-team reads completeness through the same schema" {
  seed '{"profile":"web-next","complete":true,"engines":{"semgrep":{"status":"ok","exit":42},"osv-scanner":{"status":"ok","exit":0},"gitleaks":{"status":"ok","exit":0}},"findings":[],"historical_findings":[]}'
  run env PATH="$BIN:$PYTHON_DIR:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/run-redteam.sh" "$PROJECT" data-exfil --confirm --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"baseline completeness: incomplete (semgrep ok with exit 42)"* ]] || { echo "$output"; false; }
}

# A pyenv-style python3 shim outside the project, steered by the project's
# .python-version (or PYENV_VERSION) to a hostile "version" that marks it ran.
pyenv_shim() {
  local real versions="$1/pyenv/versions"
  real="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  SHIMS="$1/shims"; HOSTILE_MARK="$1/hostile-python-ran"
  mkdir -p "$SHIMS" "$versions/hostile/bin"
  printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$HOSTILE_MARK" > "$versions/hostile/bin/python3"
  cat > "$SHIMS/python3" <<SH
#!/usr/bin/env bash
version="\${PYENV_VERSION:-}"
[ -n "\$version" ] || [ ! -f .python-version ] || version="\$(cat .python-version)"
[ -z "\$version" ] || exec "$versions/\$version/bin/python3" "\$@"
exec "$real" "\$@"
SH
  chmod +x "$SHIMS/python3" "$versions/hostile/bin/python3"
  printf 'hostile\n' > "$2/.python-version"
}

@test "diff and red-team run the real python3 behind a shim the project steers" {
  # Inversion (review r4 Sol R4-N1): a shim chose its interpreter from the
  # checkout's .python-version, so project code parsed every scanner report.
  seed "$INCOMPLETE"
  docs_change
  pyenv_shim "$SANDBOX" "$PROJECT"
  run env PATH="$SHIMS:$BIN:$PYTHON_DIR:/usr/bin:/bin:/usr/sbin:/sbin" SECURITY_GATE_PROJECT_NAME="$PROJECT_NAME" \
    bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$SCRIPT_DIR/run-diff.sh" "$PROJECT" --range=HEAD~1..HEAD --no-llm
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"❌ incomplete (semgrep failed)"* ]] || { echo "$output"; false; }
  [ ! -e "$HOSTILE_MARK" ] || { echo "run-diff ran the project-chosen interpreter"; false; }

  run env PATH="$SHIMS:$BIN:$PYTHON_DIR:/usr/bin:/bin" PYENV_VERSION=hostile \
    bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$SCRIPT_DIR/run-redteam.sh" "$PROJECT" data-exfil --confirm --no-llm
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"baseline completeness: incomplete (semgrep failed)"* ]] || { echo "$output"; false; }
  [ ! -e "$HOSTILE_MARK" ] || { echo "red-team ran the project-chosen interpreter"; false; }
}

@test "an opt-in shellcheck baseline record is complete only when shellcheck succeeded" {
  local ok='"semgrep":{"status":"ok","exit":0},"osv-scanner":{"status":"ok","exit":0},"gitleaks":{"status":"ok","exit":0}'

  seed '{"profile":"web-next","complete":true,"engines":{'"$ok"',"shellcheck":{"status":"ok","exit":0}},"findings":[],"historical_findings":[]}'
  docs_change
  run_diff
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Baseline:          complete — "* ]] || { echo "$output"; false; }

  # A failed or bogus-exit shellcheck record still blocks diff as incomplete.
  seed '{"profile":"web-next","complete":true,"engines":{'"$ok"',"shellcheck":{"status":"failed","exit":2}},"findings":[],"historical_findings":[]}'
  printf '# note 2\n' >> "$PROJECT/README.md"
  git -C "$PROJECT" add README.md && git -C "$PROJECT" commit -qm "docs 2"
  run_diff
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"❌ incomplete (shellcheck failed)"* ]] || { echo "$output"; false; }

  seed '{"profile":"web-next","complete":true,"engines":{'"$ok"',"shellcheck":{"status":"not_applicable","exit":3}},"findings":[],"historical_findings":[]}'
  printf '# note 3\n' >> "$PROJECT/README.md"
  git -C "$PROJECT" add README.md && git -C "$PROJECT" commit -qm "docs 3"
  run_diff
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"❌ incomplete (shellcheck not_applicable with exit 3)"* ]] || { echo "$output"; false; }
}
