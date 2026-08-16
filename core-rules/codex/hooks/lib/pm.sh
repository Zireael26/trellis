#!/usr/bin/env bash
# Trellis package-manager resolver (shared helper).
# Sourced by hooks that need to know which package manager a project uses.
# Sibling location: lib/ alongside the hook scripts.
#
# This logic is MIRRORED, not shared-by-symlink, in:
#   - core-rules/codex/hooks/lib/pm.sh                       (Codex harness copy, identical)
#   - core-rules/skills/process-gate/scripts/lib/common.sh   (pg_resolve_pm)
#
# Keep the Claude/Codex copies byte-identical. Process gate preserves this
# policy precedence but returns EMPTY without an explicit value or JS lockfile,
# while this helper terminates at npm. The separately inlined husky/pre-push
# copy is seeded once and does not source this helper.
#
# Resolution (first available value wins):
#   1. canonical project <repo>/.trellis.json                 .package_manager
#   2. DEPRECATED legacy <repo>/.trellis.config.json         .package_manager
#      (read-only; kept past v1.0.0-rc.25 only for checkouts still held on the
#      legacy layout — `trellis migrate --prepare` replaces it with .trellis.json)
#   3. immutable runtime $TRELLIS_ROOT/trellis.config.json    .package_manager
#   4. "auto" or unset → lockfile detection:
#        pnpm-lock.yaml → pnpm | bun.lock(b) → bun | yarn.lock → yarn
#        | package-lock.json → npm | (none) → npm
#
# A selected value must be auto, pnpm, npm, bun, or yarn. Unsupported, null,
# empty, and malformed values still claim their precedence slot, then resolve
# through lockfile detection rather than exposing a lower policy source.

# trellis_resolve_pm [project_dir]
#   Echoes the resolved package manager (pnpm|npm|bun|yarn). Never empty for a
#   JS project; callers should still gate on package.json before invoking.
trellis_resolve_pm() {
  local dir="${1:-$PWD}" pm="" cand
  if command -v jq >/dev/null 2>&1; then
    # A candidate without package_manager is absent and falls through. Once a
    # candidate is malformed/non-object or declares package_manager, it owns
    # this field's precedence slot: invalid, null, and empty values resolve as
    # auto rather than allowing a lower policy source to override them.
    for cand in \
      "$dir/.trellis.json" \
      "$dir/.trellis.config.json" \
      "${TRELLIS_ROOT:+${TRELLIS_ROOT}/trellis.config.json}"; do
      [ -n "$cand" ] && [ -f "$cand" ] || continue
      if ! jq -e 'type == "object"' "$cand" >/dev/null 2>&1; then
        break
      fi
      if jq -e 'has("package_manager")' "$cand" >/dev/null 2>&1; then
        pm="$(jq -r '.package_manager | if type == "string" then . else empty end' "$cand" 2>/dev/null)"
        break
      fi
    done
    case "$pm" in
      auto|pnpm|npm|bun|yarn|'') ;;
      *) pm="" ;;
    esac
  fi

  if [ -z "$pm" ] || [ "$pm" = "auto" ]; then
    if   [ -f "$dir/pnpm-lock.yaml" ];                          then pm=pnpm
    elif [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ];     then pm=bun
    elif [ -f "$dir/yarn.lock" ];                               then pm=yarn
    elif [ -f "$dir/package-lock.json" ];                       then pm=npm
    else                                                             pm=npm
    fi
  fi
  printf '%s' "$pm"
}

# trellis_pm_available <pm>
#   Returns 0 iff the package-manager binary is on PATH. Mirrors the
#   `command -v node` guard hooks already use — a configured-but-missing PM
#   must skip the step, never hard-fail a commit/push fleet-wide.
trellis_pm_available() {
  command -v "$1" >/dev/null 2>&1
}
