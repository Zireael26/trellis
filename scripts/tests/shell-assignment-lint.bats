#!/usr/bin/env bats
# Focused contract for the shell-tree temporary-assignment guard. The scanner
# sees synthetic files only; none of these snippets is executed.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCANNER="$REPO_ROOT/scripts/lint-shell-assignments.py"
LINTER="$REPO_ROOT/scripts/lint-shell-tree.sh"

setup() {
  WORK="$BATS_TEST_TMPDIR/assignment-guard"
  mkdir -p "$WORK"
  printf 'sample.sh\0' > "$WORK/paths"
}

scan() {
  (cd "$WORK" && python3 -I "$SCANNER" --files0-from paths --baseline baseline.json "$@")
}

@test "multiline prefixes, nesting, pipelines, backticks and command redirects are findings" {
  cat > "$WORK/sample.sh" <<'SH'
#!/bin/bash
a="$(ONE=1 command < input)"
b="$(
  TWO=2 \
  THREE='a b' command \
    2>/dev/null
)"
c="$(printf '%s' "$(NESTED=1 command < input)")"
d="$(printf ok | PIPE=1 command 2>&1)"
e="$(PIPE_OTHER=1 command | cat < input)"
f="$( { GROUP=1 command; } < input)"
g="$(OUTSIDE=1 command)" 2>/dev/null
h=`BACKTICK=1 command < input`
i="$(if CONDITIONAL=1 command <<<data; then :; fi)"
j="$(case x in x) CASE=1 command >>file;; esac)"
k="$(echo <(PROCESS=1 command < input))"
l="$(echo "$(( 1 + $(ARITH=1 command < input) ))")"
read -r ignored <<<data
m="$(AFTER_HERESTRING=1 command < input)"
SH
  run scan --write-baseline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run python3 -I -c 'import json,sys; rows=json.load(open(sys.argv[1]))["entries"]; names={n for r in rows for n in r["assignments"]}; expected=set("ONE TWO THREE NESTED PIPE PIPE_OTHER GROUP OUTSIDE BACKTICK CONDITIONAL CASE PROCESS ARITH AFTER_HERESTRING".split()); assert names == expected, (names,expected); assert sum(r["count"] for r in rows) == 13' "$WORK/baseline.json"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run scan
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "comments, single quotes, escaped dollars, env and assignment-only are not shell-prefix hits" {
  cat > "$WORK/sample.sh" <<'SH'
#!/bin/bash
# x="$(COMMENT=1 command < input)"
a='$(SINGLE=1 command < input)'
b="\$(ESCAPED=1 command < input)"
c="$(env SAFE=1 command < input)"
d="$(/usr/bin/env SAFE=2 command < input)"
e="$(ONLY_ASSIGNMENT=1 > output)"
f="$(NO_REDIRECT=1 command)"
g="$(echo 'quoted > text'; NO_REDIRECT=2 command)"
h="$(echo ok # comment > output
)"
i="$(echo $((1 < 2)); NO_REDIRECT=3 command)"
OUTSIDE=1 command < input
SH
  run scan --write-baseline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"0 fingerprint(s), 0 occurrence(s)"* ]] || { printf '%s\n' "$output"; false; }
  run scan
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "heredoc expansion and recognizable generated shell are scanned without treating quoted data as code" {
  cat > "$WORK/sample.sh" <<'SH'
#!/bin/bash
cat <<'TEXT'
$(LITERAL_DATA=1 command < input)
TEXT
cat <<TEXT
# $(ACTIVE_COMMENT=1 command < input)
'$(ACTIVE_QUOTES=1 command < input)'
\$(ESCAPED_BODY=1 command < input)
TEXT
cat > generated <<'SCRIPT'
#!/usr/bin/env -S bash
result="$(SHEBANG=1 command < input)"
SCRIPT
bash <<'SCRIPT'
result="$(CONSUMER=1 command < input)"
SCRIPT
cat > generated.sh <<'SCRIPT'
result="$(OUTPUT_FILE=1 command < input)"
SCRIPT
SH
  run scan --write-baseline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["entries"]; names={n for e in r for n in e["assignments"]}; assert names == set("ACTIVE_COMMENT ACTIVE_QUOTES SHEBANG CONSUMER OUTPUT_FILE".split()), names' "$WORK/baseline.json"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "baseline fingerprints preserve exact evidence, owning path and duplicate counts" {
  cat > "$WORK/sample.sh" <<'SH'
#!/bin/bash
one="$(LEGACY=old command < input)"
two="$(LEGACY=old command < input)"
SH
  run scan --write-baseline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"]; assert len(e)==1 and e[0]["count"]==2 and e[0]["path"]=="sample.sh" and "LEGACY=old command" in e[0]["context"]' "$WORK/baseline.json"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  # Line shifts do not change the identity, but a third identical occurrence is new.
  cp "$WORK/sample.sh" "$WORK/original"
  { printf '\n\n'; cat "$WORK/original"; } > "$WORK/sample.sh"
  run scan
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' 'three="$(LEGACY=old command < input)"' >> "$WORK/sample.sh"
  run scan
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"count 3, baseline 2"* ]] || { printf '%s\n' "$output"; false; }
  # Removal is stale, and a changed command does not inherit the old allowance.
  printf '%s\n' 'one="$(LEGACY=changed command < input)"' > "$WORK/sample.sh"
  run scan
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"new/excess"* && "$output" == *"stale"* ]] || { printf '%s\n' "$output"; false; }
  cp "$WORK/original" "$WORK/moved.sh"
  printf 'moved.sh\0' > "$WORK/paths"
  run scan
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"moved.sh"* && "$output" == *"sample.sh"* ]] || { printf '%s\n' "$output"; false; }
}

@test "missing, malformed and inconsistent baseline or file inventory fails closed" {
  printf '%s\n' '#!/bin/bash' 'true' > "$WORK/sample.sh"
  run scan
  [ "$status" -eq 2 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' '{not json' > "$WORK/baseline.json"
  run scan
  [ "$status" -eq 2 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' '{"schema_version":1,"entries":[]}' > "$WORK/baseline.json"
  printf 'sample.sh' > "$WORK/paths"
  run scan
  [ "$status" -eq 2 ] || { printf '%s\n' "$output"; false; }
  printf 'missing.sh\0' > "$WORK/paths"
  run scan
  [ "$status" -eq 2 ] || { printf '%s\n' "$output"; false; }
  run scan --write-baseline
  [ "$status" -eq 2 ] || { printf '%s\n' "$output"; false; }
  printf 'sample.sh\0sample.sh\0' > "$WORK/paths"
  run scan
  [ "$status" -eq 2 ] || { printf '%s\n' "$output"; false; }
}

@test "locale assignments can never be accepted into the baseline" {
  cat > "$WORK/sample.sh" <<'SH'
#!/bin/bash
a="$(LC_ALL=C command <input)"
b="$(LANG=en_US command 2>/dev/null)"
c="$(OTHER=1 command 2>/dev/null)"
SH
  run scan --write-baseline
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"unbaselined locale hit"* ]] || { printf '%s\n' "$output"; false; }
  run python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"]; assert len(e)==1 and e[0]["assignments"]==["OTHER"],e' "$WORK/baseline.json"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run scan
  [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"locale:"* ]] || { printf '%s\n' "$output"; false; }
}

@test "doctor usage and owner prepass avoid redirected temporary assignment hits" {
  # These two functions contain both an external CLI and shell-function calls;
  # check the actual production code, not only a synthetic scanner example.
  run python3 -I -B - "$SCANNER" "$REPO_ROOT/scripts/doctor.sh" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('assignment_guard', sys.argv[1])
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
text = Path(sys.argv[2]).read_text()
regions = [
    ('usage', 'hc_usage_cli() {', '\nhc_usage_receipts() {', ('$cli" doctor --json',)),
    ('owners', 'doctor_owner_artifacts_prepare() {', '\n# The snapshot is already validated',
     ('trellis_jq -r', 'attachment_owner_artifact_verdicts_readonly')),
]
failed = False
for name, start, end, required in regions:
    assert text.count(start) == 1 and text.count(end) == 1, name
    section = text.split(start, 1)[1].split(end, 1)[0]
    assert all(item in section for item in required), name
    for hit in guard.Scanner(section).findings():
        print(f'{name}: line {hit["line"]}: {hit["assignments"]}')
        failed = True
sys.exit(1 if failed else 0)
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}

@test "shell-tree integration includes extensionless Bash shebangs and fails closed on the baseline" {
  mkdir -p "$WORK/tree/core-rules" "$WORK/tree/scripts" "$WORK/tree/scheduled-tasks" \
    "$WORK/tree/local" "$WORK/tree/.claude" "$WORK/tree/specs" "$WORK/bin"
  cp "$LINTER" "$WORK/tree/scripts/lint-shell-tree.sh"
  cp "$SCANNER" "$WORK/tree/scripts/lint-shell-assignments.py"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$WORK/bin/shellcheck"
  chmod +x "$WORK/bin/shellcheck"
  printf '%s\n' '#!/usr/bin/env -S bash' 'a="$(EXTENSIONLESS=1 command 2>/dev/null)"' > "$WORK/tree/scripts/extensionless"
  printf '%s\n' '{"schema_version":1,"entries":[]}' > "$WORK/tree/scripts/lint-shell-assignments-baseline.json"
  run bash -c 'cd "$1" && PATH="$2:$PATH" bash scripts/lint-shell-tree.sh' _ "$WORK/tree" "$WORK/bin"
  [ "$status" -ne 0 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"scripts/extensionless"* && "$output" == *"new/excess"* ]] || { printf '%s\n' "$output"; false; }
  run bash -c 'cd "$1" && PATH="$2:$PATH" bash scripts/lint-shell-tree.sh --write-assignment-baseline' _ "$WORK/tree" "$WORK/bin"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run bash -c 'cd "$1" && PATH="$2:$PATH" bash scripts/lint-shell-tree.sh' _ "$WORK/tree" "$WORK/bin"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  rm "$WORK/tree/scripts/lint-shell-assignments-baseline.json"
  run bash -c 'cd "$1" && PATH="$2:$PATH" bash scripts/lint-shell-tree.sh' _ "$WORK/tree" "$WORK/bin"
  [ "$status" -ne 0 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"cannot read or validate inventory"* ]] || { printf '%s\n' "$output"; false; }
  # Enumeration must remain useful without either of the new guard files.
  rm "$WORK/tree/scripts/lint-shell-assignments.py"
  run bash -c 'cd "$1" && bash scripts/lint-shell-tree.sh --list' _ "$WORK/tree"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [[ "$output" == *"scripts/extensionless"* ]] || { printf '%s\n' "$output"; false; }
}
