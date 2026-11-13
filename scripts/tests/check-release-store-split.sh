#!/usr/bin/env bash
# Compare names and exact bodies against the tracked reviewed baseline, derived
# from pre-split a2a8746e4 and updated only for reviewed post-split test edits;
# Git retains the history of the original inventory.
# Cases a lane added inside its own scaffolded `# BEGIN LANE <id>` ...
# `# END LANE <id>` block are new, not part of the split: they may carry a name
# the original lacks, and are counted separately.
# Markers must be unindented and outside quotes or heredocs.
# Every original case must still appear exactly once, byte for byte, and no
# lane case may reuse its name.
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
for part in "${PARTS[@]}"; do
  awk -v part="$part" '
    /^# BEGIN LANE [A-Za-z0-9]+$/ { if (lane != "") bad = 1; lane = $4; next }
    /^# END LANE [A-Za-z0-9]+$/ { if ($4 != lane) bad = 1; lane = ""; next }
    lane != "" && /^@test "/ {
      name = $0; sub(/^@test "/, "", name); sub(/" \{$/, "", name); print part "\t" name
    }
    END { if (lane != "" || bad) { print "unbalanced lane markers" > "/dev/stderr"; exit 1 } }
  ' "$TREE/$part"
done > "$WORK/lane.txt"
awk -F '\t' '
  FILENAME == ARGV[1] { lane[$0] = 1; next }
  FILENAME == ARGV[2] && $3 == "test" {
    if ($5 in original) { print "duplicate original: " $5; bad = 1 }
    original[$5] = $6; count++; next
  }
  FILENAME == ARGV[3] && $3 == "test" {
    if ($5 in seen) { print "doubled: " $5; bad = 1 }
    seen[$5] = 1
    if (!($5 in original)) {
      if (($1 "\t" $5) in lane) { added++; next }
      print "added or renamed: " $5; bad = 1
    }
    else if (($1 "\t" $5) in lane) { print "lane case reuses an original name: " $5; bad = 1 }
    else if (original[$5] != $6) { print "edited: " $5; bad = 1 }
    total++
  }
  END {
    for (name in original) if (!(name in seen)) { print "dropped: " name; bad = 1 }
    if (!count || total != count) { print "count: original=" count ", parts=" total; bad = 1 }
    if (!bad) print "OK: " count " release-store test names and bodies are byte-identical (" added + 0 " lane additions)"
    exit bad
  }
' "$WORK/lane.txt" "$WORK/original.tsv" "$WORK/parts.tsv"
