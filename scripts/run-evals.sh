#!/usr/bin/env bash
# scripts/run-evals.sh — eval harness runner.
#
# Discovers fixtures under core-rules/evals/<project>/<id>/, invokes
# claude -p headless against each (n times per fixture), evaluates the
# expected.json assertions, and emits a pass-rate JSON.
#
# See core-rules/evals/SCHEMA.md for the fixture format.
#
# Usage: scripts/run-evals.sh [OPTIONS]
#
# Modes:
#   --check               Parse and validate every fixture; no model invocation.
#   --dry-run             --check plus print what would run; no invocation.
#   (default)             Run fixtures end-to-end and emit results.
#
# Filtering:
#   --filter <pattern>    Glob against <project>/<id>; e.g. 'neev/*' or '*/regression-*'.
#   --changed-only        Only fixtures whose dir is touched in `git diff main..HEAD`.
#
# Output:
#   --output <path>       Results JSON path (default: core-rules/evals/.results/<ts>.json).
#   --quiet               Less verbose progress.
#
# Tools required: yq, jq, git. Run mode also needs: claude CLI, ANTHROPIC_API_KEY.
#
# Exit codes:
#   0  All selected fixtures passed (or --check / --dry-run completed clean).
#   1  At least one fixture failed.
#   2  Bad arguments.
#   3  Missing dependency or required env var.
#   4  Fixture schema validation error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALS_DIR="$ROOT/core-rules/evals"
PARENT_RULES_FILE="$ROOT/core-rules/CLAUDE.md"
REGISTRY_FILE="$ROOT/registry.md"
BLACKLIST_FILE="$ROOT/blacklist.md"

MODE="run"
FILTER=""
CHANGED_ONLY=0
OUTPUT=""
QUIET=0

usage() {
  sed -n '4,29p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    --filter)
      [ $# -ge 2 ] || { echo "error: --filter requires an argument" >&2; exit 2; }
      FILTER="$2"; shift 2 ;;
    --changed-only) CHANGED_ONLY=1; shift ;;
    --output)
      [ $# -ge 2 ] || { echo "error: --output requires an argument" >&2; exit 2; }
      OUTPUT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }
err()  { printf 'error: %s\n' "$*" >&2; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { err "missing tool: $1"; exit 3; }
}

require_tool yq
require_tool jq
require_tool git
if [ "$MODE" = "run" ]; then
  require_tool claude
  [ -n "${ANTHROPIC_API_KEY:-}" ] || { err "ANTHROPIC_API_KEY not set (required for run mode)"; exit 3; }
fi

# -----------------------------------------------------------------------------
# Discovery + filtering
# -----------------------------------------------------------------------------

discover_fixtures() {
  find "$EVALS_DIR" -mindepth 3 -maxdepth 3 -type f -name 'manifest.yml' \
    ! -path "$EVALS_DIR/template/*" 2>/dev/null \
    | sort
}

registry_projects() {
  awk -F '|' '
    /^## Active projects/ { active=1; next }
    active && /^---$/ { exit }
    active && /^\|/ {
      name=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != "" && name != "Project" && name != "—" && name !~ /^-+$/) print name
    }
  ' "$REGISTRY_FILE"
}

blacklisted_projects() {
  awk -F '|' '
    /^## 1\./ { section=1; next }
    /^## 2\./ { section=2; next }
    section > 0 && /^\|/ {
      name=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/`/, "", name)
      if (section == 2) sub(/^.*\//, "", name)
      if (name != "" && name != "Project" && name != "Path" && name != "—" && name !~ /^-+$/) print name
    }
  ' "$BLACKLIST_FILE" | sort -u
}

reconcile_eval_projects() {
  local registry_present=0 blacklist_present=0 evals_present=0
  [ -e "$REGISTRY_FILE" ] && registry_present=1
  [ -e "$BLACKLIST_FILE" ] && blacklist_present=1
  [ -e "$EVALS_DIR" ] && evals_present=1

  # The public template intentionally excludes all three private fleet inputs.
  # That all-absent shape is valid; any partial shape is drift and must fail
  # closed before fixture discovery can silently under-count the fleet.
  if [ "$registry_present" -eq 0 ] && [ "$blacklist_present" -eq 0 ] && [ "$evals_present" -eq 0 ]; then
    return 0
  fi
  if [ "$registry_present" -eq 0 ] || [ ! -r "$REGISTRY_FILE" ]; then
    err "registry is missing or unreadable: $REGISTRY_FILE"
    return 1
  fi
  if [ "$blacklist_present" -eq 0 ] || [ ! -r "$BLACKLIST_FILE" ]; then
    err "blacklist is missing or unreadable: $BLACKLIST_FILE"
    return 1
  fi
  if [ "$evals_present" -eq 0 ] || [ ! -d "$EVALS_DIR" ] || [ ! -r "$EVALS_DIR" ]; then
    err "eval fixture root is missing, unreadable, or not a directory: $EVALS_DIR"
    return 1
  fi

  local registered blacklisted fixture_projects missing project
  registered="$(registry_projects)"
  blacklisted="$(blacklisted_projects)"
  fixture_projects="$(discover_fixtures \
    | sed "s#^$EVALS_DIR/##; s#/.*##" \
    | sort -u)"
  missing=0

  while IFS= read -r project; do
    [ -n "$project" ] || continue
    if printf '%s\n' "$blacklisted" | grep -Fqx "$project"; then
      continue
    fi
    if ! printf '%s\n' "$fixture_projects" | grep -Fqx "$project"; then
      err "active project '$project' is missing eval fixture manifests under core-rules/evals/$project/"
      missing=$((missing + 1))
    fi
  done <<EOF
$registered
EOF

  if [ "$missing" -gt 0 ]; then
    err "$missing active non-blacklisted project(s) have no eval fixtures"
    return 1
  fi
}

apply_filter() {
  local mf rel
  while IFS= read -r mf; do
    [ -z "$mf" ] && continue
    rel="${mf#"$EVALS_DIR/"}"
    rel="${rel%/manifest.yml}"
    if [ -n "$FILTER" ]; then
      # shellcheck disable=SC2254
      case "$rel" in $FILTER) ;; *) continue ;; esac
    fi
    if [ "$CHANGED_ONLY" -eq 1 ]; then
      local fdir_rel="core-rules/evals/$rel/"
      git -C "$ROOT" diff --name-only main..HEAD 2>/dev/null \
        | grep -qx "${fdir_rel}.*\\|${fdir_rel%/}" \
        || git -C "$ROOT" diff --name-only main..HEAD 2>/dev/null \
        | grep -q "^$fdir_rel" \
        || continue
    fi
    printf '%s\n' "$mf"
  done
}

# -----------------------------------------------------------------------------
# Fixture validation (schema-level)
# -----------------------------------------------------------------------------

validate_fixture() {
  local mf="$1"
  local fdir; fdir="$(dirname "$mf")"
  local exp="$fdir/expected.json"
  local fixture_id; fixture_id="$(basename "$fdir")"
  local errs=()

  if ! yq '.' "$mf" >/dev/null 2>&1; then
    errs+=("manifest.yml: not valid YAML")
    printf '%s\n' "${errs[@]}"; return 1
  fi

  local v id project prompt
  v=$(yq -r '.version // ""' "$mf")
  id=$(yq -r '.id // ""' "$mf")
  project=$(yq -r '.project // ""' "$mf")
  prompt=$(yq -r '.prompt // ""' "$mf")

  [ "$v" = "1" ] || errs+=("manifest.yml: version must be 1, got '$v'")
  [ -n "$id" ] || errs+=("manifest.yml: required field 'id' missing")
  [ -n "$project" ] || errs+=("manifest.yml: required field 'project' missing")
  [ -n "$prompt" ] || errs+=("manifest.yml: required field 'prompt' missing")
  [ "$id" = "$fixture_id" ] || errs+=("manifest.yml: id '$id' does not match directory name '$fixture_id'")

  if [ ! -f "$exp" ]; then
    errs+=("expected.json: missing")
  elif ! jq '.' "$exp" >/dev/null 2>&1; then
    errs+=("expected.json: not valid JSON")
  else
    # Validate assertion types are recognised.
    local n_assertions; n_assertions=$(jq '.assertions // [] | length' "$exp")
    local i atype known
    for i in $(if [ "$n_assertions" -gt 0 ]; then seq 0 $((n_assertions - 1)); fi); do
      atype=$(jq -r ".assertions[$i].type" "$exp")
      case "$atype" in
        file_exists|file_does_not_exist|file_contains|file_equals|command_exit_code|output_contains) known=1 ;;
        *) errs+=("expected.json: unknown assertion type '$atype' at index $i"); known=0 ;;
      esac
      [ "$known" = "1" ] || true
    done
  fi

  if [ ${#errs[@]} -gt 0 ]; then
    printf '%s\n' "${errs[@]}"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Run a single fixture (n runs)
# -----------------------------------------------------------------------------

run_fixture() {
  local mf="$1"
  local fdir; fdir="$(dirname "$mf")"
  local exp="$fdir/expected.json"
  local seed="$fdir/seed"

  local id project prompt model runs timeout allowed disallowed perm_mode bare budget
  id=$(yq -r '.id' "$mf")
  project=$(yq -r '.project' "$mf")
  prompt=$(yq -r '.prompt' "$mf")
  model=$(yq -r '.model // "sonnet"' "$mf")
  runs=$(yq -r '.runs // 5' "$mf")
  timeout=$(yq -r '.timeout_seconds // 300' "$mf")
  allowed=$(yq -r '.allowed_tools // [] | join(",")' "$mf")
  disallowed=$(yq -r '.disallowed_tools // [] | join(",")' "$mf")
  perm_mode=$(yq -r '.permission_mode // "bypassPermissions"' "$mf")
  bare=$(yq -r '.bare // true' "$mf")
  budget=$(yq -r '.max_budget_usd // ""' "$mf")

  local threshold
  threshold=$(jq -r '.pass_threshold.min_pass_rate // 0.6' "$exp")

  log "▸ $project/$id (n=$runs, model=$model)"

  local results_arr=()
  local run_idx
  for run_idx in $(seq 1 "$runs"); do
    local r
    r=$(run_one "$id" "$prompt" "$model" "$timeout" \
                "$allowed" "$disallowed" "$perm_mode" "$bare" "$budget" \
                "$seed" "$exp" "$fdir")
    results_arr+=("$r")
    local r_pass; r_pass=$(jq -r '.passed' <<<"$r")
    log "  run $run_idx: $([ "$r_pass" = "true" ] && echo "✅ pass" || echo "❌ fail")"
  done

  local pass_count=0
  local r
  for r in "${results_arr[@]}"; do
    [ "$(jq -r '.passed' <<<"$r")" = "true" ] && pass_count=$((pass_count + 1))
  done
  local pass_rate
  pass_rate=$(awk -v p="$pass_count" -v t="$runs" 'BEGIN { printf "%.4f", (t==0)?0:(p/t) }')
  local fixture_passed
  fixture_passed=$(awk -v r="$pass_rate" -v t="$threshold" 'BEGIN { print (r+0 >= t+0) ? "true" : "false" }')

  local results_json
  if [ ${#results_arr[@]} -eq 0 ]; then
    results_json="[]"
  else
    results_json="[$(IFS=,; printf '%s' "${results_arr[*]}")]"
  fi

  jq -n \
    --arg id "$id" --arg project "$project" --arg model "$model" \
    --argjson runs "$runs" --argjson pass_count "$pass_count" \
    --argjson pass_rate "$pass_rate" --argjson threshold "$threshold" \
    --argjson passed "$fixture_passed" \
    --argjson run_results "$results_json" \
    '{id: $id, project: $project, model: $model, runs: $runs,
      pass_count: $pass_count, pass_rate: $pass_rate, threshold: $threshold,
      passed: $passed, run_results: $run_results}'
}

# -----------------------------------------------------------------------------
# Run a single iteration (one of N) of a fixture and emit run-result JSON
# -----------------------------------------------------------------------------

run_one() {
  local id="$1" prompt="$2" model="$3" timeout="$4"
  local allowed="$5" disallowed="$6" perm_mode="$7" bare="$8" budget="$9"
  local seed="${10}" exp="${11}" fdir="${12}"

  local ws; ws=$(mktemp -d -t "se-eval.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$ws'" RETURN

  if [ -d "$seed" ]; then
    cp -R "$seed/." "$ws/"
  fi

  ( cd "$ws" \
    && git init -q \
    && git config user.email "eval@trellis.test" \
    && git config user.name "eval" \
    && git add -A \
    && git commit -q --allow-empty -m "seed" )

  local cmd=(claude -p --output-format json --model "$model" --permission-mode "$perm_mode")
  if [ "$bare" = "true" ]; then
    cmd+=(--bare --append-system-prompt "$(cat "$PARENT_RULES_FILE")")
  fi
  # Expose the Trellis repo for Read access. Fixtures that need to reference
  # canonical hooks, skill scripts, or audit material cite them by repo-rooted
  # path (e.g. core-rules/hooks/block-destructive.sh) and the model resolves
  # them via this --add-dir without leaking the developer's wider filesystem.
  cmd+=(--add-dir "$ROOT")
  [ -n "$allowed" ] && cmd+=(--allowed-tools "$allowed")
  [ -n "$disallowed" ] && cmd+=(--disallowed-tools "$disallowed")
  [ -n "$budget" ] && cmd+=(--max-budget-usd "$budget")

  local out_file; out_file=$(mktemp)
  local start_s end_s rc=0
  start_s=$(date +%s)
  ( cd "$ws" && timeout "$timeout" "${cmd[@]}" "$prompt" >"$out_file" 2>/dev/null ) || rc=$?
  end_s=$(date +%s)
  local duration_ms=$(((end_s - start_s) * 1000))

  local model_output=""
  if jq -e '.result' "$out_file" >/dev/null 2>&1; then
    model_output=$(jq -r '.result // ""' < "$out_file")
  fi

  local touched
  touched=$(cd "$ws" && git status --porcelain | sed -E 's/^.{2} //' | sort -u)

  local files_pass="true"
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! printf '%s\n' "$touched" | grep -qx -- "$f"; then files_pass="false"; fi
  done < <(jq -r '.files_touched.must_include[]?' "$exp" 2>/dev/null || true)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if printf '%s\n' "$touched" | grep -qx -- "$f"; then files_pass="false"; fi
  done < <(jq -r '.files_touched.must_not_include[]?' "$exp" 2>/dev/null || true)

  local assertion_results=()
  local n_assertions; n_assertions=$(jq '.assertions // [] | length' "$exp")
  local i
  for i in $(if [ "$n_assertions" -gt 0 ]; then seq 0 $((n_assertions - 1)); fi); do
    local a aid atype apass
    a=$(jq ".assertions[$i]" "$exp")
    aid=$(jq -r '.id' <<<"$a")
    atype=$(jq -r '.type' <<<"$a")
    apass=$(eval_assertion "$ws" "$fdir" "$a" "$model_output")
    assertion_results+=("$(jq -n --arg id "$aid" --arg type "$atype" --arg passed "$apass" \
      '{id: $id, type: $type, passed: ($passed == "true")}')")
  done

  local run_passed="$files_pass"
  if [ "$run_passed" = "true" ] && [ ${#assertion_results[@]} -gt 0 ]; then
    local r
    for r in "${assertion_results[@]}"; do
      [ "$(jq -r '.passed' <<<"$r")" != "true" ] && run_passed="false"
    done
  fi

  local assertions_json="[]"
  if [ ${#assertion_results[@]} -gt 0 ]; then
    assertions_json="[$(IFS=,; printf '%s' "${assertion_results[*]}")]"
  fi

  local touched_json
  touched_json=$(printf '%s\n' "$touched" | jq -Rrs 'split("\n") | map(select(length>0))')

  rm -f "$out_file"

  jq -n \
    --argjson rc "$rc" --argjson dur "$duration_ms" \
    --arg files_pass "$files_pass" \
    --arg passed "$run_passed" \
    --argjson touched "$touched_json" \
    --argjson assertions "$assertions_json" \
    '{rc: $rc, duration_ms: $dur,
      files_touched_pass: ($files_pass == "true"),
      passed: ($passed == "true"),
      touched: $touched,
      assertions: $assertions}'
}

# -----------------------------------------------------------------------------
# Assertion evaluation
# -----------------------------------------------------------------------------

eval_assertion() {
  local ws="$1" fdir="$2" a="$3" model_output="$4"
  local atype; atype=$(jq -r '.type' <<<"$a")
  case "$atype" in
    file_exists)
      local p; p=$(jq -r '.path' <<<"$a")
      [ -e "$ws/$p" ] && echo true || echo false
      ;;
    file_does_not_exist)
      local p; p=$(jq -r '.path' <<<"$a")
      [ ! -e "$ws/$p" ] && echo true || echo false
      ;;
    file_contains)
      local p pat must
      p=$(jq -r '.path' <<<"$a")
      pat=$(jq -r '.pattern' <<<"$a")
      must=$(jq -r '.must_match' <<<"$a")
      if [ ! -e "$ws/$p" ]; then echo false; return; fi
      if grep -qE "$pat" "$ws/$p"; then
        [ "$must" = "true" ] && echo true || echo false
      else
        [ "$must" = "false" ] && echo true || echo false
      fi
      ;;
    file_equals)
      local p ep
      p=$(jq -r '.path' <<<"$a")
      ep=$(jq -r '.expected_path' <<<"$a")
      if [ -e "$ws/$p" ] && [ -e "$fdir/$ep" ] && cmp -s "$ws/$p" "$fdir/$ep"; then
        echo true
      else
        echo false
      fi
      ;;
    command_exit_code)
      local code actual
      code=$(jq -r '.code' <<<"$a")
      # command is an argv array
      local cmd_args=()
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd_args+=("$line")
      done < <(jq -r '.command[]?' <<<"$a")
      if [ ${#cmd_args[@]} -eq 0 ]; then echo false; return; fi
      ( cd "$ws" && "${cmd_args[@]}" >/dev/null 2>&1 )
      actual=$?
      [ "$actual" = "$code" ] && echo true || echo false
      ;;
    output_contains)
      local pat must
      pat=$(jq -r '.pattern' <<<"$a")
      must=$(jq -r '.must_match' <<<"$a")
      if printf '%s' "$model_output" | grep -qE "$pat"; then
        [ "$must" = "true" ] && echo true || echo false
      else
        [ "$must" = "false" ] && echo true || echo false
      fi
      ;;
    *)
      echo false
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

case "$MODE" in
  check|dry-run)
    if ! reconcile_eval_projects; then
      exit 4
    fi
    ;;
esac

ALL_FIXTURES=()
while IFS= read -r line; do ALL_FIXTURES+=("$line"); done < <(discover_fixtures)
SELECTED=()
if [ ${#ALL_FIXTURES[@]} -gt 0 ]; then
  while IFS= read -r line; do SELECTED+=("$line"); done < <(printf '%s\n' "${ALL_FIXTURES[@]}" | apply_filter)
fi

if [ ${#SELECTED[@]} -eq 0 ]; then
  log "no fixtures matched."
  if [ "$MODE" = "check" ] || [ "$MODE" = "dry-run" ]; then exit 0; fi
  exit 0
fi

# Always validate
log "validating ${#SELECTED[@]} fixture(s)..."
VALID=()
INVALID=0
for mf in "${SELECTED[@]}"; do
  if msg=$(validate_fixture "$mf"); then
    VALID+=("$mf")
  else
    INVALID=$((INVALID + 1))
    rel="${mf#"$EVALS_DIR/"}"
    rel="${rel%/manifest.yml}"
    err "✗ $rel"
    printf '%s\n' "$msg" | sed 's/^/    /' >&2
  fi
done

if [ "$INVALID" -gt 0 ]; then
  err "$INVALID fixture(s) failed schema validation"
  exit 4
fi

log "✓ ${#VALID[@]} fixture(s) valid"

if [ "$MODE" = "check" ]; then
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  log "would run:"
  for mf in "${VALID[@]}"; do
    rel="${mf#"$EVALS_DIR/"}"
    rel="${rel%/manifest.yml}"
    runs=$(yq -r '.runs // 5' "$mf")
    model=$(yq -r '.model // "sonnet"' "$mf")
    log "  $rel  (n=$runs, model=$model)"
  done
  exit 0
fi

# Full run
ts="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -z "$OUTPUT" ]; then
  mkdir -p "$EVALS_DIR/.results"
  OUTPUT="$EVALS_DIR/.results/$ts.json"
fi
mkdir -p "$(dirname "$OUTPUT")"

FIXTURE_RESULTS=()
for mf in "${VALID[@]}"; do
  fr=$(run_fixture "$mf")
  FIXTURE_RESULTS+=("$fr")
done

total=${#FIXTURE_RESULTS[@]}
passed=0
for fr in "${FIXTURE_RESULTS[@]}"; do
  [ "$(jq -r '.passed' <<<"$fr")" = "true" ] && passed=$((passed + 1))
done
overall_rate=$(awk -v p="$passed" -v t="$total" 'BEGIN { printf "%.4f", (t==0)?0:(p/t) }')

if [ "${#FIXTURE_RESULTS[@]}" -eq 0 ]; then
  fixtures_json="[]"
else
  fixtures_json="[$(IFS=,; printf '%s' "${FIXTURE_RESULTS[*]}")]"
fi

jq -n \
  --arg ts "$ts" \
  --argjson fixtures "$fixtures_json" \
  --argjson total "$total" --argjson passed "$passed" \
  --argjson rate "$overall_rate" \
  '{schema_version: 1, started_at: $ts, fixtures: $fixtures,
    summary: {total: $total, passed: $passed, failed: ($total - $passed),
              pass_rate: $rate}}' > "$OUTPUT"

log "results: $OUTPUT"
log "summary: $passed/$total passed (rate=$overall_rate)"

if [ "$passed" -lt "$total" ]; then
  exit 1
fi
exit 0
