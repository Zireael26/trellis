#!/usr/bin/env bash
# Compare this clone's pinned core-rules version against the latest upstream
# tag and (optionally) opt into the upgrade by writing the new version into
# trellis.config.json.
#
# Two run contexts:
#   1. Consumer clone of the public template. origin points at the template
#      remote; tags live on origin. The script fetches origin and compares.
#   2. Private canonical (this repo). origin may not carry release tags;
#      template.remote in trellis.config.json points at the public mirror,
#      so the script falls back to that remote.
#
# Read-only by default — prints diff preview, exits without writing. Pass
# --opt-in to update trellis.config.json's trellis_version field to the
# latest tag. Schema validation runs after the write.
#
# Usage:
#   scripts/upgrade.sh                  # show diff preview, no write
#   scripts/upgrade.sh --opt-in         # write new pin after preview + prompt
#   scripts/upgrade.sh --yes --opt-in   # non-interactive (CI)
#   scripts/upgrade.sh --check          # exit 0 if pinned == latest, 1 if drift
#   scripts/upgrade.sh -h

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse --help BEFORE sourcing config-load so help works even when the local
# config is broken (e.g. fresh clone before paths are filled in).
for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  esac
done

# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

OPT_IN=false
ASSUME_YES=false
CHECK_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --opt-in)  OPT_IN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    --check)   CHECK_ONLY=true ;;
    --help|-h) ;; # already handled above
    *)         echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- Resolve upstream candidates we'll try fetching tags from ------------
# Two run contexts to support:
#   1. Consumer clone — origin IS the public template. Tags live there.
#   2. Canonical private clone — origin is the private mirror (no release
#      tags); template.remote in config points at the public mirror.
# Build a candidate list and try each until one yields a v*.*.* tag.
ORIGIN_URL="$(git -C "$TRELLIS_ROOT" remote get-url origin 2>/dev/null || true)"

UPSTREAM_CANDIDATES=()
if [ -n "$ORIGIN_URL" ]; then
  UPSTREAM_CANDIDATES+=("origin|$ORIGIN_URL")
fi
if [ -n "$TEMPLATE_REMOTE" ] && [ "$TEMPLATE_REMOTE" != "$ORIGIN_URL" ]; then
  # Synthesized transient name; we never add it as a permanent remote.
  UPSTREAM_CANDIDATES+=("trellis-upstream-tmp|$TEMPLATE_REMOTE")
fi
if [ "${#UPSTREAM_CANDIDATES[@]}" -eq 0 ]; then
  echo "upgrade: no origin and no template.remote configured — cannot fetch upstream" >&2
  exit 1
fi

# --- Local pinned version ------------------------------------------------
# Pinned version lives in config (trellis_version). If absent, fall back to
# the on-disk core-rules/VERSION as the implicit pin.
PINNED="${TRELLIS_VERSION:-}"
LOCAL_VERSION_FILE="$TRELLIS_ROOT/core-rules/VERSION"
if [ -z "$PINNED" ] && [ -f "$LOCAL_VERSION_FILE" ]; then
  PINNED="$(tr -d '[:space:]' < "$LOCAL_VERSION_FILE")"
  PINNED_SOURCE="core-rules/VERSION (no explicit pin)"
else
  PINNED_SOURCE="trellis.config.json.trellis_version"
fi

if [ -z "$PINNED" ]; then
  echo "upgrade: no pinned version and no core-rules/VERSION — cannot compare" >&2
  exit 1
fi

# --- Fetch upstream tags, iterating candidates until one yields a tag ----
fetch_from() {
  local name="$1" url="$2"
  if [ "$name" = "origin" ]; then
    git -C "$TRELLIS_ROOT" fetch --tags --quiet origin
  else
    git -C "$TRELLIS_ROOT" fetch --tags --quiet "$url" "${TEMPLATE_BRANCH:-main}"
  fi
}

pick_latest_local_tag() {
  git -C "$TRELLIS_ROOT" tag --list 'v[0-9]*.[0-9]*.[0-9]*' \
    | grep -Ev '\-' \
    | sort -V \
    | tail -n 1
}

UPSTREAM_REMOTE=""
UPSTREAM_URL=""
LATEST_TAG=""
for entry in "${UPSTREAM_CANDIDATES[@]}"; do
  cand_name="${entry%%|*}"
  cand_url="${entry#*|}"
  echo "fetching tags from $cand_name → $cand_url..."
  if ! fetch_from "$cand_name" "$cand_url" 2>/dev/null; then
    echo "  fetch failed for $cand_name — trying next candidate" >&2
    continue
  fi
  candidate_tag="$(pick_latest_local_tag || true)"
  if [ -n "$candidate_tag" ]; then
    UPSTREAM_REMOTE="$cand_name"
    UPSTREAM_URL="$cand_url"
    LATEST_TAG="$candidate_tag"
    break
  fi
  echo "  no v*.*.* tags on $cand_name — trying next candidate" >&2
done

if [ -z "$LATEST_TAG" ]; then
  echo "upgrade: no v*.*.* tags found on any candidate upstream. Nothing to compare against." >&2
  exit 1
fi

echo "upstream: $UPSTREAM_REMOTE → $UPSTREAM_URL"
LATEST="${LATEST_TAG#v}"

echo "pinned:  $PINNED  ($PINNED_SOURCE)"
echo "latest:  $LATEST  ($LATEST_TAG)"

if [ "$PINNED" = "$LATEST" ]; then
  echo "up-to-date."
  exit 0
fi

# Direction check: is PINNED strictly ahead of LATEST? If so, this is the
# "ahead-of-canonical" state that the version-drift audit flags as a
# warning ("parent likely needs a tag bump"). Never downgrade an ahead
# pin via --opt-in — that's silent regression. Exit cleanly with a
# warning instead.
SORTED_HIGH="$(printf '%s\n%s\n' "$PINNED" "$LATEST" | sort -V | tail -n 1)"
if [ "$SORTED_HIGH" = "$PINNED" ]; then
  echo
  echo "ahead-of-canonical: local pin ($PINNED) is newer than latest upstream tag ($LATEST)."
  echo "Likely cause: the canonical repo wasn't tagged after a forward bump."
  echo "Not downgrading. Tag the canonical repo at $PINNED (or higher) and rerun."
  if $CHECK_ONLY; then
    exit 1
  fi
  exit 0
fi

if $CHECK_ONLY; then
  echo "drift detected."
  exit 1
fi

# --- Diff preview of core-rules/ between pinned and latest --------------
# Use a synthetic ref for the pinned version if no matching tag exists locally
# (e.g., pinned was never released as a tag because it lives on the canonical
# clone). Fall back to a no-op diff and warn.
PINNED_REF="v$PINNED"
if ! git -C "$TRELLIS_ROOT" rev-parse --verify --quiet "$PINNED_REF" >/dev/null; then
  echo
  echo "note: no local tag $PINNED_REF — diff preview would be empty. Showing latest tag's core-rules/ tree summary instead." >&2
  echo
  echo "core-rules/ at $LATEST_TAG:"
  git -C "$TRELLIS_ROOT" ls-tree --name-only -r "$LATEST_TAG" -- core-rules/ | head -40
  echo "(showing first 40 paths; use 'git show $LATEST_TAG --stat -- core-rules/' for full)"
else
  echo
  echo "diff core-rules/ ($PINNED_REF → $LATEST_TAG):"
  git -C "$TRELLIS_ROOT" diff --stat "$PINNED_REF".."$LATEST_TAG" -- core-rules/ || true
fi

if ! $OPT_IN; then
  echo
  echo "read-only: rerun with --opt-in to update the pin in trellis.config.json."
  exit 0
fi

# --- Opt-in: rewrite trellis_version in trellis.config.json -------------
if ! $ASSUME_YES; then
  printf "Update trellis.config.json's trellis_version from %s → %s? [y/N] " "$PINNED" "$LATEST"
  read -r ans
  case "$ans" in
    y|Y) ;;
    *)   echo "aborted."; exit 0 ;;
  esac
fi

TMP="$(mktemp)"
jq --arg v "$LATEST" '.trellis_version = $v' "$TRELLIS_CONFIG_PATH" > "$TMP"
mv "$TMP" "$TRELLIS_CONFIG_PATH"
echo "updated: $TRELLIS_CONFIG_PATH (trellis_version=$LATEST)"

# Re-run schema validation as a tripwire.
if ! _pgcfg_validate "$TRELLIS_CONFIG_PATH" >/dev/null 2>&1; then
  echo "WARN: post-write schema validation reported issues — inspect $TRELLIS_CONFIG_PATH" >&2
  exit 1
fi

# --- Post-adopt verification: run the read-only doctor -------------------
# Reaching here means the --opt-in version pin was adopted successfully (the
# control flow guards this: every non-opt-in / read-only / ahead / drift path
# exits above, and the schema tripwire exits 1 on failure). Run doctor in
# READ-ONLY mode as the verification gate. This is informational only — it
# must NOT change the upgrade's success semantics, so a drift (doctor exit 1)
# is reported but does not fail the adoption. Never invoke --fix from here.
DOCTOR="$SCRIPT_DIR/doctor.sh"
if [ "${TRELLIS_SKIP_DOCTOR:-0}" = 1 ]; then
  echo "doctor: skipped (TRELLIS_SKIP_DOCTOR=1)."
elif [ -x "$DOCTOR" ]; then
  echo
  echo "running doctor (read-only) to verify the adopted pin..."
  # `if !` keeps this non-fatal under `set -e` AND lets us branch on drift.
  if ! "$DOCTOR"; then
    echo
    echo "doctor reported drift (the version-pin adoption itself succeeded)."
    echo "  preview the repair: $DOCTOR --fix --dry-run"
    echo "  apply the repair:   $DOCTOR --fix"
  fi
else
  echo "doctor: $DOCTOR not found or not executable — skipping verification." >&2
fi

echo "next: review the diff, run hooks/tests, commit the pin change."
