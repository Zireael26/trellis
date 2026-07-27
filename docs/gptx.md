# GPTX model modes

GPTX lets Claude Code and cmux remain the interaction surface while Trellis chooses
which subscription supplies the main model and advisor.

## Modes

| Mode | Main session | Default advisor | When to use it |
|---|---|---|---|
| `gptx` | Claude Opus 1M | Opus | Normal Claude session with selectively addressed GPT agents |
| `codex` | GPT-5.6 Terra xhigh | GPT-5.6 Sol | Claude quota unavailable or a GPT-only run is desired |
| `hybrid` | GPT-5.6 Terra xhigh | Opus, then visible Sol fallback | Fast implementation with stronger cross-model advice |
| `claude` | Claude Opus 1M, direct | Opus | Codex quota exhausted or no local GPT lane desired |

`--model sol|terra|luna|MODEL` and
`--advisor auto|opus|fable|sol|none` override the defaults independently.

`cmux-trellis-teams` ultimately executes `cmux claude-teams`. It injects only Claude
Code settings and forwards every other argument in order, so cmux still owns panes,
teams, hooks, terminals, resumption, and permission behavior.

## Why the GPT context is 272K here

The OpenAI API model page advertises a 1,050,000-token window for GPT-5.6 Sol. That is
an API contract, not proof of the window exposed through a ChatGPT/Codex subscription.
Trellis reads the installed Codex model catalog instead. On the catalog verified
2026-07-27, Sol, Terra, and Luna expose:

- raw window: 272,000;
- effective window at 95%: 258,400;
- Codex's 90% native auto-compact target: 244,800;
- Claude Code maximum for the custom GPT ID: 272,000;
- estimated Claude Code compaction point with current output/reserve defaults: about
  239,000.

Claude Code documents `CLAUDE_CODE_MAX_CONTEXT_TOKENS` specifically for model names it
does not recognize as Claude. It also documents `CLAUDE_CODE_AUTO_COMPACT_WINDOW` as a
process-wide compaction capacity. Trellis sets the former per resolved GPT model and
leaves the latter unset, avoiding a global 272K ceiling on native 1M Claude sessions.

Sources:

- [OpenAI GPT-5.6 Sol API model](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)

Run `trellis model-context gpt-5.6-sol` to see the current machine's values and source
catalog.

## Advisor execution

Claude Code decides whether to expose the advisor before sending a request. For a GPT
main session, Trellis selects the official `opus` alias but pins that alias to the real
GPT model ID with Claude Code's documented model-override variables. The request body
still contains `gpt-5.6-terra` or `gpt-5.6-sol`; the alias is only the local capability
gate and friendly display.

When the GPT implementer calls `advisor`:

1. CLIProxyAPI translates the GPT tool call.
2. The maintained fork recognizes only the internal loopback callback header.
3. It changes the translated ordinary tool block into Claude Code's
   `server_tool_use` block.
4. The Trellis router runs the selected advisor.
5. The router performs exactly one continuation on the original GPT main model with the
   advisor result and the advisor tool removed.
6. The fork appends `advisor_tool_result` and the continuation blocks to the same
   server-tool response, then Claude Code resumes its normal agent loop.

For `auto`, an Opus rate/usage limit persists a Sol fallback with a retry time. The first
switch and first successful restoration are visible in the advisor transcript. Explicit
advisor selections are pinned.

For a Claude main session with `--advisor sol`, Trellis disables the upstream built-in
advisor and asks the read-only `gpt-sol-advisor` agent instead. That exception preserves
the byte-for-byte Anthropic lane.

## Credential boundary

The router uses a closed GPT predicate and an open Anthropic default:

```text
explicit gpt-*, codex-*, oN*, *-sol|terra|luna -> CLIProxyAPI
claude-* and every unknown model              -> api.anthropic.com
```

On the GPT lane, the router removes Claude `authorization` and `x-api-key`, injects the
local CLIProxyAPI key, and removes Trellis selection headers. On the Anthropic lane it
removes only Trellis-internal headers and otherwise acts as a byte-preserving pipe.

The fork receives a single-use callback URL but no Claude credential. A Sol advisor
request is built with fresh proxy-only headers. An Opus/Fable advisor request goes
directly from the Trellis router to `api.anthropic.com` using the original in-memory
Claude headers. Neither credential is persisted in callback state.

## Agent roster

- `gpt-mid`: Sol medium, strong-oracle implementation.
- `gpt-high`: Sol high, moderately complex cross-file work.
- `gpt-sol`: Sol xhigh, difficult or weak-oracle work.
- `gpt-terra`: Terra xhigh, fast bounded implementer paired with a stronger advisor.
- `gpt-sol-advisor`: read-only Sol xhigh advisor for a Claude main-session override.

## Installation and rollback

Follow [AGENT_ONBOARD_GPTX.md](../AGENT_ONBOARD_GPTX.md). It is the executable setup
contract, including fork pin, dry-run, certification, service replacement, updates,
fallback reset, and uninstall.
