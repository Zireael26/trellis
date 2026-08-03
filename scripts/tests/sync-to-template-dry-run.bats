#!/usr/bin/env bats
# Isolated dry-run simulation coverage for sync-to-template.sh. Every test uses
# temporary source and mirror repos; the live Trellis checkout and public mirror
# are never targets.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SANDBOX="$BATS_TEST_TMPDIR/work"
  SOURCE="$SANDBOX/source"
  MIRROR="$SANDBOX/mirror"
  PROJECTS="$SANDBOX/projects"
  # Keep the feature token split so this synced fixture remains outside the
  # exact proxy-token content allowlist it is exercising.
  SECURITY_REL="docs/g""ptx-security.md"
  LEGACY_REL="docs/legacy/codex-plugin.md"
  mkdir -p "$SOURCE/scripts/lib" "$SOURCE/core-rules" "$SOURCE/audits" \
    "$SOURCE/docs" "$SOURCE/local" "$SOURCE/shared-runtime" \
    "$SOURCE/$(dirname "$SECURITY_REL")" "$SOURCE/$(dirname "$LEGACY_REL")" \
    "$MIRROR" "$PROJECTS"
  SHARED_RUNTIME="$(cd "$SOURCE/shared-runtime" && pwd -P)"

  printf 'Public security boundary fixture.\n' > "$SOURCE/$SECURITY_REL"
  printf 'Public legacy compatibility fixture.\n' > "$SOURCE/$LEGACY_REL"

  cp "$REPO_ROOT/scripts/sync-to-template.sh" "$SOURCE/scripts/"
  cp "$REPO_ROOT/scripts/lint-prompt-shell-blocks.sh" "$SOURCE/scripts/"
  cp "$REPO_ROOT/scripts/lib/config-load.sh" "$SOURCE/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/mirror-lint.sh" "$SOURCE/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/sed-portable.sh" "$SOURCE/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/sync-coverage.sh" "$SOURCE/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/trellis.config.schema.json" "$SOURCE/scripts/lib/"

  cat > "$SOURCE/trellis.config.json" <<EOF
{
  "trellis_root": "$SOURCE",
  "projects_root": "$PROJECTS",
  "shared_infra_root": "$SHARED_RUNTIME",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "testuser",
  "harnesses": ["claude"],
  "template": { "branch": "main" }
}
EOF

  cat > "$SOURCE/dependency-baseline.json" <<EOF
{
  "schema_version": 1,
  "policy": {
    "shared_project_minimum": 2,
    "direct_versions": "exact-per-lane",
    "peer_versions": "compatible-range",
    "expired_exceptions": "fail"
  },
  "toolchains": [{"name":"private-project-$SANDBOX","lanes":[]}],
  "packages": [],
  "security_floors": [],
  "exceptions": []
}
EOF
  cat > "$SOURCE/audits/fleet-remediation-ledger.json" <<EOF
{
  "schema_version": 1,
  "audit_date": "2026-07-21",
  "source_reports": ["private-project-$SANDBOX"],
  "findings": []
}
EOF

  cat > "$SOURCE/docs/local-development-infrastructure.md" <<'EOF'
# Private local infrastructure inventory

Private project `sentinel-private-app` binds registered port `45678`.
EOF
  cat > "$SOURCE/CHANGELOG.md" <<'EOF'
# Changelog

- The current fixture manifest includes `sentinel-private-app` with `services: {}` and `ports: {}`. Its project port is `45678`.
EOF
  printf 'Configured shared root: `%s`.\n' "$SHARED_RUNTIME" \
    > "$SOURCE/engineering-process.md"
  cat > "$SOURCE/local/shared-infra-public-denylist.txt" <<'EOF'
# Fake fixture tokens only.
`sentinel-private-app`
`45678`
EOF
  cat > "$SOURCE/local/shared-infra-public-changelog-denylist.txt" <<'EOF'
# Fake fixture tokens only.
`sentinel-private-app`
`45678`
EOF

  git -C "$MIRROR" init -q
  git -C "$MIRROR" config user.email "ci-bats@trellis.test"
  git -C "$MIRROR" config user.name "trellis ci"
}

run_sync_dry() {
  run env TRELLIS_CONFIG="$SOURCE/trellis.config.json" \
    bash "$SOURCE/scripts/sync-to-template.sh" --dry-run --template-dir="$MIRROR"
}

@test "dry-run simulated mirror catches a dirty public-only leak without touching the mirror" {
  printf 'Clean public README.\n' > "$MIRROR/README.md"
  git -C "$MIRROR" add README.md
  git -C "$MIRROR" commit -qm seed
  printf 'Operator path: %s/private\n' "$SANDBOX" > "$MIRROR/README.md"
  local before_status before_sha
  before_status="$(git -C "$MIRROR" status --short)"
  before_sha="$(shasum -a 256 "$MIRROR/README.md" | awk '{print $1}')"

  run_sync_dry

  [ "$status" -eq 1 ]
  [[ "$output" == *"MIRROR LINT FAILED"* ]]
  [[ "$output" == *"README.md: absolute-path leak"* ]]
  [ "$(git -C "$MIRROR" status --short)" = "$before_status" ]
  [ "$(shasum -a 256 "$MIRROR/README.md" | awk '{print $1}')" = "$before_sha" ]
}

@test "dry-run simulated mirror accepts a pending scheduled-tasks prune without touching the mirror" {
  mkdir -p "$MIRROR/scheduled-tasks"
  printf 'Clean public README.\n' > "$MIRROR/README.md"
  printf 'private fleet task\n' > "$MIRROR/scheduled-tasks/prompt.md"
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -qm seed

  run_sync_dry

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"simulated mirror clean"* ]]
  [ -f "$MIRROR/scheduled-tasks/prompt.md" ]
  [ -z "$(git -C "$MIRROR" status --short)" ]
}

@test "apply generates the public guide even when the private source is absent" {
  rm -f "$SOURCE/docs/local-development-infrastructure.md"
  printf 'Clean public README.\n' > "$MIRROR/README.md"
  git -C "$MIRROR" add README.md
  git -C "$MIRROR" commit -qm seed

  run env TRELLIS_CONFIG="$SOURCE/trellis.config.json" \
    bash "$SOURCE/scripts/sync-to-template.sh" --apply --template-dir="$MIRROR"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MIRROR/docs/local-development-infrastructure.md" ]
  grep -F 'The public Trellis template does **not** ship or own that external runtime repository' \
    "$MIRROR/docs/local-development-infrastructure.md"
}

@test "changelog receipt replacement fails closed when its private sentence shape drifts" {
  python3 - "$SOURCE/CHANGELOG.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace(" with `services: {}` and `ports: {}`.", " carries a reviewed declaration."))
PY

  run_sync_dry

  [ "$status" -eq 1 ]
  [[ "$output" == *"shared-infrastructure changelog receipt replacement did not fire; aborting"* ]]
  [[ "$output" != *"sentinel-private-app"* ]]
  [[ "$output" != *"45678"* ]]
}

@test "staged public guide denylist fails closed without disclosing the token" {
  python3 - "$SOURCE/scripts/sync-to-template.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = "# Optional shared local infrastructure"
replacement = needle + "\n\nPrivate allocation: `SENTINEL-PRIVATE-APP`."
path.write_text(text.replace(needle, replacement, 1))
PY

  run env TRELLIS_CONFIG="$SOURCE/trellis.config.json" \
    bash "$SOURCE/scripts/sync-to-template.sh" --dry-run --template-dir="$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"staged shared-infrastructure guide contains a private fleet identifier"* ]]
  [[ "$output" == *"shared-infrastructure publication redaction failed; aborting"* ]]
  [[ "$output" != *"sentinel-private-app"* ]]
  [[ "$output" != *"SENTINEL-PRIVATE-APP"* ]]
}

@test "apply still overlays staged paths, prunes de-listed content, and lints the real mirror" {
  mkdir -p "$MIRROR/scheduled-tasks"
  printf 'Clean public README.\n' > "$MIRROR/README.md"
  printf 'private fleet task\n' > "$MIRROR/scheduled-tasks/prompt.md"
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -qm seed

  run env TRELLIS_CONFIG="$SOURCE/trellis.config.json" \
    bash "$SOURCE/scripts/sync-to-template.sh" --apply --template-dir="$MIRROR"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"applied."* ]]
  [[ "$output" == *"pruned: scheduled-tasks"* ]]
  [[ "$output" == *"mirror clean."* ]]
  [ ! -e "$MIRROR/scheduled-tasks" ]
  [ -f "$MIRROR/scripts/sync-to-template.sh" ]
  [ -f "$MIRROR/dependency-baseline.json" ]
  [ -f "$MIRROR/audits/fleet-remediation-ledger.json" ]
  [ -f "$MIRROR/docs/local-development-infrastructure.md" ]
  [ "$(< "$MIRROR/$SECURITY_REL")" = "Public security boundary fixture." ]
  [ "$(< "$MIRROR/$LEGACY_REL")" = "Public legacy compatibility fixture." ]
  [ "$(jq '.toolchains | length' "$MIRROR/dependency-baseline.json")" -eq 0 ]
  [ "$(jq '.packages | length' "$MIRROR/dependency-baseline.json")" -eq 0 ]
  [ "$(jq '.source_reports | length' "$MIRROR/audits/fleet-remediation-ledger.json")" -eq 0 ]
  [ "$(jq '.findings | length' "$MIRROR/audits/fleet-remediation-ledger.json")" -eq 0 ]
  run grep -n 'private-project-' "$MIRROR/dependency-baseline.json" "$MIRROR/audits/fleet-remediation-ledger.json"
  [ "$status" -eq 1 ]

  run grep -F 'The public Trellis template does **not** ship or own that external runtime repository' \
    "$MIRROR/docs/local-development-infrastructure.md"
  [ "$status" -eq 0 ]
  run grep -F "jq -r '.shared_infra_root // empty'" \
    "$MIRROR/docs/local-development-infrastructure.md"
  [ "$status" -eq 0 ]
  run grep -E 'sentinel-private-app|45678|Private local infrastructure inventory' \
    "$MIRROR/docs/local-development-infrastructure.md"
  [ "$status" -eq 1 ]
  run grep -F 'Shared local-infrastructure integration now validates optional external manifests' \
    "$MIRROR/CHANGELOG.md"
  [ "$status" -eq 0 ]
  run grep -E 'sentinel-private-app|45678|current fixture manifest' \
    "$MIRROR/CHANGELOG.md"
  [ "$status" -eq 1 ]
  run grep -F 'Configured shared root: `__SHARED_INFRA_PATH__`.' \
    "$MIRROR/engineering-process.md"
  [ "$status" -eq 0 ]
  run grep -F "$SHARED_RUNTIME" "$MIRROR/engineering-process.md"
  [ "$status" -eq 1 ]

  run bash "$MIRROR/scripts/lint-prompt-shell-blocks.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean (0 files, 0 bash/sh blocks scanned)"* ]]
  [[ "$output" != *"No such file or directory"* ]]
}
