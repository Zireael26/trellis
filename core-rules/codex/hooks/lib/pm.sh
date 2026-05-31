#!/usr/bin/env bash
# Trellis package-manager resolver (shared helper).
# Sourced by hooks that need to know which package manager a project uses.
# Sibling location: lib/ alongside the hook scripts.
#
# Single source of truth for PM resolution. By deliberate design (Trellis
# avoids incidental cross-subsystem coupling — see husky/pre-commit comments)
# this logic is MIRRORED, not shared-by-symlink, in:
#   - core-rules/codex/hooks/lib/pm.sh                       (codex harness copy, identical)
#   - core-rules/skills/process-gate/scripts/lib/common.sh   (pg_resolve_pm)
#   - core-rules/husky/pre-push                              (inlined; git-level, seeded once)
# Keep these four in sync — resolution precedence + lockfile order are identical.
# One deliberate divergence: pg_resolve_pm returns EMPTY when a project has no
# JS lockfile and no explicit config (so Python/Go toolchain detection can
# proceed), whereas this helper terminates at npm. stop-verify only calls this
# inside an `[ -f package.json ]` guard, so the npm terminal never bites non-JS.
#
# Resolution (first hit wins):
#   1. project-local <repo>/.trellis.config.json  .package_manager
#   2. project-local <repo>/trellis.config.json   .package_manager
#   3. fleet $TRELLIS_ROOT/trellis.config.json     .package_manager
#   4. "auto" (or unset / any non-jq env) → lockfile detection:
#        pnpm-lock.yaml → pnpm | bun.lock(b) → bun | yarn.lock → yarn
#        | package-lock.json → npm | (none) → npm
#
# "auto" == today's lockfile detection: this whole helper is ADDITIVE — with
# package_manager unset, behaviour is byte-identical to the pre-config hooks.
# A project/fleet opts in by setting an explicit value.

# trellis_resolve_pm [project_dir]
#   Echoes the resolved package manager (pnpm|npm|bun|yarn). Never empty for a
#   JS project; callers should still gate on package.json before invoking.
trellis_resolve_pm() {
  local dir="${1:-$PWD}" pm="" cand
  if command -v jq >/dev/null 2>&1; then
    for cand in "$dir/.trellis.config.json" "$dir/trellis.config.json"; do
      if [ -f "$cand" ]; then
        pm="$(jq -r '.package_manager // empty' "$cand" 2>/dev/null)"
        [ -n "$pm" ] && break
      fi
    done
    if [ -z "$pm" ] && [ -n "${TRELLIS_ROOT:-}" ] && [ -f "$TRELLIS_ROOT/trellis.config.json" ]; then
      pm="$(jq -r '.package_manager // empty' "$TRELLIS_ROOT/trellis.config.json" 2>/dev/null)"
    fi
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
