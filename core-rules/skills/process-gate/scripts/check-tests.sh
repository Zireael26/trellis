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

pg_unshadow
PROJECT_DIR="$(pg_project_dir)"
RANGE="$(pg_parse_range "$@")"
# Freeze endpoints before either base config or the docs classifier reads Git.
docs_base=""; docs_head=""; config_range="$RANGE"
if docs_base="$(pg_range_base "$PROJECT_DIR" "$RANGE")" &&
   docs_head="$(pg_range_head "$PROJECT_DIR" "$RANGE")"; then
  config_range="$docs_base..$docs_head"
fi

# Doubt runs the full battery: when the range base does not resolve there is no
# base-side config to load, so fall back to defaults with a notice instead of
# failing closed. Every other config failure still exits: a range must not
# loosen the gate that judges it.
# Only the range-base config may declare that a battery covers static checks.
# An inherited declaration must not suppress a project's standalone checks.
PROCESS_GATE_TEST_COVERS_STATIC=()
if ! pg_load_config --range="$config_range"; then
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
tag_push=0
protected_push=0
docs_default_range=0
release_tag=""
release_tag_count=0
for arg in "$@"; do
  case "$arg" in
    --tag-push) tag_push=1 ;;
    --target=main) protected_push=1 ;;
    --docs-policy-default-range) docs_default_range=1 ;;
    --release-tag=*) tag_push=1; release_tag="${arg#--release-tag=}"; release_tag_count=$((release_tag_count + 1)) ;;
  esac
done
[ "$release_tag_count" -eq 1 ] || release_tag=""
[ "$tag_push" -eq 0 ] || pg_push_scope=full
cd "$PROJECT_DIR"

# Only explicit push scope is eligible. run-all supplies its immutable snapshot;
# direct callers also resolve their argv, never inherited interface variables.
_pg_tests_base=""; _pg_tests_head=""; pg_tests_receipt_file=""
tests_scope='not run'
if [ "$(pg_parse_mode "$@")" = push ]; then
  for arg in "$@"; do
    case "$arg" in
      --range=*|--base=*)
        if [ -n "$docs_base" ] && [ -n "$docs_head" ]; then
          _pg_tests_base="$docs_base"; _pg_tests_head="$docs_head"
        fi
        break ;;
    esac
  done
fi
pg_verdict_inputs=""
pg_check_scratch=""
mutation_work=""
pg_check_pids=()
pg_cleanup_check_tests() {
  local _pid
  for _pid in ${pg_check_pids[@]+"${pg_check_pids[@]}"}; do
    pkill -TERM -P "$_pid" 2>/dev/null || true
    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true
  done
  [ -z "${pg_tests_receipt_file:-}" ] || rm -f "$pg_tests_receipt_file"
  [ -z "${pg_verdict_inputs:-}" ] || rm -f "$pg_verdict_inputs"
  [ -z "${pg_check_scratch:-}" ] || rm -rf "$pg_check_scratch"
  [ -z "${mutation_work:-}" ] || rm -rf "$mutation_work"
}
trap 'pg_cleanup_check_tests' EXIT

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
auto_test_language=""
auto_missing_suites=""

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
    if pg_has_npm_script test; then
      PROCESS_GATE_TEST_CMD="${PROCESS_GATE_TEST_CMD:-$PM run test}"
      auto_test_language=js
    fi
  fi

  # Fast local JS/TS binary fallback when package.json omits scripts.typecheck /
  # scripts.lint and dependencies are installed locally in node_modules/.bin.
  if [ -z "${PROCESS_GATE_TYPECHECK_CMD:-}" ] && [ -f "tsconfig.json" ] && [ -d "node_modules" ]; then
    if [ -x "node_modules/.bin/tsrs" ]; then
      PROCESS_GATE_TYPECHECK_CMD="node_modules/.bin/tsrs --noEmit"
    elif [ -x "node_modules/.bin/tsgo" ]; then
      PROCESS_GATE_TYPECHECK_CMD="node_modules/.bin/tsgo --noEmit"
    elif [ -x "node_modules/.bin/tsc" ]; then
      PROCESS_GATE_TYPECHECK_CMD="node_modules/.bin/tsc --noEmit"
    fi
  fi
  if [ -z "${PROCESS_GATE_LINT_CMD:-}" ] && [ -d "node_modules" ]; then
    if [ -x "node_modules/.bin/oxlint" ] && {
      [ -f ".oxlintrc.json" ] || compgen -G "oxlint.config.*" >/dev/null ||
      grep -q '"oxlint"' package.json 2>/dev/null;
    }; then
      PROCESS_GATE_LINT_CMD="node_modules/.bin/oxlint"
    elif [ -x "node_modules/.bin/biome" ] && { [ -f "biome.json" ] || [ -f "biome.jsonc" ]; }; then
      PROCESS_GATE_LINT_CMD="node_modules/.bin/biome check ."
    elif [ -x "node_modules/.bin/eslint" ] && {
      compgen -G ".eslintrc*" >/dev/null || compgen -G "eslint.config.*" >/dev/null;
    }; then
      PROCESS_GATE_LINT_CMD="node_modules/.bin/eslint . --quiet"
    fi
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
      if [ -z "${PROCESS_GATE_TEST_CMD:-}" ]; then
        PROCESS_GATE_TEST_CMD="$PY_RUN pytest"
        auto_test_language=python
      fi
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
      if grep -qE '^test:' Makefile 2>/dev/null && [ -z "${PROCESS_GATE_TEST_CMD:-}" ]; then
        PROCESS_GATE_TEST_CMD="make test"
        auto_test_language=go
      fi
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
      if [ -z "${PROCESS_GATE_TEST_CMD:-}" ]; then
        PROCESS_GATE_TEST_CMD="go test ./..."
        auto_test_language=go
      fi
    fi
  fi

  # Autodetection chooses one command; it cannot prove that command dispatches
  # the other detected languages. A base-declared command remains authoritative.
  suite_count=0
  if [ -f package.json ] && pg_has_npm_script test; then
    suite_count=$((suite_count + 1))
    [ "$auto_test_language" = js ] || auto_missing_suites="${auto_missing_suites:+$auto_missing_suites, }JavaScript (package.json test)"
  fi
  if [ -f pyproject.toml ] && { grep -q '^\[tool\.pytest\.ini_options\]' pyproject.toml 2>/dev/null ||
       [ -f pytest.ini ] || [ -f conftest.py ]; }; then
    suite_count=$((suite_count + 1))
    [ "$auto_test_language" = python ] || auto_missing_suites="${auto_missing_suites:+$auto_missing_suites, }Python (pytest)"
  fi
  if [ -f go.mod ] || [ -f go.work ]; then
    suite_count=$((suite_count + 1))
    [ "$auto_test_language" = go ] || auto_missing_suites="${auto_missing_suites:+$auto_missing_suites, }Go (go test)"
  fi
  [ "$suite_count" -gt 1 ] || auto_missing_suites=""
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
docs_policy_oid=""
docs_policy_record=""
docs_policy_scope=legacy
docs_child_scope=0
docs_policy_helper="$SKILL_DIR/scripts/lib/docs-policy.py"
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

PG_DOCS_PUSH_FLOOR='(^|/)(configs?|schemas?|workflows?|specs?|site|content|content-collections|generated|dist|build|examples?|notebooks?|manifests?|locks?)(/|\.md$)'

# Independently check the literal scope of a rule: ERE alternation must not
# broaden it. Contract-bearing implementation docs require exact paths.
pg_docs_push_anchor() {
  local re="$1" literal subtree subtree_re='^\^docs/([A-Za-z0-9_][A-Za-z0-9_-]*)/'
  literal="${re#^}"; literal="${literal%\$}"; literal="${literal//\\./.}"
  if [[ "$literal" =~ $PG_DOCS_SAFE_RE && "$literal" == docs/*.md && "$re" == "^${literal//./\\.}\$" ]]; then
    [[ "$2" == "$literal" ]]
  elif [[ "$re" =~ $subtree_re ]]; then
    subtree="${BASH_REMATCH[1]}"
    shopt -s nocasematch
    if [[ "$subtree" == implementation ]]; then shopt -u nocasematch; return 1; fi
    shopt -u nocasematch
    [[ "$2" == "docs/$subtree/"* ]]
  else
    return 1
  fi
}

pg_docs_denied() (
  local p="$1" re
  shopt -s nocasematch
  for re in ${DOCS_DENY[@]+"${DOCS_DENY[@]}"}; do
    if [[ "$p" =~ $re ]]; then return 0; fi
  done
  return 1
)

pg_docs_path_ok() {
  local p="$1" re rc=0
  [[ "$p" == *.md ]] || { docs_only_reason="$p: not a .md record"; return 1; }
  shopt -s nocasematch
  for re in "${PG_DOCS_FLOOR_RE[@]}"; do
    if [[ "$p" =~ $re ]]; then rc=1; break; fi
  done
  if [ "$docs_policy_scope" = push ] && [[ "$p" =~ $PG_DOCS_PUSH_FLOOR ]]; then rc=1; fi
  shopt -u nocasematch
  [ "$rc" -eq 0 ] || { docs_only_reason="$p: behaviour-bearing path"; return 1; }
  rc=1
  for re in ${DOCS_ALLOW[@]+"${DOCS_ALLOW[@]}"}; do
    if [[ "$p" =~ $re ]] && { [ "$docs_policy_scope" != push ] || pg_docs_push_anchor "$re" "$p"; }; then
      rc=0; break
    fi
  done
  [ "$rc" -eq 0 ] || { docs_only_reason="$p: not on the docs-only allowlist"; return 1; }
  if pg_docs_denied "$p"; then
    docs_only_reason="$p: denied by the docs-only policy"; return 1
  fi
}

# pg_docs_read_policy <base> -> 0 loaded, 1 unreadable/malformed, 3 absent.
pg_docs_read_policy() {
  local base="$1" body line kw rest n=0 rc=0 found='docs-only-tests.policy'
  docs_policy_oid="$(python3 -I -B "$docs_policy_helper" base "$base" "${PG_DOCS_POLICY_PATHS[@]}")" || rc=$?
  case "$rc" in
    0) ;;
    3) return 3 ;;
    *) docs_only_reason="${docs_policy_oid:-cannot verify base project manifest or policy}"; return 1 ;;
  esac
  body="$(git --no-replace-objects cat-file blob "$docs_policy_oid" 2>/dev/null)" ||
    { docs_only_reason="cannot read policy blob at the base"; return 1; }
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
      scope)
        if [ "$rest" != push ] || [ "$docs_policy_scope" != legacy ]; then
          docs_only_reason="policy $found: line $n: invalid or duplicate scope"; return 1
        fi
        docs_policy_scope=push
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
  if [ "$docs_policy_scope" = push ] && [ -n "$release_metadata_manifest" ]; then
    docs_only_reason="policy $found: release-metadata class is not supported with scope push"; return 1
  fi
}

# Sets docs_only_files (the net changed-path count) when the range narrows.
# Silent when no range or no base policy; a notice for every other fallback.
pg_docs_only_eval() {
  local base="$docs_base" head="$docs_head" history paths path n rc=0
  [ -n "$base" ] && [ -n "$head" ] && [ "$base" = "$PG_CONFIG_BASE" ] || return 1
  pg_docs_read_policy "$base" || rc=$?
  case "$rc" in
    0) ;;
    3) return 1 ;;
    *) docs_only_note "$docs_only_reason"; return 1 ;;
  esac
  if [ "$docs_policy_scope" = push ] &&
    { [ -z "$_pg_tests_base" ] || [ "$pg_push_scope" != branch ] || [ "$protected_push" -eq 1 ] || [ "$docs_default_range" -eq 1 ]; }; then
    docs_only_note 'scope push requires an explicit branch-only, unprotected push range'; return 1
  fi
  if ! history="$(python3 -I -B "$docs_policy_helper" history "$base" "$head" "$docs_policy_scope")"; then
    docs_only_note "${history:-cannot verify docs-only history}"; return 1
  fi
  n="${history%%$'\n'*}"
  paths="${history#*$'\n'}"
  [[ "$n" =~ ^[1-9][0-9]*$ && "$paths" != "$history" ]] || { docs_only_note 'invalid path inventory'; return 1; }
  if [ -n "$release_metadata_manifest" ]; then
    local metadata_result metadata_only=1 metadata_rc=0
    local metadata_allowed='^(VERSION|core-rules/VERSION|CHANGELOG\.md|docs/adr/[A-Za-z0-9][A-Za-z0-9._-]*\.md)$'
    while IFS= read -r path; do
      [[ "$path" =~ $metadata_allowed ]] || metadata_only=0
      if pg_docs_denied "$path"; then
        docs_only_note "$path: denied by the base policy"; return 1
      fi
    done <<<"$paths"
    if [ "$metadata_only" -eq 1 ]; then
      # Freeze the helper and all local imports at the policy's trusted base.
      metadata_result="$(
        metadata_work="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/trellis-metadata.XXXXXX")" || exit 1
        metadata_work="$(cd "$metadata_work" && pwd -P)" || exit 1
        trap 'rm -rf "$metadata_work"' EXIT
        # Keep the checkout layout: gate_verdict.py loads the native Cargo
        # helper from ../tests/helpers/ relative to itself.
        mkdir -p "$metadata_work/scripts/lib" "$metadata_work/scripts/tests/helpers" || exit 1
        for metadata_module in release_metadata.py gate_verdict.py gate_receipts.py receipt_provenance.py; do
          metadata_source="scripts/lib/$metadata_module"
          [ "$(git ls-tree "$base" -- "$metadata_source" | awk '{print $1}')" = 100644 ] || exit 1
          (umask 077; git show "$base:$metadata_source" > "$metadata_work/$metadata_source") || exit 1
        done
        # A base that predates the helper has no native identity to bind.
        # No case statement here: Bash 3.2 would end this command substitution
        # at the closing paren of a case pattern.
        metadata_source=scripts/tests/helpers/native-cargo-home.py
        metadata_mode="$(git ls-tree "$base" -- "$metadata_source" | awk '{print $1}')"
        if [ "$metadata_mode" = 100644 ] || [ "$metadata_mode" = 100755 ]; then
          (umask 077; git show "$base:$metadata_source" > "$metadata_work/$metadata_source") || exit 1
        elif [ -n "$metadata_mode" ]; then
          exit 1
        fi
        python3 -I -B "$metadata_work/scripts/lib/release_metadata.py" "$base" "$head" "$release_metadata_manifest"
      )" || metadata_rc=$?
      case "$metadata_rc" in
        0)
          docs_only_cmd="${metadata_result#*$'\t'}"
          if [ "${metadata_result%%$'\t'*}" != "$n" ] || [ "$docs_only_cmd" = "$metadata_result" ] || [ -z "$docs_only_cmd" ]; then
            docs_only_note 'invalid release-metadata result'; return 1
          fi
          docs_only_files="$n"
          release_metadata_class=1
          return 0
          ;;
        2) ;; # No release metadata changed; apply the ordinary docs class.
        *) docs_only_note "release-metadata requires a complete audit and full green base verdict"; return 1 ;;
      esac
    fi
  fi
  while IFS= read -r path; do
    pg_docs_path_ok "$path" || { docs_only_note "$docs_only_reason"; return 1; }
  done <<<"$paths"
  docs_only_files="$n"
}

docs_only_note() {
  printf 'process-gate: notice (docs-only: full tests — %s)\n' "$1" >&2
}

if [ -n "${PROCESS_GATE_TEST_CMD:-}" ]; then
  if [ "$tag_push" -eq 0 ] && [ "$pg_push_scope" != full ]; then pg_docs_only_eval || true; fi
  if [ -n "$docs_only_files" ]; then
    docs_battery=not-required
    [ -z "$docs_only_cmd" ] || docs_battery=targeted
    docs_policy_record="tests: docs-policy v1 base=$docs_base head=$docs_head policy=$docs_policy_oid paths=$docs_only_files battery=$docs_battery"
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
     selection="$(git show "$PG_CONFIG_BASE:$PROCESS_GATE_TEST_MAP" | PROCESS_GATE_TEST_SELECTION="${PROCESS_GATE_TEST_SELECTION:-auto}" python3 -I - "$RANGE")"; then
    while IFS= read -r test_file; do
      printf -v test_arg '%q' "--test-file=$test_file"
      PROCESS_GATE_TEST_CMD+=" $test_arg"
      diff_tests_count=$((diff_tests_count + 1))
    done <<< "${selection#*$'\n'}"
  else
    printf 'process-gate: full tests — selector unavailable or range not mapped\n' >&2
  fi
fi

# A passing verdict for the same committed tree, test command, runner,
# toolchain and platform replaces the Tests run (references/tests.md). The
# canonical local runner writes its own verdicts; any other project command is
# recorded here after a passing full run. A narrowed or docs-only range, a dirty
# checkout, a different gated HEAD, a tag push or `.trellis.json`
# gate.verdict_reuse=false misses and runs the command.
PG_REUSED_VERDICT=""
PG_TAG_VERDICT=""
pg_verdict_helper="$SKILL_DIR/../../../scripts/lib/gate_verdict.py"
pg_verdict_args=()
pg_tests_passed=0
pg_tests_output=""
pg_is_local_runner() {
  [ "${PROCESS_GATE_TEST_CMD:-}" = 'python3 scripts/run-tests-local.py' ] ||
    [ "${PROCESS_GATE_TEST_CMD:-}" = 'python3 -I scripts/run-tests-local.py' ]
}
if [ "$tag_push" -eq 1 ] && [ -n "$release_tag" ] && [ "$(pg_parse_mode "$@")" = push ] && pg_is_local_runner; then
  if tag_result="$(python3 -I -B "$SKILL_DIR/../../../scripts/lib/tag_push_reuse.py" "$release_tag" "$RANGE")"; then
    PG_TAG_VERDICT="${tag_result%%$'\n'*}"
    PROCESS_GATE_TEST_CMD="${tag_result#*$'\n'}"
  fi
fi
# A forced-full run (PG_PUSH_TEST_SCOPE=full) never reads a pass, but is still
# tracked: the lookup persists its intent before it executes, so its failure,
# or its exit without a verdict, invalidates passes for the same tree and
# command. Tag pushes keep their own verified path. Store errors are reported,
# never swallowed.
pg_verdict_reuse=0
[ "$pg_push_scope" = full ] || pg_verdict_reuse=1
pg_verdict_errors=()
pg_verdict_untracked=""
if [ "$tag_push" -eq 0 ] && [ "$diff_tests_count" -eq 0 ] && [ -z "$docs_only_files" ] &&
  [ -n "${PROCESS_GATE_TEST_CMD:-}" ]; then
  # shellcheck source=lib/diff-base.sh
  . "$SKILL_DIR/scripts/lib/diff-base.sh"
  if db_resolve --range="$RANGE" >/dev/null 2>&1 && [ -n "$DB_HEAD_SHA" ]; then
    if pg_is_local_runner; then
      if [ "$pg_verdict_reuse" -eq 1 ] && [ -f scripts/lib/gate_verdict.py ]; then
        PG_REUSED_VERDICT="$(python3 -I -B scripts/run-tests-local.py --verdict-status "--head=$DB_HEAD_SHA" 2>/dev/null)" || PG_REUSED_VERDICT=""
      fi
    elif [ -f "$pg_verdict_helper" ] &&
      pg_verdict_inputs="$(umask 077; mktemp "${TMPDIR:-/tmp}/pg-verdict-inputs.XXXXXXXX")"; then
      pg_verdict_args=("--head=$DB_HEAD_SHA" "--command=$PROCESS_GATE_TEST_CMD" "--save=$pg_verdict_inputs"
        "--runner=$SKILL_DIR/scripts/check-tests.sh" "--runner=$SKILL_DIR/scripts/lib/common.sh")
      pg_verdict_lookup=("--owner-pid=$$")
      [ "$pg_verdict_reuse" -eq 1 ] || pg_verdict_lookup+=(--no-reuse)
      pg_verdict_status=0
      pg_verdict_out="$(python3 -I -B "$pg_verdict_helper" lookup "${pg_verdict_args[@]}" "${pg_verdict_lookup[@]}" 2>&1)" ||
        pg_verdict_status=$?
      case $pg_verdict_status in
        0) PG_REUSED_VERDICT="$pg_verdict_out" ;;
        1) [ -z "$pg_verdict_out" ] || pg_verdict_errors+=("$pg_verdict_out") ;;
        # No durable intent: running untracked could let a store repair revive
        # passes this run's failure supersedes, so the command does not run.
        3) pg_verdict_untracked="${pg_verdict_out:-lookup could not track the run}" ;;
        *) pg_verdict_errors+=("${pg_verdict_out:-lookup failed}") ;;
      esac
    fi
    # A reuse repeats the configured command's verdict; it claims nothing
    # about whether that command is the project's full suite.
    [ -z "$PG_REUSED_VERDICT" ] || tests_scope='reused: configured command'
  fi
fi

# Two ceilings, because `run_check` drives typecheck, lint AND tests through one
# code path. A project whose battery legitimately runs for hours has to raise the
# test ceiling, and while there was only one variable that raise silently removed
# the guard from typecheck and lint too — the two checks that should never take
# more than a few minutes and whose runaway is exactly what a timeout is for.
# Bound runaway test runs, not legitimate full suites: allow 90 minutes,
# including a shared database-lock wait (up to 900 s). Config loads from BASE,
# so a project cannot raise a too-short default in the same push that needs it.
PROCESS_GATE_TEST_TIMEOUT="${PROCESS_GATE_TEST_TIMEOUT:-5400}"
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
# the timeout starts once the slot is held, not while waiting for it. Only a
# known cap-1 installation (or no machine home) may use the legacy timer on a
# failed preflight. The battery is never retried outside the gate after launch.
PG_HEAVY_LAUNCHER=""
PG_HEAVY_PROTOCOL=""

pg_heavy_machine_cap() {
  local home="$1" path="$1/config.json" permissions config_permissions
  [ -d "$home" ] && [ ! -L "$home" ] && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  # Mirror the stable launcher's private path checks, including Darwin ACLs
  # (an xattr can otherwise hide the ACL marker). Do not read project policy.
  case "$OSTYPE" in
    darwin*) permissions="$(/usr/bin/env LC_ALL=C /bin/ls -lde "$home" "$path" 2>/dev/null)" || return 1 ;;
    *)       permissions="$(/usr/bin/env LC_ALL=C /bin/ls -ld "$home" "$path" 2>/dev/null)" || return 1 ;;
  esac
  [[ "$permissions" == *$'\n'* && "${permissions#*$'\n'}" != *$'\n'* ]] || return 1
  config_permissions="${permissions#*$'\n'}"
  case "${permissions%% *}:${config_permissions%% *}" in *+*) return 1 ;; esac
  # Match the supervisor's JSON number typing. Invalid values normalize to 1
  # but still need a v2 runtime: they must not cause an ungated run.
  /usr/bin/env -i /usr/bin/perl -MFcntl=:DEFAULT -MJSON::PP -e '
    my ($home, $path) = @ARGV;
    my @dir = lstat($home);
    exit 1 unless @dir && -d _ && $dir[4] == $> && !($dir[2] & 0077);
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;
    my @file = stat($fh);
    exit 1 unless @file && -f _ && $file[4] == $> && ($file[2] & 0400) && !($file[2] & 07077);
    my ($text, $chunk) = (q{}, q{});
    while (1) {
      my $n = read($fh, $chunk, 65536);
      exit 1 unless defined $n;
      last if $n == 0;
      $text .= $chunk;
    }
    close($fh) or exit 1;
    my $json = JSON::PP->new->utf8->allow_bignum;
    my $data = eval { $json->decode($text) };
    exit 1 unless ref($data) eq "HASH";
    my $raw = $data->{process_gate_slots};
    if (!exists $data->{process_gate_slots}) {
      print "1\n";
    } elsif (!ref($raw) && $json->allow_nonref->encode($raw) =~ /\A[12]\z/) {
      print "$raw\n";
    } else {
      print "normalized-1\n";
    }
  ' "$home" "$path" 2>/dev/null
}

pg_heavy_block() {
  pg_log fail "Tests & coverage"
  pg_finding "tests: heavy-gate-incompatible: $1"
  pg_finding "Repair the private machine config and install a matching launcher and release with trellis configure; verify with trellis heavy --check."
  pg_finding "Tests: not run"
  exit 1
}

pg_heavy_preflight() {
  local launcher="${PROCESS_GATE_HEAVY_LAUNCHER:-}" out rc reason cap line advertised="" count=0
  local user_home="${HOME:-}" home
  [ -n "${TRELLIS_HOME:-$user_home}" ] || pg_heavy_block 'HOME is required when TRELLIS_HOME is unset'
  home="${TRELLIS_HOME:-${user_home%/}/.trellis}"
  local ok_v2='^trellis heavy: ok \(heavy_slots=[1-9][0-9]*, heavy_light_slots=[1-9][0-9]*, process_gate_slots=([12]), process_gate_protocol=2, slots in /[^[:cntrl:]]+\)$'
  while [ "${home%/}" != "$home" ] && [ "$home" != / ]; do home="${home%/}"; done
  case "$home" in
    /|*$'\t'*|*$'\r'*|*$'\n'*|*/../*|*/..|*/./*|*/.|*//*|[!/]*)
      pg_heavy_block "invalid machine home: $home" ;;
  esac
  if [ ! -e "$home" ] && [ ! -L "$home" ]; then
    cap=1 # A conventional unmanaged host (or fenced test sandbox) has no machine home yet.
  elif ! cap="$(pg_heavy_machine_cap "$home")"; then
    pg_heavy_block "cannot establish process_gate_slots from $home/config.json"
  fi

  if [ -z "$launcher" ]; then
    launcher="$(command -v trellis 2>/dev/null || true)"
  fi
  if [ -z "$launcher" ] || [ ! -x "$launcher" ]; then
    reason="trellis launcher not found${launcher:+: $launcher}"
  elif out="$("$launcher" heavy --check 2>&1)"; then
    while IFS= read -r line; do
      if [[ "$line" =~ $ok_v2 ]]; then
        advertised="${BASH_REMATCH[1]}"
        count=$((count + 1))
      fi
    done <<< "$out"
    if { [ "$cap" = 1 ] && [ "$count" -eq 0 ]; } ||
      { [ "$count" -eq 1 ] && [ "$advertised" = "${cap#normalized-}" ]; }; then
      PG_HEAVY_LAUNCHER="$launcher"
      # Installed --check can be served by the launcher itself. Make the
      # actual payload prove support as well, before it starts the workload.
      [ "$cap" = 1 ] || PG_HEAVY_PROTOCOL=2
      return 0
    fi
    pg_heavy_block "trellis heavy --check did not advertise one matching process_gate_protocol=2 result for process_gate_slots=${cap#normalized-}"
  else
    rc=$?
    reason="trellis heavy --check exited $rc: $(printf '%s\n' "$out" | tail -n 1)"
  fi
  [ "$cap" = 1 ] || pg_heavy_block "$reason (process_gate_slots=${cap#normalized-} requires process_gate_protocol=2)"
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

pg_host_cores() {
  local n=""
  if command -v getconf >/dev/null 2>&1; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  elif [ -x /usr/sbin/sysctl ]; then
    n="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || true)"
  elif [ -x /usr/bin/getconf ]; then
    n="$(/usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  case "$n" in
    ''|0|*[!0-9]*) n=2 ;;
  esac
  printf '%s\n' "$n"
}

pg_check_limit() {
  case "$1" in
    tests) printf '%s\n' "$PROCESS_GATE_TEST_TIMEOUT" ;;
    *)     printf '%s\n' "$PROCESS_GATE_CHECK_TIMEOUT" ;;
  esac
}

# Execute one check command, setting _pg_exec_out, _pg_exec_rc, _pg_exec_unbounded.
# Keep the exact PG_TIMEOUT_RUNNER / run_with_timeout "$limit" shape pinned by check-tests.bats.
pg_exec_check_cmd() {
  local label="$1" cmd="$2" limit="$3" receipt_path="${4:-}"
  local out="" rc=0 unbounded=0
  local -a command_env=()
  if [ -n "$receipt_path" ]; then
    command_env=(env "PG_TESTS_BASE=$_pg_tests_base" "PG_TESTS_HEAD=$_pg_tests_head"
      "PG_TESTS_RECEIPT_FILE=$receipt_path")
  fi
  set +e
  if [ "$label" = tests ] && [ -n "$PG_HEAVY_LAUNCHER" ]; then
    out="$("$PG_HEAVY_LAUNCHER" heavy ${PG_HEAVY_PROTOCOL:+"--require-gate-protocol=$PG_HEAVY_PROTOCOL"} \
      --lane process-gate --timeout "$limit" -- ${command_env[@]+"${command_env[@]}"} bash -c "$cmd" 2>&1)"; rc=$?
  elif [ -n "$PG_TIMEOUT_RUNNER" ]; then
    out="$(run_with_timeout "$limit" ${command_env[@]+"${command_env[@]}"} bash -c "$cmd" 2>&1)"; rc=$?
  else
    # No bounded runner reachable on this PATH. Still RUN the check -- refusing
    # would turn the gate into a silent skip, which is a worse hole than an
    # unbounded run -- but say so once, so an unbounded wait is never invisible.
    out="$(${command_env[@]+"${command_env[@]}"} bash -c "$cmd" 2>&1)"; rc=$?
    unbounded=1
  fi
  set -e
  _pg_exec_out="$out"
  _pg_exec_rc="$rc"
  _pg_exec_unbounded="$unbounded"
}

pg_finalize_check_result() {
  local label="$1" cmd="$2" limit="$3" rc="$4" unbounded="$5" out="$6"
  local receipt receipt_failed=0 line
  if [ "$unbounded" -eq 1 ] && [ "$pg_unbounded_warned" = no ]; then
    pg_unbounded_warned=yes
    findings+=("checks ran UNBOUNDED: no timeout, gtimeout or perl on PATH — a hung command will not be killed")
    if [ "$worst" = "pass" ]; then
      worst="warn"
    fi
  fi
  [ "$label" != tests ] || pg_tests_output="$out"

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
      docs_child_scope=1
    else
      findings+=("invalid Tests receipt: expected one PG_TESTS_RECEIPT line")
      receipt_failed=1
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
      receipt_failed=1
      worst=fail
    fi
  fi
  if [ "$label" = tests ] && [ -n "$pg_tests_receipt_file" ]; then
    rm -f "$pg_tests_receipt_file"
    pg_tests_receipt_file=""
  fi

  # A legacy payload refuses the required flag even if installed --check
  # advertised v2. This is a deployment failure, not a failing battery.
  if [ "$label" = tests ] && [ "$PG_HEAVY_PROTOCOL" = 2 ] && [ "$rc" -eq 2 ] &&
    [[ "$out" == 'trellis heavy: unexpected argument: --require-gate-protocol=2 (put the command after --)'$'\n'* ]]; then
    findings+=("tests: heavy-gate-incompatible: the heavy payload does not support process_gate_protocol=2; install a matching launcher and release with trellis configure")
    tests_scope='not run'
    worst=fail
    return 0
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
  elif [ "$label" = tests ] && [ "$receipt_failed" -eq 0 ]; then
    pg_tests_passed=1
  fi
}

run_check() {
  local label="$1" cmd="$2" limit
  limit="$(pg_check_limit "$label")"
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
  # A reuse-tracked command never gets the range interface: its verdict is
  # keyed without the range, so committed code that narrowed on
  # PG_TESTS_BASE would publish a pass another range then reuses. A project
  # that selects through it sets gate.verdict_reuse=false.
  if [ "$label" = tests ] && [ -z "$docs_only_files" ] && [ -z "$PG_TAG_VERDICT" ] &&
    [ -n "$_pg_tests_base" ] && [ -n "$_pg_tests_head" ] && [ ! -s "$pg_verdict_inputs" ]; then
    pg_tests_receipt_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/pg-tests-receipt.XXXXXXXX")"
  fi
  [ "$label" != tests ] || tests_scope=full
  pg_exec_check_cmd "$label" "$cmd" "$limit" "${pg_tests_receipt_file:-}"
  pg_finalize_check_result "$label" "$cmd" "$limit" "$_pg_exec_rc" "$_pg_exec_unbounded" "$_pg_exec_out"
}

pg_spawn_check_stage() {
  local label="$1" cmd="$2" limit="$3" receipt_path="${4:-}"
  (
    pg_exec_check_cmd "$label" "$cmd" "$limit" "$receipt_path"
    printf '%s\n' "$_pg_exec_rc" > "$pg_check_scratch/$label.rc"
    printf '%s\n' "$_pg_exec_unbounded" > "$pg_check_scratch/$label.unbounded"
    printf '%s.' "$_pg_exec_out" > "$pg_check_scratch/$label.out"
  ) &
  pg_check_pids+=("$!")
}

pg_collect_check_stage() {
  local label="$1" cmd="$2" limit rc=1 unbounded=0 raw=""
  limit="$(pg_check_limit "$label")"
  if [ -z "$cmd" ]; then
    findings+=("$label: not declared/detected — skipped")
    if [ "$worst" = "pass" ]; then
      worst="warn"
    fi
    return 0
  fi
  if [ ! -s "$pg_check_scratch/$label.rc" ] || [ ! -s "$pg_check_scratch/$label.out" ]; then
    findings+=("$label: check runner exited unexpectedly without recording status")
    worst="fail"
    return 0
  fi
  IFS= read -r rc < "$pg_check_scratch/$label.rc"
  IFS= read -r unbounded < "$pg_check_scratch/$label.unbounded"
  raw="$(< "$pg_check_scratch/$label.out")"
  pg_finalize_check_result "$label" "$cmd" "$limit" "$rc" "${unbounded:-0}" "${raw%.}"
}

# Deduplicate only an exact base-declared tuple after test selection. A docs
# policy can even name the same command, but a narrowed run keeps local checks.
static_checks_in_battery=""
run_tests_stage=0
if [ -z "$pg_verdict_untracked" ] && [ -z "$PG_REUSED_VERDICT" ] &&
  { [ -z "$docs_only_files" ] || [ -n "${PROCESS_GATE_TEST_CMD:-}" ]; }; then
  run_tests_stage=1
fi

if [ -z "$docs_only_files" ] && [ "${#PROCESS_GATE_TEST_COVERS_STATIC[@]}" -eq 3 ] &&
  [ -n "${PROCESS_GATE_TEST_CMD:-}" ] &&
  [ "$PROCESS_GATE_TEST_CMD" = "${PROCESS_GATE_TEST_COVERS_STATIC[0]}" ] &&
  [ "${PROCESS_GATE_TYPECHECK_CMD:-}" = "${PROCESS_GATE_TEST_COVERS_STATIC[1]}" ] &&
  [ "${PROCESS_GATE_LINT_CMD:-}" = "${PROCESS_GATE_TEST_COVERS_STATIC[2]}" ]; then
  static_checks_in_battery="typecheck and lint: included in full test battery"
  if [ -n "$pg_verdict_untracked" ]; then
    findings+=("tests: not run: ${pg_verdict_untracked//$'\n'/ }; repair or remove the verdict store, or set gate.verdict_reuse=false")
    worst=fail
  elif [ "$run_tests_stage" -eq 1 ]; then
    run_check "tests" "${PROCESS_GATE_TEST_CMD:-}"
    if [ -n "$PG_TAG_VERDICT" ] && [ "$tests_scope" = full ]; then tests_scope='reused: configured command'; fi
  fi
else
  _nonempty_stages=0
  [ -z "${PROCESS_GATE_TYPECHECK_CMD:-}" ] || _nonempty_stages=$((_nonempty_stages + 1))
  [ -z "${PROCESS_GATE_LINT_CMD:-}" ] || _nonempty_stages=$((_nonempty_stages + 1))
  if [ "$run_tests_stage" -eq 1 ] && [ -n "${PROCESS_GATE_TEST_CMD:-}" ]; then
    _nonempty_stages=$((_nonempty_stages + 1))
  fi
  _max_parallel="$(pg_host_cores)"
  if [ "${PROCESS_GATE_SERIAL_CHECKS:-0}" = "1" ] || [ "$_max_parallel" -le 1 ] || [ "$_nonempty_stages" -le 1 ] ||
    ! pg_check_scratch="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/pg-checks.XXXXXXXX" 2>/dev/null || mktemp -d -t pg-checks)"; then
    pg_check_scratch=""
    run_check "typecheck" "${PROCESS_GATE_TYPECHECK_CMD:-}"
    run_check "lint"      "${PROCESS_GATE_LINT_CMD:-}"
    if [ -n "$pg_verdict_untracked" ]; then
      findings+=("tests: not run: ${pg_verdict_untracked//$'\n'/ }; repair or remove the verdict store, or set gate.verdict_reuse=false")
      worst=fail
    elif [ "$run_tests_stage" -eq 1 ]; then
      run_check "tests"   "${PROCESS_GATE_TEST_CMD:-}"
      if [ -n "$PG_TAG_VERDICT" ] && [ "$tests_scope" = full ]; then tests_scope='reused: configured command'; fi
    fi
  else
    pg_check_pids=()
    trap 'pg_cleanup_check_tests; exit 130' INT
    trap 'pg_cleanup_check_tests; exit 143' TERM
    if [ -n "${PROCESS_GATE_TYPECHECK_CMD:-}" ]; then
      pg_spawn_check_stage "typecheck" "$PROCESS_GATE_TYPECHECK_CMD" "$(pg_check_limit typecheck)" ""
    fi
    if [ -n "${PROCESS_GATE_LINT_CMD:-}" ]; then
      if [ "${#pg_check_pids[@]}" -ge "$_max_parallel" ]; then
        wait "${pg_check_pids[0]}"
        pg_check_pids=("${pg_check_pids[@]:1}")
      fi
      pg_spawn_check_stage "lint" "$PROCESS_GATE_LINT_CMD" "$(pg_check_limit lint)" ""
    fi
    if [ "$run_tests_stage" -eq 1 ] && [ -n "${PROCESS_GATE_TEST_CMD:-}" ]; then
      if [ -z "$docs_only_files" ] && [ -z "$PG_TAG_VERDICT" ] &&
        [ -n "$_pg_tests_base" ] && [ -n "$_pg_tests_head" ] && [ ! -s "$pg_verdict_inputs" ]; then
        pg_tests_receipt_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/pg-tests-receipt.XXXXXXXX")"
      fi
      tests_scope=full
      if [ "${#pg_check_pids[@]}" -ge "$_max_parallel" ]; then
        wait "${pg_check_pids[0]}"
        pg_check_pids=("${pg_check_pids[@]:1}")
      fi
      pg_spawn_check_stage "tests" "$PROCESS_GATE_TEST_CMD" "$(pg_check_limit tests)" "${pg_tests_receipt_file:-}"
    fi
    for _check_pid in ${pg_check_pids[@]+"${pg_check_pids[@]}"}; do
      wait "$_check_pid"
    done
    pg_check_pids=()
    trap - INT TERM
    pg_collect_check_stage "typecheck" "${PROCESS_GATE_TYPECHECK_CMD:-}"
    pg_collect_check_stage "lint"      "${PROCESS_GATE_LINT_CMD:-}"
    if [ -n "$pg_verdict_untracked" ]; then
      findings+=("tests: not run: ${pg_verdict_untracked//$'\n'/ }; repair or remove the verdict store, or set gate.verdict_reuse=false")
      worst=fail
    elif [ "$run_tests_stage" -eq 1 ]; then
      pg_collect_check_stage "tests"   "${PROCESS_GATE_TEST_CMD:-}"
      if [ -n "$PG_TAG_VERDICT" ] && [ "$tests_scope" = full ]; then tests_scope='reused: configured command'; fi
    fi
    rm -rf "$pg_check_scratch"
    pg_check_scratch=""
  fi
fi
# Record a project command's pass only for a full run whose inputs the lookup
# saved and the run left unchanged; the helper recaptures and compares, and
# retains the run's output as the verdict's execution log. A failing run drops
# every pass for the same tree and command; a pass that publishes nothing
# releases its intent.
if [ -z "$PG_REUSED_VERDICT" ] && [ -s "$pg_verdict_inputs" ]; then
  if [ "$pg_tests_passed" -eq 1 ] && [ "$tests_scope" = full ]; then
    pg_verdict_out="$(printf '%s\n' "$pg_tests_output" |
      python3 -I -B "$pg_verdict_helper" record "${pg_verdict_args[@]}" --log=- 2>&1 >/dev/null)" || true
  elif [ "$pg_tests_passed" -eq 1 ]; then
    pg_verdict_out="$(python3 -I -B "$pg_verdict_helper" release "${pg_verdict_args[@]}" 2>&1 >/dev/null)" || true
  else
    pg_verdict_out="$(python3 -I -B "$pg_verdict_helper" forget "${pg_verdict_args[@]}" 2>&1 >/dev/null)" || true
  fi
  [ -z "$pg_verdict_out" ] || pg_verdict_errors+=("$pg_verdict_out")
fi
for pg_verdict_error in ${pg_verdict_errors[@]+"${pg_verdict_errors[@]}"}; do
  findings+=("tests: verdict store: ${pg_verdict_error//$'\n'/ }")
  if [ "$worst" = pass ]; then worst=warn; fi
done
if [ -n "$auto_missing_suites" ] && [ -z "$docs_only_files" ]; then
  findings+=("tests: autodetection did not run $auto_missing_suites; declare PROCESS_GATE_TEST_CMD in process-gate-local/local.config.sh as a project-wide command")
  if [ "$worst" = pass ]; then worst=warn; fi
  if [ "$tests_scope" = full ]; then tests_scope=partial; fi
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

# Net test-LOC growth ratchet (P49): nudge consolidation when net added minus
# deleted lines across test files in base..head exceeds PROCESS_GATE_TEST_NET_BUDGET.
pg_is_test_ratchet_path() {
  local p="$1" base="${1##*/}"
  case "$base" in
    *.md|*.mdx|*.rst|*.txt) return 1 ;;
  esac
  case "$p" in
    *.bats|tests/*|*/tests/*|test/*|*/test/*|__tests__/*|*/__tests__/*)
      return 0 ;;
  esac
  case "$base" in
    *.test.*|*.spec.*|*_test.*|*_spec.*|test_*|*Test.*|*Tests.*|*Spec.*) return 0 ;;
  esac
  return 1
}

pg_check_net_test_loc() {
  [ "$tag_push" -eq 0 ] || return 0
  local mode="${PROCESS_GATE_TEST_NET_BUDGET_MODE:-warn}"
  local budget="${PROCESS_GATE_TEST_NET_BUDGET:-400}"
  [ "$mode" != "off" ] || return 0
  case "$budget" in
    ''|*[!0-9]*) budget=400 ;;
  esac
  local rbase rhead
  rbase="$(pg_range_base "$PROJECT_DIR" "$RANGE")" || return 0
  rhead="$(pg_range_head "$PROJECT_DIR" "$RANGE")" || return 0
  [ -n "$rbase" ] && [ -n "$rhead" ] && [ "$rbase" != "$rhead" ] || return 0
  local numstat added deleted path net_loc=0
  numstat="$(git -C "$PROJECT_DIR" diff --numstat --no-renames "$rbase..$rhead" -- 2>/dev/null)" || return 0
  [ -n "$numstat" ] || return 0
  while IFS=$'\t' read -r added deleted path; do
    [ -n "$path" ] || continue
    case "$added:$deleted" in
      *:|:*|*[!0-9:]*) continue ;;
    esac
    pg_is_test_ratchet_path "$path" || continue
    net_loc=$((net_loc + added - deleted))
  done <<< "$numstat"
  if [ "$net_loc" -gt "$budget" ]; then
    findings+=("net test LOC +${net_loc} exceeds budget +${budget}; consolidate redundant cases or set PROCESS_GATE_TEST_NET_BUDGET")
    if [ "$mode" = "block" ]; then
      worst="fail"
    elif [ "$worst" = "pass" ]; then
      worst="warn"
    fi
  fi
}

pg_check_net_test_loc

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
    if ! mutation_work="$(mktemp -d 2>/dev/null || mktemp -d -t check-tests-mutation)" \
      || [ -z "$mutation_work" ] || [ ! -d "$mutation_work" ]; then
      mutation_work=""
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

# Reserve exact two-space protocol lines for the checker itself. A multiline
# diagnostic never gets to create a sibling finding.
pg_check_finding() { pg_finding "${1//$'\n'/$'\n    '}"; }
case "$worst" in
  pass)
    pg_log pass "Tests & coverage"
    [ -z "$mutation_result" ] || pg_check_finding "$mutation_result"
    ;;
  warn)
    pg_log warn "Tests & coverage"
    for f in ${findings[@]+"${findings[@]}"}; do pg_check_finding "$f"; done
    [ -z "$mutation_result" ] || pg_check_finding "$mutation_result"
    ;;
  fail)
    pg_log fail "Tests & coverage"
    for f in ${findings[@]+"${findings[@]}"}; do pg_check_finding "$f"; done
    ;;
esac
[ -z "$PG_REUSED_VERDICT" ] || pg_check_finding "tests: $PG_REUSED_VERDICT"
if [ -n "$PG_TAG_VERDICT" ]; then
  pg_check_finding "tests: $PG_TAG_VERDICT"
  pg_finding "tests: tag-reading suites executed"
fi
[ -z "$static_checks_in_battery" ] || pg_finding "$static_checks_in_battery"
# run-all.sh carries these checker-owned lines into the verdict.
[ -z "$docs_policy_record" ] || pg_finding "$docs_policy_record"
[ "$docs_child_scope" -eq 0 ] || pg_finding 'tests: no-tests scope reported by configured command'
if [ -n "$release_metadata_class" ]; then
  pg_finding "Tests: narrowed (release-metadata: $docs_only_files files)"
elif [ -n "$docs_only_files" ] && { [ "$tests_scope" = full ] || [ "$tests_scope" = 'not run' ]; }; then
  pg_finding "Tests: narrowed (docs-only: $docs_only_files files)"
else
  pg_finding "Tests: $tests_scope"
fi

pg_exit_code "$worst"
