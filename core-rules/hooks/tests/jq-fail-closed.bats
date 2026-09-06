#!/usr/bin/env bats
# Tests P1.5 jq-missing fail-closed across jq-dependent executable hooks
# derived from both hook trees.

load helpers

discover_jq_required_hooks() {
  local dirs=()
  if [ "$#" -gt 0 ]; then
    dirs=("$@")
  else
    dirs=("$HOOKS_DIR" "$CODEX_HOOKS_DIR")
  fi
  local jq_call_basenames
  jq_call_basenames="$(mktemp)"
  local d lib
  for d in "${dirs[@]}"; do
    if [ ! -d "$d/lib" ]; then
      continue
    fi
    while IFS= read -r -d '' lib; do
      if grep -q '_se_require_jq "' "$lib"; then
        basename "$lib" >> "$jq_call_basenames"
      fi
    done < <(find "$d/lib" -maxdepth 1 -name "*.sh" -print0)
  done
  local uniq_basenames
  uniq_basenames="$(sort -u "$jq_call_basenames")"
  rm -f "$jq_call_basenames"
  local hook
  for d in "${dirs[@]}"; do
    if [ ! -d "$d" ]; then
      continue
    fi
    while IFS= read -r -d '' hook; do
      if [ ! -x "$hook" ]; then
        continue
      fi
      if grep -q '_se_require_jq "' "$hook"; then
        printf '%s\n' "$hook"
        continue
      fi
      local base
      while IFS= read -r base; do
        if [ -z "$base" ]; then
          continue
        fi
        if grep -qF "$base" "$hook"; then
          printf '%s\n' "$hook"
          break
        fi
      done <<< "$uniq_basenames"
    done < <(find "$d" -maxdepth 1 -name "*.sh" -type f -print0)
  done | sort -u
}

HOOKS=()
while IFS= read -r _hook; do
  HOOKS+=("$_hook")
done < <(discover_jq_required_hooks)

@test "P1.5: derivation helper discovers direct and wrapper jq-required hooks without stale inventory" {
  mini_hooks="$BATS_TEST_TMPDIR/mini-hooks"
  mini_codex="$BATS_TEST_TMPDIR/mini-codex"
  mkdir -p "$mini_hooks/lib" "$mini_codex/lib"
  cat > "$mini_hooks/lib/my-core.sh" <<'EOS'
#!/usr/bin/env bash
_se_require_jq "my-core"
EOS
  cat > "$mini_hooks/a.sh" <<'EOS'
#!/usr/bin/env bash
_se_require_jq "a"
EOS
  chmod +x "$mini_hooks/a.sh"
  cat > "$mini_hooks/wrapper.sh" <<'EOS'
#!/usr/bin/env bash
DIR="$(dirname "$0")"
# shellcheck source=/dev/null
. "$DIR/lib/my-core.sh"
EOS
  chmod +x "$mini_hooks/wrapper.sh"
  cat > "$mini_hooks/b.sh" <<'EOS'
#!/usr/bin/env bash
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'b: jq not found; degrading to no-op' >&2; exit 0; }
EOS
  chmod +x "$mini_hooks/b.sh"
  cat > "$mini_hooks/c.sh" <<'EOS'
#!/usr/bin/env bash
_se_require_jq "c"
EOS
  # c.sh intentionally not executable — must be excluded
  cat > "$mini_codex/e.sh" <<'EOS'
#!/usr/bin/env bash
_se_require_jq "e"
EOS
  chmod +x "$mini_codex/e.sh"

  expected1="$mini_hooks/a.sh"
  expected2="$mini_hooks/wrapper.sh"
  expected3="$mini_codex/e.sh"
  expected_sorted="$(printf '%s\n%s\n%s\n' "$expected1" "$expected2" "$expected3" | sort)"
  actual="$(discover_jq_required_hooks "$mini_hooks" "$mini_codex")"

  if [ "$actual" != "$expected_sorted" ]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$expected_sorted" "$actual" >&2
    false
  fi

  case "$actual" in
    *"b.sh"*)
      printf 'advisory b.sh should not be discovered\n' >&2
      false
      ;;
  esac
  case "$actual" in
    *"c.sh"*)
      printf 'non-executable c.sh should not be discovered\n' >&2
      false
      ;;
  esac
}

@test "P1.5: every hook fails closed (rc!=0 + install help) when jq missing" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"
  failed=()
  for h in "${HOOKS[@]}"; do
    PATH="$jq_free_path" run_with_stderr "$h" '{}'
    if [ "$status" -eq 0 ] || ! [[ "$stderr" == *"install jq"* ]]; then
      failed+=("$h:rc=$status")
    fi
  done

  # Unlike the shared hooks, this guard intentionally has no degrade hatch:
  # silently skipping it would allow slash expansion before skill-size policy.
  local slash_guard="$CODEX_HOOKS_DIR/skill-slash-guard.sh"
  PATH="$jq_free_path" run_with_stderr "$slash_guard" '{}'
  if [ "$status" -ne 1 ] || ! [[ "$stderr" == *"skill-slash-guard: jq required but not found"* ]]; then
    failed+=("$slash_guard:rc=$status")
  fi
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ ${#failed[@]} -eq 0 ] || { printf 'FAIL: %s\n' "${failed[@]}"; false; }
}

@test "P1.5: every hook degrades cleanly when TRELLIS_NO_JQ_DEGRADE=1" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"
  export TRELLIS_NO_JQ_DEGRADE=1
  failed=()
  for h in "${HOOKS[@]}"; do
    PATH="$jq_free_path" run_with_stderr "$h" '{}'
    if [ "$status" -ne 0 ] || ! [[ "$stderr" == *"TRELLIS_NO_JQ_DEGRADE=1"* ]]; then
      failed+=("$h:rc=$status")
    fi
  done
  unset TRELLIS_NO_JQ_DEGRADE
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ ${#failed[@]} -eq 0 ] || { printf 'FAIL: %s\n' "${failed[@]}"; false; }
}
