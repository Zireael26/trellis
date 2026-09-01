#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

# This is a closed exception list: adding a hook here requires a corresponding
# exact local-template registration assertion below.
is_local_template_only_hook() {
  case "$1" in
    wiki-skill-suggest.sh) return 0 ;;
    *) return 1 ;;
  esac
}

@test "canonical hook README lists every shipped Claude hook script" {
  local script base
  while IFS= read -r script; do
    base="${script##*/}"
    grep -qF -- "\`$base\`" "$ROOT/core-rules/hooks/README.md" || {
      echo "missing from canonical hook inventory: $base"
      return 1
    }
  done < <(find "$ROOT/core-rules/hooks" -maxdepth 1 -type f -name '*.sh' | sort)
}

@test "legacy Claude settings wire every hook not declared local-template-only" {
  local script base
  while IFS= read -r script; do
    base="${script##*/}"
    # Herdr role resolution is a user-global SessionStart hook. It is shipped
    # beside project hooks for release packaging, but must not be duplicated in
    # each attached project's canonical settings.
    [ "$base" = "herdr-foreman-session.sh" ] && continue
    is_local_template_only_hook "$base" && continue
    jq -e --arg base "$base" \
      '[.hooks[][]?.hooks[]?.command | select(endswith("/" + $base))] | length == 1' \
      "$ROOT/core-rules/templates/claude-settings.json" >/dev/null || {
        echo "missing or duplicate canonical hook wiring: $base"
        return 1
      }
  done < <(find "$ROOT/core-rules/hooks" -maxdepth 1 -type f -name '*.sh' | sort)
}

@test "explicit local-template-only hooks are wired once locally and absent from legacy manifests" {
  local template legacy hook_path base
  while IFS='|' read -r template legacy hook_path; do
    base="${hook_path##*/}"
    jq -e --arg suffix "/$hook_path\"" '
      [.hooks[][]?.hooks[]?.command | select(endswith($suffix))] | length == 1
    ' "$ROOT/$template" >/dev/null || {
      echo "missing or duplicate local-template hook wiring: $template -> $hook_path"
      return 1
    }
    jq -e --arg base "$base" '
      [.hooks[][]?.hooks[]?.command | select(contains("/" + $base))] | length == 0
    ' "$ROOT/$legacy" >/dev/null || {
      echo "local-template-only hook leaked into legacy manifest: $legacy -> $base"
      return 1
    }
  done <<'EOF'
core-rules/templates/claude-settings.local.json|core-rules/templates/claude-settings.json|core-rules/hooks/wiki-skill-suggest.sh
core-rules/templates/codex-hooks.local.json|core-rules/codex/hooks.json|core-rules/codex/hooks/wiki-skill-suggest.sh
EOF
}

# Every script at the top of a hook directory is EXECUTED by path — both harness
# templates put the bare path in a `command`, with no `bash` prefix — so a hook
# without the executable bit returns 126 in every attached project and the
# harness reports a hook failure, not a gate result. `core-rules/hooks/spec-gate.sh`
# and its Codex twin shipped 100644 from 2026-07-07 until the T34 gate: the
# mandatory-pipeline Stop hook was dead on arrival everywhere it was installed,
# and nothing in the tree noticed. Sourced libraries live one level down under
# `lib/` and are correctly non-executable; this only looks at maxdepth 1.
#
# Where the fix lives, since the commit subjects point elsewhere: the two
# 100644→100755 mode changes are carried by 72f3350 ("unchain the BSD/GNU stat
# probes in six suites"), which shows them as mode-only entries. The commit
# whose subject claims the fix, e6f0bd2 ("make spec-gate executable in both
# harness trees"), adds only the two cases below. Bisect order is safe — 72f3350
# precedes e6f0bd2 — but `git log -- core-rules/hooks/spec-gate.sh` will send a
# reader to the wrong diff without this note.
@test "every shipped hook script is executable in both harness trees" {
  local dir script offenders=""
  for dir in "$ROOT/core-rules/hooks" "$ROOT/core-rules/codex/hooks"; do
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      [ -x "$script" ] || offenders="$offenders ${script#"$ROOT/"}"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' | sort)
  done
  [ -z "$offenders" ] || { echo "hook scripts missing the executable bit:$offenders"; false; }
}

# The working-tree mode is not what ships — `git archive`, a clone and the
# release payload all carry the INDEX mode. A `chmod +x` that was never staged
# looks fixed locally and is still broken for every consumer.
@test "the index agrees that every shipped hook script is mode 100755" {
  local offenders
  # A git pathspec `*` crosses `/`, so the lib/ subdirectory has to be filtered
  # out explicitly — those are sourced, not executed, and are correctly 100644.
  offenders="$(git -C "$ROOT" ls-files -s -- 'core-rules/hooks/*.sh' 'core-rules/codex/hooks/*.sh' |
    awk '$4 !~ /\/lib\// && $1 != "100755" { print $4 }' | tr '\n' ' ')"
  [ -z "$offenders" ] || { echo "hook scripts not 100755 in the index: $offenders"; false; }
}
