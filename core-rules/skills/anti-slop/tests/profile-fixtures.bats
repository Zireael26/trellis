#!/usr/bin/env bats
# Profiles self-test (spec 037 C4): every profile's fixture PAIR must discriminate
# in the lane that actually ships to a project with no native toolchain installed —
# the shared grep pattern set. red.<ext> yields >= 1 finding, green.<ext> yields 0.
#
# Nothing asserted this before, which is how a green fixture that was not green
# shipped: profiles/python/fixtures/green.py:38 tripped `py-unjustified-cast`
# because its `# SAFETY:` invariant wrapped over two comment lines and the
# suppression scan only looked one line back.
#
# The fixtures are scanned by CONTENT, never by path: `**/fixtures/**` is a
# carve-out glob, precisely so that a project which installs a profile does not
# get findings from the profile's own deliberate-slop payload. Handing these paths
# to audit-slop.sh would therefore report 0 for red and green alike — a self-test
# that passes for the wrong reason.

setup() {
  SKILL="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$(cd "$SKILL/../.." && pwd)/hooks/lib/slop-patterns.sh"
  [ -f "$LIB" ] || skip "pattern lib not found at $LIB"
  # shellcheck disable=SC1090
  . "$LIB"
  AUDIT="$SKILL/scripts/audit-slop.sh"
  # Red-phase seam: AUDIT_BIN points at a deliberately clean-rendering stub
  # to prove these cases fail when a crash is swallowed, then at the real
  # audit for the green run. Unset in normal runs.
  AUDIT_BIN="${AUDIT_BIN:-$AUDIT}"
}

teardown() {
  [ -z "${REPO:-}" ] || rm -rf "$REPO"
  [ -z "${SHIM:-}" ] || rm -rf "$SHIM"
}

# new_repo — throwaway git repo for audit-slop.sh, which only sees tracked files.
# Seed files live here, never under a fixtures/ dir: `**/fixtures/**` is a
# carve-out glob, so content placed there would scan as 0 for the wrong reason.
new_repo() {
  REPO="$(mktemp -d)"
  (
    cd "$REPO" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
  )
}

# broken_engine <path> <name> — crashing stub fixture: empty stdout, exit 2.
broken_engine() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho "%s: simulated crash" >&2\nexit 2\n' "$2" > "$1"
  chmod +x "$1"
}

# scan <profile-dir> <basename> <lang> -> finding count on stdout
scan() {
  local file="$SKILL/profiles/$1/fixtures/$2"
  [ -f "$file" ] || { echo "missing fixture: $file" >&2; return 1; }
  slop_scan_text "$3" < "$file" | grep -c . || true
}

@test "typescript profile: red fixture trips the pattern set, green fixture does not" {
  run scan typescript red.ts ts
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.ts produced no findings"; false; }
  run scan typescript green.ts ts
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.ts produced $output findings"; false; }
}

@test "python profile: red fixture trips the pattern set, green fixture does not" {
  run scan python red.py py
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.py produced no findings"; false; }
  run scan python green.py py
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.py produced $output findings"; false; }
}

@test "go profile (dormant): red fixture trips the pattern set, green fixture does not" {
  run scan go red.go go
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.go produced no findings"; false; }
  run scan go green.go go
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.go produced $output findings"; false; }
}

@test "rust profile (dormant): red fixture trips the pattern set, green fixture does not" {
  run scan rust red.rs rs
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.rs produced no findings"; false; }
  run scan rust green.rs rs
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.rs produced $output findings"; false; }
}

@test "java profile (live, pattern layer only): red fixture trips the pattern set, green fixture does not" {
  run scan java red.java java
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ] || { echo "red.java produced no findings"; false; }
  run scan java green.java java
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ] || { echo "green.java produced $output findings"; false; }
}

# A multi-line SAFETY invariant is the shape green.py:38 exposed. Asserting it
# directly means the fixture can be rewritten without losing the guarantee.
@test "a SAFETY invariant that wraps over several comment lines still suppresses" {
  run bash -c '
    . "'"$LIB"'"
    printf "%s\n" \
      "    # SAFETY: model_validate has already rejected any payload whose" \
      "    # shape does not match, so the narrowed type holds here." \
      "    return cast(Widget, payload)" | slop_scan_text py'
  [ "$status" -eq 1 ]
  [ -z "$output" ] || { echo "$output"; false; }
}

# The inversion: drop the marker and the same three lines must report, or the test
# above would pass against a scanner that suppresses everything.
@test "the same wrapped comment WITHOUT the marker still reports" {
  run bash -c '
    . "'"$LIB"'"
    printf "%s\n" \
      "    # model_validate has already rejected any payload whose" \
      "    # shape does not match, so the narrowed type holds here." \
      "    return cast(Widget, payload)" | slop_scan_text py'
  [ "$status" -eq 0 ]
  [[ "$output" == *"py-unjustified-cast"* ]] || { echo "$output"; false; }
}

# A comment block does not reach past a line of code: the escape hatch has to sit
# on the construct it justifies, not somewhere above it.
@test "a SAFETY comment separated from the cast by real code does NOT suppress" {
  run bash -c '
    . "'"$LIB"'"
    printf "%s\n" \
      "    # SAFETY: checked upstream." \
      "    payload = normalize(payload)" \
      "    return cast(Widget, payload)" | slop_scan_text py'
  [ "$status" -eq 0 ]
  [[ "$output" == *"py-unjustified-cast"* ]] || { echo "$output"; false; }
}

@test "the pattern lib self-check passes (red/green samples, shape probes, carve-outs)" {
  run bash "$LIB" --self-test
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *FAIL* ]] || { echo "$output"; false; }
}

# --- broken native engines (050 S5, SC8) --------------------------------------
# Each lane below seeds an INSTALLED profile (the marker that routes to the
# native engine), a crashing engine stub (empty stdout, exit 2), and source
# content, then asserts the audit degrades instead of rendering the unrun
# tool's silence as clean. oxlint/ruff/mypy use CLEAN content — the case where
# a swallowed crash would fake a clean bill. Go (dormant, no native lane) uses
# SLOP content with a crashing golangci-lint first on PATH, proving the pattern
# layer still reports and no native result is ever claimed.

@test "broken oxlint: a crashing TS engine degrades, it never yields clean" {
  new_repo
  printf '{"plugins": ["anti-slop"]}\n' > "$REPO/.oxlintrc.json"
  mkdir -p "$REPO/src"
  printf 'export const two: number = 2;\n' > "$REPO/src/app.ts"
  broken_engine "$REPO/node_modules/.bin/oxlint" "broken-oxlint"
  ( cd "$REPO" && git add -A )
  run bash -c "cd '$REPO' && '$AUDIT_BIN' --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"degraded to the pattern set for ts"* ]] || { echo "$output"; false; }
  [[ "$output" == *'"lang":"ts","engine":"patterns"'* ]] || { echo "$output"; false; }
  [[ "$output" != *'"engine":"oxlint"'* ]] || { echo "$output"; false; }
}

@test "broken ruff: a crashing Python engine degrades, it never yields clean" {
  new_repo
  printf '[lint]\nextend-select = ["ANN401", "PGH004"]\n' > "$REPO/ruff.toml"
  mkdir -p "$REPO/app"
  printf 'CLEAN = 1\n' > "$REPO/app/client.py"
  broken_engine "$REPO/.venv/bin/ruff" "broken-ruff"
  ( cd "$REPO" && git add -A )
  run bash -c "cd '$REPO' && '$AUDIT_BIN' --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"degraded to the pattern set for py"* ]] || { echo "$output"; false; }
  [[ "$output" == *'"lang":"py","engine":"patterns"'* ]] || { echo "$output"; false; }
  [[ "$output" != *'"engine":"ruff"'* ]] || { echo "$output"; false; }
}

@test "broken mypy: a crashing type engine degrades, it never yields clean" {
  new_repo
  printf '[mypy]\nwarn_return_any = True\ndisallow_untyped_defs = True\nenable_error_code = ignore-without-code\n' > "$REPO/mypy.ini"
  mkdir -p "$REPO/app"
  printf 'CLEAN = 1\n' > "$REPO/app/client.py"
  broken_engine "$REPO/.venv/bin/mypy" "broken-mypy"
  ( cd "$REPO" && git add -A )
  run bash -c "cd '$REPO' && '$AUDIT_BIN' --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"degraded to the pattern set for py"* ]] || { echo "$output"; false; }
  [[ "$output" == *'"lang":"py","engine":"patterns"'* ]] || { echo "$output"; false; }
  [[ "$output" != *'"engine":"mypy"'* ]] || { echo "$output"; false; }
}

@test "broken golangci (dormant): a crashing Go engine degrades, it never yields clean" {
  new_repo
  printf 'package app\n\nfunc Widen(v any) string {\n\treturn "x"\n}\n' > "$REPO/app.go"
  SHIM="$(mktemp -d)"
  broken_engine "$SHIM/golangci-lint" "broken-golangci"
  ( cd "$REPO" && git add -A )
  run bash -c "cd '$REPO' && PATH='$SHIM:$PATH' '$AUDIT_BIN' --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"go-empty-interface"* ]] || { echo "$output"; false; }
  [[ "$output" == *'"lang":"go","engine":"patterns"'* ]] || { echo "$output"; false; }
  [[ "$output" == *"dormant"* ]] || { echo "$output"; false; }
}
