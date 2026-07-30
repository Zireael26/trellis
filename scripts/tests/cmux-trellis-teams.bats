#!/usr/bin/env bats

setup() {
  export ROOT
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAUNCHER="$ROOT/scripts/cmux-trellis-teams"
  export CMUX_BIN=/usr/bin/true
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex"
  mkdir -p "$CODEX_HOME"
  cp "$BATS_TEST_DIRNAME/fixtures/models-cache-272k.json" "$CODEX_HOME/models_cache.json"
}

json_field() {
  jq -r "$1" <<<"$output"
}

@test "gptx preserves the Claude main loop and split router" {
  run "$LAUNCHER" --dry-run --mode gptx --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [ "$(json_field '.mode')" = gptx ]
  [ "$(json_field '.main_model')" = "opus[1m]" ]
  [ "$(json_field '.base_url')" = http://127.0.0.1:8318 ]
  [ "$(json_field '.command[-1]')" = --dangerously-skip-permissions ]
}

@test "codex maps the opus family to Sol and distinguishes default from explicit advisor" {
  run "$LAUNCHER" --dry-run --mode codex
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-sol ]
  [ "$(json_field '.claude_model')" = opus ]
  [ "$(json_field '.advisor')" = sol ]
  [ "$(json_field '.policy.effective.advisor_source')" = mode-default ]
  [ "$(json_field '.advisor_transport')" = server-tool ]
  [ "$(json_field '.settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL')" = gpt-5.6-sol ]
  [ "$(json_field '.settings.env.TRELLIS_GPTX_MODEL_ALIASES | fromjson | .opus')" = gpt-5.6-sol ]
  [ "$(json_field '.settings.env.TRELLIS_GPTX_MODEL_ALIASES | fromjson | .sonnet')" = claude-sonnet-5 ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS')" = 272000 ]
  # This used to assert `unset`, which was asserting the hazard rather than the fix: the
  # operator's shell exports a process-wide AUTO_COMPACT_WINDOW sized for Opus's 1M
  # context, so leaving it unset here let a 272K GPT session inherit a compact threshold
  # above its own window — auto-compact never fires and the session dies on
  # `Prompt is too long`. Now set per session, and strictly below the window.
  [ "$(json_field '.settings.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW')" = 239000 ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW')" \
    -lt "$(json_field '.settings.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS')" ]
  [[ "$(json_field '.command | join(" ")')" == *"the root orchestrator may pass name"* ]]

  run "$LAUNCHER" --dry-run --mode codex --advisor sol
  [ "$status" -eq 0 ]
  [ "$(json_field '.advisor')" = sol ]
  [ "$(json_field '.policy.effective.advisor_source')" = explicit ]
}

@test "hybrid defaults to Sol with an auto Claude to Sol advisor" {
  run "$LAUNCHER" --dry-run --mode hybrid
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-sol ]
  [ "$(json_field '.advisor')" = auto ]
  [ "$(json_field '.settings.advisorModel')" = claude-opus-5 ]
}

@test "delegates defaults to auto and stays orthogonal to main and advisor" {
  run "$LAUNCHER" --dry-run --mode hybrid --advisor fable
  [ "$status" -eq 0 ]
  baseline_main="$(json_field '.main_model')"
  baseline_advisor="$(json_field '.advisor')"
  [ "$(json_field '.delegates')" = auto ]
  [ "$(json_field '.policy.effective.delegates_source')" = default ]
  [ "$(json_field '.settings.env.TRELLIS_GPTX_DELEGATES')" = auto ]
  [ "$(json_field '.settings.env.TRELLIS_GPTX_POLICY_VERSION')" = 2 ]
  [ "$(json_field '.settings.env.TRELLIS_GPTX_MODEL_ALIASES | fromjson | .fable')" = claude-fable-5 ]
  [ "$(json_field '.settings.hooks.PreToolUse[0].matcher')" = Agent ]
  [[ "$(json_field '.settings.hooks.PreToolUse[0].hooks[0].command')" == *delegation-guard.js* ]]

  local policy
  for policy in auto gpt claude none; do
    run "$LAUNCHER" --dry-run --mode hybrid --advisor fable --delegates "$policy"
    [ "$status" -eq 0 ]
    [ "$(json_field '.main_model')" = "$baseline_main" ]
    [ "$(json_field '.advisor')" = "$baseline_advisor" ]
    [ "$(json_field '.delegates')" = "$policy" ]
    [ "$(json_field '.policy.effective.delegates_source')" = explicit ]
  done
}

@test "pure Claude bypasses the local router while delegate policy stays independent" {
  run "$LAUNCHER" --dry-run --mode claude --delegates gpt
  [ "$status" -eq 0 ]
  [ "$(json_field '.base_url')" = https://api.anthropic.com ]
  [ "$(json_field '.topology')" = direct ]
  [ "$(json_field '.delegates')" = gpt ]
  [ "$(json_field '.advisor_transport')" = server-tool ]
  [ "$(json_field '.settings.env.ANTHROPIC_CUSTOM_HEADERS // "unset"')" = unset ]
  [ "$(json_field '.settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL')" = claude-opus-5 ]
  [ "$(json_field '.settings.env.TRELLIS_GPTX_MODEL_ALIASES | fromjson | .opus')" = claude-opus-5 ]
  [[ "$(json_field '.policy.effective.capability_note')" == *"no local GPT route"* ]]
}

@test "Claude with Sol advisor uses the explicit nested-agent override" {
  run "$LAUNCHER" --dry-run --mode claude --advisor sol
  [ "$status" -eq 0 ]
  [ "$(json_field '.base_url')" = http://127.0.0.1:8318 ]
  [ "$(json_field '.advisor_transport')" = nested-agent ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL')" = 1 ]
  [[ "$(json_field '.command | join(" ")')" == *gpt-sol-advisor* ]]
}

@test "explicit Terra remains available when paired with a smarter advisor" {
  run "$LAUNCHER" --dry-run --mode hybrid --model terra --advisor fable
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-terra ]
  [ "$(json_field '.advisor')" = fable ]
  [ "$(json_field '.settings.advisorModel')" = claude-fable-5 ]
}

@test "a Terra main loop requires a reachable cross-family oracle" {
  # The per-unit advice-before-mutation gate was retired 2026-07-30 for DELEGATED Terra,
  # where the orchestrator reviews the finished diff. Cross-model review found the
  # retirement went one step too far: as the MAIN model Terra is the top of the loop, so
  # there is no orchestrator to do that review. A Terra main loop must be able to REACH a
  # Claude-family oracle — as advisor, or as a delegate it may spawn.
  # NOTE: grep, not [[ ]] — a failing [[ ]] does not abort under `set -e` here, so bats
  # silently ignores it.

  # No oracle by either route: rejected before launch.
  run "$LAUNCHER" --dry-run --mode codex --model terra --advisor none --delegates none
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -Fq 'cross-family oracle'

  # `--advisor sol` is same-family review and must be named as insufficient. This is the
  # case the RETIRED gate accepted, so it is the load-bearing assertion here.
  run "$LAUNCHER" --dry-run --mode codex --model terra --advisor sol --delegates gpt
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -Fq 'GPT reviewing GPT is not independent review'

  # A Claude-family advisor satisfies it with no notice needed.
  run "$LAUNCHER" --dry-run --mode codex --model terra --advisor opus --delegates none
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-terra ]
  [ "$(json_field '.policy.effective.notices | length')" = 0 ]

  # A spawnable Claude reviewer also satisfies it, but carries the notice.
  run "$LAUNCHER" --dry-run --mode codex --model terra --advisor none --delegates claude
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-terra ]
  [ "$(json_field '.policy.effective.terra_advisor_recommended')" = true ]
  printf '%s\n' "$(json_field '.policy.effective.notices | join(" ")')" \
    | grep -Fq 'not automatic'

  # hybrid defaults delegates to auto, which includes Claude, so this stays permitted.
  run "$LAUNCHER" --dry-run --mode hybrid --model gpt-5.6-terra --advisor none
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-terra ]
}

@test "policy notices reach the operator on a real launch, not only in --dry-run JSON" {
  # Regression: notices were emitted by session-policy and read by nobody. The launcher
  # never extracted them, so the only place they appeared was inside --dry-run JSON —
  # and the test suite asserted them only there, so the live gap passed. A notice the
  # operator cannot see does not tell them what they turned off.
  # Fully stubbed HOME/curl/launchctl/nc: this must never touch a real gateway.
  fake_home="$BATS_TEST_TMPDIR/home-notice"
  fake_bin="$BATS_TEST_TMPDIR/bin-notice"
  mkdir -p "$fake_bin" "$fake_home/Library/LaunchAgents"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/curl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/nc"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/launchctl"
  chmod +x "$fake_bin/curl" "$fake_bin/nc" "$fake_bin/launchctl"

  run env \
    HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    CMUX_BIN=/usr/bin/true \
    CODEX_HOME="$CODEX_HOME" \
    "$LAUNCHER" --mode codex --model terra --advisor none --delegates claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'Trellis notice:'
  printf '%s\n' "$output" | grep -Fq 'not automatic'

  # A session with nothing turned off must stay quiet — no empty "Trellis notice:" line.
  run env \
    HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    CMUX_BIN=/usr/bin/true \
    CODEX_HOME="$CODEX_HOME" \
    "$LAUNCHER" --mode codex
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -Fq 'Trellis notice:'
}

@test "advisor-none sessions permit Terra delegation but flag it unadvised" {
  run "$LAUNCHER" --dry-run --mode codex --advisor none
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-sol ]
  printf '%s\n' "$(json_field '.command | join(" ")')" | grep -Fq 'runs unadvised'
  # The old prohibition must be gone, not merely reworded.
  ! printf '%s\n' "$(json_field '.command | join(" ")')" \
    | grep -Fq 'do not delegate any task to gpt-terra'
}

@test "Terra and flat Agent lifecycle contracts are explicit" {
  run grep -F "Keep the implementation unit small enough that tests and review can arbitrate it" \
    "$ROOT/core-rules/agents/gpt-terra.md"
  [ "$status" -eq 0 ]

  # Advice-before-mutation was retired 2026-07-30 for reversible in-repo work only. What
  # must still be stated is that a missing advisor is reported as residual risk rather than
  # silently swallowed, that the review gate arbitrates the reversible case, and that the
  # irreversible-work stop is an instruction rather than a mechanized block — the file must
  # not claim an enforcement that no hook provides.
  run grep -F "name the missing advice as residual risk" \
    "$ROOT/core-rules/agents/gpt-terra.md"
  [ "$status" -eq 0 ]

  run grep -F "only mandatory arbiter" \
    "$ROOT/core-rules/agents/gpt-terra.md"
  [ "$status" -eq 0 ]

  run grep -F "rather than a mechanized block" \
    "$ROOT/core-rules/agents/gpt-terra.md"
  [ "$status" -eq 0 ]

  run grep -F 'The root orchestrator may pass `name` only when intentionally creating a teammate mailbox.' \
    "$ROOT/core-rules/references/delegation.md"
  [ "$status" -eq 0 ]

  run grep -F 'A named teammate or any nested Agent caller must omit `name`' \
    "$ROOT/core-rules/references/delegation.md"
  [ "$status" -eq 0 ]

  run grep -F 'call `TaskStop` by name in the same turn that accepts' \
    "$ROOT/core-rules/references/delegation.md"
  [ "$status" -eq 0 ]

  local agent_file
  for agent_file in gpt-mid gpt-high gpt-sol gpt-terra; do
    run grep -F 'nested work is an unnamed direct-result subagent' \
      "$ROOT/core-rules/agents/$agent_file.md"
    [ "$status" -eq 0 ]
  done
}

@test "normalized mode is used consistently after policy resolution" {
  run "$LAUNCHER" --dry-run --mode ' CODEX '
  [ "$status" -eq 0 ]
  [ "$(json_field '.mode')" = codex ]
  [ "$(json_field '.policy.effective.mode')" = codex ]
  [[ "$(json_field '.settings.env.ANTHROPIC_CUSTOM_HEADERS')" == *"X-Trellis-Mode: codex"* ]]
}

@test "unknown Claude arguments are forwarded in order" {
  run "$LAUNCHER" --dry-run --mode codex -- --resume abc --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [ "$(json_field '.command[-3]')" = --resume ]
  [ "$(json_field '.command[-2]')" = abc ]
  [ "$(json_field '.command[-1]')" = --dangerously-skip-permissions ]
}

@test "a real GPTX launch reloads absent installed services before cmux" {
  fake_home="$BATS_TEST_TMPDIR/home"
  fake_bin="$BATS_TEST_TMPDIR/bin"
  launch_dir="$fake_home/Library/LaunchAgents"
  mkdir -p "$fake_bin" "$launch_dir"
  touch "$launch_dir/dev.trellis.cliproxyapi.plist"
  touch "$launch_dir/dev.trellis.gptx-router.plist"

  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
state="${BATS_TEST_TMPDIR:?}/gateway-ready"
[[ -f "$state" ]]
EOF
  cat > "$fake_bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BATS_TEST_TMPDIR:?}/launchctl.log"
if [[ "$1" == print ]]; then
  exit 1
fi
if [[ "$1" == bootstrap && "$3" == *gptx-router.plist ]]; then
  touch "${BATS_TEST_TMPDIR:?}/gateway-ready"
fi
EOF
  # This scenario is "installed services are absent", so nothing is bound to the port.
  # Stub nc accordingly: without it the launcher's listening-check reaches the REAL
  # router on this machine, decides the gateway is merely slow, and skips the bootstrap
  # this test exists to assert.
  cat > "$fake_bin/nc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake_bin/curl" "$fake_bin/launchctl" "$fake_bin/nc"

  run env \
    HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    CMUX_BIN=/usr/bin/true \
    CODEX_HOME="$CODEX_HOME" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    "$LAUNCHER" --mode codex
  [ "$status" -eq 0 ]
  run grep -F "bootstrap gui/$(id -u) $launch_dir/dev.trellis.cliproxyapi.plist" \
    "$BATS_TEST_TMPDIR/launchctl.log"
  [ "$status" -eq 0 ]
  run grep -F "bootstrap gui/$(id -u) $launch_dir/dev.trellis.gptx-router.plist" \
    "$BATS_TEST_TMPDIR/launchctl.log"
  [ "$status" -eq 0 ]
}

@test "invalid selectors and cross-mode models fail closed" {
  run "$LAUNCHER" --dry-run --mode nope
  [ "$status" -eq 2 ]

  run "$LAUNCHER" --dry-run --delegates nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown delegates policy"* ]]

  run "$LAUNCHER" --dry-run --mode codex --model opus
  [ "$status" -eq 2 ]

  run "$LAUNCHER" --dry-run --mode claude --model terra
  [ "$status" -eq 2 ]
}

@test "a listening but slow gateway is never restarted" {
  # Regression guard. `gateway_ready` used a 2s timeout and any failure kickstarted the
  # router, so a status probe that timed out under load restarted a HEALTHY gateway and
  # dropped every in-flight request for every other session on the machine. Observed
  # 2026-07-30 while three concurrent GPT agents were streaming.
  fake_home="$BATS_TEST_TMPDIR/home2"
  fake_bin="$BATS_TEST_TMPDIR/bin2"
  launch_dir="$fake_home/Library/LaunchAgents"
  mkdir -p "$fake_bin" "$launch_dir"
  touch "$launch_dir/dev.trellis.cliproxyapi.plist"
  touch "$launch_dir/dev.trellis.gptx-router.plist"

  # curl always fails => the readiness probe times out, as under heavy load.
  printf '#!/usr/bin/env bash\nexit 28\n' > "$fake_bin/curl"
  # nc succeeds => something IS bound to the port, so the process is alive.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/nc"
  cat > "$fake_bin/launchctl" <<'INNER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BATS_TEST_TMPDIR:?}/launchctl-slow.log"
INNER
  chmod +x "$fake_bin/curl" "$fake_bin/nc" "$fake_bin/launchctl"
  : > "$BATS_TEST_TMPDIR/launchctl-slow.log"

  run env HOME="$fake_home" PATH="$fake_bin:$PATH" CMUX_BIN=/usr/bin/true \
    CODEX_HOME="$CODEX_HOME" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    "$LAUNCHER" --mode codex
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'listening but slow'
  # The whole point: launchctl must never have been invoked.
  [ ! -s "$BATS_TEST_TMPDIR/launchctl-slow.log" ]
}

@test "the model alias is authoritative over an inherited CLI effort" {
  # A delegated agent inherits the PARENT session's --effort, so a gpt-high pane displays
  # "xhigh effort" even though its profile declares high. The router's alias rewrite is
  # what actually reaches upstream, and it overrides the inherited value. Pin that
  # precedence: if it ever inverts, every profile silently runs at the parent's effort and
  # the medium/high/xhigh ladder becomes decorative.
  run node -e '
    const {prepareForwardBody} = require(process.env.ROOT + "/scripts/gptx/effort-alias.js");
    const parsed = {model: "gpt-5.6-sol-high", output_config: {effort: "xhigh"}, messages: []};
    const r = prepareForwardBody({lane: "codex", parsedBody: parsed,
      body: Buffer.from(JSON.stringify(parsed))});
    const fwd = JSON.parse(r.body.toString());
    if (fwd.model !== "gpt-5.6-sol") throw new Error("model not collapsed: " + fwd.model);
    if (fwd.output_config.effort !== "high") throw new Error("alias lost to CLI: " + fwd.output_config.effort);
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq ok
}
