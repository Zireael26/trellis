#!/usr/bin/env bash
# trellis disk-janitor — report-first reclaim of build caches, dead worktrees,
# package stores, host-global Docker resources, and release execution staging
# across the active fleet.
#
# Three modes, escalating in destructiveness:
#   --report (default)  Scan every scope, print a human report to stdout AND
#                       write audits/YYYY-MM-DD-disk-janitor.md. Includes the
#                       turbo-outputs recurrence pre-pass (the 148 GB/2 days
#                       root cause) and the tripwire status (free space vs
#                       floor, largest cache vs ceiling). DELETES NOTHING and
#                       never modifies a working tree. The default launchd
#                       agent runs only this mode.
#   --dry-run           Print the EXACT deletion plan (path, human bytes,
#                       why-safe per row; worktrees show the reap verdict).
#                       DELETES NOTHING.
#
# Note: building the plan (in every mode) calls the merge discriminator, which
# runs a read-only `gh pr list` (network read) to detect merged branches. It
# modifies no git refs, removes no files, and touches no working tree — so
# report/dry-run are fully non-destructive.
#   --apply             Print the plan, then PER CATEGORY confirm before
#                       deleting — read a y/N line from stdin unless --yes.
#                       Destructive ops are a bright-line guardrail, so the
#                       prompt is mandatory without --yes. Re-scan + report
#                       reclaimed bytes. The opt-in nightly apply LaunchAgent
#                       runs only `--scopes worktrees --safe-only`.
#
# Docker volumes are never deleted, in any mode or with any flag: the Docker
# scope lists unattached anonymous volumes as report-only (Links == 0 does not
# mean a volume holds no data). Its only mutation is the BuildKit cache prune.
# Deleting a volume is an operator action under PROTOCOL §10.
#
# Worktree reap (default, reap_pushed_worktrees=true) is gated on: is_main==0
# AND not in use (live cwd/open handles via a fail-safe lsof snapshot) AND
# no tracked, untracked, or ignored local content AND recoverable (branch merged
# via gh OR pushed to origin with the tip not ahead). An in-use tree or any
# residual local content is reported for manual review and EXCLUDED from apply.
# A content-clean but unrecoverable tree under /private/tmp reaps at a short TTL
# (ephemeral_tmp_ttl_days). The same default path may clear ONE exact absent,
# Git-prunable registration under /sessions or /tmp, authorized by a strict
# current registry root and never by a broad Git prune; the unattended
# --safe-only path leaves those registrations for manual apply. Setting
# reap_pushed_worktrees=false restores the pre-Layer-2 stale+clean+merged gates,
# still behind the shared non-main + not-in-use safety gates.
#
# Per-project failure isolation: a project that errors mid-scan is reported as
# `skipped: <reason>` and the run continues.
#
# Exit codes: 0 success, 1 scan/prune error, 2 bad args, 3 identity conflict.
#
# bash 3.2 compatible: no [[ ]], no declare -A, no mapfile, no ${x,,}.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/disk-janitor-lib.sh
. "$SCRIPT_DIR/lib/disk-janitor-lib.sh"
# shellcheck source=lib/hygiene-common.sh
. "$SCRIPT_DIR/lib/hygiene-common.sh"
# shellcheck source=lib/disk-janitor-dehydrate.sh
. "$SCRIPT_DIR/lib/disk-janitor-dehydrate.sh"
# shellcheck source=lib/disk-janitor-host.sh
. "$SCRIPT_DIR/lib/disk-janitor-host.sh"

# The launcher and the LaunchAgents run the janitor with a minimal PATH, which
# has no gh (merge checks read "unverified"), docker, colima, pnpm or uv. The
# installer records their directories in TRELLIS_HOME/state/disk-janitor/
# tool-path, one absolute directory per line; prepend them in file order. A
# relative entry or one holding ':' is skipped.
JANITOR_TOOL_PATH_FILE="$TRELLIS_HOME/state/disk-janitor/tool-path"
if [ -f "$JANITOR_TOOL_PATH_FILE" ]; then
  janitor_tool_path=""
  while IFS= read -r tool_dir || [ -n "$tool_dir" ]; do
    case "$tool_dir" in
      /*:*|'') continue ;;
      /*) janitor_tool_path="${janitor_tool_path:+$janitor_tool_path:}$tool_dir" ;;
    esac
  done <"$JANITOR_TOOL_PATH_FILE"
  [ -z "$janitor_tool_path" ] || PATH="$janitor_tool_path:$PATH"
  export PATH
fi

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
MODE="report"            # report | dry-run | apply
ONLY_PROJECT=""
SCOPES="caches,worktrees,stores,docker,releases"
ASSUME_YES=0
SAFE_ONLY=0              # --safe-only: unattended-safe worktree reap (merged-only)
DEHYDRATE=0              # --dehydrate: delete regenerable dirs in idle clean trees (spec 069 D1)

print_help() {
  cat <<'EOF'
trellis disk-janitor — reclaim build caches, dead worktrees, package stores,
and host-global Docker resources and release execution staging

Usage:
  disk-janitor.sh                          Report (read-only). Default mode.
  disk-janitor.sh --report                 Same as no flag: scan + write audit.
  disk-janitor.sh --dry-run                Print the exact deletion plan only.
  disk-janitor.sh --apply                  Apply, confirming per category (y/N).
                                           NOTE: bare --apply includes BuildKit
                                           cache pruning by default. Docker
                                           volumes are never deleted.
  disk-janitor.sh --apply --yes            Apply without the per-category prompt.
  disk-janitor.sh --apply --yes --safe-only
                                           Unattended-safe worktree reap and
                                           orphaned release staging, plus the
                                           same Docker behavior as normal --apply.
  disk-janitor.sh --project ID             Limit to one local-registry project
                                           identity; multiple clones are refused.
  disk-janitor.sh --scopes caches,worktrees,stores,docker,releases
                                           Limit scopes (default: these five).
  disk-janitor.sh --scopes pi              Opt-in, report-only: pi temp files,
                                           spill logs and orphan pi worktrees
                                           (never in the default set; --apply
                                           refuses it).
  disk-janitor.sh --scopes orphans,logs,tmp,transcripts
                                           Opt-in spec 069 scopes (never in the
                                           default set; not implemented in this
                                           build).
  disk-janitor.sh --dehydrate              Delete only regenerable directories
                                           (node_modules, .venv, caches, dist/
                                           build/target beside a manifest) in
                                           idle, clean worktrees with a tracked
                                           lockfile and no open handle, and in
                                           orphans (spec 069 D1). Other ignored
                                           content is kept.
  disk-janitor.sh --help                   Show this help.

Modes (escalating):
  --report   Scans every scope, prints a report AND writes
             audits/YYYY-MM-DD-disk-janitor.md. Includes the turbo-outputs
             recurrence pre-pass + the disk tripwire (free vs floor, largest
             cache vs ceiling). Deletes nothing. The default report LaunchAgent
             runs only this mode.
  --dry-run  Prints the deletion plan (path, size, why-safe; worktrees show
             the reap verdict; Docker shows the BuildKit cache prune command
             and lists unattached anonymous volumes as report-only). Deletes
             nothing.
  --apply    Prints the plan, then per category reads a y/N line from stdin
             before deleting (mandatory unless --yes). Re-scans, reports
             reclaimed bytes. Bare --apply includes the BuildKit cache prune by
             default; use --scopes to omit it explicitly.

The janitor never deletes Docker volumes, in any mode or with any flag. Volumes
are reported only (see PROTOCOL §10); removing one is an operator action taken
with the Docker CLI directly.

Merge detection uses a read-only `gh pr list` query (a merged PR for the
branch); it modifies no git refs and deletes nothing, so report/dry-run stay
non-destructive. A worktree whose merge can't be verified (no gh, detached
HEAD) is reported as a candidate and never reaped.

--safe-only tightens the worktree reap for unattended use (the nightly apply
LaunchAgent): a `delete` verdict survives ONLY for a merged, content-clean,
non-detached, not-in-use tree. Every worktree path is checked for a live process
cwd or open handle via a bounded lsof snapshot; a missing, failed, or timed-out
lsof check fails closed and makes the tree a manual candidate.
Every other auto-delete (pushed-but-unmerged, ephemeral /private/tmp) is
downgraded to a manual candidate; those are in-flight trees owned by the fan-out
recipe teardown. The flag only ever tightens the worktree plan, so
`--dry-run --safe-only` previews exactly what the nightly would reap. Docker
behavior is unchanged by --safe-only.

Config:
  disk_janitor.docker_cache_keep_gb  BuildKit cache space retained by Docker
                                     apply pruning. Non-negative decimal;
                                     default 20. This is separate from
                                     cache_ceiling_gb, the largest JS/build-cache
                                     tripwire. The installed buildx supports
                                     --reserved-space, so Docker apply uses that
                                     flag rather than unsupported keep-storage flags.

Scopes:
  caches      .turbo/cache, .next/cache, .next/dev older than cache_ttl_days,
              skipped when a build is running.
  worktrees   linked git worktrees that are non-main AND not in use (no live cwd
              or open handle) AND have no tracked, untracked, or ignored local
              content AND are recoverable (branch merged OR pushed to origin).
              An lsof failure makes all linked trees manual candidates
              (fail-safe). Clean-but-unrecoverable and any residual local
              content are candidates, never reaped (see /private/tmp TTL).
              reap_pushed_worktrees=false restores the legacy
              stale+clean+merged gates after the liveness gate.
  stores      pnpm store / npm cache footprint — REPORT-ONLY (best-effort
              estimate; --apply does not prune stores in this release).
  docker      Host-global, scanned exactly once. Every mode shows total and
              unattached (Links == 0) anonymous volumes (64-lowercase-hex names),
              their size and IDs under a report-only heading, BuildKit cache
              reclaimable, image count, and Engine version. Apply runs only
              `docker buildx prune -f --reserved-space <N>GB`; volumes and
              images are never deleted. If Docker is not already live, the scope
              is skipped without starting Desktop.
  releases    Host-global TRELLIS_HOME/releases staging via `trellis release
              reap-tmp` (spec 069 D3): both .tmp.<version>.exec.<suffix> and
              .tmp.<version>.verify.<suffix> scratch. Only reap-tmp reapable
              rows become [delete]; keep/refused rows are [skip]/[candidate].
  pi          Host-global, opt-in: spill logs (pi-bash-*.log older than 1d or
              over 1 GiB, no open handle) apply-delete across the _pi root,
              ~/.pi-worktrees, the legacy root, bare $TMPDIR, $TMPDIR/pi and
              the Darwin user temp + pi/ (maxdepth 1, never following symlinks;
              pi_apply:false restores report-only). Temp files older than 3d
              stay manual. A worktree is listed only as an orphan: no owner
              record names it and its parent does not register it.

Exit codes: 0 success, 1 scan/prune error, 2 bad arguments, 3 identity conflict.
EOF
}

# Indexed parse so --project NAME works without bash-4 features (mirrors doctor).
arg=""
i=1
while [ "$i" -le "$#" ]; do
  eval "arg=\${$i}"
  case "$arg" in
    --report)
      MODE="report"
      ;;
    --dry-run)
      MODE="dry-run"
      ;;
    --apply)
      MODE="apply"
      ;;
    --yes|-y)
      ASSUME_YES=1
      ;;
    --safe-only)
      SAFE_ONLY=1
      ;;
    --dehydrate)
      # shellcheck disable=SC2034  # read by lib/disk-janitor-dehydrate.sh
      DEHYDRATE=1
      ;;
    --project)
      i=$((i + 1))
      [ "$i" -le "$#" ] || { echo "disk-janitor: --project requires a NAME" >&2; exit 2; }
      eval "ONLY_PROJECT=\${$i}"
      ;;
    --project=*)
      ONLY_PROJECT="${arg#--project=}"
      ;;
    --scopes)
      i=$((i + 1))
      [ "$i" -le "$#" ] || { echo "disk-janitor: --scopes requires a value" >&2; exit 2; }
      eval "SCOPES=\${$i}"
      ;;
    --scopes=*)
      SCOPES="${arg#--scopes=}"
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    -*)
      echo "disk-janitor: unknown option: $arg" >&2
      echo "try: disk-janitor.sh --help" >&2
      exit 2
      ;;
    *)
      echo "disk-janitor: unexpected argument: $arg" >&2
      exit 2
      ;;
  esac
  i=$((i + 1))
done

# scope_enabled <name> — is <name> in the comma-separated SCOPES list?
scope_enabled() {
  local want="$1" s
  local ifs_save="$IFS"
  IFS=','
  for s in $SCOPES; do
    if [ "$s" = "$want" ]; then
      IFS="$ifs_save"
      return 0
    fi
  done
  IFS="$ifs_save"
  return 1
}

# Validate the scope list up front (a typo'd scope is a bad arg, exit 2).
validate_scopes() {
  local s ifs_save="$IFS"
  IFS=','
  for s in $SCOPES; do
    case "$s" in
      caches|worktrees|stores|docker|releases|pi|orphans|logs|tmp|transcripts) ;;
      "") ;;
      *)
        IFS="$ifs_save"
        echo "disk-janitor: unknown scope: $s (valid: caches, worktrees, stores, docker, releases, pi, orphans, logs, tmp, transcripts)" >&2
        exit 2
        ;;
    esac
  done
  IFS="$ifs_save"
}
validate_scopes
# C3 (spec 069): the pi scope applies spill logs and orphan pi-agent worktrees
# when disk_janitor.pi_apply is true (default); pi_apply:false restores
# report-only. The 1.3.12 blanket refusal is retired.

# Header tag so every mode's banner shows when the unattended-safe worktree
# restriction is active (the nightly apply LaunchAgent runs with --safe-only).
SAFE_ONLY_TAG=""
[ "$SAFE_ONLY" -eq 1 ] && SAFE_ONLY_TAG="  (safe-only: merged-clean worktrees only)"

# ---------------------------------------------------------------------------
# Config — the disk_janitor object via jq with per-key defaults. The whole
# object (or the whole file's key) being absent must still work: every read is
# `// DEFAULT`. config-load exports TRELLIS_CONFIG_PATH.
# ---------------------------------------------------------------------------
CFG="$TRELLIS_CONFIG_PATH"

cfg_num() {
  # cfg_num <jq-path> <default> — read a numeric key, fall back to default.
  local path="$1" def="$2" val
  val="$(jq -r "$path // empty" "$CFG" 2>/dev/null || true)"
  [ -n "$val" ] && [ "$val" != "null" ] || val="$def"
  printf '%s' "$val"
}

cfg_bool() {
  # cfg_bool <jq-path> <default true|false> — read a boolean key. jq's `//`
  # alternative operator coalesces `false` exactly like `null`, so `X // true`
  # would read an explicit `false` back as `true` (silently defeating a disable
  # switch). We therefore read the RAW value and treat ONLY an explicit
  # "true"/"false" as authoritative; null / missing / malformed → the default.
  local path="$1" def="$2" val
  val="$(jq -r "$path" "$CFG" 2>/dev/null || echo null)"
  case "$val" in
    true) printf 'true' ;;
    false) printf 'false' ;;
    *) printf '%s' "$def" ;;
  esac
}

# NOTE: read via cfg_bool, NOT `.disk_janitor.enabled // true` — the latter
# coalesces an explicit `false` back to `true`, so `enabled=false` would fail to
# block --apply (the documented safety switch). cfg_bool honors an explicit false.
DJ_ENABLED="$(cfg_bool '.disk_janitor.enabled' true)"
# disk_janitor.enabled=false hard-blocks the destructive --apply path (report
# and dry-run remain available for inspection). The default is true.
if [ "$MODE" = "apply" ] && [ "$DJ_ENABLED" = "false" ]; then
  echo "disk-janitor: disk_janitor.enabled is false in config — --apply is disabled." >&2
  echo "  run --report or --dry-run to inspect, or set disk_janitor.enabled=true to apply." >&2
  exit 2
fi
CACHE_TTL_DAYS="$(cfg_num '.disk_janitor.cache_ttl_days' 14)"
# D3 delegates release staging to `release_store_reap_tmp` (spec 069); the
# legacy `release_staging_ttl_days` key is retired and no longer read.
WORKTREE_STALE_DAYS="$(cfg_num '.disk_janitor.worktree_stale_days' 30)"
FREE_SPACE_FLOOR_GB="$(cfg_num '.disk_janitor.free_space_floor_gb' 30)"
CACHE_CEILING_GB="$(cfg_num '.disk_janitor.cache_ceiling_gb' 20)"
# This is intentionally separate from cache_ceiling_gb: that key is the largest
# JS/build-cache tripwire, while this value is BuildKit's retained cache floor.
DOCKER_CACHE_KEEP_GB="$(cfg_num '.disk_janitor.docker_cache_keep_gb' 20)"
if ! printf '%s\n' "$DOCKER_CACHE_KEEP_GB" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
  echo "disk-janitor: WARNING: malformed disk_janitor.docker_cache_keep_gb='$DOCKER_CACHE_KEEP_GB'; using 20" >&2
  DOCKER_CACHE_KEEP_GB=20
fi
# Layer 2/3 (worktree lifecycle reap). reap_pushed_worktrees is a boolean via
# cfg_bool (so an explicit false is honored); the rest are numeric via cfg_num.
# All default-safe: an absent disk_janitor object still yields the documented
# defaults (reap_pushed_worktrees true; ephemeral_tmp_ttl_days 2; ceilings 25/80).
REAP_PUSHED_WORKTREES="$(cfg_bool '.disk_janitor.reap_pushed_worktrees' true)"
EPHEMERAL_TMP_TTL_DAYS="$(cfg_num '.disk_janitor.ephemeral_tmp_ttl_days' 2)"
# pi scope: temp files 3d; spill logs 1d or over 1 GiB (C3); pi-agent
# worktrees pi_worktree_ttl_days (A9, default 7). pi_apply:false restores
# report-only (C3 rollback). Spill roots are maxdepth-1, never following
# symlinks, across the worktree _pi root, ~/.pi-worktrees, the legacy root,
# bare $TMPDIR, $TMPDIR/pi, and the per-user DARWIN_USER_TEMP_DIR + its pi/.
PI_TMP_TTL_DAYS=3
PI_SPILL_TTL_DAYS=1
PI_SPILL_MAX_BYTES=1073741824
PI_APPLY="$(cfg_bool '.disk_janitor.pi_apply' true)"
PI_WORKTREE_TTL_DAYS="$(cfg_num '.disk_janitor.pi_worktree_ttl_days' 7)"
case "$PI_WORKTREE_TTL_DAYS" in ''|*[!0-9]*) PI_WORKTREE_TTL_DAYS=7 ;; esac
WORKTREE_COUNT_CEILING="$(cfg_num '.disk_janitor.worktree_count_ceiling' 25)"
WORKTREE_TOTAL_GB_CEILING="$(cfg_num '.disk_janitor.worktree_total_gb_ceiling' 80)"

# disk_janitor.apply_disabled_scopes: per-scope opt-out of --apply (the spec
# 069 D rollback switch). A listed scope is dropped from an apply run with a
# note; --report and --dry-run still scan it.
if [ "$MODE" = "apply" ]; then
  while IFS= read -r disabled_scope; do
    [ -n "$disabled_scope" ] || continue
    scope_enabled "$disabled_scope" || continue
    echo "disk-janitor: apply disabled for scope $disabled_scope by disk_janitor.apply_disabled_scopes; skipped" >&2
    SCOPES="$(printf '%s' ",$SCOPES," | sed "s/,$disabled_scope,/,/g; s/^,//; s/,\$//")"
  done < <(jq -r '.disk_janitor.apply_disabled_scopes[]? // empty' "$CFG" 2>/dev/null || true)
fi

SKIP_PROJECTS=()
while IFS= read -r sp; do
  [ -n "$sp" ] && SKIP_PROJECTS+=("$sp")
done < <(jq -r '.disk_janitor.skip_projects[]? // empty' "$CFG" 2>/dev/null || true)

# is_skip_project <name> — in disk_janitor.skip_projects?
is_skip_project() {
  local name="$1" s
  [ "${#SKIP_PROJECTS[@]}" -eq 0 ] && return 1
  for s in "${SKIP_PROJECTS[@]}"; do
    [ "$s" = "$name" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Strict local-registry target selection.
#
# Every available scan starts from one recorded worktree identity. We never
# reconstruct a path from a discovery root or consult the historical tracked
# registry. Unavailable inventory remains visible as a report skip, but is
# never probed (including by df).
# ---------------------------------------------------------------------------
CANON="$TRELLIS_SOURCE_ROOT"
PLAN_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor.XXXXXX")"
LSOF_SNAPSHOT_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor-lsof.XXXXXX")"
REGISTRY_SNAPSHOT_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor-registry.XXXXXX")"
TARGETS_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor-targets.XXXXXX")"
VOLUMES_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor-volumes.XXXXXX")"
DOCKER_VOLUME_IDS_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor-docker-volumes.XXXXXX")"
PI_OWNER_PATHS_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor-pi-owners.XXXXXX")"
trap 'rm -f "$PLAN_TMP" "$LSOF_SNAPSHOT_TMP" "$REGISTRY_SNAPSHOT_TMP" "$TARGETS_TMP" "$VOLUMES_TMP" "$DOCKER_VOLUME_IDS_TMP" "$PI_OWNER_PATHS_TMP"' EXIT

EXIT_STATUS=0
REGISTRY_STATE_ERRORS=0
NOW_EPOCH="$(date +%s)"

# Highest exit class wins. A registry row that fails identity validation is a
# state error, not a degraded scan, so the later EXIT_STATUS=1 signals must not
# lower it. `TRELLIS_EX_STATE` is the shared constant: disk-janitor-lib.sh
# sources local-registry.sh, which sources trellis-home.sh, in THIS shell, so
# the class names are in scope here and must not be re-spelled locally.
final_exit_status() {
  if [ "$REGISTRY_STATE_ERRORS" -gt 0 ] && [ "$EXIT_STATUS" -lt "$TRELLIS_EX_STATE" ]; then
    printf '%s\n' "$TRELLIS_EX_STATE"
  else
    printf '%s\n' "$EXIT_STATUS"
  fi
}

# plan_row <scope> <verdict> <kind> <abs_path> <bytes> <repo_or_dash> <detail>
#          [fleet project_id checkout_id worktree_id git_common_dir owner_root]
#
# Project rows use the trailing columns for registry identity. Host-global
# release-staging rows instead carry VERSION in repo_or_dash and the snapshot's
# expected device/inode in fleet/project_id; their remaining identity fields are
# empty. Renderers ignore these machine fields. Apply names and validates them
# before passing them to the descriptor-relative sink.
plan_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    "${8:-}" "${9:-}" "${10:-}" "${11:-}" "${12:-}" "${13:-}" >>"$PLAN_TMP"
}

if local_registry_list_json "$TRELLIS_HOME" "$TRELLIS_FLEET_NAME" >"$REGISTRY_SNAPSHOT_TMP"; then :; else
  rc=$?
  echo "disk-janitor: strict local registry is unavailable or invalid; refusing fleet scan" >&2
  exit "$rc"
fi

# FULL-LISTING state scan, run BEFORE the `--project` preflight guards below.
#
# The row loop already tests `identity_error` ahead of the selection filter, so
# an accepted scoped run carried a drifted sibling into its exit class. The two
# preflight guards below never reached that loop: an unknown or ambiguous
# project selector exited 2 or 3 while the listing in hand already proved the
# registry corrupt, reporting a class BELOW the state error and naming none of
# the rows. The scan therefore happens here, independent of the loop, and every
# preflight exit is floored by it.
REGISTRY_PRESCAN_STATE_ERRORS=0
if REGISTRY_PRESCAN_STATE_ERRORS="$(jq -r \
    '[.entries[] | select(.availability == "identity_error")] | length' \
    "$REGISTRY_SNAPSHOT_TMP" 2>/dev/null)"; then :; else
  echo "disk-janitor: could not inspect the strict local registry listing for identity-drift rows" >&2
  exit "$TRELLIS_EX_STATE"
fi
case "$REGISTRY_PRESCAN_STATE_ERRORS" in
  ''|*[!0-9]*)
    echo "disk-janitor: could not inspect the strict local registry listing for identity-drift rows" >&2
    exit "$TRELLIS_EX_STATE"
    ;;
esac

# Exit from a preflight refusal at no lower a class than the registry state the
# scan above already proved, and never without naming the rows that proved it —
# the plan file that normally carries those reports is not rendered on an early
# exit.
preflight_exit() {
  local class="${1:-0}" rows=""
  if [ "$REGISTRY_PRESCAN_STATE_ERRORS" -gt 0 ]; then
    rows="$(jq -r '
      .entries[]
      | select(.availability == "identity_error")
      | "disk-janitor: state error: registry row failed identity validation ("
        + .fleet + "/" + .project_id
        + (if (.root // "") == "" then "" else ": " + .root end) + ")"
    ' "$REGISTRY_SNAPSHOT_TMP" 2>/dev/null)" || rows=""
    [ -z "$rows" ] || printf '%s\n' "$rows" >&2
    [ "$class" -ge "$TRELLIS_EX_STATE" ] || class="$TRELLIS_EX_STATE"
  fi
  exit "$class"
}

# --project selects one logical project within the active fleet. Multiple
# worktrees in the same checkout are one project scope; multiple checkout IDs
# are distinct clones and therefore ambiguous without a richer selector.
# Availability never resolves that conflict: a missing clone's recorded
# checkout ID still prevents silently selecting a different clone.
if [ -n "$ONLY_PROJECT" ]; then
  local_registry_require_project_id "$ONLY_PROJECT" || preflight_exit "$?"
  project_matches="$(jq -r --arg project "$ONLY_PROJECT" \
    '[.entries[] | select(.project_id == $project)] | length' "$REGISTRY_SNAPSHOT_TMP")"
  if [ "$project_matches" -eq 0 ]; then
    echo "disk-janitor: --project '$ONLY_PROJECT' is not in the local registry" >&2
    preflight_exit 2
  fi
  checkout_matches="$(jq -r --arg project "$ONLY_PROJECT" '
    [.entries[]
      | select(.project_id == $project and .checkout_id != null and .checkout_id != "")
      | .checkout_id]
    | unique | length
  ' "$REGISTRY_SNAPSHOT_TMP")"
  if [ "$checkout_matches" -gt 1 ]; then
    echo "disk-janitor: --project '$ONLY_PROJECT' matches multiple registered checkout identities; refusing identity conflict" >&2
    preflight_exit 3
  fi
fi

TARGET_KEYS=()
TARGET_COUNT=0
VOLUME_KEYS=()

# A checkout can have several registered current worktrees. Phantom Git metadata
# is inspected once per common directory, always through the first strict,
# available current-root identity that reaches this scanner.
PHANTOM_SCAN_KEYS=()

# add_target FLEET PROJECT CHECKOUT_ID WORKTREE_ID ROOT GIT_COMMON_DIR
add_target() {
  local fleet="$1" project_id="$2" checkout_id="$3" worktree_id="$4"
  local root="$5" common="$6" root_real common_real key seen

  [ -d "$root" ] && [ ! -L "$root" ] && [ -d "$common" ] && [ ! -L "$common" ] || {
    plan_row meta skip project "${root:--}" 0 "-" \
      "skipped: registered root became unavailable or symlinked ($fleet/$project_id)" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    return 0
  }
  root_real="$(dj__abspath "$root")"
  common_real="$(dj__abspath "$common")"
  if [ "$root_real" != "$root" ] || [ "$common_real" != "$common" ]; then
    plan_row meta skip project "$root" 0 "-" \
      "skipped: registry paths are no longer canonical ($fleet/$project_id)" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    return 0
  fi
  key="$checkout_id/$worktree_id/$common/$root"
  if [ "${#TARGET_KEYS[@]}" -gt 0 ]; then
    for seen in "${TARGET_KEYS[@]}"; do
      [ "$seen" = "$key" ] && return 0
    done
  fi
  TARGET_KEYS+=("$key")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$root" "$common" >>"$TARGETS_TMP"
  TARGET_COUNT=$((TARGET_COUNT + 1))
}

# record_filesystem_for_root ROOT
# df is intentionally reached only from a live, selected worktree root. The
# filesystem device is the dedupe key, yielding one floor check per filesystem.
record_filesystem_for_root() {
  local root="$1" row filesystem avail_k avail_bytes seen
  [ -d "$root" ] && [ ! -L "$root" ] || {
    plan_row meta skip volume "${root:--}" 0 "-" \
      "skipped: unavailable root was not passed to df ($root)"
    return 0
  }
  row="$(df -Pk "$root" 2>/dev/null | awk 'NR == 2 { print $1 "\t" $4 }' || true)"
  IFS="$(printf '\t')" read -r filesystem avail_k <<EOF
$row
EOF
  if [ -z "${filesystem:-}" ]; then
    plan_row meta skip volume "$root" 0 "-" \
      "skipped: could not determine filesystem free space for registered root ($root)"
    return 0
  fi
  case "${avail_k:-}" in
    ''|*[!0-9]*)
      plan_row meta skip volume "$root" 0 "-" \
        "skipped: could not determine filesystem free space for registered root ($root)"
      return 0
      ;;
  esac
  if [ "${#VOLUME_KEYS[@]}" -gt 0 ]; then
    for seen in "${VOLUME_KEYS[@]}"; do
      [ "$seen" = "$filesystem" ] && return 0
    done
  fi
  VOLUME_KEYS+=("$filesystem")
  avail_bytes=$((avail_k * 1024))
  printf '%s\t%s\t%s\n' "$filesystem" "$root" "$avail_bytes" >>"$VOLUMES_TMP"
}

# Read each registry field on its own. `@tsv` doubles backslashes, so a legal
# backslash-containing root would never match the registered path again. The
# `// ""` defaults keep the null-to-empty mapping the tab-separated form had.
while IFS= read -r registry_row; do
  [ -n "$registry_row" ] || continue
  if fleet="$(printf '%s\n' "$registry_row" | jq -er '.fleet' 2>/dev/null)" &&
     project_id="$(printf '%s\n' "$registry_row" | jq -er '.project_id' 2>/dev/null)" &&
     kind="$(printf '%s\n' "$registry_row" | jq -er '.kind' 2>/dev/null)" &&
     availability="$(printf '%s\n' "$registry_row" | jq -er '.availability' 2>/dev/null)" &&
     status="$(printf '%s\n' "$registry_row" | jq -er '.status' 2>/dev/null)" &&
     excluded="$(printf '%s\n' "$registry_row" | jq -er '(.excluded | tostring)' 2>/dev/null)" &&
     root="$(printf '%s\n' "$registry_row" | jq -r '(.root // "")' 2>/dev/null)" &&
     checkout_id="$(printf '%s\n' "$registry_row" | jq -r '(.checkout_id // "")' 2>/dev/null)" &&
     worktree_id="$(printf '%s\n' "$registry_row" | jq -r '(.worktree_id // "")' 2>/dev/null)" &&
     common="$(printf '%s\n' "$registry_row" | jq -r '(.git_common_dir // "")' 2>/dev/null)"; then
    :
  else
    plan_row meta skip project "-" 0 "-" \
      "state error: could not parse strict local registry row"
    REGISTRY_STATE_ERRORS=$((REGISTRY_STATE_ERRORS + 1))
    continue
  fi
  # A registry state error is a property of the REGISTRY, not of the selection.
  # This test runs against the FULL row stream, before `--project` narrows it,
  # for the same reason the unparseable-row test above does: a scoped run over a
  # healthy project must not exit 0 over a registry it has just been shown to be
  # corrupt. The row is reported and counted, never processed, so the selection
  # contract — only the selected project is acted on — is unchanged.
  if [ "$availability" = "identity_error" ]; then
    plan_row meta skip project "${root:--}" 0 "-" \
      "state error: registry row failed identity validation ($fleet/$project_id${root:+: $root})" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    REGISTRY_STATE_ERRORS=$((REGISTRY_STATE_ERRORS + 1))
    continue
  fi
  [ -z "$ONLY_PROJECT" ] || [ "$project_id" = "$ONLY_PROJECT" ] || continue

  # A `checkout` row is a VISIBILITY row: the listing emits it only for a
  # registered checkout that currently holds no worktree. A reachable one is
  # `available`, so folding it into the unavailable skip reported healthy
  # inventory as an unavailable root — a misclassification in the audit even
  # though no exit class moved. It is still never a scan target: there is no
  # worktree to walk.
  if [ "$kind" = "checkout" ] && [ "$availability" = "available" ]; then
    plan_row meta skip project "${root:--}" 0 "-" \
      "skipped: registered checkout with no worktree row ($fleet/$project_id${root:+: $root})" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    continue
  fi
  if [ "$availability" != "available" ] || [ "$kind" != "worktree" ] || [ -z "$root" ]; then
    plan_row meta skip project "${root:--}" 0 "-" \
      "skipped: unavailable registry row ($fleet/$project_id${root:+: $root})" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    continue
  fi
  if [ "${status:-}" != "active" ]; then
    plan_row meta skip project "$root" 0 "-" \
      "skipped: inactive registry status ($fleet/$project_id: ${status:-unknown})" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    continue
  fi
  if [ -z "$ONLY_PROJECT" ] && [ "$excluded" = "true" ]; then
    plan_row meta skip project "$root" 0 "-" \
      "skipped: excluded by local registry ($fleet/$project_id)" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    continue
  fi
  if [ -z "$ONLY_PROJECT" ] && is_skip_project "$project_id"; then
    plan_row meta skip project "$root" 0 "-" \
      "skipped: disk_janitor.skip_projects ($fleet/$project_id)" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    continue
  fi
  add_target "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$root" "$common"
done < <(jq -c '.entries[]' "$REGISTRY_SNAPSHOT_TMP")

# One bounded host-wide lsof snapshot feeds every linked-worktree predicate.
# Failure is recorded in the snapshot itself; dj_worktree_in_use interprets that
# marker as "in use" so a broken safety check can only close the reap gate.
if scope_enabled worktrees || scope_enabled pi || scope_enabled orphans ||
   scope_enabled logs || scope_enabled tmp; then
  if dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5; then :; else :; fi
fi

# ---------------------------------------------------------------------------
# Recurrence pre-pass — the turbo-outputs landmine that caused the 148 GB
# incident. Pure report; calls the shared lib predicate + fix-hint string.
# Returns the offending project list as text on stdout (one "name\tpath" per
# line); empty when clean.
# ---------------------------------------------------------------------------
TURBO_LANDMINES=""
turbo_prepass() {
  local fleet project_id checkout_id worktree_id proj common tj rc label
  TURBO_LANDMINES=""
  [ "$TARGET_COUNT" -gt 0 ] || return 0
  while IFS="$(printf '\t')" read -r fleet project_id checkout_id worktree_id proj common; do
    # Treat the recurrence scan like every other filesystem scan: never read a
    # root that no longer proves the exact persisted Git identity.
    if ! dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" \
        "$checkout_id" "$worktree_id" "$common" "$proj" >/dev/null; then
      continue
    fi
    tj="$proj/turbo.json"
    [ -f "$tj" ] || continue
    if dj_turbo_outputs_unscoped "$tj"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
      label="$fleet/$project_id [$checkout_id/$worktree_id]"
      if [ -z "$TURBO_LANDMINES" ]; then
        TURBO_LANDMINES="$label	$tj"
      else
        TURBO_LANDMINES="$TURBO_LANDMINES
$label	$tj"
      fi
    fi
  done <"$TARGETS_TMP"
  return 0
}

# ---------------------------------------------------------------------------
# Scope A: build caches.
# ---------------------------------------------------------------------------
scan_caches() {
  local proj="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5" common="$6"
  local kind path bytes mtime rc build_active=0 cache_rows detail

  # Running-build guard: if a build is live in this project, do not touch its
  # caches at all (testable via DJ_BUILD_ACTIVE_OVERRIDE).
  if dj_build_active "$proj"; then build_active=1; fi

  if cache_rows="$(dj_find_caches "$proj")"; then :; else
    rc=$?
    echo "disk-janitor: WARNING: cache discovery failed for $proj (exit $rc)" >&2
    return "$rc"
  fi

  while IFS="$(printf '\t')" read -r kind path bytes mtime; do
    [ -n "$path" ] || continue
    if ! dj_cache_entry_owned_by_worktree "$proj" "$path"; then
      plan_row caches skip "$kind" "$path" "$bytes" "$proj" \
        "cache crosses a registered Git worktree boundary — left intact" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      continue
    fi
    if [ "$build_active" -eq 1 ]; then
      plan_row caches skip "$kind" "$path" "$bytes" "$proj" "build running — caches left intact" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      continue
    fi
    if dj_cache_is_stale "$mtime" "$CACHE_TTL_DAYS" "$NOW_EPOCH"; then rc=0; else rc=$?; fi
    # A spec 069 D1 directory (node_modules, .venv, ...) is footprint here,
    # never a cache delete: only --dehydrate removes it, and only in an idle,
    # clean worktree with a tracked lockfile.
    case "$kind" in
      turbo-cache|next-cache|next-dev) ;;
      *)
        if [ "$rc" -eq 0 ]; then detail="no git activity for ${CACHE_TTL_DAYS}d"; else detail="git activity within ${CACHE_TTL_DAYS}d"; fi
        plan_row caches candidate "$kind" "$path" "$bytes" "$proj" \
          "regenerable ($detail) — reclaimed only by --dehydrate" \
          "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
        continue
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      plan_row caches delete "$kind" "$path" "$bytes" "$proj" "stale > ${CACHE_TTL_DAYS}d" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
    else
      plan_row caches skip "$kind" "$path" "$bytes" "$proj" "younger than ${CACHE_TTL_DAYS}d" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
    fi
  done <<EOF
$cache_rows
EOF
}

# ---------------------------------------------------------------------------
# Scope B: worktrees.
#
# Default predicate (reap_pushed_worktrees=true, Layer 2 — the flood reclaimer):
#   reap iff  is_main==0  AND  not(in_use)  AND  content_clean
#             AND  recoverable
# where recoverable = merged (gh) OR pushed (upstream on origin, tip not ahead).
# not(in_use) is a hard fail-safe gate shared by every default/legacy/tmp/safe-only
# path; missing/error/timeout from lsof is treated exactly like a live handle.
# `stale` is dropped (age is irrelevant once work is recoverable); any tracked,
# untracked, or ignored local content is a manual candidate. A content-clean but
# unrecoverable tree under /private/tmp reaps at a short TTL. dj_branch_merged
# returns 0/1/2, dj_worktree_pushed 0/1.
#
# Fallback (reap_pushed_worktrees=false): the pre-Layer-2 4-gate triad exactly
# (is_main==0 AND stale AND content-clean AND merged) — a clean opt-out.
#
# The main-checkout row carries kind `worktree-main` so the Layer 3 tripwire can
# count LINKED worktrees only (col 3 == "worktree").
# ---------------------------------------------------------------------------
# scan_worktree_ignored_content WT BYTES BRANCH FLEET PROJECT_ID CHECKOUT_ID
#   WORKTREE_ID COMMON PROJ
#
# A porcelain-clean linked worktree that holds ignored content is never reaped
# whole. Spec 069 D1 splits that content: when the tree may shed regenerable
# directories its verdict is `dehydrate` (applied only under --dehydrate);
# otherwise it stays a manual candidate that names the hold reason.
scan_worktree_ignored_content() {
  local wt_path="$1" bytes="$2" branch="$3" summary count planned held
  shift 3
  summary="$(dj_dehydrate_plan_tree "$wt_path" "$@")" || return 1
  IFS="$(printf '\t')" read -r count planned held <<EOF
$summary
EOF
  case "$count$planned" in ''|*[!0-9]*) count=0 planned=0 ;; esac
  if [ "$count" -gt 0 ]; then
    plan_row worktrees dehydrate worktree "$wt_path" "$bytes" "$5" \
      "dehydrate ($count regenerable path(s), $(dj_human_bytes "$planned")); other ignored local content kept — branch=$branch" \
      "$@"
  else
    plan_row worktrees candidate worktree "$wt_path" "$bytes" "$5" \
      "candidate (ignored local content${held:+; dehydrate held: $held}) — branch=$branch" \
      "$@"
  fi
}

scan_worktrees() {
  local proj="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5" common="$6"
  local wt_path head_sha branch is_main prunable registered_root found=0
  local bytes mtime detail verdict worktree_rows rc
  local merged_rc stale_rc pushed_rc recoverable_rc
  local real_wt is_tmp tmp_stale_rc is_detached in_use_reason
  local phantom_key phantom_known phantom_seen

  # scan_project runs this in a subshell: keep every git status below from
  # refreshing the index, whose mtime is the dehydrate idle clock.
  export GIT_OPTIONAL_LOCKS=0
  registered_root="$(dj__abspath "$proj")"
  if worktree_rows="$(dj_list_worktrees "$proj")"; then :; else
    rc=$?
    echo "disk-janitor: WARNING: worktree discovery failed for $proj (exit $rc)" >&2
    return "$rc"
  fi

  # A registry row owns exactly its recorded worktree. Do not turn one primary
  # checkout scan into a scan/deletion of every Git worktree it happens to know.
  while IFS="$(printf '\t')" read -r wt_path head_sha branch is_main prunable; do
    [ -n "$wt_path" ] || continue
    wt_path="$(dj__abspath "$wt_path")"
    [ "$wt_path" = "$registered_root" ] || continue
    found=1
    : "${head_sha:-}" "${prunable:-}"

    # Main checkout: never a reap candidate — report and move on. Kind
    # `worktree-main` keeps it out of the linked-worktree tripwire count.
    if [ "$is_main" = "1" ]; then
      bytes="$(dj_dir_bytes "$wt_path")"
      plan_row worktrees skip worktree-main "$wt_path" "$bytes" "$common" \
        "main checkout — never reaped" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      continue
    fi

    # Hard liveness gate, before every default/legacy/tmp/safe-only reap path.
    # dj_worktree_in_use also returns 0 when the lsof snapshot is unavailable,
    # failed, timed out, or malformed: a broken safety check must fail closed.
    if in_use_reason="$(dj_worktree_in_use "$wt_path" "$LSOF_SNAPSHOT_TMP")"; then
      bytes="$(dj_dir_bytes "$wt_path")"
      dj_dehydrate_plan_tree "$wt_path" "$fleet" "$project_id" "$checkout_id" \
        "$worktree_id" "$common" "$proj" >/dev/null || return 1
      plan_row worktrees candidate worktree "$wt_path" "$bytes" "$common" \
        "candidate (worktree in use) — branch=$branch $in_use_reason in-use" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      continue
    fi

    bytes="$(dj_dir_bytes "$wt_path")"
    mtime="$(dj_worktree_mtime "$wt_path")"
    # ---- Fallback: pre-Layer-2 4-gate behavior (opt-out) ----
    if [ "$REAP_PUSHED_WORKTREES" = "false" ]; then
      if ! dj_worktree_porcelain_clean "$wt_path"; then
        dj_dehydrate_plan_tree "$wt_path" "$fleet" "$project_id" "$checkout_id" \
          "$worktree_id" "$common" "$proj" >/dev/null || return 1
        plan_row worktrees skip worktree "$wt_path" "$bytes" "$common" \
          "dirty (uncommitted work) — branch=$branch" \
          "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
        continue
      fi
      if ! dj_worktree_clean "$wt_path"; then
        scan_worktree_ignored_content "$wt_path" "$bytes" "$branch" \
          "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj" || return 1
        continue
      fi
      if dj_cache_is_stale "$mtime" "$WORKTREE_STALE_DAYS" "$NOW_EPOCH"; then stale_rc=0; else stale_rc=$?; fi
      if dj_branch_merged "$proj" "$branch"; then merged_rc=0; else merged_rc=$?; fi

      detail="branch=$branch content-clean"
      case "$stale_rc" in 0) detail="$detail stale" ;; *) detail="$detail fresh" ;; esac
      case "$merged_rc" in
        0) detail="$detail merged" ;;
        2) detail="$detail merge-unverified" ;;
        *) detail="$detail unmerged" ;;
      esac

      if [ "$stale_rc" -eq 0 ] && [ "$merged_rc" -eq 0 ]; then
        verdict="delete"
      elif [ "$stale_rc" -eq 0 ] && [ "$merged_rc" -eq 2 ]; then
        verdict="candidate"
        detail="candidate (unverified merge) — $detail"
      else
        verdict="skip"
      fi
      plan_row worktrees "$verdict" worktree "$wt_path" "$bytes" "$common" "$detail" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      continue
    fi

    # ---- Default: Layer 2 content-clean + recoverable ----
    if ! dj_worktree_porcelain_clean "$wt_path"; then
      dj_dehydrate_plan_tree "$wt_path" "$fleet" "$project_id" "$checkout_id" \
        "$worktree_id" "$common" "$proj" >/dev/null || return 1
      plan_row worktrees skip worktree "$wt_path" "$bytes" "$common" \
        "dirty (uncommitted work) — branch=$branch" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      continue
    fi
    if ! dj_worktree_clean "$wt_path"; then
      scan_worktree_ignored_content "$wt_path" "$bytes" "$branch" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj" || return 1
      continue
    fi

    # Recoverable = merged (gh) OR pushed (upstream, tip not ahead).
    if dj_branch_merged "$proj" "$branch"; then merged_rc=0; else merged_rc=$?; fi
    if dj_worktree_pushed "$wt_path"; then pushed_rc=0; else pushed_rc=$?; fi
    recoverable_rc=1
    if [ "$merged_rc" -eq 0 ] || [ "$pushed_rc" -eq 0 ]; then recoverable_rc=0; fi

    detail="branch=$branch content-clean"
    case "$merged_rc" in
      0) detail="$detail merged" ;;
      2) detail="$detail merge-unverified" ;;
      *) detail="$detail unmerged" ;;
    esac
    case "$pushed_rc" in 0) detail="$detail pushed" ;; *) detail="$detail unpushed" ;; esac
    case "$recoverable_rc" in 0) detail="$detail recoverable" ;; *) detail="$detail unrecoverable" ;; esac

    if [ "$recoverable_rc" -eq 0 ]; then
      verdict="delete"
    else
      # Not recoverable. Only /private/tmp (throwaway on reboot) reaps at a
      # short TTL, and never when detached (no branch ref to fall back on).
      real_wt="$(dj__abspath "$wt_path")"
      is_tmp=1
      case "$real_wt/" in
        /private/tmp/*) is_tmp=0 ;;
      esac
      is_detached=1
      case "$branch" in ''|detached|HEAD) is_detached=0 ;; esac
      if dj_cache_is_stale "$mtime" "$EPHEMERAL_TMP_TTL_DAYS" "$NOW_EPOCH"; then tmp_stale_rc=0; else tmp_stale_rc=$?; fi
      if [ "$is_tmp" -eq 0 ] && [ "$tmp_stale_rc" -eq 0 ] && [ "$is_detached" -ne 0 ]; then
        verdict="delete"
        detail="$detail ephemeral-tmp stale>${EPHEMERAL_TMP_TTL_DAYS}d"
      else
        verdict="candidate"
        detail="candidate (not recoverable) — $detail"
      fi
    fi

    # --safe-only (the unattended nightly apply): keep a `delete` verdict ONLY
    # for a merged, non-detached tree. It only ever tightens the plan.
    if [ "$SAFE_ONLY" -eq 1 ] && [ "$verdict" = "delete" ]; then
      case "$branch" in
        ''|detached|HEAD)
          verdict="candidate"
          detail="candidate (safe-only: detached) — $detail" ;;
        *)
          if [ "${merged_rc:-1}" -ne 0 ]; then
            verdict="candidate"
            detail="candidate (safe-only: not merged) — $detail"
          fi ;;
      esac
    fi
    plan_row worktrees "$verdict" worktree "$wt_path" "$bytes" "$common" "$detail" \
      "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
  done <<EOF
$worktree_rows
EOF

  if [ "$found" -ne 1 ]; then
    echo "disk-janitor: WARNING: registry root is absent from Git worktree metadata: $proj" >&2
    return 1
  fi
  # A linked checkout can have more than one active registered current root.
  # Inspect shared Git metadata exactly once, but only after the current root
  # itself was confirmed in the list above. The entry selector below never
  # touches a present worktree; it is solely the narrow phantom-registration
  # cleanup that the normal exact-root scan deliberately excludes.
  phantom_key="$checkout_id/$common"
  phantom_seen=0
  if [ "${#PHANTOM_SCAN_KEYS[@]}" -gt 0 ]; then
    for phantom_known in "${PHANTOM_SCAN_KEYS[@]}"; do
      if [ "$phantom_known" = "$phantom_key" ]; then
        phantom_seen=1
        break
      fi
    done
  fi
  [ "$phantom_seen" -eq 0 ] || return 0
  PHANTOM_SCAN_KEYS+=("$phantom_key")

  # Preserve the documented clean opt-out exactly: this follow-up is part of
  # the newer worktree-reap behavior, not a hidden expansion of legacy mode.
  [ "$REAP_PUSHED_WORKTREES" = "false" ] && return 0

  while IFS="$(printf '\t')" read -r wt_path head_sha branch is_main prunable; do
    [ -n "$wt_path" ] || continue
    # The helper fails closed for present, symlinked, inaccessible, malformed,
    # or lexically non-canonical paths. It also resolves /tmp to /private/tmp
    # before the explicit namespace gate.
    real_wt="$(dj_phantom_worktree_absent_path "$wt_path" 2>/dev/null)" || continue
    if ! dj_phantom_worktree_reapable "$registered_root" "$real_wt"; then
      continue
    fi
    if in_use_reason="$(dj_worktree_in_use "$real_wt" "$LSOF_SNAPSHOT_TMP")"; then
      plan_row worktrees candidate worktree-phantom "$real_wt" 0 "$common" \
        "candidate (phantom registration in use) — $in_use_reason current-root=$registered_root" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
    elif [ "$SAFE_ONLY" -eq 1 ]; then
      # The unattended schedule remains merged-clean worktrees only; a phantom
      # registration requires the normal interactive --apply confirmation.
      plan_row worktrees candidate worktree-phantom "$real_wt" 0 "$common" \
        "candidate (safe-only: phantom registration requires manual apply) — current-root=$registered_root" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
    else
      plan_row worktrees delete worktree-phantom "$real_wt" 0 "$common" \
        "phantom registration (absent + prunable + ephemeral) — current-root=$registered_root" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
    fi
  done <<EOF
$worktree_rows
EOF
}


# ---------------------------------------------------------------------------
# Scope C: package stores (best-effort, host-global; report once, not per-proj).
# ---------------------------------------------------------------------------
scan_stores() {
  local plan line
  plan="$(dj_pkg_store_plan 2>/dev/null || true)"
  [ -n "$plan" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line"
  done <<EOF
$plan
EOF
}
# ---------------------------------------------------------------------------
# Scope D: release execution staging (host-global; scan exactly once).
# ---------------------------------------------------------------------------
RELEASE_STAGING_SCAN_REASON=""
RELEASE_STAGING_DELETE_COUNT=0
RELEASE_STAGING_DELETE_BYTES=0
RELEASE_STAGING_ALL_BYTES=0
RELEASE_STAGING_RECLAIMED_BYTES=0

scan_release_staging() {
  # D3 (spec 069): the release-staging matcher is `release_store_reap_tmp`
  # dry-run, covering both .verify and .exec scratch. The legacy
  # dj_find_release_staging walker is retired; dj_host_release_scan owns the
  # translation into plan rows.
  dj_host_release_scan
}

# ---------------------------------------------------------------------------
# Scope F: pi temp files and orphan pi worktrees (host-global, opt-in).
# pi-subagents creates worktrees under os.tmpdir(), so pi runs with TMPDIR at
# $HOME/.pi-worktrees (TRELLIS_HOME/pi-worktrees before 1.3.12) and its own
# process temp files, the bash spill logs among them, land there too; the
# shell commands it runs use TRELLIS_PI_TMPDIR, the system temp dir plus /pi.
# A janitor started from inside pi inherits TMPDIR=<worktree root>, so a temp
# root under a worktree root is not scanned twice.
# ---------------------------------------------------------------------------
# pi_root <root> <anchor> <rel>: print the physical path of <root> when it is a
# real directory at exactly <anchor>/<rel> (any path strictly under <anchor>
# when <rel> is empty) and no component below the anchor is a symlink: the
# logical and physical paths must agree below it. The anchor's own ancestry may
# hold links (macOS /var). A root or anchor that resolves to / or to HOME is
# refused, however it is spelled ($HOME/., $HOME//, a/../b).
pi_root() {
  local root="$1" anchor="$2" want="$3" lanchor panchor lroot proot rel phome
  case "$root" in /*) ;; *) return 1 ;; esac
  case "$anchor" in /*) ;; *) return 1 ;; esac
  lanchor="$(CDPATH='' cd -L -- "$anchor" 2>/dev/null && pwd -L)" || return 1
  panchor="$(CDPATH='' cd -P -- "$anchor" 2>/dev/null && pwd -P)" || return 1
  lroot="$(CDPATH='' cd -L -- "$root" 2>/dev/null && pwd -L)" || return 1
  proot="$(CDPATH='' cd -P -- "$root" 2>/dev/null && pwd -P)" || return 1
  phome="$(CDPATH='' cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P)" || phome=/
  [ "$panchor" != / ] || return 1
  case "$lroot" in "$lanchor"/?*) rel="${lroot#"$lanchor"/}" ;; *) return 1 ;; esac
  [ -z "$want" ] || [ "$rel" = "$want" ] || return 1
  [ "$proot" = "$panchor/$rel" ] || return 1
  case "$proot" in /|"$phome") return 1 ;; esac
  printf '%s\n' "$proot"
}

PI_SCAN_NOTES=""
PI_WORKTREE_ROOT=""
if [ -n "${HOME:-}" ]; then
  PI_WORKTREE_ROOT="$(pi_root "${HOME%/}/.pi-worktrees" "$HOME" .pi-worktrees)" ||
    { PI_WORKTREE_ROOT=""; PI_SCAN_NOTES="${PI_SCAN_NOTES}\$HOME/.pi-worktrees missing, symlinked or outside HOME; not scanned. "; }
fi
PI_LEGACY_ROOT="$(pi_root "$TRELLIS_HOME/pi-worktrees" "$TRELLIS_HOME" pi-worktrees)" || PI_LEGACY_ROOT=""
[ "$PI_LEGACY_ROOT" != "$PI_WORKTREE_ROOT" ] || PI_LEGACY_ROOT=""
# The temp root lies strictly under TMPDIR, which is never HOME or /, and
# outside both worktree roots.
PI_TEMP_ROOT=""
pi_tmp_anchor="$(CDPATH='' cd -P -- "${TMPDIR:-/}" 2>/dev/null && pwd -P)" || pi_tmp_anchor=/
if [ "$pi_tmp_anchor" != / ] &&
  [ "$pi_tmp_anchor" != "$(CDPATH='' cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P)" ]; then
  PI_TEMP_ROOT="$(pi_root "${TRELLIS_PI_TMPDIR:-${TMPDIR%/}/pi}" "$TMPDIR" "")" || PI_TEMP_ROOT=""
fi
case "$PI_TEMP_ROOT/" in
  "${PI_WORKTREE_ROOT:-/nonexistent}"/*|"${PI_LEGACY_ROOT:-/nonexistent}"/*) PI_TEMP_ROOT="" ;;
esac
# C3 spill-only roots (maxdepth 1, pi-bash-*.log only, never following
# symlinks): the worktree _pi root, bare $TMPDIR, and the per-user
# DARWIN_USER_TEMP_DIR + its pi/ subdir. DJ_DARWIN_TMPDIR_OVERRIDE names the
# Darwin dir in tests so the real per-user temp is never scanned.
PI_CENTRAL_PI_ROOT=""
if _pi_candidate="$(hy_root 2>/dev/null)/_pi"; then
  if [ -d "$_pi_candidate" ] && [ ! -L "$_pi_candidate" ] && [ -O "$_pi_candidate" ]; then
    PI_CENTRAL_PI_ROOT="$_pi_candidate"
  fi
fi
PI_BARE_TMP_ROOT=""
if [ -n "${TMPDIR:-}" ]; then
  if _tmp_real="$(CDPATH='' cd -P -- "$TMPDIR" 2>/dev/null && pwd -P)"; then
    _home_real="$(CDPATH='' cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P)" || _home_real="/nonexistent-home"
    [ -n "$_home_real" ] || _home_real="/nonexistent-home"
    if [ "$_tmp_real" != / ] && [ "$_tmp_real" != "$_home_real" ] && [ -d "$_tmp_real" ] && [ ! -L "$TMPDIR" ] && [ -O "$_tmp_real" ]; then
      case "$_tmp_real/" in "$_home_real/"*) ;; *) PI_BARE_TMP_ROOT="$_tmp_real" ;; esac
    fi
  fi
fi
PI_DARWIN_ROOT=""; PI_DARWIN_PI_ROOT=""
if [ -n "${DJ_DARWIN_TMPDIR_OVERRIDE:-}" ]; then
  _darwin_base="${DJ_DARWIN_TMPDIR_OVERRIDE}"
else
  _darwin_base="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo '')"
fi
if [ -n "$_darwin_base" ]; then
  case "$_darwin_base" in /*) ;;
    *) _darwin_base="" ;;
  esac
fi
if [ -n "$_darwin_base" ] && [ -d "$_darwin_base" ] && [ ! -L "$_darwin_base" ]; then
  _darwin_real="$(CDPATH='' cd -P -- "$_darwin_base" 2>/dev/null && pwd -P)" || _darwin_real=""
  _darwin_home_real="$(CDPATH='' cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P)" || _darwin_home_real="/nonexistent-home"
  [ -n "$_darwin_home_real" ] || _darwin_home_real="/nonexistent-home"
  if [ -n "$_darwin_real" ] && [ "$_darwin_real" != / ] && [ "$_darwin_real" != "$_darwin_home_real" ]; then
    case "$_darwin_real/" in "$_darwin_home_real/"*) _darwin_real="" ;; esac
  else
    _darwin_real=""
  fi
  if [ -n "$_darwin_real" ]; then
    PI_DARWIN_ROOT="$_darwin_real"
    if [ -d "$_darwin_real/pi" ] && [ ! -L "$_darwin_real/pi" ]; then
      PI_DARWIN_PI_ROOT="$_darwin_real/pi"
    fi
  fi
fi
PI_OWNERS=""
PI_RECLAIMABLE_BYTES=0

# pi_load_owners — (re)read the owner records; PI_OWNERS is empty when they
# cannot be read, which makes every pi entry a candidate.
pi_load_owners() {
  if dj_pi_owner_paths "$TRELLIS_HOME" "$PI_OWNER_PATHS_TMP"; then
    PI_OWNERS="$PI_OWNER_PATHS_TMP"
  else
    PI_OWNERS=""
  fi
}

scan_pi() {
  local root entry row verdict kind detail tab nl bytes _wt_pi_agent _wt_eligible
  tab="$(printf '\t')"
  nl="$(printf '\nx')"; nl="${nl%x}"
  pi_load_owners
  [ -n "$PI_OWNERS" ] || PI_SCAN_NOTES="${PI_SCAN_NOTES}attachment owner records unreadable; every entry but spill logs kept. "
  [ -n "$PI_TEMP_ROOT" ] || PI_SCAN_NOTES="${PI_SCAN_NOTES}no pi temp root (TRELLIS_PI_TMPDIR/TMPDIR unset or relative, HOME or /, outside TMPDIR, under a symlink, or inside a worktree root). "
  for root in "$PI_WORKTREE_ROOT" "$PI_LEGACY_ROOT" "$PI_TEMP_ROOT"; do
    [ -n "$root" ] || continue
    if [ ! -d "$root" ] || [ -L "$root" ] || [ ! -O "$root" ]; then
      PI_SCAN_NOTES="${PI_SCAN_NOTES}$root unavailable, symlinked or not owned by this account. "
      continue
    fi
    for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      case "$entry" in
        *"$tab"*|*"$nl"*)
          PI_SCAN_NOTES="${PI_SCAN_NOTES}an entry under $root has a tab or newline in its name; left intact. "
          continue
          ;;
      esac
      row="$(dj_pi_entry_verdict "$entry" "$PI_TMP_TTL_DAYS" "$PI_OWNERS" "$LSOF_SNAPSHOT_TMP" \
        "$PI_SPILL_TTL_DAYS" "$PI_SPILL_MAX_BYTES")"
      IFS="$tab" read -r verdict kind detail <<EOF
$row
EOF
      # C3 apply/dry-run: reclaimable spill logs become delete unless
      # pi_apply:false restores report-only.
      if { [ "$MODE" = "apply" ] || [ "$MODE" = "dry-run" ]; } && [ "$PI_APPLY" = "true" ] && [ "$kind" = "pi-spill-log" ] && [ "$verdict" = "reclaimable" ]; then
        verdict="delete"
      fi
      if [ "$PI_APPLY" != "true" ] && [ "$verdict" = "delete" ]; then
        verdict="reclaimable"
      fi
      # A9: pi-agent-* worktrees need the 7-day TTL plus clean-tree and
      # no-unique-commits gates before delete; otherwise hold. Covers both
      # reclaimable orphans and registered-but-unowned worktrees (which `git
      # worktree remove` can still remove). Non-pi-agent names stay as classified.
      case "$(basename "$entry")" in pi-agent-*) _wt_pi_agent=1 ;; *) _wt_pi_agent=0 ;; esac
      if [ "$kind" = "pi-worktree" ] && [ "$_wt_pi_agent" -eq 1 ]; then
        _wt_eligible=0
        if [ "$verdict" = "reclaimable" ]; then _wt_eligible=1; fi
        if [ "$verdict" = "skip" ]; then case "$detail" in *"registered with its parent"*) _wt_eligible=1 ;; esac; fi
        if [ "$_wt_eligible" -eq 1 ]; then
          if dj_pi_entry_fresh "$entry" "$PI_WORKTREE_TTL_DAYS"; then
            verdict="skip"
            detail="fresh — younger than ${PI_WORKTREE_TTL_DAYS}d pi-worktree TTL; held"
          elif dj_host_worktree_dirty "$entry"; then
            verdict="candidate"
            detail="candidate (dirty or untracked files); held"
          elif ! dj_host_pi_no_unique_commits "$entry"; then
            verdict="candidate"
            detail="candidate (unique commits); held"
          elif { [ "$MODE" = "apply" ] || [ "$MODE" = "dry-run" ]; } && [ "$PI_APPLY" = "true" ]; then
            verdict="delete"
            detail="orphan pi-agent worktree older than ${PI_WORKTREE_TTL_DAYS}d, clean, no unique commits"
          else
            verdict="reclaimable"
            detail="orphan pi-agent worktree older than ${PI_WORKTREE_TTL_DAYS}d, clean, no unique commits; manual removal"
          fi
        fi
      fi
      bytes="$(dj_dir_bytes "$entry")"
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      plan_row pi "$verdict" "$kind" "$entry" "$bytes" "$root" "$detail"
    done
  done
  # C3 spill-only roots: central _pi, bare TMPDIR, Darwin tmp + pi/ —
  # maxdepth 1, pi-bash-*.log only, never following symlinks.
  for root in "$PI_CENTRAL_PI_ROOT" "$PI_BARE_TMP_ROOT" "$PI_DARWIN_ROOT" "$PI_DARWIN_PI_ROOT"; do
    [ -n "$root" ] || continue
    if [ ! -d "$root" ] || [ -L "$root" ]; then continue; fi
    for entry in "$root"/pi-bash-*.log; do
      [ -f "$entry" ] && [ ! -L "$entry" ] || continue
      case "$entry" in *"$tab"*|*"$nl"*) continue ;; esac
      row="$(dj_pi_entry_verdict "$entry" "$PI_TMP_TTL_DAYS" "$PI_OWNERS" "$LSOF_SNAPSHOT_TMP" \
        "$PI_SPILL_TTL_DAYS" "$PI_SPILL_MAX_BYTES")"
      IFS="$tab" read -r verdict kind detail <<EOF
$row
EOF
      [ "$kind" = "pi-spill-log" ] || continue
      if { [ "$MODE" = "apply" ] || [ "$MODE" = "dry-run" ]; } && [ "$PI_APPLY" = "true" ] && [ "$verdict" = "reclaimable" ]; then
        verdict="delete"
      fi
      if [ "$PI_APPLY" != "true" ] && [ "$verdict" = "delete" ]; then
        verdict="reclaimable"
      fi
      bytes="$(dj_dir_bytes "$entry")"
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      plan_row pi "$verdict" "$kind" "$entry" "$bytes" "$root" "$detail"
    done
  done
}

# ---------------------------------------------------------------------------
# Scope E: Docker (host-global; scan exactly once, never inside scan_project).
# The liveness probe is deliberately only `docker info`: no `open`, Desktop
# helper, or other command that could start Docker Desktop is ever invoked.
# ---------------------------------------------------------------------------

DOCKER_LIVE=0
DOCKER_SCAN_OK=0
DOCKER_SKIP_REASON=""
DOCKER_SCAN_ERROR=""
DOCKER_SERVER_VERSION="unknown"
DOCKER_ANON_VOLUME_COUNT=0
DOCKER_ANON_DANGLING_COUNT=0
DOCKER_ANON_RECLAIMABLE_BYTES=0
DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES=0
DOCKER_IMAGE_COUNT=0
DOCKER_BUILDX_PRUNE_APPLIED=0

scan_docker() {
  local summary verbose buildx_du volume_parsed buildx_parsed listed_volume_count

  if ! command -v docker >/dev/null 2>&1; then
    DOCKER_SKIP_REASON="Docker CLI unavailable"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    DOCKER_SKIP_REASON="Docker is not live"
    return 0
  fi
  DOCKER_LIVE=1

  # Every Docker query below is guarded by the successful docker-info probe.
  if ! DOCKER_SERVER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"; then
    DOCKER_SERVER_VERSION="unavailable"
  fi
  [ -n "$DOCKER_SERVER_VERSION" ] || DOCKER_SERVER_VERSION="unavailable"

  if ! summary="$(docker system df --format json 2>/dev/null)"; then
    DOCKER_SCAN_ERROR="docker system df failed"
    EXIT_STATUS=1
    return 0
  fi
  if ! verbose="$(docker system df -v --format json 2>/dev/null)"; then
    DOCKER_SCAN_ERROR="docker system df -v failed"
    EXIT_STATUS=1
    return 0
  fi
  # Buildx prune targets the full BuildKit cache, including shared records that
  # `docker system df` excludes from its private-only reclaimable figure.
  if ! buildx_du="$(docker buildx du --format json 2>/dev/null)"; then
    DOCKER_SCAN_ERROR="docker buildx du failed"
    EXIT_STATUS=1
    return 0
  fi

  if ! DOCKER_IMAGE_COUNT="$(printf '%s\n' "$summary" | jq -rs -r \
    '[.[] | select(.Type == "Images")][0].TotalCount // "0"' 2>/dev/null)"; then
    DOCKER_SCAN_ERROR="could not parse Docker image count"
    EXIT_STATUS=1
    return 0
  fi

  # Docker reports decimal SI sizes. Count every 64-hex anonymous volume and
  # the unattached subset (Links==0). This enumeration is read-only: Links==0
  # means no container uses the volume now, not that it holds no data, so the
  # IDs are reported and never deleted.
  if ! volume_parsed="$(printf '%s\n' "$verbose" | jq -r '
    def docker_bytes:
      if test("kB$") then (sub("kB$"; "") | tonumber * 1000)
      elif test("MB$") then (sub("MB$"; "") | tonumber * 1000000)
      elif test("GB$") then (sub("GB$"; "") | tonumber * 1000000000)
      elif test("TB$") then (sub("TB$"; "") | tonumber * 1000000000000)
      elif test("B$") then (sub("B$"; "") | tonumber)
      else error("unsupported Docker size: " + .)
      end;
    [.Volumes[]? | select(.Name | test("^[a-f0-9]{64}$"))] as $anonymous |
    [$anonymous[] | select(.Links == "0")] as $dangling |
    "\($anonymous | length)\t\($dangling | length)\t\([$dangling[].Size | docker_bytes] | add // 0)"
  ' 2>/dev/null)"; then
    DOCKER_SCAN_ERROR="could not parse anonymous Docker volume usage"
    EXIT_STATUS=1
    return 0
  fi
  IFS="$(printf '\t')" read -r DOCKER_ANON_VOLUME_COUNT DOCKER_ANON_DANGLING_COUNT DOCKER_ANON_RECLAIMABLE_BYTES <<EOF
$volume_parsed
EOF
  if ! printf '%s\n' "$verbose" | jq -r '
    [.Volumes[]?
     | select((.Name? // "") | test("^[a-f0-9]{64}$"))
     | select(.Links == "0")
     | .Name]
    | unique[]
  ' >"$DOCKER_VOLUME_IDS_TMP"; then
    DOCKER_SCAN_ERROR="could not record unattached anonymous Docker volume IDs"
    EXIT_STATUS=1
    return 0
  fi
  listed_volume_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$DOCKER_VOLUME_IDS_TMP")"
  if [ "$listed_volume_count" -ne "$DOCKER_ANON_DANGLING_COUNT" ]; then
    DOCKER_SCAN_ERROR="unattached Docker volume ID list does not match scan count"
    EXIT_STATUS=1
    return 0
  fi

  if ! buildx_parsed="$(printf '%s\n' "$buildx_du" | jq -rs -r '
    def docker_bytes:
      if test("kB$") then (sub("kB$"; "") | tonumber * 1000)
      elif test("MB$") then (sub("MB$"; "") | tonumber * 1000000)
      elif test("GB$") then (sub("GB$"; "") | tonumber * 1000000000)
      elif test("TB$") then (sub("TB$"; "") | tonumber * 1000000000000)
      elif test("B$") then (sub("B$"; "") | tonumber)
      else error("unsupported BuildKit size: " + .)
      end;
    [.[] | select(.Reclaimable == true) | .Size | docker_bytes] | add // 0
  ' 2>/dev/null)"; then
    DOCKER_SCAN_ERROR="could not parse BuildKit cache usage"
    EXIT_STATUS=1
    return 0
  fi
  DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES="$buildx_parsed"

  case "$DOCKER_IMAGE_COUNT:$DOCKER_ANON_VOLUME_COUNT:$DOCKER_ANON_DANGLING_COUNT:$DOCKER_ANON_RECLAIMABLE_BYTES:$DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES" in
    *[!0-9:]*)
      DOCKER_SCAN_ERROR="Docker disk usage returned malformed numeric data"
      EXIT_STATUS=1
      return 0
      ;;
  esac
  DOCKER_SCAN_OK=1
  return 0
}

# print_docker_volumes_report_only — the anonymous-volume counts and the
# unattached IDs, shared by report, dry-run and apply. Output only: nothing in
# this script deletes a Docker volume (spec 059).
print_docker_volumes_report_only() {
  local volume_id listed=0
  printf '  anonymous volumes: %s total; %s unattached (Links == 0), %s\n' \
    "$DOCKER_ANON_VOLUME_COUNT" "$DOCKER_ANON_DANGLING_COUNT" \
    "$(dj_human_bytes "$DOCKER_ANON_RECLAIMABLE_BYTES")"
  echo "  unattached anonymous volumes, report-only — the janitor never deletes volumes (PROTOCOL §10):"
  while IFS= read -r volume_id; do
    [ -n "$volume_id" ] || continue
    printf '    %s\n' "$volume_id"
    listed=$((listed + 1))
  done <"$DOCKER_VOLUME_IDS_TMP"
  [ "$listed" -gt 0 ] || echo "    (none)"
}

# ---------------------------------------------------------------------------
# Per-project scan with failure isolation: a project that errors mid-scan is
# reported as skipped and the run continues. The body runs in a subshell so a
# non-zero return under `set -e` cannot abort the loop.
# ---------------------------------------------------------------------------
# scan_project <proj> — run the enabled scopes for one project. The body runs
# in a subshell with `set +e` so a scanner that returns non-zero mid-loop
# cannot abort the whole run (it surfaces as a per-project skip instead). A
# scope being disabled is NOT an error, so each scope is gated independently and
# the subshell ends with an explicit success — the only way it returns non-zero
# is a genuine failure inside a scanner (captured into `rc`).
scan_project() {
  local proj="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5" common="$6"
  (
    set +e
    local rc=0
    if scope_enabled caches; then
      scan_caches "$proj" "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" || rc=$?
    fi
    if scope_enabled worktrees; then
      scan_worktrees "$proj" "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" || rc=$?
    fi
    exit "$rc"
  )
}

# ---------------------------------------------------------------------------
# Run the scan over the strict local-registry fleet.
# ---------------------------------------------------------------------------
turbo_prepass
if [ "$TARGET_COUNT" -gt 0 ]; then
  while IFS="$(printf '\t')" read -r fleet project_id checkout_id worktree_id proj common; do
    # Re-read the exact owner before both filesystem probing and scanning. This
    # keeps a moved/unmounted/replaced root out of the plan without falling back
    # to a guessed discovery-root path.
    if ! dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" \
        "$checkout_id" "$worktree_id" "$common" "$proj" >/dev/null; then
      plan_row meta skip project "$proj" 0 "-" \
        "skipped: registered Git identity changed or became unavailable ($fleet/$project_id)" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      continue
    fi
    record_filesystem_for_root "$proj"
    if scan_project "$proj" "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common"; then :; else
      echo "disk-janitor: WARNING: scan failed for $proj; results are incomplete" >&2
      plan_row meta skip project "$proj" 0 "-" "skipped: scan error ($proj)" \
        "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$proj"
      EXIT_STATUS=1
    fi
  done <"$TARGETS_TMP"
fi
if scope_enabled releases; then
  scan_release_staging
fi
if scope_enabled pi; then
  scan_pi
fi
# Spec 069 lane libraries; each gates itself on the scopes it owns.
dj_dehydrate_scan
dj_host_scan

STORES_PLAN=""
if scope_enabled stores; then
  STORES_PLAN="$(scan_stores || true)"
fi

# Docker is host-global: scan it once after the fleet loop, never per project.
if scope_enabled docker; then
  scan_docker
fi

# ---------------------------------------------------------------------------
# Aggregate sizes for the report / tripwire.
# ---------------------------------------------------------------------------
sum_bytes() {
  # sum_bytes <scope> <verdict-glob> — sum col5 over matching rows.
  local scope="$1" vfilter="$2"
  awk -F'\t' -v sc="$scope" -v vf="$vfilter" '
    $1==sc && ($2==vf || vf=="*") { s += $5 }
    END { printf "%.0f", s+0 }
  ' "$PLAN_TMP"
}

CACHE_DELETE_BYTES="$(sum_bytes caches delete)"
CACHE_ALL_BYTES="$(sum_bytes caches '*')"
WT_DELETE_BYTES="$(sum_bytes worktrees delete)"
WT_CANDIDATE_BYTES="$(sum_bytes worktrees candidate)"
RELEASE_STAGING_DELETE_BYTES="$(sum_bytes releases delete)"
RELEASE_STAGING_ALL_BYTES="$(sum_bytes releases '*')"
RELEASE_STAGING_DELETE_COUNT="$(awk -F'\t' '$1=="releases" && $2=="delete" { n++ } END { print n+0 }' "$PLAN_TMP")"
PI_RECLAIMABLE_BYTES="$(sum_bytes pi reclaimable)"
# A phantom registration occupies Git metadata, not a directory, so it has
# 0 B. Apply must key on planned rows as well as reclaimable bytes.
WT_DELETE_COUNT="$(awk -F'\t' '$1=="worktrees" && $2=="delete" { n++ } END { print n+0 }' "$PLAN_TMP")"
WT_REAPED_BYTES=0
TOTAL_RECLAIM_BYTES=$((CACHE_DELETE_BYTES + WT_DELETE_BYTES + RELEASE_STAGING_DELETE_BYTES))

# Largest single cache (for the ceiling tripwire).
LARGEST_CACHE_BYTES="$(awk -F'\t' '$1=="caches" && $5>m { m=$5 } END { printf "%.0f", m+0 }' "$PLAN_TMP")"

# Layer 3 tripwire inputs: registered LINKED-worktree counts + aggregate bytes,
# grouped by checkout identity rather than a path-derived root.
WT_TRIPWIRE_STATS="$(awk -F'\t' '
  $1=="worktrees" && $3=="worktree" {
    c[$10]++
    if (!($10 in label)) label[$10] = $12
    s += $5
  }
  END {
    mx = 0; name = "-";
    for (r in c) if (c[r] > mx) { mx = c[r]; name = label[r] }
    printf "%s\t%d\t%.0f", name, mx, s+0
  }
' "$PLAN_TMP")"
WT_MAX_REPO="$(printf '%s' "$WT_TRIPWIRE_STATS" | cut -f1)"
WT_MAX_COUNT="$(printf '%s' "$WT_TRIPWIRE_STATS" | cut -f2)"
WT_TOTAL_BYTES="$(printf '%s' "$WT_TRIPWIRE_STATS" | cut -f3)"
WT_TOTAL_CEILING_BYTES=$((WORKTREE_TOTAL_GB_CEILING * 1024 * 1024 * 1024))

# Every selected root contributed a df result only after its strict registry
# identity was re-read. VOLUMES_TMP therefore contains one line per reachable
# actual filesystem and intentionally has no row for unavailable inventory.
FLOOR_BYTES=$((FREE_SPACE_FLOOR_GB * 1024 * 1024 * 1024))
CEILING_BYTES=$((CACHE_CEILING_GB * 1024 * 1024 * 1024))

# ---------------------------------------------------------------------------
# Report renderer — emits to the file descriptor passed as $1 (stdout=1 for the
# console copy, a real fd for the audit file). Same body for both so they never
# drift.
# ---------------------------------------------------------------------------
# print_pi_rows — the pi scope's plan, shared by report and dry-run.
print_pi_rows() {
  local scope verdict kind path bytes repo detail
  echo "== pi temp files and orphan pi worktrees (host-global; spill logs apply-delete when pi_apply:true; older than ${PI_TMP_TTL_DAYS}d; spill logs older than ${PI_SPILL_TTL_DAYS}d or over 1 GiB) =="
  echo "  roots: ${PI_WORKTREE_ROOT:-<none>} ${PI_LEGACY_ROOT:-<none>} ${PI_TEMP_ROOT:-<none>} ${PI_CENTRAL_PI_ROOT:-<none>} ${PI_BARE_TMP_ROOT:-<none>} ${PI_DARWIN_ROOT:-<none>} ${PI_DARWIN_PI_ROOT:-<none>}"
  [ -z "$PI_SCAN_NOTES" ] || echo "  note: $PI_SCAN_NOTES"
  while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
    [ "$scope" = "pi" ] || continue
    printf '  [%s] %s (%s) — %s: %s\n' "$verdict" "$path" "$(dj_human_bytes "$bytes")" "$kind" "$detail"
  done <"$PLAN_TMP"
  printf '  reclaimable by hand (aged pi temp files, spill logs + orphan pi worktrees): %s\n' "$(dj_human_bytes "$PI_RECLAIMABLE_BYTES")"
}

render_report() {
  local line scope verdict kind path bytes repo detail
  local fleet project_id checkout_id worktree_id common owner_root
  local filesystem volume_root free_bytes

  echo "trellis disk-janitor — disk reclaim report"
  echo "date:          $(date +%F)"
  echo "fleet:         $TRELLIS_FLEET_NAME"
  echo "worktrees:     $TARGET_COUNT strict local-registry identity/identities"
  echo "config:        enabled=$DJ_ENABLED cache_ttl_days=$CACHE_TTL_DAYS worktree_stale_days=$WORKTREE_STALE_DAYS free_space_floor_gb=$FREE_SPACE_FLOOR_GB cache_ceiling_gb=$CACHE_CEILING_GB docker_cache_keep_gb=$DOCKER_CACHE_KEEP_GB reap_pushed_worktrees=$REAP_PUSHED_WORKTREES ephemeral_tmp_ttl_days=$EPHEMERAL_TMP_TTL_DAYS worktree_count_ceiling=$WORKTREE_COUNT_CEILING worktree_total_gb_ceiling=$WORKTREE_TOTAL_GB_CEILING"
  echo "scopes:        $SCOPES$SAFE_ONLY_TAG"
  echo

  # --- recurrence pre-pass ---
  echo "== Recurrence pre-pass: turbo outputs =="
  if [ -n "$TURBO_LANDMINES" ]; then
    echo "  UNSCOPED turbo outputs found (this is the cache-blowup root cause):"
    while IFS="$(printf '\t')" read -r tname tpath; do
      [ -n "$tname" ] || continue
      echo "    - $tname: $tpath"
    done <<INNER
$TURBO_LANDMINES
INNER
    echo "  fix: $(dj_turbo_fix_hint)"
  else
    echo "  ✓ no unscoped turbo outputs across scanned projects"
  fi
  echo

  # --- tripwire status ---
  echo "== Tripwire status =="
  if [ -s "$VOLUMES_TMP" ]; then
    while IFS="$(printf '\t')" read -r filesystem volume_root free_bytes; do
      [ -n "$filesystem" ] || continue
      printf '  free space on filesystem %s (registered root %s): %s' \
        "$filesystem" "$volume_root" "$(dj_human_bytes "$free_bytes")"
      if [ "$free_bytes" -lt "$FLOOR_BYTES" ]; then
        printf '  ⚠ BELOW floor (%s)\n' "$(dj_human_bytes "$FLOOR_BYTES")"
      else
        printf '  ✓ above floor (%s)\n' "$(dj_human_bytes "$FLOOR_BYTES")"
      fi
    done <"$VOLUMES_TMP"
  else
    echo "  no available registered worktree filesystem to probe (unavailable roots were skipped)"
  fi
  printf '  largest single cache: %s' "$(dj_human_bytes "$LARGEST_CACHE_BYTES")"
  if [ "$LARGEST_CACHE_BYTES" -gt "$CEILING_BYTES" ]; then
    printf '  ⚠ OVER ceiling (%s)\n' "$(dj_human_bytes "$CEILING_BYTES")"
  else
    printf '  ✓ under ceiling (%s)\n' "$(dj_human_bytes "$CEILING_BYTES")"
  fi
  # Layer 3: linked-worktree count + aggregate footprint — fires days before the
  # free-space floor is breached (126 trees on one repo screams early).
  if scope_enabled worktrees; then
    printf '  linked worktrees (busiest checkout): %s in %s' "$WT_MAX_COUNT" "$WT_MAX_REPO"
    if [ "$WT_MAX_COUNT" -gt "$WORKTREE_COUNT_CEILING" ]; then
      printf '  ⚠ OVER ceiling (%s)\n' "$WORKTREE_COUNT_CEILING"
    else
      printf '  ✓ under ceiling (%s)\n' "$WORKTREE_COUNT_CEILING"
    fi
    printf '  linked-worktree footprint (fleet): %s' "$(dj_human_bytes "$WT_TOTAL_BYTES")"
    if [ "$WT_TOTAL_BYTES" -gt "$WT_TOTAL_CEILING_BYTES" ]; then
      printf '  ⚠ OVER ceiling (%s)\n' "$(dj_human_bytes "$WT_TOTAL_CEILING_BYTES")"
    else
      printf '  ✓ under ceiling (%s)\n' "$(dj_human_bytes "$WT_TOTAL_CEILING_BYTES")"
    fi
  fi
  echo

  # --- caches ---
  if scope_enabled caches; then
    echo "== Build caches =="
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      [ "$scope" = "caches" ] || continue
      printf '  [%s] %-11s %s (%s) — %s\n' "$verdict" "$kind" "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done <"$PLAN_TMP"
    printf '  reclaimable (stale): %s\n' "$(dj_human_bytes "$CACHE_DELETE_BYTES")"
    printf '  total cache footprint: %s\n' "$(dj_human_bytes "$CACHE_ALL_BYTES")"
    echo
  fi

  # --- worktrees ---
  if scope_enabled worktrees; then
    echo "== Worktrees =="
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      [ "$scope" = "worktrees" ] || continue
      printf '  [%s] %s (%s) — %s\n' "$verdict" "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done <"$PLAN_TMP"
    printf '  reclaimable (recoverable content-clean trees + absent ephemeral phantom registrations): %s\n' "$(dj_human_bytes "$WT_DELETE_BYTES")"
    printf '  candidates (manual review, NOT reaped): %s\n' "$(dj_human_bytes "$WT_CANDIDATE_BYTES")"
    echo
  fi
  # --- release staging --- (host-global, exact orphan cleanup only)
  if scope_enabled releases; then
    echo "== Release staging (host-global) =="
    if [ -n "$RELEASE_STAGING_SCAN_REASON" ]; then
      echo "  release staging: skipped ($RELEASE_STAGING_SCAN_REASON)"
    fi
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id common owner_root; do
      [ "$scope" = "releases" ] || continue
      printf '  [%s] %s (%s) — %s\n' "$verdict" "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done <"$PLAN_TMP"
    printf '  planned release-staging bytes (aged orphaned): %s\n' "$(dj_human_bytes "$RELEASE_STAGING_DELETE_BYTES")"
    printf '  release-staging footprint scanned: %s\n' "$(dj_human_bytes "$RELEASE_STAGING_ALL_BYTES")"
    echo
  fi
  # --- pi --- (host-global, opt-in)
  if scope_enabled pi; then
    print_pi_rows
    echo
  fi
  dj_dehydrate_render
  dj_host_render


  # --- stores --- D6 (spec 069): per-store report lives in dj_host_render
  # (called below); the legacy single-number STORES_PLAN is retained only for
  # the total line. Detailed bytes + last use print in the host section.
  if scope_enabled stores; then
    case "${STORES_PLAN:-0}" in
      ''|0|*[!0-9]*) ;;
      *)
        printf '  (stores total footprint: %s; see per-store breakdown below)\n' "$(dj_human_bytes "$STORES_PLAN")"
        ;;
    esac
  fi

  # --- Docker --- (host-global; report is read-only)
  if scope_enabled docker; then
    echo "== Docker (host-global) =="
    if [ "$DOCKER_LIVE" -ne 1 ]; then
      echo "  docker scope: skipped ($DOCKER_SKIP_REASON)"
    elif [ "$DOCKER_SCAN_OK" -ne 1 ]; then
      echo "  docker scope: unavailable ($DOCKER_SCAN_ERROR)"
    else
      printf '  Docker Engine server version: %s\n' "$DOCKER_SERVER_VERSION"
      print_docker_volumes_report_only
      printf '  BuildKit cache reclaimable: %s\n' "$(dj_human_bytes "$DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES")"
      printf '  images: %s (report-only; images are never pruned)\n' "$DOCKER_IMAGE_COUNT"
      printf '  BuildKit reserved space on apply: %sGB\n' "$DOCKER_CACHE_KEEP_GB"
    fi
    echo
  fi

  # --- skipped projects ---
  if awk -F'\t' '$1=="meta"' "$PLAN_TMP" | grep -q .; then
    echo "== Skipped projects =="
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      [ "$scope" = "meta" ] || continue
      echo "  $detail"
    done <"$PLAN_TMP"
    echo
  fi

  echo "== Total =="
  printf '  host-project reclaimable now (caches + reaped worktrees + release staging): %s\n' "$(dj_human_bytes "$TOTAL_RECLAIM_BYTES")"
  if scope_enabled docker && [ "$DOCKER_SCAN_OK" -eq 1 ]; then
    printf '  Docker VM (separate; not included above): BuildKit cache %s reclaimable; %s unattached anonymous volume(s), %s, report-only\n' \
      "$(dj_human_bytes "$DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES")" \
      "$DOCKER_ANON_DANGLING_COUNT" "$(dj_human_bytes "$DOCKER_ANON_RECLAIMABLE_BYTES")"
  fi
  # D7 coverage: unattributed = df used − scanned bytes (GiB and %).
  # Scanned = caches + worktrees + releases + stores + pi + logs + tmp plan
  # bytes (all validated numerics; awk sums treat text as 0, bash arithmetic
  # below runs only on validated uints).
  {
    _cov_pi="$(sum_bytes pi '*')"; case "$_cov_pi" in ''|*[!0-9]*) _cov_pi=0 ;; esac
    _cov_logs="$(sum_bytes logs '*')"; case "$_cov_logs" in ''|*[!0-9]*) _cov_logs=0 ;; esac
    _cov_tmp="$(sum_bytes tmp '*')"; case "$_cov_tmp" in ''|*[!0-9]*) _cov_tmp=0 ;; esac
    _cov_stores="${STORES_PLAN:-0}"; case "$_cov_stores" in ''|*[!0-9]*) _cov_stores=0 ;; esac
    _cov_cache="${CACHE_ALL_BYTES:-0}"; case "$_cov_cache" in ''|*[!0-9]*) _cov_cache=0 ;; esac
    _cov_wt="${WT_TOTAL_BYTES:-0}"; case "$_cov_wt" in ''|*[!0-9]*) _cov_wt=0 ;; esac
    _cov_rel="${RELEASE_STAGING_ALL_BYTES:-0}"; case "$_cov_rel" in ''|*[!0-9]*) _cov_rel=0 ;; esac
    _cov_scanned=$(( _cov_cache + _cov_wt + _cov_rel + _cov_stores + _cov_pi + _cov_logs + _cov_tmp ))
    _cov_used="$(df -k "$TRELLIS_HOME" 2>/dev/null | awk 'NR==2 {print $3*1024}')"
    case "$_cov_used" in ''|*[!0-9]*) _cov_used=0 ;; esac
    if [ "$_cov_used" -gt 0 ] && [ "$_cov_scanned" -ge 0 ] 2>/dev/null; then
      if [ "$_cov_scanned" -gt "$_cov_used" ] 2>/dev/null; then _cov_unattr=0; else _cov_unattr=$(( _cov_used - _cov_scanned )); fi
      _cov_pct_tenths=$(( _cov_unattr * 1000 / _cov_used ))
      _cov_pct_int=$(( _cov_pct_tenths / 10 )); _cov_pct_frac=$(( _cov_pct_tenths % 10 ))
      printf '  unattributed = df used − scanned bytes: %s (%d.%d%% of df used)\n' "$(dj_human_bytes "$_cov_unattr")" "$_cov_pct_int" "$_cov_pct_frac"
    else
      echo "  unattributed: unavailable (df used unreadable)"
    fi
  } 2>/dev/null || echo "  unattributed: unavailable (coverage probe failed)"
}

# ---------------------------------------------------------------------------
# Report mode (default): print to stdout AND write the audit file.
# ---------------------------------------------------------------------------
if [ "$MODE" = "report" ]; then
  AUDIT_DIR="$CANON/audits"
  AUDIT_FILE="$AUDIT_DIR/$(date +%F)-disk-janitor.md"
  render_report
  if mkdir -p "$AUDIT_DIR" 2>/dev/null; then
    {
      echo "# Disk janitor — $(date +%F)"
      echo
      echo '```'
      render_report
      echo '```'
    } >"$AUDIT_FILE" 2>/dev/null \
      && echo "audit written: $AUDIT_FILE" \
      || echo "disk-janitor: could not write audit file at $AUDIT_FILE" >&2
  else
    echo "disk-janitor: could not create audit dir $AUDIT_DIR" >&2
  fi
  exit "$(final_exit_status)"
fi

# ---------------------------------------------------------------------------
# Dry-run: print the exact deletion plan only. Mutate nothing.
# ---------------------------------------------------------------------------
if [ "$MODE" = "dry-run" ]; then
  echo "trellis disk-janitor — DRY RUN (deletion plan; nothing is removed)"
  echo "fleet:         $TRELLIS_FLEET_NAME"
  echo "scopes:        $SCOPES$SAFE_ONLY_TAG"
  echo
  if scope_enabled caches; then
    echo "== Caches to delete (stale > ${CACHE_TTL_DAYS}d) =="
    awk -F'\t' '$1=="caches" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      printf '  descriptor-relative remove  %s  (%s, %s) — %s\n' "$path" "$kind" "$(dj_human_bytes "$bytes")" "$detail"
    done
    printf '  -> %s reclaimable\n' "$(dj_human_bytes "$CACHE_DELETE_BYTES")"
    echo
  fi
  if scope_enabled worktrees; then
    echo "== Worktrees to reap (recoverable content-clean trees OR exact absent/prunable ephemeral registrations) =="
    awk -F'\t' '$1=="worktrees" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      printf '  git worktree remove  %s  (%s) — gates: %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
    printf '  -> %s reclaimable\n' "$(dj_human_bytes "$WT_DELETE_BYTES")"
    echo "  candidates (manual review) — reported, NOT reaped:"
    awk -F'\t' '$1=="worktrees" && $2=="candidate"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      printf '    %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
    echo
  fi
  if scope_enabled releases; then
    echo "== Release staging to delete (aged orphaned snapshots; host-global) =="
    if [ -n "$RELEASE_STAGING_SCAN_REASON" ]; then
      echo "  release staging: skipped ($RELEASE_STAGING_SCAN_REASON)"
    fi
    awk -F'\t' '$1=="releases" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id common owner_root; do
      printf '  descriptor-relative remove  %s  (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
    printf '  -> %s planned release-staging bytes\n' "$(dj_human_bytes "$RELEASE_STAGING_DELETE_BYTES")"
    echo "  skipped (fresh, live-owner, or malformed-owner staging) — never deleted:"
    awk -F'\t' '$1=="releases" && $2!="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id common owner_root; do
      printf '    %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
    echo
  fi
  if scope_enabled pi; then
    print_pi_rows
    echo
  fi
  dj_dehydrate_render
  dj_host_render

  if scope_enabled docker; then
    echo "== Docker prune plan (host-global) =="
    if [ "$DOCKER_LIVE" -ne 1 ]; then
      echo "  docker scope: skipped ($DOCKER_SKIP_REASON)"
    elif [ "$DOCKER_SCAN_OK" -ne 1 ]; then
      echo "  docker scope: unavailable ($DOCKER_SCAN_ERROR)"
    else
      printf '  Docker Engine server version: %s\n' "$DOCKER_SERVER_VERSION"
      print_docker_volumes_report_only
      printf '  BuildKit cache prune: docker buildx prune -f --reserved-space %sGB — %s currently reclaimable\n' \
        "$DOCKER_CACHE_KEEP_GB" "$(dj_human_bytes "$DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES")"
      printf '  images: %s (never pruned)\n' "$DOCKER_IMAGE_COUNT"
    fi
    echo
  fi
  echo "== Planned totals =="
  printf '  host-project plan: %s\n' "$(dj_human_bytes "$TOTAL_RECLAIM_BYTES")"
  if scope_enabled releases; then
    printf '  release-staging plan (aged orphaned snapshots): %s\n' "$(dj_human_bytes "$RELEASE_STAGING_DELETE_BYTES")"
  fi
  if scope_enabled docker && [ "$DOCKER_SCAN_OK" -eq 1 ]; then
    printf '  Docker VM plan (separate; not included above): BuildKit cache %s reclaimable, retaining %sGB; %s unattached anonymous volume(s) report-only\n' \
      "$(dj_human_bytes "$DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES")" "$DOCKER_CACHE_KEEP_GB" \
      "$DOCKER_ANON_DANGLING_COUNT"
  fi
  echo
  echo "(dry-run: re-run with --apply to act; --apply confirms per category)"
  exit "$(final_exit_status)"
fi

# ---------------------------------------------------------------------------
# Apply: print the plan, then per category confirm (y/N from stdin unless
# --yes), then call the OWNED deletion funcs. Re-scan + report reclaimed bytes.
# ---------------------------------------------------------------------------

# Apply-time checks are intentionally repeated after the human confirmation:
# plan output is advisory; only a freshly verified owner and current worktree
# state may reach a mutator.
DJ_REVALIDATE_REASON=""

revalidate_cache_for_apply() {
  local fleet="$1" project_id="$2" checkout_id="$3" worktree_id="$4"
  local common="$5" root="$6" path="$7" mtime
  DJ_REVALIDATE_REASON=""
  if ! dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" \
      "$checkout_id" "$worktree_id" "$common" "$root" >/dev/null; then
    DJ_REVALIDATE_REASON="registry ownership changed or is unavailable"
    return 1
  fi
  if ! dj_cache_entry_owned_by_worktree "$root" "$path"; then
    DJ_REVALIDATE_REASON="cache no longer belongs to its registered worktree"
    return 1
  fi
  if dj_build_active "$root"; then
    DJ_REVALIDATE_REASON="build is now running"
    return 1
  fi
  mtime="$(dj_mtime "$path")"
  if ! dj_cache_is_stale "$mtime" "$CACHE_TTL_DAYS" "$(date +%s)"; then
    DJ_REVALIDATE_REASON="cache is no longer stale"
    return 1
  fi
  return 0
}
# D3 (spec 069): release-staging revalidation lives in `release_store_reap_tmp
# fix`, which re-classifies just before removing. The legacy per-row
# revalidator is retired with the old matcher.

revalidate_worktree_for_apply() {
  local fleet="$1" project_id="$2" checkout_id="$3" worktree_id="$4"
  local common="$5" root="$6" worktree_rows wt_path head_sha branch is_main prunable
  local target_branch="" target_is_main="" found=0
  local mtime merged_rc pushed_rc recoverable_rc in_use_reason
  local real_wt is_tmp tmp_stale_rc is_detached
  DJ_REVALIDATE_REASON=""

  if ! dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" \
      "$checkout_id" "$worktree_id" "$common" "$root" >/dev/null; then
    DJ_REVALIDATE_REASON="registry ownership changed or is unavailable"
    return 1
  fi
  if worktree_rows="$(dj_list_worktrees "$root")"; then :; else
    DJ_REVALIDATE_REASON="Git worktree metadata cannot be read"
    return 1
  fi
  while IFS="$(printf '\t')" read -r wt_path head_sha branch is_main prunable; do
    [ -n "$wt_path" ] || continue
    [ "$(dj__abspath "$wt_path")" = "$root" ] || continue
    found=$((found + 1))
    target_branch="$branch"
    target_is_main="$is_main"
  done <<EOF
$worktree_rows
EOF
  if [ "$found" -ne 1 ] || [ "$target_is_main" = "1" ]; then
    DJ_REVALIDATE_REASON="registered root is no longer one linked Git worktree"
    return 1
  fi
  if dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5; then :; else :; fi
  if in_use_reason="$(dj_worktree_in_use "$root" "$LSOF_SNAPSHOT_TMP")"; then
    DJ_REVALIDATE_REASON="worktree is in use ($in_use_reason)"
    return 1
  fi
  if ! dj_worktree_clean "$root"; then
    DJ_REVALIDATE_REASON="worktree has tracked, untracked, or ignored local content"
    return 1
  fi

  if [ "$REAP_PUSHED_WORKTREES" = "false" ]; then
    mtime="$(dj_worktree_mtime "$root")"
    if ! dj_cache_is_stale "$mtime" "$WORKTREE_STALE_DAYS" "$(date +%s)" ||
       ! dj_worktree_clean "$root"; then
      DJ_REVALIDATE_REASON="legacy stale-and-clean gate no longer holds"
      return 1
    fi
    if dj_branch_merged "$root" "$target_branch"; then :; else
      DJ_REVALIDATE_REASON="branch is no longer verified merged"
      return 1
    fi
    return 0
  fi

  if dj_branch_merged "$root" "$target_branch"; then merged_rc=0; else merged_rc=$?; fi
  if dj_worktree_pushed "$root"; then pushed_rc=0; else pushed_rc=$?; fi
  recoverable_rc=1
  if [ "$merged_rc" -eq 0 ] || [ "$pushed_rc" -eq 0 ]; then recoverable_rc=0; fi
  if [ "$recoverable_rc" -ne 0 ]; then
    real_wt="$(dj__abspath "$root")"
    is_tmp=1
    case "$real_wt/" in /private/tmp/*) is_tmp=0 ;; esac
    is_detached=1
    case "$target_branch" in ''|detached|HEAD) is_detached=0 ;; esac
    mtime="$(dj_worktree_mtime "$root")"
    if dj_cache_is_stale "$mtime" "$EPHEMERAL_TMP_TTL_DAYS" "$(date +%s)"; then tmp_stale_rc=0; else tmp_stale_rc=$?; fi
    if [ "$is_tmp" -ne 0 ] || [ "$is_detached" -eq 0 ] || [ "$tmp_stale_rc" -ne 0 ]; then
      DJ_REVALIDATE_REASON="worktree is no longer recoverable or eligible ephemeral tmp"
      return 1
    fi
  fi
  if [ "$SAFE_ONLY" -eq 1 ]; then
    case "$target_branch" in
      ''|detached|HEAD)
        DJ_REVALIDATE_REASON="safe-only rejects detached worktrees"
        return 1
        ;;
    esac
    if [ "$merged_rc" -ne 0 ]; then
      DJ_REVALIDATE_REASON="safe-only requires a verified merged branch"
      return 1
    fi
  fi
  return 0
}

# A phantom's target is deliberately absent and therefore cannot carry a
# registry row of its own. Its authorizing identity is the live current root
# that exposed the exact Git registration. Recheck that owner, the narrow
# absent/prunable/ephemeral predicate, and liveness after confirmation.
revalidate_phantom_worktree_for_apply() {
  local fleet="$1" project_id="$2" checkout_id="$3" worktree_id="$4"
  local common="$5" current_root="$6" phantom_root="$7" in_use_reason
  DJ_REVALIDATE_REASON=""

  if ! dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" \
      "$checkout_id" "$worktree_id" "$common" "$current_root" >/dev/null; then
    DJ_REVALIDATE_REASON="current registry ownership changed or is unavailable"
    return 1
  fi
  if ! dj_phantom_worktree_reapable "$current_root" "$phantom_root"; then
    DJ_REVALIDATE_REASON="phantom registration is no longer absent, prunable, and ephemeral"
    return 1
  fi
  if dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5; then :; else :; fi
  if in_use_reason="$(dj_worktree_in_use "$phantom_root" "$LSOF_SNAPSHOT_TMP")"; then
    DJ_REVALIDATE_REASON="phantom worktree is in use ($in_use_reason)"
    return 1
  fi
  return 0
}

# confirm_category <human-label> — return 0 to proceed, 1 to decline. With
# --yes always proceeds. Reads ONE y/N line; EOF or non-y declines (the
# destructive default is N). Guards the read under set -e and set -u.
confirm_category() {
  local label="$1" reply=""
  if [ "$ASSUME_YES" -eq 1 ]; then
    echo "  (--yes) proceeding with $label"
    return 0
  fi
  printf 'Delete %s? [y/N] ' "$label"
  if IFS= read -r reply; then :; else reply=""; fi
  case "${reply:-}" in
    y|Y|yes|YES) return 0 ;;
    *) echo "  declined — $label left untouched"; return 1 ;;
  esac
}

echo "trellis disk-janitor — APPLY"
echo "fleet:         $TRELLIS_FLEET_NAME"
echo "scopes:        $SCOPES$SAFE_ONLY_TAG"
echo

# --- caches ---
if scope_enabled caches; then
  echo "== Caches to delete (stale > ${CACHE_TTL_DAYS}d), $(dj_human_bytes "$CACHE_DELETE_BYTES") =="
  awk -F'\t' '$1=="caches" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
    printf '  %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
  done
  if [ "$CACHE_DELETE_BYTES" -gt 0 ] && confirm_category "these build caches"; then
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      [ "$scope" = "caches" ] && [ "$verdict" = "delete" ] || continue
      if ! revalidate_cache_for_apply "$fleet" "$project_id" "$checkout_id" "$worktree_id" \
          "$common" "$owner_root" "$path"; then
        echo "  skipped (plan changed): $path — $DJ_REVALIDATE_REASON"
        continue
      fi
      if dj_prune_cache_entry "$TRELLIS_HOME" "$fleet" "$project_id" "$checkout_id" \
          "$worktree_id" "$common" "$owner_root" "$path"; then
        echo "  removed: $path"
      else
        echo "  REFUSED/failed: $path (registry guard rejected or rm error)" >&2
        EXIT_STATUS=1
      fi
    done <"$PLAN_TMP"
  fi
  echo
fi

# --- worktrees --- (only verdict==delete; candidate/unverified is excluded)
if scope_enabled worktrees; then
  echo "== Worktrees to reap (recoverable content-clean worktrees + exact phantom registrations), $(dj_human_bytes "$WT_DELETE_BYTES") =="
  awk -F'\t' '$1=="worktrees" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
    printf '  %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
  done
  if [ "$WT_DELETE_COUNT" -gt 0 ] && confirm_category "these recoverable + content-clean worktrees and phantom registrations"; then
    # shellcheck disable=SC2034  # This is the one loop that never expands $repo; the name
    # still has to be read to consume the TSV column positionally.
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail fleet project_id checkout_id worktree_id common owner_root; do
      [ "$scope" = "worktrees" ] && [ "$verdict" = "delete" ] || continue
      case "$kind" in
        worktree-phantom)
          if ! revalidate_phantom_worktree_for_apply "$fleet" "$project_id" "$checkout_id" \
              "$worktree_id" "$common" "$owner_root" "$path"; then
            echo "  skipped (plan changed): $path — $DJ_REVALIDATE_REASON"
          elif dj_reap_phantom_worktree "$TRELLIS_HOME" "$fleet" "$project_id" "$checkout_id" \
              "$worktree_id" "$common" "$owner_root" "$path" "$LSOF_SNAPSHOT_TMP"; then
            echo "  reaped: $path"
            WT_REAPED_BYTES=$((WT_REAPED_BYTES + bytes))
          else
            echo "  REFUSED/failed: $path (registry guard rejected or Git error)" >&2
            EXIT_STATUS=1
          fi
          ;;
        worktree)
          if ! revalidate_worktree_for_apply "$fleet" "$project_id" "$checkout_id" "$worktree_id" \
              "$common" "$owner_root"; then
            echo "  skipped (plan changed): $path — $DJ_REVALIDATE_REASON"
          elif dj_reap_worktree "$TRELLIS_HOME" "$fleet" "$project_id" "$checkout_id" \
              "$worktree_id" "$common" "$owner_root"; then
            echo "  reaped: $path"
            WT_REAPED_BYTES=$((WT_REAPED_BYTES + bytes))
          else
            echo "  REFUSED/failed: $path (registry guard rejected or Git error)" >&2
            EXIT_STATUS=1
          fi
          ;;
        *)
          echo "  REFUSED/failed: $path (unexpected worktree plan kind: $kind)" >&2
          EXIT_STATUS=1
          ;;
      esac
    done <"$PLAN_TMP"
  fi
  echo
fi
# --- release staging --- host-global; D3 delegates removal to reap-tmp fix.
if scope_enabled releases; then
  echo "== Release staging to delete (aged orphaned snapshots via reap-tmp), $(dj_human_bytes "$RELEASE_STAGING_DELETE_BYTES") =="
  # shellcheck disable=SC2034  # plan identity columns are consumed positionally; only path/bytes/detail render here.
  awk -F'\t' '$1=="releases" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail release_device release_inode checkout_id worktree_id common owner_root; do
    printf '  %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
  done
  if [ "$RELEASE_STAGING_DELETE_COUNT" -gt 0 ]; then
    dj_host_release_apply
  fi
  echo
fi
# --- stores --- D6 (spec 069): prune lives in dj_host_store_apply (called via
# dj_host_apply below), using each tool's own prune command, never rm.

# --- Docker --- host-global; --safe-only does not change Docker behavior.
if scope_enabled docker; then
  echo "== Docker prune plan (host-global) =="
  if [ "$DOCKER_LIVE" -ne 1 ]; then
    echo "  docker scope: skipped ($DOCKER_SKIP_REASON)"
  elif [ "$DOCKER_SCAN_OK" -ne 1 ]; then
    echo "  docker scope: unavailable ($DOCKER_SCAN_ERROR)"
  else
    printf '  Docker Engine server version: %s\n' "$DOCKER_SERVER_VERSION"
    print_docker_volumes_report_only
    printf '  BuildKit cache prune: %s currently reclaimable; retain %sGB with --reserved-space\n' \
      "$(dj_human_bytes "$DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES")" "$DOCKER_CACHE_KEEP_GB"
    printf '  images: %s (never pruned)\n' "$DOCKER_IMAGE_COUNT"
    if confirm_category "BuildKit cache (docker buildx prune, retaining ${DOCKER_CACHE_KEEP_GB}GB)"; then
      if ! docker info >/dev/null 2>&1; then
        echo "  docker scope: skipped (Docker is no longer live; no prune performed)"
      else
        # BuildKit has no stable per-record delete API. Its scope remains the
        # explicitly confirmed cache class, bounded by the retained-space floor.
        if docker buildx prune -f --reserved-space "${DOCKER_CACHE_KEEP_GB}GB"; then
          DOCKER_BUILDX_PRUNE_APPLIED=1
        else
          echo "  BuildKit cache prune failed" >&2
          EXIT_STATUS=1
        fi
      fi
    fi
  fi
  echo
fi

dj_dehydrate_apply
dj_host_apply

# Re-scan caches post-delete to report the actually-reclaimed bytes.
remaining_cache_bytes=0
if scope_enabled caches && [ "$TARGET_COUNT" -gt 0 ]; then
  while IFS="$(printf '\t')" read -r fleet project_id checkout_id worktree_id proj common; do
    if ! dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" \
        "$checkout_id" "$worktree_id" "$common" "$proj" >/dev/null; then
      continue
    fi
    if remaining_cache_rows="$(dj_find_caches "$proj")"; then
      while IFS="$(printf '\t')" read -r kind path bytes mtime; do
        [ -n "${path:-}" ] || continue
        dj_cache_entry_owned_by_worktree "$proj" "$path" || continue
        remaining_cache_bytes=$((remaining_cache_bytes + bytes))
      done <<EOF
$remaining_cache_rows
EOF
    else
      rc=$?
      echo "disk-janitor: WARNING: post-apply cache discovery failed for $proj (exit $rc)" >&2
      EXIT_STATUS=1
    fi
  done <"$TARGETS_TMP"
fi

RECLAIMED=$((CACHE_ALL_BYTES - remaining_cache_bytes))
if [ "$RECLAIMED" -lt 0 ]; then RECLAIMED=0; fi
echo "== Reclaimed =="
if scope_enabled caches; then
  printf '  caches: %s freed (was %s, now %s)\n' \
    "$(dj_human_bytes "$RECLAIMED")" "$(dj_human_bytes "$CACHE_ALL_BYTES")" "$(dj_human_bytes "$remaining_cache_bytes")"
fi
if scope_enabled worktrees; then
  printf '  worktrees: %s reaped\n' "$(dj_human_bytes "$WT_REAPED_BYTES")"
fi
if scope_enabled releases; then
  printf '  release staging: actual reclaimed %s (planned %s)\n' \
    "$(dj_human_bytes "$RELEASE_STAGING_RECLAIMED_BYTES")" \
    "$(dj_human_bytes "$RELEASE_STAGING_DELETE_BYTES")"
fi
if scope_enabled docker; then
  if [ "$DOCKER_SCAN_OK" -eq 1 ]; then
    printf '  Docker VM (separate from host-project bytes): BuildKit cache %s reclaimable before prune, retaining %sGB; %s unattached anonymous volume(s) left in place (report-only)\n' \
      "$(dj_human_bytes "$DOCKER_BUILD_CACHE_RECLAIMABLE_BYTES")" "$DOCKER_CACHE_KEEP_GB" \
      "$DOCKER_ANON_DANGLING_COUNT"
    printf '  Docker prune commands completed: buildkit=%s\n' "$DOCKER_BUILDX_PRUNE_APPLIED"
  elif [ "$DOCKER_LIVE" -ne 1 ]; then
    echo "  Docker VM: no plan (Docker was not live)"
  else
    echo "  Docker VM: not included (scan unavailable)"
  fi
fi

exit "$(final_exit_status)"
