#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCHEMA="$ROOT/scripts/lib/trellis.config.schema.json"
POLICY="$ROOT/trellis.config.json"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

AJV_VALIDATE_ARGS=(validate --spec=draft2020 --strict=false)
AJV_COMMAND=()

_require_ajv2020() {
  # Probe AJV with a fixed known-good fixture, never with the tracked
  # policy: if AJV is usable but rejects the tracked policy, the tests
  # must fail, not silently fall back to the narrower jq validator.
  local known_good="$SANDBOX/known-good.json"
  printf '%s\n' '{"schema_version":2,"maintainer_name":"fixture","github_user":"fixture","harnesses":["claude"]}' > "$known_good"
  if command -v ajv >/dev/null 2>&1; then
    if ajv "${AJV_VALIDATE_ARGS[@]}" -s "$SCHEMA" -d "$known_good" >/dev/null 2>&1; then
      AJV_COMMAND=(ajv)
    else
      echo 'ajv is installed but rejects the fixed known-good probe fixture; update the fixture or schema, do not silently drop AJV'
      false
    fi
  elif command -v npx >/dev/null 2>&1 \
    && npx --no-install --offline --no-update-notifier ajv "${AJV_VALIDATE_ARGS[@]}" -s "$SCHEMA" -d "$known_good" >/dev/null 2>&1; then
    AJV_COMMAND=(npx --no-install --offline --no-update-notifier ajv)
  else
    AJV_COMMAND=()
  fi
  if [ "${TRELLIS_REQUIRE_AJV:-}" = 1 ] && [ "${#AJV_COMMAND[@]}" -eq 0 ]; then
    echo 'TRELLIS_REQUIRE_AJV=1 but no usable AJV was found'
    false
  fi

  # Always extract the jq fallback validator (sourcing config-load.sh
  # would run its machine-load main body), so it runs in every test
  # alongside AJV when AJV is present, and alone when it is not.
  local fallback_fn
  fallback_fn="$(awk '/^_pgcfg_validate_policy_fallback\(\) \{/,/^}/' "$ROOT/scripts/lib/config-load.sh")"
  [ -n "$fallback_fn" ] || { echo 'fallback validator not found in config-load.sh'; false; }
  eval "$fallback_fn"
  return 0
}

_validate_policy() {
  local rc=0
  if [ "${#AJV_COMMAND[@]}" -gt 0 ]; then
    "${AJV_COMMAND[@]}" "${AJV_VALIDATE_ARGS[@]}" -s "$SCHEMA" -d "$1" || rc=$?
  fi
  _pgcfg_validate_policy_fallback "$1" "$SCHEMA" || rc=$?
  return "$rc"
}

# Reject helper: succeeds only when AJV (when present) and the fallback
# each reject on their own, so a regression in either validator fails.
_validate_policy_rejects() {
  if [ "${#AJV_COMMAND[@]}" -gt 0 ]; then
    if "${AJV_COMMAND[@]}" "${AJV_VALIDATE_ARGS[@]}" -s "$SCHEMA" -d "$1" >/dev/null 2>&1; then
      echo "AJV unexpectedly validated $1"
      return 1
    fi
  fi
  if _pgcfg_validate_policy_fallback "$1" "$SCHEMA" >/dev/null 2>&1; then
    echo "jq fallback unexpectedly validated $1"
    return 1
  fi
  return 0
}

@test "current tracked policy validates as portable schema v2" {
  local policy="$SANDBOX/current-policy.json"
  _require_ajv2020
  cp "$POLICY" "$policy"
  run _validate_policy "$policy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "schema rejects every legacy and local-machine field" {
  local key policy
  _require_ajv2020
  for key in \
    trellis_root \
    projects_root \
    user_home \
    shared_infra_root \
    symlink_style \
    fleet \
    installed_release \
    source_root \
    release_remote \
    active_cli_release \
    default_fleet \
    fleets; do
    run jq -e --arg key "$key" '.properties[$key] == false' "$SCHEMA"
    [ "$status" -eq 0 ] || { echo "$key is not explicitly forbidden"; false; }

    policy="$SANDBOX/$key.json"
    jq --arg key "$key" '. + {($key): "legacy-machine-value"}' "$POLICY" > "$policy"
    run _validate_policy_rejects "$policy"
    [ "$status" -eq 0 ] || { echo "$key unexpectedly validated"; false; }
  done
}

@test "schema rejects missing and incorrect v2 versions" {
  local missing="$SANDBOX/missing-version.json"
  local wrong_integer="$SANDBOX/wrong-integer-version.json"
  local wrong_type="$SANDBOX/wrong-type-version.json"
  _require_ajv2020
  local policy

  jq 'del(.schema_version)' "$POLICY" > "$missing"
  jq '.schema_version = 1' "$POLICY" > "$wrong_integer"
  jq '.schema_version = "2"' "$POLICY" > "$wrong_type"

  for policy in "$missing" "$wrong_integer" "$wrong_type"; do
    run _validate_policy_rejects "$policy"
    [ "$status" -eq 0 ] || { echo "$policy unexpectedly validated"; false; }
  done
}

@test "portable policy blocks, documented comments, and repository-relative AEO baselines validate" {
  local policy="$SANDBOX/portable-blocks.json"
  _require_ajv2020
  jq '
    .comment_portable_policy = "Portable extension comment"
    | .trellis_version = "1.2.3"
    | .presets = ["web-app"]
    | .autonomy_default = 3
    | .autonomy = 4
    | .package_manager = "pnpm"
    | .sed_flavor = "bsd"
    | .approved_mcps = [
        {
          "name": "computer-use",
          "purpose": "Portable test fixture",
          "scope": "fleet"
        }
      ]
    | .template.redact_paths = ["generated/"]
    | .disk_janitor = {
        "enabled": true,
        "cache_ttl_days": 14,
        "worktree_stale_days": 30,
        "free_space_floor_gb": 30,
        "cache_ceiling_gb": 20,
        "reap_pushed_worktrees": true,
        "ephemeral_tmp_ttl_days": 2,
        "worktree_count_ceiling": 25,
        "worktree_total_gb_ceiling": 80,
        "skip_projects": []
      }
    | .loop_safety = {
        "max_iterations": 100,
        "no_progress_iterations": 3,
        "budget_ceiling_usd": 1000,
        "usd_per_mtok": 25,
        "codex_usd_per_mtok": 10
      }
    | .mandatory_pipeline = {
        "enabled": true,
        "spec_required_diff_lines": 80,
        "surgical_max_diff_lines": 400
      }
    | .aeo_gate = {
        "enabled": true,
        "project": "portable-policy",
        "url": "https://example.test",
        "marker_file": "src/page.ts",
        "marker": "stable marker",
        "baseline": "audits/aeo-baseline.json"
      }
  ' "$POLICY" > "$policy"

  run _validate_policy "$policy"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "schema rejects machine-absolute AEO baseline paths" {
  local baseline policy

  _require_ajv2020

  for baseline in \
    "/private/trellis/audits/baseline.json" \
    "C:/Trellis/audits/baseline.json" \
    'C:\Trellis\audits\baseline.json' \
    '\\server\share\audits\baseline.json'; do
    policy="$SANDBOX/absolute-baseline.json"
    jq --arg baseline "$baseline" '
      .aeo_gate = {
        "enabled": true,
        "project": "portable-policy",
        "url": "https://example.test",
        "marker_file": "src/page.ts",
        "marker": "stable marker",
        "baseline": $baseline
      }
    ' "$POLICY" > "$policy"

    run _validate_policy_rejects "$policy"
    [ "$status" -eq 0 ] || { echo "$baseline unexpectedly validated"; false; }
  done
}

@test "schema rejects option-like and control-bearing template values" {
  local policy control_remote

  _require_ajv2020

  policy="$SANDBOX/option-remote.json"
  jq '.template.remote = "--upload-pack=/tmp/attacker"' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "option-like remote unexpectedly validated"; false; }

  policy="$SANDBOX/option-branch.json"
  jq '.template.branch = "--mirror"' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "option-like branch unexpectedly validated"; false; }

  control_remote=$'git@github.com:example/trellis.git\n--upload-pack=/tmp/attacker'
  policy="$SANDBOX/control-remote.json"
  jq --arg remote "$control_remote" '.template.remote = $remote' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "control-bearing remote unexpectedly validated"; false; }
}

@test "schema rejects nonportable and ambiguous template remotes" {
  local remote policy

  _require_ajv2020

  for remote in \
    "/private/trellis.git" \
    "./trellis.git" \
    "file:///private/trellis.git" \
    "git@github.com:owner:trellis.git"; do
    policy="$SANDBOX/nonportable-remote.json"
    jq --arg remote "$remote" '.template.remote = $remote' "$POLICY" > "$policy"
    run _validate_policy_rejects "$policy"
    [ "$status" -eq 0 ] || { echo "$remote unexpectedly validated"; false; }
  done
}

@test "schema rejects branch refspecs and invalid branch names" {
  local branch policy

  _require_ajv2020

  for branch in \
    ":refs/heads/main" \
    "HEAD:refs/heads/main" \
    "+main" \
    "-main" \
    ".main" \
    "feature/../main" \
    "feature..main" \
    "feature@{1}" \
    "feature//main" \
    "feature.lock" \
    "feature/" \
    "feature." \
    "feature main" \
    'feature\main' \
    "feature~main"; do
    policy="$SANDBOX/invalid-branch.json"
    jq --arg branch "$branch" '.template.branch = $branch' "$POLICY" > "$policy"
    run _validate_policy_rejects "$policy"
    [ "$status" -eq 0 ] || { echo "$branch unexpectedly validated"; false; }
  done
}

@test "schema rejects traversal and absolute portable-policy paths" {
  local policy

  _require_ajv2020

  policy="$SANDBOX/traversal-redact-path.json"
  jq '.template.redact_paths = ["../audits"]' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "traversal redact path unexpectedly validated"; false; }

  policy="$SANDBOX/absolute-redact-path.json"
  jq '.template.redact_paths = ["/audits"]' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "absolute redact path unexpectedly validated"; false; }

  policy="$SANDBOX/traversal-marker-path.json"
  jq '.aeo_gate.marker_file = "src/../page.ts"' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "traversal marker path unexpectedly validated"; false; }

  policy="$SANDBOX/absolute-marker-path.json"
  jq '.aeo_gate.marker_file = "/private/page.ts"' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "absolute marker path unexpectedly validated"; false; }

  policy="$SANDBOX/traversal-baseline-path.json"
  jq '.aeo_gate.baseline = "../audits/baseline.json"' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "traversal baseline path unexpectedly validated"; false; }

  policy="$SANDBOX/windows-baseline-path.json"
  jq --arg baseline 'C:\Trellis\audits\baseline.json' \
    '.aeo_gate.baseline = $baseline' "$POLICY" > "$policy"
  run _validate_policy_rejects "$policy"
  [ "$status" -eq 0 ] || { echo "Windows baseline path unexpectedly validated"; false; }
}

@test "jq fallback alone rejects branch refspecs and traversal paths" {
  # Always run the fallback directly, even when AJV is present, so a
  # fallback regression cannot hide behind AJV rejecting the same input.
  _require_ajv2020
  local branch policy
  for branch in "feature..main" "feature/../main" "feature//main" "feature@{1}"; do
    policy="$SANDBOX/fallback-branch.json"
    jq --arg branch "$branch" '.template.branch = $branch' "$POLICY" > "$policy"
    run _pgcfg_validate_policy_fallback "$policy" "$SCHEMA"
    [ "$status" -ne 0 ] || { echo "fallback unexpectedly validated branch $branch"; false; }
  done
  policy="$SANDBOX/fallback-traversal.json"
  jq '.template.redact_paths = ["../audits"]' "$POLICY" > "$policy"
  run _pgcfg_validate_policy_fallback "$policy" "$SCHEMA"
  [ "$status" -ne 0 ] || { echo "fallback unexpectedly validated traversal redact path"; false; }
  policy="$SANDBOX/fallback-baseline.json"
  jq '.aeo_gate.baseline = "../audits/baseline.json"' "$POLICY" > "$policy"
  run _pgcfg_validate_policy_fallback "$policy" "$SCHEMA"
  [ "$status" -ne 0 ] || { echo "fallback unexpectedly validated traversal baseline"; false; }
}
