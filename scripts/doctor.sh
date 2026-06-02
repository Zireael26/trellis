#!/usr/bin/env bash
# trellis doctor — P1 read-only diagnosis + P2 --fix repair
#
# Deterministic, on-demand inheritance health check (the `brew doctor` shape).
#   - Tier 0: global preconditions against the CANONICAL clone ($TRELLIS_ROOT,
#     resolved from trellis.config.json — NOT doctor's cwd; doctor runs from
#     worktrees). Probes via `git -C "$TRELLIS_ROOT" ...`.
#   - Tier 1: per active project (registry.md MINUS blacklist.md): rules
#     symlink, @-import, skills/commands symlinks, harness-conditional
#     artifacts, hook freshness + settings wiring, version-pin lag.
#
# WITHOUT --fix: READ-ONLY. doctor only PRINTS the fix command a human/agent
# would run; it never calls onboard-project.sh / sync-hooks.sh /
# sync-codex-hooks.sh and never mutates anything. This path is byte-identical
# to P1.
#
# WITH --fix (P2): for each project, after diagnosis, the auto-fixable
# treatments are applied by delegating to the idempotent never-clobber engines:
#   - missing rules/skill/command symlink, missing harness artifact, missing
#     settings.json  -> onboard-project.sh "<ABS path>" (run ONCE per project,
#     with TRELLIS_SKIP_SECURITY_BASELINE=1 so a symlink repair does not also
#     run the security baseline).
#   - STALE/WRONG-TARGET trellis-managed symlink -> onboard's never-clobber
#     would leave it as-is, so --fix `rm`s the known-bad link FIRST (each rm is
#     printed before it runs), then onboard recreates it.
#   - Claude/Codex hook drift -> SKIPPED unless --fix-hooks is ALSO given
#     (it changes enforcement behavior). With --fix-hooks: sync-hooks.sh /
#     sync-codex-hooks.sh --yes <registry-name>.
#   - dead/missing @-import, settings.json .hooks drift, version-pin lag,
#     Tier-0 issues -> reported as MANUAL/INFO, NEVER auto-applied.
# After fixing a project, its checks are re-run and the resulting status shown.
#
# KNOWN onboard side effect (cannot be suppressed — there is no --skip-hooks,
# only TRELLIS_SKIP_SECURITY_BASELINE): onboard-project.sh unconditionally seeds
# MISSING hook copies + a MISSING settings.json (seed_claude_hooks /
# seed_codex_hooks skip only files that already exist). So a plain `--fix` that
# runs onboard to repair a symlink WILL also install any MISSING hooks/settings
# as a side effect — even without --fix-hooks. The --fix-hooks gate is only
# fully honored for STALE hooks: onboard never-clobbers, so it never UPDATES a
# drifted hook; that always needs --fix-hooks.
#
# --dry-run (only valid with --fix): prints exactly what --fix WOULD do per
# project (each delegated command, each rm, each manual item) and touches
# NOTHING. Always exits 0.
#
# Exit code (no flags / --fix): 0 if healthy (no ERROR; WARN/INFO are allowed),
# non-zero if any ERROR is found. Under --fix the exit reflects POST-FIX state.
# Under --dry-run the exit is always 0.
#
# Usage:
#   doctor.sh                          # check all active projects (read-only)
#   doctor.sh --project NAME           # limit to one registry project
#   doctor.sh --fix [--project NAME]   # diagnose + auto-repair (symlinks)
#   doctor.sh --fix --fix-hooks ...    # ALSO re-sync hook copies (gated)
#   doctor.sh --fix --dry-run ...      # print the repair plan; change nothing
#   doctor.sh --help
#
# bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/health-checks.sh
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
trellis doctor — inheritance health check + repair

Usage:
  doctor.sh                          Check Tier-0 preconditions + all projects.
  doctor.sh --project NAME           Limit Tier-1 checks to one registry project.
  doctor.sh --fix [--project NAME]   Diagnose, then auto-repair (see below).
  doctor.sh --fix --fix-hooks ...    ALSO re-sync drifted hook copies (gated).
  doctor.sh --fix --dry-run ...      Print the repair plan; change NOTHING.
  doctor.sh --help                   Show this help.

WITHOUT --fix this command is READ-ONLY: it prints the repair command to run
and never mutates projects or the canonical clone.

WITH --fix, per project (after diagnosis):
  [auto]   missing rules/skill/command symlink, missing harness artifact, or
           missing .claude/settings.json -> delegated to onboard-project.sh
           (idempotent, never-clobber). A STALE/wrong-target trellis-managed
           symlink is `rm`'d first (each rm is printed) because onboard's
           never-clobber would otherwise leave it as-is, then re-seeded.
  [hooks]  Claude/Codex hook drift -> SKIPPED unless --fix-hooks is also given
           (it changes enforcement behavior). With --fix-hooks: sync-hooks.sh /
           sync-codex-hooks.sh --yes <name>.
  [manual] dead/missing @-import (never auto-edit a user's CLAUDE.md) and
           settings.json .hooks drift (no engine fixes it) -> reported only.
  [info]   version-pin lag, Tier-0 canonical issues -> reported only.
After repair, the project's checks re-run and the resulting status is shown.

NOTE: onboard-project.sh seeds MISSING hooks + a MISSING settings.json
unconditionally (there is no --skip-hooks). So a plain --fix that runs onboard
WILL install missing hooks/settings as a side effect — but it NEVER updates a
STALE hook; that always requires --fix-hooks.

Flag rules: --dry-run requires --fix (plain doctor is already read-only).
--fix-hooks implies --fix. Tier-0 issues are always report-only; --fix never
mutates the canonical clone, and skips [auto] repair while a Tier-0 ERROR
stands (onboard would re-link to an off-main/dirty canonical's rules).

Output: per-project ✓ / ⚠ / ✗ table + a summary line + actionable fix hints.
Exit code: 0 if healthy (no ✗ ERRORs); non-zero if any ERROR is found.
Under --fix the exit reflects POST-FIX state; under --dry-run it is always 0.
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
#   --fix-hooks implies --fix ("ALSO re-sync hooks" rides on a --fix run).
#   --dry-run is only meaningful with --fix (plain doctor is already read-only).
[ "$DO_FIX_HOOKS" -eq 1 ] && DO_FIX=1
if [ "$DO_DRY_RUN" -eq 1 ] && [ "$DO_FIX" -eq 0 ]; then
  echo "doctor: --dry-run is only valid with --fix" >&2
  echo "try: doctor.sh --fix --dry-run" >&2
  exit 2
fi

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
  if [ "${#HINTS[@]:-0}" -gt 0 ]; then
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
done < <(read_blacklist_names)

is_blacklisted() {
  local name="$1" b
  [ "${#BLACKLIST_NAMES[@]:-0}" -eq 0 ] && return 1
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
  echo "trellis doctor — --fix (diagnose + repair)"
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

run_tier0 hc_canonical_on_main "$CANON"
run_tier0 hc_canonical_clean "$CANON"
run_tier0 hc_canonical_sync "$CANON"
run_tier0 hc_conformance_passes "$CANON"
run_tier0 hc_version_changelog_coherent "$CANON"

# Tier-0 runs before any project, so N_ERROR here is purely Tier-0. Capture it:
# Tier-0 is REPORT-ONLY (--fix never mutates the canonical clone), AND a
# standing Tier-0 ERROR (canonical off-main / dirty / not-a-work-tree) means
# onboard would re-link projects to an off-main/dirty canonical's rules
# (incident #2). So --fix SKIPS [auto] repair while a Tier-0 ERROR stands.
TIER0_ERROR=0
[ "$N_ERROR" -gt 0 ] && TIER0_ERROR=1

# Tier-0 fix hints (canonical-side; not a per-project repair). Report-only.
if [ "$N_ERROR" -gt 0 ]; then
  add_hint "Tier 0: ensure the canonical clone ($CANON) is on 'main' and clean before trusting any project's inheritance (git -C \"$CANON\" checkout main; commit or stash changes)."
  # Under --fix the `== Suggested actions ==` block is suppressed, so the
  # Tier-0 remediation must surface here directly (Tier-0 is always report-only;
  # --fix never mutates the canonical clone).
  if [ "$DO_FIX" -eq 1 ]; then
    echo "  [info] Tier-0 is report-only — --fix never touches the canonical clone."
    echo "  [info] remediate: git -C \"$CANON\" checkout main  (then commit or stash any changes)"
    echo "  [info] --fix will SKIP [auto] symlink repair until this Tier-0 ERROR clears (onboard would re-link projects to off-main/dirty rules)."
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
  if [ "${#REGISTRY_NAMES[@]:-0}" -gt 0 ]; then
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
  if [ "${#REGISTRY_NAMES[@]:-0}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      if is_blacklisted "$n"; then
        continue
      fi
      TARGETS+=("$n")
    done
  fi
fi

if [ "${#TARGETS[@]:-0}" -eq 0 ]; then
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
#   PLAN_NEEDS_ONBOARD  — 1 if any onboard-fixable failure was seen.
#   PLAN_RM_LIST        — space-joined absolute paths of known-bad trellis-managed
#                         symlinks to `rm` BEFORE onboard (one path per element;
#                         these are project paths that contain no spaces).
#   PLAN_AUTO           — newline-joined human descriptions of [auto] actions.
#   PLAN_HOOKS_CLAUDE   — 1 if Claude hook drift needs sync-hooks (gated).
#   PLAN_HOOKS_CODEX    — 1 if Codex hook drift needs sync-codex-hooks (gated).
#   PLAN_MANUAL         — newline-joined [manual] descriptions (never auto-applied).
#   PLAN_INFO           — newline-joined [info] descriptions (report-only).
PLAN_NEEDS_ONBOARD=0
PLAN_RM_LIST=""
PLAN_AUTO=""
PLAN_HOOKS_CLAUDE=0
PLAN_HOOKS_CODEX=0
PLAN_MANUAL=""
PLAN_INFO=""
PLAN_SEED_WORKTREES=""

# plan_add_rm <abs-path> — queue a known-bad symlink for rm (deduped).
plan_add_rm() {
  local p="$1" existing
  for existing in $PLAN_RM_LIST; do
    [ "$existing" = "$p" ] && return 0
  done
  PLAN_RM_LIST="$PLAN_RM_LIST $p"
}

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
run_project_checks() {
  local name="$1" proj="$2"
  local rc h
  local codex_missing codex_stale codex_detail csrc cfn cdst csha dsha

  # Reset plan for this project (caller reads these after the call).
  PLAN_NEEDS_ONBOARD=0
  PLAN_RM_LIST=""
  PLAN_AUTO=""
  PLAN_HOOKS_CLAUDE=0
  PLAN_HOOKS_CODEX=0
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
        add_hint "$name: stale/wrong rules symlink — onboard will NOT repair it (never-clobber). Run: rm \"$proj/.claude/rules/trellis.md\" && scripts/onboard-project.sh \"$proj\""
        plan_add_rm "$proj/.claude/rules/trellis.md"
        PLAN_NEEDS_ONBOARD=1
        plan_add PLAN_AUTO "rm stale rules symlink .claude/rules/trellis.md, then onboard re-seeds it"
      else
        add_hint "$name: missing rules symlink — run: scripts/onboard-project.sh \"$proj\""
        PLAN_NEEDS_ONBOARD=1
        plan_add PLAN_AUTO "onboard re-seeds missing rules symlink .claude/rules/trellis.md"
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
    add_hint "$name: incomplete skill set — run: scripts/onboard-project.sh \"$proj\""
    PLAN_NEEDS_ONBOARD=1
    # rm only the wrong-target trellis-managed skill links so onboard can
    # recreate them (never-clobber would skip a wrong-target link). Re-walk the
    # canonical set; rm ONLY `[ -L ]` whose readlink != expected canonical.
    for h in $HC_CANONICAL_SKILLS; do
      if [ -L "$proj/.claude/skills/$h" ] && [ "$(readlink "$proj/.claude/skills/$h")" != "$CANON/core-rules/skills/$h" ]; then
        plan_add_rm "$proj/.claude/skills/$h"
        plan_add PLAN_AUTO "rm wrong-target skill link .claude/skills/$h, then onboard re-seeds it"
      fi
    done
    plan_add PLAN_AUTO "onboard re-seeds any missing canonical skill links under .claude/skills/"
  fi

  # --- commands symlinks (WARN) ---
  if emit "  " hc_commands_symlinks "$proj" "$CANON"; then :; else
    add_hint "$name: incomplete command set — run: scripts/onboard-project.sh \"$proj\""
    PLAN_NEEDS_ONBOARD=1
    for h in $HC_CANONICAL_COMMANDS; do
      if [ -L "$proj/.claude/commands/$h.md" ] && [ "$(readlink "$proj/.claude/commands/$h.md")" != "$CANON/core-rules/commands/$h.md" ]; then
        plan_add_rm "$proj/.claude/commands/$h.md"
        plan_add PLAN_AUTO "rm wrong-target command link .claude/commands/$h.md, then onboard re-seeds it"
      fi
    done
    plan_add PLAN_AUTO "onboard re-seeds any missing canonical command links under .claude/commands/"
  fi

  # --- harness-conditional artifacts (WARN), one row per enabled harness ---
  for h in "${HARNESSES[@]}"; do
    if emit "  " hc_harness_artifacts "$proj" "$h"; then :; else
      add_hint "$name: missing $h harness artifacts — run: scripts/onboard-project.sh \"$proj\""
      PLAN_NEEDS_ONBOARD=1
      plan_add PLAN_AUTO "onboard re-seeds missing $h harness artifacts (.agents/ + harness surface). NOTE: a wrong-TARGET .agents symlink that still resolves is not detected by the check, so --fix cannot repair what the check cannot see."
    fi
  done

  # --- hook freshness (WARN) — GATED behind --fix-hooks ---
  if emit "  " hc_hook_freshness "$proj" "$CANON"; then :; else
    add_hint "$name: Claude hook copies drift from canonical — run (gated, changes enforcement): scripts/sync-hooks.sh $name   (preview: scripts/sync-hooks.sh --dry-run $name)"
    PLAN_HOOKS_CLAUDE=1
  fi

  # --- settings wiring (WARN) ---
  if emit "  " hc_settings_wiring "$proj" "$CANON"; then :; else
    rc=$?
    if [ ! -f "$proj/.claude/settings.json" ]; then
      add_hint "$name: missing .claude/settings.json — run: scripts/onboard-project.sh \"$proj\""
      PLAN_NEEDS_ONBOARD=1
      plan_add PLAN_AUTO "onboard re-seeds missing .claude/settings.json from the canonical template"
    else
      # PRESENT but .hooks wiring drifts — MANUAL only. onboard skips an existing
      # settings.json (never-clobber); rollout-settings.sh only unions
      # .permissions.deny and leaves .hooks alone. Do NOT rm-then-reseed: the
      # file holds user-owned permissions.allow/ask + local deny entries.
      add_hint "$name: settings.json hook wiring differs from canonical — re-seed via onboard (onboard skips an existing settings.json; remove it first if a re-seed is intended): scripts/onboard-project.sh \"$proj\""
      plan_add PLAN_MANUAL "settings.json .hooks wiring drifts — no engine fixes it (do NOT rm/reseed; it holds user permissions). Review .claude/settings.json .hooks against core-rules/templates/claude-settings.json"
    fi
  fi

  # --- codex hook freshness (WARN) — only when codex is enabled; GATED ---
  if pg_has_harness codex; then
    if [ -d "$proj/.codex/hooks" ]; then
      # Reuse hook-freshness semantics against the codex surface by passing
      # the codex paths. We compare each project codex hook to canonical.
      codex_missing=""
      codex_stale=""
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
      if [ -n "$codex_missing" ] || [ -n "$codex_stale" ]; then
        codex_detail=""
        [ -n "$codex_missing" ] && codex_detail="missing:${codex_missing}"
        [ -n "$codex_stale" ] && codex_detail="$codex_detail stale:${codex_stale}"
        report_line "  " "$HC_WARN" "codex-hooks: drift vs canonical —${codex_detail# }"
        add_hint "$name: Codex hook copies drift — run (gated): scripts/sync-codex-hooks.sh $name   (preview: scripts/sync-codex-hooks.sh --dry-run $name)"
        PLAN_HOOKS_CODEX=1
      else
        report_line "  " "$HC_OK" "codex-hooks: in sync with canonical"
      fi
    fi
  fi

  # --- worktree inheritance (WARN) — [auto]-fixable via seed-inheritance-symlinks.sh ---
  if emit "  " hc_worktree_inheritance "$proj" "$CANON"; then :; else
    # Re-enumerate offenders here (same data hc_worktree_inheritance used) so
    # the plan lists only the actually-broken worktrees rather than all of them.
    local wt_offenders wt_path
    wt_offenders="$(hc_worktree_offenders "$proj" "$CANON")"
    if [ -n "$wt_offenders" ]; then
      add_hint "$name: linked worktree(s) missing inheritance symlinks — run: scripts/seed-inheritance-symlinks.sh --target <wt>"
      while IFS= read -r wt_path; do
        [ -n "$wt_path" ] || continue
        plan_add PLAN_SEED_WORKTREES "$wt_path"
        plan_add PLAN_AUTO "seed inheritance symlinks into worktree: $wt_path"
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

  return 0
}

# print_project_plan <name> <proj> — print the tagged [auto]/[hooks]/[manual]/
# [info] plan built by the last run_project_checks call. Used by --dry-run and
# as the apply-time narration for --fix. Touches NOTHING.
print_project_plan() {
  local name="$1" proj="$2" p line
  echo "  -- plan for $name --"
  if [ "$TIER0_ERROR" -eq 1 ] && [ "$PLAN_NEEDS_ONBOARD" -eq 1 ]; then
    echo "  [auto] SKIPPED — Tier-0 ERROR stands; --fix will not onboard against an off-main/dirty canonical."
  elif [ "$PLAN_NEEDS_ONBOARD" -eq 1 ]; then
    for p in $PLAN_RM_LIST; do
      echo "  [auto] rm \"$p\""
    done
    echo "  [auto] TRELLIS_SKIP_SECURITY_BASELINE=1 scripts/onboard-project.sh \"$proj\""
    if [ -n "$PLAN_AUTO" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && echo "         - $line"
      done <<EOF
$PLAN_AUTO
EOF
    fi
  fi
  if [ "$PLAN_HOOKS_CLAUDE" -eq 1 ]; then
    if [ "$DO_FIX_HOOKS" -eq 1 ]; then
      echo "  [hooks] scripts/sync-hooks.sh --yes $name"
    else
      echo "  [hooks] Claude hook drift — skipped (run with --fix-hooks). Would run: scripts/sync-hooks.sh --yes $name"
    fi
  fi
  if [ "$PLAN_HOOKS_CODEX" -eq 1 ]; then
    if [ "$DO_FIX_HOOKS" -eq 1 ]; then
      echo "  [hooks] scripts/sync-codex-hooks.sh --yes $name"
    else
      echo "  [hooks] Codex hook drift — skipped (run with --fix-hooks). Would run: scripts/sync-codex-hooks.sh --yes $name"
    fi
  fi
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
  if [ -n "$PLAN_SEED_WORKTREES" ]; then
    if [ "$TIER0_ERROR" -eq 1 ]; then
      echo "  [auto] SKIPPED — Tier-0 ERROR stands; --fix will not seed worktrees against an off-main/dirty canonical."
    else
      while IFS= read -r line; do
        [ -n "$line" ] && echo "  [auto] scripts/seed-inheritance-symlinks.sh --target \"$line\""
      done <<EOF
$PLAN_SEED_WORKTREES
EOF
    fi
  fi
  if [ "$PLAN_NEEDS_ONBOARD" -eq 0 ] && [ "$PLAN_HOOKS_CLAUDE" -eq 0 ] && \
     [ "$PLAN_HOOKS_CODEX" -eq 0 ] && [ -z "$PLAN_MANUAL" ] && [ -z "$PLAN_INFO" ] && \
     [ -z "$PLAN_SEED_WORKTREES" ]; then
    echo "  (nothing to do — healthy)"
  fi
}

# run_cmd <description> <cmd...> — run a mutating command under `set -e` without
# aborting the loop. Prints a FAILED line and returns non-zero on error so the
# caller can note it instead of dying mid-project.
run_cmd() {
  local desc="$1"; shift
  local rc
  if "$@"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    echo "  [auto] FAILED ($desc, exit $rc): $*" >&2
  fi
  return "$rc"
}

# apply_project_fix <name> <proj> — execute the [auto] (rm-list + onboard once)
# and, only if --fix-hooks, the [hooks] (sync-hooks/sync-codex) actions built by
# the preceding run_project_checks call. Reads the BEFORE plan globals; must run
# BEFORE the after-pass re-check rebuilds them. Prints each rm before doing it.
# [manual]/[info]/Tier-0 are reported, never applied.
apply_project_fix() {
  local name="$1" proj="$2" p
  echo "  -- applying fixes for $name --"

  # Tier-0 gate: never onboard against an off-main/dirty canonical.
  if [ "$TIER0_ERROR" -eq 1 ] && [ "$PLAN_NEEDS_ONBOARD" -eq 1 ]; then
    echo "  [auto] SKIPPED — Tier-0 ERROR stands; not onboarding against an off-main/dirty canonical. Clear Tier-0 first."
  elif [ "$PLAN_NEEDS_ONBOARD" -eq 1 ]; then
    if [ ! -d "$proj" ]; then
      echo "  [auto] SKIPPED — $proj is not on disk (onboard needs an existing git repo)." >&2
    else
      # rm known-bad trellis-managed symlinks FIRST (onboard never-clobbers).
      for p in $PLAN_RM_LIST; do
        echo "  [auto] rm \"$p\""
        run_cmd "rm $p" rm "$p" || true
      done
      # Run onboard ONCE. Absolute project path; skip the security baseline.
      # NOTE: onboard-project.sh's LAST statement is a `{ ... } && echo ...`
      # short-circuit that returns non-zero for a claude-only project (the
      # trailing `&&` is false when neither codex nor antigravity is enabled),
      # so onboard can exit non-zero even on a fully successful seed. We
      # therefore DO NOT treat a non-zero onboard exit as failure here — the
      # AFTER-pass re-check is the authoritative verdict on whether the repair
      # landed. We just record the exit code informationally.
      echo "  [auto] TRELLIS_SKIP_SECURITY_BASELINE=1 scripts/onboard-project.sh \"$proj\""
      local onb_rc
      if TRELLIS_SKIP_SECURITY_BASELINE=1 "$SCRIPT_DIR/onboard-project.sh" "$proj" >/dev/null 2>&1; then
        onb_rc=0
      else
        onb_rc=$?
      fi
      if [ "$onb_rc" -eq 0 ]; then
        echo "  [auto] onboard ran (exit 0); see the re-check below for the result."
      else
        echo "  [auto] onboard ran (exit $onb_rc — may be the benign trailing-&& quirk on claude-only projects); the re-check below is authoritative."
      fi
    fi
  fi

  # [hooks] — gated behind --fix-hooks (changes enforcement behavior).
  if [ "$PLAN_HOOKS_CLAUDE" -eq 1 ]; then
    if [ "$DO_FIX_HOOKS" -eq 1 ]; then
      echo "  [hooks] scripts/sync-hooks.sh --yes $name"
      if "$SCRIPT_DIR/sync-hooks.sh" --yes "$name" >/dev/null 2>&1; then
        echo "  [hooks] Claude hooks synced."
      else
        echo "  [hooks] sync-hooks FAILED — see: scripts/sync-hooks.sh --yes $name" >&2
      fi
    else
      echo "  [hooks] Claude hook drift — skipped (run with --fix-hooks)."
    fi
  fi
  if [ "$PLAN_HOOKS_CODEX" -eq 1 ]; then
    if [ "$DO_FIX_HOOKS" -eq 1 ]; then
      echo "  [hooks] scripts/sync-codex-hooks.sh --yes $name"
      if "$SCRIPT_DIR/sync-codex-hooks.sh" --yes "$name" >/dev/null 2>&1; then
        echo "  [hooks] Codex hooks synced."
      else
        echo "  [hooks] sync-codex-hooks FAILED — see: scripts/sync-codex-hooks.sh --yes $name" >&2
      fi
    else
      echo "  [hooks] Codex hook drift — skipped (run with --fix-hooks)."
    fi
  fi

  # [seed-worktrees] — Tier-0 gated, [auto] repair via seed-inheritance-symlinks.sh.
  if [ -n "$PLAN_SEED_WORKTREES" ]; then
    if [ "$TIER0_ERROR" -eq 1 ]; then
      echo "  [auto] SKIPPED — Tier-0 ERROR stands; not seeding worktrees against an off-main/dirty canonical. Clear Tier-0 first."
    else
      local wt_path
      while IFS= read -r wt_path; do
        [ -n "$wt_path" ] || continue
        echo "  [auto] scripts/seed-inheritance-symlinks.sh --target \"$wt_path\""
        if run_cmd "seed worktree $wt_path" \
              bash "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$wt_path" --quiet; then
          echo "  [auto] worktree seeded: $wt_path"
        fi
      done <<EOF
$PLAN_SEED_WORKTREES
EOF
    fi
  fi

  # [manual]/[info] — reported, never applied.
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

if [ "${#TARGETS[@]:-0}" -gt 0 ]; then
  for name in "${TARGETS[@]}"; do
    proj="$(resolve_project_path "$name")"
    echo

    # Project dir missing: ERROR, not auto-fixable (onboard needs an existing
    # git repo). Report identically in every mode and move on.
    if [ ! -d "$proj" ]; then
      report_line "" "$HC_ERROR" "$name — project dir not on disk ($proj)"
      add_hint "$name: project directory missing at $proj — clone/restore it, then: scripts/onboard-project.sh \"$proj\""
      if [ "$DO_FIX" -eq 1 ]; then
        echo "  [manual] project dir not on disk — not auto-fixable (onboard needs an existing git repo). Clone/restore $proj, then: scripts/onboard-project.sh \"$proj\""
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
  if [ "${#TARGETS[@]:-0}" -gt 0 ]; then
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
if [ "$DO_FIX" -eq 0 ] && [ "${#HINTS[@]:-0}" -gt 0 ]; then
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
  echo "(dry-run: re-run without --dry-run to apply the [auto]/[hooks] actions above)"
  exit 0
fi

echo "== Summary =="
if [ "$N_ERROR" -eq 0 ] && [ "$N_WARN" -eq 0 ] && [ "$N_INFO" -eq 0 ]; then
  echo "$GLYPH_OK healthy — no drift detected (${#TARGETS[@]:-0} project(s) checked)"
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
