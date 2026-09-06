#!/usr/bin/env bats
# Source-only observations; run in a private copied source under the OS fence.
# Never invoke doctor, providers, native CLIs, or live fleet operations.
setup() {
  SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  LIBRARY="$SOURCE/scripts/lib/health-checks.sh"
  # shellcheck disable=SC1090
  . "$LIBRARY"
}

_observe() {
  bash -c '. "$1"; hc_harness_capability_observation "$2" "$3" "$4" "$5"' \
    bash "$LIBRARY" "$@"
}

_claims() {
  local installation="$1"; shift
  local expected="" harness
  for harness in "$@"; do
    expected="${expected}${expected:+$'\n'}harness-capability: $harness installation=$installation; native-loaded=unknown; native-exercised=unknown"
    if [ "$harness" = pi ]; then
      expected="$expected"$'\n''harness-capability: pi hard Stop=unsupported; settled/post-action=advisory; portable post-compaction recovery=unsupported'
    fi
  done
  [ "$status" -eq "$HC_INFO" ] || return 1
  [ "$output" = "$expected" ] || return 1
  [[ "$output" != *enforced* ]]
}

_wiring() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
call = '  run_check \'  \' hc_harness_capability_observation "$harnesses" "$release_ok" "$owner_state" "$surfaces_ok" || true\n'
assert text.count(call) == 1, 'observation invocation missing or duplicated'
assert '\n  fi\n' + call + '  # The owner/native checks' in text, 'observation must be unconditional after native checks'
assert text.index('run_check \'  \' hc_portable_native_surfaces') < text.index(call) < text.index('  row_diagnostics_ok=false')
PY
}

@test "each selected single harness reports verified installation but unknown native outcomes" {
  local harness
  for harness in claude codex pi; do
    run _observe "[\"$harness\"]" true attached true
    _claims verified "$harness"
  done
}

@test "mixed selections are bounded to selected harnesses including fixed Pi limitations" {
  run _observe '["claude","codex","pi"]' true attached true
  _claims verified claude codex pi
  run _observe '["pi","claude"]' true attached true
  _claims verified pi claude
}

@test "each failed prerequisite leaves installation unverified without changing native unknown" {
  run _observe '["claude","codex","pi"]' false attached true
  _claims unverified claude codex pi
  local owner
  for owner in missing runtime-missing conflict; do
    run _observe '["claude","codex","pi"]' true "$owner" true
    _claims unverified claude codex pi
  done
  run _observe '["claude","codex","pi"]' true attached false
  _claims unverified claude codex pi
}

@test "doctor actually wires observation after structural verification" {
  _wiring "$SOURCE/scripts/doctor.sh"
}

@test "removing actual doctor invocation fails wiring assertion not syntax or setup" {
  local mutant="$BATS_TEST_TMPDIR/doctor-without-observation.sh"
  python3 - "$SOURCE/scripts/doctor.sh" "$mutant" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
lines = text.splitlines(keepends=True)
removed = [line for line in lines if "run_check '  ' hc_harness_capability_observation " in line]
assert len(removed) == 1
Path(sys.argv[2]).write_text(text.replace(removed[0], ''))
PY
  bash -n "$mutant"
  run _wiring "$mutant"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AssertionError: observation invocation missing or duplicated"* ]]
}

@test "false native and installation claims fail business assertions with helper still INFO" {
  local original="$LIBRARY" mutation
  for mutation in native installation pi; do
    LIBRARY="$BATS_TEST_TMPDIR/$mutation.sh"
    python3 - "$original" "$LIBRARY" "$mutation" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old, new = {
    'native': ('native-loaded=unknown; native-exercised=unknown', 'native-loaded=enforced; native-exercised=enforced'),
    'installation': ('local installation=unverified harness', 'local installation=verified harness'),
    'pi': ('pi hard Stop=unsupported;', 'pi hard Stop=enforced;'),
}[sys.argv[3]]
assert text.count(old) == 1
Path(sys.argv[2]).write_text(text.replace(old, new))
PY
    bash -n "$LIBRARY"
    run _observe '["claude","codex","pi"]' false attached true
    [ "$status" -eq "$HC_INFO" ]
    [[ "$output" == *"harness-capability: claude installation="* ]]
    if _claims unverified claude codex pi; then
      printf 'business assertion accepted %s mutation\n' "$mutation" >&2
      return 1
    fi
  done
}
