#!/usr/bin/env bats
# Coverage for run-diff.sh dependency-change gating (DEPS_CHANGED).
#
# A uv.lock refresh must select the OSV dependency scan the same way every
# other lockfile does: the fleet is uv-only, so a uv.lock change that skips
# OSV is an unscanned dependency change. These tests drive the real script end
# to end with stubbed scanners — a uv.lock-only change must trigger OSV (a
# stubbed HIGH finding blocks the push), while a change to a non-dependency
# path must not (the same stub stays silent because osv.sh never runs).

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  OSV_FIXTURE_FILE="$TEST_ROOT/osv.json"
  mkdir -p "$PROJECT" "$BIN"
  unset SECURITY_GATE_SHELLCHECK

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
  # the OSV stage, which runs only when a manifest/lockfile is in the diff.
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "1.157.0"; else echo '{"results":[]}'; fi
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

  # OSV reports one HIGH finding against uv.lock. It is reachable only when
  # run-diff.sh classifies the changed path as a dependency file.
  cat > "$OSV_FIXTURE_FILE" <<'JSON'
{
  "results": [{
    "source": {"path": "PROJECT_PATH/uv.lock", "type": "lockfile"},
    "packages": [{
      "package": {"name": "fixture", "version": "1.0.0", "ecosystem": "PyPI"},
      "vulnerabilities": [
        {"id": "UV-LOCK-HIGH", "summary": "fixture high", "database_specific": {"severity": "HIGH"}}
      ],
      "groups": []
    }]
  }]
}
JSON
  python3 - "$OSV_FIXTURE_FILE" "$PROJECT" <<'PY'
import sys
path, project = sys.argv[1:]
with open(path) as fh:
    data = fh.read().replace("PROJECT_PATH", project)
with open(path, "w") as fh:
    fh.write(data)
PY
  export OSV_FIXTURE_FILE

  cat > "$BIN/osv-scanner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "osv-scanner version 2.4.0"
  exit 0
fi
cat "$OSV_FIXTURE_FILE"
# OSV-Scanner uses 1 to mean vulnerabilities were found.
exit 1
SH
  chmod +x "$BIN/osv-scanner"

  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# The web-next profile keeps the ShellCheck stage off, so OSV is the only
# stage a lockfile change can move.
run_diff() {
  run env PATH="$BIN:$PATH" \
    SECURITY_GATE_STACK_PROFILE=web-next \
    SECURITY_GATE_PROJECT_NAME=project \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --range=HEAD~1..HEAD --no-llm
}

@test "a uv.lock change triggers the OSV dependency scan" {
  printf '# uv lock\n' > "$PROJECT/uv.lock"
  for i in $(seq 1 50); do echo "# pin $i" >> "$PROJECT/uv.lock"; done
  git -C "$PROJECT" add uv.lock
  git -C "$PROJECT" commit -qm "chore: refresh uv.lock"
  run_diff

  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"osv/UV-LOCK-HIGH"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Deps:"*"❌ fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "a non-dependency change does not trigger the OSV dependency scan" {
  printf '# docs\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" commit -qm "docs: tweak readme"
  run_diff

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"osv/"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
}
