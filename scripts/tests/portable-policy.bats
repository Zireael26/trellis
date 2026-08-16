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
  if command -v ajv >/dev/null 2>&1 \
    && ajv "${AJV_VALIDATE_ARGS[@]}" -s "$SCHEMA" -d "$POLICY" >/dev/null 2>&1; then
    AJV_COMMAND=(ajv)
    return 0
  fi

  if command -v npx >/dev/null 2>&1 \
    && npx --no-install ajv "${AJV_VALIDATE_ARGS[@]}" -s "$SCHEMA" -d "$POLICY" >/dev/null 2>&1; then
    AJV_COMMAND=(npx --no-install ajv)
    return 0
  fi

  skip "requires AJV CLI with JSON Schema draft 2020-12 support"
}

_validate_policy() {
  "${AJV_COMMAND[@]}" "${AJV_VALIDATE_ARGS[@]}" -s "$SCHEMA" -d "$1"
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
    run _validate_policy "$policy"
    [ "$status" -ne 0 ] || { echo "$key unexpectedly validated"; false; }
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
    run _validate_policy "$policy"
    [ "$status" -ne 0 ] || { echo "$policy unexpectedly validated"; false; }
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

    run _validate_policy "$policy"
    [ "$status" -ne 0 ] || { echo "$baseline unexpectedly validated"; false; }
  done
}

@test "schema rejects option-like and control-bearing template values" {
  local policy control_remote

  _require_ajv2020

  policy="$SANDBOX/option-remote.json"
  jq '.template.remote = "--upload-pack=/tmp/attacker"' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "option-like remote unexpectedly validated"; false; }

  policy="$SANDBOX/option-branch.json"
  jq '.template.branch = "--mirror"' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "option-like branch unexpectedly validated"; false; }

  control_remote=$'git@github.com:example/trellis.git\n--upload-pack=/tmp/attacker'
  policy="$SANDBOX/control-remote.json"
  jq --arg remote "$control_remote" '.template.remote = $remote' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "control-bearing remote unexpectedly validated"; false; }
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
    run _validate_policy "$policy"
    [ "$status" -ne 0 ] || { echo "$remote unexpectedly validated"; false; }
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
    run _validate_policy "$policy"
    [ "$status" -ne 0 ] || { echo "$branch unexpectedly validated"; false; }
  done
}

@test "schema rejects traversal and absolute portable-policy paths" {
  local policy

  _require_ajv2020

  policy="$SANDBOX/traversal-redact-path.json"
  jq '.template.redact_paths = ["../audits"]' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "traversal redact path unexpectedly validated"; false; }

  policy="$SANDBOX/absolute-redact-path.json"
  jq '.template.redact_paths = ["/audits"]' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "absolute redact path unexpectedly validated"; false; }

  policy="$SANDBOX/traversal-marker-path.json"
  jq '.aeo_gate.marker_file = "src/../page.ts"' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "traversal marker path unexpectedly validated"; false; }

  policy="$SANDBOX/absolute-marker-path.json"
  jq '.aeo_gate.marker_file = "/private/page.ts"' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "absolute marker path unexpectedly validated"; false; }

  policy="$SANDBOX/traversal-baseline-path.json"
  jq '.aeo_gate.baseline = "../audits/baseline.json"' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "traversal baseline path unexpectedly validated"; false; }

  policy="$SANDBOX/windows-baseline-path.json"
  jq --arg baseline 'C:\Trellis\audits\baseline.json' \
    '.aeo_gate.baseline = $baseline' "$POLICY" > "$policy"
  run _validate_policy "$policy"
  [ "$status" -ne 0 ] || { echo "Windows baseline path unexpectedly validated"; false; }
}
