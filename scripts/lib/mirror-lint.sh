#!/usr/bin/env bash
# mirror-lint.sh — pure, sourceable denylist lint for the public Trellis mirror.
#
# Purpose: the sync (sync-to-template.sh) is a positive allowlist — it only
# inspects files it copies. Public-only files that live in the mirror but are
# NOT in SYNC_PATHS (README.md, SETUP.md, AGENT_SETUP.md, docs/architecture.svg,
# LICENSE, .github/) are never scrubbed and drift silently. That is exactly how
# stale AntiGravity content survived the RC.4 release in README/SETUP/AGENT_SETUP.
# This helper greps the ENTIRE mirror tree (not just synced paths) for forbidden
# content and fails closed, so the sync can abort before commit/push.
#
# Two token classes, because a naive denylist cries wolf (verified 2026-07-05):
#   HARD  — absolute filesystem-path leaks (trellis_root / source_root /
#           projects_root / user_home). These are NEVER legitimate anywhere in
#           the public mirror. Fail on any occurrence.
#   SCOPED — "antigravity" (case-insensitive). LEGITIMATE in the historical
#           record (docs/adr/ ADRs are immutable history, docs/specs/ historical
#           design docs, CHANGELOG.md "Removed: AntiGravity"). FORBIDDEN in
#           current operator-facing surface (README, SETUP, steering, live
#           skills/hooks). Fail only OUTSIDE the historical-record allowlist.
#
# NOT denylisted: maintainer_name ("__MAINTAINER_NAME__") and github_user
# ("__GITHUB_USER__") appear LEGITIMATELY in the public mirror — attribution in
# README.md, clone URLs in SETUP.md. Banning them would false-positive on
# correct public content. The staged-tree leak check in sync-to-template.sh
# (its SUB_FROM grep) already guards the SYNCED files against those; that check
# is unchanged. This lint is the complementary guard for the UNSYNCED files.
#
# Read/write contract:
#   READS  — only the filesystem under <mirror_dir> (file contents via grep).
#   WRITES — nothing. Prints "path: reason" per offender to stdout only. Sets no
#            globals, mutates no shell state, touches no files.
#   No `set -euo pipefail`: sourcing must not alter the caller's shell. The
#   function is self-contained and `set -e`-safe (every grep runs in an `if`).

# lint_mirror <mirror_dir> <trellis_root> <source_root> <projects_root> <user_home>
#   Prints each offender as "<relative-path>: <reason>" to stdout, one per line.
#   Returns 0 if the mirror is clean, 1 if any offender was found.
#
# The `.git/` directory is always excluded. grep -I skips binary files, so
# docs/architecture.svg (text) is scanned but true binaries are not.
lint_mirror() {
  local mirror_dir="$1" trellis_root="$2" source_root="$3" projects_root="$4" user_home="$5"
  local rc=0

  [ -d "$mirror_dir" ] || { echo "mirror-lint: not a directory: $mirror_dir" >&2; return 2; }

  # --- HARD tokens: absolute-path leaks, forbidden anywhere ---------------
  # Dedup: source_root and trellis_root are often the same clone path; report
  # each distinct token once.
  local -a hard_tokens=()
  local seen="" t
  for t in "$trellis_root" "$source_root" "$projects_root" "$user_home"; do
    [ -n "$t" ] || continue
    case "$seen" in *"|$t|"*) continue ;; esac
    seen="${seen}|$t|"
    hard_tokens+=("$t")
  done
  local tok f rel
  for tok in "${hard_tokens[@]}"; do
    [ -n "$tok" ] || continue
    # -F fixed-string (paths contain no regex intent), -I skip binary,
    # -l list files, -r recurse. Exclude the git dir.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f#"$mirror_dir"/}"
      echo "$rel: absolute-path leak ('$tok')"
      rc=1
    done < <(grep -rIlF --exclude-dir='.git' -- "$tok" "$mirror_dir" 2>/dev/null)
  done

  # Symlink TARGETS can leak a hard token even when no file content does — an
  # inheritance symlink accidentally shipped in the mirror could point at an
  # instance path. grep reads link targets as the (short) link file, not the
  # destination, so scan targets explicitly (cross-model review finding).
  local link target
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    target="$(readlink "$link" 2>/dev/null || true)"
    [ -n "$target" ] || continue
    for tok in "${hard_tokens[@]}"; do
      case "$target" in
        *"$tok"*) rel="${link#"$mirror_dir"/}"; echo "$rel: symlink target leaks absolute path ('$tok' -> $target)"; rc=1 ;;
      esac
    done
  done < <(find "$mirror_dir" -type l -not -path '*/.git/*' 2>/dev/null)

  # --- SCOPED token: antigravity, forbidden outside the historical record --
  # Allowlist (paths RELATIVE to mirror_dir where the token is legitimate):
  #   docs/adr/, docs/specs/  — immutable historical design record
  #   CHANGELOG.md            — "Removed: AntiGravity" is history, must persist
  #   the three removal-tooling files that necessarily NAME the token (this
  #   linter, sync-to-template's DELIST_PRUNE, and this linter's own test) —
  #   they sync to the mirror, so exempt them or the lint flags its own
  #   machinery. NOT a blanket scripts/ exemption: a stale antigravity in a
  #   synced OPERATOR script (onboard-project.sh, a rollout script) must still
  #   fail (cross-model review finding, 2026-07-05). The path-leak check above
  #   scans every file regardless.
  # Everything else IS scanned: README, SETUP, AGENT_SETUP, engineering-process,
  # docs steering, live core-rules skill/hook docs, and every other script — the
  # operator-facing surface where the RC.4 regression actually landed.
  local allow_re='^(docs/adr/|docs/specs/|CHANGELOG\.md$|scripts/lib/mirror-lint\.sh$|scripts/sync-to-template\.sh$|scripts/tests/mirror-lint\.bats$)'
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    if ! printf '%s\n' "$rel" | grep -qE "$allow_re"; then
      echo "$rel: stale 'antigravity' in current operator surface (historical record only: docs/adr/, docs/specs/, CHANGELOG.md)"
      rc=1
    fi
  done < <(grep -rIliF --exclude-dir='.git' -- 'antigravity' "$mirror_dir" 2>/dev/null)

  return $rc
}
