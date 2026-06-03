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
#                       why-safe per row; worktrees show the 4-gate verdict).
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
# Worktree reap is gated by the FULL 4-gate triad (is_main==0 AND stale AND
# clean AND branch merged). An UNVERIFIED merge (dj_branch_merged==2) is
# reported as a candidate and EXCLUDED from apply — never reaped.
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

print_help() {
  cat <<'EOF'
trellis disk-janitor — reclaim build caches, dead worktrees, package stores

Usage:
  disk-janitor.sh                          Report (read-only). Default mode.
  disk-janitor.sh --report                 Same as no flag: scan + write audit.
  disk-janitor.sh --dry-run                Print the exact deletion plan only.
  disk-janitor.sh --apply                  Apply, confirming per category (y/N).
  disk-janitor.sh --apply --yes            Apply without the per-category prompt.
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
             the 4-gate verdict). Deletes nothing.
  --apply    Prints the plan, then per category reads a y/N line from stdin
             before deleting (mandatory unless --yes). Re-scans, reports
             reclaimed bytes.

Merge detection uses a read-only `gh pr list` query (a merged PR for the
branch); it modifies no git refs and deletes nothing, so report/dry-run stay
non-destructive. A worktree whose merge can't be verified (no gh, detached
HEAD) is reported as a candidate and never reaped.

Scopes:
  caches      .turbo/cache, .next/cache, .next/dev older than cache_ttl_days,
              skipped when a build is running.
  worktrees   linked git worktrees that are non-main AND stale AND clean AND
              whose branch is merged. Unverified-merge worktrees are reported
              as candidates, never reaped.
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

DJ_ENABLED="$(jq -r '.disk_janitor.enabled // true' "$CFG" 2>/dev/null || echo true)"
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
# Registry / blacklist parsing — copied verbatim from doctor.sh (the established
# fleet-enumeration convention; 10 scripts duplicate this inline). Active set =
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

# Blacklist section 1 (Temporarily excluded): Project column = registry name.
# Blacklist section 2 (Permanently excluded): Path column = `/personal/<name>`;
#   map to basename so it can subtract a registry name.
# The `| — | — |` placeholder rows are skipped: em-dash is not in [a-zA-Z0-9._-].
read_blacklist_names() {
  [ -f "$BLACKLIST" ] || return 0
  awk '
    /^## 1\. Temporarily excluded/ { sec=1; next }
    /^## 2\. Permanently excluded/ { sec=2; next }
    /^## Semantics/                { sec=0 }
    sec==1 && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0
      gsub(/^\| /, "", name); gsub(/ \|.*$/, "", name)
      if (name == "Project" || name ~ /^-+$/) next
      print name
      next
    }
    sec==2 && /^\| `\/[A-Za-z0-9._\/-]+` \|/ {
      # Path column wrapped in backticks: `/personal/<name>`
      path=$0
      gsub(/^\| `/, "", path); gsub(/` \|.*$/, "", path)
      n=split(path, parts, "/")
      base=parts[n]
      if (base != "" && base != "Path") print base
    }
  ' "$BLACKLIST"
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
done < <(read_blacklist_names)

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
  local kind path bytes mtime rc build_active=0

  # Running-build guard: if a build is live in this project, do not touch its
  # caches at all (testable via DJ_BUILD_ACTIVE_OVERRIDE).
  if dj_build_active "$proj"; then build_active=1; fi

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
$(dj_find_caches "$proj")
EOF
}

# ---------------------------------------------------------------------------
# Scope B: worktrees. Reap requires the FULL 4-gate triad. dj_branch_merged
# returns 0 (merged) / 1 (unmerged) / 2 (unverified — never reaped).
# ---------------------------------------------------------------------------
scan_worktrees() {
  local proj="$1"
  local wt_path head_sha branch is_main prunable
  local bytes mtime merged_rc clean_rc stale_rc detail verdict

  # head_sha + prunable are consumed only to advance past their TSV columns.
  while IFS="$(printf '\t')" read -r wt_path head_sha branch is_main prunable; do
    [ -n "$wt_path" ] || continue
    : "${head_sha:-}" "${prunable:-}"

    # Main checkout: never a reap candidate — report and move on.
    if [ "$is_main" = "1" ]; then
      bytes="$(dj_dir_bytes "$wt_path")"
      plan_row worktrees skip worktree "$wt_path" "$bytes" "$proj" "main checkout — never reaped"
      continue
    fi

    bytes="$(dj_dir_bytes "$wt_path")"
    mtime="$(dj_worktree_mtime "$wt_path")"

    # Gate: staleness.
    if dj_cache_is_stale "$mtime" "$WORKTREE_STALE_DAYS" "$NOW_EPOCH"; then stale_rc=0; else stale_rc=$?; fi
    # Gate: clean working tree (untracked counts as dirty).
    if dj_worktree_clean "$wt_path"; then clean_rc=0; else clean_rc=$?; fi
    # Gate: branch merged. 0 merged / 1 unmerged / 2 unverified.
    if dj_branch_merged "$proj" "$branch"; then merged_rc=0; else merged_rc=$?; fi

    detail="branch=$branch"
    case "$stale_rc" in 0) detail="$detail stale" ;; *) detail="$detail fresh" ;; esac
    case "$clean_rc" in 0) detail="$detail clean" ;; *) detail="$detail dirty" ;; esac
    case "$merged_rc" in
      0) detail="$detail merged" ;;
      2) detail="$detail merge-unverified" ;;
      *) detail="$detail unmerged" ;;
    esac

    # Verdict: delete ONLY when all four gates hold. Unverified merge is a
    # reported candidate, NEVER reaped.
    if [ "$stale_rc" -eq 0 ] && [ "$clean_rc" -eq 0 ] && [ "$merged_rc" -eq 0 ]; then
      verdict="delete"
    elif [ "$stale_rc" -eq 0 ] && [ "$clean_rc" -eq 0 ] && [ "$merged_rc" -eq 2 ]; then
      verdict="candidate"
      detail="candidate (unverified merge) — $detail"
    else
      verdict="skip"
    fi
    plan_row worktrees "$verdict" worktree "$wt_path" "$bytes" "$proj" "$detail"
  done <<EOF
$(dj_list_worktrees "$proj")
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
  echo "scopes:        $SCOPES"
  echo "config:        enabled=$DJ_ENABLED cache_ttl_days=$CACHE_TTL_DAYS worktree_stale_days=$WORKTREE_STALE_DAYS free_space_floor_gb=$FREE_SPACE_FLOOR_GB cache_ceiling_gb=$CACHE_CEILING_GB"
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
    printf '  reclaimable (all 4 gates): %s\n' "$(dj_human_bytes "$WT_DELETE_BYTES")"
    printf '  candidates (unverified merge, NOT reaped): %s\n' "$(dj_human_bytes "$WT_CANDIDATE_BYTES")"
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
  echo "scopes:        $SCOPES"
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
    echo "== Worktrees to reap (is_main==0 AND stale AND clean AND merged) =="
    awk -F'\t' '$1=="worktrees" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
      printf '  git worktree remove  %s  (%s) — gates: %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
    printf '  -> %s reclaimable\n' "$(dj_human_bytes "$WT_DELETE_BYTES")"
    echo "  candidates (unverified merge) — reported, NOT reaped:"
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
echo "scopes:        $SCOPES"
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
  echo "== Worktrees to reap (all 4 gates), $(dj_human_bytes "$WT_DELETE_BYTES") =="
  awk -F'\t' '$1=="worktrees" && $2=="delete"' "$PLAN_TMP" | while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail; do
    printf '  %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
  done
  if [ "$WT_DELETE_BYTES" -gt 0 ] && confirm_category "these merged+clean+stale worktrees"; then
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
    while IFS="$(printf '\t')" read -r kind path bytes mtime; do
      [ -n "${path:-}" ] || continue
      remaining_cache_bytes=$((remaining_cache_bytes + bytes))
    done <<EOF
$(dj_find_caches "$proj" 2>/dev/null || true)
EOF
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
