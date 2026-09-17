#!/usr/bin/env bash
# User-skill harness table for Trellis-owned skill links.
#
# Single source of truth mapping a skill's harness set to native discovery
# roots. Sourced by the surface-plan validator, the skills command, and the
# doctor check, so the mapping is defined once.
#
# Table (spec 049 SC2, confirmed by the T1 Codex 0.154.0 probe):
#   claude          -> .claude/skills
#   codex + pi      -> .agents/skills (single shared link)
#   pi alone        -> .pi/agent/skills
#   codex alone     -> .codex/skills
#
# Public functions:
#   skill_roots_for_harnesses <harness>...
#
# Bash 3.2 compatible; sourcing this file has no side effects.

skill_roots_for_harnesses() {
  local harness has_claude=false has_codex=false has_pi=false

  [ "$#" -gt 0 ] || {
    printf 'skill-roots: harness set requires at least one harness\n' >&2
    return 2
  }
  for harness in "$@"; do
    case "$harness" in
      claude) has_claude=true ;;
      codex) has_codex=true ;;
      pi) has_pi=true ;;
      *)
        printf 'skill-roots: unknown harness: %s\n' "$harness" >&2
        return 2
        ;;
    esac
  done
  if [ "$has_claude" = true ]; then
    printf '%s\n' ".claude/skills"
  fi
  if [ "$has_codex" = true ] && [ "$has_pi" = true ]; then
    printf '%s\n' ".agents/skills"
  elif [ "$has_pi" = true ]; then
    printf '%s\n' ".pi/agent/skills"
  elif [ "$has_codex" = true ]; then
    printf '%s\n' ".codex/skills"
  fi
  return 0
}
