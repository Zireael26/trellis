#!/usr/bin/env bats
# Spec 052 SC7: the SessionStart artifact validator, run end to end through
# BOTH hook copies (Claude Code and Codex). A stub active-release resolver
# publishes each crafted artifact from the shared SC7 fixture set with the
# hook's own per-pass nonce, so the hook's embedded validator is the only
# thing deciding accept or reject.

load helpers

REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"
SC7_BUILDER="$REPO_ROOT/scripts/tests/fixtures/herdr-task-routing/sc7_artifacts.py"
SESSION_HOOKS=("$HOOKS_DIR/herdr-foreman-session.sh" "$CODEX_HOOKS_DIR/herdr-foreman-session.sh")

setup() {
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  SKILL="$FAKE_HOME/.trellis/releases/1.2.3/payload/core-rules/skills/herdr-foreman"
  ROLE_STATE="$FAKE_HOME/.trellis/state/roles-resolved.json"
  SC7_DIR="$BATS_TEST_TMPDIR/sc7"
  CLI_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SKILL/scripts" "$CLI_DIR"
  cp "$HOOKS_DIR/../skills/herdr-foreman/roles.json" "$SKILL/roles.json"
  printf '{"active_cli_release":"1.2.3"}\n' >"$FAKE_HOME/.trellis/config.json"

  # Discovery names the case's implementer; the deciding pass publishes the
  # crafted artifact atomically at mode 0600 under the hook-supplied nonce.
  cat >"$SKILL/scripts/resolve-roles.py" <<'PY'
import json, os, sys, tempfile
if "--implementer" not in sys.argv:
    print(json.dumps({"roles": {"implementer": {"chosen": {
        "agent": os.environ["SC7_IMPLEMENTER"]}}}}))
    raise SystemExit(0)
artifact = json.load(open(os.environ["SC7_ARTIFACT"]))
artifact["resolution_nonce"] = os.environ["HERDR_RESOLUTION_NONCE"]
out = os.path.expanduser("~/.trellis/state/roles-resolved.json")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out))
os.fchmod(fd, 0o600)
with os.fdopen(fd, "w") as sink:
    json.dump(artifact, sink)
os.replace(tmp, out)
print("stub deciding table")
PY
  printf '#!/usr/bin/env bash\nexit 0\n' >"$CLI_DIR/pi"
  cat >"$CLI_DIR/herdr" <<'EOF'
#!/usr/bin/env bash
printf '{"result":{"agents":[]}}\n'
EOF
  chmod +x "$CLI_DIR/pi" "$CLI_DIR/herdr"

  python3 "$SC7_BUILDER" "$SKILL/roles.json" "$SC7_DIR" \
    fixture-workspace fixture-pane placeholder-nonce
}

case_field() {
  python3 - "$SC7_DIR/manifest.json" "$1" "$2" <<'PY'
import json, sys
manifest, case, field = sys.argv[1:]
print(next(row[field] for row in json.load(open(manifest)) if row["case"] == case))
PY
}

# assert_case CASE [REASON]: both hook copies accept or reject CASE as the
# manifest expects; a rejection must name REASON when one is given.
assert_case() {
  local case="$1" reason="${2:-}" expect implementer hook
  expect="$(case_field "$case" expect)"
  implementer="$(case_field "$case" implementer)"
  for hook in "${SESSION_HOOKS[@]}"; do
    rm -f "$ROLE_STATE"
    run env -u CODE_REVIEWER_CMD \
      HOME="$FAKE_HOME" TRELLIS_HOME="$FAKE_HOME/.trellis" \
      HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane \
      SC7_ARTIFACT="$SC7_DIR/$case.json" SC7_IMPLEMENTER="$implementer" \
      PATH="$CLI_DIR:$PATH" \
      bash "$hook"
    [ "$status" -eq 0 ] || { echo "$hook exited $status: $output"; return 1; }
    [[ "$output" == *"stub deciding table"* ]] || {
      echo "$hook never reached the deciding pass: $output"; return 1; }
    if [ "$expect" = accept ]; then
      [[ "$output" != *"DEGRADED"* ]] || {
        echo "$hook rejected SC7($case): $output"; return 1; }
      [ -f "$ROLE_STATE" ] || { echo "$hook removed SC7($case) artifact"; return 1; }
    else
      [[ "$output" == *"DEGRADED: deciding resolver artifact was missing, stale, unscoped, or malformed for implementer $implementer"* ]] || {
        echo "$hook accepted SC7($case): $output"; return 1; }
      [ ! -e "$ROLE_STATE" ] || { echo "$hook kept rejected SC7($case) artifact"; return 1; }
      if [ -n "$reason" ] && [[ "$output" != *"$reason"* ]]; then
        echo "$hook rejected SC7($case) for another reason: $output"
        return 1
      fi
    fi
  done
}

@test "both session hook copies are byte-identical" {
  cmp "${SESSION_HOOKS[@]}"
}

@test "SC7(a) a merge reviewer in the reviewer's family is accepted" {
  assert_case a
}

@test "SC7(b) refuter seats in the security and merge families are accepted" {
  assert_case b
}

@test "SC7(c) a security reviewer in the reviewer's family is rejected" {
  assert_case c "security_reviewer shares the reviewer family"
}

@test "SC7(d) verdict seats in the producer's family are rejected" {
  assert_case d-reviewer "chosen verdict shares the implementer family"
  assert_case d-merge "chosen verdict shares the implementer family"
  assert_case d-refuter "refuter trail reuses the implementer family"
}

@test "SC7(e) a refuter seat in the reviewer's family is rejected" {
  assert_case e "refuter trail reuses the reviewer family"
}

@test "SC7(f) two refuter seats in one family are rejected" {
  assert_case f "refuter seats do not match the eligible family prefix"
}

@test "SC7(g) a 1.3.4 seat layout passes independence but keeps policy binding and DEGRADED seats" {
  assert_case g
  assert_case g-policy-sha "artifact does not bind the active release policy"
  assert_case g-missing-seats "degraded_roles do not match resolved rows"
}

@test "SC4 a launcher that contradicts the catalog harness or its trail is rejected" {
  assert_case h-launcher-forged "eligible trail contains a refusal or foreign candidate"
  assert_case h-launcher-split "chosen candidate is not the first eligible trail entry"
}

@test "SC7 every eligible verdict fallback obeys the independence rules" {
  assert_case i-fallbacks-ok
  assert_case i-reviewer-trail "verdict trail shares the implementer family"
  assert_case i-security-trail "security_reviewer trail shares the reviewer family"
  assert_case i-merge-trail "verdict trail shares the implementer family"
}

@test "SC7(e) a reviewer-family refuter entry after three valid seats is rejected" {
  assert_case e-late "refuter trail reuses the reviewer family"
}
