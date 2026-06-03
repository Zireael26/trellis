#!/usr/bin/env bash
# settings-hooks-merge.sh — pure, sourceable helper for the settings.json
# .hooks reconcile step that sync-hooks.sh performs after copying hook files.
#
# Purpose: bring a project's .claude/settings.json .hooks wiring up to the
# canonical baseline WITHOUT clobbering project-specific hook blocks. The hook
# *files* are copied by sync-hooks.sh; this reconciles the *wiring* (which event
# arrays reference which commands) so a project that gained a new canonical hook
# (e.g. reread-guard, track-read, propose-rules, stamp-turn) actually gets it
# wired, while a bespoke hook a project added (e.g. neev's
# check-module-boundary.sh on PreToolUse Edit|Write, or a custom hook appended
# into the single canonical Stop block) survives verbatim.
#
# Granularity is per hook ENTRY, not per block. The canonical Stop/SessionStart
# baselines are SINGLE multi-entry blocks, so the realistic authoring pattern is
# to append a custom hook entry INTO an existing canonical block. A block-level
# "drop the whole block if any command is canonical" rule would silently lose
# that custom entry. Instead: within each project block we drop only the hook
# ENTRIES whose command basename is canonical (the canonical baseline already
# carries those), keep the surviving non-canonical entries, and keep the block
# itself iff at least one entry survived. So:
#   * a block of ONLY canonical entries -> all entries drop -> empty block pruned
#     (the canonical baseline already laid it down).
#   * a block MIXING canonical + novel entries -> canonical entries drop, novel
#     entries survive in their original block/matcher.
#   * a block of ONLY novel entries -> survives verbatim.
# Comparison is by BASENAME (with any trailing args stripped first, so a
# canonical command invoked WITH a flag still matches and is not duplicated) so
# $CLAUDE_PROJECT_DIR/.claude/hooks/x.sh matches canonical x.sh. The basename
# match is case-SENSITIVE (x.sh != X.sh); hook filenames are lowercase by
# convention, so normalizing case is not worth the surface area.
#
# Read/write contract:
#   READS  — the two file paths passed as args (canonical template + project
#            settings.json), via jq only.
#   WRITES — nothing. Prints the merged settings JSON to stdout. Sets no global
#            variables, mutates no shell state, touches no files. The caller
#            (sync-hooks.sh) owns change-detection, DRY_RUN, and the temp-file
#            write. This separation lets the bats suite bind to the pure
#            function (mirrors sync-coverage.sh / sync-coverage.bats).
#   This file intentionally does NOT set `set -euo pipefail`: sourcing it must
#   not alter the caller's / test harness's shell.
#
# Idempotent: the merge rebuilds .hooks from the canonical baseline plus the
# re-derived surviving (non-canonical) project entries every time, so a 2nd run
# on its own output yields byte-identical JSON. On the 2nd pass the canonical
# baseline's own entries are dropped from the "project" side (they ARE canonical)
# and the surviving custom entries are re-derived once and only once, so nothing
# accumulates.

# reconcile_settings_hooks <canonical_template> <project_settings>
#   canonical_template : path to core-rules/templates/claude-settings.json
#   project_settings   : path to <project>/.claude/settings.json (must exist)
# Prints the merged settings object to stdout. Returns jq's exit status.
reconcile_settings_hooks() {
  local canonical_template project_settings
  canonical_template="$1"
  project_settings="$2"

  # jq slurp idiom mirrors rollout-settings.sh: .[0]=canonical, .[1]=project.
  #   $canonical_cmds — unique basenames of every canonical hook command (args
  #                     stripped first, though canonical commands carry none —
  #                     mirror the project side so the two never silently diverge
  #                     if canonical ever gains a flag).
  #   merged .hooks   — start from canonical .hooks, then for each project event
  #                     key, append the project blocks with their canonical hook
  #                     ENTRIES removed; a block is kept iff a non-canonical entry
  #                     survives. Creating the event array if canonical lacks it.
  # Robustness: (.hooks // {}) / (.hooks // []) so a project (or block) MISSING
  # the key degrades to empty instead of erroring (one malformed block must not
  # abort the whole fleet sync — the caller also captures a hard jq failure).
  # Note: jq `index($b)` returns 0 for a first-position match, and 0 is TRUTHY
  # in jq (only null/false are falsy) — so `index($b) | not` is correct; do not
  # special-case 0.
  jq -s '
    .[0] as $canon
    | .[1] as $proj
    | ([ $canon.hooks[][].hooks[].command | sub(" .*";"") | sub(".*/";"") ] | unique) as $canonical_cmds
    | $proj
    | .hooks = (
        ($canon.hooks // {}) as $base
        | reduce (($proj.hooks // {}) | to_entries[]) as $e (
            $base;
            .[$e.key] = (
              (.[$e.key] // [])
              + ( $e.value
                  | map( .hooks = ((.hooks // []) | map( select( (.command | sub(" .*";"") | sub(".*/";"")) as $b | $canonical_cmds | index($b) | not ) )) )
                  | map( select( (.hooks | length) > 0 ) )
                )
            )
          )
      )
  ' "$canonical_template" "$project_settings"
}
