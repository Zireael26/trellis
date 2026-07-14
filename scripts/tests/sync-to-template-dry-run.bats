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
  mkdir -p "$SOURCE/scripts/lib" "$SOURCE/core-rules" "$MIRROR" "$PROJECTS"

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
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "testuser",
  "harnesses": ["claude"],
  "template": { "branch": "main" }
}
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

  run bash "$MIRROR/scripts/lint-prompt-shell-blocks.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean (0 files, 0 bash/sh blocks scanned)"* ]]
  [[ "$output" != *"No such file or directory"* ]]
}
