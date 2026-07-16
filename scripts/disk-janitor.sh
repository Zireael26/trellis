#!/usr/bin/env bash
# trellis disk-janitor — report-first reclaim of build caches, dead worktrees,
# and package stores across the active fleet.
#
# Three modes, escalating in destructiveness:
#   --report (default)  Scan every scope, print a human report to stdout AND
#                       write audits/YYYY-MM-DD-disk-janitor.md. Includes the
#                       turbo-outputs recurrence pre-pass (the 148 GB/2 days
#                       root cause) and the tripwire status (free space vs
#                       floor, largest cache vs ceiling). DELETES NOTHING and
#                       never modifies a working tree. This is the ONLY mode
#                       launchd runs.
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
#                       reclaimed bytes. launchd NEVER runs --apply.
#
# Worktree reap (default, reap_pushed_worktrees=true) is gated on: is_main==0
# AND porcelain-clean (no uncommitted work) AND recoverable (branch merged via
# gh OR pushed to origin with the tip not ahead) AND no gitignored secret. A
# gitignored secret, or a clean-but-unrecoverable tree, is reported as a manual
# candidate and EXCLUDED from apply. A porcelain-clean unrecoverable tree under
# /private/tmp reaps at a short TTL (ephemeral_tmp_ttl_days). Setting
# reap_pushed_worktrees=false restores the pre-Layer-2 4-gate triad (is_main==0
# AND stale AND clean(allowlist) AND merged) verbatim.
#
# Per-project failure isolation: a project that errors mid-scan is reported as
# `skipped: <reason>` and the run continues.
#
# Exit codes: 0 success, 1 scan/prune error, 2 bad args.
#
# bash 3.2 compatible: no [[ ]], no declare -A, no mapfile, no ${x,,}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/blacklist-parser.sh
. "$SCRIPT_DIR/lib/blacklist-parser.sh"
# shellcheck source=lib/sed-portable.sh
. "$SCRIPT_DIR/lib/sed-portable.sh"
# shellcheck source=lib/disk-janitor-lib.sh
. "$SCRIPT_DIR/lib/disk-janitor-lib.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
MODE="report"            # report | dry-run | apply
ONLY_PROJECT=""
SCOPES="caches,worktrees,stores"
ASSUME_YES=0
SAFE_ONLY=0              # --safe-only: unattended-safe worktree reap (merged-only)

print_help() {
  cat <<'EOF'
trellis disk-janitor — reclaim build caches, dead worktrees, package stores

Usage:
  disk-janitor.sh                          Report (read-only). Default mode.
  disk-janitor.sh --report                 Same as no flag: scan + write audit.
  disk-janitor.sh --dry-run                Print the exact deletion plan only.
  disk-janitor.sh --apply                  Apply, confirming per category (y/N).
  disk-janitor.sh --apply --yes            Apply without the per-category prompt.
  disk-janitor.sh --apply --yes --safe-only
                                           Unattended-safe reap (the nightly
                                           LaunchAgent): only merged, clean,
                                           non-detached, non-secret worktrees.
  disk-janitor.sh --project NAME           Limit to one registry project.
  disk-janitor.sh --scopes caches,worktrees,stores
                                           Limit scopes (default: all three).
  disk-janitor.sh --help                   Show this help.

Modes (escalating):
  --report   Scans every scope, prints a report AND writes
             audits/YYYY-MM-DD-disk-janitor.md. Includes the turbo-outputs
             recurrence pre-pass + the disk tripwire (free vs floor, largest
             cache vs ceiling). Deletes nothing. The ONLY mode launchd runs.
  --dry-run  Prints the deletion plan (path, size, why-safe; worktrees show
             the reap verdict). Deletes nothing.
  --apply    Prints the plan, then per category reads a y/N line from stdin
             before deleting (mandatory unless --yes). Re-scans, reports
             reclaimed bytes.

Merge detection uses a read-only `gh pr list` query (a merged PR for the
branch); it modifies no git refs and deletes nothing, so report/dry-run stay
non-destructive. A worktree whose merge can't be verified (no gh, detached
HEAD) is reported as a candidate and never reaped.

--safe-only tightens the worktree reap for unattended use (the nightly apply
LaunchAgent): a `delete` verdict survives ONLY for a merged, porcelain-clean,
non-detached, non-secret tree. A merged PR means the unit is done, so no live
agent is working in the tree — the worktree scan has no live-process guard, so
"merged" is what carries the concurrency guarantee. Every other auto-delete
(pushed-but-unmerged, ephemeral /private/tmp) is downgraded to a manual
candidate; those are in-flight trees owned by the fan-out recipe teardown. The
flag only ever tightens the plan, so `--dry-run --safe-only` previews exactly
what the nightly would reap.

Scopes:
  caches      .turbo/cache, .next/cache, .next/dev older than cache_ttl_days,
              skipped when a build is running.
  worktrees   linked git worktrees that are non-main AND porcelain-clean AND
              recoverable (branch merged OR pushed to origin) AND free of any
              gitignored secret. Clean-but-unrecoverable trees and secret-bearing
              trees are reported as candidates, never reaped (see also the
              /private/tmp short-TTL path). reap_pushed_worktrees=false restores
              the legacy stale+clean+merged gate.
  stores      pnpm store / npm cache footprint — REPORT-ONLY (best-effort
              estimate; --apply does not prune stores in this release).

Exit codes: 0 success, 1 scan/prune error, 2 bad arguments.
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
      caches|worktrees|stores) ;;
      "") ;;
      *)
        IFS="$ifs_save"
        echo "disk-janitor: unknown scope: $s (valid: caches, worktrees, stores)" >&2
        exit 2
        ;;
    esac
  done
  IFS="$ifs_save"
}
validate_scopes

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
WORKTREE_STALE_DAYS="$(cfg_num '.disk_janitor.worktree_stale_days' 30)"
FREE_SPACE_FLOOR_GB="$(cfg_num '.disk_janitor.free_space_floor_gb' 30)"
CACHE_CEILING_GB="$(cfg_num '.disk_janitor.cache_ceiling_gb' 20)"
# Layer 2/3 (worktree lifecycle reap). reap_pushed_worktrees is a boolean via
# cfg_bool (so an explicit false is honored); the rest are numeric via cfg_num.
# All default-safe: an absent disk_janitor object still yields the documented
# defaults (reap_pushed_worktrees true; ephemeral_tmp_ttl_days 2; ceilings 25/80).
REAP_PUSHED_WORKTREES="$(cfg_bool '.disk_janitor.reap_pushed_worktrees' true)"
EPHEMERAL_TMP_TTL_DAYS="$(cfg_num '.disk_janitor.ephemeral_tmp_ttl_days' 2)"
WORKTREE_COUNT_CEILING="$(cfg_num '.disk_janitor.worktree_count_ceiling' 25)"
WORKTREE_TOTAL_GB_CEILING="$(cfg_num '.disk_janitor.worktree_total_gb_ceiling' 80)"

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

CANON="$TRELLIS_ROOT"
REGISTRY="$CANON/registry.md"
BLACKLIST="$CANON/blacklist.md"

# ---------------------------------------------------------------------------
# Registry parsing plus the shared blacklist parser. Active set =
# registry rows MINUS both blacklist sections MINUS disk_janitor.skip_projects,
# intersected with [ -e "$proj/.git" ].
# ---------------------------------------------------------------------------

# Registry: rows under `## Active projects`, Project column is col 1.
read_registry_names() {
  [ -f "$REGISTRY" ] || return 0
  awk '
    /^## Active projects/ { in_table=1; next }
    /^---$/ && in_table { in_table=0 }
    in_table && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0
      gsub(/^\| /, "", name); gsub(/ \|.*$/, "", name)
      if (name == "Project" || name ~ /^-+$/) next
      print name
    }
  ' "$REGISTRY"
}

# Resolve a registry name to an absolute project dir under PROJECTS_ROOT.
resolve_project_path() {
  printf '%s/%s' "$PROJECTS_ROOT" "$1"
}

REGISTRY_NAMES=()
while IFS= read -r line; do
  [ -n "$line" ] && REGISTRY_NAMES+=("$line")
done < <(read_registry_names)

BLACKLIST_NAMES=()
while IFS= read -r line; do
  [ -n "$line" ] && BLACKLIST_NAMES+=("$line")
done < <(read_blacklist_names "$BLACKLIST")

is_blacklisted() {
  local name="$1" b
  [ "${#BLACKLIST_NAMES[@]}" -eq 0 ] && return 1
  for b in "${BLACKLIST_NAMES[@]}"; do
    [ "$b" = "$name" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Target list (registry minus blacklist minus skip_projects, or single --project).
# --project validates against REGISTRY_NAMES (mirrors doctor).
# ---------------------------------------------------------------------------
TARGETS=()
if [ -n "$ONLY_PROJECT" ]; then
  found=0
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      [ "$n" = "$ONLY_PROJECT" ] && found=1
    done
  fi
  if [ "$found" -eq 0 ]; then
    echo "disk-janitor: --project '$ONLY_PROJECT' is not in registry.md" >&2
    exit 2
  fi
  if is_blacklisted "$ONLY_PROJECT"; then
    echo "  (note: '$ONLY_PROJECT' is blacklisted — scanning it anyway because explicitly requested)"
  fi
  TARGETS+=("$ONLY_PROJECT")
else
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      is_blacklisted "$n" && continue
      is_skip_project "$n" && continue
      TARGETS+=("$n")
    done
  fi
fi

# ---------------------------------------------------------------------------
# Plan accumulator. Each scanned candidate is one TSV row in a temp file:
#   <scope>\t<verdict>\t<kind>\t<abs_path>\t<bytes>\t<repo_or_dash>\t<detail>
#     verdict ∈ delete | candidate | skip
# Worktree rows also carry the repo path (col 6) needed by dj_reap_worktree.
# ---------------------------------------------------------------------------
PLAN_TMP="$(mktemp "${TMPDIR:-/tmp}/disk-janitor.XXXXXX")"
trap 'rm -f "$PLAN_TMP"' EXIT

EXIT_STATUS=0
NOW_EPOCH="$(date +%s)"

# plan_row <scope> <verdict> <kind> <abs_path> <bytes> <repo> <detail>
plan_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >>"$PLAN_TMP"
}

# ---------------------------------------------------------------------------
# Recurrence pre-pass — the turbo-outputs landmine that caused the 148 GB
# incident. Pure report; calls the shared lib predicate + fix-hint string.
# Returns the offending project list as text on stdout (one "name\tpath" per
# line); empty when clean.
# ---------------------------------------------------------------------------
TURBO_LANDMINES=""
turbo_prepass() {
  local name proj tj rc
  TURBO_LANDMINES=""
  [ "${#TARGETS[@]}" -gt 0 ] || return 0
  for name in "${TARGETS[@]}"; do
    proj="$(resolve_project_path "$name")"
    tj="$proj/turbo.json"
    [ -f "$tj" ] || continue
    if dj_turbo_outputs_unscoped "$tj"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
      if [ -z "$TURBO_LANDMINES" ]; then
        TURBO_LANDMINES="$name	$tj"
      else
        TURBO_LANDMINES="$TURBO_LANDMINES
$name	$tj"
      fi
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Scope A: build caches.
# ---------------------------------------------------------------------------
scan_caches() {
  local proj="$1"
  local kind path bytes mtime rc build_active=0 cache_rows

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
    if [ "$build_active" -eq 1 ]; then
      plan_row caches skip "$kind" "$path" "$bytes" "-" "build running — caches left intact"
      continue
    fi
    if dj_cache_is_stale "$mtime" "$CACHE_TTL_DAYS" "$NOW_EPOCH"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
      plan_row caches delete "$kind" "$path" "$bytes" "-" "stale > ${CACHE_TTL_DAYS}d"
    else
      plan_row caches skip "$kind" "$path" "$bytes" "-" "younger than ${CACHE_TTL_DAYS}d"
    fi
  done <<EOF
$cache_rows
EOF
}

# ---------------------------------------------------------------------------
# Scope B: worktrees.
#
# Default predicate (reap_pushed_worktrees=true, Layer 2 — the flood reclaimer):
#   reap iff  is_main==0  AND  porcelain_clean  AND  recoverable  AND  not(secret)
# where recoverable = merged (gh) OR pushed (upstream on origin, tip not ahead).
# `stale` is dropped (age is irrelevant once work is recoverable); a gitignored
# secret downgrades to a manual candidate; a porcelain-clean but unrecoverable
# tree under /private/tmp reaps at a short TTL. dj_branch_merged returns 0/1/2,
# dj_worktree_pushed 0/1.
#
# Fallback (reap_pushed_worktrees=false): the pre-Layer-2 4-gate triad exactly
# (is_main==0 AND stale AND clean(allowlist) AND merged) — a clean opt-out.
#
# The main-checkout row carries kind `worktree-main` so the Layer 3 tripwire can
# count LINKED worktrees only (col 3 == "worktree").
# ---------------------------------------------------------------------------
scan_worktrees() {
  local proj="$1"
  local wt_path head_sha branch is_main prunable
  local bytes mtime detail verdict worktree_rows rc
  local merged_rc clean_rc stale_rc porc_rc pushed_rc secret_rc recoverable_rc
  local real_wt is_tmp tmp_stale_rc is_detached

  if worktree_rows="$(dj_list_worktrees "$proj")"; then :; else
    rc=$?
    echo "disk-janitor: WARNING: worktree discovery failed for $proj (exit $rc)" >&2
    return "$rc"
  fi

  # head_sha + prunable are consumed only to advance past their TSV columns.
  while IFS="$(printf '\t')" read -r wt_path head_sha branch is_main prunable; do
    [ -n "$wt_path" ] || continue
    : "${head_sha:-}" "${prunable:-}"

    # Main checkout: never a reap candidate — report and move on. Kind
    # `worktree-main` keeps it out of the linked-worktree tripwire count.
    if [ "$is_main" = "1" ]; then
      bytes="$(dj_dir_bytes "$wt_path")"
      plan_row worktrees skip worktree-main "$wt_path" "$bytes" "$proj" "main checkout — never reaped"
      continue
    fi

    bytes="$(dj_dir_bytes "$wt_path")"
    mtime="$(dj_worktree_mtime "$wt_path")"

    # ---- Fallback: pre-Layer-2 4-gate behavior (opt-out) ----
    if [ "$REAP_PUSHED_WORKTREES" = "false" ]; then
      if dj_cache_is_stale "$mtime" "$WORKTREE_STALE_DAYS" "$NOW_EPOCH"; then stale_rc=0; else stale_rc=$?; fi
      if dj_worktree_clean "$wt_path"; then clean_rc=0; else clean_rc=$?; fi
      if dj_branch_merged "$proj" "$branch"; then merged_rc=0; else merged_rc=$?; fi

      detail="branch=$branch"
      case "$stale_rc" in 0) detail="$detail stale" ;; *) detail="$detail fresh" ;; esac
      case "$clean_rc" in 0) detail="$detail clean" ;; *) detail="$detail dirty" ;; esac
      case "$merged_rc" in
        0) detail="$detail merged" ;;
        2) detail="$detail merge-unverified" ;;
        *) detail="$detail unmerged" ;;
      esac

      if [ "$stale_rc" -eq 0 ] && [ "$clean_rc" -eq 0 ] && [ "$merged_rc" -eq 0 ]; then
        verdict="delete"
      elif [ "$stale_rc" -eq 0 ] && [ "$clean_rc" -eq 0 ] && [ "$merged_rc" -eq 2 ]; then
        verdict="candidate"
        detail="candidate (unverified merge) — $detail"
      else
        verdict="skip"
      fi
      plan_row worktrees "$verdict" worktree "$wt_path" "$bytes" "$proj" "$detail"
      continue
    fi

    # ---- Default: Layer 2 porcelain-clean + recoverable predicate ----

    # Hard gate: a porcelain-dirty tree (staged, unstaged, OR untracked) holds
    # real uncommitted work — ALWAYS skip, before any network/gh lookup.
    if dj_worktree_porcelain_clean "$wt_path"; then porc_rc=0; else porc_rc=1; fi
    if [ "$porc_rc" -ne 0 ]; then
      plan_row worktrees skip worktree "$wt_path" "$bytes" "$proj" "dirty (uncommitted work) — branch=$branch"
      continue
    fi

    # Recoverable = merged (gh) OR pushed (upstream, tip not ahead).
    if dj_branch_merged "$proj" "$branch"; then merged_rc=0; else merged_rc=$?; fi
    if dj_worktree_pushed "$wt_path"; then pushed_rc=0; else pushed_rc=$?; fi
    recoverable_rc=1
    if [ "$merged_rc" -eq 0 ] || [ "$pushed_rc" -eq 0 ]; then recoverable_rc=0; fi

    # Secret denylist (only meaningful for a recoverable clean tree).
    secret_rc=1
    if [ "$recoverable_rc" -eq 0 ]; then
      if dj_worktree_has_secret_ignored "$wt_path"; then secret_rc=0; else secret_rc=$?; fi
    fi

    detail="branch=$branch clean"
    case "$merged_rc" in
      0) detail="$detail merged" ;;
      2) detail="$detail merge-unverified" ;;
      *) detail="$detail unmerged" ;;
    esac
    case "$pushed_rc" in 0) detail="$detail pushed" ;; *) detail="$detail unpushed" ;; esac
    case "$recoverable_rc" in 0) detail="$detail recoverable" ;; *) detail="$detail unrecoverable" ;; esac

    if [ "$recoverable_rc" -eq 0 ] && [ "$secret_rc" -eq 0 ]; then
      # Recoverable, but a gitignored secret would be destroyed — manual only.
      verdict="candidate"
      detail="candidate (secret ignored file present) — $detail secret-ignored"
    elif [ "$recoverable_rc" -eq 0 ]; then
      verdict="delete"
    else
      # Not recoverable. Only /private/tmp (throwaway on reboot) reaps at a short
      # TTL, and never when detached (no branch ref to fall back on).
      real_wt="$(dj__abspath "$wt_path")"
      is_tmp=1
      case "$real_wt/" in
        /private/tmp/*) is_tmp=0 ;;
      esac
      is_detached=1
      case "$branch" in ''|detached|HEAD) is_detached=0 ;; esac
      if dj_cache_is_stale "$mtime" "$EPHEMERAL_TMP_TTL_DAYS" "$NOW_EPOCH"; then tmp_stale_rc=0; else tmp_stale_rc=$?; fi
      if [ "$is_tmp" -eq 0 ] && [ "$tmp_stale_rc" -eq 0 ] && [ "$is_detached" -ne 0 ]; then
        # The ephemeral-tmp reap still honors the secret denylist: a gitignored
        # secret is not in git's object store, so `git worktree remove` would
        # destroy it irretrievably — the same fail-closed class as the recoverable
        # path. A tmp tree harboring one is downgraded to a manual candidate.
        if dj_worktree_has_secret_ignored "$wt_path"; then
          verdict="candidate"
          detail="candidate (secret ignored file present) — $detail ephemeral-tmp secret-ignored"
        else
          verdict="delete"
          detail="$detail ephemeral-tmp stale>${EPHEMERAL_TMP_TTL_DAYS}d"
        fi
      else
        verdict="candidate"
        detail="candidate (not recoverable) — $detail"
      fi
    fi

    # --safe-only (the unattended nightly apply): keep a `delete` verdict ONLY
    # for a merged, non-detached tree. A merged PR means the unit is done, so no
    # live agent is working in the tree — the worktree scan has no live-process
    # guard, so "merged" is what carries the concurrency guarantee. Every other
    # auto-delete (pushed-but-unmerged, ephemeral /private/tmp) is an in-flight
    # tree owned by the fan-out teardown; downgrade it to a manual candidate.
    # Only ever tightens the plan. (The reap_pushed_worktrees=false fallback is
    # already merged-gated, so it reaches its own plan_row without this.)
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
    plan_row worktrees "$verdict" worktree "$wt_path" "$bytes" "$proj" "$detail"
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
  local proj="$1"
  (
    set +e
    local rc=0
    if scope_enabled caches; then
      scan_caches "$proj" || rc=$?
    fi
    if scope_enabled worktrees; then
      scan_worktrees "$proj" || rc=$?
    fi
    exit "$rc"
  )
}

# ---------------------------------------------------------------------------
# Run the scan over the fleet.
# ---------------------------------------------------------------------------
turbo_prepass
if [ "${#TARGETS[@]}" -gt 0 ]; then
  for name in "${TARGETS[@]}"; do
    proj="$(resolve_project_path "$name")"
    if [ ! -e "$proj/.git" ]; then
      plan_row meta skip project "$proj" 0 "-" "skipped: not a git checkout ($proj)"
      continue
    fi
    if scan_project "$proj"; then :; else
      echo "disk-janitor: WARNING: scan failed for $proj; results are incomplete" >&2
      plan_row meta skip project "$proj" 0 "-" "skipped: scan error ($proj)"
      EXIT_STATUS=1
    fi
  done
fi

STORES_PLAN=""
if scope_enabled stores; then
  STORES_PLAN="$(scan_stores || true)"
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
TOTAL_RECLAIM_BYTES=$((CACHE_DELETE_BYTES + WT_DELETE_BYTES))

# Largest single cache (for the ceiling tripwire).
LARGEST_CACHE_BYTES="$(awk -F'\t' '$1=="caches" && $5>m { m=$5 } END { printf "%.0f", m+0 }' "$PLAN_TMP")"

# Layer 3 tripwire inputs: per-repo LINKED-worktree counts + aggregate bytes,
# derived from the accumulated plan rows. The main checkout is emitted with kind
# `worktree-main` (col 3), so filtering col3=="worktree" counts linked trees only.
# awk prints "<busiest_repo>\t<max_count>\t<total_bytes>"; empty plan → "-\t0\t0".
WT_TRIPWIRE_STATS="$(awk -F'\t' '
  $1=="worktrees" && $3=="worktree" { c[$6]++; s += $5 }
  END {
    mx = 0; name = "-";
    for (r in c) if (c[r] > mx) { mx = c[r]; name = r }
    printf "%s\t%d\t%.0f", name, mx, s+0
  }
' "$PLAN_TMP")"
WT_MAX_REPO="$(printf '%s' "$WT_TRIPWIRE_STATS" | cut -f1)"
WT_MAX_COUNT="$(printf '%s' "$WT_TRIPWIRE_STATS" | cut -f2)"
WT_TOTAL_BYTES="$(printf '%s' "$WT_TRIPWIRE_STATS" | cut -f3)"
WT_TOTAL_CEILING_BYTES=$((WORKTREE_TOTAL_GB_CEILING * 1024 * 1024 * 1024))

# Free space on the projects volume. `df -Pk` forces POSIX output (one physical
# line per filesystem — no device-name wrap) with sizes in 1024-blocks; the
# Available column is field 4. Portable across darwin + linux.
free_bytes_for() {
  local target="$1" avail_k
  avail_k="$(df -Pk "$target" 2>/dev/null | awk 'NR==2 { print $4 }' || true)"
  [ -n "$avail_k" ] || { printf '0'; return 0; }
  printf '%s' "$((avail_k * 1024))"
}
FREE_BYTES="$(free_bytes_for "$PROJECTS_ROOT")"
FLOOR_BYTES=$((FREE_SPACE_FLOOR_GB * 1024 * 1024 * 1024))
CEILING_BYTES=$((CACHE_CEILING_GB * 1024 * 1024 * 1024))

# ---------------------------------------------------------------------------
# Report renderer — emits to the file descriptor passed as $1 (stdout=1 for the
# console copy, a real fd for the audit file). Same body for both so they never
# drift.
# ---------------------------------------------------------------------------
render_report() {
  local line scope verdict kind path bytes repo detail

  echo "trellis disk-janitor — disk reclaim report"
  echo "date:          $(date +%F)"
  echo "projects root: $PROJECTS_ROOT"
  echo "scopes:        $SCOPES$SAFE_ONLY_TAG"
  echo "config:        enabled=$DJ_ENABLED cache_ttl_days=$CACHE_TTL_DAYS worktree_stale_days=$WORKTREE_STALE_DAYS free_space_floor_gb=$FREE_SPACE_FLOOR_GB cache_ceiling_gb=$CACHE_CEILING_GB reap_pushed_worktrees=$REAP_PUSHED_WORKTREES ephemeral_tmp_ttl_days=$EPHEMERAL_TMP_TTL_DAYS worktree_count_ceiling=$WORKTREE_COUNT_CEILING worktree_total_gb_ceiling=$WORKTREE_TOTAL_GB_CEILING"
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
  printf '  free space on %s: %s' "$PROJECTS_ROOT" "$(dj_human_bytes "$FREE_BYTES")"
  if [ "$FREE_BYTES" -lt "$FLOOR_BYTES" ]; then
    printf '  ⚠ BELOW floor (%s)\n' "$(dj_human_bytes "$FLOOR_BYTES")"
  else
    printf '  ✓ above floor (%s)\n' "$(dj_human_bytes "$FLOOR_BYTES")"
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
    printf '  linked worktrees (busiest repo): %s in %s' "$WT_MAX_COUNT" "$WT_MAX_REPO"
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
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
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
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      [ "$scope" = "worktrees" ] || continue
      printf '  [%s] %s (%s) — %s\n' "$verdict" "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done <"$PLAN_TMP"
    printf '  reclaimable (porcelain-clean + recoverable): %s\n' "$(dj_human_bytes "$WT_DELETE_BYTES")"
    printf '  candidates (manual review, NOT reaped): %s\n' "$(dj_human_bytes "$WT_CANDIDATE_BYTES")"
    echo
  fi

  # --- stores --- (report-only: STORES_PLAN is a best-effort byte estimate)
  if scope_enabled stores; then
    echo "== Package stores (report-only; --apply does not prune stores) =="
    case "${STORES_PLAN:-0}" in
      ''|0|*[!0-9]*)
        echo "  (no reclaimable package-store space detected)"
        ;;
      *)
        printf '  pnpm + npm store footprint (best-effort upper bound): %s\n' "$(dj_human_bytes "$STORES_PLAN")"
        echo "  to reclaim, run 'pnpm store prune' manually (removes only unreferenced packages)."
        ;;
    esac
    echo
  fi

  # --- skipped projects ---
  if awk -F'\t' '$1=="meta"' "$PLAN_TMP" | grep -q .; then
    echo "== Skipped projects =="
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      [ "$scope" = "meta" ] || continue
      echo "  $detail"
    done <"$PLAN_TMP"
    echo
  fi

  echo "== Total =="
  printf '  reclaimable now (caches + reaped worktrees): %s\n' "$(dj_human_bytes "$TOTAL_RECLAIM_BYTES")"
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
  exit "$EXIT_STATUS"
fi

# ---------------------------------------------------------------------------
# Dry-run: print the exact deletion plan only. Mutate nothing.
# ---------------------------------------------------------------------------
if [ "$MODE" = "dry-run" ]; then
  echo "trellis disk-janitor — DRY RUN (deletion plan; nothing is removed)"
  echo "projects root: $PROJECTS_ROOT"
  echo "scopes:        $SCOPES$SAFE_ONLY_TAG"
  echo
  if scope_enabled caches; then
    echo "== Caches to delete (stale > ${CACHE_TTL_DAYS}d) =="
    awk -F'\t' '$1=="caches" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      printf '  rm -rf  %s  (%s, %s) — %s\n' "$path" "$kind" "$(dj_human_bytes "$bytes")" "$detail"
    done
    printf '  -> %s reclaimable\n' "$(dj_human_bytes "$CACHE_DELETE_BYTES")"
    echo
  fi
  if scope_enabled worktrees; then
    echo "== Worktrees to reap (is_main==0 AND porcelain-clean AND recoverable AND not-secret) =="
    awk -F'\t' '$1=="worktrees" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      printf '  git worktree remove  %s  (%s) — gates: %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
    printf '  -> %s reclaimable\n' "$(dj_human_bytes "$WT_DELETE_BYTES")"
    echo "  candidates (manual review) — reported, NOT reaped:"
    awk -F'\t' '$1=="worktrees" && $2=="candidate"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      printf '    %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
    echo
  fi
  echo "(dry-run: re-run with --apply to act; --apply confirms per category)"
  exit "$EXIT_STATUS"
fi

# ---------------------------------------------------------------------------
# Apply: print the plan, then per category confirm (y/N from stdin unless
# --yes), then call the OWNED deletion funcs. Re-scan + report reclaimed bytes.
# ---------------------------------------------------------------------------

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
echo "projects root: $PROJECTS_ROOT"
echo "scopes:        $SCOPES$SAFE_ONLY_TAG"
echo

# --- caches ---
if scope_enabled caches; then
  echo "== Caches to delete (stale > ${CACHE_TTL_DAYS}d), $(dj_human_bytes "$CACHE_DELETE_BYTES") =="
  awk -F'\t' '$1=="caches" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
    printf '  %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
  done
  if [ "$CACHE_DELETE_BYTES" -gt 0 ] && confirm_category "these build caches"; then
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      [ "$scope" = "caches" ] && [ "$verdict" = "delete" ] || continue
      if dj_prune_cache_entry "$path"; then
        echo "  removed: $path"
      else
        echo "  REFUSED/failed: $path (guard rejected or rm error)" >&2
        EXIT_STATUS=1
      fi
    done <"$PLAN_TMP"
  fi
  echo
fi

# --- worktrees --- (only verdict==delete; candidate/unverified is excluded)
if scope_enabled worktrees; then
  echo "== Worktrees to reap (porcelain-clean + recoverable), $(dj_human_bytes "$WT_DELETE_BYTES") =="
  awk -F'\t' '$1=="worktrees" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
    printf '  %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
  done
  if [ "$WT_DELETE_BYTES" -gt 0 ] && confirm_category "these recoverable + porcelain-clean worktrees"; then
    while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      [ "$scope" = "worktrees" ] && [ "$verdict" = "delete" ] || continue
      if dj_reap_worktree "$repo" "$path"; then
        echo "  reaped: $path"
      else
        echo "  REFUSED/failed: $path (guard rejected or git error)" >&2
        EXIT_STATUS=1
      fi
    done <"$PLAN_TMP"
  fi
  echo
fi

# --- stores --- report-only even under --apply (no store-prune in this release).
if scope_enabled stores; then
  echo "== Package stores =="
  echo "  stores is report-only — --apply does not prune package stores in this"
  echo "  release. Run 'trellis disk-janitor --report' for the footprint, then"
  echo "  'pnpm store prune' manually to reclaim unreferenced packages."
  echo
fi

# Re-scan caches post-delete to report the actually-reclaimed bytes.
remaining_cache_bytes=0
if scope_enabled caches && [ "${#TARGETS[@]}" -gt 0 ]; then
  for name in "${TARGETS[@]}"; do
    proj="$(resolve_project_path "$name")"
    [ -e "$proj/.git" ] || continue
    if remaining_cache_rows="$(dj_find_caches "$proj")"; then
      while IFS="$(printf '\t')" read -r kind path bytes mtime; do
        [ -n "${path:-}" ] || continue
        remaining_cache_bytes=$((remaining_cache_bytes + bytes))
      done <<EOF
$remaining_cache_rows
EOF
    else
      rc=$?
      echo "disk-janitor: WARNING: post-apply cache discovery failed for $proj (exit $rc)" >&2
      EXIT_STATUS=1
    fi
  done
fi

RECLAIMED=$((CACHE_ALL_BYTES - remaining_cache_bytes))
if [ "$RECLAIMED" -lt 0 ]; then RECLAIMED=0; fi
echo "== Reclaimed =="
if scope_enabled caches; then
  printf '  caches: %s freed (was %s, now %s)\n' \
    "$(dj_human_bytes "$RECLAIMED")" "$(dj_human_bytes "$CACHE_ALL_BYTES")" "$(dj_human_bytes "$remaining_cache_bytes")"
fi
if scope_enabled worktrees; then
  printf '  worktrees: %s reaped (planned)\n' "$(dj_human_bytes "$WT_DELETE_BYTES")"
fi

exit "$EXIT_STATUS"
