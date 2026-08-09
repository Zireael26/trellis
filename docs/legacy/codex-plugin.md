# Optional legacy: OpenAI Codex plugin for Claude Code

This page preserves compatibility guidance for operators who already use the OpenAI
Codex plugin or prefer its slash-command and background-job workflow. The plugin is
optional legacy compatibility — it is not required by Trellis and never becomes an
implicit fallback from an explicit selection.

## Three separate Codex/GPT surfaces

Do not collapse these into one dependency:

| Surface | Purpose | Dependency? |
|---|---|---|
| Codex CLI harness | Run Codex directly with `AGENTS.md`, `.agents/`, `.codex/` hooks, or deliberate `codex exec` commands | Independent, fully supported |
| OpenAI Codex plugin for Claude Code | Add `/codex:*` review, rescue, transfer, and job-management commands inside Claude Code | Optional legacy compatibility |

Removing plugin dependency does not remove generic Codex CLI support.

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

## Why Trellis does not default to it

Plugin jobs cross an explicit command/companion boundary. Trellis routes Codex work
through the direct CLI (deliberate `codex exec` dispatch) so units stay on normal
Agent/Workflow receipts instead of being converted into plugin jobs. The measured
difference is topology, not a claim that one model is better.

## Retained Trellis compatibility

Trellis may retain these artifacts for existing installations:

- `core-rules/agents/codex-worker.md`;
- `scripts/codex-worker-preflight.sh`;
- plugin-specific companion references and Workflow recipes;
- provider classifications needed to recognize legacy Agent types.

They are not required inheritance. Missing plugin state must not fail generic Codex
hooks or direct-CLI dispatch.

Plugin-specific preflight runs only after the operator explicitly selects that route. It
is a runtime check, not a Claude/Codex hook and not a default release gate.

## Fail-closed compatibility rule

A plugin-backed unit never becomes an automatic fallback from a direct-CLI unit, and a
direct-CLI unit never becomes an automatic fallback from a plugin-backed unit.

If explicit legacy plugin dispatch fails because setup, authentication, quota, companion,
or app-server state is unavailable:

1. record failure against selected legacy lane;
2. return failed receipt;
3. do not re-dispatch same unit to Claude or direct Codex CLI;
4. require caller/operator to select a new lane explicitly.

## Existing plugin users

Existing users may keep plugin installed. Recommended separation:

- use plugin commands only when plugin-specific review/rescue/job UI is desired;
- use direct Codex CLI only when deliberately choosing CLI thread/sandbox controls;
- never let availability failure on one surface silently select another.

No migration requires deleting plugin files. Removing plugin from default navigation,
inheritance, setup, and validation is enough. Historical ADRs and changelog entries remain
unchanged.

## Further reading

- [Codex routing and effort policy](../codex-routing.md)
- [OpenAI Codex plugin repository](https://github.com/openai/codex-plugin-cc)
