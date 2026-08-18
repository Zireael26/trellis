#!/usr/bin/env bats
# Tests for slop-tripwire.sh (PostToolUse Edit|Write|MultiEdit — advisory only).
#
# Spec task: 037-anti-slop T8. Criterion C3: one red fixture per live language
# trips the tripwire, green fixtures do not.
#
# Fixture discipline:
#   - TS and PY exercise the REAL diff paths in a real temp git repo — TS a
#     tracked file (`git diff HEAD` at -U0, so the assertion is the NEW-file
#     line number), PY an untracked file (whole file is added). GO and RS are
#     pattern-level: one red and one green sample each, no diff plumbing.
#   - Every silence assertion is PAIRED with a case where the same content DOES
#     trip. A test that only asserts "no output" passes just as well against a
#     hook that detects nothing at all.
#   - One test runs the hook inside a `set -o pipefail` caller: bats does not
#     set pipefail and real hook callers do, so a non-zero from an internal
#     pipeline would only surface there (the grep -v / pipefail lesson).

load helpers

TRIPWIRE="$HOOKS_DIR/slop-tripwire.sh"
DOCTRINE="core-rules/references/anti-slop.md"

setup() {
  setup_project_dir
  mkdir -p "$PROJECT_DIR/src" "$PROJECT_DIR/dist"
  unset SLOP_TRIPWIRE
}

teardown() {
  unset SLOP_TRIPWIRE
  teardown_project_dir
}

# --- helpers -----------------------------------------------------------------

# Run the tripwire against $1 with a Claude PostToolUse Edit envelope.
run_tripwire() {
  run_with_stderr "$TRIPWIRE" "$(jq -nc --arg t "$1" \
    '{tool_name: "Edit", tool_input: {file_path: $t}}')"
}

# The advisory message the hook emitted (empty when it stayed silent).
ctx() { printf '%s' "$output" | jq -r '.additionalContext // empty'; }

# Commit $1 (repo-relative) with the remaining args as its lines, so a later
# append is a genuine `git diff HEAD` addition.
commit_lines() {
  local rel="$1"; shift
  printf '%s\n' "$@" > "$PROJECT_DIR/$rel"
  ( cd "$PROJECT_DIR" && git add "$rel" && git commit -q -m "add $rel" )
}

append_lines() {
  local rel="$1"; shift
  printf '%s\n' "$@" >> "$PROJECT_DIR/$rel"
}

write_lines() {
  local rel="$1"; shift
  printf '%s\n' "$@" > "$PROJECT_DIR/$rel"
}

# =============================================================================
# TS — real tracked diff. The reported line number is the NEW-file line, and
# only lines this diff ADDED are scanned.
# =============================================================================
@test "ts-red: an added 'as any' trips with the new-file line number" {
  commit_lines src/client.ts 'export const a = 1;' 'export const b = 2;'
  append_lines src/client.ts 'const widget: Widget = WidgetSchema.parse(raw);' \
    'const bad = JSON.parse(body) as any;'

  run_tripwire "$PROJECT_DIR/src/client.ts"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  msg="$(ctx)"
  [[ "$msg" == *"slop-tripwire: ts-as-any at $PROJECT_DIR/src/client.ts:4"* ]] || { echo "$msg"; false; }
  [[ "$msg" == *"evidence doctrine: $DOCTRINE"* ]] || { echo "$msg"; false; }
  # The clean line added just above it is not reported.
  [ "$(printf '%s\n' "$msg" | grep -c 'slop-tripwire:')" -eq 1 ]
}

@test "ts-diff-scope: a COMMITTED 'as any' is not reported when the added line is clean" {
  # Inverts the ratchet: a hook scanning the whole file would report line 2.
  commit_lines src/legacy.ts 'export const a = 1;' 'const legacy = raw as any;'
  append_lines src/legacy.ts 'const widget: Widget = WidgetSchema.parse(raw);'

  run_tripwire "$PROJECT_DIR/src/legacy.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Same file, same hook: adding a red line DOES trip → the silence above is
  # diff scoping, not a dead detector.
  append_lines src/legacy.ts 'const bad = raw as unknown as Widget;'
  run_tripwire "$PROJECT_DIR/src/legacy.ts"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"ts-as-unknown-as at $PROJECT_DIR/src/legacy.ts:4"* ]] || { echo "$output"; false; }
}

@test "ts-green: idiomatic added lines stay silent" {
  commit_lines src/green.ts 'export const a = 1;'
  append_lines src/green.ts \
    'const widget: Widget = WidgetSchema.parse(JSON.parse(body));' \
    'function apply(input: unknown): void {}' \
    'const table = { alpha: widget } satisfies Record<string, Widget>;'

  run_tripwire "$PROJECT_DIR/src/green.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# PY — untracked file: every line is an added line.
# =============================================================================
@test "py-red: an untracked file's ': Any' signature trips at its real line" {
  write_lines src/client.py 'from typing import Any' '' \
    'def coerce(payload: Any) -> Widget:' '    return Widget(payload)'

  run_tripwire "$PROJECT_DIR/src/client.py"
  [ "$status" -eq 0 ]
  msg="$(ctx)"
  [[ "$msg" == *"slop-tripwire: py-any-annotation at $PROJECT_DIR/src/client.py:3"* ]] || { echo "$msg"; false; }
  [[ "$msg" == *"evidence doctrine: $DOCTRINE"* ]]
}

@test "py-red: a bare '# type: ignore' trips, a coded one does not" {
  write_lines src/ignore.py 'value = payload["id"]  # type: ignore'
  run_tripwire "$PROJECT_DIR/src/ignore.py"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"py-bare-type-ignore at $PROJECT_DIR/src/ignore.py:1"* ]] || { echo "$output"; false; }

  write_lines src/ignore.py 'value = payload["id"]  # type: ignore[index]'
  run_tripwire "$PROJECT_DIR/src/ignore.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "py-green: a SAFETY:-justified cast added alongside stays silent" {
  write_lines src/safe.py 'def widen(payload: dict[str, str]) -> Widget:' \
    '    # SAFETY: key presence checked by model_validate above.' \
    '    return cast(Widget, payload)'

  run_tripwire "$PROJECT_DIR/src/safe.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Drop the justification and the same cast trips → the silence is the SAFETY:
  # convention working, not a missing pattern.
  write_lines src/safe.py 'def widen(payload: dict[str, str]) -> Widget:' \
    '    return cast(Widget, payload)'
  run_tripwire "$PROJECT_DIR/src/safe.py"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"py-unjustified-cast at $PROJECT_DIR/src/safe.py:2"* ]] || { echo "$output"; false; }
}

# =============================================================================
# GO / RS — pattern-level (dormant profiles; fixtures are their only truth).
# =============================================================================
@test "go: an 'interface{}' parameter trips, a typed signature with ', ok' does not" {
  write_lines src/handle.go 'func handle(payload interface{}) error {' '	return nil' '}'
  run_tripwire "$PROJECT_DIR/src/handle.go"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"go-empty-interface at $PROJECT_DIR/src/handle.go:1"* ]] || { echo "$output"; false; }

  write_lines src/handle.go 'func handle(payload Widget) error {' \
    '	widget, ok := raw.(Widget)' '	return json.Unmarshal(data, &payload)' '}'
  run_tripwire "$PROJECT_DIR/src/handle.go"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rs: '.unwrap()' trips, '?' plus a SAFETY:-documented unsafe block does not" {
  write_lines src/lib.rs 'let widget = parse(raw).unwrap();'
  run_tripwire "$PROJECT_DIR/src/lib.rs"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"rs-unwrap at $PROJECT_DIR/src/lib.rs:1"* ]] || { echo "$output"; false; }

  write_lines src/lib.rs 'let widget = parse(raw).map_err(Error::Parse)?;' \
    '// SAFETY: handle stays non-null for the caller lifetime.' \
    'unsafe { ptr::read(handle) };'
  run_tripwire "$PROJECT_DIR/src/lib.rs"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# Carve-outs and the extension filter.
# =============================================================================
@test "carve-out: the same 'as any' trips in src/ and is silent in a .test.ts" {
  write_lines src/widget.ts 'const bad = raw as any;'
  run_tripwire "$PROJECT_DIR/src/widget.ts"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"ts-as-any"* ]] || { echo "$output"; false; }

  write_lines src/widget.test.ts 'const bad = raw as any;'
  run_tripwire "$PROJECT_DIR/src/widget.test.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "carve-out: a generated dist/ file is silent" {
  write_lines dist/bundle.js 'const bad = raw as any;'
  run_tripwire "$PROJECT_DIR/dist/bundle.js"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extension filter: an unsupported extension is silent even with slop text" {
  write_lines notes.md 'Do not write `const bad = raw as any;` in prose either.'
  run_tripwire "$PROJECT_DIR/notes.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# Cap, env escape, fail-open, and the pipefail caller.
# =============================================================================
@test "cap: 7 findings emit exactly 5 lines plus a '(+2 more)' count" {
  write_lines src/many.ts \
    'const v1 = r as any;' 'const v2 = r as any;' 'const v3 = r as any;' \
    'const v4 = r as any;' 'const v5 = r as any;' 'const v6 = r as any;' \
    'const v7 = r as any;'

  run_tripwire "$PROJECT_DIR/src/many.ts"
  [ "$status" -eq 0 ]
  msg="$(ctx)"
  [ "$(printf '%s\n' "$msg" | grep -c 'slop-tripwire:')" -eq 5 ]
  [[ "$msg" == *"(+2 more)"* ]] || { echo "$msg"; false; }
  [[ "$msg" == *"src/many.ts:5 (+2 more) — evidence doctrine: $DOCTRINE"* ]] || { echo "$msg"; false; }
}

@test "escape: SLOP_TRIPWIRE=off silences a file that otherwise trips" {
  write_lines src/off.ts 'const bad = raw as any;'

  export SLOP_TRIPWIRE=off
  run_tripwire "$PROJECT_DIR/src/off.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]

  unset SLOP_TRIPWIRE
  run_tripwire "$PROJECT_DIR/src/off.ts"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"ts-as-any"* ]] || { echo "$output"; false; }
}

@test "fail-open: an envelope with no file_path exits 0 silently" {
  run_with_stderr "$TRIPWIRE" '{"tool_name":"Edit","tool_input":{}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pipefail caller: exit 0 on both a finding and a clean file" {
  # bats does not set pipefail; a real hook caller does. slop_scan_text is
  # grep-like (status 1 when clean), so a leaked pipeline status would show up
  # here and nowhere else.
  write_lines src/hit.ts 'const bad = raw as any;'
  write_lines src/clean.ts 'export const ok = 1;'

  for rel in src/hit.ts src/clean.ts; do
    envelope="$(jq -nc --arg t "$PROJECT_DIR/$rel" \
      '{tool_name: "Edit", tool_input: {file_path: $t}}')"
    run bash -c 'set -o pipefail; printf "%s" "$1" | bash "$2" | cat > /dev/null' \
      _ "$envelope" "$TRIPWIRE"
    [ "$status" -eq 0 ] || { echo "$rel: rc=$status"; false; }
  done
}

# =============================================================================
# Contract: "exit 0 on every detection path". A missing sibling lib used to exit
# 1 with a stderr line, BEFORE the extension filter — so every Edit of every
# file type, .md included, printed a re-run-sync-hooks error in any project whose
# hooks/lib predates the anti-slop rollout.
# =============================================================================
@test "missing sibling lib: exits 0 in silence, on a covered extension and on .md alike" {
  deploy="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$deploy/lib"
  cp "$TRIPWIRE" "$deploy/slop-tripwire.sh"
  cp "$HOOKS_DIR/lib/deps.sh" "$deploy/lib/deps.sh"
  chmod +x "$deploy/slop-tripwire.sh"
  write_lines src/hit.ts 'const bad = raw as any;'
  write_lines notes.md 'const bad = raw as any;'

  for rel in src/hit.ts notes.md; do
    run_with_stderr "$deploy/slop-tripwire.sh" "$(jq -nc --arg t "$PROJECT_DIR/$rel" \
      '{tool_name: "Edit", tool_input: {file_path: $t}}')"
    [ "$status" -eq 0 ] || { echo "$rel: rc=$status"; false; }
    [ -z "$output" ] || { echo "$rel stdout: $output"; false; }
    [ -z "$stderr" ] || { echo "$rel stderr: $stderr"; false; }
  done
}

# The inversion: with the lib present the same .ts file DOES trip, so the test
# above is proving silence-on-absence rather than silence-on-everything.
@test "missing sibling lib: the same file trips once the lib is in place" {
  deploy="$BATS_TEST_TMPDIR/withlib"
  mkdir -p "$deploy/lib"
  cp "$TRIPWIRE" "$deploy/slop-tripwire.sh"
  cp "$HOOKS_DIR/lib/deps.sh" "$deploy/lib/deps.sh"
  cp "$HOOKS_DIR/lib/slop-patterns.sh" "$deploy/lib/slop-patterns.sh"
  chmod +x "$deploy/slop-tripwire.sh"
  write_lines src/hit.ts 'const bad = raw as any;'

  run_with_stderr "$deploy/slop-tripwire.sh" "$(jq -nc --arg t "$PROJECT_DIR/src/hit.ts" \
    '{tool_name: "Edit", tool_input: {file_path: $t}}')"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"ts-as-any"* ]] || { echo "$output"; false; }
}

# =============================================================================
# Carve-outs are matched on the REPO-RELATIVE path. The harness passes an
# absolute one, and the globs match a directory name anywhere in the path, so
# probing the absolute path let any ancestor above the work-tree root carve out
# the whole project — a checkout under `build/` went silent everywhere.
# =============================================================================
@test "carve-out: an ancestor directory ABOVE the repo root does not carve out the project" {
  nested="$BATS_TEST_TMPDIR/build/tests/vendor/proj"
  mkdir -p "$nested/src"
  ( cd "$nested" && git init -q && git commit --allow-empty -q -m init )
  printf 'const bad = raw as any;\n' > "$nested/src/a.ts"

  run_with_stderr "$TRIPWIRE" "$(jq -nc --arg t "$nested/src/a.ts" \
    '{tool_name: "Edit", tool_input: {file_path: $t}}')"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"ts-as-any at $nested/src/a.ts:1"* ]] || { echo "$output"; false; }
}

# The inversion: a carve-out segment INSIDE the repo still carves out.
@test "carve-out: the same ancestor names INSIDE the repo still carve out" {
  nested="$BATS_TEST_TMPDIR/plain/proj"
  mkdir -p "$nested/build/src"
  ( cd "$nested" && git init -q && git commit --allow-empty -q -m init )
  printf 'const bad = raw as any;\n' > "$nested/build/src/a.ts"

  run_with_stderr "$TRIPWIRE" "$(jq -nc --arg t "$nested/build/src/a.ts" \
    '{tool_name: "Edit", tool_input: {file_path: $t}}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
}

# =============================================================================
# The JS/TS test-directory spellings `**/tests/**` cannot reach: a `case` glob's
# `*` crosses '/', so `**/tests/**` does not match `src/__tests__/foo.ts`, which
# is exactly where `vi.mock(` and `as any` legitimately live.
# =============================================================================
@test "carve-out: __tests__, __mocks__, e2e and cypress spellings are silent, src is not" {
  write_lines src/hit.ts 'vi.mock("./client");'
  run_tripwire "$PROJECT_DIR/src/hit.ts"
  [[ "$(ctx)" == *"ts-module-mock"* ]] || { echo "$output"; false; }

  for dir in __tests__ __mocks__ e2e cypress playwright test; do
    mkdir -p "$PROJECT_DIR/src/$dir"
    write_lines "src/$dir/widget.ts" 'vi.mock("./client");'
    run_tripwire "$PROJECT_DIR/src/$dir/widget.ts"
    [ "$status" -eq 0 ] || { echo "$dir: rc=$status"; false; }
    [ -z "$output" ] || { echo "$dir: $output"; false; }
  done
}
