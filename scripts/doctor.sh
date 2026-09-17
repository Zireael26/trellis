#!/usr/bin/env bash
# trellis doctor — portable local-state health with explicit legacy diagnosis.
#
# The portable path reads only TRELLIS_HOME local state. A legacy inheritance
# diagnosis is available only when a valid legacy TRELLIS_CONFIG is supplied
# explicitly; it never discovers a config or reads the operator's HOME.
#
# Cutover boundary (v1.0.0-rc.25): doctor still RECOGNIZES a pre-cutover
# direct-link checkout — the portable classifier reports `compatibility-legacy`
# / `mixed/conflict`, and the explicit legacy mode below enumerates its rows —
# but it never CREATES a direct link. The writers it used to delegate to
# (onboard-project.sh --legacy, seed-inheritance-symlinks.sh --legacy-mirror)
# refuse at cutover, so `--fix` reports the owning migration instead.
set -u

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOCTOR_EX_USAGE=2
DOCTOR_EX_CONFLICT=3
DOCTOR_EX_STATE=4
DOCTOR_EX_UNAVAILABLE=5

# The single validating reader for the historic machine-local config shape.
# Since the cutover removed onboard-project.sh --legacy, doctor is this
# library's ONLY consumer: it exists so a leftover legacy layout can still be
# diagnosed against a validated config rather than guessed at.
# shellcheck source=lib/legacy-config.sh
. "$SCRIPT_DIR/lib/legacy-config.sh"

# ---------------------------------------------------------------------------
# One private scratch tree per doctor invocation. EVERY temporary artifact in
# either mode is created inside it, and one trap set — installed here, BEFORE
# any mode dispatches — is the only cleanup path. Functions NEVER
# install their own traps: a `trap … EXIT` silently replaces this one
# (traps are global to the process, even from a subshell), dropping HUP/INT/
# TERM coverage and every other owner's cleanup with it.
#
# The tree is created HERE, in the parent shell, NOT lazily inside a helper:
# several consumers (the SQLite copy-probes) run inside command substitutions,
# and an assignment made there dies with the subshell — a lazy create would be
# re-run and orphaned once per probe. Created eagerly, DOCTOR_SCRATCH_DIR is
# inherited unchanged by every subshell below. Private from birth (umask 077 /
# mktemp -d 0700); removed on normal exit and on SIGHUP/SIGINT/SIGTERM alike.
# ---------------------------------------------------------------------------
DOCTOR_SCRATCH_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/trellis-doctor.XXXXXXXX" 2>/dev/null)" ||
  DOCTOR_SCRATCH_DIR=""

doctor_scratch_cleanup() {
  [ -n "$DOCTOR_SCRATCH_DIR" ] && rm -rf -- "$DOCTOR_SCRATCH_DIR"
  return 0
}
trap 'doctor_scratch_cleanup' EXIT
# On a terminating signal, clean up AND terminate: a handler that merely
# returns lets bash RESUME the interrupted script — with its scratch tree
# already gone. Disarm every trap before re-raising so the default action
# delivers the signal's own exit status and EXIT cleanup cannot run twice.
trap 'doctor_scratch_cleanup; trap - EXIT HUP INT TERM; kill -HUP "$$"'  HUP
trap 'doctor_scratch_cleanup; trap - EXIT HUP INT TERM; kill -INT "$$"'  INT
trap 'doctor_scratch_cleanup; trap - EXIT HUP INT TERM; kill -TERM "$$"' TERM

# doctor_scratch_require — verify the invocation scratch tree exists in THIS
# shell. The eager creation above runs before any dispatch, so this only
# re-arms a subshell that inherited the (non-exported) empty fallback.
doctor_scratch_require() {
  if [ -z "$DOCTOR_SCRATCH_DIR" ]; then
    DOCTOR_SCRATCH_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/trellis-doctor.XXXXXXXX" 2>/dev/null)" || {
      DOCTOR_SCRATCH_DIR=""
      return 1
    }
  fi
  return 0
}

# An explicitly supplied config with any historic machine-local key is the
# compatibility contract. Do not fall through to TRELLIS_HOME for a malformed
# explicit config: that would turn a deterministic legacy invocation into an
# operator-home lookup.
doctor_select_mode() {
  local cfg="${TRELLIS_CONFIG:-}"
  if [ -z "$cfg" ]; then
    printf '%s\n' portable
    return 0
  fi
  legacy_config_preconditions doctor "$cfg" || return "$?"
  if legacy_config_has_machine_local_key "$cfg"; then
    printf '%s\n' legacy
  else
    printf '%s\n' portable
  fi
}

# --home and --fleet are portable-only selectors. --project is shared with
# compatibility diagnosis and is interpreted after the mode is selected.
doctor_args_force_portable_mode() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home|--fleet) return 0 ;;
    esac
    shift
  done
  return 1
}

legacy_doctor_load_config() {
  # Schema validation, semantic checks and the exported view all live in
  # lib/legacy-config.sh. legacy_config_load also defines pg_has_harness over
  # the HARNESSES it just read, so there is one reader and one accessor.
  legacy_config_read doctor "${TRELLIS_CONFIG:-}"
}

legacy_doctor_main() {
  set -euo pipefail
  DOCTOR_SHARED_INFRA_OVERRIDE="${SHARED_INFRA_ROOT:-}"
  legacy_doctor_load_config || exit "$?"
  . "$SCRIPT_DIR/lib/blacklist-parser.sh"
  . "$SCRIPT_DIR/lib/health-checks.sh"
# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ONLY_PROJECT=""
DO_FIX=0
DO_FIX_HOOKS=0
DO_DRY_RUN=0
print_help() {
  cat <<'EOF'
trellis doctor — legacy-layout diagnosis (compatibility mode)

Usage:
  doctor.sh                          Check Tier-0 preconditions + all projects.
  doctor.sh --project NAME           Limit Tier-1 checks to one registry project.
  doctor.sh --fix [--project NAME]   Diagnose; report the migration each row needs.
  doctor.sh --fix --fix-hooks ...    Accepted for compatibility; INERT here.
  doctor.sh --fix --dry-run ...      Print the plan; change NOTHING.
  doctor.sh --help                   Show this help.

This is the explicit legacy compatibility mode, selected only by a TRELLIS_CONFIG
carrying historic machine-local keys. It DIAGNOSES a pre-cutover direct-link
layout. It never creates one.

Since v1.0.0-rc.25 this command is READ-ONLY in every mode. The direct-link
writers it used to delegate to were removed at cutover: onboard-project.sh
--legacy and seed-inheritance-symlinks.sh --legacy-mirror both refuse (exit 2).
--fix therefore applies nothing; it exists so the same invocation keeps working
and prints the migration each row needs.

Per project (after diagnosis):
  [manual] missing/stale rules, skill, command, harness, or settings.json
           -> reported with the migration that owns the repair:
             trellis migrate --prepare <project-path>
             trellis attach --fleet NAME <project-path>
           After attach, the portable flow owns every one of those surfaces.
  [manual] Claude/Codex hook drift -> reported only. A legacy direct-link
           project has no local registry row and no recorded immutable release,
           and sync-hooks.sh / sync-codex-hooks.sh reconcile a hook surface ONLY
           through the recorded release of a registered, attached row.
  [manual] linked worktrees missing inheritance -> reported only. Attach the
           clone; `trellis attach` and scripts/seed-inheritance-symlinks.sh then
           reconcile each worktree from the recorded release.
  [manual] dead/missing @-import (never auto-edit a user's CLAUDE.md) and
           settings.json .hooks drift (no engine fixes it) -> reported only.
  [info]   version-pin lag, Tier-0 canonical issues -> reported only.

Flag rules: --dry-run requires --fix (plain doctor is already read-only).
--fix-hooks implies --fix. Tier-0 issues are always report-only.

Output: per-project ✓ / ⚠ / ✗ table + a summary line + actionable fix hints.
Exit code: 0 if healthy (no ✗ ERRORs); non-zero if any ERROR is found.
Under --dry-run it is always 0.
EOF
}

# Indexed parse so --project NAME works without bash-4 features.
arg=""
i=1
while [ "$i" -le "$#" ]; do
  eval "arg=\${$i}"
  case "$arg" in
    --project)
      i=$((i + 1))
      [ "$i" -le "$#" ] || { echo "doctor: --project requires a NAME" >&2; exit 2; }
      eval "ONLY_PROJECT=\${$i}"
      ;;
    --project=*)
      ONLY_PROJECT="${arg#--project=}"
      ;;
    --fix)
      DO_FIX=1
      ;;
    --fix-hooks)
      DO_FIX_HOOKS=1
      ;;
    --dry-run)
      DO_DRY_RUN=1
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    -*)
      echo "doctor: unknown option: $arg" >&2
      echo "try: doctor.sh --help" >&2
      exit 2
      ;;
    *)
      echo "doctor: unexpected argument: $arg" >&2
      exit 2
      ;;
  esac
  i=$((i + 1))
done

# Flag-relationship rules (documented in --help):
#   --fix-hooks still implies --fix, but only so the historic spelling keeps
#     running the [auto] repairs it always rode on. There is no hook re-sync
#     action any more (hook drift is [manual] — see apply_project_fix), so the
#     flag itself is INERT; --fix prints a line saying so rather than ignoring
#     it silently.
#   --dry-run is only meaningful with --fix (plain doctor is already read-only).
[ "$DO_FIX_HOOKS" -eq 1 ] && DO_FIX=1
if [ "$DO_DRY_RUN" -eq 1 ] && [ "$DO_FIX" -eq 0 ]; then
  echo "doctor: --dry-run is only valid with --fix" >&2
  echo "try: doctor.sh --fix --dry-run" >&2
  exit 2
fi

# Legacy mode only: legacy_config_read exports TRELLIS_ROOT (and the
# registry/blacklist paths below live beside it). This is deliberately NOT
# config-load's TRELLIS_SOURCE_ROOT — that names the portable policy
# checkout, which is a different thing from the legacy canonical root.
CANON="$TRELLIS_ROOT"
REGISTRY="$CANON/registry.md"
BLACKLIST="$CANON/blacklist.md"

# ---------------------------------------------------------------------------
# Glyphs + counters
# ---------------------------------------------------------------------------
GLYPH_OK="✓"
GLYPH_WARN="⚠"
GLYPH_ERR="✗"
GLYPH_INFO="i"

N_ERROR=0
N_WARN=0
N_INFO=0

# tally() only bumps the summary counters when TALLY_ENABLED=1. P1 (no flags)
# leaves this 1 forever, so its behavior is byte-identical. Under --fix each
# project is checked TWICE — a "before" pass that builds the repair plan and an
# "after" pass that shows the resulting status — so the "before" pass disables
# tallying to keep the summary + exit code reflecting POST-FIX state only.
TALLY_ENABLED=1

# Accumulated fix hints (printed once, after the tables).
HINTS=()

# glyph_for <status-code> -> prints the glyph
glyph_for() {
  case "$1" in
    "$HC_OK")    printf '%s' "$GLYPH_OK" ;;
    "$HC_WARN")  printf '%s' "$GLYPH_WARN" ;;
    "$HC_ERROR") printf '%s' "$GLYPH_ERR" ;;
    "$HC_INFO")  printf '%s' "$GLYPH_INFO" ;;
    *)           printf '?' ;;
  esac
}

# tally <status-code> — bump the right counter (OK adds nothing). Honors the
# TALLY_ENABLED guard so the --fix "before" pass can report rows without
# double-counting them in the summary.
tally() {
  [ "$TALLY_ENABLED" -eq 1 ] || return 0
  case "$1" in
    "$HC_ERROR") N_ERROR=$((N_ERROR + 1)) ;;
    "$HC_WARN")  N_WARN=$((N_WARN + 1)) ;;
    "$HC_INFO")  N_INFO=$((N_INFO + 1)) ;;
  esac
}

# add_hint <line> — queue a de-duplicated fix hint.
add_hint() {
  local h="$1" existing
  if [ "${#HINTS[@]}" -gt 0 ]; then
    for existing in "${HINTS[@]}"; do
      [ "$existing" = "$h" ] && return 0
    done
  fi
  HINTS+=("$h")
}

# report_line <indent> <status-code> <message> — print one ✓/⚠/✗ row + tally.
report_line() {
  local indent="$1" code="$2" msg="$3"
  printf '%s%s %s\n' "$indent" "$(glyph_for "$code")" "$msg"
  tally "$code"
}

# ---------------------------------------------------------------------------
# Registry / blacklist parsing (deterministic; matches the ACTUAL file format).
# Active set = registry rows MINUS both blacklist sections.
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

# Resolve a registry name to an absolute project dir under PROJECTS_ROOT
# (mirrors the name-based fix engines: $PROJECTS_ROOT/<name>).
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
# Header. The read-only string is kept BYTE-IDENTICAL to P1 so no-flag output
# does not drift; --fix / --dry-run get a distinct banner.
# ---------------------------------------------------------------------------
if [ "$DO_FIX" -eq 0 ]; then
  echo "trellis doctor — read-only inheritance health check"
elif [ "$DO_DRY_RUN" -eq 1 ]; then
  echo "trellis doctor — --fix --dry-run (repair PLAN; nothing applied)"
else
  echo "trellis doctor — --fix (diagnose; legacy repair removed in v1.0.0-rc.25)"
fi
echo "canonical clone: $CANON"
echo "projects root:   $PROJECTS_ROOT"
if [ "${#HARNESSES[@]}" -gt 0 ]; then
  echo "harnesses:       ${HARNESSES[*]}"
fi
echo

# ---------------------------------------------------------------------------
# TIER 0 — preconditions against the canonical clone (via git -C "$CANON").
# A run-once helper that captures status without tripping set -e.
# ---------------------------------------------------------------------------
echo "== Tier 0: global preconditions =="

run_tier0() {
  local fn="$1"; shift
  local msg rc
  if msg=$("$fn" "$@"); then rc=$?; else rc=$?; fi
  report_line "  " "$rc" "$msg"
  return 0
}

# How many lines of a delegated tool's own diagnostic reach the report, per
# stream. Bounded because the delegated Make surface is free to print an
# arbitrarily long log and a Tier-0 row is one line.
SHARED_INFRA_DETAIL_LINES=3

# Terminal-safe rendering of one line of delegated output. Same unsafe set as
# `local_registry_safe_display` (C0, DEL, and C1 in its UTF-8 spelling); that
# helper lives in the portable libraries, which legacy mode does not source, so
# the check is inlined rather than reached for across the mode boundary.
shared_infra_safe_line() {
  local LC_ALL=C value="${1:-}"
  case "$value" in
    *[$'\001'-$'\037'$'\177']*|*$'\302'[$'\200'-$'\237']*)
      printf '<unsafe tool diagnostic>' ;;
    *) printf '%s' "$value" ;;
  esac
}

# Reduce one captured stream to the delegated tool's OWN failure lines.
#
# `make` prints its recipe-failure bookkeeping LAST — `make: *** [target] Error
# N`, plus a `make[1]:` line per sub-make — so the previous `tail -n 1` of the
# combined streams reported make's wrapper every single time and the tool's
# actual reason never reached the operator. Drop make's own lines, keep the last
# $SHARED_INFRA_DETAIL_LINES of what remains, and escape each line individually
# so one hostile byte cannot take the readable rest of the report with it.
shared_infra_detail_lines() {
  local text="${1:-}" kept line out=""
  [ -n "$text" ] || return 0
  kept="$(printf '%s\n' "$text" | awk -v limit="$SHARED_INFRA_DETAIL_LINES" '
    /^make(\[[0-9]+\])?: / { next }
    { sub(/[ \t\r]+$/, ""); if (length($0) > 0) lines[++n] = $0 }
    END {
      start = n - limit + 1
      if (start < 1) start = 1
      for (i = start; i <= n; i++) print lines[i]
    }
  ')"
  [ -n "$kept" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out="${out:+$out; }$(shared_infra_safe_line "$line")"
  done <<EOF
$kept
EOF
  printf '%s' "$out"
}

# Compose the reportable detail for a failed delegation. The tool's diagnostics
# go to stderr by convention, so that stream is preferred; stdout is the
# fallback for a tool that reports on it instead.
shared_infra_failure_detail() {
  local err_file="${1:-}" out_file="${2:-}" detail
  detail="$(shared_infra_detail_lines "$(cat "$err_file" 2>/dev/null)")"
  [ -n "$detail" ] || detail="$(shared_infra_detail_lines "$(cat "$out_file" 2>/dev/null)")"
  printf '%s' "$detail"
}

# Shared checks are a run-once Tier-0 delegation. They call only the read-only
# Make surface from the accepted contract: validate and doctor. Neither normal
# diagnosis nor --fix registers, reconciles, or changes an allocation.
run_shared_infra_checks() {
  local rc detail resolved_candidate resolved_path shared_out shared_err
  [ -n "${SHARED_INFRA_ROOT:-}" ] || return 0

  resolved_candidate="${DOCTOR_SHARED_INFRA_OVERRIDE:-${HOME:-$USER_HOME}/projects/shared-infra}"
  case "$resolved_candidate" in
    /*) resolved_path="$resolved_candidate" ;;
    *) resolved_path="$(pwd -P)/$resolved_candidate" ;;
  esac
  if [ -d "$resolved_path" ]; then
    resolved_path="$(cd "$resolved_path" && pwd -P)"
  fi
  if [ "$resolved_path" = "$SHARED_INFRA_ROOT" ]; then
    report_line "  " "$HC_OK" "shared-infra override: resolved path matches config ($SHARED_INFRA_ROOT)"
  else
    report_line "  " "$HC_WARN" "shared-infra override: resolved $resolved_path differs from config $SHARED_INFRA_ROOT — set SHARED_INFRA_ROOT=$SHARED_INFRA_ROOT"
  fi

  if [ ! -f "$SHARED_INFRA_ROOT/Makefile" ]; then
    report_line "  " "$HC_ERROR" "shared-infra path: Makefile missing at $SHARED_INFRA_ROOT/Makefile"
    return 0
  fi
  report_line "  " "$HC_OK" "shared-infra path: $SHARED_INFRA_ROOT"
  if ! command -v make >/dev/null 2>&1; then
    report_line "  " "$HC_ERROR" "shared-infra delegation: make is required but not installed"
    return 0
  fi

  # Captured SEPARATELY, not merged with 2>&1: the whole point is to report the
  # tool's diagnostic, and merging is what let make's trailing bookkeeping line
  # displace it.
  # Loud, not silent: without the capture files the two delegated rows below
  # would simply not be reported, and a Tier-0 row that quietly disappears reads
  # as a row that passed.
  if shared_out="$(doctor_scratch_require && mktemp "$DOCTOR_SCRATCH_DIR/shared-out.XXXXXX")"; then
    :
  else
    report_line "  " "$HC_ERROR" "shared-infra delegation: could not create a diagnostic capture file"
    return 0
  fi
  if shared_err="$(doctor_scratch_require && mktemp "$DOCTOR_SCRATCH_DIR/shared-err.XXXXXX")"; then
    :
  else
    rm -f "$shared_out"
    report_line "  " "$HC_ERROR" "shared-infra delegation: could not create a diagnostic capture file"
    return 0
  fi

  if make --no-print-directory -C "$SHARED_INFRA_ROOT" validate \
      >"$shared_out" 2>"$shared_err"; then
    report_line "  " "$HC_OK" "shared-infra manifest: schema and allocation validation passed"
  else
    rc=$?
    detail="$(shared_infra_failure_detail "$shared_err" "$shared_out")"
    report_line "  " "$HC_ERROR" "shared-infra manifest: validation failed (exit $rc)${detail:+ — $detail}"
  fi

  if make --no-print-directory -C "$SHARED_INFRA_ROOT" doctor "REGISTRY_FILE=$REGISTRY" \
      >"$shared_out" 2>"$shared_err"; then
    report_line "  " "$HC_OK" "shared-infra doctor: registry parity, runtime, and fixed-port checks passed"
  else
    rc=$?
    detail="$(shared_infra_failure_detail "$shared_err" "$shared_out")"
    report_line "  " "$HC_ERROR" "shared-infra doctor: read-only checks failed (exit $rc)${detail:+ — $detail}"
  fi
  rm -f "$shared_out" "$shared_err"
}

run_tier0 hc_canonical_on_main "$CANON"
run_tier0 hc_canonical_clean "$CANON"
run_tier0 hc_canonical_sync "$CANON"
run_tier0 hc_conformance_passes "$CANON"
run_tier0 hc_version_changelog_coherent "$CANON"
# Canonical-side, single-arg, WARN-class (report-only): the dod-receipt grammar
# anchor must live in core-rules/CLAUDE.md so execute receipts have a contract.
run_tier0 hc_receipt_grammar_present "$CANON"
# Canonical-side line-budget guardrail (adopt-loop, spec 008 — digest 2026-07-07
# hygiene): WARN when core-rules/CLAUDE.md crosses the ~200-line attention cliff
# where a CLAUDE.md starts being partially ignored. Advisory, future-growth
# guard; never blocks (WARN-class, report-only).
run_tier0 hc_claudemd_budget "$CANON"
# Codex-runtime precondition (spec 006 PD8): the Codex hooks — incl. the spec-gate
# teeth — silently no-op unless the runtime has [features] hooks = true. Global,
# no project arg; WARN-class when Codex is enabled but its runtime hooks are off.
run_tier0 hc_codex_hooks_enabled
# Codex plugin hook health: read-only node shim + manifest compatibility check.
run_tier0 hc_codex_plugin_surface

# Capture only canonical-clone precondition errors for the repair gate. Shared
# manifest/runtime errors still count toward the final exit, but they must not
# block unrelated inheritance repair: onboard runs with TRELLIS_SKIP_INFRA=1.
TIER0_ERROR=0
[ "$N_ERROR" -gt 0 ] && TIER0_ERROR=1
run_shared_infra_checks

# Canonical Tier-0 fix hints are report-only. Shared-infra failures have their
# own rows and do not imply that the canonical clone is off-main or dirty.
if [ "$TIER0_ERROR" -eq 1 ]; then
  add_hint "Tier 0: ensure the canonical clone ($CANON) is on 'main' and clean before trusting any project's inheritance (git -C \"$CANON\" checkout main; commit or stash changes)."
  # Under --fix the `== Suggested actions ==` block is suppressed, so the
  # Tier-0 remediation must surface here directly (Tier-0 is always report-only;
  # --fix never mutates the canonical clone).
  if [ "$DO_FIX" -eq 1 ]; then
    echo "  [info] Tier-0 is report-only — --fix never touches the canonical clone."
    echo "  [info] remediate: git -C \"$CANON\" checkout main  (then commit or stash any changes)"
    echo "  [info] --fix has applied nothing since v1.0.0-rc.25; every legacy row is reported [manual] with its migration."
  fi
fi
echo

# ---------------------------------------------------------------------------
# TIER 1 — per active project.
# ---------------------------------------------------------------------------
echo "== Tier 1: per-project inheritance =="

# Build the target list (registry minus blacklist, or the single --project).
TARGETS=()
if [ -n "$ONLY_PROJECT" ]; then
  found=0
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      [ "$n" = "$ONLY_PROJECT" ] && found=1
    done
  fi
  if [ "$found" -eq 0 ]; then
    echo "doctor: --project '$ONLY_PROJECT' is not in registry.md" >&2
    exit 2
  fi
  if is_blacklisted "$ONLY_PROJECT"; then
    echo "  (note: '$ONLY_PROJECT' is blacklisted — checking it anyway because explicitly requested)"
  fi
  TARGETS+=("$ONLY_PROJECT")
else
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      if is_blacklisted "$n"; then
        # Normal fleet scheduling skips blacklisted rows; report them as HELD
        # (still registered and reportable) rather than
        # silently. An explicit --project still validates (handled above).
        echo "  (held: $n — blacklisted; skipped)"
        continue
      fi
      TARGETS+=("$n")
    done
  fi
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "  (no active projects to check)"
fi

# emit <indent> <fn> <args...> — run a check, print its ✓/⚠/✗ row (which also
# tallies the counters), and return the check's status code through $? so the
# caller can branch on it to queue a fix hint. Captures status without tripping
# `set -e` (a bare check that returns non-zero would otherwise abort the run).
emit() {
  local indent="$1" fn="$2"; shift 2
  local msg rc
  if msg=$("$fn" "$@"); then rc=$?; else rc=$?; fi
  report_line "$indent" "$rc" "$msg"
  return "$rc"
}

# ---------------------------------------------------------------------------
# --fix plan accumulators (globals; read by the caller after run_project_checks)
# ---------------------------------------------------------------------------
# run_project_checks() resets these at entry and fills them as it classifies.
#   PLAN_MANUAL         — newline-joined [manual] descriptions (never applied).
#   PLAN_INFO           — newline-joined [info] descriptions (report-only).
#   PLAN_SEED_WORKTREES — newline-joined worktree roots missing inheritance,
#                         enumerated so the migration's scope is visible.
#
# There is deliberately NO [auto] accumulator (and no PLAN_HOOKS_* one). Since
# v1.0.0-rc.25 every writer that could repair a legacy direct-link row is gone,
# so all of them classify [manual]: doctor recognizes the layout and names the
# migration that owns it.
PLAN_MANUAL=""
PLAN_INFO=""
PLAN_SEED_WORKTREES=""

# A literal newline, used to join multi-line plan strings (bash 3.2-safe — no
# $'\n' inside eval).
PLAN_NL='
'

# plan_add <var-name> <line> — append a newline-joined plan line. Uses eval to
# write through the variable name (bash 3.2: no nameref).
plan_add() {
  local var="$1" line="$2" cur
  eval "cur=\${$var}"
  if [ -z "$cur" ]; then
    cur="$line"
  else
    cur="$cur$PLAN_NL$line"
  fi
  eval "$var=\$cur"
}

# run_project_checks <name> <proj> — run the EXACT P1 per-project check sequence
# (same emit rows, same add_hint calls — read-only path stays byte-identical)
# AND, in parallel, accumulate the structured --fix plan. Mode-agnostic: it
# always does both; the caller decides which channel to print and whether to
# act. Plan globals are RESET at entry so an under-fix re-check starts clean.
# Returns 0 always (per-check status is reflected in the printed rows + tallies).
# plan_add_migrate <name> <proj> <what> — the ONLY disposition a broken legacy
# surface has after cutover. There is no [auto] channel left: every writer that
# could re-seed a direct link refuses, so doctor reports the migration that owns
# the repair and mutates nothing.
plan_add_migrate() {
  local name="$1" proj="$2" what="$3"
  add_hint "$name: $what — legacy direct-link re-seeding was removed in v1.0.0-rc.25; migrate then attach: trellis migrate --prepare \"$proj\""
  plan_add PLAN_MANUAL "$what — no engine re-seeds a legacy direct-link project; run: trellis migrate --prepare \"$proj\" then trellis attach --fleet NAME \"$proj\""
}

run_project_checks() {
  local name="$1" proj="$2"
  local rc h
  local codex_missing codex_stale codex_detail csrc cfn cdst csha dsha

  # Reset plan for this project (caller reads these after the call).
  PLAN_MANUAL=""
  PLAN_INFO=""
  PLAN_SEED_WORKTREES=""

  # --- rules symlink (ERROR class) ---
  if emit "  " hc_rules_symlink "$proj" "$CANON"; then :; else
    rc=$?
    if [ "$rc" = "$HC_ERROR" ]; then
      # Distinguish missing (onboard fixes) vs stale/wrong (onboard will NOT,
      # never-clobber leaves wrong links — must rm then re-onboard).
      if [ -L "$proj/.claude/rules/trellis.md" ]; then
        plan_add_migrate "$name" "$proj" "stale/wrong rules symlink .claude/rules/trellis.md"
      else
        plan_add_migrate "$name" "$proj" "missing rules symlink .claude/rules/trellis.md"
      fi
    fi
  fi

  # --- @-import (ERROR if dead, WARN if absent) — MANUAL-only either way ---
  # onboard never writes/rewrites the @-line (it only echoes a suggestion), and
  # auto-editing a user-owned project CLAUDE.md is forbidden.
  if emit "  " hc_import_resolves "$proj" "$CANON"; then :; else
    rc=$?
    if [ "$rc" = "$HC_ERROR" ]; then
      add_hint "$name: dead/cross-machine @-import in CLAUDE.md — onboard does NOT rewrite it. Hand-edit the @-line to: @$CANON/core-rules/CLAUDE.md"
      plan_add PLAN_MANUAL "dead/cross-machine @-import in CLAUDE.md — hand-edit @-line to: @$CANON/core-rules/CLAUDE.md (never auto-edited)"
    elif [ "$rc" = "$HC_WARN" ]; then
      add_hint "$name: no @-import fallback in CLAUDE.md — add line: @$CANON/core-rules/CLAUDE.md"
      plan_add PLAN_MANUAL "no @-import fallback in CLAUDE.md — add line: @$CANON/core-rules/CLAUDE.md (never auto-edited)"
    fi
  fi

  # --- skills symlinks (WARN) ---
  if emit "  " hc_skills_symlinks "$proj" "$CANON"; then :; else
    plan_add_migrate "$name" "$proj" "incomplete skill set under .claude/skills/"
  fi

  # --- commands symlinks (WARN) ---
  if emit "  " hc_commands_symlinks "$proj" "$CANON"; then :; else
    plan_add_migrate "$name" "$proj" "incomplete command set under .claude/commands/"
  fi

  # --- harness-conditional artifacts (WARN), one row per enabled harness ---
  for h in "${HARNESSES[@]}"; do
    if emit "  " hc_harness_artifacts "$proj" "$h"; then :; else
      plan_add_migrate "$name" "$proj" "missing $h harness artifacts"
    fi
  done

  # --- Codex process-gate local config parity (WARN) — REPORT-ONLY ---
  # process-gate-local is project-owned, so doctor never auto-copies it; it only
  # flags when Codex would enforce a different local policy than Claude.
  if pg_has_harness codex; then
    if emit "  " hc_codex_process_gate_local_parity "$proj"; then :; else
      add_hint "$name: Codex process-gate-local config diverges from Claude — reconcile .agents/skills/process-gate-local/local.config.sh with .claude/skills/process-gate-local/local.config.sh"
      plan_add PLAN_MANUAL "Codex process-gate-local config diverges from Claude — reconcile .agents/skills/process-gate-local/local.config.sh with .claude/skills/process-gate-local/local.config.sh"
    fi
  fi

  # --- hook freshness (WARN) — [manual], never auto-repairable here ---
  # sync-hooks.sh reconciles a hook surface ONLY through the recorded immutable
  # release of a registered, attached row. A legacy direct-link project has
  # neither, so the delegation can only ever refuse; advertising it as an
  # [auto]/[hooks] repair promised a fix that cannot land. Report the remedy
  # that actually works instead.
  if emit "  " hc_hook_freshness "$proj" "$CANON"; then :; else
    add_hint "$name: Claude hook copies drift from canonical — NOT auto-repairable for a legacy direct-link project (sync-hooks.sh reconciles only a registered, attached row through its recorded immutable release). Adopt a release and attach the project: scripts/attach-project.sh attach \"$proj\""
    plan_add PLAN_MANUAL "Claude hook copies drift from canonical — no engine repairs a legacy direct-link project's hooks; attach it (scripts/attach-project.sh attach \"$proj\") so the portable flow owns hook reconciliation"
  fi

  # --- settings wiring (WARN) ---
  if emit "  " hc_settings_wiring "$proj" "$CANON"; then :; else
    rc=$?
    if [ ! -f "$proj/.claude/settings.json" ]; then
      plan_add_migrate "$name" "$proj" "missing .claude/settings.json"
    else
      # PRESENT but .hooks wiring drifts — MANUAL only. onboard skips an existing
      # settings.json (never-clobber); rollout-settings.sh only unions
      # .permissions.deny and leaves .hooks alone. Do NOT rm-then-reseed: the
      # file holds user-owned permissions.allow/ask + local deny entries.
      add_hint "$name: settings.json hook wiring differs from canonical — no engine fixes it; the file holds user-owned permissions. Review .claude/settings.json .hooks against core-rules/templates/claude-settings.json"
      plan_add PLAN_MANUAL "settings.json .hooks wiring drifts — no engine fixes it (do NOT rm/reseed; it holds user permissions). Review .claude/settings.json .hooks against core-rules/templates/claude-settings.json"
    fi
  fi

  # --- codex hook freshness (WARN) — only when codex is enabled; GATED ---
  if pg_has_harness codex; then
    if [ -d "$proj/.codex/hooks" ]; then
      # Reuse hook-freshness semantics against the codex surface by passing
      # the codex paths. We compare each project codex hook to canonical,
      # including hooks.json and the lib cores sourced by Stop hooks.
      codex_missing=""
      codex_stale=""
      if [ -f "$CANON/core-rules/codex/hooks.json" ]; then
        if [ ! -f "$proj/.codex/hooks.json" ]; then
          codex_missing="$codex_missing hooks.json"
        elif ! cmp -s "$CANON/core-rules/codex/hooks.json" "$proj/.codex/hooks.json"; then
          codex_stale="$codex_stale hooks.json"
        fi
      fi
      if [ -d "$CANON/core-rules/codex/hooks" ]; then
        for csrc in "$CANON/core-rules/codex/hooks"/*.sh; do
          [ -e "$csrc" ] || continue
          cfn="$(basename "$csrc")"
          cdst="$proj/.codex/hooks/$cfn"
          if [ ! -f "$cdst" ]; then codex_missing="$codex_missing $cfn"; continue; fi
          csha="$(shasum -a 256 "$csrc" | awk '{print $1}')"
          dsha="$(shasum -a 256 "$cdst" | awk '{print $1}')"
          [ "$csha" != "$dsha" ] && codex_stale="$codex_stale $cfn"
        done
      fi
      if [ -d "$CANON/core-rules/codex/hooks/lib" ]; then
        for csrc in "$CANON/core-rules/codex/hooks/lib"/*.sh; do
          [ -e "$csrc" ] || continue
          cfn="lib/$(basename "$csrc")"
          cdst="$proj/.codex/hooks/$cfn"
          if [ ! -f "$cdst" ]; then codex_missing="$codex_missing $cfn"; continue; fi
          csha="$(shasum -a 256 "$csrc" | awk '{print $1}')"
          dsha="$(shasum -a 256 "$cdst" | awk '{print $1}')"
          [ "$csha" != "$dsha" ] && codex_stale="$codex_stale $cfn"
        done
      fi
      for cfn in code-reviewer.sh ui-verify-core.sh spec-gate-core.sh aeo-gate-warn.sh; do
        csrc="$CANON/core-rules/hooks/lib/$cfn"
        [ -f "$csrc" ] || continue
        cdst="$proj/.codex/hooks/lib/$cfn"
        if [ ! -f "$cdst" ]; then codex_missing="$codex_missing lib/$cfn"; continue; fi
        csha="$(shasum -a 256 "$csrc" | awk '{print $1}')"
        dsha="$(shasum -a 256 "$cdst" | awk '{print $1}')"
        [ "$csha" != "$dsha" ] && codex_stale="$codex_stale lib/$cfn"
      done
      if [ -n "$codex_missing" ] || [ -n "$codex_stale" ]; then
        codex_detail=""
        [ -n "$codex_missing" ] && codex_detail="missing:${codex_missing}"
        [ -n "$codex_stale" ] && codex_detail="$codex_detail stale:${codex_stale}"
        report_line "  " "$HC_WARN" "codex-hooks: drift vs canonical —${codex_detail# }"
        add_hint "$name: Codex hook copies drift — NOT auto-repairable for a legacy direct-link project (sync-codex-hooks.sh reconciles only a registered, attached row through its recorded immutable release). Adopt a release and attach the project: scripts/attach-project.sh attach \"$proj\""
        plan_add PLAN_MANUAL "Codex hook copies drift from canonical — no engine repairs a legacy direct-link project's hooks; attach it (scripts/attach-project.sh attach \"$proj\") so the portable flow owns hook reconciliation"
      else
        report_line "  " "$HC_OK" "codex-hooks: in sync with canonical"
      fi
    fi
  fi

  # --- worktree inheritance (WARN) — [manual] since the cutover ---
  # seed-inheritance-symlinks.sh --legacy-mirror was removed at v1.0.0-rc.25.
  # Its replacement reconciles a worktree from the clone's REGISTRATION, which a
  # legacy direct-link clone does not have, so the repair is the clone's
  # migration — not a per-worktree command. Offenders are still enumerated so
  # the operator sees exactly which worktrees the migration has to cover.
  if emit "  " hc_worktree_inheritance "$proj" "$CANON"; then :; else
    local wt_offenders wt_path
    wt_offenders="$(hc_worktree_offenders "$proj" "$CANON")"
    if [ -n "$wt_offenders" ]; then
      add_hint "$name: linked worktree(s) missing inheritance symlinks — legacy mirroring was removed in v1.0.0-rc.25; migrate and attach the clone: trellis migrate --prepare \"$proj\""
      while IFS= read -r wt_path; do
        [ -n "$wt_path" ] || continue
        plan_add PLAN_SEED_WORKTREES "$wt_path"
        plan_add PLAN_MANUAL "linked worktree missing inheritance: $wt_path — attach the clone (trellis migrate --prepare \"$proj\" then trellis attach), which reconciles each worktree from the recorded release"
      done <<EOF
$wt_offenders
EOF
    fi
  fi

  # --- version-pin lag (INFO) — report-only, never auto-applied ---
  if emit "  " hc_version_pin_lag "$proj" "$CANON"; then :; else
    rc=$?
    if [ "$rc" = "$HC_INFO" ]; then
      add_hint "$name: trellis_version pin trails canonical (rules current via symlink) — adopt latest with: scripts/upgrade.sh --opt-in"
      plan_add PLAN_INFO "version pin trails canonical (rules current via symlink) — deliberate opt-in: scripts/upgrade.sh --opt-in (never auto-run)"
    fi
  fi

  # --- turbo outputs recurrence guard (WARN) — REPORT-ONLY, never auto-fixed ---
  # turbo.json is a user-owned project file: doctor NEVER auto-edits it (same
  # policy as the @-import). So this WARN queues a suggested-action hint ONLY and
  # touches NO PLAN_* accumulator — it deliberately stays out of the --fix
  # machinery. The operator applies the one-line glob per repo and commits it.
  if emit "  " hc_turbo_outputs "$proj"; then :; else
    add_hint "$name: turbo.json has an unscoped .next/** outputs glob (Next caches get tarred into the Turbo cache, the disk-blowup recurrence) — ${proj}/turbo.json: $(hc_turbo_fix_hint)"
  fi

  # --- process-enforcement inheritance-health checks (WARN) — REPORT-ONLY ---
  # All three are static (DL-P8a-01: never invoke the subject) advisory checks.
  # Like hc_turbo_outputs above, they queue a suggested-action hint ONLY and
  # touch NO PLAN_* accumulator — they stay out of the --fix machinery and never
  # flip the overall exit (WARN tallies into N_WARN, not N_ERROR).

  # reviewer resolvable: WARN only when a review hook is wired but its lib is
  # missing (silent fail-open). A project that runs no review is OK (no noise).
  if emit "  " hc_reviewer_resolvable "$proj" "$CANON"; then :; else
    add_hint "$name: code-review hook wired but lib/code-reviewer.sh is missing (review silently fails open) — re-seed hooks: scripts/sync-hooks.sh $name"
  fi

  # ui screenshot path: WARN when a UI project has no resolvable screenshot tool.
  if emit "  " hc_ui_screenshot_path "$proj" "$CANON"; then :; else
    add_hint "$name: UI project has no resolvable screenshot path for ui-verify — configure UI_SHOT_CMD or install a screenshot tool (e.g. playwright)"
  fi

  # pre-push wired to run-all.sh: WARN when the local merge gate is not wired.
  if emit "  " hc_prepush_wired_runall "$proj" "$CANON"; then :; else
    add_hint "$name: pre-push hook is not wired to process-gate's run-all.sh — the local merge gate is bypassed; re-seed the canonical pre-push hook"
  fi

  # --- Gate interpreter diagnostics (always advisory / no execution) ---
  # This mirrors stop-verify resolution so operators can see the concrete Node
  # and Python launchers before an enforcement hook runs.
  emit "  " hc_gate_interpreters "$proj"

  return 0
}

# print_project_plan <name> <proj> — print the tagged [manual]/[info] plan built
# by the last run_project_checks call. Used by --dry-run and as the narration
# for --fix. Touches NOTHING.
#
# There is deliberately NO [auto] channel: the cutover removed every writer that
# could re-seed a legacy direct link, so a legacy row's only honest disposition
# is the migration that owns it.
print_project_plan() {
  local name="$1" proj="$2" line
  echo "  -- plan for $name --"
  if [ -n "$PLAN_MANUAL" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "  [manual] $line"
    done <<EOF
$PLAN_MANUAL
EOF
  fi
  if [ -n "$PLAN_INFO" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "  [info] $line"
    done <<EOF
$PLAN_INFO
EOF
  fi
  if [ -z "$PLAN_MANUAL" ] && [ -z "$PLAN_INFO" ]; then
    echo "  (nothing to do — healthy)"
  fi
}

# apply_project_fix <name> <proj> — since v1.0.0-rc.25 this APPLIES NOTHING.
# The cutover removed onboard-project.sh --legacy and
# seed-inheritance-symlinks.sh --legacy-mirror, which were the only mutating
# actions doctor ever delegated for a legacy direct-link row. Both now refuse
# (exit 2), so attempting them would only manufacture a failure. The function is
# retained so `--fix` keeps working as an invocation and re-prints the migration
# each row needs, in the same place the applied actions used to appear.
apply_project_fix() {
  local name="$1" proj="$2" p
  echo "  -- applying fixes for $name --"
  echo "  [manual] legacy direct-link repair was removed in v1.0.0-rc.25; doctor diagnoses this layout and never re-seeds it."
  if [ -n "$PLAN_MANUAL" ] || [ -n "$PLAN_SEED_WORKTREES" ]; then
    echo "  [manual] migrate the checkout, then attach it:"
    echo "  [manual]   trellis migrate --prepare \"$proj\""
    echo "  [manual]   trellis attach --fleet NAME \"$proj\""
  fi
  if [ "$DO_FIX_HOOKS" -eq 1 ]; then
    echo "  [manual] --fix-hooks is inert: a legacy direct-link project has no registered, attached row for sync-hooks.sh/sync-codex-hooks.sh to reconcile through its recorded immutable release."
  fi
  if [ -n "$PLAN_MANUAL" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && echo "  [manual] $p"
    done <<EOF
$PLAN_MANUAL
EOF
  fi
  if [ -n "$PLAN_INFO" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && echo "  [info] $p"
    done <<EOF
$PLAN_INFO
EOF
  fi
}

if [ "${#TARGETS[@]}" -gt 0 ]; then
  for name in "${TARGETS[@]}"; do
    proj="$(resolve_project_path "$name")"
    echo

    # Project dir missing: ERROR, not auto-fixable (onboard needs an existing
    # git repo). Report identically in every mode and move on.
    if [ ! -d "$proj" ]; then
      report_line "" "$HC_ERROR" "$name — project dir not on disk ($proj)"
      add_hint "$name: project directory missing at $proj — clone/restore it, then: trellis migrate --prepare \"$proj\" && trellis attach --fleet NAME \"$proj\""
      if [ "$DO_FIX" -eq 1 ]; then
        echo "  [manual] project dir not on disk — nothing to diagnose or migrate. Clone/restore $proj, then: trellis migrate --prepare \"$proj\" && trellis attach --fleet NAME \"$proj\""
      fi
      continue
    fi
    echo "$name ($proj)"

    if [ "$DO_FIX" -eq 0 ]; then
      # READ-ONLY path — byte-identical to P1: single pass, tally on, hints
      # collected for the `== Suggested actions ==` block printed after the loop.
      run_project_checks "$name" "$proj"
      continue
    fi

    if [ "$DO_DRY_RUN" -eq 1 ]; then
      # Single pass, tallies ON (no apply, no after-pass — no double-count risk).
      # The summary then reports the diagnosed (BEFORE) counts; exit is forced 0.
      run_project_checks "$name" "$proj"
      print_project_plan "$name" "$proj"
      continue
    fi

    # Real --fix. The "before" pass builds the plan with tallies DISABLED so the
    # summary/exit reflect POST-FIX state only.
    TALLY_ENABLED=0
    run_project_checks "$name" "$proj"
    TALLY_ENABLED=1

    # Apply the [auto] (+ gated [hooks]) actions using the BEFORE plan, THEN
    # re-run the checks (tallies ON) to show the resulting status.
    apply_project_fix "$name" "$proj"
    echo "  -- re-checking $name after fixes --"
    run_project_checks "$name" "$proj"
  done
fi

# ---------------------------------------------------------------------------
# Tooling baseline — dev-environment health (Node + package-manager resolution
# in non-login shells, .nvmrc/node coherence). Distinct from inheritance:
# WARN at worst, never gates the exit. Guards the 2026-05-31 regression where
# git hooks (non-login) resolved the wrong Node and lost pnpm.
# ---------------------------------------------------------------------------
echo
echo "== Tooling baseline =="
run_tier0 hc_tooling_noninteractive_path

node_major="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || true)"
if [ -z "$node_major" ]; then
  report_line "  " "$HC_OK" ".nvmrc/node coherence skipped (node not on PATH)"
else
  nvmrc_seen=0
  nvmrc_bad=""
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    for name in "${TARGETS[@]}"; do
      f="$(resolve_project_path "$name")/.nvmrc"
      [ -f "$f" ] || continue
      nvmrc_seen=1
      want="$(tr -dc '0-9.' < "$f" 2>/dev/null | cut -d. -f1)"
      [ -n "$want" ] && [ "$want" != "$node_major" ] && nvmrc_bad="$nvmrc_bad $name(.nvmrc=$want)"
    done
  fi
  if [ "$nvmrc_seen" -eq 0 ]; then
    report_line "  " "$HC_OK" "no project .nvmrc pins to compare against node v$node_major"
  elif [ -n "$nvmrc_bad" ]; then
    report_line "  " "$HC_WARN" ".nvmrc pins differ from running node v$node_major:$nvmrc_bad — hooks may run under the wrong Node"
    add_hint "Tooling: align these projects' .nvmrc with the active Node major (v$node_major) or nvm-use the pinned version. See gotchas: non-login hooks + Node baseline."
  else
    report_line "  " "$HC_OK" "all project .nvmrc pins match running node v$node_major"
  fi
fi

echo

# ---------------------------------------------------------------------------
# Fix hints — READ-ONLY mode only. Under --fix/--dry-run the per-project plan is
# printed inline ([auto]/[hooks]/[manual]/[info]); this block is suppressed so
# the two channels never duplicate each other.
# ---------------------------------------------------------------------------
if [ "$DO_FIX" -eq 0 ] && [ "${#HINTS[@]}" -gt 0 ]; then
  echo "== Suggested actions =="
  for h in "${HINTS[@]}"; do
    printf '  - %s\n' "$h"
  done
  echo
fi

# ---------------------------------------------------------------------------
# Summary + exit
# ---------------------------------------------------------------------------
# --dry-run changed nothing and always exits 0 (deliberate branch, not a
# fall-through): the summary below reflects the BEFORE state, but the plan was
# never applied, so the exit code must not claim success/failure of a fix.
if [ "$DO_DRY_RUN" -eq 1 ]; then
  echo "== Summary (--dry-run: nothing applied) =="
  printf '%s %d error(s)  %s %d warning(s)  %s %d info — diagnosed, NOT fixed\n' \
    "$GLYPH_ERR" "$N_ERROR" "$GLYPH_WARN" "$N_WARN" "$GLYPH_INFO" "$N_INFO"
  echo "(dry-run: every action above is [manual] — since v1.0.0-rc.25 --fix applies nothing to a legacy layout)"
  exit 0
fi

echo "== Summary =="
if [ "$N_ERROR" -eq 0 ] && [ "$N_WARN" -eq 0 ] && [ "$N_INFO" -eq 0 ]; then
  echo "$GLYPH_OK healthy — no drift detected (${#TARGETS[@]} project(s) checked)"
  exit 0
fi

printf '%s %d error(s)  %s %d warning(s)  %s %d info\n' \
  "$GLYPH_ERR" "$N_ERROR" "$GLYPH_WARN" "$N_WARN" "$GLYPH_INFO" "$N_INFO"

if [ "$N_ERROR" -gt 0 ]; then
  echo "$GLYPH_ERR inheritance is broken for at least one project (or the canonical clone is off-main/dirty)."
  exit 1
fi

if [ "$N_WARN" -gt 0 ]; then
  echo "$GLYPH_WARN degraded but no inheritance-breaking errors."
else
  # Only INFO items (e.g. canonical behind-origin, version-pin lag). INFO is not
  # degraded, so use the info glyph rather than the WARN glyph here.
  echo "$GLYPH_INFO informational notes only — inheritance healthy."
fi
exit 0

}

if doctor_args_force_portable_mode "$@"; then
  DOCTOR_MODE=portable
else
  DOCTOR_MODE="$(doctor_select_mode)" || exit "$?"
fi
if [ "$DOCTOR_MODE" = legacy ]; then
  legacy_doctor_main "$@"
  exit "$?"
fi

. "$SCRIPT_DIR/lib/trellis-home.sh"
. "$SCRIPT_DIR/lib/release-store.sh"
. "$SCRIPT_DIR/lib/local-registry.sh"
. "$SCRIPT_DIR/lib/surface-plan.sh"
. "$SCRIPT_DIR/lib/attachment.sh"
. "$SCRIPT_DIR/lib/health-checks.sh"

ONLY_PROJECT=""; ONLY_FLEET=""; DO_FIX=0; DO_DRY_RUN=0
usage() {
  cat <<'EOF'
Usage: trellis doctor [--home PATH] [--fleet NAME] [--project ID]
       trellis doctor --fix [--home PATH] [--fleet NAME] [--project ID] [--dry-run]

Enumerates local registry rows including unavailable paths. Validates the
report-only user-surface row, immutable releases, exact local attachment
ownership, local excludes, and manifest-driven Claude/Codex leaves.
--fix repairs only safe project attachment rows through attach/relink/recover;
the user-surface row is report-only and prints an attach/relink remedy. It
never deletes project-owned files or migrates legacy/mixed layouts.

Usage visibility diagnostics are advisory and read-only: they inspect one private
snapshot, never collect, refresh, probe providers, or create/migrate a store.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -ge 2 ] || { echo 'doctor: --home requires PATH' >&2; exit 2; }; TRELLIS_HOME="$2"; export TRELLIS_HOME; shift 2 ;;
    --fleet) [ "$#" -ge 2 ] || { echo 'doctor: --fleet requires NAME' >&2; exit 2; }; ONLY_FLEET="$2"; shift 2 ;;
    --project) [ "$#" -ge 2 ] || { echo 'doctor: --project requires ID' >&2; exit 2; }; ONLY_PROJECT="$2"; shift 2 ;;
    --fix) DO_FIX=1; shift ;;
    --dry-run) DO_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "doctor: unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "$DO_DRY_RUN" -eq 0 ] || [ "$DO_FIX" -eq 1 ] || { echo 'doctor: --dry-run requires --fix' >&2; exit 2; }
[ -z "$ONLY_FLEET" ] || trellis_home_require_fleet_name "$ONLY_FLEET" || exit "$?"
[ -z "$ONLY_PROJECT" ] || local_registry_require_project_id "$ONLY_PROJECT" || exit "$?"
command -v jq >/dev/null 2>&1 || { echo 'doctor: jq is required' >&2; exit "$TRELLIS_EX_UNAVAILABLE"; }

HOME_PATH="$(trellis_home_resolve "")" || exit "$?"
REGISTRY_PATH="$(local_registry_path "$HOME_PATH")" || exit "$?"
GLYPH_OK='✓'; GLYPH_WARN='⚠'; GLYPH_ERR='✗'; GLYPH_INFO='i'
N_ERROR=0; N_WARN=0; N_INFO=0; ROWS_CHECKED=0; DOCTOR_EXIT=0

# Portable diagnostics preserve their public outcome class even though the
# shared health predicates use HC_ERROR as a boolean. Legacy compatibility
# checks retain their historical boolean exit behavior in legacy_doctor_main.
record_portable_exit_class() {
  local code="${1:-$DOCTOR_EX_STATE}"
  case "$code" in
    1|"$DOCTOR_EX_USAGE"|"$DOCTOR_EX_CONFLICT"|"$DOCTOR_EX_STATE"|"$DOCTOR_EX_UNAVAILABLE") ;;
    *) code="$DOCTOR_EX_STATE" ;;
  esac
  if [ "$code" -gt "$DOCTOR_EXIT" ]; then
    DOCTOR_EXIT="$code"
  fi
}

portable_check_failure_class() {
  local fn="$1" output="$2"
  case "$fn" in
    hc_portable_source_root)
      printf '%s\n' "$DOCTOR_EX_UNAVAILABLE"
      ;;
    hc_portable_release|hc_portable_active_cli_release)
      case "$output" in
        *' is unavailable'*|*'no usable active_cli_release'*)
          printf '%s\n' "$DOCTOR_EX_UNAVAILABLE" ;;
        *) printf '%s\n' "$DOCTOR_EX_STATE" ;;
      esac
      ;;
    hc_portable_user_surface)
      case "${HC_PORTABLE_USER_SURFACE_STATE:-}" in
        conflict|stale) printf '%s\n' "$DOCTOR_EX_CONFLICT" ;;
        *) printf '%s\n' "$DOCTOR_EX_STATE" ;;
      esac
      ;;
    hc_portable_owner)
      case "${HC_PORTABLE_OWNER_STATE:-}" in
        conflict|runtime-missing) printf '%s\n' "$DOCTOR_EX_CONFLICT" ;;
        *) printf '%s\n' "$DOCTOR_EX_STATE" ;;
      esac
      ;;
    hc_portable_hooks_path)
      printf '%s\n' "$DOCTOR_EX_CONFLICT"
      ;;
    hc_portable_layout)
      case "${HC_PORTABLE_LAYOUT:-}:${HC_PORTABLE_OWNER_STATE:-}" in
        mixed/conflict:*|portable-attached:*|corrupt:conflict|corrupt:runtime-missing)
          printf '%s\n' "$DOCTOR_EX_CONFLICT" ;;
        *) printf '%s\n' "$DOCTOR_EX_STATE" ;;
      esac
      ;;
    hc_portable_excludes)
      case "$output" in
        *'owner block does not match'*|*'changed at '*|*'missing, duplicated, or modified'*)
          printf '%s\n' "$DOCTOR_EX_CONFLICT" ;;
        *) printf '%s\n' "$DOCTOR_EX_STATE" ;;
      esac
      ;;
    hc_portable_native_surfaces)
      case "$output" in
        *'selection does not exactly match'*|*'committed leaves differ'*|*'committed render bytes'* )
          printf '%s\n' "$DOCTOR_EX_CONFLICT" ;;
        *) printf '%s\n' "$DOCTOR_EX_STATE" ;;
      esac
      ;;
    *)
      printf '%s\n' "$DOCTOR_EX_STATE"
      ;;
  esac
}

report() {
  local indent="$1" status="$2" message="$3" exit_class="${4:-}" glyph
  case "$status" in
    "$HC_OK") glyph="$GLYPH_OK" ;;
    "$HC_WARN") glyph="$GLYPH_WARN"; N_WARN=$((N_WARN + 1)) ;;
    "$HC_ERROR")
      glyph="$GLYPH_ERR"
      N_ERROR=$((N_ERROR + 1))
      [ -n "$exit_class" ] || exit_class="$DOCTOR_EX_STATE"
      record_portable_exit_class "$exit_class"
      ;;
    "$HC_INFO") glyph="$GLYPH_INFO"; N_INFO=$((N_INFO + 1)) ;;
    *)
      glyph='?'
      N_ERROR=$((N_ERROR + 1))
      record_portable_exit_class "${exit_class:-$DOCTOR_EX_STATE}"
      ;;
  esac
  printf '%s%s %s\n' "$indent" "$glyph" "$message"
}
# Keep the function execution in this shell: portable checks publish exact
# ownership/layout state used to choose the bounded repair route.
run_check() {
  local indent="$1" fn="$2" output_file output status exit_class=""
  shift 2
  output_file="$(doctor_scratch_require && mktemp "$DOCTOR_SCRATCH_DIR/check.XXXXXXX")" || { report "$indent" "$HC_ERROR" 'doctor could not create a diagnostic scratch file' "$DOCTOR_EX_STATE"; return "$HC_ERROR"; }
  if "$fn" "$@" > "$output_file"; then status=0; else status=$?; fi
  output="$(cat "$output_file")"; rm -f "$output_file"
  if [ "$status" -eq "$HC_ERROR" ]; then
    exit_class="$(portable_check_failure_class "$fn" "$output")"
  fi
  report "$indent" "$status" "$output" "$exit_class"
  return "$status"
}
# ---------------------------------------------------------------------------
# Usage federation (spec 039) — READ-ONLY semantic inspection of the private
# usage store under TRELLIS_HOME.
#
# These checks deliberately do NOT invoke scripts/usage-federation.py against
# the operator's private store: its own doctor opens the store through
# UsageStore.open, which CREATES <TRELLIS_HOME>/usage/usage.sqlite3 and its
# directory when missing and fchmods both to 0600/0700 (store.py
# _open_private_file/_secure_sqlite_file). The throwaway CLI probe below is
# isolated inside the invocation scratch tree; a health report must never
# mutate local state.
#
# SQLite probe contract (ONE consistent snapshot per invocation): the store is
# WAL-mode (persistent in the file header), so a `-readonly` connection cannot
# open a quiescent store — its -shm does not exist until a live writer makes it
# — while opening the real file read-write would create -wal/-shm sidecars next
# to it. The database is therefore copied ONCE, together with its live -wal
# tail, into the invocation's private scratch tree, and every probe in the run
# aggregates over that same snapshot: one point-in-time view, so the counts one
# check reports cannot contradict the ages another reports. The operator's
# store sees only plain reads; nothing is created, chmodded, or written in
# place. A writer racing the copy can at worst cost the snapshot its WAL tail;
# every probe is advisory (WARN-class at worst), never a gate.
#
# All rows are WARN-class at worst (like the Tooling baseline): usage
# federation is an optional subsystem, a degraded or absent store is reported
# honestly without gating the exit, and none of these checks enters the
# --fix repair plan. USAGE_DB_SCHEMA_VERSION mirrors store.py's
# STORE_SCHEMA_VERSION (currently v5); bump it here when the store migrates
# forward.
#
# The usage visibility checks below are advisory and read-only. They use one
# private snapshot per invocation and never collect, refresh, probe providers,
# or create/migrate a store.
#
# hc_usage_cli validates the same surface the `trellis usage` dispatcher runs:
# scripts/usage-federation.py must be a regular executable file whose library
# imports resolve through this checkout's lib/. One invocation proves both —
# catalog loads from the release tree, the private-home rule is enforced, and
# exit codes follow TOP_STATUS_EXIT (0 complete / 4 partial / 5 unavailable,
# 2 usage). openrouter is NOT a fallback here or anywhere else in this file:
# an unavailable opencode-go endpoint is reported as exactly that.
# ---------------------------------------------------------------------------
USAGE_DB_SCHEMA_VERSION=5
hc_usage_cli() {
  local cli="$SCRIPT_DIR/usage-federation.py" home="$1" rc probe_json route
  if [ -L "$cli" ] || [ ! -f "$cli" ]; then
    printf 'usage-federation CLI missing at %s' "$cli"
    return "$HC_WARN"
  fi
  if [ ! -x "$cli" ]; then
    printf 'usage-federation CLI is not executable at %s' "$cli"
    return "$HC_WARN"
  fi
  if [ ! -r "$SCRIPT_DIR/lib/usage_federation/cli.py" ]; then
    printf 'usage-federation CLI library missing at lib/usage_federation/cli.py'
    return "$HC_WARN"
  fi
  # One throwaway invocation validates everything a static listing cannot: the
  # catalog loads from this checkout, the private-home rule is enforced, and
  # the exit contract matches TOP_STATUS_EXIT (0 complete / 4 partial /
  # 5 unavailable). It runs against a THROWAWAY private home inside the
  # invocation scratch tree, never against the operator's TRELLIS_HOME:
  # UsageStore.open migrates an older store forward on open (v1/v2/v3 -> v4) and
  # creates a missing one, and a health check must not do either to real
  # state. stdout JSON is parsed only to confirm an exit-5 run carries its
  # own unavailable receipt; nothing from it is ever printed.
  local probe_home
  doctor_scratch_require || {
    printf '%s' 'doctor: no private scratch tree for the usage-federation CLI probe' >&2
    return "$HC_WARN"
  }
  # Canonical spelling: the CLI's private-home rule refuses any path with a
  # symlink component (e.g. macOS /var), so resolve through pwd -P.
  probe_home="$(cd "$DOCTOR_SCRATCH_DIR" && pwd -P)/probe-home.XXXXXXXX"
  if ! mkdir "$probe_home" || ! chmod 700 "$probe_home"; then
    rm -rf "$probe_home"
    printf '%s' 'usage-federation CLI probe could not create a throwaway private home'
    return "$HC_WARN"
  fi
  # Bounded parser probes validate the public visibility routes and the private
  # receipt help route without entering watch, receipt begin/bind, refresh,
  # collection, or any provider/network path. Help output is intentionally
  # discarded so diagnostics remain content-free.
  for route in strip watch report receipt; do
    if ! TRELLIS_HOME="$probe_home" "$cli" "$route" --help >/dev/null 2>&1; then
      printf 'usage-federation %s help route failed validation' "$route"
      return "$HC_WARN"
    fi
  done

  probe_json="$(TRELLIS_HOME="$probe_home" "$cli" doctor --json 2>/dev/null)" && rc=0 || rc=$?
  case "$rc" in
    5)
      if printf '%s' "$probe_json" | jq -e '.store.available == false' >/dev/null 2>&1; then
        printf 'usage-federation CLI validated end-to-end (exit-5 store-unavailable receipt honored)'
      else
        printf 'usage-federation CLI exited %s without an unavailable-store receipt' "$rc"
        return "$HC_WARN"
      fi
      ;;
    *)
      printf 'usage-federation CLI doctor exited %s on a missing store (expected 5)' "$rc"
      return "$HC_WARN"
  esac
}
hc_usage_receipts() {
  local home="$1"
  local db="$home/usage/usage.sqlite3"
  local relations="" receipt_table="" binding_table="" shape="" summary=""
  local total_receipts="" total_bindings="" pending="" path_bound=""
  local session_bound="" unresolved="" invalid="" missing_binding=""
  local orphan_binding="" value=""

  if [ ! -f "$db" ] || [ -L "$db" ]; then
    printf 'dispatch receipt evidence unavailable: no existing private usage store'
    return "$HC_WARN"
  fi

  # Never inspect the live database directly. _hc_usage_sqlite reuses the
  # invocation-wide copied main database plus WAL tail.
  relations="$(_hc_usage_sqlite "$db" "
    SELECT
      (SELECT COUNT(*) FROM sqlite_master
       WHERE type = 'table' AND name = 'dispatch_receipts'),
      (SELECT COUNT(*) FROM sqlite_master
       WHERE type = 'table' AND name = 'dispatch_bindings')
  ")" || {
    printf 'dispatch receipt evidence unreadable: relation probe failed through a non-mutating snapshot'
    return "$HC_WARN"
  }
  IFS='|' read -r receipt_table binding_table <<< "$relations"
  case "$receipt_table|$binding_table" in
    1\|1) ;;
    *)
      printf 'dispatch receipt evidence unavailable: schema v4 receipt/binding relations are missing (counts not inferred as zero)'
      return "$HC_WARN"
      ;;
  esac

  # Validate the stable v4 columns and STRICT table declarations without
  # exposing the SQL or any private row values.
  shape="$(_hc_usage_sqlite "$db" "
    SELECT
      (SELECT COUNT(*) FROM pragma_table_info('dispatch_receipts')
       WHERE name IN ('dispatch_id', 'requested_at', 'requested_at_us',
                      'worktree', 'request_source', 'harness')),
      (SELECT COUNT(*) FROM pragma_table_info('dispatch_bindings')
       WHERE name IN ('dispatch_id', 'bound_at', 'bound_at_us',
                      'session_canonical_path', 'session_id', 'resolution')),
      (SELECT CASE WHEN lower(COALESCE(sql, '')) LIKE '%strict%'
                   THEN 1 ELSE 0 END
       FROM sqlite_master
       WHERE type = 'table' AND name = 'dispatch_receipts'),
      (SELECT CASE WHEN lower(COALESCE(sql, '')) LIKE '%strict%'
                   THEN 1 ELSE 0 END
       FROM sqlite_master
       WHERE type = 'table' AND name = 'dispatch_bindings')
  ")" || {
    printf 'dispatch receipt evidence unreadable: v4 relation shape could not be inspected'
    return "$HC_WARN"
  }
  case "$shape" in
    6\|6\|1\|1) ;;
    *)
      printf 'dispatch receipt evidence malformed: v4 receipt/binding relation shape is invalid'
      return "$HC_WARN"
      ;;
  esac

  summary="$(_hc_usage_sqlite "$db" "
    SELECT
      (SELECT COUNT(*) FROM dispatch_receipts),
      (SELECT COUNT(*) FROM dispatch_bindings),
      (SELECT COUNT(*) FROM dispatch_bindings WHERE resolution = 'pending'),
      (SELECT COUNT(*) FROM dispatch_bindings WHERE resolution = 'session_path_bound'),
      (SELECT COUNT(*) FROM dispatch_bindings WHERE resolution = 'session_bound'),
      (SELECT COUNT(*) FROM dispatch_bindings WHERE resolution = 'unresolved'),
      (SELECT COUNT(*) FROM dispatch_bindings
       WHERE resolution IS NULL
          OR resolution NOT IN
             ('pending', 'session_path_bound', 'session_bound', 'unresolved')),
      (SELECT COUNT(*) FROM dispatch_receipts AS r
       LEFT JOIN dispatch_bindings AS b ON b.dispatch_id = r.dispatch_id
       WHERE b.dispatch_id IS NULL),
      (SELECT COUNT(*) FROM dispatch_bindings AS b
       LEFT JOIN dispatch_receipts AS r ON r.dispatch_id = b.dispatch_id
       WHERE r.dispatch_id IS NULL)
  ")" || {
    printf 'dispatch receipt evidence unreadable: aggregate probe failed through a non-mutating snapshot'
    return "$HC_WARN"
  }
  IFS='|' read -r total_receipts total_bindings pending path_bound session_bound unresolved \
    invalid missing_binding orphan_binding <<< "$summary"
  for value in "$total_receipts" "$total_bindings" "$pending" "$path_bound" \
    "$session_bound" "$unresolved" "$invalid" "$missing_binding" "$orphan_binding"; do
    case "$value" in
      ''|*[!0-9]*)
        printf 'dispatch receipt evidence malformed: aggregate counts are not numeric'
        return "$HC_WARN"
        ;;
    esac
  done
  if [ "$invalid" -ne 0 ] || [ "$missing_binding" -ne 0 ] ||
     [ "$orphan_binding" -ne 0 ] || [ "$total_receipts" -ne "$total_bindings" ]; then
    printf 'dispatch receipt evidence malformed: receipts=%s bindings=%s invalid_resolution=%s missing_binding=%s orphan_binding=%s' \
      "$total_receipts" "$total_bindings" "$invalid" "$missing_binding" "$orphan_binding"
    return "$HC_WARN"
  fi

  printf 'dispatch receipt evidence readable (schema v4; receipts=%s; bindings=%s; pending=%s; session_path_bound=%s; session_bound=%s; unresolved=%s)' \
    "$total_receipts" "$total_bindings" "$pending" "$path_bound" "$session_bound" "$unresolved"
}
hc_usage_visibility() {
  local home="$1" db
  db="$home/usage/usage.sqlite3"
  local schema="" tables="" summary="" value="" visibility_status="$HC_OK"
  local lane_catalog_table="" advertised_table="" enumeration_table=""
  local enumeration_models_table="" outcomes_table="" observations_table=""
  local coverage_table=""
  local lane_count="" advertised_count="" enumeration_count=""
  local outcomes_count="" observation_count="" fresh_count="" stale_count=""
  local no_activity_count="" not_supported_count="" unreported_count=""
  local unavailable_count=""
  local auth_error_count=""
  local rate_limited_count=""
  local schema_error_count="" unknown_count="" coverage_count=""

  if [ ! -f "$db" ] || [ -L "$db" ]; then
    printf 'usage visibility unavailable: no existing private usage store (strip/watch/report remain read-only; transport=cli-only; http=none; daemon=none; provider_probes=forbidden)'
    return "$HC_WARN"
  fi

  # Keep visibility on the same invocation-wide snapshot as every other usage
  # check. This only reads the schema marker; it never opens the live database.
  schema="$(_hc_usage_sqlite "$db" 'SELECT MAX(version) FROM schema_version')" || {
    printf 'usage visibility unreadable: schema version probe failed through a non-mutating snapshot'
    return "$HC_WARN"
  }
  case "$schema" in
    ''|*[!0-9]*)
      printf 'usage visibility malformed: schema version is not numeric (no display state inferred)'
      return "$HC_WARN"
      ;;
    "$USAGE_DB_SCHEMA_VERSION") ;;
    *)
      printf 'usage visibility unavailable: schema v%s is not the required v%s (no display state inferred)' \
        "$schema" "$USAGE_DB_SCHEMA_VERSION"
      return "$HC_WARN"
      ;;
  esac

  # Verify relation presence before querying any relation. An older or
  # hand-created store must not turn a missing visibility relation into a
  # healthy empty count.
  tables="$(_hc_usage_sqlite "$db" "
    SELECT
      (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'lane_catalog'),
      (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'advertised_models'),
      (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'model_enumerations'),
      (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'model_enumeration_models'),
      (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'serving_outcomes'),
      (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'source_observations'),
      (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'source_coverage')
  ")" || {
    printf 'usage visibility unreadable: relation probe failed through a non-mutating snapshot'
    return "$HC_WARN"
  }
  IFS='|' read -r lane_catalog_table advertised_table enumeration_table \
    enumeration_models_table outcomes_table observations_table coverage_table <<< "$tables"
  case "$lane_catalog_table|$advertised_table|$enumeration_table|$enumeration_models_table|$outcomes_table|$observations_table|$coverage_table" in
    1\|1\|1\|1\|1\|1\|1) ;;
    *)
      printf 'usage visibility unavailable: schema v4 catalog/enumeration/serving relations are missing (counts not inferred as zero)'
      return "$HC_WARN"
      ;;
  esac

  # Counts are aggregate-only and use fixed, contract-defined state labels.
  # No model, provider, project, route, reason, path, or raw JSON value is
  # selected for public diagnostics. An empty observations relation is called
  # out as "none" below rather than presented as healthy numeric zero.
  summary="$(_hc_usage_sqlite "$db" "
    SELECT
      (SELECT COUNT(*) FROM lane_catalog),
      (SELECT COUNT(*) FROM advertised_models),
      (SELECT COUNT(*) FROM model_enumerations),
      (SELECT COUNT(*) FROM serving_outcomes),
      (SELECT COUNT(*) FROM source_observations),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'fresh'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'stale'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'no_activity'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'not_supported'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'unreported'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'unavailable'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'auth_error'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'rate_limited'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'schema_error'),
      (SELECT COUNT(*) FROM source_observations WHERE status = 'unknown'),
      (SELECT COUNT(*) FROM source_coverage)
  ")" || {
    printf 'usage visibility unreadable: aggregate probe failed through a non-mutating snapshot'
    return "$HC_WARN"
  }
  IFS='|' read -r lane_count advertised_count enumeration_count outcomes_count \
    observation_count fresh_count stale_count no_activity_count \
    not_supported_count unreported_count unavailable_count auth_error_count \
    rate_limited_count schema_error_count unknown_count coverage_count <<< "$summary"
  for value in "$lane_count" "$advertised_count" "$enumeration_count" \
    "$outcomes_count" "$observation_count" "$fresh_count" "$stale_count" \
    "$no_activity_count" "$not_supported_count" "$unreported_count" \
    "$unavailable_count" "$auth_error_count" "$rate_limited_count" \
    "$schema_error_count" "$unknown_count" "$coverage_count"; do
    case "$value" in
      ''|*[!0-9]*)
        printf 'usage visibility malformed: aggregate counts are not numeric (no display state inferred)'
        return "$HC_WARN"
        ;;
    esac
  done
  if [ "$stale_count" -ne 0 ] || [ "$unavailable_count" -ne 0 ] ||
     [ "$auth_error_count" -ne 0 ] || [ "$rate_limited_count" -ne 0 ] ||
     [ "$schema_error_count" -ne 0 ]; then
    visibility_status="$HC_WARN"
  fi
  if [ "$observation_count" -eq 0 ]; then
    printf 'usage visibility ready (schema v4; catalog=%s; advertised_models=%s; enumerations=%s; serving_outcomes=%s; observations=none; coverage=%s; routes=strip,watch,report; transport=cli-only; http=none; daemon=none; provider_probes=forbidden; advisory=read-only)' \
      "$lane_count" "$advertised_count" "$enumeration_count" "$outcomes_count" "$coverage_count"
    return "$visibility_status"
  fi
  printf 'usage visibility ready (schema v4; catalog=%s; advertised_models=%s; enumerations=%s; serving_outcomes=%s; observations=%s; states=fresh:%s,stale:%s,no_activity:%s,not_supported:%s,unreported:%s,unavailable:%s,auth_error:%s,rate_limited:%s,schema_error:%s,unknown:%s; coverage=%s; routes=strip,watch,report; transport=cli-only; http=none; daemon=none; provider_probes=forbidden; advisory=read-only)' \
    "$lane_count" "$advertised_count" "$enumeration_count" "$outcomes_count" \
    "$observation_count" "$fresh_count" "$stale_count" "$no_activity_count" \
    "$not_supported_count" "$unreported_count" "$unavailable_count" \
    "$auth_error_count" "$rate_limited_count" "$schema_error_count" \
    "$unknown_count" "$coverage_count"
  return "$visibility_status"
}


hc_usage_root() {
  local home="$1" uid
  if [ ! -e "$home" ]; then
    printf 'configured root absent at %s — usage federation unavailable' "$home"
    return "$HC_WARN"
  fi
  if ! _attachment_canonical_dir "$home"; then
    printf 'configured root at %s is a symlink or non-directory — usage federation unavailable' "$home"
    return "$HC_WARN"
  fi
  uid="$(stat -c %u "$home" 2>/dev/null || stat -f %u "$home" 2>/dev/null)" || {
    printf 'configured root at %s could not be inspected' "$home"
    return "$HC_WARN"
  }
  if [ "$uid" != "$(id -u)" ]; then
    printf 'configured root at %s is not owned by the effective user — store refuses to open' "$home"
    return "$HC_WARN"
  fi
  printf 'configured root usable for usage store (%s; mode %s)' "$home" "$(_attachment_mode "$home")"
}

hc_usage_store() {
  local home="$1" usage_dir db dir_mode db_mode summary
  usage_dir="$home/usage"
  db="$usage_dir/usage.sqlite3"
  if [ ! -e "$usage_dir" ] && [ ! -e "$db" ]; then
    printf 'private usage store not initialized at %s (unavailable; doctor never creates it)' "$db"
    return "$HC_WARN"
  fi
  if ! _attachment_canonical_dir "$usage_dir"; then
    printf 'usage path at %s is a symlink or non-directory — store unavailable' "$usage_dir"
    return "$HC_WARN"
  fi
  dir_mode="$(_attachment_mode "$usage_dir")" || {
    printf 'usage path at %s could not be inspected' "$usage_dir"
    return "$HC_WARN"
  }
  if [ "$dir_mode" != 700 ]; then
    printf 'usage directory mode is %s, expected 700 — store refuses to open until private' "$dir_mode"
    return "$HC_WARN"
  fi
  if [ ! -e "$db" ]; then
    printf 'usage database missing at %s (unavailable; doctor never creates it)' "$db"
    return "$HC_WARN"
  fi
  if ! _attachment_canonical_file "$db"; then
    printf 'usage database at %s is a symlink or non-regular file — store unavailable' "$db"
    return "$HC_WARN"
  fi
  db_mode="$(_attachment_mode "$db")" || {
    printf 'usage database at %s could not be inspected' "$db"
    return "$HC_WARN"
  }
  if [ "$db_mode" != 600 ]; then
    printf 'usage database mode is %s, expected 600 — store refuses to open until private' "$db_mode"
    return "$HC_WARN"
  fi
  summary="$(_hc_usage_sqlite "$db" \
    'SELECT COUNT(*), MIN(version), MAX(version) FROM schema_version')" || {
    printf 'usage database at %s exists but its schema could not be read through a non-mutating probe' "$db"
    return "$HC_WARN"
  }
  local rows min_version max_version
  rows="${summary%%|*}"
  summary="${summary#*|}"; min_version="${summary%%|*}"
  max_version="${summary#*|}"
  case "$rows${rows:+$min_version$max_version}" in
    ''|*[!0-9]*)
      printf 'usage database at %s has a malformed schema_version table — corrupt store' "$db"
      return "$HC_WARN"
      ;;
  esac
  if [ "$min_version" != 1 ] || [ "$max_version" -lt 1 ] ||
     [ "$rows" != "$((max_version - min_version + 1))" ]; then
    printf 'usage database at %s has a non-contiguous schema_version history — corrupt store' "$db"
    return "$HC_WARN"
  fi
  if [ "$max_version" -gt "$USAGE_DB_SCHEMA_VERSION" ]; then
    printf 'usage database schema v%s is newer than this checkout understands (max v%s) — upgrade before use' \
      "$max_version" "$USAGE_DB_SCHEMA_VERSION"
    return "$HC_WARN"
  fi
  printf 'private usage store readable (%s; dir mode %s, db mode %s, schema v%s)' \
    "$db" "$dir_mode" "$db_mode" "$max_version"
}

# _hc_usage_snapshot <database> — materialize THE ONE snapshot of the live WAL
# store this invocation probes, and print its path. The file name is FIXED
# inside the private scratch tree: whichever probe runs first creates it and
# every later probe — including ones running inside command substitutions,
# where an assignment would die with the subshell — reuses the same bytes.
# The main database is copied first, then the live -wal tail beside it; the
# first sqlite3 open replays that WAL into the copy, so every probe in the run
# aggregates over ONE point-in-time view that includes committed-but-
# uncheckpointed transactions (a plain file copy of only the main db would
# silently miss them). A writer racing the two copies can at worst make the
# tail partially inapplicable; recovery stops cleanly at the mismatch and the
# probes stay advisory. Any -wal/-shm/-journal sidecars SQLite leaves beside
# the snapshot stay inside the 0700 scratch tree; no function installs its own
# trap — the invocation-wide EXIT/HUP/INT/TERM traps at the top of doctor.sh
# own cleanup even when a probe never returns.
_hc_usage_snapshot() {
  local db="$1" snap="$DOCTOR_SCRATCH_DIR/usage-snapshot.sqlite3"
  if [ -f "$snap" ]; then
    printf '%s' "$snap"
    return 0
  fi
  : > "$snap" || return 1
  chmod 600 "$snap"
  if ! cp "$db" "$snap" 2>/dev/null; then
    rm -f "$snap" "$snap-wal" "$snap-shm" "$snap-journal"
    return 1
  fi
  if [ -f "$db-wal" ]; then
    cp "$db-wal" "$snap-wal" 2>/dev/null || :
  fi
  printf '%s' "$snap"
}

_hc_usage_sqlite() {
  local db="$1" sql="$2" snap result rc
  doctor_scratch_require || {
    printf '%s' 'doctor: no private scratch tree available for a read-only usage probe' >&2
    return 1
  }
  snap="$(_hc_usage_snapshot "$db")" || return 1
  result="$(sqlite3 "$snap" "$sql" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$result"
  return "$rc"
}

hc_usage_watermarks() {
  local home="$1" db counts status n total=0 degraded="" last_us now age="unknown"
  db="$home/usage/usage.sqlite3"
  if [ ! -f "$db" ] || [ -L "$db" ]; then
    printf 'source watermarks unreadable: no existing private usage store'
    return "$HC_WARN"
  fi
  counts="$(_hc_usage_sqlite "$db" \
    "SELECT status || '=' || COUNT(*) FROM source_files WHERE is_current = 1 GROUP BY status ORDER BY status")" || {
    printf 'source watermarks unreadable: watermark query failed through a non-mutating probe'
    return "$HC_WARN"
  }
  while IFS='=' read -r status n; do
    [ -n "$status" ] || continue
    case "$n" in
      ''|*[!0-9]*) printf 'source watermarks unreadable: malformed watermark row'; return "$HC_WARN" ;;
    esac
    total=$((total + n))
    case "$status" in
      discovered|ready|complete) : ;;
      *)
        case "$status" in
          *[!a-z0-9_]*) status="<unsafe>" ;;
        esac
        degraded="$degraded $status=$n"
        ;;
    esac
  done <<EOF
$counts
EOF
  if [ "$total" -eq 0 ]; then
    printf 'no watermarked transcript sources recorded yet'
    return "$HC_INFO"
  fi
  last_us="$(_hc_usage_sqlite "$db" \
    'SELECT MAX(last_scan_at_us) FROM source_files WHERE is_current = 1')" || last_us=""
  case "${last_us:-}" in
    ''|*[!0-9]*) : ;;
    *)
      now="$(date +%s)"
      age=$((now - last_us / 1000000))
      [ "$age" -ge 0 ] || age=0
      age="${age}s old"
      ;;
  esac
  # Counts and ages only: transcript paths and content are never printed.
  if [ -n "$degraded" ]; then
    printf '%d current watermark(s); degraded:%s (newest scan %s)' "$total" "$degraded" "$age"
    return "$HC_WARN"
  fi
  printf '%d current watermark(s) healthy; newest scan %s' "$total" "$age"
}

SAFE_REPAIR=""; SAFE_REPAIR_BLOCKED=""; SAFE_REPAIR_BLOCKED_CLASS=""; SAFE_REPAIR_HARNESSES=""
SAFE_REPAIR_OWNER_SHA256=""; SAFE_REPAIR_OWNER_PARENT_DEV_INO=""
journal_matches_registry_row() {
  local candidate="$1" fleet="$2" project_id="$3" root="$4" checkout_id="$5"
  local worktree_id="$6" attachment_id="$7" release="$8" status canonical
  status="$(jq -r '.status // empty' "$candidate" 2>/dev/null)" || return 2
  case "$status" in
    prepared)
      canonical="$(_attachment_journal_path "$HOME_PATH" "$attachment_id")"
      [ "$candidate" = "$canonical" ] || return 1
      _attachment_journal_json_valid "$candidate" >/dev/null 2>&1 || return 2
      jq -e --arg fleet "$fleet" --arg project "$project_id" --arg root "$root" \
        --arg checkout "$checkout_id" --arg worktree "$worktree_id" \
        --arg attachment "$attachment_id" --arg release "$release" '
          .fleet == $fleet and .project_id == $project
          and .project_root == $root and .worktree_root == $root
          and .checkout_id == $checkout and .worktree_id == $worktree
          and .attachment_id == $attachment and .release == $release
        ' "$candidate" >/dev/null 2>&1
      ;;
    detaching)
      canonical="$(_attachment_detach_journal_path "$HOME_PATH" "$attachment_id")"
      [ "$candidate" = "$canonical" ] || return 1
      _attachment_detach_journal_valid "$candidate" >/dev/null 2>&1 || return 2
      jq -e --arg fleet "$fleet" --arg project "$project_id" --arg root "$root" \
        --arg checkout "$checkout_id" --arg worktree "$worktree_id" \
        --arg attachment "$attachment_id" --arg release "$release" '
          .checkout_id == $checkout and .worktree_id == $worktree
          and .attachment_id == $attachment
          and .original_owner.fleet == $fleet and .original_owner.project_id == $project
          and .original_owner.project_root == $root and .original_owner.worktree_root == $root
          and .original_owner.checkout_id == $checkout and .original_owner.worktree_id == $worktree
          and .original_owner.attachment_id == $attachment and .original_owner.release == $release
        ' "$candidate" >/dev/null 2>&1
      ;;
    *) return 2 ;;
  esac
}

safe_repair_capture_owner_binding() {
  local owner="$1" parent digest parent_identity
  SAFE_REPAIR_OWNER_SHA256=""
  SAFE_REPAIR_OWNER_PARENT_DEV_INO=""
  _attachment_canonical_file "$owner" || return 1
  [ "$(_attachment_mode "$owner")" = 600 ] || return 1
  parent="$(dirname "$owner")" || return 1
  _attachment_canonical_dir "$parent" || return 1
  [ "$(_attachment_mode "$parent")" = 700 ] || return 1
  digest="$(_attachment_hash "$owner")" || return 1
  parent_identity="$(_attachment_fs_identity "$parent")" || return 1
  printf '%s' "$parent_identity" | LC_ALL=C grep -Eq '^[0-9][0-9]*:[0-9][0-9]*$' || return 1
  SAFE_REPAIR_OWNER_SHA256="$digest"
  SAFE_REPAIR_OWNER_PARENT_DEV_INO="$parent_identity"
}
plan_safe_repair() {
  local root="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5"
  local attachment_id="$6" release="$7" owner_state="$8" layout="$9" release_ok="${10}"
  local excludes_ok="${11}" surfaces_ok="${12}" registry_status="${13}" excluded="${14}"
  local identity_state="${15}" diagnostics_ok="${16}" harnesses="${17}" hooks_authority="${18}"
  local journal candidate journal_name status journal_root rc matches=0 normalized_harnesses matched_journal matched_journal_state manual_recover_command owner
  SAFE_REPAIR=""; SAFE_REPAIR_BLOCKED=""; SAFE_REPAIR_BLOCKED_CLASS=""; SAFE_REPAIR_HARNESSES=""
  SAFE_REPAIR_OWNER_SHA256=""; SAFE_REPAIR_OWNER_PARENT_DEV_INO=""
  [ "$registry_status" = active ] || return 0
  [ "$excluded" = false ] || return 0
  [ "$identity_state" = verified ] || return 0
  journal="$HOME_PATH/state/attachment-journals"
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    if ! _attachment_canonical_dir "$journal" || [ "$(_attachment_mode "$journal")" != 700 ]; then
      SAFE_REPAIR_BLOCKED='attachment journal directory is a symlink, non-directory, or has unsafe permissions'
      return 0
    fi
    for candidate in "$journal"/* "$journal"/.[!.]* "$journal"/..?*; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      journal_name="${candidate##*/}"
      case "$journal_name" in
        *.json) ;;
        *)
          SAFE_REPAIR_BLOCKED='attachment journal directory has an unexpected entry'
          return 0
          ;;
      esac
      if [ -L "$candidate" ] || [ ! -f "$candidate" ] || ! _attachment_no_symlink_components "$candidate" 0; then
        SAFE_REPAIR_BLOCKED='attachment journal entry is a symlink or non-regular file'
        return 0
      fi
      if [ "$(_attachment_mode "$candidate")" != 600 ]; then
        SAFE_REPAIR_BLOCKED='attachment journal entry has unsafe permissions'
        return 0
      fi
      status="$(jq -r '.status // empty' "$candidate" 2>/dev/null)" || {
        SAFE_REPAIR_BLOCKED='attachment journal entry is corrupt or has an unsafe shape'
        return 0
      }
      case "$status" in
        prepared)
          _attachment_journal_json_valid "$candidate" >/dev/null 2>&1 || {
            SAFE_REPAIR_BLOCKED='attachment journal entry is corrupt or has an unsafe shape'
            return 0
          }
          journal_root="$(jq -r '.worktree_root // empty' "$candidate" 2>/dev/null)" || {
            SAFE_REPAIR_BLOCKED='attachment journal entry is corrupt or has an unsafe shape'
            return 0
          }
          ;;
        detaching)
          _attachment_detach_journal_valid "$candidate" >/dev/null 2>&1 || {
            SAFE_REPAIR_BLOCKED='attachment journal entry is corrupt or has an unsafe shape'
            return 0
          }
          journal_root="$(jq -r '.original_owner.worktree_root // empty' "$candidate" 2>/dev/null)" || {
            SAFE_REPAIR_BLOCKED='attachment journal entry is corrupt or has an unsafe shape'
            return 0
          }
          ;;
        *)
          SAFE_REPAIR_BLOCKED='attachment journal entry is corrupt or has an unsafe shape'
          return 0
          ;;
      esac
      [ "$journal_root" = "$root" ] || continue
      if journal_matches_registry_row "$candidate" "$fleet" "$project_id" "$root" \
          "$checkout_id" "$worktree_id" "$attachment_id" "$release"; then
        matches=$((matches + 1))
        matched_journal="$candidate"
        matched_journal_state="$status"
        if [ "$matches" -gt 1 ]; then
          SAFE_REPAIR_BLOCKED='multiple exact attachment journals match this registry row'
          return 0
        fi
      else
        rc=$?
        if [ "$rc" -eq 1 ]; then
          SAFE_REPAIR_BLOCKED='attachment journal does not exactly match this registry row'
        else
          SAFE_REPAIR_BLOCKED='attachment journal is corrupt or has an unsafe shape'
        fi
        return 0
      fi
    done
  fi
  if [ "$matches" -eq 1 ]; then
    printf -v manual_recover_command 'trellis recover --home %q %q' "$HOME_PATH" "$root"
    SAFE_REPAIR_BLOCKED="attachment journal at $matched_journal (state=$matched_journal_state) requires manual recovery; review it, then run $manual_recover_command. Automatic recovery is withheld because its plan provenance cannot be proven"
    SAFE_REPAIR_BLOCKED_CLASS="$DOCTOR_EX_STATE"
    return 0
  fi
  case "$layout:$owner_state:$release_ok" in
    inert-non-user:missing:true)
      normalized_harnesses="$(local_registry_normalize_harnesses "$harnesses" 2>/dev/null || true)"
      if [ -z "$normalized_harnesses" ] || [ "$normalized_harnesses" = '[]' ]; then
        SAFE_REPAIR_BLOCKED='registry harness selection is empty or invalid; attach cannot choose native surfaces'
        return 0
      fi
      if [ "$diagnostics_ok" = true ] && [ -f "$root/.trellis.json" ]; then
        SAFE_REPAIR=attach
        SAFE_REPAIR_HARNESSES="$normalized_harnesses"
      fi
      ;;
    portable-attached:runtime-missing:true)
      case "$hooks_authority" in
        managed) ;;
        operator-owned)
          SAFE_REPAIR_BLOCKED='automatic relink is withheld because core.hooksPath is operator-owned; no repair was attempted'
          SAFE_REPAIR_BLOCKED_CLASS="$DOCTOR_EX_CONFLICT"
          return 0
          ;;
        *)
          SAFE_REPAIR_BLOCKED='automatic relink is withheld because managed hook authority could not be proven; no repair was attempted'
          SAFE_REPAIR_BLOCKED_CLASS="$DOCTOR_EX_CONFLICT"
          return 0
          ;;
      esac
      if [ "$excludes_ok" = true ] && [ "$surfaces_ok" = true ]; then
        owner="$HOME_PATH/state/attachments/$checkout_id/$worktree_id.json"
        if safe_repair_capture_owner_binding "$owner"; then
          SAFE_REPAIR=relink
        else
          SAFE_REPAIR_BLOCKED='attachment owner changed or cannot be safely bound for relink'
          SAFE_REPAIR_BLOCKED_CLASS="$DOCTOR_EX_CONFLICT"
        fi
      fi
      ;;
  esac
}
print_auto_command() {
  local argument
  printf '  [auto]'
  for argument in "$@"; do printf ' %q' "$argument"; done
  printf '\n'
}
active_cli_repair_tool() {
  local active_release release_path repair_tool
  hc_portable_machine_config "$HOME_PATH" >/dev/null || return "$TRELLIS_EX_STATE"
  active_release="$(jq -r '.active_cli_release // empty' "$HOME_PATH/config.json")" || return "$TRELLIS_EX_STATE"
  release_path="$(TRELLIS_HOME="$HOME_PATH" release_store_locate "$active_release" 2>/dev/null)" || return "$?"
  repair_tool="$release_path/payload/scripts/attach-project.sh"
  if ! _attachment_canonical_file "$repair_tool" || [ ! -x "$repair_tool" ]; then
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$repair_tool"
}
apply_safe_repair() {
  local mode="$1" root="$2" fleet="$3" project_id="$4" checkout_id="$5" worktree_id="$6"
  local attachment_id="$7" release="$8" harnesses="$9" owner_sha256="${10}" owner_parent_dev_ino="${11}" harness repair_tool=""
  local -a args=() binding=()
  binding=(
    --expected-fleet "$fleet"
    --expected-project-id "$project_id"
    --expected-root "$root"
    --expected-checkout-id "$checkout_id"
    --expected-worktree-id "$worktree_id"
    --expected-attachment-id "$attachment_id"
    --expected-release "$release"
    --expected-harnesses-json "$harnesses"
  )
  case "$mode" in
    attach)
      while IFS= read -r harness; do [ -n "$harness" ] && args+=(--harness "$harness"); done < <(printf '%s\n' "$harnesses" | jq -r '.[]')
      if [ "$DO_DRY_RUN" -eq 1 ]; then
        print_auto_command trellis attach --home "$HOME_PATH" --fleet "$fleet" --release "$release" "${binding[@]}" "${args[@]}" "$root"
        return 0
      fi
      repair_tool="$(active_cli_repair_tool)" || return "$?"
      "$repair_tool" attach --home "$HOME_PATH" --fleet "$fleet" --release "$release" "${binding[@]}" "${args[@]}" "$root"
      ;;
    relink)
      [ -n "$owner_sha256" ] && [ -n "$owner_parent_dev_ino" ] || return "$TRELLIS_EX_STATE"
      binding+=(--expected-owner-sha256 "$owner_sha256" --expected-owner-parent-dev-ino "$owner_parent_dev_ino")
      if [ "$DO_DRY_RUN" -eq 1 ]; then
        print_auto_command trellis relink --home "$HOME_PATH" --fleet "$fleet" "${binding[@]}" "$root"
        return 0
      fi
      repair_tool="$(active_cli_repair_tool)" || return "$?"
      "$repair_tool" relink --home "$HOME_PATH" --fleet "$fleet" "${binding[@]}" "$root"
      ;;
    *) return "$TRELLIS_EX_USAGE" ;;
  esac
}

# A successful repair command is not evidence that the original error is gone.
# Re-read the authoritative registry and prove the same worktree reaches the
# strict attachment/layout predicate before clearing this row's pre-repair
# diagnostics from the aggregate.
verify_safe_repair_result() (
  local home="$1" root="$2" fleet="$3" project_id="$4" snapshot rows row
  local checkout_id worktree_id attachment_id release harnesses owner
  # Inside the invocation scratch tree; the invocation-wide trap owns it — a
  # subshell-local EXIT trap here would replace that cleanup for the WHOLE
  # process (traps are global, not per-subshell).
  snapshot="$(doctor_scratch_require && mktemp "$DOCTOR_SCRATCH_DIR/post-repair.XXXXXXXX")" || return 1
  local_registry_list_diagnostic_json "$home" "$fleet" > "$snapshot" || return 1
  rows="$(jq -c --arg root "$root" --arg fleet "$fleet" --arg project "$project_id" '
    [.entries[]
      | select(.kind == "worktree" and .root == $root and .fleet == $fleet and .project_id == $project)]
  ' "$snapshot")" || return 1
  [ "$(printf '%s\n' "$rows" | jq 'length')" -eq 1 ] || return 1
  row="$(printf '%s\n' "$rows" | jq -c '.[0]')" || return 1
  [ "$(printf '%s\n' "$row" | jq -r '.status')" = active ] &&
    [ "$(printf '%s\n' "$row" | jq -r '.excluded')" = false ] &&
    [ "$(printf '%s\n' "$row" | jq -r '.availability')" = available ] &&
    [ "$(printf '%s\n' "$row" | jq -r '.identity.state')" = verified ] || return 1
  checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')" || return 1
  worktree_id="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')" || return 1
  attachment_id="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')" || return 1
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')" || return 1
  harnesses="$(printf '%s\n' "$row" | jq -c '.harnesses // []')" || return 1
  [ -n "$checkout_id" ] && [ -n "$worktree_id" ] &&
    [ -n "$attachment_id" ] && [ -n "$release" ] || return 1
  owner="$home/state/attachments/$checkout_id/$worktree_id.json"
  hc_portable_attachment "$home" "$owner" "$root" "$fleet" "$project_id" \
    "$checkout_id" "$worktree_id" "$attachment_id" "$release" "$harnesses" >/dev/null || return 1
  [ "$HC_PORTABLE_ATTACHMENT_STATE" = attached ] || return 1
  hc_portable_layout "$root" attached "$project_id" >/dev/null &&
    [ "$HC_PORTABLE_LAYOUT" = portable-attached ]
)

printf 'trellis doctor — %s\n' "$(if [ "$DO_FIX" -eq 1 ]; then echo 'safe attachment repair'; else echo 'read-only local health'; fi)"
printf 'Trellis home: %s\nLocal registry: %s\n\n' "$HOME_PATH" "$REGISTRY_PATH"
echo '== Local machine state =='
if ! run_check '  ' hc_portable_machine_config "$HOME_PATH"; then
  echo '== Summary =='; echo "$GLYPH_ERR local machine configuration is invalid; no registry paths were guessed."; exit "$DOCTOR_EXIT"
fi
if [ -n "$ONLY_FLEET" ] &&
   ! jq -e --arg fleet "$ONLY_FLEET" '.fleets[$fleet] != null' "$HOME_PATH/config.json" >/dev/null 2>&1; then
  echo "doctor: selected fleet is not configured locally: $ONLY_FLEET" >&2
  exit "$TRELLIS_EX_USAGE"
fi
run_check '  ' hc_portable_source_root "$HOME_PATH" || true
run_check '  ' hc_portable_release_store "$HOME_PATH" || true
run_check '  ' hc_portable_active_cli_release "$HOME_PATH" || true
if run_check '  ' hc_portable_user_surface "$HOME_PATH"; then
  :
else
  case "${HC_PORTABLE_USER_SURFACE_STATE:-}" in
    unmanaged)
      printf '%s\n' '  [manual] user attachment is report-only; remedy: trellis attach --user' ;;
    stale)
      printf '%s\n' '  [manual] user attachment is report-only; remedy: trellis relink --user' ;;
    *)
      printf '%s\n' '  [manual] user attachment is report-only; remedy: review, then use trellis attach --user for an unmanaged surface or trellis relink --user for an owned surface' ;;
  esac
fi
# User skill roots live under the account HOME (destination_home leaves), not
# under TRELLIS_HOME ($HOME_PATH): pass the runtime HOME as the checked home.
# Report-only like the user surface; --fix never touches harness roots.
run_check '  ' hc_user_skill_roots "${HOME:-}" "$HOME_PATH" || true
run_check '  ' hc_usage_cli "$HOME_PATH" || true
run_check '  ' hc_usage_root "$HOME_PATH" || true
run_check '  ' hc_usage_store "$HOME_PATH" || true
run_check '  ' hc_usage_visibility "$HOME_PATH" || true
run_check '  ' hc_usage_watermarks "$HOME_PATH" || true
run_check '  ' hc_usage_receipts "$HOME_PATH" || true
# The snapshot lives INSIDE the invocation scratch tree, and NO trap is
# installed here: a second `trap … EXIT` would silently replace the
# invocation-wide cleanup trap above and strand that tree on every exit.
SNAPSHOT="$(doctor_scratch_require && mktemp "$DOCTOR_SCRATCH_DIR/registry.XXXXXXXX")" ||
  { echo 'doctor: could not create a private scratch file for the registry snapshot' >&2; exit "$TRELLIS_EX_UNAVAILABLE"; }
if local_registry_list_diagnostic_json "$HOME_PATH" "$ONLY_FLEET" > "$SNAPSHOT"; then :; else
  status=$?; report '  ' "$HC_ERROR" "local registry: invalid, unsafe, or unavailable at $REGISTRY_PATH"; echo '== Summary =='; exit "$status"
fi
report '  ' "$HC_OK" 'local registry: validated local fleet inventory'
echo; echo '== Registered checkouts and worktrees =='
[ "$(jq '.entries | length' "$SNAPSHOT")" -ne 0 ] || echo '  (no locally registered checkout records)'
# A registry state error is a property of the REGISTRY, not of the selection.
# `--project` decides which rows this run INSPECTS and offers to repair; it must
# not decide which rows count toward the exit class. The row loop below skips
# non-selected rows before it ever reads `.identity.state`, so without this
# pre-pass a `--project P` run over a healthy P reported clean over a registry
# it had just listed as drifted. Reported here from the FULL snapshot, once,
# and never repaired — a row outside the selection is not this run's target.
#
# `identity_error` is the ONE name the unified row classifier gives class 4, in
# both `local_registry_list_json`'s `availability` and this listing's
# `.identity.state`. It used to be `drift` here, and because the diagnostic
# classifier also short-circuited on reachability before comparing stored
# hashes, a row the strict path condemned class 4 could reach this select as
# `unavailable` and be missed entirely.
#
# Both messages below interpolate registry-derived text and the selector into an
# operator's terminal. `--project` is already refused at parse time unless it
# matches the registry project-ID grammar, exactly as disk-janitor refuses it;
# the drift lines carry roots and classifier details straight out of a file this
# reader deliberately does not require to be strict-clean. Both go through the
# same terminal-safety helper every other registry consumer prints roots with.
if [ -n "$ONLY_PROJECT" ]; then
  SAFE_ONLY_PROJECT="$(local_registry_safe_display "$ONLY_PROJECT")"
  # Emitted as FIELDS, not as one composed sentence. `local_registry_safe_display`
  # collapses its WHOLE argument, so escaping the composed line reported
  # "<unsafe registry text>" and nothing else — the row identity, the only part
  # that says which row drifted, was destroyed by whichever field was unsafe.
  # Fleet, project ID, and kind are schema-constrained; root and detail are the
  # free-form fields and are the only ones escaped. `@tsv` keeps one row on one
  # line by rendering an embedded tab or newline as its two-character escape.
  if UNSELECTED_DRIFT="$(jq -r --arg project "$ONLY_PROJECT" '
    .entries[]
    | select(.project_id != $project)
    | select(.identity.state == "identity_error")
    | ["\(.fleet)/\(.project_id) (\(.kind))", (.root // "(no recorded root)"),
       (.identity.detail // "registered row cannot be verified")] | @tsv
  ' "$SNAPSHOT" 2>/dev/null)"; then
    while IFS=$'\t' read -r drift_label drift_root drift_detail; do
      [ -n "$drift_label" ] || continue
      report '  ' "$HC_ERROR" "identity drift outside --project $SAFE_ONLY_PROJECT: $drift_label at $(local_registry_safe_display "${drift_root:-(no recorded root)}"): $(local_registry_safe_display "${drift_detail:-registered row cannot be verified}") — no automatic mutation was attempted" "$DOCTOR_EX_CONFLICT"
    done <<EOF
$UNSELECTED_DRIFT
EOF
  else
    report '  ' "$HC_ERROR" "local registry: could not inspect rows outside --project $SAFE_ONLY_PROJECT for identity drift" "$DOCTOR_EX_STATE"
  fi
fi
while IFS= read -r row; do
  fleet="$(printf '%s\n' "$row" | jq -r '.fleet')"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id')"
  kind="$(printf '%s\n' "$row" | jq -r '.kind')"
  availability="$(printf '%s\n' "$row" | jq -r '.availability')"
  registry_status="$(printf '%s\n' "$row" | jq -r '.status // empty')"
  excluded="$(printf '%s\n' "$row" | jq -r '.excluded // false')"
  identity_state="$(printf '%s\n' "$row" | jq -r '.identity.state // "unknown"')"
  identity_detail="$(printf '%s\n' "$row" | jq -r '.identity.detail // empty')"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')"
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')"
  harnesses="$(printf '%s\n' "$row" | jq -c '.harnesses // []')"
  checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')"
  worktree_id="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')"
  attachment_id="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')"
  # REPORTED spellings of the two free-form, registry-derived fields. This row
  # comes from the diagnostic listing, which deliberately does not require the
  # file to be strict-clean, so a root or classifier detail printed here must go
  # through the same terminal-safety helper the selection-scoped reporter above
  # uses. $root and $identity_detail keep the real bytes for the filesystem
  # probes, the health checks, and the repair plan, which all need them.
  safe_root="$(local_registry_safe_display "${root:-<no root>}")"
  safe_identity_detail="$(local_registry_safe_display "${identity_detail:-registered row cannot be verified}")"
  [ -z "$ONLY_PROJECT" ] || [ "$project_id" = "$ONLY_PROJECT" ] || continue
  HC_PORTABLE_HOOKS_AUTHORITY=""
  ROW_ERRORS_AT_START="$N_ERROR"
  ROWS_CHECKED=$((ROWS_CHECKED + 1)); printf '\n%s/%s (%s)\n' "$fleet" "$project_id" "$kind"
  payload=""; release_ok=false
  if [ -n "$release" ]; then
    if run_check '  ' hc_portable_release "$HOME_PATH" "$release"; then
      if payload="$(TRELLIS_HOME="$HOME_PATH" release_store_locate "$release" 2>/dev/null)"; then
        release_ok=true
      else
        report '  ' "$HC_ERROR" 'immutable release: verified payload disappeared before row inspection'
      fi
    fi
  fi
  if [ "$kind" != worktree ]; then
    # `not-applicable` is the IDENTITY-state word for a rootless project row, in
    # this listing and in the classifier both listings share. It was never an
    # availability word in `local_registry_list_json`, so keying on
    # `.availability` here made doctor the only consumer that needed the two
    # listings to name the same row differently.
    if [ "$kind" = project ] && [ "$registry_status" = detached ] &&
       [ "$identity_state" = not-applicable ]; then
      report '  ' "$HC_WARN" 'detached inventory: retained project has no local worktree root to inspect'
    elif [ "$availability" = unavailable ] || [ "$registry_status" = unavailable ] ||
         [ "$kind" = unavailable ]; then
      report '  ' "$HC_ERROR" "unavailable: retained local registry row at $safe_root — mount/restore it, then run trellis doctor again" "$DOCTOR_EX_UNAVAILABLE"
    elif [ "$kind" = checkout ]; then
      # A registered checkout that currently holds no worktree row. It carries a
      # reachable root, so its identity is still reportable; there is simply no
      # attachment surface to inspect or repair.
      if [ "$identity_state" != verified ]; then
        report '  ' "$HC_ERROR" "identity drift: $safe_identity_detail at $safe_root — no automatic mutation was attempted" "$DOCTOR_EX_CONFLICT"
      else
        report '  ' "$HC_WARN" "checkout inventory: registered checkout at $safe_root has no registered worktree to inspect"
      fi
    else
      report '  ' "$HC_WARN" 'detached inventory: no registered worktree root to inspect'
    fi
    continue
  fi
  if [ "$availability" = unavailable ] || [ "$registry_status" = unavailable ] ||
     [ -z "$root" ] || [ ! -d "$root" ]; then
    report '  ' "$HC_ERROR" "unavailable: retained local registry row at $safe_root — mount/restore it, then run trellis doctor again" "$DOCTOR_EX_UNAVAILABLE"
    continue
  fi
  if [ "$identity_state" != verified ]; then
    report '  ' "$HC_ERROR" "identity drift: $safe_identity_detail at $safe_root — no automatic mutation was attempted" "$DOCTOR_EX_CONFLICT"
    continue
  fi
  if [ "$registry_status" != active ]; then
    report '  ' "$HC_WARN" "registry status: $registry_status — automatic attachment repair is withheld"
  fi
  if [ "$excluded" != false ]; then
    report '  ' "$HC_WARN" 'registry exclusion: automatic attachment repair is withheld'
  fi
  owner="$HOME_PATH/state/attachments/$checkout_id/$worktree_id.json"; owner_state=missing
  if run_check '  ' hc_portable_owner "$HOME_PATH" "$owner" "$root" "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$attachment_id" "$release"; then owner_state=attached; else owner_state="${HC_PORTABLE_OWNER_STATE:-conflict}"; fi
  if [ "$owner_state" != missing ]; then
    run_check '  ' hc_portable_hooks_path "$HOME_PATH" "$root" "$checkout_id" "$owner" || true
  fi
  if [ -z "$release" ] && [ "$owner_state" != missing ]; then
    report '  ' "$HC_ERROR" 'immutable release: registry worktree has no recorded release' "$DOCTOR_EX_STATE"
  fi
  excludes_ok=false; surfaces_ok=false
  if [ "$owner_state" = attached ] || [ "$owner_state" = runtime-missing ]; then
    if [ -n "$payload" ] &&
       run_check '  ' hc_portable_excludes "$HOME_PATH" "$owner" "$payload/payload" "$harnesses"; then excludes_ok=true; fi
    if [ -n "$payload" ] &&
       run_check '  ' hc_portable_native_surfaces "$HOME_PATH" "$owner" "$payload/payload" "$harnesses"; then surfaces_ok=true; fi
  fi
  run_check '  ' hc_harness_capability_observation "$harnesses" "$release_ok" "$owner_state" "$surfaces_ok" || true
  # The owner/native checks validate recorded artifact metadata, but release
  # adoption can advance the runtime manifest without materializing a newly
  # declared discovery leaf.  Inspect the concrete checkout before computing any
  # safe-repair route; this drift is detection-only and requires detach/attach.
  run_check '  ' health_checks_missing_leaves "$root" "$harnesses" "$HOME_PATH" "$release" || true
  run_check '  ' hc_portable_layout "$root" "$owner_state" "$project_id" || true
  layout="$HC_PORTABLE_LAYOUT"
  # Anti-slop presence (spec 037): read-only, OK/INFO only — it reports whether a
  # language profile config and a gate_profiles.anti_slop.posture exist, and never
  # errors, so it stays out of $row_diagnostics_ok and out of the repair plan.
  run_check '  ' hc_anti_slop_profile "$root" || true
  row_diagnostics_ok=false
  [ "$N_ERROR" -eq "$ROW_ERRORS_AT_START" ] && row_diagnostics_ok=true
  plan_safe_repair "$root" "$fleet" "$project_id" "$checkout_id" "$worktree_id" \
    "$attachment_id" "$release" "$owner_state" "$layout" "$release_ok" \
    "$excludes_ok" "$surfaces_ok" "$registry_status" "$excluded" "$identity_state" "$row_diagnostics_ok" \
    "$harnesses" "$HC_PORTABLE_HOOKS_AUTHORITY"
  if [ -n "$SAFE_REPAIR_BLOCKED" ]; then
    if [ -z "$SAFE_REPAIR_BLOCKED_CLASS" ]; then
      case "$SAFE_REPAIR_BLOCKED" in
        'multiple exact attachment journals match this registry row'|'attachment journal does not exactly match this registry row')
          SAFE_REPAIR_BLOCKED_CLASS="$DOCTOR_EX_CONFLICT"
          ;;
        *) SAFE_REPAIR_BLOCKED_CLASS="$DOCTOR_EX_STATE" ;;
      esac
    fi
    report '  ' "$HC_ERROR" "repair boundary: $SAFE_REPAIR_BLOCKED; no automatic mutation was attempted" "$SAFE_REPAIR_BLOCKED_CLASS"
  elif [ -n "$SAFE_REPAIR" ]; then
    if [ "$DO_FIX" -eq 1 ]; then
      if apply_safe_repair "$SAFE_REPAIR" "$root" "$fleet" "$project_id" "$checkout_id" "$worktree_id" \
        "$attachment_id" "$release" "${SAFE_REPAIR_HARNESSES:-$harnesses}" \
        "$SAFE_REPAIR_OWNER_SHA256" "$SAFE_REPAIR_OWNER_PARENT_DEV_INO"; then
        if [ "$DO_DRY_RUN" -eq 1 ]; then
          report '  ' "$HC_ERROR" "safe repair through trellis $SAFE_REPAIR is planned but was not applied; state remains unresolved"
        elif verify_safe_repair_result "$HOME_PATH" "$root" "$fleet" "$project_id"; then
          N_ERROR="$ROW_ERRORS_AT_START"
          report '  ' "$HC_INFO" "safe repair delegated through trellis $SAFE_REPAIR and passed strict post-repair verification"
        else
          report '  ' "$HC_ERROR" "safe repair through trellis $SAFE_REPAIR completed but strict post-repair verification failed; state remains unresolved"
        fi
      else
        report '  ' "$HC_ERROR" "safe repair through trellis $SAFE_REPAIR failed; no direct filesystem repair was attempted"
      fi
    else
      # $safe_root, like every other row line: this is the LAST registry-derived
      # root printed in the loop and it was the one still emitting raw bytes.
      report '  ' "$HC_INFO" "safe repair available: trellis $SAFE_REPAIR $safe_root (doctor --fix delegates; it never deletes project-owned files)"
    fi
  elif { [ "$layout" = inert-non-user ] || [ "$layout" = portable-attached ]; } && [ "$release_ok" != true ]; then
    report '  ' "$HC_INFO" "repair boundary: attach/relink is withheld until recorded immutable release ${release:-<missing>} validates; no project-owned file was changed"
  elif [ "$registry_status" = active ] && [ "$excluded" = false ] &&
       [ "$layout" = portable-attached ] && [ "$owner_state" = runtime-missing ]; then
    report '  ' "$HC_INFO" 'repair boundary: relink is withheld until committed exclude and native-surface checks pass'
  elif [ "$layout" = compatibility-legacy ] || [ "$layout" = mixed/conflict ] || [ "$layout" = corrupt ]; then
    report '  ' "$HC_INFO" 'repair boundary: no automatic mutation; review migration/ownership conflict without deleting project-owned files'
  fi
done < <(jq -c '.entries[]' "$SNAPSHOT")
if [ "$ROWS_CHECKED" -eq 0 ] && [ -n "$ONLY_PROJECT" ]; then report '  ' "$HC_ERROR" "local registry has no record for requested project $ONLY_PROJECT"; fi
echo; echo '== Summary =='
printf '%s %d error(s)  %s %d warning(s)  %s %d info  (%d local row(s) checked)\n' "$GLYPH_ERR" "$N_ERROR" "$GLYPH_WARN" "$N_WARN" "$GLYPH_INFO" "$N_INFO" "$ROWS_CHECKED"
if [ "$DO_DRY_RUN" -eq 1 ]; then
  echo "$GLYPH_INFO dry-run: no repair was applied"
  summary_exit_code="$(hc_doctor_summary_exit_code "$N_ERROR" "$DOCTOR_EXIT")"
  exit "$summary_exit_code"
fi
summary_exit_code="$(hc_doctor_summary_exit_code "$N_ERROR" "$DOCTOR_EXIT")"
exit "$summary_exit_code"
