#!/usr/bin/env bash
# Reconcile a linked worktree from its clone's local Trellis registration and
# recorded immutable release.
#
# `git worktree add` does not recreate machine-local Trellis surfaces, so a new
# worktree starts without them. This script re-attaches it through the same
# transaction `trellis attach` uses, from the release its clone already records.
# An unregistered clone remains completely inert.
#
# The legacy mirror mode — copying direct links out of the primary checkout,
# spelled `--legacy-mirror` or `--root <dir>` — shipped for exactly one
# compatibility release and was REMOVED at v1.0.0-rc.25. Both spellings now
# refuse with exit 2. Migrate the clone instead:
#
#   trellis migrate --prepare <clone-path>
#   trellis attach --fleet NAME <clone-path>
#
# Usage: seed-inheritance-symlinks.sh [--target <dir>] [--quiet] [--verify-only]
#                                     [--help]
#
# Options:
#   --target <dir>   The worktree to reconcile. Default: $PWD.
#   --quiet          Suppress successful reconciliation output.
#   --verify-only    Check attachment state only; exit 1 when an opted-in
#                    worktree is missing its attachment.
#   --help           Print usage to stdout and exit 0.

set -euo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [--target <dir>] [--quiet] [--verify-only] [--help]

Reconcile a linked worktree from its clone's local Trellis registration and
recorded immutable release. Unregistered clones remain inert.

Options:
  --target <dir>   Worktree to reconcile. Default: \$PWD.
  --quiet          Suppress successful reconciliation output.
  --verify-only    Check attachment state only; exit 1 when an opted-in
                   worktree is missing its attachment.
  --help           Show this message and exit 0.

Removed in v1.0.0-rc.25: --legacy-mirror and --root (legacy direct-link
mirroring). Run \`trellis migrate --prepare\` then \`trellis attach\` instead.
EOF
}

legacy_mirror_removed() {
  printf 'error: legacy direct-link worktree mirroring was removed in v1.0.0-rc.25 (%s)\n' "$1" >&2
  printf 'error: migrate the clone, then attach it:\n' >&2
  printf 'error:   trellis migrate --prepare <clone-path>\n' >&2
  printf 'error:   trellis attach --fleet NAME <clone-path>\n' >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""
QUIET=0
VERIFY_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { echo "error: --target requires an argument" >&2; usage >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --root|--root=*|--legacy-mirror)
      legacy_mirror_removed "${1%%=*}" ;;
    --quiet)
      QUIET=1; shift ;;
    --verify-only)
      VERIFY_ONLY=1; shift ;;
    --help)
      usage; exit 0 ;;
    -*)
      echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 1: Resolve TARGET
# ---------------------------------------------------------------------------
if [ -z "$TARGET" ]; then
  TARGET="$PWD"
fi

# Resolve to absolute real path (handles macOS /var vs /private/var)
if [ ! -d "$TARGET" ]; then
  echo "error: target is not a directory: $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd -P)"

# Must be inside a git repo
if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: target is not inside a git repo: $TARGET" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The only mode: reconcile from local attachment state. The direct-link
# mirroring path that used to sit below this point was removed at v1.0.0-rc.25;
# both flags that selected it now refuse above.
# ---------------------------------------------------------------------------
attachment_reconcile() {
  local script_dir home registry state identity checkout worktree common registration
  local fleet project_id release payload owner rc harness attachment_id harnesses_json
  local donor_worktree donor_root donor_attachment donor_owner donor_identity donor_ok
  local donor_checkout donor_worktree_actual donor_root_actual donor_common
  local -a attach_args=() expected_args=() donor_args=()

  script_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  # Do not create local state merely to inspect a clone: unregistered clones
  # must remain completely inert.
  # shellcheck source=lib/trellis-home.sh
  . "$script_dir/lib/trellis-home.sh"
  # shellcheck source=lib/local-registry.sh
  . "$script_dir/lib/local-registry.sh"
  # shellcheck source=lib/release-store.sh
  . "$script_dir/lib/release-store.sh"
  # shellcheck source=lib/attachment.sh
  . "$script_dir/lib/attachment.sh"

  home="$(trellis_home_resolve "")" || return "$?"
  registry="$(local_registry_path "$home")" || return "$?"
  [ -e "$registry" ] || [ -L "$registry" ] || return 0

  state="$(mktemp "${TMPDIR:-/tmp}/trellis.worktree.registry.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  # Keep the registry reader's status intact. In particular, a corrupt or
  # unavailable local registry must not look like an unregistered clone. The
  # whole-file identity validator additionally aborted on the FIRST broken row
  # anywhere in the registry, which made one unrelated project's drift block
  # `git worktree add` seeding for every project on the machine. This call binds
  # exactly one row, so it validates exactly that row below — schema, private
  # state and permissions are still whole-file checks.
  local_registry_read_diagnostic_state "$home" > "$state" || {
    rc=$?
    rm -f "$state"
    return "$rc"
  }
  identity="$(local_registry_identity_for_root "$TARGET")" || {
    rc=$?
    rm -f "$state"
    return "$rc"
  }
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || {
    rm -f "$state"
    return "$TRELLIS_EX_STATE"
  }
  worktree="$(printf '%s\n' "$identity" | jq -r '.worktree_id')" || {
    rm -f "$state"
    return "$TRELLIS_EX_STATE"
  }
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || {
    rm -f "$state"
    return "$TRELLIS_EX_STATE"
  }
  # The row this call is about to bind gets the SAME strict identity validation
  # `local_registry_validate_available_identities` would have applied to it, so
  # a broken row here is still a hard class-4 refusal to seed. An unregistered
  # clone has no such row and validates vacuously, staying inert below.
  local_registry_validate_bound_row_identity "$(jq -c . "$state")" "$checkout" "$worktree" || {
    rc=$?
    rm -f "$state"
    return "$rc"
  }
  registration="$(jq -c --arg checkout "$checkout" --arg worktree "$worktree" \
    --arg common "$common" --arg root "$TARGET" '
    [ .projects | to_entries[]
      | . as $project
      | select($project.value.status == "active")
      | select(($project.value.metadata.legacy.blacklisted // false) == false)
      | $project.value.checkouts[$checkout]? as $record
      | select($record != null and $record.git_common_dir == $common)
      | select(([ $record.worktrees[]? | select(.attachment_id? != null) ] | length) > 0)
      | {fleet:$project.value.fleet, project_id:$project.value.project_id,
         unavailable_roots:($project.value.unavailable_roots // []),
         release:$record.release, harnesses:$record.harnesses, checkout:$record,
         worktree:($record.worktrees[$worktree] // {root:$root})} ]
    | if length == 0 then null
      elif length == 1 then .[0]
      else error("checkout is registered by multiple Trellis projects")
      end
  ' "$state")" || {
    rm -f "$state"
    return "$TRELLIS_EX_STATE"
  }
  rm -f "$state"

  # A registry can exist for another project/fleet without opting this clone
  # in. It must not cause project mutation or an emitted warning.
  [ "$registration" != null ] || return 0
  fleet="$(printf '%s\n' "$registration" | jq -r '.fleet')" || return "$TRELLIS_EX_STATE"
  project_id="$(printf '%s\n' "$registration" | jq -r '.project_id')" || return "$TRELLIS_EX_STATE"
  release="$(printf '%s\n' "$registration" | jq -r '.release // empty')" || return "$TRELLIS_EX_STATE"
  [ -n "$release" ] || return "$TRELLIS_EX_STATE"
  if printf '%s\n' "$registration" | jq -e --arg root "$TARGET" '
    (.unavailable_roots | index($root)) == null
  ' >/dev/null 2>&1; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$registration" | jq -e --arg root "$TARGET" '
    .worktree.root == $root
  ' >/dev/null 2>&1 || return "$TRELLIS_EX_STATE"
  harnesses_json="$(local_registry_normalize_harnesses "$(printf '%s\n' "$registration" | jq -c '.harnesses')")" || return "$?"
  [ "$harnesses_json" != '[]' ] || return "$TRELLIS_EX_STATE"
  payload="$(TRELLIS_HOME="$home" release_store_locate "$release")" || return "$?"
  payload="$payload/payload"
  [ -d "$payload" ] && [ ! -L "$payload" ] || return "$TRELLIS_EX_STATE"
  [ -x "$payload/scripts/attach-project.sh" ] || return "$TRELLIS_EX_STATE"
  owner="$home/state/attachments/$checkout/$worktree.json"
  attachment_id="$(printf '%s\n' "$registration" | jq -r '.worktree.attachment_id // empty')" || return "$TRELLIS_EX_STATE"
  expected_args=(
    "--expected-fleet" "$fleet"
    "--expected-project-id" "$project_id"
    "--expected-root" "$TARGET"
    "--expected-checkout-id" "$checkout"
    "--expected-worktree-id" "$worktree"
    "--expected-attachment-id" "$attachment_id"
    "--expected-release" "$release"
    "--expected-harnesses-json" "$harnesses_json"
  )
  if [ "$VERIFY_ONLY" -eq 1 ]; then
    # attachment_verify checks every owned artifact (including rendered files).
    # Bind that complete result to this exact registry worktree row and to the
    # immutable release anchor; scalar owner metadata alone is not enough.
    if [ -n "$attachment_id" ] &&
       [ -f "$owner" ] && [ ! -L "$owner" ] &&
       attachment_verify "$home" "$owner" >/dev/null 2>&1 &&
       jq -e --arg fleet "$fleet" --arg project_id "$project_id" --arg checkout "$checkout" \
         --arg worktree "$worktree" --arg attachment "$attachment_id" --arg release "$release" \
         --arg root "$TARGET" --arg payload "$payload" '
           .status == "committed"
           and .fleet == $fleet and .project_id == $project_id
           and .checkout_id == $checkout and .worktree_id == $worktree
           and .attachment_id == $attachment
           and .project_root == $root and .worktree_root == $root
           and .release == $release
           and ([.artifacts[]
                 | select(.path == ".trellis/runtime"
                          and .kind == "symlink"
                          and .target == $payload)] | length) == 1
         ' "$owner" >/dev/null 2>&1; then
      if [ "$QUIET" -eq 0 ]; then
        printf 'verify: attached worktree is current: %s\n' "$TARGET"
      fi
      return 0
    fi
    printf 'verify: opted-in worktree is missing its local Trellis attachment: %s\n' "$TARGET" >&2
    return 1
  fi
  # A target row with an attachment ID is an explicit repair request. A new
  # worktree may inherit this checkout's attachment only from a fully verified
  # sibling, never from scalar registry metadata alone.
  if [ -z "$attachment_id" ]; then
    donor_ok=0
    while IFS=$'\t' read -r donor_worktree donor_root donor_attachment; do
      [ -n "$donor_worktree" ] && [ -n "$donor_root" ] && [ -n "$donor_attachment" ] || continue
      donor_owner="$home/state/attachments/$checkout/$donor_worktree.json"
      [ -f "$donor_owner" ] && [ ! -L "$donor_owner" ] || continue
      [ "$(_attachment_mode "$donor_owner")" = 600 ] || continue
      donor_identity="$(local_registry_identity_for_root "$donor_root" 2>/dev/null)" || continue
      donor_checkout="$(printf '%s\n' "$donor_identity" | jq -r '.checkout_id')" || continue
      donor_worktree_actual="$(printf '%s\n' "$donor_identity" | jq -r '.worktree_id')" || continue
      donor_root_actual="$(printf '%s\n' "$donor_identity" | jq -r '.root')" || continue
      donor_common="$(printf '%s\n' "$donor_identity" | jq -r '.git_common_dir')" || continue
      [ "$donor_checkout" = "$checkout" ] &&
        [ "$donor_common" = "$common" ] &&
        [ "$donor_worktree_actual" = "$donor_worktree" ] &&
        [ "$donor_root_actual" = "$donor_root" ] || continue
      attachment_verify "$home" "$donor_owner" >/dev/null 2>&1 || continue
      jq -e --arg fleet "$fleet" --arg project_id "$project_id" --arg checkout "$checkout" \
        --arg worktree "$donor_worktree" --arg attachment "$donor_attachment" \
        --arg root "$donor_root" --arg release "$release" --arg payload "$payload" '
          .status == "committed"
          and .fleet == $fleet and .project_id == $project_id
          and .checkout_id == $checkout and .worktree_id == $worktree
          and .attachment_id == $attachment
          and .project_root == $root and .worktree_root == $root
          and .release == $release
          and ([.artifacts[]
                | select(.path == ".trellis/runtime"
                         and .kind == "symlink"
                         and .target == $payload)] | length) == 1
        ' "$donor_owner" >/dev/null 2>&1 || continue
      donor_ok=1
      donor_args=(
        "--expected-donor-root" "$donor_root"
        "--expected-donor-checkout-id" "$checkout"
        "--expected-donor-worktree-id" "$donor_worktree"
        "--expected-donor-attachment-id" "$donor_attachment"
        "--expected-donor-release" "$release"
        "--expected-donor-harnesses-json" "$harnesses_json"
      )
      break
    done < <(printf '%s\n' "$registration" | jq -r --arg worktree "$worktree" '
      .checkout.worktrees
      | to_entries[]
      | select(.key != $worktree and (.value.attachment_id? | type == "string"))
      | [.key, .value.root, .value.attachment_id] | @tsv
    ')
    [ "$donor_ok" -eq 1 ] || return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r harness; do
    [ -n "$harness" ] || continue
    attach_args+=("--harness" "$harness")
  done < <(printf '%s\n' "$harnesses_json" | jq -r '.[]')
  if [ "$QUIET" -eq 1 ]; then
    TRELLIS_HOME="$home" "$payload/scripts/attach-project.sh" attach --home "$home" \
      --fleet "$fleet" --release "$release" "${expected_args[@]}" "${donor_args[@]+"${donor_args[@]}"}" \
      "${attach_args[@]}" "$TARGET" >/dev/null
  else
    TRELLIS_HOME="$home" "$payload/scripts/attach-project.sh" attach --home "$home" \
      --fleet "$fleet" --release "$release" "${expected_args[@]}" "${donor_args[@]+"${donor_args[@]}"}" \
      "${attach_args[@]}" "$TARGET"
  fi
}

attachment_reconcile
exit $?
