#!/usr/bin/env bash
# Verify — and optionally reconcile — the fleet's locally attached harness
# surfaces against the immutable releases the local registry records.
#
# Reads the machine-local Trellis home for the fleet's registered rows. Scope it
# with --home / --fleet / --project.
#
# This is the verification wrapper the 2026-08-13 parent-hook-drift audit asked
# for, rebuilt on the portable-attachment model. The audit's finding still
# stands: the file copy and the settings reconcile already existed and were
# correct, and nothing re-read the fleet afterwards to confirm the rollout
# landed, so `lib/spec-gate-core.sh` sat at four vintages across ten projects
# with every manifest check reporting green.
#
# What changed is WHERE truth lives. A project no longer receives raw copies of
# this checkout's core-rules/: it carries a committed attachment bound to an
# installed immutable release, and the mutable source tree that launched this
# command has no authority over it at all. Comparing SOURCE_ROOT/core-rules with
# a project's .claude/hooks therefore answers a question nobody asks any more —
# a management checkout sitting on an unreleased branch would report the whole
# fleet drifted while every attachment was exactly correct.
#
# So the sweep asks the one question that is authoritative:
#
#   for every selected registry row, does hc_portable_attachment accept it?
#
# That predicate — the same one `trellis show-config` and `trellis doctor` use —
# checks the exact registry/owner binding, the verified immutable release, the
# managed exclude block, the native surfaces (links, renders, runtime anchor)
# and the managed hooks, for exactly the harnesses that row attaches. Harness
# coverage therefore follows the attachment: a Pi-only row is verified against
# the Pi surface and is NOT expected to carry .claude/hooks.
#
# It is an INSTALLATION predicate. It proves the managed leaves on disk match
# the immutable manifest; it does not prove any harness loaded them, and this
# command never claims enforcement.
#
# Row dispositions, all of them explicit:
#   verified      an available, active, non-excluded worktree whose attachment
#                 the strict predicate accepts.
#   report-only   an explicitly excluded or detached inventory row. Counted
#                 separately and never folded into the verified population.
#   failure       an identity-error row, an unavailable row, an active row with
#                 no committed attachment, an unreadable row, or an attachment
#                 the predicate rejects.
#
# A run that verifies nothing says so. "Fleet is in sync" is reserved for a run
# that actually verified at least one attachment and rejected none.
#
# Usage:
#   rollout-hooks.sh --check              # report only, nonzero on any failure
#   rollout-hooks.sh --check --project X  # report only, one project
#   rollout-hooks.sh --yes                # reconcile the fleet, then verify
#   rollout-hooks.sh --project X          # reconcile one project, then verify
#
# Exit status:
#   0   every selected row verified, and at least one attachment was verified
#   1   selection error (the named project has no row in the selected fleet)
#   2   usage error
#   3   a selected attachment conflicts with its registry/owner binding
#   4   registry state error, or a selected row could not be verified
#   5   the environment could not answer, or there was nothing to verify
#   *   in apply mode, the raw exit of a failing sync child, propagated verbatim

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"
# shellcheck source=lib/release-store.sh
. "$SCRIPT_DIR/lib/release-store.sh"
# shellcheck source=lib/local-registry.sh
. "$SCRIPT_DIR/lib/local-registry.sh"
# shellcheck source=lib/surface-plan.sh
. "$SCRIPT_DIR/lib/surface-plan.sh"
# shellcheck source=lib/attachment.sh
. "$SCRIPT_DIR/lib/attachment.sh"
# shellcheck source=lib/health-checks.sh
. "$SCRIPT_DIR/lib/health-checks.sh"

# Same boundary sync-hooks.sh uses: every dynamic value that reaches a terminal
# — a registry root, a release string, a child diagnostic — goes through %q, so
# a control byte in registry text is rendered rather than executed.
diagnostic_escape() {
  LC_ALL=C printf '%q' "${1-}"
}

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
      [ "$#" -gt 0 ] || { echo "--project requires a name" >&2; exit "$TRELLIS_EX_USAGE"; }
      ONLY_PROJECT="$1"
      ;;
    --project=*) ONLY_PROJECT="${1#--project=}" ;;
    --home)
      shift
      [ "$#" -gt 0 ] || { echo "--home requires PATH" >&2; exit "$TRELLIS_EX_USAGE"; }
      HOME_OPT="$1"
      ;;
    --home=*) HOME_OPT="${1#--home=}" ;;
    --fleet)
      shift
      [ "$#" -gt 0 ] || { echo "--fleet requires NAME" >&2; exit "$TRELLIS_EX_USAGE"; }
      FLEET_OPT="$1"
      ;;
    --fleet=*) FLEET_OPT="${1#--fleet=}" ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown option: $(diagnostic_escape "$1")" >&2
      exit "$TRELLIS_EX_USAGE"
      ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || {
  echo "jq is required for the local registry sweep" >&2
  exit "$TRELLIS_EX_UNAVAILABLE"
}

# --- Selected local state ---------------------------------------------------
# The project list, each row's checkout root, its attachment binding and its
# recorded release all come from the machine-local registry. Membership is
# machine-local: checkouts live at arbitrary absolute paths, and joining a
# shared projects root would sweep the wrong directory on any machine whose
# checkouts are not siblings.
if HOME_PATH="$(trellis_home_resolve "$HOME_OPT" 2>/dev/null)"; then
  :
else
  rc=$?
  echo "could not resolve local Trellis home" >&2
  exit "$rc"
fi
CONFIG_PATH="$(trellis_home_config_path "$HOME_PATH")"
if FLEET="$(trellis_home_resolve_fleet "$FLEET_OPT" "$CONFIG_PATH" 2>/dev/null)"; then
  :
else
  rc=$?
  echo "could not resolve local fleet" >&2
  exit "$rc"
fi

printf 'Trellis home: %s\n' "$(diagnostic_escape "$HOME_PATH")"
printf 'Fleet:        %s\n' "$(diagnostic_escape "$FLEET")"

# The aggregate is armed before any selection, for the same reason sync-hooks.sh
# arms its own there: a state error is a property of the REGISTRY, and no later
# exit path — including the selection refusal — may report below what the FULL
# listing has already proven.
RESULT_STATUS=0
VERIFIED=0
FAILED=0
REPORTED=0

record_failure() {
  local status="$1"
  if [ "$status" -gt "$RESULT_STATUS" ]; then
    RESULT_STATUS="$status"
  fi
}

# read_listing <snapshot-file> <targets-file>
# Consumes the COMPLETE strict listing, then narrows to the selection. The
# listing's own class-4 rows (availability `identity_error`) are legitimate
# content and are kept as rows so the sweep can fail on them; a listing that
# does not read as an inventory at all is fatal, and no row is ever dropped.
read_listing() {
  local snapshot="$1" targets="$2" rc
  if local_registry_list_json "$HOME_PATH" "$FLEET" > "$snapshot"; then
    :
  else
    rc=$?
    printf 'could not read the strict local registry for fleet %s\n' \
      "$(diagnostic_escape "$FLEET")" >&2
    return "$rc"
  fi
  if ! jq -e '(.entries | type) == "array"' "$snapshot" >/dev/null 2>&1; then
    printf '%s\n' 'strict local registry listing is not a readable inventory' >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -n "$ONLY_PROJECT" ]; then
    jq -c --arg project_id "$ONLY_PROJECT" \
      '.entries[] | select(.project_id == $project_id)' "$snapshot" > "$targets" ||
      return "$TRELLIS_EX_STATE"
  else
    jq -c '.entries[]' "$snapshot" > "$targets" || return "$TRELLIS_EX_STATE"
  fi
  # Rows the --project filter just removed are reported from the FULL listing,
  # so a scoped run over a healthy project can never exit clean over a registry
  # it has been shown to be corrupt. Unscoped, this reports nothing.
  if local_registry_report_unselected_state_errors "$(cat "$snapshot")" "$(cat "$targets")"; then
    :
  else
    record_failure "$?"
  fi
}

# verify_row <listing-row> — one row, one disposition, printed as it is decided.
verify_row() {
  local row="$1"
  local fleet project_id kind availability status excluded root release
  local attachment_id checkout_id worktree_id harnesses label owner detail_file detail rc

  # Extract nullable columns independently. Tab is an IFS whitespace character,
  # so a single tab-separated read would collapse an empty attachment_id and
  # shift every later binding field one column left.
  if fleet="$(printf '%s\n' "$row" | jq -er '.fleet' 2>/dev/null)" &&
     project_id="$(printf '%s\n' "$row" | jq -er '.project_id' 2>/dev/null)" &&
     kind="$(printf '%s\n' "$row" | jq -er '.kind' 2>/dev/null)" &&
     availability="$(printf '%s\n' "$row" | jq -er '.availability' 2>/dev/null)" &&
     status="$(printf '%s\n' "$row" | jq -er '.status' 2>/dev/null)" &&
     excluded="$(printf '%s\n' "$row" | jq -er '((.excluded // false) | tostring)' 2>/dev/null)" &&
     root="$(printf '%s\n' "$row" | jq -r '(.root // "")' 2>/dev/null)" &&
     release="$(printf '%s\n' "$row" | jq -r '(.release // "")' 2>/dev/null)" &&
     attachment_id="$(printf '%s\n' "$row" | jq -r '(.attachment_id // "")' 2>/dev/null)" &&
     checkout_id="$(printf '%s\n' "$row" | jq -r '(.checkout_id // "")' 2>/dev/null)" &&
     worktree_id="$(printf '%s\n' "$row" | jq -r '(.worktree_id // "")' 2>/dev/null)" &&
     harnesses="$(printf '%s\n' "$row" | jq -c '(.harnesses // [])' 2>/dev/null)"; then
    :
  else
    echo "== (unreadable registry row) =="
    echo "  MALFORMED: strict registry row could not be read; it is not dropped"
    FAILED=$((FAILED + 1))
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  label="$fleet/$project_id"
  printf '== %s [%s] %s ==\n' "$(diagnostic_escape "$label")" "$(diagnostic_escape "$kind")" \
    "$(diagnostic_escape "${root:-(no recorded root)}")"

  # Identity drift is tested first, exactly as sync_one tests it: it is a fact
  # about the row's recorded identity, not about whether this run would have
  # acted on the row, so an excluded or detached row's drift is still a failure.
  if [ "$availability" = identity_error ]; then
    echo "  IDENTITY ERROR: registry row failed identity validation"
    FAILED=$((FAILED + 1))
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  if [ "$excluded" = true ]; then
    echo "  report-only: explicitly excluded inventory row; not verified"
    REPORTED=$((REPORTED + 1))
    return 0
  fi
  if [ "$status" = detached ]; then
    echo "  report-only: detached inventory row; not verified"
    REPORTED=$((REPORTED + 1))
    return 0
  fi
  if [ "$availability" = unavailable ] || [ "$status" = unavailable ] || [ "$kind" = unavailable ]; then
    echo "  UNAVAILABLE: registered root is not present; nothing here can be called synchronized"
    FAILED=$((FAILED + 1))
    record_failure "$TRELLIS_EX_UNAVAILABLE"
    return 0
  fi
  if [ "$kind" != worktree ] || [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "  UNATTACHED: active registry row carries no available worktree to verify"
    FAILED=$((FAILED + 1))
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  if [ -z "$attachment_id" ] || [ -z "$checkout_id" ] || [ -z "$worktree_id" ] || [ -z "$release" ]; then
    echo "  UNATTACHED: active worktree has no committed immutable attachment"
    FAILED=$((FAILED + 1))
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi

  # The owner path is DERIVED from the row's own validated checkout/worktree
  # IDs — the same derivation doctor, show-config and sync-hooks use. Nothing
  # here invents an ID or guesses a path.
  owner="$HOME_PATH/state/attachments/$checkout_id/$worktree_id.json"
  if detail_file="$(mktemp "${TMPDIR:-/tmp}/trellis.rollout-attachment.XXXXXX")"; then
    :
  else
    echo "  UNAVAILABLE: could not allocate a diagnostic for the attachment check"
    FAILED=$((FAILED + 1))
    record_failure "$TRELLIS_EX_UNAVAILABLE"
    return 0
  fi
  # Redirected to a file, never captured with $(...): the predicate reports its
  # verdict through HC_PORTABLE_* globals, and a command substitution would run
  # it in a subshell where those assignments are discarded.
  if hc_portable_attachment "$HOME_PATH" "$owner" "$root" "$fleet" "$project_id" \
       "$checkout_id" "$worktree_id" "$attachment_id" "$release" "$harnesses" \
       > "$detail_file" 2>/dev/null; then
    rc="$HC_OK"
  else
    rc=$?
  fi
  detail="$(tail -n 1 "$detail_file")"
  rm -f "$detail_file"

  if [ "$rc" -eq "$HC_OK" ] && [ "$HC_PORTABLE_ATTACHMENT_STATE" = attached ]; then
    printf '  verified: installed immutable attachment %s for %s\n' \
      "$(diagnostic_escape "$release")" \
      "$(diagnostic_escape "$(printf '%s\n' "$harnesses" | jq -r 'join(", ")')")"
    VERIFIED=$((VERIFIED + 1))
    return 0
  fi
  printf '  CONFLICT: %s\n' "$(diagnostic_escape "${detail:-strict immutable attachment verification failed}")"
  FAILED=$((FAILED + 1))
  case "$HC_PORTABLE_OWNER_STATE" in
    conflict) record_failure "$TRELLIS_EX_CONFLICT" ;;
    *) record_failure "$TRELLIS_EX_STATE" ;;
  esac
}

# sweep — read the registry FRESH, then verify every selected row.
sweep() {
  local snapshot targets row count rc=0
  VERIFIED=0
  FAILED=0
  REPORTED=0
  snapshot="$(mktemp "${TMPDIR:-/tmp}/trellis.rollout-registry.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  targets="$(mktemp "${TMPDIR:-/tmp}/trellis.rollout-targets.XXXXXX")" || {
    rm -f "$snapshot"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  if read_listing "$snapshot" "$targets"; then
    :
  else
    rc=$?
    rm -f "$snapshot" "$targets"
    return "$rc"
  fi
  count="$(wc -l < "$targets" | tr -d ' ')"
  if [ "$count" -eq 0 ] && [ -n "$ONLY_PROJECT" ]; then
    printf 'project not in local registry fleet %s: %s\n' \
      "$(diagnostic_escape "$FLEET")" "$(diagnostic_escape "$ONLY_PROJECT")" >&2
    rm -f "$snapshot" "$targets"
    return 1
  fi
  printf 'Selected rows: %s\n' "$count"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    verify_row "$row"
  done < "$targets"
  rm -f "$snapshot" "$targets"
}

# report — the summary line, and the only place "in sync" may be printed.
report() {
  printf 'verified=%s failed=%s report-only=%s\n' "$VERIFIED" "$FAILED" "$REPORTED"
  if [ "$FAILED" -gt 0 ]; then
    printf '%s attachment(s) could not be verified. Rollout is NOT complete.\n' "$FAILED" >&2
    return 0
  fi
  if [ "$RESULT_STATUS" -ne 0 ]; then
    printf '%s\n' 'verification incomplete; rollout is NOT complete' >&2
    return 0
  fi
  if [ "$VERIFIED" -eq 0 ]; then
    printf '%s\n' 'no attachments verified; this run proves nothing about fleet state' >&2
    record_failure "$TRELLIS_EX_UNAVAILABLE"
    return 0
  fi
  printf 'Fleet is in sync (%s attachment(s) verified against their installed immutable release).\n' "$VERIFIED"
}

if $CHECK_ONLY; then
  echo "== check =="
  if sweep; then :; else record_failure "$?"; fi
  echo "== done =="
  report
  exit "$RESULT_STATUS"
fi

# --- Apply mode -------------------------------------------------------------
# The wrapper owns the CHECK. Every mutation is delegated to the existing
# reconcilers, which write only from a verified installed release; this command
# copies nothing itself. Both children are invoked for the selected scope, and
# a child failure propagates raw and stops the run before any success line.
if ! $ASSUME_YES; then
  if [ -n "$ONLY_PROJECT" ]; then
    printf 'Reconcile attached harness surfaces in fleet %s for project %s ? [y/N] ' \
      "$(diagnostic_escape "$FLEET")" "$(diagnostic_escape "$ONLY_PROJECT")"
  else
    printf 'Reconcile attached harness surfaces across fleet %s ? [y/N] ' \
      "$(diagnostic_escape "$FLEET")"
  fi
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit 0; }
fi

echo "== apply: .claude =="
if [ -n "$ONLY_PROJECT" ]; then
  "$SCRIPT_DIR/sync-hooks.sh" --home "$HOME_PATH" --fleet "$FLEET" --yes "$ONLY_PROJECT"
else
  "$SCRIPT_DIR/sync-hooks.sh" --home "$HOME_PATH" --fleet "$FLEET" --yes
fi

echo "== apply: .codex =="
if [ -n "$ONLY_PROJECT" ]; then
  "$SCRIPT_DIR/sync-codex-hooks.sh" --home "$HOME_PATH" --fleet "$FLEET" --yes "$ONLY_PROJECT"
else
  "$SCRIPT_DIR/sync-codex-hooks.sh" --home "$HOME_PATH" --fleet "$FLEET" --yes
fi

# Post-apply verification — the whole point of this wrapper. The registry is
# re-read here rather than reused from a pre-apply step: a reconcile can change
# a row's attachment binding, and verifying stale rows would certify a state
# that no longer exists. An apply that reports success while leaving an
# unverifiable attachment behind is exactly the failure the audit documented,
# so the exit status is the sweep's, not the children's.
#
# A harness the reconcilers do not drive (Pi) is not synchronized by this
# wrapper either; those children report it n/a and the sweep still verifies the
# selected Pi attachment strictly, or fails.
echo "== verify =="
if sweep; then :; else record_failure "$?"; fi
echo "== done =="
report
exit "$RESULT_STATUS"
