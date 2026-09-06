#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <pi-subagents-package-root>\n' "${0##*/}" >&2
  exit 64
fi

package_root=$1
package_json="$package_root/package.json"
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
patch_files=(
  "$script_dir/pi-subagents-0.19.0-preserve-cleanup-worktree.patch"
  "$script_dir/pi-subagents-0.19.0-preserve-cleanup-dist.patch"
  "$script_dir/pi-subagents-0.19.0-follow-symlinked-skill-leaves.patch"
  "$script_dir/pi-subagents-0.19.0-worktree-create-timeout.patch"
)

if [[ ! -f "$package_json" || ! -f "$package_root/src/worktree.ts" ]]; then
  printf 'error: %s is not an @tintinweb/pi-subagents package root\n' "$package_root" >&2
  exit 66
fi

version=$(node -e 'const { resolve } = require("node:path"); const p = require(resolve(process.argv[1])); process.stdout.write(p.version ?? "")' "$package_json")
if [[ "$version" != 0.19.0 ]]; then
  printf 'error: patch is pinned to @tintinweb/pi-subagents 0.19.0, found %s\n' "$version" >&2
  exit 65
fi

# Preflight the entire bundle before mutation. This is not a rollback guarantee
# if another process changes the package after these checks.
pending_patches=()
for patch_file in "${patch_files[@]}"; do
  if patch -d "$package_root" -p1 -f -R -s --dry-run -i "$patch_file" >/dev/null 2>&1; then
    printf 'already applied: %s\n' "$patch_file"
    continue
  fi
  if ! patch -d "$package_root" -p1 -f -s --dry-run -i "$patch_file"; then
    printf 'error: package source drifted; refusing to apply %s\n' "$patch_file" >&2
    exit 1
  fi
  pending_patches+=("$patch_file")
done

# Bash 3.2 treats an empty array as unset under nounset.
for patch_file in ${pending_patches[@]+"${pending_patches[@]}"}; do
  if ! patch -d "$package_root" -p1 -f -s -i "$patch_file"; then
    printf 'error: apply failed for %s; package may be partially patched and was not rolled back\n' "$patch_file" >&2
    exit 1
  fi
  printf 'applied: %s\n' "$patch_file"
done

for patch_file in "${patch_files[@]}"; do
  if ! patch -d "$package_root" -p1 -f -R -s --dry-run -i "$patch_file"; then
    printf 'error: final bundle verification failed for %s; package may be partially patched and was not rolled back\n' "$patch_file" >&2
    exit 1
  fi
done
