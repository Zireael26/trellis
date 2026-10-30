#!/usr/bin/env bash
# Read-only release check: stage the working tree, never an installed release
# or the public mirror. Use the publisher's own policy and staging functions so
# an allowlist/exclusion/redaction change cannot leave a second replica stale.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ "$#" -gt 1 ]; then
  printf 'Usage: check-mirror-preseal.sh [SOURCE_ROOT]\n' >&2
  exit 2
fi
SOURCE_ROOT="$(CDPATH='' cd -- "${1:-$SCRIPT_DIR/..}" && pwd -P)"
publisher="$SOURCE_ROOT/scripts/sync-to-template.sh"
[ -f "$publisher" ] && [ ! -L "$publisher" ] || {
  printf 'mirror-preseal: publisher is not a regular file\n' >&2
  exit 4
}
scratch="$(mktemp -d "${TMPDIR:-/tmp}/trellis-mirror-preseal.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
trap 'exit 4' HUP INT TERM
stage="$scratch/stage"
mkdir "$stage"

# Only extract definitions and deterministic public-shell replacements. Never
# source the publisher wholesale: its bootstrap has publication authority, and
# its body fetches releases and mutates a mirror. Missing/duplicate/reordered
# boundaries fail closed instead of silently linting an empty projection.
extract_between() {
  awk '
    BEGIN { first = ARGV[1]; last = ARGV[2]; ARGV[1] = ARGV[2] = "" }
    $0 == first { starts++; if (phase != 0) bad = 1; phase = 1 }
    $0 == last { ends++; if (phase != 1) bad = 1; phase = 2 }
    phase == 1 { print }
    END { if (bad || starts != 1 || ends != 1 || phase != 2) exit 1 }
  ' "$1" "$2" "$publisher" >> "$3" || {
    printf 'mirror-preseal: publisher extraction boundary changed: %s\n' "$1" >&2
    exit 4
  }
}
functions="$scratch/functions.sh"
extract_between '# Positive publication allowlist. A payload path must be deliberately listed to' \
  'mirror_require_real_parent() {' "$functions"
extract_between 'stage_verified_payload() {' \
  '# Project the STAGED inheritance manifest into the one a mirror user can' "$functions"
extract_between 'project_staged_inheritance_manifest() {' \
  "printf '==> Checking private core-rules prune pairing\\n'" "$functions"
extract_between "# Publish a deterministic tracked policy shell, not the immutable payload's" \
  "printf '==> Linting staged portable policy\\n'" "$scratch/shells.sh"

# shellcheck source=lib/mirror-lint.sh
. "$SOURCE_ROOT/scripts/lib/mirror-lint.sh"
# shellcheck source=/dev/null
. "$functions"
# The extracted publisher functions read these globals.
# shellcheck disable=SC2034
PAYLOAD_ROOT="$SOURCE_ROOT"
# shellcheck disable=SC2034
RESTORE_PARENT='' # A working tree already contains the tests restored at publish time.
preflight_core_rules_private_prunes || exit 4
preflight_payload_no_publish_prunes || exit 4
stage_verified_payload
project_staged_inheritance_manifest
# shellcheck source=/dev/null
. "$scratch/shells.sh"

# More than 1,000 regular files currently publish. Keep a conservative floor
# and independent sentinel paths: an empty/truncated extraction must never pass.
file_count="$(find -P "$stage" -type f -print | wc -l | tr -d ' ')"
[ "$file_count" -ge 1000 ] || {
  printf 'mirror-preseal: incomplete stage (%s files; minimum 1000)\n' "$file_count" >&2
  exit 4
}
for sentinel in CHANGELOG.md core-rules/inheritance-manifest.json \
  core-rules/hooks/tests/task-state.bats scripts/lib/mirror-lint.sh; do
  [ -f "$stage/$sentinel" ] && [ ! -L "$stage/$sentinel" ] || {
    printf 'mirror-preseal: missing staged sentinel: %s\n' "$sentinel" >&2
    exit 4
  }
done
printf 'mirror-preseal: linting %s staged files\n' "$file_count"
if ! lint_mirror "$stage"; then
  printf 'mirror-preseal: staged public policy refused\n' >&2
  exit 4
fi
printf 'mirror-preseal: staged public policy clean\n'
