#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

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

@test "canonical settings wire every shipped Claude hook script" {
  local script base
  while IFS= read -r script; do
    base="${script##*/}"
    jq -e --arg base "$base" \
      '[.hooks[][]?.hooks[]?.command | select(endswith("/" + $base))] | length == 1' \
      "$ROOT/core-rules/templates/claude-settings.json" >/dev/null || {
        echo "missing or duplicate canonical hook wiring: $base"
        return 1
      }
  done < <(find "$ROOT/core-rules/hooks" -maxdepth 1 -type f -name '*.sh' | sort)
}
