#!/usr/bin/env bash
# Hard-fail when any canonical Skill manifest exceeds 65,536 UTF-8 bytes.
# Optional arguments replace the default canonical Skill collection roots.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/skill-size.sh
. "$SCRIPT_DIR/lib/skill-size.sh"

collections=()
if [ "$#" -gt 0 ]; then
  collections=("$@")
else
  collections=("$REPO_ROOT/core-rules/skills" "$REPO_ROOT/.claude/skills")
fi

checked=0
failed=0
seen=""
for collection in "${collections[@]}"; do
  if [ ! -d "$collection" ]; then
    echo "check-skill-sizes: not a directory: $collection" >&2
    failed=1
    continue
  fi
  for root in "$collection"/*; do
    [ -d "$root" ] && [ -f "$root/SKILL.md" ] || continue
    canonical="$(skill_size__canonical_dir "$root")" || {
      echo "check-skill-sizes: cannot resolve Skill root: $root" >&2
      failed=1
      continue
    }
    case "
$seen
" in *"
$canonical
"*) continue ;; esac
    seen="${seen}${seen:+
}${canonical}"
    checked=$((checked + 1))
    if ! skill_size_check_root "$canonical"; then
      failed=1
    fi
  done
done

if [ "$failed" -ne 0 ]; then
  echo "check-skill-sizes: FAILED ($checked Skill roots checked)" >&2
  exit 1
fi
printf 'check-skill-sizes: OK (%s Skill roots checked; budget %s bytes)\n' \
  "$checked" "$SKILL_SIZE_BUDGET_BYTES"
