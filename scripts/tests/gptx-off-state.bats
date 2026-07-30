#!/usr/bin/env bats
# Spec 028 §4.3 — "works out of the box", as a deterministic property rather
# than a promise.
#
# The claim: with the GPTX switch off (the default), a Trellis install must not
# state doctrine a single-subscription operator cannot satisfy. That is
# checkable, so it is checked here instead of being asserted in a spec.
#
# Two properties:
#   1. No always-loaded doctrine surface names a `gpt-*` profile as a routing
#      target or states the cross-family mix quota.
#   2. Every file that DOES state either must carry an explicit `gptx.enabled`
#      predicate, so a reader hits the precondition before the requirement.
#
# Deliberately NOT covered: `core-rules/agents/gpt-*.md`. Those are profile
# definitions, not doctrine — they state no requirement, and a profile nothing
# routes to is unused rather than unsatisfiable. Spec 028 plan § Surface
# inventory records them as inert for exactly this reason.
#
# bash 3.2 / bats 1.x compatible.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

# A gpt-* profile named as a routing target, or the cross-family quota.
GPT_TARGET_RE='gpt-(mid|high|sol|terra)'
QUOTA_RE='0\.4 x pool|at least 40%|ceil\(0\.4'

# Files loaded in every session regardless of the switch.
ALWAYS_LOADED="core-rules/CLAUDE.md core-rules/references/model-routing.md"

@test "off-state: always-loaded doctrine names no gpt-* routing target" {
  for f in $ALWAYS_LOADED; do
    run grep -nE "$GPT_TARGET_RE" "$REPO/$f"
    [ "$status" -ne 0 ] || {
      echo "$f names a gpt-* profile but is loaded with the switch off:"; echo "$output"; false
    }
  done
}

@test "off-state: always-loaded doctrine states no cross-family quota" {
  for f in $ALWAYS_LOADED; do
    run grep -nE "$QUOTA_RE" "$REPO/$f"
    [ "$status" -ne 0 ] || {
      echo "$f states a mix quota a single-subscription operator cannot satisfy:"; echo "$output"; false
    }
  done
}

@test "off-state: every file naming a gpt-* routing target carries a gptx.enabled predicate" {
  bare=""
  while IFS= read -r f; do
    case "$f" in
      */core-rules/agents/gpt-*.md) continue ;;   # profile definitions: inert, see header
    esac
    grep -q 'gptx\.enabled' "$f" || bare="$bare $f"
  done < <(grep -rlE "$GPT_TARGET_RE" "$REPO/core-rules" 2>/dev/null | sort)
  [ -z "$bare" ] || { echo "unpredicated GPT-naming doctrine:$bare"; false; }
}

@test "off-state: every file stating the mix quota carries a gptx.enabled predicate" {
  bare=""
  while IFS= read -r f; do
    grep -q 'gptx\.enabled' "$f" || bare="$bare $f"
  done < <(grep -rlE "$QUOTA_RE" "$REPO/core-rules" 2>/dev/null | sort)
  [ -z "$bare" ] || { echo "unpredicated quota statement:$bare"; false; }
}

@test "off-state: the cross-family file opens with its precondition, not with doctrine" {
  f="$REPO/core-rules/references/model-routing-cross-family.md"
  [ -f "$f" ]
  # The predicate must appear before any gpt-* routing target in the file.
  pred=$(grep -nE 'gptx\.enabled' "$f" | head -1 | cut -d: -f1)
  first=$(grep -nE "$GPT_TARGET_RE" "$f" | head -1 | cut -d: -f1)
  [ -n "$pred" ]
  [ -n "$first" ]
  [ "$pred" -lt "$first" ]
}

@test "off-state: the single-family review rule survives the switch being off" {
  # Never-self-review must not vanish with the cross-family reviewer; it changes
  # shape into a fresh-context subagent. Grep proves it is present.
  run grep -qi 'fresh-context subagent' "$REPO/core-rules/references/model-routing.md"
  [ "$status" -eq 0 ]
}

@test "off-state: the xhigh ceiling survives the switch being off" {
  run grep -q 'xhigh` is the ceiling' "$REPO/core-rules/references/model-routing.md"
  [ "$status" -eq 0 ]
}

@test "off-state: model-routing.md points at the cross-family file conditionally" {
  # A reader with the switch off must be told the file exists AND that it does
  # not apply to them — an unconditional pointer is what spec 028 exists to fix.
  run grep -q 'gptx\.enabled' "$REPO/core-rules/references/model-routing.md"
  [ "$status" -eq 0 ]
}

@test "off-state: core-rules/CLAUDE.md stays within its size budget" {
  n=$(wc -c < "$REPO/core-rules/CLAUDE.md" | tr -d ' ')
  l=$(wc -l < "$REPO/core-rules/CLAUDE.md" | tr -d ' ')
  [ "$n" -le 19000 ] || { echo "CLAUDE.md is $n bytes, over the 19,000 target"; false; }
  [ "$l" -le 200 ]   || { echo "CLAUDE.md is $l lines, over the 200 target"; false; }
}

@test "off-state: no core-rules doctrine selects max effort" {
  # xhigh is the ceiling; `max` must not appear as a selected effort anywhere in
  # inherited doctrine. Prose that names max in order to forbid it is fine.
  run grep -rnE '(effort|reasoning)[":= ]+["'\'']?max\b' "$REPO/core-rules" --include='*.md'
  [ "$status" -ne 0 ] || { echo "doctrine selects max effort:"; echo "$output"; false; }
}
