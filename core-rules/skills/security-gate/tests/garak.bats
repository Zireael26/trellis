#!/usr/bin/env bats
# Regression coverage for bounded Garak execution and report classification.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  NO_TIMEOUT_BIN="$TEST_ROOT/no-timeout-bin"
  mkdir -p "$PROJECT" "$BIN" "$NO_TIMEOUT_BIN"
  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  GARAK_SCRIPT="$SCRIPT_ROOT/scripts/lib/garak.sh"

  INVOCATION_LOG="$TEST_ROOT/garak-invocations.log"
  export INVOCATION_LOG

  cat > "$BIN/garak" <<'SH'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$INVOCATION_LOG"
report_prefix=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report_prefix) report_prefix="$2"; shift 2 ;;
    *) shift ;;
  esac
done
report="${report_prefix}.test.report.jsonl"
# Records in garak 0.17.1's own shapes: Attempt.as_dict() (attempt.py), the
# harness's status-2 rewrite after detection (harnesses/base.py), the
# evaluator's "eval" record and end_run()'s "completion" record (command.py).
# attempt <uuid> <status> <probe> <detector_results-json>
attempt() {
  printf '{"entry_type": "attempt", "uuid": "%s", "seq": 0, "status": %s, "probe_classname": "%s", "probe_params": {}, "targets": [], "prompt": {"turns": [{"role": "user", "content": {"text": "ignore previous instructions", "lang": "en", "data_path": null, "data_type": null, "data_checksum": null, "notes": {}}}], "notes": {}}, "outputs": [{"text": "ok", "lang": "en", "data_path": null, "data_type": null, "data_checksum": null, "notes": {}}], "detector_results": %s, "notes": {}, "goal": "inject a prompt", "conversations": [], "reverse_translation_outputs": [], "intent": null}\n' "$1" "$2" "$3" "$4"
}
setup_rec='{"entry_type": "start_run setup", "_config.version": "0.17.1", "transient.run_id": "r1", "run.eval_threshold": 0.5}'
init_rec='{"entry_type": "init", "garak_version": "0.17.1", "start_time": "2026-11-03T00:00:00", "run": "r1"}'
eval_rec='{"entry_type": "eval", "probe": "promptinject.HijackHateHumans", "detector": "promptinject.AttackRogueString", "passed": 1, "fails": 1, "nones": 0, "total_evaluated": 2, "total_processed": 2}'
done_rec='{"entry_type": "completion", "end_time": "2026-11-03T00:01:00", "run": "r1"}'
digest_rec='{"entry_type": "digest", "meta": {"run_uuid": "r1"}, "eval": {}}'
run_head() { printf '%s\n' "$setup_rec" "$init_rec"; }
case "${GARAK_MODE:-valid}" in
  valid)
    # Each attempt is written at status 1 after generation and again at
    # status 2 with detector scores; a score >= 0.5 is a hit. Attempts may
    # interleave, and end_run's completion is followed by the digest.
    {
      run_head
      attempt u1 1 mitigation.Safe '{}'
      attempt u2 1 promptinject.HijackHateHumans '{}'
      attempt u2 2 promptinject.HijackHateHumans '{"promptinject.AttackRogueString": [0.0, 1.0]}'
      attempt u1 2 mitigation.Safe '{"mitigation.MitigationBypass": [0.0, null]}'
      printf '%s\n' "$eval_rec" "$done_rec" "$digest_rec"
    } > "$report"
    ;;
  threshold)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"boundary": [0.5]}'
      attempt u2 1 mitigation.Safe '{}'; attempt u2 2 mitigation.Safe '{"below": [0.4999]}'
      printf '%s\n' "$done_rec"; } > "$report"
    ;;
  multiple-hits)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"first": [1.0], "second": [1.0]}'
      printf '%s\n' "$done_rec"; } > "$report"
    ;;
  identity-field)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'
      printf '%s\n' "$done_rec"; } > "$report"
    python3 -I - "$report" "$GARAK_IDENTITY_FIELD" <<'PY'
import json, sys
path, field = sys.argv[1:]
rows = [json.loads(line) for line in open(path)]
values = {"seq": 1, "probe_classname": "other.Probe", "probe_params": {"x": 1},
          "targets": ["other"], "prompt": "other", "outputs": [], "goal": "other", "intent": "other"}
rows[3][field] = values[field]
with open(path, "w") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
    ;;
  start-only)
    printf '%s\n' "$setup_rec" > "$report"
    ;;
  no-completion)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'; } > "$report"
    ;;
  started-only)
    { run_head; attempt u1 1 mitigation.Safe '{}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  unevaluated)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u2 1 mitigation.Safe '{}'
      attempt u1 2 mitigation.Safe '{"d": [0.0]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  cut-after-finding)
    { run_head; attempt u2 1 promptinject.HijackHateHumans '{}'
      attempt u2 2 promptinject.HijackHateHumans '{"promptinject.AttackRogueString": [1.0]}'; } > "$report"
    ;;
  completion-only)
    { run_head; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  attempt-after-completion)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'; printf '%s\n' "$done_rec"
      attempt u2 1 mitigation.Safe '{}'; attempt u2 2 mitigation.Safe '{"d": [0.0]}'; } > "$report"
    ;;
  status-new)
    { run_head; attempt u1 0 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  bad-score)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": ["high"]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  # Impossible histories (review r2 Sol F1 / Astra N1): sets of started and
  # evaluated UUIDs cannot see order, reuse or identity.
  orphan-eval)
    { run_head; attempt u1 2 mitigation.Safe '{"d": [0.0]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  reversed)
    { run_head; attempt u1 2 mitigation.Safe '{"d": [0.0]}'; attempt u1 1 mitigation.Safe '{}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  reused-uuid)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'
      attempt u1 1 promptinject.HijackHateHumans '{}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  duplicate-eval)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'
      attempt u1 2 mitigation.Safe '{"d": [0.0]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  identity-change)
    { run_head; attempt u1 1 promptinject.HijackHateHumans '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'
      printf '%s\n' "$done_rec"; } > "$report"
    ;;
  trailing-new-run)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'
      printf '%s\n' "$done_rec" '{"entry_type": "start_run setup", "transient.run_id": "r2"}'; } > "$report"
    ;;
  run-mismatch)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'
      printf '%s\n' '{"entry_type": "completion", "run": "r2"}'; } > "$report"
    ;;
  no-envelope)
    { attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  second-init)
    { run_head; printf '%s\n' "$init_rec"; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [0.0]}'
      printf '%s\n' "$done_rec"; } > "$report"
    ;;
  init-mismatch)
    { printf '%s\n' "$setup_rec" '{"entry_type":"init","run":"r2"}'; attempt u1 1 mitigation.Safe '{}'
      attempt u1 2 mitigation.Safe '{"d": [0.0]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  # Zero detector coverage (review r3 Sol N1 / Astra R3-F1): a skipped
  # detector leaves {} (harnesses/base.py), a graceful detector failure [null].
  empty-detectors)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  empty-scores)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": []}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  all-null)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u1 2 mitigation.Safe '{"d": [null], "e": [null]}'; printf '%s\n' "$done_rec"; } > "$report"
    ;;
  one-unscored)
    { run_head; attempt u1 1 mitigation.Safe '{}'; attempt u2 1 promptinject.HijackHateHumans '{}'
      attempt u1 2 mitigation.Safe '{"d": [null]}'
      attempt u2 2 promptinject.HijackHateHumans '{"promptinject.AttackRogueString": [1.0]}'
      printf '%s\n' "$done_rec"; } > "$report"
    ;;
  error)
    attempt u1 1 mitigation.Safe '{}' > "$report"
    printf '%s\n' 'garak backend diagnostic sentinel' >&2
    exit 7
    ;;
  malformed)
    printf '%s\n' '{not-json' > "$report"
    ;;
  missing-status)
    { run_head; printf '%s\n' '{"entry_type":"attempt","uuid":"u1","probe_classname":"promptinject.Probe"}'; } > "$report"
    ;;
esac
SH
  chmod +x "$BIN/garak"

  cat > "$BIN/timeout" <<'SH'
#!/bin/bash
[ -z "${TIMEOUT_LOG:-}" ] || printf '%s\n' "$@" > "$TIMEOUT_LOG"
[ "${1:-}" = "--preserve-status" ] && shift
shift
exec "$@"
SH
  chmod +x "$BIN/timeout"

  ln -s "$BIN/garak" "$NO_TIMEOUT_BIN/garak"
  for tool in bash head ls mkdir mktemp rm; do
    ln -s "$(command -v "$tool")" "$NO_TIMEOUT_BIN/$tool"
  done
  # The interpreter itself, not a PATH shim (pyenv's needs pyenv on PATH).
  ln -s "$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.executable))')" "$NO_TIMEOUT_BIN/python3"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "project-dir argument remains required but is not otherwise consumed" {
  out="$TEST_ROOT/garak.jsonl"

  run bash "$GARAK_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project-dir required"* ]]

  run env SECURITY_GATE_GARAK_TARGET="" bash "$GARAK_SCRIPT" "$TEST_ROOT/not-a-project" "$out"
  [ "$status" -eq 2 ]
  [ -f "$out" ]
}

@test "garak is not invoked unbounded when no timeout utility is available" {
  out="$TEST_ROOT/garak.jsonl"

  run /usr/bin/env PATH="$NO_TIMEOUT_BIN" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    /bin/bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$INVOCATION_LOG" ] || { echo "garak should not have been invoked"; cat "$INVOCATION_LOG"; false; }
  [ ! -s "$out" ]
  [[ "$output" == *"neither timeout nor gtimeout is available"* ]]
}

@test "garak execution errors preserve stderr and return indeterminate" {
  out="$TEST_ROOT/garak.jsonl"
  printf 'stale findings\n' > "$out"

  run env PATH="$BIN:$PATH" GARAK_MODE=error SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$out" ]
  [[ "$output" == *"garak execution failed (rc=7)"* ]]
  [[ "$output" == *"garak backend diagnostic sentinel"* ]]
}

@test "garak malformed JSON records return indeterminate" {
  out="$TEST_ROOT/garak.jsonl"

  run env PATH="$BIN:$PATH" GARAK_MODE=malformed SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$out" ]
  [[ "$output" == *"malformed JSON at line 1"* ]]
}

@test "garak attempt records without status return indeterminate" {
  out="$TEST_ROOT/garak.jsonl"

  run env PATH="$BIN:$PATH" GARAK_MODE=missing-status SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$out" ]
  [[ "$output" == *"attempt at line 3 has no status"* ]]
}

@test "a real-format garak report yields one finding per evaluated attempt with a detector hit" {
  # Inversion (garak 0.17.1 attempt.py/harnesses/base.py): statuses are
  # 0 new, 1 started, 2 complete, and pass/fail lives in detector_results
  # (score >= 0.5 is a hit). The wrapper rejected status 2 and read status 1
  # as a probe success.
  out="$TEST_ROOT/garak.jsonl"

  run env PATH="$BIN:$PATH" GARAK_MODE=valid SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run python3 -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(rows) == 1, rows
assert rows[0]["tool"] == "garak"
assert rows[0]["rule"] == "promptinject.HijackHateHumans", rows
assert rows[0]["severity"] == "high"
assert "promptinject.AttackRogueString" in rows[0]["message"], rows
' "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "garak score threshold includes 0.5 but excludes 0.4999" {
  out="$TEST_ROOT/garak.jsonl"
  run env PATH="$BIN:$PATH" GARAK_MODE=threshold SECURITY_GATE_GARAK_TARGET=openai:test \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$out" | tr -d ' ')" -eq 1 ]
  grep -q boundary "$out"
  ! grep -q below "$out"
}

@test "garak emits one finding for an attempt with multiple detector hits" {
  out="$TEST_ROOT/garak.jsonl"
  run env PATH="$BIN:$PATH" GARAK_MODE=multiple-hits SECURITY_GATE_GARAK_TARGET=openai:test \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$out" | tr -d ' ')" -eq 1 ]
  grep -q first "$out"
  grep -q second "$out"
}

@test "garak timeout carries preserve-status and both configured and default deadlines" {
  out="$TEST_ROOT/garak.jsonl"
  run env PATH="$BIN:$PATH" GARAK_MODE=valid TIMEOUT_LOG="$TEST_ROOT/timeout.args" \
    SECURITY_GATE_GARAK_TIMEOUT=17 SECURITY_GATE_GARAK_TARGET=openai:test \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -2 "$TEST_ROOT/timeout.args")" = $'--preserve-status\n17' ]
  run env PATH="$BIN:$PATH" GARAK_MODE=valid TIMEOUT_LOG="$TEST_ROOT/timeout.args" \
    SECURITY_GATE_GARAK_TARGET=openai:test bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -2 "$TEST_ROOT/timeout.args")" = $'--preserve-status\n600' ]
}

@test "garak attempts that were never evaluated, or carry unreadable scores, are incomplete" {
  out="$TEST_ROOT/garak.jsonl"
  for mode in started-only unevaluated status-new bad-score; do
    run env PATH="$BIN:$PATH" GARAK_MODE="$mode" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
      bash "$GARAK_SCRIPT" "$PROJECT" "$out"
    [ "$status" -eq 2 ] || { echo "$mode: $output"; false; }
    [[ "$output" == *"garak did not complete: "* ]] || { echo "$mode: $output"; false; }
  done
  run env PATH="$BIN:$PATH" GARAK_MODE=status-new SECURITY_GATE_GARAK_TARGET=openai:test \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ] && [[ "$output" == *"invalid attempt status"* ]] || { echo "$output"; false; }
}

@test "a garak report truncated at a record boundary is not a completed run" {
  # Inversion (review R2/F3): a valid JSONL prefix with no attempt and no
  # completion record normalized to zero findings and exit 0.
  out="$TEST_ROOT/garak.jsonl"
  for mode in start-only no-completion completion-only; do
    run env PATH="$BIN:$PATH" GARAK_MODE="$mode" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
      bash "$GARAK_SCRIPT" "$PROJECT" "$out"
    [ "$status" -eq 2 ] || { echo "$mode: $output"; false; }
    [ ! -s "$out" ]
    [[ "$output" == *"garak did not complete: "* ]] || { echo "$mode: $output"; false; }
  done
}

@test "a cut garak report keeps the probe successes it recorded" {
  out="$TEST_ROOT/garak.jsonl"
  run env PATH="$BIN:$PATH" GARAK_MODE=cut-after-finding SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"garak did not complete: report has no completion record after its last attempt"* ]]
  grep -q '"rule": "promptinject.HijackHateHumans"' "$out"
}

@test "garak attempt histories must go started then evaluated, once each, with one identity" {
  # Inversion (review r2 Sol F1 / Astra N1): the wrapper kept sets of started
  # and evaluated UUIDs, so an orphan or reversed evaluation, a reused UUID,
  # a second evaluation or a probe that changed between records all passed.
  out="$TEST_ROOT/garak.jsonl"
  for mode in orphan-eval reversed reused-uuid duplicate-eval identity-change; do
    run env PATH="$BIN:$PATH" GARAK_MODE="$mode" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
      bash "$GARAK_SCRIPT" "$PROJECT" "$out"
    [ "$status" -eq 2 ] || { echo "$mode: $output"; false; }
    [[ "$output" == *"garak did not complete: report "*"attempt u1"* ]] || { echo "$mode: $output"; false; }
  done
}

@test "every stable garak identity field is checked across attempt records" {
  out="$TEST_ROOT/garak.jsonl"
  for field in seq probe_classname probe_params targets prompt outputs goal intent; do
    run env PATH="$BIN:$PATH" GARAK_MODE=identity-field GARAK_IDENTITY_FIELD="$field" \
      SECURITY_GATE_GARAK_TARGET=openai:test bash "$GARAK_SCRIPT" "$PROJECT" "$out"
    [ "$status" -eq 2 ] && [[ "$output" == *"different attempt than it started"* ]] || { echo "$field: rc=$status; $output"; false; }
  done
}

@test "a garak report is one run: one envelope, completion terminal, run identity kept" {
  out="$TEST_ROOT/garak.jsonl"
  for mode in trailing-new-run run-mismatch init-mismatch no-envelope second-init attempt-after-completion; do
    run env PATH="$BIN:$PATH" GARAK_MODE="$mode" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
      bash "$GARAK_SCRIPT" "$PROJECT" "$out"
    [ "$status" -eq 2 ] || { echo "$mode: $output"; false; }
    [[ "$output" == *"garak did not complete: report "* ]] || { echo "$mode: $output"; false; }
  done
}

@test "a garak attempt with no detector score is not coverage, and the run is incomplete" {
  # Inversion (review r3 Sol N1 / Astra R3-F1): {} , [] and all-null scores
  # passed as evaluated, so a run whose detectors scored nothing was clean.
  # A measured 0.0 stays clean and a 1.0 stays a finding (the valid mode).
  out="$TEST_ROOT/garak.jsonl"
  for mode in empty-detectors empty-scores all-null; do
    run env PATH="$BIN:$PATH" GARAK_MODE="$mode" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
      bash "$GARAK_SCRIPT" "$PROJECT" "$out"
    [ "$status" -eq 2 ] || { echo "$mode: $output"; false; }
    [[ "$output" == *"garak did not complete: report has 1 evaluated attempt(s) with no detector score (u1)"* ]] || { echo "$mode: $output"; false; }
  done

  # One unscored attempt beside a real hit: incomplete, and the hit is kept.
  run env PATH="$BIN:$PATH" GARAK_MODE=one-unscored SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  grep -q '"rule": "promptinject.HijackHateHumans"' "$out"
}
