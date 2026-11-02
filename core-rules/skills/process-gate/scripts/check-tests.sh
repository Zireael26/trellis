#!/usr/bin/env bash
# Gate 4: Tests & coverage — runs project-declared typecheck/lint/test commands.
# Usage: check-tests.sh [--range=<gitspec> | --base=<ref>] [--mode=push|merge]

set -euo pipefail
# Only this gate may populate the Tests command's interface.
unset PG_TESTS_BASE PG_TESTS_HEAD PG_TESTS_RECEIPT_FILE
unset PROCESS_GATE_TEST_MAP # Only tracked base-side config may opt into selection.

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

# Doubt runs the full battery: when the range base does not resolve there is no
# base-side config to load, so fall back to defaults with a notice instead of
# failing closed. Every other config failure still exits: a range must not
# loosen the gate that judges it.
# Only the range-base config may declare that a battery covers static checks.
# An inherited declaration must not suppress a project's standalone checks.
PROCESS_GATE_TEST_COVERS_STATIC=()
if ! pg_load_config "$@"; then
  case "${PG_CONFIG_ERROR:-}" in
    *"cannot resolve the base of range "*)
      printf 'process-gate: notice (docs-only: full tests — %s)\n' "${PG_CONFIG_ERROR:-unresolvable range}" >&2
      ;;
    *) exit 1 ;;
  esac
fi
# Push scope controls this gate only, never any command or nested fixture gate.
pg_push_scope="${PG_PUSH_TEST_SCOPE:-}"
unset PG_PUSH_TEST_SCOPE
RANGE="$(pg_parse_range "$@")"
tag_push=0
release_tag=""
release_tag_count=0
for arg in "$@"; do
  case "$arg" in
    --tag-push) tag_push=1 ;;
    --release-tag=*) tag_push=1; release_tag="${arg#--release-tag=}"; release_tag_count=$((release_tag_count + 1)) ;;
  esac
done
[ "$release_tag_count" -eq 1 ] || release_tag=""
[ "$tag_push" -eq 0 ] || pg_push_scope=full
PROJECT_DIR="$(pg_project_dir)"
cd "$PROJECT_DIR"

# Only explicit push scope is eligible. run-all supplies its immutable snapshot;
# direct callers also resolve their argv, never inherited interface variables.
_pg_tests_base=""; _pg_tests_head=""; pg_tests_receipt_file=""
tests_scope='not run'
if [ "$(pg_parse_mode "$@")" = push ]; then
  for arg in "$@"; do
    case "$arg" in
      --range=*|--base=*)
        if ! _pg_tests_base="$(pg_range_base "$PROJECT_DIR" "$RANGE")" ||
          ! _pg_tests_head="$(pg_range_head "$PROJECT_DIR" "$RANGE")"; then
          _pg_tests_base=""; _pg_tests_head=""
        fi
        break ;;
    esac
  done
fi
trap '[ -z "$pg_tests_receipt_file" ] || rm -f "$pg_tests_receipt_file"' EXIT

# Git exports repository-local routing variables to hooks. The configured test
# command is a fixture suite, not an extension of the hook's Git process: if it
# inherits GIT_DIR, even `git -C "$fixture"` continues to target the checkout
# that launched pre-push. Resolve the intended project first, cd there, then
# remove every local routing override before typecheck/lint/tests (and their
# descendants) run. scripts/run-tests.sh adds a second, fail-loud mutation
# fence; this clearing is what makes the ordinary fixture path resolve normally.
# Keep this list explicit and mirrored in scripts/run-tests.sh.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
unset GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE
unset GIT_SHALLOW_FILE GIT_CEILING_DIRECTORIES
unset GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE
unset GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
while IFS= read -r git_config_var; do
  [ -n "$git_config_var" ] && unset "$git_config_var"
done < <(compgen -A variable GIT_CONFIG_KEY_ || true)
while IFS= read -r git_config_var; do
  [ -n "$git_config_var" ] && unset "$git_config_var"
done < <(compgen -A variable GIT_CONFIG_VALUE_ || true)
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

# pg_has_npm_script <script-name>  (cwd is PROJECT_DIR)
#   Returns 0 only when package.json declares the named script. Portable across
#   jq → node → a grep fallback on .scripts. Used to keep an undeclared script's
#   command EMPTY rather than constructing `$PM run <name>` which exits nonzero
#   ("Missing script") and would wrongly BLOCK repos without that script.
pg_has_npm_script() {
  [ -f package.json ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg s "$1" '.scripts[$s] != null' package.json >/dev/null 2>&1
  elif command -v node >/dev/null 2>&1; then
    node -e 'var s=(require("./package.json").scripts)||{};process.exit(s[process.argv[1]]?0:1)' "$1" 2>/dev/null
  else
    # Last-resort grep tier: best-effort (COARSE) — only the jq and node tiers
    # above are exact. Scope the match to the .scripts object region first (the
    # "scripts" key to the next closing brace) so a non-script key of the same
    # name (e.g. a devDependency literally named "test") cannot false-positive
    # into building `$PM run <name>` for a script that doesn't exist → BLOCK.
    # Terminate on a closing brace ALONE on its line (DL-P7-10): a `,/}/` range
    # stops at the FIRST line containing ANY `}`, so a .scripts VALUE that itself
    # contains a literal `}` (e.g. "lint": "eslint --rule '{...}'") before the
    # target script would truncate the region → MISS a genuinely-declared later
    # script → warn-skip a real test (fail-OPEN). `/^[[:space:]]*}/` ends only on
    # a sole-`}` line, so an in-value brace no longer closes the region.
    # STILL COARSE: a multi-line script value with its own sole-`}` line could
    # truncate, and nested script maps are not parsed — only the jq and node
    # tiers are exact. (No JSON parser here — that is what those tiers are for.)
    sed -n '/"scripts"[[:space:]]*:/,/^[[:space:]]*}/p' package.json 2>/dev/null \
      | grep -Eq "\"$1\"[[:space:]]*:" 2>/dev/null
  fi
}

worst="pass"
findings=()

# Auto-detect package manager if not declared
if [ -z "${PROCESS_GATE_TYPECHECK_CMD:-}${PROCESS_GATE_LINT_CMD:-}${PROCESS_GATE_TEST_CMD:-}" ]; then
  PM="$(pg_resolve_pm "$PROJECT_DIR")"
  # Configured-but-missing PM → surface as WARN and skip the JS toolchain rather
  # than hard-failing the gate (mirrors stop-verify / pre-push skip-on-absent-PM).
  if [ -n "$PM" ] && [ -f "package.json" ] && ! command -v "$PM" >/dev/null 2>&1; then
    pg_log warn "Tests & coverage"
    pg_finding "package manager '$PM' not on PATH — JS typecheck/lint/test skipped (install $PM, or set PROCESS_GATE_*_CMD in local.config.sh)"
    exit 2
  fi
  # `$PM run <script>` is the portable form across pnpm/npm/yarn/bun — bare
  # `npm typecheck`/`npm lint` are invalid (npm only aliases test/start/stop).
  # Only build the command when package.json actually declares the script;
  # otherwise leave the cmd EMPTY so run_check downgrades it to a WARN instead
  # of running a missing npm script that exits nonzero and BLOCKS the gate.
  if [ -n "$PM" ] && [ -f "package.json" ]; then
    if pg_has_npm_script typecheck; then PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PM run typecheck}"; fi
    if pg_has_npm_script lint;      then PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PM run lint}"; fi
    if pg_has_npm_script test;      then PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PM run test}"; fi
  fi

  # Python toolchain detection (order: uv → pdm → bare pyproject)
  if [ -z "${PM:-}" ] && [ -f "pyproject.toml" ]; then
    if   [ -f "uv.lock" ];     then PY_RUN="uv run"
    elif [ -f "pdm.lock" ];    then PY_RUN="pdm run"
    else PY_RUN="python -m"
    fi

    # Default typecheck: mypy if configured (pyproject [tool.mypy] or mypy.ini).
    # Pyright is opt-in via explicit PROCESS_GATE_TYPECHECK_CMD override.
    # Config-presence is NOT enough (DL-P7-07): also probe that the tool is
    # RUNNABLE in its own env via the EXACT `$PY_RUN <tool>` invocation form
    # (so `python -m mypy`, `uv run mypy` each resolve a
    # venv/uv-managed tool; `--version` is fast and side-effect-free). A
    # configured-but-not-installed tool leaves the cmd EMPTY → run_check WARNs
    # (couldn't-run), instead of failing at runtime → BLOCK.
    if { grep -q '^\[tool\.mypy\]' pyproject.toml 2>/dev/null || [ -f "mypy.ini" ]; } && $PY_RUN mypy --version >/dev/null 2>&1; then
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-$PY_RUN mypy .}"
    fi

    # Default lint: ruff if configured and runnable.
    if { grep -q '^\[tool\.ruff\]' pyproject.toml 2>/dev/null || [ -f "ruff.toml" ]; } && $PY_RUN ruff --version >/dev/null 2>&1; then
      PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-$PY_RUN ruff check .}"
    fi

    # Default tests: pytest if configured and runnable.
    if { grep -q '^\[tool\.pytest\.ini_options\]' pyproject.toml 2>/dev/null \
       || [ -f "pytest.ini" ] || [ -f "conftest.py" ]; } && $PY_RUN pytest --version >/dev/null 2>&1; then
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PY_RUN pytest}"
    fi
  fi

  # Go toolchain detection (workspaces or single module).
  # Require `go` on PATH for the ENTIRE branch (DL-P7-07): a configured Go repo
  # with `go` off PATH would make `go vet`/`go test` (and any make target that
  # drives go) exit 127 at runtime → worst=fail → BLOCK. go-absent is
  # "couldn't-run", which the bright line maps to WARN, not fail — so when go
  # is absent we build NO go commands (all three downgrade to warn). This guard
  # also covers the make-target arm: a `make vet/test` that shells out to go
  # needs go present too.
  if [ -z "${PM:-}" ] && { [ -f "go.work" ] || [ -f "go.mod" ]; } && command -v go >/dev/null 2>&1; then
    # Go workspaces break `go vet ./...` and `go test ./...` from the repo
    # root — prefer a Makefile orchestrator if one exposes vet/lint/test
    # targets. Multi-language monorepos commonly use this pattern.
    if [ -f "Makefile" ] && grep -qE '^(vet|lint|test):' Makefile 2>/dev/null; then
      # PER-TARGET guard (DL-P7-09): the branch enters on ANY ONE of
      # vet/lint/test being a Makefile target, but each `make <target>` command
      # is built ONLY when that SPECIFIC target is declared. A Makefile that
      # declares only a subset (e.g. just `test:`) previously ran `make vet` /
      # `make lint` anyway — each exits 2 ("No rule to make target") → worst=fail
      # → BLOCK. A missing make target is "couldn't-run", which the bright line
      # maps to WARN: leave its cmd EMPTY so run_check downgrades it. A DECLARED
      # target whose recipe genuinely fails (`make test` exits 1) still hard-fails.
      if grep -qE '^vet:'  Makefile 2>/dev/null; then PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-make vet}"; fi
      if grep -qE '^lint:' Makefile 2>/dev/null; then PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-make lint}"; fi
      if grep -qE '^test:' Makefile 2>/dev/null; then PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-make test}"; fi
    elif [ -f "go.work" ]; then
      # go.work workspace ROOT with no Makefile vet/lint/test target: the
      # root-level `go vet ./...` / `go test ./...` are BROKEN here (they exit
      # nonzero with "directory prefix . does not contain modules listed in
      # go.work") → would BLOCK. Leave typecheck/test UNDECLARED so they
      # downgrade to warn; do NOT build the broken root-level commands.
      # golangci-lint is still safe to declare (module-aware) when present.
      if command -v golangci-lint >/dev/null 2>&1; then
        PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-golangci-lint run ./...}"
      fi
    else
      # Single-module go.mod (no go.work, no Makefile targets): `go vet ./...`
      # and `go test ./...` are valid from the module root.
      PROCESS_GATE_TYPECHECK_CMD="${PROCESS_GATE_TYPECHECK_CMD:-go vet ./...}"
      if command -v golangci-lint >/dev/null 2>&1; then
        PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-golangci-lint run ./...}"
      fi
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-go test ./...}"
    fi
  fi
fi

# Docs-only Tests path (C08, Sol's FOLD-GATE rule). The test battery is
# narrowed only when every path touched by every commit in the range is a
# passive Markdown record that the project's docs-only policy allows and does
# not deny, and that clears the built-in floor below. The policy is read from
# Git objects at the range's base, never from the range or the checkout: a
# candidate cannot widen its own exemption. Doubt runs the full battery: an
# unresolvable range, a non-ancestor start, a merge commit, an empty range, an
# unreadable or malformed policy, or any unknown path. Typecheck and lint still
# run; the battery is replaced by the policy's optional `tests` command.
PG_DOCS_POLICY_PATHS=(
  ".agents/skills/process-gate-local/docs-only-tests.policy"
  ".claude/skills/process-gate-local/docs-only-tests.policy"
)
docs_only_files=""
docs_only_cmd=""
docs_only_reason=""
release_metadata_manifest=""
release_metadata_class=""
DOCS_ALLOW=()
DOCS_DENY=()

# Built-in floor, applied before and regardless of any policy. A path must be
# made of ordinary components (no dot-directories, spaces, controls or leading
# dashes), end in .md, and name no behaviour-bearing file or namespace. The
# deny half matches case-insensitively, so case aliases cannot slip through.
PG_DOCS_SAFE_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$'
PG_DOCS_FLOOR_RE=(
  '(^|/)(core-rules|scripts|bin|hooks|skills|commands|agents|prompts|templates|tests?|__tests__|fixtures?|__fixtures__|testdata|__snapshots__|baselines?|spec|secrets?|credentials?)/'
  '(^|/)(SKILL|CLAUDE|AGENTS|GEMINI|CODEX|README|SETUP|INSTALL|prompt|targets)\.md$'
  '(^|/)[^/]*(VERSION|UPGRADING|secret|credential)[^/]*$'
)

pg_docs_path_ok() {
  local p="$1" re rc=0
  [[ "$p" =~ $PG_DOCS_SAFE_RE ]] || { docs_only_reason="$p: not an ordinary path"; return 1; }
  [[ "$p" == *.md ]] || { docs_only_reason="$p: not a .md record"; return 1; }
  shopt -s nocasematch
  for re in "${PG_DOCS_FLOOR_RE[@]}"; do
    if [[ "$p" =~ $re ]]; then rc=1; break; fi
  done
  shopt -u nocasematch
  [ "$rc" -eq 0 ] || { docs_only_reason="$p: behaviour-bearing path"; return 1; }
  rc=1
  for re in ${DOCS_ALLOW[@]+"${DOCS_ALLOW[@]}"}; do
    if [[ "$p" =~ $re ]]; then rc=0; break; fi
  done
  [ "$rc" -eq 0 ] || { docs_only_reason="$p: not on the docs-only allowlist"; return 1; }
  for re in ${DOCS_DENY[@]+"${DOCS_DENY[@]}"}; do
    if [[ "$p" =~ $re ]]; then docs_only_reason="$p: denied by the docs-only policy"; return 1; fi
  done
}

# A passive text blob: no NUL byte, not an LFS pointer.
pg_docs_blob_ok() {
  local sha="$1" size text head
  size="$(git cat-file -s "$sha" 2>/dev/null)" || return 1
  text="$(git cat-file blob "$sha" 2>/dev/null | LC_ALL=C tr -d '\000' | wc -c | tr -d '[:space:]')" || return 1
  [ "$size" = "$text" ] || return 1
  head="$(git cat-file blob "$sha" 2>/dev/null | LC_ALL=C head -c 40 || true)"
  case "$head" in "version https://git-lfs"*) return 1 ;; esac
}

# Read `git diff-tree -z --raw` entries on stdin. Prints the first reason a
# path is ineligible and returns 1; returns 0 when every entry is eligible.
pg_docs_entries() {
  local meta path path2 src dst dsha status
  while IFS= read -r -d '' meta; do
    IFS= read -r -d '' path || { echo "truncated diff entry"; return 1; }
    # meta is ":<srcmode> <dstmode> <srcsha> <dstsha> <status>"
    read -r src dst _ dsha status <<<"${meta#:}"
    path2=""
    case "$status" in
      A|M|D) ;;
      R*|C*) IFS= read -r -d '' path2 || { echo "truncated diff entry"; return 1; } ;;
      *) echo "$path: change type $status"; return 1 ;;
    esac
    case "$src:$dst" in
      000000:100644|100644:000000|100644:100644) ;;
      *) echo "$path${path2:+ -> $path2}: mode $src -> $dst"; return 1 ;;
    esac
    pg_docs_path_ok "$path" || { echo "$docs_only_reason"; return 1; }
    if [ -n "$path2" ]; then
      pg_docs_path_ok "$path2" || { echo "$docs_only_reason"; return 1; }
    fi
    if [ "$dst" = 100644 ] && ! pg_docs_blob_ok "$dsha"; then
      echo "${path2:-$path}: binary or LFS blob"; return 1
    fi
  done
  return 0
}

# pg_docs_read_policy <base> -> 0 loaded, 1 unreadable/malformed, 3 absent.
pg_docs_read_policy() {
  local base="$1" p mode body="" found="" b line kw rest n=0 rc
  for p in "${PG_DOCS_POLICY_PATHS[@]}"; do
    mode="$(git ls-tree "$base" -- "$p" 2>/dev/null | awk '{print $1}')" ||
      { docs_only_reason="cannot list $p at the base"; return 1; }
    [ -n "$mode" ] || continue
    [ "$mode" = 100644 ] || { docs_only_reason="policy $p is not a regular file at the base"; return 1; }
    b="$(git cat-file blob "$base:$p" 2>/dev/null)" ||
      { docs_only_reason="cannot read policy $p at the base"; return 1; }
    if [ -n "$found" ] && [ "$b" != "$body" ]; then
      docs_only_reason="policies $found and $p differ at the base"; return 1
    fi
    found="$p"; body="$b"
  done
  [ -n "$found" ] || return 3
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ""|\#*) continue ;; esac
    kw="${line%%[[:space:]]*}"
    rest="${line#"$kw"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$kw" in
      allow|deny)
        if [ -z "$rest" ]; then
          docs_only_reason="policy $found: line $n: empty pattern"; return 1
        fi
        if [ "$kw" = allow ] && [[ "$rest" != ^*\$ ]]; then
          docs_only_reason="policy $found: line $n: allow pattern must be anchored ^...\$"; return 1
        fi
        # =~ itself returns 2 for a regex that does not compile.
        rc=0
        # shellcheck disable=SC2319
        [[ "" =~ $rest ]] || rc=$?
        if [ "$rc" -eq 2 ]; then
          docs_only_reason="policy $found: line $n: invalid regex"; return 1
        fi
        if [ "$kw" = allow ]; then DOCS_ALLOW+=("$rest"); else DOCS_DENY+=("$rest"); fi
        ;;
      class)
        if [[ "$rest" =~ ^release-metadata[[:space:]]+([A-Za-z0-9_./-]+\.json)$ ]] && [ -z "$release_metadata_manifest" ]; then
          release_metadata_manifest="${BASH_REMATCH[1]}"
        else
          docs_only_reason="policy $found: line $n: invalid or duplicate class"; return 1
        fi
        ;;
      tests)
        if [ -z "$rest" ] || [ -n "$docs_only_cmd" ]; then
          docs_only_reason="policy $found: line $n: one non-empty tests command allowed"; return 1
        fi
        docs_only_cmd="$rest"
        ;;
      *) docs_only_reason="policy $found: line $n: unknown keyword '$kw'"; return 1 ;;
    esac
  done <<<"$body"
}

# Sets docs_only_files (the net changed-path count) when the range narrows.
# Silent when no range or no base policy; a notice for every other fallback.
pg_docs_only_eval() {
  local base head c commits why n rc
  # Sourced for the P1a resolver functions only; it sets no shell options.
  # shellcheck source=lib/diff-base.sh
  . "$SKILL_DIR/scripts/lib/diff-base.sh" || return 1
  db_resolve --range="$RANGE" || return 1
  base="$DB_BASE_SHA"; head="$DB_HEAD_SHA"
  case "$RANGE" in
    *...*) base="$(git merge-base "$base" "$head" 2>/dev/null)" || return 1 ;;
  esac
  rc=0; pg_docs_read_policy "$base" || rc=$?
  case "$rc" in
    0) ;;
    3) return 1 ;;
    *) docs_only_note "$docs_only_reason"; return 1 ;;
  esac
  if [ -n "$release_metadata_manifest" ]; then
    local metadata_result metadata_path metadata_re metadata_only=1 metadata_rc=0
    local metadata_allowed='^(VERSION|core-rules/VERSION|CHANGELOG\.md|docs/adr/[A-Za-z0-9][A-Za-z0-9._-]*\.md)$'
    [ -z "$(git rev-list --min-parents=2 "$base..$head" 2>/dev/null || echo unreadable)" ] || metadata_only=0
    for c in $(git rev-list "$base..$head" 2>/dev/null); do
      while IFS= read -r -d '' metadata_path; do
        [[ "$metadata_path" =~ $metadata_allowed ]] || metadata_only=0
        for metadata_re in ${DOCS_DENY[@]+"${DOCS_DENY[@]}"}; do
          if [[ "$metadata_path" =~ $metadata_re ]]; then
            docs_only_note "$metadata_path: denied by the base policy"; return 1
          fi
        done
      done < <(git diff-tree -r -z --name-only --no-renames --no-commit-id "$c")
    done
    if [ "$metadata_only" -eq 1 ]; then
      # Freeze the helper and all local imports at the policy's trusted base.
      metadata_result="$(
        metadata_work="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/trellis-metadata.XXXXXX")" || exit 1
        metadata_work="$(cd "$metadata_work" && pwd -P)" || exit 1
        trap 'rm -rf "$metadata_work"' EXIT
        for metadata_module in release_metadata.py gate_verdict.py gate_receipts.py receipt_provenance.py; do
          metadata_source="scripts/lib/$metadata_module"
          [ "$(git ls-tree "$base" -- "$metadata_source" | awk '{print $1}')" = 100644 ] || exit 1
          (umask 077; git show "$base:$metadata_source" > "$metadata_work/$metadata_module") || exit 1
        done
        python3 -I "$metadata_work/release_metadata.py" "$base" "$head" "$release_metadata_manifest"
      )" || metadata_rc=$?
      case "$metadata_rc" in
        0)
          docs_only_files="${metadata_result%%$'\t'*}"
          docs_only_cmd="${metadata_result#*$'\t'}"
          release_metadata_class=1
          return 0
          ;;
        2) ;; # No release metadata changed; apply the ordinary docs class.
        *) docs_only_note "release-metadata requires a complete audit and full green base verdict"; return 1 ;;
      esac
    fi
  fi
  # db_anc is the resolver's reviewed ancestry probe (release-tag-consumers.bats).
  if ! db_anc "$base" "$head"; then
    docs_only_note "range start is not an ancestor of its end"; return 1
  fi
  if ! commits="$(git rev-list "$base..$head" 2>/dev/null)"; then
    docs_only_note "cannot list the commits in $RANGE"; return 1
  fi
  if [ -z "$commits" ]; then
    docs_only_note "no commits in $RANGE"; return 1
  fi
  if [ -n "$(git rev-list --min-parents=2 "$base..$head" 2>/dev/null || echo unreadable)" ]; then
    docs_only_note "merge commit in $RANGE"; return 1
  fi
  for c in $commits; do
    if ! why="$(git diff-tree -r -z --raw --no-abbrev -M --no-commit-id "$c" | pg_docs_entries)"; then
      docs_only_note "${why:-cannot read commit $c}"; return 1
    fi
  done
  n="$(git diff --no-renames --name-only -z "$base" "$head" | LC_ALL=C tr -cd '\000' | wc -c | tr -d '[:space:]')" ||
    { docs_only_note "cannot count the changed paths"; return 1; }
  if [ "${n:-0}" -eq 0 ]; then
    docs_only_note "no changed paths in $RANGE"; return 1
  fi
  docs_only_files="$n"
}

docs_only_note() {
  printf 'process-gate: notice (docs-only: full tests — %s)\n' "$1" >&2
}

if [ -n "${PROCESS_GATE_TEST_CMD:-}" ]; then
  if [ "$tag_push" -eq 0 ] && [ "$pg_push_scope" != full ]; then pg_docs_only_eval || true; fi
  if [ -n "$docs_only_files" ]; then
    PROCESS_GATE_TEST_CMD="$docs_only_cmd"
    if [ -n "$_pg_tests_base" ] && [ -z "$docs_only_cmd" ]; then
      tests_scope='no-tests: docs-only'
    fi
  fi
fi

# Optional selector is trusted BASE code, used only for explicit branch pushes.
# Its diagnostic header is not a receipt: the command reports through the
# gate-range interface. An absent or undecidable map leaves the command full.
diff_tests_count=0
if [ -z "$docs_only_files" ] && [ -n "$_pg_tests_base" ] &&
   [ "$pg_push_scope" = branch ] && [ -n "${PROCESS_GATE_TEST_MAP:-}" ]; then
  if [ "$(git rev-parse HEAD)" != "$_pg_tests_head" ]; then
    printf 'process-gate: full tests — HEAD differs from pushed range head\n' >&2
  elif ! git diff --quiet -- || ! git diff --cached --quiet HEAD --; then
    printf 'process-gate: full tests — tracked tree is dirty or unreadable\n' >&2
  elif pg_base_path "$PROJECT_DIR" "$PG_CONFIG_BASE" "$PROCESS_GATE_TEST_MAP" &&
     selection="$(git show "$PG_CONFIG_BASE:$PROCESS_GATE_TEST_MAP" | python3 -I - "$RANGE")"; then
    while IFS= read -r test_file; do
      printf -v test_arg '%q' "--test-file=$test_file"
      PROCESS_GATE_TEST_CMD+=" $test_arg"
      diff_tests_count=$((diff_tests_count + 1))
    done <<< "${selection#*$'\n'}"
  else
    printf 'process-gate: full tests — selector unavailable or range not mapped\n' >&2
  fi
fi

# Only the canonical full local runner can supply an exact-input verdict. A
# project command, narrowed range, dirty checkout, or different gated HEAD misses.
PG_REUSED_VERDICT=""
PG_TAG_VERDICT=""
if [ "$tag_push" -eq 1 ] && [ -n "$release_tag" ] && [ "$(pg_parse_mode "$@")" = push ] &&
  { [ "${PROCESS_GATE_TEST_CMD:-}" = 'python3 scripts/run-tests-local.py' ] ||
    [ "${PROCESS_GATE_TEST_CMD:-}" = 'python3 -I scripts/run-tests-local.py' ]; }; then
  if tag_result="$(python3 -I "$SKILL_DIR/../../../scripts/lib/tag_push_reuse.py" "$release_tag" "$RANGE")"; then
    PG_TAG_VERDICT="${tag_result%%$'\n'*}"
    PROCESS_GATE_TEST_CMD="${tag_result#*$'\n'}"
  fi
fi
if [ "$tag_push" -eq 0 ] && [ "$pg_push_scope" != full ] && [ "$diff_tests_count" -eq 0 ] &&
  [ -z "$docs_only_files" ] && [ -f scripts/lib/gate_verdict.py ] &&
  { [ "${PROCESS_GATE_TEST_CMD:-}" = 'python3 scripts/run-tests-local.py' ] ||
    [ "${PROCESS_GATE_TEST_CMD:-}" = 'python3 -I scripts/run-tests-local.py' ]; }; then
  # shellcheck source=lib/diff-base.sh
  . "$SKILL_DIR/scripts/lib/diff-base.sh"
  if db_resolve --range="$RANGE" >/dev/null 2>&1 && [ -n "$DB_HEAD_SHA" ]; then
    PG_REUSED_VERDICT="$(python3 -I scripts/run-tests-local.py --verdict-status "--head=$DB_HEAD_SHA" 2>/dev/null)" || PG_REUSED_VERDICT=""
    [ -z "$PG_REUSED_VERDICT" ] || tests_scope=full
  fi
fi

# Two ceilings, because `run_check` drives typecheck, lint AND tests through one
# code path. A project whose battery legitimately runs for hours has to raise the
# test ceiling, and while there was only one variable that raise silently removed
# the guard from typecheck and lint too — the two checks that should never take
# more than a few minutes and whose runaway is exactly what a timeout is for.
# test-postgres.mjs can spend up to 900 s acquiring its shared database
# lock; leave another 600 s for the battery after acquisition.
PROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-1500}"
PROCESS_GATE_CHECK_TIMEOUT="${PROCESS_GATE_CHECK_TIMEOUT:-300}"

# Portable hard ceiling for every bounded command in this script -- the main
# checks and the optional mutation probe alike. GNU `timeout` is normally absent
# on macOS, so a `command -v timeout` guard with no fallback runs UNBOUNDED
# there: measured 2026-09-04, two `git push` runs sat in this file's test leg for
# 3h17m and 3h45m against a half-dead Docker daemon whose client calls never
# returned. The perl process-group pattern matches the reviewer/propose-rules
# guards; 125 means no bounded runner is available, 124/142 mean it timed out.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $secs = shift @ARGV;
      my $pid = fork();
      exit 125 if !defined $pid;
      if ($pid == 0) { POSIX::setsid(); exec @ARGV or POSIX::_exit(127); }
      $SIG{ALRM} = sub {
        kill("TERM", -$pid); select(undef, undef, undef, 0.3);
        kill("KILL", -$pid); waitpid($pid, 0); exit(142);
      };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@"
  else
    return 125
  fi
}

# Which bounded runner this host actually has, resolved once. Empty means none
# is reachable on this PATH, which is a reportable condition rather than a
# reason to skip the check -- see run_check.
if command -v timeout >/dev/null 2>&1; then
  PG_TIMEOUT_RUNNER=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  PG_TIMEOUT_RUNNER=gtimeout
elif command -v perl >/dev/null 2>&1; then
  PG_TIMEOUT_RUNNER=perl
else
  PG_TIMEOUT_RUNNER=""
fi
pg_unbounded_warned=no

# Machine-wide heavy-slot gate (spec 054). The test battery waits for a
# `trellis heavy` slot so parallel lanes on one host do not starve each other;
# the timeout starts once the slot is held, not while waiting for it. `--check`
# runs first and decides the path before the battery runs even once: 0 runs
# through the gate, anything else (or no launcher) runs the old bounded path
# with a notice. So a failing test is never re-run on the fallback path.
# PROCESS_GATE_HEAVY_LAUNCHER names the launcher; it defaults to `trellis` on
# PATH.
PG_HEAVY_LAUNCHER=""
pg_heavy_preflight() {
  local launcher="${PROCESS_GATE_HEAVY_LAUNCHER:-}" out rc reason
  if [ -z "$launcher" ]; then
    launcher="$(command -v trellis 2>/dev/null || true)"
  fi
  if [ -z "$launcher" ] || [ ! -x "$launcher" ]; then
    reason="trellis launcher not found${launcher:+: $launcher}"
  else
    set +e
    out="$("$launcher" heavy --check 2>&1)"; rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      PG_HEAVY_LAUNCHER="$launcher"
      return 0
    fi
    reason="trellis heavy --check exited $rc: $(printf '%s\n' "$out" | tail -n 1)"
  fi
  printf 'process-gate: notice (heavy-gate-unavailable: %s)\n' "$reason" >&2
}
# A narrowed range's tests command is light: it never waits for a heavy slot.
if [ -n "${PROCESS_GATE_TEST_CMD:-}" ] && [ -z "$docs_only_files" ] &&
  [ -z "$PG_REUSED_VERDICT" ] && [ -z "$PG_TAG_VERDICT" ]; then
  pg_heavy_preflight
fi

# Preserve complete failed-check output beside failed local-gate shard evidence.
# Keep only owner-private process-gate directories here; run-tests-local owns
# its separate token directories under the same failed-shards parent.
pg_failure_dir_mtime() {
  local dir="$1" stamp
  if [ "$(uname -s)" = Darwin ]; then
    stamp="$(stat -f '%m' "$dir" 2>/dev/null)" || return 1
  else
    stamp="$(stat -c '%Y' "$dir" 2>/dev/null)" || return 1
  fi
  case "$stamp" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$stamp"
}

pg_prune_failure_outputs() {
  local root="$1" uid candidate stamp best_index i kept=0
  local -a dirs=() mtimes=()
  uid="$(id -u)" || return 1
  find "$root" -mindepth 1 -maxdepth 1 -type d -name 'process-gate-failure.*' \
    -uid "$uid" -perm 0700 -mmin +10080 -exec rm -rf {} + 2>/dev/null || true
  while IFS= read -r -d '' candidate; do
    stamp="$(pg_failure_dir_mtime "$candidate" 2>/dev/null || true)"
    case "$stamp" in ""|*[!0-9]*) stamp=0 ;; esac
    dirs+=("$candidate")
    mtimes+=("$stamp")
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'process-gate-failure.*' \
    -uid "$uid" -perm 0700 -print0 2>/dev/null)
  [ "${#dirs[@]}" -gt 0 ] || return 0

  while [ "$kept" -lt 7 ]; do
    best_index=-1
    for i in "${!dirs[@]}"; do
      [ -n "${dirs[$i]}" ] || continue
      if [ "$best_index" -lt 0 ] || [ "${mtimes[$i]}" -gt "${mtimes[$best_index]}" ]; then
        best_index="$i"
      fi
    done
    [ "$best_index" -ge 0 ] || break
    dirs[$best_index]=""
    mtimes[$best_index]=""
    kept=$((kept + 1))
  done
  for candidate in "${dirs[@]}"; do
    [ -z "$candidate" ] || rm -rf "$candidate" 2>/dev/null || true
  done
}

pg_private_directory() {
  local path="$1" owner mode info
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  if [ "$(uname -s)" = Darwin ]; then
    info="$(stat -f '%u %Lp' "$path" 2>/dev/null)" || return 1
  else
    info="$(stat -c '%u %a' "$path" 2>/dev/null)" || return 1
  fi
  read -r owner mode <<<"$info"
  [ "$owner" = "$(id -u)" ] && [ "$mode" = 700 ]
}

pg_gate_state_root() (
  local path="${TRELLIS_GATE_STATE_DIR-${HOME:-}/.local/state/trellis-gate}" ancestor suffix="" part
  [ -n "${TRELLIS_GATE_STATE_DIR+x}" ] || [ -n "${HOME:-}" ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  ancestor="$path"
  while [ ! -d "$ancestor" ]; do
    [ ! -e "$ancestor" ] && [ ! -L "$ancestor" ] || return 1
    part="${ancestor##*/}"
    case "$part" in .|..) return 1 ;; esac
    suffix="/$part$suffix"
    ancestor="${ancestor%/*}"
    [ -n "$ancestor" ] || ancestor=/
  done
  ancestor="$(cd "$ancestor" && pwd -P)$suffix" || return 1
  while :; do
    [ ! -e "$ancestor/.git" ] && [ ! -L "$ancestor/.git" ] || return 1
    [ "$ancestor" != / ] || break
    ancestor="${ancestor%/*}"
    [ -n "$ancestor" ] || ancestor=/
  done
  printf '%s\n' "$path"
)

pg_add_failure_output() {
  local label="$1" output="$2" state_root failure_root failure_dir failure_file line
  state_root="$(pg_gate_state_root)" || state_root=""
  failure_root="$state_root/failed-shards"
  if [ -z "$state_root" ] || [ -L "$state_root" ] || [ -L "$failure_root" ] ||
    ! (umask 077; mkdir -p "$failure_root" 2>/dev/null) ||
    ! pg_private_directory "$state_root" || ! pg_private_directory "$failure_root"; then
    findings+=("$label: full output could not be saved in an owner-private failed-shards directory")
    return 0
  fi

  pg_prune_failure_outputs "$failure_root" || true
  if ! failure_dir="$(umask 077; mktemp -d "$failure_root/process-gate-failure.XXXXXXXXXXXX" 2>/dev/null)"; then
    findings+=("$label: full output could not be saved under $failure_root")
    return 0
  fi
  failure_file="$failure_dir/output.txt"
  if ! pg_private_directory "$failure_dir" ||
    ! (umask 077; printf '%s' "${output:0:5242880}" > "$failure_file") ||
    ! chmod 0600 "$failure_file" 2>/dev/null; then
    rm -rf "$failure_dir" 2>/dev/null || true
    findings+=("$label: full output could not be saved privately under $failure_root")
    return 0
  fi

  if [ "${#output}" -gt 5242880 ]; then
    printf '\n[check-tests: output truncated at 5 MiB]\n' >> "$failure_file"
    findings+=("$label: full output saved at $failure_file (truncated at 5 MiB)")
  else
    findings+=("$label: full output saved at $failure_file")
  fi
  while IFS= read -r line; do
    findings+=("    $line")
  done < <(printf '%s\n' "$output" | grep '^not ok ' | head -n 20 || true)
}

run_check() {
  local label="$1" cmd="$2" limit
  case "$label" in
    tests) limit="$PROCESS_GATE_TEST_TIMEOUT" ;;
    *)     limit="$PROCESS_GATE_CHECK_TIMEOUT" ;;
  esac
  # Bright line: ABSENT/UNDECLARED check → WARN, never a fail. A check that is
  # declared/detected and FAILS at runtime (rc nonzero, below) stays a hard
  # fail. An empty cmd means the check was never declared or auto-detected, so
  # it must not BLOCK — every label downgrades to warn (was: typecheck→fail).
  if [ -z "$cmd" ]; then
    findings+=("$label: not declared/detected — skipped")
    if [ "$worst" = "pass" ]; then
      worst="warn"
    fi
    return 0
  fi

  local out rc receipt
  local -a command_env=()
  if [ "$label" = tests ] && [ -z "$PG_TAG_VERDICT" ] && [ -n "$_pg_tests_base" ] && [ -n "$_pg_tests_head" ]; then
    pg_tests_receipt_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/pg-tests-receipt.XXXXXXXX")"
    # Set these AFTER the heavy launcher's clean-env boundary, on the command
    # itself. Typecheck, lint, coverage and mutation never get this interface.
    command_env=(env "PG_TESTS_BASE=$_pg_tests_base" "PG_TESTS_HEAD=$_pg_tests_head"
      "PG_TESTS_RECEIPT_FILE=$pg_tests_receipt_file")
  fi
  [ "$label" != tests ] || tests_scope=full
  set +e
  if [ "$label" = tests ] && [ -n "$PG_HEAVY_LAUNCHER" ]; then
    out="$("$PG_HEAVY_LAUNCHER" heavy --lane process-gate --timeout "$limit" -- ${command_env[@]+"${command_env[@]}"} bash -c "$cmd" 2>&1)"; rc=$?
  elif [ -n "$PG_TIMEOUT_RUNNER" ]; then
    out="$(run_with_timeout "$limit" ${command_env[@]+"${command_env[@]}"} bash -c "$cmd" 2>&1)"; rc=$?
  else
    # No bounded runner reachable on this PATH. Still RUN the check -- refusing
    # would turn the gate into a silent skip, which is a worse hole than an
    # unbounded run -- but say so once, so an unbounded wait is never invisible.
    out="$(${command_env[@]+"${command_env[@]}"} bash -c "$cmd" 2>&1)"; rc=$?
    if [ "$pg_unbounded_warned" = no ]; then
      pg_unbounded_warned=yes
      findings+=("checks ran UNBOUNDED: no timeout, gtimeout or perl on PATH — a hung command will not be killed")
      if [ "$worst" = "pass" ]; then
        worst="warn"
      fi
    fi
  fi
  set -e

  if [ "$label" = tests ] && [ -s "$pg_tests_receipt_file" ]; then
    receipt=""
    if [ "$(wc -c < "$pg_tests_receipt_file")" -le 128 ] &&
      [ "$(wc -l < "$pg_tests_receipt_file")" -eq 1 ]; then
      receipt="$(< "$pg_tests_receipt_file")"
    fi
    if [ "$receipt" = 'PG_TESTS_RECEIPT full' ]; then
      tests_scope=full
    elif [[ "$receipt" =~ ^PG_TESTS_RECEIPT\ narrowed\ ([1-9][0-9]*)$ ]]; then
      tests_scope="narrowed: ${BASH_REMATCH[1]} selected"
    elif [ "$receipt" = 'PG_TESTS_RECEIPT no-tests docs-only' ]; then
      tests_scope='no-tests: docs-only'
    else
      findings+=("invalid Tests receipt: expected one PG_TESTS_RECEIPT line")
      worst=fail
    fi
  fi
  if [ "$label" = tests ] && [ "$diff_tests_count" -gt 0 ]; then
    if [ "$rc" -ne 0 ]; then
      # Failed selected runs need no success receipt; report their real failure.
      tests_scope=unknown
    elif [ "$tests_scope" != "narrowed: $diff_tests_count selected" ]; then
      findings+=("invalid Tests receipt: selected command must report narrowed $diff_tests_count")
      tests_scope=unknown
      worst=fail
    fi
  fi
  if [ -n "$pg_tests_receipt_file" ]; then
    rm -f "$pg_tests_receipt_file"
    pg_tests_receipt_file=""
  fi

  # A cooperating test runner can distinguish database-lock starvation from a
  # failing assertion with this exact marker. Keep the gate blocking, but name
  # the failure as infrastructure; the tests did not complete.
  if [ "$label" = tests ] && {
    printf '%s\n' "$out" | grep -Fxq 'process-gate-infra: test-database lock wait timed out' ||
    printf '%s\n' "$out" | grep -Eiq 'timed out.*(test[- ]?postgres|test[- ]?database).*lock|(test[- ]?postgres|test[- ]?database).*lock.*timed out';
  }; then
    findings+=("tests: infrastructure failure: test-database lock wait timed out — battery did not complete; retry after the lock is available")
    pg_add_failure_output "$label" "$out"
    worst="fail"
    return 0
  fi

  # 124 (GNU timeout) and 142 (the perl fallback's SIGALRM path) both mean the
  # ceiling fired. Say so: "exited 124" reads like a test failure and sends the
  # operator hunting for a bug that is not there. Only meaningful when a runner
  # was actually used -- unbounded, those are the command's own exit codes.
  if { [ -n "$PG_TIMEOUT_RUNNER" ] || { [ "$label" = tests ] && [ -n "$PG_HEAVY_LAUNCHER" ]; }; } &&
    { [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ]; }; then
    findings+=("$label: \`$cmd\` exceeded ${limit}s and was killed")
    pg_add_failure_output "$label" "$out"
    while IFS= read -r line; do
      findings+=("    $line")
    done < <(printf "%s\n" "$out" | tail -n 10)
    worst="fail"
    return 0
  fi

  if [ "$rc" -ne 0 ]; then
    findings+=("$label: \`$cmd\` exited $rc")
    pg_add_failure_output "$label" "$out"
    # Last 10 lines of output for context
    while IFS= read -r line; do
      findings+=("    $line")
    done < <(printf "%s\n" "$out" | tail -n 10)
    worst="fail"
  fi
}

# Deduplicate only an exact base-declared tuple after test selection. A docs
# policy can even name the same command, but a narrowed run keeps local checks.
static_checks_in_battery=""
if [ -z "$docs_only_files" ] && [ "${#PROCESS_GATE_TEST_COVERS_STATIC[@]}" -eq 3 ] &&
  [ -n "${PROCESS_GATE_TEST_CMD:-}" ] &&
  [ "$PROCESS_GATE_TEST_CMD" = "${PROCESS_GATE_TEST_COVERS_STATIC[0]}" ] &&
  [ "${PROCESS_GATE_TYPECHECK_CMD:-}" = "${PROCESS_GATE_TEST_COVERS_STATIC[1]}" ] &&
  [ "${PROCESS_GATE_LINT_CMD:-}" = "${PROCESS_GATE_TEST_COVERS_STATIC[2]}" ]; then
  static_checks_in_battery="typecheck and lint: included in full test battery"
else
  run_check "typecheck" "${PROCESS_GATE_TYPECHECK_CMD:-}"
  run_check "lint"      "${PROCESS_GATE_LINT_CMD:-}"
fi
# Narrowed with no policy tests command: the battery is skipped, not undeclared.
if [ -z "$PG_REUSED_VERDICT" ] && { [ -z "$docs_only_files" ] || [ -n "${PROCESS_GATE_TEST_CMD:-}" ]; }; then
  run_check "tests"     "${PROCESS_GATE_TEST_CMD:-}"
fi

# Optional: coverage. Routed through run_with_timeout at the check ceiling like
# the declared checks above — a hung reporter must be killed, never unbounded —
# and its status is captured: the old `|| true` swallowed a failing reporter
# into a silent pass. Coverage is a reporter, not the test battery, so it
# shares PROCESS_GATE_CHECK_TIMEOUT, not PROCESS_GATE_TEST_TIMEOUT.
# SAFETY: the coverage command always runs under the CHECK_TIMEOUT ceiling (or
# the once-only unbounded warn when no runner exists), so a hung reporter is
# killed at the ceiling exactly like a hung declared check. A narrowed range
# skips it with the battery it reports on.
if [ -n "${PROCESS_GATE_COVERAGE_CMD:-}" ] && [ -z "$docs_only_files" ]; then
  set +e
  if [ -n "$PG_TIMEOUT_RUNNER" ]; then
    cov_out="$(run_with_timeout "$PROCESS_GATE_CHECK_TIMEOUT" bash -c "$PROCESS_GATE_COVERAGE_CMD" 2>&1)"; cov_rc=$?
  else
    cov_out="$(bash -c "$PROCESS_GATE_COVERAGE_CMD" 2>&1)"; cov_rc=$?
    if [ "$pg_unbounded_warned" = no ]; then
      pg_unbounded_warned=yes
      findings+=("checks ran UNBOUNDED: no timeout, gtimeout or perl on PATH — a hung command will not be killed")
      if [ "$worst" = "pass" ]; then
        worst="warn"
      fi
    fi
  fi
  set -e
  if [ -n "$PG_TIMEOUT_RUNNER" ] && { [ "$cov_rc" -eq 124 ] || [ "$cov_rc" -eq 142 ]; }; then
    findings+=("coverage: \`$PROCESS_GATE_COVERAGE_CMD\` exceeded ${PROCESS_GATE_CHECK_TIMEOUT}s and was killed")
    while IFS= read -r line; do
      findings+=("    $line")
    done < <(printf "%s\n" "$cov_out" | tail -n 10)
    if [ "$worst" = "pass" ]; then worst="warn"; fi
  elif [ "$cov_rc" -ne 0 ]; then
    findings+=("coverage: \`$PROCESS_GATE_COVERAGE_CMD\` exited $cov_rc")
    while IFS= read -r line; do
      findings+=("    $line")
    done < <(printf "%s\n" "$cov_out" | tail -n 10)
    if [ "$worst" = "pass" ]; then worst="warn"; fi
  else
    pct="$(printf "%s" "$cov_out" | grep -oE 'All files[^|]*\|[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?$' | head -1 || true)"
    floor="${PROCESS_GATE_COVERAGE_FLOOR:-0}"
    if [ -n "$pct" ] && [ "$(printf '%.0f' "$pct")" -lt "$floor" ]; then
      findings+=("coverage: ${pct}% < floor ${floor}%")
      if [ "$worst" = "pass" ]; then worst="warn"; fi
    fi
  fi
fi

# Optional report-only mutation spot-check. It considers at most the first 25
# supported changed test files (C-locale path order), flips exactly one
# assertion in a disposable local clone, verifies the clone's unmodified control
# first, then runs the same test command under a short hard ceiling. The caller's
# checkout is never edited. Unsupported/inconclusive/surviving probes WARN; they
# never turn a passing baseline into a hard failure.
mutation_result=""
if [ "${PROCESS_GATE_MUTATION_SPOTCHECK:-0}" = "1" ] && [ "$worst" != "fail" ] && [ -z "$docs_only_files" ]; then
  mutation_timeout="${PROCESS_GATE_MUTATION_TIMEOUT:-30}"
  mutation_skip=""
  mutation_target=""
  mutation_kind=""

  # Scratch operations must not inherit repository-local routing from a hook
  # caller. In particular, GIT_DIR can make `git -C <scratch> checkout` move the
  # caller's HEAD instead of the disposable clone's HEAD.
  mutation_clean_env=(
    env
    -u GIT_DIR
    -u GIT_WORK_TREE
    -u GIT_COMMON_DIR
    -u GIT_INDEX_FILE
    -u GIT_OBJECT_DIRECTORY
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES
    -u GIT_PREFIX
    -u GIT_IMPLICIT_WORK_TREE
    -u GIT_GRAFT_FILE
    -u GIT_REPLACE_REF_BASE
    -u GIT_SHALLOW_FILE
    -u GIT_CEILING_DIRECTORIES
    -u GIT_DISCOVERY_ACROSS_FILESYSTEM
    -u GIT_NAMESPACE
  )

  case "$mutation_timeout" in
    ""|0|*[!0-9]*) mutation_skip="invalid PROCESS_GATE_MUTATION_TIMEOUT '$mutation_timeout' — skipped" ;;
  esac
  if [ -z "$mutation_skip" ] && [ -z "${PROCESS_GATE_TEST_CMD:-}" ]; then
    mutation_skip="test command unavailable — skipped"
  fi
  case "$RANGE" in
    -*) [ -n "$mutation_skip" ] || mutation_skip="unsafe diff range '$RANGE' — skipped" ;;
  esac

  if [ -z "$mutation_skip" ]; then
    if ! tracked_dirty="$(git status --porcelain --untracked-files=no 2>/dev/null)"; then
      mutation_skip="project is not a readable git worktree — skipped"
    elif [ -n "$tracked_dirty" ]; then
      mutation_skip="tracked working tree is dirty — skipped to keep the clone/control exact"
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    if mutation_work="$(mktemp -d 2>/dev/null || mktemp -d -t check-tests-mutation)" \
      && [ -n "$mutation_work" ] && [ -d "$mutation_work" ]; then
      # shellcheck disable=SC2154  # rc is assigned inside the trap
      trap 'rc=$?; rm -rf "$mutation_work"; exit "$rc"' EXIT
    else
      mutation_skip="unable to create mutation scratch directory — skipped"
    fi

    if [ -z "$mutation_skip" ]; then
    if ! pg_diff_files "$RANGE" > "$mutation_work/changed"; then
      mutation_skip="unable to enumerate changed files for range '$RANGE' — skipped"
    else
      LC_ALL=C sort -u "$mutation_work/changed" > "$mutation_work/changed.sorted"
      mutation_scanned=0
      while IFS= read -r mutation_file; do
        mutation_file_kind=""
        case "$mutation_file" in
          *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|__tests__/*.js|__tests__/*.jsx|__tests__/*.ts|__tests__/*.tsx|test/*.js|test/*.jsx|test/*.ts|test/*.tsx|tests/*.js|tests/*.jsx|tests/*.ts|tests/*.tsx|*/__tests__/*.js|*/__tests__/*.jsx|*/__tests__/*.ts|*/__tests__/*.tsx|*/test/*.js|*/test/*.jsx|*/test/*.ts|*/test/*.tsx|*/tests/*.js|*/tests/*.jsx|*/tests/*.ts|*/tests/*.tsx)
            mutation_file_kind="js"
            ;;
          test_*.py|*_test.py|*/test_*.py|test/*.py|tests/*.py|*/test/*.py|*/tests/*.py)
            mutation_file_kind="python"
            ;;
          *_test.go)
            mutation_file_kind="go"
            ;;
        esac
        [ -n "$mutation_file_kind" ] || continue
        [ -f "$PROJECT_DIR/$mutation_file" ] || continue
        [ ! -L "$PROJECT_DIR/$mutation_file" ] || continue
        mutation_scanned=$((mutation_scanned + 1))
        [ "$mutation_scanned" -le 25 ] || break

        mutation_bytes="$(wc -c < "$PROJECT_DIR/$mutation_file" | tr -d '[:space:]')"
        case "$mutation_bytes" in
          ""|*[!0-9]*) continue ;;
        esac
        [ "$mutation_bytes" -le 262144 ] || continue

        set +e
        case "$mutation_file_kind" in
          js)
            awk '
              BEGIN {
                # Deliberately bounded to core Jest/Vitest matchers. Custom
                # matchers and arbitrary `.to*` methods are unsupported rather
                # than risking a runtime-error mutant that looks assertion-killed.
                expect_matchers = "(Be|Equal|StrictEqual|BeCloseTo|BeDefined|BeFalsy|BeGreaterThan|BeGreaterThanOrEqual|BeInstanceOf|BeLessThan|BeLessThanOrEqual|BeNaN|BeNull|BeTruthy|BeUndefined|Contain|ContainEqual|HaveBeenCalled|HaveBeenCalledTimes|HaveBeenCalledWith|HaveBeenLastCalledWith|HaveBeenNthCalledWith|HaveLastReturnedWith|HaveLength|HaveNthReturnedWith|HaveProperty|HaveReturned|HaveReturnedTimes|HaveReturnedWith|Match|MatchObject|MatchSnapshot|MatchInlineSnapshot|Throw|ThrowError|ThrowErrorMatchingSnapshot|ThrowErrorMatchingInlineSnapshot)"
                expect_modifier = "([.](resolves|rejects))?"
                expect_not = "^[[:space:]]*" expect_modifier "[.]not[.]to" expect_matchers "[[:space:]]*[(]"
                expect_positive = "^[[:space:]]*" expect_modifier "[.]to" expect_matchers "[[:space:]]*[(]"
              }
              function flip_expect(line,    scan, segment, open, i, c, depth, quote, escaped, closing, suffix, at) {
                scan = 1
                while (scan <= length(line)) {
                  segment = substr(line, scan)
                  if (!match(segment, /(^|[^[:alnum:]_$])expect[[:space:]]*[(]/)) return line
                  open = scan + RSTART + RLENGTH - 2
                  depth = 1
                  quote = ""
                  escaped = 0
                  closing = 0
                  for (i = open + 1; i <= length(line); i++) {
                    c = substr(line, i, 1)
                    if (quote != "") {
                      if (escaped) {
                        escaped = 0
                      } else if (c == "\\") {
                        escaped = 1
                      } else if (c == quote) {
                        quote = ""
                      }
                    } else if (c == "\"" || c == "\047" || c == "`") {
                      quote = c
                    } else if (c == "(") {
                      depth++
                    } else if (c == ")") {
                      depth--
                      if (depth == 0) {
                        closing = i
                        break
                      }
                    }
                  }
                  if (!closing) return line

                  suffix = substr(line, closing + 1)
                  if (suffix ~ expect_not) {
                    match(suffix, /[.]not[.]to/)
                    at = RSTART
                    return substr(line, 1, closing) substr(suffix, 1, at - 1) ".to" substr(suffix, at + 7)
                  }
                  if (suffix ~ expect_positive) {
                    match(suffix, "[.]to" expect_matchers)
                    at = RSTART
                    return substr(line, 1, closing) substr(suffix, 1, at - 1) ".not.to" substr(suffix, at + 3)
                  }
                  scan = closing + 1
                }
                return line
              }
              {
                line = $0
                if (!done && line ~ /expect[[:space:]]*[(]/) {
                  flipped = flip_expect(line)
                  if (flipped != line) {
                    line = flipped
                    done = 1
                  }
                }
                if (!done && line ~ /assert[.]/) {
                  if (line ~ /assert[.]notDeepStrictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]notDeepStrictEqual/, "assert.deepStrictEqual", line); done = 1
                  } else if (line ~ /assert[.]deepStrictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]deepStrictEqual/, "assert.notDeepStrictEqual", line); done = 1
                  } else if (line ~ /assert[.]notStrictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]notStrictEqual/, "assert.strictEqual", line); done = 1
                  } else if (line ~ /assert[.]strictEqual[[:space:]]*[(]/) {
                    sub(/assert[.]strictEqual/, "assert.notStrictEqual", line); done = 1
                  } else if (line ~ /assert[.]notEqual[[:space:]]*[(]/) {
                    sub(/assert[.]notEqual/, "assert.equal", line); done = 1
                  } else if (line ~ /assert[.]equal[[:space:]]*[(]/) {
                    sub(/assert[.]equal/, "assert.notEqual", line); done = 1
                  }
                }
                print line
              }
              END { if (!done) exit 3 }
            ' "$PROJECT_DIR/$mutation_file" > "$mutation_work/mutated"
            mutation_rc=$?
            ;;
          python)
            awk '
              {
                line = $0
                if (!done && line ~ /^[[:space:]]*assert[[:space:]]+/) {
                  if (line ~ /^[[:space:]]*assert[[:space:]]+not[[:space:]]+/) {
                    sub(/assert[[:space:]]+not[[:space:]]+/, "assert ", line)
                  } else {
                    sub(/assert[[:space:]]+/, "assert not ", line)
                  }
                  done = 1
                }
                print line
              }
              END { if (!done) exit 3 }
            ' "$PROJECT_DIR/$mutation_file" > "$mutation_work/mutated"
            mutation_rc=$?
            ;;
          go)
            awk '
              { lines[NR] = $0 }
              END {
                for (i = 1; i <= NR && !done; i++) {
                  if (lines[i] ~ /(assert|require)[.]NotEqual[[:space:]]*[(]/) {
                    sub(/[.]NotEqual/, ".Equal", lines[i]); done = 1
                  } else if (lines[i] ~ /(assert|require)[.]Equal[[:space:]]*[(]/) {
                    sub(/[.]Equal/, ".NotEqual", lines[i]); done = 1
                  } else if (lines[i] ~ /(assert|require)[.]False[[:space:]]*[(]/) {
                    sub(/[.]False/, ".True", lines[i]); done = 1
                  } else if (lines[i] ~ /(assert|require)[.]True[[:space:]]*[(]/) {
                    sub(/[.]True/, ".False", lines[i]); done = 1
                  } else if (lines[i] ~ /^[[:space:]]*if[[:space:]]+.*(==|!=).*[{][[:space:]]*$/) {
                    assertion = 0
                    for (j = i + 1; j <= NR && j <= i + 5; j++) {
                      if (lines[j] ~ /[.](Error|Fatal)(f|ln)?[[:space:]]*[(]/) assertion = 1
                    }
                    if (assertion && lines[i] ~ /!=/) {
                      sub(/!=/, "==", lines[i]); done = 1
                    } else if (assertion && lines[i] ~ /==/) {
                      sub(/==/, "!=", lines[i]); done = 1
                    }
                  }
                }
                for (i = 1; i <= NR; i++) print lines[i]
                if (!done) exit 3
              }
            ' "$PROJECT_DIR/$mutation_file" > "$mutation_work/mutated"
            mutation_rc=$?
            ;;
        esac
        set -e

        if [ "$mutation_rc" -eq 0 ]; then
          mutation_target="$mutation_file"
          mutation_kind="$mutation_file_kind"
          break
        fi
      done < "$mutation_work/changed.sorted"

      if [ -z "$mutation_target" ]; then
        mutation_skip="no flippable assertion in the first 25 supported changed test files — skipped"
      fi
    fi
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    mutation_repo="$mutation_work/repo"
    mutation_head="$(git rev-parse --verify HEAD 2>/dev/null || true)"
    set +e
    clone_out="$(run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" git clone --quiet --shared --no-checkout "$PROJECT_DIR" "$mutation_repo" 2>&1)"
    clone_rc=$?
    if [ "$clone_rc" -eq 0 ]; then
      checkout_out="$(run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" git -C "$mutation_repo" checkout --quiet --detach "$mutation_head" 2>&1)"
      checkout_rc=$?
    else
      # No checkout ran: leave checkout_out empty so the setup tail below
      # carries the clone output once, not duplicated.
      checkout_out=""
      checkout_rc="$clone_rc"
    fi
    set -e
    if [ "$clone_rc" -ne 0 ] || [ "$checkout_rc" -ne 0 ]; then
      mutation_skip="isolated clone/control setup failed or timed out — skipped"
      # The setup verbs run --quiet, so anything captured here is git's own
      # error text; carry it into the warning instead of /dev/null so the
      # operator can see WHY the isolated setup failed.
      mutation_setup_tail="$(printf "%s\n%s" "$clone_out" "$checkout_out" | grep -v '^$' | tail -n 5 | tr '\n' ';' || true)"
      if [ -n "$mutation_setup_tail" ]; then
        mutation_skip="$mutation_skip (clone/checkout output: ${mutation_setup_tail%;})"
      fi
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    mutation_cmd="$PROCESS_GATE_TEST_CMD"
    printf -v mutation_quoted_target '%q' "$mutation_target"
    case "$mutation_kind:$mutation_cmd" in
      js:"npm run test"|js:"pnpm run test"|js:"yarn run test"|js:"bun run test")
        mutation_cmd="$mutation_cmd -- $mutation_quoted_target"
        ;;
      python:*" pytest")
        mutation_cmd="$mutation_cmd $mutation_quoted_target"
        ;;
      go:"go test ./...")
        mutation_package="${mutation_target%/*}"
        if [ "$mutation_package" = "$mutation_target" ]; then
          mutation_package="."
        else
          mutation_package="./$mutation_package"
        fi
        printf -v mutation_quoted_package '%q' "$mutation_package"
        mutation_cmd="go test $mutation_quoted_package"
        ;;
    esac

    set +e
    control_out="$(run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" bash -c 'cd "$1" && exec bash -c "$2"' _ "$mutation_repo" "$mutation_cmd" 2>&1)"
    control_rc=$?
    set -e
    if [ "$control_rc" -ne 0 ]; then
      case "$control_rc" in
        124|142) mutation_skip="isolated control timed out after ${mutation_timeout}s — skipped" ;;
        125)     mutation_skip="no bounded timeout runner available — skipped" ;;
        *)       mutation_skip="isolated control exited $control_rc — skipped (mutation result would be ambiguous)" ;;
      esac
      # A control that fails for an environmental reason must say why: carry
      # its output into the warning instead of /dev/null.
      control_tail="$(printf "%s" "$control_out" | grep -v '^$' | tail -n 5 | tr '\n' ';' || true)"
      if [ -n "$control_tail" ]; then
        mutation_skip="$mutation_skip (control output: ${control_tail%;})"
      fi
    fi
  fi

  if [ -z "$mutation_skip" ]; then
    mkdir -p "$mutation_repo/$(dirname "$mutation_target")"
    cp "$mutation_work/mutated" "$mutation_repo/$mutation_target"
    set +e
    mutant_out="$(run_with_timeout "$mutation_timeout" "${mutation_clean_env[@]}" bash -c 'cd "$1" && exec bash -c "$2"' _ "$mutation_repo" "$mutation_cmd" 2>&1)"
    mutant_rc=$?
    set -e
    case "$mutant_rc" in
      0)
        mutation_skip="assertion flip survived in $mutation_target"
        ;;
      124|142)
        mutation_skip="assertion flip timed out after ${mutation_timeout}s in $mutation_target — result inconclusive"
        ;;
      125)
        mutation_skip="no bounded timeout runner available — skipped"
        ;;
      *)
        mutation_result="mutation spot-check: assertion flip killed in $mutation_target"
        ;;
    esac
    case "$mutant_rc" in
      0|124|142)
        # An inconclusive or surviving probe that printed must say what it
        # printed: carry the mutant output into the warning.
        mutant_tail="$(printf "%s" "$mutant_out" | grep -v '^$' | tail -n 5 | tr '\n' ';' || true)"
        if [ -n "$mutant_tail" ]; then
          mutation_skip="$mutation_skip (mutant output: ${mutant_tail%;})"
        fi
        ;;
    esac
  fi

  if [ -n "$mutation_skip" ]; then
    findings+=("mutation spot-check: $mutation_skip")
    if [ "$worst" = "pass" ]; then worst="warn"; fi
  fi
fi

case "$worst" in
  pass)
    pg_log pass "Tests & coverage"
    [ -z "$mutation_result" ] || pg_finding "$mutation_result"
    ;;
  warn)
    pg_log warn "Tests & coverage"
    for f in ${findings[@]+"${findings[@]}"}; do pg_finding "$f"; done
    [ -z "$mutation_result" ] || pg_finding "$mutation_result"
    ;;
  fail)
    pg_log fail "Tests & coverage"
    for f in ${findings[@]+"${findings[@]}"}; do pg_finding "$f"; done
    ;;
esac
[ -z "$PG_REUSED_VERDICT" ] || pg_finding "tests: $PG_REUSED_VERDICT"
if [ -n "$PG_TAG_VERDICT" ]; then
  pg_finding "tests: $PG_TAG_VERDICT"
  pg_finding "tests: tag-reading suites executed"
fi
[ -z "$static_checks_in_battery" ] || pg_finding "$static_checks_in_battery"
# run-all.sh carries this exact line into the verdict; keep its shape.
if [ -n "$release_metadata_class" ]; then
  pg_finding "Tests: narrowed (release-metadata: $docs_only_files files)"
elif [ -n "$docs_only_files" ] && { [ "$tests_scope" = full ] || [ "$tests_scope" = 'not run' ]; }; then
  pg_finding "Tests: narrowed (docs-only: $docs_only_files files)"
else
  pg_finding "Tests: $tests_scope"
fi

pg_exit_code "$worst"
