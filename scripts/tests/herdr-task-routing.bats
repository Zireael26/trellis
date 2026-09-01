#!/usr/bin/env bats
# Fixture-driven coverage for resolve-roles.py's finite task classifier.
# Every classifier decision uses a checked-in usage response; legacy resolver
# modes use the same response through a temporary omp shim.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RESOLVER="$REPO_ROOT/core-rules/skills/herdr-foreman/scripts/resolve-roles.py"
FIXTURES="$REPO_ROOT/scripts/tests/fixtures/herdr-task-routing"
PYTHON="$(command -v python3)"
ORIGINAL_PATH="$PATH"

setup() {
  AVAILABLE="$FIXTURES/available.json"
  EXHAUSTED="$FIXTURES/exhausted.json"
  DISABLED="$FIXTURES/disabled.json"
  NO_REPORT="$FIXTURES/no-report.json"
  LEGACY_HOME="$BATS_TEST_TMPDIR/home"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$LEGACY_HOME/.omp/agent" "$FAKE_BIN"
  cat > "$FAKE_BIN/omp" <<EOF
#!/bin/sh
if [ "\$1" = usage ] && [ "\$2" = --json ]; then
  cat "$AVAILABLE"
  exit 0
fi
printf 'unexpected omp invocation: %s %s\\n' "\$1" "\$2" >&2
exit 1
EOF
  chmod 755 "$FAKE_BIN/omp"
}

classify_with() {
  local fixture="$1"
  local shape="$2"
  shift 2
  "$PYTHON" "$RESOLVER" --classify "$shape" --usage-file "$fixture" --json "$@"
}

legacy_with_fake_usage() {
  env HOME="$LEGACY_HOME" PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    "$PYTHON" "$RESOLVER" "$@"
}

assert_status() {
  local expected="$1"
  if [ "$status" -ne "$expected" ]; then
    printf 'expected exit %s, got %s\nstdout:\n%s\nstderr:\n%s\n' \
      "$expected" "$status" "$output" "${stderr-}" >&2
    return 1
  fi
}

assert_json() {
  if ! printf '%s' "$output" | jq -e . >/dev/null 2>&1; then
    printf 'expected JSON output:\n%s\nstderr:\n%s\n' "$output" "${stderr-}" >&2
    return 1
  fi
}

assert_field() {
  local expression="$1"
  local expected="$2"
  local actual
  if ! actual="$(printf '%s' "$output" | jq -r "$expression")"; then
    printf 'could not read JSON field %s from:\n%s\nstderr:\n%s\n' \
      "$expression" "$output" "${stderr-}" >&2
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    printf 'field %s: expected %s, got %s\nJSON:\n%s\nstderr:\n%s\n' \
      "$expression" "$expected" "$actual" "$output" "${stderr-}" >&2
    return 1
  fi
}

assert_output_contains() {
  local needle="$1"
  if [[ "$output" != *"$needle"* ]]; then
    printf 'expected output to contain %s:\n%s\nstderr:\n%s\n' \
      "$needle" "$output" "${stderr-}" >&2
    return 1
  fi
}

@test "every task shape selects its required capability and reasoning effort" {
  local shape expected_agent expected_effort
  for row in \
    "scan flash high" \
    "mechanical-coding luna max" \
    "bounded-review cheap xhigh" \
    "deep-work glm-flash-go max" \
    "hard-work luna max" \
    "security-review security-reviewer xhigh" \
    "merge-review sol xhigh"; do
    read -r shape expected_agent expected_effort <<<"$row"
    run --separate-stderr classify_with "$AVAILABLE" "$shape"
    assert_status 0
    assert_json
    assert_field '.task_shape' "$shape"
    assert_field '.chosen_agent' "$expected_agent"
    assert_field '.reasoning_effort' "$expected_effort"
    assert_field '.dispatchable' true
  done
}

@test "identical classifier inputs produce identical route receipts" {
  run --separate-stderr classify_with "$AVAILABLE" scan
  assert_status 0
  assert_json
  local first="$output"

  run --separate-stderr classify_with "$AVAILABLE" scan
  assert_status 0
  assert_json
  if [ "$output" != "$first" ]; then
    printf 'repeated classifier output differed\nfirst:\n%s\nsecond:\n%s\n' "$first" "$output" >&2
    false
  fi
}

@test "Sol is reserved for hard work and is not a bounded-review route" {
  run --separate-stderr classify_with "$EXHAUSTED" hard-work
  assert_status 0
  assert_json
  assert_field '.chosen_agent' sol
  assert_field '.reasoning_effort' xhigh
  assert_field '.fallback_used' true
  if ! printf '%s' "$output" | jq -e 'any(.trail[]; startswith("luna:exhausted:"))' >/dev/null; then
    printf 'hard-work did not exhaust Luna before selecting Sol:\n%s\n' "$output" >&2
    false
  fi

  run --separate-stderr classify_with "$AVAILABLE" bounded-review --operator-agent sol
  assert_status 3
  assert_json
  assert_field '.chosen_agent' sol
  assert_field '.dispatchable' false
  assert_field '.trail[0]' 'sol:capability-mismatch'
}

@test "an exact named cheap agent succeeds when its quota is available" {
  run --separate-stderr classify_with "$AVAILABLE" bounded-review --operator-agent cheap
  assert_status 0
  assert_json
  assert_field '.requested_agent' cheap
  assert_field '.chosen_agent' cheap
  assert_field '.provider' opencode
  assert_field '.model' 'opencode/muse-spark-1.2-contributor-free:xhigh'
  assert_field '.reasoning_effort' xhigh
  assert_field '.family' meta
  assert_field '.fallback_used' false
  assert_field '.dispatchable' true
}

@test "an exact named cheap agent refuses when its provider is disabled" {
  run --separate-stderr classify_with "$DISABLED" bounded-review --operator-agent cheap
  assert_status 3
  assert_json
  assert_field '.requested_agent' cheap
  assert_field '.chosen_agent' cheap
  assert_field '.dispatchable' false
  assert_field '.trail[0]' 'cheap:disabled:0.0'
}

@test "exact named glm-flash-go route honors prepaid catalog metadata" {
  # `glm-flash` (nous-portal) was retired from the roster; `glm-flash-go` is the
  # surviving prepaid route and carries the same property under test — a declared
  # prepaid agent dispatches on catalog metadata alone, with no usage report.
  run --separate-stderr classify_with "$NO_REPORT" security-review \
    --operator-agent glm-flash-go
  assert_status 0
  assert_json
  assert_field '.requested_agent' glm-flash-go
  assert_field '.chosen_agent' glm-flash-go
  assert_field '.provider' opencode-go-2
  assert_field '.model' 'opencode-go-2/glm-5.3-flash:max'
  assert_field '.reasoning_effort' max
  assert_field '.trail[0]' 'glm-flash-go:prepaid:-'
  assert_field '.fallback_used' false
  assert_field '.dispatchable' true
}

@test "metered no-report routes refuse before declared unmetered fallback" {
  run --separate-stderr classify_with "$NO_REPORT" scan
  assert_status 0
  assert_json
  assert_field '.chosen_agent' cheap
  assert_field '.provider' opencode
  assert_field '.fallback_used' true
  if ! printf '%s' "$output" | jq -e '
    .trail == ["flash:no-report:-", "cheap:prepaid:-"]
  ' >/dev/null; then
    printf 'metered no-report route was not refused before unmetered fallback:\n%s\n' \
      "$output" >&2
    false
  fi
}

@test "unknown shape and operator requests exit 2 without guessing" {
  run --separate-stderr classify_with "$AVAILABLE" unknown-shape
  assert_status 2
  if [[ "$stderr" != *"unknown task shape"* ]]; then
    printf 'unknown shape error was not explicit:\n%s\n' "$stderr" >&2
    false
  fi

  run --separate-stderr classify_with "$AVAILABLE" scan \
    --operator-agent unknown-agent
  assert_status 2
  if [[ "$stderr" != *"unknown operator agent"* ]]; then
    printf 'unknown operator error was not explicit:\n%s\n' "$stderr" >&2
    false
  fi
}

@test "automatic verdict routes accept a declared prepaid route without a report" {
  run --separate-stderr classify_with "$NO_REPORT" security-review
  assert_status 0
  assert_json
  assert_field '.chosen_agent' glm-flash-go
  assert_field '.provider' opencode-go-2
  assert_field '.model' 'opencode-go-2/glm-5.3-flash:max'
  assert_field '.fallback_used' true
  if ! printf '%s' "$output" | jq -e '
    .trail == [
      "security-reviewer:no-report:-",
      "sol:no-report:-",
      "glm-flash-go:prepaid:-"
    ]
  ' >/dev/null; then
    printf 'prepaid no-report route was not selected after metered routes:\n%s\n' \
      "$output" >&2
    false
  fi
}

@test "pre-dispatch receipt leaves runtime match null until actual model is observed" {
  run --separate-stderr classify_with "$AVAILABLE" scan
  assert_status 0
  assert_json
  assert_field '.actual_model' null
  assert_field '.runtime_match' null
  assert_field '.dispatchable' true
}

@test "an observed DeepSeek substitution returns runtime mismatch exit 4" {
  run --separate-stderr classify_with "$AVAILABLE" mechanical-coding \
    --actual-model opencode-go/deepseek-v4-flash:max
  assert_status 4
  assert_json
  assert_field '.chosen_agent' luna
  assert_field '.reasoning_effort' max
  assert_field '.actual_model' 'opencode-go/deepseek-v4-flash:max'
  assert_field '.runtime_match' false
  assert_field '.dispatchable' true
}

@test "verdict selection excludes the producer model family" {
  run --separate-stderr classify_with "$AVAILABLE" bounded-review --producer-agent cheap
  assert_status 0
  assert_json
  assert_field '.producer_family' meta
  assert_field '.chosen_agent' flash
  assert_field '.fallback_used' true
  if ! printf '%s' "$output" | jq -e 'any(.trail[]; . == "cheap:same-family")' >/dev/null; then
    printf 'producer-family exclusion was absent from trail:\n%s\n' "$output" >&2
    false
  fi
  run --separate-stderr classify_with "$AVAILABLE" security-review --producer-agent grok
  assert_status 0
  assert_json
  assert_field '.producer_family' xai
  assert_field '.chosen_agent' sol
  assert_field '.fallback_used' true
  if ! printf '%s' "$output" | jq -e 'any(.trail[]; . == "security-reviewer:same-family")' >/dev/null; then
    printf 'security verdict did not exclude the xai producer family:\n%s\n' "$output" >&2
    false
  fi

  run --separate-stderr classify_with "$AVAILABLE" merge-review --producer-agent sol
  assert_status 0
  assert_json
  assert_field '.producer_family' openai
  assert_field '.chosen_agent' grok
  assert_field '.fallback_used' true
  if ! printf '%s' "$output" | jq -e 'any(.trail[]; . == "sol:same-family")' >/dev/null; then
    printf 'merge verdict did not exclude the openai producer family:\n%s\n' "$output" >&2
    false
  fi
}

@test "an exact operator request with the wrong capability is rejected" {
  run --separate-stderr classify_with "$AVAILABLE" deep-work --operator-agent flash
  assert_status 3
  assert_json
  assert_field '.requested_agent' flash
  assert_field '.chosen_agent' flash
  assert_field '.dispatchable' false
  assert_field '.trail[0]' 'flash:capability-mismatch'
}

@test "automatic compatible-chain exhaustion fails closed" {
  run --separate-stderr classify_with "$EXHAUSTED" bounded-review
  assert_status 3
  assert_json
  assert_field '.chosen_agent' null
  assert_field '.dispatchable' false
  if ! printf '%s' "$output" | jq -e '
    (.trail | length == 2)
    and any(.trail[]; startswith("cheap:exhausted:"))
    and any(.trail[]; startswith("flash:reported:0.1"))
  ' >/dev/null; then
    printf 'compatible-chain exhaustion receipt was incomplete:\n%s\n' "$output" >&2
    false
  fi
}

@test "classification receipt contains route, quota, and runtime fields" {
  run --separate-stderr classify_with "$AVAILABLE" scan --actual-model google-antigravity/gemini-3.7-flash:high
  assert_status 0
  assert_json
  if ! printf '%s' "$output" | jq -e '
    . as $receipt
    | ["task_shape", "role", "requested_agent", "chosen_agent", "provider",
       "model", "reasoning_effort", "family", "producer_family", "usage_source",
       "trail", "fallback_used", "actual_model", "runtime_match", "dispatchable"]
    | map(. as $key | select($receipt | has($key)))
    | length == 15
  ' >/dev/null; then
    printf 'receipt fields were incomplete:\n%s\n' "$output" >&2
    false
  fi
  assert_field '.usage_source' fixture
  assert_field '.model' 'google-antigravity/gemini-3.7-flash:high'
  assert_field '.reasoning_effort' high
  assert_field '.actual_model' 'google-antigravity/gemini-3.7-flash:high'
  assert_field '.runtime_match' true
}

@test "legacy json mode resolves through deterministic usage without a scoped artifact" {
  run --separate-stderr legacy_with_fake_usage --json
  assert_status 0
  assert_json
  assert_field '.usage_source' openusage:live
  assert_field '.roles.implementer.chosen.agent' luna
  [ ! -e "$LEGACY_HOME/.omp/agent/roles-resolved.json" ]
}

@test "a limitReached provider is refused even at zero threshold" {
  local usage="$BATS_TEST_TMPDIR/limit-reached.json"
  printf '%s\n' \
    '{"reports":[{"provider":"opencode","limits":[],"metadata":{"limitReached":true}}]}' \
    >"$usage"
  run --separate-stderr classify_with "$usage" bounded-review
  assert_status 3
  assert_json
  assert_field '.chosen_agent' null
  assert_field '.trail[0]' 'cheap:limitReached:0.0'
}

@test "an unmetered route retains an executable fall-through candidate" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import importlib.util, json, sys

resolver_path, roles_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))
hydrated = rr.hydrate_catalog(cfg)
chain = hydrated["roles"]["reviewer"]["chain"]
first = chain[0]
assert first["agent"] == "cheap"
# "carries no usage report" is now declared per-agent as metered:prepaid;
# rr.UNMETERED is the older provider-level spelling. Accept either, so the
# assertion tests the property rather than one encoding of it. A metered
# agent at position 0 still fails.
assert first.get("metered") == "prepaid" or first["provider"] in rr.UNMETERED
assert any(candidate["agent"] != first["agent"] for candidate in chain[1:])
print(",".join(candidate["agent"] for candidate in chain))
PY
  assert_status 0
  assert_output_contains 'cheap,flash'
}

@test "real noninteractive auth probes refuse matching routes without truncating fallback" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import importlib.util, json, sys

resolver_path, roles_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))

scout = cfg["roles"]["scout"]
configured_probe = next(
    candidate["auth_probe"]
    for candidate in scout["chain"]
    if candidate["agent"] == "flash"
)
refuter_probe = next(
    candidate["auth_probe"]
    for candidate in cfg["roles"]["refuter"]["chain"]
    if candidate["agent"] == "flash"
)
assert configured_probe == ["omp", "token", "google-antigravity"]
assert refuter_probe == configured_probe

good_probe = [
    sys.executable,
    "-c",
    "import os,sys; assert not os.isatty(0); "
    "print('credential-value'); print('diagnostic', file=sys.stderr)",
]
for role in cfg["roles"].values():
    for candidate in role["chain"]:
        if "auth_probe" in candidate:
            candidate["auth_probe"] = good_probe
assert rr.auth_probe_passes(
    {"auth_probe": [sys.executable, "-c", "pass"]}, {}
) is False

cfg["agents"]["unauthenticated-google"] = {
    "provider": "google",
    "model": "google/gemini-3.7-flash:high",
    "effort": "high",
    "family": "google",
    "capabilities": ["scan"],
}
bad = {
    "agent": "unauthenticated-google",
    "min_remaining": 0.0,
    "auth_probe": [sys.executable, "-c", "raise SystemExit(19)"],
}
scout["chain"].insert(0, bad)
late = next(candidate for candidate in scout["chain"] if candidate["agent"] == "cheap")
late["auth_probe"] = [
    sys.executable,
    "-c",
    "print('not-a-credential'); raise SystemExit(23)",
]
usage = {
    "reports": [
        {"provider": "google", "limits": [
            {"amount": {"remainingFraction": 1.0}}
        ]},
        {"provider": "google-antigravity", "limits": [
            {"amount": {"remainingFraction": 1.0}}
        ]},
        {"provider": "opencode-go", "limits": [
            {"amount": {"remainingFraction": 1.0}}
        ]},
    ]
}
roles, _ = rr.resolve(cfg, usage, today="2026-08-22")
resolved = roles["scout"]
assert resolved["chosen"]["agent"] == "flash"
assert rr.misrouted({
    "provider": "google-antigravity",
    "model": "google/gemini-3.7-flash:high",
})
assert [candidate["agent"] for candidate in resolved["trail"]] == [
    "flash",
    "cheap",
]
assert all(
    candidate["eligible"] and candidate["reason"] == "eligible"
    for candidate in resolved["trail"]
)
assert [
    (candidate["agent"], candidate["reason"])
    for candidate in resolved["refusals"]
] == [
    ("unauthenticated-google", "auth-probe-failed"),
    ("cheap", "auth-probe-failed"),
]
assert resolved["refusals"][0]["note"] == "reported"
assert resolved["refusals"][1]["note"] == "prepaid"
print(resolved["chosen"]["agent"])
PY
  assert_status 0
  assert_output_contains 'flash'
}

@test "ad-hoc panels count mapped families and refuse collapsed or unmapped seats" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import importlib.util, json, sys

resolver_path, roles_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))

count, findings = rr.panel_families(cfg, ["cheap", "luna", "sol"])
assert count == 2
assert findings and "one prior" in findings[0]

count, findings = rr.panel_families(cfg, ["grok", "cheap"])
assert count == 2
assert findings == []

count, findings = rr.panel_families(cfg, ["grok", "unmapped-seat"])
assert count == 1
assert findings and "cannot be counted" in findings[0]
print("independent")
PY
  assert_status 0
  assert_output_contains 'independent'
}

@test "hydrated role routes inherit models and auth probes from the central agent catalog" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import importlib.util, json, sys

resolver_path, roles_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))
hydrated = rr.hydrate_catalog(cfg)
for role in hydrated["roles"].values():
    for candidate in role["chain"]:
        facts = cfg["agents"][candidate["agent"]]
        for key in ("provider", "model", "effort", "family", "capabilities"):
            assert candidate[key] == facts[key], (candidate["agent"], key)

for role_name in ("scout", "refuter"):
    candidate = next(
        candidate
        for candidate in cfg["roles"][role_name]["chain"]
        if candidate["agent"] == "flash"
    )
    assert candidate["auth_probe"] == [
        "omp", "token", "google-antigravity"
    ]
print("aligned")
PY
  assert_status 0
  assert_output_contains 'aligned'
}

@test "legacy panel mode retains distinct-family output without quota lookup" {
  run --separate-stderr "$PYTHON" "$RESOLVER" --panel flash,cheap
  assert_status 0
  assert_output_contains 'panel: 2 seats -> 2 distinct families'
}

@test "a scoped Herdr resolution binds policy scope and publishes atomically" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" "$AVAILABLE" <<'PY'
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile

source_resolver, source_roles, source_usage = sys.argv[1:]

with tempfile.TemporaryDirectory() as home:
    trellis_home = os.path.join(home, "trellis")
    payload = os.path.join(trellis_home, "releases", "1.2.3", "payload")
    resolver_path = os.path.join(
        payload,
        "core-rules",
        "skills",
        "herdr-foreman",
        "scripts",
        "resolve-roles.py",
    )
    roles_path = os.path.join(
        payload, "core-rules", "skills", "herdr-foreman", "roles.json"
    )
    os.makedirs(os.path.dirname(resolver_path))
    shutil.copyfile(source_resolver, resolver_path)
    shutil.copyfile(source_roles, roles_path)
    with open(roles_path, "rb") as policy:
        policy_bytes = policy.read()
    cfg = json.loads(policy_bytes)
    usage = json.load(open(source_usage))

    with open(os.path.join(trellis_home, "config.json"), "w") as config:
        json.dump({"active_cli_release": "1.2.3"}, config)
    os.environ.update({
        "TRELLIS_HOME": trellis_home,
        "HERDR_ENV": "1",
        "HERDR_WORKSPACE_ID": "fixture-workspace",
        "HERDR_PANE_ID": "fixture-pane",
        "HERDR_RESOLUTION_NONCE": "fixture-workspace:fixture-pane:pass",
    })
    spec = importlib.util.spec_from_file_location("rr", resolver_path)
    rr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rr)
    rr.OUT = os.path.join(home, ".omp", "agent", "roles-resolved.json")
    rr.load_usage = lambda ttl, fresh, usage_source="omp": (usage, "fixture")
    rr.auth_probe_passes = lambda candidate, cache: True

    def identity(agent):
        facts = cfg["agents"][agent]
        return agent, facts["model"], facts["provider"]

    # Discovery is read-only even when no deciding artifact exists.
    assert not os.path.lexists(rr.OUT)
    sys.argv = [sys.argv[0], "--json"]
    with contextlib.redirect_stdout(io.StringIO()):
        rr.main()
    assert not os.path.lexists(rr.OUT)

    implementer = "luna"
    _, model, provider = identity(implementer)
    sys.argv = [sys.argv[0], "--implementer", implementer, "--json"]
    with contextlib.redirect_stdout(io.StringIO()):
        rr.main()
    with open(rr.OUT) as artifact:
        scoped = json.load(artifact)
    assert stat.S_IMODE(os.stat(rr.OUT).st_mode) == 0o600
    assert scoped["roles_policy"] == {
        "roles_sha256": hashlib.sha256(policy_bytes).hexdigest(),
        "cache_ttl_seconds": cfg["cache_ttl_seconds"],
    }
    assert scoped["resolution_nonce"] == "fixture-workspace:fixture-pane:pass"
    assert scoped["resolution_scope"] == {
        "scoped": True,
        "implementer": implementer,
        "implementer_model": model,
        "implementer_provider": provider,
        "implementer_family": "openai",
        "cross_family_enforced": True,
        "verdict_families_distinct": False,
        "herdr_workspace_id": "fixture-workspace",
        "herdr_pane_id": "fixture-pane",
    }
    chosen = scoped["roles"]["implementer"]["chosen"]
    assert (chosen["agent"], chosen["model"], chosen["provider"]) == (
        implementer,
        model,
        provider,
    )
    assert scoped["approval_ready"] is False
    assert scoped["family_collapse"] == []
    assert scoped["degraded_roles"] == ["merge_reviewer", "refuter"]
    assert scoped["degraded_verdict_roles"] == ["merge_reviewer", "refuter"]
    assert scoped["roles"]["reviewer"]["chosen"]["agent"] == "cheap"
    assert scoped["roles"]["security_reviewer"]["chosen"]["agent"] == "security-reviewer"
    merge = scoped["roles"]["merge_reviewer"]
    assert merge["chosen"] is None
    assert merge["trail"] == []
    refuter = scoped["roles"]["refuter"]
    assert refuter["required_seats"] == 3
    assert [seat["agent"] for seat in refuter["seats"]] == ["glm-flash-go", "flash"]
    assert refuter["chosen"]["agent"] == "glm-flash-go"
    assert all(
        refuter["chosen"].get(key) == refuter["seats"][0].get(key)
        for key in ("agent", "model", "provider", "remaining", "note")
    )
    assert all(
        seat["eligible"] is True and seat["reason"] == "eligible"
        for seat in refuter["seats"]
    )

    # Discovery-only output cannot mutate a valid deciding artifact.
    with open(rr.OUT, "rb") as artifact:
        before = artifact.read()
    sys.argv = [sys.argv[0], "--json"]
    with contextlib.redirect_stdout(io.StringIO()):
        rr.main()
    with open(rr.OUT, "rb") as artifact:
        assert artifact.read() == before

    original_collapse = rr.family_collapse
    rr.family_collapse = lambda *args, **kwargs: ["forced collapse"]
    sys.argv = [sys.argv[0], "--implementer", implementer, "--json"]
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            rr.main()
        except SystemExit as error:
            assert error.code == 1
        else:
            raise AssertionError("collapsed scoped roster was published")
    assert not os.path.lexists(rr.OUT)
    rr.family_collapse = original_collapse

    sys.argv = [sys.argv[0], "--implementer", implementer, "--json"]
    with contextlib.redirect_stdout(io.StringIO()):
        rr.main()
    assert os.path.lexists(rr.OUT)

    # A selector that is configured in policy but does not match the live
    # implementer row clears the artifact rather than publishing stale authority.
    sys.argv = [sys.argv[0], "--implementer", "grok", "--json"]
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            rr.main()
        except SystemExit as error:
            assert error.code == 1
        else:
            raise AssertionError("mismatched scoped implementer was accepted")
    assert not os.path.lexists(rr.OUT)
print("scoped")
PY
  assert_status 0
  assert_output_contains 'scoped'
}

@test "a quota flip between discovery and deciding passes clears stale scope authority" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" "$AVAILABLE" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile

source_resolver, source_roles, source_usage = sys.argv[1:]

with tempfile.TemporaryDirectory() as home:
    trellis_home = os.path.join(home, "trellis")
    payload = os.path.join(trellis_home, "releases", "1.2.3", "payload")
    resolver_path = os.path.join(
        payload,
        "core-rules",
        "skills",
        "herdr-foreman",
        "scripts",
        "resolve-roles.py",
    )
    roles_path = os.path.join(
        payload, "core-rules", "skills", "herdr-foreman", "roles.json"
    )
    os.makedirs(os.path.dirname(resolver_path))
    shutil.copyfile(source_resolver, resolver_path)
    shutil.copyfile(source_roles, roles_path)
    with open(os.path.join(trellis_home, "config.json"), "w") as config:
        json.dump({"active_cli_release": "1.2.3"}, config)
    os.environ.update({
        "TRELLIS_HOME": trellis_home,
        "HERDR_ENV": "1",
        "HERDR_WORKSPACE_ID": "fixture-workspace",
        "HERDR_PANE_ID": "fixture-pane",
        "HERDR_RESOLUTION_NONCE": "fixture-workspace:fixture-pane:flip",
    })
    spec = importlib.util.spec_from_file_location("rr", resolver_path)
    rr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rr)
    rr.OUT = os.path.join(home, ".omp", "agent", "roles-resolved.json")
    rr.auth_probe_passes = lambda candidate, cache: True

    discovery_usage = json.load(open(source_usage))
    deciding_usage = json.loads(json.dumps(discovery_usage))
    for report in deciding_usage["reports"]:
        if report["provider"] == "openai-codex":
            report["limits"][0]["amount"]["remainingFraction"] = 0.0
    usages = iter((
        (discovery_usage, "discovery-fixture"),
        (deciding_usage, "deciding-fixture"),
    ))
    rr.load_usage = lambda ttl, fresh, usage_source="omp": next(usages)

    sys.argv = [sys.argv[0], "--json"]
    discovery_output = io.StringIO()
    with contextlib.redirect_stdout(discovery_output):
        rr.main()
    discovery = json.loads(discovery_output.getvalue())
    selector = discovery["roles"]["implementer"]["chosen"]
    assert selector["agent"] == "luna"

    # Prove the deciding pass removes an artifact that appeared after discovery.
    os.makedirs(os.path.dirname(rr.OUT), exist_ok=True)
    with open(rr.OUT, "w") as stale:
        stale.write("stale")

    sys.argv = [sys.argv[0], "--implementer", selector["agent"], "--json"]
    deciding_output = io.StringIO()
    with contextlib.redirect_stdout(deciding_output):
        try:
            rr.main()
        except SystemExit as error:
            assert error.code == 1
        else:
            raise AssertionError("quota-flipped deciding pass was accepted")
    deciding = json.loads(deciding_output.getvalue())
    assert deciding["roles"]["implementer"]["chosen"]["agent"] == "glm-flash-go"
    assert deciding["resolution_scope"]["implementer"] == "luna"
    assert deciding["resolution_scope"]["implementer_family"] == "openai"
    assert deciding["resolution_scope"]["verdict_families_distinct"] is False
    assert deciding["approval_ready"] is False
    assert not os.path.lexists(rr.OUT)
print("quota-flip-refused")
PY
  assert_status 0
  assert_output_contains 'quota-flip-refused'
}

@test "a scoped resolver outside Herdr removes prior state before refusing" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile

resolver_path, roles_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

with tempfile.TemporaryDirectory() as home:
    rr.ROLES = roles_path
    rr.OUT = os.path.join(home, ".omp", "agent", "roles-resolved.json")
    os.makedirs(os.path.dirname(rr.OUT))
    with open(rr.OUT, "w") as artifact:
        artifact.write('{"stale":true}\n')
    for key in (
        "TRELLIS_HOME",
        "HERDR_ENV",
        "HERDR_WORKSPACE_ID",
        "HERDR_PANE_ID",
        "HERDR_RESOLUTION_NONCE",
    ):
        os.environ.pop(key, None)
    rr.load_usage = lambda *_: (_ for _ in ()).throw(
        AssertionError("out-of-Herdr scope must refuse before usage")
    )
    sys.argv = [sys.argv[0], "--implementer", "luna", "--json"]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rr.main()
    except SystemExit as error:
        assert error.code
        assert "HERDR_ENV=1" in str(error)
    else:
        raise AssertionError("out-of-Herdr scoped resolver exited cleanly")
    assert not os.path.lexists(rr.OUT)
print("out-of-herdr-refused")
PY
  assert_status 0
  assert_output_contains 'out-of-herdr-refused'
}

@test "a scoped resolver outside the active release refuses with Herdr context" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile

source_resolver, source_roles = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", source_resolver)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

with tempfile.TemporaryDirectory() as home:
    trellis_home = os.path.join(home, "trellis")
    payload = os.path.join(trellis_home, "releases", "1.2.3", "payload")
    active_roles = os.path.join(
        payload, "core-rules", "skills", "herdr-foreman", "roles.json"
    )
    active_resolver = os.path.join(
        payload,
        "core-rules",
        "skills",
        "herdr-foreman",
        "scripts",
        "resolve-roles.py",
    )
    os.makedirs(os.path.dirname(active_resolver))
    shutil.copyfile(source_resolver, active_resolver)
    shutil.copyfile(source_roles, active_roles)
    with open(os.path.join(trellis_home, "config.json"), "w") as config:
        json.dump({"active_cli_release": "1.2.3"}, config)

    rr.ROLES = source_roles
    rr.OUT = os.path.join(home, ".omp", "agent", "roles-resolved.json")
    os.makedirs(os.path.dirname(rr.OUT))
    with open(rr.OUT, "w") as artifact:
        artifact.write('{"stale":true}\n')
    os.environ.update({
        "TRELLIS_HOME": trellis_home,
        "HERDR_ENV": "1",
        "HERDR_WORKSPACE_ID": "fixture-workspace",
        "HERDR_PANE_ID": "fixture-pane",
    })
    rr.load_usage = lambda *_: (_ for _ in ()).throw(
        AssertionError("foreign scoped resolver must refuse before usage")
    )
    sys.argv = [sys.argv[0], "--implementer", "luna", "--json"]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rr.main()
    except SystemExit as error:
        assert error.code
        assert "active Trellis release payload" in str(error)
    else:
        raise AssertionError("foreign scoped resolver exited cleanly")
    assert not os.path.lexists(rr.OUT)
print("release-refused")
PY
  assert_status 0
  assert_output_contains 'release-refused'
}

@test "non-object and malformed usage payloads use the safe resolver fallback" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import importlib.util
import json
import os
import sys
import tempfile
import time

resolver_path, roles_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))
rr.auth_probe_passes = lambda candidate, cache: True

class Result:
    returncode = 0

    def __init__(self, stdout):
        self.stdout = stdout

with tempfile.TemporaryDirectory() as home:
    for index, payload in enumerate(("[]", "null", '"text"', "1")):
        rr.CACHE = os.path.join(home, str(index), "usage-cache.json")
        rr.subprocess.run = lambda *args, _payload=payload, **kwargs: Result(
            _payload
        )
        usage, source = rr.load_usage(600, True)
        assert usage is None
        assert source == "unavailable (ValueError)"
        roles, degraded = rr.resolve(cfg, usage, today="2026-08-22")
        assert roles["implementer"]["chosen"] is None
        assert "implementer" in degraded

    # A malformed live result may use only a TTL-valid cache, never an old one.
    rr.CACHE = os.path.join(home, "stale", "usage-cache.json")
    os.makedirs(os.path.dirname(rr.CACHE))
    with open(rr.CACHE, "w") as cache:
        json.dump({"at": time.time() - 601, "usage": {"reports": []}}, cache)
    rr.subprocess.run = lambda *args, **kwargs: Result("null")
    usage, source = rr.load_usage(600, True)
    assert usage is None
    assert source == "unavailable (ValueError)"

    rr.CACHE = os.path.join(home, "valid", "nested", "usage-cache.json")
    rr.subprocess.run = lambda *args, **kwargs: Result('{"reports":[]}')
    usage, source = rr.load_usage(600, True)
    assert usage == {"reports": []}
    assert source == "live"
    assert os.path.isfile(rr.CACHE)

for malformed in (
    {"reports": {}},
    {"disabledCredentials": {}},
    {"reports": [None, {"provider": "opencode", "limits": {}}]},
):
    roles, _ = rr.resolve(cfg, malformed, today="2026-08-22")
    chosen = roles["implementer"]["chosen"]
    assert chosen["agent"] == "glm-flash-go"
    assert chosen["remaining"] is None
    assert chosen["note"] == "prepaid"
print("safe")
PY
  assert_status 0
  assert_output_contains 'safe'
}

@test "an unknown scoped implementer refuses before usage and removes prior state" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile

source_resolver, source_roles = sys.argv[1:]

with tempfile.TemporaryDirectory() as home:
    trellis_home = os.path.join(home, "trellis")
    payload = os.path.join(trellis_home, "releases", "1.2.3", "payload")
    resolver_path = os.path.join(
        payload,
        "core-rules",
        "skills",
        "herdr-foreman",
        "scripts",
        "resolve-roles.py",
    )
    roles_path = os.path.join(
        payload, "core-rules", "skills", "herdr-foreman", "roles.json"
    )
    os.makedirs(os.path.dirname(resolver_path))
    shutil.copyfile(source_resolver, resolver_path)
    shutil.copyfile(source_roles, roles_path)
    with open(os.path.join(trellis_home, "config.json"), "w") as config:
        json.dump({"active_cli_release": "1.2.3"}, config)
    os.environ.update({
        "TRELLIS_HOME": trellis_home,
        "HERDR_ENV": "1",
        "HERDR_WORKSPACE_ID": "fixture-workspace",
        "HERDR_PANE_ID": "fixture-pane",
    })
    spec = importlib.util.spec_from_file_location("rr", resolver_path)
    rr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rr)
    cfg = json.load(open(roles_path))
    rr.auth_probe_passes = lambda candidate, cache: True
    roles, degraded = rr.resolve(
        cfg, {"reports": []}, "typo-agent", today="2026-08-22"
    )
    for role in rr.VERDICT_ROLES:
        resolved = roles[role]
        assert role in degraded
        assert resolved["chosen"] is None
        assert resolved["trail"] == []
        assert resolved["overflow"] is None
        assert len(resolved["refusals"]) == len(cfg["roles"][role]["chain"])
        assert {
            item["reason"] for item in resolved["refusals"]
        } == {"unknown-implementer-family"}
    rr.OUT = os.path.join(home, ".omp", "agent", "roles-resolved.json")
    os.makedirs(os.path.dirname(rr.OUT))
    with open(rr.OUT, "w") as artifact:
        artifact.write('{"stale":true}\n')
    rr.load_usage = lambda *_: (_ for _ in ()).throw(
        AssertionError("unknown implementer must refuse before usage")
    )
    sys.argv = [sys.argv[0], "--implementer", "typo-agent", "--json"]
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            rr.main()
    except SystemExit as error:
        assert error.code
        assert "no entry" in str(error)
    else:
        raise AssertionError("unknown implementer exited cleanly")
    assert not os.path.lexists(rr.OUT)
print("unknown-refused")
PY
  assert_status 0
  assert_output_contains 'unknown-refused'
}

@test "scoped limits that do not govern a model remain unknown" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" <<'PY'
import importlib.util
import json
import sys

resolver_path, roles_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))
rr.auth_probe_passes = lambda candidate, cache: True

usage = {
    "reports": [{
        "provider": "openai-codex",
        "limits": [{
            "scope": {"modelId": "other-model"},
            "amount": {"remainingFraction": 0.01},
        }],
    }]
}
fraction, note = rr.provider_state(
    usage, "openai-codex", "openai-codex/gpt-5.6-sol:xhigh"
)
assert fraction is None
assert note == "no-report"
assert note != "reported"

fraction, note = rr.provider_state(
    {"reports": [{"provider": "google-antigravity", "limits": []}]},
    "google-antigravity",
    "google-antigravity/gemini-3.7-flash:high",
)
assert fraction is None
assert note == "no-report"

roles, _ = rr.resolve(cfg, usage, today="2026-08-22")
chosen = roles["foreman"]["chosen"]
assert chosen["agent"] == "glm-flash-go"
assert chosen["remaining"] is None
assert chosen["note"] == "prepaid"
print("unknown")
PY
  assert_status 0
  assert_output_contains 'unknown'
}

@test "refuter preserves seat zero and reports an incomplete quorum explicitly" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" "$AVAILABLE" <<'PY'
import importlib.util
import json
import sys

resolver_path, roles_path, usage_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))
usage = json.load(open(usage_path))
rr.auth_probe_passes = lambda candidate, cache: True
roles, degraded = rr.resolve(cfg, usage, "luna", today="2026-08-22")
refuter = roles["refuter"]
assert refuter["required_seats"] == 3
assert refuter["seats"]
assert refuter["chosen"]["agent"] == refuter["seats"][0]["agent"]
assert refuter["chosen"]["remaining"] == refuter["seats"][0]["remaining"]
assert refuter["chosen"]["note"] == refuter["seats"][0]["note"]
assert all(
    seat["eligible"] and seat["reason"] == "eligible"
    for seat in refuter["seats"]
)
families = {
    cfg["agents"][seat["agent"]]["family"]
    for seat in refuter["seats"]
}
assert len(families) == len(refuter["seats"])
assert "openai" not in families
assert len(refuter["seats"]) <= refuter["required_seats"]
if len(refuter["seats"]) < refuter["required_seats"]:
    assert "refuter" in degraded
else:
    assert "refuter" not in degraded
print(f"{len(refuter['seats'])}/{refuter['required_seats']}")
PY
  assert_status 0
  assert_output_contains '/'
}

@test "a failed refuter auth probe cannot satisfy the N-of-3 quorum" {
  run --separate-stderr "$PYTHON" - "$RESOLVER" \
    "$REPO_ROOT/core-rules/skills/herdr-foreman/roles.json" "$AVAILABLE" <<'PY'
import importlib.util
import json
import sys

resolver_path, roles_path, usage_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
cfg = json.load(open(roles_path))
good = [sys.executable, "-c", "print('credential-value')"]
for role in cfg["roles"].values():
    for candidate in role["chain"]:
        if "auth_probe" in candidate:
            candidate["auth_probe"] = good
bad = [sys.executable, "-c", "raise SystemExit(1)"]
flash = next(
    candidate
    for candidate in cfg["roles"]["refuter"]["chain"]
    if candidate["agent"] == "flash"
)
flash["auth_probe"] = bad
usage = json.load(open(usage_path))
roles, degraded = rr.resolve(cfg, usage, "luna", today="2026-08-22")
refuter = roles["refuter"]
assert refuter["required_seats"] == 3
assert len(refuter["seats"]) < refuter["required_seats"]
assert "refuter" in degraded
assert refuter["chosen"]["agent"] == refuter["seats"][0]["agent"]
assert all(
    seat["eligible"] and seat["reason"] == "eligible"
    for seat in refuter["seats"]
)
print("degraded")
PY
  assert_status 0
  assert_output_contains 'degraded'
}
