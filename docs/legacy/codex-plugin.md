# Optional compatibility: OpenAI Codex plugin for Claude Code

This page provides compatibility guidance for operators who intentionally use the
OpenAI Codex plugin. The plugin owns its slash-command and background-job workflow;
it is optional to Trellis and never becomes an implicit fallback from an explicit
selection.

## Three separate Codex/GPT surfaces

Do not collapse these into one dependency:

| Surface | Purpose | Dependency? |
|---|---|---|
| Codex CLI harness | Run Codex directly with `AGENTS.md`, `.agents/`, `.codex/` hooks, or deliberate `codex exec` commands | Independent, fully supported |
| OpenAI Codex plugin for Claude Code | Run explicitly selected `/codex:*` review, rescue, transfer, and job-management commands inside Claude Code | Optional plugin-owned direct commands |

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

## Retired Trellis-owned integration

Commit `2ad1808` retired the Trellis-owned `codex-worker`, worker preflight and
rollout, and `codex-executor`/`codex-fanout` Workflow recipes. Those surfaces are
absent: do not invoke, reinstall, or treat them as an available plugin integration.

Direct `codex exec` is independent of plugin state. A plugin user follows the
plugin's own setup and support instructions only after explicitly choosing a
plugin-owned command. Trellis has no worker preflight, rollout, or recipe preflight
for either direct CLI or the plugin.

## Fail-closed compatibility rule

An explicitly selected plugin-owned command never becomes an automatic fallback from
a direct-CLI command, and a direct-CLI command never becomes an automatic fallback
from a plugin-owned command.

If an explicitly selected plugin-owned command fails because setup, authentication,
quota, companion, or app-server state is unavailable:

1. record failure against the selected plugin lane;
2. report that failure to the caller;
3. do not re-dispatch the same unit to Claude or direct Codex CLI;
4. require the caller/operator to select a new lane explicitly.

## Existing plugin users

Existing users may keep plugin installed. Recommended separation:

- use plugin commands only when plugin-specific review/rescue/job UI is desired;
- use direct Codex CLI only when deliberately choosing CLI thread/sandbox controls;
- never let availability failure on one surface silently select another.

No migration requires deleting locally installed plugin files. Trellis no longer owns
plugin navigation, inheritance, dispatch setup, worker, preflight, or rollout paths.
Doctor retains only hook PATH/node-shim validation and repair for installed plugins.
Historical ADRs and changelog entries remain unchanged.

## Further reading

- [Codex routing and effort policy](../codex-routing.md)
- [OpenAI Codex plugin repository](https://github.com/openai/codex-plugin-cc)
