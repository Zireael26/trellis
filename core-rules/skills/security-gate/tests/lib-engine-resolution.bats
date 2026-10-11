#!/usr/bin/env bats
# Scanner libs run engines by absolute PATH path. An exported shell function
# (`BASH_FUNC_python3%%`) never answers for an engine or its parser, and
# osv.sh additionally refuses an osv-scanner that lives in the scanned tree and
# hands osv-scanner the config file it is given instead of letting it discover
# the tree's own osv-scanner.toml. Each stub produces a finding; a hijacked
# engine or parser produces none.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT" "$BIN"
  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$SCRIPT_ROOT/scripts/lib"
  OUT="$TEST_ROOT/out.jsonl"
  export OSV_ARGS_LOG="$TEST_ROOT/osv.args"

  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "trellis test"
  printf '%s\n' 'export const a = 1;' > "$PROJECT/a.ts"
  # osv.sh keeps findings only for tracked sources; the OSV stub reports this one.
  printf '%s\n' '{}' > "$PROJECT/package.json"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm seed

  cat > "$BIN/osv-scanner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$OSV_ARGS_LOG"
for a in "$@"; do dir="$a"; done
printf '{"results":[{"source":{"path":"%s/package.json","type":"lockfile"},"packages":[{"package":{"name":"fixture","version":"1.0","ecosystem":"npm"},"groups":[],"vulnerabilities":[{"id":"FIXTURE-HIGH","summary":"seeded","database_specific":{"severity":"HIGH"}}]}]}]}\n' "$dir"
exit 1
SH
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"results":[{"check_id":"fixture-rule","path":"a.ts","start":{"line":1},"extra":{"severity":"ERROR","message":"fixture"}}]}'
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) printf '%s\n' '[{"RuleID":"fixture-rule","Description":"fixture","File":"a.ts","StartLine":1}]' > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 1
SH
  cat > "$BIN/garak" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report_prefix) prefix="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' '{"entry_type":"attempt","status":1,"probe_classname":"fixture.Probe","detector_results":{"d":1}}' \
  > "${prefix}.test.report.jsonl"
SH
  cat > "$BIN/llm" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"ok":1}'
SH
  cat > "$BIN/timeout" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--preserve-status" ] && shift
shift
exec "$@"
SH
  chmod +x "$BIN"/*
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# A python3 that swallows its script and prints nothing: a parser hijack.
PY_HIJACK='BASH_FUNC_python3%%=() { cat >/dev/null; }'

@test "osv.sh ignores an exported python3 function" {
  run env PATH="$BIN:$PATH" "$PY_HIJACK" bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
}

@test "osv.sh ignores an exported osv-scanner function" {
  run env PATH="$BIN:$PATH" 'BASH_FUNC_osv-scanner%%=() { printf "%s\n" "{\"results\":[]}"; }' \
    bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
}

@test "osv.sh never runs an osv-scanner from a PATH directory inside the project" {
  mkdir -p "$PROJECT/.tools"
  printf '#!/usr/bin/env bash\n: > "%s/pwned"\nprintf "%%s\\n" "{\\"results\\":[]}"\n' "$TEST_ROOT" > "$PROJECT/.tools/osv-scanner"
  chmod +x "$PROJECT/.tools/osv-scanner"
  run env PATH="$PROJECT/.tools:$BIN:$PATH" bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "osv.sh refuses an osv-scanner symlinked into the project" {
  mkdir -p "$PROJECT/.tools" "$TEST_ROOT/linkbin"
  printf '#!/usr/bin/env bash\n: > "%s/pwned"\n' "$TEST_ROOT" > "$PROJECT/.tools/osv-scanner"
  chmod +x "$PROJECT/.tools/osv-scanner"
  ln -s "$PROJECT/.tools/osv-scanner" "$TEST_ROOT/linkbin/osv-scanner"
  run env PATH="$TEST_ROOT/linkbin:$BIN:$PATH" bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 2 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"resolves inside the scanned project"* ]] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "osv.sh passes its config file as --config" {
  : > "$TEST_ROOT/osv-config.toml"
  run env PATH="$BIN:$PATH" bash "$LIB/osv.sh" "$PROJECT" "$OUT" --config "$TEST_ROOT/osv-config.toml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx -- '--config' "$OSV_ARGS_LOG"
  grep -qx -- "$TEST_ROOT/osv-config.toml" "$OSV_ARGS_LOG"
}

@test "semgrep.sh ignores an exported python3 function" {
  run env PATH="$BIN:$PATH" "$PY_HIJACK" bash "$LIB/semgrep.sh" "$PROJECT" web-next "$OUT"
  grep -q 'fixture-rule' "$OUT" || { echo "rc=$status; $output"; false; }
}

@test "gitleaks.sh ignores an exported python3 function" {
  run env PATH="$BIN:$PATH" "$PY_HIJACK" bash "$LIB/gitleaks.sh" "$PROJECT" "$OUT"
  grep -q 'fixture-rule' "$OUT" || { echo "rc=$status; $output"; false; }
}

@test "garak.sh ignores an exported python3 function" {
  run env PATH="$BIN:$PATH" "$PY_HIJACK" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$LIB/garak.sh" "$PROJECT" "$OUT"
  grep -q 'fixture.Probe' "$OUT" || { echo "rc=$status; $output"; false; }
}

@test "llm-call.sh ignores an exported timeout function" {
  printf 'system\n' > "$TEST_ROOT/prompt.md"
  printf '{}\n' > "$TEST_ROOT/input.json"
  run env PATH="$BIN:$PATH" LLM_PROVIDER=anthropic \
    'BASH_FUNC_timeout%%=() { printf "%s\n" "{\"hijacked\":1}"; }' \
    bash "$LIB/llm-call.sh" "$TEST_ROOT/prompt.md" "$TEST_ROOT/input.json" "$OUT"
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  grep -qx '{"ok":1}' "$OUT"
}

@test "osv.sh never imports a module from the scanned tree" {
  printf 'import sys\nsys.exit(0)\n' > "$PROJECT/json.py"
  run env PATH="$BIN:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$PROJECT" "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
}

@test "osv.sh: an exported builtin function cannot cut the scan short" {
  run env PATH="$BIN:$PATH" 'BASH_FUNC_builtin%%=() { exit 0; }' bash "$LIB/osv.sh" "$PROJECT" "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'FIXTURE-HIGH' "$OUT"
}
