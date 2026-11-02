#!/usr/bin/env bash
# Compare names and exact bodies against the pre-split a2a8746e4 original.
# The retained .txt is not a runnable suite. Reuse the quote/heredoc-aware R1
# parser (including bash -n and bats --count), not a brace-counting shortcut.
# Optional root supports isolated mutation probes without editing the checkout.
set -euo pipefail
ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TREE="${1:-$ROOT}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-store-split.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ORIGINAL=scripts/tests/release-store-original.txt
PARTS=()
for part in "$TREE"/scripts/tests/release-store-part*.bats; do
  [ -f "$part" ] || continue
  PARTS+=("scripts/tests/${part##*/}")
done
[ "${#PARTS[@]}" -gt 0 ] || { echo 'no release-store parts found' >&2; exit 1; }
[ ! -e "$TREE/scripts/tests/release-store.bats" ] || {
  echo 'original runnable suite still exists beside parts' >&2; exit 1;
}
bash "$ROOT/scripts/tests/test-equivalence.sh" emit --tree "$TREE" "$ORIGINAL" > "$WORK/original.tsv"
bash "$ROOT/scripts/tests/test-equivalence.sh" emit --tree "$TREE" "${PARTS[@]}" > "$WORK/parts.tsv"
awk -F '\t' '
  FNR == NR && $3 == "test" {
    if ($5 in original) { print "duplicate original: " $5; bad = 1 }
    original[$5] = $6; count++; next
  }
  FILENAME == ARGV[2] && $3 == "test" {
    if ($5 in seen) { print "doubled: " $5; bad = 1 }
    seen[$5] = 1; total++
    if (!($5 in original)) { print "added or renamed: " $5; bad = 1 }
    else if (original[$5] != $6) { print "edited: " $5; bad = 1 }
  }
  END {
    for (name in original) if (!(name in seen)) { print "dropped: " name; bad = 1 }
    if (!count || total != count) { print "count: original=" count ", parts=" total; bad = 1 }
    if (!bad) print "OK: " count " release-store test names and bodies are byte-identical"
    exit bad
  }
' "$WORK/original.tsv" "$WORK/parts.tsv"
