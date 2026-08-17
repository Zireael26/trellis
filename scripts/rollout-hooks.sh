#!/usr/bin/env bash
# Roll canonical hooks to the fleet AND verify the result.
#
# Reads the machine-local Trellis home for the fleet's project list and each
# project's checkout root. Scope it with --home / --fleet / --project.
#
# This is the verification wrapper the 2026-08-13 parent-hook-drift audit asked
# for. The file copy and the settings.json reconcile already exist and are
# correct — sync-hooks.sh covers .claude/hooks/ including lib/ plus the .hooks
# wiring merge, and sync-codex-hooks.sh mirrors .codex/hooks/. What was missing
# is the step AFTER: nothing re-read the fleet to confirm the rollout landed. So
# `lib/spec-gate-core.sh` sat at four distinct vintages across all ten projects,
# `decision-receipt.sh` was documented and deployed nowhere, and three projects
# carried skill-* hooks on disk that no settings.json referenced — each of them
# a sync that silently did not happen, with no gate to notice.
#
# This script therefore delegates the writes and owns the check:
#   --check    report-only sweep; nonzero exit if any project drifts.
#   (default)  delegate to sync-hooks.sh (+ sync-codex-hooks.sh), then re-run
#              the sweep and exit nonzero on RESIDUAL drift.
#
# The sweep replays the audit's own comparisons:
#   1. Every canonical core-rules/hooks/*.sh is present, byte-identical, +x.
#   2. Every canonical core-rules/hooks/lib/*.sh is present and byte-identical.
#   3. Every canonical (event, matcher, command) hook registration in
#      core-rules/templates/claude-settings.json appears in the project's
#      .claude/settings.json, and the canonical entries appear in canonical
#      ORDER within each event (this is what pins decision-receipt.sh between
#      spec-gate.sh and stop-verify.sh under Stop, per core-rules/hooks.md).
#   4. Where <project>/.codex/hooks/ exists, the Codex mirror is byte-identical
#      too — hooks.json, the Codex hook scripts, and the shared cores.
#
# Project-local extras are NEVER flagged and never removed: a hook file the
# canonical set does not contain (a project's own module-boundary hook), a hook entry
# the canonical wiring does not carry, and config.sh are all out of scope by
# construction — the sweep only asserts that canonical content is PRESENT, never
# that project content is absent.
#
# Usage:
#   rollout-hooks.sh --check              # report only, nonzero on drift
#   rollout-hooks.sh --check --project X  # report only, one project
#   rollout-hooks.sh --yes                # apply to the fleet, then verify
#   rollout-hooks.sh --project X          # apply to one project, then verify
#
# Exit status:
#   0  fleet is in sync (or apply succeeded and left no residual drift)
#   1  drift found (--check), or residual drift after apply
#   2  usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"
# shellcheck source=lib/local-registry.sh
. "$SCRIPT_DIR/lib/local-registry.sh"

CHECK_ONLY=false
ASSUME_YES=false
ONLY_PROJECT=""
HOME_OPT=""
FLEET_OPT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)    CHECK_ONLY=true ;;
    --yes|-y)   ASSUME_YES=true ;;
    --project)
      shift
      [ "$#" -gt 0 ] || { echo "--project requires a name" >&2; exit 2; }
      ONLY_PROJECT="$1"
      ;;
    --project=*) ONLY_PROJECT="${1#--project=}" ;;
    --home)
      shift
      [ "$#" -gt 0 ] || { echo "--home requires PATH" >&2; exit 2; }
      HOME_OPT="$1"
      ;;
    --home=*) HOME_OPT="${1#--home=}" ;;
    --fleet)
      shift
      [ "$#" -gt 0 ] || { echo "--fleet requires NAME" >&2; exit 2; }
      FLEET_OPT="$1"
      ;;
    --fleet=*) FLEET_OPT="${1#--fleet=}" ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

CANONICAL_HOOKS_DIR="$SOURCE_ROOT/core-rules/hooks"
CANONICAL_CODEX_DIR="$SOURCE_ROOT/core-rules/codex"
CANONICAL_CODEX_HOOKS_DIR="$CANONICAL_CODEX_DIR/hooks"
CANONICAL_SETTINGS_TEMPLATE="$SOURCE_ROOT/core-rules/templates/claude-settings.json"
# Kept in lockstep with sync-codex-hooks.sh REVIEWER_CORES: the cross-harness
# decision cores live only in the Claude canonical lib and are copied into
# .codex/hooks/lib/, so the sweep has to look for them there too.
CODEX_SHARED_CORES="code-reviewer.sh ui-verify-core.sh spec-gate-core.sh aeo-gate-warn.sh decision-receipt-core.sh"
[ -d "$CANONICAL_HOOKS_DIR" ]         || { echo "canonical hooks dir missing: $CANONICAL_HOOKS_DIR" >&2; exit 1; }
[ -f "$CANONICAL_SETTINGS_TEMPLATE" ] || { echo "canonical settings template missing: $CANONICAL_SETTINGS_TEMPLATE" >&2; exit 1; }
command -v jq >/dev/null 2>&1         || { echo "jq required for the registration sweep" >&2; exit 1; }

# --- Provenance breadcrumbs ---
# Same reasoning as sync-hooks.sh: the 2026-05-09 incident was a stale source
# that silently shipped old hooks fleet-wide. A verification pass reading from a
# stale canonical would confidently certify the wrong bytes, so name the source.
SOURCE_HEAD="(no git)"
if command -v git >/dev/null 2>&1 && git -C "$SOURCE_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD)"
fi
BELLWETHER="$CANONICAL_HOOKS_DIR/session-context.sh"
BELLWETHER_SHA="(missing)"
[ -f "$BELLWETHER" ] && BELLWETHER_SHA="$(shasum -a 256 "$BELLWETHER" | awk '{print $1}')"

echo "Source:        $SOURCE_ROOT"
echo "Source HEAD:   $SOURCE_HEAD"
echo "Bellwether:    session-context.sh sha=${BELLWETHER_SHA:0:12}"

# --- Fleet membership -------------------------------------------------------
# The project list and each project's checkout come from the machine-local
# registry, not from a tracked table. `registry.md`/`blacklist.md` were removed
# with the portable-fleet work: membership is machine-local now, checkouts live
# at arbitrary absolute paths, and opting a project out is a registry state
# rather than a second tracked file. Resolving a path by joining a shared
# projects root would silently sweep the wrong directory on any machine whose
# checkouts are not siblings.
if ! HOME_PATH="$(trellis_home_resolve "$HOME_OPT" 2>/dev/null)"; then
  echo "could not resolve local Trellis home" >&2
  exit 1
fi
CONFIG_PATH="$(trellis_home_config_path "$HOME_PATH")"
if ! FLEET="$(trellis_home_resolve_fleet "$FLEET_OPT" "$CONFIG_PATH" 2>/dev/null)"; then
  echo "could not resolve local fleet" >&2
  exit 1
fi

REGISTRY_SNAPSHOT="$(local_registry_list_json "$HOME_PATH" "$FLEET" 2>/dev/null)" || {
  echo "could not read local registry for fleet $FLEET" >&2
  exit 1
}

# Parallel name/root arrays: bash 3.2 has no associative arrays, and the rest
# of this script already indexes projects by name.
REGISTRY_NAMES=()
REGISTRY_ROOTS=()
while IFS=$'\t' read -r rh_name rh_root; do
  [ -n "$rh_name" ] || continue
  REGISTRY_NAMES+=("$rh_name")
  REGISTRY_ROOTS+=("$rh_root")
done < <(printf '%s\n' "$REGISTRY_SNAPSHOT" | jq -r '
  [ .entries[]? | select(.status != "detached") ]
  | group_by(.project_id)[]
  | "\(.[0].project_id)\t\(.[0].root // "")"
' 2>/dev/null)

resolve_project_path() {
  local name="$1" i=0
  [ "${#REGISTRY_NAMES[@]}" -eq 0 ] && { printf ''; return 0; }
  while [ "$i" -lt "${#REGISTRY_NAMES[@]}" ]; do
    if [ "${REGISTRY_NAMES[$i]}" = "$name" ]; then
      printf '%s' "${REGISTRY_ROOTS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  printf ''
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# hook_registrations <settings.json>
# Emits one "event<TAB>matcher<TAB>basename" line per wired hook entry, in file
# order. Command args are stripped before the basename so a canonical command
# invoked with a flag still matches (mirrors lib/settings-hooks-merge.sh, which
# must agree with this or the sweep would flag what the merge just wrote).
hook_registrations() {
  jq -r '
    (.hooks // {}) | to_entries[] | .key as $e
    | .value[] | (.matcher // "") as $m
    | (.hooks // [])[]
    | "\($e)\t\($m)\t\(.command | sub(" .*";"") | sub(".*/";""))"
  ' "$1"
}

# check_one <name> — print findings, echo the drift count on the LAST line.
# Findings go to stdout; the count is returned via stdout so the caller can
# accumulate without a subshell-visible global (set -e + $(...) makes a
# `return`-based count fragile once a helper legitimately fails).
check_one() {
  local name="$1"
  local proj drift=0
  proj="$(resolve_project_path "$name")"

  if [ ! -d "$proj" ]; then
    echo "== $name =="
    echo "  skip (not on disk): $proj"
    echo "DRIFT:0"
    return 0
  fi

  echo "== $name =="

  local hooks_dir="$proj/.claude/hooks"
  if [ ! -d "$hooks_dir" ]; then
    echo "  MISSING: .claude/hooks/ (run onboard-project.sh first)"
    echo "DRIFT:1"
    return 0
  fi

  # 1. Canonical hook scripts: present, byte-identical, executable.
  local src fn dst
  for src in "$CANONICAL_HOOKS_DIR"/*.sh; do
    fn="$(basename "$src")"
    dst="$hooks_dir/$fn"
    if [ ! -f "$dst" ]; then
      echo "  MISSING: $fn"
      drift=$((drift+1))
      continue
    fi
    if [ "$(sha_of "$src")" != "$(sha_of "$dst")" ]; then
      echo "  DRIFTED: $fn (sha $(sha_of "$dst" | cut -c1-12) != canonical $(sha_of "$src" | cut -c1-12))"
      drift=$((drift+1))
      continue
    fi
    if [ ! -x "$dst" ]; then
      echo "  NOT EXECUTABLE: $fn"
      drift=$((drift+1))
    fi
  done

  # 2. Canonical lib/. The audit's worst finding lived here — lib/ was synced by
  #    sync-hooks.sh but nothing verified it, so spec-gate-core.sh ran at four
  #    vintages fleet-wide while every manifest check reported green.
  if [ -d "$CANONICAL_HOOKS_DIR/lib" ]; then
    for src in "$CANONICAL_HOOKS_DIR/lib"/*.sh; do
      fn="$(basename "$src")"
      dst="$hooks_dir/lib/$fn"
      if [ ! -f "$dst" ]; then
        echo "  MISSING: lib/$fn"
        drift=$((drift+1))
        continue
      fi
      if [ "$(sha_of "$src")" != "$(sha_of "$dst")" ]; then
        echo "  DRIFTED: lib/$fn (sha $(sha_of "$dst" | cut -c1-12) != canonical $(sha_of "$src" | cut -c1-12))"
        drift=$((drift+1))
      fi
    done
  fi

  # 3. settings.json registration + canonical ordering.
  local settings="$proj/.claude/settings.json"
  if [ ! -f "$settings" ]; then
    echo "  MISSING: .claude/settings.json (run onboard-project.sh first)"
    drift=$((drift+1))
  elif ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  MALFORMED: .claude/settings.json is not valid JSON"
    drift=$((drift+1))
  else
    local canon_regs proj_regs
    canon_regs="$(hook_registrations "$CANONICAL_SETTINGS_TEMPLATE")"
    proj_regs="$(hook_registrations "$settings")"

    # 3a. Presence: every canonical (event, matcher, command) triple is wired.
    #     This is the check that would have caught the three projects carrying
    #     skill-*.sh on disk with no settings.json entry pointing at them.
    #     Split the tab-separated record by hand rather than with
    #     `IFS=$'\t' read -r ev mt cmd`. Tab is an IFS *whitespace* character,
    #     so read collapses a run of tabs into one delimiter and drops empty
    #     leading/trailing fields — which silently shifted every no-matcher
    #     record (Stop, SessionStart, PreCompact carry matcher "") one field
    #     left, leaving $cmd empty and skipping the entire entry. That is most
    #     of the canonical manifest, including decision-receipt.sh.
    local line ev mt cmd rest
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ev="${line%%$'\t'*}"
      rest="${line#*$'\t'}"
      mt="${rest%%$'\t'*}"
      cmd="${rest#*$'\t'}"
      [ -n "$cmd" ] || continue
      if ! printf '%s\n' "$proj_regs" | grep -qxF "$ev	$mt	$cmd"; then
        echo "  UNREGISTERED: $cmd (expected under $ev${mt:+ matcher=$mt})"
        drift=$((drift+1))
      fi
    done <<EOF
$canon_regs
EOF

    # 3b. Order: within each event, the canonical entries must appear in
    #     canonical order. Canonical Stop order is spec-gate ->
    #     decision-receipt -> stop-verify -> code-review-subagent ->
    #     propose-rules -> ui-verify -> stamp-turn; a project that appends
    #     decision-receipt at the END of Stop is wired but wired WRONG, and 3a
    #     alone would call that green.
    #
    #     Both sequences are restricted to canonical commands the project
    #     ACTUALLY wires, which keeps 3a and 3b orthogonal: a hook that is
    #     simply absent is one UNREGISTERED finding, not an UNREGISTERED plus a
    #     phantom MISORDERED for every event it belonged to. Project-local
    #     entries are filtered out too, so a bespoke hook never trips this.
    local events canon_seq proj_seq
    events="$(printf '%s\n' "$canon_regs" | cut -f1 | awk 'NF' | awk '!seen[$0]++')"
    for ev in $events; do
      proj_seq="$(printf '%s\n' "$proj_regs" | awk -F'\t' -v e="$ev" '$1==e {print $3}')"
      canon_seq="$(printf '%s\n' "$canon_regs" | awk -F'\t' -v e="$ev" '$1==e {print $3}')"
      # Restrict each side to the intersection, preserving its own order.
      proj_seq="$(printf '%s\n' "$proj_seq" | grep -xF -f <(printf '%s\n' "$canon_seq") || true)"
      canon_seq="$(printf '%s\n' "$canon_seq" | grep -xF -f <(printf '%s\n' "$proj_seq") || true)"
      if [ "$canon_seq" != "$proj_seq" ]; then
        echo "  MISORDERED: $ev canonical hooks out of canonical order"
        echo "    expected: $(printf '%s' "$canon_seq" | tr '\n' ' ')"
        echo "    found:    $(printf '%s' "$proj_seq" | tr '\n' ' ')"
        drift=$((drift+1))
      fi
    done
  fi

  # 4. Codex mirror, only where the project already has one. A project without
  #    .codex/hooks/ has not opted into the Codex harness; absence is not drift.
  if [ -d "$proj/.codex/hooks" ]; then
    if [ -f "$CANONICAL_CODEX_DIR/hooks.json" ]; then
      if [ ! -f "$proj/.codex/hooks.json" ]; then
        echo "  MISSING: .codex/hooks.json"
        drift=$((drift+1))
      elif ! cmp -s "$CANONICAL_CODEX_DIR/hooks.json" "$proj/.codex/hooks.json"; then
        echo "  DRIFTED: .codex/hooks.json"
        drift=$((drift+1))
      fi
    fi
    if [ -d "$CANONICAL_CODEX_HOOKS_DIR" ]; then
      for src in "$CANONICAL_CODEX_HOOKS_DIR"/*.sh; do
        [ -f "$src" ] || continue
        fn="$(basename "$src")"
        dst="$proj/.codex/hooks/$fn"
        if [ ! -f "$dst" ]; then
          echo "  MISSING: .codex/hooks/$fn"
          drift=$((drift+1))
        elif [ "$(sha_of "$src")" != "$(sha_of "$dst")" ]; then
          echo "  DRIFTED: .codex/hooks/$fn"
          drift=$((drift+1))
        fi
      done
    fi
    # Codex lib/ = the canonical Codex lib plus the shared Claude cores.
    for src in "$CANONICAL_CODEX_HOOKS_DIR"/lib/*.sh; do
      [ -f "$src" ] || continue
      fn="$(basename "$src")"
      dst="$proj/.codex/hooks/lib/$fn"
      if [ ! -f "$dst" ]; then
        echo "  MISSING: .codex/hooks/lib/$fn"
        drift=$((drift+1))
      elif [ "$(sha_of "$src")" != "$(sha_of "$dst")" ]; then
        echo "  DRIFTED: .codex/hooks/lib/$fn"
        drift=$((drift+1))
      fi
    done
    for fn in $CODEX_SHARED_CORES; do
      src="$CANONICAL_HOOKS_DIR/lib/$fn"
      [ -f "$src" ] || continue
      dst="$proj/.codex/hooks/lib/$fn"
      if [ ! -f "$dst" ]; then
        echo "  MISSING: .codex/hooks/lib/$fn"
        drift=$((drift+1))
      elif [ "$(sha_of "$src")" != "$(sha_of "$dst")" ]; then
        echo "  DRIFTED: .codex/hooks/lib/$fn"
        drift=$((drift+1))
      fi
    done
  fi

  [ "$drift" -eq 0 ] && echo "  (in sync)"
  echo "DRIFT:$drift"
}

# sweep — run check_one over every target, print findings, return total drift.
sweep() {
  local n out total=0 per
  for n in ${TARGETS[@]+"${TARGETS[@]}"}; do
    out="$(check_one "$n")"
    printf '%s\n' "$out" | grep -v '^DRIFT:'
    per="$(printf '%s\n' "$out" | sed -n 's/^DRIFT://p' | tail -1)"
    total=$((total + per))
  done
  SWEEP_TOTAL="$total"
}

# --- Target resolution ------------------------------------------------------
# bash 3.2 + set -u: length-guard every expansion that can legitimately be empty.
TARGETS=()
if [ -n "$ONLY_PROJECT" ]; then
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      [ "$n" = "$ONLY_PROJECT" ] && TARGETS+=("$n")
    done
  fi
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "project not in local registry fleet $FLEET: $ONLY_PROJECT" >&2
    exit 1
  fi
else
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      TARGETS+=("$n")
    done
  fi
fi

echo "Targets: ${TARGETS[*]-}"

SWEEP_TOTAL=0

if $CHECK_ONLY; then
  echo "== check =="
  sweep
  echo "== done =="
  if [ "$SWEEP_TOTAL" -gt 0 ]; then
    echo "DRIFT: $SWEEP_TOTAL finding(s) across ${#TARGETS[@]} project(s)." >&2
    exit 1
  fi
  echo "Fleet is in sync ($SWEEP_TOTAL findings)."
  exit 0
fi

# --- Apply mode -------------------------------------------------------------
if ! $ASSUME_YES; then
  printf "Apply canonical hooks to: %s ? [y/N] " "${TARGETS[*]-}"
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit 0; }
fi

echo "== apply: .claude =="
if [ -n "$ONLY_PROJECT" ]; then
  "$SCRIPT_DIR/sync-hooks.sh" --yes "$ONLY_PROJECT"
else
  "$SCRIPT_DIR/sync-hooks.sh" --yes
fi

if pg_has_harness codex; then
  echo "== apply: .codex =="
  if [ -n "$ONLY_PROJECT" ]; then
    "$SCRIPT_DIR/sync-codex-hooks.sh" --yes "$ONLY_PROJECT"
  else
    "$SCRIPT_DIR/sync-codex-hooks.sh" --yes
  fi
fi

# Post-sync verification — the whole point of this wrapper. An apply that
# reports success while leaving drift behind is exactly the failure the audit
# documented, so the exit status is the sweep's, not the sync's.
echo "== verify =="
sweep
echo "== done =="
if [ "$SWEEP_TOTAL" -gt 0 ]; then
  echo "RESIDUAL DRIFT after apply: $SWEEP_TOTAL finding(s). Rollout is NOT complete." >&2
  exit 1
fi
echo "Fleet is in sync ($SWEEP_TOTAL findings)."
echo "Reminder: commit changes in each project (chore: sync hooks to canonical)."
