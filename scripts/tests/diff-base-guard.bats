#!/usr/bin/env bats
# diff-base-guard.bats — spec 067 T7: no gate path or gate doc derives a diff
# base outside the shared resolver (process-gate/scripts/lib/diff-base.sh).
# Every hit of GUARD_RE under GUARD_PATHS (tests excluded) must sit on the
# allowlist, pinned by file and exact line. An entry that no longer matches a
# line fails too, so the PR that wires a pending site (P1c-1, P1c-2, P1d-2)
# drops its entry in the same change.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
GUARD_RE='(origin/)?(main|master)\.\.HEAD|merge-base [^#]*origin/'
GUARD_PATHS=(
  core-rules/skills/process-gate
  core-rules/skills/security-gate
  core-rules/skills/aeo-gate
  core-rules/skills/herdr-foreman
  core-rules/skills/wiki-skill-propose
  core-rules/hooks
  core-rules/codex/hooks
  core-rules/githooks
  core-rules/husky
  core-rules/hooks.md
)

# <path>|<why it may stay>|<hit line, indentation trimmed>
GUARD_ALLOWLIST='core-rules/skills/security-gate/scripts/run-diff.sh|fallback when the process-gate skill is absent (spec 6.1.1)|RANGE="origin/main..HEAD"
core-rules/skills/security-gate/scripts/run-diff.sh|fallback when the process-gate skill is absent (spec 6.1.1)|RANGE="main..HEAD"
core-rules/skills/security-gate/scripts/run-diff.sh|fallback when the process-gate skill is absent (spec 6.1.1)|RANGE="master..HEAD"
core-rules/hooks/lib/spec-gate-core.sh|1.3.10 legacy marker binding only, never a verdict (spec 067 6.1.7)|base=$(git -C "$dir" merge-base "$head" "origin/$b" 2>/dev/null) && { printf '"'"'%s'"'"' "$base"; return; }
core-rules/skills/process-gate/scripts/lib/common.sh|coordinator ruling D1 (1.3.12-a): superset fallback when the resolver refuses and no flag was given|DB_RANGE="main..HEAD"
core-rules/skills/process-gate/scripts/lib/common.sh|coordinator ruling D1 (1.3.12-a): superset fallback when the resolver refuses and no flag was given|DB_RANGE="master..HEAD"
core-rules/githooks/pre-push|pending P1c-2|AEO_GATE_RANGE="${RANGE:-origin/main..HEAD}" bash -p "$AEOGATE" || true
core-rules/husky/pre-push|pending P1c-2|AEO_GATE_RANGE="${RANGE:-origin/main..HEAD}" bash -p "$AEOGATE" || true'

# guard_hits <root>: "<path>|<hit line, indentation trimmed>" for every hit.
guard_hits() {
  local root="$1" p f
  for p in "${GUARD_PATHS[@]}"; do
    [ -e "$root/$p" ] || continue
    find "$root/$p" -type f ! -path '*/tests/*' ! -name diff-base.sh
  done | LC_ALL=C sort -u | while IFS= read -r f; do
    grep -E "$GUARD_RE" "$f" |
      awk -v p="${f#"$root"/}" '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print p "|" $0 }'
  done
}

# guard_verdict <hits-file>: report unallowlisted hits and stale entries.
guard_verdict() {
  local hits="$1" allowed="$BATS_TEST_TMPDIR/allowed" out rc=0
  printf '%s\n' "$GUARD_ALLOWLIST" | sed 's/^\([^|]*\)|[^|]*|/\1|/' > "$allowed"
  if out="$(grep -vxFf "$allowed" "$hits")"; then
    printf '%s\n' "$out" | sed 's/^/hardcoded diff base: /'
    rc=1
  fi
  if out="$(grep -vxFf "$hits" "$allowed")"; then
    printf '%s\n' "$out" | sed 's/^/stale allowlist entry: /'
    rc=1
  fi
  return "$rc"
}

@test "no gate path or gate doc hardcodes a diff base outside the resolver" {
  guard_hits "$REPO_ROOT" > "$BATS_TEST_TMPDIR/hits"
  run guard_verdict "$BATS_TEST_TMPDIR/hits"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "planted defaults in a gate script, a gate doc and a merge-base are each caught" {
  # Inversion: a scanner that finds nothing, or skips docs, misses a named line.
  local root="$BATS_TEST_TMPDIR/plant"
  mkdir -p "$root/core-rules/skills/process-gate/scripts" "$root/core-rules/hooks/lib" \
    "$root/core-rules/hooks/tests"
  printf 'RANGE="${RANGE:-main..HEAD}"\n' > "$root/core-rules/skills/process-gate/scripts/check-new.sh"
  printf 'Run with `--range=origin/main..HEAD`.\n' > "$root/core-rules/skills/process-gate/SKILL.md"
  printf '  base=$(git merge-base HEAD origin/main)\n' > "$root/core-rules/hooks/lib/new.sh"
  printf 'RANGE=main..HEAD\n' > "$root/core-rules/hooks/tests/fixture.sh"
  guard_hits "$root" > "$BATS_TEST_TMPDIR/hits"
  run guard_verdict "$BATS_TEST_TMPDIR/hits"
  [ "$status" -eq 1 ]
  [[ "$output" == *'hardcoded diff base: core-rules/skills/process-gate/scripts/check-new.sh|RANGE="${RANGE:-main..HEAD}"'* ]] || { echo "$output"; false; }
  [[ "$output" == *'hardcoded diff base: core-rules/skills/process-gate/SKILL.md|Run with `--range=origin/main..HEAD`.'* ]] || { echo "$output"; false; }
  [[ "$output" == *'hardcoded diff base: core-rules/hooks/lib/new.sh|base=$(git merge-base HEAD origin/main)'* ]] || { echo "$output"; false; }
  [[ "$output" != *'tests/fixture.sh'* ]] || { echo "$output"; false; }
}
