#!/usr/bin/env bats
# Tests P1.5 jq-missing fail-closed across jq-dependent executable hooks
# derived from both hook trees.

load helpers
bats_require_minimum_version 1.5.0

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

# The hooks run in place from this checkout, as the rendered commands do; the
# Codex shared-lib fallback is bound to TRELLIS_ROOT (spec 055 R1.1).
HOOKS_RUNTIME="$(cd "$HOOKS_DIR/../.." && pwd -P)"
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

# Exercise deployed wrappers with an actual infrastructure fault. String and
# nested lookalikes must never suppress the first, fail-closed Stop block.
_r2_m3_assert_envelope() {
  local hook="$1" harness="$2" path="$3" envelope="$4" expect="$5"
  run --separate-stderr env PATH="$path" TRELLIS_NO_JQ_DEGRADE=0 /bin/bash "$hook" <<<"$envelope"
  if [ "$expect" = active ]; then
    [ "$status" -eq 0 ] && [ -z "$output" ] && [ -z "$stderr" ]
  elif [ "$harness" = claude ]; then
    [ "$status" -eq 2 ] && [[ "$stderr" == *"required"* || "$stderr" == *"missing"* ]]
  else
    [ "$status" -eq 0 ] && printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  fi
}

_r2_m3_wrapper_cases() {
  local harness="$1" kind="$2" source deploy jq_free file envelope
  if [ "$harness" = claude ]; then source="$HOOKS_DIR"; else source="$CODEX_HOOKS_DIR"; fi
  deploy="$BATS_TEST_TMPDIR/$harness-$kind/hooks"
  mkdir -p "$deploy/lib"
  cp "$source/$kind.sh" "$deploy/$kind.sh"
  cp "$source/lib/deps.sh" "$deploy/lib/deps.sh"
  if [ "$kind" = decision-receipt ]; then
    cp "$source/lib/autonomy.sh" "$deploy/lib/autonomy.sh"
    cp "$HOOKS_DIR/lib/decision-receipt-core.sh" "$deploy/lib/decision-receipt-core.sh"
  fi
  jq_free="$(make_jq_free_path)"
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" \
    '{"hook_event_name":"Stop","nested":{"stop_hook_active":false},"stop_hook_active":true}' active
  for envelope in \
    '{"stop_hook_active":false}' \
    '{"nested":{"stop_hook_active":true},"stop_hook_active":false}' \
    '{"last_assistant_message":"\\\"stop_hook_active\\\":true","stop_hook_active":false}' \
    '{"stop_hook_active":"true"}' \
    '{"stop_hook_active":true,"stop_hook_active":false}' \
    '{"stop_hook_active":true} garbage'; do
    _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" "$envelope" blocked
  done
  for file in deps.sh; do
    mv "$deploy/lib/$file" "$deploy/lib/$file.missing"
    _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$PATH" '{"stop_hook_active":true}' active
    _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$PATH" '{"stop_hook_active":false}' blocked
    mv "$deploy/lib/$file.missing" "$deploy/lib/$file"
  done
  if [ "$kind" = decision-receipt ]; then
    for file in autonomy.sh decision-receipt-core.sh; do
      mv "$deploy/lib/$file" "$deploy/lib/$file.missing"
      _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$PATH" '{"stop_hook_active":true}' active
      _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$PATH" '{"stop_hook_active":false}' blocked
      mv "$deploy/lib/$file.missing" "$deploy/lib/$file"
    done
  fi
}

@test "R2 M3: Claude Stop infrastructure faults do not loop on an active Stop" {
  _r2_m3_wrapper_cases claude stop-verify
}

@test "R2 M3: Codex Stop infrastructure faults do not loop on an active Stop" {
  _r2_m3_wrapper_cases codex stop-verify
}

@test "R2 M3: Claude decision infrastructure faults do not loop on an active Stop" {
  _r2_m3_wrapper_cases claude decision-receipt
}

@test "R2 M3: Codex decision infrastructure faults do not loop on an active Stop" {
  _r2_m3_wrapper_cases codex decision-receipt
}

# Relocate only the system-Perl executable in deployed fixture copies. This
# makes an absent executable or a PATH stub with a missing JSON::PP module
# reproducible even on macOS hosts where /usr/bin/perl cannot be removed.
_r3_l5_cases() {
  local harness="$1" kind="$2" source deploy jq_free real_python mode envelope
  if [ "$harness" = claude ]; then source="$HOOKS_DIR"; else source="$CODEX_HOOKS_DIR"; fi
  deploy="$BATS_TEST_TMPDIR/r3-$harness-$kind"
  mkdir -p "$deploy/lib"
  cp "$source/$kind.sh" "$deploy/$kind.sh"
  cp "$source/lib/deps.sh" "$deploy/lib/deps.sh"
  if [ "$kind" = decision-receipt ]; then
    cp "$source/lib/autonomy.sh" "$deploy/lib/autonomy.sh"
    cp "$HOOKS_DIR/lib/decision-receipt-core.sh" "$deploy/lib/decision-receipt-core.sh"
  fi
  jq_free="$(make_jq_free_path)"
  real_python="$(command -v python3)"
  ln -s "$real_python" "$jq_free/python3"
  python3 -I - "$deploy/$kind.sh" "$jq_free/perl" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
s = path.read_text()
assert s.count('/usr/bin/perl') == 2
path.write_text(s.replace('/usr/bin/perl', sys.argv[2]))
PY
  for mode in absent no-module; do
    if [ "$mode" = no-module ]; then
      printf '#!/bin/sh\nprintf called > "$PERL_MARKER"\nexit 2\n' > "$jq_free/perl"
      chmod +x "$jq_free/perl"
    fi
    export PERL_MARKER="$BATS_TEST_TMPDIR/$harness-$kind-perl-called"
    for envelope in \
      '{"session_id":"s","cwd":"/work","hook_event_name":"Stop","stop_hook_active":true}' \
      '{"stop_hook_active":true}'; do
      _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" "$envelope" active
    done
    if [ "$mode" = no-module ]; then [ -s "$PERL_MARKER" ]; fi
    for envelope in \
      '{"stop_hook_active":false}' \
      '{"nested":{"stop_hook_active":true},"stop_hook_active":false}' \
      '{"stop_hook_active":"true"}' \
      '{"stop_hook_active":true,"stop_hook_active":false}' \
      '{"stop_hook_active":true} garbage' \
      '{"stop_hook_active":true,"invalid":NaN}'; do
      _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" "$envelope" blocked
    done
  done
  # A hook may be launched from / while the project is elsewhere. Do not
  # mistake that unrelated process cwd for the configured project root.
  local saved_pwd="$PWD"
  export CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR" CODEX_PROJECT_DIR="$BATS_TEST_TMPDIR"
  cd /
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" '{"stop_hook_active":true,"session_id":"s"}' active
  # An actual project root of / cannot have an interpreter outside itself;
  # even a native always-successful binary on PATH cannot suppress a block.
  export CLAUDE_PROJECT_DIR=/ CODEX_PROJECT_DIR=/
  mv "$jq_free/python3" "$jq_free/python3-trusted"
  cp /usr/bin/true "$jq_free/python3"
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" '{"stop_hook_active":false}' blocked
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" '{"stop_hook_active":true}' active
  mv "$jq_free/python3" "$jq_free/python3-root-untrusted"
  mv "$jq_free/python3-trusted" "$jq_free/python3"
  cd "$saved_pwd"
  # A native executable supplied inside the project must not be trusted as
  # python merely because it exits zero. A real system interpreter may still
  # handle the envelope; the fake must never turn false into a continuation.
  mv "$jq_free/python3" "$jq_free/python3-real"
  cp /usr/bin/true "$jq_free/python3"
  export CLAUDE_PROJECT_DIR="$jq_free" CODEX_PROJECT_DIR="$jq_free"
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" '{"stop_hook_active":false}' blocked
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" '{"stop_hook_active":true,"session_id":"s"}' active
  # Simulate no trusted Python either: a present Perl lacking JSON::PP must
  # still reach the exact minimal fallback rather than re-block it.
  mv "$jq_free/python3" "$jq_free/python3-untrusted"
  python3 -I - "$deploy/$kind.sh" "$deploy/no-python" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]); source = path.read_text()
for candidate in ('/opt/homebrew/bin/python3', '/usr/local/bin/python3', '/usr/bin/python3'):
    source = source.replace(candidate, sys.argv[2])
path.write_text(source)
PY
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" '{"stop_hook_active":true}' active
  _r2_m3_assert_envelope "$deploy/$kind.sh" "$harness" "$jq_free" '{"stop_hook_active":false}' blocked
}

@test "R3 L5: Claude Stop falls back when Perl or JSON::PP is missing" {
  _r3_l5_cases claude stop-verify
}

@test "R3 L5: Codex Stop falls back when Perl or JSON::PP is missing" {
  _r3_l5_cases codex stop-verify
}

@test "R3 L5: Claude decision falls back when Perl or JSON::PP is missing" {
  _r3_l5_cases claude decision-receipt
}

@test "R3 L5: Codex decision falls back when Perl or JSON::PP is missing" {
  _r3_l5_cases codex decision-receipt
}

# Exercise the trust predicate from each deployed wrapper directly, so the
# fallback to a later good interpreter cannot mask acceptance of a bad one.
_r4_l1_extract() {
  local wrapper="$1"
  R4_HELPER="$BATS_TEST_TMPDIR/trust-helper.sh"
  awk '/^_stop_trusted_python\(\) \{/ {copy=1} copy {print} copy && /^\}/ {exit}' "$wrapper" > "$R4_HELPER"
  [ -s "$R4_HELPER" ]
}

_r4_l1_layout() {
  R4_CWD="$BATS_TEST_TMPDIR/cwd"
  R4_PROJECT="$BATS_TEST_TMPDIR/project"
  R4_BIN="$BATS_TEST_TMPDIR/outside-bin"
  mkdir -p "$R4_CWD" "$R4_PROJECT" "$R4_BIN"
  cp /usr/bin/true "$R4_BIN/native-python"
  chmod 755 "$R4_BIN/native-python"
}

@test "R4 L1: the working directory is protected when project variables are unset" {
  _r4_l1_layout
  cp /usr/bin/true "$R4_CWD/python3"
  chmod 755 "$R4_CWD/python3"
  local wrapper
  for wrapper in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh" \
    "$HOOKS_DIR/decision-receipt.sh" "$CODEX_HOOKS_DIR/decision-receipt.sh"; do
    _r4_l1_extract "$wrapper"
    run env -u CLAUDE_PROJECT_DIR -u CODEX_PROJECT_DIR /bin/bash -c '
      cd "$1"; . "$2"; _stop_trusted_python "$3"
    ' _ "$R4_CWD" "$R4_HELPER" "$R4_CWD/python3"
    [ "$status" -ne 0 ]
    run env -u CLAUDE_PROJECT_DIR -u CODEX_PROJECT_DIR /bin/bash -c '
      cd "$1"; . "$2"; _stop_trusted_python "$3"
    ' _ "$R4_CWD" "$R4_HELPER" "$R4_BIN/native-python"
    [ "$status" -eq 0 ]
  done
}

@test "R4 L1: an external executable script cannot masquerade as Python" {
  _r4_l1_layout
  printf '#!/bin/sh\nexit 0\n' > "$R4_BIN/python-shim"
  chmod 755 "$R4_BIN/python-shim"
  local wrapper
  for wrapper in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh" \
    "$HOOKS_DIR/decision-receipt.sh" "$CODEX_HOOKS_DIR/decision-receipt.sh"; do
    _r4_l1_extract "$wrapper"
    run env CLAUDE_PROJECT_DIR="$R4_PROJECT" CODEX_PROJECT_DIR="$R4_PROJECT" /bin/bash -c '
      cd "$1"; . "$2"; _stop_trusted_python "$3"
    ' _ "$R4_CWD" "$R4_HELPER" "$R4_BIN/python-shim"
    [ "$status" -ne 0 ]
    run env CLAUDE_PROJECT_DIR="$R4_PROJECT" CODEX_PROJECT_DIR="$R4_PROJECT" /bin/bash -c '
      cd "$1"; . "$2"; _stop_trusted_python "$3"
    ' _ "$R4_CWD" "$R4_HELPER" "$R4_BIN/native-python"
    [ "$status" -eq 0 ]
  done
}

@test "R4 L1: a group-writable native Python candidate is untrusted" {
  _r4_l1_layout
  chmod 775 "$R4_BIN/native-python"
  local wrapper
  for wrapper in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh" \
    "$HOOKS_DIR/decision-receipt.sh" "$CODEX_HOOKS_DIR/decision-receipt.sh"; do
    _r4_l1_extract "$wrapper"
    run env CLAUDE_PROJECT_DIR="$R4_PROJECT" CODEX_PROJECT_DIR="$R4_PROJECT" /bin/bash -c '
      cd "$1"; . "$2"; _stop_trusted_python "$3"
    ' _ "$R4_CWD" "$R4_HELPER" "$R4_BIN/native-python"
    [ "$status" -ne 0 ]
  done
  chmod 755 "$R4_BIN/native-python"
  run env CLAUDE_PROJECT_DIR="$R4_PROJECT" CODEX_PROJECT_DIR="$R4_PROJECT" /bin/bash -c '
    cd "$1"; . "$2"; _stop_trusted_python "$3"
  ' _ "$R4_CWD" "$R4_HELPER" "$R4_BIN/native-python"
  [ "$status" -eq 0 ]
}

@test "R4 L1: a native Python candidate owned by another user is untrusted" {
  _r4_l1_layout
  local wrapper stub="$BATS_TEST_TMPDIR/stat-owner" foreign=2147483647
  [ "$(id -u)" != "$foreign" ]
  printf '#!/bin/sh\nprintf "%%s 755\\n" "$R4_OWNER"\n' > "$stub"
  chmod 755 "$stub"
  for wrapper in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh" \
    "$HOOKS_DIR/decision-receipt.sh" "$CODEX_HOOKS_DIR/decision-receipt.sh"; do
    _r4_l1_extract "$wrapper"
    # Override stat only in the extracted test fixture; no privilege or actual
    # ownership changes are needed to reach the foreign-uid branch.
    python3 -I - "$R4_HELPER" "$stub" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]); source = path.read_text()
assert source.count('/usr/bin/stat') == 2
path.write_text(source.replace('/usr/bin/stat', sys.argv[2]))
PY
    run env R4_OWNER="$foreign" CLAUDE_PROJECT_DIR="$R4_PROJECT" CODEX_PROJECT_DIR="$R4_PROJECT" /bin/bash -c '
      cd "$1"; . "$2"; _stop_trusted_python "$3"
    ' _ "$R4_CWD" "$R4_HELPER" "$R4_BIN/native-python"
    [ "$status" -ne 0 ]
    run env R4_OWNER=0 CLAUDE_PROJECT_DIR="$R4_PROJECT" CODEX_PROJECT_DIR="$R4_PROJECT" /bin/bash -c '
      cd "$1"; . "$2"; _stop_trusted_python "$3"
    ' _ "$R4_CWD" "$R4_HELPER" "$R4_BIN/native-python"
    [ "$status" -eq 0 ]
  done
}

@test "143-stop stop verifier missing jq or dependencies blocks on each Stop transport" {
  local jq_free hook harness dir
  jq_free="$(make_jq_free_path)"
  for harness in claude codex; do
    if [ "$harness" = claude ]; then hook="$HOOKS_DIR/stop-verify.sh"; else hook="$CODEX_HOOKS_DIR/stop-verify.sh"; fi
    run --separate-stderr env PATH="$jq_free" TRELLIS_NO_JQ_DEGRADE=0 bash "$hook" <<<'{}'
    if [ "$harness" = claude ]; then
      [ "$status" -eq 2 ]
    else
      [ "$status" -eq 0 ]
      printf '%s\n' "$output" | jq -e '.decision == "block"' >/dev/null
    fi
    [[ "$stderr" == *"install jq"* ]]
    dir="$BATS_TEST_TMPDIR/$harness/hooks"
    mkdir -p "$dir"
    cp "$hook" "$dir/stop-verify.sh"
    run --separate-stderr bash "$dir/stop-verify.sh" <<<'{}'
    if [ "$harness" = claude ]; then
      [ "$status" -eq 2 ]
    else
      [ "$status" -eq 0 ]
      printf '%s\n' "$output" | jq -e '.decision == "block"' >/dev/null
    fi
    [[ "$stderr" == *"missing sibling lib"* ]]
    run --separate-stderr bash "$hook" <<<'{"stop_hook_active":true}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

# turn-baseline.sh without jq: exit 0 and the non-blocking prompt-context
# warning on stdout (spec 074 T30 apex residual ruling).
_turn_baseline_degraded_notice() {
  [ "$status" -eq 0 ] &&
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]] &&
    [[ "$output" == *'turn-baseline degraded: the next Stop may not detect this turn'* ]]
}

@test "P1.5: every hook reports missing jq or emits a Codex Stop block" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"
  failed=()
  for h in "${HOOKS[@]}"; do
    PATH="$jq_free_path" TRELLIS_ROOT="$HOOKS_RUNTIME" run_with_stderr "$h" '{}'
    if [ "${h##*/}" = turn-baseline.sh ]; then
      # Spec 074 T30 apex ruling: the prompt hook never blocks or fails a
      # prompt; with no usable state it warns the model in prompt context.
      if ! _turn_baseline_degraded_notice; then
        failed+=("$h:rc=$status")
      fi
    elif [ "$h" = "$CODEX_HOOKS_DIR/decision-receipt.sh" ] || [ "$h" = "$CODEX_HOOKS_DIR/stop-verify.sh" ]; then
      # Codex Stop blocks are JSON on stdout with exit 0, not exit 2.
      if [ "$status" -ne 0 ] || [[ "$output" != *'"decision":"block"'* ]] || ! [[ "$stderr" == *"install jq"* ]]; then
        failed+=("$h:rc=$status")
      fi
    elif [ "$status" -eq 0 ] || ! [[ "$stderr" == *"install jq"* ]]; then
      failed+=("$h:rc=$status")
    fi
  done

  # Unlike the shared hooks, this guard intentionally has no degrade hatch:
  # silently skipping it would allow slash expansion before skill-size policy.
  # Exit 2 is Claude's blocking code for UserPromptExpansion. Check both trees
  # with and without the degrade hatch.
  local slash_guard
  for slash_guard in "$HOOKS_DIR/skill-slash-guard.sh" "$CODEX_HOOKS_DIR/skill-slash-guard.sh"; do
    PATH="$jq_free_path" TRELLIS_NO_JQ_DEGRADE=1 run_with_stderr "$slash_guard" '{}'
    if [ "$status" -ne 2 ] || ! [[ "$stderr" == *"skill-slash-guard: jq required but not found; refusing"* ]]; then
      failed+=("$slash_guard:rc=$status")
    fi
    PATH="$jq_free_path" run_with_stderr "$slash_guard" '{}'
    if [ "$status" -ne 2 ] || ! [[ "$stderr" == *"skill-slash-guard: jq required but not found"* ]]; then
      failed+=("$slash_guard:nodegrade-env:rc=$status")
    fi
  done
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ ${#failed[@]} -eq 0 ] || { printf 'FAIL: %s\n' "${failed[@]}"; false; }
}

# The hatch is for advisory and Stop hooks only. A bright-line guard
# (`_se_require_jq ... block`) still refuses with it set (spec 074 E5).
@test "P1.5: every hook degrades cleanly when TRELLIS_NO_JQ_DEGRADE=1, except the bright-line guards" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"
  export TRELLIS_NO_JQ_DEGRADE=1
  failed=()
  guards=0
  for h in "${HOOKS[@]}"; do
    PATH="$jq_free_path" TRELLIS_ROOT="$HOOKS_RUNTIME" run_with_stderr "$h" '{}'
    if [ "${h##*/}" = turn-baseline.sh ]; then
      # T30: the prompt hook warns instead of degrading silently.
      if ! _turn_baseline_degraded_notice || [[ "$stderr" == *"degrading"* ]]; then
        failed+=("$h:rc=$status")
      fi
    elif [ "${h##*/}" = decision-receipt.sh ]; then
      # T27: mandatory decision policy is never a warning-only no-op, so the
      # hatch does not apply; it blocks on its harness's Stop transport.
      if [[ "$stderr" == *"degrading"* ]]; then
        failed+=("$h:degraded")
      elif [ "$h" = "$CODEX_HOOKS_DIR/decision-receipt.sh" ]; then
        if [ "$status" -ne 0 ] || [[ "$output" != *'"decision":"block"'* ]]; then
          failed+=("$h:rc=$status")
        fi
      elif [ "$status" -ne 2 ] || ! [[ "$stderr" == *"jq required but not found"* ]]; then
        failed+=("$h:rc=$status")
      fi
    elif grep -qE '^_se_require_jq "[a-z-]+" block$' "$h"; then
      guards=$((guards + 1))
      if [ "$status" -ne 2 ] || ! [[ "$stderr" == *"jq required but not found; refusing"* ]] ||
        [[ "$stderr" == *"degrading"* ]]; then
        failed+=("$h:rc=$status")
      fi
    elif [ "$status" -ne 0 ] || ! [[ "$stderr" == *"TRELLIS_NO_JQ_DEGRADE=1"* ]]; then
      failed+=("$h:rc=$status")
    fi
  done
  # block-destructive and reread-guard, in both trees.
  [ "$guards" -eq 4 ] || failed+=("bright-line guards found: $guards")
  unset TRELLIS_NO_JQ_DEGRADE
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ ${#failed[@]} -eq 0 ] || { printf 'FAIL: %s\n' "${failed[@]}"; false; }
}
