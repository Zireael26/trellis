#!/usr/bin/env bats
# Shared CRLF/BOM fixtures are available for native differential tests.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/skill-frontmatter.XXXXXX")"; SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"; PROJECT="$SANDBOX/project"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$PROJECT"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  export HOME TRELLIS_HOME
}
teardown() { [ -z "${SANDBOX:-}" ] || { chmod -R u+rwX "$SANDBOX"; rm -rf "${SANDBOX:?}"; }; }

@test "CRLF and BOM declared names select and block an oversized project skill in all copies" {
  local fixture lib hook root="$PROJECT/.claude/skills/short-dir"
  mkdir -p "$root" "$HOME/.claude/skills/release-check"
  printf '%s\n' '---' 'name: release-check' '---' > "$HOME/.claude/skills/release-check/SKILL.md"
  for fixture in crlf bom; do
    cp "$REPO_ROOT/scripts/tests/fixtures/skill-frontmatter/$fixture.md" "$root/SKILL.md"
    head -c 70000 /dev/zero | tr '\000' x >> "$root/SKILL.md"
    for lib in scripts/lib/skill-size.sh core-rules/hooks/lib/skill-size.sh core-rules/codex/hooks/lib/skill-size.sh; do
      . "$REPO_ROOT/$lib"
      . "$REPO_ROOT/core-rules/hooks/lib/skill-preload.sh"
      run skill_size_resolve_root release-check "$PROJECT" "$HOME"
      [ "$status" -eq 0 ] && [ "$output" = "$root" ] || { echo "$fixture $lib: $output"; false; }
      run skill_preload_check release-check "$PROJECT" "$HOME"
      [ "$status" -eq 1 ] || { echo "$fixture $lib: $output"; false; }
      [[ "$output" == *"exceeds 65536-byte inline budget"* ]] || { echo "$output"; false; }
    done
    for hook in core-rules/hooks/skill-slash-guard.sh core-rules/codex/hooks/skill-slash-guard.sh; do
      run env HOME="$HOME" CLAUDE_PROJECT_DIR="$PROJECT" bash -c \
        'printf "%s" '\''{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"release-check"}'\'' | bash "$1"' \
        _ "$REPO_ROOT/$hook"
      [ "$status" -eq 0 ] || { echo "$fixture $hook: $output"; false; }
      printf '%s\n' "$output" | jq -e '.decision == "block" and (.reason | contains("65536-byte inline budget"))' >/dev/null || { echo "$fixture $hook: $output"; false; }
    done
  done
}

@test "frontmatter identity reads only a 4096-byte prefix plus one boundary byte" {
  local root="$PROJECT/.claude/skills/huge" lib seconds used trace="$SANDBOX/awk-trace" stub="$SANDBOX/bin"
  mkdir -p "$root" "$stub" "$HOME/.claude/skills/hidden"
  head -c 4194304 /dev/zero | tr '\000' x > "$root/SKILL.md"
  printf 'small\n' > "$HOME/.claude/skills/hidden/SKILL.md"
  export SKILL_TEST_REAL_AWK="$(command -v awk)" SKILL_TEST_AWK_TRACE="$trace" SKILL_TEST_SCRATCH="$SANDBOX"
  cat > "$stub/awk" <<'SH'
#!/bin/bash
case "$1" in
  *'NR == 1'*)
    for arg in "$@"; do
      case "$arg" in */SKILL.md) printf 'unbounded-file\n' >> "$SKILL_TEST_AWK_TRACE"; exec "$SKILL_TEST_REAL_AWK" "$@" ;; esac
    done
    input="$SKILL_TEST_SCRATCH/awk-input-$$"
    /bin/cat > "$input"
    /usr/bin/wc -c < "$input" >> "$SKILL_TEST_AWK_TRACE"
    "$SKILL_TEST_REAL_AWK" "$@" < "$input"
    rc=$?
    /bin/rm -f "${input:?}"
    exit "$rc"
    ;;
esac
exec "$SKILL_TEST_REAL_AWK" "$@"
SH
  chmod 700 "$stub/awk"
  PATH="$stub:$PATH"
  for lib in scripts/lib/skill-size.sh core-rules/hooks/lib/skill-size.sh core-rules/codex/hooks/lib/skill-size.sh; do
    . "$REPO_ROOT/$lib"
    : > "$trace"
    SECONDS=0
    run skill_size__declared_name "$root"
    seconds="$SECONDS"
    [ "$status" -ne 0 ] || { echo "$lib: unexpected name $output"; false; }
    [ "$seconds" -lt 10 ] || { echo "$lib: bounded read exceeded 10 seconds"; false; }
    [ "$(tr -d '[:space:]' < "$trace")" = 4097 ] || { echo "$lib read: $(<"$trace")"; false; }
    run skill_size_resolve_root huge "$PROJECT" "$HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$root" ] || { echo "$lib: $output"; false; }

    # An early name is not authoritative if its frontmatter never closes in
    # the prefix; the ordinary user skill wins, while basename lookup remains.
    printf '%s\n' '---' 'name: hidden' > "$root/SKILL.md"
    head -c 5000 /dev/zero | tr '\000' x >> "$root/SKILL.md"
    printf '\n---\n' >> "$root/SKILL.md"
    run skill_size_resolve_root hidden "$PROJECT" "$HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$HOME/.claude/skills/hidden" ] || { echo "$lib: $output"; false; }
    # A fence-looking prefix ending at byte 4096 is not a fence if the next
    # byte continues its line. The lookahead byte must prevent that alias.
    printf '%s\n' '---' 'name: hidden' > "$root/SKILL.md"
    used="$(wc -c < "$root/SKILL.md" | tr -d '[:space:]')"
    head -c "$((4096 - used - 4))" /dev/zero | tr '\000' x >> "$root/SKILL.md"
    printf '\n---X\n' >> "$root/SKILL.md"
    run skill_size_resolve_root hidden "$PROJECT" "$HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$HOME/.claude/skills/hidden" ] || { echo "$lib boundary: $output"; false; }
    # The third dash is byte 4097 and a fourth dash follows it. Truncation
    # must not turn that non-fence into a complete closing fence.
    printf '%s\n' '---' 'name: hidden' > "$root/SKILL.md"
    used="$(wc -c < "$root/SKILL.md" | tr -d '[:space:]')"
    head -c "$((4097 - used - 4))" /dev/zero | tr '\000' x >> "$root/SKILL.md"
    printf '\n----\n' >> "$root/SKILL.md"
    run skill_size_resolve_root hidden "$PROJECT" "$HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$HOME/.claude/skills/hidden" ] || { echo "$lib byte-4097 boundary: $output"; false; }
    # A complete short frontmatter ending exactly at EOF is still valid.
    printf '%s' $'---\nname: hidden\n---' > "$root/SKILL.md"
    run skill_size_resolve_root hidden "$PROJECT" "$HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$root" ] || { echo "$lib EOF: $output"; false; }
    head -c 4194304 /dev/zero | tr '\000' x > "$root/SKILL.md"
  done
}

@test "basename-only skills remain valid and an unreadable candidate denies only its own name" {
  local lib
  mkdir -p "$PROJECT/.claude/skills/unreadable" "$HOME/.claude/skills/plain" "$HOME/.claude/skills/unrelated"
  printf 'unreadable\n' > "$PROJECT/.claude/skills/unreadable/SKILL.md"
  chmod 000 "$PROJECT/.claude/skills/unreadable/SKILL.md"
  printf 'basename-only body\n' > "$HOME/.claude/skills/plain/SKILL.md"
  printf 'unrelated body\n' > "$HOME/.claude/skills/unrelated/SKILL.md"
  for lib in scripts/lib/skill-size.sh core-rules/hooks/lib/skill-size.sh core-rules/codex/hooks/lib/skill-size.sh; do
    . "$REPO_ROOT/$lib"
    . "$REPO_ROOT/core-rules/hooks/lib/skill-preload.sh"
    run skill_preload_check plain "$PROJECT" "$HOME"
    [ "$status" -eq 0 ] || { echo "$lib: $output"; false; }
    run skill_preload_check unreadable "$PROJECT" "$HOME"
    [ "$status" -eq 2 ] || { echo "$lib: $output"; false; }
    run skill_preload_check unrelated "$PROJECT" "$HOME"
    [ "$status" -eq 0 ] || { echo "$lib: $output"; false; }
  done
}
