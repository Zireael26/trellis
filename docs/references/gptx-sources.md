# GPTX sources and prior art

**Last checked:** 2026-07-29

This ledger separates vendor contracts, implementation provenance, and community prior
art. Mutable repositories are paired with the commit reviewed for this release. A link is
not an endorsement, and community behavior is not evidence of Anthropic support.

## Anthropic: supported gateway shape and unsupported model boundary

### Other LLM gateways

- Page: [Other LLM gateways](https://code.claude.com/docs/en/llm-gateway)
- Accessed: 2026-07-29
- Release-critical statement:

  > “Any gateway that exposes a supported API format works. Anthropic doesn't endorse,
  > maintain, or audit third-party gateway products, and doesn't support routing Claude
  > Code to non-Claude models through any gateway.”

- Subscription behavior:
  - a gateway credential or `apiKeyHelper` replaces the Claude subscription login for
    that session;
  - setting only `ANTHROPIC_BASE_URL` changes destination but leaves the saved
    subscription login active;
  - a gateway forwarding subscription traffic to Anthropic must preserve the OAuth
    capability in `anthropic-beta`.

GPTX uses the second form: `ANTHROPIC_BASE_URL` points Claude Code at the local Trellis
router, while the Anthropic lane preserves the saved subscription credential and required
headers. Non-Claude routing remains unsupported regardless of wire-format compatibility.

Related official pages:

- [Connect Claude Code to an LLM gateway](https://code.claude.com/docs/en/llm-gateway-connect)
- [Gateway protocol reference](https://code.claude.com/docs/en/llm-gateway-protocol)
- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [Model configuration](https://code.claude.com/docs/en/model-config)

## Anthropic: orchestration surfaces reused by GPTX

- [Create custom subagents](https://code.claude.com/docs/en/sub-agents), accessed
  2026-07-29
  - subagents run in isolated context windows with custom prompts, tool access, and
    independent permissions;
  - results return to the caller;
  - custom definitions can choose a model and be reused as teammate roles.
- [Agent teams](https://code.claude.com/docs/en/agent-teams), accessed 2026-07-29
  - agent teams coordinate separate Claude Code instances with shared tasks and direct
    messaging;
  - one session is the lead and teammates have independent context windows;
  - agent teams are experimental, disabled by default, and have documented resumption,
    coordination, nesting, and shutdown limits.
- [Feature overview](https://code.claude.com/docs/en/features-overview), accessed
  2026-07-29
  - subagents run inside one session and report to the caller;
  - agent teams are independent sessions with peer communication and a shared task list;
  - plugins are a packaging layer for skills, hooks, subagents, and MCP servers.
- [Tools reference](https://code.claude.com/docs/en/tools-reference), accessed 2026-07-29
- [Agent view](https://code.claude.com/docs/en/agent-view), accessed 2026-07-29

These pages describe Claude Code's supported orchestration semantics. They do not support
or endorse putting a GPT model behind those surfaces. GPTX's “native-feeling” claim means
it preserves the surrounding Agent/team/tool lifecycle while using an unsupported gateway
model lane.

Trellis Dynamic Workflows are a Trellis orchestration layer over Agent calls, not a
separate Anthropic-supported non-Claude feature. Canonical mechanics live in
[`core-rules/skills/orchestrate/`](../../core-rules/skills/orchestrate/).

## GPT translator provenance

### Maintained fork

- Repository: [__GITHUB_USER__/CLIProxyAPI](https://github.com/__GITHUB_USER__/CLIProxyAPI)
- Reviewed commit:
  [`108b2a535b0241491436149b65cfb78734c61280`](https://github.com/__GITHUB_USER__/CLIProxyAPI/commit/108b2a535b0241491436149b65cfb78734c61280)
- Branch at review: `main`
- License: [MIT](https://github.com/__GITHUB_USER__/CLIProxyAPI/blob/main/LICENSE)
- Trellis pin: [`scripts/gptx/proxy-fork.json`](../../scripts/gptx/proxy-fork.json)

Release-relevant fork scope: loopback advisor callback validation, Claude server-tool
transcript conversion, bounded continuation, shutdown/retry-before-commit reliability,
and callback deadline/replay behavior.

### Upstream

- Repository: [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- License: [MIT](https://github.com/router-for-me/CLIProxyAPI/blob/main/LICENSE)

Upstream documentation owns ordinary CLIProxyAPI configuration, Codex login, and provider
support. Trellis documentation owns only the additional pin, local routing contract,
recovery values, and advisor bridge required by GPTX.

## Official OpenAI Codex plugin for Claude Code

- Repository: [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)
- Commit checked:
  [`db52e28f4d9ded852ab3942cea316258ae4ef346`](https://github.com/openai/codex-plugin-cc/commit/db52e28f4d9ded852ab3942cea316258ae4ef346)
- License: [Apache-2.0](https://github.com/openai/codex-plugin-cc/blob/main/LICENSE)
- Repository description: “Use Codex from Claude Code to review code or delegate tasks.”

README surface checked on 2026-07-29:

- `/codex:review`
- `/codex:adversarial-review`
- `/codex:rescue`
- `/codex:transfer`
- `/codex:status`
- `/codex:result`
- `/codex:cancel`
- `/codex:setup`
- plugin-provided `codex:codex-rescue` subagent
- local Codex CLI and Codex app-server runtime
- asynchronous job management through status/result/cancel

This plugin is useful prior art and may coexist with GPTX. It is not a GPTX dependency.
Its command/job boundary differs from GPTX's routed main-model and registered Agent paths.

## Community Claude/Codex collaboration patterns

These projects were inspected for architecture and workflow shape, not copied into GPTX.
Their repository state can change; use the pinned commit when validating a claim.

### Stop-hook review loop

- Repository: [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop)
- Commit checked:
  [`244f4c7bc15e98552af7cc5a67e70dfcdea9ab12`](https://github.com/hamelsmu/claude-review-loop/commit/244f4c7bc15e98552af7cc5a67e70dfcdea9ab12)
- License metadata: no SPDX license declared by GitHub at access time; verify before reuse.
- Pattern checked:
  - `/review-loop` starts task then review phases;
  - a Claude Code Stop hook blocks exit and instructs Claude to run Codex;
  - up to four Codex review agents cover diff, architecture, framework, and UX lenses;
  - consolidated review artifact lands under `reviews/`.

### Persistent plan and implementation review artifacts

- Repository: [boyand/codex-review](https://github.com/boyand/codex-review)
- Commit checked:
  [`416204c8b1904a28d7cc9dccaf3c8d49145399c2`](https://github.com/boyand/codex-review/commit/416204c8b1904a28d7cc9dccaf3c8d49145399c2)
- License: [MIT](https://github.com/boyand/codex-review/blob/main/LICENSE)
- Pattern checked:
  - Claude plans, Codex reviews the plan, Claude implements, Codex reviews again;
  - plan, review rounds, findings, and decisions are persisted in repository-local
    workflow artifacts;
  - commands expose plan review, implementation review, summary, status, and doctor.

### MCP-mediated plan/implement/review routing

- Repository: [ching-kuo/claude-codex](https://github.com/ching-kuo/claude-codex)
- Commit checked:
  [`9847101d1b15980ba3005429816f2a2ff0ccff62`](https://github.com/ching-kuo/claude-codex/commit/9847101d1b15980ba3005429816f2a2ff0ccff62)
- License: [MIT](https://github.com/ching-kuo/claude-codex/blob/main/LICENSE)
- Pattern checked:
  - Codex is installed as an MCP server for Claude Code;
  - skills/commands implement plan, execution, TDD, and review loops;
  - implementation route can switch by task size;
  - structured review verdicts drive bounded correction rounds.

## What GPTX changes relative to prior art

Prior art commonly crosses a visible boundary at a slash command, Stop hook, MCP call, or
external job. GPTX instead routes an explicitly selected model at the Messages API lane,
which lets GPT occupy these Trellis positions:

- main loop in `codex` or `hybrid` mode;
- registered Agent/subagent profile;
- named teammate profile;
- Dynamic Workflow Agent stage;
- advisor-backed GPT continuation.

That is a boundary reduction, not proof of universal superiority. Costs and risks move
elsewhere: two local services, credential routing, unsupported Anthropic behavior,
translator maintenance, live certification, and reversible operations.

## Source-use rules

1. Quote Anthropic's unsupported boundary verbatim and link the official page.
2. Use “native-feeling” or “through existing harness surfaces,” never “Anthropic-native”
   or “officially supported.”
3. Distinguish Anthropic orchestration semantics from GPTX's unsupported model lane.
4. Pin mutable implementation/community claims to commits.
5. Preserve upstream licenses and attribution.
6. Do not use search-result snippets as final evidence when repository/docs content is
   available.
7. Recheck vendor pages, fork pin, model catalog, and plugin README before every public
   release.
