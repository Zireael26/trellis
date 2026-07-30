# Optional legacy: OpenAI Codex plugin for Claude Code

GPTX does not require the OpenAI Codex plugin for Claude Code. Native GPTX profiles use
the Trellis router and maintained CLIProxyAPI fork through Claude Code's existing model,
Agent, team, and Workflow surfaces.

This page preserves compatibility guidance for operators who already use the plugin or
prefer its slash-command and background-job workflow.

## Three separate Codex/GPT surfaces

Do not collapse these into one dependency:

| Surface | Purpose | GPTX dependency? |
|---|---|---|
| GPTX model lane | Run explicit GPT models as main sessions, Agents, teammates, Workflow stages, and advisor continuations | Core GPTX path |
| Codex CLI harness | Run Codex directly with `AGENTS.md`, `.agents/`, `.codex/` hooks, or deliberate `codex exec` commands | Independent, still supported |
| OpenAI Codex plugin for Claude Code | Add `/codex:*` review, rescue, transfer, and job-management commands inside Claude Code | Optional legacy compatibility |

Removing plugin dependency from GPTX does not remove generic Codex CLI support.

## Plugin behavior

OpenAI describes [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)
as “Use Codex from Claude Code to review code or delegate tasks.” The README checked at
commit
[`db52e28f4d9ded852ab3942cea316258ae4ef346`](https://github.com/openai/codex-plugin-cc/commit/db52e28f4d9ded852ab3942cea316258ae4ef346)
exposes:

- `/codex:review` and `/codex:adversarial-review`;
- `/codex:rescue` and `/codex:transfer`;
- `/codex:status`, `/codex:result`, and `/codex:cancel`;
- `/codex:setup`;
- `codex:codex-rescue` subagent;
- local Codex CLI/app-server execution and asynchronous job state.

License: Apache-2.0. Follow the plugin's own README for installation and support.

## Why GPTX no longer defaults to it

Plugin jobs cross an explicit command/companion boundary. GPTX can instead select GPT at
the model lane and register GPT-backed Agent definitions. That lets Trellis use normal
Agent results, teammate mailboxes, and Workflow receipts without converting each unit into
a plugin job.

Measured difference is topology, not a claim that one model is better:

| Dimension | Plugin path | GPTX path |
|---|---|---|
| Invocation | `/codex:*` command or plugin subagent | `--mode`, `--advisor`, `--delegates`, `--model`, or `gpt-*` Agent type |
| Runtime | Codex plugin + CLI/app server | Trellis router + CLIProxyAPI fork |
| Main loop | Claude remains main | Claude or GPT selected by mode |
| Result tracking | Plugin status/result/cancel | Agent direct result, teammate mailbox, or Workflow receipt |
| Failure policy | Plugin/job contract | Trellis lane lock and fail-closed provider policy |
| Anthropic support boundary | Third-party plugin feature | Non-Claude gateway routing explicitly unsupported by Anthropic |

GPTX adds local gateway and credential-routing responsibility. Plugin use may be simpler
when only occasional Codex review or rescue jobs are wanted.

## Retained Trellis compatibility

Trellis may retain these artifacts for existing installations:

- `core-rules/agents/codex-worker.md`;
- `scripts/codex-worker-preflight.sh`;
- plugin-specific companion references and Workflow recipes;
- provider classifications needed to recognize legacy Agent types.

They are not required inheritance for a GPTX-capable project. Missing plugin state must not
fail native GPTX setup, generic Codex hooks, or public GPTX certification.

Plugin-specific preflight runs only after the operator explicitly selects that route. It
is a runtime check, not a Claude/Codex hook and not a default release gate.

## Fail-closed compatibility rule

A plugin-backed unit never becomes an automatic fallback from a GPTX unit. A GPTX unit
never becomes an automatic fallback from a plugin-backed unit.

If explicit legacy plugin dispatch fails because setup, authentication, quota, companion,
or app-server state is unavailable:

1. record failure against selected legacy lane;
2. return failed receipt;
3. do not re-dispatch same unit to Claude, native GPTX, or direct Codex CLI;
4. require caller/operator to select a new lane explicitly.

This preserves same no-silent-substitution rule as active GPTX modes.

## Existing plugin users

Existing users may keep plugin installed. Recommended separation:

- use GPTX `gpt-*` Agents for generic Agent, team, and Workflow units;
- use plugin commands only when plugin-specific review/rescue/job UI is desired;
- use direct Codex CLI only when deliberately choosing CLI thread/sandbox controls;
- never let availability failure on one surface silently select another;
- do not count plugin job receipt as GPTX live Agent/Workflow certification.

No migration requires deleting plugin files. Removing plugin from default navigation,
inheritance, setup, and validation is enough. Historical ADRs and changelog entries remain
unchanged.

## Further reading

- [GPTX architecture](../gptx.md)
- [GPTX setup](../../AGENT_ONBOARD_GPTX.md)
- [GPTX security](../gptx-security.md)
- [GPTX sources and prior art](../references/gptx-sources.md)
- [OpenAI Codex plugin repository](https://github.com/openai/codex-plugin-cc)
