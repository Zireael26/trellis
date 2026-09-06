#!/usr/bin/env bats
# Tests for check-slop.sh (gate 9) — the posture matrix and the ratchet.
#
# Two things are load-bearing here and both are asserted by pairing every RED
# case with a GREEN one that inverts the requirement:
#   1. Posture drives the row AND the exit code: off/absent -> n/a+0,
#      advisory -> warn+0 (never blocks), enforced -> fail+1, malformed ->
#      advisory+warn naming the breakage.
#   2. Scope is the ratchet: only lines the range ADDS are reported. A
#      pre-existing violation in a touched file is not a finding; a line MOVED
#      into a new file IS (documented expected behavior, plan D4).
#
# Approach mirrors check-secrets.bats: a throwaway fixture repo, a synthetic
# .trellis.json per test, and the check run against HEAD~1..HEAD.
# CLAUDE_PROJECT_DIR points at the fixture so posture comes from the fixture's
# tree, not the host's. The pattern lib resolves from the canonical checkout
# (the skill dir's sibling `hooks/lib`), so no seeding is needed except in the
# run-all wiring tests, which run from a stub skill dir.

setup() {
  SKILL="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SKILL/scripts/check-slop.sh"
  REAL_SCRIPTS="$SKILL/scripts"
  SLOP_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/hooks/lib/slop-patterns.sh"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    mkdir -p src
    printf 'export const ok = 1;\n' > src/app.ts
    git add src/app.ts
    git commit -q -m "base"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Declare posture by writing a whole .trellis.json body (raw, so malformed
# bodies are expressible too). Untracked on purpose: posture is worktree config,
# not part of the scanned diff.
set_trellis() {
  printf '%s\n' "$1" > "$PROJECT_DIR/.trellis.json"
}

posture() {
  set_trellis "{\"gate_profiles\":{\"anti_slop\":{\"posture\":\"$1\"}}}"
}

# Commit <relpath> with <content> as a second commit, then run the check over it.
commit_and_check() {
  local relpath="$1" content="$2"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p "$(dirname "$relpath")"
    printf '%s' "$content" > "$relpath"
    git add "$relpath"
    git commit -q -m "add $relpath"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

SLOP_TS=$'const raw = JSON.parse(body) as any;\n'
CLEAN_TS=$'export const two: number = 2;\n'

# --- posture matrix --------------------------------------------------------

@test "posture absent (no .trellis.json): row is n/a and nothing is scanned" {
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == info* ]] || { echo "$output"; false; }
  [[ "$output" == *"n/a"* ]] || { echo "$output"; false; }
  # The inversion that matters: a real slop line is present and still unreported.
  [[ "$output" != *"ts-as-any"* ]] || { echo "$output"; false; }
}

@test "posture off: row is n/a even with slop in the added lines" {
  posture off
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == info* ]] || { echo "$output"; false; }
  [[ "$output" != *"ts-as-any"* ]] || { echo "$output"; false; }
}

@test "posture advisory + slop: warns, names file:line and pattern, exits 0" {
  posture advisory
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"src/slop.ts:1 — ts-as-any"* ]] || { echo "$output"; false; }
  [[ "$output" == *"posture=advisory"* ]] || { echo "$output"; false; }
}

@test "posture advisory + clean added lines: passes (the advisory warn is earned, not constant)" {
  posture advisory
  commit_and_check "src/clean.ts" "$CLEAN_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == pass* ]] || { echo "$output"; false; }
  [[ "$output" != *"ts-as-any"* ]] || { echo "$output"; false; }
}

@test "posture enforced + slop: fails with rc 1" {
  posture enforced
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 1 ]
  [[ "$output" == fail* ]] || { echo "$output"; false; }
  [[ "$output" == *"src/slop.ts:1 — ts-as-any"* ]] || { echo "$output"; false; }
}

@test "posture enforced + clean added lines: passes with rc 0 (rc 1 is the finding, not the posture)" {
  posture enforced
  commit_and_check "src/clean.ts" "$CLEAN_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == pass* ]] || { echo "$output"; false; }
}

@test "malformed posture value: treated as advisory, warn names the bad value, rc 0" {
  posture strict
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *'posture "strict" is not one of off|advisory|enforced'* ]] || { echo "$output"; false; }
  [[ "$output" == *"treated as advisory"* ]] || { echo "$output"; false; }
  # Fail-open, not fail-closed: a typo must not block the branch.
  [[ "$output" == *"posture=advisory"* ]] || { echo "$output"; false; }
}

@test "malformed posture type (number): warn names the type, rc 0" {
  set_trellis '{"gate_profiles":{"anti_slop":{"posture":3}}}'
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"posture is a number, not a string"* ]] || { echo "$output"; false; }
}

@test "malformed anti_slop node (string, not object): warn names it, rc 0" {
  set_trellis '{"gate_profiles":{"anti_slop":"advisory"}}'
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"gate_profiles.anti_slop is not an object"* ]] || { echo "$output"; false; }
}

@test "unparseable .trellis.json: warn names it, treated as advisory, rc 0" {
  set_trellis '{ this is not json'
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"not parseable JSON"* ]] || { echo "$output"; false; }
  [[ "$output" == *"ts-as-any"* ]] || { echo "$output"; false; }
}

@test "anti_slop declared with no posture key: undeclared -> n/a" {
  set_trellis '{"gate_profiles":{"anti_slop":{}}}'
  commit_and_check "src/slop.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == info* ]] || { echo "$output"; false; }
}

# --- the ratchet (diff scoping) -------------------------------------------

@test "ratchet: a pre-existing slop line in a TOUCHED file is NOT flagged" {
  posture enforced
  (
    cd "$PROJECT_DIR" || exit 1
    # Slop lands in the BASE commit, outside every range under test.
    printf 'const raw = JSON.parse(body) as any;\nexport const ok = 1;\n' > src/app.ts
    git add src/app.ts
    git commit -q -m "pre-existing slop"
    # The range under test only appends an innocent line to the same file.
    printf 'const raw = JSON.parse(body) as any;\nexport const ok = 1;\nexport const two = 2;\n' > src/app.ts
    git add src/app.ts
    git commit -q -m "unrelated append"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == pass* ]] || { echo "$output"; false; }
  [[ "$output" != *"ts-as-any"* ]] || { echo "$output"; false; }
}

@test "ratchet: the SAME line inside the range IS flagged (proves the scoping, not a blind spot)" {
  posture enforced
  (
    cd "$PROJECT_DIR" || exit 1
    printf 'export const ok = 1;\nconst raw = JSON.parse(body) as any;\n' > src/app.ts
    git add src/app.ts
    git commit -q -m "introduce slop"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/app.ts:2 — ts-as-any"* ]] || { echo "$output"; false; }
}

@test "ratchet: a MOVED slop line IS flagged — documented expected behavior (plan D4)" {
  # No rename tracking: relocating an existing violation into a new file makes
  # the line new to that file, so it reports. Accepted, not a bug — the posture
  # is advisory until a project opts into enforced, and native suppression
  # syntax with a reason covers the intended cases.
  posture advisory
  (
    cd "$PROJECT_DIR" || exit 1
    printf 'const raw = JSON.parse(body) as any;\nexport const ok = 1;\n' > src/app.ts
    git add src/app.ts
    git commit -q -m "pre-existing slop"
    printf 'export const ok = 1;\n' > src/app.ts
    printf 'const raw = JSON.parse(body) as any;\n' > src/moved.ts
    git add src/app.ts src/moved.ts
    git commit -q -m "move the slop line"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"src/moved.ts:1 — ts-as-any"* ]] || { echo "$output"; false; }
  # The deletion side is not re-reported against the old file.
  [[ "$output" != *"src/app.ts"* ]] || { echo "$output"; false; }
}

@test "carve-out globs are honored: slop in a .test.ts file is not flagged" {
  posture enforced
  commit_and_check "src/app.test.ts" "$SLOP_TS"
  [ "$status" -eq 0 ]
  [[ "$output" == pass* ]] || { echo "$output"; false; }
}

# --- detection ladder + the ratchet on the NATIVE path --------------------
# The pattern path only ever sees added lines, so it cannot prove the ratchet.
# A native linter reports whole files, and that is the one place the filter is
# load-bearing. The linter is stubbed (a fixed concise-format report) so the
# test is deterministic and needs no real ruff on the host.

seed_stub_ruff() {
  printf '[lint]\nselect = ["ANN401"]\n' > "$PROJECT_DIR/ruff.toml"
  mkdir -p "$PROJECT_DIR/.venv/bin"
  cat > "$PROJECT_DIR/.venv/bin/ruff" <<'EOF'
#!/usr/bin/env bash
# Stub linter: reports one violation per known file regardless of arguments,
# in `ruff check --output-format=concise` shape.
echo "app/legacy.py:1:5: ANN401 pre-existing violation"
echo "app/client.py:1:5: ANN401 newly added violation"
exit 1
EOF
  chmod +x "$PROJECT_DIR/.venv/bin/ruff"
}

@test "ladder: a ruff profile config routes to the native linter, and the ratchet drops its out-of-range findings" {
  posture enforced
  seed_stub_ruff
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p app
    printf 'LEGACY = 1\n' > app/legacy.py
    git add app/legacy.py
    git commit -q -m "base legacy"
    # The range adds app/client.py line 1 and appends to legacy.py, so
    # legacy.py:1 is NOT an added line while client.py:1 is.
    printf 'CLIENT = 1\n' > app/client.py
    printf 'LEGACY = 1\nEXTRA = 2\n' > app/legacy.py
    git add app/client.py app/legacy.py
    git commit -q -m "add client, append to legacy"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"detection:"*"py=ruff"* ]] || { echo "$output"; false; }
  [[ "$output" == *"app/client.py:1 — ANN401 newly added violation"* ]] || { echo "$output"; false; }
  # The ratchet: the linter reported it, the gate must not.
  [[ "$output" != *"pre-existing violation"* ]] || { echo "$output"; false; }
}

# Curate gate dependencies from the caller's PATH, preserving its Git/mktemp
# fences and Python without exposing host linters through a directory suffix.
linter_free_path() {
  local shim tool
  shim="$(mktemp -d "$BATS_TEST_TMPDIR/slop-tools.XXXXXX")" || return 1
  for tool in bash git mktemp python3 jq dirname awk cut sort grep rm cat head; do
    ln -s "$(command -v "$tool")" "$shim/$tool" || return 1
  done
  printf '%s' "$shim"
}

@test "ladder: a profile config with no runnable linter falls back to patterns, not to a false clean" {
  posture advisory
  # Config marker present; no .venv/bin/ruff, and a PATH that excludes the
  # host's ruff. A green row here would be a fallback masquerading as measured.
  printf '[lint]\nselect = ["ANN401"]\n' > "$PROJECT_DIR/ruff.toml"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p app
    printf 'from typing import Any\n\n\ndef coerce(payload: Any) -> None:\n    return None\n' > app/client.py
    git add app/client.py
    git commit -q -m "add py slop"
  )
  local tools caller_git caller_mktemp
  caller_git="$(command -v git)"
  caller_mktemp="$(command -v mktemp)"
  tools="$(linter_free_path)"
  [ "$(readlink "$tools/git")" = "$caller_git" ]
  [ "$(readlink "$tools/mktemp")" = "$caller_mktemp" ]
  [ "$(PATH="$tools" command -v git)" = "$tools/git" ]
  PATH="$tools" python3 -c 'import sys; assert sys.version_info.major == 3'
  PATH="$tools" jq -en 'true' >/dev/null
  ! PATH="$tools" command -v ruff
  ! PATH="$tools" command -v mypy
  run bash -c "cd '$PROJECT_DIR' && PATH='$tools' '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"detection:"*"py=patterns"* ]] || { echo "$output"; false; }
  [[ "$output" == *"app/client.py:4 — py-any-annotation"* ]] || { echo "$output"; false; }
}

# --- native lanes must not be trusted blindly ------------------------------

@test "ladder: a native engine that FAILS to run (rc>=2) degrades to patterns and says so" {
  posture enforced
  printf '[lint]\nselect = ["ANN401"]\n' > "$PROJECT_DIR/ruff.toml"
  mkdir -p "$PROJECT_DIR/.venv/bin"
  printf '#!/usr/bin/env bash\necho "ruff failed: unknown rule selector" >&2\nexit 2\n' \
    > "$PROJECT_DIR/.venv/bin/ruff"
  chmod +x "$PROJECT_DIR/.venv/bin/ruff"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p app
    printf 'from typing import Any\n\n\ndef coerce(payload: Any) -> None:\n    return None\n' > app/client.py
    git add app/client.py
    git commit -q -m "add py slop"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"native engine failed to run"* ]] || { echo "$output"; false; }
  [[ "$output" == *"detection:"*"py=patterns"* ]] || { echo "$output"; false; }
  [[ "$output" == *"app/client.py:4 — py-any-annotation"* ]] || { echo "$output"; false; }
}

# Invariant: a native engine that fails to run (exit >=2) over clean lines must warn
# and degrade to patterns; an unrun engine's empty output must never render as pass.
@test "ladder: a broken native engine over clean lines WARNS, it never passes" {
  posture enforced
  printf '[lint]\nselect = ["ANN401"]\n' > "$PROJECT_DIR/ruff.toml"
  mkdir -p "$PROJECT_DIR/.venv/bin"
  printf '#!/usr/bin/env bash\necho "ruff failed: bad config" >&2\nexit 2\n' \
    > "$PROJECT_DIR/.venv/bin/ruff"
  chmod +x "$PROJECT_DIR/.venv/bin/ruff"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p app
    printf 'CLEAN = 1\n' > app/client.py
    git add app/client.py
    git commit -q -m "add clean py"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"native engine failed to run"* ]] || { echo "$output"; false; }
}

# The stub linter above cannot prove the rule set is narrowed: a canned report only
# ever emits what it was written to emit, so inverting the requirement (a project
# rule that is NOT an anti-slop rule) could not break any assertion. These two run
# the real thing.
@test "ladder: REAL ruff reports the profile's rule and NOT the project's other rules" {
  command -v ruff >/dev/null 2>&1 || skip "ruff not installed"
  posture enforced
  printf '[lint]\nextend-select = ["ANN401", "PGH004", "F", "E"]\n' > "$PROJECT_DIR/ruff.toml"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p app
    # F401 (unused import) is a project lint concern, not an evidence-doctrine
    # pattern, and spec §4 puts a general slop tier out of scope for v1.
    printf 'import os\n\n\ndef f(x: int) -> int:\n    return x\n' > app/tidy.py
    git add app/tidy.py
    git commit -q -m "add unused import"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [[ "$output" == *"detection:"*"py=ruff"* ]] || { echo "$output"; false; }
  [[ "$output" != *"F401"* ]] || { echo "$output"; false; }
  [ "$status" -eq 0 ]
  [[ "$output" == pass* ]] || { echo "$output"; false; }
}

@test "ladder: REAL ruff still reports ANN401 (the narrowing did not silence the lane)" {
  command -v ruff >/dev/null 2>&1 || skip "ruff not installed"
  posture enforced
  printf '[lint]\nextend-select = ["ANN401", "PGH004", "F", "E"]\n' > "$PROJECT_DIR/ruff.toml"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p app
    printf 'from typing import Any\n\n\ndef g(x: Any) -> None:\n    return None\n' > app/slop.py
    git add app/slop.py
    git commit -q -m "add ANN401"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"app/slop.py:4 — ANN401"* ]] || { echo "$output"; false; }
}

@test "ladder: mypy owns the type-flow half and reaches the row (D3), narrowed to its codes" {
  command -v mypy >/dev/null 2>&1 || skip "mypy not installed"
  posture advisory
  printf '[mypy]\nwarn_return_any = True\ndisallow_untyped_defs = True\nenable_error_code = ignore-without-code\n' \
    > "$PROJECT_DIR/mypy.ini"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p app
    printf 'from typing import Any\n\n\ndef load() -> Any:\n    return 1\n\n\ndef leak() -> str:\n    return load()\n\n\ndef untyped(x):\n    return x\n\n\nbad = missing_name\n' \
      > app/flow.py
    git add app/flow.py
    git commit -q -m "add type-flow slop"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"detection:"*"py=mypy"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[no-any-return]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[no-untyped-def]"* ]] || { echo "$output"; false; }
  # `missing_name` is a project type error mypy also reports on an added line. It
  # is not an evidence-doctrine pattern, so the narrowing has to drop it — the
  # `[<code>]` suffix is matched, not the bare code name, because a kept message
  # can legitimately name another code in its suggestion text.
  [[ "$output" != *"[name-defined]"* ]] || { echo "$output"; false; }
}

@test "ladder: an oxlint config WITHOUT the profile marker is not the native lane" {
  posture enforced
  # A plain oxlint config plus a stub oxlint that reports a generic style rule.
  # Keying the ladder off config EXISTENCE rendered that rule under the anti-slop
  # label and blocked the merge on it.
  printf '{"rules":{"no-unused-vars":"error"}}\n' > "$PROJECT_DIR/.oxlintrc.json"
  mkdir -p "$PROJECT_DIR/node_modules/.bin"
  printf '#!/usr/bin/env bash\necho "src/new.ts:1:7: eslint(no-unused-vars): unused"\nexit 1\n' \
    > "$PROJECT_DIR/node_modules/.bin/oxlint"
  chmod +x "$PROJECT_DIR/node_modules/.bin/oxlint"
  (
    cd "$PROJECT_DIR" || exit 1
    printf 'export const two = 2;\n' > src/new.ts
    git add src/new.ts
    git commit -q -m "add clean ts"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"detection:"*"ts=patterns"* ]] || { echo "$output"; false; }
  [[ "$output" != *"no-unused-vars"* ]] || { echo "$output"; false; }
}

# --- diff parsing: the shapes that were silent false negatives -------------

@test "diff parsing: a TAB-INDENTED added line is scanned (gofmt indents with tabs)" {
  posture enforced
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p internal
    printf 'package main\n' > internal/a.go
    git add internal/a.go
    git commit -q -m "base go"
    printf 'package main\n\nfunc h(raw Thing) string {\n\tkind := raw.(Widget).Kind\n\treturn kind\n}\n' > internal/a.go
    git add internal/a.go
    git commit -q -m "add tab-indented assertion"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"internal/a.go:4 — go-unchecked-assert"* ]] || { echo "$output"; false; }
}

@test "diff parsing: a path containing a SPACE is scanned (git tab-terminates that header)" {
  posture enforced
  commit_and_check "src/my file.ts" "$SLOP_TS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/my file.ts:1 — ts-as-any"* ]] || { echo "$output"; false; }
}

@test "diff parsing: a NON-ASCII path is scanned (core.quotePath would C-quote it)" {
  posture enforced
  commit_and_check "src/naïve.ts" "$SLOP_TS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"naïve.ts:1 — ts-as-any"* ]] || { echo "$output"; false; }
}

# --- posture is resolved BEFORE the pattern lib ----------------------------
# The lib lives outside the project in the canonical checkout, so the only way to
# exercise its absence is to run the script from a stub skill dir with no sibling
# hooks/lib and no seeded harness copy.

libless_skill_dir() {
  LIBLESS="$(mktemp -d)"
  mkdir -p "$LIBLESS/scripts/lib"
  cp "$REAL_SCRIPTS/check-slop.sh" "$LIBLESS/scripts/check-slop.sh"
  cp "$REAL_SCRIPTS/lib/common.sh" "$LIBLESS/scripts/lib/common.sh"
  chmod +x "$LIBLESS/scripts/check-slop.sh"
}

@test "no pattern lib + posture off/undeclared: still n/a, never a warn" {
  # Every fleet project is in this state until the lib is synced, and a codex-only
  # attachment stays there. A warn here flips the whole process-gate verdict to
  # NEEDS CHANGES on a gate the project never declared.
  libless_skill_dir
  (
    cd "$PROJECT_DIR" || exit 1
    printf '%s' "$SLOP_TS" > src/slop.ts
    git add src/slop.ts
    git commit -q -m "slop"
  )
  run bash -c "cd '$PROJECT_DIR' && '$LIBLESS/scripts/check-slop.sh' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == info* ]] || { echo "$output"; false; }
  [[ "$output" == *"n/a"* ]] || { echo "$output"; false; }
  posture off
  run bash -c "cd '$PROJECT_DIR' && '$LIBLESS/scripts/check-slop.sh' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == info* ]] || { echo "$output"; false; }
  rm -rf "$LIBLESS"
}

@test "no pattern lib + a DECLARED posture: warns and names the missing lib" {
  # The inversion: once a project has opted in, a missing lib is actionable and
  # must not be swallowed.
  libless_skill_dir
  posture advisory
  (
    cd "$PROJECT_DIR" || exit 1
    printf '%s' "$SLOP_TS" > src/slop.ts
    git add src/slop.ts
    git commit -q -m "slop"
  )
  run bash -c "cd '$PROJECT_DIR' && '$LIBLESS/scripts/check-slop.sh' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == warn* ]] || { echo "$output"; false; }
  [[ "$output" == *"slop-patterns.sh not found"* ]] || { echo "$output"; false; }
  rm -rf "$LIBLESS"
}

# --- caller shell options -------------------------------------------------
# bats does not set pipefail and real callers (run-all.sh, pre-push) do. The
# pattern scanner is grep-like — status 1 means "clean" — so a clean scan under
# a pipefail caller is exactly where an unguarded pipeline turns "nothing to
# report" into a hard failure.

@test "pipefail caller: a CLEAN scan still exits 0 through a pipe" {
  posture advisory
  (
    cd "$PROJECT_DIR" || exit 1
    printf 'export const two = 2;\n' > src/clean.ts
    git add src/clean.ts
    git commit -q -m "clean"
  )
  run bash -c "set -o pipefail; cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD | cat"
  [ "$status" -eq 0 ]
}

@test "pipefail caller: an ENFORCED failure still surfaces rc 1 through a pipe" {
  posture enforced
  (
    cd "$PROJECT_DIR" || exit 1
    printf '%s' "$SLOP_TS" > src/slop.ts
    git add src/slop.ts
    git commit -q -m "slop"
  )
  run bash -c "set -o pipefail; cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD | cat"
  [ "$status" -eq 1 ]
}

# --- run-all.sh wiring (row 9) --------------------------------------------
# Same stub-skill-dir strategy as run-all-mode.bats: the aggregator plus the
# REAL check-slop.sh, with the other seven gates stubbed to pass. The pattern lib
# is seeded at the harness path (`.claude/hooks/lib/`) because SKILL_DIR is the
# stub, not the canonical checkout.

stub_skill_dir() {
  STUB="$(mktemp -d)"
  mkdir -p "$STUB/scripts/lib"
  cp "$REAL_SCRIPTS/run-all.sh"    "$STUB/scripts/run-all.sh"
  cp "$REAL_SCRIPTS/lib/common.sh" "$STUB/scripts/lib/common.sh"
  cp "$REAL_SCRIPTS/check-slop.sh" "$STUB/scripts/check-slop.sh"
  local name
  for name in check-pr.sh check-secrets.sh check-bypass.sh check-tests.sh \
    check-docs.sh check-security-diff.sh check-analyze.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/scripts/$name"
    chmod +x "$STUB/scripts/$name"
  done
  chmod +x "$STUB/scripts/run-all.sh"
  mkdir -p "$PROJECT_DIR/.claude/hooks/lib"
  cp "$SLOP_LIB" "$PROJECT_DIR/.claude/hooks/lib/slop-patterns.sh"
  export PROCESS_GATE_STACK_PROFILE="n-a"
}

# An explicit range is required: the fixture's branch IS main, so the default
# `main..HEAD` would be empty and the row would pass for the wrong reason.
run_all() {
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=HEAD~1..HEAD"
}

@test "run-all: advisory findings render the Anti-slop row as warn -> NEEDS CHANGES, never BLOCKED" {
  stub_skill_dir
  posture advisory
  (
    cd "$PROJECT_DIR" || exit 1
    printf '%s' "$SLOP_TS" > src/slop.ts
    git add src/slop.ts
    git commit -q -m "slop"
  )
  run_all
  [ "$status" -eq 2 ]
  [[ "$output" == *"Anti-slop:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  # The findings section carries the anchor, not just the row glyph.
  [[ "$output" == *"src/slop.ts:1 — ts-as-any"* ]] || { echo "$output"; false; }
  rm -rf "$STUB"
}

@test "run-all: enforced findings render the row as fail -> BLOCKED" {
  stub_skill_dir
  posture enforced
  (
    cd "$PROJECT_DIR" || exit 1
    printf '%s' "$SLOP_TS" > src/slop.ts
    git add src/slop.ts
    git commit -q -m "slop"
  )
  run_all
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  rm -rf "$STUB"
}

@test "run-all: undeclared posture renders the row as n/a and leaves the verdict MERGEABLE" {
  stub_skill_dir
  (
    cd "$PROJECT_DIR" || exit 1
    printf '%s' "$SLOP_TS" > src/slop.ts
    git add src/slop.ts
    git commit -q -m "slop"
  )
  run_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Anti-slop:"*"n/a"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
  rm -rf "$STUB"
}
